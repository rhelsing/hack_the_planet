extends Node

## Lists mp3 files under res://audio/voice_cache/ that no current dialogue
## source can produce. Orphans accumulate when:
##   - A line is rewritten (old hash now unused)
##   - A character's voice_id changes (every line re-keyed)
##   - A character is removed from voices.tres
##   - A variant is generated for a token combo no longer in any template
##
## Read-only by default. Pass `-- delete` to actually rm the orphans:
##   godot --headless res://tools/find_orphan_voices.tscn --quit-after 60 -- delete
##
## NOTE: lines with plugin-resolved primitives ({{...}}, [if]/[else]/[/if],
## [[a|b]] alternations) cannot be statically enumerated — their concrete
## resolved text is only known at runtime. The tool prints those cache files
## under "RUNTIME (un-checkable)" rather than calling them orphans, so you
## don't accidentally rm something that's actually live but whose template
## we couldn't expand.


const DIALOGUE_DIR: String = "res://dialogue"
const LEVEL_DIRS: Array[String] = ["res://level"]
const _SPEAKER_RE: String = "^([A-Z][A-Za-z_0-9]*): (.+)$"

## Single cache location after the Apr 2026 migration. user://tts_cache/ is
## dead — see autoload/dialogue.gd header.
const CACHE_DIRS: Array[String] = [
	"res://audio/voice_cache/",
]


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	print("\n=== find_orphan_voices ===")

	var voices: Resource = load("res://dialogue/voices.tres")
	if voices == null:
		printerr("Failed to load voices.tres — abort"); get_tree().quit(1); return

	# Collect every (character, template) pair.
	var pairs := _collect_voice_lines()
	print("collected %d (character, template) pairs" % pairs.size())

	# Build the set of expected mp3 filenames from STATICALLY resolvable
	# templates. Plugin-resolved templates ({{...}}, [if]/[[) are tracked
	# separately so we can flag their cache files as "un-checkable" rather
	# than orphans.
	var expected: Dictionary = {}                          # filename → true
	var characters_with_runtime: Dictionary = {}           # character → true
	for entry: Dictionary in pairs:
		var character: String = entry.character
		var template: String = entry.text
		if not voices.has_voice(character):
			continue
		if _is_plugin_resolved(template):
			characters_with_runtime[character] = true
			continue
		var voice_id: String = voices.get_voice_id(character)
		for variant: String in LineLocalizer.all_variants(template):
			var path: String = Dialogue._cache_path_write(character, variant, voice_id)
			expected[path.get_file()] = true

	# List actual files in every cache dir.
	var actual_paths: Array[String] = []
	for dir_uri: String in CACHE_DIRS:
		actual_paths.append_array(_list_mp3s(dir_uri))

	# Bucket them.
	var live: int = 0
	var runtime_unchecked: Array[String] = []
	var orphans: Array[String] = []
	for full_path: String in actual_paths:
		var fname: String = full_path.get_file()
		if expected.has(fname):
			live += 1
			continue
		# Filename format from Dialogue._cache_filename: "<character_lower>_<hash>.mp3".
		# If the character has any runtime-resolved templates, we can't be sure
		# this file is orphaned — be conservative.
		var char_prefix: String = fname.split("_")[0] if "_" in fname else ""
		var matched_runtime: bool = false
		for char_name: String in characters_with_runtime:
			if char_prefix == char_name.to_lower():
				matched_runtime = true; break
		if matched_runtime:
			runtime_unchecked.append(full_path)
		else:
			orphans.append(full_path)

	print("\n— SUMMARY —")
	print("  live (matches a current static template) : %d" % live)
	print("  runtime un-checkable (plugin-resolved)   : %d" % runtime_unchecked.size())
	print("  ORPHAN (no current source produces this) : %d" % orphans.size())

	if not runtime_unchecked.is_empty():
		print("\n— RUNTIME (un-checkable) —")
		print("  These belong to characters whose dialogue contains {{...}},")
		print("  [if]/[else]/[/if], or [[a|b]] templates. Could be live or stale.")
		print("  Don't auto-delete; review manually if you want to shrink cache.")
		for p: String in runtime_unchecked:
			print("    ? %s" % p)

	if not orphans.is_empty():
		print("\n— ORPHANS (safe to delete) —")
		var total_bytes: int = 0
		for p: String in orphans:
			var bytes: int = _file_size(p)
			total_bytes += bytes
			print("    × %s  (%.1f KB)" % [p, bytes / 1024.0])
		print("  total reclaimable: %.1f KB" % (total_bytes / 1024.0))

	# Optional delete pass — only if `delete` was passed after the `--`.
	var args := OS.get_cmdline_user_args()
	if "delete" in args and not orphans.is_empty():
		print("\n— DELETING orphans —")
		for p: String in orphans:
			# Also remove the .import sidecar if it's a res:// resource so
			# Godot doesn't try to re-import a missing file next boot.
			var sidecar: String = p + ".import"
			DirAccess.remove_absolute(p)
			if FileAccess.file_exists(sidecar):
				DirAccess.remove_absolute(sidecar)
			print("    rm %s" % p)
		print("  removed %d files." % orphans.size())

	get_tree().quit(0)


# ── Source walking (mirrors tools/prime_all_dialogue.gd) ────────────────

func _collect_voice_lines() -> Array:
	var out: Array = []
	out.append_array(_walk_dialogue_files(DIALOGUE_DIR))
	for level_dir: String in LEVEL_DIRS:
		out.append_array(_walk_tscn_voice_lines(level_dir))
	return out


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
			out.append({
				"character": m.get_string(1),
				"text": m.get_string(2).strip_edges(),
			})
		f.close()
	return out


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
			if line.begins_with("[node "):
				current_character = ""
				continue
			if line.begins_with("voice_character"):
				var rhs: String = line.get_slice("&\"", 1)
				if rhs.length() > 1:
					current_character = rhs.substr(0, rhs.length() - 1)
				continue
			if line.begins_with("voice_line") and not current_character.is_empty():
				var lhs := line.split("=", true, 1)
				if lhs.size() < 2: continue
				var raw: String = lhs[1].strip_edges()
				if raw.length() >= 2 and raw.begins_with("\"") and raw.ends_with("\""):
					raw = raw.substr(1, raw.length() - 2)
				if raw.is_empty(): continue
				out.append({"character": current_character, "text": raw})
		f.close()
	return out


# ── Helpers ──────────────────────────────────────────────────────────────

func _is_plugin_resolved(text: String) -> bool:
	# Same skip set as prime_all_dialogue.gd's static-only filter.
	return text.contains("{{") or text.contains("[if") \
			or text.contains("[[") or text.contains("[else") \
			or text.contains("[/if")


func _list_files(root: String, suffix: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(root)
	if dir == null: return out
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next(); continue
		var full: String = root.rstrip("/") + "/" + entry
		if dir.current_is_dir():
			out.append_array(_list_files(full, suffix))
		elif entry.ends_with(suffix):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out


func _list_mp3s(dir_uri: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_uri)
	if dir == null: return out
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".mp3"):
			out.append(dir_uri.rstrip("/") + "/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()
	return out


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return 0
	var n: int = f.get_length()
	f.close()
	return n
