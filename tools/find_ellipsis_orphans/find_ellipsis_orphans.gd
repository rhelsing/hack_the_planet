extends SceneTree

## Identifies cached TTS .mp3s that were rendered when `for_eleven_labs` was
## still doing the unconditional `... → " hmm "` swap mid-sentence. Those
## files now contain "hmm" baked in where the line author intended an
## ellipsis pause. Cache filenames hash off the PRE-transform text (see
## Dialogue._cache_filename), so the new fixed rule cannot trigger a
## natural cache miss — we have to delete the stale mp3s by hand.
##
## Walks the same corpus prime_all_dialogue.gd does:
##   - dialogue/*.dialogue (Speaker: text lines)
##   - level/**/*.tscn (WalkieTrigger / FlagWalkie line + RespawnMessageZone voice_line)
##   - cutscenes/*.tres (LineStep payloads, recursive into ParallelStep / SubsequenceStep)
##
## For each line:
##   - Skip if no ellipsis present (..  ...  …)
##   - Skip if line is a STANDALONE ellipsis (strip_edges() ∈ {"...", "..", "…"}) —
##     those keep the hmm conversion under the new rule, audio is still correct.
##   - Otherwise: this is a mid-sentence ellipsis line, mp3 audio is wrong.
##     Compute cache filename + check disk; collect into report.
##
## Two modes:
##   --dry-run (default): print the table, NO file changes.
##   --delete: print table AND delete each found .mp3 + .mp3.import sibling.
##
## Run:
##   godot --headless --script res://tools/find_ellipsis_orphans/find_ellipsis_orphans.gd --quit
##   godot --headless --script res://tools/find_ellipsis_orphans/find_ellipsis_orphans.gd --quit -- --delete

const ELEVEN_MODEL_ID: String = "eleven_flash_v2_5"
const TtsText: GDScript = preload("res://autoload/tts_text.gd")
const DIALOGUE_DIR: String = "res://dialogue"
const LEVEL_DIRS: Array[String] = ["res://level"]
const CUTSCENE_DIR: String = "res://cutscenes"
const SHIPPED_CACHE_DIR: String = "res://audio/voice_cache/"

## Speaker-line regex for .dialogue files. Matches "Character: spoken text".
const _SPEAKER_RE: String = "^([A-Z][A-Za-z_0-9]*): (.+)$"

var _delete_mode: bool = false


func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--delete":
			_delete_mode = true
	_run()


func _run() -> void:
	print("\n=== find_ellipsis_orphans (mode=%s) ===" % ("DELETE" if _delete_mode else "DRY-RUN"))
	var voices: Resource = load("res://dialogue/voices.tres")
	if voices == null:
		printerr("voices.tres failed to load — abort")
		quit(1); return

	var lines: Array = []
	lines.append_array(_walk_dialogue_files(DIALOGUE_DIR))
	for d: String in LEVEL_DIRS:
		lines.append_array(_walk_tscn_voice_lines(d))
	lines.append_array(_walk_cutscene_timelines(CUTSCENE_DIR))
	print("collected %d candidate (character, text) pairs" % lines.size())

	# Filter to mid-sentence ellipsis ONLY.
	var hits: Array = []
	for entry: Dictionary in lines:
		var text: String = entry.get("text", "")
		if text.is_empty():
			continue
		if not _has_ellipsis(text):
			continue
		if _is_standalone_ellipsis(text):
			continue
		hits.append(entry)
	print("filtered to %d mid-sentence ellipsis lines\n" % hits.size())

	# For each, compute cache filename and check disk.
	var found: Array = []
	var missing: int = 0
	for entry: Dictionary in hits:
		var character: String = entry.character
		var text: String = entry.text
		var model_id: String = entry.get("model", ELEVEN_MODEL_ID)
		if not voices.call("has_voice", character):
			continue
		var voice_id: String = voices.call("get_voice_id", character)
		var fname: String = _compute_filename(character, text, voice_id, model_id)
		var path: String = SHIPPED_CACHE_DIR + fname
		var preview: String = text.substr(0, 80).replace("\n", " ")
		if FileAccess.file_exists(path):
			found.append({
				"character": character,
				"text": text,
				"preview": preview,
				"fname": fname,
				"path": path,
				"source": entry.get("source", "<unknown>"),
				"model_id": model_id,
			})
		else:
			missing += 1

	# Print table.
	print("=" .repeat(120))
	print("MID-SENTENCE ELLIPSIS LINES WITH CACHED MP3 (count: %d)" % found.size())
	print("=" .repeat(120))
	print("%-9s | %-37s | %-40s | %s" % ["char", "filename", "source", "preview"])
	print("-" .repeat(120))
	for h: Dictionary in found:
		var char_short: String = String(h.character).substr(0, 9)
		var src_short: String = String(h.source).substr(0, 40)
		print("%-9s | %-37s | %-40s | %s" % [char_short, h.fname, src_short, h.preview])
	print("-" .repeat(120))
	print("matched mp3s on disk:    %d" % found.size())
	print("not-yet-cached lines:    %d" % missing)
	print("total mid-ellipsis lines: %d" % hits.size())

	# Delete if requested.
	if _delete_mode and not found.is_empty():
		print("\n=== DELETING ===")
		var deleted: int = 0
		var failed: int = 0
		for h: Dictionary in found:
			var ok: bool = _delete_one(h.path)
			if ok:
				deleted += 1
				print("  [DEL] %s" % h.path)
			else:
				failed += 1
				print("  [ERR] %s" % h.path)
		print("\ndeleted: %d  failed: %d" % [deleted, failed])

	quit(0)


