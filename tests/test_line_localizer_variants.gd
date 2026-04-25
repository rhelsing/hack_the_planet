extends Node

## Pure-function checks for LineLocalizer's variant expansion. Runs as a
## scene so the autoloads (HandlePicker, Glyphs) are available.
##
## Run: /Applications/Godot.app/Contents/MacOS/Godot --headless \
##         res://tests/test_line_localizer_variants.tscn

func _ready() -> void:
	var failures: Array[String] = []

	# Token-less template: single variant.
	var v1: Array[String] = LineLocalizer.all_variants("Plain line.")
	if v1.size() != 1 or v1[0] != "Plain line.":
		failures.append("token-less template should pass through unchanged, got %s" % str(v1))

	# Handle-only template: variants per HandlePicker.POOL entry.
	var v2: Array[String] = LineLocalizer.all_variants("Hi {player_handle}.")
	if v2.size() != HandlePicker.POOL.size():
		failures.append("handle-only variants should match POOL size (%d), got %d" % [HandlePicker.POOL.size(), v2.size()])
	for line in v2:
		if line.contains("{player_handle}"):
			failures.append("handle variant still contains token: %s" % line)

	# Device-only template: variants per Glyphs.DEVICES.
	var v3: Array[String] = LineLocalizer.all_variants("Press {jump} to jump.")
	if v3.size() != Glyphs.DEVICES.size():
		failures.append("device-only variants should match DEVICES size (%d), got %d" % [Glyphs.DEVICES.size(), v3.size()])
	var has_kb: bool = false
	var has_pad: bool = false
	for line in v3:
		if line.contains("Space"): has_kb = true
		if line.contains("Cross"): has_pad = true
	if not has_kb:
		failures.append("device-only variants missing keyboard label 'Space': %s" % str(v3))
	if not has_pad:
		failures.append("device-only variants missing gamepad label 'Cross': %s" % str(v3))

	# Cartesian: handle × device. Should be POOL × DEVICES entries.
	var v4: Array[String] = LineLocalizer.all_variants("Hey {player_handle}, hit {jump}.")
	var expected: int = HandlePicker.POOL.size() * Glyphs.DEVICES.size()
	if v4.size() != expected:
		failures.append("cartesian variants should be %d (POOL × DEVICES), got %d" % [expected, v4.size()])
	for line in v4:
		if line.contains("{player_handle}") or line.contains("{jump}"):
			failures.append("cartesian variant still contains a token: %s" % line)

	# has_device_token excludes {player_handle}.
	if LineLocalizer.has_device_token("Hi {player_handle}."):
		failures.append("has_device_token should ignore {player_handle}")
	if not LineLocalizer.has_device_token("Press {jump}."):
		failures.append("has_device_token should detect device tokens")

	if failures.is_empty():
		print("PASS test_line_localizer_variants")
		get_tree().quit(0)
	else:
		for f in failures:
			printerr("FAIL: " + f)
		get_tree().quit(1)
