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
## When the target is crouched, this is multiplied by `crouch_suspect_multiplier`.
@export var suspect_duration: float = 3.0
## Maximum seconds in HOSTILE (chase). After this many seconds in CHASE,
## the brain "tuckers out" and drops back to ALERT then CALM. 0 = never
## tuckers (chase forever — swarm default). Only applies in crouched
## stealth mode; standing-target HOSTILE never tuckers (matches red).
@export var chase_max_duration: float = 8.0

@export_group("Stealth Mode")
## Per-pawn opt-in: apply red-faction aggressive buffs (2.5× speed, 99
## damage, invulnerable, attack_cooldown=0, wind_up_duration=0) on entry
## to HOSTILE (chase) state, lift them on exit. Combined with cone vision
## + faction "splice_stealth", this creates a patrol AI that walks 1×
## speed while exploring and bursts to red-class lethality the moment it
## acquires you. Faction stays unchanged — only the gameplay buffs flip.
@export var aggressive_while_chasing: bool = false
## When the target is crouched, the cone's effective range — slice rays
## AND alert/chase-exit radius AND hostile-zone radius — multiply by this
## factor. <1 = crouch SHRINKS the cone (stealth is the safer mode).
## >1 = crouch makes the pawn more vigilant. Default 0.5 = crouch halves
## the cone so the player can sneak past.
@export var crouch_range_multiplier: float = 0.5
## SUSPECT-phase duration multiplier when the target is crouched. 1.0 =
## no crouch effect on the SUSPECT timer.
@export var crouch_suspect_multiplier: float = 1.0
## Inner cone radius (m) where detection skips SUSPECT and snaps directly
## to HOSTILE. 0 = no inner zone (entire cone routes through SUSPECT).
## >0 = two-zone perception (outer SUSPECT yellow, inner HOSTILE red);
## scales by `crouch_range_multiplier` alongside detection_radius.
@export var hostile_zone_radius: float = 0.0

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
@export_range(0.0, 5.0) var chase_speed_fraction := 1.0

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

@export_group("Navigation")
## Navigation strategy. Determines how the brain handles vertical platform
## traversal — jumps up to higher targets, drops down to lower ones, or
## stays grounded entirely. Switchable per brain preset:
##   NONE:      brake at ledges; never jump. Patrol AI / cone-stealth fits.
##   DUMB:      brake at ledges; jump if target is above + on floor. The
##              naive default. Per-target attempt cache prevents spam.
##   SMART:     DUMB + landing-arc raycast (don't fire if no surface lands)
##              + drop-down at ledges when target is below + drop is safe.
##              Handles "follow me up an elevator" and "drop to my platform"
##              scenarios. ~3-5 extra raycasts per chasing pawn per tick.
##   COMPANION: not yet implemented — would use NavigationRegion3D +
##              NavigationLink3D for multi-platform path planning.
enum NavMode { NONE, DUMB, SMART, COMPANION }
@export var nav_mode: NavMode = NavMode.DUMB

@export_subgroup("Jump tuning")
## Minimum y-delta (target.y - body.y) that triggers a jump. Below this,
## the brain trusts walking + elevators to handle the height difference.
## 1.5m matches a single platform step + a comfortable jump apex.
@export var jump_height_threshold: float = 1.5
## Seconds between consecutive jump triggers. Stops the brain from
## hammering the jump button while in mid-air or stuck against a step.
@export var jump_cooldown: float = 0.4

@export_subgroup("SMART tuning")
## Minimum y-delta below body before considering a drop-down. Smaller = more
## aggressive drops, more risk of stepping off small ledges. 1.0m is a
## comfortable "platform-level" gap.
@export var smart_drop_threshold: float = 1.0
## Maximum drop the SMART nav will commit to. Drops exceeding this are
## treated as suicide; sentinel brakes at ledge instead. 8m is a tall fall
## but survivable on most levels.
@export var max_safe_drop: float = 8.0
## How much of the theoretical jump reach the SMART arc-check trusts. The
## body's actual jump arc varies with current speed + frame timing; a
## safety factor < 1.0 prevents marginal jumps that miss by a hair.
@export_range(0.3, 1.0) var smart_jump_safety_factor: float = 0.7

@export_group("Ledges")
@export var turn_at_ledges := true
@export var ledge_probe_distance := 1.5
## Drop depth (m) below the future foot point that still counts as "ground" —
## walks down stair steps shallower than this, treats anything deeper as a
## ledge and turns. 0.5 ≈ tall step. Bump up for sloppy stairs that read as
## ledges; bump down to make enemies skittish around small drops.
@export var ledge_probe_depth := 0.5

