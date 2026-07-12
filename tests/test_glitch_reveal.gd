extends Node
## Scene-mode contract test for GlitchReveal. Boots the project normally so
## GameState/Events autoloads are live (SceneTree --script mode can't compile
## autoload references — same reason test_runner.tscn exists).
##
## Invoke with:
##   godot --headless --path . res://tests/test_glitch_reveal.tscn

var _failures: Array[String] = []


func _ready() -> void:
	# One frame so autoloads finish their own _ready.
	await get_tree().process_frame
	var ps: PackedScene = load("res://level/interactable/portal_platform/portal_platform.tscn")
	var platform: Node3D = ps.instantiate() as Node3D
	var reveal := Node.new()
	reveal.set_script(load("res://level/interactable/glitch_reveal/glitch_reveal.gd"))
	reveal.set(&"reveal_flag", &"test_glitch_reveal_flag")
	reveal.set(&"reveal_duration", 0.1)
	platform.add_child(reveal)
	add_child(platform)
	# Hide is deferred one frame past the ready cascade.
	await get_tree().process_frame
	var box: CSGBox3D = platform.get_node(^"Deck/Box") as CSGBox3D
	var trigger: Area3D = platform.get_node(^"Trigger") as Area3D
	_expect("hidden: platform invisible", not platform.visible)
	_expect("hidden: box collision off", not box.use_collision)
	_expect("hidden: trigger shape disabled", (trigger.get_node(^"Shape") as CollisionShape3D).disabled)
	_expect("hidden: trigger not monitoring", not trigger.monitoring)

	GameState.set_flag("test_glitch_reveal_flag", true)
	await get_tree().process_frame
	_expect("revealed: platform visible", platform.visible)
	_expect("revealed: box collision restored", box.use_collision)
	_expect("revealed: glitch overlay applied", box.material_overlay != null)
	_expect("revealed: starts transparent", box.transparency > 0.5)

	# Let the 0.1s reveal finish.
	await get_tree().create_timer(0.3).timeout
	_expect("done: overlay cleared", box.material_overlay == null)
	_expect("done: fully opaque", box.transparency < 0.01)
	_expect("done: trigger armed", trigger.monitoring)
	_expect("done: trigger shape enabled", not (trigger.get_node(^"Shape") as CollisionShape3D).disabled)

	# Already-true flag at ready → platform left in authored state.
	var platform2: Node3D = ps.instantiate() as Node3D
	var reveal2 := Node.new()
	reveal2.set_script(load("res://level/interactable/glitch_reveal/glitch_reveal.gd"))
	reveal2.set(&"reveal_flag", &"test_glitch_reveal_flag")
	platform2.add_child(reveal2)
	add_child(platform2)
	await get_tree().process_frame
	_expect("saved-game: platform stays visible", platform2.visible)
	_expect("saved-game: collision untouched", (platform2.get_node(^"Deck/Box") as CSGBox3D).use_collision)

	if _failures.is_empty():
		print("[test_glitch_reveal] PASS (%d checks)" % 14)
		get_tree().quit(0)
	else:
		for f in _failures:
			push_error("[test_glitch_reveal] FAIL: %s" % f)
		get_tree().quit(1)


func _expect(label: String, ok: bool) -> void:
	if not ok:
		_failures.append(label)
