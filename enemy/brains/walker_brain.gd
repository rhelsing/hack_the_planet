class_name WalkerBrain extends EnemyBrain

## Simplest brain: walk forward, flip direction at walls and (optionally)
## ledges. No perception, no target tracking.

## Starting direction in the enemy's local XZ plane. Normalized at runtime.
@export var initial_direction := Vector3(1.0, 0.0, 0.0)
## Turn around when a short downward probe ahead finds no ground.
@export var turn_at_ledges := true
## How far ahead (meters) the ledge probe is cast from the enemy origin.
@export var ledge_probe_distance := 0.8
## How far down (meters) the ledge probe reaches before declaring a drop.
@export var ledge_probe_depth := 1.2

var _direction: Vector3


func _ready() -> void:
	_direction = initial_direction.normalized()
	if _direction == Vector3.ZERO:
		_direction = Vector3.RIGHT


func think(enemy: Enemy, _delta: float) -> Vector3:
	if enemy.is_on_wall():
		_direction = -_direction
	elif turn_at_ledges and enemy.is_on_floor() and not _has_ground_ahead(enemy):
		_direction = -_direction

	return _direction * enemy.move_speed


func _has_ground_ahead(enemy: Enemy) -> bool:
	var space := enemy.get_world_3d().direct_space_state
	var from := enemy.global_position + _direction * ledge_probe_distance
	var to := from + Vector3.DOWN * ledge_probe_depth
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [enemy.get_rid()]
	return not space.intersect_ray(query).is_empty()
