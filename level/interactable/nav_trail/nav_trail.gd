class_name NavTrail extends Node3D

## Player-laid navigation rail — STEP 1 (debug visual only).
##
## While the local player runs near any `ally_waypoints` probe, this records
## their recent path as a rolling polyline at a fixed height off the floor and
## draws it as a bright debug line. Reuses the existing probes purely as an
## activation zone.
##
## Later steps (not built yet): enemies/allies that get close to this rail snap
## onto it, get driven along it toward the player, and hop off at the head
## (near the player) or the tail end.

## Horizontal distance (m) from any probe within which the player's path is
## recorded. Outside this, recording pauses; the existing trail persists.
@export var activation_radius: float = 12.0

## Height (m) above the floor to place trail points. A downward ray under the
## player finds the floor; the point sits this far above the hit.
@export var trail_height: float = 0.5

## Minimum horizontal distance (m) the player must move before a new point is
## appended. Keeps the polyline light.
@export var point_spacing: float = 1.0

## Max accumulated path length (m). Oldest points drop off the tail once the
## trail exceeds this — a rolling trail whose head follows the player. Set very
## high for an effectively endless trail; the reset/backtrack guards are what
## actually end it in practice.
@export var max_trail_length: float = 100.0

## Pure-pursuit carrot distance (m). When an AI follows the rail, it steers at
## a point this far ahead along the path toward the head — smooths the follow
## so pawns cut curves instead of stop-turning at each point.
@export var follow_lookahead: float = 3.0

## Catmull-Rom subdivisions per raw segment when building the smoothed rail.
## Higher = smoother curve + more ground-snap rays. 0 = no smoothing (raw
## points). The drawn line AND the AI query API both use the smoothed path.
@export_range(0, 8) var smooth_subdivisions: int = 4

## If the next point lands farther than this from the head, treat it as a
## teleport / respawn / warp (not a walked step) and start a fresh trail there
## instead of drawing a straight streak across the gap. Keep it well above the
## most you can travel between points in one hop (~a couple meters).
@export var reset_distance: float = 6.0

## Backtrack sensitivity. Each new step's direction is dotted with the trail's
## smoothed recent heading; AT OR BELOW this the player is turning back, so the
## trail cancels. This is the main dial: higher = MORE sensitive (0.0 cancels on
## a >90° turn; 0.5 on a >60° turn; 0.7 on a >45° turn). Lower toward -1 = only
## near-full U-turns cancel.
@export_range(-1.0, 1.0) var backtrack_dot_threshold: float = 0.3

## How much the reference heading is smoothed (running average of recent travel
## direction) before the backtrack test. 0 = compare against only the last 1m
## segment (jittery — normal skating noise can false-cancel). Higher = steadier
## reference, so a sustained curve-back accumulates and cancels even when each
## individual step barely turns. ~0.5 lets you crank sensitivity without noise.
@export_range(0.0, 0.95) var heading_smoothing: float = 0.5

## Toggle the debug line. Off = invisible; the rail still records and drives the
## AI (the smoothed path is built regardless of this flag).
@export var debug_draw: bool = false

## Line color / glow.
@export var line_color: Color = Color(0.2, 1.0, 0.5, 1.0)

# Raw recorded floor points, tail (oldest) → head (newest, under the player).
var _points: PackedVector3Array = PackedVector3Array()
# Smoothed + ground-snapped derivative of _points. This is what gets DRAWN and
# what the AI query API reads. Rebuilt whenever _points changes.
var _smoothed: PackedVector3Array = PackedVector3Array()
# Horizontal unit direction of the last committed segment. Used to detect
# backtracking. ZERO when the trail has no committed heading yet.
var _heading: Vector3 = Vector3.ZERO
var _line: MeshInstance3D


func _ready() -> void:
	# Brains find the rail by group (one per level).
	add_to_group(&"nav_trail")
	_line = MeshInstance3D.new()
	_line.mesh = ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = line_color
	mat.emission_enabled = true
	mat.emission = line_color
	mat.emission_energy_multiplier = 2.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true  # debug: show through geometry
	_line.material_override = mat
	add_child(_line)


func _physics_process(_delta: float) -> void:
	var player := get_tree().get_first_node_in_group(&"player") as Node3D
	if player == null:
		return
	if _near_probe(player.global_position):
		_maybe_append_point(player)
	_redraw()


