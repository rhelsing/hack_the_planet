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
## Continuous sway amplitude once the startup burst has settled. Keeps a
## low-level side-to-side rock going while moving. 0 = fully settle to still.
@export var cruise_sway_amplitude := 0.0
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

@export_group("Rail Grind")
## Speed the player moves along a rail (m/s). 0 disables grinding.
@export var grind_speed := 0.0
## Upward impulse applied when jumping off a rail (on top of normal jump).
@export var grind_exit_boost := 0.0
## Yaw offset (degrees) applied to the skin while grinding — rotates the body
## sideways relative to the rail direction. 90 = fully perpendicular.
@export_range(-180.0, 180.0) var grind_yaw_offset_deg := 0.0
## Max roll (radians) player can add with left/right input to counter-balance
## the rail tilt.
@export var grind_counter_strength := 0.6
## If roll exceeds this magnitude (radians) the player falls off the rail.
## ~0.5 = 28°, ~0.7 = 40°.
@export var grind_fall_threshold := 0.55
## Multiplier on centripetal roll while grinding — higher = bigger lean into curves.
@export var grind_lean_multiplier := 3.0
## Roll (radians) applied to the skin during a wall-ride, signed by the
## wall side: wall on player's right → negative roll (lean right into wall);
## wall on player's left → positive roll. Stacks on top of the regular
## centripetal lean and is scaled by the skin's lean_multiplier. ~0.5 ≈ 28°.
@export var wall_ride_lean_amount: float = 0.5
## Grace window (seconds) after walking off a ledge during which a jump
## press still counts as the FIRST jump (not the air/double jump). Without
## this, a fraction-of-a-second-late press silently consumes the double
## jump and the player can't air-jump from the apex. ~0.10–0.15s feels
## tight without being cheaty.
@export var coyote_time: float = 0.12
## Extra downward offset applied to the skin proportional to total tilt
## magnitude (radians). Gives a "crouch into the turn" feel.
@export var tilt_height_drop := 0.0
## Vertical lift (m) applied to the skin when running, scaled linearly by
## (speed / max_speed). Counteracts the foot-into-ground sink that the
## forward lean introduces — without this, dramatic lean values pitch the
## body forward and the feet visibly clip below the floor at top speed.
## Only applied while on_floor; airborne skin uses identity offset.
@export var forward_speed_lift := 0.0
