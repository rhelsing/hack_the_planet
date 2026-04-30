class_name CutscenePlayer
extends Node

## Drives a CutsceneTimeline. Drop one in your level scene, point it at a
## timeline resource, optionally bind an arm_flag — when the flag flips
## true (or arm() is called manually), the timeline plays.
##
## Per-instance state. No statics. Concurrent CutscenePlayers in the same
## scene are independent. See docs/cutscene_engine.md for the full design.

signal step_started(step: CutsceneStep, index: int)
signal step_ended(step: CutsceneStep, index: int)
signal ended(success: bool)   # success=false on cancel

# ── Authoring ────────────────────────────────────────────────────────────

## The script to play. .tres file referencing a CutsceneTimeline.
@export var timeline: CutsceneTimeline

## Optional flag that auto-arms the cutscene. When this flag flips to true
## on GameState, play() fires. Empty = no auto-arm; only manual arm() works.
@export var arm_flag: StringName = &""

## Auto-cancel hook. While the cutscene is running, if this flag flips true,
## cancel() fires. Empty = no auto-cancel.
@export var stop_flag: StringName = &""

## When true (default), arm_flag-triggered play fires once per save.
## Cancel/skip count as "fired." Manual arm() bypasses this gate.
@export var fire_once: bool = true

## Optional keyboard shortcut for manual arm. KEY_NONE disables. Useful
## for QA — bind F11 to a cutscene and press to fire it on demand.
@export var debug_hotkey: Key = KEY_NONE

# ── Run state (per-instance, not static) ─────────────────────────────────

var _running: bool = false
var _paused: bool = false
var _cancelled: bool = false
var _skip_requested: bool = false
var _fired: bool = false
var _current_index: int = 0

# Saved state for restore on cutscene end.
var _saved_player: Node3D = null
var _saved_player_physics: bool = true
var _saved_brain: Node = null
var _saved_brain_input: bool = true
var _saved_brain_unhandled: bool = true
# Stored as Node, not CanvasItem — the HUD root is a CanvasLayer in this
# project, and CanvasLayer is NOT a CanvasItem in Godot 4's class
# hierarchy. We toggle .visible duck-typed so this works for either.
var _hud_root: Node = null
var _saved_hud_visible: bool = true

# ── Skip-prompt state ────────────────────────────────────────────────────
# `_skip_progress` is the single source of truth for the bar fill: 0.0
# (idle) to 1.0 (skip triggered). Holding the skip key ticks it up at
# 1/skip_hold_seconds per second; releasing ticks it DOWN at the same
# rate. When it hits 0.0 with no hold, the prompt fades. This gives the
# bar a symmetric "fill in / drain out" feel, which reads as honest
# affordance (the player sees their commitment level rise + fall in
# real time, not a binary on/off).
var _skip_hold_active: bool = false
var _skip_progress: float = 0.0
var _skip_prompt: CanvasLayer = null
var _skip_prompt_visible: bool = false
var _skip_prompt_label: Label = null
var _skip_prompt_bar: ProgressBar = null
var _skip_prompt_tween: Tween = null


# ── Lifecycle ────────────────────────────────────────────────────────────

func _ready() -> void:
	# INHERIT — pause the tree, pause the player. The whole pause-respect
	# chain hinges on this not being ALWAYS.
	process_mode = Node.PROCESS_MODE_INHERIT
	if arm_flag != &"" and not bool(GameState.get_flag(arm_flag, false)):
		Events.flag_set.connect(_on_flag_set)
	elif arm_flag != &"" and fire_once:
		_fired = true   # already past this beat on resume
	# Auto-cancel hook.
	if stop_flag != &"":
		Events.flag_set.connect(_on_stop_flag_set)
	# Pause integration. CutsceneAudio handles voice + music; we connect to
	# the global pause-changed so the audio service is told once per toggle
	# regardless of who triggered the pause.
	var pc := get_tree().root.get_node_or_null(^"PauseController")
	if pc != null and pc.has_signal(&"paused_changed"):
		pc.paused_changed.connect(_on_paused_changed)


