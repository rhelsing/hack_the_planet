# Engine B — passive ragdoll with anatomical limits + influence ease-in.
#
# Scene-15 style: the body SLUMPS out of its frozen pose instead of snapping.
# No launch impulse (it collapses in place under gravity), anatomical cone/hinge
# limits + segment masses (heavy torso, light extremities) so it folds like a
# body, low damping, and an influence 0->1 ease-in. No stabilizer / freeze /
# settle — it just comes to rest naturally on the limits + friction.
#
# Limit values are the KayKit map of Ragdoll.PROC_SPECS (the tested anatomical
# table). Sign conventions on the elbow/knee hinges mirror the shipping skin's
# authored rig so left/right fold the correct way.
extends "res://player/ragdoll/engine_sim_base.gd"


func engine_name() -> String:
	return "B · passive + limits + ease-in"


func apply_tuning(v: Dictionary) -> void:
	super(v)
	# Ease-in speed. Now that B also gets the shared launch push, a slow ease
	# would let the pushed bodies fly while the mesh still shows the frozen pose
	# (visible lurch). Default fast (~0.15 s to full physics); lower it toward a
	# slow slump only when back_speed is low. ease_speed >= huge = no ease-in.
	_ease_speed = float(v.get("ease_speed", 6.0))


func _configure_bone(pb: PhysicalBone3D, bone: String) -> void:
	# Anatomical give: low damping so it folds freely and settles on the limits,
	# not the stiff 29 of Engine A. Driven by the tuning "damp_all" so the tuner
	# knob applies verbatim in-game. Friction maxed so it doesn't skate on rest.
	pb.angular_damp = float(_tuning.get("damp_all", 1.5))
	pb.linear_damp = 0.0
	pb.friction = 1.0
	pb.gravity_scale = _gravity_scale()
	match bone:
		"hips":
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_NONE
			pb.mass = 9.8
		"chest":
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
			pb.mass = 10.0
			pb.set("joint_constraints/swing_span", 22.0)
			pb.set("joint_constraints/twist_span", 15.0)
		"head":
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
			pb.mass = 4.0
			pb.set("joint_constraints/swing_span", 30.0)
			pb.set("joint_constraints/twist_span", 25.0)
		"upperarm.l", "upperarm.r":
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
			pb.mass = 2.0
			pb.set("joint_constraints/swing_span", 75.0)
			pb.set("joint_constraints/twist_span", 45.0)
		"lowerarm.l":
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
			pb.mass = 1.1
			pb.set("joint_constraints/angular_limit_lower", -110.0)
			pb.set("joint_constraints/angular_limit_upper", 10.0)
		"lowerarm.r":
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
			pb.mass = 1.1
			pb.set("joint_constraints/angular_limit_lower", -10.0)
			pb.set("joint_constraints/angular_limit_upper", 110.0)
		"upperleg.l", "upperleg.r":
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
			pb.mass = 7.0
			pb.set("joint_constraints/swing_span", 45.0)
			pb.set("joint_constraints/twist_span", 30.0)
		"lowerleg.l", "lowerleg.r":
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
			pb.mass = 3.2
			pb.set("joint_constraints/angular_limit_lower", -10.0)
			pb.set("joint_constraints/angular_limit_upper", 120.0)
