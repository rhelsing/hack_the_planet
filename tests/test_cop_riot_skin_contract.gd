extends SceneTree

## Proves cop_riot_skin.tscn conforms to CharacterSkin: exposes the
## proportions, implements the contract methods, damage_tint clamps.
## Run: godot --headless --script res://tests/test_cop_riot_skin_contract.gd --quit

func _init() -> void:
	var failures: Array[String] = []

	var scene: PackedScene = load("res://player/skins/cop_riot/cop_riot_skin.tscn")
	if scene == null:
		failures.append("could not load cop_riot_skin.tscn")
	else:
		var skin := scene.instantiate()
		if not (skin is CharacterSkin):
			failures.append("cop_riot scene root doesn't extend CharacterSkin (got %s)" % skin.get_class())
		else:
			var cs := skin as CharacterSkin
			if cs.lean_pivot_height <= 0.0:
				failures.append("lean_pivot_height should be > 0, got %s" % cs.lean_pivot_height)
			if cs.body_center_y <= 0.0:
				failures.append("body_center_y should be > 0, got %s" % cs.body_center_y)
			for m: String in ["idle", "move", "fall", "jump", "edge_grab", "wall_slide", "attack", "dash", "crouch"]:
				if not cs.has_method(m):
					failures.append("cop_riot missing contract method: %s" % m)
			# damage_tint setter (inherited, no-op but clamps).
			cs.damage_tint = 3.0
			if cs.damage_tint > 1.0:
				failures.append("damage_tint should clamp to [0,1], got %s" % cs.damage_tint)
		skin.queue_free()

	if failures.is_empty():
		print("PASS test_cop_riot_skin_contract: cop_riot conforms to CharacterSkin")
		quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_cop_riot_skin_contract: " + f)
		quit(1)
