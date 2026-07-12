class_name DialogueLinter extends RefCounted

## Reusable linter for .dialogue files + the .gd code that backs them.
## The SceneTree wrapper at tools/lint_dialogues.gd instantiates this and
## prints to stdout; tests/test_dialogue_lint.gd instantiates it with
## tighter inputs and asserts on the returned LintReport.
##
## Checks:
##   E.2 — flag write/read audit (orphan writers, orphan readers).
##   E.3 — StoryVec axis/region validation (typos vs config).
##   E.4 — untagged-exit detection (options routing to END without [#exit]).
##   E.7 — menu-size audit (moments with more than MAX_MENU_OPTIONS options).


# ── Regexes ────────────────────────────────────────────────────────────
const SET_FLAG_DLG_RE: String = "GameState\\.set_flag\\s*\\(\\s*\"([^\"]+)\""
const GET_FLAG_DLG_RE: String = "GameState\\.get_flag\\s*\\(\\s*\"([^\"]+)\""
const SET_FLAG_GD_RE: String = "set_flag\\s*\\(\\s*&?\"([^\"]+)\""
const GET_FLAG_GD_RE: String = "get_flag\\s*\\(\\s*&?\"([^\"]+)\""
# Inspector / export-bound flag property references. Many interactables
# expose their flag-of-interest via a `*_flag` export (in .gd source) or
# inspector binding (in .tscn) and call set_flag/get_flag at runtime via
# the variable — invisible to the literal-string regex. Treat any
# `*flag = &"X"` / `*flag = "X"` reference as BOTH a read AND a write
# (we can't always tell which from the property name; e.g. `done_flag`
# usually writes, `require_flag` reads, but the linter doesn't need to
# split semantics — it just needs to know X is referenced somewhere).
#
# .gd may have a type annotation between the name and `=`:
#   @export var require_flag: StringName = &"walkie_talkie_owned"
# .tscn never does (inspector serializes without annotations).
const TSCN_FLAG_RE: String = "[a-z_]*flag[a-z_]*\\s*=\\s*&?\"([^\"]+)\""
const GD_EXPORT_FLAG_RE: String = "[a-z_]*flag[a-z_]*\\s*(?::\\s*\\w+)?\\s*=\\s*&?\"([^\"]+)\""

const NUDGE_RE: String = "StoryVec\\.nudge\\s*\\(\\s*&?\"([^\"]+)\""
const IN_REGION_RE: String = "StoryVec\\.in_region\\s*\\(\\s*&?\"([^\"]+)\""
const VALUE_RE: String = "StoryVec\\.value\\s*\\(\\s*&?\"([^\"]+)\""

const EXIT_TAG: String = "exit"
const LEGACY_EXIT_TEXT: String = "End the conversation"

## E.7 — worst-case simultaneous options a single response menu may show
## before the linter warns. Every [if]-gated option counts as visible
## (static analysis can't prove gates mutually exclusive), so the number
## reported is the ceiling, not necessarily what a given save sees.
const MAX_MENU_OPTIONS: int = 3

# Allowlist for flag names that are set with DYNAMIC names in .gd code
# (e.g. LevelProgression's `_completed_key(num)` builds "level_N_completed"
# at runtime, which our regex can't see).
const FLAG_DYNAMIC_GD_WRITERS: Array[String] = [
	"level_1_completed", "level_2_completed",
	"level_3_completed", "level_4_completed",
	"level_1_unlocked", "level_2_unlocked",
	"level_3_unlocked", "level_4_unlocked",
]


# ── Report shape ───────────────────────────────────────────────────────
class LintReport:
	var errors: Array[Dictionary] = []
	var warnings: Array[Dictionary] = []
	var info: Array[String] = []
	var files_scanned: int = 0
	var lines_scanned: int = 0
	var flag_writes: Dictionary = {}
	var flag_reads: Dictionary = {}

	func error(file: String, msg: String, ctx: Dictionary = {}) -> void:
		errors.append({"file": file, "msg": msg, "ctx": ctx})

	func warn(file: String, msg: String, ctx: Dictionary = {}) -> void:
		warnings.append({"file": file, "msg": msg, "ctx": ctx})

	func has_findings() -> bool:
		return errors.size() > 0 or warnings.size() > 0


# ── Public API ─────────────────────────────────────────────────────────

