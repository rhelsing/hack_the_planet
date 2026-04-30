class_name SubsequenceStep
extends CutsceneStep

## Embed another CutsceneTimeline as a single step. Runs the embedded
## timeline's steps serially; this step completes when the subsequence
## completes. Used as the vehicle for serial subgroups inside ParallelStep
## (e.g., "pan camera while a serial run of 6 lines plays").
##
## The parent player's pause/skip/cancel state propagates into the
## subsequence — it's a black box from the timing perspective but not from
## the runtime control perspective.

@export var timeline: CutsceneTimeline
