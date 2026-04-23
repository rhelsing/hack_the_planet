extends Node
## Threaded scene loader with a progress UI.
## Call SceneLoader.goto("res://path.tscn") from anywhere.
##
## Handles the Godot 4.6 quirk where load_threaded_get_status's progress[0]
## can remain at 0 until THREAD_LOAD_LOADED on some backends (#56882, #90076).
## If progress hasn't advanced in STALL_THRESHOLD seconds we swap the UI from
## a determinate bar to an indeterminate spinner.

signal scene_entered(scene: Node)

const STALL_THRESHOLD := 0.25
const LOADER_UI_SCENE := "res://menu/scene_loader.tscn"
const TransitionScript := preload("res://menu/transitions/transition.gd")

var _target_path: String = ""
var _ui: Node = null
var _progress: Array[float] = [0.0]
var _last_progress_value: float = 0.0
var _last_progress_change_time: float = 0.0
var _transition: Transition = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


## Kick off a threaded load + show the loader UI. If already loading, noop.
## Also runs the user-selected Transition effect (glitch / instant) out of
## the old scene and back into the new one, so scene changes get a visual
## bookend rather than a hard cut.
func goto(path: String) -> void:
	if _target_path != "":
		push_warning("SceneLoader.goto called while already loading %s" % _target_path)
		return
	_target_path = path
	_progress = [0.0]
	_last_progress_value = 0.0
	_last_progress_change_time = Time.get_ticks_msec() / 1000.0
	# Create a Transition based on user Settings. If Settings isn't in the
	# tree yet (very early boot), we fall back to the default (glitch).
	var style := "glitch"
	var settings := get_tree().root.get_node_or_null(^"Settings")
	if settings != null and settings.has_method(&"get_value"):
		style = String(settings.call(&"get_value", "graphics", "transition_style", "glitch"))
	_transition = TransitionScript.from_style(style)
	await _transition.play_out(get_tree())
	_spawn_ui()
	ResourceLoader.load_threaded_request(path)
	set_process(true)


## Returns true when a load is in progress. Test hook.
func is_loading() -> bool:
	return _target_path != ""


func _process(_delta: float) -> void:
	var status := ResourceLoader.load_threaded_get_status(_target_path, _progress)
	_report_progress()
	match status:
		ResourceLoader.THREAD_LOAD_LOADED:
			_on_loaded()
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			push_error("SceneLoader failed to load: %s" % _target_path)
			_cleanup()


func _report_progress() -> void:
	var p: float = _progress[0] if _progress.size() > 0 else 0.0
	var now: float = Time.get_ticks_msec() / 1000.0
	if p != _last_progress_value:
		_last_progress_value = p
		_last_progress_change_time = now
	if _ui == null or not _ui.has_method(&"set_progress"):
		return
	var stalled: bool = (now - _last_progress_change_time) > STALL_THRESHOLD
	_ui.set_progress(p if not stalled else -1.0)


func _on_loaded() -> void:
	var packed := ResourceLoader.load_threaded_get(_target_path) as PackedScene
	if packed == null:
		push_error("SceneLoader: loaded resource is not a PackedScene: %s" % _target_path)
		_cleanup()
		return
	var tree := get_tree()
	tree.change_scene_to_packed(packed)
	await tree.process_frame
	scene_entered.emit(tree.current_scene)
	# Free the loader UI before the transition fades out — the UI shouldn't
	# flash visibly when the glitch pulls back. Transition sits on layer 2000,
	# UI on 1000, so UI being gone is safe.
	if _ui != null and is_instance_valid(_ui):
		_ui.queue_free()
	_ui = null
	if _transition != null:
		await _transition.play_in(tree)
		_transition = null
	_target_path = ""
	set_process(false)


func _cleanup() -> void:
	if _ui != null and is_instance_valid(_ui):
		_ui.queue_free()
	_ui = null
	_transition = null
	_target_path = ""
	set_process(false)


func _spawn_ui() -> void:
	if not ResourceLoader.exists(LOADER_UI_SCENE):
		# UI scene missing (headless test path). Continue without UI.
		return
	var packed: PackedScene = load(LOADER_UI_SCENE)
	if packed == null:
		return
	_ui = packed.instantiate()
	_ui.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(_ui)
