class_name EnemyAIBrain
extends Brain

## AI driver for hostile pawns. Wanders with curiosity, switches to CHASE
## when the target enters detection range, triggers attack when in strike
## range. Produces a full Intent directly (fraction-of-max_speed semantics
## so magnitude 0.33 = 1/3 speed wander, 1.0 = full-speed chase).

@export_group("Detection")
@export var detection_radius := 16.0
## Chase ends at this distance. Must exceed detection_radius (hysteresis
## prevents flicker at the boundary).
@export var chase_exit_radius := 22.0
## Groups whose members are valid targets. Multi-group so factions can
## target multiple opposing factions (e.g. allies hit both `enemies` and
## `splice_enemies`). PlayerBody.set_faction() rewrites this at runtime
## per the faction targeting table. Inspector default keeps existing
## "hit the player" behavior for old enemy variants without faction set.
@export var target_groups: Array[StringName] = [&"player"]

@export_group("Vision Cone")
## Half-angle in degrees of the FOV cone. 0 = omnidirectional (default,
## existing swarm behavior). 45 = 90° total cone. Targets outside the
## cone aren't acquired even within detection_radius.
@export_range(0.0, 180.0) var vision_cone_deg: float = 0.0
## Show the vision cone as a translucent fan. Material writes depth via
## TRANSPARENCY_ALPHA_DEPTH_PRE_PASS so walls properly occlude it (no
## ghost fan poking through cover). Auto-on for stealth variants.
@export var vision_debug_visible: bool = false
## Vertical offset (m) where the cone fan is drawn AND where the slice
## raycasts originate. The visible fan IS the LOS volume — sharing this
## height means low cover blocks detection visibly. ~0.9-1.0 = waist
## (recommended for stealth), 1.4 = chest (sees over short cover).
@export var vision_eye_height: float = 1.0
## Seconds for the cone to swivel toward _direction (lerp). 0 = instant
## snap; higher = smoother turn. ~0.15 reads natural for patrol AI.
@export_range(0.0, 1.0) var vision_swivel_smoothing: float = 0.15

@export_group("Vision Cone Stealth")
## When true and the cone is enabled (vision_cone_deg > 0), a crouched
## target is treated as invisible — the cone won't acquire them.
## Player crouch state read via PlayerBody._was_crouched (stealth-game
## sneaking pattern). Off = crouching is irrelevant (still detected).
@export var crouch_makes_invisible: bool = true
## Seconds the cone holds in SUSPECT (yellow) before promoting to HOSTILE
## (red, chase). Player has this long to break LOS / crouch out before
## they snap into pursuit. 0 = snap immediately (swarm AI default).
@export var suspect_duration: float = 3.0
## Maximum seconds in HOSTILE (chase). After this many seconds in CHASE,
## the brain "tuckers out" and drops back to ALERT then CALM. 0 = never
## tuckers (chase forever — swarm default).
@export var chase_max_duration: float = 8.0

@export_group("Vision Cone Colors")
## Color while no target is in view (calm patrol). Half-transparent.
@export var color_calm: Color = Color(0.0, 0.85, 0.0, 0.30)
## Color during the post-CHASE alert window (target was visible, now
## lost — they're scanning). Lasts `alert_duration` then fades to calm.
@export var color_alert: Color = Color(0.95, 0.85, 0.0, 0.35)
## Color while actively chasing (target visible, hostile lock).
@export var color_hostile: Color = Color(0.95, 0.0, 0.0, 0.40)
## Seconds the cone stays alert (yellow) after losing the target before
## relaxing back to calm (green).
@export var alert_duration: float = 3.0
## Seconds for the cone color to crossfade between phase changes. 0 =
## instant pop; ~0.25 reads as a beat of "wait, what?" before locking on.
@export var color_blend_time: float = 0.25

@export_group("Vision Cone Audio")
## Played once when transitioning from calm/alert → hostile (target acquired).
@export var sound_acquire: AudioStream
## Played once when transitioning from hostile → alert (target lost).
@export var sound_lose: AudioStream
## Played once when transitioning from alert → calm (back to patrol).
@export var sound_relax: AudioStream

