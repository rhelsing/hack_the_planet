extends SceneTree

## NavBlackboard contract: engage claims capped + idempotent + pruned on
## claimant death, release frees slots, shared LKP freshness, stateless
## spread offsets differ per claimant, disabled board = solo semantics.
## Run: godot --headless --script res://tests/test_nav_blackboard.gd --quit

var _failures: Array[String] = []


func _check(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _init() -> void:
	var board := NavBlackboard.new()
	board.group = &"testsquad"
	board.max_engagers_per_target = 2
	root.add_child(board)
	var a := Node.new()
	var b := Node.new()
	var c := Node.new()
	var target := Node.new()
	for n: Node in [a, b, c, target]:
		root.add_child(n)
	board.ready.connect(func() -> void: _run(board, a, b, c, target))


func _run(board: NavBlackboard, a: Node, b: Node, c: Node, target: Node) -> void:
	# Claims: capped at max_engagers, idempotent renewal, third is refused.
	_check(board.claim_engage(a, target), "first claim should succeed")
	_check(board.claim_engage(b, target), "second claim should succeed")
	_check(board.claim_engage(a, target), "renewing an existing claim must succeed")
	_check(not board.claim_engage(c, target), "third claim must be refused (cap 2)")

	# Release frees a slot.
	board.release_engage(b)
	_check(board.claim_engage(c, target), "released slot should be claimable")

	# Pruning: a dead claimant's slot frees automatically.
	a.free()
	var d := Node.new()
	root.add_child(d)
	_check(board.claim_engage(d, target), "dead claimant must be pruned, freeing its slot")

	# Shared LKP: fresh reads back; stale (max_age 0) reads INF.
	board.report_lkp(Vector3(3, 0, 4))
	_check(board.squad_lkp() == Vector3(3, 0, 4), "fresh LKP should read back")
	board.lkp_max_age = 0.0
	_check(board.squad_lkp() == Vector3.INF, "stale LKP must read INF")
	board.lkp_max_age = 12.0

	# Spread: distinct claimants get distinct, radius-length offsets.
	var o1 := board.search_offset_for(c, 6.0)
	var o2 := board.search_offset_for(d, 6.0)
	_check(absf(o1.length() - 6.0) < 0.01, "offset must have the requested radius")
	_check(o1.distance_to(o2) > 0.01, "distinct claimants should spread differently")
	_check(board.search_offset_for(c, 6.0) == o1, "offset must be stable per claimant")

	# Alert: max-merge + lazy decay path returns something sane.
	board.report_alert(1.0)
	_check(board.squad_alert() > 0.9, "fresh alert should read near its reported level")

	# Disabled board = solo semantics everywhere.
	board.enabled = false
	_check(board.claim_engage(c, target) and board.claim_engage(d, target)
		and board.claim_engage(b, target), "disabled board must grant every claim")
	_check(board.squad_lkp() == Vector3.INF, "disabled board must report no LKP")
	_check(board.search_offset_for(c, 6.0) == Vector3.ZERO, "disabled board must not offset")
	_check(board.squad_alert() == 0.0, "disabled board must report zero alert")

	# find_for: matches by group, null for unknown groups (null = solo).
	board.enabled = true
	_check(NavBlackboard.find_for(self, &"testsquad") == board, "find_for should match group")
	_check(NavBlackboard.find_for(self, &"nosuch") == null, "unknown group must find null")
	_check(NavBlackboard.find_for(self, &"") == null, "empty group must find null")

	if _failures.is_empty():
		print("PASS test_nav_blackboard: claims/LKP/spread/disabled contract intact")
		quit(0)
	else:
		for f: String in _failures:
			printerr("FAIL test_nav_blackboard: " + f)
		quit(1)
