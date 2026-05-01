class_name StealthKillTarget
extends Interactable

## Press-E hack-takedown for splice-stealth enemies. Drops as a child of
## the pawn (a PlayerBody-based enemy). The InteractionSensor offers the
## "[E] hack" prompt only when:
##   1. Player has the powerup_secret flag (the hacker power-up).
##   2. Player is BEHIND the pawn — dot-product check against the pawn's
##      facing, gated by `behind_dot_threshold`.
##   3. Pawn isn't already dying / dead.
##
## On interact, the parent pawn's stealth_kill() runs: glitch overlay
## ramps to 1, skin tilts to lying-on-back, confetti bursts, queue_free.
## No knockback launch — they fall over in place.

## How "behind" the player must be. dot(pawn_forward, pawn→player) ≤ this
## threshold = behind. -1.0 = directly behind only; 0.0 = anywhere in the
## back hemisphere (180° arc); 0.3 = ~70° back arc (forgiving, easy to
## sneak up on). Default 0.0 = back-hemisphere only.
@export_range(-1.0, 1.0) var behind_dot_threshold: float = 0.0

## Max distance (m) for the highlight + prompt to show. Without this gate
## a back-hemisphere check alone lit up sentinels from across the level.
## ~4m is a comfortable backstab range — close enough that the player has
## to actually be sneaking up, not eyeballing from afar.
@export var max_highlight_distance: float = 4.0

## Required GameState flag for the prompt to even show. Empty = always
## show. Defaults to "powerup_secret" so only hackers see the [E] hack
## prompt on splice-stealth pawns.
@export var required_powerup: StringName = &"powerup_secret"

## Seconds the player must hold the interact action to execute the kill.
## A press alone does nothing — the bar fills while held + eligible and
## drains while not. At full bar, stealth_kill fires. Mirrors the cutscene
## skip-prompt's hold-to-confirm pattern.
@export_range(0.1, 10.0, 0.1) var hold_duration: float = 2.0
## Seconds to fully drain the bar from full when the player releases. <
## hold_duration so a near-complete press isn't punished too hard for a
## brief release. Default = same as fill so symmetric pulse.
@export_range(0.05, 10.0, 0.05) var release_drain_duration: float = 2.0
## Seconds the cone takes to flicker out after a successful hack. Passed
## to EnemyAIBrain.kill_fade_cone on the pawn's brain.
@export_range(0.1, 10.0, 0.1) var cone_fade_duration: float = 2.0


## Cached MeshInstance3D list, walked from the parent pawn at first
## set_highlighted() call. Drop the kill target inside any pawn skin
## tree and the whole pawn glows on focus.
var _resolved_highlight_meshes: Array[MeshInstance3D] = []
var _highlight_resolved: bool = false
# Tracks whether the InteractionSensor currently has us focused. When
# true, _physics_process re-evaluates the eligibility checks (behind +
# crouched + powerup) every tick so the overlay flips on/off as the
# player orbits the pawn — focus alone isn't enough to paint.
var _focus_active: bool = false
# Last-applied overlay state. Lets the per-tick refresh skip the mesh
# walk when nothing changed.
var _painted: bool = false
# Hold-to-hack progress 0..1. Builds while interact is held + eligible,
# drains otherwise. Hits 1.0 → fire stealth_kill, reset to 0.
var _hold_progress: float = 0.0
# Latched true once we've fired the kill so the per-tick logic can't
# re-trigger inside the same death window.
var _kill_fired: bool = false
# Hold-edge state — drives audio start/stop and the brain's hack-active
# toggle on transitions only.
var _was_holding: bool = false
# True once the random hacking sting has fired in this hold cycle. Reset
# on release. Prevents the sting from re-triggering every tick past 0.5.
var _sting_played: bool = false

