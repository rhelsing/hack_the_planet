class_name MusicStep
extends CutsceneStep

## Swap the music track. Routed through CutsceneAudio (which calls Audio
## under the hood) so pause behavior is consistent with the rest of the
## engine. Returns immediately — fades happen in the background while
## subsequent steps run.

## The new track. Set null to stop music entirely (with a fade).
@export var stream: AudioStream

## Fade-in seconds for the new track. 0 = instant.
@export_range(0.0, 10.0, 0.1) var fade_in: float = 0.4

## When true, the new stream loops continuously. When false, it plays once
## and stops.
@export var loop: bool = true
