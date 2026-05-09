extends Node

## Dev hold-to-peek StoryVec overlay.
##
## Hold the "1" key (any time, anywhere) to display the current story
## vector on a 2D graph. Release to hide. Generic — if the StoryVec config
## declares exactly 2 axes the overlay renders a quadrant plane; for any
## other axis count it falls back to a numeric readout.
##
## Pure dev tool. No save state, no input registration in project.godot —
## just listens for the literal physical "1" key in _input. If a future
## player-facing action ever needs that key, gate this on
## `OS.is_debug_build()` or wrap the _input check in a flag.

const GRAPH_SIZE: float = 480.0
const GRAPH_PADDING: float = 96.0  # space for labels + axis ticks
const DOT_RADIUS: float = 12.0
const FONT_SIZE_HEADER: int = 24  # was 14 (default Label theme)
const FONT_SIZE_AXIS: int = 24    # was 12
const FONT_SIZE_TICK: int = 20    # was 10
const FONT_SIZE_REGION: int = 22  # was 11
const REGION_TINTS: Array[Color] = [
	Color(0.35, 0.91, 0.35, 0.18),   # green
	Color(0.91, 0.78, 0.48, 0.18),   # amber
	Color(0.55, 0.78, 0.95, 0.18),   # blue
	Color(0.95, 0.55, 0.55, 0.18),   # red
	Color(0.7, 0.7, 0.7, 0.18),      # neutral gray
]

var _canvas: CanvasLayer
var _control: Control
var _label: Label
var _visible: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_canvas = CanvasLayer.new()
	_canvas.layer = 110  # above DebugPanel (100)
	_canvas.visible = false
	add_child(_canvas)

	# Centered anchor — graph sits in the middle of the viewport while held.
	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_CENTER)
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(anchor)

	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# A flat panel stylebox so the overlay stays readable against any scene.
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.78)
	sb.border_color = Color(1, 1, 1, 0.4)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	sb.content_margin_left = 8
	sb.content_margin_top = 8
	sb.content_margin_right = 8
	sb.content_margin_bottom = 8
	panel.add_theme_stylebox_override(&"panel", sb)
	# Center the panel on the anchor.
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-(GRAPH_SIZE + GRAPH_PADDING * 2) * 0.5,
			-(GRAPH_SIZE + GRAPH_PADDING * 2) * 0.5)
	anchor.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(vbox)

	_label = Label.new()
	_label.text = "StoryVec  (hold 1)"
	_label.add_theme_color_override(&"font_color", Color(0.85, 0.85, 0.85))
	_label.add_theme_font_size_override(&"font_size", FONT_SIZE_HEADER)
	vbox.add_child(_label)

	_control = Control.new()
	_control.custom_minimum_size = Vector2(GRAPH_SIZE + GRAPH_PADDING, GRAPH_SIZE + GRAPH_PADDING)
	_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_control.draw.connect(_draw_graph)
	vbox.add_child(_control)


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.physical_keycode == KEY_1:
			if key.pressed and not key.echo:
				_show()
			elif not key.pressed:
				_hide()


func _show() -> void:
	if _visible: return
	_visible = true
	_canvas.visible = true
	_label.text = _summary_text()
	_control.queue_redraw()


func _hide() -> void:
	if not _visible: return
	_visible = false
	_canvas.visible = false


func _process(_delta: float) -> void:
	# Cheap live update while held — nudges that fire mid-hold should reflect.
	if _visible:
		_label.text = _summary_text()
		_control.queue_redraw()


func _summary_text() -> String:
	if not _has_story_vec(): return "StoryVec  <autoload missing>"
	var sv: Node = StoryVec
	var cfg: Resource = sv._config if sv != null else null
	if cfg == null or cfg.axes == null or cfg.axes.is_empty():
		return "StoryVec  <no config>"
	var parts: Array[String] = []
	for axis: StringName in cfg.axes:
		parts.append("%s=%.1f" % [axis, sv.value(axis)])
	var region_name: StringName = sv.region()
	var region_str: String = region_name if region_name != &"" else "<no region>"
	return "StoryVec  %s  region=%s" % [", ".join(parts), region_str]


