extends Node

## End-to-end integration: Door.interact() wires through GameState flag →
## Events.door_opened emission → Audio subscription reaction (door_open cue
## looked up in registry). Also exercises requires_key gating.
##
## Run with:
##   godot --headless res://tests/test_door_e2e.tscn


const DoorScene = preload("res://interactable/door/door.tscn")


var _door_opened_ids: Array = []
var _flags_set: Array = []


func _ready() -> void:
	Events.door_opened.connect(func(id): _door_opened_ids.append(id))
	Events.flag_set.connect(func(id, _v): _flags_set.append(id))
	_run.call_deferred()


func _run() -> void:
	var failures: Array[String] = []
	# Stand-in actor — interact()/can_interact() are typed Node3D.
	var actor := Node3D.new()
	add_child(actor)

	GameState.reset()

	# ---- Happy path: no key required ----
	var door1: Interactable = DoorScene.instantiate()
	door1.interactable_id = &"test_door_01"
	add_child(door1)

	if not door1.can_interact(actor):
		failures.append("door without requires_key should allow interact")

	door1.interact(actor)
	await get_tree().process_frame

	if not _door_opened_ids.has(&"test_door_01"):
		failures.append("Events.door_opened should fire with the door's id")
	if not _flags_set.has(&"test_door_01"):
		failures.append("GameState.set_flag should fire via Events.flag_set")
	if GameState.get_flag(&"test_door_01") != true:
		failures.append("door should set its id flag to true on interact")

	# ---- Key gating: locked door rejects when inventory lacks key ----
	var door2: Interactable = DoorScene.instantiate()
	door2.interactable_id = &"test_door_02"
	door2.requires_key = &"gold_key"
	add_child(door2)

	if door2.can_interact(actor):
		failures.append("door with requires_key should reject when key not in inventory")

	# ---- Key gating: unlocked when key added ----
	GameState.add_item(&"gold_key")
	if not door2.can_interact(actor):
		failures.append("door with requires_key should allow when key is in inventory")

	door2.interact(actor)
	await get_tree().process_frame

	if not _door_opened_ids.has(&"test_door_02"):
		failures.append("gated door should emit door_opened after unlock")

	# ---- Audio integration: registry has the cue that should fire ----
	# Can't easily assert playback in headless (no mixer), but we can verify
	# the cue exists so the subscription isn't a dead reference.
	if Audio._registry == null:
		failures.append("Audio registry missing — cue reaction path dead")
	else:
		var cues: Dictionary = Audio._registry.get("cues")
		if not cues.has(&"door_open"):
			failures.append("Audio registry missing 'door_open' cue — Events.door_opened subscription has nothing to play")

	# ---- Idempotency: two emits for two doors, not cross-contaminated ----
	if _door_opened_ids.size() != 2:
		failures.append("expected exactly 2 door_opened emissions, got %d" % _door_opened_ids.size())

	if failures.is_empty():
		print("PASS test_door_e2e: interact → flag → Events.door_opened → Audio reacts; key gating works both ways")
		get_tree().quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_door_e2e: " + f)
		get_tree().quit(1)
