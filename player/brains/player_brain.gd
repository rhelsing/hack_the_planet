class_name PlayerBrain
extends Brain

## Human input driver. Reads Input + mouse, converts the 2D movement axis to
## a world-space direction using the camera's yaw, and writes the result into
## an Intent consumed by the body. Also owns player-only conveniences: mouse
## look, skate/walk profile toggle, follow-mode toggle, cursor capture.
##
## Camera/spring/pivot references are exported so the brain can be used with
## any body that wires them up in its scene. AI brains won't have these —
## they just ignore camera entirely.

## Paths to the body's camera rig, relative to this brain's parent (the body).
## Exposed as NodePaths rather than typed node exports so the tscn serialization
## is unambiguous — typed node exports require editor drag-and-drop to resolve
## correctly, which breaks when the tscn is hand-edited.
@export var camera_path: NodePath = "CameraPivot/SpringArm3D/Camera3D"
@export var camera_pivot_path: NodePath = "CameraPivot"
@export var spring_arm_path: NodePath = "CameraPivot/SpringArm3D"

var camera: Camera3D
var camera_pivot: Node3D
var spring_arm: SpringArm3D

@export_group("Mouse Look")
@export var mouse_x_sensitivity := 0.002
@export var mouse_y_sensitivity := 0.001
@export var invert_y := true
@export var pitch_min_deg := -75.0
@export var pitch_max_deg := 20.0

@export_group("Stick Look")
## Yaw rate in radians/sec at full right-stick deflection.
@export var stick_yaw_speed := 3.0
## Pitch rate in radians/sec at full right-stick deflection. Smaller than yaw
## by convention — vertical look is less commonly swept than horizontal.
@export var stick_pitch_speed := 2.0
## Hub deadzone applied on top of the per-axis deadzone in the InputMap.
## Keeps the camera completely still at rest.
@export var stick_look_deadzone := 0.15

@export_group("Sneak (post-hacking ability)")
## Above this magnitude on the move stick, the player runs at full speed.
## Below it but above `move_deadzone`, controller-driven auto-sneak engages.
## Only relevant on gamepad — keyboard players use Shift toggle.
@export var sneak_stick_threshold := 0.25
## GameState flag that gates the sneak feature. Set to "" to enable
## unconditionally (debug). Default is the L2 hacking power-up.
@export var sneak_required_flag: StringName = &"powerup_secret"

## Deadzone applied to the raw 2D movement axis before converting to world
## direction. Small — the body layers its own thresholds on top.
@export var move_deadzone := 0.1

var _intent := Intent.new()
## Toggled on every Shift press once the hacking ability is owned. Persists
## until pressed again — sneak stays engaged even if the player runs through
## it. Controller players bypass this entirely; their auto-sneak reads the
## stick magnitude per-tick.
var _sneak_toggle: bool = false
## Set true the tick a mouse moved; the body reads this to re-engage manual
## camera control. Exposed so the body's camera follow logic can query it.
var time_since_mouse_input := 999.0

## Which input device the player used most recently. Consumers (PromptUI,
## HUD, rebind menus) read this for glyph switching — mouse counts as
## "keyboard" since the two are typically used together on desktop. Updated
## in _input on change only (dedupe) to avoid signal spam on held inputs.
var last_device: String = "keyboard"


func _ready() -> void:
	# Resolve camera rig paths relative to the parent (body). Paths are
	# node-relative, not brain-relative, so stock skins work without rewiring.
	var body := get_parent()
	if body != null:
		if not camera_path.is_empty():
			camera = body.get_node_or_null(camera_path) as Camera3D
		if not camera_pivot_path.is_empty():
			camera_pivot = body.get_node_or_null(camera_pivot_path) as Node3D
		if not spring_arm_path.is_empty():
			spring_arm = body.get_node_or_null(spring_arm_path) as SpringArm3D
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if event.relative.length() > 0.01:
			time_since_mouse_input = 0.0
		if camera_pivot != null:
			camera_pivot.rotation.y -= event.relative.x * mouse_x_sensitivity
		if spring_arm != null:
			var y_sign := -1.0 if invert_y else 1.0
			var new_pitch: float = spring_arm.rotation.x + event.relative.y * mouse_y_sensitivity * y_sign
			spring_arm.rotation.x = clamp(new_pitch, deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))


func _input(event: InputEvent) -> void:
	_update_last_device(event)
	var body := get_parent()
	if body == null:
		return
	if event.is_action_pressed("toggle_follow_mode") and body.has_method("toggle_follow_mode"):
		body.toggle_follow_mode()