# Audio assets:
# • _HACK_STING_POOL — one-shot stings, picked randomly per hold, played
#   once at midway (`_STING_TRIGGER_AT`) and cut if the player releases.
# • _DRAG_LOOP_STREAM — same buzz the maze puzzle plays while the cursor
#   is dragging. Loops the entire hold, cuts on release.
# • _POWER_OFF_STREAM — one-shot kill sting at -14dB (~20% loudness).
const _HACK_STING_POOL: Array[AudioStream] = [
	preload("res://audio/sfx/hacking/hacking_1.mp3"),
	preload("res://audio/sfx/hacking/hacking_2.mp3"),
	preload("res://audio/sfx/hacking/hacking_3.mp3"),
	preload("res://audio/sfx/hacking/hacking_4.mp3"),
	preload("res://audio/sfx/hacking/hacking_5.mp3"),
	preload("res://audio/sfx/hacking/hacking_6.mp3"),
	preload("res://audio/sfx/hacking/hacking_7.mp3"),
]
const _DRAG_LOOP_STREAM: AudioStream = preload("res://audio/sfx/maze_buzz.mp3")
const _POWER_OFF_STREAM: AudioStream = preload("res://audio/sfx/power_off.mp3")
const _POWER_OFF_VOLUME_DB: float = -14.0
## Progress threshold at which the random hacking sting fires. Defaults to
## the midpoint — sells "the hack is locking in" right before the bar
## completes. < 0 disables the sting.
const _STING_TRIGGER_AT: float = 0.5

var _drag_loop_player: AudioStreamPlayer3D = null
var _sting_player: AudioStreamPlayer3D = null

# Billboard widget — Sprite3D + SubViewport with the donut + hint label,
# floating above the pawn. Built lazily on first show so dormant targets
# cost nothing. Visible while the player is eligible (same gate as the
# cyan highlight); donut value tracks _hold_progress.
const _BILLBOARD_HEIGHT: float = 2.6
var _billboard: Sprite3D = null
var _billboard_viewport: SubViewport = null
var _billboard_label: Label = null
var _billboard_donut: CircularProgress = null


func _ready() -> void:
	super._ready()
	if prompt_verb == "interact":
		prompt_verb = "hack"


## InteractionSensor calls this with on=true when this target becomes the
## focused interactable. With layer-gated visibility (see _physics_process)
## focus only happens when we're eligible, so this is essentially a
## redundant secondary signal — but we honor it for safety so an unfocused
## state always clears the overlay.
func set_highlighted(on: bool) -> void:
	_focus_active = on
	if not on:
		_apply_highlight(false)


# Drive BOTH the sensor's view of us (collision_layer) AND the highlight
# overlay from a single eligibility predicate. Sensor scans by collision
# layer (`interaction_sensor.gd:98`), so layer=0 → sensor blind → no focus
# → PromptUI stays empty (`prompt_ui.gd:125`). Same pattern as
# `puzzle_terminal.gd:106` for visibility-gated terminals. The label, the
# (locked) suffix, and the cyan overlay are all bound to one signal:
# `_eligible_for_highlight(actor)`.
const _SENSOR_VISIBLE_LAYER: int = 512
func _physics_process(delta: float) -> void:
	var actor: Node3D = _player_actor()
	var eligible: bool = actor != null and _eligible_for_highlight(actor)
	var desired_layer: int = _SENSOR_VISIBLE_LAYER if eligible else 0
	if collision_layer != desired_layer:
		collision_layer = desired_layer
	if eligible != _painted:
		_apply_highlight(eligible)
	# Hold-to-hack progress. Build while held + eligible, drain otherwise.
	# Once fired, gate further ticks so a still-held key doesn't re-trigger.
	if _kill_fired:
		return
	var holding: bool = eligible and Input.is_action_pressed(&"interact")
	# Hold-edge audio + sting reset. Drag loop runs the entire hold; sting
	# is one-shot at midway and won't re-fire inside the same hold.
	if holding and not _was_holding:
		_start_drag_loop()
		_sting_played = false
	elif not holding and _was_holding:
		_stop_drag_loop()
		_stop_sting()
		_sting_played = false
	_was_holding = holding
	if holding:
		_hold_progress = minf(_hold_progress + delta / max(hold_duration, 0.001), 1.0)
		# Midway sting — fire ONCE per hold when the bar crosses the
		# threshold. Random pick so back-to-back hacks don't sound identical.
		if not _sting_played and _STING_TRIGGER_AT >= 0.0 \
				and _hold_progress >= _STING_TRIGGER_AT:
			_play_random_sting()
			_sting_played = true
	else:
		_hold_progress = maxf(_hold_progress - delta / max(release_drain_duration, 0.001), 0.0)
	_update_billboard(eligible)
	# Brain cone state: active while THIS frame is a held one. Releasing
	# drops _hack_active=false the same tick, so the cone snaps back to
	# normal alpha logic instead of waiting for the bar drain.
	_push_hack_state_to_brain(holding, _hold_progress)
	if _hold_progress >= 1.0:
		_kill_fired = true
		_hold_progress = 0.0
		_was_holding = false
		_stop_drag_loop()
		_stop_sting()
		_update_billboard(false)
		_trigger_kill(actor)


