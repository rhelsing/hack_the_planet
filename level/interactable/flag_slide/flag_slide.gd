extends Node
class_name FlagSlide

## Tweens its parent Node3D by `slide_offset` over `slide_duration` when
## `trigger_flag` becomes true on GameState. If
## `wait_for_walkie_line_ends` is true, arms on the flag-set and waits for
## the next Walkie.line_ended before sliding — so a triggering walkie line
## reads in full first. Idempotent across reloads: if the flag is already
## true at _ready, the parent jumps straight to the post-slide position
## (no animation, no sound).
##
## Use cases: bridges that retract after a beat, walls that drop, props
## that animate in/out tied to narrative flags.

@export var trigger_flag: StringName = &""
@export var slide_offset: Vector3 = Vector3(0.0, -20.0, 0.0)
@export var slide_duration: float = 1.0
@export var slide_sound: AudioStream
## When true, the slide animation waits for the next Walkie.line_ended
## after the trigger_flag is set. Use when a walkie line should finish
## before the prop moves.
@export var wait_for_walkie_line_ends: bool = false

var _start_pos: Vector3
var _end_pos: Vector3
var _parent: Node3D
# 0 = idle (waiting for flag), 1 = armed (flag set, waiting for walkie),
# 2 = slid.
var _state: int = 0


func _ready() -> void:
	_parent = get_parent() as Node3D
	if _parent == null:
		push_warning("FlagSlide: parent is not Node3D — %s" % get_path())
		return
	_start_pos = _parent.global_position
	_end_pos = _start_pos + slide_offset
	if trigger_flag != &"" and bool(GameState.get_flag(trigger_flag, false)):
		# Already past this beat — snap to the post-slide position.
		_parent.global_position = _end_pos
		_state = 2
		return
	if trigger_flag != &"":
		Events.flag_set.connect(_on_flag_set)
	if wait_for_walkie_line_ends:
		Walkie.line_ended.connect(_on_walkie_line_ended)


func _on_flag_set(id: StringName, value: Variant) -> void:
	if _state != 0: return
	if id != trigger_flag: return
	if not bool(value): return
	if wait_for_walkie_line_ends:
		_state = 1  # arm; wait for next Walkie line_ended
	else:
		_slide()


func _on_walkie_line_ended() -> void:
	if _state != 1: return
	_slide()


func _slide() -> void:
	_state = 2
	if slide_sound != null:
		var sfx := AudioStreamPlayer3D.new()
		sfx.stream = slide_sound
		sfx.bus = &"SFX"
		_parent.add_child(sfx)
		sfx.play()
		sfx.finished.connect(sfx.queue_free)
	var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_parent, "global_position", _end_pos, slide_duration)
