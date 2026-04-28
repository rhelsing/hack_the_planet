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
	GameState.add_item(&"some_item")
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
	if not GameState.has_item(&"some_item"):
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

	# ---- Coin sets (persisted, set-shaped) ----
	GameState.reset()
	if GameState.coin_count != 0 or GameState.coin_total != 0:
		failures.append("reset() should zero coin counters")
	if not GameState.coins_collected.is_empty() or not GameState.coins_seen.is_empty():
		failures.append("reset() should clear coin sets")
	# Manual set mutation simulates coin._ready / collect — without a real
	# scene tree we can't call register_coin(coin) with a real Node, so
	# we exercise the dict shape directly.
	GameState.coins_seen["/root/Level/Coin1"] = true
	GameState.coins_seen["/root/Level/Coin2"] = true
	GameState.coins_seen["/root/Level/Coin3"] = true
	GameState.coin_total = GameState.coins_seen.size()
	GameState.coins_collected["/root/Level/Coin1"] = true
	GameState.coin_count = GameState.coins_collected.size()
	# Round-trip through save: counters should restore from the dict sizes.
	var snap2: Dictionary = GameState.to_dict()
	if not snap2.has("coins_collected") or not snap2.has("coins_seen"):
		failures.append("to_dict should carry coin sets")
	GameState.reset()
	GameState.from_dict(snap2)
	if GameState.coin_count != 1:
		failures.append("from_dict should restore coin_count from coins_collected.size, got %d" % GameState.coin_count)
	if GameState.coin_total != 3:
		failures.append("from_dict should restore coin_total from coins_seen.size, got %d" % GameState.coin_total)
	if not GameState.coins_collected.has("/root/Level/Coin1"):
		failures.append("from_dict should restore coins_collected paths")
	# Old v2 saves had `coin_count` / `floppy_count` as plain ints. Loading
	# one of those should zero the new sets without erroring.
	var v2_save: Dictionary = {
		"version": 2, "inventory": [], "flags": {}, "dialogue_visited": {},
		"coin_count": 99, "floppy_count": 7,
	}
	GameState.from_dict(v2_save)
	if GameState.coin_count != 0 or GameState.coin_total != 0:
		failures.append("v2 saves (no coin sets) should leave counters at 0")

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