## True when `pos` is within activation_radius (horizontal) of any probe.
func _near_probe(pos: Vector3) -> bool:
	var r_sq: float = activation_radius * activation_radius
	for n in get_tree().get_nodes_in_group(&"ally_waypoints"):
		if n is Node3D:
			var p: Vector3 = (n as Node3D).global_position
			var dx: float = p.x - pos.x
			var dz: float = p.z - pos.z
			if dx * dx + dz * dz <= r_sq:
				return true
	return false


## Append a new point at the player's floor position, with three guards:
##   - no floor under the player (mid-jump / off the map) → don't extend
##   - discontinuity (teleport/respawn) → clear and restart at the new spot
##   - backtracking (reversed vs recent heading) → turn the trail off
func _maybe_append_point(player: Node3D) -> void:
	var rid: RID = (player as CollisionObject3D).get_rid() if player is CollisionObject3D else RID()
	var fh: Dictionary = _floor_hit(player.global_position, rid)
	# No walkable floor under the player → the rail must not follow them into
	# the air / off the map. This is the void-follow fix.
	if not fh.hit:
		return
	var pt: Vector3 = fh.point
	if _points.is_empty():
		_points.append(pt)
		_rebuild_smoothed()
		return
	var head: Vector3 = _points[_points.size() - 1]
	var delta: Vector3 = pt - head
	delta.y = 0.0
	var dist: float = delta.length()
	# Teleport / warp / respawn: too far to be a walked step → fresh trail.
	if dist > reset_distance:
		_points = PackedVector3Array([pt])
		_heading = Vector3.ZERO
		_rebuild_smoothed()
		return
	# Not moved far enough to commit a new point.
	if dist < point_spacing:
		return
	var move_dir: Vector3 = delta / dist
	# Backtracking: turning back against the smoothed recent heading → cancel.
	# The smoothed reference means a gradual curve-back still accumulates and
	# trips this even when each individual 1m step barely turns.
	if _heading != Vector3.ZERO and move_dir.dot(_heading) <= backtrack_dot_threshold:
		_points = PackedVector3Array()
		_heading = Vector3.ZERO
		_rebuild_smoothed()
		return
	_points.append(pt)
	# Update the smoothed heading (running average toward the new step).
	if _heading == Vector3.ZERO:
		_heading = move_dir
	else:
		_heading = _heading.lerp(move_dir, 1.0 - heading_smoothing).normalized()
	_trim_to_length()
	_rebuild_smoothed()


## Drop points off the tail until total path length <= max_trail_length.
func _trim_to_length() -> void:
	var total: float = 0.0
	for i in range(1, _points.size()):
		total += _points[i].distance_to(_points[i - 1])
	while _points.size() > 2 and total > max_trail_length:
		total -= _points[1].distance_to(_points[0])
		_points.remove_at(0)


## Purely-vertical raycast (1m up → 10m down) to find the floor under `pos`.
## Returns {hit: bool, point: Vector3}; on a hit, point sits trail_height above
## the floor. On a miss (void / airborne) hit is false and the caller skips.
func _floor_hit(pos: Vector3, exclude_rid: RID) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		pos + Vector3.UP * 1.0, pos + Vector3.DOWN * 10.0)
	if exclude_rid != RID():
		q.exclude = [exclude_rid]
	var hit: Dictionary = space.intersect_ray(q)
	if hit.is_empty():
		return {"hit": false, "point": pos}
	var h: Vector3 = hit["position"] as Vector3
	return {"hit": true, "point": Vector3(h.x, h.y + trail_height, h.z)}


## Rebuild the smoothed + ground-snapped rail from the raw points (strategy
## A + C): Catmull-Rom through the points for a clean curve, then snap every
## generated vertex straight down to the floor so the curve hugs the ramp
## instead of chording across or bowing off it. This is what gets drawn and
## what the AI reads. Called only when _points changes (≈ once per meter).
func _rebuild_smoothed() -> void:
	var n: int = _points.size()
	if n < 2 or smooth_subdivisions <= 0:
		_smoothed = _points.duplicate()
		return
	var player := get_tree().get_first_node_in_group(&"player") as Node3D
	var rid: RID = (player as CollisionObject3D).get_rid() if player is CollisionObject3D else RID()
	var out: PackedVector3Array = PackedVector3Array()
	for i in range(n - 1):
		var p0: Vector3 = _points[maxi(i - 1, 0)]
		var p1: Vector3 = _points[i]
		var p2: Vector3 = _points[i + 1]
		var p3: Vector3 = _points[mini(i + 2, n - 1)]
		# First segment emits its start vertex; later segments start one sub-step
		# in so joins aren't duplicated.
		var start_j: int = 0 if i == 0 else 1
		for j in range(start_j, smooth_subdivisions + 1):
			var t: float = float(j) / float(smooth_subdivisions)
			var v: Vector3 = _catmull_rom(p0, p1, p2, p3, t)
			var fh: Dictionary = _floor_hit(v, rid)
			if fh.hit:
				v = fh.point
			out.append(v)
	_smoothed = out


