extends CanvasLayer
## Pause menu. Root has PROCESS_MODE_WHEN_PAUSED so it's interactive while
## the scene tree is paused via get_tree().paused = true.
##
## Shown/hidden by PauseController.paused_changed — not by the pause input
## directly. Sub-menus (Settings, SaveSlots) pushed into MenuStack with the
## same pattern as main_menu.

const MAIN_MENU    := "res://menu/main_menu.tscn"
const SETTINGS     := "res://menu/settings_menu.tscn"
const SAVE_SLOTS   := "res://menu/save_slots.tscn"
const CONTROLS     := "res://menu/controls_panel.tscn"

@onready var _root: Control = %Root
@onready var _buttons: Control = %ButtonsRoot
@onready var _stack: Control = %MenuStack
@onready var _resume_btn:  Button = %ResumeBtn
@onready var _save_btn:    Button = %SaveBtn
@onready var _load_btn:    Button = %LoadBtn
@onready var _settings_btn:Button = %SettingsBtn
@onready var _controls_btn:Button = %ControlsBtn
@onready var _checkpoint_btn: Button = %LastCheckpointBtn
@onready var _restart_btn: Button = %RestartLevelBtn
@onready var _to_main_btn: Button = %ToMainBtn
@onready var _quit_btn:    Button = %QuitBtn

var _stack_children: Array[Node] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	visible = false
	_wire_buttons()
	var pc := get_tree().root.get_node_or_null(^"PauseController")
	if pc != null and pc.has_signal(&"paused_changed"):
		pc.connect(&"paused_changed", _on_paused_changed)


func _wire_buttons() -> void:
	_resume_btn.pressed.connect(_on_resume)
	_save_btn.pressed.connect(_on_save)
	_load_btn.pressed.connect(_on_load)
	_settings_btn.pressed.connect(_on_settings)
	_controls_btn.pressed.connect(_on_controls)
	_checkpoint_btn.pressed.connect(_on_last_checkpoint)
	_restart_btn.pressed.connect(_on_restart_level)
	_to_main_btn.pressed.connect(_on_to_main)
	_quit_btn.pressed.connect(_on_quit_desktop)


# ── Pause sync ──────────────────────────────────────────────────────────

func _on_paused_changed(is_paused: bool) -> void:
	visible = is_paused
	if is_paused:
		_open()
	else:
		_close()


func _open() -> void:
	_capture_mouse(false)
	_refresh_save_enabled()
	_refresh_checkpoint_enabled()
	_refresh_restart_enabled()
	_resume_btn.grab_focus()
	Events.menu_opened.emit(&"pause")


func _close() -> void:
	# Pop any stacked sub-menus on unpause.
	for c in _stack_children.duplicate():
		if is_instance_valid(c):
			c.queue_free()
	_stack_children.clear()
	_buttons.visible = true
	_capture_mouse(true)
	Events.menu_closed.emit(&"pause")


func _capture_mouse(capture: bool) -> void:
	var brain := get_tree().root.get_node_or_null(^"PlayerBrain")
	if brain != null and brain.has_method(&"capture_mouse"):
		brain.call(&"capture_mouse", capture)
		return
	# Fallback until char_dev ships capture_mouse on PlayerBrain.
	Input.mouse_mode = (
		Input.MOUSE_MODE_CAPTURED if capture else Input.MOUSE_MODE_VISIBLE
	)


func _refresh_checkpoint_enabled() -> void:
	# "Last Checkpoint" is a full reload of the active slot — autosaves fire
	# on Events.checkpoint_reached, so the slot's snapshot IS the checkpoint
	# state. Same gating as Save: needs an active slot.
	var ss := get_tree().root.get_node_or_null(^"SaveService")
	var has_slot: bool = ss != null and bool(ss.call(&"has_active_slot"))
	_checkpoint_btn.disabled = not has_slot


func _refresh_restart_enabled() -> void:
	# "Restart Level" reloads whatever level is currently mounted under the
	# Game host. Disabled when no level is loaded (defensive — pause menu
	# shouldn't open without one). Save state is independent: even without
	# an active slot, the in-memory restart still works (just no on-disk
	# persist). So gating is purely on having a level to restart.
	_restart_btn.disabled = _current_level_path() == ""


func _refresh_save_enabled() -> void:
	# Save is disabled when: (a) we have no active slot (shouldn't happen in
	# the normal flow since New Game / Load both set it), or (b) dialogue /
	# puzzle modal is up — settle-state-only saves.
	var pc := get_tree().root.get_node_or_null(^"PauseController")
	var ss := get_tree().root.get_node_or_null(^"SaveService")
	var modal_blocked := false
	if pc != null:
		# Pause menu's own modal count bumps when we open, so count > 1 means
		# some *other* modal is up (dialogue, puzzle, settings).
		var ct: int = int(pc.get(&"modal_count"))
		modal_blocked = ct > 1
	var no_slot: bool = ss == null or not bool(ss.call(&"has_active_slot"))
	_save_btn.disabled = modal_blocked or no_slot


