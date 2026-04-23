class_name KayKitSkin
extends CharacterSkin

## Sophia-derived KayKit skin with full polish: directional dodge (4 clips),
## crouch pose, and damage-flash overlay on all 6 mannequin mesh parts.
## Conforms exactly to the CharacterSkin contract; overrides the hooks that
## have real animations available in the KayKit library.
##
## All merged animations are available through the merged primary
## AnimationPlayer (see extra_animation_sources). Clip references inside
## the AnimationTree point at specific library names.

## Extra GLBs whose animations get merged into the primary AnimationPlayer
## at _ready. Each is instantiated once, its clips are copied into the
## primary's default library, and the source is freed.
@export var extra_animation_sources: Array[PackedScene] = []

@onready var animation_tree: AnimationTree = %AnimationTree
@onready var state_machine: AnimationNodeStateMachinePlayback = animation_tree.get("parameters/StateMachine/playback")
@onready var move_tilt_path: String = "parameters/StateMachine/Move/tilt/add_amount"

# Cached reference to the Dash state's AnimationNodeAnimation so dash() can
# swap its clip (Dodge_Forward / Backward / Left / Right) per call before
# starting the state.
var _dash_anim_node: AnimationNodeAnimation

# Shared red-tint material overlay applied to all mannequin mesh parts so
# damage flash reads as a body flush (matches Sophia's single-mesh overlay
# but distributed across the mannequin's 6 separate pieces).
var _damage_overlay: StandardMaterial3D
var _body_meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	# Merge extra animation packs BEFORE the AnimationTree starts consuming
	# clips by name. By the time state_machine.travel("Move") fires, the
	# library must contain "Running_A", "Dodge_Forward", "Crouching", etc.
	var primary := _find_anim_player(self)
	if primary == null:
		return
	for src_scene: PackedScene in extra_animation_sources:
		if src_scene == null:
			continue
		_merge_animations_from(primary, src_scene)

	# Cache the Dash AnimationNodeAnimation for runtime clip swapping.
	var outer := animation_tree.tree_root as AnimationNodeBlendTree
	if outer != null:
		var sm := outer.get_node(&"StateMachine") as AnimationNodeStateMachine
		if sm != null:
			_dash_anim_node = sm.get_node(&"Dash") as AnimationNodeAnimation

	# Set up damage overlay. The mannequin has 6 separate mesh parts under
	# Model/Rig_Medium/Skeleton3D; we share one StandardMaterial3D across
	# all of them so alpha changes flush the whole body in one write.
	_damage_overlay = StandardMaterial3D.new()
	_damage_overlay.albedo_color = Color(1.0, 0.12, 0.12, 0.0)
	_damage_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_damage_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_collect_mannequin_meshes(self)
	for m: MeshInstance3D in _body_meshes:
		m.material_overlay = _damage_overlay


func _collect_mannequin_meshes(n: Node) -> void:
	if n is MeshInstance3D and str(n.name).begins_with("Mannequin_"):
		_body_meshes.append(n as MeshInstance3D)
	for c: Node in n.get_children():
		_collect_mannequin_meshes(c)


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
func idle() -> void: state_machine.travel("Idle")
func move() -> void: state_machine.travel("Move")
func fall() -> void: state_machine.travel("Fall")
func jump() -> void: state_machine.travel("Jump")
func edge_grab() -> void: state_machine.travel("EdgeGrab")
func wall_slide() -> void: state_machine.travel("WallSlide")
# attack re-uses the EdgeGrab state's Punch clip via the body's existing
# one-shot pattern (mirror of how Sophia re-uses EdgeGrab for attack).
func attack() -> void: state_machine.start("EdgeGrab")


func dash(direction: Vector3 = Vector3.ZERO) -> void:
	# Pick the dodge clip whose directionality best matches the world-space
	# dash vector, projected onto the skin's current facing. Body passes the
	# same vector it applied to velocity so animation matches motion.
	if _dash_anim_node != null:
		_dash_anim_node.animation = _pick_dodge_clip(direction)
	state_machine.start("Dash")


func crouch(active: bool) -> void:
	# Force-enter the Crouch state on press. Release is handled by the body's
	# per-frame travel calls — PlayerBody gates those so Crouch isn't
	# overwritten while held, then when crouch_held flips false the next
	# frame's idle()/move() travels out via Crouch→Idle / Crouch→Move.
	if active:
		state_machine.start("Crouch")


func set_damage_tint(value: float) -> void:
	super(value)
	if _damage_overlay != null:
		var c: Color = _damage_overlay.albedo_color
		c.a = damage_tint
		_damage_overlay.albedo_color = c


# Project `world_dir` onto the skin's own facing to pick one of the four
# KayKit dodge clips. When motion is primarily sideways we pick Left/Right;
# otherwise Forward/Backward. Ties favour forward.
func _pick_dodge_clip(world_dir: Vector3) -> StringName:
	if world_dir.length_squared() < 0.0001:
		return &"Dodge_Forward"
	var forward: Vector3 = -global_basis.z
	var right: Vector3 = global_basis.x
	var f := world_dir.dot(forward)
	var r := world_dir.dot(right)
	if absf(r) > absf(f):
		return &"Dodge_Right" if r > 0.0 else &"Dodge_Left"
	return &"Dodge_Forward" if f >= 0.0 else &"Dodge_Backward"
