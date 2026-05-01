extends Node

## Lightweight cutscene overlay system. For now: stills only — shows a
## fullscreen image for a fixed duration, intended to be triggered from
## .dialogue files via `do`. Video support (AnimatedTexture / VideoStream)
## will land later behind the same call shape so dialogue scripts don't
## have to change.
##
## Usage from a .dialogue file (Cutscene must be in dialogue_manager's
## general/states list):
##
##     Nyx: Hey there runner.
##     do Cutscene.show_image("res://cutscenes/nyx_intro.jpg", 2.5)
##     Nyx: Umm.. why are you looking at me like that?
##
## DialogueManager's _mutate awaits the do-action (default Wait behaviour),
## so `await` inside show_image blocks the next line until the overlay
## finishes. World keeps ticking — same design as the dialogue balloon.

# Sit above HUD (which is below ~1000) and the dialogue balloon. Below the
# scene-transition glitch overlay (layer 2000) so transitions still win.
const _LAYER: int = 1800

var _canvas: CanvasLayer = null


## Show a fullscreen still image, then auto-dismiss after `duration`. Awaits
## internally so `do Cutscene.show_image(...)` blocks dialogue progression.
## Returns when the overlay has been removed. No-op if another cutscene is
## already showing — the second call returns immediately (caller should
## sequence; nesting isn't supported yet).
func show_image(path: String, duration: float = 3.0) -> void:
	if _canvas != null:
		push_warning("Cutscene.show_image: cutscene already active, ignoring %s" % path)
		return
	var tex: Texture2D = load(path) as Texture2D
	if tex == null:
		push_warning("Cutscene.show_image: failed to load %s" % path)
		return
	var bg: ColorRect = _spawn_input_gated_canvas()
	bg.color = Color.BLACK

	var img: TextureRect = TextureRect.new()
	img.anchor_right = 1.0
	img.anchor_bottom = 1.0
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img.texture = tex
	_canvas.add_child(img)

	# create_timer(duration, process_always=true) so the overlay stays for
	# the full duration even if something pauses the tree mid-show.
	await get_tree().create_timer(duration, true).timeout
	_cleanup()


