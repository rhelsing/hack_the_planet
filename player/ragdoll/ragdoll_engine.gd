# Swappable "fall engine" for the ragdoll sandbox (tests/ragdoll_tuning.tscn).
#
# Each implementation owns HOW the bones fall once the character dies: the rig
# topology, joint limits, drive/damping, and any post-process. The sandbox owns
# the skeleton and the launch trigger; the engine owns everything about the fall.
# Only ONE engine is ever built per run — the others are never instanced, so
# they're inert (no bones, no cost). Cycle/rebuild via the sandbox to A/B them.
#
# Path-based extends (no class_name) keeps these sandbox-only classes out of the
# global namespace — they never touch the shipping game.
extends RefCounted

var skin: Node3D               # the spawned KayKit skin
var skeleton: Skeleton3D       # its Skeleton3D (Model/Rig_Medium/Skeleton3D)


func setup(p_skin: Node3D, p_skeleton: Skeleton3D) -> void:
	skin = p_skin
	skeleton = p_skeleton


## Short human label shown in the selector + HUD.
func engine_name() -> String:
	return "base"


## Construct this engine's physics representation from the skeleton. Called once
## after the skin spawns, before the character is killed. No-op if the engine
## reuses an authored rig.
func build() -> void:
	pass


## Push the sandbox knob dictionary onto whatever this engine exposes. Engines
## ignore knobs that don't apply to them. Called at kill time, before start().
func apply_tuning(_values: Dictionary) -> void:
	pass


## Kill the character: hand the rig to physics. `launch_velocity` is world-space
## (m/s); passive / KO engines may ignore it or use only part of it.
func start(_launch_velocity: Vector3) -> void:
	pass


## Per-physics-tick work while ragdolled (clamps, ease-in ramp, spring drive…).
func physics_tick(_delta: float) -> void:
	pass


func is_active() -> bool:
	return false


## Where the corpse actually ended up — for camera follow + slide measurement.
func reference_position() -> Vector3:
	return skin.global_position if skin != null else Vector3.ZERO


## Remove any nodes this engine added, so the sandbox can respawn / switch cleanly.
func teardown() -> void:
	pass
