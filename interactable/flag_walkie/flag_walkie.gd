extends Node
class_name FlagWalkie

## Drop in any scene; fires `Walkie.speak(character, line)` the moment
## `trigger_flag` becomes true on GameState. One-shot by default. Use for
## "the moment X happens, this character pipes up" beats — e.g. Glitch's
## "try it out then talk to me" right after a puzzle solves.

@export var character: StringName = &"DialTone"
@export_multiline var line: String = ""
@export var trigger_flag: StringName = &""
@export var fire_once: bool = true

var _fired: bool = false


func _ready() -> void:
	if trigger_flag == &"":
		return
	# Already past this beat — don't re-fire on level reload after a save.
	if bool(GameState.get_flag(trigger_flag, false)):
		_fired = true
		return
	Events.flag_set.connect(_on_flag_set)


func _on_flag_set(id: StringName, value: Variant) -> void:
	if _fired and fire_once: return
	if id != trigger_flag: return
	if not bool(value): return
	if line.strip_edges().is_empty():
		push_warning("FlagWalkie: empty line — %s" % get_path())
		return
	_fired = true
	Walkie.speak(String(character), line)