@export_group("Performance")
## Tick the brain only every Nth physics frame when not actively chasing.
## 1 = every frame (original behavior). 4 = ~15Hz brain logic, ~75% CPU
## savings on this brain's per-frame cost. Stealth enemies should set this
## to 1 so their cone raycasts don't miss a player crossing their FOV.
## CHASE/HOSTILE state always ticks every frame regardless — pursuit stays
## responsive. Each instance picks a random offset 0..N-1 at _ready so a
## cluster of enemies don't all tick on the same frame.
@export_range(1, 16) var tick_every_n_frames: int = 4
## Pause the body's AnimationTree when the body is off-screen. Brain logic
## still ticks (so enemies pursue when behind the camera) but skeleton
## skinning + state machine evaluation is skipped. Biggest single win for
## scenes with many enemies — animation/skeleton work tends to dominate.
@export var pause_animation_offscreen: bool = true
## Beyond this distance from the target, the AnimationTree advances at
## anim_rate_mid Hz instead of the engine's full visual rate. The eye
## can't tell that a guy 25m away is animating at 20Hz instead of 60.
@export var anim_lod_mid_distance: float = 25.0
## Beyond this distance, AnimationTree advances at anim_rate_far Hz.
@export var anim_lod_far_distance: float = 50.0
## AnimationTree advance rate (Hz) inside anim_lod_mid_distance. 60 = full.
@export var anim_rate_near: float = 60.0
## AnimationTree advance rate (Hz) between mid and far distance.
@export var anim_rate_mid: float = 20.0
## AnimationTree advance rate (Hz) beyond anim_lod_far_distance.
@export var anim_rate_far: float = 5.0
## AABB used to size the off-screen notifier — humanoid-sized. Bumped wide
## so the notifier registers as visible slightly before the skin appears,
## hiding the one-frame "frozen pose" pop when transitioning back on-screen.
const _PERF_NOTIFIER_AABB := AABB(Vector3(-1.0, -0.2, -1.0), Vector3(2.0, 2.4, 2.0))

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
var _jump_cooldown_timer := 0.0
# Sticky cache of "I already jumped at this target." Cleared when the
# target reference changes OR when the pawn reaches dy < threshold (i.e.,
# the jump worked OR the target moved within reach). Prevents the "jump
# in place forever against a wall I can't clear" loop.
var _jump_attempted_target: Node3D = null
# Mirror cache for SMART nav drop-down attempts. Set when the drop-landing
# probe finds no safe surface; cleared when target changes or we reach
# parity height (target no longer below threshold).
var _drop_attempted_target: Node3D = null
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
# Cached once per real tick. Drives stealth-mode toggles: cone gating in
# detection, range/suspect multipliers, aggressive-buff flip, cone visual
# show/hide + flicker. Read from `_target._was_crouched` (PlayerBody).
var _target_crouched: bool = false
# Mirrors the body's last applied set_aggressive_buffs() state so we only
# call across on transitions, not every frame.
var _aggressive_active: bool = false
# Effective ranges + SUSPECT threshold for THIS tick. Filled by
# _refresh_effective_ranges(). When in cone-mode + crouched, range scales
# by crouch_range_multiplier and suspect by crouch_suspect_multiplier;
# otherwise these mirror the authored values.
var _effective_detection_radius: float = 0.0
var _effective_chase_exit_radius: float = 0.0
var _effective_hostile_radius: float = 0.0
var _effective_suspect_duration: float = 0.0
# Cached materials for the two-zone cone visual. Created lazily on first
# rebuild so brains that don't render the fan don't pay for them.
var _hostile_zone_material_cached: StandardMaterial3D = null
var _suspect_zone_material_cached: StandardMaterial3D = null
# Cone visual alpha multiplier (0..1) applied to the displayed albedo
# alpha each frame. Hidden when target is standing; flickers ON like a
# fluorescent bulb on standing→crouched transition; fades to 0 on the
# reverse. Debounced so rapid crouch toggles don't restart the flicker.
var _cone_alpha_mult: float = 0.0
# Flicker pattern playback. Each entry is (state, duration_seconds) where
# state is 0 (off) or 1 (on). Index advances when timer expires; pattern
# ends with a steady-on phase (handled by clearing the pattern).
var _flicker_pattern: Array = []
var _flicker_index: int = 0
var _flicker_step_timer: float = 0.0
# Wallclock at which the most recent flicker began. Used by the debounce
# check — re-triggers within the window snap to ON without flickering.
var _last_flicker_started_at: float = -1000.0
const _FLICKER_DEBOUNCE_SEC: float = 1.0

# ── Debug overlay ────────────────────────────────────────────────────────
# Global toggle (F3 wired in game.gd). When true, every brain's debug Label3D
# floats above its pawn showing archetype / state / alert phase / vel /
# distance to target. Static so a single keystroke flips visibility for all
# active brains without an autoload.
static var debug_visible: bool = false
var _debug_label: Label3D = null
# Last text written; we only re-assign label.text when something changed so
# we don't allocate a new string every tick on dozens of pawns.
var _debug_label_last_text: String = ""

# Performance — lazy-built on first tick because we need the body reference.
var _perf_setup_done: bool = false
var _animation_tree: AnimationTree = null
var _notifier: VisibleOnScreenNotifier3D = null
# Default true so enemies that spawn already on-screen don't freeze on
# their first frame waiting for a screen_entered signal that won't come.
var _on_screen: bool = true
var _tick_offset: int = 0
# Accumulates per-frame delta on skipped frames; flushed into the real
# tick's delta so wander timers / cooldowns track wallclock time accurately.
var _skip_delta_accum: float = 0.0
var _anim_advance_accum: float = 0.0


func _ready() -> void:
	_direction = Vector3.RIGHT.rotated(Vector3.UP, randf() * TAU)
	_reset_wander_timer()
	_state = starting_state
	# Seed yaw so first-frame slice rays + visual point along _direction
	# instead of swinging from 0 on spawn.
	_vision_cone_yaw = atan2(_direction.x, _direction.z) + PI
	# Stagger this brain's tick offset so a cluster spawned together don't
	# all tick on the same physics frame. Body reference isn't available
	# yet — the AnimationTree + notifier wiring waits for first tick().
	_tick_offset = randi() % maxi(tick_every_n_frames, 1)


