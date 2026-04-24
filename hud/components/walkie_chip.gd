extends Control

## Walkie-talkie inventory chip. Three states:
##   - hidden  : GameState.flags.walkie_talkie_owned is false
##   - idle    : owned, no line playing — dim emoji
##   - pulsing : a Walkie line is playing — bright + scale pulse
##
## Listens to Events.flag_set (for ownership) and Walkie.line_started /
## line_ended (for pulse).

@export var owned_flag: StringName = &"walkie_talkie_owned"
@export var idle_modulate: Color = Color(1, 1, 1, 0.55)
@export var active_modulate: Color = Color(0.55, 1, 0.65, 1)

@onready var _icon: Label = $Icon

var _pulse_tween: Tween


func _ready() -> void:
	_refresh_owned()
	Events.flag_set.connect(_on_flag_set)
	Walkie.line_started.connect(_on_line_started)
	Walkie.line_ended.connect(_on_line_ended)


func _on_flag_set(id: StringName, _value: Variant) -> void:
	if id == owned_flag:
		_refresh_owned()


func _refresh_owned() -> void:
	var owned: bool = bool(GameState.get_flag(owned_flag, false))
	visible = owned
	if owned:
		_icon.modulate = idle_modulate


func _on_line_started(_character: String, _text: String) -> void:
	if not visible:
		return
	_icon.modulate = active_modulate
	if _pulse_tween != null and _pulse_tween.is_valid():
		_pulse_tween.kill()
	_pulse_tween = create_tween().set_loops().set_trans(Tween.TRANS_SINE)
	_pulse_tween.tween_property(_icon, "scale", Vector2(1.15, 1.15), 0.35)
	_pulse_tween.tween_property(_icon, "scale", Vector2(1.0, 1.0), 0.35)


func _on_line_ended() -> void:
	if _pulse_tween != null and _pulse_tween.is_valid():
		_pulse_tween.kill()
	_icon.scale = Vector2.ONE
	_icon.modulate = idle_modulate
