class_name CutsceneTimeline
extends Resource

## A cutscene's script — pure data. Authored as a `.tres` file. Run by a
## CutscenePlayer node. See `docs/cutscene_engine.md` for the full design.
##
## Three things live here:
##   1. The ordered list of steps (the actual timeline).
##   2. Setup/teardown config (freeze player, hide HUD).
##   3. Outcome flags fired on natural completion vs cancellation.
##
## Anything else (when to start the cutscene, debug hotkeys, the camera
## node references) lives on the CutscenePlayer node — that's per-instance
## wiring, not data the script cares about.

## The timeline. Each entry is a CutsceneStep subclass: LineStep, CutStep,
## PanStep, WaitStep, MusicStep, StingerStep, FlagStep, ParallelStep,
## SubsequenceStep, or SkipPointStep. Run in order top-to-bottom.
@export var steps: Array[CutsceneStep] = []

@export_group("Stage")
## When true, the player can't move during the cutscene. set_physics_process
## is flipped on PlayerBody for the duration; restored on completion or cancel.
@export var freeze_player: bool = true
## When true, the HUD root (group "hud") is hidden during the cutscene.
@export var hide_hud: bool = false
## How long the cinematic-camera trajectories should drift over. Any
## `CameraDrift` child of a camera referenced by a CutStep gets its
## `duration` set to this value and is kicked into motion at cutscene
## start. Cameras drift for the whole sequence regardless of which shot
## is currently being viewed (they tween in parallel; CutSteps just
## decide which one's render the player sees). 0 = don't kick drifts.
@export_range(0.0, 600.0, 0.5) var scene_duration: float = 30.0

@export_group("Outcome")
## GameState flag set to true on natural completion. Empty = no flag.
@export var done_flag: StringName = &""
## GameState flag set to true on cancel/skip-to-end. Empty = use done_flag
## even on cancel (the common case — game progresses regardless of whether
## the player watched fully). Set this when downstream story logic needs to
## branch on "did they actually see it through" vs "did they cancel out."
@export var cancelled_flag: StringName = &""

@export_group("Input")
## InputMap action the player must HOLD to skip while this cutscene is
## running. Default `interact` matches what dialogue and other in-world
## prompts use (E on keyboard, Triangle / X on gamepad — InputMap-bound).
## Cutscenes that need a different binding can override per-timeline.
@export var skip_action: StringName = &"interact"
## When true, holding skip_action for `skip_hold_seconds` jumps to the
## next SkipPointStep (or end if none). When false, the cutscene cannot
## be skipped mid-flight — only cancelled externally via cancel().
##
## Skip is also gated on `freeze_player = true` regardless of this flag —
## non-blocking cutscenes (battle radio, ambient chatter) MUST keep the
## interact key free for gameplay use, so they're never skippable even if
## the author leaves allow_skip true. To explicitly disable for a
## blocking cutscene that should be unmissable, set this false.
@export var allow_skip: bool = true
## Seconds the player must hold skip_action to actually trigger the skip.
## Long enough to prevent accidental skips, short enough to feel responsive.
@export_range(0.5, 10.0, 0.1) var skip_hold_seconds: float = 3.0
