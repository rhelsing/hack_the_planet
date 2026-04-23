extends Node
## Multi-slot save. Writes JSON to user://save_slot_<id>.json plus a small
## sidecar .meta.json so the slot-list UI can render cards without parsing
## the full save.
##
## Design (docs/menus.md §3.2 + §8, sync_up 2026-04-22, amendment v1.2):
## - Slots: "a", "b", "c". No hidden autosave.
## - On "New Game" the player picks a slot. SaveService.active_slot tracks it
##   for the rest of the session. Autosaves (checkpoint/flag) write to
##   active_slot. Load sets active_slot to the slot being loaded.
## - SaveService owns `current_level` + `playtime_s` (option c — keeps these
##   fields off GameState and PlayerBody).
## - Bundles GameState.to_dict() + PlayerBody.get_save_dict() if those APIs
##   exist. Both are guarded (interactables_dev + character_dev ship them in
##   their own sprints).
## - Schema version 1. Migration lives inside the respective dict consumers
##   (GameState.from_dict, PlayerBody.load_save_dict); SaveService passes the
##   dicts through opaquely.

const SLOTS: Array[StringName] = [&"a", &"b", &"c"]
const CURRENT_VERSION := 1

var current_level: StringName = &""
var playtime_s: float = 0.0
## Which slot the current gameplay session is writing to. Set by
## begin_new_game() and load_from_slot(). Empty string when we're not in a
## session (main menu, credits). Autosaves skip if this is empty.
var active_slot: StringName = &""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Events.checkpoint_reached.connect(_on_checkpoint_reached)
	Events.flag_reached.connect(_on_flag_reached)
	var sl := get_tree().root.get_node_or_null(^"SceneLoader")
	if sl != null and sl.has_signal(&"scene_entered"):
		sl.connect(&"scene_entered", _on_scene_entered)


func _process(delta: float) -> void:
	# Only tick while unpaused and inside gameplay. Avoid inflating playtime
	# when sitting on the main menu.
	if get_tree().paused:
		return
	if _is_in_gameplay():
		playtime_s += delta


# ── Public API ───────────────────────────────────────────────────────────

func has_any_slot() -> bool:
	for id in SLOTS:
		if has_slot(id):
			return true
	return false


func has_slot(id: StringName) -> bool:
	return FileAccess.file_exists(_save_path(id))


func slot_ids_for_picker() -> Array[StringName]:
	return [&"a", &"b", &"c"]


## Called by main menu when the player confirms "New Game → Slot X". Clears
## GameState, overwrites the slot file, and sets active_slot so autosaves
## land here for the session.
func begin_new_game(slot: StringName) -> void:
	if not (slot in SLOTS):
		push_error("SaveService.begin_new_game: invalid slot %s" % slot)
		return
	var gs := get_tree().root.get_node_or_null(^"GameState")
	if gs != null and gs.has_method(&"reset"):
		gs.call(&"reset")
	active_slot = slot
	playtime_s = 0.0
	save_to_slot(slot)


## True whenever a gameplay session is bound to a slot. Autosave targets it.
func has_active_slot() -> bool:
	return active_slot != &""


## Called when returning to the main menu / quitting — clears the active slot
## so the next boot starts fresh.
func clear_active_slot() -> void:
	active_slot = &""


func slot_metadata(id: StringName) -> Dictionary:
	var p := _meta_path(id)
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


func save_to_slot(id: StringName) -> void:
	var payload := {
		"version": CURRENT_VERSION,
		"timestamp": int(Time.get_unix_time_from_system()),
		"level_id": String(current_level),
		"playtime_s": playtime_s,
		"game_state": _game_state_dict(),
		"player_state": _player_save_dict(),
	}
	_write_json(_save_path(id), payload)
	_write_json(_meta_path(id), _make_meta(payload))
	Events.game_saved.emit(id)


