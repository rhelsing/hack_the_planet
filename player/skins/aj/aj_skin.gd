class_name AjSkin
extends CharacterSkin

## Mixamo "Aj" character (83 bones, mixamorig_* naming with underscores —
## Blender's glTF exporter normalizes the FBX's `:` separators). Animation
## library is merged from 15 Mixamo anim FBXs + Aj's own bind-pose action
## via tools/import_mixamo.py. anime_character template: damage tint
## overlay flushes the 4-mesh body on hit, all states have real clip
## mappings (no idle-fallback for action states).

@export var extra_animation_sources: Array[PackedScene] = []

@export var skate_root_y: float = 0.134

const _FOOT_L_BONE := &"mixamorig_LeftFoot"
const _FOOT_R_BONE := &"mixamorig_RightFoot"
@onready var _wheels_left: Node3D = $WheelsLeft
@onready var _wheels_right: Node3D = $WheelsRight
@onready var _dust_particles: GPUParticles3D = %DustParticles

@onready var animation_tree: AnimationTree = %AnimationTree
@onready var state_machine: AnimationNodeStateMachinePlayback = animation_tree.get("parameters/StateMachine/playback")
@onready var move_tilt_path: String = "parameters/StateMachine/Move/tilt/add_amount"

var _dash_anim_node: AnimationNodeAnimation
var _edge_anim_node: AnimationNodeAnimation
const _ATTACK_CLIPS := [&"Punching"]

var _hit_anim_node: AnimationNodeAnimation
const _HIT_CLIPS := [&"Yelling"]

var _idle_anim_node: AnimationNodeAnimation
const _IDLE_CLIPS := [&"Breathing Idle"]
var _idle_cycle_index: int = 0

var _damage_overlay: StandardMaterial3D
var _body_meshes: Array[MeshInstance3D] = []

# Idle-dance — when active (set externally, e.g. hub.gd post-L4 victory),
# the skin watches for sustained idle time and after `idle_dance_threshold_s`
# the AnimationTree is disabled and a random clip from `idle_dance_clips`
# plays directly via the AnimationPlayer. New random clip every random
# interval from `idle_dance_intervals_sec`. Any non-idle contract method
# (move/jump/dash/etc.) re-enables the tree and snaps back to gameplay.
@export var idle_dance_enabled: bool = false
@export var idle_dance_clips: Array[StringName] = []
@export var idle_dance_intervals_sec: Array[float] = [5.0, 7.0, 13.0]
@export var idle_dance_threshold_s: float = 1.0

var _idle_time_s: float = 0.0
var _idle_dance_active: bool = false
var _next_dance_swap_at_s: float = 0.0


func _ready() -> void:
	var primary := _find_anim_player(self)
	if primary == null:
		return
	for src_scene: PackedScene in extra_animation_sources:
		if src_scene == null:
			continue
		_merge_animations_from(primary, src_scene)

	_force_loop_linear(primary, [
		"Breathing Idle", "Crouching Idle",
		"Walking", "Crouched Walking",
		"Running", "Standard Run",
		"Talking", "Talking(1)",
		# Victory-state dances loop until the swap timer fires another pick.
		"Dancing Twerk", "Hip Hop Dancing", "Hip Hop Dancing(1)",
		"Hip Hop Dancing(2)", "Shuffling", "Silly Dancing", "Wave Hip Hop Dance",
	])

	var outer := animation_tree.tree_root as AnimationNodeBlendTree
	if outer != null:
		var sm := outer.get_node(&"StateMachine") as AnimationNodeStateMachine
		if sm != null:
			_dash_anim_node = sm.get_node(&"Dash") as AnimationNodeAnimation
			_edge_anim_node = sm.get_node(&"EdgeGrab") as AnimationNodeAnimation
			_hit_anim_node = sm.get_node(&"Hit") as AnimationNodeAnimation
			_idle_anim_node = sm.get_node(&"Idle") as AnimationNodeAnimation

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
	var default_lib := primary.get_animation_library(&"")
	if default_lib == null:
		default_lib = AnimationLibrary.new()
		primary.add_animation_library(&"", default_lib)
	# Mixamo single-clip FBX files all label their animation `mixamo_com`
	# — collision-prone when merging multiple. Detect that case and
	# rename to the source file's stem so each clip lands as its filename.
	var rename_to: StringName = _mixamo_rename_target(scene, src_anim)
	for lib_name: StringName in src_anim.get_animation_library_list():
		var src_lib := src_anim.get_animation_library(lib_name)
		if src_lib == null:
			continue
		for anim_name: StringName in src_lib.get_animation_list():
			var target_name: StringName = rename_to if rename_to != &"" else anim_name
			if not default_lib.has_animation(target_name):
				default_lib.add_animation(target_name, src_lib.get_animation(anim_name))
	instance.queue_free()


func _mixamo_rename_target(scene: PackedScene, src_anim: AnimationPlayer) -> StringName:
	var clip_count: int = 0
	var only_clip_name: String = ""
	for lib_name: StringName in src_anim.get_animation_library_list():
		var lib := src_anim.get_animation_library(lib_name)
		if lib == null:
			continue
		for n: StringName in lib.get_animation_list():
			clip_count += 1
			only_clip_name = String(n)
	if clip_count != 1 or only_clip_name != "mixamo_com":
		return &""
	var path: String = scene.resource_path
	if path.is_empty():
		return &""
	return StringName(path.get_file().get_basename())


# --- CharacterSkin contract ---
func _process(delta: float) -> void:
	if not idle_dance_enabled or state_machine == null or _idle_anim_node == null:
		return
	var is_idle: bool = state_machine.get_current_node() == &"Idle"
	if not is_idle:
		_idle_time_s = 0.0
		if _idle_dance_active:
			_restore_idle_clip()
		return
	_idle_time_s += delta
	if not _idle_dance_active:
		if _idle_time_s >= idle_dance_threshold_s:
			_swap_to_random_dance_clip()
			_idle_dance_active = true
			_next_dance_swap_at_s = _idle_time_s + _pick_dance_interval()
		return
	if _idle_time_s >= _next_dance_swap_at_s:
		_swap_to_random_dance_clip()
		_next_dance_swap_at_s = _idle_time_s + _pick_dance_interval()


# Swap the Idle state's underlying clip to a random dance + restart the Idle
# state so the new clip plays from the start. AnimationTree stays active —
# all other state transitions (Move/Jump/Dash/etc.) keep working normally.
func _swap_to_random_dance_clip() -> void:
	if _idle_anim_node == null or idle_dance_clips.is_empty():
		return
	var primary := _find_anim_player(self)
	if primary == null:
		return
	var clip: StringName = idle_dance_clips[randi() % idle_dance_clips.size()]
	if not primary.has_animation(clip):
		print("[aj_skin] dance clip missing in library: %s" % clip)
		return
	_idle_anim_node.animation = clip
	state_machine.start("Idle")
	print("[aj_skin] dance → %s" % clip)


# Restore the normal Breathing Idle clip on the Idle state slot so the next
# time we enter Idle (e.g. player stops walking) we don't mid-dance.
func _restore_idle_clip() -> void:
	_idle_dance_active = false
	if _idle_anim_node == null:
		return
	if _IDLE_CLIPS.size() > 0:
		_idle_anim_node.animation = _IDLE_CLIPS[_idle_cycle_index]


func _pick_dance_interval() -> float:
	if idle_dance_intervals_sec.is_empty():
		return 5.0
	return idle_dance_intervals_sec[randi() % idle_dance_intervals_sec.size()]


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
