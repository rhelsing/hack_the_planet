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


func interact(actor: Node3D) -> void:
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

	# 4. Reset the skin. Transform3D() is identity → strips lean, tilt, offset.
	#    idle() / set_skate_mode(false) drop run+skate anims to idle pose.
	if reset_skin_pose and skin != null:
		skin.transform = Transform3D()
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
	# then hand control back.
	if _cinematic_cam != null and _saved_camera != null:
		var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		tween.tween_property(_cinematic_cam, "global_transform",
			_saved_camera.global_transform, camera_duration * 0.8)
		await tween.finished
		_saved_camera.make_current()
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
	_saved_camera = null
