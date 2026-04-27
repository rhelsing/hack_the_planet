extends SceneTree


func _init() -> void:
	var ps: PackedScene = load("res://level/interactable/control_portal/control_portal.tscn") as PackedScene
	if ps == null:
		push_error("[control_portal] failed to load PackedScene")
		quit(1)
		return
	var inst: Node = ps.instantiate()
	if inst == null:
		push_error("[control_portal] failed to instantiate")
		quit(1)
		return
	root.add_child(inst)
	if not inst.has_node(^"Deck/Box"):
		push_error("[control_portal] missing Deck/Box")
		quit(1)
		return
	if not inst.has_node(^"Trigger"):
		push_error("[control_portal] missing Trigger")
		quit(1)
		return
	# ConvertZone is no longer a child — it's looked up by id at runtime
	# from a level-side ConvertZone scene. Verifying convert_zone_id export
	# exists is enough.
	if not "convert_zone_id" in inst:
		push_error("[control_portal] missing convert_zone_id export")
		quit(1)
		return
	print("[control_portal] load OK")
	quit(0)
