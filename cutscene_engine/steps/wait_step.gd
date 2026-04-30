class_name WaitStep
extends CutsceneStep

## Pure timing. Three modes — first non-empty one wins:
##   1. `seconds` > 0: wait that long via get_tree().create_timer (pauses
##      with the tree).
##   2. `until_signal` set: await the named signal on the configured node.
##   3. `until_flag` set: await GameState.set_flag(name, true).
## Mode 2 + 3 let cutscenes synchronize with external systems (a spawner
## finishing, an enemy dying) without polling.

## Mode 1 — fixed-duration pause. Used when you just want a beat of silence.
@export_range(0.0, 60.0, 0.1) var seconds: float = 0.0

## Mode 2 — wait for a signal. Path is relative to the CutscenePlayer's
## scene root. If the named signal doesn't exist on the target, the step
## logs a warning and returns immediately.
@export var until_signal_target: NodePath
@export var until_signal_name: StringName

## Mode 3 — wait for a GameState flag to become truthy. Already-true at
## step start = step returns immediately.
@export var until_flag: StringName
