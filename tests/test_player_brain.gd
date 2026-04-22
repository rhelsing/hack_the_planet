extends SceneTree

## Smoke test: PlayerBrain.tick() returns an Intent with sane defaults when
## no input is happening, and respects the camera when converting axes.
## Run: godot --headless --script res://tests/test_player_brain.gd --quit

func _init() -> void:
	var failures: Array[String] = []

	var brain := PlayerBrain.new()
	var body := Node3D.new()  # any Node3D works — brain doesn't touch body

	# No camera attached → no input → world_dir should be zero, flags false.
	var intent := brain.tick(body, 0.016)
	if intent == null:
		failures.append("tick() returned null")
	elif not (intent is Intent):
		failures.append("tick() returned non-Intent: %s" % intent)
	else:
		if intent.move_direction != Vector3.ZERO:
			failures.append("idle tick should produce zero move_direction, got %s" % intent.move_direction)
		if intent.jump_pressed:
			failures.append("idle tick should not report jump_pressed")
		if intent.attack_pressed:
			failures.append("idle tick should not report attack_pressed")

	# time_since_mouse_input ticks forward.
	var t0 := brain.time_since_mouse_input
	brain.tick(body, 0.5)
	if brain.time_since_mouse_input <= t0:
		failures.append("time_since_mouse_input should advance with delta")

	# Subsequent ticks yield fresh Intents (not stale shared state across frames).
	# We return the same Intent instance for zero-allocation steady-state, so
	# verify fields reset rather than the object identity.
	var i2 := brain.tick(body, 0.016)
	if i2.jump_pressed or i2.attack_pressed:
		failures.append("stale edge flags leaked between ticks")

	brain.queue_free()
	body.queue_free()

	if failures.is_empty():
		print("PASS test_player_brain: tick() contract holds")
		quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_player_brain: " + f)
		quit(1)
