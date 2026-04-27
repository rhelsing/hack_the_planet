extends SceneTree


func _init() -> void:
	var ps: PackedScene = load("res://level/interactable/bouncy_platform/bouncy_platform.tscn") as PackedScene
	if ps == null:
		push_error("[bouncy_platform] failed to load PackedScene")
		quit(1)
		return
	var inst: Node = ps.instantiate()
	if inst == null:
		push_error("[bouncy_platform] failed to instantiate")
		quit(1)
		return
	root.add_child(inst)
	# Force _ready propagation; check the deck/material were wired.
	if not inst.has_node(^"Deck/Box"):
		push_error("[bouncy_platform] missing Deck/Box")
		quit(1)
		return
	if not inst.has_node(^"CarryZone"):
		push_error("[bouncy_platform] missing CarryZone")
		quit(1)
		return
	print("[bouncy_platform] load OK")
	quit(0)
