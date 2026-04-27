extends CanvasLayer

## Sibling CanvasLayer in game.tscn (matches the ControlsHint pattern).
## Shows "[E] verb" while an Interactable is focused AND no modal is up
## (dialogue / puzzle / pause menu). Also shows a "(locked)" suffix for
## gated interactables and flashes a toast notice on failed activation.
##
## Discovery: sensor joins the "interaction_sensor" group at _ready; we find
## it lazily on first focus. Modal state is a counter driven by Events.
## See docs/interactables.md §12.1.

## Action name that the prompt's bracketed glyph represents. Resolved at draw
## time via Glyphs.for_action(action_name) so the keyboard/gamepad mapping
## stays in sync with the canonical Glyphs dictionary — no per-prompt overrides.
@export var action_name: String = "interact"
@export var toast_duration_s: float = 2.5

var _sensor: Node = null  # InteractionSensor, found lazily by group
var _focused: Interactable = null
var _modal_count: int = 0
# Dedupe state — only log on transition, not every refresh.
var _last_logged_visible: int = -1  # -1 unknown, 0 hidden, 1 visible
var _last_logged_focus: String = "<unset>"

@onready var _label: Label = $Root/PromptLabel
@onready var _toast: Label = $Root/ToastLabel
@onready var _toast_timer: Timer = _build_toast_timer()


func _ready() -> void:
	layer = 1  # Above HUD (0), below dialogue/puzzle (10) and pause (100)
	if _label == null:
		push_error("PromptLabel not found at Root/PromptLabel in prompt_ui.tscn")
		return
	_label.text = ""
	_label.visible = false
	_toast.text = ""
	_toast.visible = false

	Events.modal_opened.connect(_on_modal_opened)
	Events.modal_closed.connect(_on_modal_closed)
	Events.modal_count_reset.connect(_on_modal_reset)

	# Sensor may or may not exist yet depending on scene load order. Poll
	# once here; if not found, connect lazily on first _process tick.
	_try_connect_sensor()


func _process(_delta: float) -> void:
	if _sensor == null:
		_try_connect_sensor()
		return
	# If the focused interactable was freed out from under us (e.g., a pickup
	# that queue_freed itself on interact), the dangling ref won't trip the
	# normal `_focused != null` check in Godot 4. Refresh so the label clears.
	if _focused != null and not is_instance_valid(_focused):
		_focused = null
		_refresh()
	elif _focused != null:
		# Gate state can change (key picked up, flag set) without focus
		# transitioning. Cheap refresh keeps the "(locked)" suffix accurate.
		_refresh()


func _try_connect_sensor() -> void:
	var s := get_tree().get_first_node_in_group(&"interaction_sensor")
	if s == null: return
	_sensor = s
	s.focus_changed.connect(_on_focus_changed)
	if s.has_signal(&"locked"):
		s.locked.connect(_on_locked)
	# Pick up current focus in case it was set before we connected.
	_on_focus_changed(s.focused)


func _build_toast_timer() -> Timer:
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = toast_duration_s
	t.timeout.connect(_hide_toast)
	add_child(t)
	return t


func _on_focus_changed(focused: Interactable) -> void:
	_focused = focused
	_refresh()


func _on_modal_opened(id: StringName) -> void:
	_modal_count += 1
	print("[prompt] modal_opened %s -> count=%d" % [id, _modal_count])
	_refresh()


func _on_modal_closed(id: StringName) -> void:
	_modal_count = maxi(_modal_count - 1, 0)
	print("[prompt] modal_closed %s -> count=%d" % [id, _modal_count])
	_refresh()


func _on_modal_reset() -> void:
	print("[prompt] modal_reset (was %d)" % _modal_count)
	_modal_count = 0
	_refresh()


func _on_locked(_it: Interactable, reason: String) -> void:
	_toast.text = reason
	_toast.visible = true
	_toast_timer.start()


func _hide_toast() -> void:
	_toast.visible = false
	_toast.text = ""


func _refresh() -> void:
	# `_focused != null` returns true for freed objects in GDScript 4 —
	# defend against the dangling ref with is_instance_valid.
	var focus_alive: bool = _focused != null and is_instance_valid(_focused)
	if not focus_alive:
		_focused = null
	var should_show := _focused != null and _modal_count == 0
	_label.visible = should_show
	# Dedupe: only log on visibility OR focus transitions.
	var focus_str: String = _focused.name if _focused != null else "<null>"
	var vis_int: int = 1 if should_show else 0
	if vis_int != _last_logged_visible or focus_str != _last_logged_focus:
		_last_logged_visible = vis_int
		_last_logged_focus = focus_str
		print("[prompt] refresh visible=%s focus=%s modal_count=%d" % [
			should_show, focus_str, _modal_count])
	if not should_show:
		_label.text = ""
		return
	var glyph := _pick_glyph()
	var suffix: String = "  (locked)" if _focused.is_locked() else ""
	_label.text = "[%s] %s%s" % [glyph, _focused.prompt_verb, suffix]


## Resolves the bracketed glyph from the canonical Glyphs autoload. One source
## of truth for keyboard vs gamepad labels — same dict that drives Glyphs.format()
## for hint zones and voice line templates.
func _pick_glyph() -> String:
	return Glyphs.for_action(action_name)
