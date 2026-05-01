extends Node

## Read-only cache-hash identifier + COPY-to-review-folder. For every line
## flagged for re-bake (audio-cue lines + tier1 #40 list), computes the
## expected voice_cache filename(s) using the same hash logic as
## Dialogue._cache_filename, finds existing mp3s, and COPIES them to
## res://audio/voice_cache/_review_for_rebake/ for manual listening.
##
## NO source files modified. NO mp3s deleted or moved. Pure copy + report.
##
## Token expansion: lines containing {player_handle} get 4 cache hits
## (Pixel/Neon/Cipher/Byte from HandlePicker.POOL). All 4 mp3s are copied.
##
## Run:
##   /Applications/Godot.app/Contents/MacOS/Godot --headless \
##       res://tools/identify_cache_hashes/identify_cache_hashes.tscn

const ELEVEN_MODEL_ID: String = "eleven_flash_v2_5"
const ELEVEN_V3_ID: String = "eleven_v3"
const SHIPPED_CACHE_DIR: String = "res://audio/voice_cache/"
const REVIEW_DIR: String = "res://audio/voice_cache/_review_for_rebake/"

# Handles for {player_handle} token expansion. Mirror of HandlePicker.POOL.
const HANDLES: Array = ["Pixel", "Neon", "Cipher", "Byte"]

# ─────────────────────────────────────────────────────────────────────────
# Batch 1: audio-cue lines. The 6 lines containing v3-style cues that
# need to be re-baked once cues are stripped. Format:
#   [tag, character, text, model_id]
# Lines tagged [#model=eleven_v3] use the v3 cache key, which has model
# suffixed in the hash.
# ─────────────────────────────────────────────────────────────────────────
const CUE_LINES: Array = [
	["cue_01_splice_pause",
		"Splice",
		"They built the \"hackers for the people\" thing because it's easier to share when you have nothing. I had **nothing**. [pause] Now I have **something**.",
		ELEVEN_MODEL_ID],
	["cue_02_splice_laughs_softly",
		"Splice",
		"There it is. [laughs softly] Knew you'd see it.",
		ELEVEN_MODEL_ID],
	["cue_03_splice_sighs_v3",
		"Splice",
		"...wow. [sighs] Wow okay.",
		ELEVEN_V3_ID],
	["cue_04_splice_chuckles",
		"Splice",
		"[chuckles] You're not walking out of here, runner.",
		ELEVEN_MODEL_ID],
	["cue_05_splice_whispering",
		"Splice",
		"[whispering] I'll find you again. I will **find you**, runner.",
		ELEVEN_MODEL_ID],
	["cue_06_walkie19_nyx_laughs",
		"Nyx",
		"[laughs] You didn't teach him a thing. [sigh] Good luck, {player_handle}.",
		ELEVEN_V3_ID],
]

# ─────────────────────────────────────────────────────────────────────────
# Batch 2: tier1 #40 fragments. Substring-match against the corpus.
# Speakers are inferred from where each fragment lives.
# ─────────────────────────────────────────────────────────────────────────
## Tier1 #40 fragments — substrings that DO match the actual source text.
## User's tier1 list captured these from listening, so wording was off
## (e.g. "Bite your signal as stabilized" was really "your signal has
## stabilized"). Each entry below is a fragment unique enough to locate
## the source line via substring match. Three from the original 15 still
## could NOT be located in the corpus and are noted as missing.
const TIER1_FRAGMENTS: Array = [
	"She tell you? Never stuck",                            # 1 — DialTone, dial_tone.dialogue
	"your signal has stabilized again",                     # 2 — walkie in level_3.tscn
	"My tracking code seems to be paying off",              # 3 — walkie in level_3.tscn
	"Look at you go! That's so awesome",                    # 4 — walkie in level_3.tscn
	"I left because I figured it out",                      # 5 — Splice, level_3_splice_offer.dialogue
	"sheeple",                                              # 6 — Splice, level_3_splice_offer.dialogue
	"power-ups in your pocket",                             # 7 — Splice, level_3_splice_offer.dialogue
	"deleting the part of the wire",                        # 8 — Splice, level_3_splice_offer.dialogue
	"No no no",                                             # 9 — Splice, level_3_splice_offer.dialogue
	"can't do that again",                                  # 10 — Nyx, dial_tone.dialogue
	# 11 — "The…" — NOT FOUND in corpus (too short to match uniquely)
	# 12 — "We know where the last disk is" — NOT FOUND in corpus
	"better than I expected",                               # 13 — Splice walkie in level_4.tscn
	# 14 — "we split, stay synced on the channel" — NOT FOUND in corpus
	"rules are **rigged** because they were",               # 15 — Nyx, dial_tone.dialogue
]

var _copied_count: int = 0
var _missing_count: int = 0
var _not_found_fragments: Array = []


