class_name StealthSentinelBrain
extends EnemyAIBrain

## Stealth-specific brain. Inherits all of EnemyAIBrain's machinery
## (detection state machine, navigation, target distribution, hit-aggro,
## tucker-out timing) and overrides four points:
##
##   1. tick()                — clears face_yaw_override_set every tick so
##                              the override only sticks when this brain
##                              actively requests it (during pause-look).
##   2. _can_see_target()     — adds vertical bounds. Target must be within
##                              ±vertical_cone_half_height meters of body.y.
##                              Player on a balcony or in a pit → invisible.
##   3. _update_vision_yaw()  — cone yaw = body's _yaw_state, not brain
##                              intent. Cone never drifts vs body facing.
##   4. _wander_direction()   — authored patrol pattern: walk a wide gentle
##                              arc, stop, look side-to-side via brain-driven
##                              face_yaw_override, repeat.
##
## All HOSTILE behavior, hit-aggro, target spreading, ally-retaliation
## targeting flow inherits cleanly from the parent. The original
## EnemyAIBrain script and splice_stealth_ai.tscn config are not modified.

@export_group("Stealth Cone")
## Half-height of the vertical detection band around body.y. Targets whose
## y differs by more than this can't be seen even if they're inside the
## horizontal cone arc + range. ±1m default = roughly the sentinel's body
## envelope (player on flat ground passes; player on a 1.5m mezzanine fails).
@export var vertical_cone_half_height: float = 1.0

@export_group("Stealth Patrol")
## Seconds in the WALK phase. Body arcs slowly during this window, body's
## velocity-based yaw tracks the arc, cone follows the body.
@export var arc_walk_duration: float = 4.0
## Curve rate while walking, degrees per second. ~25 = ~100° turn over a
## 4s walk window — gentle, never erratic.
@export var arc_walk_turn_rate_deg: float = 25.0
## Seconds in the PAUSE phase. Body is fully still; brain rotates body yaw
## via face_yaw_override so the head/cone sweeps left-right naturally.
@export var pause_duration: float = 4.0
## Max yaw offset (degrees) during pause's side-to-side sine oscillation.
## ±60° = roughly "look over each shoulder."
@export var pause_look_max_deg: float = 60.0
## Sine cycles per second for the pause look oscillation. 0.4 Hz =
## 2.5 seconds per full L-R-L cycle. Lower = slower head turn.
@export var pause_look_frequency_hz: float = 0.4

# Patrol state machine (within WANDER state). Toggles each pause/walk
# transition. Both phases tick the parent's _wander_direction once per
# frame (for wall/ledge bounce + the shared _direction state) — only the
# returned vector differs.
var _patrol_walking: bool = false
var _patrol_timer: float = 0.0
# Anchor body yaw at start of pause; the side-to-side oscillation is
# applied as an offset around this so we don't drift on each pause cycle.
var _pause_yaw_anchor: float = 0.0
var _pause_elapsed: float = 0.0


func tick(body: Node3D, delta: float) -> Intent:
	# Reset the override flag every tick BEFORE parent runs. Pause phase
	# (handled inside our _wander_direction override) re-sets it true with
	# the current target yaw; walk phase + chase + everything else leaves
	# it false → body falls through to its existing velocity-tracked yaw.
	_intent.face_yaw_override_set = false
	return super.tick(body, delta)


# Override: when the player is crouched, sentinels don't actively pre-target
# golds — they focus on the player. target_groups stays full ([&"player",
# &"allies"]) for aggro_to retaliation: if a gold attacks the sentinel, the
# attack still flows through aggro_to which checks the unmutated list, so
# retaliation works. The mutate-restore here only filters the candidate
# scan inside super._ensure_target. Standing player → no filter, normal
# wide-net targeting (the "fair game" mode).
func _ensure_target(body: Node3D) -> void:
	if not _is_player_crouched_for_filter():
		super._ensure_target(body)
		return
	var saved_targets: Array[StringName] = target_groups.duplicate()
	var saved_priority: Array[StringName] = priority_target_groups.duplicate()
	target_groups = _strip_allies(saved_targets)
	priority_target_groups = _strip_allies(saved_priority)
	super._ensure_target(body)
	target_groups = saved_targets
	priority_target_groups = saved_priority


