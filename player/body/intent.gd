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

## Edge-triggered: true for exactly one physics tick when the interact action
## starts (open doors, trigger dialogue, activate puzzle terminals). Consumed
## by the InteractionSensor on PlayerBrain.
var interact_pressed: bool = false

## Edge-triggered: true for exactly one physics tick when dash is initiated.
## Body applies a velocity impulse along move_direction (or the last faced
## direction if no movement input) with a cooldown + brief i-frame window.
var dash_pressed: bool = false

## Held: true whenever the crouch key is down. Not edge-triggered. Body only
## honors crouch when the active MovementProfile is the walk profile — skating
## doesn't crouch. Effect is a slow-walk speed multiplier; skins with a real
## crouch pose can override crouch(active) to show it.
var crouch_held: bool = false

## Held: when true, the body zeros horizontal velocity this tick — bypassing
## both the accel branch (move_direction non-zero) and the friction branch
## (gradual decay). Used by AI brains at ledges where physics-rate friction
## can't brake a fast pawn (e.g. red 2.5×) before they slide off. Re-evaluated
## every tick — clears automatically the moment the brain stops requesting it.
var hard_brake: bool = false

## Optional brain-driven yaw target (radians, in the same space the body's
## _yaw_state uses — i.e. signed_angle_to(Vector3.BACK, forward, UP)). When
## face_yaw_override_set is true, the body uses this for its skin facing
## instead of the velocity-tracked default. Lets a brain rotate a stationary
## pawn — e.g. stealth patrol's "stop and look side-to-side" beat where the
## body has zero velocity but the brain still wants to swing the head.
## Smoothing still applies via profile.rotation_speed, so a sudden override
## flip rotates over ~0.5s instead of popping.
var face_yaw_override: float = 0.0
var face_yaw_override_set: bool = false
