extends PathFollow3D
## Animates the rail-follower's progress_ratio on an infinite loop and adds a
## subtle noise-based idle wiggle to the child Camera3D. Pattern cribbed from
## meloonics/3D-Menu-Cam (docs/menus.md §5.1).

@export var loop_duration_s: float = 45.0
@export var wiggle_pos_amplitude: float = 0.03
@export var wiggle_rot_amplitude_deg: float = 0.5
@export var wiggle_frequency: float = 0.4

var _t: float = 0.0
var _noise: FastNoiseLite
var _camera: Camera3D
var _cam_base_pos: Vector3
var _cam_base_rot: Vector3


func _ready() -> void:
	loop = true
	cubic_interp = true
	# Keep the camera upright along the path. ROTATION_Y rotates only around
	# world-up so the camera still faces along the travel direction but never
	# pitches or rolls with the curve's tilt/twist. Use ROTATION_NONE if you
	# want the camera to keep a fixed orientation regardless of travel dir.
	rotation_mode = PathFollow3D.ROTATION_Y
	_noise = FastNoiseLite.new()
	_noise.seed = randi()
	_noise.frequency = wiggle_frequency
	for c in get_children():
		if c is Camera3D:
			_camera = c
			_cam_base_pos = c.position
			_cam_base_rot = c.rotation
			break


func _process(delta: float) -> void:
	_t += delta
	progress_ratio = fmod(_t / loop_duration_s, 1.0)
	if _camera == null:
		return
	var pos_offset := Vector3(
		_noise.get_noise_2d(_t * 1.0, 0.0),
		_noise.get_noise_2d(0.0, _t * 1.1),
		_noise.get_noise_2d(_t * 0.7, 5.5),
	) * wiggle_pos_amplitude
	_camera.position = _cam_base_pos + pos_offset
	var rot_offset := Vector3(
		_noise.get_noise_2d(_t * 0.9, 12.0),
		_noise.get_noise_2d(_t * 0.6, 37.0),
		0.0,
	) * deg_to_rad(wiggle_rot_amplitude_deg)
	_camera.rotation = _cam_base_rot + rot_offset
