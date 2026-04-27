extends SceneTree


func _init() -> void:
	var ps: PackedScene = load("res://level/interactable/convert_zone/convert_zone.tscn") as PackedScene
	if ps == null:
		push_error("[convert_zone] failed to load PackedScene")
		quit(1)
		return
	var inst: Node = ps.instantiate()
	if inst == null:
		push_error("[convert_zone] failed to instantiate")
		quit(1)
		return
	if not (inst is Area3D):
		push_error("[convert_zone] root is not Area3D, got %s" % inst.get_class())
		quit(1)
		return
	if not "id" in inst:
		push_error("[convert_zone] missing `id` export")
		quit(1)
		return
	# Set id BEFORE add_child so _ready picks it up and registers.
	inst.set(&"id", &"test_zone_alpha")
	root.add_child(inst)
	# add_child defers _ready to end-of-frame — wait one process frame so
	# the static-var registration has actually run before we check it.
	await process_frame
	var script: Script = load("res://level/interactable/convert_zone/convert_zone.gd")
	var zones: Array = script.call(&"zones_for", &"test_zone_alpha") as Array
	if zones.is_empty():
		push_error("[convert_zone] registry didn't pick up the zone")
		quit(1)
		return
	print("[convert_zone] load OK, registry size=%d" % zones.size())
	quit(0)
