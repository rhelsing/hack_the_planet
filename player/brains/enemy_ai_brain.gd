class_name EnemyAIBrain
extends Brain

## AI driver for hostile pawns. Wanders with curiosity, switches to CHASE
## when the target enters detection range, triggers attack when in strike
## range. Produces a full Intent directly (fraction-of-max_speed semantics
## so magnitude 0.33 = 1/3 speed wander, 1.0 = full-speed chase).

@export_group("Detection")
@export var detection_radius := 16.0
## Chase ends at this distance. Must exceed detection_radius (hysteresis
## prevents flicker at the boundary).
@export var chase_exit_radius := 22.0
## Groups whose members are valid targets. Multi-group so factions can
## target multiple opposing factions (e.g. allies hit both `enemies` and
## `splice_enemies`). PlayerBody.set_faction() rewrites this at runtime
## per the faction targeting table. Inspector default keeps existing
## "hit the player" behavior for old enemy variants without faction set.
@export var target_groups: Array[StringName] = [&"player"]

@export_group("Speed")
## Fraction of body's max_speed used while wandering. 0 = stand still.
@export_range(0.0, 1.0) var wander_speed_fraction := 0.33
## Fraction of body's max_speed used while chasing. 1.0 = full speed.
@export_range(0.0, 1.0) var chase_speed_fraction := 1.0

@export_group("Wander")
@export var min_wander_interval := 1.0
@export var max_wander_interval := 3.0
## Probability the enemy reorients when the wander interval elapses.
## 0 = only turns at walls/ledges. 1 = reorients every interval.
@export_range(0.0, 1.0) var curiosity := 0.7
## Max swing (degrees) when reorienting. Small = gentle meander, 180 = free reverse.
@export_range(0.0, 180.0) var max_turn_deg := 130.0

@export_group("Attack")
## Fire intent.attack_pressed when target is within this horizontal range.
@export var attack_range := 2.0
## Max vertical distance at which the AI will try to attack. Matches the
## body's attack_vertical_range — no point firing a swing if the sweep would
## miss anyway because the player is airborne overhead.
@export var attack_vertical_range := 1.5
## Seconds between consecutive attack triggers.
@export var attack_cooldown := 1.6
## Wind-up phase before the swing fires — the AI slows to wind_up_speed_fraction
## and holds for this many seconds. This is the player's punish window.
## 0.0 disables the wind-up (instant attacks).
@export var wind_up_duration := 0.55
## Fraction of chase speed maintained during wind-up. 0 = full stop,
## 0.15 = slow creep (still drifting toward target as they wind up).
@export_range(0.0, 1.0) var wind_up_speed_fraction := 0.15

@export_group("Follow")
## When non-empty AND no enemy is in detection range, the brain walks
## toward the nearest node in this group instead of pure-random wander.
## Used by ally pawns (faction "gold") set via PlayerBody.set_faction —
## they follow the player around and idle near them. Empty = pure wander.
@export var follow_subject_group: StringName = &""
## Stop-and-idle gap. When closer than this to the follow subject, the
## brain idles in place; when farther, it walks toward the subject.
@export var follow_distance: float = 3.0

@export_group("Ledges")
@export var turn_at_ledges := true
@export var ledge_probe_distance := 1.5
## Drop depth (m) below the future foot point that still counts as "ground" —
## walks down stair steps shallower than this, treats anything deeper as a
## ledge and turns. 0.5 ≈ tall step. Bump up for sloppy stairs that read as
## ledges; bump down to make enemies skittish around small drops.
@export var ledge_probe_depth := 0.5

enum State { WANDER, CHASE, IDLE, WIND_UP }

@export_group("State")
## Behavior the enemy returns to when no target is in range. WANDER = meander
## with curiosity rerolls. IDLE = stand in place facing forward. Both react
## the same to a target entering detection range (→ CHASE).
@export var starting_state: State = State.WANDER

var _state: State = State.WANDER
var _direction := Vector3.RIGHT
var _wander_timer := 0.0
var _attack_cooldown_timer := 0.0
var _wind_up_timer := 0.0
var _target: Node3D
var _intent := Intent.new()


func _ready() -> void:
	_direction = Vector3.RIGHT.rotated(Vector3.UP, randf() * TAU)
	_reset_wander_timer()
	_state = starting_state


func tick(body: Node3D, delta: float) -> Intent:
	# Reset edge flags every tick; only set them true when we fire this frame.
	_intent.move_direction = Vector3.ZERO
	_intent.jump_pressed = false
	_intent.attack_pressed = false
	_attack_cooldown_timer = maxf(0.0, _attack_cooldown_timer - delta)

	_ensure_target(body)
	_update_state(body)

	match _state:
		State.CHASE:
			_intent.move_direction = _chase_direction(body) * chase_speed_fraction
			_maybe_start_wind_up(body)
		State.WIND_UP:
			_tick_wind_up(body, delta)
		State.IDLE:
			_intent.move_direction = Vector3.ZERO
		_:
			# WANDER: if a follow subject is configured (allies follow the
			# player), home toward them with a stop-and-idle gap. Otherwise
			# fall back to pure-random wander.
			if follow_subject_group != &"":
				_intent.move_direction = _follow_direction(body) * chase_speed_fraction
			else:
				_intent.move_direction = _wander_direction(body, delta) * wander_speed_fraction

	return _intent


