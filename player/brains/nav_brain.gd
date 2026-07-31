class_name NavBrain
extends Brain

## Clean-room enemy AI driver, grown archetype by archetype in the nav
## sandbox (level/nav_test.tscn, F10). Goal: recreate each existing enemy
## type as a PRESET of these exports — better — and eventually replace
## EnemyAIBrain.
##
## This class decides WHAT to do — awareness, behavior states, destinations,
## speeds — and nothing else. HOW the pawn reaches a destination lives in
## NavSteering (paths, links, safety holds); physics lives on the body;
## visuals live on the skin. Every future behavior layer (follow, attack,
## suspect) is an export group + a state here, and must not leak into the
## other layers.
##
## v3 layers ("regular kaykit" nav): WANDER (unaware; navmesh-snapped
## destinations so it can never stray off an edge) and CHASE (aware;
## distance + LOS gated with hysteresis — no omniscience). Follow/ally is
## NOT a separate layer: it's an omniscient-toggle preset of chase (see
## docs/nav_stack.md build plan).
## Defaults mirror EnemyAIBrain's green kaykit: detect 16, exit 22,
## wander 0.33, chase 1.0.

@export_group("Target")
## Groups whose members can be detected and chased — nearest member across
## all groups wins. Plural to match the body's faction-retarget convention
## (PlayerBody.set_faction writes `target_groups` when present), so runtime
## conversions rewire this brain with no faction knowledge leaking in here.
@export var target_groups: Array[StringName] = [&"player"]
## Groups that OVERRIDE nearest-wins while a member is inside
## priority_target_radius — the sentinel "execute the gold in my bubble
## before the player" rule (plan §7). Empty = plain nearest-wins.
@export var priority_target_groups: Array[StringName] = []
## Radius (m) for the priority override. 0 = disabled.
@export var priority_target_radius: float = 0.0
## Stop steering when within this horizontal distance (m) of the target.
@export var arrive_distance: float = 1.5

@export_group("Detection")
## Skip ALL detection gating: always aware of the nearest target_group
## member, never gives up. This IS ally/follow mode (a preset toggle, not a
## separate layer) and doubles as the A/B switch when tuning awareness.
@export var omniscient: bool = false
## Awareness sphere (m) for ACQUIRING a target. Once locked, distance no
## longer matters — pursuit is sustained by sight and forgotten by time
## ("radius acquires, sight sustains, time forgets"). This is what lets a
## long route detour without the pawn forgetting you.
@export var detection_radius: float = 24.0
## Require a clear eye-to-target ray to ACQUIRE a target.
@export var require_line_of_sight: bool = true
## Ray origin height (m) on this pawn.
@export var eye_height: float = 1.4
## Seconds without SENSING the target (sight when LOS is required; presence
## inside detection_radius otherwise) before a chased target is forgotten.
## (While the memory runs, steering still targets the true position — a
## known simplification until last-known-position search lands.)
@export var chase_memory_duration: float = 6.0
## Omnidirectional no-LOS sense (m) — "hearing". Catches targets sneaking
## behind the pawn or behind thin cover within this range, scaled by the
## target's duck-typed noise_loudness() (crouched = 0 = silent). 0 = deaf.
@export var hearing_radius: float = 10.0
## Maximum seconds of continuous chase before the pawn "tuckers out" and
## gives up — drops to an amber cool-down, then calm (plan §5, the legacy
## escape valve vs locked pursuit). 0 = never (greens/reds parity default).
@export var chase_max_duration: float = 0.0
## Seconds after a tucker-out during which this pawn cannot reacquire —
## hostile-zone snap, accumulation, and peer alerts are all suppressed
## (the legacy ALERT scan window). Damage (aggro_to) punches through.
@export var tucker_recover_duration: float = 3.0
## Once HOSTILE with a held target, sustain the lock by a raw sphere
## instead of senses: no LOS, no cone, no crouch — cover does NOT break the
## chase (plan §6, the legacy aggressive-stealth escape ruleset; this
## deliberately suspends LKP anti-wallhack inside the sphere). Only
## distance beyond hostile_lock_radius, the tucker, or memory decay ends it.
@export var hostile_lock_ignores_los: bool = false
## Sphere radius (m) for the hostile lock. INVARIANT: keep this ≥
## detection_radius — a lock smaller than acquisition oscillates on a
## visible target between the radii (parity plan §6). 0 = the lock never
## breaks by distance.
@export var hostile_lock_radius: float = 0.0

@export_group("Perception")
## Vision cone arc (degrees). 360 = no arc gate (greens/reds see all around).
@export var cone_deg: float = 360.0
## Vertical sight band ±m around body Y. 0 = no vertical gate.
@export var vertical_half_height: float = 0.0
## Seconds of point-blank, center-cone sight to reach HOSTILE. 0 = instant
## acquisition (the proven v3 binary model — greens/reds parity default).
## > 0 enables the suspicion accumulator: distance and cone-centrality scale
## the fill rate, crossing suspect_threshold sends the pawn investigating.
@export var suspect_time: float = 0.0
## Suspicion level (0..1) that counts as SUSPECT (investigate the stimulus).
@export var suspect_threshold: float = 0.5
## Sight-range multiplier when the evaluated target is crouched (duck-typed
## is_crouched()). <1 = crouching shrinks how far this pawn sees — the
## sneak-past verb. 1 = stance-blind (greens/reds parity default).
## Stealth preset: 0.33 (45m standing → the legacy 15m crouched envelope).
@export_range(0.0, 1.0) var crouch_range_multiplier: float = 1.0
## Cone-arc multiplier when the evaluated target is crouched. <1 collapses
## the arc to a forward sliver. Stealth preset: 0.3 (100° → 30°).
@export_range(0.0, 1.0) var crouch_cone_multiplier: float = 1.0
## STANDING target with LOS inside this radius (m) → instant HOSTILE, no
## suspect grace (the sphere IS the danger — the legacy hostile zone).
## Crouched targets always get the accumulator. 0 = off.
@export var hostile_zone_radius: float = 0.0