func _input(event: InputEvent) -> void:
	# Debug hotkey — fires arm() regardless of fire_once. Useful for QA.
	if debug_hotkey != KEY_NONE and event is InputEventKey:
		var ek: InputEventKey = event as InputEventKey
		if ek.pressed and not ek.echo and ek.keycode == debug_hotkey:
			get_viewport().set_input_as_handled()
			arm()


func _unhandled_input(event: InputEvent) -> void:
	# Hold-to-skip. Pressing skip_action sets the hold flag + shows the
	# prompt; releasing clears the hold flag. Per-frame logic in
	# _process integrates _skip_progress up while held / down while
	# released. Gated on `freeze_player = true` so non-blocking cutscenes
	# (battle radio, ambient chatter) leave the interact key free for
	# gameplay use — see skip_action docs in cutscene_timeline.gd.
	if not _is_skip_eligible():
		return
	if event.is_action_pressed(timeline.skip_action):
		get_viewport().set_input_as_handled()
		_skip_hold_active = true
		_show_skip_prompt()
	elif event.is_action_released(timeline.skip_action):
		_skip_hold_active = false


# Skip is allowed iff we're running, the timeline opts in, AND the cutscene
# is "blocking" (player frozen). Non-blocking cutscenes don't claim the
# interact key — that'd hijack interactable affordance during gameplay.
func _is_skip_eligible() -> bool:
	if not _running or timeline == null:
		return false
	if not timeline.allow_skip:
		return false
	if not timeline.freeze_player:
		return false
	return true


func _process(delta: float) -> void:
	# Skip-prompt integration. When held, _skip_progress rises at
	# 1/hold_seconds per second; when released, it falls at the same
	# rate. Hits 1.0 → fire skip. Hits 0.0 with no hold → hide prompt.
	if _skip_prompt == null:
		return
	var hold_dur: float = max(timeline.skip_hold_seconds if timeline != null else 3.0, 0.1)
	var rate: float = delta / hold_dur
	if _skip_hold_active:
		_skip_progress = clampf(_skip_progress + rate, 0.0, 1.0)
		_set_skip_progress(_skip_progress)
		if _skip_progress >= 1.0:
			_skip_hold_active = false
			_skip_progress = 0.0
			_hide_skip_prompt()
			skip()
	elif _skip_progress > 0.0:
		_skip_progress = clampf(_skip_progress - rate, 0.0, 1.0)
		_set_skip_progress(_skip_progress)
		if _skip_progress <= 0.0 and _skip_prompt_visible:
			_hide_skip_prompt()


# ── Public API ───────────────────────────────────────────────────────────

## Trigger the cutscene. Bypasses fire_once — for direct invocation from
## code or debug hotkey. The flag-triggered path uses _on_flag_set which
## honors fire_once.
func arm() -> void:
	if _running:
		return
	if timeline == null:
		push_warning("CutscenePlayer.arm: no timeline set")
		return
	_run.call_deferred()


## Cancel the in-flight cutscene. Safe to call from any state. Sets
## cancelled_flag (or done_flag if cancelled_flag is empty) at teardown.
func cancel() -> void:
	if not _running:
		return
	_cancelled = true
	# Surface immediately to the audio service so a long line stops dead.
	CutsceneAudio.cancel_line()


## Skip to the next SkipPointStep, applying any FlagSteps along the way.
## If no SkipPoint remains, jumps to end (treated as cancel).
func skip() -> void:
	if not _running:
		return
	_skip_requested = true
	CutsceneAudio.cancel_line()


func is_running() -> bool:
	return _running


# ── Run loop ─────────────────────────────────────────────────────────────

func _on_flag_set(id: StringName, value: Variant) -> void:
	if id != arm_flag:
		return
	if not bool(value):
		return
	if _fired and fire_once:
		return
	_fired = true
	arm()


func _on_stop_flag_set(id: StringName, value: Variant) -> void:
	if id != stop_flag:
		return
	if bool(value):
		cancel()


func _on_paused_changed(is_paused: bool) -> void:
	if not _running:
		return
	_paused = is_paused
	CutsceneAudio.pause(is_paused)


