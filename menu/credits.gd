extends Control
## One-pass auto-scrolling credits roll. Anchored to the left 20% of the
## screen; text starts below the column and tweens upward until the last
## line clears the top, then emits back_requested. Esc skips the roll early.

signal back_requested

## Pixels per second for the upward scroll. Tune by feel — typical film
## credits run ~50 px/s; faster reads punchier for a short list.
@export var scroll_speed_px_per_s: float = 60.0

## Base size for credits text at hud_scale = 1.0, before the credits
## multiplier. The .tscn sets 14 as the authored base; we keep it in
## sync via _apply_text_scale on _ready and on Settings changes.
const _FONT_BASE: int = 14
## Credits-specific multiplier on top of Settings.get_hud_scale(). Bump
## here if credits should always read larger than HUD chrome.
const _FONT_MULT: float = 1.5

@onready var _column: Control = %ScrollColumn
@onready var _content: Control = %ScrollContent
@onready var _text: Label = %ScrollText

var _scroll_tween: Tween = null
## Whether ui_cancel / ui_accept can short-circuit the roll. Main menu sets
## true (player can skip and return); in-game overlays leave this false so
## Esc still opens the pause menu, not the credits skipper.
var _skippable: bool = false


func configure(args: Dictionary) -> void:
	_skippable = bool(args.get("skippable", false))


func _ready() -> void:
	# Only skippable credits (main menu) count as a modal — they actually
	# block input. Passive in-game credits (hub post-L4, level 5 corridor)
	# leave _skippable = false and shouldn't suppress prompts or register
	# with pause_controller.is_any_modal_open(). configure() runs before
	# _ready so _skippable is reliably set here.
	if _skippable:
		Events.modal_opened.emit(&"credits")
		tree_exited.connect(func() -> void: Events.modal_closed.emit(&"credits"))
	# Apply the user's text-scale setting to the credits font, then re-apply
	# whenever Settings changes (so the slider works while the roll is up).
	_apply_text_scale()
	Events.settings_applied.connect(_apply_text_scale)
	# Defer so the layout has resolved column.size and label.size before we
	# pin the start position + compute the end position.
	_start_scroll.call_deferred()


func _apply_text_scale() -> void:
	if _text == null:
		return
	var s := Settings.get_hud_scale()
	var size_px: int = int(round(_FONT_BASE * _FONT_MULT * s))
	_text.add_theme_font_size_override(&"font_size", size_px)


func _start_scroll() -> void:
	if _column == null or _content == null:
		return
	var start_y: float = _column.size.y
	var end_y: float = -_content.size.y
	_content.position.y = start_y
	var distance: float = absf(end_y - start_y)
	var duration: float = distance / maxf(scroll_speed_px_per_s, 1.0)
	_scroll_tween = create_tween()
	_scroll_tween.tween_property(_content, "position:y", end_y, duration)
	_scroll_tween.finished.connect(_on_scroll_finished)


func _on_scroll_finished() -> void:
	_play_back_sfx()
	back_requested.emit()


func _input(event: InputEvent) -> void:
	if not _skippable:
		return
	if event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"ui_accept"):
		_play_back_sfx()
		back_requested.emit()
		get_viewport().set_input_as_handled()


func _play_back_sfx() -> void:
	var audio := get_tree().root.get_node_or_null(^"Audio")
	if audio != null and audio.has_method(&"play_sfx"):
		audio.call(&"play_sfx", &"ui_back")
