class_name CopRiotSkin
extends CharacterSkin

## Sophia-derived state machine for the cop_riot rig. The GLB only ships
## with Riot_Idle + Riot_Run, so most states fall back to one of the two
## inside the AnimationTree — but the STRUCTURE is full (idle/move/jump/
## fall/edge/wall/attack/dash/crouch + tilt blend) so this skin is
## behaviourally identical to Sophia/KayKit as a player. Adding new cop
## clips later requires only swapping clip names in the AnimationTree
## sub-resources; no code changes.
##
## No damage-tint overlay — the cop_riot GLB uses embedded materials that
## aren't trivially overlayable. Damage-flash inherits the CharacterSkin
## no-op.

@onready var animation_tree: AnimationTree = %AnimationTree
@onready var state_machine: AnimationNodeStateMachinePlayback = animation_tree.get("parameters/StateMachine/playback")
@onready var move_tilt_path: String = "parameters/StateMachine/Move/tilt/add_amount"

## Y-offset applied to the Model node in skate mode so the heel rests on
## the wheels. Walk mode drops it to 0 so bare feet touch the ground.
## Tune per skin — different rigs have different foot-origin heights.
@export var skate_root_y: float = 0.134

## Rollerblade wheels live as inspector-tunable Node3D children in the scene
## (WheelsLeft / WheelsRight, sibling to Model). At _ready they're reparented
## under runtime BoneAttachment3Ds bound to the foot bones, keeping global
## transform so the user's scene-editor position survives the reparent.
const _FOOT_L_BONE := &"mixamorig_LeftFoot_026"
const _FOOT_R_BONE := &"mixamorig_RightFoot_030"
@onready var _wheels_left: Node3D = $WheelsLeft
@onready var _wheels_right: Node3D = $WheelsRight
@onready var _dust_particles: GPUParticles3D = %DustParticles


func _ready() -> void:
	# GLB imports default to LOOP_NONE. Both cop_riot clips should loop so
	# Idle / Run don't freeze after one cycle.
	var primary := _find_anim_player(self)
	if primary != null:
		for n: String in ["Riot_Idle", "Riot_Run"]:
			if primary.has_animation(n):
				primary.get_animation(n).loop_mode = Animation.LOOP_LINEAR

	# Reparent inspector-placed wheel nodes under runtime BoneAttachment3Ds.
	_reparent_under_bone(_wheels_left, _FOOT_L_BONE)
	_reparent_under_bone(_wheels_right, _FOOT_R_BONE)
	if _wheels_left != null: _wheels_left.visible = false
	if _wheels_right != null: _wheels_right.visible = false


func _reparent_under_bone(wheels: Node3D, bone_name: StringName) -> void:
	if wheels == null:
		return
	var skeleton := _find_skeleton(self)
	if skeleton == null:
		return
	var idx := skeleton.find_bone(bone_name)
	if idx == -1:
		return
	var ba := BoneAttachment3D.new()
	ba.bone_name = bone_name
	ba.bone_idx = idx
	skeleton.add_child(ba)
	wheels.reparent(ba, true)


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c: Node in n.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null


func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c: Node in n.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null


# --- CharacterSkin contract ---
func idle() -> void: state_machine.travel("Idle")
func move() -> void: state_machine.travel("Move")
func fall() -> void: state_machine.travel("Fall")
func jump() -> void: state_machine.travel("Jump")
func edge_grab() -> void: state_machine.travel("EdgeGrab")
func wall_slide() -> void: state_machine.travel("WallSlide")
func attack() -> void: state_machine.start("EdgeGrab")

func dash(_direction: Vector3 = Vector3.ZERO) -> void:
	# No directional dodge clips on this rig — force-enter the shared Dash
	# state (points at Riot_Run). Exits via body's per-frame travel calls
	# once dash_timer expires.
	state_machine.start("Dash")

func crouch(active: bool) -> void:
	if active:
		state_machine.start("Crouch")

func set_skate_mode(active: bool) -> void:
	var model: Node3D = get_node_or_null("Model") as Node3D
	if model != null:
		model.position.y = skate_root_y if active else 0.0
	if _wheels_left != null:
		_wheels_left.visible = active
	if _wheels_right != null:
		_wheels_right.visible = active


func set_dust_emitting(enabled: bool) -> void:
	if _dust_particles != null:
		_dust_particles.emitting = enabled
