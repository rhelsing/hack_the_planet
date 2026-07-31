extends SceneTree

## NavBrain contract: distance-gated awareness with hysteresis, horizontal
## unit-vector steering scaled by chase_speed_fraction, stop inside
## arrive_distance, never fires attack/jump, and unaware = no movement
## (wander needs a navmesh agent; bare setups stand still).
## LOS is disabled here — it needs real physics; the nav_test boot covers it.
## Run: godot --headless --script res://tests/test_nav_brain.gd --quit

## Sight-mocked subclass: hearing/LOS logic testable without physics.
class BlindBrain extends NavBrain:
	func _can_see(_body: Node3D, _target: Node3D) -> bool:
		return false


## Follow subject with a scriptable combat clock (combat-consent seam).
class Handler extends Node3D:
	var since: float = INF
	func seconds_since_attack() -> float:
		return since


var _failures: Array[String] = []
var _brain: NavBrain = null
var _body: Node3D = null
var _target: Node3D = null
# Second group member for nearest-wins. Added up-front in _init (root
# rejects add_child during a ready callback), parked far until needed.
var _near: Node3D = null
# Squad fixtures — same up-front rule: nodes must enter the tree in _init.
var _sq_board: NavBlackboard = null
var _body_a: Node3D = null
var _body_b: Node3D = null
# "allies"-group member for the priority-target pre-pass (plan §7).
var _gold: Node3D = null
# Combat-consent follow subject (group "handler").
var _handler: Handler = null


func _init() -> void:
	_brain = NavBrain.new()
	_brain.debug_log = false
	_brain.require_line_of_sight = false
	_brain.hearing_radius = 0.0  # isolate distance logic from hearing
	_brain.wander_tick_every = 1  # perf frame-skip off for determinism
	_brain.attack_range = 0.0  # combat off for the movement/awareness checks
	_body = Node3D.new()
	_target = Node3D.new()
	_target.add_to_group("player")

	# Outside the tree → no scanning possible → empty intent, no crash.
	var i0 := _brain.tick(_body, 0.016)
	if i0 == null:
		_failures.append("no-tree tick returned null")
	elif i0.move_direction != Vector3.ZERO or i0.jump_pressed or i0.attack_pressed:
		_failures.append("no-tree tick should produce an empty intent")

	_near = Node3D.new()
	_near.add_to_group("player")
	_sq_board = NavBlackboard.new()
	_sq_board.group = &"sqtest"
	_sq_board.max_engagers_per_target = 1
	_body_a = Node3D.new()
	_body_b = Node3D.new()
	_gold = Node3D.new()
	_gold.add_to_group("allies")
	_handler = Handler.new()
	_handler.add_to_group("handler")
	root.add_child(_gold)
	root.add_child(_handler)
	root.add_child(_target)
	root.add_child(_near)
	root.add_child(_sq_board)
	root.add_child(_body_a)
	root.add_child(_body_b)
	_body.ready.connect(_run)
	root.add_child(_body)


