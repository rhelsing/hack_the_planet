extends RefCounted

## Text transformations applied at the ElevenLabs API boundary. Source
## .dialogue files keep author-friendly markup; the payload sent to the
## TTS endpoint gets the spoken-form transformation.
##
## Current rules (both treat the spans the same way — caps for emphasis):
##   **word**  →  WORD     (markdown bold)
##   *word*    →  WORD     (markdown italic)
##
## Bold runs first so `**word**` doesn't get partially eaten by the italic
## regex. Add new rules here as the markup convention expands. Every caller
## that puts text into the {"text": ...} field of an ElevenLabs request
## must run it through `for_eleven_labs(...)` first.


## Per-line model override regex. Lines tagged `[#model=eleven_v3]` (or any
## valid ElevenLabs model id) get baked + cached on that model instead of
## the project default. Used by Walkie + Companion (which receive raw text)
## and by the bake/orphan tools (which scan dialogue files as raw text).
## DialogueManager parses this tag natively for `.dialogue` lines via
## `line.get_tag_value("model")`, so the autoload runtime path doesn't go
## through these helpers — but the bake/orphan paths do.
const MODEL_TAG_RE: String = "\\[#model=([a-zA-Z0-9_]+)\\]"
const MODEL_TAG_STRIP_RE: String = "\\[#model=[a-zA-Z0-9_]+\\]"


## Returns the model id from a `[#model=<id>]` tag in `text`, or `default`
## if no tag is present.
static func parse_model_tag(text: String, default: String) -> String:
	var re: RegEx = RegEx.create_from_string(MODEL_TAG_RE)
	var m: RegExMatch = re.search(text)
	if m == null:
		return default
	return m.get_string(1)


## Removes the `[#model=<id>]` tag from text. Used before passing the text
## to TTS / display so the tag itself doesn't reach ElevenLabs or the user.
static func strip_model_tag(text: String) -> String:
	var re: RegEx = RegEx.create_from_string(MODEL_TAG_STRIP_RE)
	return re.sub(text, "", true).strip_edges()


## Convert dialogue-source text into the form sent to ElevenLabs.
static func for_eleven_labs(text: String) -> String:
	var out: String = text
	# Strip visual BBCode FIRST. By the time dialogue text reaches us, the
	# scroll_balloon has often already converted `**word**` into
	# `[b][color=#XXXXXX]WORD[/color][/b]` (its mutation runs *before* our
	# got_dialogue handler because the plugin emits got_dialogue deferred —
	# scroll_balloon's await returns first, mutates line.text, and only
	# then does the next idle frame fire our handler). So by the time the
	# bold/italic regex below would run, the asterisks are gone.
	#
	# Allow-list only the VISUAL tags (b/i/u/s/color/font/font_size/center/
	# right/outline). Everything else — ElevenLabs v3 audio cues like
	# `[laughs]`, `[pause]`, `[whispering]`, `[chuckles]`, `[#model=...]`,
	# DialogueManager `[#walkie]` and `[if … /]` — is preserved untouched.
	var bbcode: RegEx = RegEx.new()
	bbcode.compile("\\[/?(b|i|u|s|color|font|font_size|center|right|outline)(=[^\\]]*)?\\]")
	out = bbcode.sub(out, "", true)
	# Bold first — `\*\*([^*]+)\*\*`. The `[^*]+` capture excludes asterisks
	# so we don't span across multiple emphasis pairs.
	var bold: RegEx = RegEx.new()
	bold.compile("\\*\\*([^*]+)\\*\\*")
	for m: RegExMatch in bold.search_all(out):
		out = out.replace(m.get_string(0), m.get_string(1).to_upper())
	# Italic — runs on the post-bold string, so any remaining `*x*` pairs
	# are unambiguously single-asterisk emphasis.
	var italic: RegEx = RegEx.new()
	italic.compile("\\*([^*]+)\\*")
	for m: RegExMatch in italic.search_all(out):
		out = out.replace(m.get_string(0), m.get_string(1).to_upper())
	# Ellipsis → "hmm". ElevenLabs reads "..." literally as "dot dot dot"
	# (and Unicode U+2026 "…" as a meaningless beat); the bracketed
	# `[sigh]` form gets read literally on flash_v2_5 as the word "sigh"
	# rather than performing a sigh (audio cues are v3-only). Plain "hmm"
	# is the safe fallback that flash speaks naturally as a beat. Display
	# path keeps "..." / "…" intact (subtitles render them as printed);
	# only the TTS payload swaps them.
	out = out.replace("…", " hmm ")
	out = out.replace("...", " hmm ")
	# Gamepad face-button glyphs → spoken words. HUD + subtitles render the
	# Unicode shapes (set in autoload/glyphs.gd); ElevenLabs would read them
	# as silence or codepoint-name, so reverse them back to "Cross" /
	# "Circle" / "Square" / "Triangle" right before the synth payload.
	out = out.replace("✕", "Cross")
	out = out.replace("○", "Circle")
	out = out.replace("□", "Square")
	out = out.replace("△", "Triangle")
	return out
