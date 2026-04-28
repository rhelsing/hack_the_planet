extends Node

## Distance-gated process_mode toggle for enemies. Polled at low frequency
## (poll_interval, default 0.5s), this script flips far enemies to
## PROCESS_MODE_DISABLED so their brains, animations, physics callbacks,
## and signal listeners all stop running. When the player walks back
## within wake_distance, they re-enable.
##
## Cheap because:
##   - Distance compared via distance_squared_to (no sqrt per enemy)
##   - Polls at 2 Hz (poll_interval) not every frame — 22 enemies × 2/sec
##     is 44 distance ops per second total.
##   - process_mode change is a single property assignment.
##
## Hysteresis (wake_distance < sleep_distance) avoids flicker as the
## player walks the boundary.
##
## Disabled state in Godot 4: the node tree below the enemy stops
## _process / _physics_process / input. The CharacterBody3D stays in the
## physics world (transform + collision shape persist) so other things
## can still query it; it just doesn't do anything per-frame.

@export var sleep_distance: float = 80.0
@export var wake_distance: float = 70.0
@export var enemy_groups: Array[StringName] = [&"enemies", &"splice_enemies"]
@export var player_group: StringName = &"player"
@export var poll_interval: float = 0.5
@export var verbose: bool = false

var _accum: float = 0.0
var _player_cache: Node3D = null


func _process(delta: float) -> void:
	_accum += delta
	if _accum < poll_interval:
		return
	_accum = 0.0
	var player := _resolve_player()
	if player == null:
		return
	var p: Vector3 = player.global_position
	var sleep_sq: float = sleep_distance * sleep_distance
	var wake_sq: float = wake_distance * wake_distance
	var slept: int = 0
	var woken: int = 0
	for grp in enemy_groups:
		for n: Node in get_tree().get_nodes_in_group(grp):
			# Safety: never sleep the player even if they're temporarily in
			# an enemy group via a faction swap. Costs one ref-equality test
			# per enemy per poll — negligible.
			if n == player:
				continue
			if not (n is Node3D):
				continue
			var enemy: Node3D = n as Node3D
			var d_sq: float = enemy.global_position.distance_squared_to(p)
			var is_disabled: bool = enemy.process_mode == Node.PROCESS_MODE_DISABLED
			if is_disabled and d_sq < wake_sq:
				enemy.process_mode = Node.PROCESS_MODE_INHERIT
				woken += 1
			elif not is_disabled and d_sq > sleep_sq:
				enemy.process_mode = Node.PROCESS_MODE_DISABLED
				slept += 1
	if verbose and (slept > 0 or woken > 0):
		print("[enemy_distance_sleep] slept=%d woken=%d" % [slept, woken])


func _resolve_player() -> Node3D:
	if _player_cache != null and is_instance_valid(_player_cache):
		return _player_cache
	for n: Node in get_tree().get_nodes_in_group(player_group):
		if n is Node3D:
			_player_cache = n as Node3D
			return _player_cache
	return null