func _run() -> void:
	_running = true
	_cancelled = false
	_skip_requested = false
	_current_index = 0
	_setup()
	while _current_index < timeline.steps.size():
		if _cancelled:
			break
		if _skip_requested:
			_handle_skip()
			continue
		var step: CutsceneStep = timeline.steps[_current_index]
		step_started.emit(step, _current_index)
		await _run_step(step)
		step_ended.emit(step, _current_index)
		_current_index += 1
	_teardown()
	_running = false
	ended.emit(not _cancelled)


# ── Setup / teardown ─────────────────────────────────────────────────────

func _setup() -> void:
	CutsceneCamera.save_current()
	if timeline.freeze_player:
		_freeze_player(true)
	if timeline.hide_hud:
		_hide_hud(true)
	if timeline.scene_duration > 0.0:
		_kick_camera_drifts()


func _teardown() -> void:
	# Order matters: stop audio first so a tail doesn't ride into the
	# restored gameplay state. Then camera, then player, then HUD, then flag.
	CutsceneAudio.cancel_line()
	CutsceneCamera.restore()
	if timeline.freeze_player:
		_freeze_player(false)
	if timeline.hide_hud:
		_hide_hud(false)
	# Outcome flag. cancelled_flag wins on cancel if set; else done_flag
	# fires for both natural completion and cancel (the doc default).
	var flag: StringName = timeline.done_flag
	if _cancelled and timeline.cancelled_flag != &"":
		flag = timeline.cancelled_flag
	if flag != &"":
		GameState.set_flag(flag, true)


# ── Step dispatch ────────────────────────────────────────────────────────
# Centralized switch — adding a step type means adding one elif branch
# here, in plain sight, with the rest of the dispatch.

## Returns a coroutine handle (implicit Variant) so callers can either
## `await` it directly OR collect handles in a list and await them in
## parallel (see _run_parallel). Not annotated `-> void` for that reason.
func _run_step(step: CutsceneStep):
	if step is LineStep:
		await _run_line(step)
	elif step is CutStep:
		_run_cut(step)
	elif step is PanStep:
		await _run_pan(step)
	elif step is WaitStep:
		await _run_wait(step)
	elif step is MusicStep:
		_run_music(step)
	elif step is StingerStep:
		await _run_stinger(step)
	elif step is FlagStep:
		_run_flag(step)
	elif step is ParallelStep:
		await _run_parallel(step)
	elif step is SubsequenceStep:
		await _run_subsequence(step)
	elif step is SkipPointStep:
		pass   # marker only — no runtime behavior
	else:
		push_warning("CutscenePlayer: unknown step type %s" % step.get_class())


func _run_line(step: LineStep) -> void:
	CutsceneAudio.play_line(step.character, step.text, step.channel, step.bus_override)
	# Park until the line completes naturally OR cancel_line() emits the
	# signal. The signal is single-fire per line, so this resolves once.
	await CutsceneAudio.line_ended
	if step.hold_after > 0.0 and not _cancelled and not _skip_requested:
		await get_tree().create_timer(step.hold_after).timeout


func _run_cut(step: CutStep) -> void:
	var cam := get_node_or_null(step.camera) as Camera3D
	if cam == null:
		push_warning("CutStep: camera path not found: %s" % step.camera)
		return
	CutsceneCamera.cut_to(cam)


func _run_pan(step: PanStep) -> void:
	var cam := get_node_or_null(step.camera) as Camera3D
	var from := get_node_or_null(step.from) as Marker3D
	var to := get_node_or_null(step.to) as Marker3D
	if cam == null or from == null or to == null:
		push_warning("PanStep: missing camera/from/to for %s" % step.label)
		return
	if step.await_finish:
		await CutsceneCamera.pan(cam, from, to, step.duration, step.trans, step.ease)
	else:
		# Fire-and-forget. Player advances past this step; the camera keeps
		# tweening in the background until duration elapses.
		CutsceneCamera.pan(cam, from, to, step.duration, step.trans, step.ease)


