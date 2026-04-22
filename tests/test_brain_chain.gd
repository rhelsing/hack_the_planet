extends SceneTree

## Integration-ish smoke test: ScriptedBrain emits a sequence of Intents,
## proving the Brain/Intent/ScriptedBrain plumbing works without needing the
## full physics scene. Real body integration is covered by the headless game
## boot (godot --headless --quit-after N).

func _init() -> void:
	var failures: Array[String] = []

	# Build three intents: one move tick, one jump tick, one attack tick.
	var i_move := Intent.new(); i_move.move_direction = Vector3(1, 0, 0)
	var i_jump := Intent.new(); i_jump.jump_pressed = true
	var i_attack := Intent.new(); i_attack.attack_pressed = true

	var seq: Array[Intent] = [i_move, i_jump, i_attack]
	var brain := ScriptedBrain.from_sequence(seq)

	var body := Node3D.new()

	var got1 := brain.tick(body, 0.016)
	if got1.move_direction != Vector3(1, 0, 0):
		failures.append("tick 1 move_direction mismatch: %s" % got1.move_direction)

	var got2 := brain.tick(body, 0.016)
	if not got2.jump_pressed:
		failures.append("tick 2 should have jump_pressed")

	var got3 := brain.tick(body, 0.016)
	if not got3.attack_pressed:
		failures.append("tick 3 should have attack_pressed")

	# After sequence, ScriptedBrain returns empty Intents (not null, not stale).
	var got4 := brain.tick(body, 0.016)
	if got4 == null:
		failures.append("tick 4 returned null")
	elif got4.move_direction != Vector3.ZERO or got4.jump_pressed or got4.attack_pressed:
		failures.append("tick 4 should be an empty Intent after sequence exhausted")

	body.queue_free()

	if failures.is_empty():
		print("PASS test_brain_chain: Brain/Intent/ScriptedBrain chain intact")
		quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_brain_chain: " + f)
		quit(1)
