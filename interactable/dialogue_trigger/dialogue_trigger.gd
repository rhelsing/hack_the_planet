class_name DialogueTrigger
extends Interactable

## Press-E NPC / interactable that opens a dialogue conversation.
## See docs/interactables.md §10.3 and docs/scroll_dialogue.md §5.
##
## Cinematic entry (P5) — on interact, before the balloon opens:
##   1. Player tweens to `approach_spot` (a Marker3D child of this node)
##   2. Player rotates to face `look_at_target` (defaults to this node)
##   3. A cinematic Camera3D tweens to `camera_target` transform
##   4. Dialogue.start fires after the tweens settle
##   5. On Events.dialogue_ended, original camera is restored and the
##      cinematic camera is freed
##
## Every step is opt-in — leave the NodePath exports empty (default) to get
## the old behavior (instant dialogue, no walk, no camera move).

## Authored in the Godot editor via Nathan Hoad's Dialogue Manager plugin.
## Typed as Resource (not DialogueResource) so the class_name from the plugin
## isn't required at parse time of this file.
@export var dialogue_resource: Resource

## Start node name inside the .dialogue file (matches `~ start` convention).
@export var dialogue_start: String = "start"

@export_group("Redirect")
## Optional. If set, and `redirect_unless_flag` is currently false, pressing
## interact on this trigger forwards to `redirect_target.interact(actor)`
## instead of opening this trigger's own dialogue. Used for "talk to NPC A
## first" gates: e.g. talking to Nyx pre-DialTone routes to DialTone.
@export var redirect_target: NodePath
## GameState flag that, when true, disables the redirect (this trigger plays
## its own dialogue normally). Empty = no redirect.
@export var redirect_unless_flag: String = ""

@export_group("Cinematic Entry")
## Marker3D child node where the player walks to before dialogue starts.
## Leave empty = no walk.
@export var approach_spot: NodePath

## Node the player rotates to face. Defaults to `this` (the NPC itself).
## Only Y-axis rotation; X/Z preserved.
@export var look_at_target: NodePath

## Marker3D child node where the cinematic camera positions itself.
## ONLY the position is honored — the marker's rotation is ignored. The
## camera's look direction is auto-computed to frame the midpoint between
## player approach-spot and NPC, lifted `focus_height` units above the
## midpoint's ground plane. Drop the marker anywhere that feels cinematic;
## the framing stays consistent without manual rotation tuning.
@export var camera_target: NodePath

## Height above the player↔NPC midpoint where the camera aims. 1.0 = roughly
## chest/shoulder of standing characters. Raise for more headroom in frame,
## lower for a grounded feel.
@export var focus_height: float = 1.0

## Player skin's authored-forward offset vs Godot's -Z convention, in degrees.
## KayKit / Kenney / most humanoid rigs = 0 (default). Godot-native -Z
## skin = 180. Sideways-authored = 90/270. Tune per-scene if a specific
## NPC's setup calls for it.
@export var skin_forward_offset_deg: float = 0.0

@export_group("Cinematic Timing")
## Seconds for the approach walk + camera tween. Player covers distance at
## approach_speed_mps (see below) — duration auto-scales for long approaches.
@export var approach_duration: float = 0.8

## Seconds for the camera to tween from current framing to camera_target.
@export var camera_duration: float = 0.7

## Speed cap (meters per second) for the approach. If the distance divided
## by approach_duration exceeds this, duration is extended so walk speed
## stays natural. 4.0 ≈ brisk walk, 7.0 ≈ jog.
@export var approach_speed_mps: float = 4.0

## Walk-anim threshold (meters). If the player is already closer than this
## to the approach_spot, skip the walk/run animation and stay in idle —
## avoids a jarring one-step run cycle for tiny adjustments.
@export var walk_anim_threshold_m: float = 1.0

## Seconds for the skin-rotation tween once the player arrives.
@export var face_duration: float = 0.3

@export_group("Cinematic Post-Arrival")
## If true, the skin's leans/tilts/particles get zeroed when cinematic starts
## (prevents skate-lean from freezing in during the tween). Off only if a
## specific NPC needs those visual effects preserved for artistic reasons.
@export var reset_skin_pose: bool = true