func _run_wait(step: WaitStep) -> void:
	if step.seconds > 0.0:
		await get_tree().create_timer(step.seconds).timeout
		return
	if step.until_signal_target != NodePath() and step.until_signal_name != &"":
		var target := get_node_or_null(step.until_signal_target)
		if target != null and target.has_signal(step.until_signal_name):
			await target[step.until_signal_name]
		else:
			push_warning("WaitStep: signal %s on %s not found" % [
				step.until_signal_name, step.until_signal_target])
		return
	if step.until_flag != &"":
		if bool(GameState.get_flag(step.until_flag, false)):
			return
		# Park on Events.flag_set. Loop to handle other flags firing first.
		while true:
			var args = await Events.flag_set
			# Events.flag_set emits (id, value). When awaited, the result is
			# an Array [id, value] in Godot 4.
			if args is Array and args.size() >= 2:
				if StringName(args[0]) == step.until_flag and bool(args[1]):
					return
			# Defensive: if we got something else, also recheck GameState.
			if bool(GameState.get_flag(step.until_flag, false)):
				return


func _run_music(step: MusicStep) -> void:
	CutsceneAudio.play_music(step.stream, step.fade_in)


func _run_stinger(step: StingerStep) -> void:
	if step.await_finish:
		await CutsceneAudio.play_stinger(step.stream, step.bus, true, step.volume_db)
	else:
		CutsceneAudio.play_stinger(step.stream, step.bus, false, step.volume_db)


func _run_flag(step: FlagStep) -> void:
	if step.flag != &"":
		GameState.set_flag(step.flag, step.value)


## Run all sub-steps concurrently. Godot 4 disallows calling a coroutine
## without `await` (parse error), so we can't capture coroutine handles
## directly. Instead, each track is wrapped in a helper that fires a
## "done" user-signal on a shared Node when its sub-step finishes; the
## parent counts completions until all tracks signal done.
##
## v1 honors await_all=true only. await_all=false (race semantics) is
## documented as a future feature in cutscene_engine.md §10.
func _run_parallel(step: ParallelStep) -> void:
	if not step.await_all:
		push_warning("ParallelStep: await_all=false not yet supported, treating as true")
	if step.steps.is_empty():
		return
	var hub := Node.new()
	hub.add_user_signal(&"track_done")
	add_child(hub)
	var pending: int = step.steps.size()
	for sub_step in step.steps:
		_track_in_parallel(sub_step, hub)
	while pending > 0:
		await hub.track_done
		pending -= 1
	hub.queue_free()


# Helper for _run_parallel: runs one sub-step to completion, then emits
# "track_done" on the shared hub. Fire-and-forget from the parent's POV;
# the parent listens to hub.track_done to count completions.
func _track_in_parallel(step: CutsceneStep, hub: Node) -> void:
	await _run_step(step)
	if is_instance_valid(hub):
		hub.emit_signal(&"track_done")


func _run_subsequence(step: SubsequenceStep) -> void:
	if step.timeline == null:
		return
	# Run the embedded timeline's steps in order using the SAME player's
	# state machine. We don't spin up a second CutscenePlayer — the parent's
	# pause/skip/cancel flags propagate naturally because we're still on the
	# parent's coroutine stack.
	#
	# Skip-during-subsequence: when the parent's skip is requested, we bail
	# out here, but FIRST apply any remaining FlagSteps in the subsequence
	# tail so game state matches "as if it played fully" — same invariant
	# the parent's _handle_skip enforces at the top level.
	var i: int = 0
	while i < step.timeline.steps.size():
		if _cancelled:
			return
		if _skip_requested:
			_apply_terminal_effects_recursive(step.timeline.steps.slice(i))
			return
		await _run_step(step.timeline.steps[i])
		i += 1


# ── Skip handler ─────────────────────────────────────────────────────────

func _handle_skip() -> void:
	# Skip = full skip to end. Walk EVERY remaining step; apply any
	# step that mutates persistent state — FlagStep (game flags) AND
	# MusicStep (music swap) — so the post-cutscene world is in the same
	# state as if the cutscene played fully. Recursively descends into
	# ParallelStep / SubsequenceStep so nested terminal effects also
	# fire. Skip transient steps (LineStep, WaitStep, StingerStep,
	# CutStep, PanStep) — camera restores in teardown anyway.
	#
	# Loop exits normally so done_flag fires (NOT cancelled_flag). Skip
	# is "I watched enough, count it complete," not "I'm aborting."
	_skip_requested = false
	_apply_terminal_effects_recursive(timeline.steps.slice(_current_index))
	_current_index = timeline.steps.size()


