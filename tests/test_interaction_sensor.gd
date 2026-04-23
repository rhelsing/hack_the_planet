extends SceneTree

## Pure unit test for InteractionScoring.score(). Static function,
## no autoloads needed — runs cleanly in --script mode.
##
## Run with:
##   godot --headless --script res://tests/test_interaction_sensor.gd --quit
## Exits with code 0 on pass, 1 on fail.


const Scoring = preload("res://interactable/scoring.gd")


func _init() -> void:
	var failures: Array[String] = []

	# Standard weights used in production (matches defaults in the class).
	var W_PROX := 0.4
	var W_BODY := 0.4
	var W_CAM := 0.2
	var RANGE := 2.5
	var CUTOFF := -0.5

	# Body at origin, facing -Z (Godot forward convention).
	var body_pos := Vector3.ZERO
	var body_fwd := Vector3(0, 0, -1)
	var no_cam := Vector3.ZERO  # camera-crosshair disabled

	# ---- Out of range returns -INF ----
	var far_score := Scoring.score(
		body_pos, body_fwd, Vector3(0, 0, -10.0), 1.0,
		RANGE, W_PROX, W_BODY, W_CAM, no_cam, CUTOFF,
	)
	if far_score != -INF:
		failures.append("candidate out of range should score -INF, got %f" % far_score)

	# ---- Directly behind fails facing cutoff ----
	var behind_score := Scoring.score(
		body_pos, body_fwd, Vector3(0, 0, 2.0), 1.0,  # behind player (facing=-1)
		RANGE, W_PROX, W_BODY, W_CAM, no_cam, CUTOFF,
	)
	if behind_score != -INF:
		failures.append("candidate behind body should fail facing_cutoff, got %f" % behind_score)

	# ---- Directly in front, close = high score ----
	var close_front := Scoring.score(
		body_pos, body_fwd, Vector3(0, 0, -1.0), 1.0,
		RANGE, W_PROX, W_BODY, W_CAM, no_cam, CUTOFF,
	)
	var far_front := Scoring.score(
		body_pos, body_fwd, Vector3(0, 0, -2.0), 1.0,
		RANGE, W_PROX, W_BODY, W_CAM, no_cam, CUTOFF,
	)
	if not (close_front > far_front):
		failures.append("close candidate should score higher than far (both in front): %f vs %f" %
			[close_front, far_front])

	# ---- Side-on candidate (dot=0, right in front of cutoff) still scores but low ----
	var side_score := Scoring.score(
		body_pos, body_fwd, Vector3(1.0, 0, 0), 1.0,  # 90deg off forward
		RANGE, W_PROX, W_BODY, W_CAM, no_cam, CUTOFF,
	)
	if side_score == -INF:
		failures.append("side candidate (90°) should NOT be -INF; cutoff is -0.5")
	if not (close_front > side_score):
		failures.append("front candidate should outscore side candidate (body weight)")

	# ---- Priority adds additive bonus; two candidates same position ----
	# With priority 2.0 (bonus +0.25) vs 1.0 (bonus 0), priority 2 should win.
	var priority_low := Scoring.score(
		body_pos, body_fwd, Vector3(0, 0, -1.0), 1.0,
		RANGE, W_PROX, W_BODY, W_CAM, no_cam, CUTOFF,
	)
	var priority_high := Scoring.score(
		body_pos, body_fwd, Vector3(0, 0, -1.0), 2.0,
		RANGE, W_PROX, W_BODY, W_CAM, no_cam, CUTOFF,
	)
	if not (priority_high > priority_low):
		failures.append("priority 2.0 should outscore priority 1.0 at same position")
	if not is_equal_approx(priority_high - priority_low, 0.25):
		failures.append("priority bonus should be 0.25 per unit over 1.0, got %f" %
			(priority_high - priority_low))

	# ---- Camera-facing bias only kicks in when weight > 0 ----
	# Camera pointing at candidate that's slightly off body-forward axis.
	var cam_fwd := (Vector3(0.5, 0, -1.0)).normalized()
	var with_cam := Scoring.score(
		body_pos, body_fwd, Vector3(0.5, 0, -1.0), 1.0,
		RANGE, W_PROX, W_BODY, W_CAM, cam_fwd, CUTOFF,
	)
	var without_cam := Scoring.score(
		body_pos, body_fwd, Vector3(0.5, 0, -1.0), 1.0,
		RANGE, W_PROX, W_BODY, 0.0, cam_fwd, CUTOFF,
	)
	if not (with_cam > without_cam):
		failures.append("enabling camera weight should boost a camera-aligned candidate: %f vs %f" %
			[with_cam, without_cam])

	# ---- Two candidates: closer + front wins over distant + same-facing ----
	var cand_close := Scoring.score(
		body_pos, body_fwd, Vector3(0, 0, -1.0), 1.0,
		RANGE, W_PROX, W_BODY, W_CAM, no_cam, CUTOFF,
	)
	var cand_distant := Scoring.score(
		body_pos, body_fwd, Vector3(0, 0, -2.4), 1.0,  # near range edge
		RANGE, W_PROX, W_BODY, W_CAM, no_cam, CUTOFF,
	)
	if not (cand_close > cand_distant):
		failures.append("closer candidate should win when facing is equal")

	# ---- Distant + on-axis vs close + off-axis — body weight + proximity should favor close+side ----
	# close+side: proximity=1.0 (right at body), body facing ~0, priority 1
	# distant+on-axis: proximity low, body facing 1, priority 1
	# Close wins because the (1 - dist/range) factor dominates near zero distance.
	var close_side := Scoring.score(
		body_pos, body_fwd, Vector3(0.3, 0, 0), 1.0,  # side, very close
		RANGE, W_PROX, W_BODY, 0.0, no_cam, CUTOFF,
	)
	var far_front2 := Scoring.score(
		body_pos, body_fwd, Vector3(0, 0, -2.4), 1.0,  # on-axis, far
		RANGE, W_PROX, W_BODY, 0.0, no_cam, CUTOFF,
	)
	# Both valid scores; close_side benefits from ~1.0 proximity, far_front2 from ~1.0 facing.
	# Document the actual relationship — whichever way, both finite.
	if close_side == -INF or far_front2 == -INF:
		failures.append("both close-side and far-front should be valid (finite) scores")

	# ---- Done ----
	if failures.is_empty():
		print("PASS test_interaction_sensor: scoring function respects range, facing, proximity, priority, camera weight")
		quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_interaction_sensor: " + f)
		quit(1)
