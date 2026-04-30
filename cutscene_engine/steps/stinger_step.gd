class_name StingerStep
extends CutsceneStep

## A one-shot SFX layered over whatever's playing. Doesn't touch music.
## Optionally awaited (e.g., the BRAAAM at the start of the L4 boss
## cutscene must finish before the music kicks in).

@export var stream: AudioStream

@export var bus: StringName = &"SFX"

## When true, the player blocks until the stinger ends. When false, fire
## and forget — useful for ambient hits that should overlap with lines.
@export var await_finish: bool = false

@export_range(-30.0, 12.0, 0.5) var volume_db: float = 0.0
