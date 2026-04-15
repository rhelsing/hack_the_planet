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
