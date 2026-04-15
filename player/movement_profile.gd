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

@export_group("Wall Ride")
## How long the player can stick to a wall, in seconds. 0 disables wall ride.
@export var wall_ride_duration := 0.0
## Minimum horizontal speed required to trigger / maintain a wall ride.
@export var wall_ride_min_speed := 5.0
## Fraction of gravity applied while on the wall (0 = stick, 1 = normal gravity).
@export_range(0.0, 1.0) var wall_ride_gravity_scale := 0.0
## How far sideways to check for walls (meters).
@export var wall_ride_reach := 1.0
## Outward push applied along the wall normal when jumping off. High values
## launch you across the map.
@export var wall_ride_jump_push := 14.0
## Max degrees a surface can tilt from vertical and still count as a wall.
## 17° = strictly walls, 45° = steep ramps allowed, 90° = anything.
@export_range(0.0, 90.0) var wall_ride_max_tilt_deg := 17.0
## Extra downward offset applied to the skin proportional to total tilt
## magnitude (radians). Gives a "crouch into the turn" feel.
@export var tilt_height_drop := 0.0
