extends SceneTree

## Entry point — invokes DialogueLinter (tools/dialogue_linter.gd) on the
## production paths and prints findings to stdout. Exits 1 if any errors,
## 0 otherwise. Warnings don't fail the gate.
##
## Run:
##   godot --headless --script res://tools/lint_dialogues.gd --quit

const Linter = preload("res://tools/dialogue_linter.gd")

const DIALOGUE_DIR: String = "res://dialogue/"
const STORY_VEC_CONFIG_PATH: String = "res://dialogue/story_vec_config.tres"

# Production .gd directories to scan for flag references.
const GD_SCAN_DIRS: Array[String] = [
	"res://autoload",
	"res://game.gd",
	"res://hud",
	"res://interactable",
	"res://level",
	"res://menu",
	"res://player",
	"res://cutscene_engine",
	"res://dialogue",
]

# .tscn dirs — the inspector binds many flag references via @export
# properties (require_flag, advance_flag, etc.) that the .gd scan can't see.
const TSCN_SCAN_DIRS: Array[String] = [
	"res://level",
	"res://hud",
	"res://interactable",
	"res://menu",
]


func _init() -> void:
	var paths := _list_dialogue_files(DIALOGUE_DIR)
	if paths.is_empty():
		printerr("lint_dialogues: no .dialogue files found in %s" % DIALOGUE_DIR)
		quit(1)
		return
	var linter := Linter.new()
	var report = linter.analyze(paths, GD_SCAN_DIRS, STORY_VEC_CONFIG_PATH, TSCN_SCAN_DIRS)
	_print_summary(report)
	quit(1 if report.errors.size() > 0 else 0)


func _list_dialogue_files(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		printerr("lint_dialogues: cannot open %s" % dir_path)
		return out
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


func _print_summary(report) -> void:
	print("")
	print("=== Lint summary ===")
	print("Files scanned: %d" % report.files_scanned)
	print("Lines scanned: %d" % report.lines_scanned)
	print("Errors: %d   Warnings: %d" % [report.errors.size(), report.warnings.size()])
	if report.errors.size() > 0:
		print("\n--- ERRORS ---")
		for e in report.errors:
			print("  [%s] %s" % [e["file"], e["msg"]])
	if report.warnings.size() > 0:
		print("\n--- WARNINGS ---")
		for w in report.warnings:
			print("  [%s] %s" % [w["file"], w["msg"]])
