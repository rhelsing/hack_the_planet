@tool
extends NavigationRegion3D

## Nav bake + automatic jump/drop link generation.
##
## The bake is a PRE-PROCESS. `tools/bake_nav.sh` boots each listed level
## headless with `-- --nav-bake`, which bakes mesh + links here and writes a
## sidecar artifact to level/nav/baked/<level>.res — level .tscn files are
## never rewritten. At normal load, _ready applies the sidecar (instant).
## The editor `bake_now` checkbox produces the same sidecar for quick
## iteration. Levels with no sidecar yet fall back to a one-shot live bake
## so the sandbox keeps working.
##
## Link generation: sample the baked mesh's boundary edges, pair samples on
## DIFFERENT islands within the jump envelope, reject pairs with a wall
## between, spawn links (bidirectional when the climb is jumpable, one-way
## for pure drops). Slopes need no links — any surface under agent_max_slope
## bakes walkable and the body just walks it.

## Editor pseudo-button: tick to bake mesh + links and save the sidecar.
@export var bake_now: bool = false : set = _set_bake_now

## Show navmesh + link lines + agent paths in-game (editor runs only).
@export var debug_draw := true

@export_group("Link generation")
## Max horizontal distance (m) between two island boundary samples that can
## be linked. Keep at or under the pawn's flat jump reach:
## (max_speed + jump_horizontal_boost) * air_time, air_time = 2*jump_impulse/g.
## Dummy today: (5+3) * 0.95 = 7.6.
@export var max_link_horizontal: float = 7.5
## Horizontal reach for the SKATE capability tier (NavLayers.SKATE_JUMP).
## Links between max_link_horizontal and this get the skate-only layer —
## walking pawns route around them, skating pawns (agent mask 3) take them.
## Skating red envelope: 11.2 × 1.5 + 3 boost ≈ 19.8 m/s × 0.95s ≈ 18.8m;
## 14 leaves landing margin. 0 = tier disabled (walk links only).
@export var skate_link_horizontal: float = 14.0
## Max upward height gain (m) still linked BIDIRECTIONALLY — the jump-up must
## clear it. Pawn apex = jump_impulse²/(2g) ≈ 3.4m; leave landing margin.
@export var max_jump_up: float = 2.6
## Max drop (m) for one-way down links. Beyond this, no link (treated lethal).
@export var max_drop: float = 8.0
## Spacing (m) of samples along boundary edges.
@export var sample_step: float = 2.0
## Min distance (m) between accepted links' midpoints (dedup).
@export var min_link_spacing: float = 3.0
## Height (m) above samples for the wall-blockage ray.
@export var los_clearance: float = 1.2


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if OS.get_cmdline_user_args().has("--nav-bake"):
		# Offline pipeline mode (tools/bake_nav.sh): bake, save sidecar, exit.
		await get_tree().process_frame  # CSG builds after entering the tree
		var ok := _bake_and_save()
		get_tree().quit(0 if ok else 1)
		return
	var sidecar := _sidecar_path()
	if sidecar != "" and ResourceLoader.exists(sidecar):
		_apply_sidecar(load(sidecar) as NavBakeResult)
	elif navigation_mesh != null and navigation_mesh.get_polygon_count() > 0:
		print("[nav_bake] using in-scene bake: %d polygons, %d links" % [
			navigation_mesh.get_polygon_count(), _count_links()])
	else:
		# No artifact yet — live fallback so an unbaked level still works.
		await get_tree().process_frame
		bake_now_full()
	if debug_draw and OS.has_feature("editor"):
		NavigationServer3D.set_debug_enabled(true)


## Sidecar artifact path, keyed by the parent level's scene file name.
func _sidecar_path() -> String:
	var parent := get_parent()
	if parent == null or parent.scene_file_path == "":
		return ""
	return "res://level/nav/baked/%s.res" % parent.scene_file_path.get_file().get_basename()


func _apply_sidecar(result: NavBakeResult) -> void:
	if result == null or result.mesh == null:
		push_error("[nav_bake] sidecar %s is invalid — falling back to live bake" % _sidecar_path())
		bake_now_full()
		return
	navigation_mesh = result.mesh
	_clear_generated_links()
	var records: Array = []
	for i in result.link_starts.size():
		records.append({
			"from": result.link_starts[i],
			"to": result.link_ends[i],
			"bidir": result.link_bidirectional[i] if i < result.link_bidirectional.size() else true,
			"layers": result.link_layers[i] if i < result.link_layers.size() else NavLayers.WALK,
		})
	_spawn_links(records)
	print("[nav_bake] sidecar applied: %d polygons, %d links (%s)" % [
		result.mesh.get_polygon_count(), records.size(), _sidecar_path()])


