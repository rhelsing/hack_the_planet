extends Node

## Tests Interactable.is_locked() + describe_lock() — the new API the
## PromptUI + sensor depend on for the locked-notice UX.
##
## Run with:
##   godot --headless res://tests/test_interactable_lock.tscn


const DoorScene = preload("res://interactable/door/door.tscn")


func _ready() -> void:
	var failures: Array[String] = []
	GameState.reset()

	# ---- Unlocked by default ----
	var plain: Interactable = DoorScene.instantiate()
	plain.interactable_id = &"plain_door"
	add_child(plain)
	if plain.is_locked():
		failures.append("door with no gates should not be locked")
	if plain.describe_lock() != "":
		failures.append("describe_lock should be empty string when unlocked, got '%s'" % plain.describe_lock())

	# ---- Key-gated, no key in inventory → locked ----
	var keyed: Interactable = DoorScene.instantiate()
	keyed.interactable_id = &"keyed_door"
	keyed.requires_key = &"red_key"
	add_child(keyed)
	if not keyed.is_locked():
		failures.append("door with requires_key and empty inventory should be locked")
	var reason: String = keyed.describe_lock()
	if not reason.begins_with("Locked"):
		failures.append("describe_lock should start with 'Locked', got '%s'" % reason)
	if not reason.contains("Red Key"):
		failures.append("describe_lock should humanize requires_key to 'Red Key', got '%s'" % reason)

	# ---- Add key → no longer locked ----
	GameState.add_item(&"red_key")
	if keyed.is_locked():
		failures.append("door should unlock after key is in inventory")
	if keyed.describe_lock() != "":
		failures.append("describe_lock should be empty after unlock")

	# ---- Flag-gated door ----
	var flagged: Interactable = DoorScene.instantiate()
	flagged.interactable_id = &"flagged_door"
	flagged.requires_flag = &"mainframe_hacked"
	add_child(flagged)
	if not flagged.is_locked():
		failures.append("door with requires_flag (unset) should be locked")
	var flag_reason: String = flagged.describe_lock()
	if not flag_reason.contains("Mainframe Hacked"):
		failures.append("describe_lock should humanize requires_flag, got '%s'" % flag_reason)

	# ---- Flag-gated: flag set false → still locked ----
	GameState.set_flag(&"mainframe_hacked", false)
	if not flagged.is_locked():
		failures.append("flag=false should still count as locked (get_flag default false is the same)")

	# ---- Flag-gated: flag=true → unlocked ----
	GameState.set_flag(&"mainframe_hacked", true)
	if flagged.is_locked():
		failures.append("flag=true should unlock the door")

	# ---- Both gates: needs BOTH to pass ----
	var both: Interactable = DoorScene.instantiate()
	both.interactable_id = &"both_gates"
	both.requires_key = &"gold_key"
	both.requires_flag = &"power_on"
	add_child(both)
	GameState.reset()
	# Neither satisfied
	var both_reason: String = both.describe_lock()
	if not both_reason.contains("Gold Key"):
		failures.append("both-gated lock reason should mention missing key")
	if not both_reason.contains("Power On"):
		failures.append("both-gated lock reason should mention missing flag")
	# One satisfied, other not
	GameState.add_item(&"gold_key")
	if not both.is_locked():
		failures.append("key alone shouldn't unlock when flag also required")
	GameState.set_flag(&"power_on", true)
	if both.is_locked():
		failures.append("both gates satisfied should unlock")

	# ---- Done ----
	if failures.is_empty():
		print("PASS test_interactable_lock: is_locked + describe_lock respect key + flag gates, humanize correctly")
		get_tree().quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_interactable_lock: " + f)
		get_tree().quit(1)
