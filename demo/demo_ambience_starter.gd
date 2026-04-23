extends Node

## Starts the demo's music + ambience on _ready. Drop this as a child of any
## scene to auto-play the placeholder audio streams. Remove or edit the
## exported paths to swap in real music/ambience when you have it.

@export var music_stream: AudioStream = preload("res://audio/music/disco_music.mp3")
@export var ambience_stream: AudioStream  # optional; leave null to skip
@export var music_fade_in: float = 1.5
@export var ambience_fade_in: float = 2.0


func _ready() -> void:
	if music_stream != null:
		Audio.play_music(music_stream, music_fade_in)
	if ambience_stream != null:
		Audio.play_ambience(ambience_stream, ambience_fade_in)
