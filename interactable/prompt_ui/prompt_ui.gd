extends CanvasLayer

## Sibling CanvasLayer in game.tscn (matches the ControlsHint pattern).
## Shows "[E] verb" while an Interactable is focused AND no modal is up
## (dialogue / puzzle / pause menu). Also shows a "(locked)" suffix for
## gated interactables and flashes a toast notice on failed activation.
##
## Discovery: sensor joins the "interaction_sensor" group at _ready; we find
## it lazily on first focus. Modal state is a counter driven by Events.
## See docs/interactables.md §12.1.

@export var glyph_keyboard: String = "E"
@export var glyph_gamepad: String = "X"
@export var toast_duration_s: float = 2.5

var _sensor: Node = null  # InteractionSensor, found lazily by group
var _focused: Interactable = null
var _modal_count: int = 0

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


func _on_modal_opened(_id: StringName) -> void:
	_modal_count += 1
	_refresh()


func _on_modal_closed(_id: StringName) -> void:
	_modal_count = maxi(_modal_count - 1, 0)
	_refresh()


func _on_modal_reset() -> void:
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
	var should_show := _focused != null and _modal_count == 0
	_label.visible = should_show
	if not should_show:
		_label.text = ""
		return
	var glyph := _pick_glyph()
	var suffix: String = "  (locked)" if _focused.is_locked() else ""
	_label.text = "[%s] %s%s" % [glyph, _focused.prompt_verb, suffix]


## Reads last input device from PlayerBrain if available. Has_method safety
## net until char_dev Patch A exposes `last_device: String`. Falls back to
## keyboard.
func _pick_glyph() -> String:
	var brain := get_tree().get_first_node_in_group(&"player_brain")
	if brain != null and "last_device" in brain:
		if brain.last_device == "gamepad":
			return glyph_gamepad
	return glyph_keyboard
