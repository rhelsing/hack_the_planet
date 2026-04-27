extends Node

## ⚠️  DEPRECATED — use tools/prime_all_dialogue.gd instead.
##
## prime_all_dialogue is a strict superset:
##   - Walks .dialogue files (this script's only source)
##   - PLUS scans level .tscn files for inline voice_line / line exports
##   - PLUS scans Companion.speak / Walkie.speak code calls
##   - Writes directly to res://audio/voice_cache/ (this script writes to
##     user://tts_cache/ which is now dead — Apr 2026 migration)
##
## Kept here only so existing CI / docs that reference it don't 404.
## Functionality unchanged; the deprecation is purely "use the bigger tool."
##
## ---- original docstring below ----
##
## Pre-renders every spoken line in res://dialogue/*.dialogue through
## ElevenLabs into the dev TTS cache, including all variants (handle ×
## device cartesian). Run before a release to populate audio/voice_cache/
## without playing through every name × controller combo by hand.
##
## Run:
##   /Applications/Godot.app/Contents/MacOS/Godot --headless \
##       res://tools/prerender_voices.tscn
##
## On completion, mp3s land in:
##   ~/Library/Application Support/Godot/app_userdata/Hack The Planet/tts_cache/
## Move the new ones into res://audio/voice_cache/ and commit to ship them.
##
## Limitations:
## - Only .dialogue files. Code-side Companion.speak / Walkie.speak strings
##   are not auto-extracted; play through them once each to fill those.
## - Sequential one HTTPRequest at a time (VoicePrimer's existing rate). A
##   full first run can take 10–20 minutes; reruns skip already-cached lines.
##
## Mustache → token translation:
## Author convention in .dialogue files is mustache — {{HandlePicker.chosen_name()}}
## and {{Glyphs.for_action("jump")}}. Those resolve at line-render time to one
## value, so runtime VoicePrimer can't see them. This script reads the source
## text directly and rewrites those mustache calls into LineLocalizer tokens
## ({player_handle} / {jump} / etc.) before variant expansion, so the cartesian
## still gets cached.

const DIALOGUE_DIR: String = "res://dialogue/"
const POLL_INTERVAL_S: float = 2.0

# Identifiers that match the "Speaker:" pattern but are dialogue-system
# bindings, not characters. Skip these so we don't try to TTS-synth game
# logic.
const _RESERVED_SPEAKERS: PackedStringArray = [
	"GameState", "HandlePicker", "Events", "LevelProgression",
	"DialogueManager", "Audio", "Walkie", "Companion", "Glyphs",
]

var _start_pending: int = 0


func _ready() -> void:
	if Dialogue._api_key.is_empty():
		printerr("[prerender] no ElevenLabs API key configured — aborting.")
		printerr("[prerender] expected key in res://dialogue/tts_config.tres or env var.")
		get_tree().quit(1)
		return

	var pairs: Array = _scan_dialogue_files()
	print("[prerender] parsed %d speaker-line pairs from %s" % [pairs.size(), DIALOGUE_DIR])

	var enqueued: int = 0
	for p: Dictionary in pairs:
		for variant: String in LineLocalizer.all_variants(p.text):
			if VoicePrimer.enqueue_text(p.character, variant):
				enqueued += 1

	_start_pending = VoicePrimer.pending_count()
	print("[prerender] %d new variants enqueued for synth (others already cached)" % enqueued)
	if _start_pending == 0:
		print("[prerender] nothing to do — all variants already on disk.")
		get_tree().quit(0)
		return

	_poll_loop()


func _poll_loop() -> void:
	while true:
		await get_tree().create_timer(POLL_INTERVAL_S).timeout
		var remaining: int = VoicePrimer.pending_count()
		var done: int = _start_pending - remaining
		print("[prerender] %d/%d done" % [done, _start_pending])
		if remaining == 0:
			print("[prerender] complete — mp3s in dev TTS cache.")
			print("[prerender] move new files from tts_cache/ to res://audio/voice_cache/ to ship.")
			get_tree().quit(0)
			return


# ── Parsing ─────────────────────────────────────────────────────────────

func _scan_dialogue_files() -> Array:
	var out: Array = []
	var dir: DirAccess = DirAccess.open(DIALOGUE_DIR)
	if dir == null:
		printerr("[prerender] couldn't open %s" % DIALOGUE_DIR)
		return out
	dir.list_dir_begin()
	while true:
		var name: String = dir.get_next()
		if name == "":
			break
		if not name.ends_with(".dialogue"):
			continue
		var pairs: Array = _parse_dialogue_file(DIALOGUE_DIR + name)
		print("[prerender]   %s → %d lines" % [name, pairs.size()])
		out.append_array(pairs)
	dir.list_dir_end()
	return out


# Match "Speaker: text" lines, excluding option lines (start with `-`),
# section headers (`~`), mutations (`do`), conditionals (`if`/`elif`/`else`),
# and dialogue-engine bindings.
func _parse_dialogue_file(path: String) -> Array:
	var pairs: Array = []
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		printerr("[prerender] could not read %s" % path)
		return pairs
	var re: RegEx = RegEx.create_from_string("^\\s*([A-Z][A-Za-z0-9_]*):\\s*(.+)$")
	while not f.eof_reached():
		var line: String = f.get_line()
		var trimmed: String = line.strip_edges()
		if trimmed.is_empty(): continue
		if trimmed.begins_with("#") or trimmed.begins_with("~"): continue
		if trimmed.begins_with("- ") or trimmed.begins_with("-"): continue
		if trimmed.begins_with("do ") or trimmed.begins_with("if ") \
		   or trimmed.begins_with("elif ") or trimmed.begins_with("else") \
		   or trimmed.begins_with("=>"):
			continue
		var m: RegExMatch = re.search(line)
		if m == null:
			continue
		var speaker: String = m.get_string(1)
		if _RESERVED_SPEAKERS.has(speaker):
			continue
		var text: String = m.get_string(2).strip_edges()
		text = _mustache_to_tokens(text)
		pairs.append({"character": speaker, "text": text})
	return pairs


# Rewrite the mustache forms authors use in .dialogue files into LineLocalizer
# token forms so all_variants() can expand them. Mustache calls collapse to
# one value at runtime; reading the source lets us recover the variability.
#   {{HandlePicker.chosen_name()}}    →  {player_handle}
#   {{Glyphs.for_action("jump")}}     →  {jump}
# Other mustache calls (option(0), reaction(), etc.) are intentionally left
# alone — they're not variant-cacheable templates.
static func _mustache_to_tokens(text: String) -> String:
	var out := text
	out = out.replace("{{HandlePicker.chosen_name()}}", "{player_handle}")
	# Glyphs.for_action accepts any quoted action name. Match flexibly so
	# Glyphs.for_action("jump"), .for_action( "jump" ), .for_action('jump')
	# all rewrite cleanly.
	var re := RegEx.create_from_string("\\{\\{\\s*Glyphs\\.for_action\\(\\s*[\"']([A-Za-z_][A-Za-z0-9_]*)[\"']\\s*\\)\\s*\\}\\}")
	for m: RegExMatch in re.search_all(text):
		out = out.replace(m.get_string(0), "{" + m.get_string(1) + "}")
	return out
