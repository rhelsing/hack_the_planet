extends Node

## Boot-time smoke test for the game shell → hub mounting.
## Instances game.tscn as a subtree and verifies that after a couple of
## frames, the Level child is the hub (not the pre-baked legacy level).
## Run with:
##   godot --headless res://tests/test_game_hub_boot.tscn
## Exits 0 on pass, 1 on fail.


func _ready() -> void:
	var failures: Array[String] = []

	# Start from clean state — New Game equivalent.
	GameState.reset()
	SaveService.current_level = &""

	var packed: PackedScene = load("res://game.tscn")
	if packed == null:
		failures.append("could not load game.tscn")
		_report(failures)
		return

	var game := packed.instantiate()
	add_child(game)

	# Game._ready runs synchronously at add_child. Give one frame for any
	# deferred calls (unlikely, but safe) and then verify.
	await get_tree().process_frame

	var level: Node = game.get_node_or_null(^"Level")
	if level == null:
		failures.append("game.tscn has no Level child after _ready")
	else:
		var sf: String = level.scene_file_path
		if sf != "res://level/hub.tscn":
			failures.append("Level child should be hub.tscn, got: '%s'" % sf)

	if SaveService.current_level != &"hub":
		failures.append("SaveService.current_level should be 'hub' after boot, got '%s'"
			% SaveService.current_level)

	# Pedestal 1 (Love) is gated on level_1_unlocked (set by DialTone's intro).
	# On a fresh save without dialogue, it should be locked.
	var ped1 := game.get_node_or_null(^"Level/PedestalLove")
	if ped1 == null:
		failures.append("hub is missing PedestalLove")
	elif ped1.has_method(&"can_interact") and ped1.call(&"can_interact", null):
		failures.append("PedestalLove should be locked before level_1_unlocked")

	# Setting level_1_unlocked (what stage_intro does) opens it.
	GameState.set_flag(&"level_1_unlocked", true)
	if ped1 != null and ped1.has_method(&"can_interact") and not ped1.call(&"can_interact", null):
		failures.append("PedestalLove should unlock after level_1_unlocked")

	# Pedestal 2 (Secret) is gated on BOTH level_1_completed (auto, via level_num>1)
	# AND level_2_unlocked (set by DialTone's stage_post_1). Locked initially.
	var ped2 := game.get_node_or_null(^"Level/PedestalSecret")
	if ped2 == null:
		failures.append("hub is missing PedestalSecret")
	elif ped2.has_method(&"can_interact") and ped2.call(&"can_interact", null):
		failures.append("PedestalSecret should be locked before level_2_unlocked")

	# level_1_completed alone is not enough — still need level_2_unlocked.
	GameState.set_flag(&"level_1_completed", true)
	if ped2 != null and ped2.has_method(&"can_interact") and ped2.call(&"can_interact", null):
		failures.append("PedestalSecret should still be locked with only level_1_completed")

	# Both flags set — pedestal opens.
	GameState.set_flag(&"level_2_unlocked", true)
	if ped2 != null and ped2.has_method(&"can_interact") and not ped2.call(&"can_interact", null):
		failures.append("PedestalSecret should unlock after level_1_completed + level_2_unlocked")

	# Legacy current_level = "game" should also resolve to hub, not recurse.
	# (Simulate a stale save from before the level-host refactor.)
	SaveService.current_level = &"game"
	game.queue_free()
	await get_tree().process_frame

	GameState.reset()
	var game2 := packed.instantiate()
	add_child(game2)
	await get_tree().process_frame
	var level2: Node = game2.get_node_or_null(^"Level")
	if level2 == null:
		failures.append("legacy current_level='game' → Level child is null (expected hub)")
	elif level2.scene_file_path != "res://level/hub.tscn":
		failures.append("legacy current_level='game' should fall back to hub, got '%s'"
			% level2.scene_file_path)

	_report(failures)


func _report(failures: Array) -> void:
	if failures.is_empty():
		print("PASS test_game_hub_boot")
		get_tree().quit(0)
	else:
		for f in failures:
			printerr("FAIL test_game_hub_boot: " + str(f))
		get_tree().quit(1)
