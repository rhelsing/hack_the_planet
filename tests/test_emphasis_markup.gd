extends SceneTree

## Verifies the two pipelines that share the **bold** / *italic* convention:
##   - autoload/tts_text.gd::for_eleven_labs    (both → ALL CAPS)
##   - dialogue/scroll_balloon.gd::_format_italics_for_display
##                                              (** → [b], * → [i] BBCode)
## Both must process bold-first so the inner *...* of a **...** pair doesn't
## get partially eaten by the italic regex.
##
## Run: godot --headless --script res://tests/test_emphasis_markup.gd --quit

const TtsText: GDScript = preload("res://autoload/tts_text.gd")
const ScrollBalloon: GDScript = preload("res://dialogue/scroll_balloon.gd")


func _init() -> void:
	var failures: Array[String] = []

	# --- TTS payload (both styles → uppercase) ---------------------------
	_check_tts(failures, "**bold**", "BOLD")
	_check_tts(failures, "*italic*", "ITALIC")
	_check_tts(failures, "Never **been** stuck.", "Never BEEN stuck.")
	_check_tts(failures, "*aside under breath*", "ASIDE UNDER BREATH")
	_check_tts(failures, "**both** and *one*", "BOTH and ONE")
	_check_tts(failures, "no emphasis here", "no emphasis here")
	_check_tts(failures, "", "")
	# Mismatched single asterisk — pass through (no full pair).
	_check_tts(failures, "*unmatched asterisk", "*unmatched asterisk")

	# --- Display BBCode (** → [b], * → [i]) ------------------------------
	_check_display(failures, "**bold**", "[b]bold[/b]")
	_check_display(failures, "*italic*", "[i]italic[/i]")
	_check_display(failures, "Never **been** stuck.", "Never [b]been[/b] stuck.")
	_check_display(failures, "**both** and *one*", "[b]both[/b] and [i]one[/i]")
	_check_display(failures, "no markup", "no markup")
	_check_display(failures, "", "")

	if failures.is_empty():
		print("PASS test_emphasis_markup: TTS + display transforms verified")
		quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_emphasis_markup: " + f)
		quit(1)


func _check_tts(failures: Array[String], input: String, expected: String) -> void:
	var got: String = TtsText.for_eleven_labs(input)
	if got != expected:
		failures.append("for_eleven_labs(%s) = %s, expected %s" % [
			JSON.stringify(input), JSON.stringify(got), JSON.stringify(expected)])


func _check_display(failures: Array[String], input: String, expected: String) -> void:
	var got: String = ScrollBalloon._format_italics_for_display(input)
	if got != expected:
		failures.append("_format_italics_for_display(%s) = %s, expected %s" % [
			JSON.stringify(input), JSON.stringify(got), JSON.stringify(expected)])
