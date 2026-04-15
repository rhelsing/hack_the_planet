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
var _prev_skin_yaw := 0.0
var _prev_h_vel := Vector3.ZERO
var _current_lean_pitch := 0.0
var _current_lean_roll := 0.0
var _natural_lean_roll := 0.0
var _speedup_timer := 999.0
var _was_moving := false
var _brake_impulse := 0.0
var _was_pressing_forward := false
var _wall_ride_active := false
var _wall_ride_timer := 0.0
var _wall_normal := Vector3.ZERO
var _grinding := false
var _grind_rail: Path3D = null
var _grind_progress := 0.0
var _grind_direction := 1.0
var _grind_snap_t := 1.0
var _grind_start_pos := Vector3.ZERO

@onready var _last_input_direction := global_basis.z
@onready var _start_position := global_position

@onready var _camera_pivot: Node3D = %CameraPivot
@onready var _camera: Camera3D = %Camera3D
@onready var _skin: SophiaSkin = %SophiaSkin
@onready var _landing_sound: AudioStreamPlayer3D = %LandingSound
@onready var _jump_sound: AudioStreamPlayer3D = %JumpSound
@onready var _dust_particles: GPUParticles3D = %DustParticles


func _ready() -> void:
	_current_profile = skate_profile if skate_profile != null else walk_profile
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
	Events.rail_touched.connect(_on_rail_touched)
	Events.checkpoint_reached.connect(_on_checkpoint_reached)
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


func _on_rail_touched(rail: Node, body: Node) -> void:
	if body != self or _grinding:
		return
	var profile: MovementProfile = _current_profile
	if profile == null or profile.grind_speed <= 0.0:
		return
	_grind_rail = rail as Path3D
	_grind_progress = _grind_rail.closest_progress(global_position)
	# Pick direction: compare player's velocity to the curve tangent at the entry
	# point. If they disagree, grind backward along the curve.
	var pf: PathFollow3D = _grind_rail.get_node_or_null("PathFollow3D") as PathFollow3D
	_grind_direction = 1.0
	if pf != null:
		pf.progress = _grind_progress
		var tangent: Vector3 = -pf.global_transform.basis.z
		var h_vel: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
		if h_vel.length() > 0.1 and h_vel.dot(tangent) < 0.0:
			_grind_direction = -1.0
	_grinding = true
	_grind_snap_t = 0.0
	_grind_start_pos = global_position
	_natural_lean_roll = 0.0
	_skin.idle()


func _on_checkpoint_reached(pos: Vector3) -> void:
	_start_position = pos


