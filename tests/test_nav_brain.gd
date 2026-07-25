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


var _failures: Array[String] = []
var _brain: NavBrain = null
var _body: Node3D = null
var _target: Node3D = null
# Second group member for nearest-wins. Added up-front in _init (root
# rejects add_child during a ready callback), parked far until needed.
var _near: Node3D = null


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
	root.add_child(_target)
	root.add_child(_near)
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

	# SUSPECT: suspect_time > 0 climbs the accumulator — below threshold the
	# pawn stays put (wander, no agent), crossing it investigates toward the
	# stimulus at wander speed, filling it chases at full speed.
	var slow := NavBrain.new()
	slow.debug_log = false
	slow.require_line_of_sight = false
	slow.hearing_radius = 0.0
	slow.wander_tick_every = 1
	slow.attack_range = 0.0
	slow.suspect_time = 1.0
	_target.global_position = Vector3(2000, 0, 0)
	_near.global_position = Vector3(6, 0, 0)
	var s1 := slow.tick(_body, 0.3)
	if s1.move_direction != Vector3.ZERO:
		_failures.append("below suspect threshold should stand, got %s" % s1.move_direction)
	var s2 := slow.tick(_body, 0.3)
	if s2.move_direction.x <= 0.0:
		_failures.append("suspect should investigate toward the stimulus, got %s" % s2.move_direction)
	if s2.move_direction.length() > slow.wander_speed_fraction + 0.01:
		_failures.append("investigation must move at wander speed, got %.2f" % s2.move_direction.length())
	var s3 := slow.tick(_body, 1.0)
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
