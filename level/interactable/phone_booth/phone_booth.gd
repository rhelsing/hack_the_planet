@tool
class_name PhoneBooth extends Node3D

## Drag the buildings shader material here to use a different active look
## without editing the scene subresource. Defaults to the project's
## res://level/buildings.tres via the scene.
@export var active_material: Material

## Notification sound played when this booth transitions to the active
## checkpoint. Played as a 2D AudioStreamPlayer on the SFX bus so it reads
## as UI feedback regardless of camera distance. Re-touching an already-
## active booth does NOT replay (gated by _was_active).
@export var active_sound: AudioStream = preload("res://audio/sfx/checkpoint_active.mp3")
@export_range(-30.0, 12.0) var active_sound_volume_db: float = -6.0

## Optional: when this booth activates (live touch OR continue-from-save
## spawn at this position), arm the CutscenePlayer at the given path
## after `arm_delay` seconds. Empty NodePath = no cutscene wiring.
##
## Session-once semantics: if `session_played_flag` is set in
## GameState.session_flags (in-memory only, not serialized), the cutscene
## is NOT armed — same-session re-entries (death/respawn at this
## checkpoint) skip silently. Game restart wipes the session_flags dict
## (autoload re-init) so continue-from-save replays the cutscene.
@export_group("Cutscene trigger")
@export var on_activate_arm_cutscene: NodePath
@export_range(0.0, 10.0, 0.1) var arm_delay: float = 1.0
@export var session_played_flag: StringName = &""

## Persistent flag set on GameState the first time the player enters this
## booth's trigger. Empty = no flag (default — every existing booth in the
## game leaves it empty). Used by chained beacon UI: Booth A's persist_flag
## becomes Booth B's beacon `visible_when_flag`, so each activation lights
## up the next marker. Symmetric to Walkie's persist_flag and WallCage's
## spawned_flag — same pattern, different sub-system.
@export var persist_flag: StringName = &""

@onready var _activation_block: MeshInstance3D = get_node_or_null("ActivationBlock")

var _active_sound_player: AudioStreamPlayer
var _was_active: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	add_to_group("phone_booths")
	# Start hidden — the block only appears (with building material) once the
	# player activates this booth as their checkpoint. Kept visible in the
	# editor so you can position it; toggled off at runtime startup.
	if _activation_block != null:
		_activation_block.visible = false
	# 2D notification player — same pattern as warp/coin clicks (see audio.gd
	# _make_player). Bus is SFX so master+sfx volume settings apply.
	_active_sound_player = AudioStreamPlayer.new()
	_active_sound_player.bus = &"SFX"
	add_child(_active_sound_player)
	var area: Area3D = get_node_or_null("Area3D")
	if area != null:
		area.body_entered.connect(_on_body_entered)
		# Continue-from-save case: the player teleports INSIDE this Area3D
		# rather than crossing its boundary, so body_entered would never
		# fire. After one physics frame, walk the overlap set and synthesize
		# the entry. No-op on fresh-load when no player exists yet, no-op
		# on level-load where the player spawned elsewhere.
		_check_initial_overlap.call_deferred(area)


func _check_initial_overlap(area: Area3D) -> void:
	if not is_instance_valid(area):
		return
	await get_tree().physics_frame
	if not is_instance_valid(area):
		return
	for body: Node3D in area.get_overlapping_bodies():
		if body.is_in_group("player"):
			_on_body_entered(body)
			return


func _on_body_entered(body: Node3D) -> void:
	# Only the player banks checkpoints — if an enemy wanders through a booth
	# it shouldn't move the player's respawn point to wherever the enemy was.
	if not body.is_in_group("player"):
		return
	Events.checkpoint_reached.emit(_compute_safe_respawn_pos(body))
	_activate()
	_maybe_fire_cutscene()
	if persist_flag != &"":
		GameState.set_flag(persist_flag, true)


func _maybe_fire_cutscene() -> void:
	if on_activate_arm_cutscene.is_empty():
		return
	# Same-session guard. We set the session flag IMMEDIATELY (before the
	# delay timer) so a second body_entered during the 1s window can't
	# double-arm. The flag is in-memory only — death+respawn keeps it set
	# (no replay), but game restart / continue-from-save wipes it (replay).
	if session_played_flag != &"" \
			and bool(GameState.session_flags.get(session_played_flag, false)):
		return
	if session_played_flag != &"":
		GameState.session_flags[session_played_flag] = true
	_arm_after_delay.call_deferred()


func _arm_after_delay() -> void:
	if arm_delay > 0.0:
		await get_tree().create_timer(arm_delay).timeout
	if not is_inside_tree():
		return
	var cs: Node = get_node_or_null(on_activate_arm_cutscene)
	if cs == null:
		push_warning("PhoneBooth: cutscene path not found: %s" % on_activate_arm_cutscene)
		return
	if cs.has_method(&"arm"):
		cs.call(&"arm")


