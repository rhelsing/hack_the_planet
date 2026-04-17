class_name ExplorerBrain extends EnemyBrain

## Wanders around with tunable curiosity. When the player enters detection
## range, switches to CHASE and rushes them at a higher speed. Drops back to
## WANDER once they leave a larger exit radius (hysteresis prevents flicker).

@export_group("Detection")
## Horizontal distance at which the enemy notices the player and starts chasing.
@export var detection_radius := 16.0
## Distance at which chase ends. Must exceed detection_radius.
@export var chase_exit_radius := 22.0
## Group the player belongs to. First node found in this group is targeted.
@export var target_group := "player"

@export_group("Chase")
## Multiplier applied to move_speed while chasing. 1.0 = same as wander.
@export_range(0.5, 6.0) var chase_speed_multiplier := 3.0

@export_group("Wander")
## Minimum seconds before picking a new random heading.
@export var min_wander_interval := 1.0
## Maximum seconds before picking a new random heading.
@export var max_wander_interval := 3.0
## Probability (0-1) the enemy changes heading when the interval elapses.
## 0 = only turns at walls/ledges (like a plain walker).
## 1 = reorients every interval.
@export_range(0.0, 1.0) var curiosity := 0.7
## Max angle (degrees) the heading can swing when reorienting.
## Small = gentle meander, 180 = free to reverse.
@export_range(0.0, 180.0) var max_turn_deg := 130.0

@export_group("Ledges")
@export var turn_at_ledges := true
@export var ledge_probe_distance := 0.8
@export var ledge_probe_depth := 1.2

enum State { WANDER, CHASE }

var _state: State = State.WANDER
var _direction := Vector3.RIGHT
var _wander_timer := 0.0
var _target: Node3D


func _ready() -> void:
	_direction = Vector3.RIGHT.rotated(Vector3.UP, randf() * TAU)
	_reset_wander_timer()


func think(enemy: Enemy, delta: float) -> Vector3:
	_ensure_target(enemy)
	_update_state(enemy)

	match _state:
		State.CHASE:
			return _chase_direction(enemy) * enemy.move_speed * chase_speed_multiplier
		_:
			return _wander_direction(enemy, delta) * enemy.move_speed


func _update_state(enemy: Enemy) -> void:
	if _target == null:
		_state = State.WANDER
		return
	var distance := _horizontal_distance(enemy.global_position, _target.global_position)
	match _state:
		State.WANDER:
			if distance < detection_radius:
				_state = State.CHASE
		State.CHASE:
			if distance > chase_exit_radius:
				_state = State.WANDER
				_reset_wander_timer()


func _chase_direction(enemy: Enemy) -> Vector3:
	var to_target: Vector3 = _target.global_position - enemy.global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
		return Vector3.ZERO
	_direction = to_target.normalized()
	# Don't flip direction on obstacles while chasing — just stall, so the
	# enemy presses eagerly against the wall/ledge instead of oscillating
	# back and forth at the boundary.
	if enemy.is_on_wall():
		return Vector3.ZERO
	if turn_at_ledges and enemy.is_on_floor() and not _has_ground_ahead(enemy):
		return Vector3.ZERO
	return _direction


func _wander_direction(enemy: Enemy, delta: float) -> Vector3:
	var flipped := false
	if enemy.is_on_wall():
		_direction = -_direction
		flipped = true
	elif turn_at_ledges and enemy.is_on_floor() and not _has_ground_ahead(enemy):
		_direction = -_direction
		flipped = true

	_wander_timer -= delta
	if _wander_timer <= 0.0:
		# Don't double-turn the frame we already flipped off a wall/ledge;
		# let the new heading play out a bit first.
		if not flipped and randf() < curiosity:
			_pick_random_heading()
		_reset_wander_timer()
	return _direction


func _pick_random_heading() -> void:
	var angle := deg_to_rad(randf_range(-max_turn_deg, max_turn_deg))
	_direction = _direction.rotated(Vector3.UP, angle).normalized()


func _reset_wander_timer() -> void:
	_wander_timer = randf_range(min_wander_interval, max_wander_interval)


func _ensure_target(enemy: Enemy) -> void:
	if _target != null and is_instance_valid(_target):
		return
	var tree := enemy.get_tree()
	if tree == null:
		return
	for node: Node in tree.get_nodes_in_group(target_group):
		if node is Node3D:
			_target = node
			return


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	var dx := b.x - a.x
	var dz := b.z - a.z
	return sqrt(dx * dx + dz * dz)


func _has_ground_ahead(enemy: Enemy) -> bool:
	var space := enemy.get_world_3d().direct_space_state
	var from := enemy.global_position + _direction * ledge_probe_distance
	var to := from + Vector3.DOWN * ledge_probe_depth
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [enemy.get_rid()]
	return not space.intersect_ray(query).is_empty()
