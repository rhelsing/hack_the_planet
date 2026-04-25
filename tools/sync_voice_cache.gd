extends SceneTree

## Legacy bake tool: copies mp3s from user://tts_cache → res://audio/voice_cache.
##
## NOTE: dialogue.gd now writes fresh editor synths straight to res://, so
## this script isn't part of the normal workflow anymore. Run it once if
## you have leftover lines in user://tts_cache from before that change,
## then forget about it.
##
## Run from the repo root:
##   godot --headless --script res://tools/sync_voice_cache.gd --quit
##
## Idempotent. Files already present in res:// are skipped.

const DEV_CACHE: String = "user://tts_cache/"
const SHIPPED_CACHE: String = "res://audio/voice_cache/"


func _init() -> void:
	print("=== sync_voice_cache ===")
	print("  dev:     %s" % ProjectSettings.globalize_path(DEV_CACHE))
	print("  shipped: %s" % ProjectSettings.globalize_path(SHIPPED_CACHE))

	if not DirAccess.dir_exists_absolute(DEV_CACHE):
		push_error("Dev cache dir does not exist: %s" % DEV_CACHE)
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(SHIPPED_CACHE)

	var dev := DirAccess.open(DEV_CACHE)
	var shipped := DirAccess.open(SHIPPED_CACHE)
	if dev == null or shipped == null:
		push_error("Could not open a cache dir")
		quit(1)
		return

	var dev_files: Dictionary = _list_mp3s(dev)
	var shipped_files: Dictionary = _list_mp3s(shipped)

	var copied: int = 0
	var skipped: int = 0
	for fname in dev_files:
		if shipped_files.has(fname):
			skipped += 1
			continue
		var src: String = DEV_CACHE + fname
		var dst: String = SHIPPED_CACHE + fname
		var err: int = DirAccess.copy_absolute(src, dst)
		if err == OK:
			copied += 1
			print("  + %s" % fname)
		else:
			push_warning("Failed to copy %s (err=%d)" % [fname, err])

	var orphans: Array[String] = []
	for fname in shipped_files:
		if not dev_files.has(fname):
			orphans.append(String(fname))

	print("")
	print("Summary:")
	print("  copied:  %d" % copied)
	print("  skipped: %d (already in shipped cache)" % skipped)
	print("  orphans: %d (in shipped but not in dev)" % orphans.size())
	for o in orphans:
		print("    ? %s" % o)
	if orphans.size() > 0:
		print("")
		print("Orphans are lines that were voiced in a prior pass but are no longer")
		print("being synthesized (text changed, character renamed). Delete manually")
		print("if you want to shrink the shipped cache.")

	quit(0)


func _list_mp3s(dir: DirAccess) -> Dictionary:
	var out: Dictionary = {}
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".mp3"):
			out[fname] = true
		fname = dir.get_next()
	dir.list_dir_end()
	return out
