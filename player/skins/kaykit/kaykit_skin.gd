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
# Cached @export tints for set_faction_tint — captured the first time
# faction sets them, restored when faction returns to amount=0.
var _faction_tints_captured: bool = false
var _default_tint_head: Color
var _default_tint_body: Color
var _default_tint_arm_left: Color
var _default_tint_arm_right: Color
var _default_tint_leg_left: Color
var _default_tint_leg_right: Color

# Per-instance memo of the last albedo applied to each mannequin part. Keyed
# by part name (e.g. "Mannequin_Head"). _apply_part_tints early-outs any part
# whose color matches the cached entry — repeat conversions of an already-
# correctly-tinted pawn become free.
var _last_applied_tints: Dictionary = {}

# Class-wide pool of duplicated tint materials, keyed by [src_material_id,
# color]. Sharing one BaseMaterial3D across every pawn that requests the
# same (source, color) pair turns N simultaneous faction conversions into
# 1 set of pipeline-state-object compiles instead of N — load-bearing on
# Intel Mac (Metal) where bulk PSO creation stalls or crashes the driver.
static var _shared_tint_materials: Dictionary = {}

const _GLITCH_SHADER: Shader = preload("res://player/skins/kaykit/death_glitch.gdshader")

## TEMP Intel-Mac instrumentation. Mirror with game.gd / player_body.gd.
const DEBUG_INTEL: bool = false


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
	var _t0_us: int = Time.get_ticks_usec() if DEBUG_INTEL else 0
	var _local_skip: int = 0
	var _cache_hits: int = 0
	var _new_dups: int = 0
	for m: MeshInstance3D in _body_meshes:
		if not by_name.has(m.name):
			continue
		var color: Color = by_name[m.name]
		if _last_applied_tints.get(m.name) == color:
			_local_skip += 1
			continue
		var src: Material = null
		if m.mesh != null and m.mesh.get_surface_count() > 0:
			src = m.mesh.surface_get_material(0)
		var src_id: int = src.get_instance_id() if src != null else 0
		var key: Array = [src_id, color]
		var dup: BaseMaterial3D = _shared_tint_materials.get(key)
		if dup == null:
			if src is BaseMaterial3D:
				dup = (src as BaseMaterial3D).duplicate() as BaseMaterial3D
			else:
				dup = StandardMaterial3D.new()
			dup.albedo_color = color
			_shared_tint_materials[key] = dup
			_new_dups += 1
		else:
			_cache_hits += 1
		m.set_surface_override_material(0, dup)
		_last_applied_tints[m.name] = color
	if DEBUG_INTEL:
		# Per-skin tint stats. dups= fresh BaseMaterial3D allocations (the
		# expensive PSO-trigger work); hits= shared-cache reuses; skip=
		# parts whose color hadn't changed. On a healthy burst pawn 0 should
		# show ~6 dups and pawns 1+ should show 0 dups / 6 hits.
		print("[tint-perf] f=%d t_us=%d dups=%d hits=%d skip=%d cache_size=%d %s" % [
			Engine.get_process_frames(),
			Time.get_ticks_usec() - _t0_us,
			_new_dups,
			_cache_hits,
			_local_skip,
			_shared_tint_materials.size(),
			get_path(),
		])


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


func set_faction_tint(color: Color, amount: float) -> void:
	# Per-part albedo override. amount > 0 → push `color` into all six
	# Mannequin parts (head, body, arms, legs) and re-apply. amount == 0
	# → restore the authored per-part tints. The first call caches the
	# authored values via _captured_default_tints so red→green can revert
	# cleanly. Overlay shader uniforms left at 0 — pure-color reskin.
	if amount > 0.0:
		_capture_default_tints_if_needed()
		tint_head = color
		tint_body = color
		tint_arm_left = color
		tint_arm_right = color
		tint_leg_left = color
		tint_leg_right = color
	else:
		_restore_default_tints_if_captured()
	_apply_part_tints()


func _capture_default_tints_if_needed() -> void:
	if _faction_tints_captured:
		return
	_faction_tints_captured = true
	_default_tint_head = tint_head
	_default_tint_body = tint_body
	_default_tint_arm_left = tint_arm_left
	_default_tint_arm_right = tint_arm_right
	_default_tint_leg_left = tint_leg_left
	_default_tint_leg_right = tint_leg_right


func _restore_default_tints_if_captured() -> void:
	if not _faction_tints_captured:
		return
	tint_head = _default_tint_head
	tint_body = _default_tint_body
	tint_arm_left = _default_tint_arm_left
	tint_arm_right = _default_tint_arm_right
	tint_leg_left = _default_tint_leg_left
	tint_leg_right = _default_tint_leg_right


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