func _update_state(body: Node3D) -> void:
	if _target == null:
		_state = starting_state
		return
	var distance := _horizontal_distance(body.global_position, _target.global_position)
	match _state:
		State.WANDER, State.IDLE:
			if distance < detection_radius:
				_state = State.CHASE
		State.CHASE:
			if distance > chase_exit_radius:
				_state = starting_state
				_reset_wander_timer()


func _chase_direction(body: Node3D) -> Vector3:
	var to_target: Vector3 = _target.global_position - body.global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
		return Vector3.ZERO
	_direction = to_target.normalized()
	# Pressing into walls/ledges while chasing — stall instead of flipping,
	# so the enemy stays aimed at the target.
	if body.has_method("is_on_wall") and body.is_on_wall():
		return Vector3.ZERO
	if turn_at_ledges and body.has_method("is_on_floor") and body.is_on_floor() and not _has_ground_ahead(body):
		return Vector3.ZERO
	return _direction


func _follow_direction(body: Node3D) -> Vector3:
	# Pick the nearest member of follow_subject_group. Returns zero if
	# inside the follow_distance gap — that maps to "idle in place" via
	# move_direction = 0. Returns toward-subject unit vector otherwise.
	var tree := body.get_tree()
	if tree == null:
		return Vector3.ZERO
	var subject: Node3D = null
	var best_dist_sq: float = INF
	for n: Node in tree.get_nodes_in_group(follow_subject_group):
		if not (n is Node3D):
			continue
		var node3d: Node3D = n as Node3D
		var dx: float = node3d.global_position.x - body.global_position.x
		var dz: float = node3d.global_position.z - body.global_position.z
		var dsq: float = dx * dx + dz * dz
		if dsq < best_dist_sq:
			best_dist_sq = dsq
			subject = node3d
	if subject == null:
		return Vector3.ZERO
	var dist: float = sqrt(best_dist_sq)
	if dist <= follow_distance:
		return Vector3.ZERO  # idle inside the gap
	var to_subject: Vector3 = subject.global_position - body.global_position
	to_subject.y = 0.0
	if to_subject.length_squared() < 0.0001:
		return Vector3.ZERO
	return to_subject.normalized()


func _wander_direction(body: Node3D, delta: float) -> Vector3:
	var flipped := false
	if body.has_method("is_on_wall") and body.is_on_wall():
		_direction = -_direction
		flipped = true
	elif turn_at_ledges and body.has_method("is_on_floor") and body.is_on_floor() and not _has_ground_ahead(body):
		_direction = -_direction
		flipped = true

	_wander_timer -= delta
	if _wander_timer <= 0.0:
		# Skip an extra reroll on the frame we just flipped off a wall/ledge.
		if not flipped and randf() < curiosity:
			_pick_random_heading()
		_reset_wander_timer()
	return _direction


func _pick_random_heading() -> void:
	var angle := deg_to_rad(randf_range(-max_turn_deg, max_turn_deg))
	_direction = _direction.rotated(Vector3.UP, angle).normalized()


func _reset_wander_timer() -> void:
	_wander_timer = randf_range(min_wander_interval, max_wander_interval)


func _ensure_target(body: Node3D) -> void:
	if _target != null and is_instance_valid(_target):
		return
	var tree := body.get_tree()
	if tree == null:
		return
	# Walk every target group; first valid Node3D wins. Dedup not needed —
	# we return on first hit. A pawn in two groups would just be picked
	# from whichever group iterates first.
	for grp in target_groups:
		for node: Node in tree.get_nodes_in_group(grp):
			if node is Node3D:
				_target = node
				return


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	var dx := b.x - a.x
	var dz := b.z - a.z
	return sqrt(dx * dx + dz * dz)


## Trigger the wind-up the moment the target enters strike range and the
## cooldown is ready. From WIND_UP, _tick_wind_up handles the actual swing
## fire after wind_up_duration elapses.
func _maybe_start_wind_up(body: Node3D) -> void:
	if _target == null or _attack_cooldown_timer > 0.0:
		return
	var d: float = _horizontal_distance(body.global_position, _target.global_position)
	if d > attack_range:
		return
	var dy: float = absf(_target.global_position.y - body.global_position.y)
	if dy > attack_vertical_range:
		return
	if wind_up_duration <= 0.0:
		# Wind-up disabled — fire immediately (legacy behavior).
		_intent.attack_pressed = true
		_attack_cooldown_timer = attack_cooldown
		return
	_state = State.WIND_UP
	_wind_up_timer = wind_up_duration


## Slow to a creep facing the target while the wind-up timer ticks down.
## On expiry, fire the attack and return to CHASE — cooldown gates the
## next wind-up. The slow phase IS the player's punish window.
func _tick_wind_up(body: Node3D, delta: float) -> void:
	_wind_up_timer -= delta
	# Keep facing/drifting toward the target so they don't visually freeze
	# in a stale heading if the player sidesteps during the wind-up.
	_intent.move_direction = _chase_direction(body) * wind_up_speed_fraction
	if _wind_up_timer <= 0.0:
		_intent.attack_pressed = true
		_attack_cooldown_timer = attack_cooldown
		_state = State.CHASE


func _has_ground_ahead(body: Node3D) -> bool:
	var space := body.get_world_3d().direct_space_state
	var from: Vector3 = body.global_position + _direction * ledge_probe_distance
	var to: Vector3 = from + Vector3.DOWN * ledge_probe_depth
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [(body as CollisionObject3D).get_rid()] if body is CollisionObject3D else []
	return not space.intersect_ray(query).is_empty()