func tick(body: Node3D, delta: float) -> Intent:
	if not _perf_setup_done:
		_setup_perf(body)
		_setup_debug_label(body)

	# Animation runs on its own clock — distance-LOD'd advance + off-screen
	# pause. Done BEFORE the tick-budgeting gate so animation keeps progressing
	# every visible frame even when AI logic itself is staggered.
	_advance_animation_lod(body, delta)

	# Tick budgeting: when not actively chasing, run the brain only every Nth
	# physics frame. Movement intent persists from the last real tick so the
	# body keeps walking in its current direction; only the edge flags reset
	# (so attack/jump don't re-fire on skipped frames).
	_skip_delta_accum += delta
	var hostile: bool = _alert_phase == _AlertPhase.HOSTILE
	var should_tick: bool = hostile or tick_every_n_frames <= 1 or \
		(Engine.get_physics_frames() + _tick_offset) % tick_every_n_frames == 0
	if not should_tick:
		_intent.jump_pressed = false
		_intent.attack_pressed = false
		return _intent
	delta = _skip_delta_accum
	_skip_delta_accum = 0.0

	# Reset edge flags every tick; only set them true when we fire this frame.
	_intent.move_direction = Vector3.ZERO
	_intent.jump_pressed = false
	_intent.attack_pressed = false
	_intent.hard_brake = false
	_attack_cooldown_timer = maxf(0.0, _attack_cooldown_timer - delta)
	_jump_cooldown_timer = maxf(0.0, _jump_cooldown_timer - delta)

	# Resolve target first so crouch read + effective ranges all operate on
	# the same up-to-date target reference this tick.
	_ensure_target(body)
	_refresh_target_crouched()
	_refresh_effective_ranges()
	# (Cone is always on now — no _advance_cone_alpha / flicker; the
	# fan's static red+yellow zones are baked into the visual rebuild.)

	# Cone yaw + per-slice raycasts run BEFORE alert phase. _can_see_target
	# (called inside _update_alert_phase) reads _slice_distances; the visual
	# rebuild reads them too. Single shared source.
	_update_vision_yaw(delta)
	_compute_slice_distances(body)

	_update_alert_phase(body, delta)
	_update_vision_debug(body, delta)
	_update_state(body)
	_update_debug_label(body)

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

	# Navigation runs AFTER state's match block so it sees the move_direction
	# we just computed — and so SMART can override the chase-direction's
	# ledge brake when target is below + drop is safe.
	_navigate(body)

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
#   cone == 0 (swarm)  : pure sphere — in range = detected.
#   cone > 0 (stealth) : cone arc + line-of-sight via per-slice
#     raycasts, ALWAYS — regardless of crouch. Crouch instead shrinks
#     the cone reach (via crouch_range_multiplier on the caller's
#     range_cap). The slice rays ARE the LOS check; visual fan and
#     detection share them.
# Reports raw "currently visible" state — the alert state machine
# (with its SUSPECT delay and hostile_zone_radius shortcut) decides
# what to do with that signal.
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
	# Cone path: must lie inside the FOV arc AND inside the unblocked
	# extent of whichever slice contains them.
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
	var slice_dist: float = minf(_slice_distances[f_idx], _slice_distances[c_idx])
	return horiz <= slice_dist


func _chase_direction(body: Node3D) -> Vector3:
	var to_target: Vector3 = _target.global_position - body.global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
		return Vector3.ZERO
	_direction = to_target.normalized()
	# Wall handling is deferred to CharacterBody3D.move_and_slide — pushing
	# into a wall stalls naturally. We previously zeroed intent on is_on_wall
	# but that flag is direction-agnostic AND sticky when stationary, so the
	# pawn would freeze and never re-track when the target moved.
	if turn_at_ledges and body.has_method("is_on_floor") and body.is_on_floor() and not _has_ground_ahead(body):
		# Friction alone can't brake red (2.5×) within stop-distance of the
		# ledge probe; flag a hard_brake so the body zeros h_vel this tick.
		# Self-clears next tick when the brain stops requesting it.
		_intent.hard_brake = true
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
	# Crouch-pause: if the follow subject is crouching, allies idle in place
	# rather than re-acquire — gives the player a "ditch the posse for
	# stealth" beat. Auto-resumes the moment the subject uncrouches.
	if "_was_crouched" in subject and bool(subject.get(&"_was_crouched")):
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
		# Validate the cached target still belongs to one of our target
		# groups — set_faction() rewrites target_groups but doesn't reach
		# in here to clear _target, so a converted ally would otherwise
		# keep chasing whatever it was last targeting (often the player).
		# Dropping the cached target here forces a re-acquire below.
		for grp in target_groups:
			if _target.is_in_group(grp):
				return
		_target = null
	var tree := body.get_tree()
	if tree == null:
		return
	# Pick the NEAREST target across all groups, not the first match.
	# Naïve first-match locked converted golds onto far-away greens on
	# other platforms — outside detection_radius — so they never engaged
	# the reds standing 5m away. Nearest-pick scans all eligible bodies
	# (deduped, since a pawn can be in multiple groups e.g. red is in
	# both "splice_enemies" and "enemies") and picks the closest by
	# horizontal+vertical distance. O(N) per acquisition; cheap at our
	# scale (a re-acquire only fires when current _target dies/leaves).
	var best: Node3D = null
	var best_dsq: float = INF
	var seen: Dictionary = {}
	for grp in target_groups:
		for node: Node in tree.get_nodes_in_group(grp):
			if seen.has(node):
				continue
			seen[node] = true
			if not (node is Node3D):
				continue
			var n3d: Node3D = node as Node3D
			var dsq: float = n3d.global_position.distance_squared_to(body.global_position)
			if dsq < best_dsq:
				best_dsq = dsq
				best = n3d
	_target = best


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


# Navigation dispatcher. nav_mode determines vertical-traversal strategy.
# All modes share the chase/follow horizontal direction set by the state
# match block; this function decides whether to also jump up, drop down,
# or stay grounded.
func _navigate(body: Node3D) -> void:
	# Gold allies always run SMART — they need to track the player up
	# elevators and drop down to follow. The brain preset's nav_mode
	# applies to whatever faction the pawn was authored as; converted
	# golds (regardless of original brain) get promoted here so the
	# posse follows reliably across platforms.
	var effective_mode: int = nav_mode
	if "faction" in body and body.get(&"faction") == &"gold":
		effective_mode = NavMode.SMART
	match effective_mode:
		NavMode.NONE:
			pass  # ledge brake from _chase_direction stays; no jumps
		NavMode.DUMB:
			_nav_dumb(body)
		NavMode.SMART:
			_nav_smart(body)
		NavMode.COMPANION:
			# Not yet implemented — falls back to SMART. When built, this
			# will query a NavigationAgent3D for the next path waypoint
			# and trigger jumps/drops based on NavigationLink3D crossings.
			_nav_smart(body)


