class_name AudioCue
extends Resource

## Data-only SFX cue. Authored as .tres files and listed in CueRegistry.
## Audio.play_sfx(&"door_open") looks up the cue and plays a random stream
## from the pool with randomized volume + pitch in the configured range.
## See docs/interactables.md §8.4.

## Random pick at playback — use multiple streams to avoid repetition fatigue.
@export var streams: Array[AudioStream] = []

## When true, sample() steps through streams in order (A, B, C, A, B, C…)
## instead of random. Use for short paired cues where strict alternation
## reads cleaner than the 50% repeat rate of random-from-2 (e.g., coin click).
@export var strict_alternate: bool = false
var _alternate_index: int = 0

@export_group("Volume")
@export_range(-60.0, 24.0) var volume_db_min: float = 0.0
@export_range(-60.0, 24.0) var volume_db_max: float = 0.0

@export_group("Pitch")
@export_range(0.1, 4.0) var pitch_min: float = 1.0
@export_range(0.1, 4.0) var pitch_max: float = 1.0

## Audio bus name. Most cues go to "SFX"; UI cues go to "UI"; music/dialogue
## are handled by dedicated playback paths, not by AudioCue.
@export var bus: StringName = &"SFX"


## Returns (stream, volume_db, pitch) triple, or (null, 0, 1) if pool empty.
func sample() -> Array:
	if streams.is_empty():
		return [null, 0.0, 1.0]
	var stream: AudioStream
	if strict_alternate:
		stream = streams[_alternate_index]
		_alternate_index = (_alternate_index + 1) % streams.size()
	else:
		stream = streams[randi() % streams.size()]
	var vol := randf_range(volume_db_min, volume_db_max)
	var pitch := randf_range(pitch_min, pitch_max)
	return [stream, vol, pitch]
