extends SceneTree

## Proves floating_robot_skin.tscn conforms to CharacterSkin: scene root extends
## CharacterSkin, all 12 contract methods are reachable (inherited no-ops are
## fine — companion_npc never invokes them on this skin), and damage_tint
## clamps. Run: godot --headless --script res://tests/test_floating_robot_skin_contract.gd --quit

func _init() -> void:
	var failures: Array[String] = []

	var scene: PackedScene = load("res://player/skins/floating_robot/floating_robot_skin.tscn")
	if scene == null:
		failures.append("could not load floating_robot_skin.tscn")
	else:
		var skin := scene.instantiate()
		if not (skin is CharacterSkin):
			failures.append("floating_robot scene root doesn't extend CharacterSkin (got %s)" % skin.get_class())
		else:
			var cs := skin as CharacterSkin
			if cs.lean_pivot_height <= 0.0:
				failures.append("lean_pivot_height should be > 0, got %s" % cs.lean_pivot_height)
			if cs.body_center_y <= 0.0:
				failures.append("body_center_y should be > 0, got %s" % cs.body_center_y)
			for m: String in ["idle", "move", "fall", "jump", "edge_grab", "wall_slide", "attack", "dash", "crouch", "die", "land", "on_hit"]:
				if not cs.has_method(m):
					failures.append("floating_robot missing contract method: %s" % m)
			cs.damage_tint = 3.0
			if cs.damage_tint > 1.0:
				failures.append("damage_tint should clamp to [0,1], got %s" % cs.damage_tint)
		skin.queue_free()

	if failures.is_empty():
		print("PASS test_floating_robot_skin_contract: floating_robot conforms to CharacterSkin")
		quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_floating_robot_skin_contract: " + f)
		quit(1)
