# Engine C — the ep5 KO fall (the "bag of noodles" collapse).
#
# Reproduces the FEEL of scene 56's KO: when a character is knocked out the
# limbs flail loosely — the "bag of noodles" collapse. Every jointed bone is a
# JOINT_TYPE_CONE with a WIDE swing + twist span (near-free), light limb masses,
# and low damping.
#
# WHY CONE, NOT 6DOF: on Jolt a PhysicalBone3D 6DOF joint with its angular limits
# DISABLED is treated as LOCKED (rigid), not free — a kicked forearm rotated 0.2°.
# A wide cone rotated 174°. So the loose joint on Jolt is a fat-span cone, not a
# limit-less 6DOF. (Verified headless; see scratch probe_kick.)
#
# NOTE: KO *fall* only — not ep5's full active ragdoll (alive spring-tracks-
# animation, get-up). Scoped to the death sandbox on purpose.
extends "res://player/ragdoll/engine_sim_base.gd"

# Loose cone so the limbs flail, but not a full noodle (150/120 read as jelly).
const _KO_SWING := 75.0
const _KO_TWIST := 45.0
# Bone self-collision off so adjacent limb capsules can't wedge the pose rigid
# (they overlap at every joint) — that was a second source of stiffness.
const _RAGDOLL_LAYER_BIT := 8

# ep5-style masses: heavy-ish core, very light extremities → the limbs whip.
const _KO_MASS := {
	"hips": 1.0, "chest": 1.0, "head": 0.6,
	"upperarm.l": 0.4, "upperarm.r": 0.4, "lowerarm.l": 0.3, "lowerarm.r": 0.3,
	"upperleg.l": 0.5, "upperleg.r": 0.5, "lowerleg.l": 0.3, "lowerleg.r": 0.3,
}


func engine_name() -> String:
	return "C · KO floppy (loose cone)"


func _configure_bone(pb: PhysicalBone3D, bone: String) -> void:
	# Some damping so it settles instead of jellying forever. Light limbs = whip.
	pb.angular_damp = 0.7
	pb.linear_damp = 0.0
	pb.friction = 0.6
	pb.gravity_scale = _gravity_scale()
	pb.mass = _KO_MASS.get(bone, 0.5)
	# Drop the ragdoll layer from the mask so bones don't collide with EACH OTHER
	# (adjacent limb capsules overlap at every joint and would wedge the pose
	# rigid). They still hit the world/floor via the other mask bits.
	pb.collision_mask = pb.collision_mask & ~_RAGDOLL_LAYER_BIT
	if bone == "hips":
		pb.joint_type = PhysicalBone3D.JOINT_TYPE_NONE
		return
	# Wide cone = the loose joint on Jolt. (A 6DOF with disabled angular limits
	# is treated as LOCKED by Jolt — kicked forearm moved 0.2°; a wide cone
	# moved 174°.)
	pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
	pb.set("joint_constraints/swing_span", _KO_SWING)
	pb.set("joint_constraints/twist_span", _KO_TWIST)