## Run the full lint pass. Returns a populated LintReport.
##   dialogue_paths     — list of .dialogue file URIs ("res://...").
##   gd_dirs            — list of dirs/files to scan for .gd flag refs.
##   story_vec_config   — path to the StoryVecConfig .tres (or "" to skip
##                        StoryVec validation entirely — useful in tests).
func analyze(dialogue_paths: Array[String], gd_dirs: Array[String],
		story_vec_config: String, tscn_dirs: Array[String] = []) -> LintReport:
	var report := LintReport.new()
	for path in dialogue_paths:
		_scan_dialogue(path, report)
	for gd_root in gd_dirs:
		_collect_flags_from_gd(gd_root, report)
	for tscn_root in tscn_dirs:
		_collect_flags_from_tscn(tscn_root, report)
	_audit_flags(report)
	if not story_vec_config.is_empty():
		var axes := _load_story_vec_axes(story_vec_config)
		var regions := _load_story_vec_regions(story_vec_config)
		var all_paths: Array[String] = dialogue_paths.duplicate()
		for gd_root in gd_dirs:
			_collect_gd_paths(gd_root, all_paths)
		_audit_story_vec(all_paths, axes, regions, report)
	return report


# ── Per-file scanning ──────────────────────────────────────────────────

func _scan_dialogue(path: String, report: LintReport) -> void:
	var resource: Resource = ResourceLoader.load(path)
	if resource == null:
		report.error(path, "ResourceLoader.load returned null")
		return
	if not resource is DialogueResource:
		report.error(path, "loaded resource is not a DialogueResource (got %s)"
				% resource.get_class())
		return
	var dr: DialogueResource = resource
	report.files_scanned += 1
	report.lines_scanned += dr.lines.size()
	report.info.append("%s — %d lines" % [path, dr.lines.size()])

	_collect_flags(path, report)
	_check_exit_tags(path, dr, report)
	_check_menu_sizes(path, report)


# ── E.7 — menu-size audit ──────────────────────────────────────────────
# A "menu" (a moment the player picks from) is a consecutive run of `- `
# option lines at the same tab depth. Lines indented DEEPER belong to the
# option above them (its body); any line at the same or shallower depth
# ends the run. Nested menus inside an option body are audited as their
# own moments. Reports title + line + gated/exit breakdown so triage can
# tell "5 options but 3 are progressive unlocks" from a genuine wall.

func _check_menu_sizes(path: String, report: LintReport) -> void:
	var src := _read_text(path)
	if src.is_empty():
		return
	var title := "(top)"
	var open: Dictionary = {}  # tab depth → menu dict (see _open_menu)
	var line_no := 0
	for raw: String in src.split("\n"):
		line_no += 1
		var stripped := raw.strip_edges()
		if stripped.is_empty() or stripped.begins_with("#"):
			continue
		var depth := 0
		while depth < raw.length() and raw[depth] == "\t":
			depth += 1
		if stripped.begins_with("~ "):
			# New section: every open menu ends here.
			_flush_menus_at_or_deeper(path, open, 0, report)
			title = stripped.substr(2).strip_edges()
			continue
		if stripped.begins_with("- "):
			# An option at this depth ends any deeper menu's run.
			_flush_menus_at_or_deeper(path, open, depth + 1, report)
			if not open.has(depth):
				open[depth] = {"title": title, "line": line_no,
						"total": 0, "gated": 0, "exits": 0}
			var m: Dictionary = open[depth]
			m.total += 1
			if stripped.begins_with("- [if "):
				m.gated += 1
			if "[#%s]" % EXIT_TAG in stripped:
				m.exits += 1
			continue
		# Non-option line: ends any menu at this depth or deeper. A body
		# line one level deeper than its option leaves the option's menu
		# open; a speaker/do/=> line back at the menu's own depth closes it.
		_flush_menus_at_or_deeper(path, open, depth, report)
	_flush_menus_at_or_deeper(path, open, 0, report)


func _flush_menus_at_or_deeper(path: String, open: Dictionary, min_depth: int,
		report: LintReport) -> void:
	for d: int in open.keys().duplicate():
		if d < min_depth:
			continue
		var m: Dictionary = open[d]
		open.erase(d)
		if m.total <= MAX_MENU_OPTIONS:
			continue
		report.warn(path, "menu in '~ %s' (line %d) shows up to %d options (%d always-on, %d [if]-gated, %d exit) — target ≤ %d"
				% [m.title, m.line, m.total, m.total - m.gated, m.gated,
				   m.exits, MAX_MENU_OPTIONS],
				{"menu": m.title, "line": m.line, "total": m.total,
				 "gated": m.gated, "exits": m.exits})


