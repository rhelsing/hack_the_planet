extends Node

## Coverage for DialogueExpander.expand. Runs as a scene so HandlePicker /
## Glyphs autoloads are available to the mustache resolver.
##
## Run: /Applications/Godot.app/Contents/MacOS/Godot --headless \
##         res://tests/test_dialogue_expander.tscn

func _ready() -> void:
	var failures: Array[String] = []

	# 1. No primitives — passes through.
	var v: Array[String] = DialogueExpander.expand("Plain line.")
	if v.size() != 1 or v[0] != "Plain line.":
		failures.append("plain line should pass through, got %s" % str(v))

	# 2. Self-closing [if /] — stripped.
	v = DialogueExpander.expand("Hi [if X /] there")
	if v.size() != 1:
		failures.append("self-closing [if /] should leave 1 variant, got %d" % v.size())
	elif v[0].contains("[if"):
		failures.append("self-closing [if /] not stripped: %s" % v[0])

	# 3. Block [if][else][/if] — 2 branches.
	v = DialogueExpander.expand("[if X]A[else]B[/if]")
	if v.size() != 2 or not (v.has("A") and v.has("B")):
		failures.append("if/else should produce {A, B}, got %s" % str(v))

	# 4. Block [if][/if] without else — 1 branch.
	v = DialogueExpander.expand("[if X]A[/if]")
	if v.size() != 1 or v[0] != "A":
		failures.append("if without else should produce {A}, got %s" % str(v))

	# 5. Alternation — N siblings.
	v = DialogueExpander.expand("[[hi|hello|hey]]")
	if v.size() != 3 or not (v.has("hi") and v.has("hello") and v.has("hey")):
		failures.append("alternation should split on |, got %s" % str(v))

	# 6. Mustache: chosen_name → POOL.size() variants.
	v = DialogueExpander.expand("Hi {{HandlePicker.chosen_name()}}.")
	if v.size() != HandlePicker.POOL.size():
		failures.append("chosen_name should expand to %d, got %d" % [HandlePicker.POOL.size(), v.size()])
	for s in v:
		if s.contains("{{"):
			failures.append("chosen_name variant still has mustache: %s" % s)

	# 7. Mustache: Glyphs.for_action → DEVICES.size() variants.
	v = DialogueExpander.expand("Press {{Glyphs.for_action(\"jump\")}}!")
	if v.size() != Glyphs.DEVICES.size():
		failures.append("for_action should expand to %d, got %d" % [Glyphs.DEVICES.size(), v.size()])
	var has_kb := false
	var has_pad := false
	for s in v:
		if s.contains("Space"): has_kb = true
		if s.contains("X"): has_pad = true
	if not has_kb or not has_pad:
		failures.append("for_action variants missing keyboard/gamepad labels: %s" % str(v))

	# 8. Mustache: option(N) — single deterministic variant.
	v = DialogueExpander.expand("{{HandlePicker.option(0)}}")
	if v.size() != 1 or v[0] != HandlePicker.POOL[0]:
		failures.append("option(0) should expand to single POOL[0], got %s" % str(v))

	# 9. Cartesian: Grit-style nested if + alternation.
	v = DialogueExpander.expand("[if X][[a|b|c]][else]z[/if]")
	if v.size() != 4 or not (v.has("a") and v.has("b") and v.has("c") and v.has("z")):
		failures.append("nested if+alt should produce {a, b, c, z}, got %s" % str(v))

	# 10. Unknown mustache → empty (line gets dropped).
	v = DialogueExpander.expand("Hi {{Unknown.thing()}}.")
	if v.size() != 0:
		failures.append("unknown mustache should produce [], got %s" % str(v))

	# 11. Cartesian: name × glyph = POOL × DEVICES.
	v = DialogueExpander.expand("{{HandlePicker.chosen_name()}}, hit {{Glyphs.for_action(\"jump\")}}.")
	var expected: int = HandlePicker.POOL.size() * Glyphs.DEVICES.size()
	if v.size() != expected:
		failures.append("name × glyph cartesian should be %d, got %d" % [expected, v.size()])

	if failures.is_empty():
		print("PASS test_dialogue_expander")
		get_tree().quit(0)
	else:
		for f in failures:
			printerr("FAIL: " + f)
		get_tree().quit(1)
