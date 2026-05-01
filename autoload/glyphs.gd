extends Node

## Maps action names to device-specific glyphs so tutorial hints, dialogue,
## and HUD prompts can swap "Space" for "✕" (DualSense Cross) when the
## player is on a controller.
##
## Two consumption styles:
##   1. `Glyphs.for_action("jump")` → returns the glyph for the active
##      device. Use this in dialogue interpolation:
##        Glitch: Hit {{Glyphs.for_action("jump")}} to leap.
##   2. `Glyphs.format("Press {jump} to leap!")` → substitutes every
##      `{action_name}` placeholder. Use this for hint-zone messages,
##      tooltips, anything pre-authored as a single string.
##
## The active device is read from the player's brain (`last_device` exposed
## by PlayerBrain). If no player is in the scene, defaults to "keyboard"
## glyphs — the safe assumption for a desktop launch with no input yet.

## Gamepad face buttons render as Unicode glyphs (○ △ □ ✕) for HUD and
## subtitle display. The TTS payload boundary (tts_text.gd:for_eleven_labs)
## reverse-maps these back to spoken words ("Circle" / "Triangle" /
## "Square" / "Cross") because ElevenLabs reads the unicode codepoints as
## silence or codepoint-name. Shoulder buttons (L1/L2/R1/R2/L3) and Options
## stay as text — they have no natural Unicode equivalent and read fine in
## both contexts as-is.
const _GLYPHS: Dictionary = {
	"jump":          {"keyboard": "Space",      "gamepad": "✕"},
	"dash":          {"keyboard": "Q",          "gamepad": "○"},
	"attack":        {"keyboard": "T",          "gamepad": "□"},
	"interact":      {"keyboard": "E",          "gamepad": "△"},
	"crouch":        {"keyboard": "Ctrl",       "gamepad": "L3"},
	"sneak_toggle":  {"keyboard": "Shift",      "gamepad": "L3"},
	"pause":         {"keyboard": "Esc",        "gamepad": "Options"},
	"grapple_fire":  {"keyboard": "G",          "gamepad": "L2"},
	"flare_shoot":   {"keyboard": "Y",          "gamepad": "R2"},
	"music_prev":    {"keyboard": "-",          "gamepad": "L1"},
	"music_next":    {"keyboard": "=",          "gamepad": "R1"},
	"move":          {"keyboard": "WASD",       "gamepad": "left stick"},
	"look":          {"keyboard": "the mouse",  "gamepad": "right stick"},
}


## Returns the glyph for `action_name` based on the active player's most
## recent input device. Falls back to "?" if the action is unknown.
func for_action(action_name: String) -> String:
	var entry: Dictionary = _GLYPHS.get(action_name, {})
	if entry.is_empty():
		return "?"
	return entry.get(_active_device(), entry.get("keyboard", "?"))


## Substitute every `{action_name}` placeholder in `template` with the
## device-appropriate glyph. Unknown placeholders are left as-is so authoring
## typos stay visible instead of silently disappearing.
func format(template: String) -> String:
	var result := template
	for action_name: String in _GLYPHS:
		var placeholder: String = "{" + action_name + "}"
		if placeholder in result:
			result = result.replace(placeholder, for_action(action_name))
	return result


## All device keys used in the glyph table. Used by VoicePrimer to enumerate
## sibling variants for background TTS caching (one mp3 per device).
const DEVICES: Array = ["keyboard", "gamepad"]


## Substitute placeholders for an explicit device key (not the active player's).
## VoicePrimer needs this to pre-synth every device's variant regardless of who
## is currently playing.
func format_for(template: String, device: String) -> String:
	var result := template
	for action_name: String in _GLYPHS:
		var placeholder: String = "{" + action_name + "}"
		if placeholder in result:
			var entry: Dictionary = _GLYPHS[action_name]
			var label: String = entry.get(device, entry.get("keyboard", "?"))
			result = result.replace(placeholder, label)
	return result


## True iff `template` contains any known glyph placeholder. Lets variant-
## expansion code skip templates that don't need device-specific caching.
func has_token(template: String) -> bool:
	for action_name: String in _GLYPHS:
		if ("{" + action_name + "}") in template:
			return true
	return false


# ── Internals ────────────────────────────────────────────────────────────

func _active_device() -> String:
	var tree := get_tree()
	if tree == null:
		return "keyboard"
	# PlayerBody is in the "player" group; the brain (PlayerBrain) is its
	# child and exposes `last_device` per the contract noted in player_brain.gd.
	for player: Node in tree.get_nodes_in_group("player"):
		for child: Node in player.get_children():
			if "last_device" in child:
				return child.last_device
	return "keyboard"