# Pick the subject we're navigating toward this tick — chase target if
# HOSTILE, follow subject (player) otherwise. Returns null when there's
# no valid target to navigate toward.
func _navigation_target(body: Node3D) -> Node3D:
	if _state == State.CHASE or _state == State.WIND_UP:
		if _target != null and is_instance_valid(_target):
			return _target
		return null
	if follow_subject_group != &"":
		return _nearest_in_group(body, follow_subject_group)
	return null


# DUMB nav: blind faith jump. Target above + on floor + cooldown → jump.
# No landing-arc check, no drop logic. Naive but predictable. Per-target
# attempt cache prevents re-jumping at unreachable walls.
func _nav_dumb(body: Node3D) -> void:
	if _jump_cooldown_timer > 0.0:
		return
	if not (body.has_method("is_on_floor") and body.is_on_floor()):
		return
	var towards: Node3D = _navigation_target(body)
	if towards == null or not is_instance_valid(towards):
		return
	if towards.has_method(&"is_on_floor") and not towards.is_on_floor():
		return
	var dy: float = towards.global_position.y - body.global_position.y
	if dy < jump_height_threshold:
		_jump_attempted_target = null
		return
	if _intent.move_direction.length() < 0.01:
		return
	if _jump_attempted_target == towards:
		return
	_intent.jump_pressed = true
	_jump_cooldown_timer = jump_cooldown
	_jump_attempted_target = towards


# SMART nav: arc-checked jumps + drop-down at ledges.
#   Jump UP: only if a downward probe at the projected landing spot finds
#     ground at a Y between (current Y, target Y + 1m). Saves wasted jumps
#     into open space.
#   Drop DOWN: if at a ledge (chase set hard_brake), target is below by
#     smart_drop_threshold, and a forward+down probe finds a safe landing
#     within max_safe_drop. Skips the brake so the body walks off; gravity
#     handles the fall.
func _nav_smart(body: Node3D) -> void:
	if not (body.has_method("is_on_floor") and body.is_on_floor()):
		return
	var towards: Node3D = _navigation_target(body)
	if towards == null or not is_instance_valid(towards):
		return
	if towards.has_method(&"is_on_floor") and not towards.is_on_floor():
		return
	var towards_dir: Vector3 = (towards.global_position - body.global_position)
	towards_dir.y = 0.0
	if towards_dir.length_squared() > 0.0001:
		towards_dir = towards_dir.normalized()
	else:
		towards_dir = _direction
	var dy: float = towards.global_position.y - body.global_position.y
	# Detect ledge ourselves — _chase_direction sets hard_brake in chase
	# state, but follow mode (gold allies) goes through _follow_direction
	# which doesn't probe ledges. Without this self-check golds walk
	# straight off cliffs.
	var probe_dir: Vector3 = _direction if _intent.move_direction.length() > 0.01 else towards_dir
	var prior_direction: Vector3 = _direction
	_direction = probe_dir
	var ground_ahead: bool = _has_ground_ahead(body)
	_direction = prior_direction
	var at_ledge: bool = not ground_ahead
	# CASE 1 — Drop-down: at a ledge with target below threshold.
	if at_ledge and dy < -smart_drop_threshold:
		if _drop_attempted_target != towards:
			if _smart_drop_landing_safe(body, towards, towards_dir):
				_intent.hard_brake = false
				_intent.move_direction = towards_dir * chase_speed_fraction
				_drop_attempted_target = null
				return
			_drop_attempted_target = towards
		_intent.hard_brake = true
		_intent.move_direction = Vector3.ZERO
		return
	# CASE 2 — Jump-up: target above threshold (any position, not just ledge).
	if dy >= jump_height_threshold:
		_try_jump(body, towards, towards_dir, at_ledge)
		return
	# CASE 3 — Same-level gap: at a ledge with target roughly same Y, jump
	# across if the arc lands on the far side. Only fires AT a ledge so
	# sentinels don't randomly hop on flat ground.
	if at_ledge and absf(dy) < jump_height_threshold:
		_try_jump(body, towards, towards_dir, at_ledge)
		return
	# CASE 4 — Default: ledge with no jump/drop path. Brake. Catches
	# follow-mode allies that would otherwise walk off.
	if at_ledge:
		_intent.hard_brake = true
		_intent.move_direction = Vector3.ZERO
	# Within reach — clear caches.
	_jump_attempted_target = null
	if dy >= -smart_drop_threshold:
		_drop_attempted_target = null


# Shared jump trigger for jump-up and same-level cases. Validates the arc,
# fires intent.jump_pressed if reachable, caches failure if not. When at
# a ledge AND the jump can't reach, brake instead of standing on air.
func _try_jump(body: Node3D, towards: Node3D, towards_dir: Vector3, at_ledge: bool) -> void:
	if _jump_cooldown_timer > 0.0:
		if at_ledge:
			_intent.hard_brake = true
			_intent.move_direction = Vector3.ZERO
		return
	if _jump_attempted_target == towards:
		if at_ledge:
			_intent.hard_brake = true
			_intent.move_direction = Vector3.ZERO
		return
	if _smart_jump_arc_lands(body, towards, towards_dir):
		_intent.jump_pressed = true
		_jump_cooldown_timer = jump_cooldown
		_jump_attempted_target = towards
		_intent.hard_brake = false
		_intent.move_direction = towards_dir * chase_speed_fraction
	else:
		_jump_attempted_target = towards
		if at_ledge:
			_intent.hard_brake = true
			_intent.move_direction = Vector3.ZERO


