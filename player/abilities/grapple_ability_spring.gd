class_name GrappleAbilitySpring
extends Ability

## BACKUP of the asymmetric damped-spring grapple. To revert from the
## physics-chain version, swap the script on PlayerBody/Abilities/
## GrappleAbility in player_body.tscn to this file.

## Grapple hook. Walks the "grappleable" group each frame; any target inside
## MAX_RANGE and within the camera's facing cone shows its prompt label. On
## grapple_fire, attaches to the best target and drives the player with an
## asymmetric damped-spring rope. Press jump to release with current velocity.
##
## Swing model (asymmetric spring — "real rope"):
##   1. Carry the player's pre-grapple velocity — approach direction becomes
##      swing direction.
##   2. Each tick: apply gravity to velocity.
##   3. If distance > rope_length: apply a spring pull toward the anchor
##      (magnitude = stiffness × stretch) plus damping on the radial velocity
##      component. Rope can only pull, not push.
##   4. If distance <= rope_length: no force applied — rope is slack, player
##      moves freely.
##   5. Integrate position from velocity.
##
## Dial the feel with rope_stiffness + rope_damping exports:
##   - High stiffness + damping → near-rigid Verlet feel (snappy, no bounce).
##   - Low stiffness → bungee (big stretch, overshoot, oscillation).
##   - Critical damping for stiffness k is ≈ 2·√k; default (200, 20) is
##     under-damped for a lively swing, tune up for stability.

## How far the aim detector reaches (m). Target beyond this is ignored.
const MAX_RANGE: float = 25.0
## Cosine of the max angle between camera-forward and direction-to-target.
## 0.7 ≈ 45° half-cone — forgiving aim.
const FACING_COS: float = 0.7
## On grapple-fire, the rope length is set to (distance_to_anchor - PULL_IN).
## Smaller = less pull-in, longer swing rope. Tune in the inspector if needed.
const PULL_IN: float = 2.0
## Hard minimum on rope length so a grapple fired at point-blank range still
## produces a workable swing instead of collapsing.
const MIN_ROPE_LENGTH: float = 5.0
## Downward acceleration applied each tick during swing, m/s². Higher =
## faster, snappier swing; lower = floaty.
const SWING_GRAVITY: float = 20.0
## Upward kick applied on release so letting go at the apex feels like a jump.
const RELEASE_UP_KICK: float = 5.0

## Spring stiffness (k). The force pulling you toward the anchor when
## stretched is stiffness × stretch_meters. Very high (800+) ≈ rigid rope.
## Low (50) ≈ bungee cord.
@export var rope_stiffness: float = 200.0
## Radial damping. Opposes motion along the rope direction (stops oscillation).
## Critical damping for mass=1 is ≈ 2·√stiffness. Below that, the rope bounces;
## above, it settles smoothly.
@export var rope_damping: float = 20.0
## Safety clamp: if the spring is tuned too softly, the player could stretch
## the rope absurdly. Cap stretch at this many meters beyond rope_length
## with a hard Verlet-style clamp so we never tunnel across the map.
const MAX_STRETCH: float = 4.0

# Aim state — updated each frame from the grappleable scan.
var _aim_target: Node3D = null

# Swing state — populated on _start_swing, cleared on _release.
var _swinging: bool = false
var _anchor: Node3D = null
var _rope_length: float = 0.0
## Carried velocity during swing — starts as the player's pre-grapple
## velocity, accumulates gravity each tick, gets the radial component
## stripped on constraint hits.
var _vel: Vector3 = Vector3.ZERO
var _line_renderer: MeshInstance3D = null

# Camera pivot bookkeeping — we flip CameraPivot out of top-level mode for
# the duration of the swing so it follows the body as a regular child (the
# normal DETACHED follow loop is paused while body._physics_process is off).
var _cached_pivot: Node3D = null
var _saved_pivot_top_level: bool = false
var _saved_pivot_local_position: Vector3 = Vector3.ZERO


func _ready() -> void:
	if ability_id == &"":
		ability_id = &"GrappleAbility"
	if powerup_flag == &"":
		powerup_flag = &"powerup_sex"
	super._ready()


# ── Frame-level updates ─────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if not owned:
		return
	if _swinging:
		_update_line_visual()
	else:
		_update_aim()


func _physics_process(delta: float) -> void:
	if _swinging:
		_tick_swing(delta)


func _unhandled_input(event: InputEvent) -> void:
	if not owned:
		return
	if _swinging:
		if event.is_action_pressed(&"jump"):
			_release()
		return
	if event.is_action_pressed(&"grapple_fire") and _aim_target != null:
		_start_swing(_aim_target)


