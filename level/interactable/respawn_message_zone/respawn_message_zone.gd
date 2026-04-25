extends Area3D
class_name RespawnMessageZone

## Trigger volume that arms a contextual hint for the next respawn. Place
## these around tricky platforming so falling produces a relevant message
## (e.g. drop one in the air below a gap with "Try the wall-ride to your
## left"). Latest-armed wins; PlayerBody clears the queue after one show.

## Center-screen label hint shown post-respawn. If voice_line is set, this is
## ignored and the voice path is taken instead.
@export_multiline var message: String = ""

## When set, this zone arms a voiced cue instead of a label. The cue plays
## post-respawn through the Companion bus (reverb), not the Walkie phone FX.
## `voice_character` must be a key in dialogue/voices.tres.
@export var voice_character: StringName = &""
@export_multiline var voice_line: String = ""


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	# Voice path wins. Either-or, never both — keeps the post-respawn beat
	# from being a label AND a voice line at the same time.
	if not voice_line.is_empty() and voice_character != &"":
		# Same {action_name} substitution as the label path so spoken lines
		# adapt to controller vs keyboard. Format BEFORE emit so the cache
		# key (text → mp3 hash) reflects the resolved string, and the spoken
		# audio matches what the player hears in their head while reading.
		Events.respawn_voice_armed.emit(String(voice_character), Glyphs.format(voice_line))
		return
	if message.is_empty():
		return
	# Substitute {action_name} placeholders with the active device's glyph so
	# "Press {jump} to jump!" renders as "Press Space to jump!" or "Press ✕
	# to jump!" depending on whether the player last used keyboard or pad.
	Events.respawn_message_armed.emit(Glyphs.format(message))