func _run() -> void:
	_body.global_position = Vector3.ZERO
	_target.global_position = Vector3(10, 0, 0)
	_near.global_position = Vector3(1000, 0, 0)

	# Target within detection_radius (16) → acquired, steer +X, full speed.
	var i1 := _brain.tick(_body, 0.016)
	if i1.move_direction.distance_to(Vector3(1, 0, 0)) > 0.01:
		_failures.append("should steer +X at detected target, got %s" % i1.move_direction)
	if i1.jump_pressed or i1.attack_pressed:
		_failures.append("nav brain must never fire jump/attack")

	# Vertical delta is ignored in steering (horizontal-only).
	_target.global_position = Vector3(0, 5, 10)
	var i2 := _brain.tick(_body, 0.016)
	if i2.move_direction.distance_to(Vector3(0, 0, 1)) > 0.01:
		_failures.append("vertical delta should not bend the steer, got %s" % i2.move_direction)

	# Inside arrive_distance → stop.
	_target.global_position = Vector3(0.5, 0, 0)
	var i3 := _brain.tick(_body, 0.016)
	if i3.move_direction != Vector3.ZERO:
		_failures.append("inside arrive_distance should stop, got %s" % i3.move_direction)

	# chase_speed_fraction scales the magnitude.
	_brain.chase_speed_fraction = 0.5
	_target.global_position = Vector3(0, 0, -10)
	var i4 := _brain.tick(_body, 0.016)
	if absf(i4.move_direction.length() - 0.5) > 0.01:
		_failures.append("chase_speed_fraction should scale magnitude, got %.3f" % i4.move_direction.length())

	# Nearest-wins: a closer group member steals the lock.
	_near.global_position = Vector3(-3, 0, 0)
	var i5 := _brain.tick(_body, 0.016)
	if i5.move_direction.distance_to(Vector3(-0.5, 0, 0)) > 0.01:
		_failures.append("nearest target should win, got %s" % i5.move_direction)

	# Awareness: "radius acquires, sight sustains, time forgets." With LOS
	# off, sensed = inside detection_radius; a big tick exceeding
	# chase_memory_duration forgets an unsensed target. No agent = stand.
	_target.global_position = Vector3(100, 0, 0)
	_near.global_position = Vector3(1000, 0, 0)
	var i6 := _brain.tick(_body, 10.0)
	if i6.move_direction != Vector3.ZERO:
		_failures.append("unsensed target should be forgotten after memory expires, got %s" % i6.move_direction)

	# Omniscient (ally/follow mode): distance gating fully bypassed.
	_brain.omniscient = true
	var i6b := _brain.tick(_body, 0.016)
	if i6b.move_direction.distance_to(Vector3(0.5, 0, 0)) > 0.01:
		_failures.append("omniscient should acquire at any range, got %s" % i6b.move_direction)
	# Toggle back off: far target unsensed → memory expires → forgotten.
	_brain.omniscient = false
	var i6c := _brain.tick(_body, 10.0)
	if i6c.move_direction != Vector3.ZERO:
		_failures.append("disabling omniscient should forget far target after memory, got %s" % i6c.move_direction)

	# Re-acquire when a target re-enters detection range.
	_near.global_position = Vector3(5, 0, 0)
	var i7 := _brain.tick(_body, 0.016)
	if i7.move_direction.distance_to(Vector3(0.5, 0, 0)) > 0.01:
		_failures.append("re-entering detection range should re-acquire, got %s" % i7.move_direction)

	# Attack (instant path): in range fires once; cooldown gates the next tick.
	_brain.attack_range = 2.0
	_brain.wind_up_duration = 0.0
	_near.global_position = Vector3(1, 0, 0)
	var a1 := _brain.tick(_body, 0.016)
	if not a1.attack_pressed:
		_failures.append("in-range target should trigger attack_pressed")
	var a2 := _brain.tick(_body, 0.016)
	if a2.attack_pressed:
		_failures.append("attack_cooldown should gate the second tick")
	# Vertical dodge: overhead target never attacked (cooldown cleared by
	# the big delta).
	_near.global_position = Vector3(0.5, 5, 0)
	var a3 := _brain.tick(_body, 2.0)
	if a3.attack_pressed:
		_failures.append("target above attack_vertical_range should not be attacked")

	# Aggro: a far, unsensed attacker is pursued after aggro_to...
	_near.global_position = Vector3(1000, 0, 0)
	_brain.tick(_body, 10.0)  # memory expires → unaware
	_brain.aggro_to(_near)
	var a4 := _brain.tick(_body, 0.016)
	if a4.move_direction.distance_to(Vector3(0.5, 0, 0)) > 0.01:
		_failures.append("aggro_to should chase an unsensed attacker, got %s" % a4.move_direction)
	# ...and forgotten once grace + memory both expire.
	var a5 := _brain.tick(_body, 15.0)
	if a5.move_direction != Vector3.ZERO:
		_failures.append("aggro target should be forgotten after grace+memory, got %s" % a5.move_direction)

	# Wind-up: in range → telegraph (no swing) for wind_up_duration, then
	# the committed swing fires.
	_brain.wind_up_duration = 0.5
	_near.global_position = Vector3(1, 0, 0)
	var w1 := _brain.tick(_body, 0.016)  # reacquire + enter WIND_UP
	if w1.attack_pressed:
		_failures.append("wind-up should delay the swing")
	var w2 := _brain.tick(_body, 0.3)
	if w2.attack_pressed:
		_failures.append("swing must not fire mid wind-up")
	var w3 := _brain.tick(_body, 0.3)
	if not w3.attack_pressed:
		_failures.append("swing should fire once wind_up_duration elapses")

	# Hearing: sight mocked to ALWAYS FAIL (BlindBrain) + LOS required —
	# only the no-LOS hearing sphere can acquire.
	var blind := BlindBrain.new()
	blind.debug_log = false
	blind.wander_tick_every = 1
	_target.global_position = Vector3(2000, 0, 0)  # out of everything
	_near.global_position = Vector3(5, 0, 0)  # inside hearing (8)
	var h1 := blind.tick(_body, 0.016)
	if h1.move_direction.distance_to(Vector3(1, 0, 0)) > 0.01:
		_failures.append("target inside hearing_radius should be heard, got %s" % h1.move_direction)
	var blind2 := BlindBrain.new()
	blind2.debug_log = false
	blind2.wander_tick_every = 1
	_near.global_position = Vector3(12, 0, 0)  # outside hearing, inside detection
	var h2 := blind2.tick(_body, 0.016)
	if h2.move_direction != Vector3.ZERO:
		_failures.append("unseen+unheard target should not be acquired, got %s" % h2.move_direction)

	# SUSPECT: suspect_time > 0 climbs the accumulator — while actively
	# sensing sub-hostile the pawn FREEZES and stares at the stimulus (plan
	# §4, the legacy "I'm being noticed" tell); losing the sense above
	# threshold investigates the LKP at wander speed; filling the
	# accumulator chases at full speed.
	var slow := NavBrain.new()
	slow.debug_log = false
	slow.require_line_of_sight = false
	slow.hearing_radius = 0.0
	slow.wander_tick_every = 1
	slow.attack_range = 0.0
	slow.suspect_time = 1.0
	_target.global_position = Vector3(2000, 0, 0)
	_near.global_position = Vector3(6, 0, 0)
	var s1 := slow.tick(_body, 0.7)  # sensed, sub-hostile → stare
	if s1.move_direction != Vector3.ZERO:
		_failures.append("sensing sub-hostile should freeze and stare, got %s" % s1.move_direction)
	if slow._facing.distance_to(Vector3(1, 0, 0)) > 0.05:
		_failures.append("stare should lock facing on the stimulus, got %s" % slow._facing)
	_near.global_position = Vector3(2000, 0, 0)  # cut the sense above threshold
	var s2 := slow.tick(_body, 0.3)
	if s2.move_direction.x <= 0.0:
		_failures.append("suspect should investigate toward the LKP, got %s" % s2.move_direction)
	if s2.move_direction.length() > slow.wander_speed_fraction + 0.01:
		_failures.append("investigation must move at wander speed, got %.2f" % s2.move_direction.length())
	_near.global_position = Vector3(6, 0, 0)  # back in view
	var s3 := slow.tick(_body, 1.0)  # accumulator fills → hostile chase
	if s3.move_direction.distance_to(Vector3(1, 0, 0)) > 0.01:
		_failures.append("filled accumulator should chase at full speed, got %s" % s3.move_direction)

	# Alerts: an unsuspecting pawn receiving a peer's shout investigates the
	# shouted position (never instantly hostile).
	var alerted := NavBrain.new()
	alerted.debug_log = false
	alerted.require_line_of_sight = false
	alerted.hearing_radius = 0.0
	alerted.wander_tick_every = 1
	alerted.attack_range = 0.0
	alerted.suspect_time = 1.0
	_near.global_position = Vector3(2000, 0, 0)  # nothing sensable
	alerted.receive_alert(Vector3(0, 0, 8))
	var s4 := alerted.tick(_body, 0.016)
	if s4.move_direction.z <= 0.0:
		_failures.append("alerted pawn should investigate the shout, got %s" % s4.move_direction)
	if s4.move_direction.length() > alerted.wander_speed_fraction + 0.01:
		_failures.append("alerted pawn must investigate, not chase, got %.2f" % s4.move_direction.length())

	# Follow (ally): with no combat target, steer to the nearest follow-
	# subject member at chase speed; stop inside follow_distance.
	var ally := NavBrain.new()
	ally.debug_log = false
	ally.require_line_of_sight = false
	ally.hearing_radius = 0.0
	ally.wander_tick_every = 1
	ally.attack_range = 0.0
	var no_targets: Array[StringName] = []
	ally.target_groups = no_targets  # nothing to fight — pure follow
	ally.follow_subject_group = &"player"
	_target.global_position = Vector3(0, 0, 20)
	_near.global_position = Vector3(0, 0, 25)
	var f1 := ally.tick(_body, 0.016)
	if f1.move_direction.distance_to(Vector3(0, 0, 1)) > 0.01:
		_failures.append("ally should follow the subject at chase speed, got %s" % f1.move_direction)
	_target.global_position = Vector3(0, 0, 2)  # inside follow_distance (3.5)
	_near.global_position = Vector3(1000, 0, 0)
	var f2 := ally.tick(_body, 0.016)
	if f2.move_direction != Vector3.ZERO:
		_failures.append("ally inside follow_distance should stand, got %s" % f2.move_direction)

	# Hack freeze (external CONTROL, plan §1): is_chasing gates the prompt,
	# freeze zeroes movement/attack even on a stagger-SKIPPED frame (R1 —
	# the gate must sit before the wander stagger), suspicion holds while
	# frozen, and unfreezing resumes the chase cleanly.
	var hack := NavBrain.new()
	hack.debug_log = false
	hack.require_line_of_sight = false
	hack.hearing_radius = 0.0
	hack.wander_tick_every = 1  # stagger off for the acquire tick
	hack.attack_range = 2.0
	hack.wind_up_duration = 0.0
	if hack.is_chasing():
		_failures.append("is_chasing must be false before any chase")
	_near.global_position = Vector3(5, 0, 0)
	var k1 := hack.tick(_body, 0.016)
	if k1.move_direction == Vector3.ZERO or not hack.is_chasing():
		_failures.append("pre-freeze pawn should chase (move %s, chasing %s)" % [
			k1.move_direction, hack.is_chasing()])
	hack.set_hack_active(true, 0.3)
	# R1 trap, deterministic: stagger ON, and physics frame count is constant
	# inside a headless script, so pick a tick offset that makes THIS frame a
	# skipped one, then arm a stale WANDER move. A freeze gate placed below
	# the stagger would replay the stale move; the correct gate returns zero.
	hack.wander_tick_every = 4
	var fr: int = Engine.get_physics_frames()
	hack._tick_offset = ((4 - (fr % 4)) % 4 + 1) % 4
	hack._state = NavBrain.State.WANDER
	hack._intent.move_direction = Vector3(1, 0, 0)
	var susp_frozen: float = hack._perception.suspicion
	var kf := hack.tick(_body, 0.016)
	if kf.move_direction != Vector3.ZERO or kf.attack_pressed:
		_failures.append("frozen pawn must zero-move on a stagger-skipped frame, got %s" % kf.move_direction)
	var kf2 := hack.tick(_body, 1.0)
	if kf2.move_direction != Vector3.ZERO:
		_failures.append("frozen pawn must stay stopped, got %s" % kf2.move_direction)
	if absf(hack._perception.suspicion - susp_frozen) > 0.001:
		_failures.append("suspicion must hold while frozen (was %.2f now %.2f)" % [
			susp_frozen, hack._perception.suspicion])
	hack.set_hack_active(false)
	hack.wander_tick_every = 1  # guarantee a real tick for the resume check
	var k2 := hack.tick(_body, 0.016)
	if k2.move_direction == Vector3.ZERO or not hack.is_chasing():
		_failures.append("unfrozen pawn should resume chasing, got %s" % k2.move_direction)

	# Squad claims (blackboard): with max_engagers 1, the first pawn claims
	# and swings; the second holds a moving standoff (never swings); a dead
	# claimant frees the slot and rotates the perimeter pawn in. Every
	# pre-existing case above runs squad_group="" — passing them unchanged
	# IS the blackboard-off proof.
	_body_a.global_position = Vector3.ZERO
	_body_b.global_position = Vector3(0, 0, 1)
	var sq1 := NavBrain.new()
	var sq2 := NavBrain.new()
	for sq: NavBrain in [sq1, sq2]:
		sq.debug_log = false
		sq.require_line_of_sight = false
		sq.hearing_radius = 0.0
		sq.wander_tick_every = 1
		sq.attack_range = 2.0
		sq.wind_up_duration = 0.0
		sq.squad_group = &"sqtest"
	_near.global_position = Vector3(1, 0, 0)
	_target.global_position = Vector3(2000, 0, 0)
	var q1 := sq1.tick(_body_a, 0.016)
	if not q1.attack_pressed:
		_failures.append("claimed engager should attack")
	var q2 := sq2.tick(_body_b, 0.016)
	if q2.attack_pressed:
		_failures.append("unclaimed squad pawn must not attack (perimeter duty)")
	if q2.move_direction == Vector3.ZERO:
		_failures.append("unclaimed pawn should still move to its standoff point")
	_body_a.free()  # claimant dies → prune frees the slot
	var q3 := sq2.tick(_body_b, 2.0)
	if not q3.attack_pressed:
		_failures.append("freed claim slot should rotate the perimeter pawn in")

	# Tucker-out (§5) + recover window (R3): a chase past chase_max_duration
	# drops; while recovering the pawn ignores a visible target AND peer
	# alerts; damage (aggro_to) punches through; an expired window
	# reacquires cleanly. This is the R9 composed sequence for the tucker
	# half (the `slow` section above composes the stare half).
	var tuck := NavBrain.new()
	tuck.debug_log = false
	tuck.require_line_of_sight = false
	tuck.hearing_radius = 0.0
	tuck.wander_tick_every = 1
	tuck.attack_range = 0.0
	tuck.chase_max_duration = 1.0
	tuck.tucker_recover_duration = 2.0
	_near.global_position = Vector3(5, 0, 0)
	_target.global_position = Vector3(2000, 0, 0)
	tuck.tick(_body, 0.016)  # acquire → chase
	var t1 := tuck.tick(_body, 1.5)  # past chase_max → tucker out
	if t1.move_direction != Vector3.ZERO:
		_failures.append("tuckered pawn should drop the chase, got %s" % t1.move_direction)
	var t2 := tuck.tick(_body, 0.016)  # visible target, inside the window
	if t2.move_direction != Vector3.ZERO:
		_failures.append("tucker window must block reacquisition, got %s" % t2.move_direction)
	tuck.receive_alert(Vector3(0, 0, 9))
	var t3 := tuck.tick(_body, 0.016)
	if t3.move_direction != Vector3.ZERO:
		_failures.append("tucker window must ignore peer alerts, got %s" % t3.move_direction)
	tuck.aggro_to(_near)
	var t4 := tuck.tick(_body, 0.016)
	if t4.move_direction == Vector3.ZERO:
		_failures.append("damage must punch through the tucker window")
	var t5 := tuck.tick(_body, 30.0)  # chase clock expires again → tucker
	if t5.move_direction != Vector3.ZERO:
		_failures.append("re-tucker after aggro chase should drop, got %s" % t5.move_direction)
	var t6 := tuck.tick(_body, 3.0)  # window (2s) expires → clean reacquire
	if t6.move_direction == Vector3.ZERO:
		_failures.append("expired tucker window should allow a clean reacquire")

	# Hostile lock (§6): sphere-only sustain — blocked sight keeps the chase
	# alive inside the radius (cover doesn't save you); beyond the radius it
	# decays even though nothing else changed.
	var lock := BlindBrain.new()  # sight always fails
	lock.debug_log = false
	lock.wander_tick_every = 1
	lock.attack_range = 0.0
	lock.hearing_radius = 0.0
	lock.require_line_of_sight = true
	lock.hostile_lock_ignores_los = true
	lock.hostile_lock_radius = 54.0
	lock.aggro_to(_near)  # force-hold a target (blind — senses can't)
	_near.global_position = Vector3(40, 0, 0)  # inside 54, sight blocked
	var l1 := lock.tick(_body, 8.0)  # far past memory — the sphere sustains
	if l1.move_direction.distance_to(Vector3(1, 0, 0)) > 0.01:
		_failures.append("lock must sustain a blocked-sight target inside the radius, got %s" % l1.move_direction)
	_near.global_position = Vector3(60, 0, 0)  # beyond the lock radius
	var l2 := lock.tick(_body, 10.0)  # full memory decay → forgotten
	if l2.move_direction != Vector3.ZERO:
		_failures.append("beyond the lock radius the chase must decay, got %s" % l2.move_direction)

	# Priority targets (§7): a priority-group member inside the bubble beats
	# a closer regular target; outside the bubble nearest-wins returns.
	var pri := NavBrain.new()
	pri.debug_log = false
	pri.require_line_of_sight = false
	pri.hearing_radius = 0.0
	pri.wander_tick_every = 1
	pri.attack_range = 0.0
	var pri_targets: Array[StringName] = [&"player", &"allies"]
	pri.target_groups = pri_targets
	var pri_groups: Array[StringName] = [&"allies"]
	pri.priority_target_groups = pri_groups
	pri.priority_target_radius = 10.0
	_gold.global_position = Vector3(0, 0, 8)   # priority, inside the bubble
	_near.global_position = Vector3(4, 0, 0)   # regular, closer
	_target.global_position = Vector3(2000, 0, 0)
	var p1 := pri.tick(_body, 0.016)
	if p1.move_direction.distance_to(Vector3(0, 0, 1)) > 0.01:
		_failures.append("priority member in the bubble must beat a closer regular target, got %s" % p1.move_direction)
	var pri2 := NavBrain.new()
	pri2.debug_log = false
	pri2.require_line_of_sight = false
	pri2.hearing_radius = 0.0
	pri2.wander_tick_every = 1
	pri2.attack_range = 0.0
	pri2.target_groups = pri_targets.duplicate()
	pri2.priority_target_groups = pri_groups.duplicate()
	pri2.priority_target_radius = 10.0
	_gold.global_position = Vector3(0, 0, 12)  # outside the bubble
	var p2 := pri2.tick(_body, 0.016)
	if p2.move_direction.distance_to(Vector3(1, 0, 0)) > 0.01:
		_failures.append("priority member outside the bubble must not override nearest, got %s" % p2.move_direction)
	_gold.global_position = Vector3(2000, 0, 0)  # park for later sections

	# Combat consent (companion): only fights while the follow subject fought
	# within the window — passive = follow, fighting = engage, expired =
	# break off and return. Aggro while passive also drops next tick.
	var comp := NavBrain.new()
	comp.debug_log = false
	comp.require_line_of_sight = false
	comp.hearing_radius = 0.0
	comp.wander_tick_every = 1
	comp.attack_range = 0.0
	comp.follow_subject_group = &"handler"
	comp.engage_requires_subject_combat = 5.0
	_target.global_position = Vector3(2000, 0, 0)
	_near.global_position = Vector3(5, 0, 0)       # in-range target (+X)
	_handler.global_position = Vector3(0, 0, -20)  # subject stands away (−Z)
	_handler.since = INF
	var cc1 := comp.tick(_body, 0.016)
	if cc1.move_direction.z >= 0.0:
		_failures.append("passive subject: companion should follow (-Z), got %s" % cc1.move_direction)
	_handler.since = 1.0
	var cc2 := comp.tick(_body, 0.016)
	if cc2.move_direction.x <= 0.0:
		_failures.append("fighting subject: companion should engage (+X), got %s" % cc2.move_direction)
	_handler.since = 99.0
	var cc3 := comp.tick(_body, 0.016)
	if cc3.move_direction.z >= 0.0:
		_failures.append("expired window: companion should break off to follow, got %s" % cc3.move_direction)
	comp.queue_free()

	pri.queue_free()
	pri2.queue_free()
	lock.queue_free()
	tuck.queue_free()
	_sq_board.queue_free()
	_body_b.queue_free()
	sq1.queue_free()
	sq2.queue_free()
	hack.queue_free()
	ally.queue_free()
	slow.queue_free()
	alerted.queue_free()
	blind.queue_free()
	blind2.queue_free()
	_brain.queue_free()
	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("PASS test_nav_brain: awareness/steer/arrive contract intact")
		quit(0)
	else:
		for f: String in _failures:
			printerr("FAIL test_nav_brain: " + f)
		quit(1)