func load_from_slot(id: StringName) -> void:
	if not has_slot(id):
		push_warning("SaveService.load_from_slot: no file for slot %s" % id)
		return
	var f := FileAccess.open(_save_path(id), FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		push_error("SaveService: corrupt save file for slot %s" % id)
		return
	var d: Dictionary = parsed
	current_level = StringName(d.get("level_id", ""))
	playtime_s = float(d.get("playtime_s", 0.0))
	active_slot = id
	_apply_game_state(d.get("game_state", {}))
	_pending_player_state = d.get("player_state", {})
	Events.game_loaded.emit(id)
	_request_scene_load(String(current_level))


func most_recent_slot() -> StringName:
	# For main-menu "Continue" — newest populated of A/B/C.
	var best: StringName = &""
	var best_ts := -1
	for id in slot_ids_for_picker():
		if not has_slot(id):
			continue
		var ts := int(slot_metadata(id).get("timestamp", 0))
		if ts > best_ts:
			best_ts = ts
			best = id
	return best


func delete_slot(id: StringName) -> void:
	for p in [_save_path(id), _meta_path(id)]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


## Called by whoever loads a level so current_level reflects reality.
func set_current_level(level_id: StringName) -> void:
	current_level = level_id


# ── Internals ────────────────────────────────────────────────────────────

var _pending_player_state: Dictionary = {}

func _on_checkpoint_reached(_pos: Vector3) -> void:
	# Autosave goes to the player's chosen slot for this session. If they
	# never picked one (dev-launching straight into the level with no main-
	# menu trip), silently skip rather than writing to a pseudo-slot.
	if active_slot == &"":
		return
	save_to_slot(active_slot)


func _on_flag_reached() -> void:
	# End-of-level autosave (per sync_up 2026-04-22 char_dev ack).
	if active_slot == &"":
		return
	save_to_slot(active_slot)


func _on_scene_entered(scene: Node) -> void:
	if scene != null:
		current_level = _scene_id_for(scene)
	if _pending_player_state.is_empty() or scene == null:
		return
	var player := scene.get_node_or_null(^"Player")
	if player != null and player.has_method(&"load_save_dict"):
		player.call(&"load_save_dict", _pending_player_state)
	_pending_player_state = {}


func _save_path(id: StringName) -> String:
	return "user://save_slot_%s.json" % id


func _meta_path(id: StringName) -> String:
	return "user://save_slot_%s.meta.json" % id


func _write_json(path: String, d: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("SaveService: could not open %s for write" % path)
		return
	f.store_string(JSON.stringify(d, "\t"))


func _make_meta(payload: Dictionary) -> Dictionary:
	return {
		"timestamp": payload.get("timestamp", 0),
		"level_id": payload.get("level_id", ""),
		"playtime_s": payload.get("playtime_s", 0.0),
		"screenshot_b64": _capture_screenshot_b64(),
	}


func _capture_screenshot_b64() -> String:
	# Skip in headless / dummy renderer — viewport texture isn't available.
	if DisplayServer.get_name() == "headless":
		return ""
	var vp := get_viewport()
	if vp == null:
		return ""
	var tex := vp.get_texture()
	if tex == null:
		return ""
	var img := tex.get_image()
	if img == null:
		return ""
	img.resize(64, 36, Image.INTERPOLATE_LANCZOS)
	var png := img.save_png_to_buffer()
	if png.is_empty():
		return ""
	return Marshalls.raw_to_base64(png)


func _game_state_dict() -> Dictionary:
	var gs := get_tree().root.get_node_or_null(^"GameState")
	if gs != null and gs.has_method(&"to_dict"):
		return gs.call(&"to_dict")
	return {}


func _apply_game_state(d: Dictionary) -> void:
	var gs := get_tree().root.get_node_or_null(^"GameState")
	if gs != null and gs.has_method(&"from_dict"):
		gs.call(&"from_dict", d)


func _player_save_dict() -> Dictionary:
	var scene := get_tree().current_scene
	if scene == null:
		return {}
	var player := scene.get_node_or_null(^"Player")
	if player != null and player.has_method(&"get_save_dict"):
		return player.call(&"get_save_dict")
	return {}


func _is_in_gameplay() -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		return false
	# Cheap heuristic: main menu + credits + loader sit under menu/ paths.
	var sf: String = scene.scene_file_path
	return not sf.begins_with("res://menu/")


func _scene_id_for(scene: Node) -> StringName:
	# Map scene_file_path to a stable id used by main-menu Continue.
	var sf: String = scene.scene_file_path
	return StringName(sf.get_file().trim_suffix(".tscn"))


func _request_scene_load(level_id: String) -> void:
	if level_id.is_empty():
		return
	# Convention: level_id is the file basename minus .tscn. Gameplay levels
	# live at res://<level_id>.tscn or res://<level_id>/... — we try common
	# paths, otherwise assume a `game.tscn`-style root and punt.
	var candidates := [
		"res://%s.tscn" % level_id,
		"res://level/%s.tscn" % level_id,
		"res://game.tscn",
	]
	var sl := get_tree().root.get_node_or_null(^"SceneLoader")
	for c in candidates:
		if ResourceLoader.exists(c):
			if sl != null and sl.has_method(&"goto"):
				sl.call(&"goto", c)
			else:
				get_tree().change_scene_to_file(c)
			return