# Cinematic-teardown bookkeeping. Set on enter, read on dialogue_ended.
var _cinematic_active: bool = false
var _saved_camera: Camera3D = null
var _cinematic_cam: Camera3D = null
var _saved_player_physics: bool = true
var _saved_dust_emitting: bool = false
# Transparent input-blocking overlay placed on its own CanvasLayer below the
# dialogue balloon (~1500) and above HUD (~1) for the duration of the cinematic.
# Without it kbd/controller can navigate to and click on HUD/menu Controls
# while the camera is in NPC-cam mode.
var _input_blocker_layer: CanvasLayer = null
## Held during cinematic so _exit_tree can thaw the player even if we're
## detached before the normal `dialogue_ended` path reaches _exit_cinematic.
var _saved_actor: Node3D = null
# Skin rotation before cinematic. We tween the SKIN visually (not the body)
# because PlayerBody._physics_process sets _skin.transform every tick based
# on _yaw_state — tweening the body does nothing visible. We freeze body's
# physics during cinematic, tween skin directly, then restore skin rotation
# on exit so when physics resumes nothing pops.
const _SAVED_YAW_UNSET: float = INF
var _saved_skin_rotation_y: float = _SAVED_YAW_UNSET


func _ready() -> void:
	super._ready()
	if prompt_verb == "interact":
		prompt_verb = "talk"


## Safety net. If this trigger is removed from the tree while a cinematic is
## active (common case: dialogue's `do LevelProgression.advance()` swaps the
## scene), the queued `dialogue_ended` handler can't tween from a detached
## node. Restore everything synchronously — camera, player physics, dust —
## so the player doesn't end up in the hub frozen with an orphaned camera.
func _exit_tree() -> void:
	if not _cinematic_active:
		return
	# Camera — snap back, no tween (we're detached, tween wouldn't progress).
	if _cinematic_cam != null and is_instance_valid(_cinematic_cam):
		_cinematic_cam.queue_free()
	_cinematic_cam = null
	if _saved_camera != null and is_instance_valid(_saved_camera):
		_saved_camera.make_current()
		print("[cam-dbg] _exit_tree restored: %s" % _saved_camera.get_path())
	else:
		print("[cam-dbg] _exit_tree NO restore: saved=%s valid=%s" % [
			_saved_camera, is_instance_valid(_saved_camera) if _saved_camera != null else false])
	_saved_camera = null
	# Input blocker lives on /root (NOT a child of this node), so it
	# survives scene swaps unless we explicitly free it here. Without this,
	# a Nyx-style "do LevelProgression.advance()" mid-cinematic leaks the
	# blocker into the next scene, and its mouse_filter=STOP / action-eat
	# script silently swallows mouse-motion + button input → camera locks.
	_free_input_blocker()
	# Player — thaw physics + restore dust. Actor survives scene swaps (it
	# lives in game.tscn, not the level scene) so these calls are safe.
	if _saved_actor != null and is_instance_valid(_saved_actor):
		var dust: GPUParticles3D = _saved_actor.get_node_or_null(^"%DustParticles") as GPUParticles3D
		if dust != null:
			dust.emitting = _saved_dust_emitting
		_saved_actor.set_physics_process(_saved_player_physics)
	_saved_actor = null
	_cinematic_active = false


func interact(actor: Node3D) -> void:
	# Redirect gate: if configured and the unlock flag isn't set yet, forward
	# this interaction to another trigger entirely. Cinematic + dialogue all
	# fire from the redirect target, so the player walks to *that* NPC.
	if not redirect_unless_flag.is_empty() and not GameState.get_flag(redirect_unless_flag, false):
		var target := get_node_or_null(redirect_target) as DialogueTrigger
		if target != null:
			target.interact(actor)
			return
		push_warning("DialogueTrigger %s redirect_target invalid: %s" % [interactable_id, redirect_target])
	if dialogue_resource == null:
		push_warning("DialogueTrigger %s has no dialogue_resource" % interactable_id)
		return
	# Run the cinematic if any cinematic target is configured. If none of the
	# three exports is set, behaves identically to the pre-P5 instant path.
	var has_cinematic: bool = (
		not approach_spot.is_empty()
		or not look_at_target.is_empty()
		or not camera_target.is_empty()
	)
	if has_cinematic:
		await _enter_cinematic(actor)
	Dialogue.start(dialogue_resource, dialogue_start, interactable_id)
	if has_cinematic:
		# One-shot listener restores camera + player physics when dialogue closes.
		Events.dialogue_ended.connect(_exit_cinematic.bind(actor), CONNECT_ONE_SHOT)


# ---- Cinematic internals ------------------------------------------------