@export_group("Speed")
## Fraction of body's max_speed used while wandering. 0 = stand still.
@export_range(0.0, 1.0) var wander_speed_fraction := 0.33
## Fraction of body's max_speed used while chasing. 1.0 = full speed.
@export_range(0.0, 1.0) var chase_speed_fraction := 1.0

@export_group("Wander")
@export var min_wander_interval := 1.0
@export var max_wander_interval := 3.0
## Probability the enemy reorients when the wander interval elapses.
## 0 = only turns at walls/ledges. 1 = reorients every interval.
@export_range(0.0, 1.0) var curiosity := 0.7
## Max swing (degrees) when reorienting. Small = gentle meander, 180 = free reverse.
@export_range(0.0, 180.0) var max_turn_deg := 130.0

@export_group("Attack")
## Fire intent.attack_pressed when target is within this horizontal range.
@export var attack_range := 2.0
## Max vertical distance at which the AI will try to attack. Matches the
## body's attack_vertical_range — no point firing a swing if the sweep would
## miss anyway because the player is airborne overhead.
@export var attack_vertical_range := 1.5
## Seconds between consecutive attack triggers.
@export var attack_cooldown := 1.6
## Wind-up phase before the swing fires — the AI slows to wind_up_speed_fraction
## and holds for this many seconds. This is the player's punish window.
## 0.0 disables the wind-up (instant attacks).
@export var wind_up_duration := 0.55
## Fraction of chase speed maintained during wind-up. 0 = full stop,
## 0.15 = slow creep (still drifting toward target as they wind up).
@export_range(0.0, 1.0) var wind_up_speed_fraction := 0.15

@export_group("Follow")
## When non-empty AND no enemy is in detection range, the brain walks
## toward the nearest node in this group instead of pure-random wander.
## Used by ally pawns (faction "gold") set via PlayerBody.set_faction —
## they follow the player around and idle near them. Empty = pure wander.
@export var follow_subject_group: StringName = &""
## Stop-and-idle gap. When closer than this to the follow subject, the
## brain idles in place; when farther, it walks toward the subject.
@export var follow_distance: float = 3.0

@export_group("Ledges")
@export var turn_at_ledges := true
@export var ledge_probe_distance := 1.5
## Drop depth (m) below the future foot point that still counts as "ground" —
## walks down stair steps shallower than this, treats anything deeper as a
## ledge and turns. 0.5 ≈ tall step. Bump up for sloppy stairs that read as
## ledges; bump down to make enemies skittish around small drops.
@export var ledge_probe_depth := 0.5

enum State { WANDER, CHASE, IDLE, WIND_UP }

@export_group("State")
## Behavior the enemy returns to when no target is in range. WANDER = meander
## with curiosity rerolls. IDLE = stand in place facing forward. Both react
## the same to a target entering detection range (→ CHASE).
@export var starting_state: State = State.WANDER

