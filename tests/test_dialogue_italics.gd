extends Node

## Unit test for P3 italics handling:
##   - Dialogue._strip_italic_spans removes `*...*` spans for TTS
##   - ScrollBalloon._format_italics_for_display converts `*...*` to BBCode [i]
##
## Run with:
##   godot --headless res://tests/test_dialogue_italics.tscn


const DialogueScript = preload("res://autoload/dialogue.gd")
const ScrollBalloonScript = preload("res://dialogue/scroll_balloon.gd")


func _segment(text: String, character: String) -> Array:
	return DialogueScript._segment_line(text, character)


func _ready() -> void:
	var failures: Array[String] = []

	# ---- _strip_italic_spans (TTS side) ----
	var strip_cases: Array = [
		["Troll: Hello.", "Troll: Hello."],
		["Hello *world* goodbye", "Hello  goodbye"],  # span removed, leaves spaces
		["*only italic*", ""],                          # whole line removed
		["*one* then *two*", "then"],                   # multiple spans
		["no asterisks here", "no asterisks here"],
	]
	for c: Array in strip_cases:
		var input: String = c[0]
		var expected: String = c[1]
		var got: String = DialogueScript._strip_italic_spans(input)
		var norm_got := got.replace("  ", " ").strip_edges()
		var norm_exp := expected.replace("  ", " ").strip_edges()
		if norm_got != norm_exp:
			failures.append("_strip_italic_spans(%r): expected %r, got %r" % [input, norm_exp, norm_got])

	# ---- _format_italics_for_display (balloon side) ----
	var format_cases: Array = [
		["Hello world", "Hello world"],
		["Hello *world*", "Hello [i]world[/i]"],
		["*one* *two*", "[i]one[/i] [i]two[/i]"],
		["Some *italic span* mid-sentence.", "Some [i]italic span[/i] mid-sentence."],
	]
	for c: Array in format_cases:
		var input: String = c[0]
		var expected: String = c[1]
		var got: String = ScrollBalloonScript._format_italics_for_display(input)
		if got != expected:
			failures.append("_format_italics_for_display(%r): expected %r, got %r" % [input, expected, got])

	# ---- Round-trip invariant: display-formatted text has no bare asterisks,
	# TTS-stripped text has no asterisks either ----
	var raw: String = "Troll: Listen. *He leans in.* Don't trust her."
	var display := ScrollBalloonScript._format_italics_for_display(raw)
	var tts := DialogueScript._strip_italic_spans(raw)
	if display.count("*") > 0:
		failures.append("display output still contains bare asterisks: %r" % display)
	if tts.count("*") > 0:
		failures.append("TTS output still contains bare asterisks: %r" % tts)
	if not display.contains("[i]He leans in.[/i]"):
		failures.append("display output missing expected [i]...[/i] span: %r" % display)
	if tts.contains("He leans in"):
		failures.append("TTS output should have dropped the italic content: %r" % tts)

	# ---- P4.5 segmentation: character/narrator chunks ----
	# "*A* B" → [Narrator A] [Grit B]
	var segs_a: Array = _segment("*A* B", "Grit")
	if segs_a.size() != 2 \
			or segs_a[0].speaker != "Narrator" or segs_a[0].text != "A" \
			or segs_a[1].speaker != "Grit" or segs_a[1].text != "B":
		failures.append("segment '*A* B' wrong: %s" % str(segs_a))

	# "*He shifts, the tiniest crack in his stance.* Damn, kid. Didn't even flinch."
	# should split into Narrator + Grit — the real failure case the user reported.
	var segs_real: Array = _segment(
		"*He shifts, the tiniest crack in his stance.* Damn, kid. Didn't even flinch.", "Grit"
	)
	if segs_real.size() != 2:
		failures.append("real-case line expected 2 segments, got %d: %s" % [segs_real.size(), str(segs_real)])
	elif segs_real[0].speaker != "Narrator":
		failures.append("real-case: first segment should be Narrator, got %s" % segs_real[0].speaker)
	elif segs_real[1].speaker != "Grit":
		failures.append("real-case: second segment should be Grit, got %s" % segs_real[1].speaker)
	elif segs_real[0].text.contains("*") or segs_real[1].text.contains("*"):
		failures.append("real-case: segments still contain asterisks — not stripped")

	# "pre *mid* post" → 3 segments alternating
	var segs_mid: Array = _segment("pre *mid* post", "Grit")
	if segs_mid.size() != 3 \
			or segs_mid[0].speaker != "Grit" or segs_mid[0].text != "pre" \
			or segs_mid[1].speaker != "Narrator" or segs_mid[1].text != "mid" \
			or segs_mid[2].speaker != "Grit" or segs_mid[2].text != "post":
		failures.append("segment 'pre *mid* post' wrong: %s" % str(segs_mid))

	# No asterisks → single character segment
	var segs_none: Array = _segment("just regular dialogue", "Grit")
	if segs_none.size() != 1 or segs_none[0].speaker != "Grit":
		failures.append("no-italic case should yield 1 Grit segment, got %s" % str(segs_none))

	if failures.is_empty():
		print("PASS test_dialogue_italics: strip + format + segmentation (character/narrator) all correct")
		get_tree().quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_dialogue_italics: " + f)
		get_tree().quit(1)
