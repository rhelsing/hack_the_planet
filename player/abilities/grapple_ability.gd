class_name GrappleAbility
extends Ability

## Grapple hook with a physically simulated rope chain that DRIVES the player.
##
## Rope = N RigidBody3D segments connected by PinJoint3Ds. First segment
## pinned to a StaticBody3D at the hook; last segment pinned to a free-
## simulating RigidBody3D ("player proxy") which the player character then
## tracks each physics tick. All player motion during the swing emerges from
## the chain's physics — gravity, chain tension, pin constraints — not from
## a hand-written spring equation.
##
## On release: we read the proxy's linear_velocity and hand it off to
## PlayerBody.velocity (plus a small up kick) so letting go flings you along
## the swing's tangent.
##
## Fallback: grapple_ability_spring.gd holds the previous asymmetric-spring
## implementation. Swap scripts on PlayerBody/Abilities/GrappleAbility in
## player_body.tscn to revert.

# ── Tunables ────────────────────────────────────────────────────────────

const MAX_RANGE: float = 25.0
const FACING_COS: float = 0.7
const RELEASE_UP_KICK: float = 5.0

## rope_length = (current_distance - pull_in), clamped to min_rope_length.
## Higher pull_in = bigger "yank" toward anchor; 0 = rope starts at current
## distance.
@export_range(0.0, 10.0, 0.25) var pull_in: float = 8.0
## Hard floor on rope length (m). Prevents collapsing onto the anchor on
## close-range shots.
@export_range(1.0, 15.0, 0.25) var min_rope_length: float = 3.75
## Number of physical segments making up the rope. Higher = smoother drape,
## more physics cost. Lower = chunkier, snappier rope.
@export_range(2, 20) var rope_segments: int = 7
## Mass per segment (kg). Heavier segments feel more like a weighted chain;
## lighter segments keep the rope whippy.
@export_range(0.01, 1.0, 0.01) var rope_segment_mass: float = 1.0
## Mass of the player proxy that hangs off the chain end (kg). Heavier = the
## swing feels weightier, rope pulls harder; lighter = whippier.
@export_range(0.1, 5.0, 0.1) var player_proxy_mass: float = 0.1
## Linear damping on the player proxy. 0 = zero friction, swing forever.
## ~0.1–0.3 reads as energetic but not jittery.
@export_range(0.0, 2.0, 0.05) var player_proxy_damp: float = 0.0


# ── Aim state ───────────────────────────────────────────────────────────

var _aim_target: Node3D = null


# ── Swing state ─────────────────────────────────────────────────────────

var _swinging: bool = false
var _anchor: Node3D = null
var _rope_length: float = 0.0
var _line_renderer: MeshInstance3D = null

# Physical rope chain
var _anchor_proxy: StaticBody3D = null
var _player_proxy: RigidBody3D = null
var _rope_bodies: Array[RigidBody3D] = []
var _rope_joints: Array[Node] = []

# Camera pivot bookkeeping
var _cached_pivot: Node3D = null
var _saved_pivot_top_level: bool = false
var _saved_pivot_local_position: Vector3 = Vector3.ZERO


func _ready() -> void:
	if ability_id == &"":
		ability_id = &"GrappleAbility"
	if powerup_flag == &"":
		powerup_flag = &"powerup_sex"
	super._ready()
	_register_debug_sliders()


