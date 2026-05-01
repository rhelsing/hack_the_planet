extends Control

## Full-screen Control that draws every visible Beacon registered with
## the Beacons autoload. Computes screen position each frame from the
## active 3D camera; on-screen → diamond over the target, off-screen →
## arrow clamped to the viewport edge pointing toward it. Label + distance
## (in u, integer) sit beside the marker.
##
## Distance is camera-origin → beacon, straight 3D. Hidden under
## `hide_distance_under` so it doesn't clutter when the player is on top
## of the target.

@export var edge_margin: float = 48.0
@export var diamond_radius: float = 12.0
@export var arrow_size: float = 16.0
@export var line_thickness: float = 2.0
@export var fill_alpha: float = 0.7
@export var hide_distance_under: float = 3.0
## Authored at hud.scale = 1.0. Multiplied by Settings.get_hud_scale() at
## draw time so the slider scales waypoint text alongside other HUD chrome.
@export var font_size: int = 14

# Dedupe state so we only print on transitions, not every frame.
var _last_camera_ok: int = -1  # -1 unknown, 0 missing, 1 present
var _last_drawn_count: int = -1
var _logged_visible_set: Dictionary = {}


func _ready() -> void:
	# Cover the full viewport. mouse_filter=ignore so we never eat input.
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)
	print("[beacon_layer] ready")


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var camera := get_viewport().get_camera_3d()
	var cam_ok: int = 1 if camera != null else 0
	if cam_ok != _last_camera_ok:
		_last_camera_ok = cam_ok
		print("[beacon_layer] camera=%s" % ("ok" if camera != null else "MISSING"))
	if camera == null:
		return
	var screen_size: Vector2 = size
	var screen_center: Vector2 = screen_size * 0.5
	var rect := Rect2(edge_margin, edge_margin,
		screen_size.x - edge_margin * 2.0, screen_size.y - edge_margin * 2.0)
	var font := get_theme_default_font()

	var all_beacons: Array = Beacons.all()
	var drawn_count: int = 0
	# Distance origin: player position (group), not camera. Third-person camera
	# sits 5–10u behind the player and would always read ~10u even when the
	# player is on top of the beacon — misleading.
	var player_pos: Vector3 = camera.global_position
	for p in get_tree().get_nodes_in_group("player"):
		if p is Node3D:
			player_pos = (p as Node3D).global_position
			break
	for beacon in all_beacons:
		if not is_instance_valid(beacon):
			continue
		if not beacon.beacon_visible:
			continue
		drawn_count += 1
		# One-shot log per beacon when it first becomes visible to the layer.
		if not _logged_visible_set.has(beacon):
			_logged_visible_set[beacon] = true
			print("[beacon_layer] drawing %s at %s" % [beacon.name, beacon.global_position])
		var world_pos: Vector3 = beacon.global_position
		var distance: float = player_pos.distance_to(world_pos)

		var is_behind: bool = camera.is_position_behind(world_pos)
		var screen_pos: Vector2 = camera.unproject_position(world_pos)
		if is_behind:
			# Mirror across center so the indicator points the right way
			# even when the target is behind the camera.
			screen_pos = screen_center + (screen_center - screen_pos)

		var on_screen: bool = (not is_behind) and rect.has_point(screen_pos)
		var draw_color: Color = beacon.color
		var fill: Color = Color(draw_color.r, draw_color.g, draw_color.b, fill_alpha)

		if on_screen:
			_draw_diamond(screen_pos, diamond_radius, draw_color, fill)
		else:
			var clamped: Vector2 = _clamp_to_rect(screen_center, screen_pos, rect)
			var dir: Vector2 = (screen_pos - screen_center)
			if dir.length_squared() < 0.0001:
				dir = Vector2.UP
			else:
				dir = dir.normalized()
			_draw_arrow(clamped, dir, arrow_size, draw_color, fill)
			screen_pos = clamped

		var text: String = beacon.label
		if distance >= hide_distance_under:
			var d_str: String = "%du" % int(round(distance))
			if not text.is_empty():
				text = "%s  %s" % [text, d_str]
			else:
				text = d_str
		if not text.is_empty() and font != null:
			# Scaled font_size — single uniform HUD knob from Settings.
			var fs: int = int(font_size * Settings.get_hud_scale())
			var text_size: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs)
			var text_pos: Vector2 = screen_pos + Vector2(-text_size.x * 0.5, diamond_radius + 4.0 + text_size.y)
			# 1px shadow for legibility on bright backgrounds.
			draw_string(font, text_pos + Vector2(1, 1), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs, Color(0, 0, 0, 0.8))
			draw_string(font, text_pos, text,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs, draw_color)
	if drawn_count != _last_drawn_count:
		_last_drawn_count = drawn_count
		print("[beacon_layer] drawn=%d (registered=%d)" % [drawn_count, all_beacons.size()])


func _draw_diamond(center: Vector2, radius: float, outline: Color, fill: Color) -> void:
	var pts := PackedVector2Array([
		center + Vector2(0, -radius),
		center + Vector2(radius, 0),
		center + Vector2(0, radius),
		center + Vector2(-radius, 0),
	])
	draw_colored_polygon(pts, fill)
	var loop := PackedVector2Array(pts)
	loop.append(pts[0])
	draw_polyline(loop, outline, line_thickness, true)


func _draw_arrow(tip: Vector2, dir: Vector2, length: float, outline: Color, fill: Color) -> void:
	# Triangle pointing along `dir`, with `tip` at the leading vertex.
	var perp := Vector2(-dir.y, dir.x)
	var base := tip - dir * length
	var half := length * 0.6
	var pts := PackedVector2Array([
		tip,
		base + perp * half,
		base - perp * half,
	])
	draw_colored_polygon(pts, fill)
	var loop := PackedVector2Array(pts)
	loop.append(pts[0])
	draw_polyline(loop, outline, line_thickness, true)


func _clamp_to_rect(center: Vector2, point: Vector2, rect: Rect2) -> Vector2:
	# Find where the segment from `center` to `point` exits `rect`.
	# Point is assumed outside; we walk along the ray and clip to each edge.
	var dir: Vector2 = point - center
	if dir.length_squared() < 0.0001:
		return center
	var t_min: float = 1.0
	# Left/right
	if dir.x != 0.0:
		var tx_left: float = (rect.position.x - center.x) / dir.x
		if tx_left > 0.0 and tx_left < t_min:
			t_min = tx_left
		var tx_right: float = (rect.position.x + rect.size.x - center.x) / dir.x
		if tx_right > 0.0 and tx_right < t_min:
			t_min = tx_right
	# Top/bottom
	if dir.y != 0.0:
		var ty_top: float = (rect.position.y - center.y) / dir.y
		if ty_top > 0.0 and ty_top < t_min:
			t_min = ty_top
		var ty_bot: float = (rect.position.y + rect.size.y - center.y) / dir.y
		if ty_bot > 0.0 and ty_bot < t_min:
			t_min = ty_bot
	return center + dir * t_min
