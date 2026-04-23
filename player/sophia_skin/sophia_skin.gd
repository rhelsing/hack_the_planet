class_name SophiaSkin
extends CharacterSkin

@onready var animation_tree = %AnimationTree
@onready var state_machine : AnimationNodeStateMachinePlayback = animation_tree.get("parameters/StateMachine/playback")
@onready var move_tilt_path : String = "parameters/StateMachine/Move/tilt/add_amount"

## Skin root lift when skates are on — matches the original sophia.tscn
## default translation (y=0.13390523). Walk mode drops this to 0 so bare
## feet sit flush on the ground.
const SKATE_ROOT_Y := 0.13390523

@onready var _sophia_root: Node3D = $sophia
@onready var _wheels_left: Node3D = $sophia/rig/Skeleton3D/WheelsLeft
@onready var _wheels_right: Node3D = $sophia/rig/Skeleton3D/WheelsRight

var run_tilt = 0.0 : set = _set_run_tilt

@export var blink = true : set = set_blink
@onready var blink_timer = %BlinkTimer
@onready var closed_eyes_timer = %ClosedEyesTimer
@onready var eye_mat = $sophia/rig/Skeleton3D/Sophia.get("surface_material_override/2")
@onready var _body_mesh: MeshInstance3D = $sophia/rig/Skeleton3D/Sophia

var _damage_overlay: StandardMaterial3D

func _ready():
	_damage_overlay = StandardMaterial3D.new()
	# Peak tint is the albedo when alpha=1; the `damage_tint` setter drives
	# alpha from 0 (invisible) up to full tint strength.
	_damage_overlay.albedo_color = Color(1.0, 0.12, 0.12, 0.0)
	_damage_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_damage_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_body_mesh.material_overlay = _damage_overlay

	blink_timer.connect("timeout", func():
		eye_mat.set("uv1_offset", Vector3(0.0, 0.5, 0.0))
		closed_eyes_timer.start(0.2)
		)
		
	closed_eyes_timer.connect("timeout", func():
		eye_mat.set("uv1_offset", Vector3.ZERO)
		blink_timer.start(randf_range(1.0, 4.0))
		)

func set_blink(state : bool):
	if blink == state: return
	blink = state
	if blink:
		blink_timer.start(0.2)
	else:
		blink_timer.stop()
		closed_eyes_timer.stop()


func set_damage_tint(value: float) -> void:
	# Sophia flushes red via a StandardMaterial3D overlay on her body mesh.
	super(value)
	if _damage_overlay != null:
		var c: Color = _damage_overlay.albedo_color
		c.a = damage_tint
		_damage_overlay.albedo_color = c


func set_skate_mode(active: bool) -> void:
	# Skate on: wheels show, skin root lifts by SKATE_ROOT_Y so the heel rests
	# on the blade edge. Walk: wheels hide, root drops to 0 so bare feet touch
	# the ground. Called by PlayerBody.toggle_profile() and once at _ready
	# to seed the starting state.
	if _sophia_root != null:
		_sophia_root.position.y = SKATE_ROOT_Y if active else 0.0
	if _wheels_left != null:
		_wheels_left.visible = active
	if _wheels_right != null:
		_wheels_right.visible = active

func _set_run_tilt(value : float):
	run_tilt = clamp(value, -1.0, 1.0)
	animation_tree.set(move_tilt_path, run_tilt)

func idle():
	state_machine.travel("Idle")

func move():
	state_machine.travel("Move")

func fall():
	state_machine.travel("Fall")

func jump():
	state_machine.travel("Jump")

func edge_grab():
	state_machine.travel("EdgeGrab")

func wall_slide():
	state_machine.travel("WallSlide")

func attack():
	state_machine.start("EdgeGrab")