@export_group("Alerts")
## On going hostile, shout to same-group peers within this radius so they
## investigate the target's position. 0 = no shouting.
@export var alert_broadcast_radius: float = 0.0
## Scene group whose members' brains receive the shout (the peers' BODIES
## are in this group — e.g. "splice_enemies"). Empty = no shouting.
@export var alert_group: StringName = &""

@export_group("Follow")
## Group whose nearest member this pawn follows whenever it has no combat
## target (ally mode: stay with your charge, engage threats opportunistically,
## return when the fight ends). Empty = no follow. Runtime conversions set
## this via PlayerBody.set_faction's guarded poke.
@export var follow_subject_group: StringName = &""
## Stop this far (m) from the follow subject.
@export var follow_distance: float = 3.5
## Combat consent: when > 0, this pawn only acquires combat targets (and
## drops held ones) while its follow subject attacked within this many
## seconds — read duck-typed via `seconds_since_attack()` on the subject
## (absent method = no gate). The companion mirrors its charge's
## aggression: you swing, she fights; you stop, she breaks off and returns
## to your side. Being hit while passive doesn't provoke her either (the
## next tick drops any aggro target). 0 = always engage (golds, enemies).
@export var engage_requires_subject_combat: float = 0.0

@export_group("Squad")
## NavBlackboard squad this brain joins (a board node with matching `group`
## must exist in the level). Empty = solo: no board lookups at all —
## provably the pre-blackboard behavior (the off-switch is structural).
## Enemies and allies use the identical mechanism; conversions may poke
## this (gold → "allies") like any other guarded export.
@export var squad_group: StringName = &""
## Unclaimed engagers hold a spread perimeter this far (m) from the target
## instead of piling into the same doorway; a freed claim slot (death,
## target loss) rotates the next pawn in automatically.
@export var standoff_distance: float = 6.0

@export_group("Attack")
## Horizontal strike range (m). 0 disables the attack layer (nav-only pawn).
@export var attack_range: float = 2.0
## Max vertical delta (m) to fire — jumping over a swing dodges it (the
## drone-era horizontal-only lesson; see CLAUDE.md anti-patterns).
@export var attack_vertical_range: float = 1.5
## Seconds between attack triggers.
@export var attack_cooldown: float = 1.6
## Wind-up phase before the swing fires — the pawn slows to
## wind_up_speed_fraction and telegraphs for this long. This is the
## player's punish/dodge window (the old brain's combat beat). The pawn
## COMMITS: dodging makes the swing whiff, it doesn't cancel it.
## 0 = instant attacks.
@export var wind_up_duration: float = 0.55
## Fraction of chase speed kept during wind-up (0 = full stop, 0.15 = creep).
@export_range(0.0, 1.0) var wind_up_speed_fraction: float = 0.15
## Seconds after aggro_to (damage wakes the pawn) during which the attacker
## is pursued regardless of senses.
@export var aggro_grace: float = 4.0

@export_group("Performance")
## Tick brain logic every Nth physics frame while WANDERING (chase always
## runs full rate). Skipped frames keep the last move_direction so the body
## keeps walking; delta accumulates so timers stay wallclock-true. Far
## culling is level-side (enemy_distance_sleep.gd — pawns are in "enemies").
@export_range(1, 16) var wander_tick_every: int = 4

@export_group("Speed")
## Fraction of the body's max speed while wandering.
@export_range(0.0, 1.0) var wander_speed_fraction: float = 0.33
## Fraction of the body's max speed while chasing.
@export_range(0.0, 1.0) var chase_speed_fraction: float = 1.0

@export_group("Wander")
## Radius (m) around the pawn for random wander destinations (navmesh-
## snapped, so picks always land on walkable ground).
@export var wander_radius: float = 8.0
## New destination when this timer expires or the pawn arrives.
@export var min_wander_interval: float = 1.5
@export var max_wander_interval: float = 4.0

@export_group("Patrol")
## RANDOM = navmesh-snapped random points (default). ARC_SCAN = the sentinel
## patrol: walk a gentle arc, stop, sweep the head (and vision cone)
## side-to-side via face_yaw_override, repeat — with per-pawn phase jitter
## so a cluster never scans in lockstep.
enum WanderStyle { RANDOM, ARC_SCAN }
@export var wander_style: WanderStyle = WanderStyle.RANDOM
## Seconds walking the arc each cycle.
@export var arc_walk_duration: float = 4.0
## Arc curve rate (deg/s) while walking. ~25 = ~100° over a 4s walk.
@export var arc_walk_turn_rate_deg: float = 25.0
## Seconds standing still scanning each cycle.
@export var pause_duration: float = 4.0
## Max head-turn offset (deg) during the pause scan. ±60 ≈ over-the-shoulder.
@export var pause_look_max_deg: float = 60.0
## Scan sine cycles per second. 0.4 Hz = 2.5s per full left-right-left sweep.
@export var pause_look_frequency_hz: float = 0.4
## ± fraction applied to each cycle's duration so pawns drift out of sync.
@export_range(0.0, 1.0) var cycle_jitter: float = 0.4

@export_group("Navigation")
## Re-request a path only when the destination drifted this far (m).
@export var repath_distance: float = 1.0

@export_group("Debug")
## Print state/target/waypoint transitions (deduped — never per tick).
@export var debug_log: bool = true

