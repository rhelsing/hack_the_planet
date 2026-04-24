extends CanvasLayer

## Center-screen contextual hint chain. Each Events.respawn_message_show()
## call appends to an internal queue; the overlay processes them one at a
## time with a warp-in / hold / warp-out cycle and a brief gap between.
##
## Per-message lifecycle:
##   show_delay (first in chain only) → warp-in (scale 0→1 + sfx) → hold →
##   warp-out (scale 1→0 + sfx) → gap → next
##
## PlayerBody fires one signal per queued zone text on respawn — the overlay
## is what owns the chain timing.

## Delay before the FIRST message in a chain appears (lets the player land
## + orient post-respawn). Subsequent messages in the same chain skip this.
@export var show_delay: float = 3.0
@export var hold_duration: float = 3.0
@export var warp_in_duration: float = 0.28
@export var warp_out_duration: float = 0.22
## Pause between one message scaling out and the next warping in.
@export var gap_between_messages: float = 0.45
@export var font_size: int = 36
## Optional warp SFX. Played on every warp-in and warp-out. Drop any short
## stinger here in the inspector — null = silent.
@export var warp_sfx: AudioStream

var _label: Label
var _sfx: AudioStreamPlayer
var _queue: Array[String] = []
var _playing: bool = false
# Explicit chain-state flag. True from the first enqueue of a fresh chain
# until the queue fully drains. Used to decide if `show_delay` applies (only
# on the first message in a chain). Inferring this from label.scale/text
# was racy — when the warp-out tween hadn't fully settled, the next
# message was treated as non-first and skipped the 3s lead-in.
var _chain_active: bool = false


func _ready() -> void:
	# Without this, dialogue (which pauses the tree) freezes the warp chain —
	# tweens + AudioStreamPlayer.play() calls queue up silently and then all
	# fire on a single frame when the tree unpauses. PROCESS_MODE_ALWAYS lets
	# the chain keep ticking through pause modals so the audio stays in sync.
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

	_sfx = AudioStreamPlayer.new()
	_sfx.bus = &"SFX" if AudioServer.get_bus_index(&"SFX") != -1 else &"Master"
	_sfx.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_sfx)
	if warp_sfx != null:
		_sfx.stream = warp_sfx  # set once so .play() uses it without re-assign

	Events.respawn_message_show.connect(_enqueue)
	print("[respawn_overlay] ready. warp_sfx=%s bus=%s" % [warp_sfx, _sfx.bus])


func _enqueue(text: String) -> void:
	if text.is_empty():
		return
	_queue.append(text)
	_try_play_next()


func _try_play_next() -> void:
	if _playing or _queue.is_empty():
		return
	_playing = true
	var is_first: bool = (_label.scale == Vector2.ZERO and _label.text.is_empty())
	# After a message ends we clear text so the next chain starts as "first"
	# again. During a chain (text still set), is_first is false.
	var lead_in: float = show_delay if is_first else 0.0
	var text: String = _queue.pop_front()
	_label.text = text
	_label.scale = Vector2.ZERO
	# Recompute pivot now that text width may have changed.
	_label.pivot_offset = _label.size * 0.5

	var tw := create_tween()
	if lead_in > 0.0:
		tw.tween_interval(lead_in)
	tw.tween_callback(_play_warp_sfx)
	tw.tween_property(_label, "scale", Vector2.ONE, warp_in_duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(hold_duration)
	tw.tween_callback(_play_warp_sfx)
	tw.tween_property(_label, "scale", Vector2.ZERO, warp_out_duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(_finish_one)


func _finish_one() -> void:
	_playing = false
	if _queue.is_empty():
		# Chain exhausted — clear text so the NEXT signal starts as "first".
		_label.text = ""
	else:
		# Brief gap before the next one warps in.
		await get_tree().create_timer(gap_between_messages).timeout
		_try_play_next()


func _play_warp_sfx() -> void:
	if _sfx.stream == null:
		print("[respawn_overlay] warp sfx skipped — no stream set (warp_sfx export is null)")
		return
	_sfx.play()
	print("[respawn_overlay] warp sfx PLAY (bus=%s vol=%.1fdB)" % [_sfx.bus, _sfx.volume_db])
