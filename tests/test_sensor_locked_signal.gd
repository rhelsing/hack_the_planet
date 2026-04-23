extends Node

## Verifies InteractionSensor.try_activate emits the `locked` signal with a
## human-readable reason when the focused interactable is gated, and does NOT
## emit `locked` on a clean activation.
##
## Run with:
##   godot --headless res://tests/test_sensor_locked_signal.tscn


const SensorScene = preload("res://interactable/interaction_sensor.tscn")
const DoorScene = preload("res://interactable/door/door.tscn")


var _locked_events: Array = []
var _sensor: Node


func _ready() -> void:
	GameState.reset()

	# Minimal body stand-in — sensor.body is typed CharacterBody3D and is
	# read by the scoring function for position/forward.
	var body := CharacterBody3D.new()
	body.add_to_group(&"player")
	body.global_position = Vector3.ZERO
	add_child(body)

	_sensor = SensorScene.instantiate()
	add_child(_sensor)
	_sensor.body = body
	_sensor.locked.connect(_on_locked)

	_run.call_deferred()


func _on_locked(_it, reason: String) -> void:
	_locked_events.append(reason)


func _run() -> void:
	var failures: Array[String] = []

	# ---- No focus → try_activate does nothing ----
	_sensor.try_activate(_sensor.body)
	if _locked_events.size() != 0:
		failures.append("try_activate with no focus should not emit locked")

	# ---- Focus an unlocked door → activate succeeds, no locked emit ----
	var door_ok: Interactable = DoorScene.instantiate()
	door_ok.interactable_id = &"ok_door"
	add_child(door_ok)
	_sensor.focused = door_ok
	_sensor.try_activate(_sensor.body)
	await get_tree().process_frame
	if _locked_events.size() != 0:
		failures.append("unlocked door activation should not emit locked")

	# ---- Focus a gated door → activate emits locked with reason ----
	var door_gated: Interactable = DoorScene.instantiate()
	door_gated.interactable_id = &"gated_door"
	door_gated.requires_key = &"silver_key"
	add_child(door_gated)
	_sensor.focused = door_gated
	_locked_events.clear()
	_sensor.try_activate(_sensor.body)
	if _locked_events.size() != 1:
		failures.append("gated door activation should emit locked once, got %d" % _locked_events.size())
	elif not _locked_events[0].contains("Silver Key"):
		failures.append("locked reason should mention key, got '%s'" % _locked_events[0])

	# ---- Satisfy the gate → activation succeeds, no locked emit ----
	GameState.add_item(&"silver_key")
	_locked_events.clear()
	_sensor.focused = door_gated
	_sensor.try_activate(_sensor.body)
	await get_tree().process_frame
	if _locked_events.size() != 0:
		failures.append("gated door should NOT emit locked after key is obtained")

	# ---- Done ----
	if failures.is_empty():
		print("PASS test_sensor_locked_signal: locked emits only on gated activation, carries humanized reason")
		get_tree().quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_sensor_locked_signal: " + f)
		get_tree().quit(1)
