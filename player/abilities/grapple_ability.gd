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
## Gravity multiplier on the player proxy during the swing. >1 = the swing
## arcs tighter and "sucks down" — combined with rope tension, the player
## gets yanked toward the anchor AND down before the launch fires.
@export_range(0.5, 5.0, 0.1) var swing_gravity_scale: float = 2.0
## When the player fires from ABOVE the anchor, both gravity and the chain
## point straight down — there's no swing arc, just a fall onto the rope.
## This impulse forces the proxy's seed Y velocity up to at least this value
## so the swing kicks off with upward motion, even from above. 0 = disabled.
@export_range(0.0, 30.0, 0.5) var above_anchor_up_impulse: float = 12.0

@export_group("Too-close stretch")
## When the player fires from very close to a grappleable, the natural
## swing arc collapses — short rope after pull_in, tiny radius, no
## momentum. These two clamps virtually relocate the body outward at fire
## time so a real pendulum can establish itself. They only activate when
## the actual offset is BELOW the threshold; normal-range grapples
## bypass this block entirely and behave identically to before.
##
## Example: anchor 10m above and 2m forward of player → offset (~10.2m,
## ~11° from vertical → tiny swing). After stretch with the defaults
## below, body is virtually placed at ~17m / ~33° from vertical so the
## chain spawns with a real arc to swing through.
##
## Either clamp set to 0 disables that leg.

## Minimum total distance from anchor at fire. If the player fires from
## closer, the body's world position is pushed out along the same offset
## direction to this distance.
@export_range(0.0, 30.0, 0.5) var min_effective_distance: float = 15.0
## Minimum horizontal (XZ) component of the offset at fire. Ensures real
## pendulum arc even when firing from directly under or above. After the
## radial clamp, if horizontal is still too small, the body is pushed
## sideways along the existing horizontal direction (or the body's
## forward axis as a fallback when firing from straight under/over).
@export_range(0.0, 20.0, 0.5) var min_effective_horizontal: float = 8.0

@export_group("Release launch")
## Vertical kick on release. Always applied so apex-release reads as a jump.
@export_range(0.0, 20.0, 0.25) var release_up_kick: float = 5.0
## Horizontal kick on release, along the direction from anchor → player at
## the moment of fire (the "side you were on"). Sends you launching out from
## that side rather than continuing the chaotic swing tangent.
@export_range(0.0, 30.0, 0.25) var release_lateral_kick: float = 8.0
## How much of the chain proxy's chaotic swing velocity blends into the
## release. 0 = pure deterministic up + lateral kick (most predictable).
## 1 = pure proxy velocity (organic but unpredictable). 0.0 default makes
## the launch always read the same way.
@export_range(0.0, 1.0, 0.05) var release_velocity_inherit: float = 0.0
@export_group("")


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

# Horizontal direction from anchor → player at the moment of fire. Used to
# bias the release launch back toward the side the player came in from,
# regardless of where the swing actually carried them.
var _launch_side_dir: Vector3 = Vector3.FORWARD

# True when the player fired from ABOVE the anchor. Switches the proxy into
# a no-gravity hover so the swing doesn't free-fall onto the rope and lose
# all the altitude before release fires.
var _above_anchor_mode: bool = false

# Long-running "swing whole time until landing" audio. Started on rope-bite,
# stopped when the player's body becomes is_on_floor() AFTER the swing has
# released. Tracked separately from the one-shot fire/bite cues because it
# needs a stop handle and outlives the rope itself (continues through the
# post-release flight until ground contact).
const _SWING_AUDIO_PATH: String = "res://audio/sfx/grapple/grapples_playing_whole_time_until_landing.mp3"
var _swing_audio_player: AudioStreamPlayer = null
# True from rope-bite until the post-release flight ends on the ground.
# `_swinging` flips false on _release; this stays true until landing so the
# _process loop knows the swing-audio still owes us a stop.
var _swing_audio_active: bool = false


