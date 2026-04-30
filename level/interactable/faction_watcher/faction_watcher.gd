extends Node
class_name FactionWatcher

## Watches the population of a specific faction in the level. When the
## live count of bodies in `enemy_group` whose `faction` matches
## `target_faction` drops to zero, sets `done_flag` on GameState.
##
## Guards against firing pre-spawn: requires at least `min_seen_before_done`
## qualifying bodies to have existed at some moment before checking can
## fire. Use to gate "no more reds" / "no more golds" boss-phase beats.
##
## Arms via `arm_flag`. Until then the watcher is inert. Once `done_flag`
## fires, the watcher disables itself — single-shot.

@export var arm_flag: StringName = &""
@export var done_flag: StringName = &""
@export var enemy_group: StringName = &"splice_enemies"
## faction StringName to count. "red", "green", "gold", "splice_stealth",
## per the PlayerBody._FACTION_GROUP mapping.
@export var target_faction: StringName = &"red"
## Minimum bodies that must have existed at some point before the
## zero-count check is allowed to fire `done_flag`. 1 = "at least one
## must have spawned"; higher = "wait for boss spawn to ramp up".
@export var min_seen_before_done: int = 1
## Seconds the count must STAY at zero before `done_flag` fires. 0 = fire
## the moment count hits zero (legacy behavior). Use > 0 to debounce
## momentary 0-counts (e.g. a kill + spawn arriving in the same tick) —
## "battle is genuinely over after N seconds of no enemies".
@export var stable_seconds: float = 0.0
## Poll interval (physics frames) — 1 = every frame. 4 = every 4th frame.
## Watcher work is cheap (group scan + faction read), so default fast.
@export_range(1, 60) var tick_every_n_frames: int = 4

var _armed: bool = false
var _ever_seen: int = 0
var _frames_since_check: int = 0
var _zero_since_msec: int = -1


func _ready() -> void:
	set_physics_process(false)
	if arm_flag == &"":
		_arm()
		return
	if bool(GameState.get_flag(arm_flag, false)):
		_arm()
	else:
		Events.flag_set.connect(_on_flag_set)


func _on_flag_set(id: StringName, value: Variant) -> void:
	if id != arm_flag: return
	if not bool(value): return
	_arm()


func _arm() -> void:
	if _armed: return
	_armed = true
	set_physics_process(true)


func _physics_process(_delta: float) -> void:
	_frames_since_check += 1
	if _frames_since_check < tick_every_n_frames:
		return
	_frames_since_check = 0
	var count: int = 0
	for body: Node in get_tree().get_nodes_in_group(enemy_group):
		if not is_instance_valid(body): continue
		var f: Variant = body.get(&"faction")
		if f != null and StringName(f) == target_faction:
			count += 1
	if count > _ever_seen:
		_ever_seen = count
	if _ever_seen < min_seen_before_done:
		_zero_since_msec = -1
		return
	if count > 0:
		# Reset stable timer — population came back up.
		_zero_since_msec = -1
		return
	# count == 0 here.
	if stable_seconds <= 0.0:
		# Legacy: fire immediately.
		set_physics_process(false)
		if done_flag != &"":
			GameState.set_flag(done_flag, true)
		return
	# Stable-debounce path.
	if _zero_since_msec < 0:
		_zero_since_msec = Time.get_ticks_msec()
	elif Time.get_ticks_msec() - _zero_since_msec >= int(stable_seconds * 1000.0):
		set_physics_process(false)
		if done_flag != &"":
			GameState.set_flag(done_flag, true)