## Deduped state transitions (StringName of the State enum key, e.g.
## &"WANDER" -> &"CHASE"). Bodies/components subscribe — the brain never
## applies buffs, tints, or sounds itself (docs/nav_stack.md).
signal state_changed(previous: StringName, current: StringName)
## Deduped suspicion accumulator readout (0..1) for tint/cone/HUD readers.
signal suspicion_changed(value: float)

enum State { WANDER, CHASE, WIND_UP, SUSPECT, FOLLOW }

var _state: State = State.WANDER
var _intent := Intent.new()
var _nav := NavSteering.new()
var _perception := NavPerception.new()
var _target: Node3D = null
var _arrived: bool = false
# Pawn facing (cone axis) — owned here, never read off the body: the brain
# commanded the movement / the patrol scan, so it already knows.
var _facing: Vector3 = Vector3.FORWARD
var _sensed_this_tick: bool = false
var _alert_sent: bool = false
var _last_suspicion_emitted: float = -1.0
# ARC_SCAN patrol state (lazy-initialized with random phase per pawn).
var _patrol_inited: bool = false
var _patrol_walking: bool = false
var _patrol_timer: float = 0.0
var _scan_phase_offset: float = 0.0
var _pause_yaw_anchor: float = 0.0
var _pause_elapsed: float = 0.0
var _arc_dir: Vector3 = Vector3.ZERO
var _wander_point: Vector3 = Vector3.INF
var _wander_timer: float = 0.0
var _attack_cooldown_timer: float = 0.0
var _aggro_timer: float = 0.0
var _wind_up_timer: float = 0.0
# Tucker-out bookkeeping (plan §5): seconds spent holding the current
# target (reset on every target change) and the post-give-up window during
# which reacquisition is suppressed.
var _chase_elapsed: float = 0.0
var _tucker_cooldown: float = 0.0
# Perf staggering: random offset picked lazily so a crowd spawned together
# doesn't think on the same physics frame; -1 = not yet picked.
var _tick_offset: int = -1
var _skip_accum: float = 0.0
# External CONTROL state (hack freeze / future stuns). While _frozen the
# tick early-returns a zero-move intent — no patrol, no senses, no swing.
# _freeze_progress is presentation data only (the cone visual's dying-
# signal flicker envelope reads it via perception_view).
var _frozen: bool = false
var _freeze_progress: float = 0.0
# Plan R6 view memo: the stance perception_view reports effective numbers
# for — held target wins, else the nearest scan candidate. Deduped by the
# brain each tick so the cone visual never flickers between candidates.
var _last_nearest: Node3D = null
var _view_crouched: bool = false
# Squad blackboard (null = solo; every board read has a solo fallback).
var _board: NavBlackboard = null
var _board_searched: bool = false
# This tick's engage-claim verdict; true in solo (no board = no gating).
var _engage_claimed: bool = true
# First NavBrain instance to tick claims the DebugPanel section (backtick
# toggles the panel in-game). Static so 8 dummies don't fight over it —
# sliders tune THAT pawn; bank values via the panel's "Copy diff" button.
static var _panel_claimed: bool = false
# True only on the instance that actually claimed the panel — its
# _exit_tree releases the claim (and the panel rows) so the next ticking
# brain re-registers with LIVE callables instead of leaving the panel bound
# to a freed instance (the backtick crash).
var _panel_claimed_by_me: bool = false


func _exit_tree() -> void:
	if not _panel_claimed_by_me:
		return
	_panel_claimed_by_me = false
	_panel_claimed = false
	var panel: Node = get_node_or_null(^"/root/DebugPanel")
	if panel != null and panel.has_method(&"remove_source"):
		panel.call(&"remove_source", "nav_brain.gd")


func _register_debug_panel() -> void:
	if _panel_claimed:
		return
	var panel: Node = get_node_or_null(^"/root/DebugPanel")
	if panel == null or not panel.has_method(&"add_slider"):
		return
	_panel_claimed = true
	_panel_claimed_by_me = true
	const SRC := "nav_brain.gd"
	panel.add_toggle("Nav/Detection/omniscient (ally)",
		func(): return omniscient, func(v): omniscient = v, SRC)
	panel.add_slider("Nav/Detection/detection_radius", 4.0, 60.0, 1.0,
		func(): return detection_radius, func(v): detection_radius = v, SRC)
	panel.add_slider("Nav/Detection/chase_memory_duration", 0.5, 20.0, 0.5,
		func(): return chase_memory_duration, func(v): chase_memory_duration = v, SRC)
	panel.add_slider("Nav/Detection/hearing_radius", 0.0, 30.0, 0.5,
		func(): return hearing_radius, func(v): hearing_radius = v, SRC)
	panel.add_slider("Nav/Attack/attack_range", 0.0, 6.0, 0.1,
		func(): return attack_range, func(v): attack_range = v, SRC)
	panel.add_slider("Nav/Attack/attack_vertical_range", 0.0, 4.0, 0.1,
		func(): return attack_vertical_range, func(v): attack_vertical_range = v, SRC)
	panel.add_slider("Nav/Attack/attack_cooldown", 0.2, 5.0, 0.1,
		func(): return attack_cooldown, func(v): attack_cooldown = v, SRC)
	panel.add_slider("Nav/Attack/wind_up_duration", 0.0, 2.0, 0.05,
		func(): return wind_up_duration, func(v): wind_up_duration = v, SRC)
	panel.add_slider("Nav/Attack/wind_up_speed_fraction", 0.0, 1.0, 0.05,
		func(): return wind_up_speed_fraction, func(v): wind_up_speed_fraction = v, SRC)
	panel.add_slider("Nav/Attack/aggro_grace", 0.0, 10.0, 0.5,
		func(): return aggro_grace, func(v): aggro_grace = v, SRC)
	panel.add_slider("Nav/Performance/wander_tick_every", 1.0, 16.0, 1.0,
		func(): return wander_tick_every, func(v): wander_tick_every = int(v), SRC)
	panel.add_toggle("Nav/Detection/require_line_of_sight",
		func(): return require_line_of_sight, func(v): require_line_of_sight = v, SRC)
	panel.add_slider("Nav/Speed/wander_speed_fraction", 0.0, 1.0, 0.01,
		func(): return wander_speed_fraction, func(v): wander_speed_fraction = v, SRC)
	panel.add_slider("Nav/Speed/chase_speed_fraction", 0.0, 1.0, 0.01,
		func(): return chase_speed_fraction, func(v): chase_speed_fraction = v, SRC)
	panel.add_slider("Nav/Wander/wander_radius", 2.0, 24.0, 0.5,
		func(): return wander_radius, func(v): wander_radius = v, SRC)
	panel.add_slider("Nav/Target/arrive_distance", 0.5, 8.0, 0.1,
		func(): return arrive_distance, func(v): arrive_distance = v, SRC)
	panel.add_slider("Nav/Perception/cone_deg", 30.0, 360.0, 5.0,
		func(): return cone_deg, func(v): cone_deg = v, SRC)
	panel.add_slider("Nav/Perception/suspect_time", 0.0, 4.0, 0.1,
		func(): return suspect_time, func(v): suspect_time = v, SRC)
	panel.add_slider("Nav/Perception/vertical_half_height", 0.0, 6.0, 0.5,
		func(): return vertical_half_height, func(v): vertical_half_height = v, SRC)
	panel.add_slider("Nav/Alerts/alert_broadcast_radius", 0.0, 40.0, 1.0,
		func(): return alert_broadcast_radius, func(v): alert_broadcast_radius = v, SRC)
	panel.add_readout("Nav/state",
		func(): return "%s target=%s susp=%.2f" % [State.keys()[_state],
			_target.name if _target != null and is_instance_valid(_target) else "-",
			_perception.suspicion],
		SRC)


