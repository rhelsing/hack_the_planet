class_name Puzzle
extends CanvasLayer

## Base class for mini-puzzle minigames. Subclasses call _complete(success)
## to resolve. The Puzzles autoload (owner of pause lifecycle) awaits the
## `finished` signal and emits the matching Events broadcast.
## See docs/interactables.md §11.1.

signal finished(success: bool)


func _ready() -> void:
	# Puzzles run while the tree is paused (Puzzles.start flips get_tree().paused).
	# Subclasses inherit this unless they explicitly override process_mode.
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	# Sit above HUD/PromptUI, below pause menu (see CanvasLayer z-order §12).
	layer = 10


## Player can always bail with ui_cancel (Esc / gamepad B). Consume the input
## before PauseController sees it so pause menu doesn't also open.
##
## Subclasses that want to override input handling should either call super
## or re-implement this cancel path.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		_complete(false)


## Subclasses call this when the puzzle resolves. Emits the signal and
## self-frees after the current frame so any async callers can read state.
func _complete(success: bool) -> void:
	finished.emit(success)
	queue_free()