# Ring-search around the booth for a respawn-safe spot: at least 3 and at
# most 5 units away horizontally, sitting on a roughly-flat surface near
# the booth's own Y, with at least 1 unit of platform clearance in every
# cardinal direction. Returns the validated spot raised 1 unit above the
# ground hit. Falls back to the booth's own global_position when nothing
# in the ring validates (better to respawn at the pivot than refuse to
# respawn). The booth's own StaticBody3D RID is excluded from the cast so
# the down-ray can't be eaten by the booth's collider on tightly-placed
# variants.
func _compute_safe_respawn_pos(actor: Node3D) -> Vector3:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return global_position
	# Exclude the booth's own collider (so the down-ray can't be eaten by
	# its own roof) and the player's collider (so the wall-clearance shape
	# cast doesn't false-positive on the player who's standing inside the
	# trigger when this runs).
	var exclude: Array[RID] = []
	var sb := get_node_or_null(^"StaticBody3D")
	if sb is StaticBody3D:
		exclude.append((sb as StaticBody3D).get_rid())
	if actor is CollisionObject3D:
		exclude.append((actor as CollisionObject3D).get_rid())
	var booth_y: float = global_position.y
	# Mid-radius first; the inside-of-mid then outside-of-mid order keeps
	# the picked spot biased toward 4 units away when multiple candidates
	# would validate.
	var radii: Array = [4.0, 3.0, 5.0]
	for radius: float in radii:
		for i in range(8):
			var angle: float = float(i) * (TAU / 8.0)
			var dir := Vector3(cos(angle), 0.0, sin(angle))
			var candidate := global_position + dir * radius
			var ground: Vector3 = _raycast_ground(space, candidate, booth_y, exclude)
			if ground.x == INF:
				continue
			if not _has_safe_clearance(space, ground, exclude):
				continue
			return ground + Vector3.UP
	return global_position


# Cast a 30-unit ray down from booth.y + 5 above the candidate XZ. Accepts
# the hit only when (a) the surface normal is mostly up (filters walls and
# steep ramps that the body would slide off of) and (b) the hit Y is
# within 10 units of the booth (filters rays that punched into a deep pit
# below). Returns Vector3(INF,INF,INF) on miss/reject.
func _raycast_ground(space: PhysicsDirectSpaceState3D, candidate: Vector3, booth_y: float, exclude: Array[RID]) -> Vector3:
	var origin := Vector3(candidate.x, booth_y + 5.0, candidate.z)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + Vector3.DOWN * 30.0)
	query.exclude = exclude
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return Vector3(INF, INF, INF)
	if (hit["normal"] as Vector3).y < 0.7:
		return Vector3(INF, INF, INF)
	var pos: Vector3 = hit["position"]
	if absf(pos.y - booth_y) > 10.0:
		return Vector3(INF, INF, INF)
	return pos


# Verify the candidate has both edge AND wall clearance:
#   1. Edge — four cardinal offsets ±1 unit X/Z must each land on ground
#      within 1 unit of the candidate Y. Catches platform edges (no ground
#      to the side) and step-downs (ground is there but a unit below).
#   2. Wall — a 1-unit-radius sphere centered just above the spawn point
#      (ground.y + 1.1) must overlap NO physics geometry. Catches walls,
#      pillars, railings, hazards, anything else within 1 unit
#      horizontally at the player's body level. The +1.1 lift keeps the
#      sphere off the ground (otherwise it'd false-positive on the very
#      floor we're respawning onto).
# Both must pass for a candidate to be picked.
func _has_safe_clearance(space: PhysicsDirectSpaceState3D, ground_pos: Vector3, exclude: Array[RID]) -> bool:
	# Edge probes.
	var offsets: Array = [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]
	for offset: Vector3 in offsets:
		var probe := ground_pos + offset
		var origin := Vector3(probe.x, ground_pos.y + 0.5, probe.z)
		var query := PhysicsRayQueryParameters3D.create(origin, origin + Vector3.DOWN * 5.0)
		query.exclude = exclude
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			return false
		var hit_y: float = (hit["position"] as Vector3).y
		if absf(hit_y - ground_pos.y) > 1.0:
			return false
	# Wall / obstacle clearance — sphere overlap test at chest height.
	var sphere := SphereShape3D.new()
	sphere.radius = 1.0
	var shape_query := PhysicsShapeQueryParameters3D.new()
	shape_query.shape = sphere
	shape_query.transform = Transform3D(Basis.IDENTITY, ground_pos + Vector3(0, 1.1, 0))
	shape_query.exclude = exclude
	var hits: Array = space.intersect_shape(shape_query, 1)
	if not hits.is_empty():
		return false
	return true


func _activate() -> void:
	# One active checkpoint at a time: clear every other booth, then light us up.
	for other: Node in get_tree().get_nodes_in_group("phone_booths"):
		if other is PhoneBooth and other != self:
			(other as PhoneBooth)._set_active(false)
	_set_active(true)


func _set_active(active: bool) -> void:
	if _activation_block == null:
		return
	# Detect the false→true transition before flipping state — that's the
	# only moment the notification should fire.
	var newly_active: bool = active and not _was_active
	_was_active = active
	_activation_block.visible = active
	if active and active_material != null:
		_activation_block.set_surface_override_material(0, active_material)
	if newly_active and active_sound != null and _active_sound_player != null:
		_active_sound_player.stream = active_sound
		_active_sound_player.volume_db = active_sound_volume_db
		_active_sound_player.play()