# First member of the "player" group. Used by the per-tick highlight
# refresh — sensor doesn't pass the actor through to set_highlighted().
func _player_actor() -> Node3D:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group(&"player") as Node3D


# Side-effect-free mirror of can_interact's gate set. Called every physics
# frame while focused, so no debug prints — keep it tight.
func _eligible_for_highlight(actor: Node3D) -> bool:
	if required_powerup != &"" and not GameState.get_flag(required_powerup, false):
		return false
	if "_was_crouched" in actor and not bool(actor.get(&"_was_crouched")):
		return false
	var pawn: Node3D = get_parent() as Node3D
	if pawn == null or not is_instance_valid(pawn):
		return false
	if "is_dying" in pawn and bool(pawn.call(&"is_dying")):
		return false
	# Distance gate. Without this, behind+crouched lit up sentinels across
	# the entire level. max_highlight_distance defaults to 4m — comfortable
	# backstab range, requires the player to actually be sneaking close.
	var dist_sq: float = actor.global_position.distance_squared_to(pawn.global_position)
	if dist_sq > max_highlight_distance * max_highlight_distance:
		return false
	var pawn_forward: Vector3 = _pawn_forward(pawn)
	if pawn_forward.length_squared() < 0.0001:
		return true
	var to_actor: Vector3 = actor.global_position - pawn.global_position
	to_actor.y = 0.0
	if to_actor.length_squared() < 0.0001:
		return true
	to_actor = to_actor.normalized()
	return pawn_forward.dot(to_actor) <= behind_dot_threshold


# Cached brain reference — found by walking the parent pawn's children
# for one with `set_hack_active`. Set lazily on first push.
var _brain_cached: Node = null
func _push_hack_state_to_brain(active: bool, progress: float) -> void:
	if _brain_cached == null or not is_instance_valid(_brain_cached):
		var pawn: Node = get_parent()
		if pawn == null:
			return
		for child: Node in pawn.get_children():
			if child.has_method(&"set_hack_active"):
				_brain_cached = child
				break
		if _brain_cached == null:
			return
	_brain_cached.call(&"set_hack_active", active, progress)


# ── Billboard ──────────────────────────────────────────────────────────
# Sprite3D anchored above the pawn that renders a SubViewport containing
# a "Hold {glyph} to hack" label + the cyan donut. Visible while the
# player is eligible (same gate as the cyan body highlight). Built lazily
# so a level full of stealth pawns doesn't pay for viewports until at
# least one becomes eligible.
const _BILLBOARD_VIEWPORT_SIZE: Vector2i = Vector2i(600, 500)
const _BILLBOARD_PIXEL_SIZE: float = 0.0035