func _collect_flags(path: String, report: LintReport) -> void:
	var src := _read_text(path)
	if src.is_empty(): return
	for m: RegExMatch in RegEx.create_from_string(SET_FLAG_DLG_RE).search_all(src):
		_record_flag(report.flag_writes, m.get_string(1), path)
	for m: RegExMatch in RegEx.create_from_string(GET_FLAG_DLG_RE).search_all(src):
		_record_flag(report.flag_reads, m.get_string(1), path)


func _collect_flags_from_gd(root: String, report: LintReport) -> void:
	if root.ends_with(".gd"):
		_scan_gd_file(root, report)
		return
	var dir := DirAccess.open(root)
	if dir == null: return
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "": break
		if name.begins_with("."): continue
		var full := root + "/" + name
		if dir.current_is_dir():
			_collect_flags_from_gd(full, report)
		elif name.ends_with(".gd"):
			_scan_gd_file(full, report)
	dir.list_dir_end()


func _scan_gd_file(path: String, report: LintReport) -> void:
	var src := _read_text(path)
	if src.is_empty(): return
	for m: RegExMatch in RegEx.create_from_string(SET_FLAG_GD_RE).search_all(src):
		_record_flag(report.flag_writes, m.get_string(1), path)
	for m: RegExMatch in RegEx.create_from_string(GET_FLAG_GD_RE).search_all(src):
		_record_flag(report.flag_reads, m.get_string(1), path)
	# Also catch @export var defaults that bind a flag name. Allows a type
	# annotation between the property and `=` (StringName / String / etc).
	for m: RegExMatch in RegEx.create_from_string(GD_EXPORT_FLAG_RE).search_all(src):
		var flag := m.get_string(1)
		_record_flag(report.flag_writes, flag, path)
		_record_flag(report.flag_reads, flag, path)


# .tscn flag-property references — record as ambiguous (both read+write).
# Conservative: prevents false positives at the cost of letting through
# truly-unused .tscn-bound flags (rare).
func _collect_flags_from_tscn(root: String, report: LintReport) -> void:
	if root.ends_with(".tscn"):
		_scan_tscn_file(root, report)
		return
	var dir := DirAccess.open(root)
	if dir == null: return
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "": break
		if name.begins_with("."): continue
		var full := root + "/" + name
		if dir.current_is_dir():
			_collect_flags_from_tscn(full, report)
		elif name.ends_with(".tscn"):
			_scan_tscn_file(full, report)
	dir.list_dir_end()


func _scan_tscn_file(path: String, report: LintReport) -> void:
	var src := _read_text(path)
	if src.is_empty(): return
	for m: RegExMatch in RegEx.create_from_string(TSCN_FLAG_RE).search_all(src):
		var flag := m.get_string(1)
		_record_flag(report.flag_writes, flag, path)
		_record_flag(report.flag_reads, flag, path)


func _record_flag(table: Dictionary, flag: String, path: String) -> void:
	if not table.has(flag):
		table[flag] = []
	if not (path in table[flag]):
		(table[flag] as Array).append(path)


# ── Cross-file audits ──────────────────────────────────────────────────

func _audit_flags(report: LintReport) -> void:
	var orphan_writers: Array[String] = []
	var orphan_readers: Array[String] = []
	for flag in report.flag_writes.keys():
		if not report.flag_reads.has(flag):
			orphan_writers.append(flag)
	for flag in report.flag_reads.keys():
		if report.flag_writes.has(flag): continue
		if flag in FLAG_DYNAMIC_GD_WRITERS: continue
		orphan_readers.append(flag)
	orphan_writers.sort()
	orphan_readers.sort()

	for flag in orphan_readers:
		var files: Array = report.flag_reads.get(flag, [])
		report.error("(cross-file)",
				"flag '%s' is READ but never SET — gate always evaluates to default" % flag,
				{"read_in": files})
	for flag in orphan_writers:
		var files: Array = report.flag_writes.get(flag, [])
		report.warn("(cross-file)",
				"flag '%s' is SET but never READ — verify it's still meaningful" % flag,
				{"set_in": files})


# ── StoryVec validation ────────────────────────────────────────────────

func _load_story_vec_axes(config_path: String) -> Array[StringName]:
	var out: Array[StringName] = []
	if not ResourceLoader.exists(config_path): return out
	var cfg := ResourceLoader.load(config_path)
	if cfg == null or not ("axes" in cfg): return out
	for a in cfg.axes: out.append(StringName(a))
	return out