func _set_bake_now(value: bool) -> void:
	bake_now = false
	if value and Engine.is_editor_hint():
		_bake_and_save()


## Bake + generate + write the sidecar. Returns success. Callable from the
## editor button, the --nav-bake pipeline, or any script.
func _bake_and_save() -> bool:
	var records: Array = bake_now_full()
	if navigation_mesh == null or navigation_mesh.get_polygon_count() == 0:
		return false
	var path := _sidecar_path()
	if path == "":
		push_error("[nav_bake] cannot derive sidecar path (level has no scene_file_path)")
		return false
	var result := NavBakeResult.new()
	result.mesh = navigation_mesh.duplicate(true) as NavigationMesh
	for r: Dictionary in records:
		result.link_starts.append(r.from as Vector3)
		result.link_ends.append(r.to as Vector3)
		result.link_bidirectional.append(r.bidir as bool)
		result.link_layers.append(int(r.get("layers", NavLayers.WALK)))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://level/nav/baked"))
	var err := ResourceSaver.save(result, path)
	if err != OK:
		push_error("[nav_bake] failed to save sidecar %s (err %d)" % [path, err])
		return false
	print("[nav_bake] sidecar saved: %s (%d polygons, %d links)" % [
		path, result.mesh.get_polygon_count(), records.size()])
	return true


## Live mesh bake + link regeneration (transient nodes). Returns the link
## records so callers can persist them.
func bake_now_full() -> Array:
	var nm := navigation_mesh
	if nm == null:
		push_error("[nav_bake] no NavigationMesh resource assigned on %s" % get_path())
		return []
	# Geometry lives across the level (inherited mockup base + hand-placed
	# grounds), not under this node — feed the parser via the group source
	# mode by tagging every sibling. Transient tags; only needed during bake.
	nm.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	nm.geometry_source_group_name = &"nav_bake_source"
	for c: Node in get_parent().get_children():
		if c != self and c is Node3D and not c.is_in_group(&"nav_bake_source"):
			c.add_to_group(&"nav_bake_source")
	bake_navigation_mesh(false)
	if nm.get_polygon_count() == 0:
		push_error("[nav_bake] bake produced 0 polygons — check parsed_geometry_type / baking AABB")
		return []
	_clear_generated_links()
	var records: Array = _generate_links(nm)
	_spawn_links(records)
	print("[nav_bake] baked %d polygons, generated %d links" % [nm.get_polygon_count(), records.size()])
	return records


func _count_links() -> int:
	var n: int = 0
	for c: Node in get_children():
		if c is NavigationLink3D:
			n += 1
	return n


func _clear_generated_links() -> void:
	for c: Node in get_children():
		if c is NavigationLink3D and String(c.name).begins_with("GenLink"):
			c.free()


func _spawn_links(records: Array) -> void:
	var idx: int = 0
	for r: Dictionary in records:
		idx += 1
		var link := NavigationLink3D.new()
		link.name = "GenLink%d" % idx
		link.start_position = r.from
		link.end_position = r.to
		link.bidirectional = r.bidir
		link.navigation_layers = int(r.get("layers", NavLayers.WALK))
		add_child(link)


