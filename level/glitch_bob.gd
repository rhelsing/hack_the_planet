extends Node
class_name GlitchBob

## Procedural disco bob. Attach as a child of any Node3D — on _process the
## script writes the parent's local position + rotation each frame, tracing
## a rainbow arc with a slight dip + lean at the tips.
##
## Motion:
##   - x: pure sine, full side-to-side
##   - y: cos² (high at center, low at tips) + a sin⁴ "tip dip" so the
##     extremes drop slightly below baseline before reversing
##   - rotation.z: lean toward whichever side x is on (max at the tips)
##
## Defaults read as a small, gentle bop. Tune the four amplitudes + speed
## from the inspector.

@export_range(0.0, 5.0) var amplitude_x: float = 0.6
## Height of the rainbow apex above the tips (the "lift" at center).
@export_range(0.0, 2.0) var amplitude_y: float = 0.25
## Extra dip at the tips, below baseline. The "bump at the bottom" of the rainbow.
@export_range(0.0, 1.0) var tip_dip: float = 0.08
## Maximum tilt at the tips (radians). 0 = no lean.
@export_range(0.0, 1.0) var lean_radians: float = 0.18
## Beat speed in radians/sec. ~2.5 ≈ 24 BPM full cycle, disco-ish bop.
@export_range(0.1, 10.0) var speed: float = 2.5

var _base_position: Vector3
var _base_rotation: Vector3
var _target: Node3D
var _t: float = 0.0


func _ready() -> void:
	_target = get_parent() as Node3D
	if _target == null:
		push_warning("GlitchBob needs a Node3D parent (got %s)" % get_parent())
		set_process(false)
		return
	_base_position = _target.position
	_base_rotation = _target.rotation


func _process(delta: float) -> void:
	_t += delta * speed
	var s: float = sin(_t)
	var c: float = cos(_t)
	var x_off: float = amplitude_x * s
	var y_off: float = amplitude_y * c * c - tip_dip * pow(s, 4.0)
	_target.position = _base_position + Vector3(x_off, y_off, 0.0)
	_target.rotation = _base_rotation + Vector3(0.0, 0.0, -lean_radians * s)