var _state: State = State.WANDER
var _direction := Vector3.RIGHT
var _wander_timer := 0.0
var _attack_cooldown_timer := 0.0
var _wind_up_timer := 0.0
var _target: Node3D
var _intent := Intent.new()
# Debug-viz fan mesh. Attached to the body so its transform follows the
# pawn; rotated each tick to match _direction so the cone points where
# the brain is looking. Built lazily on first tick when vision_debug_visible.
var _vision_cone_mesh: MeshInstance3D = null
# Smoothed yaw the cone tracks toward via lerp_angle each tick. Avoids
# the snappy direction-flip that happens when the brain rerolls wander.
var _vision_cone_yaw: float = 0.0
# Smoothed color tracking _vision_cone_color_target via lerp each tick.
var _vision_cone_color_current: Color = Color(0.0, 0.85, 0.0, 0.30)
var _vision_cone_color_target: Color = Color(0.0, 0.85, 0.0, 0.30)
# Three-phase alert state. Mirrors color: calm (green), alert (yellow,
# brief post-CHASE scan), hostile (red, in CHASE). Sounds fire on each
# transition. _alert_timer counts down the alert→calm window.
enum _AlertPhase { CALM, SUSPECT, HOSTILE, ALERT }
var _alert_phase: int = _AlertPhase.CALM
# Used by SUSPECT (counts up to suspect_duration → promote to HOSTILE),
# HOSTILE (counts up to chase_max_duration → tucker out), and ALERT
# (counts down to 0 → relax to CALM). Single var, repurposed per phase.
var _alert_timer: float = 0.0
# 3D audio player attached to the body for phase-transition sounds.
# Lazy-built first time we play anything — no allocation cost for
# enemies that don't have sound exports configured.
var _vision_audio: AudioStreamPlayer3D = null
# Per-tick raycast distances for each cone slice. Index i corresponds to
# angle (-half + step*i) from forward. Drives BOTH the visual fan AND
# the crouched-target detection check — same source of truth so what
# you see is what they see. Empty when vision_cone_deg <= 0 (swarm mode).
const _CONE_SLICES: int = 16
var _slice_distances: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	_direction = Vector3.RIGHT.rotated(Vector3.UP, randf() * TAU)
	_reset_wander_timer()
	_state = starting_state
	# Seed yaw so first-frame slice rays + visual point along _direction
	# instead of swinging from 0 on spawn.
	_vision_cone_yaw = atan2(_direction.x, _direction.z) + PI


func tick(body: Node3D, delta: float) -> Intent:
	# Reset edge flags every tick; only set them true when we fire this frame.
	_intent.move_direction = Vector3.ZERO
	_intent.jump_pressed = false
	_intent.attack_pressed = false
	_attack_cooldown_timer = maxf(0.0, _attack_cooldown_timer - delta)

	# Cone yaw + per-slice raycasts run BEFORE alert phase. _can_see_target
	# (called inside _update_alert_phase) reads _slice_distances; the visual
	# rebuild reads them too. Single shared source.
	_update_vision_yaw(delta)
	_compute_slice_distances(body)

	_update_alert_phase(body, delta)
	_update_vision_debug(body, delta)
	_ensure_target(body)
	_update_state(body)

	match _state:
		State.CHASE:
			_intent.move_direction = _chase_direction(body) * chase_speed_fraction
			_maybe_start_wind_up(body)
		State.WIND_UP:
			_tick_wind_up(body, delta)
		State.IDLE:
			_intent.move_direction = Vector3.ZERO
		_:
			# WANDER: if a follow subject is configured (allies follow the
			# player), home toward them with a stop-and-idle gap. Otherwise
			# fall back to pure-random wander.
			if follow_subject_group != &"":
				_intent.move_direction = _follow_direction(body) * chase_speed_fraction
			else:
				_intent.move_direction = _wander_direction(body, delta) * wander_speed_fraction

	return _intent


func _update_state(_body: Node3D) -> void:
	# Movement state follows the four-phase alert machine: only HOSTILE
	# drives CHASE; CALM/SUSPECT/ALERT all wander. SUSPECT looks visually
	# alarmed via the yellow cone but the brain still patrols normally —
	# the player has those 3 seconds to break LOS or crouch.
	if _target == null:
		_state = starting_state
		return
	if _alert_phase == _AlertPhase.HOSTILE:
		if _state != State.CHASE and _state != State.WIND_UP:
			_state = State.CHASE
	else:
		if _state == State.CHASE or _state == State.WIND_UP:
			_state = starting_state
			_reset_wander_timer()