## Standard centripetal-form-agnostic Catmull-Rom interpolation.
func _catmull_rom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2: float = t * t
	var t3: float = t2 * t
	return 0.5 * (
		(2.0 * p1)
		+ (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


## Rebuild the debug line strip from the smoothed rail.
func _redraw() -> void:
	var im := _line.mesh as ImmediateMesh
	im.clear_surfaces()
	_line.visible = debug_draw
	if not debug_draw or _smoothed.size() < 2:
		return
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for p: Vector3 in _smoothed:
		im.surface_add_vertex(_line.to_local(p))
	im.surface_end()


# ── Public query API (read by enemy_ai_brain.gd) ────────────────────────────

## True when there's a usable rail (>= 2 points).
func has_trail() -> bool:
	return _smoothed.size() >= 2


## World position of the head — the newest point, under the player. ZERO if none.
func head_position() -> Vector3:
	if _smoothed.is_empty():
		return Vector3.ZERO
	return _smoothed[_smoothed.size() - 1]


## Horizontal distance from `world_pos` to the nearest point on the rail.
## INF when there's no trail.
func distance_to(world_pos: Vector3) -> float:
	if _smoothed.size() < 2:
		return INF
	return _nearest(world_pos).dist


## Horizontal unit direction to follow the rail toward the head (the player)
## from `world_pos`, aiming at a pure-pursuit carrot `follow_lookahead` meters
## ahead along the path. ZERO when no trail or already at the head.
func steer_along(world_pos: Vector3) -> Vector3:
	if _smoothed.size() < 2:
		return Vector3.ZERO
	var n: Dictionary = _nearest(world_pos)
	var carrot: Vector3 = _point_at_offset(n.offset + follow_lookahead)
	var dir: Vector3 = carrot - world_pos
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		return Vector3.ZERO
	return dir.normalized()


## Nearest point on the polyline to `world_pos` (horizontal metric). Returns
## {dist, offset, point}: horizontal distance, arc-length from the tail (3D),
## and the projected world point.
func _nearest(world_pos: Vector3) -> Dictionary:
	var best_dist: float = INF
	var best_offset: float = 0.0
	var best_point: Vector3 = _smoothed[0]
	var acc: float = 0.0
	for i in range(_smoothed.size() - 1):
		var a: Vector3 = _smoothed[i]
		var b: Vector3 = _smoothed[i + 1]
		var seg_len: float = a.distance_to(b)
		var sx: float = b.x - a.x
		var sz: float = b.z - a.z
		var horiz_len2: float = sx * sx + sz * sz
		var t: float = 0.0
		if horiz_len2 > 0.0001:
			t = clampf(((world_pos.x - a.x) * sx + (world_pos.z - a.z) * sz) / horiz_len2, 0.0, 1.0)
		var proj: Vector3 = a.lerp(b, t)
		var dx: float = world_pos.x - proj.x
		var dz: float = world_pos.z - proj.z
		var d: float = sqrt(dx * dx + dz * dz)
		if d < best_dist:
			best_dist = d
			best_offset = acc + seg_len * t
			best_point = proj
		acc += seg_len
	return {"dist": best_dist, "offset": best_offset, "point": best_point}


## World point at arc-length `offset` from the tail, measured along the polyline
## (3D). Clamps to the tail (offset <= 0) and the head (offset >= total).
func _point_at_offset(offset: float) -> Vector3:
	if _smoothed.size() < 2:
		return head_position()
	if offset <= 0.0:
		return _smoothed[0]
	var acc: float = 0.0
	for i in range(_smoothed.size() - 1):
		var a: Vector3 = _smoothed[i]
		var b: Vector3 = _smoothed[i + 1]
		var seg_len: float = a.distance_to(b)
		if acc + seg_len >= offset:
			var t: float = 0.0
			if seg_len > 0.0001:
				t = (offset - acc) / seg_len
			return a.lerp(b, t)
		acc += seg_len
	return _smoothed[_smoothed.size() - 1]
