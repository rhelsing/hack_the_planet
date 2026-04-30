extends Node
class_name KillCounter

## Counts bodies that LEAVE a target faction (either by death/queue_free or
## by faction conversion). Fires `done_flag` once `kill_threshold` is hit
## plus an optional `post_delay` has elapsed. Single-shot.
##
## Polls each physics frame: build a set of bodies currently in
## `enemy_group` whose `faction` == `target_faction`. Any body present
## last tick but missing this tick = one "destroyed". Catches:
##   - died + queue_free'd       → not in scene tree this tick
##   - converted to another faction → no longer matches target_faction
##
## Both count toward the threshold. Use to gate "after 10 reds gone, do X"
## beats — e.g. battle radio chatter, ramping difficulty, end-phase music.

@export var arm_flag: StringName = &""
@export var done_flag: StringName = &""
@export var enemy_group: StringName = &"splice_enemies"
@export var target_faction: StringName = &"red"
## Number of bodies that must leave the target faction before the timer
## starts. Counts both deaths and conversions.
@export var kill_threshold: int = 10
## Seconds to wait between hitting the kill threshold and setting
## done_flag. 0 = fire immediately on threshold.
@export var post_delay: float = 0.0

var _armed: bool = false
# instance_id (int64) → true. We DON'T store Object refs because once a body
# queue_free's, the ref becomes invalid; iterating a Dictionary whose keys
# are freed Objects throws "Trying to assign invalid previously freed
# instance" the moment GDScript tries to bind a key to the typed loop
# variable. instance_ids are pure ints — they survive freeing intact, so the
# diff against `current_ids` cleanly counts vanished bodies as kills.
var _tracked_ids: Dictionary = {}
var _kill_count: int = 0
var _threshold_hit: bool = false


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
	if _threshold_hit: return
	# Snapshot instance_ids of bodies currently in target faction.
	var current_ids: Dictionary = {}
	for body: Node in get_tree().get_nodes_in_group(enemy_group):
		if not is_instance_valid(body): continue
		var f: Variant = body.get(&"faction")
		if f != null and StringName(f) == target_faction:
			current_ids[body.get_instance_id()] = true
	# Anything in _tracked_ids but missing here = left the faction (died or
	# converted). Increment count.
	for id: int in _tracked_ids:
		if not current_ids.has(id):
			_kill_count += 1
			if _kill_count >= kill_threshold:
				_on_threshold_hit()
				return
	_tracked_ids = current_ids


func _on_threshold_hit() -> void:
	_threshold_hit = true
	set_physics_process(false)
	if post_delay > 0.0:
		await get_tree().create_timer(post_delay).timeout
	if done_flag != &"":
		GameState.set_flag(done_flag, true)