# Detection check. Two modes selected by `vision_cone_deg`:
#   cone == 0 (swarm)    : pure sphere — in range = detected.
#   cone > 0 (stealth)   : "absolutely impossible without crouching" —
#     standing target is detected anywhere within `range_cap` (full
#     sphere, no cone gate). Crouched target must fall inside a slice
#     whose raycast reached at least the target's distance. The slice
#     rays ARE the LOS check; visual fan and detection share them.
# The SUSPECT phase (3s tolerance) handles the noticing delay — this
# function only reports raw "currently visible" state.
func _can_see_target(body: Node3D, range_cap: float) -> bool:
	if _target == null or not is_instance_valid(_target):
		return false
	var to_target: Vector3 = _target.global_position - body.global_position
	var to_target_flat := Vector3(to_target.x, 0.0, to_target.z)
	var horiz: float = to_target_flat.length()
	if horiz > range_cap:
		return false
	if vision_cone_deg <= 0.0:
		return true  # swarm: sphere detection, no cone
	var crouched: bool = "_was_crouched" in _target and bool(_target.get(&"_was_crouched"))
	if not crouched:
		return true  # standing inside stealth sphere = absolutely seen
	# Crouched: must lie inside the cone AND inside the unblocked extent
	# of whichever slice contains them. A wall touching either bounding
	# ray of the slice clips the slice short and conceals the target.
	if horiz < 0.0001 or _slice_distances.size() < 2:
		return true
	var to_dir: Vector3 = to_target_flat / horiz
	var theta_t: float = atan2(to_dir.x, to_dir.z) + PI
	var a_target: float = angle_difference(_vision_cone_yaw, theta_t)
	var half_rad: float = deg_to_rad(vision_cone_deg)
	if absf(a_target) > half_rad:
		return false  # outside cone arc
	var step: float = (2.0 * half_rad) / float(_CONE_SLICES)
	var slice_f: float = (a_target + half_rad) / step
	var f_idx: int = clampi(int(floor(slice_f)), 0, _slice_distances.size() - 1)
	var c_idx: int = clampi(int(ceil(slice_f)), 0, _slice_distances.size() - 1)
	# Conservative pick: the shorter of the two bounding rays. If a wall
	# is on either side of the target's slice, treat as blocked. Matches
	# how the visual fan visibly shrinks at that slice.
	var slice_dist: float = minf(_slice_distances[f_idx], _slice_distances[c_idx])
	return horiz <= slice_dist


func _chase_direction(body: Node3D) -> Vector3:
	var to_target: Vector3 = _target.global_position - body.global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
		return Vector3.ZERO
	_direction = to_target.normalized()
	# Pressing into walls/ledges while chasing — stall instead of flipping,
	# so the enemy stays aimed at the target.
	if body.has_method("is_on_wall") and body.is_on_wall():
		return Vector3.ZERO
	if turn_at_ledges and body.has_method("is_on_floor") and body.is_on_floor() and not _has_ground_ahead(body):
		return Vector3.ZERO
	return _direction


func _follow_direction(body: Node3D) -> Vector3:
	# Pick the nearest member of follow_subject_group. Returns zero if
	# inside the follow_distance gap — that maps to "idle in place" via
	# move_direction = 0. Returns toward-subject unit vector otherwise.
	var tree := body.get_tree()
	if tree == null:
		return Vector3.ZERO
	var subject: Node3D = null
	var best_dist_sq: float = INF
	for n: Node in tree.get_nodes_in_group(follow_subject_group):
		if not (n is Node3D):
			continue
		var node3d: Node3D = n as Node3D
		var dx: float = node3d.global_position.x - body.global_position.x
		var dz: float = node3d.global_position.z - body.global_position.z
		var dsq: float = dx * dx + dz * dz
		if dsq < best_dist_sq:
			best_dist_sq = dsq
			subject = node3d
	if subject == null:
		return Vector3.ZERO
	var dist: float = sqrt(best_dist_sq)
	if dist <= follow_distance:
		return Vector3.ZERO  # idle inside the gap
	var to_subject: Vector3 = subject.global_position - body.global_position
	to_subject.y = 0.0
	if to_subject.length_squared() < 0.0001:
		return Vector3.ZERO
	return to_subject.normalized()


