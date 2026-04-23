class_name UniversalMaleSkin
extends CharacterSkin

## Universal Animation Library Standard mannequin skin. UAL1 provides the
## mesh + a base library (45 clips: Idle, Jog_Fwd, Sprint, Jump*, Roll,
## Punch_*, Death01, Crouch_*, Hit_*, etc.). UAL2 merges in extras (Slide,
## Melee_Hook, Sword_*, Idle_FoldArms, NinjaJump_*). Conforms exactly to
## the CharacterSkin contract.

## Extra GLBs whose animations get merged into the primary AnimationPlayer
## at _ready. Each is instantiated once, its clips are copied into the
## primary's default library, and the source is freed.
@export var extra_animation_sources: Array[PackedScene] = []

## Y-offset applied to the Model node in skate mode so the heel rests on
## the wheels. Walk mode drops it to 0 so bare feet touch the ground.
@export var skate_root_y: float = 0.134

## UAL rigs are UE-style naming: foot_l / foot_r.
const _FOOT_L_BONE := &"foot_l"
const _FOOT_R_BONE := &"foot_r"
@onready var _wheels_left: Node3D = $WheelsLeft
@onready var _wheels_right: Node3D = $WheelsRight
@onready var _dust_particles: GPUParticles3D = %DustParticles

@onready var animation_tree: AnimationTree = %AnimationTree
@onready var state_machine: AnimationNodeStateMachinePlayback = animation_tree.get("parameters/StateMachine/playback")
@onready var move_tilt_path: String = "parameters/StateMachine/Move/tilt/add_amount"

# Cached reference to the Dash state's AnimationNodeAnimation so dash() can
# swap its clip per call. UAL only has `Roll` — no directional variants, so
# all four dash directions play the same clip. Can swap later if more rolls
# are added.
var _dash_anim_node: AnimationNodeAnimation

# Cached reference to the EdgeGrab state's AnimationNodeAnimation so attack()
# can randomize between punch variants.
var _edge_anim_node: AnimationNodeAnimation
const _ATTACK_CLIPS := [&"Punch_Cross", &"Punch_Jab"]

# Hit state randomization between Hit_Chest and Hit_Head.
var _hit_anim_node: AnimationNodeAnimation
const _HIT_CLIPS := [&"Hit_Chest", &"Hit_Head"]

# Idle cycling between Idle and Idle_FoldArms.
var _idle_anim_node: AnimationNodeAnimation
const _IDLE_CLIPS := [&"Idle", &"Idle_FoldArms"]
var _idle_cycle_index: int = 0

# Damage overlay. UAL ships a single `Mannequin` MeshInstance3D (not 6 parts
# like KayKit), so we only need one overlay assignment.
var _damage_overlay: StandardMaterial3D
var _body_meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	var primary := _find_anim_player(self)
	if primary == null:
		return
	for src_scene: PackedScene in extra_animation_sources:
		if src_scene == null:
			continue
		_merge_animations_from(primary, src_scene)

	# GLB imports default clips to LOOP_NONE — patch the ones that should
	# loop so Idle / Jog / Crouch / Sprint / Walk don't freeze after one play.
	_force_loop_linear(primary, [
		"Idle", "Idle_FoldArms", "Idle_Talking", "Idle_Lantern", "Idle_No",
		"Jog_Fwd", "Sprint", "Walk", "Walk_Formal", "Walk_Carry",
		"Crouch_Idle", "Crouch_Fwd",
		"Swim_Idle", "Swim_Fwd",
		"Jump",  # Jump_Idle equivalent — looping mid-air pose
		"Pistol_Idle", "Sword_Idle",
		"Slide",
		"Zombie_Idle", "Zombie_Walk_Fwd",
	])

	# Cache animation-node refs for runtime clip swapping.
	var outer := animation_tree.tree_root as AnimationNodeBlendTree
	if outer != null:
		var sm := outer.get_node(&"StateMachine") as AnimationNodeStateMachine
		if sm != null:
			_dash_anim_node = sm.get_node(&"Dash") as AnimationNodeAnimation
			_edge_anim_node = sm.get_node(&"EdgeGrab") as AnimationNodeAnimation
			_hit_anim_node = sm.get_node(&"Hit") as AnimationNodeAnimation
			_idle_anim_node = sm.get_node(&"Idle") as AnimationNodeAnimation

	# Damage overlay. UAL's single `Mannequin` mesh gets the red-flash flush.
	_damage_overlay = StandardMaterial3D.new()
	_damage_overlay.albedo_color = Color(1.0, 0.12, 0.12, 0.0)
	_damage_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_damage_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_collect_mannequin_meshes(self)
	for m: MeshInstance3D in _body_meshes:
		m.material_overlay = _damage_overlay

	_reparent_under_bone(_wheels_left, _FOOT_L_BONE)
	_reparent_under_bone(_wheels_right, _FOOT_R_BONE)
	if _wheels_left != null: _wheels_left.visible = false
	if _wheels_right != null: _wheels_right.visible = false


