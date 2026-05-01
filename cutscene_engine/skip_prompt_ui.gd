class_name SkipPromptUI
extends CanvasLayer

## Reusable "Hold {glyph} to skip" prompt with fading label + progress bar.
## Used by both cutscene_player (timeline cutscenes) and Cutscene.show_video
## (OGV overlays). Self-builds children on _ready; PROCESS_MODE_ALWAYS so
## the prompt survives a paused tree.
##
## Layer 75 sits above HUD (0) and walkie subtitles (50) but below the
## pause menu (100) — gameplay UI can't obscure the prompt, but the pause
## menu still wins if the player opens it mid-cutscene.

const _LAYER: int = 75

var _root: Control = null
var _label: Label = null
var _bar: ProgressBar = null
var _tween: Tween = null
var _visible_state: bool = false


func _ready() -> void:
	layer = _LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


func _build() -> void:
	if _root != null:
		return
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_root.offset_top = -110.0
	_root.offset_bottom = -40.0
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.modulate.a = 0.0
	add_child(_root)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	_root.add_child(box)
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override(&"font_size", 18)
	_label.add_theme_color_override(&"font_color", Color(0.95, 0.95, 0.95, 1))
	_label.add_theme_constant_override(&"outline_size", 4)
	_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.85))
	box.add_child(_label)
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(220, 6)
	_bar.show_percentage = false
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.value = 0.0
	box.add_child(_bar)
	visible = false


## Show the prompt with text "Hold {glyph} to skip" where glyph is
## resolved via Glyphs autoload (e.g., "E", "Triangle"). Falls back to the
## uppercased action name if Glyphs isn't available.
func show_for(action: StringName) -> void:
	_build()
	var action_name: String = String(action)
	var glyph: String = action_name.to_upper()
	var glyphs := get_tree().root.get_node_or_null(^"Glyphs")
	if glyphs != null and glyphs.has_method(&"for_action"):
		glyph = String(glyphs.call(&"for_action", action_name))
	_label.text = "Hold %s to skip" % glyph
	_bar.value = 0.0
	visible = true
	_visible_state = true
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_root, "modulate:a", 1.0, 0.15)


## Fade the prompt out and hide. No-op when already hidden.
func hide_prompt() -> void:
	if not _visible_state:
		return
	_visible_state = false
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_root, "modulate:a", 0.0, 0.2)
	_tween.tween_callback(func() -> void: visible = false)


## 0..1 fill of the hold-progress bar.
func set_progress(p: float) -> void:
	if _bar != null:
		_bar.value = clampf(p, 0.0, 1.0)
