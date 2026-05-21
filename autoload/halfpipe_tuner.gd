extends Node

## Always-visible on-screen halfpipe tuner. Left-anchored, above PauseMenu
## (layer 101) so sliders are clickable while paused. Comment the autoload
## entry in project.godot to remove it entirely, or comment the
## _register_halfpipe_tuner() call in player_body.gd to leave it empty.
##
## All knobs here are read EXCLUSIVELY by code inside _update_halfpipe_stick
## and its dispatched pass methods, all gated on _on_halfpipe. Flat-ground
## / normal-skate movement is not affected by anything in this panel.
##
## Hotkeys (work during gameplay and pause):
##   7 → Current   8 → Kinematic   9 → Kinematic+Pump   0 → Centripetal

var _canvas: CanvasLayer
var _root_vbox: VBoxContainer
var _readouts: Array = []
# Pass-section state — rebuilt every time the user changes the active pass.
var _pass_label: Label = null
var _pass_description: Label = null
var _pass_body: VBoxContainer = null
# Pass spec registry. Each entry: { label, description, sliders: [ {name,min,max,step,getter,setter,desc} ] }
var _pass_specs: Dictionary = {}
var _pass_setter: Callable = Callable()
var _pass_getter: Callable = Callable()
# Hotkeys: top-row keys → pass index. Same order as the enum in player_body.
const _PASS_HOTKEYS := {
	KEY_7: 0,  # Current
	KEY_8: 1,  # Kinematic
	KEY_9: 2,  # Kinematic+Pump
	KEY_0: 3,  # Centripetal
}


## Master visibility. Set false to hide the panel without removing the
## autoload (which would break the parser since player_body.gd references
## HalfpipeTuner.* unconditionally in its registration function). Tuning
## is done as of 2026-05-20 — flip to true to bring the panel back.
@export var panel_visible: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	if _canvas != null:
		_canvas.visible = panel_visible


func _build_ui() -> void:
	_canvas = CanvasLayer.new()
	_canvas.layer = 101  # above PauseMenu (100) so sliders are clickable when paused
	# CRITICAL: same as PauseMenu's CanvasLayer — process_mode must be ALWAYS
	# explicitly. Inheriting it from the autoload Node was unreliable for
	# routing GUI input across the CanvasLayer boundary during pause.
	_canvas.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_canvas)

	var anchor := Control.new()
	anchor.process_mode = Node.PROCESS_MODE_ALWAYS
	anchor.anchor_left = 0.0
	anchor.anchor_right = 0.0
	anchor.anchor_top = 0.0
	anchor.anchor_bottom = 1.0
	anchor.offset_left = 10
	anchor.offset_right = 360
	anchor.offset_top = 10
	anchor.offset_bottom = -10
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(anchor)

	var panel := PanelContainer.new()
	panel.process_mode = Node.PROCESS_MODE_ALWAYS
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	anchor.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.process_mode = Node.PROCESS_MODE_ALWAYS
	panel.add_child(scroll)

	_root_vbox = VBoxContainer.new()
	_root_vbox.process_mode = Node.PROCESS_MODE_ALWAYS
	_root_vbox.custom_minimum_size = Vector2(330, 0)
	_root_vbox.add_theme_constant_override("separation", 4)
	scroll.add_child(_root_vbox)

	var title := Label.new()
	title.text = "Halfpipe Tuner   keys 7/8/9/0"
	title.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
	_root_vbox.add_child(title)


# ── Pass system ─────────────────────────────────────────────────────────

## Register the pass selector enum + a getter/setter for it. Wires the
## dropdown to the hotkey table and to the pass-section rebuild.
func register_pass_selector(options: PackedStringArray, getter: Callable, setter: Callable) -> void:
	_pass_getter = getter
	_pass_setter = setter

	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = "Pass"
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var option := OptionButton.new()
	for o in options:
		option.add_item(o)
	option.select(int(getter.call()))
	row.add_child(option)
	_root_vbox.add_child(row)

	option.item_selected.connect(func(idx: int) -> void:
		setter.call(idx)
		_rebuild_pass_section(idx)
	)
	# Remember the option button so hotkey presses can drive it.
	_pass_option_button = option

	# Pass label + description (rebuilt on swap).
	_pass_label = Label.new()
	_pass_label.add_theme_color_override("font_color", Color(0.7, 1.0, 0.9))
	_root_vbox.add_child(_pass_label)
	_pass_description = Label.new()
	_pass_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pass_description.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	_root_vbox.add_child(_pass_description)
	_pass_body = VBoxContainer.new()
	_pass_body.add_theme_constant_override("separation", 6)
	_root_vbox.add_child(_pass_body)


