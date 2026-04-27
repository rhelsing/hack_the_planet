extends Node
## Main menu scene. Hosts:
##   - MenuWorld (3D fly-through)
##   - MenuUI CanvasLayer (title + VBox of MenuButtons + MenuStack)
##
## Sub-menus (settings, save_slots, credits) are pushed into MenuStack as
## child scenes. The main button column is a direct child of the stack's
## root so it's popped/hidden the same way.

const SETTINGS_MENU := "res://menu/settings_menu.tscn"
const SAVE_SLOTS    := "res://menu/save_slots.tscn"
const CREDITS       := "res://menu/credits.tscn"
const GAME_SCENE    := "res://game.tscn"
## Intro cinematic shown only on New Game (not Continue / Load). Plays
## after the slot is picked, before the SceneLoader transitions in.
const INTRO_VIDEO_PATH := "res://cutscenes/intro_movie.ogv"
## Menu background music. Swap for any of the imported tracks under
## audio/music/ — size_of_life_*.mp3, song1/2, disco_music, etc. — to taste.
const MENU_MUSIC_PATH := "res://audio/music/hackers_theme.mp3"

@onready var _buttons_root: Control = %ButtonsRoot
@onready var _continue_btn: Button  = %ContinueBtn
@onready var _new_btn:      Button  = %NewGameBtn
@onready var _load_btn:     Button  = %LoadBtn
@onready var _settings_btn: Button  = %SettingsBtn
@onready var _credits_btn:  Button  = %CreditsBtn
@onready var _quit_btn:     Button  = %QuitBtn
@onready var _stack:        Control = %MenuStack
@onready var _title:        Label   = %Title

var _stack_children: Array[Node] = []
var _go_to_game_after_pick: bool = false


func _ready() -> void:
	Events.menu_opened.emit(&"main_menu")
	_wire_buttons()
	_refresh_continue_state()
	_title.text = "HACK THE PLANET"
	_continue_btn.grab_focus()
	_start_menu_music()
	# Re-check continue state if a save gets written while we're on the menu.
	Events.game_saved.connect(func(_slot: StringName) -> void:
		_refresh_continue_state()
	)


func _start_menu_music() -> void:
	# Audio autoload owns playback; guarded for the --script test mode.
	var audio := get_tree().root.get_node_or_null(^"Audio")
	if audio == null or not audio.has_method(&"play_music"):
		return
	if not ResourceLoader.exists(MENU_MUSIC_PATH):
		return
	var stream := load(MENU_MUSIC_PATH)
	audio.call(&"play_music", stream, 1.5)


func _wire_buttons() -> void:
	_continue_btn.pressed.connect(_on_continue)
	_new_btn.pressed.connect(_on_new_game)
	_load_btn.pressed.connect(_on_load)
	_settings_btn.pressed.connect(_on_settings)
	_credits_btn.pressed.connect(_on_credits)
	_quit_btn.pressed.connect(_on_quit)


func _refresh_continue_state() -> void:
	var save_service := get_tree().root.get_node_or_null(^"SaveService")
	var has_save := false
	if save_service != null and save_service.has_method(&"has_any_slot"):
		has_save = save_service.call(&"has_any_slot")
	_continue_btn.disabled = not has_save
	_continue_btn.label = "Continue" if has_save else "Continue [No save found]"


# ── Button handlers ──────────────────────────────────────────────────────

func _on_continue() -> void:
	var save_service := get_tree().root.get_node_or_null(^"SaveService")
	if save_service == null:
		_go_to_game()
		return
	var slot: StringName = save_service.call(&"most_recent_slot")
	if String(slot).is_empty():
		_go_to_game()
	else:
		save_service.call(&"load_from_slot", slot)


func _on_new_game() -> void:
	# Player picks A/B/C first. save_slots.begin_new_game() resets GameState,
	# writes the initial slot file, and sets active_slot. We follow up with
	# a scene change once the picker pops.
	_go_to_game_after_pick = true
	_push_sub_menu(SAVE_SLOTS, {"mode": "new"})


func _on_load() -> void:
	_push_sub_menu(SAVE_SLOTS, {"mode": "load"})


func _on_settings() -> void:
	_push_sub_menu(SETTINGS_MENU, {})


func _on_credits() -> void:
	_push_sub_menu(CREDITS, {})


func _on_quit() -> void:
	get_tree().quit()


# ── Stack management ────────────────────────────────────────────────────

func _push_sub_menu(path: String, args: Dictionary) -> void:
	print("[main_menu] _push_sub_menu %s args=%s" % [path, args])
	if not ResourceLoader.exists(path):
		push_warning("Main menu: sub-menu missing: %s" % path)
		return
	var packed: PackedScene = load(path)
	var inst := packed.instantiate()
	if inst.has_method(&"configure"):
		inst.call(&"configure", args)
	if inst.has_signal(&"back_requested"):
		inst.connect(&"back_requested", _pop_sub_menu.bind(inst), CONNECT_ONE_SHOT)
	_stack.add_child(inst)
	_stack_children.append(inst)
	_buttons_root.visible = false


func _pop_sub_menu(inst: Node) -> void:
	print("[main_menu] _pop_sub_menu: go_to_game_after_pick=%s" % _go_to_game_after_pick)
	if is_instance_valid(inst):
		inst.queue_free()
	_stack_children.erase(inst)
	if _stack_children.is_empty():
		_buttons_root.visible = true
		_continue_btn.grab_focus()
		# New Game → slot picker → player chose → go to game.
		if _go_to_game_after_pick:
			_go_to_game_after_pick = false
			var ss := get_tree().root.get_node_or_null(^"SaveService")
			var has_slot: bool = ss != null and bool(ss.call(&"has_active_slot"))
			print("[main_menu] after pick: SaveService=%s has_active_slot=%s" % [ss, has_slot])
			if has_slot:
				print("[main_menu] calling _go_to_game(show_intro=true)")
				_go_to_game(true)


func _go_to_game(show_intro: bool = false) -> void:
	print("[main_menu] _go_to_game → %s show_intro=%s" % [GAME_SCENE, show_intro])
	# New Game only: play the intro cinematic before the loading sequence.
	# Cutscene.show_video pauses music + ambience for the duration and resumes
	# them on its own. Awaits naturally to the video's end via `finished`.
	if show_intro and ResourceLoader.exists(INTRO_VIDEO_PATH):
		var cs := get_tree().root.get_node_or_null(^"Cutscene")
		if cs != null and cs.has_method(&"show_video"):
			await cs.call(&"show_video", INTRO_VIDEO_PATH, -1.0)
	var sl := get_tree().root.get_node_or_null(^"SceneLoader")
	if sl != null and sl.has_method(&"goto"):
		print("[main_menu] using SceneLoader.goto")
		sl.call(&"goto", GAME_SCENE)
	else:
		print("[main_menu] SceneLoader missing — falling back to change_scene_to_file")
		get_tree().change_scene_to_file(GAME_SCENE)