func _physics_process(delta: float) -> void:
	var profile := _current_profile

	if _grinding:
		_update_grind(delta, profile)
		_update_follow_camera(delta)
		return

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
	var new_yaw: float = lerp_angle(_skin.rotation.y, target_angle, profile.rotation_speed * delta)

	# Body lean: forward tilt scales with speed; side roll scales with
	# angular turn rate × speed (centripetal force feel).
	var d_yaw: float = wrapf(new_yaw - _prev_skin_yaw, -PI, PI) / max(delta, 0.0001)
	_prev_skin_yaw = new_yaw
	_prev_h_vel = h_vel
	var speed: float = h_vel.length()
	# Startup sway: side-to-side rocking for the first couple seconds of motion.
	var is_moving: bool = speed > 0.5
	if is_moving and not _was_moving:
		_speedup_timer = 0.0
	if is_moving:
		_speedup_timer += delta
	_was_moving = is_moving
	var speedup_roll := 0.0
	if is_moving and _speedup_timer < profile.speedup_duration:
		var t: float = _speedup_timer / max(profile.speedup_duration, 0.001)
		var decay: float = 1.0 - t
		speedup_roll = profile.speedup_amplitude * sin(TAU * profile.speedup_frequency * _speedup_timer) * decay
	# Kill the sway while airborne so jumps read clean.
	if not is_on_floor():
		speedup_roll = 0.0
	var target_pitch: float = clamp(-speed * profile.forward_lean_amount, -0.6, 0.6)
	# Smooth the lean/centripetal components only. Sway is applied unsmoothed
	# on top so the oscillation isn't damped out by lean_smoothing.
	var centripetal_roll: float = clamp(-d_yaw * speed * profile.side_lean_amount, -0.6, 0.6)
	var lean_factor := 1.0 - exp(-profile.lean_smoothing * delta)
	_current_lean_pitch = lerp(_current_lean_pitch, target_pitch, lean_factor)
	_current_lean_roll = lerp(_current_lean_roll, centripetal_roll, lean_factor)

	# Brake impulse: fire a one-shot reversed-lean the instant forward is
	# released at speed; exp-decay back to zero.
	var pressing_forward: bool = raw_input.y < -0.2
	if _was_pressing_forward and not pressing_forward and speed > 1.0:
		_brake_impulse = profile.brake_impulse_amount
	_was_pressing_forward = pressing_forward
	_brake_impulse = lerp(_brake_impulse, 0.0, 1.0 - exp(-profile.brake_impulse_decay * delta))

	var final_pitch: float = _current_lean_pitch + _brake_impulse
	var final_roll: float = _current_lean_roll + speedup_roll

	# Rotate the skin around a head-height pivot: the basis holds yaw+pitch+roll,
	# and we shift the skin's origin so the pivot point stays fixed in space.
	var pivot: Vector3 = Vector3(0, profile.lean_pivot_height, 0)
	var tilt_basis: Basis = Basis(Vector3.RIGHT, final_pitch) * Basis(Vector3.BACK, final_roll)
	var full_basis: Basis = Basis(Vector3.UP, new_yaw) * tilt_basis
	var origin_offset: Vector3 = pivot - full_basis * pivot
	var tilt_magnitude: float = sqrt(final_pitch * final_pitch + final_roll * final_roll)
	origin_offset.y -= tilt_magnitude * profile.tilt_height_drop
	_skin.transform = Transform3D(full_basis, origin_offset)

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

	# Wall ride (only runs if the current profile enables it).
	if profile.wall_ride_duration > 0.0:
		_update_wall_ride(delta, profile)

	_was_on_floor_last_frame = on_floor
	move_and_slide()

	_update_follow_camera(delta)


func _update_grind(delta: float, profile: MovementProfile) -> void:
	if _grind_rail == null or not is_instance_valid(_grind_rail):
		_grinding = false
		return
	var pf: PathFollow3D = _grind_rail.get_node_or_null("PathFollow3D") as PathFollow3D
	if pf == null or _grind_rail.curve == null:
		_grinding = false
		return
	_grind_progress += profile.grind_speed * _grind_direction * delta
	var length: float = _grind_rail.curve.get_baked_length()
	var exit_end: bool = _grind_progress >= length or _grind_progress <= 0.0
	var jumped: bool = Input.is_action_just_pressed("jump")
	pf.progress = clamp(_grind_progress, 0.0, length)
	# Smoothly lerp the character onto the rail over ~0.2s instead of snapping.
	# Ease-out curve so the approach feels smooth, not abrupt at the end.
	_grind_snap_t = minf(_grind_snap_t + delta / 0.35, 1.0)
	var eased: float = 1.0 - pow(1.0 - _grind_snap_t, 3.0)
	global_position = _grind_start_pos.lerp(pf.global_position, eased)
	var tangent: Vector3 = -pf.global_transform.basis.z * _grind_direction
	velocity = tangent * profile.grind_speed
	# Track curvature in rail-direction space (independent of the body's
	# sideways offset) so banking keys off the actual rail bend, not body yaw.
	var tangent_yaw: float = Vector3.BACK.signed_angle_to(tangent, Vector3.UP)
	var d_yaw: float = wrapf(tangent_yaw - _prev_skin_yaw, -PI, PI) / max(delta, 0.0001)
	_prev_skin_yaw = tangent_yaw
	# Natural centripetal lean — smoothed in its own tracked variable so the
	# counter input (applied later) can't artificially push us past the fall
	# threshold or mask a real fall.
	var centripetal: float = d_yaw * profile.grind_speed * profile.side_lean_amount * profile.grind_lean_multiplier
	var lean_factor: float = 1.0 - exp(-profile.lean_smoothing * delta)
	_natural_lean_roll = lerp(_natural_lean_roll, centripetal, lean_factor)
	_current_lean_pitch = lerp(_current_lean_pitch, 0.0, lean_factor)

	# Fall only when the smoothed NATURAL lean exceeds the threshold
	# (counter input is ignored for this check).
	if absf(_natural_lean_roll) > profile.grind_fall_threshold:
		_grinding = false
		_grind_rail = null
		velocity.y += 2.0
		return

	# Player counter-balance integrates over time, producing the combined roll.
	var raw_input := Input.get_vector("move_left", "move_right", "move_up", "move_down", 0.2)
	_current_lean_roll = clamp(_natural_lean_roll - raw_input.x * profile.grind_counter_strength * delta, -1.5, 1.5)


	# Build orientation: 1) face rail direction, 2) bank around rail tangent,
	# 3) rotate sideways around banked up (skater-style body offset).
	var rail_frame: Basis = Basis(Vector3.UP, tangent_yaw)
	var rail_forward: Vector3 = rail_frame * Vector3.FORWARD
	var banked: Basis = Basis(rail_forward, _current_lean_roll) * rail_frame
	var body_up: Vector3 = banked * Vector3.UP
	var full_basis: Basis = Basis(body_up, deg_to_rad(profile.grind_yaw_offset_deg)) * banked
	# Feet pivot so the body rotates like someone actually balancing on the rail.
	_skin.transform = Transform3D(full_basis, Vector3.ZERO)
	# Drive move_and_slide so render interpolation smooths visuals between ticks.
	move_and_slide()
	# Once snapped on, keep locked to the curve. During the entry lerp we let
	# the interpolated position win so the approach is smooth.
	if _grind_snap_t >= 1.0:
		global_position = pf.global_position
	if exit_end or jumped:
		if jumped:
			velocity += Vector3.UP * (profile.jump_impulse + profile.grind_exit_boost)
		_grinding = false
		_grind_rail = null


