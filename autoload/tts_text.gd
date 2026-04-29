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


## Convert dialogue-source text into the form sent to ElevenLabs.
static func for_eleven_labs(text: String) -> String:
	var out: String = text
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
	return out
