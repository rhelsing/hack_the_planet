extends Node

## Puzzles autoload. Instantiates puzzle scenes, awaits their finished signal,
## drives pause + modal coordination, emits lifecycle on Events.
## See docs/interactables.md §11 + sync_up.md ui_dev coordination.
##
## Modal pairing invariant (sync_up.md, ui_dev concern): _active is set to
## true BEFORE any await and reset BEFORE emitting modal_closed — so
## PauseController can synchronously query is_active() during input handling.
## modal_closed emits from the one path that can't miss (puzzle's finished
## signal fires before queue_free, and we await explicitly).

const MODAL_ID: StringName = &"puzzle"

var _active: bool = false
var _active_id: StringName = &""


func is_active() -> bool:
	return _active


func _ready() -> void:
	# Scene-change safety: ui_dev's SceneLoader may emit a pre-change signal.
	# Force-close any in-flight puzzle so we don't leak pause state.
	var loader: Node = get_node_or_null(^"/root/SceneLoader")
	if loader != null and loader.has_signal(&"scene_changing"):
		loader.connect(&"scene_changing", force_close)


## Force-close the active puzzle from outside (scene-change, error recovery).
## Treats as failure — fires puzzle_failed, not puzzle_solved.
func force_close() -> void:
	if not _active: return
	# Find the live puzzle instance and queue_free it so its `finished` await
	# resolves deterministically. But since we're outside the await chain,
	# we emit the closing signals ourselves and mark state clean.
	var instance := _find_puzzle_instance()
	if instance != null:
		instance.queue_free()
	get_tree().paused = false
	_capture_player_mouse(true)
	Events.modal_closed.emit(MODAL_ID)
	Events.puzzle_failed.emit(_active_id)
	_active = false
	_active_id = &""


func _find_puzzle_instance() -> Node:
	for c: Node in get_tree().root.get_children():
		if c is CanvasLayer and c.has_signal(&"finished"):
			return c
	return null


func start(puzzle_scene: PackedScene, puzzle_id: StringName = &"") -> void:
	if _active:
		push_warning("Puzzles.start ignored — a puzzle is already active: %s" % _active_id)
		return
	if puzzle_scene == null:
		push_warning("Puzzles.start called with null puzzle_scene")
		return

	# Invariant: flip state BEFORE emit + pause, so synchronous consumers
	# (PauseController._unhandled_input) see a consistent world.
	_active = true
	_active_id = puzzle_id

	Events.puzzle_started.emit(_active_id)
	Events.modal_opened.emit(MODAL_ID)
	get_tree().paused = true

	var instance: Node = puzzle_scene.instantiate()
	# Duck-check instead of `is Puzzle` — class_name lookup is fragile from
	# an autoload's parse time. Anything with a `finished` signal works.
	if not instance.has_signal(&"finished"):
		push_error("Puzzles.start: scene root must emit `finished(success)`, got %s" % instance.get_class())
		_reset_on_error(instance)
		return

	# Pause the player's mouse capture (cursor needed for UI if any).
	_capture_player_mouse(false)

	get_tree().root.add_child(instance)
	# `await signal` with a single-arg signal returns that arg directly.
	var success: bool = await instance.finished

	# Close pair — emit before flipping _active so consumers can query _active_id still.
	get_tree().paused = false
	_capture_player_mouse(true)
	Events.modal_closed.emit(MODAL_ID)
	if success:
		Events.puzzle_solved.emit(_active_id)
	else:
		Events.puzzle_failed.emit(_active_id)

	_active = false
	_active_id = &""


func _reset_on_error(instance: Variant) -> void:
	get_tree().paused = false
	Events.modal_closed.emit(MODAL_ID)
	_active = false
	_active_id = &""
	if instance != null and instance is Node:
		(instance as Node).queue_free()


## Finds PlayerBrain by group (char_dev exposes the "player_brain" group)
## and toggles mouse capture. Silent no-op if brain isn't present yet —
## puzzles still work, just no cursor swap.
func _capture_player_mouse(on: bool) -> void:
	var brain := get_tree().get_first_node_in_group(&"player_brain")
	if brain != null and brain.has_method(&"capture_mouse"):
		brain.capture_mouse(on)
