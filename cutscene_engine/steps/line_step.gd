class_name LineStep
extends CutsceneStep

## Speak one line of dialogue. The CutscenePlayer awaits the line's
## completion via CutsceneAudio (which routes to Walkie or Companion based
## on `channel` and respects pause). Markdown emphasis (`**bold**`,
## `*italic*`) and tokens (`{handle}`, `{action_name}`) are processed by
## the existing TTS pipeline — same conventions as .dialogue files.

## Speaker name. Must have a voice configured in dialogue/voices.tres.
@export var character: StringName = &""

## The spoken line. Supports `**bold**`, `*italic*`, ElevenLabs v3 audio
## cues like `[whispering]`, `[laughs]`, and tokens like `{handle}`.
@export_multiline var text: String = ""

## Audio routing. "companion" = clean voice on Companion bus. "walkie" =
## phone-FX (bandpass + distortion) on Walkie bus.
@export_enum("companion", "walkie") var channel: String = "companion"

## Optional bus override. When set, the line plays through this bus instead
## of the channel's default. Use for cinematic-only effects like a "Reverb"
## or "CloseUp" bus without changing channel routing project-wide.
@export var bus_override: StringName = &""

## Seconds to hold after the line completes before advancing to the next
## step. Pause-respecting — if game is paused, the hold pauses too.
@export_range(0.0, 30.0, 0.05) var hold_after: float = 0.0
