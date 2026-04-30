class_name PanStep
extends CutsceneStep

## Tween a camera between two pose markers. Pure Tween-based — does not
## touch CameraDrift (an unrelated, pre-existing system). Pause-respecting
## via the player's process_mode = INHERIT.

## Camera3D node to move.
@export var camera: NodePath

## Marker3D for the start pose. Camera snaps here on step start.
@export var from: NodePath

## Marker3D for the end pose. Camera arrives here at duration's end.
@export var to: NodePath

@export_range(0.1, 120.0, 0.1) var duration: float = 5.0
@export var trans: Tween.TransitionType = Tween.TRANS_QUAD
@export var ease: Tween.EaseType = Tween.EASE_IN_OUT

## When true, the player blocks until the pan finishes. When false, the pan
## kicks off and the step returns immediately — useful inside ParallelStep
## where the pan should run alongside dialogue but the timeline shouldn't
## stall on it.
@export var await_finish: bool = true