func tick(body: Node3D, delta: float) -> Intent:
	_intent.jump_pressed = false
	_intent.attack_pressed = false
	# Cleared every tick; only the patrol pause-scan re-sets it, so all other
	# states fall through to the body's velocity-tracked facing.
	_intent.face_yaw_override_set = false
	# is_inside_tree guard: group scans + world queries need the tree; brains
	# tick pre-spawn in unit tests.
	if not body.is_inside_tree():
		_intent.move_direction = Vector3.ZERO
		return _intent

	# External freeze (hack/stun). Sits BEFORE the wander stagger so a frozen
	# pawn can never replay a stale move on a skipped frame (plan R1).
	# Cooldowns keep ticking (old-brain parity: enemy_ai_brain ticked them
	# above its hack gate); senses/patrol/attack all stop, so suspicion
	# holds. _skip_accum is consumed so unfreezing doesn't flush the whole
	# freeze span into suspicion decay and wander timers in one tick.
	if _frozen:
		_skip_accum = 0.0
		_attack_cooldown_timer = maxf(0.0, _attack_cooldown_timer - delta)
		_aggro_timer = maxf(0.0, _aggro_timer - delta)
		_tucker_cooldown = maxf(0.0, _tucker_cooldown - delta)
		_intent.move_direction = Vector3.ZERO
		return _intent

	# Perf: while WANDERING, run brain logic every Nth physics frame (chase
	# always full rate). Skipped frames keep the last move_direction so the
	# body keeps walking; edge flags stay cleared. Random offset staggers a
	# crowd so they don't all think on the same frame.
	if _tick_offset < 0:
		_tick_offset = randi() % maxi(wander_tick_every, 1)
	_skip_accum += delta
	if _state == State.WANDER and wander_tick_every > 1 \
			and (Engine.get_physics_frames() + _tick_offset) % wander_tick_every != 0:
		return _intent
	delta = _skip_accum
	_skip_accum = 0.0
	_intent.move_direction = Vector3.ZERO
	_attack_cooldown_timer = maxf(0.0, _attack_cooldown_timer - delta)
	_aggro_timer = maxf(0.0, _aggro_timer - delta)
	_tucker_cooldown = maxf(0.0, _tucker_cooldown - delta)

	_nav.repath_distance = repath_distance
	_nav.debug_log = debug_log
	_nav.setup(body)
	_register_debug_panel()
	_sync_perception()
	_update_awareness(body, delta)
	# View memo (plan R6): stance the cone should size against this tick.
	var view_subject: Node3D = _target \
		if _target != null and is_instance_valid(_target) else _last_nearest
	_view_crouched = NavPerception.crouched_of(view_subject)

	if _target != null:
		var board := _get_board(body)
		_engage_claimed = board == null or board.claim_engage(body, _target)
		if _state == State.WIND_UP:
			_tick_wind_up(body, delta)
		else:
			_set_state(body, State.CHASE)
			_intent.move_direction = _chase(body) * chase_speed_fraction
			# Only claimed engagers swing; perimeter holders contain.
			if _engage_claimed:
				_maybe_start_wind_up(body)
	elif _sensed_this_tick and _perception.suspicion > 0.0 \
			and not _perception.is_hostile():
		# SUSPECT freeze-and-stare (plan §4): actively sensing something
		# sub-hostile — stand still and lock the cone on it while the fuse
		# burns (the legacy readable "I'm being noticed" beat; also fires on
		# a heard-but-unseen noise, blessed in review R7). Unreachable for
		# suspect_time=0 archetypes: they snap hostile the same tick they
		# sense, so greens/reds are provably unchanged.
		_set_state(body, State.SUSPECT)
		_intent.move_direction = Vector3.ZERO
		var to_stim := _perception.lkp - body.global_position
		to_stim.y = 0.0
		if to_stim.length() > 0.1:
			_facing = to_stim.normalized()
	elif _perception.is_suspect() and _perception.lkp != Vector3.INF:
		_set_state(body, State.SUSPECT)
		_intent.move_direction = _investigate(body) * wander_speed_fraction
		# Cone locks onto the stimulus while investigating.
		var to_lkp := _perception.lkp - body.global_position
		to_lkp.y = 0.0
		if to_lkp.length() > 0.1:
			_facing = to_lkp.normalized()
	else:
		var subject: Node3D = _follow_subject(body) if follow_subject_group != &"" else null
		if subject != null:
			_set_state(body, State.FOLLOW)
			_intent.move_direction = _nav.steer_to(
				body, subject.global_position, follow_distance) * chase_speed_fraction
		else:
			_set_state(body, State.WANDER)
			_intent.move_direction = _wander(body, delta) * wander_speed_fraction

	# Facing follows commanded movement (patrol pause / SUSPECT set it above).
	if _intent.move_direction.length() > 0.05:
		_facing = _intent.move_direction.normalized()

	if _nav.consume_jump(body):
		_intent.jump_pressed = true
	_emit_suspicion()
	return _intent


