class_name LineLocalizer
extends RefCounted

## Token resolver for voice line templates. Pure function, no side effects.
##
## v1 supports {player_handle} only. Future tokens ({jump}, {dash}, ...) for
## device-variant resolution plug into the same resolver — see
## docs/dynamic_dialogue_engine.md (layer 3).
##
## NOTE: distinct from DialogueManager's mustache substitution. DM uses {{ }}
## inside .dialogue files at line-render time. We use { } inside voice line
## strings (Companion.speak / Walkie.speak / RespawnMessageZone.voice_line)
## at synth-cache-key time. No collision; different syntax.

const _HANDLE_TOKEN: String = "{player_handle}"


## Substitute every token with the currently-active value (chosen handle, etc.).
## Templates with no tokens pass through unchanged.
static func resolve(template: String) -> String:
	if not has_handle_token(template):
		return template
	return template.replace(_HANDLE_TOKEN, HandlePicker.chosen_name())


## All handle-variant resolutions of `template`. Returns the cartesian product
## of {player_handle} expansion. Used by VoicePrimer to determine sibling cache
## entries to synth in the background.
##
## A template without tokens returns [template] — single variant.
static func handle_variants(template: String) -> Array[String]:
	var out: Array[String] = []
	if not has_handle_token(template):
		out.append(template)
		return out
	for handle: String in HandlePicker.POOL:
		out.append(template.replace(_HANDLE_TOKEN, handle))
	return out


static func has_handle_token(template: String) -> bool:
	return template.contains(_HANDLE_TOKEN)
