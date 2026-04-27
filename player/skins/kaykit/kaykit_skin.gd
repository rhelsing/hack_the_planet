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

## Y-offset applied to the Model node in skate mode so the heel rests on
## the wheels. Walk mode drops it to 0 so bare feet touch the ground.
## Tune per skin — different rigs have different foot-origin heights.
@export var skate_root_y: float = 0.134

## Per-part albedo tints. Default to the mannequin's stock grey; override on
## inherited skin scenes (e.g. enemy_kaykit_red.tscn) to recolor pawns
## without touching textures or shaders. Each tint duplicates the shared
## Character_Material at _ready and applies as a surface override on that
## part's MeshInstance3D, so tints are per-instance, not global.
const _DEFAULT_TINT := Color(0.4845, 0.4845, 0.4845)
@export_group("Part Tints")
@export var tint_head: Color = _DEFAULT_TINT
@export var tint_body: Color = _DEFAULT_TINT
@export var tint_arm_left: Color = _DEFAULT_TINT
@export var tint_arm_right: Color = _DEFAULT_TINT
@export var tint_leg_left: Color = _DEFAULT_TINT
@export var tint_leg_right: Color = _DEFAULT_TINT
@export_group("")

## Rollerblade wheels live as inspector-tunable Node3D children in the scene
## (WheelsLeft / WheelsRight, sibling to Model). At _ready they're reparented
## under runtime BoneAttachment3Ds bound to the foot bones, keeping global
## transform so the user's scene-editor position is preserved. Visibility
## tracks skate mode.
const _FOOT_L_BONE := &"foot.l"
const _FOOT_R_BONE := &"foot.r"
@onready var _wheels_left: Node3D = $WheelsLeft
@onready var _wheels_right: Node3D = $WheelsRight
@onready var _dust_particles: GPUParticles3D = %DustParticles

@onready var animation_tree: AnimationTree = %AnimationTree
@onready var state_machine: AnimationNodeStateMachinePlayback = animation_tree.get("parameters/StateMachine/playback")
@onready var move_tilt_path: String = "parameters/StateMachine/Move/tilt/add_amount"

# Cached reference to the Dash state's AnimationNodeAnimation so dash() can
# swap its clip (Dodge_Forward / Backward / Left / Right) per call before
# starting the state.
var _dash_anim_node: AnimationNodeAnimation

# Cached reference to the EdgeGrab state's AnimationNodeAnimation so attack()
# can randomize between punch / kick clips each swing.
var _edge_anim_node: AnimationNodeAnimation
const _ATTACK_CLIPS := [&"Melee_Unarmed_Attack_Punch_A", &"Melee_Unarmed_Attack_Kick"]

# Cached Hit state for take_hit randomization between Hit_A and Hit_B.
var _hit_anim_node: AnimationNodeAnimation
const _HIT_CLIPS := [&"Hit_A", &"Hit_B"]

# Cached Idle state + cycling state so the idle pose alternates between
# Idle_A and Idle_B when the player pauses between moves (adds life).
var _idle_anim_node: AnimationNodeAnimation
const _IDLE_CLIPS := [&"Idle_A", &"Idle_B"]
var _idle_cycle_index: int = 0

# Ambient idle-flicker — every 5 / 7 / 13s a brief 0->1->0 glitch pulse fires
# while the pawn is alive. Picks a fresh interval each cycle from this set.
const _AMBIENT_FLICKER_INTERVALS := [5.0, 7.0, 13.0]
var _ambient_flicker_timer: float = 0.0
var _ambient_flicker_active: bool = false
var _ambient_flicker_elapsed: float = 0.0
const _AMBIENT_FLICKER_DURATION := 0.35

# Glitch overlay state. Body owns the death-sequence ramp and writes via
# set_glitch_progress; ambient flicker drives its own ramp on _ambient_flicker_*.
# The shared shader material is built once at _ready and replaces the prior
# StandardMaterial3D damage overlay — both effects share the same overlay slot.
var _glitch_overlay: ShaderMaterial
var _death_glitch_value: float = 0.0
var _ambient_glitch_value: float = 0.0

# Cached Crouch state. Tree authors it as "Crouching" by default; we override
# the clip once at _ready to "Sneaking" so the crouch read is the lower,
# weight-forward stalking pose instead of the high resting squat.
var _crouch_anim_node: AnimationNodeAnimation

