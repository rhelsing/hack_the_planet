extends CSGBox3D

## Vertical elevator platform. Rises, holds, falls, holds — repeating.
## Base Y is the bottom of the cycle; amplitude is the climb height.

@export var amplitude: float = 2.0
@export var rise_duration: float = 1.5
@export var peak_pause: float = 0.8
@export var fall_duration: float = 1.5
@export var trough_pause: float = 0.8
@export var phase_offset: float = 0.0

var _base_y: float = 0.0
var _t: float = 0.0


func _ready() -> void:
	_base_y = position.y


func _process(delta: float) -> void:
	_t += delta
	position.y = _base_y + _offset()


func _offset() -> float:
	var total: float = rise_duration + peak_pause + fall_duration + trough_pause
	if total <= 0.0:
		return 0.0
	var t: float = fposmod(_t + phase_offset * total, total)
	if t < rise_duration:
		return (1.0 - cos(PI * t / rise_duration)) * 0.5 * amplitude
	t -= rise_duration
	if t < peak_pause:
		return amplitude
	t -= peak_pause
	if t < fall_duration:
		return (1.0 + cos(PI * t / fall_duration)) * 0.5 * amplitude
	return 0.0
