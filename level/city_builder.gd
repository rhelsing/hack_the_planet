extends CSGBox3D

## Procedurally spawns a skyline of variable-height "buildings" (CSGBox3D
## children) sitting 0.02m above this plane's top face. Sharing the
## buildings.tres material so they read as one connected cityscape.
## A keep-out radius around the local origin preserves space for the hub's
## actual gameplay geometry.

## Material applied to every spawned building. Defaults to the project's
## buildings.tres.
@export var buildings_material: Material = preload("res://level/buildings.tres")

@export_group("City grid")
## Side length of each grid cell, meters. One building per cell, guaranteed
## not to overlap neighbors. Should be >= max_width + cell_gap.
@export_range(5.0, 100.0) var cell_size: float = 32.0
## Gap kept between the building and its cell edge. Prevents touching.
@export_range(0.0, 20.0) var cell_gap: float = 4.0
## Skip any cell whose XZ would fall inside this radius of local origin.
## Keeps the playable hub area clear.
@export_range(0.0, 500.0) var keep_out_radius: float = 30.0
## Cells beyond this radius from local origin are skipped. Tighter = denser
## city near the hub edge, less waste on invisible distant boxes.
@export_range(50.0, 2000.0) var max_spawn_radius: float = 400.0
## Clearance above the plane's top face, meters.
@export_range(0.0, 1.0, 0.001) var ground_clearance: float = 0.02

@export_group("Building size")
## Widths are clamped to fit inside (cell_size - cell_gap).
@export_range(1.0, 100.0) var min_width: float = 8.0
@export_range(1.0, 200.0) var max_width: float = 28.0
## min_height bumped so every building reaches above the hub floor at y=0
## (base sits at y=-33, so min 40m tall = top at y=+7, clearly visible).
@export_range(1.0, 200.0) var min_height: float = 40.0
@export_range(10.0, 500.0) var max_height: float = 140.0

@export_group("Path avoidance")
## Optional Path3D whose curve buildings should steer clear of. Useful in
## the menu world: point this at the CameraPath and the city won't clip
## into the flythrough.
@export var avoid_path: NodePath
## Reject any cell whose XZ is within this many meters of the closest point
## on avoid_path. Ignored when avoid_path is unset.
@export_range(0.0, 100.0) var path_avoid_radius: float = 8.0

@export_group("Grapple avoidance")
## Reject any cell whose XZ is within this many meters of any node in the
## "grappleable" group. Grappleables are visual-only (no physics body), so
## the overlap check above doesn't see them — this is the dedicated path.
## Set to 0 to disable.
@export_range(0.0, 100.0) var grapple_avoid_radius: float = 14.0

@export_group("Rail avoidance")
## Reject any cell whose XZ is within this many meters of the closest point
## on any Rail's curve (every node in the "rail" group). Rails are Path3D
## nodes — no collider on the curve itself, only an Area3D for grab
## detection — so the physics overlap check below doesn't see them. This
## is the dedicated path. Set to 0 to disable.
@export_range(0.0, 100.0) var rail_avoid_radius: float = 4.0

@export_group("Determinism")
## Fixed RNG seed so the city looks the same across reloads. Change to
## reshuffle the layout.
@export var rng_seed: int = 1337


func _ready() -> void:
	# CSG shapes rebuild their collision via deferred calls — one frame is
	# not enough. Two physics frames plus a short timer gives every
	# sibling's collision body time to land in the physics server before
	# we do intersect_shape against it.
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().create_timer(0.05).timeout
	_spawn_city()
	_register_debug_sliders()


func _register_debug_sliders() -> void:
	var dp := get_tree().root.get_node_or_null(^"DebugPanel")
	if dp == null:
		return
	dp.add_slider("City/cell_size", 5, 100, 1,
		func() -> float: return cell_size,
		func(v: float) -> void:
			cell_size = v
			_respawn_city(),
		"city_builder.gd")
	dp.add_slider("City/cell_gap", 0, 20, 0.5,
		func() -> float: return cell_gap,
		func(v: float) -> void:
			cell_gap = v
			_respawn_city(),
		"city_builder.gd")
	dp.add_slider("City/keep_out_radius", 0, 500, 5,
		func() -> float: return keep_out_radius,
		func(v: float) -> void:
			keep_out_radius = v
			_respawn_city(),
		"city_builder.gd")
	dp.add_slider("City/max_spawn_radius", 50, 2000, 10,
		func() -> float: return max_spawn_radius,
		func(v: float) -> void:
			max_spawn_radius = v
			_respawn_city(),
		"city_builder.gd")
	dp.add_slider("City/min_height", 1, 200, 1,
		func() -> float: return min_height,
		func(v: float) -> void:
			min_height = v
			_respawn_city(),
		"city_builder.gd")
	dp.add_slider("City/max_height", 10, 500, 1,
		func() -> float: return max_height,
		func(v: float) -> void:
			max_height = v
			_respawn_city(),
		"city_builder.gd")