# Probe whether a jump from current state lands on solid ground. Estimate
# apex + horizontal reach from jump_impulse, gravity, and current horiz
# speed; cast down at that point. Solid surface between (my Y, target Y +
# 1m tolerance) = jump worth attempting.
func _smart_jump_arc_lands(body: Node3D, towards: Node3D, dir: Vector3) -> bool:
	var profile: Variant = body.get(&"_current_profile")
	var jump_v: float = 10.0
	if profile != null and "jump_impulse" in profile:
		jump_v = float(profile.jump_impulse)
	var gravity_y: float = 30.0
	var air_time: float = 2.0 * jump_v / gravity_y
	var horiz_speed: float = 0.0
	if body is CharacterBody3D:
		var v: Vector3 = (body as CharacterBody3D).velocity
		horiz_speed = sqrt(v.x * v.x + v.z * v.z)
	# Floor estimate at max_speed × 0.5 — sentinel jumping from a standing
	# start (e.g. just braked at a ledge) accelerates from 0 to max_speed
	# during the air time. Average horizontal speed mid-jump ≈ max/2 in
	# that case. If they're already going faster than that, use the
	# actual speed.
	var max_speed: float = 5.0
	if profile != null and "max_speed" in profile:
		max_speed = float(profile.max_speed)
	horiz_speed = maxf(horiz_speed, max_speed * 0.5)
	var reach: float = horiz_speed * air_time * smart_jump_safety_factor
	var apex: float = (jump_v * jump_v) / (2.0 * gravity_y)
	var landing: Vector3 = body.global_position + dir * reach + Vector3.UP * apex
	var space := body.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(landing, landing + Vector3.DOWN * (apex + 5.0))
	if body is CollisionObject3D:
		query.exclude = [(body as CollisionObject3D).get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return false
	# Filter wall-grazes: a ray hitting the SIDE of a platform's collision
	# returns a hit with a near-horizontal normal. Floor surfaces have an
	# upward-pointing normal (y ≈ 1.0). 0.5 cutoff = at least 60° from
	# vertical, allowing slight slopes but rejecting walls.
	var hit_normal: Vector3 = hit.normal as Vector3
	if hit_normal.y < 0.5:
		return false
	# Landing must be NEAR the target's Y — within 1m above or below.
	# Looser rules (any surface between body and target) caused sentinels
	# to jump onto whatever "lower" platform was in arc range — typically
	# elevators at base position — and call that progress. They never
	# actually reached the target's elevation, just landed somewhere
	# random and got stuck.
	var hit_y: float = (hit.position as Vector3).y
	var target_y: float = towards.global_position.y
	return absf(hit_y - target_y) <= 1.0


# Probe whether walking off the ledge in `dir` lands on a safe surface
# at or above target's Y, within max_safe_drop. Returns true if drop is
# committable.
func _smart_drop_landing_safe(body: Node3D, towards: Node3D, dir: Vector3) -> bool:
	var current_y: float = body.global_position.y
	var target_y: float = towards.global_position.y
	if current_y - target_y > max_safe_drop:
		return false
	var probe_origin: Vector3 = body.global_position + dir * 1.5 + Vector3.UP * 0.2
	var space := body.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(probe_origin, probe_origin + Vector3.DOWN * (max_safe_drop + 1.0))
	if body is CollisionObject3D:
		query.exclude = [(body as CollisionObject3D).get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return false
	# Same wall-rejection as the jump-arc probe: only floors count.
	var hit_normal: Vector3 = hit.normal as Vector3
	if hit_normal.y < 0.5:
		return false
	var hit_y: float = (hit.position as Vector3).y
	# Landing must be near target's Y (so we land where target is, not in
	# a deeper pit past them).
	return hit_y >= target_y - 1.0 and current_y - hit_y <= max_safe_drop


func _nearest_in_group(body: Node3D, group: StringName) -> Node3D:
	var tree := body.get_tree()
	if tree == null:
		return null
	var best: Node3D = null
	var best_dsq: float = INF
	for n: Node in tree.get_nodes_in_group(group):
		if not (n is Node3D):
			continue
		var n3d: Node3D = n as Node3D
		var dsq: float = n3d.global_position.distance_squared_to(body.global_position)
		if dsq < best_dsq:
			best_dsq = dsq
			best = n3d
	return best


func _has_ground_ahead(body: Node3D) -> bool:
	# Velocity-aware SWEPT probe: a single distant probe overshoots gaps and
	# lands on the next platform — reporting "ground ahead" when there's
	# actually a chasm in between (level_4's ~3.6m inter-platform gaps were
	# the bug that made this a sweep instead of a single ray). Cast a row
	# of downward probes from `step` ahead up to `lookahead`; if ANY misses,
	# there's a gap → ledge.
	#
	# Lookahead extends by 0.5s of current speed worth of stopping budget so
	# fast pawns (red 2.5× = 12.5 m/s; or attack-lunge ~20 m/s spike) brake
	# before the edge instead of sliding past it.
	var lookahead: float = ledge_probe_distance
	if body is CharacterBody3D:
		var v: Vector3 = (body as CharacterBody3D).velocity
		var horiz_speed: float = sqrt(v.x * v.x + v.z * v.z)
		lookahead = ledge_probe_distance + horiz_speed * 0.5
	var space := body.get_world_3d().direct_space_state
	var exclude: Array[RID] = []
	if body is CollisionObject3D:
		exclude.append((body as CollisionObject3D).get_rid())
	# Step granularity: 0.5m catches level_4's 3.5m+ chasms easily; tighter
	# than a typical pawn footprint so even narrow gaps register.
	var step: float = 0.5
	var n_steps: int = maxi(1, int(ceil(lookahead / step)))
	# Lift the probe origin slightly above the body so a stationary pawn
	# resting exactly on the platform's top face still gets a clean hit on
	# the surface beneath. Without this, body.global_position.y can settle
	# coplanar with the floor, and rays starting on the surface miss it —
	# the brain then thinks "no ground" forever and the pawn freezes.
	var lift: float = 0.1
	for i in range(1, n_steps + 1):
		var dist: float = minf(step * float(i), lookahead)
		var from: Vector3 = body.global_position + _direction * dist + Vector3.UP * lift
		var to: Vector3 = from + Vector3.DOWN * (ledge_probe_depth + lift)
		var query := PhysicsRayQueryParameters3D.create(from, to)
		query.exclude = exclude
		if space.intersect_ray(query).is_empty():
			return false
	return true


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
	# radius once we're past CALM so the target remains "visible" through
	# the hysteresis window. Effective values fold in the crouch range
	# multiplier (cone shrinks when target crouches).
	var range_cap: float = _effective_chase_exit_radius if (_alert_phase == _AlertPhase.HOSTILE) else _effective_detection_radius
	var visible: bool = _target != null and _can_see_target(body, range_cap)
	# Hostile-zone shortcut: when the target is inside the inner cone
	# radius (< _effective_hostile_radius), skip SUSPECT and snap to
	# HOSTILE. Outside the inner zone but inside the cone's outer band:
	# normal SUSPECT delay (yellow → red after suspect_duration).
	var inside_hostile_zone: bool = false
	if visible and _effective_hostile_radius > 0.0 and _target != null:
		var to_t: Vector3 = _target.global_position - body.global_position
		to_t.y = 0.0
		inside_hostile_zone = to_t.length() < _effective_hostile_radius
	match _alert_phase:
		_AlertPhase.CALM:
			if visible:
				if inside_hostile_zone or _effective_suspect_duration <= 0.0 or vision_cone_deg <= 0.0:
					_alert_phase = _AlertPhase.HOSTILE
					_alert_timer = 0.0
				else:
					_alert_phase = _AlertPhase.SUSPECT
					_alert_timer = 0.0
		_AlertPhase.SUSPECT:
			if not visible:
				_alert_phase = _AlertPhase.CALM
			elif inside_hostile_zone:
				_alert_phase = _AlertPhase.HOSTILE
				_alert_timer = 0.0
			else:
				_alert_timer += delta
				if _alert_timer >= _effective_suspect_duration:
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
# Also flips aggressive_while_chasing buffs on HOSTILE enter/exit edges so
# splice_stealth pawns burst to red-class lethality only while pursuing.
func _on_alert_phase_changed(body: Node3D, prior: int, current: int) -> void:
	if aggressive_while_chasing and body.has_method(&"set_aggressive_buffs"):
		var entering_hostile: bool = current == _AlertPhase.HOSTILE
		var leaving_hostile: bool = prior == _AlertPhase.HOSTILE and current != _AlertPhase.HOSTILE
		if entering_hostile and not _aggressive_active:
			body.call(&"set_aggressive_buffs", true)
			_aggressive_active = true
		elif leaving_hostile and _aggressive_active:
			body.call(&"set_aggressive_buffs", false)
			_aggressive_active = false
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
	# Use the effective range — doubled when target is crouched (stealth mode).
	var range_m: float = _effective_detection_radius if _effective_detection_radius > 0.0 else detection_radius
	if space == null:
		for i in range(n):
			_slice_distances[i] = range_m
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
		var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * range_m)
		query.exclude = exclude
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			_slice_distances[i] = range_m
		else:
			_slice_distances[i] = origin.distance_to(hit.position as Vector3)


# Position the fan apex at the eye and rebuild the two-zone mesh from
# this tick's slice distances. Cone is always visible whenever
# vision_debug_visible is true — it's a static perception readout, not a
# fade-in-on-detect cue. Inner zone (red, hostile_zone_radius) and outer
# zone (yellow, detection_radius) are separate surfaces with their own
# materials; phase color tweens are no longer applied to the fan itself.
func _update_vision_debug(body: Node3D, _delta: float) -> void:
	if not vision_debug_visible or vision_cone_deg <= 0.0:
		if _vision_cone_mesh != null and is_instance_valid(_vision_cone_mesh):
			_vision_cone_mesh.queue_free()
			_vision_cone_mesh = null
		return
	if _vision_cone_mesh == null or not is_instance_valid(_vision_cone_mesh):
		_vision_cone_mesh = _build_vision_cone_mesh(body)
	_vision_cone_mesh.global_position = body.global_position + Vector3.UP * vision_eye_height
	_rebuild_vision_cone_mesh()


func _build_vision_cone_mesh(body: Node3D) -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.mesh = ImmediateMesh.new()
	# No material_override — each surface in _rebuild_vision_cone_mesh is
	# painted with its own zone-specific material via surface_begin(...,
	# material). DEPTH_PRE_PASS on each material lets walls correctly
	# occlude the translucent fan.
	body.add_child(inst)
	inst.top_level = true
	return inst


# Build (once) and return the cached zone material. Inner = hostile (red).
# Outer = suspect (yellow). Static colors — the alert-phase color tween
# is no longer applied to the fan; the fan is a perception readout, not
# a state indicator.
func _hostile_zone_material() -> Material:
	if _hostile_zone_material_cached == null:
		_hostile_zone_material_cached = _make_zone_material(color_hostile)
	return _hostile_zone_material_cached


func _suspect_zone_material() -> Material:
	if _suspect_zone_material_cached == null:
		_suspect_zone_material_cached = _make_zone_material(color_alert)
	return _suspect_zone_material_cached


func _make_zone_material(c: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


# Rebuild the fan as TWO concentric zones, both clipped per-slice by the
# this tick's wall raycasts:
#   Inner (red) : 0 → min(slice_dist, hostile_radius). Triangles share apex.
#   Outer (yel) : hostile_radius → min(slice_dist, detection_radius). Quads.
# When hostile_zone_radius == 0, the inner zone covers the full cone and
# the outer is empty (legacy single-zone behavior).
func _rebuild_vision_cone_mesh() -> void:
	if _vision_cone_mesh == null or not is_instance_valid(_vision_cone_mesh):
		return
	var mesh := _vision_cone_mesh.mesh as ImmediateMesh
	if mesh == null:
		return
	mesh.clear_surfaces()
	if _slice_distances.size() < 2:
		return
	var half_rad: float = deg_to_rad(vision_cone_deg)
	var step: float = (2.0 * half_rad) / float(_CONE_SLICES)
	var apex := Vector3.ZERO
	var forward := Vector3(-sin(_vision_cone_yaw), 0.0, -cos(_vision_cone_yaw))
	# When hostile_zone_radius is 0 (or negative), treat the entire cone
	# as the inner zone — single-color red fan to maintain backward compat.
	var hostile_r: float = _effective_hostile_radius if _effective_hostile_radius > 0.0 else _effective_detection_radius
	# Inner zone (hostile / red).
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _hostile_zone_material())
	for i in range(_CONE_SLICES):
		var a0: float = -half_rad + step * float(i)
		var a1: float = -half_rad + step * float(i + 1)
		var dir0: Vector3 = forward.rotated(Vector3.UP, a0)
		var dir1: Vector3 = forward.rotated(Vector3.UP, a1)
		var d0: float = minf(_slice_distances[i], hostile_r)
		var d1: float = minf(_slice_distances[i + 1], hostile_r)
		mesh.surface_add_vertex(apex)
		mesh.surface_add_vertex(dir0 * d0)
		mesh.surface_add_vertex(dir1 * d1)
	mesh.surface_end()
	# Outer zone (suspect / yellow). Skip when no outer band exists.
	if _effective_detection_radius <= hostile_r:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _suspect_zone_material())
	for i in range(_CONE_SLICES):
		var a0: float = -half_rad + step * float(i)
		var a1: float = -half_rad + step * float(i + 1)
		var dir0: Vector3 = forward.rotated(Vector3.UP, a0)
		var dir1: Vector3 = forward.rotated(Vector3.UP, a1)
		var d0_in: float = minf(_slice_distances[i], hostile_r)
		var d1_in: float = minf(_slice_distances[i + 1], hostile_r)
		var d0_out: float = minf(_slice_distances[i], _effective_detection_radius)
		var d1_out: float = minf(_slice_distances[i + 1], _effective_detection_radius)
		# Slice fully clipped inside the inner zone (wall closer than
		# hostile_r) — no outer-band geometry for it.
		if d0_out <= d0_in and d1_out <= d1_in:
			continue
		var p0_in: Vector3 = dir0 * d0_in
		var p1_in: Vector3 = dir1 * d1_in
		var p0_out: Vector3 = dir0 * d0_out
		var p1_out: Vector3 = dir1 * d1_out
		# Quad split into two triangles.
		mesh.surface_add_vertex(p0_in)
		mesh.surface_add_vertex(p0_out)
		mesh.surface_add_vertex(p1_out)
		mesh.surface_add_vertex(p0_in)
		mesh.surface_add_vertex(p1_out)
		mesh.surface_add_vertex(p1_in)
	mesh.surface_end()


