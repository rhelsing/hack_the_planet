extends CanvasLayer

@export_multiline var controls_text := "WASD — move     Space — jump     Mouse — look     Q — walk/skate     F — follow mode     ` — debug panel"
@export var large_duration := 3.0
@export var fade_duration := 0.8
@export var large_font_size := 24
@export var small_font_size := 13
@export var small_alpha := 0.45

var _label: Label
var _elapsed := 0.0
var _transitioned := false


func _ready() -> void:
	_label = Label.new()
	_label.text = controls_text
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.add_theme_font_size_override("font_size", large_font_size)
	# Subtle dark outline so it's readable on any background.
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	_label.add_theme_constant_override("outline_size", 4)
	# Start centered horizontally, slightly above vertical center.
	_label.anchor_left = 0.0
	_label.anchor_right = 1.0
	_label.anchor_top = 0.5
	_label.anchor_bottom = 0.5
	_label.offset_top = -24
	_label.offset_bottom = 24
	add_child(_label)


func _process(delta: float) -> void:
	if _transitioned:
		return
	_elapsed += delta
	if _elapsed >= large_duration:
		_transitioned = true
		_transition_to_small()


func _transition_to_small() -> void:
	var tween := create_tween().set_parallel(true)
	# Slide to bottom: move anchors + offsets so the label sits against the bottom edge.
	tween.tween_property(_label, "anchor_top", 1.0, fade_duration)
	tween.tween_property(_label, "anchor_bottom", 1.0, fade_duration)
	tween.tween_property(_label, "offset_top", -24.0, fade_duration)
	tween.tween_property(_label, "offset_bottom", -6.0, fade_duration)
	tween.tween_property(_label, "modulate:a", small_alpha, fade_duration)
	# Font size can't tween directly; step it down at transition start.
	_label.add_theme_font_size_override("font_size", small_font_size)
	_label.add_theme_constant_override("outline_size", 2)
