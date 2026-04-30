extends Node
class_name WallCage

## Spawns four invisible StaticBody3D walls around the perimeter of `target`'s
## top face once the trigger sequence completes:
##   1. `arm_flag` becomes true on GameState (typically a Walkie's persist_flag).
##   2. If `wait_for_walkie_end` is true, the next Walkie.line_ended fires.
##   3. `arm_delay` seconds elapse.
##   4. On each frame thereafter, check if the player is in the column above
##      the target box. As soon as they are — spawn the cage.
##
## Walls remain in place until `remove_when_flag` becomes true (optional —
## leave empty if you'll despawn manually). Useful for "trap the player on
## the platform during a cutscene" beats. Walls are non-rendering — pure
## colliders on the configured layer.
##
## `target` should be a Node3D with a `size: Vector3` property (CSGBox3D /
## MeshInstance3D-with-BoxMesh / etc.). The component reads center + size
## once at _ready to compute world-space bounds.

@export var arm_flag: StringName = &""
@export var wait_for_walkie_end: bool = true
@export var arm_delay: float = 2.0
@export var target: NodePath
@export var remove_when_flag: StringName = &""
## Flag set on GameState the moment the cage actually spawns. Useful as
## the trigger for follow-on beats (cutscene start, music swap, etc.).
## Empty = no flag set.
@export var spawned_flag: StringName = &""
@export var wall_height: float = 15.0
@export var wall_thickness: float = 1.0
@export_flags_3d_physics var collision_layer: int = 1
@export_flags_3d_physics var collision_mask: int = 0

@export_group("Directional")
## When true, bodies in `directional_groups` pass through the walls while
## they're OUTSIDE the cage volume, but get blocked once inside. Lets
## companions arriving via rail keep streaming in after the cage is up.
## Per-physics-tick: scans bodies in the listed groups and toggles
## `add_collision_exception_with` on each wall. Bodies in other groups
## (e.g. enemies, default world geometry) hit the walls normally.
@export var directional: bool = false
@export var directional_groups: Array[StringName] = [&"player", &"allies"]

# 0=idle (waiting for arm_flag), 1=armed (waiting for walkie line ending),
# 2=counting down, 3=spawned.
var _state: int = 0
var _countdown_until_msec: int = 0
var _walls: Array[StaticBody3D] = []
var _target_node: Node3D = null
var _box_min: Vector3
var _box_max: Vector3
# Bodies that currently have collision-exception with all our walls (i.e.
# walls are passing them through). Tracked so we don't re-add/remove every
# tick. Cleared on cage despawn.
var _passthrough: Dictionary = {}


func _ready() -> void:
	_target_node = get_node_or_null(target) as Node3D
	if _target_node == null:
		push_warning("WallCage: target not Node3D — %s" % get_path())
		return
	_compute_bounds()
	if arm_flag != &"" and bool(GameState.get_flag(arm_flag, false)):
		# Already armed from a prior session — short-circuit through the chain.
		_state = 1
		_on_armed()
	elif arm_flag != &"":
		Events.flag_set.connect(_on_flag_set)
	if remove_when_flag != &"":
		Events.flag_set.connect(_on_remove_flag_set)
	set_process(false)


func _compute_bounds() -> void:
	var center: Vector3 = _target_node.global_position
	var size: Vector3 = Vector3.ONE
	if "size" in _target_node:
		size = _target_node.get(&"size") as Vector3
	_box_min = center - size * 0.5
	_box_max = center + size * 0.5


func _on_flag_set(id: StringName, value: Variant) -> void:
	if _state != 0: return
	if id != arm_flag: return
	if not bool(value): return
	_state = 1
	_on_armed()


func _on_armed() -> void:
	if wait_for_walkie_end:
		Walkie.line_ended.connect(_on_walkie_line_ended, CONNECT_ONE_SHOT)
	else:
		_start_countdown()


func _on_walkie_line_ended() -> void:
	if _state != 1: return
	_start_countdown()


func _start_countdown() -> void:
	_state = 2
	_countdown_until_msec = Time.get_ticks_msec() + int(arm_delay * 1000.0)
	set_process(true)


