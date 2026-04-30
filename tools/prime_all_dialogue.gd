extends Node

## Batch-prime every voice line that the game might ever speak. Walks the
## .dialogue files under dialogue/, scans level scenes for inline voice_line
## hints, expands each (character, template) into its 1–8 LineLocalizer
## variants (handle × device cartesian), and POSTs each missing variant to
## ElevenLabs. Already-cached variants skip.
##
## Run with:
##   godot --headless res://tools/prime_all_dialogue.tscn --quit-after 432000
##
## --quit-after is FRAMES, not seconds — default 60fps means 60 frames per
## wallclock second. Use a number large enough to cover the worst-case
## backlog (4 handles × 2 devices × ~344 templates × 2.4s = ~55 min ≈
## 200_000 frames at 60fps). The script calls get_tree().quit(0) when the
## queue drains, so the flag is just a safety cap.
##
## Sequential, polite (≥0.4s between requests) — fine to leave running while
## you do other work. Writes mp3s to res://audio/voice_cache/ so they ship
## with the build and exported runs hit zero API calls.
##
## Variant bounds (worst case): 4 player_handle slots × 2 device profiles =
## 8 synths per template. Most templates have neither token = 1 synth each.

const ELEVEN_API_URL: String = "https://api.elevenlabs.io/v1/text-to-speech/%s"
const ELEVEN_MODEL_ID: String = "eleven_flash_v2_5"
const TtsText: GDScript = preload("res://autoload/tts_text.gd")
const REQUEST_GAP_SEC: float = 0.4
const DIALOGUE_DIR: String = "res://dialogue"
const LEVEL_DIRS: Array[String] = ["res://level"]
const CUTSCENE_DIR: String = "res://cutscenes"

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
		# Per-line model override: pull `[#model=v3]` from the template, strip
		# from the text used for hashing + synthesis. Default = project's
		# ELEVEN_MODEL_ID. See README §"Per-line model overrides".
		var line_model: String = TtsText.parse_model_tag(template, ELEVEN_MODEL_ID)
		var clean_template: String = TtsText.strip_model_tag(template)
		for variant: String in LineLocalizer.all_variants(clean_template):
			var path: String = Dialogue._cache_path_write(character, variant, voice_id, line_model)
			if FileAccess.file_exists(path):
				_skipped += 1
				continue
			# Also check the shipped cache in case write_path is dev:// in
			# exported builds — Dialogue._cache_path_read does both tiers.
			var read_path: String = Dialogue._cache_path_read(character, variant, voice_id, line_model)
			if not read_path.is_empty():
				_skipped += 1
				continue
			_queue.append({
				"character": character,
				"text": variant,
				"voice_id": voice_id,
				"path": path,
				"model_id": line_model,
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
	out.append_array(_walk_cutscene_timelines(CUTSCENE_DIR))
	return out


## Walks .tres files under `root`, loads each as a CutsceneTimeline, iterates
## steps, and pulls (character, text) from every LineStep — including ones
## nested inside ParallelStep / SubsequenceStep. Cutscene authoring uses the
## new engine (cutscene_engine/); the bake script picks them up here so
## LineStep texts get pre-cached TTS the same way .dialogue speaker lines do.
func _walk_cutscene_timelines(root: String) -> Array:
	var out: Array = []
	var paths: Array[String] = _list_files(root, ".tres")
	for path: String in paths:
		var resource: Resource = ResourceLoader.load(path)
		if resource == null or not (resource is CutsceneTimeline):
			continue
		var timeline: CutsceneTimeline = resource
		_collect_line_steps(timeline.steps, out)
	return out


## Recursive — walks ParallelStep.steps and SubsequenceStep.cutscene.steps so
## nested LineSteps don't get missed.
func _collect_line_steps(steps: Array, out: Array) -> void:
	for step: CutsceneStep in steps:
		if step == null:
			continue
		if step is LineStep:
			var ls: LineStep = step
			var character: String = String(ls.character)
			var text: String = ls.text
			if character.is_empty() or text.is_empty():
				continue
			for variant: String in DialogueExpander.expand(text):
				out.append({"character": character, "text": variant})
		elif step is ParallelStep:
			var ps: ParallelStep = step
			_collect_line_steps(ps.steps, out)
		elif step is SubsequenceStep:
			var ss: SubsequenceStep = step
			if ss.timeline != null:
				_collect_line_steps(ss.timeline.steps, out)


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
			# Plugin-resolved primitives — mustache calls, [if]/[else]/[/if],
			# [[a|b]] alternations — get expanded into their full set of
			# concrete variants by DialogueExpander. Lines whose only mustache
			# call is unknown return [] from expand() and get dropped (lazy
			# fill at runtime via VoicePrimer).
			for variant: String in DialogueExpander.expand(text):
				out.append({"character": character, "text": variant})
		f.close()
	return out


## Walks tscn files for two voice-line styles inside a node block:
##   1. voice_character = &"X" + voice_line = "..." (RespawnMessageZone)
##   2. line = "..." (+ optional character = &"X", default "DialTone") on
##      WalkieTrigger instances. Walkie nodes are detected by matching the
##      `instance=ExtResource("X")` id against ext_resources whose path
##      contains "walkie_trigger".
func _walk_tscn_voice_lines(root: String) -> Array:
	var out: Array = []
	var paths: Array[String] = _list_files(root, ".tscn")
	for path: String in paths:
		out.append_array(_scan_tscn(path))
	return out


func _scan_tscn(path: String) -> Array:
	var out: Array = []
	var walkie_ext_ids: Dictionary = {}
	# Pass 1: ext_resource ids that point to walkie_trigger.tscn.
	var f1 := FileAccess.open(path, FileAccess.READ)
	if f1 == null:
		return out
	while not f1.eof_reached():
		var ln: String = f1.get_line()
		if not ln.begins_with("[ext_resource"):
			continue
		if not ln.contains("walkie_trigger"):
			continue
		# NOTE: leading space distinguishes `id="..."` from `uid="..."` —
		# tscn ext_resource lines have both, with `uid="..."` listed first.
		var id_marker := " id=\""
		var id_start := ln.find(id_marker)
		if id_start < 0:
			continue
		id_start += id_marker.length()
		var id_end := ln.find("\"", id_start)
		if id_end > id_start:
			walkie_ext_ids[ln.substr(id_start, id_end - id_start)] = true
	f1.close()
	# Pass 2: walk nodes, capture both styles.
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var voice_character: String = ""
	var walkie_character: String = ""
	var node_is_walkie: bool = false
	while not f.eof_reached():
		var line: String = f.get_line()
		# Node boundary: reset all per-node state, detect walkie via the
		# instance=ExtResource("X") attribute on the [node ...] header.
		if line.begins_with("[node "):
			voice_character = ""
			walkie_character = "DialTone"
			node_is_walkie = false
			var inst_marker := "instance=ExtResource(\""
			var inst_idx := line.find(inst_marker)
			if inst_idx >= 0:
				var id_start := inst_idx + inst_marker.length()
				var id_end := line.find("\"", id_start)
				if id_end > id_start:
					var ext_id: String = line.substr(id_start, id_end - id_start)
					node_is_walkie = walkie_ext_ids.has(ext_id)
			continue
		# RespawnMessageZone-style: voice_character + voice_line.
		if line.begins_with("voice_character"):
			var rhs: String = line.get_slice("&\"", 1)
			if rhs.length() > 1:
				voice_character = rhs.substr(0, rhs.length() - 1)
			continue
		if line.begins_with("voice_line") and not voice_character.is_empty():
			var raw: String = _parse_quoted_rhs(line)
			if not raw.is_empty():
				out.append({"character": voice_character, "text": raw})
			continue
		# WalkieTrigger-style: only inside walkie node blocks.
		if not node_is_walkie:
			continue
		if line.begins_with("character "):
			var wrhs: String = line.get_slice("&\"", 1)
			if wrhs.length() > 1:
				walkie_character = wrhs.substr(0, wrhs.length() - 1)
			continue
		if line.begins_with("line "):
			var raw: String = _parse_quoted_rhs(line)
			if not raw.is_empty():
				out.append({"character": walkie_character, "text": raw})
	f.close()
	return out


## Parse `key = "value"` → "value". Returns "" if RHS isn't a quoted string.
func _parse_quoted_rhs(tscn_line: String) -> String:
	var lhs := tscn_line.split("=", true, 1)
	if lhs.size() < 2:
		return ""
	var raw: String = lhs[1].strip_edges()
	if raw.length() < 2 or not raw.begins_with("\"") or not raw.ends_with("\""):
		return ""
	return raw.substr(1, raw.length() - 2)


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
	var line_model: String = next.get("model_id", ELEVEN_MODEL_ID)
	var body: Dictionary = {
		"text": TtsText.for_eleven_labs(next.text),
		"model_id": line_model,
	}
	var json: String = JSON.stringify(body)
	var model_suffix: String = (" [model=%s]" % line_model) if line_model != ELEVEN_MODEL_ID else ""
	print("[%d/%d] synth: %s%s | \"%s\"" % [
		_done + 1, _done + 1 + _queue.size(),
		next.character, model_suffix, next.text.substr(0, 60),
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