var _pass_option_button: OptionButton = null


## Register one pass's UI spec. Sliders is an Array of Dictionaries:
##   {"name": "stick_strength", "min": 0, "max": 300, "step": 5,
##    "getter": ..., "setter": ..., "desc": "Pull toward trough"}
func register_pass(idx: int, label: String, description: String, sliders: Array) -> void:
	_pass_specs[idx] = {"label": label, "description": description, "sliders": sliders}
	# If this is the currently active pass and the section hasn't been
	# built yet, build it now. Otherwise the swap happens on next change.
	if _pass_getter.is_valid() and int(_pass_getter.call()) == idx and _pass_body != null and _pass_body.get_child_count() == 0:
		_rebuild_pass_section(idx)


func _rebuild_pass_section(idx: int) -> void:
	if _pass_body == null:
		return
	for c in _pass_body.get_children():
		c.queue_free()
	if not _pass_specs.has(idx):
		_pass_label.text = ""
		_pass_description.text = ""
		return
	var spec: Dictionary = _pass_specs[idx]
	_pass_label.text = "▼ %s" % spec.label
	_pass_description.text = spec.description
	for slider_spec in spec.sliders:
		_add_pass_slider(slider_spec)


func _add_pass_slider(s: Dictionary) -> void:
	var initial: float = float(s.getter.call())
	var name_label := Label.new()
	name_label.text = "%s: %.3f" % [s.name, initial]
	_pass_body.add_child(name_label)
	if s.has("desc") and s.desc != "":
		var desc_label := Label.new()
		desc_label.text = "  %s" % s.desc
		desc_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_pass_body.add_child(desc_label)
	var slider := HSlider.new()
	slider.min_value = s.min
	slider.max_value = s.max
	slider.step = s.step
	slider.value = initial
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pass_body.add_child(slider)
	slider.value_changed.connect(func(v: float) -> void:
		name_label.text = "%s: %.3f" % [s.name, v]
		s.setter.call(v)
	)


# ── Always-on knobs (apply across passes) ───────────────────────────────

## Single-line key/value display, refreshed every frame.
func add_readout(label_text: String, getter: Callable) -> void:
	var lbl := Label.new()
	lbl.text = "%s: %s" % [label_text, str(getter.call())]
	_root_vbox.add_child(lbl)
	_readouts.append({"label": lbl, "name": label_text, "getter": getter})


## Slider shown below the pass section — applies to all passes.
func add_shared_slider(name: String, min_v: float, max_v: float, step: float, getter: Callable, setter: Callable, desc: String = "") -> void:
	var initial: float = float(getter.call())
	var name_label := Label.new()
	name_label.text = "%s: %.3f" % [name, initial]
	_root_vbox.add_child(name_label)
	if desc != "":
		var desc_label := Label.new()
		desc_label.text = "  %s" % desc
		desc_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_root_vbox.add_child(desc_label)
	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.value = initial
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root_vbox.add_child(slider)
	slider.value_changed.connect(func(v: float) -> void:
		name_label.text = "%s: %.3f" % [name, v]
		setter.call(v)
	)


func add_section_header(text: String) -> void:
	var hdr := Label.new()
	hdr.text = text
	hdr.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5))
	_root_vbox.add_child(hdr)


func _process(_delta: float) -> void:
	for r in _readouts:
		r.label.text = "%s: %s" % [r.name, str(r.getter.call())]


func _unhandled_input(event: InputEvent) -> void:
	# Top-row hotkeys for Pass switching. process_mode = ALWAYS means we
	# still receive input during pause.
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event
	if not key.pressed or key.echo:
		return
	if not _PASS_HOTKEYS.has(key.keycode):
		return
	if _pass_option_button == null or not _pass_setter.is_valid():
		return
	var idx: int = _PASS_HOTKEYS[key.keycode]
	if idx >= _pass_option_button.item_count:
		return
	_pass_option_button.select(idx)
	_pass_setter.call(idx)
	_rebuild_pass_section(idx)
	get_viewport().set_input_as_handled()