func _process(_delta: float) -> void:
	if _state != 2: return
	if Time.get_ticks_msec() < _countdown_until_msec: return
	var player := get_tree().get_first_node_in_group(&"player") as Node3D
	if player == null: return
	var p: Vector3 = player.global_position
	if p.y <= _box_max.y: return  # not above the top face yet
	if p.x < _box_min.x or p.x > _box_max.x: return
	if p.z < _box_min.z or p.z > _box_max.z: return
	_spawn_walls()
	_state = 3
	if spawned_flag != &"":
		GameState.set_flag(spawned_flag, true)
	set_process(false)


## Per-tick directional check. For each body in `directional_groups`,
## maintain the wall collision-exception so the body can cross any wall
## from outside-in but not inside-out. "Inside" here means within the
## XZ footprint of the box AND above its top — i.e., on the cage floor.
func _physics_process(_delta: float) -> void:
	if not directional: return
	if _state != 3 or _walls.is_empty(): return
	for grp: StringName in directional_groups:
		for body: Node in get_tree().get_nodes_in_group(grp):
			if not (body is Node3D): continue
			_update_directional(body as Node3D)


func _update_directional(body: Node3D) -> void:
	var inside: bool = _is_inside_cage(body.global_position)
	if inside:
		# Walls block them — clear any pass-through.
		if _passthrough.has(body):
			for wall: StaticBody3D in _walls:
				if is_instance_valid(wall):
					wall.remove_collision_exception_with(body)
			_passthrough.erase(body)
	else:
		# Body is outside the cage — let them cross any wall to come in.
		if not _passthrough.has(body):
			for wall: StaticBody3D in _walls:
				if is_instance_valid(wall):
					wall.add_collision_exception_with(body)
			_passthrough[body] = true


func _is_inside_cage(pos: Vector3) -> bool:
	if pos.x < _box_min.x or pos.x > _box_max.x: return false
	if pos.z < _box_min.z or pos.z > _box_max.z: return false
	# "Inside" means above the top of the conversion box. A body sitting at
	# floor level beside the box isn't inside even if its XZ overlaps.
	if pos.y < _box_max.y: return false
	return true


func _spawn_walls() -> void:
	var center: Vector3 = (_box_min + _box_max) * 0.5
	var size: Vector3 = _box_max - _box_min
	var top_y: float = _box_max.y
	var wall_center_y: float = top_y + wall_height * 0.5
	# Four walls — +X, -X, +Z, -Z. Each gets a StaticBody3D + BoxShape3D.
	# Slight overlap at the corners (wall_thickness on each side of the
	# perpendicular pair) so there are no diagonal escape gaps.
	var sides: Array[Dictionary] = [
		{
			"pos": Vector3(_box_max.x + wall_thickness * 0.5, wall_center_y, center.z),
			"size": Vector3(wall_thickness, wall_height, size.z + wall_thickness * 2.0),
		},
		{
			"pos": Vector3(_box_min.x - wall_thickness * 0.5, wall_center_y, center.z),
			"size": Vector3(wall_thickness, wall_height, size.z + wall_thickness * 2.0),
		},
		{
			"pos": Vector3(center.x, wall_center_y, _box_max.z + wall_thickness * 0.5),
			"size": Vector3(size.x, wall_height, wall_thickness),
		},
		{
			"pos": Vector3(center.x, wall_center_y, _box_min.z - wall_thickness * 0.5),
			"size": Vector3(size.x, wall_height, wall_thickness),
		},
	]
	var parent: Node = get_tree().current_scene
	for s: Dictionary in sides:
		var body := StaticBody3D.new()
		body.collision_layer = collision_layer
		body.collision_mask = collision_mask
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = s.size
		shape.shape = box
		body.add_child(shape)
		parent.add_child(body)
		body.global_position = s.pos
		_walls.append(body)


func _on_remove_flag_set(id: StringName, value: Variant) -> void:
	if id != remove_when_flag: return
	if not bool(value): return
	for w in _walls:
		if is_instance_valid(w):
			w.queue_free()
	_walls.clear()
	_passthrough.clear()
	set_physics_process(false)