func _wander_direction(body: Node3D, delta: float) -> Vector3:
	var flipped := false
	if body.has_method("is_on_wall") and body.is_on_wall():
		_direction = -_direction
		flipped = true
	elif turn_at_ledges and body.has_method("is_on_floor") and body.is_on_floor() and not _has_ground_ahead(body):
		_direction = -_direction
		flipped = true

	_wander_timer -= delta
	if _wander_timer <= 0.0:
		# Skip an extra reroll on the frame we just flipped off a wall/ledge.
		if not flipped and randf() < curiosity:
			_pick_random_heading()
		_reset_wander_timer()
	return _direction


func _pick_random_heading() -> void:
	var angle := deg_to_rad(randf_range(-max_turn_deg, max_turn_deg))
	_direction = _direction.rotated(Vector3.UP, angle).normalized()


func _reset_wander_timer() -> void:
	_wander_timer = randf_range(min_wander_interval, max_wander_interval)


func _ensure_target(body: Node3D) -> void:
	if _target != null and is_instance_valid(_target):
		return
	var tree := body.get_tree()
	if tree == null:
		return
	# Walk every target group; first valid Node3D wins. Dedup not needed —
	# we return on first hit. A pawn in two groups would just be picked
	# from whichever group iterates first.
	for grp in target_groups:
		for node: Node in tree.get_nodes_in_group(grp):
			if node is Node3D:
				_target = node
				return


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	var dx := b.x - a.x
	var dz := b.z - a.z
	return sqrt(dx * dx + dz * dz)


## Trigger the wind-up the moment the target enters strike range and the
## cooldown is ready. From WIND_UP, _tick_wind_up handles the actual swing
## fire after wind_up_duration elapses.
func _maybe_start_wind_up(body: Node3D) -> void:
	if _target == null or _attack_cooldown_timer > 0.0:
		return
	var d: float = _horizontal_distance(body.global_position, _target.global_position)
	if d > attack_range:
		return
	var dy: float = absf(_target.global_position.y - body.global_position.y)
	if dy > attack_vertical_range:
		return
	if wind_up_duration <= 0.0:
		# Wind-up disabled — fire immediately (legacy behavior).
		_intent.attack_pressed = true
		_attack_cooldown_timer = attack_cooldown
		return
	_state = State.WIND_UP
	_wind_up_timer = wind_up_duration


## Slow to a creep facing the target while the wind-up timer ticks down.
## On expiry, fire the attack and return to CHASE — cooldown gates the
## next wind-up. The slow phase IS the player's punish window.
func _tick_wind_up(body: Node3D, delta: float) -> void:
	_wind_up_timer -= delta
	# Keep facing/drifting toward the target so they don't visually freeze
	# in a stale heading if the player sidesteps during the wind-up.
	_intent.move_direction = _chase_direction(body) * wind_up_speed_fraction
	if _wind_up_timer <= 0.0:
		_intent.attack_pressed = true
		_attack_cooldown_timer = attack_cooldown
		_state = State.CHASE


func _has_ground_ahead(body: Node3D) -> bool:
	var space := body.get_world_3d().direct_space_state
	var from: Vector3 = body.global_position + _direction * ledge_probe_distance
	var to: Vector3 = from + Vector3.DOWN * ledge_probe_depth
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [(body as CollisionObject3D).get_rid()] if body is CollisionObject3D else []
	return not space.intersect_ray(query).is_empty()


# ---- Vision-cone debug visualization ------------------------------------