## Read-only snapshot for visualizers (cone renderer, HUD, debug labels).
## Consumers must never write back — rendering the stack can't change it.
func perception_view() -> Dictionary:
	return {
		"facing": _facing,
		"suspicion": _perception.suspicion,
		"suspect_threshold": suspect_threshold,
		# Effective (stance-gated) numbers — the picture shrinks with the
		# truth when the target crouches, with zero cone logic here.
		"cone_deg": _perception.effective_cone_deg(_view_crouched),
		"range": _perception.effective_range(_view_crouched),
		"target_crouched": _view_crouched,
		"eye_height": eye_height,
		"state": StringName(State.keys()[_state]),
		"hack_active": _frozen,
		"hack_progress": _freeze_progress,
	}


## Freeze channel (external CONTROL state): any system can push
## "frozen/stunned". StealthKillTarget drives it each tick during a hack
## with the hold progress; releasing pre-completion drops it the same tick.
func set_hack_active(active: bool, progress: float = 0.0) -> void:
	_frozen = active
	_freeze_progress = clampf(progress, 0.0, 1.0)


## True while committed to a fight. StealthKillTarget gates the hack prompt
## on this — sneak windows close the moment the pawn goes hostile.
func is_chasing() -> bool:
	return _state == State.CHASE or _state == State.WIND_UP


## Forward brain exports into the perception model (presets own numbers).
func _sync_perception() -> void:
	_perception.sight_range = detection_radius
	_perception.cone_deg = cone_deg
	_perception.vertical_half_height = vertical_half_height
	_perception.hearing_radius = hearing_radius
	_perception.suspect_time = suspect_time
	_perception.suspect_threshold = suspect_threshold
	_perception.memory_duration = chase_memory_duration
	_perception.crouch_range_multiplier = crouch_range_multiplier
	_perception.crouch_cone_multiplier = crouch_cone_multiplier
	_perception.hostile_zone_radius = hostile_zone_radius
	_perception.facing = _facing


func _emit_suspicion() -> void:
	var s: float = _perception.suspicion
	if absf(s - _last_suspicion_emitted) > 0.03 or (s == 0.0 and _last_suspicion_emitted != 0.0):
		_last_suspicion_emitted = s
		suspicion_changed.emit(s)


# ── Attack ───────────────────────────────────────────────────────────────

func _maybe_start_wind_up(body: Node3D) -> void:
	if attack_range <= 0.0 or _attack_cooldown_timer > 0.0:
		return
	var to_target := _target.global_position - body.global_position
	var dy: float = absf(to_target.y)
	to_target.y = 0.0
	if to_target.length() > attack_range or dy > attack_vertical_range:
		return
	if wind_up_duration <= 0.0:
		_intent.attack_pressed = true
		_attack_cooldown_timer = attack_cooldown
		return
	_wind_up_timer = wind_up_duration
	_set_state(body, State.WIND_UP)


## The telegraph: creep toward the target for wind_up_duration, then the
## swing fires no matter where they went (committed — the whiff IS the
## player's reward for dodging).
func _tick_wind_up(body: Node3D, delta: float) -> void:
	_wind_up_timer -= delta
	_intent.move_direction = _nav.steer_to(body, _target.global_position, arrive_distance) \
		* chase_speed_fraction * wind_up_speed_fraction
	if _wind_up_timer <= 0.0:
		_intent.attack_pressed = true
		_attack_cooldown_timer = attack_cooldown
		_set_state(body, State.CHASE)


## Damage wakes the pawn: force-target the attacker, bypassing all senses
## for aggro_grace seconds. Wire from the body's take_hit.
func aggro_to(attacker: Node) -> void:
	if attacker == null or not (attacker is Node3D) or not is_instance_valid(attacker):
		return
	_aggro_timer = aggro_grace
	# Damage punches through the tucker window (plan R3) and starts a fresh
	# chase clock — getting hit always wakes the pawn.
	_tucker_cooldown = 0.0
	_chase_elapsed = 0.0
	# Damage is a full sense: snap hostile and remember where it came from.
	_perception.suspicion = 1.0
	_perception.mark_sensed((attacker as Node3D).global_position)
	if attacker != _target:
		_target = attacker as Node3D
		if debug_log:
			print("[nav] aggro -> %s" % attacker.name)


# ── Chase ────────────────────────────────────────────────────────────────