# ── Filtering ────────────────────────────────────────────────────────────

func _has_ellipsis(text: String) -> bool:
	return text.contains("...") or text.contains("..") or text.contains("…")


func _is_standalone_ellipsis(text: String) -> bool:
	var s: String = text.strip_edges()
	return s == "..." or s == ".." or s == "…"


# ── Hashing ──────────────────────────────────────────────────────────────

func _compute_filename(character: String, text: String, voice_id: String, model_id: String) -> String:
	var hash_input: String
	if model_id == ELEVEN_MODEL_ID:
		hash_input = "%s__%s__%s" % [character, text, voice_id]
	else:
		hash_input = "%s__%s__%s__%s" % [character, text, voice_id, model_id]
	var hashed: String = hash_input.md5_text().left(15)
	var safe_char: String = character.to_lower().replace(" ", "_")
	return "%s_%s.mp3" % [safe_char, hashed]


# ── Deletion ─────────────────────────────────────────────────────────────

func _delete_one(res_path: String) -> bool:
	var abs_mp3: String = ProjectSettings.globalize_path(res_path)
	var abs_import: String = abs_mp3 + ".import"
	# DirAccess.remove_absolute can return OK without actually removing the
	# file when Godot's resource cache holds an open reference (observed for
	# cutscene-sourced mp3s after `load(.tres)`). Belt-and-suspenders:
	# attempt both, then verify with FileAccess.file_exists; on survival,
	# shell-fallback to `rm`.
	DirAccess.remove_absolute(abs_mp3)
	if FileAccess.file_exists(res_path + ".import"):
		DirAccess.remove_absolute(abs_import)
	if FileAccess.file_exists(res_path):
		OS.execute("rm", ["-f", abs_mp3])
	if FileAccess.file_exists(res_path + ".import"):
		OS.execute("rm", ["-f", abs_import])
	return not FileAccess.file_exists(res_path) and not FileAccess.file_exists(res_path + ".import")


# ── Walkers ──────────────────────────────────────────────────────────────

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
			# Per-line model override via [#model=<id>] tag — strip from text
			# AND surface as the model_id so the cache key matches.
			var model_id: String = TtsText.parse_model_tag(text, ELEVEN_MODEL_ID)
			text = TtsText.strip_model_tag(text)
			# Token expansion: {player_handle} → 4 cache files.
			for variant: String in _expand_handle(text):
				out.append({
					"character": character,
					"text": variant,
					"model": model_id,
					"source": path.replace("res://", ""),
				})
		f.close()
	return out


func _walk_tscn_voice_lines(root: String) -> Array:
	var out: Array = []
	var paths: Array[String] = _list_files(root, ".tscn")
	for path: String in paths:
		out.append_array(_scan_tscn(path))
	return out