# Four-phase state machine — drives cone color + transition sounds AND
# whether the brain is in CHASE state for movement. Phases:
#   CALM (green): no target visible. Wander.
#   SUSPECT (yellow): target seen, building up. Wander, _alert_timer counts
#     up. At suspect_duration → HOSTILE.
#   HOSTILE (red): chasing. _state = CHASE. _alert_timer counts up to
#     chase_max_duration → ALERT (tuckered out). Or target lost → ALERT.
#   ALERT (yellow): post-chase look-around. _alert_timer counts down to 0
#     → CALM.
# When suspect_duration <= 0, CALM → HOSTILE snaps directly (swarm pattern).
# When chase_max_duration <= 0, HOSTILE never tuckers (swarm pattern).
func _update_alert_phase(body: Node3D, delta: float) -> void:
	var prior: int = _alert_phase
	# Re-check visibility against the up-to-date target. Use the chase-exit
	# radius once we're past CALM so target remains "visible" through the
	# hysteresis window — same as the original swarm behavior.
	var range_cap: float = chase_exit_radius if (_alert_phase == _AlertPhase.HOSTILE) else detection_radius
	var visible: bool = _target != null and _can_see_target(body, range_cap)
	match _alert_phase:
		_AlertPhase.CALM:
			if visible:
				if suspect_duration > 0.0 and vision_cone_deg > 0.0:
					_alert_phase = _AlertPhase.SUSPECT
					_alert_timer = 0.0
				else:
					_alert_phase = _AlertPhase.HOSTILE
					_alert_timer = 0.0
		_AlertPhase.SUSPECT:
			if not visible:
				_alert_phase = _AlertPhase.CALM
			else:
				_alert_timer += delta
				if _alert_timer >= suspect_duration:
					_alert_phase = _AlertPhase.HOSTILE
					_alert_timer = 0.0
		_AlertPhase.HOSTILE:
			_alert_timer += delta
			var tuckered: bool = chase_max_duration > 0.0 and _alert_timer >= chase_max_duration
			if not visible or tuckered:
				_alert_phase = _AlertPhase.ALERT
				_alert_timer = alert_duration
		_AlertPhase.ALERT:
			_alert_timer = maxf(0.0, _alert_timer - delta)
			if _alert_timer <= 0.0:
				_alert_phase = _AlertPhase.CALM
	if prior != _alert_phase:
		_on_alert_phase_changed(body, prior, _alert_phase)


# Phase-transition hook: pick the target color for the cone and play the
# matching sound. Color crossfades over color_blend_time; sound fires once.
func _on_alert_phase_changed(body: Node3D, _prior: int, current: int) -> void:
	match current:
		_AlertPhase.HOSTILE:
			_vision_cone_color_target = color_hostile
			_play_phase_sound(body, sound_acquire)
		_AlertPhase.SUSPECT:
			_vision_cone_color_target = color_alert  # yellow buildup
			# No sound — the player needs the 3s window to be uncertain.
		_AlertPhase.ALERT:
			_vision_cone_color_target = color_alert
			_play_phase_sound(body, sound_lose)
		_AlertPhase.CALM:
			_vision_cone_color_target = color_calm
			_play_phase_sound(body, sound_relax)


func _play_phase_sound(body: Node3D, stream: AudioStream) -> void:
	if stream == null:
		return
	if _vision_audio == null or not is_instance_valid(_vision_audio):
		_vision_audio = AudioStreamPlayer3D.new()
		_vision_audio.bus = &"SFX"
		_vision_audio.unit_size = 8.0
		_vision_audio.max_distance = 30.0
		body.add_child(_vision_audio)
	_vision_audio.stream = stream
	_vision_audio.play()


# Smooth the cone yaw toward _direction. Called early in tick() so both
# the slice raycasts and the visual fan use the same up-to-date yaw.
func _update_vision_yaw(delta: float) -> void:
	if vision_cone_deg <= 0.0 and not vision_debug_visible:
		return
	var target_yaw: float = atan2(_direction.x, _direction.z) + PI
	if vision_swivel_smoothing <= 0.0:
		_vision_cone_yaw = target_yaw
	else:
		var k: float = 1.0 - exp(-delta / vision_swivel_smoothing)
		_vision_cone_yaw = lerp_angle(_vision_cone_yaw, target_yaw, k)