# All mannequin mesh parts that receive the shared overlay (damage flash +
# glitch). Six pieces under Model/Rig_Medium/Skeleton3D.
var _body_meshes: Array[MeshInstance3D] = []

const _GLITCH_SHADER: Shader = preload("res://player/skins/kaykit/death_glitch.gdshader")


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

	# GLB imports default clips to LOOP_NONE — patch the ones that should
	# loop so Run / Idle / Crouching don't freeze after one play.
	_force_loop_linear(primary, [
		"Idle_A", "Idle_B",
		"Running_A", "Running_B",
		"Running_Strafe_Left", "Running_Strafe_Right",
		"Walking_A", "Walking_B", "Walking_C",
		"Walking_Backwards",
		"Crouching", "Sneaking", "Crawling",
		"Jump_Idle",
		"Melee_Unarmed_Idle", "Melee_2H_Idle", "Melee_Blocking",
	])

	# Cache animation-node refs for runtime clip swapping — dash picks a
	# direction, attack + hit randomize variants, idle alternates for life.
	var outer := animation_tree.tree_root as AnimationNodeBlendTree
	if outer != null:
		var sm := outer.get_node(&"StateMachine") as AnimationNodeStateMachine
		if sm != null:
			_dash_anim_node = sm.get_node(&"Dash") as AnimationNodeAnimation
			_edge_anim_node = sm.get_node(&"EdgeGrab") as AnimationNodeAnimation
			_hit_anim_node = sm.get_node(&"Hit") as AnimationNodeAnimation
			_idle_anim_node = sm.get_node(&"Idle") as AnimationNodeAnimation
			_crouch_anim_node = sm.get_node(&"Crouch") as AnimationNodeAnimation
			if _crouch_anim_node != null:
				_crouch_anim_node.animation = &"Sneaking"
			if _dash_anim_node != null:
				_dash_anim_node.animation = &"Dodge_Forward"

	# Combined damage + glitch overlay. One ShaderMaterial shared across all
	# 6 mannequin parts; both effects drive uniforms on the same shader so we
	# don't compete for the single material_overlay slot.
	_glitch_overlay = ShaderMaterial.new()
	_glitch_overlay.shader = _GLITCH_SHADER
	_collect_mannequin_meshes(self)
	for m: MeshInstance3D in _body_meshes:
		m.material_overlay = _glitch_overlay
	_apply_part_tints()

	# Stagger the first ambient flicker so a cluster of enemies doesn't
	# pulse in lockstep when they spawn together.
	_ambient_flicker_timer = randf_range(2.0, _AMBIENT_FLICKER_INTERVALS.max())

	# Reparent the inspector-placed wheel nodes under runtime BoneAttachment3Ds
	# so they track the foot bones. keep_global_transform=true means the user's
	# tuned scene-editor position is preserved at bind pose.
	_reparent_under_bone(_wheels_left, _FOOT_L_BONE)
	_reparent_under_bone(_wheels_right, _FOOT_R_BONE)
	if _wheels_left != null: _wheels_left.visible = false
	if _wheels_right != null: _wheels_right.visible = false


func _collect_mannequin_meshes(n: Node) -> void:
	if n is MeshInstance3D and str(n.name).begins_with("Mannequin_"):
		_body_meshes.append(n as MeshInstance3D)
	for c: Node in n.get_children():
		_collect_mannequin_meshes(c)


# Duplicate the source material per mesh part so tints are per-instance, then
# stamp the configured albedo. Falls back to a fresh StandardMaterial3D if the
# part's surface has no source material (shouldn't happen with the stock GLB
# but guards against future imports). No-op for parts whose name isn't in the
# tint table — keeps the override slot empty so they read the shared material.
func _apply_part_tints() -> void:
	var by_name := {
		&"Mannequin_Head": tint_head,
		&"Mannequin_Body": tint_body,
		&"Mannequin_ArmLeft": tint_arm_left,
		&"Mannequin_ArmRight": tint_arm_right,
		&"Mannequin_LegLeft": tint_leg_left,
		&"Mannequin_LegRight": tint_leg_right,
	}
	for m: MeshInstance3D in _body_meshes:
		if not by_name.has(m.name):
			continue
		var color: Color = by_name[m.name]
		var src: Material = null
		if m.mesh != null and m.mesh.get_surface_count() > 0:
			src = m.mesh.surface_get_material(0)
		var dup: BaseMaterial3D
		if src is BaseMaterial3D:
			dup = (src as BaseMaterial3D).duplicate() as BaseMaterial3D
		else:
			dup = StandardMaterial3D.new()
		dup.albedo_color = color
		m.set_surface_override_material(0, dup)


