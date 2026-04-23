class_name HUDToast
extends RichTextLabel
## Single toast line with typewriter reveal, hold, and fade-out. Self-frees
## after its lifecycle. ToastStack instantiates one per event.

signal expired

const REVEAL_S := 0.30
const HOLD_S   := 1.50
const FADE_S   := 0.30


func show_message(message: String, color: Color) -> void:
	bbcode_enabled = true
	fit_content = true
	scroll_active = false
	autowrap_mode = TextServer.AUTOWRAP_OFF
	text = "[color=#%s]%s[/color]" % [color.to_html(false), message]
	visible_ratio = 0.0
	modulate.a = 1.0

	var tw := create_tween()
	tw.tween_property(self, "visible_ratio", 1.0, REVEAL_S).set_trans(Tween.TRANS_LINEAR)
	tw.tween_interval(HOLD_S)
	tw.tween_property(self, "modulate:a", 0.0, FADE_S).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void:
		expired.emit()
		queue_free()
	)
