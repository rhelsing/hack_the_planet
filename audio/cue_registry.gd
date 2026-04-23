class_name CueRegistry
extends Resource

## Explicit manifest of every SFX cue in the project. Edited in the Inspector
## as a Dictionary of `StringName → AudioCue`. See docs/interactables.md §8.4.
##
## Explicit (not auto-scan) per the JB/AAA "no silent failures" principle:
## when Audio.play_sfx(&"typo") fails, the registry miss is a loud push_error.
## Auto-scan would silently play nothing.

@export var cues: Dictionary = {}


## Returns the AudioCue for id, or null if missing. Untyped return so the
## `class_name AudioCue` symbol doesn't need to be resolved at parse time
## of this file (avoids class_name registration ordering issues).
func get_cue(id: StringName) -> Resource:
	return cues.get(id, null)


func has_cue(id: StringName) -> bool:
	return cues.has(id)