func _ready() -> void:
	# Make review dir (idempotent).
	var abs_dir: String = ProjectSettings.globalize_path(REVIEW_DIR)
	DirAccess.make_dir_recursive_absolute(abs_dir)
	print("=" .repeat(80))
	print("CACHE HASH REVIEW — copying matched mp3s to %s" % REVIEW_DIR)
	print("=" .repeat(80))
	print("")
	_process_cue_lines()
	print("")
	_process_tier1_fragments()
	print("")
	print("=" .repeat(80))
	print("SUMMARY")
	print("  copied: %d mp3s into %s" % [_copied_count, REVIEW_DIR])
	print("  missing (no cache file): %d lines" % _missing_count)
	if not _not_found_fragments.is_empty():
		print("  fragments NOT located in corpus: %d" % _not_found_fragments.size())
		for frag: String in _not_found_fragments:
			print("    - \"%s\"" % frag)
	print("=" .repeat(80))
	get_tree().quit(0)


func _process_cue_lines() -> void:
	print("--- BATCH 1: AUDIO-CUE LINES (%d source lines) ---" % CUE_LINES.size())
	for entry in CUE_LINES:
		var tag: String = entry[0]
		var character: String = entry[1]
		var text_template: String = entry[2]
		var model: String = entry[3]
		_emit_with_token_expansion(tag, character, text_template, model)


func _process_tier1_fragments() -> void:
	print("--- BATCH 2: TIER1 #40 FRAGMENTS (%d fragments) ---" % TIER1_FRAGMENTS.size())
	var idx: int = 0
	for frag: String in TIER1_FRAGMENTS:
		idx += 1
		var hits: Array = _grep_corpus(frag)
		if hits.is_empty():
			_not_found_fragments.append(frag)
			print("  [%02d] NOT FOUND: \"%s\"" % [idx, frag])
			continue
		var hit_idx: int = 0
		for hit: Dictionary in hits:
			hit_idx += 1
			var tag: String = "tier1_%02d_%s_%d" % [idx, hit.character.to_lower(), hit_idx]
			_emit_with_token_expansion(tag, hit.character, hit.text, hit.get("model", ELEVEN_MODEL_ID))


# Expand {player_handle} (and any future tokens) into all variants, then
# emit one cache lookup per variant.
func _emit_with_token_expansion(tag: String, character: String, text_template: String, model: String) -> void:
	var variants: Array = _expand_handle_token(text_template)
	for v: Dictionary in variants:
		_emit_one(tag + (("_" + v.suffix) if v.suffix else ""), character, v.text, model)


func _expand_handle_token(template: String) -> Array:
	if not "{player_handle}" in template:
		return [{"text": template, "suffix": ""}]
	var out: Array = []
	for h: String in HANDLES:
		out.append({"text": template.replace("{player_handle}", h), "suffix": h.to_lower()})
	return out


func _emit_one(tag: String, character: String, text: String, model: String) -> void:
	var voices: Resource = Dialogue._voices
	var voice_id: String = ""
	if voices != null and voices.has_method(&"has_voice") and voices.has_voice(character):
		voice_id = voices.get_voice_id(character)
	var fname: String = _compute_filename(character, text, voice_id, model)
	var src_path: String = SHIPPED_CACHE_DIR + fname
	var preview: String = text.substr(0, 60).replace("\n", " ")
	if not FileAccess.file_exists(src_path):
		print("  [MISS] %s | %s | %s" % [tag, fname, preview])
		_missing_count += 1
		return
	# Copy to review folder with a readable prefix so user can ID in Finder.
	var dest_path: String = REVIEW_DIR + tag + "__" + fname
	var ok: int = DirAccess.copy_absolute(
		ProjectSettings.globalize_path(src_path),
		ProjectSettings.globalize_path(dest_path))
	if ok == OK:
		print("  [COPY] %s → %s | %s" % [tag, fname, preview])
		_copied_count += 1
	else:
		print("  [ERR ] %s | copy failed (err=%d)" % [tag, ok])


func _compute_filename(character: String, text: String, voice_id: String, model_id: String) -> String:
	var hash_input: String
	if model_id == ELEVEN_MODEL_ID:
		hash_input = "%s__%s__%s" % [character, text, voice_id]
	else:
		hash_input = "%s__%s__%s__%s" % [character, text, voice_id, model_id]
	var hashed: String = hash_input.md5_text().left(15)
	var safe_char: String = character.to_lower().replace(" ", "_")
	return "%s_%s.mp3" % [safe_char, hashed]


