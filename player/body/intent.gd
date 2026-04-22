class_name Intent
extends RefCounted

## The only data that flows from a brain into the body each physics tick.
## PlayerBrain fills this from Input + camera; AI brains fill it from world
## state; NetworkBrain fills it from a remote peer's replicated intent.
## The body consumes it and doesn't care where the values came from.

## World-space horizontal direction the pawn wants to move. y is always 0.
## Magnitude is in [0, 1] — the body multiplies by MovementProfile.max_speed.
var move_direction: Vector3 = Vector3.ZERO

## Edge-triggered: true for exactly one physics tick when a jump is initiated.
## Brains are responsible for detecting the press edge (e.g., is_action_just_pressed
## for PlayerBrain, a one-shot signal for AI). Body doesn't debounce.
var jump_pressed: bool = false

## Edge-triggered: true for exactly one physics tick when an attack starts.
var attack_pressed: bool = false