func _draw_graph() -> void:
	if not _has_story_vec():
		_control.draw_string(_get_font(), Vector2(8, 24),
				"StoryVec autoload missing", HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
				Color.WHITE_SMOKE)
		return
	var sv: Node = StoryVec
	var cfg: Resource = sv._config
	if cfg == null or cfg.axes == null or cfg.axes.size() != 2:
		# Fallback — N-dim or no-config: just render axis values as text.
		_draw_numeric_fallback(cfg, sv)
		return

	var x_axis: StringName = cfg.axes[0]
	var y_axis: StringName = cfg.axes[1]
	var bmin: float = cfg.bounds_min
	var bmax: float = cfg.bounds_max
	var origin := Vector2(GRAPH_PADDING + GRAPH_SIZE * 0.5, GRAPH_PADDING + GRAPH_SIZE * 0.5)
	var unit: float = GRAPH_SIZE * 0.5 / max(abs(bmin), abs(bmax))

	# Tint each defined region with a rotating palette so the player can
	# eyeball where they are.
	var region_idx := 0
	for r: Dictionary in cfg.regions:
		var t: Dictionary = r.get("thresholds", {})
		var x_lo: float = bmin
		var x_hi: float = bmax
		var y_lo: float = bmin
		var y_hi: float = bmax
		if t.has(x_axis):
			x_lo = float(t[x_axis][0]); x_hi = float(t[x_axis][1])
		if t.has(y_axis):
			y_lo = float(t[y_axis][0]); y_hi = float(t[y_axis][1])
		var rect := Rect2(
			origin + Vector2(x_lo * unit, -y_hi * unit),
			Vector2((x_hi - x_lo) * unit, (y_hi - y_lo) * unit))
		var tint: Color = REGION_TINTS[region_idx % REGION_TINTS.size()]
		_control.draw_rect(rect, tint, true)
		# Region label in the center of its rect.
		var label_pos: Vector2 = rect.position + rect.size * 0.5
		_control.draw_string(_get_font(), label_pos + Vector2(-64, 8),
				str(r.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE_REGION,
				Color(1, 1, 1, 0.55))
		region_idx += 1

	# Axes (cross at origin) + bounding rect.
	var axis_color := Color(1, 1, 1, 0.5)
	_control.draw_rect(Rect2(
		Vector2(GRAPH_PADDING, GRAPH_PADDING),
		Vector2(GRAPH_SIZE, GRAPH_SIZE)), axis_color, false, 1.0)
	_control.draw_line(Vector2(GRAPH_PADDING, origin.y),
			Vector2(GRAPH_PADDING + GRAPH_SIZE, origin.y), axis_color, 1.0)
	_control.draw_line(Vector2(origin.x, GRAPH_PADDING),
			Vector2(origin.x, GRAPH_PADDING + GRAPH_SIZE), axis_color, 1.0)

	# Axis labels.
	_control.draw_string(_get_font(),
			Vector2(GRAPH_PADDING + GRAPH_SIZE - 8, origin.y - 12),
			str(x_axis), HORIZONTAL_ALIGNMENT_RIGHT, -1, FONT_SIZE_AXIS, Color.WHITE)
	_control.draw_string(_get_font(),
			Vector2(origin.x + 12, GRAPH_PADDING + 24),
			str(y_axis), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE_AXIS, Color.WHITE)
	# Bounds ticks.
	_control.draw_string(_get_font(), Vector2(GRAPH_PADDING - 4, origin.y + 28),
			"%.0f" % bmin, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE_TICK,
			Color(1, 1, 1, 0.6))
	_control.draw_string(_get_font(),
			Vector2(GRAPH_PADDING + GRAPH_SIZE - 36, origin.y + 28),
			"%.0f" % bmax, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE_TICK,
			Color(1, 1, 1, 0.6))

	# Vector dot.
	var px: float = sv.value(x_axis) * unit
	var py: float = sv.value(y_axis) * unit
	var dot_pos: Vector2 = origin + Vector2(px, -py)
	_control.draw_circle(dot_pos, DOT_RADIUS + 4,
			Color(0, 0, 0, 0.6))  # halo for contrast
	_control.draw_circle(dot_pos, DOT_RADIUS, Color(1, 1, 0.4))


func _draw_numeric_fallback(cfg: Resource, sv: Node) -> void:
	var y: float = 36.0
	if cfg == null:
		_control.draw_string(_get_font(), Vector2(16, y),
				"StoryVec  <no config>", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE_HEADER,
				Color.WHITE_SMOKE)
		return
	for axis: StringName in cfg.axes:
		_control.draw_string(_get_font(), Vector2(16, y),
				"%s = %.2f" % [axis, sv.value(axis)],
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE_HEADER, Color.WHITE_SMOKE)
		y += 32.0


func _get_font() -> Font:
	# Default Godot UI font — no theme dependencies.
	return ThemeDB.fallback_font


func _has_story_vec() -> bool:
	return get_node_or_null(^"/root/StoryVec") != null