func _register_debug_sliders() -> void:
	var dp := get_tree().root.get_node_or_null(^"DebugPanel")
	if dp == null:
		return
	dp.add_slider("Grapple/pull_in", 0.0, 10.0, 0.25,
		func() -> float: return pull_in,
		func(v: float) -> void: pull_in = v)
	dp.add_slider("Grapple/min_rope_length", 1.0, 15.0, 0.25,
		func() -> float: return min_rope_length,
		func(v: float) -> void: min_rope_length = v)
	dp.add_slider("Grapple/rope_segments", 2, 20, 1,
		func() -> float: return float(rope_segments),
		func(v: float) -> void: rope_segments = int(v))
	dp.add_slider("Grapple/rope_segment_mass", 0.01, 1.0, 0.01,
		func() -> float: return rope_segment_mass,
		func(v: float) -> void: rope_segment_mass = v)
	dp.add_slider("Grapple/player_proxy_mass", 0.1, 5.0, 0.1,
		func() -> float: return player_proxy_mass,
		func(v: float) -> void: player_proxy_mass = v)
	dp.add_slider("Grapple/player_proxy_damp", 0.0, 2.0, 0.05,
		func() -> float: return player_proxy_damp,
		func(v: float) -> void: player_proxy_damp = v)


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
		if dot > best_score:
			best_score = dot
			best = t
	if best != null:
		_set_target_prompt(best, true)
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

	var offset: Vector3 = body_3d.global_position - anchor_pos
	var current_distance: float = offset.length()
	var raw_rope: float = current_distance - pull_in
	var clamped: bool = raw_rope < min_rope_length
	_rope_length = maxf(raw_rope, min_rope_length)
	print("[grapple] fire: anchor=%s player=%s dist=%.2f rope=%.2f clamped=%s" % [
		anchor_pos, body_3d.global_position, current_distance, _rope_length, clamped,
	])

	# Capture approach velocity. It's seeded onto the player proxy so the
	# chain "inherits" the momentum the player came in with.
	var approach_vel: Vector3 = Vector3.ZERO
	if body is CharacterBody3D:
		approach_vel = (body as CharacterBody3D).velocity

	# If the player is currently beyond rope_length, pre-snap them inward.
	# Proxy will be seeded at this position + approach_vel.
	var offset_dir: Vector3 = offset.normalized() if offset.length_squared() > 0.01 else Vector3.DOWN
	if offset.length() > _rope_length:
		body_3d.global_position = anchor_pos + offset_dir * _rope_length
		var radial_speed: float = approach_vel.dot(offset_dir)
		if radial_speed > 0.0:
			approach_vel -= offset_dir * radial_speed

	# Freeze the CharacterBody3D so its own physics doesn't fight the chain.
	# We'll overwrite global_position each tick from the proxy.
	body.set_physics_process(false)
	if body is CharacterBody3D:
		(body as CharacterBody3D).velocity = Vector3.ZERO

	# Camera: pin pivot as a regular child so it follows the body (which
	# follows the proxy). DETACHED top_level mode would otherwise freeze the
	# pivot in world space.
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

	_spawn_rope_chain(anchor_pos, body_3d.global_position, approach_vel)

	_line_renderer = _build_line_renderer()
	get_tree().current_scene.add_child(_line_renderer)


func _tick_swing(delta: float) -> void:
	if _anchor == null or not is_instance_valid(_anchor):
		_release()
		return
	if _player_proxy == null or not is_instance_valid(_player_proxy):
		_release()
		return
	var body := _find_body() as Node3D
	if body == null:
		return
	# The chain physics moved the proxy this tick. Snap the character body
	# to match so the camera, skin, and attack sweeps all follow the proxy.
	body.global_position = _player_proxy.global_position


func _release() -> void:
	var body := _find_body()
	# Release velocity is the proxy's linear velocity (the physical swing
	# result) plus a small up kick so letting go at apex reads as a jump.
	var release_velocity: Vector3 = Vector3.UP * RELEASE_UP_KICK
	if _player_proxy != null and is_instance_valid(_player_proxy):
		release_velocity = _player_proxy.linear_velocity + Vector3.UP * RELEASE_UP_KICK

	_swinging = false
	_anchor = null
	if _line_renderer != null and is_instance_valid(_line_renderer):
		_line_renderer.queue_free()
	_line_renderer = null

	_tear_down_rope_chain()

	# Only restore top_level. Don't restore the saved position — that value
	# was captured before the swing and is now stale; _snap_camera_to_player
	# below sets the correct current position.
	if _cached_pivot != null and is_instance_valid(_cached_pivot):
		_cached_pivot.top_level = _saved_pivot_top_level
	_cached_pivot = null

	if body == null:
		return
	if body is CharacterBody3D:
		(body as CharacterBody3D).velocity = release_velocity
	body.set_physics_process(true)
	if body.has_method(&"_snap_camera_to_player"):
		body.call(&"_snap_camera_to_player")