func _ready() -> void:
	if ability_id == &"":
		ability_id = &"GrappleAbility"
	if powerup_flag == &"":
		powerup_flag = &"powerup_sex"
	super._ready()
	_register_debug_sliders()
	# Long-form swing audio gets its own player so we can start/stop it on
	# command. SFX bus so the music duck doesn't squash it; load on demand
	# rather than preload so the initial scene parse doesn't pay for it.
	_swing_audio_player = AudioStreamPlayer.new()
	_swing_audio_player.bus = &"SFX"
	_swing_audio_player.stream = load(_SWING_AUDIO_PATH) as AudioStream
	add_child(_swing_audio_player)


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
	dp.add_slider("Grapple/swing_gravity_scale", 0.5, 5.0, 0.1,
		func() -> float: return swing_gravity_scale,
		func(v: float) -> void: swing_gravity_scale = v)
	dp.add_slider("Grapple/release_up_kick", 0.0, 20.0, 0.25,
		func() -> float: return release_up_kick,
		func(v: float) -> void: release_up_kick = v)
	dp.add_slider("Grapple/release_lateral_kick", 0.0, 30.0, 0.25,
		func() -> float: return release_lateral_kick,
		func(v: float) -> void: release_lateral_kick = v)
	dp.add_slider("Grapple/release_velocity_inherit", 0.0, 1.0, 0.05,
		func() -> float: return release_velocity_inherit,
		func(v: float) -> void: release_velocity_inherit = v)
	dp.add_slider("Grapple/above_anchor_up_impulse", 0.0, 30.0, 0.5,
		func() -> float: return above_anchor_up_impulse,
		func(v: float) -> void: above_anchor_up_impulse = v)


# ── Frame-level updates ─────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if not owned:
		return
	if _swinging:
		_update_line_visual()
	else:
		_update_aim()
	# Swing audio outlives the rope. Started on bite, stopped here when
	# the player has released AND landed back on the ground. Polling
	# is_on_floor each frame is cheap (a flag read on CharacterBody3D).
	if _swing_audio_active and not _swinging:
		var body := _find_body()
		if body == null or (body is CharacterBody3D and (body as CharacterBody3D).is_on_floor()):
			if _swing_audio_player != null and _swing_audio_player.playing:
				_swing_audio_player.stop()
			_swing_audio_active = false


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
	# Three-event grapple SFX: fire (the whip-out attack), bite (the
	# anchor-lock impact, fired below right after the rope physics spawn),
	# release (in _release). Cues registered in audio/cue_registry.tres;
	# stream pools currently empty so play_sfx silently no-ops until the
	# user drops audio files into the .tres files.
	Audio.play_sfx(&"grapple_fire")

	_anchor = target
	_swinging = true
	var anchor_pos: Vector3 = target.global_position

	var offset: Vector3 = body_3d.global_position - anchor_pos
	# Too-close stretch — virtually push the body outward when firing from
	# inside the swing-arc minimum. Both clamps are bottom-only: they
	# branch out only if the actual offset is below the threshold, so
	# normal-range grapples skip this block entirely.
	var stretched: bool = false
	if min_effective_distance > 0.0 \
			and offset.length() > 0.001 \
			and offset.length() < min_effective_distance:
		offset = offset.normalized() * min_effective_distance
		stretched = true
	if min_effective_horizontal > 0.0:
		var horiz: Vector3 = Vector3(offset.x, 0.0, offset.z)
		var horiz_dist: float = horiz.length()
		if horiz_dist < min_effective_horizontal:
			# Pick the horizontal direction to grow into. Existing
			# horizontal preferred (preserves intent); fall back to the
			# body's forward axis (-Z) when firing straight under/over.
			var horiz_dir: Vector3
			if horiz_dist > 0.001:
				horiz_dir = horiz.normalized()
			else:
				horiz_dir = -body_3d.global_basis.z
				horiz_dir.y = 0.0
				if horiz_dir.length_squared() > 0.001:
					horiz_dir = horiz_dir.normalized()
				else:
					horiz_dir = Vector3.FORWARD
			offset += horiz_dir * (min_effective_horizontal - horiz_dist)
			stretched = true
	if stretched:
		body_3d.global_position = anchor_pos + offset
		print("[grapple] too-close stretch: offset=%s dist=%.2f" % [
			offset, offset.length()])
	_above_anchor_mode = offset.y > 0.0
	var current_distance: float = offset.length()
	# Capture the side the player was on (horizontal-only). Release uses this
	# to launch them back out toward where they came from, ignoring whatever
	# tangent the chaotic chain physics happened to land on.
	var horiz_offset: Vector3 = Vector3(offset.x, 0.0, offset.z)
	if horiz_offset.length_squared() > 0.0001:
		_launch_side_dir = horiz_offset.normalized()
	else:
		_launch_side_dir = Vector3.FORWARD
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

	# Above the anchor = both gravity and chain point straight down → no
	# swing arc, just a fall onto the rope. Force the proxy's seed Y velocity
	# up to `above_anchor_up_impulse` so even an above-anchor grapple kicks
	# off going up. APPLIED AFTER the radial strip above — when above the
	# anchor, "away from anchor" IS up, so the strip would otherwise eat the
	# entire impulse the moment we add it.
	if offset.y > 0.0 and above_anchor_up_impulse > 0.0:
		approach_vel.y = maxf(approach_vel.y, above_anchor_up_impulse)
	print("[grapple] above=%s approach_vel=%s" % [offset.y > 0.0, approach_vel])

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
	# Bite — rope just anchored to the target. Layered on top of fire in
	# the same frame; the audio sample envelopes give the ear "throw …
	# thunk." Insert a deferred timer here if a longer beat is needed.
	Audio.play_sfx(&"grapple_bite")
	# Long-form swing audio kicks in here and runs until the player lands
	# on the ground after release (poll in _process). Stop any prior swing
	# audio first in case a rapid re-grapple is firing before the previous
	# stop condition was met.
	if _swing_audio_player != null:
		if _swing_audio_player.playing:
			_swing_audio_player.stop()
		_swing_audio_player.play()
		_swing_audio_active = true
	# Animation: at-bite → "Falling Idle" (mapped to WallSlide state on AjSkin)
	# for the swing-hang pose. After 2s, transition to Fall so the held
	# pose breathes; the post-release flight then continues in Fall until
	# PlayerBody's normal physics-driven state takes over on landing.
	_play_grapple_bite_anim(body)

	_line_renderer = _build_line_renderer()
	get_tree().current_scene.add_child(_line_renderer)


