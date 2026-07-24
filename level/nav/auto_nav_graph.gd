class_name AutoNavGraph extends Node3D

## Dynamic Tier-1 navigation graph — built ONCE at load, covering the whole map.
##
## During loading it samples the top surface of every platform (`CSGBox3D`,
## except `ground_bg`) on a grid and spawns a Marker3D into the `nav_graph`
## group at each walkable point. Work is spread across load frames (a per-frame
## probe budget) so there's no single spike. Once placement finishes it warms
## the enemy routing graph (EnemyAIBrain._ensure_wp_graph) so the first in-combat
## route finds it already built instead of hitching mid-gameplay.
##
## Why full-map-at-load, not a rolling window around the player: a window would
## leave enemies at the far end of the map with NO nodes → they'd fall back to
## reactive steering (walk off ledges / flicker). A static full-map graph is
## available to every pawn the instant it needs to route, and unused far nodes
## cost only a few bytes — BFS never visits them.
##
## Separate from NavTrail: hand-placed `ally_waypoints` are NavTrail activation
## probes; routing nodes live in `nav_graph` so the two never pollute each other.
##
## Tier 1 = HORIZONTAL routing only; _nav_smart owns jump/drop; NavTrail +
## rail-entry keep precedence; reactive steer + stuck-escape are the fallback.

## MASTER SWITCH. false = do nothing: no nodes placed, no graph built, routing
## falls back to reactive steering + stuck-escape (pre-nav behavior). Flip to
## true to turn the whole system back on.
@export var enabled: bool = false

## Horizontal grid spacing (m) between sampled nodes on a platform top.
@export var spacing: float = 3.0

## Hard cap on total sampled nodes (safety for a pathological/procedural level).
@export var max_nodes: int = 6000

## CSGBox3D node names to skip (the big background/sky floor, etc.).
@export var exclude_node_names: Array[String] = ["ground_bg"]

## Hit-normal.y threshold for "floor" vs wall/steep face (0.5 ≈ within 60°).
@export var floor_normal_dot: float = 0.5

## Progressive budget: sample at most this many probe points per physics frame
## during the load pass, then yield. Keeps each load frame cheap.
@export var probes_per_frame: int = 250

## Physics frames to wait before starting so csg_collider_swap's baked colliders
## exist to raycast against.
@export var collider_settle_frames: int = 3

## Draw a small sphere under each node (debug only).
@export var debug_draw: bool = false

## Routing-node group — NOT `ally_waypoints` (that's NavTrail's).
const NAV_GROUP: StringName = &"nav_graph"

## Emitted once placement + graph build finish (or immediately if disabled).
## SceneLoader awaits this to hold the loading bar until the bake completes.
signal build_finished

var _generated: bool = false
var _done: bool = false


func is_done() -> bool:
	return _done
var _placed: Dictionary = {}   # cell-key → true (dedup across overlapping boxes)
var _count: int = 0
var _debug_mesh: SphereMesh = null


func _ready() -> void:
	_build.call_deferred()


func _build() -> void:
	if _generated:
		return
	_generated = true
	if not enabled:
		_done = true
		build_finished.emit()
		return
	for _i in collider_settle_frames:
		await get_tree().physics_frame
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		_finish()
		return
	if not tree.get_nodes_in_group(NAV_GROUP).is_empty():
		_finish()
		return

	# direct_space_state is only valid during physics processing and comes back
	# null mid scene-transition; retry a few frames, then give up gracefully.
	# CRITICAL: every exit path must _finish() or SceneLoader's await hangs the
	# loading transition forever (the glitch overlay never plays back in).
	var space := get_world_3d().direct_space_state
	var tries: int = 0
	while space == null and tries < 10:
		await get_tree().physics_frame
		space = get_world_3d().direct_space_state
		tries += 1
	if space == null:
		_finish()
		return
	var exclude: Array[RID] = _pawn_rids(tree)
	var boxes: Array[Node] = _gather_platforms(tree.current_scene)

	# Placement pass — sample every platform top, yielding by probe budget.
	var probes: int = 0
	for box: Node in boxes:
		if _count >= max_nodes:
			break
		var size: Vector3 = box.get(&"size")
		var xf: Transform3D = (box as Node3D).global_transform
		var half: Vector3 = size * 0.5
		var nx: int = maxi(1, int(ceil(size.x / spacing)))
		var nz: int = maxi(1, int(ceil(size.z / spacing)))
		for i in nx + 1:
			for j in nz + 1:
				if _count >= max_nodes:
					break
				var lx: float = clampf(-half.x + float(i) * spacing, -half.x, half.x)
				var lz: float = clampf(-half.z + float(j) * spacing, -half.z, half.z)
				_probe_and_place(space, xf * Vector3(lx, half.y, lz), exclude)
				probes += 1
				if probes >= probes_per_frame:
					probes = 0
					await get_tree().physics_frame
	print("[autonav] placed %d nav nodes across %d platforms" % [_count, boxes.size()])

	# Build the routing graph, spread across load frames (resumable). Awaited by
	# SceneLoader while the loading bar is up, so the K-NN bake never hits a
	# gameplay frame.
	var brains: Array[Node] = tree.current_scene.find_children("*", "EnemyAIBrain", true, false)
	if not brains.is_empty():
		var brain := brains[0] as EnemyAIBrain
		if brain != null:
			await brain.build_graph_async()
	_finish()


func _finish() -> void:
	_done = true
	build_finished.emit()


func _probe_and_place(space: PhysicsDirectSpaceState3D, world_top: Vector3,
		exclude: Array[RID]) -> void:
	var q := PhysicsRayQueryParameters3D.create(
		world_top + Vector3.UP * 0.5, world_top + Vector3.DOWN * 1.0)
	q.exclude = exclude
	var hit: Dictionary = space.intersect_ray(q)
	if hit.is_empty():
		return
	if (hit.normal as Vector3).y < floor_normal_dot:
		return
	var p: Vector3 = hit.position as Vector3
	var key: String = _cell_key(p)
	if _placed.has(key):
		return
	_placed[key] = true
	var m := Marker3D.new()
	add_child(m)
	m.global_position = p
	m.add_to_group(NAV_GROUP)
	_count += 1
	if debug_draw:
		_attach_debug(m)


func _gather_platforms(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	for n: Node in root.find_children("*", "CSGBox3D", true, false):
		if String(n.name) in exclude_node_names:
			continue
		out.append(n)
	return out


func _pawn_rids(tree: SceneTree) -> Array[RID]:
	var exclude: Array[RID] = []
	for grp: StringName in [&"player", &"enemies", &"splice_enemies", &"allies"]:
		for n: Node in tree.get_nodes_in_group(grp):
			if n is CollisionObject3D:
				exclude.append((n as CollisionObject3D).get_rid())
	return exclude


# 3D cell key (coarse Y bucket) so stacked platforms each keep their own node.
func _cell_key(p: Vector3) -> String:
	return "%d,%d,%d" % [roundi(p.x / spacing), roundi(p.y / 2.0), roundi(p.z / spacing)]


func _attach_debug(m: Marker3D) -> void:
	if _debug_mesh == null:
		_debug_mesh = SphereMesh.new()
		_debug_mesh.radius = 0.25
		_debug_mesh.height = 0.5
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.2, 0.8, 1.0)
		mat.emission_enabled = true
		mat.emission = Color(0.2, 0.8, 1.0)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_debug_mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = _debug_mesh
	mi.position = Vector3.UP * 0.3
	m.add_child(mi)
