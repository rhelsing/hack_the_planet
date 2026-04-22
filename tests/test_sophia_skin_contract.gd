extends SceneTree

## Proves Sophia's skin is a valid CharacterSkin: exposes lean_pivot_height,
## body_center_y, and damage_tint; inherits the no-op animation methods
## (though Sophia overrides all of them).
## Run: godot --headless --script res://tests/test_sophia_skin_contract.gd --quit

func _init() -> void:
	var failures: Array[String] = []

	var scene: PackedScene = load("res://player/sophia_skin/sophia_skin.tscn")
	if scene == null:
		failures.append("could not load sophia_skin.tscn")
	else:
		var skin := scene.instantiate()
		if not (skin is CharacterSkin):
			failures.append("sophia scene root doesn't extend CharacterSkin (got %s)" % skin.get_class())
		else:
			var cs := skin as CharacterSkin
			if cs.lean_pivot_height <= 0.0:
				failures.append("lean_pivot_height should be > 0, got %s" % cs.lean_pivot_height)
			if cs.body_center_y <= 0.0:
				failures.append("body_center_y should be > 0, got %s" % cs.body_center_y)
			# Contract methods exist and can be called without args.
			for m: String in ["idle", "move", "fall", "jump", "edge_grab", "wall_slide", "attack"]:
				if not cs.has_method(m):
					failures.append("sophia missing contract method: %s" % m)
			# damage_tint setter clamps input.
			cs.damage_tint = 2.5
			if cs.damage_tint > 1.0:
				failures.append("damage_tint should clamp to [0,1], got %s" % cs.damage_tint)
		skin.queue_free()

	if failures.is_empty():
		print("PASS test_sophia_skin_contract: Sophia conforms to CharacterSkin")
		quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_sophia_skin_contract: " + f)
		quit(1)