func _play_grapple_bite_anim(body: Node) -> void:
	var skin: Variant = body.get(&"_skin")
	if skin == null or not is_instance_valid(skin):
		return
	if skin.has_method(&"wall_slide"):
		skin.call(&"wall_slide")
	await get_tree().create_timer(2.0, true).timeout
	# Player may have released before the timer fired — body's physics_process
	# is back on and driving the skin from velocity, so don't fight it.
	if not _swinging:
		return
	if not is_instance_valid(skin):
		return
	if skin.has_method(&"fall"):
		skin.call(&"fall")


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
	# No release-specific cue in the v2 audio model — the swing-loop
	# audio (started on bite) is what carries the player through release
	# and continues until they land on the ground (stopped by _process).
	var body := _find_body()
	# Deterministic launch: always up + out from the side the player was on
	# at fire. The chain's chaotic swing velocity is optionally blended in
	# via release_velocity_inherit (0 = canned, 1 = pure organic swing).
	var release_velocity: Vector3 = (
		Vector3.UP * release_up_kick
		+ _launch_side_dir * release_lateral_kick
	)
	if release_velocity_inherit > 0.0 \
			and _player_proxy != null and is_instance_valid(_player_proxy):
		release_velocity += _player_proxy.linear_velocity * release_velocity_inherit
	print("[grapple] release: above=%s vel=%s body_y=%s" % [
		_above_anchor_mode,
		release_velocity,
		(body as Node3D).global_position.y if body is Node3D else 0.0,
	])
	_above_anchor_mode = false

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
	# Above-anchor: zero gravity + heavy damp → the proxy hovers and gets
	# pulled horizontally toward the anchor by rope tension only, no
	# free-fall. This is what lets release-from-above actually read as up.
	# Below-anchor: swing_gravity_scale > 1 for the normal "yank toward and
	# down" pendulum that loads up the spring before release.
	if _above_anchor_mode:
		_player_proxy.gravity_scale = 0.0
		_player_proxy.linear_damp = 1.5
	else:
		_player_proxy.gravity_scale = swing_gravity_scale
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