# ---- Performance: animation LOD + off-screen pause + tick staggering -----

func _setup_perf(body: Node3D) -> void:
	_perf_setup_done = true
	_animation_tree = _find_animation_tree(body)
	if _animation_tree != null:
		# AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL = 2. Switch to
		# manual so we drive advance() ourselves at the LOD'd rate. Set via
		# property name to be resilient to enum-rename churn between Godot
		# minor versions.
		_animation_tree.set(&"callback_mode_process", 2)
	if pause_animation_offscreen:
		_notifier = VisibleOnScreenNotifier3D.new()
		_notifier.aabb = _PERF_NOTIFIER_AABB
		body.add_child(_notifier)
		_notifier.screen_entered.connect(_on_notifier_entered)
		_notifier.screen_exited.connect(_on_notifier_exited)


func _on_notifier_entered() -> void:
	_on_screen = true


func _on_notifier_exited() -> void:
	_on_screen = false


func _find_animation_tree(node: Node) -> AnimationTree:
	if node is AnimationTree:
		return node as AnimationTree
	for c: Node in node.get_children():
		var r := _find_animation_tree(c)
		if r != null:
			return r
	return null


func _advance_animation_lod(body: Node3D, delta: float) -> void:
	if _animation_tree == null:
		return
	if pause_animation_offscreen and not _on_screen:
		return  # frozen pose off-screen — biggest single CPU/GPU win
	var d: float = _distance_to_target_or_player(body)
	var rate: float
	if d < anim_lod_mid_distance:
		rate = anim_rate_near
	elif d < anim_lod_far_distance:
		rate = anim_rate_mid
	else:
		rate = anim_rate_far
	_anim_advance_accum += delta
	var step: float = 1.0 / maxf(rate, 0.1)
	if _anim_advance_accum >= step:
		_animation_tree.advance(_anim_advance_accum)
		_anim_advance_accum = 0.0


