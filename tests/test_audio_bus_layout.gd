extends Node

## Smoke test for the 5-bus audio layout + sidechain compressors.
## Verifies default_bus_layout.tres actually registers the buses we expect
## and that the ducking compressors point at the Dialogue bus.
##
## Run with:
##   godot --headless res://tests/test_audio_bus_layout.tscn


const EXPECTED_BUSES: Array[StringName] = [&"Master", &"Music", &"SFX", &"Dialogue", &"Ambience", &"UI"]


func _ready() -> void:
	var failures: Array[String] = []

	# ---- All 6 buses present ----
	for bus_name in EXPECTED_BUSES:
		var idx := AudioServer.get_bus_index(bus_name)
		if idx < 0:
			failures.append("bus '%s' not found in AudioServer" % bus_name)

	# ---- Sidechain compressor on Music + Ambience referencing Dialogue ----
	# We don't assert exact compressor parameters — designers will tune those.
	# We do assert structural correctness: a compressor exists with sidechain="Dialogue".
	_check_sidechain(failures, &"Music")
	_check_sidechain(failures, &"Ambience")

	# ---- SFX and Dialogue buses should NOT be self-ducking ----
	if _bus_has_dialogue_sidechain(&"SFX"):
		failures.append("SFX bus should not have a Dialogue sidechain (diegetic sounds shouldn't duck)")
	if _bus_has_dialogue_sidechain(&"Dialogue"):
		failures.append("Dialogue bus should not have a Dialogue sidechain (would self-duck)")

	# ---- Audio autoload loaded its cue registry ----
	if Audio == null:
		failures.append("Audio autoload missing")
	elif Audio._registry == null:
		failures.append("Audio autoload failed to load cue registry")

	# ---- Missing-cue path push_errors (not silent) ----
	# We can't directly assert push_error was called, but we verify the
	# public API accepts a known-bad id without crashing.
	if Audio != null:
		Audio.play_sfx(&"nonexistent_cue_id_for_test")  # expect loud warn, not crash

	if failures.is_empty():
		print("PASS test_audio_bus_layout: all 6 buses present, sidechain compressors route to Dialogue, cue registry loaded")
		get_tree().quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_audio_bus_layout: " + f)
		get_tree().quit(1)


func _check_sidechain(failures: Array[String], bus_name: StringName) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		failures.append("%s bus missing — can't check sidechain" % bus_name)
		return
	var count := AudioServer.get_bus_effect_count(idx)
	var found := false
	for i in range(count):
		var fx := AudioServer.get_bus_effect(idx, i)
		if fx is AudioEffectCompressor and (fx as AudioEffectCompressor).sidechain == &"Dialogue":
			found = true
			break
	if not found:
		failures.append("%s bus has no AudioEffectCompressor with sidechain='Dialogue'" % bus_name)


func _bus_has_dialogue_sidechain(bus_name: StringName) -> bool:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0: return false
	var count := AudioServer.get_bus_effect_count(idx)
	for i in range(count):
		var fx := AudioServer.get_bus_effect(idx, i)
		if fx is AudioEffectCompressor and (fx as AudioEffectCompressor).sidechain == &"Dialogue":
			return true
	return false