func _chase(body: Node3D) -> Vector3:
	# Live position only while actually sensing; otherwise the last-known
	# position (kills the memory-window wallhack — doc edge case #2).
	var goal: Vector3 = _target.global_position if _sensed_this_tick else _perception.lkp
	if goal == Vector3.INF:
		goal = _target.global_position
	# Unclaimed squad members hold a spread standoff perimeter instead of
	# piling into the same approach; claims rotate them in when slots free.
	if not _engage_claimed and _board != null and is_instance_valid(_board):
		goal += _board.search_offset_for(body, standoff_distance)
	var to_goal := goal - body.global_position
	to_goal.y = 0.0
	var arrived := to_goal.length() <= arrive_distance
	if arrived != _arrived:
		_arrived = arrived
		if debug_log:
			print("[nav] %s %s target (%.1fm)" % [
				body.name, "arrived at" if arrived else "left", to_goal.length()])
	return _nav.steer_to(body, goal, arrive_distance)


## SUSPECT: walk to the stimulus position at wander speed. Arriving without
## reacquiring drops suspicion under the threshold — that IS the v1 search
## (docs/nav_stack.md build plan #8); decay handles the rest.
func _investigate(body: Node3D) -> Vector3:
	var goal: Vector3 = _perception.lkp
	# Squad search: hunt the squad's freshest shared LKP, approaching from a
	# per-pawn spread direction so investigators fan out instead of
	# converging on one point. Solo = own LKP, no offset — today's behavior.
	var board := _get_board(body)
	if board != null:
		var shared: Vector3 = board.squad_lkp()
		if shared != Vector3.INF:
			goal = shared + board.search_offset_for(body, 2.5)
	var to := goal - body.global_position
	to.y = 0.0
	if to.length() <= arrive_distance:
		_perception.suspicion = minf(_perception.suspicion, suspect_threshold - 0.01)
		return Vector3.ZERO
	var dir := _nav.steer_to(body, goal, arrive_distance)
	# No usable route to the stimulus — give up rather than stand suspicious
	# forever. (Transient holds — map sync, crowd jams — also abort; the
	# pawn just resumes patrol, which reads fine and can't deadlock.)
	if dir == Vector3.ZERO and _nav.has_agent():
		_perception.suspicion = minf(_perception.suspicion, suspect_threshold - 0.01)
	return dir


## Lazy squad-board lookup. Null = solo (empty squad_group, no matching
## board in the level, or the board freed) — every caller has a solo path.
func _get_board(body: Node3D) -> NavBlackboard:
	if squad_group == &"":
		return null
	if _board != null and not is_instance_valid(_board):
		_board = null
	if _board == null and not _board_searched:
		_board_searched = true
		_board = NavBlackboard.find_for(body.get_tree(), squad_group)
	return _board


# ── Awareness ────────────────────────────────────────────────────────────

func _update_awareness(body: Node3D, delta: float) -> void:
	_sensed_this_tick = false
	if omniscient:
		var nearest_o := _nearest_candidate(body, INF)
		_last_nearest = nearest_o
		if nearest_o != null:
			_perception.suspicion = 1.0
			_perception.mark_sensed(nearest_o.global_position)
			_sensed_this_tick = true
		_set_target(body, nearest_o)
		return
	var scan_radius: float = maxf(detection_radius, hearing_radius)
	var nearest: Node3D = _nearest_candidate(body, scan_radius)
	_last_nearest = nearest
	# Combat consent (companions): passive subject = no acquisition, and any
	# held target (including aggro retaliation) is dropped below.
	var combat_ok: bool = _subject_combat_ok(body)
	if _target == null or not is_instance_valid(_target):
		_target = null
		# Acquisition: the nearest candidate feeds the accumulator. With
		# suspect_time = 0 this snaps hostile in one tick (v3 parity); with
		# > 0 the pawn climbs through SUSPECT on the way up.
		var s: float = 0.0
		if nearest != null and combat_ok:
			s = _perception.sense_strength(
				body.global_position, nearest,
				not require_line_of_sight or _can_see(body, nearest), false)
		# Tucker recover window (plan §5/R3): no reacquisition — the
		# hostile-zone snap and accumulation are both suppressed here, and
		# receive_alert is gated at its entry. aggro_to punches through.
		if _tucker_cooldown > 0.0:
			s = 0.0
		if s > 0.0:
			_perception.integrate(s, delta)
			_perception.mark_sensed(nearest.global_position)
			_sensed_this_tick = true
		elif not (_perception.is_suspect() and _perception.lkp != Vector3.INF):
			# Decay is SENSE memory, not investigation intent: while an
			# investigation is live (suspect + a place to check) suspicion
			# holds — _investigate() drops it on arrival or no-route.
			_perception.integrate(0.0, delta)
		if _perception.is_hostile() and nearest != null:
			_set_target(body, nearest)
			var board := _get_board(body)
			if board != null:
				board.report_alert(1.0)
				board.report_lkp(nearest.global_position)
			_maybe_broadcast_alert(body, nearest)
		return
	# Combat consent expired mid-hold (or an aggro hit landed while the
	# subject is passive): break off, forget, return to the subject's side.
	if not combat_ok:
		_set_target(body, null)
		_perception.forget()
		_alert_sent = false
		return
	# Holding a target: "radius acquires, sight sustains, time forgets."
	# Sight-driven sustain lifts range/cone/vertical gates (committed pursuit
	# never drops mid-route); radius-driven setups (require_line_of_sight
	# off) sustain inside the detection radius, exactly as v3 did. Aggro
	# grace counts as fully sensed. Decay reaching zero = forgotten.
	# Tucker-out (plan §5): a chase runs at most chase_max_duration seconds,
	# then the pawn gives up regardless of senses — the player's earned
	# escape against a lock that would otherwise never end.
	_chase_elapsed += delta
	if chase_max_duration > 0.0 and _chase_elapsed >= chase_max_duration:
		_tucker_out(body)
		return
	var s2: float
	if hostile_lock_ignores_los:
		# Hostile lock (plan §6): while a target is HELD, the sphere is the
		# ONLY sense — no fallback to sight outside it (that reopens the
		# edge oscillation the §6 invariant exists to prevent).
		var flat_d := _target.global_position - body.global_position
		flat_d.y = 0.0
		s2 = 1.0 if (hostile_lock_radius <= 0.0 \
			or flat_d.length() <= hostile_lock_radius) else 0.0
	else:
		s2 = _perception.sense_strength(
			body.global_position, _target,
			not require_line_of_sight or _can_see(body, _target),
			require_line_of_sight)
	if _aggro_timer > 0.0:
		s2 = maxf(s2, 1.0)
	_perception.integrate(s2, delta)
	if s2 > 0.0:
		_perception.mark_sensed(_target.global_position)
		_sensed_this_tick = true
		# The squad hunts one truth: freshest sighting wins.
		var hold_board := _get_board(body)
		if hold_board != null:
			hold_board.report_lkp(_target.global_position)
	if _perception.suspicion <= 0.0:
		_set_target(body, null)
		_alert_sent = false
		return
	# Nearest-wins among currently sensed candidates.
	if nearest != null and nearest != _target \
			and _perception.sense_strength(body.global_position, nearest,
				not require_line_of_sight or _can_see(body, nearest), false) > 0.0:
		_set_target(body, nearest)