func _build_billboard() -> void:
	if _billboard != null and is_instance_valid(_billboard):
		return
	var pawn: Node3D = get_parent() as Node3D
	if pawn == null or not is_instance_valid(pawn):
		return
	_billboard_viewport = SubViewport.new()
	_billboard_viewport.size = _BILLBOARD_VIEWPORT_SIZE
	_billboard_viewport.transparent_bg = true
	_billboard_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_billboard_viewport.disable_3d = true
	add_child(_billboard_viewport)

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override(&"separation", 12)
	_billboard_viewport.add_child(box)

	# Label: 2× the prior 28pt baseline (=56) and then HUD-scaled so the
	# accessibility scale slider applies. Donut: 1.5× radius/thickness.
	var hud_scale: float = Settings.get_hud_scale()
	_billboard_label = Label.new()
	_billboard_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_billboard_label.add_theme_font_size_override(&"font_size", int(56 * hud_scale))
	_billboard_label.add_theme_color_override(&"font_color", Color.WHITE)
	_billboard_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.95))
	_billboard_label.add_theme_constant_override(&"outline_size", 6)
	_billboard_label.text = "Hold E to hack"
	_billboard_label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(_billboard_label)

	_billboard_donut = CircularProgress.new()
	_billboard_donut.radius = 75.0 * hud_scale
	_billboard_donut.thickness = 18.0 * hud_scale
	_billboard_donut.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(_billboard_donut)

	_billboard = Sprite3D.new()
	_billboard.texture = _billboard_viewport.get_texture()
	_billboard.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	_billboard.no_depth_test = true
	_billboard.pixel_size = _BILLBOARD_PIXEL_SIZE
	_billboard.position = Vector3(0, _BILLBOARD_HEIGHT, 0)
	pawn.add_child(_billboard)
	_billboard.visible = false


# Toggle visibility + push current donut value + glyph. Called every tick.
func _update_billboard(eligible: bool) -> void:
	if not eligible and _billboard == null:
		return
	_build_billboard()
	if _billboard == null or not is_instance_valid(_billboard):
		return
	_billboard.visible = eligible
	if not eligible:
		return
	_billboard_donut.value = _hold_progress
	var glyph: String = Glyphs.for_action("interact")
	var new_text: String = "Hold %s to hack" % glyph
	if _billboard_label.text != new_text:
		_billboard_label.text = new_text


# ── Audio ──────────────────────────────────────────────────────────────
# Two layers:
#   • _drag_loop_player — looped maze_buzz the entire hold, cut on release.
#   • _sting_player     — one-shot random hacking sting at midway, cut on
#                         release if it overruns.

func _ensure_drag_loop_player() -> void:
	if _drag_loop_player != null and is_instance_valid(_drag_loop_player):
		return
	# Duplicate so we can flip loop on without mutating the shared
	# resource — same pattern crumble_platform uses for its shake loop.
	var stream: AudioStream = _DRAG_LOOP_STREAM.duplicate()
	if "loop" in stream:
		stream.loop = true
	_drag_loop_player = AudioStreamPlayer3D.new()
	_drag_loop_player.stream = stream
	_drag_loop_player.bus = &"SFX"
	_drag_loop_player.unit_size = 6.0
	_drag_loop_player.max_distance = 35.0
	add_child(_drag_loop_player)


func _ensure_sting_player() -> void:
	if _sting_player != null and is_instance_valid(_sting_player):
		return
	_sting_player = AudioStreamPlayer3D.new()
	_sting_player.bus = &"SFX"
	_sting_player.unit_size = 6.0
	_sting_player.max_distance = 35.0
	add_child(_sting_player)


func _start_drag_loop() -> void:
	_ensure_drag_loop_player()
	if _drag_loop_player != null:
		_drag_loop_player.play()


