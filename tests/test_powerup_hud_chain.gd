extends Node

## Traces the full "pickup → flag → ability → HUD" chain on a fresh GameState.
## Reveals whether:
##   1. Setting the flag flips Ability.owned true
##   2. The Ability calls body.notify_ability_granted
##   3. PlayerBody.ability_granted signal emits
##   4. Something's consuming it (the HUD connects via call_deferred)
##
## Run with: godot --headless res://tests/test_powerup_hud_chain.tscn


func _ready() -> void:
	var failures: Array[String] = []
	GameState.reset()

	# Simulate Continue-from-save: flag is already true BEFORE game.tscn
	# instantiates. If the HUD rebuild timing is wrong this will break.
	# GameState.set_flag(&"powerup_love", true)

	# Load the full game.tscn so PlayerBody + HUD + Abilities wire up the
	# same way they do at runtime.
	var packed: PackedScene = load("res://game.tscn")
	if packed == null:
		failures.append("could not load game.tscn")
		_report(failures)
		return
	var game := packed.instantiate()
	add_child(game)

	# Give deferred calls (HUD._bind) a chance to run.
	await get_tree().process_frame
	await get_tree().process_frame

	var player: Node = game.get_node_or_null(^"Player")
	if player == null:
		failures.append("Player node missing from game.tscn")
		_report(failures)
		return

	var abilities: Node = player.get_node_or_null(^"Abilities")
	if abilities == null:
		failures.append("Player/Abilities missing")
		_report(failures)
		return

	print("[diag] Abilities children:")
	for child in abilities.get_children():
		var script_path := ""
		var s: Script = child.get_script() as Script
		if s != null:
			script_path = s.resource_path
		print("[diag]   %s script=%s ability_id=%s flag=%s" % [
			child.name, script_path, child.get("ability_id"), child.get("powerup_flag")
		])

	var skate: Node = abilities.get_node_or_null(^"SkateAbility")
	if skate == null:
		failures.append("SkateAbility missing under Abilities")
		_report(failures)
		return
	print("[diag] SkateAbility found, ability_id=%s powerup_flag=%s owned=%s"
		% [skate.ability_id, skate.powerup_flag, skate.owned])

	# Check HUD wiring.
	var powerup_row: Node = game.get_node_or_null(^"HUD/TopLeftBelowHealth/PowerupRow")
	if powerup_row == null:
		failures.append("HUD/TopLeftBelowHealth/PowerupRow missing")
	else:
		print("[diag] PowerupRow found")
		# After two frames, _bind should have run.
		var is_connected: bool = false
		if player.has_signal(&"ability_granted"):
			for conn: Dictionary in player.ability_granted.get_connections():
				var cb: Callable = conn.get("callable")
				if cb.get_object() == powerup_row:
					is_connected = true
					break
		print("[diag] PowerupRow connected to ability_granted: %s" % is_connected)

	# Listen directly on the player signal so we know whether it emits.
	var granted_heard: Array = []
	if player.has_signal(&"ability_granted"):
		player.ability_granted.connect(func(id: StringName) -> void:
			granted_heard.append(id)
		)

	# Simulate a powerup pickup.
	print("[diag] before set_flag: skate.owned=%s" % skate.owned)
	GameState.set_flag(&"powerup_love", true)
	# Let the signal propagation settle.
	await get_tree().process_frame
	print("[diag] after set_flag:  skate.owned=%s  heard=%s" % [skate.owned, granted_heard])

	if not skate.owned:
		failures.append("skate.owned did NOT flip true after set_flag")
	if not granted_heard.has(&"Skate"):
		failures.append("PlayerBody.ability_granted(&'Skate') was not emitted")

	# Check HUD slot was added.
	if powerup_row != null:
		var slots: Dictionary = powerup_row.get("_slots")
		if slots == null:
			failures.append("PowerupRow._slots property missing")
		else:
			print("[diag] PowerupRow slots: %s" % slots.keys())
			print("[diag] PowerupRow visible: %s" % powerup_row.visible)
			if not slots.has(&"Skate"):
				failures.append("PowerupRow did not add a slot for &'Skate'")
			else:
				var slot: Control = slots[&"Skate"] as Control
				if slot != null:
					var label: Label = null
					for c in slot.get_children():
						if c is Label:
							label = c as Label
							break
					var text: String = label.text if label != null else "<no label>"
					print("[diag] Skate slot text: '%s' visible: %s" % [text, slot.visible])

	_report(failures)


func _report(failures: Array) -> void:
	if failures.is_empty():
		print("PASS test_powerup_hud_chain")
		get_tree().quit(0)
	else:
		for f in failures:
			printerr("FAIL test_powerup_hud_chain: " + str(f))
		get_tree().quit(1)
