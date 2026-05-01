extends Node
class_name DelayedFlag

## Sets `done_flag` on GameState `delay_seconds` after `arm_flag` becomes
## true (or immediately on _ready when `arm_flag` is empty). Single-shot,
## persistent — won't re-fire across reloads if `done_flag` is already set.
##
## "Becomes true" is a live transition: if `arm_flag` is already true at
## _ready (e.g. loaded from a save past this point), we do NOT fire —
## we wait for a fresh `set_flag` call this session. This stops the
## chain from re-arming on every load when `arm_flag` is persisted but
## `done_flag` is session-reset (see GameState._SESSION_RESET_FLAGS).
##
## Use as a general timer utility: "fire flag X seconds after Y", "wait
## for cutscene to end + 5s before unlocking the door", etc.

@export var arm_flag: StringName = &""
@export var done_flag: StringName = &""
@export var delay_seconds: float = 1.0

var _fired: bool = false


func _ready() -> void:
	if done_flag != &"" and bool(GameState.get_flag(done_flag, false)):
		_fired = true
		return
	if arm_flag == &"":
		_run.call_deferred()
		return
	Events.flag_set.connect(_on_flag_set)


func _on_flag_set(id: StringName, value: Variant) -> void:
	if _fired: return
	if id != arm_flag: return
	if not bool(value): return
	_run()


func _run() -> void:
	if _fired: return
	_fired = true
	if delay_seconds > 0.0:
		await get_tree().create_timer(delay_seconds).timeout
	if done_flag != &"":
		GameState.set_flag(done_flag, true)
