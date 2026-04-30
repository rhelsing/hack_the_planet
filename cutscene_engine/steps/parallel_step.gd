class_name ParallelStep
extends CutsceneStep

## Run a list of CutsceneSteps concurrently. Each entry in `steps` becomes
## its own track. The step completes when all tracks finish (when
## `await_all = true`) or when the first one does (`await_all = false`).
##
## To run a SERIAL subgroup of steps as one track parallel to another track,
## wrap the subgroup in a SubsequenceStep. ParallelStep does not have any
## inline serial-track logic — it's pure parallel.

@export var steps: Array[CutsceneStep] = []

## When true, the parallel block completes only when every track is done.
## When false, completes the moment any single track finishes (the
## remaining tracks are then cancelled).
@export var await_all: bool = true
