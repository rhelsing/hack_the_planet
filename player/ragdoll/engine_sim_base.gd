# Shared base for the SIMULATOR-driven fall engines (B passive, C KO).
#
# Both build the same way: freeze the skin's animation (so the skeleton holds its
# last pose), reparent the KayKit authored PhysicalBone3D rig under a FRESH
# PhysicalBoneSimulator3D, enable the colliders, reconfigure each bone via
# _configure_bone() (the ONLY thing the subclass changes — joint type, limits,
# mass, damping), start the simulation, then drive an `influence` 0->1 ease-in.
#
# Backend-agnostic on purpose: only swing_span/twist_span (cone),
# angular_limit_lower/upper (hinge), and per-axis 6DOF limits are used — every
# one honored by BOTH GodotPhysics and Jolt. The bias/softness/relaxation params
# (which Jolt silently ignores) are never touched here, so a backend flip can't
# change B/C behavior.
extends "res://player/ragdoll/ragdoll_engine.gd"

var _sim: PhysicalBoneSimulator3D
var _hips: PhysicalBone3D
var _active := false
var _tuning: Dictionary = {}

# Influence ease-in. _ease_speed in influence-units/sec; a huge value = snap to
# full physics instantly (Engine C). Engine B lowers it so the body slumps out
# of the frozen pose. _EASE_INSTANT is the "no ease-in" sentinel.
const _EASE_INSTANT := 1.0e9
var _ease_speed := _EASE_INSTANT
var _influence := 1.0


## Subclass hook: set joint_type / limits / mass / damping on one physical bone.
func _configure_bone(_pb: PhysicalBone3D, _bone: String) -> void:
	pass


## Subclass hook: optional impulse after simulation starts (Engine C's KO shove).
func _on_started(_launch_velocity: Vector3, _bones: Array) -> void:
	pass


func apply_tuning(v: Dictionary) -> void:
	_tuning = v


func start(launch_velocity: Vector3) -> void:
	if _active or skeleton == null:
		return
	# Freeze the animation so the skeleton holds its pose; physics eases in over
	# it (mirrors scene 15's _player.pause()).
	var tree := _find_anim_tree(skin)
	if tree != null:
		tree.active = false
	# Gather the authored rig, reparent it under a fresh simulator, reconfigure.
	var authored: Array[PhysicalBone3D] = []
	for c: Node in skeleton.get_children():
		if c is PhysicalBone3D:
			authored.append(c as PhysicalBone3D)
	if authored.is_empty():
		push_error("%s: no authored PhysicalBone3D rig under %s" % [engine_name(), skeleton])
		return
	_sim = PhysicalBoneSimulator3D.new()
	_sim.name = "SandboxRagdollSim"
	skeleton.add_child(_sim)
	var bones: Array = []
	for pb: PhysicalBone3D in authored:
		pb.reparent(_sim, true)
		for s: Node in pb.get_children():
			if s is CollisionShape3D:
				(s as CollisionShape3D).disabled = false
		var bone := String(pb.get("bone_name"))
		_configure_bone(pb, bone)
		if bone == "hips":
			_hips = pb
		bones.append(pb)
	_sim.physical_bones_start_simulation()
	_active = true
	# Ease-in: start at 0 influence (pose) and ramp, or snap to 1 (instant).
	_influence = 1.0 if _ease_speed >= _EASE_INSTANT else 0.0
	if "influence" in _sim:
		_sim.influence = _influence
	# SHARED push: every engine gets the same launch impulse + spin from the
	# same sandbox knobs (back/up/side_bias + spin_yaw/roll). The engines differ
	# in how the bones FALL after the push, not in the push itself.
	_apply_launch(bones, launch_velocity)
	_on_started(launch_velocity, bones)


## Shared launch: one coherent impulse (mass-weighted) + a whole-body spin, so
## the rig takes off as one piece — mirrors PlayerBody/skin start_ragdoll math.
func _apply_launch(bones: Array, launch: Vector3) -> void:
	if launch.length_squared() < 1e-6:
		return
	var v: Vector3 = launch * float(_tuning.get("impulse_scale", 1.0))
	for pb: PhysicalBone3D in bones:
		pb.apply_central_impulse(v * pb.mass)
	var yaw_max := float(_tuning.get("spin_yaw", 0.0))
	var roll_max := float(_tuning.get("spin_roll", 0.0))
	if yaw_max <= 0.0 and roll_max <= 0.0:
		return
	var dir: Vector3 = v
	dir.y = 0.0
	if dir.length_squared() < 1e-4:
		return
	dir = dir.normalized()
	var omega: Vector3 = Vector3.UP * randf_range(-yaw_max, yaw_max) \
		+ Vector3.UP.cross(dir) * randf_range(0.0, roll_max)
	var com: Vector3 = reference_position()
	for pb: PhysicalBone3D in bones:
		pb.angular_velocity = omega
		pb.apply_central_impulse(omega.cross(pb.global_position - com) * pb.mass)


func physics_tick(delta: float) -> void:
	if not _active or _sim == null:
		return
	if _influence < 1.0:
		_influence = minf(1.0, _influence + _ease_speed * delta)
		if "influence" in _sim:
			_sim.influence = _influence


func is_active() -> bool:
	return _active


func reference_position() -> Vector3:
	if _hips != null and is_instance_valid(_hips):
		return _hips.global_position
	return skin.global_position if skin != null else Vector3.ZERO


func teardown() -> void:
	if _sim != null and is_instance_valid(_sim):
		_sim.queue_free()
	_sim = null
	_hips = null
	_active = false


## Per-bone gravity multiplier so the corpse falls at the game's tuned rate
## (matches Engine A's ragdoll_gravity_scale default), not the physics 9.8.
func _gravity_scale() -> float:
	return float(_tuning.get("gravity", 4.2))


func _find_anim_tree(n: Node) -> AnimationTree:
	if n is AnimationTree:
		return n as AnimationTree
	for c: Node in n.get_children():
		var r := _find_anim_tree(c)
		if r != null:
			return r
	return null
