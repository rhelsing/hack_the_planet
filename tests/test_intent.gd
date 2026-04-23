extends SceneTree

## Smoke test: Intent contract. Run with:
##   godot --headless --script res://tests/test_intent.gd --quit
## Exits with code 0 on pass, 1 on fail.

func _init() -> void:
	var failures: Array[String] = []

	# Defaults: a fresh Intent is a zeroed no-op.
	var a := Intent.new()
	if a.move_direction != Vector3.ZERO:
		failures.append("default move_direction should be Vector3.ZERO, got %s" % a.move_direction)
	if a.jump_pressed != false:
		failures.append("default jump_pressed should be false")
	if a.attack_pressed != false:
		failures.append("default attack_pressed should be false")
	if a.interact_pressed != false:
		failures.append("default interact_pressed should be false")
	if a.dash_pressed != false:
		failures.append("default dash_pressed should be false")
	if a.crouch_held != false:
		failures.append("default crouch_held should be false")

	# Field writes and reads round-trip.
	var b := Intent.new()
	b.move_direction = Vector3(1, 0, 0)
	b.jump_pressed = true
	b.attack_pressed = true
	b.interact_pressed = true
	b.dash_pressed = true
	b.crouch_held = true
	if b.move_direction != Vector3(1, 0, 0):
		failures.append("move_direction write/read failed")
	if not b.jump_pressed:
		failures.append("jump_pressed write/read failed")
	if not b.attack_pressed:
		failures.append("attack_pressed write/read failed")
	if not b.interact_pressed:
		failures.append("interact_pressed write/read failed")
	if not b.dash_pressed:
		failures.append("dash_pressed write/read failed")
	if not b.crouch_held:
		failures.append("crouch_held write/read failed")

	# Two instances are independent (RefCounted, not autoload).
	var c := Intent.new()
	if c.jump_pressed:
		failures.append("new Intent shouldn't inherit state from previous instance")

	if failures.is_empty():
		print("PASS test_intent: Intent contract behaves as specified")
		quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_intent: " + f)
		quit(1)
