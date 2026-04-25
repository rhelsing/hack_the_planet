class_name LineLocalizer
extends RefCounted

## Token resolver for voice line templates. Pure function, no side effects.
##
## Tokens:
##   {player_handle} — substituted with HandlePicker.chosen_name(); siblings
##                     enumerate every name in HandlePicker.POOL.
##   {jump} / {dash} / {interact} / ... — delegated to the Glyphs autoload
##                     for device-specific labels. Siblings enumerate every
##                     entry in Glyphs.DEVICES (keyboard, gamepad).
##
## Templates with no tokens pass through unchanged — call sites can pipe every
## voice line through resolve() unconditionally.
##
## NOTE: distinct from DialogueManager's mustache substitution. DM uses {{ }}
## inside .dialogue files at line-render time. We use { } inside voice line
## strings (Companion.speak / Walkie.speak / RespawnMessageZone.voice_line)
## at synth-cache-key time. No collision; different syntax.

const _HANDLE_TOKEN: String = "{player_handle}"


## Substitute every token with the currently-active value. Templates with no
## tokens pass through unchanged.
static func resolve(template: String) -> String:
	var out := template
	if has_handle_token(out):
		out = out.replace(_HANDLE_TOKEN, HandlePicker.chosen_name())
	if has_device_token(out):
		out = Glyphs.format(out)
	return out


## All variants of `template` — cartesian of handle × device expansion.
## Used by VoicePrimer to enumerate sibling cache entries to synth in the
## background. A token-less template returns [template].
static func all_variants(template: String) -> Array[String]:
	var out: Array[String] = []
	for h: String in handle_variants(template):
		for d: String in device_variants(h):
			out.append(d)
	return out


## All handle-variant resolutions of `template`. A template without the
## handle token returns [template] — single variant.
static func handle_variants(template: String) -> Array[String]:
	var out: Array[String] = []
	if not has_handle_token(template):
		out.append(template)
		return out
	for handle: String in HandlePicker.POOL:
		out.append(template.replace(_HANDLE_TOKEN, handle))
	return out


## All device-variant resolutions of `template` — one per Glyphs.DEVICES key.
## A template without device tokens returns [template].
static func device_variants(template: String) -> Array[String]:
	var out: Array[String] = []
	if not has_device_token(template):
		out.append(template)
		return out
	for device: String in Glyphs.DEVICES:
		out.append(Glyphs.format_for(template, device))
	return out


static func has_handle_token(template: String) -> bool:
	return template.contains(_HANDLE_TOKEN)


## Delegates to Glyphs so the set of recognized device tokens is owned in
## one place (autoload/glyphs.gd's _GLYPHS dict).
static func has_device_token(template: String) -> bool:
	return Glyphs.has_token(template)
