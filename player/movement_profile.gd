class_name MovementProfile
extends Resource

@export var max_speed := 8.0
@export var accel := 30.0
@export var friction := 30.0
@export_range(0.0, 1.0) var air_accel_mult := 1.0
@export var turn_rate := TAU
@export var jump_impulse := 12.0
@export var rotation_speed := 12.0
@export var stopping_speed := 1.0
@export var face_velocity := false

@export_group("Lean")
@export var forward_lean_amount := -0.095
@export var side_lean_amount := 0.005
@export var lean_smoothing := 4.5

@export_group("Startup Sway")
## Seconds of side-to-side tilt when starting from rest (picking up speed).
@export var speedup_duration := 2.0
## Max roll amplitude during sway (radians).
@export var speedup_amplitude := 0.15
## Oscillations per second.
@export var speedup_frequency := 2.0
## Height of the skin's rotation pivot (roughly head height, meters).
## Rotations at this pivot make the feet swing while the head stays put.
@export var lean_pivot_height := 1.6
## One-shot inverse-lean kick when releasing forward input at speed. Decays.
@export var brake_impulse_amount := 0.0
## Exponential decay rate for the brake impulse. ~4 ≈ 95% in 0.75s.
@export var brake_impulse_decay := 4.0
## Extra downward offset applied to the skin proportional to total tilt
## magnitude (radians). Gives a "crouch into the turn" feel.
@export var tilt_height_drop := 0.0
