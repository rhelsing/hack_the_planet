extends Node

## Integration test for LevelProgression autoload.
## Run with:
##   godot --headless res://tests/test_level_progression.tscn
## Exits 0 on pass, 1 on fail.


func _ready() -> void:
	var failures: Array[String] = []

	GameState.reset()

	# ---- register_level writes current_level_num + SaveService path ----
	LevelProgression.register_level(1)
	if LevelProgression.get_current_level_num() != 1:
		failures.append("register_level(1) should set current_level_num to 1, got %d"
			% LevelProgression.get_current_level_num())
	if SaveService.current_level != &"level_1":
		failures.append("register_level(1) should set SaveService.current_level to level_1, got %s"
			% SaveService.current_level)

	# ---- is_level_complete reads the level_N_completed flag ----
	if LevelProgression.is_level_complete(1):
		failures.append("is_level_complete(1) should start false")
	GameState.set_flag(&"level_1_completed", true)
	if not LevelProgression.is_level_complete(1):
		failures.append("is_level_complete(1) should be true after flag set")

	# ---- is_powerup_owned reads flags ----
	if LevelProgression.is_powerup_owned(&"powerup_love"):
		failures.append("is_powerup_owned should start false")
	GameState.set_flag(&"powerup_love", true)
	if not LevelProgression.is_powerup_owned(&"powerup_love"):
		failures.append("is_powerup_owned should be true after flag set")

	# ---- advance() marks completed + points SaveService at hub ----
	GameState.reset()
	LevelProgression.register_level(2)
	LevelProgression.advance()
	# advance calls SceneLoader.goto, which may be async. What we can verify
	# synchronously: the flag + save path were set before the goto.
	if not GameState.get_flag(&"level_2_completed", false):
		failures.append("advance() should set level_2_completed")
	if SaveService.current_level != LevelProgression.HUB_LEVEL_ID:
		failures.append("advance() should set SaveService.current_level to hub, got %s"
			% SaveService.current_level)

	# ---- goto_level gate: level > 1 requires previous complete ----
	GameState.reset()
	LevelProgression.goto_level(3)  # should be blocked (L2 not done)
	if SaveService.current_level == &"level_3":
		failures.append("goto_level(3) should be blocked when level 2 not complete")

	# L2 complete → L3 should work
	GameState.set_flag(&"level_2_completed", true)
	LevelProgression.goto_level(3)
	if SaveService.current_level != &"level_3":
		failures.append("goto_level(3) should route to level_3 when L2 complete, got %s"
			% SaveService.current_level)

	# L1 is always unlocked
	GameState.reset()
	LevelProgression.goto_level(1)
	if SaveService.current_level != &"level_1":
		failures.append("goto_level(1) should always work, got %s" % SaveService.current_level)

	# Out of range
	LevelProgression.goto_level(0)  # push_error, no mutation
	LevelProgression.goto_level(5)

	# ---- Done ----
	if failures.is_empty():
		print("PASS test_level_progression")
		get_tree().quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_level_progression: " + f)
		get_tree().quit(1)
