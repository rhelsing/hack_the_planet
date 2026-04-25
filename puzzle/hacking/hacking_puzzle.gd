extends "res://puzzle/puzzle.gd"

## "Hacking" = rhythm-tap. A slider moves across the bar; press interact
## when the indicator is inside the target zone.
## - Hit: speed up, advance progress, zone teleports
## - Miss: slow down, regress progress
## - required_hits in zone = solved
## - no fail state in v1 (per designer spec)
## See docs/interactables.md §11.2.

@export var required_hits: int = 5
@export var zone_width_px: float = 140.0
@export var base_speed_px_s: float = 240.0
@export var speed_increase_per_hit: float = 90.0
@export var speed_decrease_per_miss: float = 60.0
@export var max_speed_px_s: float = 1200.0

var _hits: int = 0
var _speed: float = 0.0
var _direction: int = 1  # +1 right, -1 left; bounces at bar edges

@onready var _bar: Control = %Bar
@onready var _indicator: Control = %Indicator
@onready var _zone: Control = %TargetZone
@onready var _progress_label: Label = %ProgressLabel
@onready var _instructions: Label = %Instructions


func _ready() -> void:
	super._ready()
	# Substitute {interact} (or any glyph token) with the active controller's
	# label — keyboard "E", gamepad "Triangle", etc. Single source via Glyphs.
	_instructions.text = Glyphs.format(_instructions.text)
	_speed = base_speed_px_s
	_position_zone_randomly()
	_update_label()


func _process(delta: float) -> void:
	var new_x: float = _indicator.position.x + float(_direction) * _speed * delta
	if new_x <= 0.0:
		new_x = 0.0
		_direction = 1
	elif new_x + _indicator.size.x >= _bar.size.x:
		new_x = _bar.size.x - _indicator.size.x
		_direction = -1
	_indicator.position.x = new_x


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"interact"): return
	get_viewport().set_input_as_handled()
	if _indicator_in_zone():
		_on_hit()
	else:
		_on_miss()


func _indicator_in_zone() -> bool:
	var indicator_center_x: float = _indicator.position.x + _indicator.size.x * 0.5
	return (indicator_center_x >= _zone.position.x
			and indicator_center_x <= _zone.position.x + _zone.size.x)


func _on_hit() -> void:
	_hits += 1
	_speed = minf(_speed + speed_increase_per_hit, max_speed_px_s)
	_position_zone_randomly()
	_update_label()
	if _hits >= required_hits:
		_complete(true)


func _on_miss() -> void:
	_hits = maxi(_hits - 1, 0)
	_speed = maxf(_speed - speed_decrease_per_miss, base_speed_px_s)
	_position_zone_randomly()
	_update_label()


func _position_zone_randomly() -> void:
	var max_x: float = maxf(_bar.size.x - zone_width_px, 0.0)
	_zone.position.x = randf_range(0.0, max_x)
	_zone.size.x = zone_width_px


func _update_label() -> void:
	_progress_label.text = "%d / %d" % [_hits, required_hits]