func _distance_to_target_or_player(body: Node3D) -> float:
	# Prefer the cached _target (set by _ensure_target during chase). Fall
	# back to the first member of any target_groups so we still LOD even
	# before the enemy has acquired a target.
	if _target != null and is_instance_valid(_target):
		return body.global_position.distance_to(_target.global_position)
	var tree := body.get_tree()
	if tree == null:
		return 0.0
	for grp in target_groups:
		for n: Node in tree.get_nodes_in_group(grp):
			if n is Node3D:
				return body.global_position.distance_to((n as Node3D).global_position)
	return 0.0


# ---- Stealth dual-mode: crouch-driven aggressive buffs + cone visibility -

# Cache the resolved target's crouch state for this tick. Detects edges
# (standing↔crouched) and fires the cone-flicker trigger on crouch entry.
func _refresh_target_crouched() -> void:
	var prev: bool = _target_crouched
	if _target == null or not is_instance_valid(_target):
		_target_crouched = false
	else:
		_target_crouched = "_was_crouched" in _target and bool(_target.get(&"_was_crouched"))
	if prev != _target_crouched:
		_on_crouch_transition(_target_crouched)


# Fold the crouch-mode multipliers into the effective range + suspect
# values used by detection and the alert state machine. Cone-mode +
# crouched is the only branch that scales; everything else mirrors the
# authored values so non-stealth brains behave identically to before.
func _refresh_effective_ranges() -> void:
	var stealth_active: bool = vision_cone_deg > 0.0 and _target_crouched
	var range_mult: float = crouch_range_multiplier if stealth_active else 1.0
	var suspect_mult: float = crouch_suspect_multiplier if stealth_active else 1.0
	_effective_detection_radius = detection_radius * range_mult
	_effective_chase_exit_radius = chase_exit_radius * range_mult
	_effective_hostile_radius = hostile_zone_radius * range_mult
	_effective_suspect_duration = suspect_duration * suspect_mult


