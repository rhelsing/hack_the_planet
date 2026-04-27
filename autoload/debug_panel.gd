extends Node

const CONFIG_PATH := "user://debug_panel.cfg"
const CONFIG_VERSION := 3

var _canvas: CanvasLayer
var _root_vbox: VBoxContainer
var _sections: Dictionary = {}
var _controls: Dictionary = {}
# Initial value at registration time, keyed by path. Used by the "Copy diff"
# button to show only what's been tweaked away from @export defaults.
var _defaults: Dictionary = {}
# Optional filename callers pass with each add_*; appended to diff lines as
# `# source.gd` so you know where to update the @export default.
var _sources: Dictionary = {}
var _readouts: Array[Dictionary] = []
var _config := ConfigFile.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_config.load(CONFIG_PATH)
	# Slider/toggle/enum *values* are intentionally not persisted — the panel
	# only tunes during a session, then resets to @export defaults next run.
	# Wipe any stale values from older builds that did persist them.
	if _config.has_section("values"):
		_config.erase_section("values")
		_config.save(CONFIG_PATH)
	var saved_version: int = int(_config.get_value("_meta", "version", 1))
	if saved_version < CONFIG_VERSION:
		if _config.has_section("sections"):
			_config.erase_section("sections")
		_config.set_value("_meta", "version", CONFIG_VERSION)
		_config.save(CONFIG_PATH)
	_build_ui()


func _build_ui() -> void:
	_canvas = CanvasLayer.new()
	_canvas.layer = 100
	add_child(_canvas)

	var anchor := Control.new()
	anchor.anchor_left = 1.0
	anchor.anchor_right = 1.0
	anchor.anchor_top = 0.0
	anchor.anchor_bottom = 1.0
	anchor.offset_left = -400
	anchor.offset_right = -10
	anchor.offset_top = 10
	anchor.offset_bottom = -10
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(anchor)

	var panel := PanelContainer.new()
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	anchor.add_child(panel)

	var scroll := ScrollContainer.new()
	panel.add_child(scroll)

	_root_vbox = VBoxContainer.new()
	_root_vbox.custom_minimum_size = Vector2(360, 0)
	_root_vbox.add_theme_constant_override("separation", 2)
	scroll.add_child(_root_vbox)

	var title := Label.new()
	title.text = "Debug Panel  (` to toggle)"
	_root_vbox.add_child(title)

	var copy_btn := Button.new()
	copy_btn.text = "Copy diff to clipboard"
	_root_vbox.add_child(copy_btn)
	copy_btn.pressed.connect(func() -> void:
		var diff: String = _build_diff_text()
		DisplayServer.clipboard_set(diff)
		copy_btn.text = "Copied!" if diff.length() > 0 else "(no diff — defaults)"
		await get_tree().create_timer(1.2).timeout
		copy_btn.text = "Copy diff to clipboard"
	)

	_canvas.visible = false


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_QUOTELEFT:
			_canvas.visible = not _canvas.visible
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _canvas.visible else Input.MOUSE_MODE_CAPTURED
			get_viewport().set_input_as_handled()


func _process(_dt: float) -> void:
	if not _canvas.visible:
		return
	for r in _readouts:
		r.label.text = "%s: %s" % [r.name, str(r.getter.call())]


func _get_or_create_section(section_parts: PackedStringArray) -> VBoxContainer:
	var current_parent: VBoxContainer = _root_vbox
	var accum := ""
	for part in section_parts:
		accum = part if accum.is_empty() else accum + "/" + part
		if _sections.has(accum):
			current_parent = _sections[accum]
			continue
		var expanded: bool = _config.get_value("sections", accum, false)
		var header := Button.new()
		header.alignment = HORIZONTAL_ALIGNMENT_LEFT
		header.toggle_mode = true
		header.button_pressed = expanded
		header.text = _header_text(part, expanded)
		current_parent.add_child(header)

		var row := HBoxContainer.new()
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(10, 0)
		row.add_child(spacer)
		var body := VBoxContainer.new()
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.add_theme_constant_override("separation", 2)
		body.visible = expanded
		row.add_child(body)
		current_parent.add_child(row)

		var path := accum
		var part_name := part
		header.toggled.connect(func(pressed: bool) -> void:
			body.visible = pressed
			header.text = _header_text(part_name, pressed)
			_config.set_value("sections", path, pressed)
			_config.save(CONFIG_PATH)
		)

		_sections[accum] = body
		current_parent = body
	return current_parent


func _header_text(label: String, expanded: bool) -> String:
	return ("▼ " if expanded else "▶ ") + label


func _split_path(path: String) -> Array:
	var parts := path.split("/")
	var leaf: String = parts[parts.size() - 1]
	var section_parts := PackedStringArray()
	for i in range(parts.size() - 1):
		section_parts.append(parts[i])
	return [section_parts, leaf]


