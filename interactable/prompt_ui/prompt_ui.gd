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

# Authored sizes at hud.scale = 1.0. Multiplied by Settings.get_hud_scale()
# in _apply_hud_scale (called at _ready and on Events.settings_applied so
# the slider takes effect live). Mirrors walkie_ui's scaling pattern.
const _PROMPT_FONT_BASE: int = 24
const _TOAST_FONT_BASE: int = 20
const _PROMPT_PANEL_MIN_WIDTH_BASE: float = 220.0
const _TOAST_PANEL_MIN_WIDTH_BASE: float = 260.0

@onready var _label: Label = $Root/PromptCenter/PromptPanel/PromptLabel
@onready var _toast: Label = $Root/ToastCenter/ToastPanel/ToastLabel
@onready var _prompt_panel: PanelContainer = $Root/PromptCenter/PromptPanel
@onready var _toast_panel: PanelContainer = $Root/ToastCenter/ToastPanel
@onready var _toast_timer: Timer = _build_toast_timer()

# Hold-progress bar built lazily on first set_hold_progress call. Reused
# by any Interactable that wants a "hold to confirm" affordance — see
# stealth_kill_target.gd. Mirrors the cutscene-skip bar's shape but
# sized 200% (440×12) and white-on-translucent for legibility against
# the dark prompt panel directly above it.
var _hold_bar_center: CenterContainer = null
var _hold_bar: CircularProgress = null
var _hold_bar_label: Label = null
## Caller-overridable hint text. `{glyph}` is replaced with the current
## device-correct interact glyph (E / △ / etc.). Use {} to access via the
## Glyphs autoload at refresh time.
var _hold_bar_hint: String = "Hold {glyph} to hack"


func _ready() -> void:
	add_to_group(&"prompt_ui")
	layer = 1  # Above HUD (0), below dialogue/puzzle (10) and pause (100)
	if _label == null:
		push_error("PromptLabel not found at Root/PromptCenter/PromptPanel/PromptLabel in prompt_ui.tscn")
		return
	_label.text = ""
	_prompt_panel.visible = false
	_toast.text = ""
	_toast_panel.visible = false

	Events.modal_opened.connect(_on_modal_opened)
	Events.modal_closed.connect(_on_modal_closed)
	Events.modal_count_reset.connect(_on_modal_reset)

	# HUD scale: font sizes + panel widths read from a single Settings.hud.scale
	# knob. Live-updates via settings_applied so the slider takes effect even
	# while a prompt is on screen.
	Events.settings_applied.connect(_apply_hud_scale)
	_apply_hud_scale()

	# Sensor may or may not exist yet depending on scene load order. Poll
	# once here; if not found, connect lazily on first _process tick.
	_try_connect_sensor()


func _apply_hud_scale() -> void:
	var s: float = Settings.get_hud_scale()
	_label.add_theme_font_size_override(&"font_size", int(_PROMPT_FONT_BASE * s))
	_toast.add_theme_font_size_override(&"font_size", int(_TOAST_FONT_BASE * s))
	_prompt_panel.custom_minimum_size = Vector2(_PROMPT_PANEL_MIN_WIDTH_BASE * s, 0)
	_toast_panel.custom_minimum_size = Vector2(_TOAST_PANEL_MIN_WIDTH_BASE * s, 0)


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
	_toast_panel.visible = true
	_toast_timer.start()


func _hide_toast() -> void:
	_toast_panel.visible = false
	_toast.text = ""


func _refresh() -> void:
	# `_focused != null` returns true for freed objects in GDScript 4 —
	# defend against the dangling ref with is_instance_valid.
	var focus_alive: bool = _focused != null and is_instance_valid(_focused)
	if not focus_alive:
		_focused = null
	var should_show := _focused != null and _modal_count == 0
	_prompt_panel.visible = should_show
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


# ── Hold-progress bar ────────────────────────────────────────────────────
# Public driver: any Interactable that wants a "hold to confirm" affordance
# (currently StealthKillTarget) calls this each tick with progress 0..1.
# v == 0 hides the bar; v > 0 shows it. The bar is built lazily on first
# call so the load-time cost is paid only when needed.
func set_hold_progress(progress: float, hint: String = "") -> void:
	progress = clampf(progress, 0.0, 1.0)
	_ensure_hold_bar()
	if hint != "":
		_hold_bar_hint = hint
	_hold_bar.value = progress
	# Re-stamp the label every call so a controller swap mid-hold updates
	# the glyph live (matches the powerup-pill device-swap pattern).
	var glyph: String = Glyphs.for_action("interact")
	_hold_bar_label.text = _hold_bar_hint.replace("{glyph}", glyph)
	_hold_bar_center.visible = progress > 0.0


func _ensure_hold_bar() -> void:
	if _hold_bar != null and is_instance_valid(_hold_bar):
		return
	# Mount above the prompt panel so the label + bar pair reads as one
	# unit ABOVE the existing "[E] hack" prompt. Prompt sits at offset
	# -100..-32 from bottom; we sit from -190..-110 (80px tall window for
	# the VBox containing label + bar + spacing).
	_hold_bar_center = CenterContainer.new()
	_hold_bar_center.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_hold_bar_center.offset_top = -190.0
	_hold_bar_center.offset_bottom = -110.0
	_hold_bar_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	$Root.add_child(_hold_bar_center)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override(&"separation", 8)
	box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_hold_bar_center.add_child(box)

	_hold_bar_label = Label.new()
	_hold_bar_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hold_bar_label.add_theme_font_size_override(&"font_size", int(20 * Settings.get_hud_scale()))
	_hold_bar_label.add_theme_color_override(&"font_color", Color(1, 1, 1, 1))
	_hold_bar_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.85))
	_hold_bar_label.add_theme_constant_override(&"outline_size", 4)
	_hold_bar_label.text = "Hold E to hack"
	box.add_child(_hold_bar_label)

	_hold_bar = CircularProgress.new()
	# Sized for ~80px ring diameter at 1× HUD scale, halo blooming to ~120px.
	# Easy to spot above the prompt panel without dominating the screen.
	_hold_bar.radius = 36.0 * Settings.get_hud_scale()
	_hold_bar.thickness = 9.0 * Settings.get_hud_scale()
	box.add_child(_hold_bar)
	_hold_bar_center.visible = false
