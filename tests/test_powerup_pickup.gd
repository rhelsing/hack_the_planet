extends Node

## Integration test for PowerupPickup.
## Run with:
##   godot --headless res://tests/test_powerup_pickup.tscn
## Exits 0 on pass, 1 on fail.


func _ready() -> void:
	var failures: Array[String] = []
	GameState.reset()

	var scene: PackedScene = load("res://interactable/pickup/powerup_pickup.tscn")
	if scene == null:
		failures.append("could not load powerup_pickup.tscn")
		_report(failures)
		return

	var pickup := scene.instantiate()
	pickup.powerup_flag = &"powerup_love"
	pickup.powerup_label = "LOVE"
	add_child(pickup)

	# _ready should push the label onto the DiskLabel child.
	var disk_label: Label3D = pickup.get_node_or_null(^"DiskLabel") as Label3D
	if disk_label == null:
		failures.append("powerup_pickup.tscn missing DiskLabel child")
	elif disk_label.text != "LOVE":
		failures.append("DiskLabel.text should be 'LOVE' after _ready, got '%s'" % disk_label.text)

	# Capture the item_added signal so we know the collect-ding pathway fires.
	var items_heard: Array = []
	var cb := func(id: StringName) -> void: items_heard.append(id)
	Events.item_added.connect(cb)

	pickup.interact(null)

	if GameState.get_flag(&"powerup_love") != true:
		failures.append("interact should set powerup_love flag")
	if not items_heard.has(&"powerup_love"):
		failures.append("interact should emit Events.item_added with the flag id")

	Events.item_added.disconnect(cb)

	# Invalid-config path: empty flag should push_error and free.
	var pickup2 := scene.instantiate()
	pickup2.powerup_flag = &""
	add_child(pickup2)
	# interact() pushes an error and queue_frees — just verify it doesn't crash.
	pickup2.interact(null)

	_report(failures)


func _report(failures: Array) -> void:
	if failures.is_empty():
		print("PASS test_powerup_pickup")
		get_tree().quit(0)
	else:
		for f in failures:
			printerr("FAIL test_powerup_pickup: " + str(f))
		get_tree().quit(1)