## Boundary-edge sampling + island pairing. Returns link records:
## [{from: Vector3 (upper), to: Vector3 (lower), bidir: bool, dy: float}].
func _generate_links(nm: NavigationMesh) -> Array:
	var verts: PackedVector3Array = nm.get_vertices()
	var poly_count: int = nm.get_polygon_count()
	# Edge (vertex index pair) → polygons using it. Edges used by exactly
	# one polygon form the walkable surface's outer boundary.
	var edge_polys: Dictionary = {}
	for pi in poly_count:
		var poly: PackedInt32Array = nm.get_polygon(pi)
		for k in poly.size():
			var a: int = poly[k]
			var b: int = poly[(k + 1) % poly.size()]
			var key := Vector2i(mini(a, b), maxi(a, b))
			if not edge_polys.has(key):
				edge_polys[key] = []
			(edge_polys[key] as Array).append(pi)
	# Island labels: flood-fill polygon adjacency across shared edges.
	var adj: Dictionary = {}
	for key: Vector2i in edge_polys:
		var ps: Array = edge_polys[key]
		if ps.size() >= 2:
			for i in ps.size():
				for j in ps.size():
					if i == j:
						continue
					if not adj.has(ps[i]):
						adj[ps[i]] = []
					(adj[ps[i]] as Array).append(ps[j])
	var island := PackedInt32Array()
	island.resize(poly_count)
	island.fill(-1)
	var island_count: int = 0
	for pi in poly_count:
		if island[pi] != -1:
			continue
		var stack: Array = [pi]
		island[pi] = island_count
		while not stack.is_empty():
			var p: int = stack.pop_back()
			for n: int in adj.get(p, []):
				if island[n] == -1:
					island[n] = island_count
					stack.append(n)
		island_count += 1
	# Samples along boundary edges.
	var samples: Array = []  # {pos: Vector3, island: int}
	for key: Vector2i in edge_polys:
		var ps: Array = edge_polys[key]
		if ps.size() != 1:
			continue
		var va: Vector3 = verts[key.x]
		var vb: Vector3 = verts[key.y]
		var n_sub: int = maxi(1, int(floor(va.distance_to(vb) / sample_step)))
		for s in n_sub:
			var t: float = (float(s) + 0.5) / float(n_sub)
			samples.append({"pos": va.lerp(vb, t), "island": island[ps[0]]})
	# Candidate pairs: different islands, within the jump envelope.
	var cands: Array = []
	for i in samples.size():
		for j in range(i + 1, samples.size()):
			if samples[i].island == samples[j].island:
				continue
			var hi: Dictionary = samples[i]
			var lo: Dictionary = samples[j]
			if lo.pos.y > hi.pos.y:
				hi = samples[j]
				lo = samples[i]
			var dy: float = hi.pos.y - lo.pos.y
			if dy > max_drop:
				continue
			var dh: float = Vector2(hi.pos.x - lo.pos.x, hi.pos.z - lo.pos.z).length()
			if dh < 0.5 or dh > maxf(max_link_horizontal, skate_link_horizontal):
				continue
			cands.append({"from": hi.pos, "to": lo.pos, "dy": dy, "dh": dh, "cost": dh + dy})
	cands.sort_custom(func(x, y): return x.cost < y.cost)
	# Greedy accept: spacing dedup, then wall check. The blockage ray runs
	# HORIZONTALLY at the upper sample's level so a legit drop doesn't
	# self-block on its own ledge; walls between islands still reject.
	var space := get_world_3d().direct_space_state
	var accepted: Array = []
	for c: Dictionary in cands:
		var mid: Vector3 = (c.from as Vector3).lerp(c.to as Vector3, 0.5)
		var too_close: bool = false
		for a: Dictionary in accepted:
			if ((a.from as Vector3).lerp(a.to as Vector3, 0.5)).distance_to(mid) < min_link_spacing:
				too_close = true
				break
		if too_close:
			continue
		var from_p: Vector3 = (c.from as Vector3) + Vector3.UP * los_clearance
		var to_p := Vector3((c.to as Vector3).x, (c.from as Vector3).y + los_clearance, (c.to as Vector3).z)
		if not space.intersect_ray(PhysicsRayQueryParameters3D.create(from_p, to_p)).is_empty():
			continue
		c["bidir"] = (c.dy as float) <= max_jump_up
		# Capability tier: within the walking envelope = WALK (everyone);
		# beyond it = SKATE_JUMP (only agents with the skate mask bit).
		c["layers"] = NavLayers.WALK if (c.dh as float) <= max_link_horizontal \
			else NavLayers.SKATE_JUMP
		accepted.append(c)
		print("[nav_bake]   link (%.1f,%.1f,%.1f)->(%.1f,%.1f,%.1f) dy=%.1f %s%s" % [
			c.from.x, c.from.y, c.from.z, c.to.x, c.to.y, c.to.z,
			c.dy, "bidir" if c.bidir else "drop-only",
			" SKATE-TIER" if c.layers == NavLayers.SKATE_JUMP else ""])
	return accepted