# Advance _cone_alpha_mult one tick. Standing target → fade to 0 over
# ~0.15s. Crouched target → walk the flicker pattern if active, otherwise
# steady at 1.0. Flicker pattern is set up by _on_crouch_transition().
func _advance_cone_alpha(delta: float) -> void:
	if _target_crouched:
		if _flicker_pattern.is_empty():
			_cone_alpha_mult = 1.0
			return
		_flicker_step_timer -= delta
		if _flicker_step_timer > 0.0:
			return
		_flicker_index += 1
		if _flicker_index >= _flicker_pattern.size():
			_flicker_pattern.clear()
			_cone_alpha_mult = 1.0
			return
		var step: Array = _flicker_pattern[_flicker_index] as Array
		_cone_alpha_mult = float(step[0])
		_flicker_step_timer = float(step[1])
		return
	# Standing — kill any in-flight flicker, fade to 0.
	if not _flicker_pattern.is_empty():
		_flicker_pattern.clear()
	var fade_rate: float = 1.0 / 0.15  # 0.15s fade-out
	_cone_alpha_mult = maxf(0.0, _cone_alpha_mult - fade_rate * delta)


# Crouch edge handler. Standing→crouched fires a fluorescent flicker on
# the cone fan, debounced so rapid crouch toggling doesn't restart the
# pattern (within the debounce window the cone snaps to ON instead).
# Crouched→standing is handled by the fade in _advance_cone_alpha.
func _on_crouch_transition(now_crouched: bool) -> void:
	if not now_crouched:
		return
	var t: float = _wallclock_seconds()
	if t - _last_flicker_started_at < _FLICKER_DEBOUNCE_SEC:
		# Within debounce window: snap on, no flicker.
		_flicker_pattern.clear()
		_cone_alpha_mult = 1.0
		return
	_last_flicker_started_at = t
	# Pattern: [alpha, duration_sec]. Reads as a fluorescent tube struggling
	# to ignite — fast bursts, irregular gaps, settles to steady ON when
	# the pattern array empties.
	_flicker_pattern = [
		[1.0, 0.05],
		[0.0, 0.05],
		[1.0, 0.04],
		[0.0, 0.08],
		[1.0, 0.06],
		[0.0, 0.03],
		[1.0, 0.10],
		[0.0, 0.04],
	]
	_flicker_index = 0
	_cone_alpha_mult = float((_flicker_pattern[0] as Array)[0])
	_flicker_step_timer = float((_flicker_pattern[0] as Array)[1])


func _wallclock_seconds() -> float:
	return Time.get_ticks_msec() / 1000.0


# ── Debug overlay ────────────────────────────────────────────────────────

# Lazy-build the floating Label3D that summarizes brain state above this
# pawn. Only built once per brain (stored on `_debug_label`); visibility
# tracks the static `debug_visible` flag.
func _setup_debug_label(body: Node3D) -> void:
	if _debug_label != null and is_instance_valid(_debug_label):
		return
	_debug_label = Label3D.new()
	_debug_label.position = Vector3(0, 2.4, 0)
	_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# DISABLED depth test so the label punches through walls — what we want
	# for debug — and we read the text from any angle.
	_debug_label.no_depth_test = true
	_debug_label.font_size = 28
	_debug_label.outline_size = 6
	_debug_label.modulate = Color(1, 1, 1, 1)
	_debug_label.outline_modulate = Color(0, 0, 0, 1)
	_debug_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_debug_label.visible = debug_visible
	body.add_child(_debug_label)


# Refresh the debug label text + visibility. Cheap when hidden (early-out).
# Text is recomputed every tick but only re-assigned when it actually
# changed, so transient labels don't churn the renderer.
func _update_debug_label(body: Node3D) -> void:
	if _debug_label == null:
		return
	if _debug_label.visible != debug_visible:
		_debug_label.visible = debug_visible
	if not debug_visible:
		return
	var arch: String = "STEALTH" if vision_cone_deg > 0.0 else "SWARM"
	var faction: String = String(body.get(&"faction")) if "faction" in body else "?"
	var state_names: Array[String] = ["WANDER", "CHASE", "IDLE", "WIND_UP"]
	var phase_names: Array[String] = ["CALM", "SUSPECT", "HOSTILE", "ALERT"]
	var state_str: String = state_names[_state] if _state >= 0 and _state < state_names.size() else "?"
	var phase_str: String = phase_names[_alert_phase] if _alert_phase >= 0 and _alert_phase < phase_names.size() else "?"
	var v: Vector3 = (body as CharacterBody3D).velocity if body is CharacterBody3D else Vector3.ZERO
	var speed: float = sqrt(v.x * v.x + v.z * v.z)
	var dist_str: String = "--"
	if _target != null and is_instance_valid(_target):
		dist_str = "%.1f" % body.global_position.distance_to(_target.global_position)
	# Stealth cares about phase + chase timer; swarm just shows state + vel.
	var text: String
	if vision_cone_deg > 0.0:
		text = "[%s] %s\n%s / %s\nv=%.1f d=%s" % [arch, faction, state_str, phase_str, speed, dist_str]
	else:
		text = "[%s] %s\n%s\nv=%.1f d=%s" % [arch, faction, state_str, speed, dist_str]
	if text != _debug_label_last_text:
		_debug_label.text = text
		_debug_label_last_text = text