## Peer went hostile nearby and shouted this position: investigate it.
## Already-hostile pawns ignore the shout — they have their own fight.
## A tucker-recovering pawn ignores it too (plan R3): the give-up window is
## the player's earned escape, a shout must not un-earn it.
func receive_alert(pos: Vector3) -> void:
	if _perception.is_hostile():
		return
	if _tucker_cooldown > 0.0:
		return
	_perception.notify(pos, suspect_threshold)


## The chase ran its course (plan §5): drop the target, cool to an amber
## scan (suspicion just under threshold, decaying — visually the legacy
## ALERT→CALM), and refuse reacquisition for tucker_recover_duration.
func _tucker_out(body: Node3D) -> void:
	if debug_log:
		print("[nav] %s tuckered out (%.1fs chase)" % [body.name, _chase_elapsed])
	_set_target(body, null)
	_alert_sent = false
	_tucker_cooldown = tucker_recover_duration
	_perception.suspicion = minf(_perception.suspicion, suspect_threshold - 0.01)
	_perception.lkp = Vector3.INF  # scan in place — don't investigate


func _maybe_broadcast_alert(body: Node3D, target: Node3D) -> void:
	if _alert_sent or alert_broadcast_radius <= 0.0 or alert_group == &"":
		return
	_alert_sent = true
	var shouted: int = 0
	for n: Node in body.get_tree().get_nodes_in_group(alert_group):
		if n == body or not (n is Node3D):
			continue
		if (n as Node3D).global_position.distance_to(body.global_position) > alert_broadcast_radius:
			continue
		for c: Node in n.get_children():
			if c.has_method(&"receive_alert"):
				c.call(&"receive_alert", target.global_position)
				shouted += 1
				break
	if debug_log and shouted > 0:
		print("[nav] %s ALERT -> %d peers investigate (%.1f,%.1f,%.1f)" % [
			body.name, shouted, target.global_position.x,
			target.global_position.y, target.global_position.z])


## Overridable perception seam — tests mock sight by subclassing and
## scripting this; the real implementation is a physics ray.
func _can_see(body: Node3D, target: Node3D) -> bool:
	return _has_los(body, target)


## Combat consent check (see engage_requires_subject_combat). True when the
## gate is off, the subject is absent/ungateable, or the subject fought
## within the window.
func _subject_combat_ok(body: Node3D) -> bool:
	if engage_requires_subject_combat <= 0.0:
		return true
	var subject: Node3D = _follow_subject(body) if follow_subject_group != &"" else null
	if subject == null or not subject.has_method(&"seconds_since_attack"):
		return true
	return float(subject.call(&"seconds_since_attack")) <= engage_requires_subject_combat


## Nearest member of follow_subject_group at any range, or null. The subject
## is this pawn's charge — no detection gating applies to knowing where your
## own group is.
func _follow_subject(body: Node3D) -> Node3D:
	var best: Node3D = null
	var best_d: float = INF
	for n: Node in body.get_tree().get_nodes_in_group(follow_subject_group):
		if not (n is Node3D) or n == body:
			continue
		var d := (n as Node3D).global_position.distance_squared_to(body.global_position)
		if d < best_d:
			best_d = d
			best = n as Node3D
	return best


## Nearest member across all target_groups within `radius`, or null.
## Priority pre-pass (plan §7): a priority_target_groups member inside
## priority_target_radius wins outright, even when a regular target is
## closer — the sentinel executes the gold in its bubble first.
func _nearest_candidate(body: Node3D, radius: float) -> Node3D:
	if priority_target_radius > 0.0 and not priority_target_groups.is_empty():
		var p := _nearest_in_groups(
			body, priority_target_groups, minf(priority_target_radius, radius))
		if p != null:
			return p
	return _nearest_in_groups(body, target_groups, radius)


func _nearest_in_groups(body: Node3D, groups: Array[StringName], radius: float) -> Node3D:
	var best: Node3D = null
	var best_dist_sq: float = radius * radius
	for group: StringName in groups:
		for n: Node in body.get_tree().get_nodes_in_group(group):
			if not (n is Node3D) or n == body:
				continue
			var dist_sq := (n as Node3D).global_position.distance_squared_to(body.global_position)
			if dist_sq < best_dist_sq:
				best_dist_sq = dist_sq
				best = n as Node3D
	return best


