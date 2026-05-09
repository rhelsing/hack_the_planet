extends SceneTree

## Phase E.5 — DialogueLinter smoke + structural assertions.
##
## Validates that the linter API works and that running it on production
## paths produces a sensible LintReport. Doesn't pin specific finding
## counts (those drift with content) — Phase E.6's job to triage actual
## findings.
##
## Run via:
##   godot --headless --script res://tests/test_dialogue_lint.gd --quit


const Linter = preload("res://tools/dialogue_linter.gd")
const DIALOGUE_DIR: String = "res://dialogue/"
const STORY_VEC_CONFIG: String = "res://dialogue/story_vec_config.tres"


func _init() -> void:
	var failures: Array[String] = []

	# ---- 1. Empty inputs → empty report, no crash ----
	var linter := Linter.new()
	var empty_report = linter.analyze([], [], "")
	if empty_report == null:
		failures.append("analyze() returned null on empty inputs")
	elif empty_report.files_scanned != 0:
		failures.append("empty input should scan 0 files, got %d" % empty_report.files_scanned)
	elif empty_report.errors.size() != 0:
		failures.append("empty input should produce 0 errors, got %d" % empty_report.errors.size())

	# ---- 2. Production smoke — linter completes on the real codebase ----
	var paths := _list_dialogue_files(DIALOGUE_DIR)
	if paths.is_empty():
		failures.append("expected at least 1 .dialogue file in %s" % DIALOGUE_DIR)

	var report = linter.analyze(paths, ["res://dialogue", "res://autoload"], STORY_VEC_CONFIG)
	if report == null:
		failures.append("analyze() returned null on production paths")
	elif report.files_scanned != paths.size():
		failures.append("expected %d files scanned, got %d" % [paths.size(), report.files_scanned])
	elif report.lines_scanned <= 0:
		failures.append("lines_scanned should be > 0 on production paths")

	# ---- 3. Each finding has the expected shape ----
	for e in report.errors:
		if not (e is Dictionary and e.has("file") and e.has("msg")):
			failures.append("malformed error entry: %s" % str(e))
			break
	for w in report.warnings:
		if not (w is Dictionary and w.has("file") and w.has("msg")):
			failures.append("malformed warning entry: %s" % str(w))
			break

	# ---- 4. Flag tables populated ----
	if report.flag_writes.is_empty():
		failures.append("flag_writes should be non-empty on production paths")
	if report.flag_reads.is_empty():
		failures.append("flag_reads should be non-empty on production paths")

	# ---- 5. has_findings() reflects errors+warnings count ----
	var expected_findings: bool = (report.errors.size() > 0) or (report.warnings.size() > 0)
	if report.has_findings() != expected_findings:
		failures.append("has_findings() disagrees with errors/warnings size")

	if failures.is_empty():
		print("PASS test_dialogue_lint: 5 cases clean (linter API + production smoke)")
		quit(0)
	else:
		for f in failures:
			printerr("FAIL test_dialogue_lint: " + str(f))
		quit(1)


func _list_dialogue_files(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null: return out
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "": break
		if dir.current_is_dir(): continue
		if not name.ends_with(".dialogue"): continue
		out.append(dir_path + name)
	dir.list_dir_end()
	out.sort()
	return out