func _stop_drag_loop() -> void:
	if _drag_loop_player != null and is_instance_valid(_drag_loop_player) \
			and _drag_loop_player.playing:
		_drag_loop_player.stop()


func _play_random_sting() -> void:
	if _HACK_STING_POOL.is_empty():
		return
	_ensure_sting_player()
	_sting_player.stream = _HACK_STING_POOL[randi() % _HACK_STING_POOL.size()]
	_sting_player.play()


func _stop_sting() -> void:
	if _sting_player != null and is_instance_valid(_sting_player) \
			and _sting_player.playing:
		_sting_player.stop()


# Hold-bar filled — fire the kill. The cone is already at hack_progress=1.0
# (driven each tick from _physics_process), so the brain's cone alpha is
# already 0 by the time we get here. Power-off sfx replaces the old
# stealth_hack_success cue — cleaner sting, plays at -14dB (~20% loudness).
func _trigger_kill(actor: Node3D) -> void:
	var pawn: Node3D = get_parent() as Node3D
	if pawn == null or not pawn.has_method(&"stealth_kill"):
		return
	# Power-off sting on the SFX bus, parented to the layer so it survives
	# the pawn's queue_free. Self-frees on finish.
	var po := AudioStreamPlayer3D.new()
	po.stream = _POWER_OFF_STREAM
	po.bus = &"SFX"
	po.volume_db = _POWER_OFF_VOLUME_DB
	po.unit_size = 6.0
	po.max_distance = 35.0
	po.global_position = pawn.global_position
	# Re-parent to the level scene so the player free-ing of the pawn doesn't
	# cut the sting mid-play.
	var host: Node = get_tree().current_scene if get_tree() != null else null
	if host == null:
		host = get_tree().root
	host.add_child(po)
	po.play()
	po.finished.connect(po.queue_free)
	var from_dir: Vector3 = (pawn.global_position - actor.global_position) if actor != null else Vector3.BACK
	pawn.call(&"stealth_kill", from_dir)


# Paint or clear the overlay on every cached MeshInstance3D in the pawn.
func _apply_highlight(on: bool) -> void:
	_painted = on
	var meshes: Array[MeshInstance3D] = _resolve_highlight_meshes()
	if meshes.is_empty():
		return
	var overlay: Material = _highlight_overlay_material()
	for m: MeshInstance3D in meshes:
		m.material_overlay = overlay if on else null


# First-call walk of the parent pawn's subtree — collects every
# MeshInstance3D descendant. Cached so repeated focus toggles don't re-walk.
func _resolve_highlight_meshes() -> Array[MeshInstance3D]:
	if _highlight_resolved:
		return _resolved_highlight_meshes
	_highlight_resolved = true
	var pawn: Node = get_parent()
	if pawn == null:
		return _resolved_highlight_meshes
	_collect_mesh_instances(pawn, _resolved_highlight_meshes)
	return _resolved_highlight_meshes


func _collect_mesh_instances(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child: Node in node.get_children():
		_collect_mesh_instances(child, out)


# Blue-green emissive overlay. Same shape as PuzzleTerminal's default
# highlight but tuned cyan-leaning so the player can tell hacked-pawn
# (target) from hacked-terminal at a glance if the two ever coexist.
static var _highlight_material_cached: Material = null
static func _highlight_overlay_material() -> Material:
	if _highlight_material_cached == null:
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.1, 0.9, 0.7, 0.35)
		mat.emission_enabled = true
		mat.emission = Color(0.2, 1.0, 0.7)
		mat.emission_energy_multiplier = 1.5
		_highlight_material_cached = mat
	return _highlight_material_cached


