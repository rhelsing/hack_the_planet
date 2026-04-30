extends Node
class_name BuriedReveal

## Buries its parent Node3D `bury_depth` units below its authored Y at scene
## load, then tweens it back up when `reveal_flag` becomes true on GameState.
## If `reveal_after_walkie_line_ends` is true, arms on flag-set and waits for
## the next Walkie.line_ended before sliding — so a narrative line can finish
## reading before the prop pops up.
##
## Re-entry safe: if the flag is already true at _ready (returning to a level
## the player previously revealed in), the parent stays at its authored
## position and never buries.

@export var reveal_flag: StringName = &""
@export var bury_depth: float = 2.0
## Optional explicit XYZ offset. When non-zero, the parent starts at
## `authored_position + start_offset` and slides back to the authored
## position on reveal — overrides `bury_depth` (which is Y-only). Use
## for slide-in props that come in from any axis.
@export var start_offset: Vector3 = Vector3.ZERO
@export var reveal_duration: float = 0.5
@export var reveal_sound: AudioStream
## When true, the slide animation waits for the next Walkie line_ended after
## reveal_flag is set. Use when a triggering walkie line should play in full
## before the prop appears.
@export var reveal_after_walkie_line_ends: bool = false

var _target_pos: Vector3
var _parent: Node3D
# 0 = buried (waiting for flag), 1 = armed (flag set, awaiting line_ended),
# 2 = revealed.
var _state: int = 0


func _ready() -> void:
	_parent = get_parent() as Node3D
	if _parent == null:
		push_warning("BuriedReveal: parent is not Node3D — %s" % get_path())
		return
	_target_pos = _parent.global_position
	if reveal_flag != &"" and bool(GameState.get_flag(reveal_flag, false)):
		# Already revealed in a prior session — stay at authored position.
		_state = 2
		return
	var offset: Vector3 = start_offset if start_offset != Vector3.ZERO else Vector3(0.0, -bury_depth, 0.0)
	_parent.global_position = _target_pos + offset
	if reveal_flag != &"":
		Events.flag_set.connect(_on_flag_set)
	if reveal_after_walkie_line_ends:
		Walkie.line_ended.connect(_on_walkie_line_ended)


func _on_flag_set(id: StringName, value: Variant) -> void:
	if _state != 0: return
	if id != reveal_flag: return
	if not bool(value): return
	if reveal_after_walkie_line_ends:
		_state = 1  # arm; wait for next Walkie line_ended
	else:
		_reveal()


func _on_walkie_line_ended() -> void:
	if _state != 1: return
	_reveal()


func _reveal() -> void:
	_state = 2
	if reveal_sound != null:
		var sfx := AudioStreamPlayer3D.new()
		sfx.stream = reveal_sound
		sfx.bus = &"SFX"
		_parent.add_child(sfx)
		sfx.play()
		sfx.finished.connect(sfx.queue_free)
	var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(_parent, "global_position", _target_pos, reveal_duration)
