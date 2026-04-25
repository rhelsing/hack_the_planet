extends Node

## Batch-prime every voice line that the game might ever speak. Walks the
## .dialogue files under dialogue/, scans level scenes for inline voice_line
## hints, expands each (character, template) into its 1–8 LineLocalizer
## variants (handle × device cartesian), and POSTs each missing variant to
## ElevenLabs. Already-cached variants skip.
##
## Run with:
##   godot --headless res://tools/prime_all_dialogue.tscn --quit-after 1800
##
## Sequential, polite (≥0.4s between requests) — fine to leave running while
## you do other work. Writes mp3s to res://audio/voice_cache/ so they ship
## with the build and exported runs hit zero API calls.
##
## Variant bounds (worst case): 4 player_handle slots × 2 device profiles =
## 8 synths per template. Most templates have neither token = 1 synth each.

const ELEVEN_API_URL: String = "https://api.elevenlabs.io/v1/text-to-speech/%s"
const ELEVEN_MODEL_ID: String = "eleven_flash_v2_5"
const REQUEST_GAP_SEC: float = 0.4
const DIALOGUE_DIR: String = "res://dialogue"
const LEVEL_DIRS: Array[String] = ["res://level"]

## Speaker-line regex for .dialogue files. Matches "Character: spoken text".
## Skips lines starting with `do`, `if`, `=>`, `~`, `-` (response options),
## `#` (comments). Character name is one capitalized word + word chars.
const _SPEAKER_RE: String = "^([A-Z][A-Za-z_0-9]*): (.+)$"

var _http: HTTPRequest
var _queue: Array = []          # [{character, text, voice_id, path}]
var _in_flight: Dictionary = {} # path -> true
var _done: int = 0
var _skipped: int = 0
var _total_queued: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_http_completed)
	add_child(_http)
	_collect_and_queue.call_deferred()


func _collect_and_queue() -> void:
	print("\n=== prime_all_dialogue ===")
	if Dialogue._api_key == null or Dialogue._api_key.is_empty():
		printerr("No ElevenLabs API key configured — abort")
		get_tree().quit(1); return

	var voices: Resource = load("res://dialogue/voices.tres")
	if voices == null:
		printerr("Failed to load voices.tres — abort")
		get_tree().quit(1); return

	var lines := _collect_voice_lines()
	print("collected %d (character, template) pairs" % lines.size())

	# Expand variants and enqueue any that aren't already cached.
	for entry: Dictionary in lines:
		var character: String = entry.character
		var template: String = entry.text
		if not voices.has_voice(character):
			continue
		var voice_id: String = voices.get_voice_id(character)
		for variant: String in LineLocalizer.all_variants(template):
			var path: String = Dialogue._cache_path_write(character, variant, voice_id)
			if FileAccess.file_exists(path):
				_skipped += 1
				continue
			# Also check the shipped cache in case write_path is dev:// in
			# exported builds — Dialogue._cache_path_read does both tiers.
			var read_path: String = Dialogue._cache_path_read(character, variant, voice_id)
			if not read_path.is_empty():
				_skipped += 1
				continue
			_queue.append({
				"character": character,
				"text": variant,
				"voice_id": voice_id,
				"path": path,
			})
			_total_queued += 1

	print("queued %d new synths, %d already cached" % [_total_queued, _skipped])
	_drain_next()


# ── Source-walking ──────────────────────────────────────────────────────

func _collect_voice_lines() -> Array:
	var out: Array = []
	out.append_array(_walk_dialogue_files(DIALOGUE_DIR))
	for level_dir: String in LEVEL_DIRS:
		out.append_array(_walk_tscn_voice_lines(level_dir))
	return out


