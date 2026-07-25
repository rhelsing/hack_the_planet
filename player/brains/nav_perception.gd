class_name NavPerception
extends RefCounted

## WHAT can this pawn sense — the sensing half of DECIDE, beside NavSteering
## (which owns HOW to move). See docs/nav_stack.md.
##
## Two channels feed one suspicion accumulator (0..1):
##   sight   — range + cone arc + vertical band + LOS, returning a STRENGTH
##             scaled by distance and cone-centrality (closer + centered =
##             faster detection), not a boolean.
##   hearing — omnidirectional, cone-independent, scaled by the target's
##             loudness (duck-typed `noise_loudness()`; absent = 1.0).
##             Loudness 0 (crouched) = silent: the sneak-behind verb.
##
## The accumulator IS the alert model: crossing suspect_threshold = SUSPECT,
## reaching 1.0 = HOSTILE, decaying to 0 over memory_duration = forgotten.
## With suspect_time == 0 it collapses exactly to the binary
## "radius acquires, sight sustains, time forgets" model NavBrain v3 shipped
## with — greens/reds keep their proven behavior by preset numbers alone.
##
## Pure logic: no scene tree, no physics, no game classes. LOS arrives as a
## bool from the caller (NavBrain's overridable `_can_see()` seam), so every
## path here unit-tests headless. Portable to any game by construction.

# ── Config (forwarded from NavBrain exports each tick; presets own numbers) ─
var sight_range: float = 24.0
## 360 = no arc gate (greens/reds). Smaller = a real vision cone.
var cone_deg: float = 360.0
## 0 = no vertical gate. Otherwise targets outside ±this of body Y are unseen.
var vertical_half_height: float = 0.0
var hearing_radius: float = 10.0
## Seconds of point-blank, center-cone sight to reach HOSTILE. 0 = instant
## (the v3 binary model — parity default).
var suspect_time: float = 0.0
## Suspicion level that counts as SUSPECT (investigate).
var suspect_threshold: float = 0.5
## Seconds for suspicion to decay 1 → 0 when nothing is sensed. This is the
## same knob as NavBrain.chase_memory_duration — decay IS forgetting.
var memory_duration: float = 6.0
## Pawn facing (world, horizontal) — the cone axis. The brain owns facing
## (it commanded the movement / the patrol scan), so no body reads needed.
var facing: Vector3 = Vector3.FORWARD

# ── State ──────────────────────────────────────────────────────────────────
var suspicion: float = 0.0
## Last-known position of whatever fed the accumulator. INF = none.
var lkp: Vector3 = Vector3.INF


## Combined sense strength for `target` as seen from `body_pos`. `can_see`
## is the caller's LOS verdict (physics lives above this class). `sustain`
## lifts the sight range cap — "sight sustains at ANY distance" once a
## target is held, so long route detours never cause forgetting (v3 rule).
func sense_strength(body_pos: Vector3, target: Node3D, can_see: bool, sustain: bool) -> float:
	return maxf(
		_hearing_strength(body_pos, target),
		_sight_strength(body_pos, target, can_see, sustain))


func _hearing_strength(body_pos: Vector3, target: Node3D) -> float:
	if hearing_radius <= 0.0:
		return 0.0
	var loudness: float = loudness_of(target)
	if loudness <= 0.0:
		return 0.0
	var effective: float = hearing_radius * loudness
	var dist: float = body_pos.distance_to(target.global_position)
	if dist > effective:
		return 0.0
	# Near-instant right on top of the pawn, a reaction beat at the edge.
	return clampf(1.0 - 0.6 * (dist / effective), 0.4, 1.0)


func _sight_strength(body_pos: Vector3, target: Node3D, can_see: bool, sustain: bool) -> float:
	if not can_see:
		return 0.0
	var to_target: Vector3 = target.global_position - body_pos
	var flat := Vector3(to_target.x, 0.0, to_target.z)
	var dist: float = flat.length()
	var centrality: float = 1.0
	# Sustain = committed pursuit: range, cone, and vertical gates all lift
	# (mirrors the legacy rule that a committed chase never drops because the
	# target circled behind or hopped a ledge) — only LOS still decides.
	if not sustain:
		if vertical_half_height > 0.0 and absf(to_target.y) > vertical_half_height:
			return 0.0
		if dist > sight_range:
			return 0.0
		if cone_deg < 360.0 and dist > 0.001:
			var half_rad: float = deg_to_rad(cone_deg) * 0.5
			var flat_facing := Vector3(facing.x, 0.0, facing.z)
			if flat_facing.length() < 0.001:
				return 0.0
			var angle: float = flat_facing.angle_to(flat)
			if angle > half_rad:
				return 0.0
			# 1.0 dead-center → 0.5 at the cone edge.
			centrality = 1.0 - 0.5 * (angle / half_rad)
	# 1.0 up close → 0.35 at range; sustained-beyond-range holds the floor.
	var distance_factor: float = clampf(
		1.0 - 0.65 * (dist / maxf(sight_range, 0.001)), 0.35, 1.0)
	return distance_factor * centrality


## Advance the accumulator one tick. strength 0 = decay.
func integrate(strength: float, delta: float) -> void:
	if strength > 0.0:
		if suspect_time <= 0.0:
			suspicion = 1.0
		else:
			suspicion = minf(1.0, suspicion + strength * delta / suspect_time)
	elif memory_duration <= 0.0:
		suspicion = 0.0
	else:
		suspicion = maxf(0.0, suspicion - delta / memory_duration)


## External stimulus (a peer's alert shout, a noise event): remember where,
## and raise suspicion to at least `strength` (clamped). An alert passing
## suspect_threshold sends the pawn investigating without making it hostile.
func notify(pos: Vector3, strength: float) -> void:
	lkp = pos
	suspicion = maxf(suspicion, clampf(strength, 0.0, 1.0))


## Refresh the last-known position while a target is actively sensed.
func mark_sensed(pos: Vector3) -> void:
	lkp = pos


func is_hostile() -> bool:
	return suspicion >= 0.999


func is_suspect() -> bool:
	return suspicion >= suspect_threshold


func forget() -> void:
	suspicion = 0.0
	lkp = Vector3.INF


## Duck-typed loudness: how audible is this target right now? Games attach
## meaning (crouched = 0, skating = >1); absent method = 1.0 so bare test
## nodes and other games' pawns work unmodified.
static func loudness_of(target: Node3D) -> float:
	if target != null and target.has_method(&"noise_loudness"):
		return maxf(0.0, float(target.call(&"noise_loudness")))
	return 1.0