# Search the dialogue/cutscene/level corpus for a fragment substring.
# Returns array of {character, text, model} for each matching line.
# Not exhaustive but covers the common patterns:
#   - .dialogue: "Speaker: text [#tags]"
#   - .tres LineStep: character = &"X" + text = "..."
#   - .tscn FlagWalkie/WalkieTrigger: character = &"X" + line = "..."
func _grep_corpus(fragment: String) -> Array:
	var results: Array = []
	# Pass 1: .dialogue files
	for path: String in _list_files("res://dialogue/", ".dialogue"):
		var content: String = _read_file(path)
		for raw_line: String in content.split("\n"):
			if not (fragment in raw_line):
				continue
			var parsed: Dictionary = _parse_dialogue_line(raw_line)
			if parsed.is_empty():
				continue
			results.append(parsed)
	# Pass 2: .tres / .tscn — block-scan
	for path: String in _list_files_rec("res://", ".tres") + _list_files_rec("res://", ".tscn"):
		# Skip the .import sidecars and library dirs.
		if "/.godot/" in path or path.ends_with(".import"):
			continue
		var content: String = _read_file(path)
		if not (fragment in content):
			continue
		# Block-scan: split on [node ...] / [sub_resource ...] markers.
		var blocks: Array = _split_blocks(content)
		for block: String in blocks:
			if not (fragment in block):
				continue
			var character: String = _extract_field(block, "character", true)
			var text: String = _extract_field(block, "text", false)
			if text.is_empty():
				text = _extract_field(block, "line", false)
			# walkie_trigger.gd / flag_walkie.gd default to DialTone when no
			# character override is set in-scene. Reflect that here so we
			# can hash unset-character walkies correctly.
			if character.is_empty():
				character = "DialTone"
			if text.is_empty():
				continue
			results.append({"character": character, "text": text, "model": ELEVEN_MODEL_ID})
	return results


func _parse_dialogue_line(raw: String) -> Dictionary:
	var line: String = raw.strip_edges()
	if line.is_empty(): return {}
	if line.begins_with("~") or line.begins_with("do ") or line.begins_with("=>"):
		return {}
	var colon_idx: int = line.find(":")
	if colon_idx <= 0: return {}
	var prefix: String = line.substr(0, colon_idx).strip_edges()
	# Speaker should look like "Word" — alphanumeric.
	if not prefix.match("[A-Za-z][A-Za-z0-9_]*"):
		# Try light validation: just letters
		var ok := true
		for c in prefix:
			if not c.is_valid_identifier() and c not in [".", " "]:
				ok = false
				break
		if not ok: return {}
	var rest: String = line.substr(colon_idx + 1).strip_edges()
	# Strip trailing line-tags like [#walkie] / [#model=...]
	var tag_strip: RegEx = RegEx.create_from_string("\\s*\\[#[^\\]]+\\][\\s]*$")
	rest = tag_strip.sub(rest, "", true).strip_edges()
	# Parse model from tag if present; default flash.
	var model_re: RegEx = RegEx.create_from_string("\\[#model=([a-zA-Z0-9_]+)\\]")
	var model_match: RegExMatch = model_re.search(raw)
	var model: String = model_match.get_string(1) if model_match != null else ELEVEN_MODEL_ID
	return {"character": prefix, "text": rest, "model": model}


# Crude block splitter — splits the file at every line beginning with `[`.
# Each "block" is the text between two such markers (the node/subresource
# definition + its property lines). Good enough for finding character +
# line/text pairs within a single node.
func _split_blocks(content: String) -> Array:
	var blocks: Array = []
	var current: String = ""
	for line: String in content.split("\n"):
		if line.begins_with("["):
			if not current.is_empty():
				blocks.append(current)
			current = line + "\n"
		else:
			current += line + "\n"
	if not current.is_empty():
		blocks.append(current)
	return blocks


# Extract a field's value from a block. `field = &"value"` (StringName) or
# `field = "value"` (string). Returns "" if not found.
func _extract_field(block: String, field: String, is_stringname: bool) -> String:
	for line: String in block.split("\n"):
		var stripped: String = line.strip_edges()
		if not stripped.begins_with(field + " ="):
			continue
		var eq_idx: int = stripped.find("=")
		var rhs: String = stripped.substr(eq_idx + 1).strip_edges()
		if is_stringname:
			# &"Foo"
			if rhs.begins_with("&\"") and rhs.ends_with("\""):
				return rhs.substr(2, rhs.length() - 3)
		else:
			# "Foo bar"
			if rhs.begins_with("\"") and rhs.ends_with("\""):
				return rhs.substr(1, rhs.length() - 2).c_unescape()
		return rhs
	return ""


func _list_files(dir: String, ext: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir)
	if d == null: return out
	d.list_dir_begin()
	while true:
		var f: String = d.get_next()
		if f.is_empty(): break
		if d.current_is_dir(): continue
		if f.ends_with(ext):
			out.append(dir + f)
	d.list_dir_end()
	return out


func _list_files_rec(root: String, ext: String) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		var d := DirAccess.open(dir)
		if d == null: continue
		d.list_dir_begin()
		while true:
			var f: String = d.get_next()
			if f.is_empty(): break
			# Skip hidden (.godot, etc.) and addons we don't author.
			if f.begins_with("."):
				continue
			var path: String = dir + f if dir.ends_with("/") else dir + "/" + f
			if d.current_is_dir():
				if f in ["addons", ".godot", ".import"]:
					continue
				stack.append(path + "/")
			else:
				if f.ends_with(ext):
					out.append(path)
		d.list_dir_end()
	return out


func _read_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return ""
	var s: String = f.get_as_text()
	f.close()
	return s
