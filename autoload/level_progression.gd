extends Node

## Single source of truth for the 4-level arc's state machine.
## - Level scenes call `register_level(num)` on _ready.
## - End-of-level dialogue calls `advance()` to mark complete + return to hub.
## - Hub pedestals call `goto_level(num)` to start/replay a level.
##
## All progression state lives in GameState.flags (persisted via SaveService).
## See docs/level_progression.md for the phased plan.

const HUB_PATH: String = "res://level/hub.tscn"
const HUB_LEVEL_ID: StringName = &"hub"

const LEVEL_PATHS: Dictionary = {
	1: "res://level/level_1.tscn",
	2: "res://level/level_2.tscn",
	3: "res://level/level_3.tscn",
	4: "res://level/level_4.tscn",
}

const CURRENT_LEVEL_NUM: StringName = &"current_level_num"


# ── Lifecycle API ────────────────────────────────────────────────────────

func register_level(num: int) -> void:
	GameState.set_flag(CURRENT_LEVEL_NUM, num)
	var path: String = LEVEL_PATHS.get(num, "")
	if path != "":
		SaveService.set_current_level(_scene_id_from_path(path))


func advance() -> void:
	var num: int = get_current_level_num()
	if num > 0:
		GameState.set_flag(_completed_key(num), true)
	SaveService.set_current_level(HUB_LEVEL_ID)
	# Save AFTER _goto so the saved player position reflects the hub spawn,
	# not the end-NPC position in the old level. _goto awaits the transition +
	# mount; the player has been snapped to PlayerSpawn by the time we save.
	await _goto(HUB_PATH)
	_save_if_active()


## Path-based scene swap that bypasses the 1–4 gating + completion bookkeeping
## of `goto_level`. Used by branching dialogue outcomes that send the player
## somewhere outside the normal arc (e.g. Splice's L3 offer → L5 betrayal
## continuation, or refusal → straight back to hub without marking L3 complete).
func goto_path(path: String) -> void:
	if path.is_empty():
		push_error("LevelProgression.goto_path: empty path"); return
	if not ResourceLoader.exists(path):
		push_error("LevelProgression.goto_path: missing scene %s" % path); return
	SaveService.set_current_level(_scene_id_from_path(path))
	await _goto(path)
	_save_if_active()


func goto_level(num: int) -> void:
	if num < 1 or num > 4:
		push_error("LevelProgression.goto_level: invalid num %d" % num)
		return
	if num > 1 and not is_level_complete(num - 1):
		push_warning("LevelProgression.goto_level: level %d locked (complete %d first)" % [num, num - 1])
		return
	var path: String = LEVEL_PATHS.get(num, "")
	if path == "":
		return
	SaveService.set_current_level(_scene_id_from_path(path))
	# Save AFTER _goto so the saved player position is the new level's spawn
	# (not the pedestal you were standing on in the hub). await so the save
	# fires once Game.load_level has completed the transition + mount.
	await _goto(path)
	_save_if_active()


# ── Read helpers (for dialogue + HUD + pedestal gating) ─────────────────

func get_current_level_num() -> int:
	return int(GameState.get_flag(CURRENT_LEVEL_NUM, 0))


func is_level_complete(num: int) -> bool:
	return bool(GameState.get_flag(_completed_key(num), false))


func is_powerup_owned(flag: StringName) -> bool:
	return bool(GameState.get_flag(flag, false))


# ── Internals ────────────────────────────────────────────────────────────

func _completed_key(num: int) -> StringName:
	return StringName("level_%d_completed" % num)


func _save_if_active() -> void:
	if SaveService.has_active_slot():
		SaveService.save_to_slot(SaveService.active_slot)


func _goto(path: String) -> void:
	# In-game navigation: swap the Level child of the running Game host.
	# Keeps Player + HUD persistent across level changes. Game.load_level is
	# now async (wraps the swap in a Transition); awaiting here so callers
	# (advance, goto_level, goto_path) can save AFTER the mount + transition.
	var audio := get_tree().root.get_node_or_null(^"Audio")
	if audio != null and audio.has_method(&"play_sfx"):
		audio.call(&"play_sfx", &"teleport")
	var scene := get_tree().current_scene
	if scene != null and scene.has_method(&"load_level"):
		await scene.load_level(path)
		return
	# Fallback (tests, headless runs, or any context where Game isn't
	# current_scene): use SceneLoader for a full-scene swap. SceneLoader.goto
	# is fire-and-forget (drives its own internal awaits); we don't await here
	# because tests don't need the synchronous save-after-mount guarantee.
	var sl := get_tree().root.get_node_or_null(^"SceneLoader")
	if sl != null and sl.has_method(&"goto"):
		sl.call(&"goto", path)
	else:
		get_tree().change_scene_to_file(path)


func _scene_id_from_path(path: String) -> StringName:
	return StringName(path.get_file().trim_suffix(".tscn"))