func _load_story_vec_regions(config_path: String) -> Array[StringName]:
	var out: Array[StringName] = []
	if not ResourceLoader.exists(config_path): return out
	var cfg := ResourceLoader.load(config_path)
	if cfg == null or not ("regions" in cfg): return out
	for r in cfg.regions: out.append(StringName(r.get("name", &"")))
	return out


func _audit_story_vec(paths: Array[String], axes: Array[StringName],
		regions: Array[StringName], report: LintReport) -> void:
	var nudge_re := RegEx.create_from_string(NUDGE_RE)
	var in_region_re := RegEx.create_from_string(IN_REGION_RE)
	var value_re := RegEx.create_from_string(VALUE_RE)

	for path in paths:
		var src := _read_text(path)
		if src.is_empty(): continue
		for m: RegExMatch in nudge_re.search_all(src):
			var axis := StringName(m.get_string(1))
			if not (axis in axes):
				report.error(path,
						"StoryVec.nudge(\"%s\", ...) — axis not declared in config" % axis,
						{"declared_axes": axes})
		for m: RegExMatch in value_re.search_all(src):
			var axis := StringName(m.get_string(1))
			if not (axis in axes):
				report.error(path,
						"StoryVec.value(\"%s\") — axis not declared in config" % axis,
						{"declared_axes": axes})
		for m: RegExMatch in in_region_re.search_all(src):
			var region := StringName(m.get_string(1))
			if not (region in regions):
				report.error(path,
						"StoryVec.in_region(\"%s\") — region not declared in config" % region,
						{"declared_regions": regions})


func _collect_gd_paths(root: String, out: Array[String]) -> void:
	if root.ends_with(".gd"):
		out.append(root)
		return
	var dir := DirAccess.open(root)
	if dir == null: return
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "": break
		if name.begins_with("."): continue
		var full := root + "/" + name
		if dir.current_is_dir():
			_collect_gd_paths(full, out)
		elif name.ends_with(".gd"):
			out.append(full)
	dir.list_dir_end()


# ── Untagged-exit detection ────────────────────────────────────────────

func _check_exit_tags(path: String, dr: DialogueResource, report: LintReport) -> void:
	for line_id_v in dr.lines.keys():
		var line_id := String(line_id_v)
		var line: Dictionary = dr.lines[line_id]
		if String(line.get("type", "")) != "response": continue
		var text := String(line.get("text", ""))
		var tags: PackedStringArray = line.get("tags", PackedStringArray())
		if EXIT_TAG in tags: continue
		if text == LEGACY_EXIT_TEXT: continue
		var next_id := _strip_id_trail(String(line.get("next_id", "")))
		if _walk_terminates_at_end(dr, next_id):
			report.warn(path,
					"option \"%s\" routes to END/done without [#exit] tag — will dim on revisit" % text,
					{"line_id": line_id, "next_id": line.get("next_id", "")})


func _walk_terminates_at_end(dr: DialogueResource, start_id: String) -> bool:
	var visited: Dictionary = {}
	var current_id := start_id
	var hops: int = 0
	while hops < 64:
		hops += 1
		if current_id.is_empty(): return false
		if current_id == "end": return true
		if visited.has(current_id): return false
		if not dr.lines.has(current_id): return false
		visited[current_id] = true
		var data: Dictionary = dr.lines[current_id]
		var t := String(data.get("type", ""))
		if t == "response": return false
		current_id = _strip_id_trail(String(data.get("next_id", "")))
	return false


# ── Helpers ────────────────────────────────────────────────────────────

func _strip_id_trail(id: String) -> String:
	if id.is_empty(): return id
	var pipe := id.find("|")
	if pipe > -1: id = id.substr(0, pipe)
	if "@" in id:
		var parts := id.split("@")
		id = parts[parts.size() - 1]
	return id


func _read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return ""
	var src: String = f.get_as_text()
	# Strip line comments before regex — otherwise docstrings that mention
	# example calls (e.g. inside autoload/story_vec.gd) get false-flagged.
	var lines: Array[String] = []
	for line in src.split("\n"):
		var stripped: String = line
		var idx: int = stripped.find("#")
		if idx >= 0:
			# Don't strip `#` if it's inside a `[#tag]` marker.
			var before: String = stripped.substr(0, idx)
			if not before.ends_with("["):
				stripped = stripped.substr(0, idx)
		lines.append(stripped)
	return "\n".join(lines)