# --- Ragdoll death ---
# Scene-authored PhysicalBone3D rig under Model/Rig_Medium/Skeleton3D: 11
# bones (hips, chest, head, upper/lower arms, upper/lower legs). Hands and
# feet have no bodies — they ride their parent limb, which is what makes the
# corpse read as a stiff action figure. Colliders are authored disabled so
# live pawns cost nothing in broadphase; start_ragdoll enables them and hands
# the skeleton to physics. One-way — dying pawns queue_free from the body side.

## Multiplies the launch velocity the body passes into start_ragdoll. Each
## bone gets impulse = mass * velocity, so the whole rig launches uniformly
## at the requested speed; raise this for more send-off.
@export var ragdoll_impulse_scale: float = 1.0

## Gravity multiplier applied to every bone at start_ragdoll. Pawns fall at
## the body's -30 m/s² gameplay gravity but the physics server default is
## 9.8 — without this the corpse floats at a third of game gravity.
@export var ragdoll_gravity_scale: float = 4.2

## Per-tick speed caps while ragdolled. Ground impact can spike GodotPhysics
## bone velocities into the hundreds of m/s (solver depenetration + joint
## snapback); clamping every physics tick makes detonation impossible — the
## excess bleeds off through damping and reads as stiff clatter instead.
@export var ragdoll_max_bone_speed: float = 55.0
@export var ragdoll_max_bone_spin: float = 25.0

## Freeze every bone's rotation the instant the corpse lands (first bone
## contact after the hips have dropped ragdoll_freeze_min_drop below their
## launch height). The statue keeps its linear momentum and slides out on
## friction — no post-landing tumbling.
@export var ragdoll_freeze_rotation_on_land := true
## Hips must fall this far (m) below their launch height before the landing
## freeze can arm — otherwise a stealth-killed pawn whose feet already touch
## the floor would freeze while still upright.
@export var ragdoll_freeze_min_drop := 0.2
## Seconds between the first landing contact and the rotation lock — gives
## the corpse its impact tumble before it goes rigid and slides.
@export var ragdoll_freeze_delay := 0.3

## Random spin injected at launch, as one coherent whole-body rotation.
## Yaw: [-max, max] rad/s about vertical — helicopter spin, either way.
## Roll: [0, max] rad/s about the horizontal axis perpendicular to travel,
## signed so the head tips toward travel — always reads as rolling backward
## off the hit, never a forward flip.
@export var ragdoll_spin_yaw_max := 15.0
@export var ragdoll_spin_roll_max := 15.0

var _ragdoll_active := false
var _ragdoll_bones: Array[PhysicalBone3D] = []
var _ragdoll_hips: PhysicalBone3D = null
var _ragdoll_frozen := false
var _ragdoll_start_hips_y := 0.0
# -1 = not landed yet; >= 0 counts up from first contact toward freeze_delay.
var _ragdoll_land_timer := -1.0


## Hand the skeleton to physics. `launch_velocity` is a world-space velocity
## (same units as the knockback death's launch), converted per-bone into a
## momentum-consistent impulse so the rig takes off as one stiff piece.
func start_ragdoll(launch_velocity: Vector3) -> void:
	if _ragdoll_active:
		return
	var skel := _find_skeleton(self)
	if skel == null:
		push_error("KayKitSkin.start_ragdoll: no skeleton under %s" % get_path())
		return
	var bones: Array[PhysicalBone3D] = []
	for c: Node in skel.get_children():
		if c is PhysicalBone3D:
			bones.append(c as PhysicalBone3D)
	if bones.is_empty():
		push_error("KayKitSkin.start_ragdoll: no PhysicalBone3D rig in %s" % get_path())
		return
	_ragdoll_active = true
	_ragdoll_bones = bones
	_ragdoll_frozen = false
	_ragdoll_land_timer = -1.0
	for pb: PhysicalBone3D in bones:
		if pb.get("bone_name") == "hips":
			_ragdoll_hips = pb
			break
	animation_tree.active = false
	for pb: PhysicalBone3D in bones:
		pb.gravity_scale = ragdoll_gravity_scale
		# Landing detection reads real contacts off the direct body state —
		# works at any ground height, unlike a global-y threshold.
		PhysicsServer3D.body_set_max_contacts_reported(pb.get_rid(), 1)
		for s: Node in pb.get_children():
			if s is CollisionShape3D:
				(s as CollisionShape3D).disabled = false
	skel.physical_bones_start_simulation()
	var v: Vector3 = launch_velocity * ragdoll_impulse_scale
	for pb: PhysicalBone3D in bones:
		pb.apply_central_impulse(v * pb.mass)
	_apply_launch_spin(bones, v)
	_ragdoll_start_hips_y = ragdoll_reference_position().y


