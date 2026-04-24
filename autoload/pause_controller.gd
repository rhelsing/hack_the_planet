extends Node
## Owns pause state and the global Esc/Start listener. The pause menu scene
## (child of game.tscn) shows/hides itself by connecting to `paused_changed`.
##
## Per sync_up 2026-04-22: dialogue and puzzle autoloads call
## `get_tree().paused = true` *directly* from their own start/finish methods;
## this controller does NOT gate their pause calls. Our only coordination
## surface is `user_pause_allowed` (set false by dialogue/puzzle while their
## own modal is open), which suppresses the user-triggered pause menu from
## layering on top of a dialogue balloon.

signal paused_changed(is_paused: bool)

## Dialogue/puzzle autoloads flip this false while their modal is open so Esc
## does not layer a pause menu on top of them. Pause menu itself respects this
## via its show/hide logic.
var user_pause_allowed: bool = true

## Counter-pattern storage for modal stack signals (see events.gd). Anything
## that wants to know "is *any* modal up?" reads `modal_count > 0`. Debug
## panel can call `Events.modal_count_reset.emit()` to zero the counter if a
## bad unpair leaves it stuck. Exposed here as the single source of truth.
var modal_count: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Events.modal_opened.connect(_on_modal_opened)
	Events.modal_closed.connect(_on_modal_closed)
	Events.modal_count_reset.connect(_on_modal_count_reset)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"pause"):
		return
	if not user_pause_allowed:
		return
	if _is_dialogue_open() or _is_puzzle_active():
		return
	# Don't pause from the main menu / save-slots / credits — those scenes
	# have no PauseMenu instance to show, so pausing there just freezes the
	# tree with nothing to un-pause it cleanly.
	if _is_in_menu_scene():
		return
	toggle()
	get_viewport().set_input_as_handled()


func toggle() -> void:
	set_paused(not get_tree().paused)


func set_paused(v: bool) -> void:
	if get_tree().paused == v:
		return
	get_tree().paused = v
	paused_changed.emit(v)
	if v:
		Events.menu_opened.emit(&"pause")
		Events.modal_opened.emit(&"pause")
	else:
		Events.menu_closed.emit(&"pause")
		Events.modal_closed.emit(&"pause")


## Returns true when any modal is up (dialogue, puzzle, pause menu, etc.).
## Used by HUD / PromptUI to know "hide me."
func is_any_modal_open() -> bool:
	return modal_count > 0


func _on_modal_opened(_id: StringName) -> void:
	modal_count += 1


func _on_modal_closed(_id: StringName) -> void:
	modal_count = maxi(modal_count - 1, 0)


func _on_modal_count_reset() -> void:
	modal_count = 0


# Guard: these autoloads may not exist yet (interactables_dev hasn't shipped
# them). Return false until they do.
func _is_dialogue_open() -> bool:
	var d := get_tree().root.get_node_or_null(^"Dialogue")
	if d == null:
		return false
	if not d.has_method(&"is_open"):
		return false
	return d.call(&"is_open")


func _is_puzzle_active() -> bool:
	var p := get_tree().root.get_node_or_null(^"Puzzles")
	if p == null:
		return false
	if not p.has_method(&"is_active"):
		return false
	return p.call(&"is_active")


## True when the current scene lives under res://menu/ (main menu, save
## slots, settings, credits, scene loader). Pause is suppressed there.
func _is_in_menu_scene() -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		return true  # no scene = don't pause
	var sf: String = scene.scene_file_path
	return sf.begins_with("res://menu/")