func _strip_allies(groups: Array[StringName]) -> Array[StringName]:
	var out: Array[StringName] = []
	for g in groups:
		if g != &"allies":
			out.append(g)
	return out


# Direct lookup of the player's crouch state. Used to gate the ally-filter
# above. Independent of the brain's own _target / follow logic.
func _is_player_crouched_for_filter() -> bool:
	if _body_ref == null:
		return false
	var tree := _body_ref.get_tree()
	if tree == null:
		return false
	var player: Node = tree.get_first_node_in_group(&"player")
	if player == null or not is_instance_valid(player):
		return false
	return "_was_crouched" in player and bool(player.get(&"_was_crouched"))


# Override: vertical bounds on visibility. Anything outside ±half_height
# of the body's Y is invisible during patrol/suspect/alert. HOSTILE's
# Fix-2 sphere-detection branch in _update_alert_phase bypasses this
# entirely (intentional — once committed, jumping on a platform doesn't
# drop the chase).
func _can_see_target(body: Node3D, range_cap: float) -> bool:
	if _target != null and is_instance_valid(_target):
		var dy: float = absf(_target.global_position.y - body.global_position.y)
		if dy > vertical_cone_half_height:
			return false
	return super._can_see_target(body, range_cap)


# Override: cone yaw = body's actual facing. Convention: pawn forward
# computed as Vector3.BACK rotated by _yaw_state (matches stealth_kill_target's
# _pawn_forward); cone forward = Vector3(-sin(yaw), 0, -cos(yaw)). Solving
# the equality gives _vision_cone_yaw = PI + body._yaw_state. Smoothing via
# vision_swivel_smoothing carries over from the parent.
func _update_vision_yaw(delta: float) -> void:
	if vision_cone_deg <= 0.0 and not vision_debug_visible:
		return
	if _body_ref == null:
		return
	var body_yaw: float = float(_body_ref.get(&"_yaw_state"))
	var target_yaw: float = PI + body_yaw
	if vision_swivel_smoothing <= 0.0:
		_vision_cone_yaw = target_yaw
	else:
		var k: float = 1.0 - exp(-delta / vision_swivel_smoothing)
		_vision_cone_yaw = lerp_angle(_vision_cone_yaw, target_yaw, k)


# Override: arc-walk + pause-look-side-to-side patrol pattern.
#   Walk phase  → rotate _direction continuously (gentle arc). Body's
#                 face_velocity tracks the curving heading; cone follows
#                 via _update_vision_yaw above. Walls/ledges still flip
#                 _direction (parent's logic).
#   Pause phase → return Vector3.ZERO so body stops. Brain pushes a
#                 sine-modulated yaw into face_yaw_override so the head
#                 visibly looks left-right while body is stationary.
func _wander_direction(body: Node3D, delta: float) -> Vector3:
	_patrol_timer -= delta
	if _patrol_timer <= 0.0:
		_patrol_walking = not _patrol_walking
		_patrol_timer = arc_walk_duration if _patrol_walking else pause_duration
		if not _patrol_walking and _body_ref != null:
			_pause_yaw_anchor = float(_body_ref.get(&"_yaw_state"))
			_pause_elapsed = 0.0
	if _patrol_walking:
		# Continuously curve _direction. Same wall/ledge bounce semantics
		# the parent has — a wall flips heading, a ledge brakes (handled by
		# the ledge probe in the parent's chase/wander pipeline).
		var arc_rad: float = deg_to_rad(arc_walk_turn_rate_deg) * delta
		_direction = _direction.rotated(Vector3.UP, arc_rad)
		if body.has_method("is_on_wall") and body.is_on_wall():
			_direction = -_direction
		elif turn_at_ledges and body.has_method("is_on_floor") \
				and body.is_on_floor() and not _has_ground_ahead(body):
			_direction = -_direction
		return _direction
	# Pause: stand still, oscillate body yaw left-right around anchor.
	_pause_elapsed += delta
	var ofs_rad: float = deg_to_rad(pause_look_max_deg) \
		* sin(_pause_elapsed * pause_look_frequency_hz * TAU)
	_intent.face_yaw_override = _pause_yaw_anchor + ofs_rad
	_intent.face_yaw_override_set = true
	return Vector3.ZERO
