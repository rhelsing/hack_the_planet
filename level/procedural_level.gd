extends Node3D

## Runtime-built level. Reads a JSON brief authored in tools/level_constructor
## and spawns plain MeshInstance3D + StaticBody3D + primitive colliders per
## primitive — no CSG at runtime. Materials are shared per-type so a level of
## N structure cells shares one material instance.
##
## Brief schema (v0.5):
##   { level_num, biome, seed, cells: [{ id, pos:[x,y,z], size:[w,h,d], primitives:[{ id, type }] }] }
##
## Coordinates: cell.pos / cell.size are in 20-unit grid coords.
## A primitive's world AABB is pos*CELL_SIZE..(pos+size)*CELL_SIZE.
##
## Brief path is consumed from GameState's `next_brief_path` flag (set by the
## hub LabEntry before it triggers the scene swap). Falls back to the @export
## default for direct in-editor testing of this scene.

const CELL_SIZE: float = 20.0
const NEXT_BRIEF_FLAG: StringName = &"next_brief_path"

const BASE_SCENE: PackedScene = preload("res://level/level_mockup.tscn")
const PHONE_BOOTH_SCENE: PackedScene = preload("res://level/interactable/phone_booth/phone_booth.tscn")
const PLATFORMS_MATERIAL: ShaderMaterial = preload("res://level/platforms.tres")

@export var brief_path: String = "res://tools/level_constructor/briefs/level_1_starter.json"
@export var random_seed: int = 42
## Y level that all structure pillars extend down to. Set negative so the
## bottoms sink into level_mockup's ground (top at y=0) instead of sitting
## flush at the seam.
@export var floor_y: float = -10.0

var _rng: RandomNumberGenerator
var _player_spawn: Marker3D
var _spawned_root: Node3D

var _mat_start: StandardMaterial3D
var _mat_end: StandardMaterial3D


func _ready() -> void:
	_rng = RandomNumberGenerator.new()
	_init_materials()

	var override_path: String = String(GameState.get_flag(NEXT_BRIEF_FLAG, ""))
	if not override_path.is_empty():
		brief_path = override_path
		GameState.set_flag(NEXT_BRIEF_FLAG, "")

	_player_spawn = get_node_or_null(^"PlayerSpawn") as Marker3D
	if _player_spawn == null:
		_player_spawn = Marker3D.new()
		_player_spawn.name = "PlayerSpawn"
		add_child(_player_spawn)
		_player_spawn.position = Vector3(0, 5, 0)

	_spawned_root = Node3D.new()
	_spawned_root.name = "ProceduralContent"
	add_child(_spawned_root)

	_instance_base()

	var brief: Variant = _load_brief(brief_path)
	if brief == null:
		push_error("[procedural_level] cannot load brief at %s" % brief_path)
		return

	if brief is Dictionary and "seed" in brief:
		_rng.seed = int(brief.seed)
	else:
		_rng.seed = random_seed

	var cells: Array = []
	if brief is Dictionary and brief.cells is Array:
		cells = brief.cells

	for cell in cells:
		_build_cell(cell)

	print("[procedural_level] built %d cells from %s (seed=%d)" % [cells.size(), brief_path, _rng.seed])


func _init_materials() -> void:
	_mat_start = StandardMaterial3D.new()
	_mat_start.albedo_color = Color(0.29, 0.87, 0.5)
	_mat_start.emission_enabled = true
	_mat_start.emission = Color(0.29, 0.87, 0.5)
	_mat_start.emission_energy_multiplier = 1.0

	_mat_end = StandardMaterial3D.new()
	_mat_end.albedo_color = Color(0.98, 0.8, 0.08)
	_mat_end.emission_enabled = true
	_mat_end.emission = Color(0.98, 0.8, 0.08)
	_mat_end.emission_energy_multiplier = 1.5


func _instance_base() -> void:
	var base: Node = BASE_SCENE.instantiate()
	# level_mockup ships its own PlayerSpawn at fixed coords. Strip it so our
	# root-level PlayerSpawn (positioned by the level_start primitive) wins.
	var base_spawn: Node = base.get_node_or_null(^"PlayerSpawn")
	if base_spawn != null:
		base_spawn.queue_free()
	add_child(base)


