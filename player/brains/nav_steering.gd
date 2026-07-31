class_name NavSteering
extends RefCounted

## HOW a pawn gets somewhere — navmesh path following, link jumps, and the
## safety rules around missing paths. Owns the body's NavigationAgent3D.
##
## The layer boundaries (keep them clean):
##   Brain — WHAT/WHY: targets, destinations, speeds. Calls this class.
##   NavSteering — HOW: paths, links, holds. No goals, no combat, no visuals.
##   Body — physics application + CharacterSkin dispatch.
##   Skin — looks only. Swap a dog in; nothing above cares.
##
## Contract: call setup(body) once (idempotent), then steer_to() each tick
## with a destination — returns a horizontal unit direction (ZERO = arrived,
## no usable path, or holding for safety). Then consume_jump(): true = fire
## one jump edge this tick (a NavigationLink3D start was reached; steering
## already aims across the gap). Without a NavigationAgent3D child on the
## body, steer_to falls back to the straight line (unit tests, bare setups)
## and links never fire.

var repath_distance: float = 1.0
var debug_log: bool = false

var _agent: NavigationAgent3D = null
var _searched: bool = false
var _jump_queued: bool = false
var _jump_queued_ms: int = 0
# RVO avoidance (only when the agent has avoidance_enabled): we feed the
# desired velocity, the server returns a crowd-safe one next frame (the
# standard one-frame lag), and steering returns that direction instead.
var _safe_velocity: Vector3 = Vector3.ZERO
var _has_safe_velocity: bool = false
# Body position last steer — a >5m jump means teleport (respawn) → repath.
var _last_body_pos: Vector3 = Vector3.INF
# True while the agent has no usable path; pawn holds position (never
# beelines off a cliff). Also dedups the log.
var _waiting_for_path: bool = false
# DEBUG: deduped waypoint trace anchor.
var _last_waypoint_logged: Vector3 = Vector3.INF
# TEMP DEBUG — why the last steer_to returned zero (or moved). Read by the
# group probe to categorize crowd pauses. Values: moving/arrived/rvo_wait/no_path.
var last_stall_reason: StringName = &"moving"


## Type-based one-shot agent lookup (house style: no %UniqueName for
## swappable parts). Missing agent is a supported mode, but say so once.
func setup(body: Node3D) -> void:
	if _searched:
		return
	_searched = true
	for c: Node in body.get_children():
		if c is NavigationAgent3D:
			_agent = c as NavigationAgent3D
			_agent.link_reached.connect(_on_link_reached)
			if _agent.avoidance_enabled:
				_agent.velocity_computed.connect(_on_velocity_computed)
			break
	if debug_log:
		print("[nav] %s steering=%s" % [
			body.name,
			"navmesh" if _agent != null else "direct (no NavigationAgent3D child)"])


func has_agent() -> bool:
	return _agent != null


func steer_to(body: Node3D, dest: Vector3, arrive: float) -> Vector3:
	setup(body)
	var to_dest := dest - body.global_position
	to_dest.y = 0.0
	var dist := to_dest.length()
	if dist <= arrive or dist < 0.001:
		last_stall_reason = &"arrived"
		return Vector3.ZERO
	if _agent == null:
		last_stall_reason = &"moving"
		return to_dest / dist
	# Teleport detection (kill-plane respawn): the current path is for a
	# position we no longer occupy — force a fresh request.
	if _last_body_pos != Vector3.INF \
			and body.global_position.distance_to(_last_body_pos) > 5.0:
		_request_path(dest)
		if debug_log:
			print("[nav] %s teleported — repath forced" % body.name)
	_last_body_pos = body.global_position
	if _agent.target_position.distance_to(dest) > repath_distance:
		_request_path(dest)
	var next: Vector3 = _agent.get_next_path_position()
	# DEBUG: deduped waypoint trace. Strip once the sandbox stabilizes.
	if debug_log and next.distance_to(_last_waypoint_logged) > 0.1:
		_last_waypoint_logged = next
		print("[nav] %s waypoint -> (%.1f,%.1f,%.1f) body=(%.1f,%.1f,%.1f) d=%.2f" % [
			body.name, next.x, next.y, next.z,
			body.global_position.x, body.global_position.y, body.global_position.z,
			body.global_position.distance_to(next)])
	var dir := next - body.global_position
	dir.y = 0.0
	if dir.length() < 0.05 or _agent.is_navigation_finished():
		# No usable path this tick (map still syncing, stale after respawn).
		# Request fresh and WAIT — never fall back to a blind beeline.
		_request_path(dest)
		if debug_log and not _waiting_for_path:
			print("[nav] %s no usable path — holding position" % body.name)
		_waiting_for_path = true
		last_stall_reason = &"no_path"
		return Vector3.ZERO
	if _waiting_for_path and debug_log:
		print("[nav] %s path acquired — moving" % body.name)
	_waiting_for_path = false
	last_stall_reason = &"moving"
	dir = dir.normalized()
	# RVO: hand the desired velocity to the server; steer along the crowd-
	# safe velocity it computed last frame. Near-zero safe velocity = the
	# crowd says wait (jam) — stand rather than shove. Desired magnitude is
	# the AGENT's max_speed (per-pawn config on the NavigationAgent3D node)
	# — steering never reads the body, brains never pass speed through.
	if _agent.avoidance_enabled:
		_agent.velocity = dir * maxf(_agent.max_speed, 0.1)
		if _has_safe_velocity:
			var safe := Vector3(_safe_velocity.x, 0.0, _safe_velocity.z)
			if safe.length() < 0.05:
				last_stall_reason = &"rvo_wait"
				return Vector3.ZERO
			return safe.normalized()
	return dir


func _on_velocity_computed(safe_velocity: Vector3) -> void:
	_safe_velocity = safe_velocity
	_has_safe_velocity = true


## Max age (ms) of a queued link-jump. link_reached can fire while the pawn
## is briefly airborne; without expiry the jump stays queued through repaths
## and fires seconds later in an arbitrary direction near an edge — the
## "rocket off the side of the platform" bug.
const _JUMP_QUEUE_TTL_MS: int = 500

## One-shot jump edge, gated on being grounded and freshness. Call after
## steer_to.
func consume_jump(body: Node3D) -> bool:
	if not _jump_queued:
		return false
	var age: int = Time.get_ticks_msec() - _jump_queued_ms
	if age > _JUMP_QUEUE_TTL_MS:
		_jump_queued = false
		if debug_log:
			print("[nav] %s stale link-jump discarded (age=%dms)" % [body.name, age])
		return false
	# Refcounted world inhibit (generic meta convention — this game's
	# ConvertZone boss arenas set it): jumps stay queued (the TTL still
	# expires them) but never fire while the count is positive.
	if body.has_meta(&"jump_inhibit_count") and int(body.get_meta(&"jump_inhibit_count")) > 0:
		return false
	if body.has_method("is_on_floor") and body.is_on_floor():
		_jump_queued = false
		if debug_log:
			print("[nav] %s JUMP fires at (%.1f,%.1f,%.1f) age=%dms" % [
				body.name, body.global_position.x, body.global_position.y,
				body.global_position.z, age])
		return true
	return false


## Ask the agent for a fresh path. The tiny Y nudge guarantees the stored
## target actually CHANGES — a setter that early-outs on an identical value
## would silently keep the stale path.
func _request_path(dest: Vector3) -> void:
	_agent.target_position = dest + Vector3(0.0, 0.001 * randf(), 0.0)


func _on_link_reached(_details: Dictionary) -> void:
	_jump_queued = true
	_jump_queued_ms = Time.get_ticks_msec()
