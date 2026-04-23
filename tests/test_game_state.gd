extends Node

## Integration test for GameState autoload. Uses the real live autoload so
## Events signal emissions round-trip correctly.
##
## Run with:
##   godot --headless res://tests/test_game_state.tscn
## Exits with code 0 on pass, 1 on fail.


func _ready() -> void:
	var failures: Array[String] = []

	# Fresh slate regardless of prior session state.
	GameState.reset()

	# ---- Inventory ----
	if GameState.has_item(&"village_key"):
		failures.append("has_item should be false on empty inventory")
	GameState.add_item(&"village_key")
	if not GameState.has_item(&"village_key"):
		failures.append("has_item should be true after add_item")
	# Idempotent: adding twice doesn't duplicate.
	GameState.add_item(&"village_key")
	if GameState.inventory.size() != 1:
		failures.append("add_item should be idempotent, got size %d" % GameState.inventory.size())
	GameState.remove_item(&"village_key")
	if GameState.has_item(&"village_key"):
		failures.append("has_item should be false after remove_item")
	GameState.remove_item(&"nonexistent")
	if not GameState.inventory.is_empty():
		failures.append("remove_item on nonexistent should not mutate")

	# ---- Flags ----
	if GameState.get_flag(&"door_01") != null:
		failures.append("get_flag missing should return null default")
	if GameState.get_flag(&"door_01", false) != false:
		failures.append("get_flag should honor provided default")
	GameState.set_flag(&"door_01", true)
	if GameState.get_flag(&"door_01") != true:
		failures.append("flag round-trip failed")
	GameState.set_flag(&"counter", 3)
	if GameState.get_flag(&"counter") != 3:
		failures.append("int-valued flag round-trip failed")

	# ---- Dialogue-visited (matches 3dPFormer zipped-key shape) ----
	if GameState.has_visited("Troll", "opener_Hi!"):
		failures.append("has_visited should be false before visit")
	GameState.visit_dialogue("Troll", "opener", "Hi!")
	if not GameState.has_visited("Troll", "opener_Hi!"):
		failures.append("visit_dialogue should record zipped key")
	if GameState.has_visited("Frog", "opener_Hi!"):
		failures.append("visit_dialogue should scope by character")

	# ---- Save round-trip ----
	GameState.add_item(&"floppy_disk")
	GameState.set_flag(&"mainframe_hacked", true)
	var snapshot: Dictionary = GameState.to_dict()
	GameState.reset()
	if not GameState.inventory.is_empty():
		failures.append("reset should clear inventory")
	if not GameState.flags.is_empty():
		failures.append("reset should clear flags")
	if not GameState.dialogue_visited.is_empty():
		failures.append("reset should clear dialogue_visited")

	GameState.from_dict(snapshot)
	if not GameState.has_item(&"floppy_disk"):
		failures.append("from_dict should restore inventory")
	if GameState.get_flag(&"mainframe_hacked") != true:
		failures.append("from_dict should restore flags")
	if not GameState.has_visited("Troll", "opener_Hi!"):
		failures.append("from_dict should restore dialogue_visited")

	# ---- Deep-copy safety ----
	GameState.set_flag(&"post_load_mutation", true)
	if snapshot.flags.has(&"post_load_mutation"):
		failures.append("from_dict should deep-copy flags (snapshot leaked into live)")

	# ---- Schema version stamped (v2 since counters were added) ----
	if snapshot.get("version") != GameState.SCHEMA_VERSION:
		failures.append("to_dict should stamp SCHEMA_VERSION (%d), got %s" %
			[GameState.SCHEMA_VERSION, str(snapshot.get("version"))])

	# ---- Typed inventory reload (StringName coercion from JSON-loaded strings) ----
	var raw_dict: Dictionary = {
		"version": 1,
		"inventory": ["plain_string_id", "another"],
		"flags": {},
		"dialogue_visited": {},
	}
	GameState.reset()
	GameState.from_dict(raw_dict)
	if not GameState.has_item(&"plain_string_id"):
		failures.append("from_dict should coerce String inventory entries to StringName")

	# ---- Counters (v2 schema, for HUD — per hud.md §7.2.1) ----
	GameState.reset()
	if GameState.coin_count != 0:
		failures.append("reset() should zero coin_count")
	if GameState.floppy_count != 0:
		failures.append("reset() should zero floppy_count")
	# coin_collected bumps coin_count (legacy signal from auto-trigger pickups)
	Events.coin_collected.emit(null)
	Events.coin_collected.emit(null)
	if GameState.coin_count != 2:
		failures.append("coin_count should bump on Events.coin_collected, got %d" % GameState.coin_count)
	# Floppy added via add_item bumps floppy_count
	GameState.add_item(&"floppy_disk")
	GameState.add_item(&"other_item")
	if GameState.floppy_count != 1:
		failures.append("floppy_count should bump only for floppy_disk, got %d" % GameState.floppy_count)
	# Round-trip counters through dict
	var snap2: Dictionary = GameState.to_dict()
	if snap2.get("version") != 2:
		failures.append("SCHEMA_VERSION should be 2 after counter add")
	if snap2.get("coin_count") != 2 or snap2.get("floppy_count") != 1:
		failures.append("to_dict should carry counter fields")
	GameState.reset()
	GameState.from_dict(snap2)
	if GameState.coin_count != 2 or GameState.floppy_count != 1:
		failures.append("from_dict should restore counters")
	# Old v1 dicts without counter fields → default to 0 (migration safety)
	var v1_dict: Dictionary = {"version": 1, "inventory": [], "flags": {}, "dialogue_visited": {}}
	GameState.from_dict(v1_dict)
	if GameState.coin_count != 0 or GameState.floppy_count != 0:
		failures.append("from_dict should default counters to 0 on v1 saves")

	# ---- Events signal emission (live autoload wiring) ----
	var received_items: Array = []
	var cb := func(id: StringName) -> void: received_items.append(id)
	Events.item_added.connect(cb)
	GameState.reset()
	GameState.add_item(&"signal_test")
	if not received_items.has(&"signal_test"):
		failures.append("add_item should fire Events.item_added")
	Events.item_added.disconnect(cb)

	var received_flags: Array = []
	var cb2 := func(id: StringName, _val: Variant) -> void: received_flags.append(id)
	Events.flag_set.connect(cb2)
	GameState.set_flag(&"signal_flag", 42)
	if not received_flags.has(&"signal_flag"):
		failures.append("set_flag should fire Events.flag_set")
	Events.flag_set.disconnect(cb2)

	# ---- Done ----
	if failures.is_empty():
		print("PASS test_game_state: inventory + flags + dialogue + save + deep-copy + coercion + signals")
		get_tree().quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_game_state: " + f)
		get_tree().quit(1)
