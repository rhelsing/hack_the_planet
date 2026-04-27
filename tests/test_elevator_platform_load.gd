extends SceneTree


func _init() -> void:
	var ps: PackedScene = load("res://level/interactable/elevator_platform/elevator_platform.tscn") as PackedScene
	if ps == null:
		push_error("[elevator_platform] failed to load PackedScene")
		quit(1)
		return
	var inst: Node = ps.instantiate()
	if inst == null:
		push_error("[elevator_platform] failed to instantiate")
		quit(1)
		return
	root.add_child(inst)
	if not inst.has_node(^"Deck/Visual"):
		push_error("[elevator_platform] missing Deck/Visual")
		quit(1)
		return
	if not inst.has_node(^"Deck/CollisionShape3D"):
		push_error("[elevator_platform] missing Deck/CollisionShape3D")
		quit(1)
		return
	var deck: Node = inst.get_node(^"Deck")
	if not (deck is AnimatableBody3D):
		push_error("[elevator_platform] Deck is not AnimatableBody3D, got %s" % deck.get_class())
		quit(1)
		return
	print("[elevator_platform] load OK")
	quit(0)
