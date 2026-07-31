# Procedural 11-bone ragdoll rig for Mixamo-skinned skins (e.g. AjSkin), which
# ship no PhysicalBone3D rig. Synthesizes the SAME 11-bone set as the authored
# KayKit rig (no hands/feet/fingers) as direct children of the Skeleton3D,
# colliders disabled until death — so the sandbox's sim engines reparent +
# configure them exactly like the authored rig.
#
# Each bone's node name is the CANONICAL key ("hips","chest",…) the engines
# match on; bone_name is the real mixamo skeleton bone. Joint TYPE/limits/mass
# are set by the engines per-key at kill time, so this builder only lays out the
# bodies (bone binding, capsule sized to bone length, layer/mask).
extends RefCounted

const RADIUS_RATIO := 0.12
const TERMINAL_LEN := 0.16

# [canonical_key, mixamo_bone, child_bone (for capsule length), default_mass]
const SPECS := [
	["hips",       "mixamorig_Hips",         "mixamorig_Spine",       9.8],
	["chest",      "mixamorig_Spine1",       "mixamorig_Neck",       10.0],
	["head",       "mixamorig_Head",         "mixamorig_HeadTop_End", 4.0],
	["upperarm.l", "mixamorig_LeftArm",      "mixamorig_LeftForeArm", 2.0],
	["lowerarm.l", "mixamorig_LeftForeArm",  "mixamorig_LeftHand",    1.1],
	["upperarm.r", "mixamorig_RightArm",     "mixamorig_RightForeArm",2.0],
	["lowerarm.r", "mixamorig_RightForeArm", "mixamorig_RightHand",   1.1],
	["upperleg.l", "mixamorig_LeftUpLeg",    "mixamorig_LeftLeg",     7.0],
	["lowerleg.l", "mixamorig_LeftLeg",      "mixamorig_LeftFoot",    3.2],
	["upperleg.r", "mixamorig_RightUpLeg",   "mixamorig_RightLeg",    7.0],
	["lowerleg.r", "mixamorig_RightLeg",     "mixamorig_RightFoot",   3.2],
]


## Build the rig under `skel`. Idempotent-ish: skips if a bone named "hips"
## already exists (so re-spawns don't stack rigs). Returns bones built.
static func build(skel: Skeleton3D, layer: int, mask: int) -> int:
	if skel.get_node_or_null("hips") != null:
		return 0
	var built := 0
	for spec: Array in SPECS:
		var bidx := skel.find_bone(spec[1])
		if bidx == -1:
			push_warning("mixamo_rig: bone '%s' not found on %s" % [spec[1], skel])
			continue
		var length := _bone_length(skel, spec[2])
		var pb := PhysicalBone3D.new()
		pb.name = spec[0]           # canonical key (engines match on this)
		pb.bone_name = spec[1]      # real mixamo skeleton bone
		pb.mass = spec[3]
		pb.collision_layer = layer
		pb.collision_mask = mask
		pb.friction = 1.0
		pb.angular_damp = 1.5
		_attach_capsule(pb, length)
		skel.add_child(pb)
		built += 1
	return built


# Bone length = the child bone's local rest offset magnitude (Mixamo bones point
# +Y toward their child, so this is the segment length along the capsule axis).
static func _bone_length(skel: Skeleton3D, child_bone: String) -> float:
	var ci := skel.find_bone(child_bone)
	if ci == -1:
		return TERMINAL_LEN
	return maxf(skel.get_bone_rest(ci).origin.length(), 0.06)


static func _attach_capsule(pb: PhysicalBone3D, length: float) -> void:
	var shape := CapsuleShape3D.new()
	shape.height = maxf(length, 0.08)
	shape.radius = clampf(length * RADIUS_RATIO, 0.03, shape.height * 0.5)
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = Vector3(0, length * 0.5, 0)   # center along the bone's +Y
	col.disabled = true                          # enabled at death by the engine
	pb.add_child(col)
	pb.body_offset = Transform3D(Basis(), Vector3(0, length * 0.5, 0))
