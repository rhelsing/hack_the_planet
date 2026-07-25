extends SceneTree

## NavPerception contract: suspicion accumulator (fill scaled by strength,
## decay over memory), sight gates (range, cone arc, vertical band, LOS,
## sustain), hearing (cone-independent, loudness-scaled — crouched=silent),
## stimulus notify, and the suspect_time=0 parity collapse to the binary v3
## model. Pure logic — LOS is a caller-supplied bool, so no physics needed.
## Run: godot --headless --script res://tests/test_nav_perception.gd --quit

## Target that duck-types "crouched": silent to hearing.
class QuietTarget extends Node3D:
	func noise_loudness() -> float:
		return 0.0


var _failures: Array[String] = []


func _check(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _init() -> void:
	var target := Node3D.new()
	var quiet := QuietTarget.new()
	root.add_child(target)
	root.add_child(quiet)
	target.ready.connect(func() -> void: _run(target, quiet))


func _run(target: Node3D, quiet: Node3D) -> void:
	var origin := Vector3.ZERO

	# 1. Parity collapse: suspect_time=0 + any sense → hostile instantly;
	#    unsensed decays to zero over memory_duration (== the v3 timer).
	var p := NavPerception.new()
	p.suspect_time = 0.0
	p.memory_duration = 6.0
	target.global_position = Vector3(5, 0, 0)
	var s := p.sense_strength(origin, target, true, false)
	_check(s > 0.0, "in-range visible target should be sensed")
	p.integrate(s, 0.016)
	_check(p.is_hostile(), "suspect_time=0 must reach hostile in one tick (parity)")
	p.integrate(0.0, 3.0)
	_check(not p.is_hostile() and p.suspicion > 0.4, "decay should be gradual (memory)")
	p.integrate(0.0, 4.0)
	_check(p.suspicion == 0.0, "fully decayed after memory_duration")

	# 2. Accumulator: suspect_time=1 fills proportionally to strength.
	var p2 := NavPerception.new()
	p2.suspect_time = 1.0
	p2.integrate(1.0, 0.5)
	_check(absf(p2.suspicion - 0.5) < 0.001, "strength 1 for 0.5s → suspicion 0.5")
	_check(p2.is_suspect() and not p2.is_hostile(), "0.5 = suspect, not hostile")
	var p3 := NavPerception.new()
	p3.suspect_time = 1.0
	p3.integrate(0.4, 0.5)
	_check(absf(p3.suspicion - 0.2) < 0.001, "weaker sense fills slower")

	# 3. Cone arc gate: 90° cone facing +Z — target behind is unseen, but
	#    hearing still catches it (cone-independent, the whole point).
	var pc := NavPerception.new()
	pc.cone_deg = 90.0
	pc.facing = Vector3(0, 0, 1)
	pc.hearing_radius = 10.0
	target.global_position = Vector3(0, 0, -5)
	_check(pc._sight_strength(origin, target, true, false) == 0.0,
		"target behind the cone must be unseen")
	_check(pc.sense_strength(origin, target, true, false) > 0.0,
		"target behind but within hearing must be heard")
	pc.hearing_radius = 0.0
	_check(pc.sense_strength(origin, target, true, false) == 0.0,
		"deaf + behind = unsensed")
	target.global_position = Vector3(0, 0, 5)
	_check(pc._sight_strength(origin, target, true, false) > 0.0,
		"target ahead inside the cone is seen")

	# 4. Centrality: centered target senses stronger than edge-of-cone.
	var center_s := pc._sight_strength(origin, target, true, false)
	target.global_position = Vector3(3.4, 0, 3.6)  # ~43° off axis, near 45° edge
	var edge_s := pc._sight_strength(origin, target, true, false)
	_check(edge_s > 0.0 and edge_s < center_s, "edge-of-cone must be weaker than center")

	# 5. Vertical band: ±1m gate blocks a mezzanine target.
	var pv := NavPerception.new()
	pv.vertical_half_height = 1.0
	pv.hearing_radius = 0.0
	target.global_position = Vector3(0, 3, 5)
	_check(pv.sense_strength(origin, target, true, false) == 0.0,
		"target 3m above with ±1m band must be invisible")
	target.global_position = Vector3(0, 0.5, 5)
	_check(pv.sense_strength(origin, target, true, false) > 0.0,
		"target inside the band is visible")

	# 6. Hearing loudness: crouched (loudness 0) is silent at point blank;
	#    standing target at the same spot is heard.
	var ph := NavPerception.new()
	ph.hearing_radius = 10.0
	quiet.global_position = Vector3(2, 0, 0)
	target.global_position = Vector3(2, 0, 0)
	_check(ph._hearing_strength(origin, quiet) == 0.0, "crouched target must be silent")
	_check(ph._hearing_strength(origin, target) > 0.0, "standing target must be heard")
	target.global_position = Vector3(12, 0, 0)
	_check(ph._hearing_strength(origin, target) == 0.0, "outside 10m is unheard")

	# 7. LOS + range + sustain: no LOS = no sight; beyond range unsensed
	#    unless sustained (sight sustains at any distance once held).
	var pr := NavPerception.new()
	pr.sight_range = 10.0
	pr.hearing_radius = 0.0
	target.global_position = Vector3(15, 0, 0)
	_check(pr.sense_strength(origin, target, false, false) == 0.0, "no LOS = unseen")
	_check(pr.sense_strength(origin, target, true, false) == 0.0, "beyond range = unseen")
	_check(pr.sense_strength(origin, target, true, true) > 0.0, "sustain lifts the range cap")

	# 8. Stimulus: notify sets LKP and raises to suspect, never hostile.
	var pn := NavPerception.new()
	pn.suspect_time = 1.0
	pn.notify(Vector3(9, 0, 9), pn.suspect_threshold)
	_check(pn.is_suspect() and not pn.is_hostile(), "alert = investigate, not hostile")
	_check(pn.lkp == Vector3(9, 0, 9), "alert must set LKP")
	pn.suspicion = 0.9
	pn.notify(Vector3(1, 0, 1), 0.5)
	_check(absf(pn.suspicion - 0.9) < 0.001, "notify never lowers suspicion")

	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("PASS test_nav_perception: accumulator/cone/hearing/stimulus contract intact")
		quit(0)
	else:
		for f: String in _failures:
			printerr("FAIL test_nav_perception: " + f)
		quit(1)