# Walk a list of steps, applying every step that mutates persistent state:
# FlagStep (game flags) and MusicStep (which track is playing). Recurses
# into ParallelStep.steps and SubsequenceStep.timeline.steps so terminal
# effects nested inside containers also fire on skip.
#
# This is the load-bearing invariant from docs/cutscene_engine.md §7: the
# game world post-skip MUST be indistinguishable from the game world
# post-natural-completion. Flags + music are the persistent channels;
# camera is restored in teardown regardless.
#
# Transient steps (LineStep, WaitStep, StingerStep, CutStep, PanStep) are
# skipped — they're effects, not state.
func _apply_terminal_effects_recursive(steps: Array) -> void:
	for step in steps:
		if step is FlagStep:
			_run_flag(step)
		elif step is MusicStep:
			_run_music(step)
		elif step is ParallelStep:
			_apply_terminal_effects_recursive((step as ParallelStep).steps)
		elif step is SubsequenceStep:
			var sub := step as SubsequenceStep
			if sub.timeline != null:
				_apply_terminal_effects_recursive(sub.timeline.steps)


# ── Player + HUD freeze ──────────────────────────────────────────────────

func _freeze_player(on: bool) -> void:
	if on:
		_saved_player = get_tree().get_first_node_in_group(&"player") as Node3D
		if _saved_player == null:
			return
		_saved_player_physics = _saved_player.is_physics_processing()
		_saved_player.set_physics_process(false)
		# Disable the brain's input handling too so camera + interact don't
		# fight the cutscene. The existing CutsceneSequence flagged this gap;
		# we close it here.
		for child in _saved_player.get_children():
			if "PlayerBrain" in child.name or "Brain" in child.name:
				_saved_brain = child
				_saved_brain_input = child.is_processing_input()
				_saved_brain_unhandled = child.is_processing_unhandled_input()
				child.set_process_input(false)
				child.set_process_unhandled_input(false)
				break
	else:
		if _saved_player != null and is_instance_valid(_saved_player):
			_saved_player.set_physics_process(_saved_player_physics)
		if _saved_brain != null and is_instance_valid(_saved_brain):
			_saved_brain.set_process_input(_saved_brain_input)
			_saved_brain.set_process_unhandled_input(_saved_brain_unhandled)
		_saved_player = null
		_saved_brain = null


# Walk every CutStep in the timeline, resolve its camera, and start any
# CameraDrift child the camera has. Each drift's `duration` is set to the
# timeline's `scene_duration` so trajectories spread over the whole
# cutscene regardless of which shot is currently rendered. Cameras seen
# more than once (the same shot appears in shots 1 and 3) only kick once.
#
# CameraDrift is an existing project node (level/interactable/camera_drift)
# unrelated to the cutscene engine — we just trigger it here, same as the
# legacy CutsceneSequence did via _kick_camera_drifts.
func _kick_camera_drifts() -> void:
	var seen: Dictionary = {}
	for step in timeline.steps:
		var cam_path: NodePath = NodePath()
		if step is CutStep:
			cam_path = (step as CutStep).camera
		elif step is PanStep:
			cam_path = (step as PanStep).camera
		if cam_path == NodePath():
			continue
		var cam := get_node_or_null(cam_path)
		if cam == null or seen.has(cam):
			continue
		seen[cam] = true
		for child in cam.get_children():
			if child is CameraDrift:
				(child as CameraDrift).duration = timeline.scene_duration
				(child as CameraDrift).start_drift()