## Tween player to approach spot + face target, tween camera to framing.
## Awaits all tweens before returning.
##
## Sequencing:
##   Phase 1 (parallel): walk (body position) + camera framing tween
##   Phase 2 (after walk): rotate the SKIN to face look_at_target
##
## Rotation is applied to the skin node, not the body, because PlayerBody's
## _physics_process sets _skin.transform every tick based on _yaw_state —
## tweening body.rotation.y has no visible effect. Body physics is frozen
## during the cinematic so the skin tween isn't overwritten. On exit the
## skin rotation is restored and physics re-enabled; nothing pops because
## body's _yaw_state was unchanged.
func _enter_cinematic(actor: Node3D) -> void:
	if _cinematic_active: return
	_cinematic_active = true
	_saved_actor = actor
	_spawn_input_blocker()

	var approach_node := get_node_or_null(approach_spot) as Node3D
	var look_at_node := get_node_or_null(look_at_target) as Node3D
	if look_at_node == null: look_at_node = self as Node3D
	var camera_node := get_node_or_null(camera_target) as Node3D
	var skin: Node3D = _find_skin(actor)
	print("[cinematic] enter: actor=%s skin=%s approach=%s lookat=%s cam=%s" % [
		actor, skin, approach_node, look_at_node, camera_node,
	])

	# Save original camera so we can restore it on exit.
	_saved_camera = actor.get_viewport().get_camera_3d()
	print("[cam-dbg] cinematic enter: saved=%s on %s" % [
		_saved_camera.get_path() if _saved_camera != null else "<none>", interactable_id])
	if skin != null:
		_saved_skin_rotation_y = skin.rotation.y

	# Put the player into a clean idle pose — single method, encapsulated.
	_freeze_player_for_cinematic(actor, skin)

	# ---- Phase 1: walk + camera (in parallel) ----
	# Walk duration auto-extends for long distances so the character doesn't
	# look like they're teleporting. Minimum = approach_duration export.
	var distance: float = 0.0
	if approach_node != null:
		distance = actor.global_position.distance_to(approach_node.global_position)
	var walk_time: float = approach_duration
	if approach_speed_mps > 0.0 and distance > 0.0:
		var speed_limited: float = distance / approach_speed_mps
		walk_time = maxf(walk_time, speed_limited)

	# Only play walk/run anim if the approach is long enough to warrant it.
	# Small nudges stay in idle — avoids the hitchy one-step run cycle.
	var should_play_walk_anim: bool = distance >= walk_anim_threshold_m
	if should_play_walk_anim and skin != null and skin.has_method(&"move"):
		skin.call(&"move")

	var walk_tween := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	if approach_node != null:
		walk_tween.tween_property(actor, "global_position",
			approach_node.global_position, walk_time)

	if camera_node != null and _saved_camera != null:
		_cinematic_cam = Camera3D.new()
		_cinematic_cam.fov = _saved_camera.fov
		_cinematic_cam.global_transform = _saved_camera.global_transform
		get_tree().root.add_child(_cinematic_cam)
		_cinematic_cam.make_current()
		# Auto-frame: camera position from marker (rotation ignored), basis
		# computed from looking_at(midpoint + focus_height up). Consistent
		# framing regardless of how the designer rotated the marker.
		var player_final_pos: Vector3 = (
			approach_node.global_position if approach_node != null else actor.global_position
		)
		var focus_point: Vector3 = player_final_pos.lerp(look_at_node.global_position, 0.5)
		focus_point.y += focus_height
		var framed_transform: Transform3D = Transform3D(
			Basis.IDENTITY, camera_node.global_position
		).looking_at(focus_point, Vector3.UP)
		walk_tween.tween_property(_cinematic_cam, "global_transform",
			framed_transform, camera_duration)

	await walk_tween.finished

	# Arrived — flip back to idle before rotating to face NPC. Safe to call
	# even if we skipped the move() above (idle → idle is a no-op anim-wise).
	if skin != null and skin.has_method(&"idle"):
		skin.call(&"idle")

	# ---- Phase 2: rotate SKIN to face NPC (short-path) ----
	if skin == null:
		print("[cinematic] NO SKIN found on actor — skipping rotate")
		return
	var dir_xz := (look_at_node.global_position - actor.global_position)
	dir_xz.y = 0.0
	if dir_xz.length_squared() <= 0.0001:
		print("[cinematic] degenerate look-at direction — skipping rotate")
		return
	# Skin's authored forward is +Z (KayKit/Sophia convention, not Godot-
	# native -Z). target yaw s.t. skin.basis.z points at NPC = atan2(dx, dz).
	# `skin_forward_offset_deg` is the export so a Godot-native skin (-Z)
	# can set it to 180 without a code change. Default 0 matches our skins.
	var raw_target_yaw: float = atan2(dir_xz.x, dir_xz.z) + deg_to_rad(skin_forward_offset_deg)
	var current_world_yaw: float = skin.global_rotation.y
	var shortest_delta: float = wrapf(raw_target_yaw - current_world_yaw, -PI, PI)
	var short_target_world: float = current_world_yaw + shortest_delta
	var body_world_yaw: float = actor.global_rotation.y
	var short_target_local: float = short_target_world - body_world_yaw
	print("[cinematic] skin rotate: current_local=%.3f target_local=%.3f (dir=%s)" % [
		skin.rotation.y, short_target_local, dir_xz,
	])
	var rot_tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	rot_tween.tween_property(skin, "rotation:y", short_target_local, face_duration)
	await rot_tween.finished