func _update_wall_ride(delta: float, profile: MovementProfile) -> void:
	var horizontal_speed: float = Vector2(velocity.x, velocity.z).length()

	if _wall_ride_active:
		_wall_ride_timer += delta
		var detected: Vector3 = _find_wall(profile)
		var lost_contact: bool = detected == Vector3.ZERO
		var too_slow: bool = horizontal_speed < profile.wall_ride_min_speed * 0.5
		var expired: bool = _wall_ride_timer >= profile.wall_ride_duration
		var jumped: bool = Input.is_action_just_pressed("jump")
		if lost_contact or too_slow or expired or jumped:
			if jumped:
				velocity += _wall_normal * profile.wall_ride_jump_push
				velocity.y = profile.jump_impulse
			_wall_ride_active = false
			return
		_wall_normal = detected
		# Scale gravity (we undo the physics_process gravity for this frame and
		# re-apply the scaled version).
		velocity.y -= _gravity * delta
		velocity.y += _gravity * profile.wall_ride_gravity_scale * delta
		# Strip any velocity component pushing into the wall so we slide along it.
		var into_wall: float = velocity.dot(_wall_normal)
		if into_wall < 0.0:
			velocity -= _wall_normal * into_wall
	else:
		if is_on_floor():
			return
		if horizontal_speed < profile.wall_ride_min_speed:
			return
		var detected: Vector3 = _find_wall(profile)
		if detected != Vector3.ZERO:
			_wall_ride_active = true
			_wall_ride_timer = 0.0
			_wall_normal = detected