# Powerup gate + behind-the-back gate. The base Interactable.can_interact
# already covers requires_key / requires_flag — we layer the powerup +
# behind checks on top so the prompt visibility tracks position in real
# time (sensor scoring re-evaluates each tick).
func can_interact(actor: Node3D) -> bool:
	var super_pass: bool = super.can_interact(actor)
	if not super_pass:
		print("[skt-dbg] FAIL super.can_interact (requires_key=%s requires_flag=%s) actor=%s" % [
			requires_key, requires_flag, actor])
		return false
	# Global gates: powerup + alive + crouch. is_locked() calls this with
	# actor=null; we treat the null-actor case as "unlocked" so the
	# (locked) suffix never shows on stealth pawns — these only exist in
	# levels where the player has the ability. The crouch gate fires
	# only when there's a real actor (E-press attempt): standing players
	# can see the prompt but can't activate it.
	if required_powerup != &"":
		var has_powerup: bool = bool(GameState.get_flag(required_powerup, false))
		if not has_powerup:
			print("[skt-dbg] FAIL powerup '%s' not set actor=%s" % [required_powerup, actor])
			return false
	if actor != null and "_was_crouched" in actor:
		var crouched: bool = bool(actor.get(&"_was_crouched"))
		if not crouched:
			print("[skt-dbg] FAIL not crouched actor=%s" % actor)
			return false
	var pawn: Node3D = get_parent() as Node3D
	if pawn == null or not is_instance_valid(pawn):
		print("[skt-dbg] FAIL pawn invalid (parent=%s) actor=%s" % [pawn, actor])
		return false
	if "is_dying" in pawn and bool(pawn.call(&"is_dying")):
		print("[skt-dbg] FAIL pawn is_dying actor=%s" % [actor])
		return false
	# Dynamic behind check — skipped when actor is null (is_locked path).
	if actor == null:
		print("[skt-dbg] PASS (null actor / lock-check) — unlocked")
		return true
	# Distance gate — kept in lockstep with _eligible_for_highlight so the
	# prompt and the hold bar (driven by eligibility) appear together.
	var dist_sq: float = actor.global_position.distance_squared_to(pawn.global_position)
	if dist_sq > max_highlight_distance * max_highlight_distance:
		print("[skt-dbg] FAIL distance %.2f > %.2f actor=%s" % [
			sqrt(dist_sq), max_highlight_distance, actor])
		return false
	var pawn_forward: Vector3 = _pawn_forward(pawn)
	if pawn_forward.length_squared() < 0.0001:
		print("[skt-dbg] PASS (no facing) actor=%s" % actor)
		return true
	var to_actor: Vector3 = actor.global_position - pawn.global_position
	to_actor.y = 0.0
	if to_actor.length_squared() < 0.0001:
		return true
	to_actor = to_actor.normalized()
	var dot: float = pawn_forward.dot(to_actor)
	var behind: bool = dot <= behind_dot_threshold
	print("[skt-dbg] %s behind-check dot=%.2f thresh=%.2f → %s" % [
		"PASS" if behind else "FAIL", dot, behind_dot_threshold,
		"behind" if behind else "in front"])
	return behind


func describe_lock() -> String:
	if required_powerup != &"" and not GameState.get_flag(required_powerup, false):
		return "needs " + str(required_powerup).capitalize()
	return super.describe_lock()


func interact(_actor: Node3D) -> void:
	# Hold-to-hack. The actual kill is driven by _physics_process watching
	# `interact` held + eligible — see _trigger_kill above. The press itself
	# is consumed silently; only a full 2s hold fires the kill.
	pass


# Best-effort "what direction is the pawn facing" lookup. PlayerBody stores
# yaw in _yaw_state and applies it to its skin each tick. Convention:
# yaw=0 → forward = Vector3.BACK (matching the body's face_target math
# at line ~1711 of player_body.gd), so forward = BACK rotated by yaw.
static func _pawn_forward(pawn: Node3D) -> Vector3:
	if "_yaw_state" in pawn:
		var yaw: float = float(pawn.get(&"_yaw_state"))
		return Vector3.BACK.rotated(Vector3.UP, yaw)
	return -pawn.global_basis.z