func _scan_tscn(path: String) -> Array:
	var out: Array = []
	var walkie_ext_ids: Dictionary = {}
	var f1 := FileAccess.open(path, FileAccess.READ)
	if f1 == null:
		return out
	while not f1.eof_reached():
		var ln: String = f1.get_line()
		if not ln.begins_with("[ext_resource"):
			continue
		if not (ln.contains("walkie_trigger") or ln.contains("flag_walkie")):
			continue
		var id_marker := " id=\""
		var id_start := ln.find(id_marker)
		if id_start < 0:
			continue
		id_start += id_marker.length()
		var id_end := ln.find("\"", id_start)
		if id_end > id_start:
			walkie_ext_ids[ln.substr(id_start, id_end - id_start)] = true
	f1.close()

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var voice_character: String = ""
	var walkie_character: String = ""
	var node_is_walkie: bool = false
	while not f.eof_reached():
		var ln2: String = f.get_line()
		if ln2.begins_with("[node "):
			# Reset per-node state. Walkie nodes default character to DialTone.
			voice_character = ""
			walkie_character = "DialTone"
			node_is_walkie = false
			for ext_id: String in walkie_ext_ids:
				if ln2.contains('instance=ExtResource("' + ext_id + '")'):
					node_is_walkie = true
					break
			continue
		# Style 1: RespawnMessageZone — voice_character + voice_line.
		if ln2.begins_with("voice_character = &\""):
			voice_character = ln2.substr(20).rstrip("\"\n").strip_edges()
			continue
		if ln2.begins_with("voice_line = \""):
			var raw: String = ln2.substr(14).rstrip("\"\n").strip_edges()
			if raw.ends_with("\""):
				raw = raw.substr(0, raw.length() - 1)
			if not voice_character.is_empty() and not raw.is_empty():
				var model_id: String = TtsText.parse_model_tag(raw, ELEVEN_MODEL_ID)
				var clean: String = TtsText.strip_model_tag(raw)
				for v: String in _expand_handle(clean):
					out.append({
						"character": voice_character,
						"text": v,
						"model": model_id,
						"source": path.replace("res://", ""),
					})
			continue
		# Style 2: WalkieTrigger / FlagWalkie — character + line.
		# Prefix `character = &"` is 14 chars (c-h-a-r-a-c-t-e-r-SP-=-SP-&-").
		if node_is_walkie and ln2.begins_with("character = &\""):
			walkie_character = ln2.substr(14).rstrip("\"\n").strip_edges()
			if walkie_character.ends_with("\""):
				walkie_character = walkie_character.substr(0, walkie_character.length() - 1)
			continue
		if node_is_walkie and ln2.begins_with("line = \""):
			var raw2: String = ln2.substr(8).rstrip("\n").strip_edges()
			# Strip trailing quote.
			if raw2.ends_with("\""):
				raw2 = raw2.substr(0, raw2.length() - 1)
			# Unescape `\"` inside the body so the hash payload matches the
			# string as the runtime sees it.
			raw2 = raw2.replace("\\\"", "\"")
			if not raw2.is_empty():
				var model_id2: String = TtsText.parse_model_tag(raw2, ELEVEN_MODEL_ID)
				var clean2: String = TtsText.strip_model_tag(raw2)
				for v2: String in _expand_handle(clean2):
					out.append({
						"character": walkie_character,
						"text": v2,
						"model": model_id2,
						"source": path.replace("res://", ""),
					})
	f.close()
	return out


func _walk_cutscene_timelines(root: String) -> Array:
	var out: Array = []
	var paths: Array[String] = _list_files(root, ".tres")
	for path: String in paths:
		var res: Resource = load(path)
		if res == null or not "steps" in res:
			continue
		var steps: Array = res.steps
		_collect_line_steps(steps, out, path)
	return out


func _collect_line_steps(steps: Array, out: Array, source: String) -> void:
	for step in steps:
		if step == null:
			continue
		# LineStep duck-typed: has `character` and `text` properties.
		if "character" in step and "text" in step:
			var character: String = String(step.character)
			var text: String = String(step.text)
			if not character.is_empty() and not text.is_empty():
				var model_id: String = TtsText.parse_model_tag(text, ELEVEN_MODEL_ID)
				var clean: String = TtsText.strip_model_tag(text)
				for v: String in _expand_handle(clean):
					out.append({
						"character": character,
						"text": v,
						"model": model_id,
						"source": source.replace("res://", ""),
					})
		# Recurse into nested timelines.
		if "steps" in step and step.steps is Array:
			_collect_line_steps(step.steps, out, source)
		if "timeline" in step and step.timeline != null and "steps" in step.timeline:
			_collect_line_steps(step.timeline.steps, out, source)


# ── Helpers ──────────────────────────────────────────────────────────────

const _HANDLES: Array[String] = ["Pixel", "Neon", "Cipher", "Byte"]

func _expand_handle(text: String) -> Array:
	if not "{player_handle}" in text:
		return [text]
	var out: Array = []
	for h: String in _HANDLES:
		out.append(text.replace("{player_handle}", h))
	return out


func _list_files(root: String, ext: String) -> Array[String]:
	var out: Array[String] = []
	var stack: Array[String] = [root]
	while not stack.is_empty():
		var d: String = stack.pop_back()
		var dir := DirAccess.open(d)
		if dir == null:
			continue
		dir.list_dir_begin()
		while true:
			var name: String = dir.get_next()
			if name == "":
				break
			if name.begins_with("."):
				continue
			var p: String = d.path_join(name)
			if dir.current_is_dir():
				stack.append(p)
			elif p.ends_with(ext):
				out.append(p)
		dir.list_dir_end()
	return out