## Single-owner mouse-mode toggle. Pause menus, dialogue, and puzzle UI all
## call this instead of touching Input.mouse_mode directly so the state stays
## consistent across modal transitions.
func capture_mouse(on: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE


func _update_last_device(event: InputEvent) -> void:
	var kind: String = last_device
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		kind = "gamepad"
	elif event is InputEventKey or event is InputEventMouseButton or event is InputEventMouseMotion:
		kind = "keyboard"
	# Dedupe: write only on change so observers can subscribe without noise.
	if kind != last_device:
		last_device = kind


func tick(_body: Node3D, delta: float) -> Intent:
	time_since_mouse_input += delta

	# Full gameplay-input gate during dialogue. Without this, controller buttons
	# bleed through: Cross fires both `ui_accept` (advances dialogue) AND `jump`
	# polled here (player jumps mid-conversation). Mouse+keyboard didn't notice
	# because cursor was UI-focused, but pads have no such focus context.
	# Empty intent = body sees zero movement + zero action edges this tick.
	if Dialogue.is_open():
		_intent.move_direction = Vector3.ZERO
		_intent.jump_pressed = false
		_intent.attack_pressed = false
		_intent.interact_pressed = false
		_intent.dash_pressed = false
		_intent.crouch_held = false
		return _intent

	# Right-stick → camera, mirroring the mouse path. Apply yaw to camera_pivot
	# and pitch to spring_arm so spring/camera follow the same chain as mouse.
	# `time_since_mouse_input` is reset on stick movement too — the body uses
	# this signal to know whether manual camera control is currently engaged.
	var look_axis := Input.get_vector("look_left", "look_right", "look_up", "look_down", stick_look_deadzone)
	if look_axis.length_squared() > 0.0:
		time_since_mouse_input = 0.0
		if camera_pivot != null:
			camera_pivot.rotation.y -= look_axis.x * stick_yaw_speed * delta
		if spring_arm != null:
			var y_sign := -1.0 if invert_y else 1.0
			var new_pitch: float = spring_arm.rotation.x + look_axis.y * stick_pitch_speed * delta * y_sign
			spring_arm.rotation.x = clamp(new_pitch, deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))

	# Raw 2D input — deadzone here is tiny so the body's own thresholds remain
	# the source of truth for "is the player pressing forward."
	var raw_axis := Input.get_vector("move_left", "move_right", "move_up", "move_down", move_deadzone)

	# Convert to world-space horizontal direction using the camera's yaw.
	# Without a camera (shouldn't happen for a player), fall back to world axes.
	var world_dir := Vector3.ZERO
	if camera != null:
		var forward: Vector3 = camera.global_basis.z
		var right: Vector3 = camera.global_basis.x
		world_dir = forward * raw_axis.y + right * raw_axis.x
	else:
		world_dir = Vector3(raw_axis.x, 0.0, raw_axis.y)
	world_dir.y = 0.0
	# Preserve magnitude (for analog sticks) while clamping to [0, 1].
	var mag: float = min(world_dir.length(), 1.0)
	if world_dir.length_squared() > 0.0001:
		world_dir = world_dir.normalized() * mag

	# Crouch / sneak — entire mechanic is gated on the hacking power-up. Until
	# the player owns it, Ctrl / R3 / Shift / slow-stick are all inert. Once
	# owned, three activation paths feed the same crouch_held wire (which
	# drives Crouching Idle / Crouched Walking via the existing state machine):
	#   1. Crouch action (Ctrl key, R3 stick click) — held.
	#   2. Sneak toggle (Shift key) — sticky.
	#   3. Auto-sneak — controller stick below `sneak_stick_threshold`.
	var crouch_held: bool = false
	var ability_owned: bool = sneak_required_flag.is_empty() or GameState.get_flag(sneak_required_flag, false)
	if ability_owned:
		if Input.is_action_just_pressed("sneak_toggle"):
			_sneak_toggle = not _sneak_toggle
		var sneak_active: bool = _sneak_toggle
		if last_device == "gamepad":
			var stick_mag: float = raw_axis.length()
			if stick_mag > 0.0 and stick_mag < sneak_stick_threshold:
				sneak_active = true
		crouch_held = Input.is_action_pressed("crouch") or sneak_active

	_intent.move_direction = world_dir
	_intent.jump_pressed = Input.is_action_just_pressed("jump")
	_intent.attack_pressed = Input.is_action_just_pressed("attack")
	_intent.interact_pressed = Input.is_action_just_pressed("interact")
	_intent.dash_pressed = Input.is_action_just_pressed("dash")
	_intent.crouch_held = crouch_held
	return _intent
