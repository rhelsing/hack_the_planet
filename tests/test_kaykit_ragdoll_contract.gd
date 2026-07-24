extends SceneTree

## Contract test for the scene-authored ragdoll rig in kaykit_skin.tscn.
## Asserts the 11-bone set (no hands, no feet — user call: welded limbs are
## the stiff-toy look), joint types, collision layers, disabled-until-death
## shapes, and the start_ragdoll handoff. Bone binding resolves through the
## skeleton's internal simulator on the first processed frame, so assertions
## run after a few frames instead of inside _init.
## Run: godot --headless --script res://tests/test_kaykit_ragdoll_contract.gd

const EXPECTED_JOINTS := {
	"hips": PhysicalBone3D.JOINT_TYPE_NONE,
	"chest": PhysicalBone3D.JOINT_TYPE_CONE,
	"head": PhysicalBone3D.JOINT_TYPE_CONE,
	"upperarm.l": PhysicalBone3D.JOINT_TYPE_CONE,
	"upperarm.r": PhysicalBone3D.JOINT_TYPE_CONE,
	"lowerarm.l": PhysicalBone3D.JOINT_TYPE_HINGE,
	"lowerarm.r": PhysicalBone3D.JOINT_TYPE_HINGE,
	"upperleg.l": PhysicalBone3D.JOINT_TYPE_CONE,
	"upperleg.r": PhysicalBone3D.JOINT_TYPE_CONE,
	"lowerleg.l": PhysicalBone3D.JOINT_TYPE_HINGE,
	"lowerleg.r": PhysicalBone3D.JOINT_TYPE_HINGE,
}
const BANNED_BONES := ["hand", "wrist", "foot", "toes"]

var _frames := 0
var _skin: Node
var _skel: Skeleton3D
var _failures: Array[String] = []


func _init() -> void:
	var scene: PackedScene = load("res://player/skins/kaykit/kaykit_skin.tscn")
	_skin = scene.instantiate()
	root.add_child(_skin)
	_skel = _skin.get_node_or_null("Model/Rig_Medium/Skeleton3D")
	if _skel == null:
		print("FAIL: no skeleton at Model/Rig_Medium/Skeleton3D")
		quit(1)
		return
	process_frame.connect(_tick)


func _check(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _tick() -> void:
	_frames += 1
	if _frames < 5:
		return

	var bones: Dictionary = {}
	for c: Node in _skel.get_children():
		if c is PhysicalBone3D:
			bones[String(c.get("bone_name"))] = c

	_check(bones.size() == EXPECTED_JOINTS.size(),
		"expected %d physical bones, found %d" % [EXPECTED_JOINTS.size(), bones.size()])
	for bone_name: String in EXPECTED_JOINTS:
		_check(bones.has(bone_name), "missing physical bone for '%s'" % bone_name)
	for bone_name: String in bones:
		for banned: String in BANNED_BONES:
			_check(not bone_name.contains(banned),
				"bone '%s' should not be simulated (no hands/feet)" % bone_name)
		var pb := bones[bone_name] as PhysicalBone3D
		if EXPECTED_JOINTS.has(bone_name):
			_check(pb.joint_type == EXPECTED_JOINTS[bone_name],
				"'%s' joint_type=%d, expected %d" % [bone_name, pb.joint_type, EXPECTED_JOINTS[bone_name]])
		_check(pb.get_bone_id() != -1, "'%s' did not bind to a skeleton bone" % bone_name)
		_check(pb.collision_layer == 8, "'%s' layer=%d, expected 8 (ragdoll)" % [bone_name, pb.collision_layer])
		_check(pb.collision_mask == 15, "'%s' mask=%d, expected 15" % [bone_name, pb.collision_mask])
		var cs := pb.get_node_or_null("CollisionShape3D") as CollisionShape3D
		_check(cs != null and cs.shape != null, "'%s' has no collision shape" % bone_name)
		if cs != null:
			_check(cs.disabled, "'%s' shape should be disabled before death" % bone_name)

	# Handoff: start_ragdoll enables shapes, kills the AnimationTree, flags
	# active. Second call is a no-op (no crash, no duplicate work).
	_check(not _skin.call(&"is_ragdolled"), "skin reports ragdolled before start_ragdoll")
	_skin.call(&"start_ragdoll", Vector3(4, 4, 0))
	_skin.call(&"start_ragdoll", Vector3(4, 4, 0))
	_check(_skin.call(&"is_ragdolled"), "is_ragdolled false after start_ragdoll")
	var tree := _skin.get_node_or_null("AnimationTree") as AnimationTree
	_check(tree != null and not tree.active, "AnimationTree still active after start_ragdoll")
	for bone_name: String in bones:
		var cs2 := (bones[bone_name] as PhysicalBone3D).get_node_or_null("CollisionShape3D") as CollisionShape3D
		if cs2 != null:
			_check(not cs2.disabled, "'%s' shape still disabled after start_ragdoll" % bone_name)
	var ref_pos: Vector3 = _skin.call(&"ragdoll_reference_position")
	_check(ref_pos.is_finite(), "ragdoll_reference_position not finite")

	if _failures.is_empty():
		print("test_kaykit_ragdoll_contract: PASS (%d bones checked)" % bones.size())
		quit(0)
	else:
		for f: String in _failures:
			print("FAIL: %s" % f)
		quit(1)