## Create a BoneAttachment3D under the skin's skeleton bound to `bone_name`
## and reparent `wheels` under it, preserving global transform so the user's
## editor-tuned position still reads correctly once the bone moves.
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


## Force loop_mode = LOOP_LINEAR on named clips in the player's library.
## Called once at _ready after the merge; no-op for clips that don't exist.
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
	# Cycle the Idle clip variant only when entering Idle from another state
	# (avoids flicker between A/B on every frame while standing still).
	if state_machine.get_current_node() != &"Idle" and _idle_anim_node != null:
		_idle_cycle_index = (_idle_cycle_index + 1) % _IDLE_CLIPS.size()
		_idle_anim_node.animation = _IDLE_CLIPS[_idle_cycle_index]
	state_machine.travel("Idle")
func move() -> void: state_machine.travel("Move")
func fall() -> void: state_machine.travel("Fall")
func jump() -> void: state_machine.travel("Jump")
func edge_grab() -> void: state_machine.travel("EdgeGrab")
func wall_slide() -> void: state_machine.travel("WallSlide")
# attack randomizes between punch + kick by swapping the EdgeGrab state's
# clip reference before starting — cop's hands are empty so these are the
# two fitting unarmed strikes. Add more clips to _ATTACK_CLIPS for variety.
func attack() -> void:
	if _edge_anim_node != null:
		_edge_anim_node.animation = _ATTACK_CLIPS[randi() % _ATTACK_CLIPS.size()]
	state_machine.start("EdgeGrab")




func land() -> void:
	# Jump_Land is a short one-shot. Skip if we're not airborne-to-ground
	# (state_machine already tracks this — start() forces, travel() would
	# be nicer for smoothness but Land has no transitions IN yet).
	state_machine.start("Land")


func on_hit() -> void:
	# Alternate between Hit_A / Hit_B per damage event so repeated hits
	# don't look identical.
	if _hit_anim_node != null:
		_hit_anim_node.animation = _HIT_CLIPS[randi() % _HIT_CLIPS.size()]
	state_machine.start("Hit")


func dash(_direction: Vector3 = Vector3.ZERO) -> void:
	# Always Dodge_Forward — the directional pick (left/right/back) read as
	# stutter-step rather than a committed dash, and the forward roll reads
	# right regardless of where the player is actually moving.
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
	if _glitch_overlay != null:
		_glitch_overlay.set_shader_parameter(&"damage_alpha", damage_tint)


func set_glitch_progress(value: float) -> void:
	_death_glitch_value = clampf(value, 0.0, 1.0)
	_push_glitch_uniform()


func _push_glitch_uniform() -> void:
	if _glitch_overlay == null:
		return
	# The shader takes one combined value — death ramp and ambient blip both
	# contribute, max() so the louder one wins.
	var v: float = maxf(_death_glitch_value, _ambient_glitch_value)
	_glitch_overlay.set_shader_parameter(&"glitch_progress", v)


func _process(delta: float) -> void:
	# Ambient flicker: pulse the glitch overlay 0->1->0 over _AMBIENT_FLICKER_DURATION
	# every 5/7/13s while alive. _death_glitch_value (driven by the body during
	# the death sequence) wins via the max() in _push_glitch_uniform.
	if _ambient_flicker_active:
		_ambient_flicker_elapsed += delta
		var t: float = _ambient_flicker_elapsed / _AMBIENT_FLICKER_DURATION
		# Triangle wave: ramp up to 1.0 at t=0.5, back to 0 at t=1.0.
		_ambient_glitch_value = 1.0 - absf(t * 2.0 - 1.0) if t < 1.0 else 0.0
		if t >= 1.0:
			_ambient_flicker_active = false
			_ambient_glitch_value = 0.0
			_ambient_flicker_timer = _AMBIENT_FLICKER_INTERVALS.pick_random()
		_push_glitch_uniform()
	else:
		_ambient_flicker_timer -= delta
		if _ambient_flicker_timer <= 0.0:
			_ambient_flicker_active = true
			_ambient_flicker_elapsed = 0.0


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