## Walks the actor's children for a CharacterSkin descendant. PlayerBody
## exposes `_skin` as a gdscript member so we duck-access it as a first pass;
## falls back to searching children for any node whose class_name includes
## "Skin" so future skin renames still work.
func _find_skin(actor: Node3D) -> Node3D:
	if actor == null: return null
	var direct: Variant = actor.get("_skin")
	if direct is Node3D: return direct
	for child in actor.get_children():
		if child is Node3D and "skin" in child.name.to_lower():
			return child
	return null


## Comprehensive cinematic-entry reset. Zeros every visible motion artifact
## the player-body applies each tick so the character reads as "standing
## still" for the duration of the cinematic. Without this, lean, tilt,
## brake-impulse, walk cycle, skate wheels, dust particles all freeze at
## whatever state E-press interrupted → looks broken.
##
## Method names match what PlayerBody exposes today. If char_dev later
## ships a single `PlayerBody.enter_cinematic_pose()` helper, this whole
## body becomes `actor.enter_cinematic_pose()` and the duck-access goes away.
func _freeze_player_for_cinematic(actor: Node3D, skin: Node3D) -> void:
	_saved_player_physics = actor.is_physics_processing()

	# 1. Stop horizontal motion → no further lean/brake accumulation.
	if actor is CharacterBody3D:
		(actor as CharacterBody3D).velocity = Vector3.ZERO

	# 2. Zero body-level lean/tilt/yaw state vars so the FIRST physics tick
	#    after cinematic-exit doesn't pop back into a leaning pose. These
	#    vars live on PlayerBody — duck-accessed via Object.set.
	for prop_name in ["_natural_lean_roll", "_current_lean_pitch",
			"_current_lean_roll", "_brake_impulse", "_prev_skin_yaw"]:
		if actor.get(prop_name) != null:  # only if the property exists
			actor.set(prop_name, 0.0)
	if actor.get("_prev_h_vel") != null:
		actor.set("_prev_h_vel", Vector3.ZERO)

	# 3. Stop dust particles (they don't care about physics_process).
	var dust: GPUParticles3D = actor.get_node_or_null(^"%DustParticles") as GPUParticles3D
	if dust != null:
		_saved_dust_emitting = dust.emitting
		dust.emitting = false

	# 4. Reset the skin. Identity basis strips lean/tilt/offset; we preserve
	#    the skin's uniform_scale so a non-1.0 scale (e.g. AJ at 1.3) doesn't
	#    get clobbered back to 1.0 for the duration of the cinematic/dialogue.
	#    idle() / set_skate_mode(false) drop run+skate anims to idle pose.
	if reset_skin_pose and skin != null:
		var skin_scale: float = 1.0
		if "uniform_scale" in skin:
			skin_scale = float(skin.uniform_scale)
		skin.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * skin_scale), Vector3.ZERO)
		if skin.has_method(&"set_skate_mode"):
			skin.call(&"set_skate_mode", false)
		if skin.has_method(&"idle"):
			skin.call(&"idle")

	# 5. Freeze physics last. Body's _physics_process can't re-apply anything
	#    from this point until exit.
	actor.set_physics_process(false)
	print("[cinematic] player frozen: velocity/lean/tilt/particles zeroed")