## Show a fullscreen video. Pauses music + ambience for the duration so the
## video's own audio reads cleanly, then resumes the soundtrack from where
## it left off. Awaits the video's natural end (default duration=-1) or a
## fixed duration if specified. Format must be Theora/Vorbis (.ogv) — Godot
## 4's only native video stream codec.
##
## `post_delay` (seconds) holds the await before returning so the next
## dialogue beat doesn't step on the moment. The overlay is already gone
## by the time the timer ticks — the silence happens against the live
## scene, balloon hidden via the mutation hide-cooldown.
##
## When `allow_skip` is true, holding `skip_action` for `skip_hold_seconds`
## stops the video and exits early. The same SkipPromptUI used by timeline
## cutscenes is shown — input is read via Input.is_action_pressed polling
## (not _input events) so it bypasses _cutscene_input_block.gd.
func show_video(path: String, duration: float = -1.0, post_delay: float = 0.0,
		allow_skip: bool = true, skip_action: StringName = &"interact",
		skip_hold_seconds: float = 1.5) -> void:
	if _canvas != null:
		push_warning("Cutscene.show_video: cutscene already active, ignoring %s" % path)
		return
	var stream: VideoStream = load(path) as VideoStream
	if stream == null:
		push_warning("Cutscene.show_video: failed to load %s" % path)
		return
	var bg: ColorRect = _spawn_input_gated_canvas()
	bg.color = Color.BLACK

	var player: VideoStreamPlayer = VideoStreamPlayer.new()
	player.anchor_right = 1.0
	player.anchor_bottom = 1.0
	player.expand = true  # stretch to fill while preserving aspect via CONTROL anchors
	# Route video audio through SFX so the sidechain compressors on Music
	# don't duck it, and so it survives Audio.pause_music() (which only
	# touches the Music + Ambience players, not the SFX bus).
	player.bus = &"SFX"
	player.stream = stream
	_canvas.add_child(player)

	# Pause soundtrack in place — preserves the playback position so it
	# resumes seamlessly when the video ends.
	Audio.pause_music()
	player.play()

	# Skip prompt — built lazily, parented under our cutscene canvas so it
	# dies with the overlay if the player skips or the video ends naturally.
	# Layer bumped above _LAYER (the video canvas) so the prompt renders ON
	# TOP of the video. SkipPromptUI._ready sets layer=75 (correct for timeline
	# cutscenes which sit on layer 0); for OGV overlays at layer 1800, 75 is
	# fully occluded by the video. This override has to happen AFTER
	# add_child so it wins against the _ready assignment.
	var skip_ui: SkipPromptUI = null
	if allow_skip:
		skip_ui = SkipPromptUI.new()
		_canvas.add_child(skip_ui)
		skip_ui.layer = _LAYER + 1

	# Polling loop — exits on (natural-end via finished signal) OR (duration
	# elapsed if positive) OR (skip-hold completed). Uses Input.is_action_pressed
	# so it bypasses _cutscene_input_block.gd, which only eats _input events.
	#
	# `done_box` is a one-element Array used as a mutable state-box. GDScript
	# lambdas capture outer locals by reference for objects/arrays/dicts but
	# CANNOT reassign back to a captured primitive — `var done: bool` would
	# stay false forever even after the signal fires. Array indexing mutates
	# in place so the loop sees the update.
	var done_box: Array = [false]
	player.finished.connect(func() -> void: done_box[0] = true, CONNECT_ONE_SHOT)
	var t_start: float = Time.get_ticks_msec() / 1000.0
	var hold_progress: float = 0.0
	var prompt_visible: bool = false
	while not done_box[0]:
		await get_tree().process_frame
		if duration > 0.0:
			var elapsed: float = Time.get_ticks_msec() / 1000.0 - t_start
			if elapsed >= duration:
				break
		if not allow_skip:
			continue
		var dt: float = get_process_delta_time()
		var rate: float = dt / maxf(skip_hold_seconds, 0.1)
		var holding: bool = Input.is_action_pressed(skip_action)
		if holding:
			if not prompt_visible:
				skip_ui.show_for(skip_action)
				prompt_visible = true
			hold_progress = clampf(hold_progress + rate, 0.0, 1.0)
			skip_ui.set_progress(hold_progress)
			if hold_progress >= 1.0:
				player.stop()
				break
		elif hold_progress > 0.0:
			hold_progress = clampf(hold_progress - rate, 0.0, 1.0)
			skip_ui.set_progress(hold_progress)
			if hold_progress <= 0.0 and prompt_visible:
				skip_ui.hide_prompt()
				prompt_visible = false

	Audio.resume_music()
	_cleanup()
	if post_delay > 0.0:
		await get_tree().create_timer(post_delay, true).timeout


func _cleanup() -> void:
	if _canvas != null and is_instance_valid(_canvas):
		_canvas.queue_free()
	_canvas = null


## Build the cutscene's CanvasLayer + a full-rect ColorRect bg that
## blocks ALL input (mouse, keyboard, controller). Mouse blocked via
## MOUSE_FILTER_STOP on the bg; kbd/controller blocked by the layer's
## script which set_input_as_handled()'s every action event; focus
## yanked off any underlying menu Button via grab_focus on the bg.
## Returns the bg (caller adds children + tweaks color/etc.).
func _spawn_input_gated_canvas() -> ColorRect:
	_canvas = CanvasLayer.new()
	_canvas.layer = _LAYER
	_canvas.process_mode = Node.PROCESS_MODE_ALWAYS
	# Eats every action-typed event while the cutscene is up so kbd/controller
	# can't navigate menu Buttons on lower CanvasLayers.
	_canvas.set_script(preload("res://autoload/_cutscene_input_block.gd"))
	add_child(_canvas)

	var bg: ColorRect = ColorRect.new()
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.focus_mode = Control.FOCUS_ALL
	_canvas.add_child(bg)
	bg.grab_focus.call_deferred()
	return bg