# Cast _CONE_SLICES+1 rays from the eye outward at evenly-spaced angles
# spanning the FOV cone. Each ray is clipped at its first wall hit (or
# stays at detection_radius if it hits nothing). The resulting array is
# the single source of truth for both the visible fan AND the crouched-
# target detection check.
func _compute_slice_distances(body: Node3D) -> void:
	if vision_cone_deg <= 0.0:
		if _slice_distances.size() != 0:
			_slice_distances.resize(0)
		return
	var n: int = _CONE_SLICES + 1
	if _slice_distances.size() != n:
		_slice_distances.resize(n)
	var space := body.get_world_3d().direct_space_state
	if space == null:
		for i in range(n):
			_slice_distances[i] = detection_radius
		return
	var origin: Vector3 = body.global_position + Vector3.UP * vision_eye_height
	var forward := Vector3(-sin(_vision_cone_yaw), 0.0, -cos(_vision_cone_yaw))
	var half_rad: float = deg_to_rad(vision_cone_deg)
	var step: float = (2.0 * half_rad) / float(_CONE_SLICES)
	var exclude: Array[RID] = []
	if body is CollisionObject3D:
		exclude.append((body as CollisionObject3D).get_rid())
	for i in range(n):
		var a: float = -half_rad + step * float(i)
		var dir: Vector3 = forward.rotated(Vector3.UP, a)
		var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * detection_radius)
		query.exclude = exclude
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			_slice_distances[i] = detection_radius
		else:
			_slice_distances[i] = origin.distance_to(hit.position as Vector3)


# Position the fan apex at the eye, crossfade the color, then rebuild the
# mesh from this tick's slice distances. top_level decouples the mesh
# from the body's rotation — vertices are emitted in world-aligned local
# space, transform translates only.
func _update_vision_debug(body: Node3D, delta: float) -> void:
	if not vision_debug_visible or vision_cone_deg <= 0.0:
		if _vision_cone_mesh != null and is_instance_valid(_vision_cone_mesh):
			_vision_cone_mesh.queue_free()
			_vision_cone_mesh = null
		return
	if _vision_cone_mesh == null or not is_instance_valid(_vision_cone_mesh):
		_vision_cone_mesh = _build_vision_cone_mesh(body)
		_vision_cone_color_current = _vision_cone_color_target
	_vision_cone_mesh.global_position = body.global_position + Vector3.UP * vision_eye_height
	var ck: float = 1.0
	if color_blend_time > 0.0:
		ck = clampf(delta / color_blend_time, 0.0, 1.0)
	_vision_cone_color_current = _vision_cone_color_current.lerp(_vision_cone_color_target, ck)
	var mat: StandardMaterial3D = _vision_cone_mesh.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = _vision_cone_color_current
	_rebuild_vision_cone_mesh()


func _build_vision_cone_mesh(body: Node3D) -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.mesh = ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color_calm
	# DEPTH_PRE_PASS lets opaque walls correctly occlude the translucent
	# fan. Plain alpha lets the fan bleed through cover.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	inst.material_override = mat
	body.add_child(inst)
	inst.top_level = true
	return inst


# Rebuild the fan as one triangle per slice. Each triangle reaches the
# clipped distance from this tick's slice raycasts — so the visible fan
# IS the LOS volume, slice-for-slice. Walls clip the cone live.
func _rebuild_vision_cone_mesh() -> void:
	if _vision_cone_mesh == null or not is_instance_valid(_vision_cone_mesh):
		return
	var mesh := _vision_cone_mesh.mesh as ImmediateMesh
	if mesh == null:
		return
	mesh.clear_surfaces()
	if _slice_distances.size() < 2:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_rad: float = deg_to_rad(vision_cone_deg)
	var step: float = (2.0 * half_rad) / float(_CONE_SLICES)
	var apex := Vector3.ZERO
	var forward := Vector3(-sin(_vision_cone_yaw), 0.0, -cos(_vision_cone_yaw))
	for i in range(_CONE_SLICES):
		var a0: float = -half_rad + step * float(i)
		var a1: float = -half_rad + step * float(i + 1)
		var dir0: Vector3 = forward.rotated(Vector3.UP, a0)
		var dir1: Vector3 = forward.rotated(Vector3.UP, a1)
		var p0: Vector3 = dir0 * _slice_distances[i]
		var p1: Vector3 = dir1 * _slice_distances[i + 1]
		mesh.surface_add_vertex(apex)
		mesh.surface_add_vertex(p0)
		mesh.surface_add_vertex(p1)
	mesh.surface_end()
