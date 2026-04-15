extends CharacterBody3D

@export_group("Movement")
@export var walk_profile: MovementProfile
@export var skate_profile: MovementProfile

@export_group("Follow Camera")
enum FollowMode { PARENTED, DETACHED }
## PARENTED: pivot position snaps to player, only yaw lags. Responsive.
## DETACHED: pivot position also lags the player. Cinematic.
@export var follow_mode: FollowMode = FollowMode.DETACHED
## Local/world offset from player origin to pivot (roughly shoulder/head height).
@export var pivot_offset := Vector3(0.0, 1.0, 0.0)
## Lower = lazier yaw follow.
@export_range(0.0, 1.0) var angle_smoothing := 0.023
## Lower = lazier position follow (DETACHED only).
@export_range(0.0, 1.0) var position_smoothing := 0.122

@export_group("Mouse Look")
@export var mouse_x_sensitivity := 0.002
@export var mouse_y_sensitivity := 0.001
@export var invert_y := true
@export var pitch_min_deg := -75.0
@export var pitch_max_deg := 20.0
## Seconds of no mouse input before auto-follow re-engages.
@export var mouse_release_delay := 2.4
## Seconds to smoothly blend between manual and auto control.
@export var mouse_blend_time := 0.8
## Seconds of mouse idle before pitch begins returning to rest.
@export var pitch_return_delay := 0.3
## Exponential decay rate for pitch return. ~1.5 ≈ 95% back in 2 seconds.
@export var pitch_return_rate := 1.5

@export_group("Camera Occlusion")
## Smooths SpringArm's instant-snap output into an eased response.
## Higher = snappier. ~8 ≈ 95% in 0.37s.
@export var spring_smooth_rate := 8.0
## Minimum allowed camera distance along the arm (prevents it from collapsing
## into the character when something is right up against them).
@export var min_camera_distance := 1.5
## SpringArm buffer from hits (how far to stay off walls/props).
@export var spring_margin := 1.5
## Sphere radius used for the spring arm cast. Larger = gives the camera "more
## body" so it rounds corners earlier instead of threading thin obstacles.
@export var spring_cast_radius := 0.2


## Each frame, we find the height of the ground below the player and store it here.
## The camera uses this to keep a fixed height while the player jumps, for example.
var ground_height := 0.0

var _gravity := -30.0
var _was_on_floor_last_frame := true
var _current_profile: MovementProfile
var _target_yaw := 0.0
var _time_since_mouse_input := 999.0
var _manual_weight := 0.0
var _spring: SpringArm3D
var _base_pitch := 0.0
var _camera_original_z := 0.0
var _current_camera_z := 0.0

@onready var _last_input_direction := global_basis.z
@onready var _start_position := global_position

@onready var _camera_pivot: Node3D = %CameraPivot
@onready var _camera: Camera3D = %Camera3D
@onready var _skin: SophiaSkin = %SophiaSkin
@onready var _landing_sound: AudioStreamPlayer3D = %LandingSound
@onready var _jump_sound: AudioStreamPlayer3D = %JumpSound
@onready var _dust_particles: GPUParticles3D = %DustParticles


