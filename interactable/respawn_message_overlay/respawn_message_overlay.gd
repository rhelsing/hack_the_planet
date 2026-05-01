extends CanvasLayer

## Center-screen contextual hint chain. Each Events.respawn_message_show()
## call appends to an internal queue; the overlay processes them one at a
## time with a warp-in / hold / warp-out cycle and a brief gap between.
##
## Per-message lifecycle:
##   show_delay (first in chain only) → warp-in (scale 0→1) → hold →
##   warp-out (scale 1→0) → gap → next
##
## VISUAL ONLY — no audio. Companion NPCs play their own SFX on disappear;
## this overlay stays silent so the two systems don't compete.

## Fallback lead-in if `respawn_message_show` is emitted without a pre_delay
## (or with 0). Authoring callers should pass a non-zero pre_delay so they
## can sync the visible pop to whatever moment makes sense (typically
## start_of_death + death_duration + post-respawn beat — see PlayerBody).
@export var show_delay: float = 0.2
@export var hold_duration: float = 3.0
@export var warp_in_duration: float = 0.28
@export var warp_out_duration: float = 0.22
## Pause between one message scaling out and the next warping in.
@export var gap_between_messages: float = 0.45
@export var font_size: int = 36

var _label: Label
# Each entry: {"text": String, "pre_delay": float}. pre_delay only applies
# to the FIRST message of a fresh chain; subsequent ones use 0 lead-in
# (the gap_between_messages handles spacing within a chain).
var _queue: Array[Dictionary] = []
var _playing: bool = false
# True from the first enqueue of a fresh chain until the queue fully drains.
# Decides if `show_delay` applies (only on the first message in a chain).
var _chain_active: bool = false


func _ready() -> void:
	# Without ALWAYS, dialogue (which pauses the tree) freezes the chain —
	# tween callbacks queue up silently and fire in one frame on resume.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_font_size_override("font_size", font_size)
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	_label.add_theme_constant_override("outline_size", 6)
	_label.anchor_left = 0.0
	_label.anchor_right = 1.0
	_label.anchor_top = 0.5
	_label.anchor_bottom = 0.5
	_label.offset_left = 64
	_label.offset_right = -64
	_label.offset_top = -56
	_label.offset_bottom = 56
	_label.scale = Vector2.ZERO
	_label.pivot_offset = _label.size * 0.5
	add_child(_label)

	Events.respawn_message_show.connect(_enqueue)


func _enqueue(text: String, pre_delay: float = 0.0) -> void:
	if text.is_empty():
		return
	_queue.append({"text": text, "pre_delay": pre_delay})
	_try_play_next()


func _try_play_next() -> void:
	if _playing or _queue.is_empty():
		return
	_playing = true
	var is_first: bool = not _chain_active
	_chain_active = true
	var entry: Dictionary = _queue.pop_front()
	var text: String = entry.get("text", "")
	var caller_pre_delay: float = float(entry.get("pre_delay", 0.0))
	# Caller-supplied pre_delay wins on the first message; falls back to the
	# `show_delay` export if the emitter didn't pass one. Subsequent messages
	# in the chain skip the lead-in entirely (gap_between_messages handles it).
	var lead_in: float = 0.0
	if is_first:
		lead_in = caller_pre_delay if caller_pre_delay > 0.0 else show_delay
	_label.text = text
	_label.scale = Vector2.ZERO
	_label.pivot_offset = _label.size * 0.5

	var tw := create_tween()
	if lead_in > 0.0:
		tw.tween_interval(lead_in)
	tw.tween_property(_label, "scale", Vector2.ONE, warp_in_duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(hold_duration)
	tw.tween_property(_label, "scale", Vector2.ZERO, warp_out_duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(_finish_one)


func _finish_one() -> void:
	_playing = false
	if _queue.is_empty():
		_label.text = ""
		_chain_active = false
	else:
		await get_tree().create_timer(gap_between_messages).timeout
		_try_play_next()