# ── Physical rope chain ─────────────────────────────────────────────────

func _spawn_rope_chain(anchor_pos: Vector3, player_pos: Vector3, seed_vel: Vector3) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return

	# Anchor proxy: StaticBody3D at the hook. PinJoint3D needs a body.
	_anchor_proxy = StaticBody3D.new()
	_anchor_proxy.collision_layer = 0
	_anchor_proxy.collision_mask = 0
	scene.add_child(_anchor_proxy)
	_anchor_proxy.global_position = anchor_pos

	# Rope segments laid straight from anchor to player. Gravity + joints
	# pull them into a natural drape over the first few ticks.
	var seg_count: int = rope_segments
	var step: Vector3 = (player_pos - anchor_pos) / float(seg_count)

	var prev_body: PhysicsBody3D = _anchor_proxy
	for i in range(seg_count):
		var seg := RigidBody3D.new()
		seg.collision_layer = 0
		seg.collision_mask = 0
		seg.mass = rope_segment_mass
		seg.gravity_scale = 1.0
		seg.linear_damp = 0.4
		seg.angular_damp = 0.4
		var shape := CollisionShape3D.new()
		var s := SphereShape3D.new()
		s.radius = 0.04
		shape.shape = s
		seg.add_child(shape)
		scene.add_child(seg)
		seg.global_position = anchor_pos + step * (float(i) + 0.5)
		_rope_bodies.append(seg)

		var joint := PinJoint3D.new()
		scene.add_child(joint)
		joint.global_position = anchor_pos + step * float(i)
		joint.node_a = prev_body.get_path()
		joint.node_b = seg.get_path()
		_rope_joints.append(joint)

		prev_body = seg

	# Player proxy: FREE-simulating RigidBody3D at the end of the chain. The
	# player character tracks its position each tick, so chain tension +
	# gravity (propagated through pin joints) become the player's motion.
	_player_proxy = RigidBody3D.new()
	_player_proxy.collision_layer = 0
	_player_proxy.collision_mask = 0
	_player_proxy.mass = player_proxy_mass
	_player_proxy.gravity_scale = 1.0
	_player_proxy.linear_damp = player_proxy_damp
	_player_proxy.angular_damp = player_proxy_damp
	var proxy_shape := CollisionShape3D.new()
	var ps := SphereShape3D.new()
	ps.radius = 0.2
	proxy_shape.shape = ps
	_player_proxy.add_child(proxy_shape)
	scene.add_child(_player_proxy)
	_player_proxy.global_position = player_pos
	# Seed with the player's pre-grapple velocity — chain inherits momentum.
	_player_proxy.linear_velocity = seed_vel

	var final_joint := PinJoint3D.new()
	scene.add_child(final_joint)
	final_joint.global_position = player_pos
	final_joint.node_a = _rope_bodies[-1].get_path()
	final_joint.node_b = _player_proxy.get_path()
	_rope_joints.append(final_joint)


func _tear_down_rope_chain() -> void:
	for j in _rope_joints:
		if is_instance_valid(j):
			j.queue_free()
	_rope_joints.clear()
	for b in _rope_bodies:
		if is_instance_valid(b):
			b.queue_free()
	_rope_bodies.clear()
	if _player_proxy != null and is_instance_valid(_player_proxy):
		_player_proxy.queue_free()
	_player_proxy = null
	if _anchor_proxy != null and is_instance_valid(_anchor_proxy):
		_anchor_proxy.queue_free()
	_anchor_proxy = null


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
	# Draw: anchor → each rope segment → player (head-height). The segments
	# physically simulate, so the line will bend/sag with their motion.
	im.surface_add_vertex(_anchor.global_position)
	for seg in _rope_bodies:
		if is_instance_valid(seg):
			im.surface_add_vertex(seg.global_position)
	im.surface_add_vertex(body.global_position + Vector3.UP * 1.2)
	im.surface_end()