func _load_brief(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("[procedural_level] brief not found: %s" % path)
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		push_error("[procedural_level] JSON parse failed at %s" % path)
		return null
	return parsed


func _world_origin(cell_pos: Array) -> Vector3:
	return Vector3(float(cell_pos[0]), float(cell_pos[1]), float(cell_pos[2])) * CELL_SIZE


func _world_size(cell_size: Array) -> Vector3:
	return Vector3(float(cell_size[0]), float(cell_size[1]), float(cell_size[2])) * CELL_SIZE


func _build_cell(cell: Dictionary) -> void:
	if not (cell.has("pos") and cell.has("size") and cell.has("primitives")):
		return
	var origin: Vector3 = _world_origin(cell.pos)
	var size: Vector3 = _world_size(cell.size)
	for prim in cell.primitives:
		var t: String = String(prim.get("type", ""))
		match t:
			"level_start": _build_level_start(origin, size)
			"level_end":   _build_level_end(origin, size)
			"checkpoint":  _build_checkpoint(origin, size)
			"structure":   _build_structure(origin, size)
			_: push_warning("[procedural_level] unknown primitive type %s" % t)


func _build_level_start(origin: Vector3, size: Vector3) -> void:
	var center_x := size.x * 0.5
	var center_z := size.z * 0.5
	# Spawn the player on top of the start cell.
	_player_spawn.position = origin + Vector3(center_x, size.y + 1.0, center_z)
	# Glowing pad at floor level (visual only — no collision needed).
	_spawn_pad(origin + Vector3(center_x, size.y + 0.15, center_z),
	           max(min(size.x, size.z) * 0.4, 1.0),
	           _mat_start)


func _build_level_end(origin: Vector3, size: Vector3) -> void:
	var center_x := size.x * 0.5
	var center_z := size.z * 0.5
	_spawn_pad(origin + Vector3(center_x, size.y + 0.15, center_z),
	           max(min(size.x, size.z) * 0.4, 1.0),
	           _mat_end)
	# Trigger area covering the cell volume; mask matches PLAYER only.
	var area := Area3D.new()
	area.collision_layer = 0
	area.collision_mask = Layers.PLAYER
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	area.add_child(shape)
	_spawned_root.add_child(area)
	area.position = origin + size * 0.5
	area.body_entered.connect(_on_level_end_entered)


func _on_level_end_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	if not is_inside_tree():
		return
	LevelProgression.goto_hub()


func _build_checkpoint(origin: Vector3, size: Vector3) -> void:
	var booth: Node3D = PHONE_BOOTH_SCENE.instantiate()
	_spawned_root.add_child(booth)
	booth.position = origin + Vector3(size.x * 0.5, size.y, size.z * 0.5)


func _build_structure(origin: Vector3, size: Vector3) -> void:
	# Extend the structure visual + collider down to floor_y so platforms read
	# as solid pillars/buildings instead of floating boxes. Top of cell stays
	# at origin.y + size.y; bottom stretches to ground level.
	var top_y: float = origin.y + size.y
	if top_y <= floor_y:
		return
	var visual_size := Vector3(size.x, top_y - floor_y, size.z)
	var center := Vector3(
		origin.x + size.x * 0.5,
		floor_y + visual_size.y * 0.5,
		origin.z + size.z * 0.5,
	)
	var body := StaticBody3D.new()
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var mesh_inst := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = visual_size
	mesh_inst.mesh = mesh
	mesh_inst.material_override = PLATFORMS_MATERIAL
	body.add_child(mesh_inst)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = visual_size
	col.shape = box
	body.add_child(col)
	_spawned_root.add_child(body)
	body.position = center


func _spawn_pad(world_pos: Vector3, radius: float, mat: StandardMaterial3D) -> void:
	var mesh_inst := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = 0.3
	mesh_inst.mesh = mesh
	mesh_inst.material_override = mat
	_spawned_root.add_child(mesh_inst)
	mesh_inst.position = world_pos