func _collect_mannequin_meshes(n: Node) -> void:
	# UAL ships a single MeshInstance3D named "Mannequin". Walk all descendants
	# and grab MeshInstance3Ds — permissive so future UAL variants with
	# multiple parts still get the overlay.
	if n is MeshInstance3D:
		_body_meshes.append(n as MeshInstance3D)
	for c: Node in n.get_children():
		_collect_mannequin_meshes(c)


## Create a BoneAttachment3D under the skin's skeleton bound to `bone_name`
## and reparent `wheels` under it, preserving global transform.
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


func _force_loop_linear(primary: AnimationPlayer, clip_names: Array) -> void:
	for n: String in clip_names:
		if primary.has_animation(n):
			primary.get_animation(n).loop_mode = Animation.LOOP_LINEAR


func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c: Node in n.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null


func _merge_animations_from(primary: AnimationPlayer, scene: PackedScene) -> void:
	var instance := scene.instantiate()
	var src_anim := _find_anim_player(instance)
	if src_anim == null:
		instance.queue_free()
		return
	var default_lib := primary.get_animation_library(&"")
	if default_lib == null:
		default_lib = AnimationLibrary.new()
		primary.add_animation_library(&"", default_lib)
	for lib_name: StringName in src_anim.get_animation_library_list():
		var src_lib := src_anim.get_animation_library(lib_name)
		if src_lib == null:
			continue
		for anim_name: StringName in src_lib.get_animation_list():
			if not default_lib.has_animation(anim_name):
				default_lib.add_animation(anim_name, src_lib.get_animation(anim_name))
	instance.queue_free()


# --- CharacterSkin contract ---
func idle() -> void:
	if state_machine.get_current_node() != &"Idle" and _idle_anim_node != null:
		_idle_cycle_index = (_idle_cycle_index + 1) % _IDLE_CLIPS.size()
		_idle_anim_node.animation = _IDLE_CLIPS[_idle_cycle_index]
	state_machine.travel("Idle")
func move() -> void: state_machine.travel("Move")
func fall() -> void: state_machine.travel("Fall")
func jump() -> void: state_machine.travel("Jump")
func edge_grab() -> void: state_machine.travel("EdgeGrab")
func wall_slide() -> void: state_machine.travel("WallSlide")


func attack() -> void:
	if _edge_anim_node != null:
		_edge_anim_node.animation = _ATTACK_CLIPS[randi() % _ATTACK_CLIPS.size()]
	state_machine.start("EdgeGrab")


func die() -> void:
	state_machine.start("Die")


func land() -> void:
	state_machine.start("Land")


func on_hit() -> void:
	if _hit_anim_node != null:
		_hit_anim_node.animation = _HIT_CLIPS[randi() % _HIT_CLIPS.size()]
	state_machine.start("Hit")


func dash(_direction: Vector3 = Vector3.ZERO) -> void:
	# UAL only has a single `Roll` clip — no directional variants, so all
	# four dash directions play the same animation. Swap later if more
	# rolls/dodges are authored.
	state_machine.start("Dash")


func crouch(active: bool) -> void:
	if active:
		state_machine.start("Crouch")


func set_damage_tint(value: float) -> void:
	super(value)
	if _damage_overlay != null:
		var c: Color = _damage_overlay.albedo_color
		c.a = damage_tint
		_damage_overlay.albedo_color = c


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
