# Tuner engine "B · game" — a live pass-through to the skin's real start_ragdoll,
# which now runs Engine B. It pushes the tuner knobs onto the skin's B @exports
# so what you tune here reproduces the SHIPPING enemy death verbatim (there is no
# separate copy — this literally runs the game code).
extends "res://player/ragdoll/ragdoll_engine.gd"


func engine_name() -> String:
	return "B · game (live start_ragdoll)"


func apply_tuning(v: Dictionary) -> void:
	if skin == null:
		return
	# Drive the skin's Engine-B @exports from the knobs so skin.start_ragdoll
	# reproduces the tuned feel exactly.
	skin.set(&"ragdoll_gravity_scale", v.get("gravity", 4.2))
	skin.set(&"ragdoll_angular_damp", v.get("damp_all", 1.5))
	skin.set(&"ragdoll_ease_speed", v.get("ease_speed", 6.0))
	skin.set(&"ragdoll_spin_yaw_max", v.get("spin_yaw", 15.0))
	skin.set(&"ragdoll_spin_roll_max", v.get("spin_roll", 15.0))
	# The sandbox already scaled the collision shapes live (its collider sliders),
	# so neutralize the skin's own start_ragdoll scaling to avoid double-scaling
	# (the game keeps its authored @export scales — it never runs the sandbox
	# scaler, so in-game it's single-scaled).
	skin.set(&"ragdoll_collider_radius_scale", 1.0)
	skin.set(&"ragdoll_collider_length_scale", 1.0)
	skin.set(&"ragdoll_head_radius_scale", 1.0)
	skin.set(&"ragdoll_head_length_scale", 1.0)
	skin.set(&"ragdoll_head_offset", 0.0)


func start(launch_velocity: Vector3) -> void:
	if skin != null and skin.has_method(&"start_ragdoll"):
		skin.call(&"start_ragdoll", launch_velocity)


func is_active() -> bool:
	return skin != null and skin.has_method(&"is_ragdolled") and bool(skin.call(&"is_ragdolled"))


func reference_position() -> Vector3:
	if skin != null and skin.has_method(&"ragdoll_reference_position"):
		return skin.call(&"ragdoll_reference_position")
	return skin.global_position if skin != null else Vector3.ZERO