func _ready() -> void:
	_current_profile = walk_profile if walk_profile != null else skate_profile
	_apply_follow_mode()
	_target_yaw = _camera_pivot.global_rotation.y
	_spring = _camera_pivot.get_node("SpringArm3D")
	_base_pitch = _spring.rotation.x
	_camera_original_z = _camera.position.z
	_current_camera_z = _camera_original_z
	# Replace the SeparationRayShape3D (meant for character floor separation)
	# with a sphere so margin acts as a real physical buffer around obstacles.
	var sphere := SphereShape3D.new()
	sphere.radius = spring_cast_radius
	_spring.shape = sphere
	_spring.margin = spring_margin
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_register_debug_panel()
	Events.kill_plane_touched.connect(func on_kill_plane_touched() -> void:
		global_position = _start_position
		velocity = Vector3.ZERO
		_skin.idle()
		_snap_camera_to_player()
		set_physics_process(true)
	)
	Events.flag_reached.connect(func on_flag_reached() -> void:
		set_physics_process(false)
		_skin.idle()
		_dust_particles.emitting = false
	)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if event.relative.length() > 0.01:
			_time_since_mouse_input = 0.0
		_camera_pivot.rotation.y -= event.relative.x * mouse_x_sensitivity
		var spring: SpringArm3D = _camera_pivot.get_node("SpringArm3D")
		var y_sign := -1.0 if invert_y else 1.0
		var new_pitch: float = spring.rotation.x + event.relative.y * mouse_y_sensitivity * y_sign
		spring.rotation.x = clamp(new_pitch, deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_skate"):
		if _current_profile == skate_profile and walk_profile != null:
			_current_profile = walk_profile
		elif skate_profile != null:
			_current_profile = skate_profile
	elif event.is_action_pressed("toggle_follow_mode"):
		follow_mode = FollowMode.DETACHED if follow_mode == FollowMode.PARENTED else FollowMode.PARENTED
		_apply_follow_mode()


func _apply_follow_mode() -> void:
	_camera_pivot.top_level = (follow_mode == FollowMode.DETACHED)
	_snap_camera_to_player()


func _snap_camera_to_player() -> void:
	if follow_mode == FollowMode.DETACHED:
		_camera_pivot.global_position = global_position + pivot_offset
	else:
		_camera_pivot.position = pivot_offset


func _physics_process(delta: float) -> void:
	var profile := _current_profile

	# Input direction is based on current camera yaw — camera is follow-driven
	# so this naturally aligns with the direction of travel.
	var raw_input := Input.get_vector("move_left", "move_right", "move_up", "move_down", 0.4)
	var forward := _camera.global_basis.z
	var right := _camera.global_basis.x
	var move_direction := forward * raw_input.y + right * raw_input.x
	move_direction.y = 0.0
	move_direction = move_direction.normalized()

	if move_direction.length() > 0.2:
		_last_input_direction = move_direction.normalized()

	# Skin facing.
	var h_vel := Vector3(velocity.x, 0.0, velocity.z)
	var face_target := _last_input_direction
	if profile.face_velocity and h_vel.length() > 0.5:
		face_target = h_vel.normalized()
	var target_angle := Vector3.BACK.signed_angle_to(face_target, Vector3.UP)
	_skin.global_rotation.y = lerp_angle(_skin.rotation.y, target_angle, profile.rotation_speed * delta)

	# Horizontal movement.
	var y_velocity := velocity.y
	var on_floor := is_on_floor()
	var air_mult := 1.0 if on_floor else profile.air_accel_mult
	var accel_now := profile.accel * air_mult
	var friction_now := profile.friction * air_mult

	if move_direction.length() > 0.01:
		var h_dir := h_vel.normalized() if h_vel.length() > 0.1 else move_direction
		var steered := h_dir.slerp(move_direction, clamp(profile.turn_rate * delta, 0.0, 1.0))
		var target_vel := steered * profile.max_speed
		h_vel = h_vel.move_toward(target_vel, accel_now * delta)
	else:
		h_vel = h_vel.move_toward(Vector3.ZERO, friction_now * delta)
		if profile.stopping_speed > 0.0 and h_vel.length_squared() < profile.stopping_speed * profile.stopping_speed:
			h_vel = Vector3.ZERO

	velocity = Vector3(h_vel.x, y_velocity + _gravity * delta, h_vel.z)

	# Animations and FX.
	var ground_speed := Vector2(velocity.x, velocity.z).length()
	var is_just_jumping := Input.is_action_just_pressed("jump") and on_floor
	if is_just_jumping:
		velocity.y += profile.jump_impulse
		_skin.jump()
		_jump_sound.play()
	elif not on_floor and velocity.y < 0:
		_skin.fall()
	elif on_floor:
		if ground_speed > 0.0:
			_skin.move()
		else:
			_skin.idle()

	_dust_particles.emitting = on_floor && ground_speed > 0.0

	if on_floor and not _was_on_floor_last_frame:
		_landing_sound.play()

	_was_on_floor_last_frame = on_floor
	move_and_slide()

	_update_follow_camera(delta)


func _process(delta: float) -> void:
	# Smooth SpringArm's snap. SpringArm scales the camera's positive local Z by
	# (hit_length / spring_length) each physics tick; we lerp toward that same
	# scaled target and write it back in _process so ours is the final write.
	if _spring == null or _camera == null:
		return
	if _spring.spring_length <= 0.0:
		return
	var motion_delta: float = clamp(_spring.get_hit_length() / _spring.spring_length, 0.0, 1.0)
	var target_z: float = max(_camera_original_z * motion_delta, min_camera_distance)
	var factor := 1.0 - exp(-spring_smooth_rate * delta)
	_current_camera_z = lerp(_current_camera_z, target_z, factor)
	_camera.position.z = _current_camera_z


func _register_debug_panel() -> void:
	DebugPanel.add_enum("Camera/Follow/mode", PackedStringArray(["PARENTED", "DETACHED"]),
		func() -> int: return int(follow_mode),
		func(v: int) -> void:
			follow_mode = v
			_apply_follow_mode())
	DebugPanel.add_slider("Camera/Follow/angle_smoothing", 0.001, 0.3, 0.001,
		func() -> float: return angle_smoothing,
		func(v: float) -> void: angle_smoothing = v)
	DebugPanel.add_slider("Camera/Follow/position_smoothing", 0.001, 0.3, 0.001,
		func() -> float: return position_smoothing,
		func(v: float) -> void: position_smoothing = v)
	DebugPanel.add_slider("Camera/Follow/pivot_offset_y", 0.0, 5.0, 0.05,
		func() -> float: return pivot_offset.y,
		func(v: float) -> void:
			var o := pivot_offset
			o.y = v
			pivot_offset = o)
	DebugPanel.add_slider("Camera/SpringArm/length", 1.0, 25.0, 0.1,
		func() -> float: return _spring.spring_length,
		func(v: float) -> void: _spring.spring_length = v)
	DebugPanel.add_slider("Camera/SpringArm/smooth_rate", 0.5, 30.0, 0.1,
		func() -> float: return spring_smooth_rate,
		func(v: float) -> void: spring_smooth_rate = v)
	DebugPanel.add_slider("Camera/SpringArm/margin", 0.0, 3.0, 0.05,
		func() -> float: return _spring.margin,
		func(v: float) -> void:
			_spring.margin = v
			spring_margin = v)
	DebugPanel.add_slider("Camera/SpringArm/cast_radius", 0.05, 1.0, 0.05,
		func() -> float: return spring_cast_radius,
		func(v: float) -> void:
			spring_cast_radius = v
			if _spring.shape is SphereShape3D:
				(_spring.shape as SphereShape3D).radius = v)
	DebugPanel.add_slider("Camera/SpringArm/min_distance", 0.0, 10.0, 0.1,
		func() -> float: return min_camera_distance,
		func(v: float) -> void: min_camera_distance = v)
	DebugPanel.add_slider("Camera/SpringArm/base_pitch_deg", -60.0, 10.0, 0.5,
		func() -> float: return rad_to_deg(_base_pitch),
		func(v: float) -> void: _base_pitch = deg_to_rad(v))
	DebugPanel.add_slider("Camera/Mouse/pitch_return_delay", 0.0, 3.0, 0.05,
		func() -> float: return pitch_return_delay,
		func(v: float) -> void: pitch_return_delay = v)
	DebugPanel.add_slider("Camera/Mouse/pitch_return_rate", 0.1, 10.0, 0.1,
		func() -> float: return pitch_return_rate,
		func(v: float) -> void: pitch_return_rate = v)
	DebugPanel.add_slider("Camera/Camera3D/fov", 30.0, 110.0, 1.0,
		func() -> float: return _camera.fov,
		func(v: float) -> void: _camera.fov = v)
	DebugPanel.add_slider("Camera/Mouse/x_sensitivity", 0.0, 0.02, 0.0005,
		func() -> float: return mouse_x_sensitivity,
		func(v: float) -> void: mouse_x_sensitivity = v)
	DebugPanel.add_slider("Camera/Mouse/y_sensitivity", 0.0, 0.02, 0.0005,
		func() -> float: return mouse_y_sensitivity,
		func(v: float) -> void: mouse_y_sensitivity = v)
	DebugPanel.add_toggle("Camera/Mouse/invert_y",
		func() -> bool: return invert_y,
		func(v: bool) -> void: invert_y = v)
	DebugPanel.add_slider("Camera/Mouse/release_delay", 0.0, 5.0, 0.1,
		func() -> float: return mouse_release_delay,
		func(v: float) -> void: mouse_release_delay = v)
	DebugPanel.add_slider("Camera/Mouse/blend_time", 0.0, 2.0, 0.05,
		func() -> float: return mouse_blend_time,
		func(v: float) -> void: mouse_blend_time = v)
	DebugPanel.add_readout("Debug/h_speed",
		func() -> String: return "%.1f m/s" % Vector2(velocity.x, velocity.z).length())


func _update_follow_camera(delta: float) -> void:
	# Track mouse activity: ramp manual weight up on active input, down after release delay.
	_time_since_mouse_input += delta
	var target_weight: float = 1.0 if _time_since_mouse_input < mouse_release_delay else 0.0
	var blend_factor := 1.0 - exp(-delta / max(mouse_blend_time, 0.001))
	_manual_weight = lerp(_manual_weight, target_weight, blend_factor)

	# Pitch returns only while the character is moving — stopped, it stays where aimed.
	var h_vel_for_pitch := Vector3(velocity.x, 0.0, velocity.z)
	if h_vel_for_pitch.length() > 0.5 and _time_since_mouse_input > pitch_return_delay:
		var pitch_factor := 1.0 - exp(-pitch_return_rate * delta)
		_spring.rotation.x = lerp_angle(_spring.rotation.x, _base_pitch, pitch_factor)

	# Drive camera yaw to sit behind the player's horizontal motion —
	# but only while actually moving, so stopped the camera stays where the player put it.
	var h_vel := Vector3(velocity.x, 0.0, velocity.z)
	if h_vel.length() > 0.5:
		_target_yaw = atan2(h_vel.x, h_vel.z)
		var yaw_factor := (1.0 - exp(-angle_smoothing * 60.0 * delta)) * (1.0 - _manual_weight)
		_camera_pivot.global_rotation.y = lerp_angle(_camera_pivot.global_rotation.y, _target_yaw, yaw_factor)

	if follow_mode == FollowMode.DETACHED:
		var target_pos := global_position + pivot_offset
		var pos_factor := 1.0 - exp(-position_smoothing * 60.0 * delta)
		_camera_pivot.global_position = _camera_pivot.global_position.lerp(target_pos, pos_factor)