func _find_wall(profile: MovementProfile) -> Vector3:
	var h_vel := Vector3(velocity.x, 0.0, velocity.z)
	if h_vel.length() < 0.1:
		return Vector3.ZERO
	var forward: Vector3 = h_vel.normalized()
	var right: Vector3 = forward.cross(Vector3.UP).normalized()
	var space := get_world_3d().direct_space_state
	var from: Vector3 = global_position + Vector3(0, 1.0, 0)
	for side: Vector3 in [right, -right]:
		var query := PhysicsRayQueryParameters3D.create(from, from + side * profile.wall_ride_reach)
		query.exclude = [self.get_rid()]
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty():
			var n: Vector3 = hit["normal"]
			var max_normal_y: float = sin(deg_to_rad(profile.wall_ride_max_tilt_deg))
			if absf(n.y) < max_normal_y:
				return n
	return Vector3.ZERO


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
			follow_mode = FollowMode.PARENTED if v == 0 else FollowMode.DETACHED
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
	if walk_profile != null:
		DebugPanel.add_slider("Skin/Lean/walk/forward", -0.5, 0.5, 0.005,
			func() -> float: return walk_profile.forward_lean_amount,
			func(v: float) -> void: walk_profile.forward_lean_amount = v)
		DebugPanel.add_slider("Skin/Lean/walk/side", -0.15, 0.15, 0.001,
			func() -> float: return walk_profile.side_lean_amount,
			func(v: float) -> void: walk_profile.side_lean_amount = v)
		DebugPanel.add_slider("Skin/Lean/walk/smoothing", 0.5, 20.0, 0.1,
			func() -> float: return walk_profile.lean_smoothing,
			func(v: float) -> void: walk_profile.lean_smoothing = v)
	if skate_profile != null:
		DebugPanel.add_slider("Movement/skate/max_speed", 1.0, 30.0, 0.1,
			func() -> float: return skate_profile.max_speed,
			func(v: float) -> void: skate_profile.max_speed = v)
		DebugPanel.add_slider("Movement/skate/accel", 0.5, 100.0, 0.5,
			func() -> float: return skate_profile.accel,
			func(v: float) -> void: skate_profile.accel = v)
		DebugPanel.add_slider("Movement/skate/friction", 0.0, 60.0, 0.5,
			func() -> float: return skate_profile.friction,
			func(v: float) -> void: skate_profile.friction = v)
		DebugPanel.add_slider("Movement/skate/air_accel_mult", 0.0, 1.0, 0.02,
			func() -> float: return skate_profile.air_accel_mult,
			func(v: float) -> void: skate_profile.air_accel_mult = v)
		DebugPanel.add_slider("Movement/skate/turn_rate", 0.5, 50.0, 0.1,
			func() -> float: return skate_profile.turn_rate,
			func(v: float) -> void: skate_profile.turn_rate = v)
		DebugPanel.add_slider("Movement/skate/jump_impulse", 1.0, 30.0, 0.25,
			func() -> float: return skate_profile.jump_impulse,
			func(v: float) -> void: skate_profile.jump_impulse = v)
		DebugPanel.add_slider("Movement/skate/rotation_speed", 0.5, 30.0, 0.25,
			func() -> float: return skate_profile.rotation_speed,
			func(v: float) -> void: skate_profile.rotation_speed = v)
		DebugPanel.add_slider("Movement/skate/stopping_speed", 0.0, 5.0, 0.05,
			func() -> float: return skate_profile.stopping_speed,
			func(v: float) -> void: skate_profile.stopping_speed = v)
		DebugPanel.add_toggle("Movement/skate/face_velocity",
			func() -> bool: return skate_profile.face_velocity,
			func(v: bool) -> void: skate_profile.face_velocity = v)
		DebugPanel.add_slider("Movement/skate/wall_ride_duration", 0.0, 5.0, 0.1,
			func() -> float: return skate_profile.wall_ride_duration,
			func(v: float) -> void: skate_profile.wall_ride_duration = v)
		DebugPanel.add_slider("Movement/skate/wall_ride_min_speed", 0.0, 20.0, 0.1,
			func() -> float: return skate_profile.wall_ride_min_speed,
			func(v: float) -> void: skate_profile.wall_ride_min_speed = v)
		DebugPanel.add_slider("Movement/skate/wall_ride_gravity", 0.0, 1.0, 0.05,
			func() -> float: return skate_profile.wall_ride_gravity_scale,
			func(v: float) -> void: skate_profile.wall_ride_gravity_scale = v)
		DebugPanel.add_slider("Movement/skate/wall_ride_reach", 0.3, 3.0, 0.05,
			func() -> float: return skate_profile.wall_ride_reach,
			func(v: float) -> void: skate_profile.wall_ride_reach = v)
		DebugPanel.add_slider("Movement/skate/wall_ride_jump_push", 0.0, 40.0, 0.5,
			func() -> float: return skate_profile.wall_ride_jump_push,
			func(v: float) -> void: skate_profile.wall_ride_jump_push = v)
		DebugPanel.add_slider("Movement/skate/wall_ride_max_tilt_deg", 0.0, 90.0, 0.5,
			func() -> float: return skate_profile.wall_ride_max_tilt_deg,
			func(v: float) -> void: skate_profile.wall_ride_max_tilt_deg = v)
		DebugPanel.add_slider("Movement/skate/grind_speed", 0.0, 30.0, 0.25,
			func() -> float: return skate_profile.grind_speed,
			func(v: float) -> void: skate_profile.grind_speed = v)
		DebugPanel.add_slider("Movement/skate/grind_exit_boost", 0.0, 15.0, 0.25,
			func() -> float: return skate_profile.grind_exit_boost,
			func(v: float) -> void: skate_profile.grind_exit_boost = v)
		DebugPanel.add_slider("Movement/skate/grind_yaw_offset_deg", -90.0, 90.0, 1.0,
			func() -> float: return skate_profile.grind_yaw_offset_deg,
			func(v: float) -> void: skate_profile.grind_yaw_offset_deg = v)
		DebugPanel.add_slider("Movement/skate/grind_counter_strength", 0.0, 10.0, 0.1,
			func() -> float: return skate_profile.grind_counter_strength,
			func(v: float) -> void: skate_profile.grind_counter_strength = v)
		DebugPanel.add_slider("Movement/skate/grind_fall_threshold", 0.1, 12.0, 0.1,
			func() -> float: return skate_profile.grind_fall_threshold,
			func(v: float) -> void: skate_profile.grind_fall_threshold = v)
		DebugPanel.add_slider("Movement/skate/grind_lean_multiplier", 0.0, 10.0, 0.1,
			func() -> float: return skate_profile.grind_lean_multiplier,
			func(v: float) -> void: skate_profile.grind_lean_multiplier = v)
		DebugPanel.add_slider("Skin/Sway/skate/duration", 0.0, 5.0, 0.1,
			func() -> float: return skate_profile.speedup_duration,
			func(v: float) -> void: skate_profile.speedup_duration = v)
		DebugPanel.add_slider("Skin/Sway/skate/amplitude", 0.0, 0.5, 0.005,
			func() -> float: return skate_profile.speedup_amplitude,
			func(v: float) -> void: skate_profile.speedup_amplitude = v)
		DebugPanel.add_slider("Skin/Sway/skate/frequency", 0.2, 8.0, 0.1,
			func() -> float: return skate_profile.speedup_frequency,
			func(v: float) -> void: skate_profile.speedup_frequency = v)
		DebugPanel.add_slider("Skin/Sway/skate/pivot_height", 0.0, 3.0, 0.05,
			func() -> float: return skate_profile.lean_pivot_height,
			func(v: float) -> void: skate_profile.lean_pivot_height = v)
	if walk_profile != null:
		DebugPanel.add_slider("Skin/Lean/walk/tilt_height_drop", 0.0, 2.0, 0.02,
			func() -> float: return walk_profile.tilt_height_drop,
			func(v: float) -> void: walk_profile.tilt_height_drop = v)
	if skate_profile != null:
		DebugPanel.add_slider("Skin/Lean/skate/tilt_height_drop", 0.0, 2.0, 0.02,
			func() -> float: return skate_profile.tilt_height_drop,
			func(v: float) -> void: skate_profile.tilt_height_drop = v)
		DebugPanel.add_slider("Skin/Lean/skate/brake_impulse", -0.6, 0.6, 0.02,
			func() -> float: return skate_profile.brake_impulse_amount,
			func(v: float) -> void: skate_profile.brake_impulse_amount = v)
		DebugPanel.add_slider("Skin/Lean/skate/brake_decay", 0.5, 15.0, 0.1,
			func() -> float: return skate_profile.brake_impulse_decay,
			func(v: float) -> void: skate_profile.brake_impulse_decay = v)
		DebugPanel.add_slider("Skin/Lean/skate/forward", -0.5, 0.5, 0.005,
			func() -> float: return skate_profile.forward_lean_amount,
			func(v: float) -> void: skate_profile.forward_lean_amount = v)
		DebugPanel.add_slider("Skin/Lean/skate/side", -0.15, 0.15, 0.001,
			func() -> float: return skate_profile.side_lean_amount,
			func(v: float) -> void: skate_profile.side_lean_amount = v)
		DebugPanel.add_slider("Skin/Lean/skate/smoothing", 0.5, 20.0, 0.1,
			func() -> float: return skate_profile.lean_smoothing,
			func(v: float) -> void: skate_profile.lean_smoothing = v)
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