# ── Aim scan ─────────────────────────────────────────────────────────────

func _update_aim() -> void:
	var body := _find_body()
	if body == null:
		_clear_all_prompts()
		_aim_target = null
		return
	var camera: Camera3D = body.get_node_or_null(^"CameraPivot/SpringArm3D/Camera3D") as Camera3D
	if camera == null:
		_clear_all_prompts()
		_aim_target = null
		return

	var cam_pos: Vector3 = camera.global_transform.origin
	var cam_fwd: Vector3 = -camera.global_transform.basis.z

	# Hide every grappleable first, then surface only the best — exactly one
	# prompt should be visible at a time so the player knows which they'll
	# latch onto.
	_clear_all_prompts()

	var best: Node3D = null
	var best_score: float = -INF
	for n: Node in get_tree().get_nodes_in_group(&"grappleable"):
		var t: Node3D = n as Node3D
		if t == null or not is_instance_valid(t):
			continue
		var to_t: Vector3 = t.global_position - cam_pos
		var dist: float = to_t.length()
		if dist > MAX_RANGE or dist < 0.5:
			continue
		var dot: float = to_t.normalized().dot(cam_fwd)
		if dot < FACING_COS:
			continue
		# Pick whichever is closest to dead-center of screen — highest dot
		# product with camera forward. No distance weighting.
		if dot > best_score:
			best_score = dot
			best = t
	if best != null:
		_set_target_prompt(best, true)
	# Log transitions (new aim or dropped aim) rather than every frame.
	if best != _aim_target:
		if best != null:
			var dist: float = (best.global_position - cam_pos).length()
			print("[grapple] aim locked: %s at dist=%.2f (dot=%.3f)" % [best.name, dist, best_score])
		else:
			print("[grapple] aim dropped")
	_aim_target = best


func _set_target_prompt(target: Node, visible: bool) -> void:
	if target.has_method(&"set_prompt_visible"):
		target.call(&"set_prompt_visible", visible)


func _clear_all_prompts() -> void:
	for n: Node in get_tree().get_nodes_in_group(&"grappleable"):
		_set_target_prompt(n, false)


# ── Swing start / tick / release ────────────────────────────────────────

func _start_swing(target: Node3D) -> void:
	var body := _find_body()
	if body == null:
		return
	var body_3d: Node3D = body as Node3D
	if body_3d == null:
		return
	_clear_all_prompts()

	_anchor = target
	_swinging = true
	var anchor_pos: Vector3 = target.global_position

	# Rope length = current distance minus PULL_IN, clamped to a sane minimum.
	var offset: Vector3 = body_3d.global_position - anchor_pos
	var current_distance: float = offset.length()
	var raw_rope: float = current_distance - PULL_IN
	var clamped: bool = raw_rope < MIN_ROPE_LENGTH
	_rope_length = maxf(raw_rope, MIN_ROPE_LENGTH)
	print("[grapple] fire: anchor=%s player=%s dist=%.2f raw_rope=%.2f clamped=%s rope=%.2f" % [
		anchor_pos, body_3d.global_position, current_distance, raw_rope, clamped, _rope_length,
	])

	# CARRY the player's approach velocity into the swing — this is the
	# whole point of Verlet: the direction + speed you came in with becomes
	# the initial swing direction. No zeroing out.
	_vel = Vector3.ZERO
	if body is CharacterBody3D:
		_vel = (body as CharacterBody3D).velocity

	# If the player is currently farther than rope_length, snap them in
	# along the rope direction (the "yank" feel). Strip any outward-going
	# component of velocity so the rope is immediately taut.
	var offset_dir: Vector3 = offset.normalized() if offset.length_squared() > 0.01 else Vector3.DOWN
	if offset.length() > _rope_length:
		body_3d.global_position = anchor_pos + offset_dir * _rope_length
		var radial: Vector3 = offset_dir
		var radial_speed: float = _vel.dot(radial)
		if radial_speed > 0.0:  # moving further from anchor — kill that component
			_vel -= radial * radial_speed

	# Hand motion over to our Verlet loop. CharacterBody3D's own move_and_slide
	# would fight the rope constraint if left running.
	body.set_physics_process(false)
	if body is CharacterBody3D:
		(body as CharacterBody3D).velocity = Vector3.ZERO

	# With body._physics_process off, PlayerBody's smoothed camera-follow
	# loop stops running — in DETACHED mode the pivot is a top-level node
	# and would freeze in world space, detaching from the swinging body.
	# Pin the pivot to the body as a plain child for the duration of the
	# swing so it rides along automatically.
	_cached_pivot = body.get_node_or_null(^"CameraPivot") as Node3D
	if _cached_pivot != null:
		_saved_pivot_top_level = _cached_pivot.top_level
		_saved_pivot_local_position = _cached_pivot.position
		var pivot_local: Vector3 = Vector3(0, 1, 0)
		var body_offset: Variant = body.get(&"pivot_offset")
		if body_offset is Vector3:
			pivot_local = body_offset
		_cached_pivot.top_level = false
		_cached_pivot.position = pivot_local

	# Spawn the rope-line renderer into the current scene so it can follow
	# the anchor even if we move between levels (edge case: during swing).
	_line_renderer = _build_line_renderer()
	get_tree().current_scene.add_child(_line_renderer)