## Clear existing buildings and respawn from scratch. Called when a debug
## slider changes so you can preview tuning live.
func _respawn_city() -> void:
	for c in get_children():
		c.queue_free()
	# Deferred so the queue_free children drain before we add new ones —
	# otherwise the first sample in the next spawn is still a just-freed node.
	call_deferred(&"_spawn_city")


func _spawn_city() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed

	print("[city] builder starting. cell_size=%.1f radius=(%.0f..%.0f)" % [
		cell_size, keep_out_radius, max_spawn_radius,
	])

	# Local top-face Y, plus the requested clearance.
	var top_y_local: float = size.y * 0.5 + ground_clearance

	# Physics space for overlap tests — reject any cell whose building would
	# poke up through existing hub geometry (main Ground, platforms, phone
	# booths, anything with a collider). Test box is shrunk by 0.04m so it
	# sits entirely above ground_bg's top face and never self-collides.
	var space_state: PhysicsDirectSpaceState3D = null
	var world: World3D = get_world_3d()
	if world != null:
		space_state = world.direct_space_state

	# Grid extent: cells_per_side in each direction from origin.
	var cells_per_side: int = int(max_spawn_radius / cell_size)
	# Clamp max width to cell_size - cell_gap so buildings fit inside cells.
	var max_width_fit: float = max(min_width, cell_size - cell_gap)
	var effective_max_width: float = min(max_width, max_width_fit)

	# Resolve the optional path-to-avoid once, not per-cell.
	var path_node: Path3D = null
	var path_curve: Curve3D = null
	var path_xform_inv: Transform3D
	if not avoid_path.is_empty():
		path_node = get_node_or_null(avoid_path) as Path3D
		if path_node != null:
			path_curve = path_node.curve
			path_xform_inv = path_node.global_transform.affine_inverse()

	# Snapshot grappleable world XZ positions once. Empty in the hub / levels
	# without grapples — the per-cell check costs nothing then.
	var grapple_xz: PackedVector2Array = PackedVector2Array()
	if grapple_avoid_radius > 0.0:
		for g in get_tree().get_nodes_in_group(&"grappleable"):
			if g is Node3D:
				var p: Vector3 = (g as Node3D).global_position
				grapple_xz.append(Vector2(p.x, p.z))

	# Snapshot rails — store curve + cached inverse transform so the per-cell
	# check is just a curve get_closest_point + XZ distance compare. No
	# physics, no allocation in the hot loop.
	var rails: Array = []
	if rail_avoid_radius > 0.0:
		for r in get_tree().get_nodes_in_group(&"rail"):
			if r is Path3D and (r as Path3D).curve != null:
				var path3d: Path3D = r as Path3D
				rails.append({
					"curve": path3d.curve,
					"xform": path3d.global_transform,
					"xform_inv": path3d.global_transform.affine_inverse(),
				})

	var placed: int = 0
	var rejected_radius: int = 0
	var rejected_overlap: int = 0
	var rejected_path: int = 0
	var rejected_grapple: int = 0
	var rejected_rail: int = 0
	for ix in range(-cells_per_side, cells_per_side + 1):
		for iz in range(-cells_per_side, cells_per_side + 1):
			var cx: float = float(ix) * cell_size
			var cz: float = float(iz) * cell_size
			var radial_dist: float = Vector2(cx, cz).length()
			if radial_dist < keep_out_radius or radial_dist > max_spawn_radius:
				rejected_radius += 1
				continue

			var w: float = rng.randf_range(min_width, effective_max_width)
			var d: float = rng.randf_range(min_width, effective_max_width)
			var h: float = rng.randf_range(min_height, max_height)
			var local_pos: Vector3 = Vector3(cx, top_y_local + h * 0.5, cz)
			# Half-diagonal of THIS building's XZ footprint. Inflate every
			# avoidance radius by this so the check measures rail/path/grapple
			# vs the building's actual edge, not its center. Without this, a
			# 28m-wide building 5m from a rail passes a 4m-radius check while
			# its 14m half-extent straddles the rail.
			var building_half: float = 0.5 * sqrt(w * w + d * d)

			# Path avoidance: sample the closest point on the curve to this
			# cell (in path-local space) and compare XZ distance. Ignore Y
			# because buildings are tall — a path passing anywhere overhead
			# is still a clash.
			if path_curve != null:
				var cell_world: Vector3 = global_transform * local_pos
				var cell_in_path: Vector3 = path_xform_inv * cell_world
				var closest_path_local: Vector3 = path_curve.get_closest_point(cell_in_path)
				var closest_world: Vector3 = path_node.global_transform * closest_path_local
				var dx: float = cell_world.x - closest_world.x
				var dz: float = cell_world.z - closest_world.z
				var path_threshold: float = path_avoid_radius + building_half
				if dx * dx + dz * dz < path_threshold * path_threshold:
					rejected_path += 1
					continue

			# Grapple avoidance — XZ-only distance to every grappleable.
			# Tested before the physics overlap check; intersect_shape is
			# the most expensive thing in this loop.
			if not grapple_xz.is_empty():
				var cell_world_xz: Vector3 = global_transform * local_pos
				var cxz := Vector2(cell_world_xz.x, cell_world_xz.z)
				var grapple_threshold: float = grapple_avoid_radius + building_half
				var grapple_threshold_sq: float = grapple_threshold * grapple_threshold
				var hit_grapple: bool = false
				for gxz in grapple_xz:
					if cxz.distance_squared_to(gxz) < grapple_threshold_sq:
						hit_grapple = true
						break
				if hit_grapple:
					rejected_grapple += 1
					continue

			# Rail avoidance — sample each rail's curve for the closest point
			# in path-local, transform back to world, XZ-distance check.
			# Cheaper than the physics overlap below; runs first.
			if not rails.is_empty():
				var cell_world_rail: Vector3 = global_transform * local_pos
				var hit_rail: bool = false
				var rail_threshold: float = rail_avoid_radius + building_half
				var rail_threshold_sq: float = rail_threshold * rail_threshold
				for rail in rails:
					var cell_local: Vector3 = (rail.xform_inv as Transform3D) * cell_world_rail
					var closest_local: Vector3 = (rail.curve as Curve3D).get_closest_point(cell_local)
					var closest_world: Vector3 = (rail.xform as Transform3D) * closest_local
					var dxr: float = cell_world_rail.x - closest_world.x
					var dzr: float = cell_world_rail.z - closest_world.z
					if dxr * dxr + dzr * dzr < rail_threshold_sq:
						hit_rail = true
						break
				if hit_rail:
					rejected_rail += 1
					continue

			if space_state != null and _overlaps_level_geometry(
				space_state, local_pos, Vector3(w, h, d)
			):
				rejected_overlap += 1
				continue

			var bld := MeshInstance3D.new()
			var mesh := BoxMesh.new()
			mesh.size = Vector3(w, h, d)
			bld.mesh = mesh
			bld.material_override = buildings_material
			bld.position = local_pos
			bld.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(bld)
			placed += 1
	print("[city] spawned %d buildings (radius=%d, overlap=%d, path=%d, grapple=%d, rail=%d rejects)" % [
		placed, rejected_radius, rejected_overlap, rejected_path, rejected_grapple, rejected_rail,
	])


## True if a box of `sz` at local position `local_pos` would overlap any
## collision-enabled node in the current physics space. The test box is
## shrunk by 0.04m so building bases (which sit 0.02m above ground_bg's
## top face) don't register against ground_bg itself.
func _overlaps_level_geometry(
	space_state: PhysicsDirectSpaceState3D,
	local_pos: Vector3,
	sz: Vector3,
) -> bool:
	var shape := BoxShape3D.new()
	shape.size = sz - Vector3(0.04, 0.04, 0.04)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = global_transform * Transform3D(Basis.IDENTITY, local_pos)
	query.collide_with_bodies = true
	# Areas are off: the hub's KillPlane + other trigger volumes span huge
	# regions and would reject every cell. Only solid PhysicsBody3Ds count
	# — that's what's visible to the player anyway.
	query.collide_with_areas = false
	var hits := space_state.intersect_shape(query, 1)
	return not hits.is_empty()