## Reads every .dialogue under `root` and pulls "Character: text" lines.
## Skips response options (`- ...`), commands (`do/if/=>/~/#`), and the
## EXIT_TEXT response sentinel.
func _walk_dialogue_files(root: String) -> Array:
	var out: Array = []
	var paths: Array[String] = _list_files(root, ".dialogue")
	var re := RegEx.new()
	re.compile(_SPEAKER_RE)
	for path: String in paths:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		while not f.eof_reached():
			var line: String = f.get_line().strip_edges()
			var m := re.search(line)
			if m == null:
				continue
			var character: String = m.get_string(1)
			var text: String = m.get_string(2).strip_edges()
			# Skip lines whose final text is plugin-resolved at runtime —
			# we can't enumerate without simulating Nathan Hoad's dialogue
			# manager. Cache fills lazily on first play instead.
			#   {{...}}  — mustache: function calls (HandlePicker, GameState)
			#   [if ...] — inline conditionals
			#   [[a|b]]  — random-pick alternations
			if text.contains("{{") or text.contains("[if") \
					or text.contains("[[") or text.contains("[else") \
					or text.contains("[/if"):
				continue
			out.append({"character": character, "text": text})
		f.close()
	return out


## Walks tscn files for `voice_character = &"X"` paired with `voice_line = "..."`
## within the same node block. Used by RespawnMessageZone hints in level scenes.
func _walk_tscn_voice_lines(root: String) -> Array:
	var out: Array = []
	var paths: Array[String] = _list_files(root, ".tscn")
	for path: String in paths:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var current_character: String = ""
		while not f.eof_reached():
			var line: String = f.get_line()
			# Reset character on every node boundary; voice_character lives
			# inside a single node block.
			if line.begins_with("[node "):
				current_character = ""
				continue
			# voice_character = &"X"
			if line.begins_with("voice_character"):
				var rhs: String = line.get_slice("&\"", 1)
				if rhs.length() > 1:
					current_character = rhs.substr(0, rhs.length() - 1)
				continue
			# voice_line = "..."
			if line.begins_with("voice_line") and not current_character.is_empty():
				var lhs := line.split("=", true, 1)
				if lhs.size() < 2:
					continue
				var raw: String = lhs[1].strip_edges()
				# Strip surrounding quotes.
				if raw.length() >= 2 and raw.begins_with("\"") and raw.ends_with("\""):
					raw = raw.substr(1, raw.length() - 2)
				# Skip empty.
				if raw.is_empty():
					continue
				out.append({"character": current_character, "text": raw})
		f.close()
	return out


func _list_files(root: String, suffix: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full: String = root.rstrip("/") + "/" + entry
		if dir.current_is_dir():
			out.append_array(_list_files(full, suffix))
		elif entry.ends_with(suffix):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out


# ── Synth queue drain ───────────────────────────────────────────────────

func _drain_next() -> void:
	if _queue.is_empty():
		print("\n=== DONE: %d synthesized, %d skipped (cached) ===" % [_done, _skipped])
		get_tree().quit(0)
		return
	var next: Dictionary = _queue.pop_front()
	_in_flight[next.path] = true
	var url: String = ELEVEN_API_URL % next.voice_id
	var headers: PackedStringArray = [
		"xi-api-key: " + Dialogue._api_key,
		"Content-Type: application/json",
		"Accept: audio/mpeg",
	]
	var body: Dictionary = {
		"text": next.text,
		"model_id": ELEVEN_MODEL_ID,
	}
	var json: String = JSON.stringify(body)
	print("[%d/%d] synth: %s | \"%s\"" % [
		_done + 1, _done + 1 + _queue.size(),
		next.character, next.text.substr(0, 60),
	])
	_http.set_meta("current", next)
	var err := _http.request(url, headers, HTTPClient.METHOD_POST, json)
	if err != OK:
		printerr("  HTTPRequest.request err=%d — skipping" % err)
		_in_flight.erase(next.path)
		_done += 1
		_drain_next()


func _on_http_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var current: Dictionary = _http.get_meta("current", {})
	_in_flight.erase(current.get("path", ""))
	if response_code != 200 or body.size() == 0:
		printerr("  FAIL code=%d  body=%s" % [response_code, body.get_string_from_utf8().substr(0, 200)])
	else:
		var path: String = current.path
		# Make sure the dir exists (res://audio/voice_cache/ should already, but
		# be defensive in case someone runs this before Godot's scanned the dir).
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			printerr("  FAIL FileAccess.open(WRITE) — %s" % path)
		else:
			f.store_buffer(body)
			f.close()
			print("  → %d bytes  %s" % [body.size(), path.get_file()])
	_done += 1
	# Polite gap before the next request.
	get_tree().create_timer(REQUEST_GAP_SEC).timeout.connect(_drain_next)
