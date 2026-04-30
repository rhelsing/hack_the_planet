extends Node3D
class_name RepeatingSpawner

## Flag-armed enemy spawner that drops `spawn_scene` instances at this
## node's world position on a fixed cadence for a fixed total duration.
##
## Lifecycle:
##   1. _ready: connect to Events.flag_set if `arm_flag` is set.
##   2. arm_flag becomes true → wait `initial_delay` seconds.
##   3. Spawn one instance, wait `spawn_interval` seconds, repeat — until
##      either `total_duration` elapses (from first spawn) OR `max_spawns`
##      is hit (-1 = unlimited).
##   4. Disarms and goes silent.
##
## Spawned enemies are added to the current scene root so they outlive
## this spawner if it's freed mid-cycle.

@export var spawn_scene: PackedScene
## GameState flag that arms the spawner. Empty = inert (manual `arm()`).
@export var arm_flag: StringName = &""
## Seconds after the flag fires before the first spawn drops.
@export var initial_delay: float = 0.0
## Seconds between successive spawns.
@export var spawn_interval: float = 1.0
## Total seconds to keep spawning, measured from the first spawn (after
## initial_delay). 0 or negative = unlimited (use max_spawns to cap).
@export var total_duration: float = 10.0
## Hard cap on spawn count. -1 = no cap.
@export var max_spawns: int = -1

@export_group("Oscillate")
## When true, the spawner's global X oscillates linearly between
## `oscillate_x_min` and `oscillate_x_max` indefinitely, starting at the
## same moment as spawning (after `initial_delay`). Each spawn drops at
## the current oscillating position, so enemies fan out across the range.
@export var oscillate_enabled: bool = false
@export var oscillate_x_min: float = 0.0
@export var oscillate_x_max: float = 0.0
## Seconds for one full pass (min → max OR max → min). A round trip
## back to the start takes 2× this value.
@export var oscillate_pass_duration: float = 5.0

var _armed: bool = false
var _spawn_count: int = 0
var _start_time_sec: float = -1.0


func _ready() -> void:
	if arm_flag == &"":
		return
	if bool(GameState.get_flag(arm_flag, false)):
		_arm()
	else:
		Events.flag_set.connect(_on_flag_set)


func _on_flag_set(id: StringName, value: Variant) -> void:
	if id != arm_flag: return
	if not bool(value): return
	_arm()


## Manual arm hook — call from anywhere to start spawning without a flag.
func arm() -> void:
	_arm()


func _arm() -> void:
	if _armed: return
	_armed = true
	_run.call_deferred()


func _run() -> void:
	if initial_delay > 0.0:
		await get_tree().create_timer(initial_delay).timeout
	if not is_instance_valid(self): return
	_start_oscillation()
	_start_time_sec = Time.get_ticks_msec() / 1000.0
	while is_instance_valid(self):
		if total_duration > 0.0:
			var elapsed: float = Time.get_ticks_msec() / 1000.0 - _start_time_sec
			if elapsed >= total_duration: break
		if max_spawns >= 0 and _spawn_count >= max_spawns: break
		_spawn_one()
		await get_tree().create_timer(spawn_interval).timeout


## Kick off an infinite ping-pong tween between oscillate_x_min and
## oscillate_x_max. Linear ease — straight back-and-forth, no easing at
## endpoints. set_loops(0) loops forever; the tween dies with this node.
func _start_oscillation() -> void:
	if not oscillate_enabled: return
	# Start the camera at min so the first pass is min → max. Authored X
	# is overridden so designers can place the spawner visually anywhere
	# inside the oscillation range without it jumping at arm time.
	global_position.x = oscillate_x_min
	var tween: Tween = create_tween().set_loops()
	tween.tween_property(self, "global_position:x", oscillate_x_max, oscillate_pass_duration)
	tween.tween_property(self, "global_position:x", oscillate_x_min, oscillate_pass_duration)


func _spawn_one() -> void:
	if spawn_scene == null:
		push_warning("RepeatingSpawner: no spawn_scene set — %s" % get_path())
		return
	var enemy: Node3D = spawn_scene.instantiate() as Node3D
	if enemy == null:
		push_warning("RepeatingSpawner: spawn_scene root is not Node3D — %s" % spawn_scene.resource_path)
		return
	var parent: Node = get_tree().current_scene
	parent.add_child(enemy)
	enemy.global_position = global_position
	_spawn_count += 1