func _warn_duplicate(path: String) -> bool:
	if _controls.has(path):
		push_warning("DebugPanel: path '%s' already registered, skipping" % path)
		return true
	return false


# True only after _ready has built the UI. Headless test runs (SceneTree
# scripts) instantiate autoloads but skip _ready, so callers can hit add_*
# before we're set up — silently no-op rather than null-deref.
func _ui_ready() -> bool:
	return _root_vbox != null


func add_slider(path: String, min_v: float, max_v: float, step: float, getter: Callable, setter: Callable, source: String = "") -> void:
	if not _ui_ready(): return
	if _warn_duplicate(path): return
	var sp := _split_path(path)
	var parent := _get_or_create_section(sp[0])
	var leaf: String = sp[1]

	var initial: float = float(getter.call())

	var label := Label.new()
	label.text = "%s: %.3f" % [leaf, initial]
	parent.add_child(label)
	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.value = initial
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(slider)
	slider.value_changed.connect(func(v: float) -> void:
		label.text = "%s: %.3f" % [leaf, v]
		setter.call(v)
	)
	_controls[path] = slider
	_defaults[path] = initial
	if source != "":
		_sources[path] = source


func add_toggle(path: String, getter: Callable, setter: Callable, source: String = "") -> void:
	if not _ui_ready(): return
	if _warn_duplicate(path): return
	var sp := _split_path(path)
	var parent := _get_or_create_section(sp[0])
	var leaf: String = sp[1]

	var initial: bool = bool(getter.call())

	var check := CheckBox.new()
	check.text = leaf
	check.button_pressed = initial
	parent.add_child(check)
	check.toggled.connect(func(pressed: bool) -> void:
		setter.call(pressed)
	)
	_controls[path] = check
	_defaults[path] = initial
	if source != "":
		_sources[path] = source


func add_enum(path: String, options: PackedStringArray, getter: Callable, setter: Callable, source: String = "") -> void:
	if not _ui_ready(): return
	if _warn_duplicate(path): return
	var sp := _split_path(path)
	var parent := _get_or_create_section(sp[0])
	var leaf: String = sp[1]

	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = leaf
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var option := OptionButton.new()
	for o in options:
		option.add_item(o)
	var initial: int = int(getter.call())
	option.select(initial)
	row.add_child(option)
	parent.add_child(row)

	option.item_selected.connect(func(idx: int) -> void:
		setter.call(idx)
	)
	_controls[path] = option
	_defaults[path] = initial
	if source != "":
		_sources[path] = source


func add_button(path: String, action: Callable) -> void:
	if not _ui_ready(): return
	if _warn_duplicate(path): return
	var sp := _split_path(path)
	var parent := _get_or_create_section(sp[0])
	var leaf: String = sp[1]
	var btn := Button.new()
	btn.text = leaf
	parent.add_child(btn)
	btn.pressed.connect(func() -> void: action.call())
	_controls[path] = btn


func add_readout(path: String, getter: Callable) -> void:
	if not _ui_ready(): return
	if _warn_duplicate(path): return
	var sp := _split_path(path)
	var parent := _get_or_create_section(sp[0])
	var leaf: String = sp[1]
	var label := Label.new()
	label.text = "%s: -" % leaf
	parent.add_child(label)
	_readouts.append({"name": leaf, "label": label, "getter": getter})
	_controls[path] = label


# Walks all registered controls, compares current value to the value we
# captured at registration (which mirrors the @export default), and emits
# `path: default → current` lines for anything that's been moved. Buttons
# and readouts are skipped — they have no meaningful value.
func _build_diff_text() -> String:
	var lines: PackedStringArray = []
	for path in _controls.keys():
		if not _defaults.has(path):
			continue
		var ctrl: Node = _controls[path]
		var current: Variant = _read_control_value(ctrl)
		if current == null:
			continue
		var default_v: Variant = _defaults[path]
		if _values_equal(current, default_v):
			continue
		var line: String = "%s: %s → %s" % [path, _fmt_value(default_v), _fmt_value(current)]
		if _sources.has(path):
			line += "  # " + String(_sources[path])
		lines.append(line)
	return "\n".join(lines)


func _read_control_value(ctrl: Node) -> Variant:
	if ctrl is HSlider:
		return (ctrl as HSlider).value
	if ctrl is CheckBox:
		return (ctrl as CheckBox).button_pressed
	if ctrl is OptionButton:
		return (ctrl as OptionButton).selected
	return null


func _values_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) == TYPE_FLOAT and typeof(b) == TYPE_FLOAT:
		return is_equal_approx(a, b)
	return a == b


func _fmt_value(v: Variant) -> String:
	if typeof(v) == TYPE_FLOAT:
		return "%.3f" % v
	return str(v)