func _has_los(body: Node3D, target: Node3D) -> bool:
	var space := body.get_world_3d().direct_space_state
	if space == null:
		return true
	var query := PhysicsRayQueryParameters3D.create(
		body.global_position + Vector3.UP * eye_height,
		target.global_position + Vector3.UP * 1.0)
	if body is CollisionObject3D:
		query.exclude = [(body as CollisionObject3D).get_rid()]
	var hit := space.intersect_ray(query)
	return hit.is_empty() or hit.get("collider") == target


func _set_target(body: Node3D, new_target: Node3D) -> void:
	if new_target == _target:
		return
	if new_target == null:
		# Free our engage slot so the next perimeter pawn rotates in.
		var board := _get_board(body)
		if board != null:
			board.release_engage(body)
		_engage_claimed = true
	_target = new_target
	_chase_elapsed = 0.0  # fresh target, fresh tucker clock (plan §5)
	if debug_log:
		print("[nav] %s target -> %s" % [
			body.name, new_target.name if new_target != null else "<none>"])


func _set_state(body: Node3D, new_state: State) -> void:
	if new_state == _state:
		return
	if debug_log:
		print("[nav] %s %s -> %s" % [
			body.name, State.keys()[_state], State.keys()[new_state]])
	var previous := _state
	_state = new_state
	_wander_point = Vector3.INF  # fresh destination when re-entering wander
	state_changed.emit(
		StringName(State.keys()[previous]), StringName(State.keys()[new_state]))


# ── Wander ───────────────────────────────────────────────────────────────

func _wander(body: Node3D, delta: float) -> Vector3:
	if wander_style == WanderStyle.ARC_SCAN:
		return _patrol(body, delta)
	if not _nav.has_agent():
		return Vector3.ZERO  # no navmesh in this setup — stand rather than stray
	_wander_timer -= delta
	var need_new: bool = _wander_point == Vector3.INF or _wander_timer <= 0.0
	if not need_new:
		var dx: float = _wander_point.x - body.global_position.x
		var dz: float = _wander_point.z - body.global_position.z
		need_new = dx * dx + dz * dz < 1.0
	if need_new:
		_pick_wander_point(body)
	if _wander_point == Vector3.INF:
		return Vector3.ZERO
	return _nav.steer_to(body, _wander_point, 1.0)


## ARC_SCAN patrol: walk a gentle curving arc, then stand and sweep the
## head (and vision cone) side-to-side, repeat. Movement is a direct heading
## (not a navmesh path); a navmesh probe 2m ahead flips the arc at edges so
## the no-ledge-fall guarantee holds without ray probes.
func _patrol(body: Node3D, delta: float) -> Vector3:
	if not _patrol_inited:
		_patrol_inited = true
		# Random phase per pawn: a spawned cluster never scans in lockstep.
		_patrol_walking = randf() < arc_walk_duration \
			/ maxf(arc_walk_duration + pause_duration, 0.001)
		_patrol_timer = randf_range(0.0, arc_walk_duration + pause_duration)
		_scan_phase_offset = randf() * TAU
	_patrol_timer -= delta
	if _patrol_timer <= 0.0:
		_patrol_walking = not _patrol_walking
		var d: float = arc_walk_duration if _patrol_walking else pause_duration
		# Per-cycle jitter keeps neighbors drifting apart over time.
		_patrol_timer = d * randf_range(1.0 - cycle_jitter, 1.0 + cycle_jitter)
		if not _patrol_walking:
			_pause_yaw_anchor = atan2(_facing.x, _facing.z)
			_pause_elapsed = 0.0
	if _patrol_walking:
		if _arc_dir == Vector3.ZERO:
			_arc_dir = _facing if _facing.length() > 0.1 else Vector3.FORWARD
		_arc_dir = _arc_dir.rotated(
			Vector3.UP, deg_to_rad(arc_walk_turn_rate_deg) * delta).normalized()
		# Edge guard: if the point 2m ahead doesn't project onto the navmesh
		# nearby, we're arcing off walkable ground — flip the arc.
		if _nav.has_agent():
			var probe: Vector3 = body.global_position + _arc_dir * 2.0
			var snapped: Vector3 = NavigationServer3D.map_get_closest_point(
				body.get_world_3d().navigation_map, probe)
			if snapped != Vector3.ZERO \
					and Vector2(snapped.x - probe.x, snapped.z - probe.z).length() > 1.0:
				_arc_dir = -_arc_dir
		return _arc_dir
	# Pause: stand still, sweep yaw around the anchor. The override rotates
	# the skin (body smooths it); _facing follows so the cone sweeps too.
	_pause_elapsed += delta
	var ofs: float = deg_to_rad(pause_look_max_deg) \
		* sin(_pause_elapsed * pause_look_frequency_hz * TAU + _scan_phase_offset)
	var scan_yaw: float = _pause_yaw_anchor + ofs
	_intent.face_yaw_override = scan_yaw
	_intent.face_yaw_override_set = true
	_facing = Vector3(sin(scan_yaw), 0.0, cos(scan_yaw))
	return Vector3.ZERO


func _pick_wander_point(body: Node3D) -> void:
	_wander_timer = randf_range(min_wander_interval, max_wander_interval)
	var ang: float = randf() * TAU
	var offset := Vector3(cos(ang), 0.0, sin(ang)) * randf_range(2.0, wander_radius)
	var map: RID = body.get_world_3d().navigation_map
	var snapped: Vector3 = NavigationServer3D.map_get_closest_point(
		map, body.global_position + offset)
	# Pre-sync maps answer ZERO for everything; treat as "no pick this cycle."
	if snapped == Vector3.ZERO:
		_wander_point = Vector3.INF
		return
	_wander_point = snapped
