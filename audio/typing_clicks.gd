class_name TypingClicks
extends RefCounted

## Gated keystroke clicks for typewriter UIs (dialogue scroll, walkie
## subtitles, end-cards). Wraps Audio.play_sfx with three independent
## filters so the click density can be tuned per consumer without each
## site reimplementing the same gating logic.
##
## Filters stack in order: every-N-chars, percent-chance, skip-whitespace.
## Default cue (&"end_card_type") is the 62-sample mechanical-keyboard
## pool; randomized stream pick + volume + pitch live on the cue itself.

static func play(
		letter_index: int,
		letter: String,
		cue: StringName = &"end_card_type",
		every_n_chars: int = 2,
		chance: float = 0.6,
		skip_whitespace: bool = true) -> void:
	if every_n_chars > 1 and (letter_index % every_n_chars) != 0:
		return
	if chance < 1.0 and randf() >= chance:
		return
	if skip_whitespace and (letter == " " or letter == "\n" or letter == "\t" or letter == ""):
		return
	Audio.play_sfx(cue)