func _hide_hud(on: bool) -> void:
	if on:
		_hud_root = get_tree().get_first_node_in_group(&"hud")
		if _hud_root != null and "visible" in _hud_root:
			_saved_hud_visible = bool(_hud_root.get(&"visible"))
			print("[cutscene] hide_hud(true): %s.visible %s → false" % [
				_hud_root.get_path(), _saved_hud_visible])
			_hud_root.set(&"visible", false)
		else:
			print("[cutscene] hide_hud(true): no hud node in group")
	else:
		if _hud_root != null and is_instance_valid(_hud_root) \
				and "visible" in _hud_root:
			print("[cutscene] hide_hud(false): %s.visible → %s" % [
				_hud_root.get_path(), _saved_hud_visible])
			_hud_root.set(&"visible", _saved_hud_visible)
		_hud_root = null


# ── Skip prompt UI ───────────────────────────────────────────────────────
# Built on demand the first time it's shown. Layer 75 sits above HUD (0)
# and walkie subtitles (50) but below pause menu (100), so a hold-prompt
# during a cutscene can't be obscured by gameplay UI but pause-menu still
# wins if the player somehow opens it.

func _ensure_skip_prompt() -> void:
	if _skip_prompt != null:
		return
	_skip_prompt = CanvasLayer.new()
	_skip_prompt.layer = 75
	_skip_prompt.process_mode = Node.PROCESS_MODE_ALWAYS  # show even if tree paused
	add_child(_skip_prompt)
	# Bottom-center anchor with vertical lift so it sits above the safe area.
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	root.offset_top = -110.0
	root.offset_bottom = -40.0
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.modulate.a = 0.0
	_skip_prompt.add_child(root)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(box)
	_skip_prompt_label = Label.new()
	_skip_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_skip_prompt_label.add_theme_font_size_override(&"font_size", 18)
	_skip_prompt_label.add_theme_color_override(&"font_color", Color(0.95, 0.95, 0.95, 1))
	_skip_prompt_label.add_theme_constant_override(&"outline_size", 4)
	_skip_prompt_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.85))
	box.add_child(_skip_prompt_label)
	_skip_prompt_bar = ProgressBar.new()
	_skip_prompt_bar.custom_minimum_size = Vector2(220, 6)
	_skip_prompt_bar.show_percentage = false
	_skip_prompt_bar.min_value = 0.0
	_skip_prompt_bar.max_value = 1.0
	_skip_prompt_bar.value = 0.0
	box.add_child(_skip_prompt_bar)
	_skip_prompt.visible = false


func _show_skip_prompt() -> void:
	_ensure_skip_prompt()
	# Glyphs.format gives the device-correct key label ("E", "Triangle", …)
	# so the prompt reads correctly regardless of input device.
	var action_name: String = String(timeline.skip_action)
	var glyph: String = action_name.to_upper()
	var glyphs := get_tree().root.get_node_or_null(^"Glyphs")
	if glyphs != null and glyphs.has_method(&"for_action"):
		glyph = String(glyphs.call(&"for_action", action_name))
	_skip_prompt_label.text = "Hold %s to skip" % glyph
	_skip_prompt_bar.value = 0.0
	_skip_prompt.visible = true
	_skip_prompt_visible = true
	# Fade in. Kill any in-flight fade so a quick re-press doesn't double-tween.
	if _skip_prompt_tween != null and _skip_prompt_tween.is_valid():
		_skip_prompt_tween.kill()
	var root := _skip_prompt.get_child(0) as Control
	if root != null:
		_skip_prompt_tween = create_tween()
		_skip_prompt_tween.tween_property(root, "modulate:a", 1.0, 0.15)


func _hide_skip_prompt() -> void:
	if _skip_prompt == null:
		return
	_skip_prompt_visible = false
	if _skip_prompt_tween != null and _skip_prompt_tween.is_valid():
		_skip_prompt_tween.kill()
	var root := _skip_prompt.get_child(0) as Control
	if root != null:
		_skip_prompt_tween = create_tween()
		_skip_prompt_tween.tween_property(root, "modulate:a", 0.0, 0.2)
		_skip_prompt_tween.tween_callback(func() -> void:
			if _skip_prompt != null:
				_skip_prompt.visible = false)


func _set_skip_progress(progress: float) -> void:
	if _skip_prompt_bar != null:
		_skip_prompt_bar.value = progress