# ── Button handlers ──────────────────────────────────────────────────────

func _on_resume() -> void:
	var pc := get_tree().root.get_node_or_null(^"PauseController")
	if pc != null and pc.has_method(&"set_paused"):
		pc.call(&"set_paused", false)


func _on_save() -> void:
	# Save directly to the slot the player picked at New Game / Load — no
	# picker. If they want to save to a different slot, use Load → start a
	# new game in another slot (explicit branching).
	var ss := get_tree().root.get_node_or_null(^"SaveService")
	if ss == null or not ss.call(&"has_active_slot"):
		return
	ss.call(&"save_to_slot", ss.active_slot)


func _on_load() -> void:
	_push_sub_menu(SAVE_SLOTS, {"mode": "load"})


func _on_settings() -> void:
	_push_sub_menu(SETTINGS, {})


func _on_controls() -> void:
	_push_sub_menu(CONTROLS, {})


func _on_last_checkpoint() -> void:
	# Reload the active slot — same code path as main menu's Continue, just
	# sourced from active_slot (the slot the player is mid-session in) rather
	# than most_recent_slot. Autosaves fire on every checkpoint, so the slot
	# already holds the last-checkpoint state. Unpause first so the load
	# isn't operating on a paused tree.
	var pc := get_tree().root.get_node_or_null(^"PauseController")
	if pc != null and pc.has_method(&"set_paused"):
		pc.call(&"set_paused", false)
	var ss := get_tree().root.get_node_or_null(^"SaveService")
	if ss == null or not bool(ss.call(&"has_active_slot")):
		return
	ss.call(&"load_from_slot", ss.active_slot)


func _on_restart_level() -> void:
	# Reload the currently mounted level. game.gd._spawn_player sees no
	# pending player_state (we never set one) and overwrites position +
	# respawn_point with the level's PlayerSpawn marker. Then we save_to_slot
	# so the on-disk save reflects the fresh-level state — without that, a
	# quit-and-Continue would resume at the player's prior mid-level
	# checkpoint, defeating the restart.
	#
	# Unpause BEFORE the load so the level swap isn't running under a paused
	# tree (matches _on_last_checkpoint + _on_to_main).
	var current_path: String = _current_level_path()
	if current_path == "":
		return
	var pc := get_tree().root.get_node_or_null(^"PauseController")
	if pc != null and pc.has_method(&"set_paused"):
		pc.call(&"set_paused", false)
	await LevelProgression.goto_path(current_path)
	# Persist after the load so the slot reflects the fresh-level state. No
	# slot active = dev launching straight into a level = silently skip
	# (in-memory restart still happened and that's what matters here).
	var ss := get_tree().root.get_node_or_null(^"SaveService")
	if ss != null and bool(ss.call(&"has_active_slot")):
		ss.call(&"save_to_slot", ss.active_slot)


# Pull the actually-mounted level's path from Game (which is the running
# scene root). Returns "" when there's no level (shouldn't happen during
# pause, but the defensive return keeps _on_restart_level safe).
func _current_level_path() -> String:
	var game := get_tree().current_scene
	if game == null or not ("_current_level" in game):
		return ""
	var level: Node = game.get(&"_current_level")
	if level == null or not is_instance_valid(level):
		return ""
	return level.scene_file_path


func _on_to_main() -> void:
	# Unpause first so the target scene is not loaded under a paused tree.
	var pc := get_tree().root.get_node_or_null(^"PauseController")
	if pc != null:
		pc.call(&"set_paused", false)
	# Clear the session's active slot — next gameplay session starts fresh
	# via New Game / Continue / Load from the main menu.
	var ss := get_tree().root.get_node_or_null(^"SaveService")
	if ss != null and ss.has_method(&"clear_active_slot"):
		ss.call(&"clear_active_slot")
	var sl := get_tree().root.get_node_or_null(^"SceneLoader")
	if sl != null and sl.has_method(&"goto"):
		sl.call(&"goto", MAIN_MENU)
	else:
		get_tree().change_scene_to_file(MAIN_MENU)


func _on_quit_desktop() -> void:
	get_tree().quit()


# ── Stack management ────────────────────────────────────────────────────

func _push_sub_menu(path: String, args: Dictionary) -> void:
	if not ResourceLoader.exists(path):
		push_warning("Pause menu: sub-menu missing: %s" % path)
		return
	var packed: PackedScene = load(path)
	var inst := packed.instantiate()
	inst.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	if inst.has_method(&"configure"):
		inst.call(&"configure", args)
	if inst.has_signal(&"back_requested"):
		inst.connect(&"back_requested", _pop_sub_menu.bind(inst), CONNECT_ONE_SHOT)
	_stack.add_child(inst)
	_stack_children.append(inst)
	_buttons.visible = false


func _pop_sub_menu(inst: Node) -> void:
	if is_instance_valid(inst):
		inst.queue_free()
	_stack_children.erase(inst)
	if _stack_children.is_empty():
		_buttons.visible = true
		_resume_btn.grab_focus()
