extends SceneTree


func _init() -> void:
	var ps: PackedScene = load("res://level/interactable/crumble_platform/crumble_platform.tscn") as PackedScene
	if ps == null:
		push_error("[crumble_platform] failed to load PackedScene")
		quit(1)
		return
	var inst: Node = ps.instantiate()
	if inst == null:
		push_error("[crumble_platform] failed to instantiate")
		quit(1)
		return
	root.add_child(inst)
	if not inst.has_node(^"Deck/Box"):
		push_error("[crumble_platform] missing Deck/Box")
		quit(1)
		return
	if not inst.has_node(^"Trigger"):
		push_error("[crumble_platform] missing Trigger")
		quit(1)
		return
	print("[crumble_platform] load OK")
	quit(0)
