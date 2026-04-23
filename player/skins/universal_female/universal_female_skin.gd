class_name UniversalFemaleSkin
extends CharacterSkin

## Universal Animation Library (UAL) female mannequin skin. Mannequin_F is the
## skinned mesh; UAL1_Standard and UAL2_Standard supply the animation library
## via extra_animation_sources. Conforms to CharacterSkin.

## Extra GLBs whose animations get merged into the primary AnimationPlayer
## at _ready. Each is instantiated once, its clips are copied into the
## primary's default library, and the source is freed.
@export var extra_animation_sources: Array[PackedScene] = []

## Y-offset applied to the Model node in skate mode so the heel rests on
## the wheels. Walk mode drops it to 0.
@export var skate_root_y: float = 0.134

## Foot bone names for wheel attachment. UAL rigs use UE-style names.
const _FOOT_L_BONE := &"foot_l"
const _FOOT_R_BONE := &"foot_r"
@onready var _wheels_left: Node3D = $WheelsLeft
@onready var _wheels_right: Node3D = $WheelsRight
@onready var _dust_particles: GPUParticles3D = %DustParticles

@onready var animation_tree: AnimationTree = %AnimationTree
@onready var state_machine: AnimationNodeStateMachinePlayback = animation_tree.get("parameters/StateMachine/playback")
@onready var move_tilt_path: String = "parameters/StateMachine/Move/tilt/add_amount"

# Cached references for runtime clip swapping.
var _dash_anim_node: AnimationNodeAnimation
var _edge_anim_node: AnimationNodeAnimation
const _ATTACK_CLIPS := [&"Punch_Jab", &"Punch_Cross"]

var _hit_anim_node: AnimationNodeAnimation
const _HIT_CLIPS := [&"Hit_Chest", &"Hit_Head"]

var _idle_anim_node: AnimationNodeAnimation
const _IDLE_CLIPS := [&"Idle", &"Idle_FoldArms"]
var _idle_cycle_index: int = 0

# Damage overlay shared across all mannequin mesh parts.
var _damage_overlay: StandardMaterial3D
var _body_meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	# Mannequin_F.glb is mesh-only (bind pose + skinned mesh, no AnimationPlayer).
	# All animation comes from the extra sources (UAL1/UAL2). Create an
	# AnimationPlayer under Model named exactly "AnimationPlayer" so the
	# AnimationTree's anim_player NodePath("../Model/AnimationPlayer") resolves.
	var primary := _find_anim_player(self)
	if primary == null:
		var model: Node = get_node_or_null("Model")
		if model == null:
			return
		primary = AnimationPlayer.new()
		primary.name = "AnimationPlayer"
		model.add_child(primary)
		# AnimationTree caches its anim_player reference at enter_tree. That's
		# already fired by the time this script's _ready runs, so the tree's
		# cache is null. Re-assigning the property forces a re-resolve so the
		# tree picks up the AnimationPlayer we just created.
		animation_tree.anim_player = animation_tree.anim_player
	for src_scene: PackedScene in extra_animation_sources:
		if src_scene == null:
			continue
		_merge_animations_from(primary, src_scene)
	# --- TEMP verification log: pelvis delta under AT ---
	var skel_verify := _find_skeleton(self)
	if skel_verify != null:
		var p := skel_verify.find_bone("pelvis")
		var b: Vector3 = skel_verify.get_bone_pose(p).origin
		state_machine.travel("Idle")
		animation_tree.advance(0.5)
		var a: Vector3 = skel_verify.get_bone_pose(p).origin
		print("[female_skin VERIFY] pelvis delta via AT after fix: %s" % (a - b))
	# --- end TEMP ---

	# GLB imports default clips to LOOP_NONE — patch the ones that should loop.
	_force_loop_linear(primary, [
		"Idle", "Idle_FoldArms", "Idle_Talking", "Idle_Torch",
		"Idle_Lantern", "Idle_Rail", "Idle_Shield",
		"Jog_Fwd", "Sprint", "Walk", "Walk_Formal", "Walk_Carry",
		"Crouch_Idle", "Crouch_Fwd",
		"Swim_Idle", "Swim_Fwd",
		"Jump",
		"Sword_Idle", "Pistol_Idle",
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

	# Damage overlay across all mannequin meshes.
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


# Walk ALL MeshInstance3D descendants so we catch `Mannequin_F` regardless of
# naming convention — UAL mesh names vary (Mannequin, Mannequin_F, etc.).
func _collect_mannequin_meshes(n: Node) -> void:
	if n is MeshInstance3D:
		_body_meshes.append(n as MeshInstance3D)
	for c: Node in n.get_children():
		_collect_mannequin_meshes(c)


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
	var default_lib: AnimationLibrary = null
	if primary.has_animation_library(&""):
		default_lib = primary.get_animation_library(&"")
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
	# UAL has a single Roll clip (non-directional). Play it regardless of dir.
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
