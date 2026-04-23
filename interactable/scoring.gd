class_name InteractionScoring
extends RefCounted

## Pure scoring math for InteractionSensor candidate ranking. Zero
## dependencies — safe to unit-test without any autoloads loaded.
##
## Sensor passes in raw primitives and gets back a comparable float.
## Higher = better focus candidate. -INF = rejected (out of range or
## behind the player beyond the facing cutoff).


static func score(
	body_pos: Vector3,
	body_forward: Vector3,
	candidate_pos: Vector3,
	focus_priority: float,
	detection_range_m: float,
	w_proximity: float,
	w_body_facing: float,
	w_camera_facing: float,
	camera_forward: Vector3,
	facing_cutoff_value: float,
) -> float:
	var to_it := candidate_pos - body_pos
	var dist := to_it.length()
	if dist > detection_range_m: return -INF
	var dir := to_it / maxf(dist, 0.0001)
	var facing := body_forward.dot(dir)
	if facing < facing_cutoff_value: return -INF

	var s := 0.0
	s += w_proximity * (1.0 - dist / detection_range_m)
	s += w_body_facing * maxf(0.0, facing)
	if w_camera_facing > 0.0 and camera_forward.length_squared() > 0.0001:
		s += w_camera_facing * maxf(0.0, camera_forward.dot(dir))
	# Priority is additive, not multiplicative — a score near 0 shouldn't
	# zero out priority. Small bonus centered on focus_priority=1.0 (no effect).
	return s + (focus_priority - 1.0) * 0.25