func _tick_swing(delta: float) -> void:
	if _anchor == null or not is_instance_valid(_anchor):
		_release()
		return
	var body := _find_body() as Node3D
	if body == null:
		return

	# 1. Gravity pulls the velocity down.
	_vel += Vector3.DOWN * SWING_GRAVITY * delta

	# 2. Asymmetric rope spring: only when stretched beyond rope_length.
	#    Force = -stiffness · stretch · radial - damping · radial_velocity.
	#    Radial points anchor→player, so the -radial direction pulls inward.
	var anchor_pos: Vector3 = _anchor.global_position
	var offset: Vector3 = body.global_position - anchor_pos
	var dist: float = offset.length()
	if dist > _rope_length and dist > 0.001:
		var radial: Vector3 = offset / dist
		var stretch: float = dist - _rope_length
		var radial_speed: float = _vel.dot(radial)
		var spring_accel: Vector3 = -radial * (rope_stiffness * stretch)
		var damping_accel: Vector3 = -radial * (rope_damping * radial_speed)
		_vel += (spring_accel + damping_accel) * delta
	# else: slack rope, no constraint force.

	# 3. Integrate position.
	var new_pos: Vector3 = body.global_position + _vel * delta

	# 4. Safety clamp: never let stretch exceed MAX_STRETCH. Catches the case
	#    where tuning is too soft and the spring can't pull back fast enough.
	var to_new: Vector3 = new_pos - anchor_pos
	var max_dist: float = _rope_length + MAX_STRETCH
	if to_new.length() > max_dist:
		var clamp_radial: Vector3 = to_new.normalized()
		new_pos = anchor_pos + clamp_radial * max_dist
		var radial_speed_clamp: float = _vel.dot(clamp_radial)
		if radial_speed_clamp > 0.0:
			_vel -= clamp_radial * radial_speed_clamp

	body.global_position = new_pos


func _release() -> void:
	var body := _find_body()
	# Hand the Verlet velocity straight to PlayerBody, plus a small up kick
	# so letting go at the apex feels like a jump instead of an instant fall.
	var release_velocity: Vector3 = _vel + Vector3.UP * RELEASE_UP_KICK

	_swinging = false
	_anchor = null
	if _line_renderer != null and is_instance_valid(_line_renderer):
		_line_renderer.queue_free()
	_line_renderer = null

	# Restore the camera pivot to whatever mode PlayerBody was in (top-level
	# for DETACHED, parented for PARENTED). _physics_process resuming below
	# takes over the smoothed follow from here.
	if _cached_pivot != null and is_instance_valid(_cached_pivot):
		_cached_pivot.top_level = _saved_pivot_top_level
		_cached_pivot.position = _saved_pivot_local_position
	_cached_pivot = null

	if body == null:
		return
	if body is CharacterBody3D:
		(body as CharacterBody3D).velocity = release_velocity
	body.set_physics_process(true)
	# Snap the camera to the body's new position so DETACHED mode doesn't
	# start from a stale pivot transform on the next frame.
	if body.has_method(&"_snap_camera_to_player"):
		body.call(&"_snap_camera_to_player")


# ── Line renderer ───────────────────────────────────────────────────────

func _build_line_renderer() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.4, 0.85, 1)
	mat.emission_enabled = true
	mat.emission = Color(0.9, 0.4, 0.85, 1)
	mat.emission_energy_multiplier = 2.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mi.material_override = mat
	return mi


func _update_line_visual() -> void:
	if _line_renderer == null or _anchor == null or not is_instance_valid(_anchor):
		return
	var body := _find_body() as Node3D
	if body == null:
		return
	var im := _line_renderer.mesh as ImmediateMesh
	if im == null:
		return
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	im.surface_add_vertex(body.global_position + Vector3.UP * 1.2)
	im.surface_add_vertex(_anchor.global_position)
	im.surface_end()
