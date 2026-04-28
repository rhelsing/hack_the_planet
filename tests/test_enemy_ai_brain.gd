extends SceneTree

## Smoke test: EnemyAIBrain produces Intents with non-zero move_direction
## when a wander timer has expired (it always has direction on first tick
## since _ready picks a random heading). magnitude should equal wander
## fraction since no target is present yet.
## Run: godot --headless --script res://tests/test_enemy_ai_brain.gd --quit

func _init() -> void:
	var failures: Array[String] = []

	var brain := EnemyAIBrain.new()
	# Disable perf gating before _ready so this contract test ticks every
	# frame (production brains stagger 1-in-N which would make a single
	# tick non-deterministic for the wander assertion).
	brain.tick_every_n_frames = 1
	brain.pause_animation_offscreen = false
	brain._ready()  # manual _ready since we're not in a full tree

	# Use a bare Node3D as the body stub — EnemyAIBrain uses body for
	# position/is_on_wall/tree. For this smoke test we skip the wall/ledge
	# probes and just check Intent shape.
	var body := Node3D.new()
	root.add_child(body)
	body.add_child(brain)
	brain._ready()

	var intent := brain.tick(body, 0.016)
	if intent == null:
		failures.append("tick() returned null")
	elif not (intent is Intent):
		failures.append("tick() should return Intent")
	else:
		# Wander magnitude should be wander_speed_fraction (direction set in _ready).
		if intent.move_direction.length() <= 0.0:
			failures.append("wander tick should produce non-zero move_direction")
		var mag: float = intent.move_direction.length()
		if abs(mag - brain.wander_speed_fraction) > 0.01:
			failures.append("wander magnitude %s should equal wander_speed_fraction %s"
				% [mag, brain.wander_speed_fraction])
		# Edge flags should be false while no target is in range.
		if intent.jump_pressed or intent.attack_pressed:
			failures.append("idle wander should not trigger jump/attack edges")

	body.queue_free()

	if failures.is_empty():
		print("PASS test_enemy_ai_brain: wander Intent produced with correct magnitude")
		quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_enemy_ai_brain: " + f)
		quit(1)
