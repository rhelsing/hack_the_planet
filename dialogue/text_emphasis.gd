class_name TextEmphasis
extends RefCounted

## On-screen rendering for the project's two emphasis markers. Used by the
## dialogue scroll balloon AND the walkie/companion subtitle so the
## conventions stay identical across both UIs.
##
##   **word**  →  [b][color=<speaker>]WORD[/color][/b]
##                bold + the speaker's registered VoicePortraits color +
##                UPPERCASE. Color falls back to plain [b]WORD[/b] when
##                no color is provided.
##   *word*    →  [i]word[/i]
##                italic only — case preserved. Used for narration / scene
##                direction.
##
## Bold runs first so a `**word**` doesn't get partially eaten by the
## italic regex on the inner pair.
##
## TTS side: autoload/tts_text.gd::for_eleven_labs uppercases the same
## spans for ElevenLabs synth so the spoken emphasis matches the visual
## WYSIWYG. Both sides drop the literal `*` characters.


## Strip ElevenLabs v3 audio cues (`[laughs]`, `[pause]`, `[whispering]`,
## `[chuckles]`, `[sighs]`, `[laughs softly]`, etc.) from text destined for
## a visible label. The TTS path keeps them — v3 reads them as voice cues —
## so they only need removal at the display boundary.
##
## Regex matches `[X]` where X starts with a letter and contains
## alphanumeric + space + underscore + dash. Excludes things with `=`, `#`,
## `/`, `(`, etc., so DialogueManager tags (`[#walkie]`, `[#model=…]`,
## `[if … /]`) and BBCode close tags (`[/color]`) are NOT matched here. The
## visual BBCode tags `[b]`, `[i]`, `[u]` ARE matched, but `format_for_display`
## adds those AFTER this strip — so callers that strip then format are safe.
static func strip_audio_tags(text: String) -> String:
	var re_tag: RegEx = RegEx.create_from_string("\\[[a-zA-Z][a-zA-Z0-9 _-]*\\]")
	var out: String = re_tag.sub(text, "", true)
	# Collapse whitespace runs left by stripped tags ("a [pause] b" → "a  b" → "a b").
	var re_space: RegEx = RegEx.create_from_string("\\s+")
	out = re_space.sub(out, " ", true)
	return out.strip_edges()


static func format_for_display(raw: String, color_hex: String = "") -> String:
	# Strip audio cues BEFORE adding visual BBCode — otherwise the [b]/[i]
	# we add here would get nuked by the strip's regex.
	var out: String = strip_audio_tags(raw)
	var bold: RegEx = RegEx.new()
	bold.compile("\\*\\*([^*]+)\\*\\*")
	for m: RegExMatch in bold.search_all(out):
		var inner_upper: String = m.get_string(1).to_upper()
		var replacement: String
		if color_hex.is_empty():
			replacement = "[b]%s[/b]" % inner_upper
		else:
			replacement = "[b][color=%s]%s[/color][/b]" % [color_hex, inner_upper]
		out = out.replace(m.get_string(0), replacement)
	var italic: RegEx = RegEx.new()
	italic.compile("\\*([^*]+)\\*")
	out = italic.sub(out, "[i]$1[/i]", true)
	return out


## Convert a Color (from VoicePortraits.get_color()) to a #RRGGBB hex
## string suitable for BBCode `[color=...]`. Alpha is dropped — BBCode
## color tags don't support alpha and the speaker tint is opaque anyway.
static func color_to_hex(c: Color) -> String:
	return "#%02X%02X%02X" % [int(c.r * 255), int(c.g * 255), int(c.b * 255)]