## Restore skin rotation, original camera, despawn cinematic cam, re-enable
## body physics. Called via Events.dialogue_ended one-shot bind.
func _exit_cinematic(_ended_id: StringName, actor: Node3D) -> void:
	if not _cinematic_active: return
	_cinematic_active = false
	_free_input_blocker()

	# Restore skin rotation (tween back to pre-cinematic local angle) so
	# when physics re-engages and the body's _yaw_state hasn't changed, the
	# skin's rotation matches body expectations — no pop.
	var skin: Node3D = _find_skin(actor)
	var restore_tween: Tween = null
	if skin != null and _saved_skin_rotation_y != _SAVED_YAW_UNSET:
		var current_yaw: float = skin.rotation.y
		var shortest_delta: float = wrapf(_saved_skin_rotation_y - current_yaw, -PI, PI)
		var short_target: float = current_yaw + shortest_delta
		restore_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		restore_tween.tween_property(skin, "rotation:y", short_target, camera_duration * 0.8)
	_saved_skin_rotation_y = _SAVED_YAW_UNSET

	# Tween the cinematic camera back to the player camera's current pose,
	# then hand control back. If we've been detached from the tree (e.g. the
	# dialogue ended via a `do LevelProgression.advance()` that swapped the
	# scene out from under us), skip the tween and restore instantly — a
	# detached Tween never progresses and would hang the await forever.
	if _cinematic_cam != null and _saved_camera != null:
		if is_inside_tree() and is_instance_valid(_saved_camera):
			var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
			tween.tween_property(_cinematic_cam, "global_transform",
				_saved_camera.global_transform, camera_duration * 0.8)
			await tween.finished
		if is_instance_valid(_saved_camera):
			_saved_camera.make_current()
			print("[cam-dbg] _exit_cinematic restored: %s on %s" % [
				_saved_camera.get_path(), interactable_id])
		_cinematic_cam.queue_free()
		_cinematic_cam = null

	if restore_tween != null and restore_tween.is_running():
		await restore_tween.finished

	# Restore dust particles BEFORE resuming physics so the body's
	# _physics_process sees them in their original emitting state.
	if is_instance_valid(actor):
		var dust: GPUParticles3D = actor.get_node_or_null(^"%DustParticles") as GPUParticles3D
		if dust != null:
			dust.emitting = _saved_dust_emitting
		actor.set_physics_process(_saved_player_physics)
		# Reverse the enter-side set_skate_mode(false). The body's profile
		# was never changed during the cinematic, so we just re-sync the
		# skin's gear visuals (rollerblade wheels) to whatever the body is
		# currently using. Without this, wheels stay hidden post-dialogue.
		var skin_after: Node3D = _find_skin(actor)
		if skin_after != null and skin_after.has_method(&"set_skate_mode"):
			var skate_active := false
			if "_current_profile" in actor and "skate_profile" in actor:
				skate_active = (actor.get("_current_profile") == actor.get("skate_profile"))
			skin_after.call(&"set_skate_mode", skate_active)
	_saved_camera = null
	_saved_actor = null


## Push a transparent input-blocking overlay on a CanvasLayer so the menu /
## HUD beneath the cinematic camera can't be navigated while we're focused
## on the NPC. Layer 1500 sits below the dialogue balloon (Nathan Hoad's
## DialogueManager balloon canvas is ~2000) and above HUD (~1).
func _spawn_input_blocker() -> void:
	if _input_blocker_layer != null:
		return
	_input_blocker_layer = CanvasLayer.new()
	_input_blocker_layer.layer = 1500
	_input_blocker_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(_input_blocker_layer)
	var blocker := Control.new()
	blocker.anchor_right = 1.0
	blocker.anchor_bottom = 1.0
	blocker.offset_right = 0.0
	blocker.offset_bottom = 0.0
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	blocker.focus_mode = Control.FOCUS_ALL
	_input_blocker_layer.add_child(blocker)
	# Pull focus away from any HUD button currently focused, then keep
	# eating ui_* events via the layer-level _input below.
	blocker.grab_focus.call_deferred()
	# Eat keyboard / controller actions targeting underlying UI.
	_input_blocker_layer.set_script(preload("res://interactable/dialogue_trigger/_input_blocker_layer.gd"))


func _free_input_blocker() -> void:
	if _input_blocker_layer != null and is_instance_valid(_input_blocker_layer):
		_input_blocker_layer.queue_free()
	_input_blocker_layer = null