## Give the rig a coherent random tumble: same angular velocity on every
## bone PLUS the matching ω×r linear component about the hips. Without the
## linear part, the per-bone angular damping (29+) eats the spin within a
## few frames and the tumble never reads.
func _apply_launch_spin(bones: Array[PhysicalBone3D], launch: Vector3) -> void:
	if ragdoll_spin_yaw_max <= 0.0 and ragdoll_spin_roll_max <= 0.0:
		return
	var dir: Vector3 = launch
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		return
	dir = dir.normalized()
	var omega: Vector3 = Vector3.UP * randf_range(-ragdoll_spin_yaw_max, ragdoll_spin_yaw_max) \
		+ Vector3.UP.cross(dir) * randf_range(0.0, ragdoll_spin_roll_max)
	var com: Vector3 = ragdoll_reference_position()
	for pb: PhysicalBone3D in bones:
		pb.angular_velocity = omega
		pb.apply_central_impulse(omega.cross(pb.global_position - com) * pb.mass)


func _physics_process(delta: float) -> void:
	# Ragdoll stabilizer: hard speed cap per bone per tick (see the export
	# comment — GodotPhysics ground impacts can otherwise explode the rig).
	if not _ragdoll_active:
		return
	if _ragdoll_frozen:
		# Frozen statue: every bone shares the hips' linear velocity, zero
		# spin. Axis locks alone leave linear DOFs free — segments can still
		# orbit-translate around their joint pivots (parallelogram flail)
		# and the settling torso presses the thin arm capsules through the
		# floor. Velocity sync makes the assembly translate as one piece.
		if _ragdoll_hips != null:
			var hv: Vector3 = _ragdoll_hips.linear_velocity
			for pb: PhysicalBone3D in _ragdoll_bones:
				if pb != _ragdoll_hips:
					pb.linear_velocity = hv
				pb.angular_velocity = Vector3.ZERO
		return
	for pb: PhysicalBone3D in _ragdoll_bones:
		var lv: Vector3 = pb.linear_velocity
		if lv.length_squared() > ragdoll_max_bone_speed * ragdoll_max_bone_speed:
			pb.linear_velocity = lv.normalized() * ragdoll_max_bone_speed
		var av: Vector3 = pb.angular_velocity
		if av.length_squared() > ragdoll_max_bone_spin * ragdoll_max_bone_spin:
			pb.angular_velocity = av.normalized() * ragdoll_max_bone_spin
	_tick_land_freeze(delta)


## Landing freeze: once the hips have fallen far enough and any bone touches
## something, wait ragdoll_freeze_delay (the impact tumble), then lock every
## bone's angular axes and zero its spin. Linear DOFs stay free, so the whole
## assembly slides as one statue and friction stops it.
func _tick_land_freeze(delta: float) -> void:
	if _ragdoll_frozen or not ragdoll_freeze_rotation_on_land:
		return
	if _ragdoll_land_timer < 0.0:
		if _ragdoll_start_hips_y - ragdoll_reference_position().y < ragdoll_freeze_min_drop:
			return
		for pb: PhysicalBone3D in _ragdoll_bones:
			var state := PhysicsServer3D.body_get_direct_state(pb.get_rid())
			if state != null and state.get_contact_count() > 0:
				_ragdoll_land_timer = 0.0
				break
		return
	_ragdoll_land_timer += delta
	if _ragdoll_land_timer < ragdoll_freeze_delay:
		return
	_ragdoll_frozen = true
	for pb: PhysicalBone3D in _ragdoll_bones:
		pb.set_axis_lock(PhysicsServer3D.BODY_AXIS_ANGULAR_X, true)
		pb.set_axis_lock(PhysicsServer3D.BODY_AXIS_ANGULAR_Y, true)
		pb.set_axis_lock(PhysicsServer3D.BODY_AXIS_ANGULAR_Z, true)
		pb.angular_velocity = Vector3.ZERO


func is_ragdolled() -> bool:
	return _ragdoll_active


## Where the corpse actually ended up — the hips bone's global position.
## The body node stays at the death spot while the bones tumble away, so
## confetti/glitch effects should anchor here, not at the body origin.
func ragdoll_reference_position() -> Vector3:
	if _ragdoll_hips != null:
		return _ragdoll_hips.global_position
	var skel := _find_skeleton(self)
	if skel != null:
		for c: Node in skel.get_children():
			if c is PhysicalBone3D and c.get("bone_name") == "hips":
				return (c as PhysicalBone3D).global_position
	return global_position


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
