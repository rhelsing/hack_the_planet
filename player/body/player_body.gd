class_name PlayerBody
extends CharacterBody3D

## Universal humanoid pawn. Reads an Intent each physics tick from a child
## Brain node (PlayerBrain for humans, AI brains for NPCs, NetworkBrain for
## remote peers), applies movement/physics/animation. No code path inside this
## file knows what kind of brain is driving it — swap brains freely, same body.

## HUD / listener signals. Local to this body (not on the Events autoload)
## so each pawn reports its own state without bus noise. HUD subscribes via
## `get_tree().get_first_node_in_group("player")` and connects directly.
signal health_changed(new_health: int, old_health: int)
signal died()
signal respawned()
## Emitted when an ability is first owned (flag flipped true). HUD powerup_row
## adds a slot for it. Source: child Ability node calls notify_ability_granted.
signal ability_granted(ability_id: StringName)
## Emitted when an ability's `enabled` state flips (e.g. hack mode toggled on).
## HUD powerup_row tints the icon accordingly.
signal ability_enabled_changed(ability_id: StringName, enabled: bool)

@export_group("Skin")
## Optional skin scene override. If set, the hardcoded SophiaSkin child is
## replaced with this at _ready. Lets the same body run as Sophia, cop_riot,
## KayKit, etc. without any code changes — just drag a different scene in.
@export var skin_scene: PackedScene

@export_group("Brain")
## Optional brain scene override. If set, the default PlayerBrain child is
## removed and this scene is instantiated as the new brain. Lets the same body
## run under human input, AI, or networked replication by swapping a scene.
@export var brain_scene: PackedScene

## Group the body joins at _ready. Default "player" for human-controlled pawns;
## enemy/companion variants override to "enemies" / "allies" so targeting
## logic in brains can find the right pawns.
@export var pawn_group: String = "player"

# Class-level singleton: at most one PlayerBody runs with pawn_group ==
# "player" at a time. Enforced in _ready — the first claimer wins, and any
# subsequent player-tagged instance gets a push_error and is routed through
# the enemy branch (camera freed, no listener, no abilities). Catches
# accidental duplicate Player nodes baked into level scenes, save/load
# weirdness, or anything else that could silently produce two cameras /
# two listeners. The architecture remains "one PlayerBody class" per
# CLAUDE.md — this is just a runtime invariant on top.
static var _player_singleton: PlayerBody = null


## Typed, O(1) accessor for the active player pawn. Use this instead of
## `get_tree().get_first_node_in_group("player")` — same answer, no search,
## stale-instance safe.
static func get_player() -> PlayerBody:
	if _player_singleton != null and is_instance_valid(_player_singleton):
		return _player_singleton
	return null


## Flip a pawn's faction. Single public entry point — handles group
## membership (leave old, join new), attack target groups, brain target
## retarget (for EnemyAIBrain), skin tint, and emits Events.faction_changed.
## Idempotent: setting the current faction is safe (no-op).
## TEMP Intel-Mac instrumentation. Mirror with game.gd / kaykit_skin.gd.
const DEBUG_INTEL: bool = false

func set_faction(new_faction: StringName) -> void:
	if not _FACTION_GROUP.has(new_faction):
		push_warning("PlayerBody.set_faction: unknown faction '%s', ignoring" % new_faction)
		return
	var _t0_us: int = Time.get_ticks_usec() if DEBUG_INTEL else 0
	# Leave the old physics group if we were in one. We track via _FACTION_GROUP
	# so we don't have to remember what group we joined last time.
	var old_group: StringName = _FACTION_GROUP.get(faction, &"")
	if old_group != &"" and is_in_group(old_group):
		remove_from_group(old_group)
	# Join the new group.
	var new_group: StringName = _FACTION_GROUP[new_faction]
	if new_group != &"" and not is_in_group(new_group):
		add_to_group(new_group)
	# Update faction WITHOUT going through the setter (to avoid recursion).
	# The setter only matters for inspector-time changes; runtime callers
	# should hit set_faction directly.
	var prior_faction: StringName = faction
	faction = new_faction
	# Snap max_health to vanilla-green (1) when reverting to green. Without
	# this, a red splice converted via portal then reverted retains its
	# scene-baked max_health=4 from enemy_kaykit_splice.tscn — looks green
	# but takes 4 hits to kill. Narrow scope: green only. Other factions
	# keep whatever max_health their source scene authored.
	if new_faction == &"green":
		max_health = 1
		_health = mini(_health, max_health)
	# Gold conversion = fixed HP, full heal. Without snapping, a gold
	# converted from a basic green (max_health=1) would die in one hit from
	# any red. 8 HP × red's 2-damage swing = 4 hits before death — reads as
	# "ally can take a few licks." Full heal because conversion is the
	# moment of rebirth-as-ally; carrying over damaged HP feels punishing.
	if new_faction == &"gold":
		max_health = 8
		_health = max_health
	# Rewrite attack target groups from the table. The constants hold
	# untyped Arrays (Dictionary values can't carry the [StringName] type
	# annotation), so we use Array.assign() — copies element-by-element
	# with the destination's type coercion, satisfying the strict type check.
	attack_target_groups.assign(_FACTION_TARGETS[new_faction] as Array)
	# Retarget the brain if it's an EnemyAIBrain (PlayerBrain ignores groups).
	# Same Array.assign trick because brain.target_groups is also typed.
	if _brain != null and "target_groups" in _brain:
		var brain_targets: Array[StringName] = []
		brain_targets.assign(attack_target_groups)
		_brain.target_groups = brain_targets
	# Allies (gold) follow the player when no enemy is in detection range.
	# Other factions clear the follow subject so they don't accidentally
	# bias toward anything. Brain-side follow_subject_group is the only
	# faction-specific brain config beyond target_groups.
	if _brain != null and "follow_subject_group" in _brain:
		_brain.follow_subject_group = &"player" if new_faction == &"gold" else &""
	# Gold-specific behavior overlay: when the player is crouched, the gold's
	# brain idles in place and only engages enemies within ally_crouched_engage_radius.
	# Other factions clear it to 0 (no special crouch behavior). See enemy_ai_brain.gd.
	if _brain != null and "ally_crouched_engage_radius" in _brain:
		_brain.ally_crouched_engage_radius = 5.0 if new_faction == &"gold" else 0.0
	# Combat leash — golds drop their chase target if the player drifts
	# more than this many meters away, then catch up via active follow.
	# 0 on non-gold = leash disabled (legacy behavior preserved).
	if _brain != null and "combat_leash_distance" in _brain:
		_brain.combat_leash_distance = 50.0 if new_faction == &"gold" else 0.0
	# Gold-specific detection: bigger sphere than variant default (16m or 30m
	# for stealth) so allies pick up threats earlier. Hysteresis pair keeps the
	# usual +6m chase-hold band. Revert from gold restores the variant's
	# authored values via the cached defaults.
	if _brain != null and "detection_radius" in _brain:
		if _brain_default_detection_radius < 0.0:
			_brain_default_detection_radius = float(_brain.detection_radius)
		_brain.detection_radius = 40.0 if new_faction == &"gold" else _brain_default_detection_radius
	if _brain != null and "chase_exit_radius" in _brain:
		if _brain_default_chase_exit_radius < 0.0:
			_brain_default_chase_exit_radius = float(_brain.chase_exit_radius)
		_brain.chase_exit_radius = 46.0 if new_faction == &"gold" else _brain_default_chase_exit_radius
	# Skate profile flip is no longer auto on gold conversion — moved to the
	# explicit caller. ControlPortal converts walk; GodAbility converts ride.
	# Apply the aggressive package (99 damage, 0 wind-up, 0 cooldown) to red
	# AND gold so both faction always swing first. Stealth-splice toggles the
	# package independently via aggressive_while_chasing on its brain.
	set_aggressive_buffs(new_faction == &"red" or new_faction == &"gold")
	# Gold-specific damage tune. set_aggressive_buffs above just wrote
	# _faction_attack_damage = 2 (red's authored value); bump it to 3 so a
	# gold ally two-shots a red. Regular red (max_health=5) → ceil(5/3) = 2
	# hits. Stealth red (max_health=6) → 6/3 = 2 hits exactly. Reverts on
	# next set_aggressive_buffs(false) call when the body leaves gold.
	if new_faction == &"gold":
		_faction_attack_damage = 3
	# Gold's "always wins vs red" probability scales with coin completion.
	# Rolled once at conversion and sticky for the life of this pawn —
	# keeps the gold-vs-red outcome deterministic per encounter rather than
	# coin-flipping on every swing. lerp(0.30, 1.00, ratio): 0 coins → 30%,
	# full coins → 100%. Re-rolled if a body is converted again.
	if new_faction == &"gold":
		var dodge: float = lerp(0.30, 1.0, GameState.coin_completion_ratio())
		_gold_dodges_splice = randf() < dodge
		print("[gold-dodge] %s rolled %s (chance=%.2f, coin_ratio=%.2f)" % [
			get_path(), _gold_dodges_splice, dodge, GameState.coin_completion_ratio()])
	# Tint the skin (no-op on skins that haven't implemented set_faction_tint).
	if _skin != null and _skin.has_method(&"set_faction_tint"):
		var tint: Array = _FACTION_TINT[new_faction]
		_skin.set_faction_tint(tint[0] as Color, float(tint[1]))
	# Broadcast for listeners (HUD, mission triggers, etc.).
	Events.faction_changed.emit(self, new_faction)
	if prior_faction != new_faction:
		print("[faction] %s: %s → %s" % [get_path(), prior_faction, new_faction])
	if DEBUG_INTEL:
		# Per-conversion timing. f= frame index lets you verify whether the
		# stagger is actually spreading conversions across frames; t_us= total
		# wall time in set_faction (skin tint duplication is the costly part
		# on Intel Mac). High t_us with same f across multiple pawns = the
		# burst is still bunching up.
		print("[faction-perf] f=%d t_us=%d %s %s→%s" % [
			Engine.get_process_frames(),
			Time.get_ticks_usec() - _t0_us,
			get_path(),
			prior_faction,
			new_faction,
		])


## Apply / remove the red-faction aggressive package independent of faction
## membership. When active: 2.5× speed, 2× damage, invulnerable, zero attack
## cooldown + wind-up — same patches set_faction("red") applies. When
## inactive: restore the current faction's natural buffs from the table.
##
## Stealth-splice enemies call this from the brain to mimic red whenever the
## player is standing, then drop back to vulnerable cone-gated stealth-mode
## the moment the player crouches. The pawn's faction stays "splice_stealth"
## throughout — only the gameplay buffs flip.
##
## Guard: never deactivates on a red-faction pawn (set_faction is the source
## of truth for permanent red enemies; flipping them off here would un-buff
## a normal red kaykit).
func set_aggressive_buffs(active: bool) -> void:
	if not active and faction == &"red":
		return
	# Active uses red's buff entry; inactive restores the current faction's.
	var buffs_key: StringName = &"red" if active else faction
	var buffs: Array = _FACTION_BUFFS.get(buffs_key, [1.0, 1]) as Array
	# Per-pawn overrides: when active, individual splice_stealth (and any
	# future aggressive pawn) can opt out of red's defaults to keep authored
	# values for damage, speed mult, and brain timer zeroing. < 0 / true =
	# legacy behavior preserved.
	if active and aggressive_speed_mult_override >= 0.0:
		_faction_speed_mult = aggressive_speed_mult_override
	else:
		_faction_speed_mult = float(buffs[0])
	if active and aggressive_damage_override >= 0:
		_faction_attack_damage = aggressive_damage_override
	else:
		_faction_attack_damage = int(buffs[1])
	# Invulnerable while aggressive, OR if the underlying faction is red /
	# splice_stealth. Splice_stealth is always invulnerable to take_hit;
	# the only kill path is StealthKillTarget's backstab, which calls
	# stealth_kill() directly and bypasses take_hit (and therefore invuln).
	_faction_invulnerable = active or faction == &"red" or faction == &"splice_stealth"
	if _brain != null:
		if "attack_cooldown" in _brain:
			if _brain_default_attack_cooldown < 0.0:
				_brain_default_attack_cooldown = float(_brain.attack_cooldown)
			if active and aggressive_zeros_brain_timers:
				_brain.attack_cooldown = 0.0
			else:
				_brain.attack_cooldown = _brain_default_attack_cooldown
		if "wind_up_duration" in _brain:
			if _brain_default_wind_up < 0.0:
				_brain_default_wind_up = float(_brain.wind_up_duration)
			if active and aggressive_zeros_brain_timers:
				_brain.wind_up_duration = 0.0
			else:
				_brain.wind_up_duration = _brain_default_wind_up
	# Diagnostic — verify reverted-from-gold bodies actually reset to vanilla.
	# Compare to the [faction] log line at the bottom of set_faction: a body
	# that just reverted to green should print here with active=false,
	# faction=green, speed=1.0, damage=1, invuln=false. Anything else means
	# the revert didn't fully neutralize them.
	if DEBUG_INTEL: print("[buffs] %s active=%s faction=%s speed=%.2f damage=%d invuln=%s cooldown=%.2f windup=%.2f" % [
		get_path(), active, faction,
		_faction_speed_mult, _faction_attack_damage, _faction_invulnerable,
		float(_brain.attack_cooldown) if _brain != null and "attack_cooldown" in _brain else -1.0,
		float(_brain.wind_up_duration) if _brain != null and "wind_up_duration" in _brain else -1.0,
	])


## Map pawn_group → default faction for backwards compat. Used by _ready
## when `faction` was left empty in the inspector.
func _initial_faction_from_pawn_group() -> StringName:
	match pawn_group:
		"player":  return &"player"
		"enemies": return &"green"
		"allies":  return &"gold"
		_:         return &"green"  # safe fallback for any unknown pawn_group

## Faction. Drives runtime group membership + attack targeting + skin tint.
## Empty = derive from pawn_group at _ready (player→player, enemies→green).
## Set explicitly in scene files for splice-controlled spawns ("red"). Flip
## at runtime via `set_faction()` for portal/hack conversions. Per
## docs/conversion_and_portals.md §3.
##
## NOTE: this is a plain @export with no custom setter. `set_faction()`
## writes to it directly — a custom setter that called set_faction would
## stack-overflow because set_faction also writes faction. If you want
## scene-time inspector changes to take effect at runtime, edit `_ready`
## to re-apply (currently does, via the empty-string fallback).
@export var faction: StringName = &""

## Groups the attack sweep targets when this pawn lunges. Computed from
## faction by `set_faction()`; the inspector default is just a safe seed
## for old enemy variants that haven't had `faction` set. Per-faction
## targeting table:
##   player → [enemies, splice_enemies, allies] (player can punch friendlies)
##   green  → [player, allies]
##   red    → [player, allies]
##   gold   → [enemies, splice_enemies] (allies don't hit each other)
@export var attack_target_groups: Array[StringName] = [&"enemies"]

# Faction → physics group membership + attack targeting + tint.
const _FACTION_GROUP: Dictionary = {
	&"player":         &"player",
	&"green":          &"enemies",
	&"red":            &"splice_enemies",
	&"splice_stealth": &"splice_enemies",
	&"gold":           &"allies",
}
const _FACTION_TARGETS: Dictionary = {
	&"player":         [&"enemies", &"splice_enemies", &"bonkable"],
	&"green":          [&"player",  &"allies"],
	&"red":            [&"player",  &"allies"],
	&"splice_stealth": [&"player",  &"allies"],
	&"gold":           [&"enemies", &"splice_enemies"],
}
# Faction → [speed_multiplier, attack_damage]. Multiplied into the body's
# move_toward target each tick + passed to take_hit on every connecting
# swing. Red is the swarm variant: 1.5× speed + 2 damage (two-hit kill on
# player max_health=3 with regen breathing room) + invulnerable + 0.3s
# wind-up. Splice stealth is the patrol variant: normal speed + one-shot
# kill (preserved via aggressive_damage_override = 99 on its variant) but
# killable + cone-of-view AI (configured on the brain, not here).
const _FACTION_BUFFS: Dictionary = {
	&"player":         [1.0, 1],
	&"green":          [1.0, 1],
	&"red":            [1.5, 2],
	&"splice_stealth": [1.0, 99],
	&"gold":           [1.7, 99],
}
# Tint: [Color, amount]. amount=0 → skin restores its authored per-part
# albedo; amount>0 → skin overrides every body part to `color`. Pure RGB
# values for splice (red) and gold so they read at a glance. Player +
# green stay vanilla.
const _FACTION_TINT: Dictionary = {
	&"player":         [Color.WHITE, 0.0],
	&"green":          [Color.WHITE, 0.0],
	&"red":            [Color(1.0, 0.0, 0.0), 1.0],
	&"splice_stealth": [Color(0.55, 0.0, 0.45), 1.0],  # purple-red
	&"gold":           [Color(1.0, 0.78, 0.10), 1.0],
}

## If true, death is terminal — the body queue_free()s instead of respawning
## at the last checkpoint. Enemies set this true; players keep it false so
## they respawn on death.
@export var dies_permanently: bool = false

## Seconds of damage immunity after respawning at a checkpoint. Prevents
## "die, respawn near an enemy cluster, take a hit the same frame, die again"
## loops. Ignored for dies_permanently pawns (they don't respawn).
@export var respawn_invuln_duration: float = 2.0

@export_group("Movement")
@export var walk_profile: MovementProfile
@export var skate_profile: MovementProfile
## If true, the pawn starts in walk mode even if skate_profile is assigned.
## Lets an enemy (or the player) hold both profiles but default to walk, so
## a future skate pickup can toggle into skate mode without requiring the
## profile to be null at spawn.
@export var start_in_walk_mode: bool = false
# Note: lean_multiplier is now a per-skin property on CharacterSkin, not on
# the body — different rigs (Sophia's dramatic skater vs cop's stiff gait)
# need different feel at the same body.

@export_group("Dash")
## Peak velocity along dash direction (m/s).
@export var dash_speed: float = 18.0
## Multiplier applied to dash_speed when the dash fires while airborne.
## 1.5 = 50% farther in air than on ground over the same dash_duration.
@export_range(0.5, 3.0) var air_dash_speed_multiplier: float = 1.2
## Seconds the dash impulse stays active.
@export var dash_duration: float = 0.2
## How long the skin's Dash state holds before the per-frame idle/move/fall
## routing resumes. Decoupled from `dash_duration` so the visual roll plays
## through the apex even though the gameplay impulse + i-frames are short.
## Should match the (custom-timeline-shortened) Sprinting Forward Roll
## duration set on each skin — see *_skin.gd `_ready`.
@export var dash_visual_duration: float = 0.8
## Seconds after a dash before another can fire.
@export var dash_cooldown: float = 0.8
## Seconds of damage immunity when a dash starts. Reuses _invuln_until_time.
@export var dash_iframes_duration: float = 0.15
## If true, Y velocity (jump / fall) is preserved during dash; dash only
## overrides horizontal. If false, dash zeroes vertical too.
@export var dash_preserves_y: bool = true

@export_group("Enemy Contact")
## Horizontal m/s applied each tick the player is standing on top of an
## enemy CharacterBody3D. Pushes them off so an enemy head isn't a stable
## platform. 0 disables the slide-off entirely.
@export var enemy_head_slide_speed: float = 6.0

@export_group("Crouch")
## max_speed multiplier while crouch_held is true. Only applied in walk mode.
@export_range(0.0, 1.0) var crouch_speed_multiplier: float = 0.45

@export_group("Follow Camera")
enum FollowMode { PARENTED, DETACHED }
## PARENTED: pivot position snaps to player, only yaw lags. Responsive.
## DETACHED: pivot position also lags the player. Cinematic.
@export var follow_mode: FollowMode = FollowMode.DETACHED
## Local/world offset from player origin to pivot (roughly shoulder/head height).
@export var pivot_offset := Vector3(0.0, 1.0, 0.0)
## Lower = lazier yaw follow.
@export_range(0.0, 1.0) var angle_smoothing := 0.023
## Lower = lazier position follow (DETACHED only).
@export_range(0.0, 1.0) var position_smoothing := 0.122

@export_group("Mouse Look")
@export var mouse_x_sensitivity := 0.002
@export var mouse_y_sensitivity := 0.001
@export var invert_y := true
@export var pitch_min_deg := -75.0
@export var pitch_max_deg := 20.0
## Seconds of no mouse input before auto-follow re-engages.
@export var mouse_release_delay := 2.4
## Seconds to smoothly blend between manual and auto control.
@export var mouse_blend_time := 0.8
## Seconds of mouse idle before pitch begins returning to rest.
@export var pitch_return_delay := 0.3
## Exponential decay rate for pitch return. ~1.5 ≈ 95% back in 2 seconds.
@export var pitch_return_rate := 1.5

@export_group("Aggressive Override")
## Speed mult applied during aggressive (HOSTILE + aggressive_while_chasing)
## mode. < 0 = use red's FACTION_BUFFS row (default behavior). Set per-pawn
## to keep red's lethality but tune speed independently — e.g. splice_stealth
## inheriting red's invuln + sphere detection but at 1.5× rather than red's
## entry-table speed.
@export var aggressive_speed_mult_override: float = -1.0
## Attack damage applied during aggressive mode. < 0 = use red's FACTION_BUFFS
## row. Set per-pawn so a stealth that goes "red-mode" can deal a tunable
## (e.g. 2-hit-kill) blow instead of red's instant-kill 99.
@export var aggressive_damage_override: int = -1
## When false, aggressive mode preserves the brain's authored attack_cooldown
## + wind_up_duration instead of zeroing them. Default true keeps red's
## relentless tempo (zero cooldown, no telegraph). Set false on stealth-style
## variants that want a visible 0.3s wind-up + normal cooldown despite the
## otherwise-red behavior.
@export var aggressive_zeros_brain_timers: bool = true

@export_group("Health")
## Hits the player can take from enemies before dying. Falling off the world
## (kill_plane) still skips straight to the death sequence regardless.
@export var max_health := 3
## Upward velocity applied at the start of the death sequence — the player
## pops into a jump and arcs through gravity before bursting into confetti.
@export var death_rise_speed := 9.0
## Seconds between the death hit and the checkpoint respawn. Confetti fires
## at the start of this window, so the player rises through their own burst.
@export var death_duration := 0.55
## Knockback (m/s) applied along the impact direction at the start of a
## knockback-style death. Used by enemies with uses_knockback_death=true
## (KayKit). Tune up for a bigger fly-back, down for a quick collapse.
@export var death_knockback_horizontal := 9.0
## Vertical lift (m/s) added to the knockback so the body arcs through the air
## before hitting their back on the ground.
@export var death_knockback_vertical := 7.0
## Seconds to ramp the skin's tilt from upright to flat-on-back during the
## flight. Should be ≤ typical airtime so they're flat by landing.
@export var death_tilt_duration := 0.4
## Vertical lift (m) added to the skin once fully laid flat — pivots at the
## feet, so without lift the body's back clips into the floor. Ramps in with
## tilt_progress so it's only applied when the body has rotated.
@export var death_pose_lift := 0.6
## ── Stealth-kill fall (hack backstab) ── the stealth path has no knockback
## flight, so it plays its own timeline: eased tip-over, then two ballistic
## flop bounces. Combat knockback deaths are untouched.
## Seconds for the tip-over phase.
@export var stealth_fall_tip_duration := 0.65
## Ease-in exponent for the tip. 2 = constant angular acceleration (the
## rotational ½gt², reads as gravity); higher = longer teeter, harder slam.
@export var stealth_fall_tip_exponent := 2.0
## Peak height (m) of the first flop bounce after impact.
@export var stealth_fall_bounce_height := 0.05
## First bounce duration (s). The second bounce lasts this × restitution.
@export var stealth_fall_bounce_duration := 0.2
## Restitution between bounces: second bounce height = h × e², like a ball.
@export_range(0.0, 1.0) var stealth_fall_restitution := 0.6
## Seconds without being hit before HP fully refills. Set high to make damage
## sticky, low to make the player resilient. 0 disables regen.
@export var health_regen_delay := 4.0
@export var death_burst_scene: PackedScene = preload("res://enemy/confetti_burst.tscn")
## Peak alpha of the red flash applied on a damage hit. Fades linearly to 0
## over damage_tint_duration.
@export_range(0.0, 1.0) var damage_tint_max := 0.55
## Seconds over which the damage flash fades from damage_tint_max back to 0.
@export var damage_tint_duration := 1.0

@export_group("Attack")
## Max distance (meters) from player center to enemy center for a hit to
## land. AAA platformers (Astro Bot, Mario Galaxy spin) sit around 1.0–1.5;
## the auto-orient + lunge below compensate for the tight window.
@export var attack_range := 1.5
## Max vertical distance at which a sweep can land. Prevents ground pawns
## from hitting things far above/below them — so jumping dodges reliably.
@export var attack_vertical_range := 1.5
## Auto-orient: when attack starts, if an enemy is within this radius AND
## inside the cone below, snap player facing toward the nearest one before
## the lunge fires. Wider than attack_range so just-out-of-reach enemies
## still pull your aim — the lunge then closes the gap.
@export var attack_auto_orient_range: float = 4.0
## Full cone (degrees) measured from current facing. 0 = no auto-orient,
## 360 = always orient toward nearest target regardless of facing.
@export_range(0.0, 360.0) var attack_auto_orient_cone_deg: float = 280.0
## Seconds the swing stays "live" after pressing J. While active, any enemy
## that enters attack_range gets hit — so the forward lunge sweeps through
## enemies that were just out of reach at the press frame. Each enemy can
## only be hit once per swing.
@export var attack_active_duration := 0.22
## Visual hold for the attack animation, separate from the hit-detection
## window above. Without this the body re-travels the skin to Idle/Move at
## `attack_active_duration` and clips longer than that (e.g. Mma Kick at
## ~1s) get cut off before the strike lands. Mirrors `_dash_visual_timer`.
@export var attack_visual_duration := 0.8
## Seconds the player can't jump after attaching to a rail. Prevents the
## "rail grabs me, I had jump queued" bug where the rail snap fires AND the
## player launches off it on the same input. Player only — allies aren't
## affected.
@export var rail_jump_lockout_seconds: float = 1.5
## Max distance (m) from the rail curve at which the grab engages. The rail's
## Area3D box is only a broad-phase (its AABB bloats badly on curved/diagonal
## rails); this is the real, uniform grab tube around the curve.
@export var rail_grab_radius: float = 1.5
## Seconds after leaving a grind (jump or end-of-rail) before another grab
## can engage. Without this the per-tick distance check re-grabs instantly —
## you're still ~0m from the rail on the exit frame.
@export var rail_regrab_cooldown: float = 0.4
## Horizontal knockback speed (m/s) applied to hit enemies.
@export var attack_knockback := 14.0
## Horizontal speed added to the player on attack (the "jostle" forward).
## Normal movement friction decays it back to cruise speed. No animation
## state change — this is the entire attack "animation."
@export var attack_lunge_speed := 8.0
## Vertical pop added on attack so the jostle reads as a mini-lunge.
@export var attack_lunge_hop := 2.0
## Peak additive forward pitch (radians) on the skin during the jostle.
## Applied on top of the normal lean curve; peaks mid-jostle then decays.
@export var attack_lunge_pitch := 0.5

@export_group("Footsteps")
## Pool of footstep sounds played as the body walks. Phase counter advances
## by (h_speed / max_speed) × cadence each tick; on wrap, picks a random clip
## (no immediate repeat) and plays it. Walk profile only — skating disables.
@export var walk_footstep_pool: Array[AudioStream] = []
## If walk_footstep_pool is empty, auto-load all .wav/.ogg/.mp3 files from
## this directory at _ready. Lets you swap in a new sample bank by dropping
## files in instead of wiring 60 inspector slots.
@export_dir var walk_footstep_auto_load_dir: String = ""
## Footsteps per second when the body is moving at full max_speed in walk
## mode. At half speed, half the cadence. Tune to match the visual gait.
@export var walk_footstep_cadence_at_max: float = 7.0
## Below this horizontal speed (m/s), no footsteps fire — kills drifting
## clicks when the body is barely moving.
@export var walk_footstep_min_speed: float = 0.6
## dB offset applied to each click. 0 = sample's authored level.
@export_range(-30.0, 12.0) var walk_footstep_volume_db: float = 6.0
## Random pitch jitter (±this fraction) per click. 0 = identical pitch.
@export_range(0.0, 0.5) var walk_footstep_pitch_jitter: float = 0.06
## Master enable. Off = silent regardless of pool.
@export var walk_footsteps_enabled: bool = true
## Floor of the walk-anim time scale at zero input. Pure 0 freezes the
## animation mid-stride at very low gamepad input — clamping to ~0.35 keeps
## feet visibly moving while the body crawls.
@export_range(0.05, 1.0) var walk_anim_min_scale: float = 0.35

## When true, the walk anim playback rate scales with h_speed/max_speed
## (anchored at `walk_anim_min_scale`). Reads great on the player —
## strolling vs. striding looks different. Reads BADLY on AI allies/enemies
## that hover at wander_speed_fraction (≈0.33×), because that lands the
## anim at ~0.55× authored which looks laggy. Set false on AI pawn variants
## (enemy_kaykit_splice etc.) so their walk always plays at authored speed.
@export var walk_anim_speed_scaling: bool = true
## ── Walk↔run gait bands (walk mode, skins with a gait BlendSpace1D) ──
## Below cutover_start the Move state is pure Walking; between start and
## end it crossfades (phase-synced) to Running; above end it's pure Running.
@export_range(0.0, 1.0) var gait_cutover_start: float = 0.5
@export_range(0.0, 1.0) var gait_cutover_end: float = 0.7
## Tempo floor for each gait's band: the clip plays at this scale at the
## bottom of its band and ramps to 1.0 at the top (walk: 0→cutover_start,
## run: cutover_end→1). The cutover dips back to the floor so the incoming
## run cycle starts unhurried.
@export_range(0.1, 1.0) var gait_tempo_floor: float = 0.7

@export_group("Skate Strides")
## Pool of stride sounds played while skating. Cadence rides the sway
## stroke clock (one stride per sway extreme — see the profile's
## speedup_frequency); with two clips and the no-immediate-repeat picker
## this reads as strict L/R alternation.
@export var skate_stride_pool: Array[AudioStream] = []
@export_dir var skate_stride_auto_load_dir: String = ""
@export var skate_stride_min_speed: float = 1.5
@export_range(-30.0, 12.0) var skate_stride_volume_db: float = 9.0
@export_range(0.0, 0.5) var skate_stride_pitch_jitter: float = 0.04
@export var skate_strides_enabled: bool = true
## Layer the walk footstep pool on top of skate strides. Same pool, same
## cadence/min-speed plumbing as walk mode — so keyboard-clicks ride along
## while you roll. Each stride checks `walk_during_skate_dropout` and
## skips that fraction, giving the "occasional burst" feel.
@export var walk_during_skate_enabled: bool = true
## Fraction of walk-strides to drop while skating. 0.0 = play every stride,
## 1.0 = always silent. Default 0.3 = ~70% of strides play, which reads
## as light keyboard chatter under the skate roll.
@export_range(0.0, 1.0) var walk_during_skate_dropout: float = 0.3

@export_group("Skate Roll")
## Looping wheel-roll bed under skate movement. Volume/pitch track speed.
## OFF by default — the synth placeholder read as static; enable once a
## real wheel recording replaces skate_roll_stream.
@export var skate_roll_stream: AudioStream = preload("res://audio/sfx/skate_roll_loop.tres")
@export var skate_roll_enabled: bool = false
## Volume at full skate speed. Low speeds fade down from here (−18dB at
## walking pace) so the bed swells with momentum instead of switching on.
@export_range(-40.0, 6.0) var skate_roll_volume_db: float = -8.0
## Pitch spread across the speed range: crawl = 1−spread, max = 1+spread.
@export_range(0.0, 0.5) var skate_roll_pitch_spread: float = 0.12

@export_group("Attack SFX")
## Kick: plays at the start of an attack swing (before the active window
## opens). Empty = silent. Random clip per swing, no immediate repeat —
## same shuffle template as the other pawn audio pools.
@export var attack_kick_pool: Array[AudioStream] = []
@export_dir var attack_kick_auto_load_dir: String = ""
@export_range(-30.0, 12.0) var attack_kick_volume_db: float = 0.0
@export_range(0.0, 0.5) var attack_kick_pitch_jitter: float = 0.05
## Impact: plays once per swing if any target was struck (not per-hit, to
## avoid AudioStreamPlayer3D cutoff stutter on multi-target sweeps). Empty
## = silent.
@export var attack_impact_pool: Array[AudioStream] = []
@export_dir var attack_impact_auto_load_dir: String = ""
@export_range(-30.0, 12.0) var attack_impact_volume_db: float = 0.0
@export_range(0.0, 0.5) var attack_impact_pitch_jitter: float = 0.05

@export_group("Death SFX")
## Pool of one-shot sounds played when this pawn's death-confetti burst
## releases (the visible "glitch out"). Moved from _start_death so the
## sound lands with the burst instead of with the launch. Empty = silent
## (default for player). Random clip, no immediate repeat.
@export var death_sound_pool: Array[AudioStream] = []
@export_dir var death_sound_auto_load_dir: String = ""
@export_range(-30.0, 12.0) var death_sound_volume_db: float = -3.0
@export_range(0.0, 0.5) var death_sound_pitch_jitter: float = 0.05
## When true, _play_random_death_sfx pulls from the attack-impact hit
## pool instead of the authored death pool. Player pawn sets this true
## (the cartoon-horn fail sounds in player_deaths/ read as cheesy on a
## fall — the punchy hit thuds feel more weighted). Enemies leave it
## false to use their authored glitch death sounds in enemy_deaths/.
@export var death_sfx_uses_attack_impact_pool: bool = false

@export_group("Camera Occlusion")
## Yaw offset (degrees) applied to the camera_pivot at spawn, on top of
## the spawn marker's facing yaw. 0 = pivot rotation matches the marker
## yaw → SpringArm extends opposite the player's facing → camera lands
## directly behind. Verified empirically against the rotated PlayerSpawn
## markers (hub / level_1 / level_2 / level_4 / level_mockup) by reading
## actual world transforms from a [cam-spawn] log: dot of (camera→player)
## with player_facing == -0.93 → angle 158° → ~22° off from perfect, the
## remainder being the SpringArm's authored Y tilt (camera looks down a
## bit, intended).
##
## Level 5 has an identity-basis marker; same offset still lands behind.
@export var camera_spawn_yaw_offset_deg: float = 0.0
## Smooths SpringArm's instant-snap output into an eased response.
## Higher = snappier. ~8 ≈ 95% in 0.37s.
@export var spring_smooth_rate := 8.0
## Minimum allowed camera distance along the arm (prevents it from collapsing
## into the character when something is right up against them).
@export var min_camera_distance := 1.5
## SpringArm buffer from hits (how far to stay off walls/props).
@export var spring_margin := 1.5
## Sphere radius used for the spring arm cast. Larger = gives the camera "more
## body" so it rounds corners earlier instead of threading thin obstacles.
@export var spring_cast_radius := 0.4


## Each frame, we find the height of the ground below the player and store it here.
## The camera uses this to keep a fixed height while the player jumps, for example.
var ground_height := 0.0

var _gravity := -30.0
var _was_on_floor_last_frame := true
var _current_profile: MovementProfile
var _target_yaw := 0.0
var _manual_weight := 0.0
var _spring: SpringArm3D
var _base_pitch := 0.0
var _camera_original_z := 0.0
var _current_camera_z := 0.0
var _prev_skin_yaw := 0.0
var _prev_h_vel := Vector3.ZERO
var _current_lean_pitch := 0.0
var _current_lean_roll := 0.0
var _natural_lean_roll := 0.0


# ── Halfpipe stick (curved-surface skate adhesion) ──────────────────────
# Optional: when standing on a body in the `skate_curve_surface` group,
# the player (or gold ally) tilts to match the curve, gets pulled toward
# the trough, and accelerates along the curve. Jumping launches off the
# surface normal (so jumping the lip of a halfpipe sends you outward, not
# straight up). When disabled, ALL of this is skipped — body behaves
# identically to before.
@export_group("Halfpipe stick")
## Master kill-switch. When false, every pass is bypassed and the body
## behaves as if the system didn't exist. Eligibility for the system is
## "is this pawn currently on skates?" — see _update_halfpipe_stick's
## gate. Wheels-visible and halfpipe-stick share the same condition
## (_current_profile == skate_profile), so anyone with blades on (player,
## gold ally, hostile splice on skates) participates.
@export var halfpipe_stick_enabled: bool = true
## How far down the body probes for a curve-surface hit. Slightly longer
## than the capsule's foot-to-center to catch the surface even mid-arc.
@export var halfpipe_probe_distance: float = 1.5
## Metadata key a curved-surface body can carry to activate the system.
## Tag a surface in the scene with `metadata/skate_curve_surface = true`
## OR with a Node3D script that calls `set_meta(&"skate_curve_surface",
## true)` in _ready. Editor saves CAN strip the .tscn metadata line if
## the scene is re-saved without preserving it, so the name-fallback
## below is the more reliable mechanism for one-off surfaces.
@export var halfpipe_surface_meta: StringName = &"skate_curve_surface"
## Node-name fallback: if a collider OR any of its ancestors has a name
## in this list, treat it as a curve surface even without metadata. Quick
## and editor-resistant. Add new halfpipe-style surfaces by name.
@export var halfpipe_surface_names: PackedStringArray = ["HalfPipe"]
## Force pulling the body along the surface tangent toward the trough.
## Scales with curve angle. Kept LOW so it doesn't fight uphill momentum —
## gravity's natural slide is already pulling you down the curve. This is
## a small "extra magnetism" feel, not a real force. Tuned 2026-05-20.
@export var halfpipe_stick_strength: float = 20.0
## Extra downhill push when the player has NO movement input. With
## floor_max_angle held high, the body would otherwise stand glued to a
## steep wall — this is the "you let go of the stick, you slide" force.
## Only fires when intent.move_direction.length() < 0.1. Scales with
## curve_factor so flat trough = no idle slide, vertical wall = full pull.
## Tuned 2026-05-20 — playtest feedback says even ~10 still autoslides
## more than expected; the slider's lower range may need a finer step.
@export var halfpipe_idle_slide_strength: float = 10.0
## Speed-along-trough multiplier for downhill velocity. 1.0 = pure physics.
## >1.0 = arcade boost on the way down. Tuned 2026-05-20.
@export var halfpipe_speed_boost: float = 1.6
## Multiplier on the body's max horizontal speed while on a curve surface.
## 1.7 = +70% — drop-in builds momentum but still has a reasonable ceiling
## so the carve doesn't outrun the camera/controls. Multiplies into the
## existing target_vel calc. Tuned 2026-05-20.
@export var halfpipe_max_speed_multiplier: float = 1.7
## Walkable-floor angle override while on a curve surface. Default
## CharacterBody3D `floor_max_angle` is 45° — at that limit you can't walk
## past the gentle parts of the trough. Bumping to 80° lets you ride
## almost-vertical walls without slipping. Restored to floor_max_angle's
## prior value when you leave the surface.
@export var halfpipe_walk_max_angle_deg: float = 90.0
## Floor-snap distance override while engaged. Godot's default
## floor_snap_length (0.1m) is too short to keep the body kissed to a
## curving surface when moving fast tangentially: each tick the body
## advances linearly, the surface curves away from that tangent, the
## snap-cast misses, is_on_floor() drops to false, gravity yanks the
## body back into the surface, re-collides, snap re-engages. That's the
## "way-up-only" bounce — going DOWN the curve self-clings; going UP
## self-detaches. Bumping snap reach lets the cast find the surface
## again before the body goes airborne. Saved + restored on disengage,
## same lifecycle as floor_max_angle. Set to 0.0 to disable the override
## entirely and use whatever the body's default snap is.
@export var halfpipe_snap_length: float = 1.5
## Seconds after a curve-surface jump before stick re-engages — prevents
## "jumped off the wall, got snapped back to the wall on the way up."
@export var halfpipe_jump_cooldown_s: float = 0.3
## Jump direction blend: 0.0 = pure world-up, 1.0 = pure surface normal.
## 0.36 = ~65% vertical with a ~35% lateral push from the wall angle, so
## jumping the lip launches you clear of the wall instead of straight up.
## Tuned 2026-05-20.
@export_range(0.0, 1.0) var halfpipe_jump_blend: float = 0.36
## Pushes the SKIN away from the wall along the surface normal while
## engaged, scaled by curve_factor. Without this, the skin's "feet" (at
## skin-local -Y) rotate to face the wall when the body tilts up — and
## penetrate it by ~(skin_height/2 - capsule_radius). 0.5m is roughly
## that mismatch for a standard humanoid rig.
@export var halfpipe_skin_wall_lift: float = 0.5
## When true, AI brains can't fire jump on a skating non-player pawn.
## Brain-driven jumps zero the carve momentum through gravity arc, so
## allies + skating enemies lose their speed on the halfpipe every time
## they decide to hop a gap. Player is exempt regardless of this flag.
@export var disable_brain_jump_on_skates: bool = true
## Multiplier on horizontal friction while engaged on a curve surface.
## Friction is already skipped on the wall (curve_factor > 0.1) but the
## trough section still gets normal-ground friction, which kills the
## wall-to-wall coast. 1.0 = unchanged; 0.3 = ~3× longer coast; 0 = the
## body never slows in the trough until something else acts on it.
## Tuned 2026-05-20.
@export_range(0.0, 1.0) var halfpipe_trough_friction_scale: float = 0.42
## Walk/Move animation playback speed during halfpipe coast (engaged + no
## input + body still moving). Plays the Move clip slowed instead of the
## Idle pose so the character looks relaxed-rolling, not frozen. 0.5 =
## half-speed feet. Set to 1.0 to use authored Move speed; set to 0 to
## fall back to Idle (the previous behavior).
@export_range(0.0, 1.5) var halfpipe_coast_anim_scale: float = 0.5

# ── Pass selector + per-pass tuning ─────────────────────────────────────
# Pass dispatch is gated entirely inside _update_halfpipe_stick, which
# itself only runs while engaged on a curve surface. Switching the pass
# live forces a disengage so per-pass state can't leak across.
enum HalfpipePass { CURRENT, KINEMATIC, KINEMATIC_PUMP, CENTRIPETAL }
@export var halfpipe_pass: HalfpipePass = HalfpipePass.KINEMATIC

@export_subgroup("Kinematic pass")
## Strength of the per-tick velocity redirect onto the surface tangent.
## 1.0 = full kinematic constraint (velocity always lies along the surface).
## 0.0 = redirect disabled. Lower values let physics fight back, higher
## values feel "on rails." Tuned 2026-05-20.
@export_range(0.0, 1.0) var halfpipe_kin_redirect_strength: float = 0.12
## Multiplier on gravity-along-tangent during kinematic passes. 1.0 = real
## physics (sin-of-angle of gravity slides you toward the trough).
## Tuned 2026-05-20.
@export_range(0.0, 3.0) var halfpipe_kin_gravity_scale: float = 1.35
## Body-up alignment lerp rate (matches Godot recipe's documented sweet
## spot of ~12). Only used by kinematic passes — the existing skin tilt
## stays for the other passes.
@export_range(0.0, 30.0) var halfpipe_kin_align_rate: float = 12.0
## Maximum tilt amount toward the surface normal. 1.0 = body fully matches
## the wall (head pointing away from wall on a vertical section); 0.0 = no
## tilt (body always upright). Caps how dramatic the lean gets without
## changing how fast it happens (that's align_rate).
@export_range(0.0, 1.0) var halfpipe_kin_max_tilt: float = 0.4

@export_subgroup("Kinematic+Pump pass")
## One-shot multiplier on velocity-along-tangent the frame the player
## releases crouch while engaged. 1.10 ≈ Skate-style pump per cycle.
@export_range(1.0, 1.4) var halfpipe_pump_multiplier: float = 1.12
## Seconds after a pump before another pump fires. Stops mashing.
@export_range(0.1, 2.0) var halfpipe_pump_cooldown: float = 0.6
## Minimum curve_factor for a pump to fire. Pumping on flat trough does
## nothing in real life — same gate here.
@export_range(0.0, 1.0) var halfpipe_pump_min_curve: float = 0.15

@export_subgroup("Centripetal pass")
## Assumed halfpipe radius in meters. level_4's HalfPipe has inner radius
## 18m (CSG InnerCarve cylinder). Set per-level if other pipes differ.
@export_range(2.0, 30.0) var halfpipe_centripetal_radius: float = 18.0
## Scalar on the v²/r grip force pulling the body into the surface.
## 0 = off (centripetal pass behaves like current). >1 = sticker grip.
@export_range(0.0, 3.0) var halfpipe_centripetal_grip_scale: float = 1.0

@export_subgroup("Shared exit conditions")
## Auto-disengage when velocity along the surface normal exceeds this
## AND curve_factor is past halfpipe_exit_curve_min — the "flew off the
## lip naturally" case. Set high to require an explicit jump to exit.
@export_range(0.0, 20.0) var halfpipe_exit_normal_speed: float = 4.0
## Curve-factor floor for the auto-exit. 0.8 = only when you're up on
## the wall, not in the trough.
@export_range(0.0, 1.0) var halfpipe_exit_curve_min: float = 0.8
@export_group("")

var _on_halfpipe: bool = false
var _halfpipe_normal: Vector3 = Vector3.UP
var _halfpipe_curve_factor: float = 0.0  # 0 at trough, 1 at vertical wall
var _halfpipe_jump_timer: float = 0.0
## Cached floor_max_angle from before we entered a curve surface. Restored
## the moment we disengage so non-pipe movement uses the project default.
var _halfpipe_saved_floor_max_angle: float = -1.0
## Cached floor_snap_length from before engagement. Same lifecycle as
## _halfpipe_saved_floor_max_angle — saved on first engage, restored on
## disengage. -1.0 sentinel means "nothing saved yet."
var _halfpipe_saved_floor_snap_length: float = -1.0
## Cached up_direction from before engagement. Sentinel Vector3.ZERO
## means "nothing saved yet."
var _halfpipe_saved_up_direction: Vector3 = Vector3.ZERO
# Debug-dedupe: print on transitions only. Filter logs with [halfpipe].
# Single state line per engage/disengage; no per-tick spam.
var _hp_last_engaged: bool = false
# Penetration-debug dedupe: store last logged signed depth (rounded to 0.1)
# so the per-tick log only fires when the depth actually moves a notch.
var _hp_last_pen_bucket: float = 999.0
# Pass-switch + pump state. Kinematic redirect/align flags are set ONLY by
# pass dispatch each tick (and cleared on disengage) so the post-pipeline
# hook below knows whether to fire.
var _hp_last_pass: int = -1
var _hp_pump_cooldown_timer: float = 0.0
var _hp_was_crouched_last_tick: bool = false
var _hp_kinematic_active_this_tick: bool = false
var _hp_align_active_this_tick: bool = false
# Set true the moment a kinematic align actually rotates the body, cleared
# when the basis has lerped back to upright after disengage. Without this,
# leaving a Kinematic-pass engagement leaves the body tilted forever — the
# only path that touches global_transform.basis on the halfpipe is gated
# on _on_halfpipe and stops firing the instant you leave.
var _hp_needs_reupright: bool = false
var _speedup_timer := 999.0
# Accumulated sway oscillation phase (radians). Advanced at speedup_frequency
# scaled by speed/max_speed so the rock slows with the body; reset on the
# start-moving edge alongside _speedup_timer.
var _sway_phase := 0.0
var _was_moving := false
var _brake_impulse := 0.0
var _was_pressing_forward := false
var _wall_ride_active := false
var _wall_ride_timer := 0.0
var _wall_normal := Vector3.ZERO
var _grinding := false
var _grind_rail: Path3D = null
# Rails whose broad-phase box we're currently inside (entered - exited).
# _try_grab_candidate_rails runs the precise distance check against these.
var _candidate_rails: Array[Path3D] = []
# Absolute time (s) before which no rail grab may engage — armed on every
# grind exit so the continuous check can't instantly re-grab.
var _rail_regrab_block_until := 0.0
var _grind_progress := 0.0
var _grind_direction := 1.0
var _grind_snap_t := 1.0
var _grind_start_pos := Vector3.ZERO
var _air_jump_available := false
# Timestamp (Time.get_ticks_msec()/1000.0) until which jump input is ignored
# by the body. Set externally (e.g. BouncyPlatform during squash) so only the
# platform's timed-boost system can act on jump presses during a bounce.
var _jump_suppressed_until: float = 0.0
# Coyote-time countdown — set to profile.coyote_time on every grounded
# tick, ticks down each airborne tick. While > 0, a jump press is treated
# as a ground jump (does NOT consume the air jump).
var _coyote_timer: float = 0.0
var _flip_timer := 0.0
var _flip_duration := 0.55
var _flip_axis := Vector3.RIGHT
var _yaw_state := 0.0
var _attack_timer := 0.0
var _attack_duration := 0.3
var _attack_active_timer := 0.0
# Visual hold timer — runs longer than _attack_active_timer so the skin
# can play out the full attack clip (Mma Kick, etc.) before the body
# resumes its per-tick travel calls. Hit detection still uses the active
# timer above.
var _attack_visual_timer := 0.0
var _attack_forward := Vector3.ZERO
var _attack_hit_enemies: Array[Node] = []
var _health := 3
var _dying := false
var _dying_timer := 0.0
# Saved at _start_death, restored at _finish_death so respawning pawns
# (player) re-enter the collision layer they came from.
var _pre_death_collision_layer: int = 0
# Footstep / death audio runtime state. Pools are resolved at _ready (either
# from the explicit @export array or the auto-load dir fallback).
var _walk_footstep_pool_resolved: Array[AudioStream] = []
var _skate_stride_pool_resolved: Array[AudioStream] = []
var _death_sound_pool_resolved: Array[AudioStream] = []
var _attack_kick_pool_resolved: Array[AudioStream] = []
var _attack_impact_pool_resolved: Array[AudioStream] = []
var _footstep_phase: float = 0.0
# Sway half-cycle index of the last stride SFX. Strides fire when this
# changes (one per sway extreme); sentinel = stride audio inactive.
const _STROKE_IDX_INACTIVE: int = -0x7FFFFFFF
var _stride_stroke_idx: int = _STROKE_IDX_INACTIVE
# Phase counter for the walk-bursts-during-skate layer. Independent of
# `_footstep_phase` (which is for walk-mode strides) so the two never
# step on each other — you can be in skate mode with this ticking and walk
# mode with the other ticking, no carry-over.
var _skate_walk_phase: float = 0.0
var _last_footstep_idx: int = -1
var _last_skate_stride_idx: int = -1
var _last_death_sfx_idx: int = -1
var _last_attack_kick_idx: int = -1
var _last_attack_impact_idx: int = -1
# Reset to false at each swing start; flipped true the first time impact
# plays. Keeps the impact sfx to one play per swing even though
# _sweep_attack runs every tick of the active window.
var _attack_impact_played: bool = false
# Faction-driven runtime tuning. Rewritten by set_faction() from the
# _FACTION_BUFFS table. Speed mult is multiplied into the move_toward
# target each tick; attack damage is passed to take_hit on every swing.
var _faction_speed_mult: float = 1.0
var _faction_attack_damage: int = 1
# Splice (red) is unkillable. take_hit early-returns when this is set.
var _faction_invulnerable: bool = false
# Set at conversion-to-gold time. When true, this gold pawn dodges all
# damage from splice_enemies (red + stealth) attackers. Determined by a
# coin-completion-ratio lerp 30%..100% — see set_faction(&"gold").
var _gold_dodges_splice: bool = false
# Cached brain defaults — set on first set_faction call that flips them
# (so red→green restores the brain's authored cooldown/wind-up). -1.0
# sentinel = "not captured yet". Applied via the brain's runtime fields.
var _brain_default_attack_cooldown: float = -1.0
var _brain_default_wind_up: float = -1.0
# Cached on first gold override so revert restores variant-authored value.
# -1.0 sentinel = "not captured yet".
var _brain_default_detection_radius: float = -1.0
var _brain_default_chase_exit_radius: float = -1.0
var _footstep_player_a: AudioStreamPlayer3D
# Looping wheel-roll bed (skate mode). Created in _ready when enabled;
# volume/pitch chase speed each audio tick, stops once faded out.
var _roll_player: AudioStreamPlayer3D = null
var _footstep_player_b: AudioStreamPlayer3D
var _footstep_player_toggle: bool = false
var _death_sfx_player: AudioStreamPlayer3D
# Kick + impact are 3D so attacks from offscreen sources (enemies hitting
# the player from behind) read directionally. The AudioListener3D the
# player creates in _ready is what makes 3D audio reliable now —
# previously the listener was the SpringArm-parked camera 9m back,
# which silenced close sounds via attenuation.
var _kick_sfx_player: AudioStreamPlayer3D
var _impact_sfx_player: AudioStreamPlayer3D
# Knockback death (uses_knockback_death skins): launch impulse along the
# impact direction, ramp the skin's tilt 0→PI/2 over death_tilt_duration so
# they're flat by landing, freeze the AnimationTree on touchdown, hold pose
# for _DEATH_POSE_HOLD, then spawn the burst + ramp glitch overlay over
# _DEATH_GLITCH_RAMP, hold the flicker for _DEATH_FLICKER_DURATION, queue_free.
const _DEATH_POSE_HOLD := 1.0
const _DEATH_FLICKER_DURATION := 0.6
const _DEATH_GLITCH_RAMP := 0.15
const _DEATH_SAFETY_TIMEOUT := 6.0
## Below this horizontal speed (m/s), the skin holds Idle instead of Move.
## Stops physics-jitter velocity (collisions, slope friction, mid-zone follow
## hysteresis) from flipping Move↔Idle every frame on AI bodies. Tuned well
## above the noise floor (~0.001–0.05 m/s) and well below any real movement.
const _MOVE_IDLE_DEADZONE := 0.15
## Seconds from the player's death to respawn — fires _finish_death mid-overlay
## so "CONNECTION TERMINATED" continues animating while the world reloads
## behind it. Enemies still use _DEATH_SAFETY_TIMEOUT (longer fallback for
## off-cliff cases where their burst+flicker never completes).
const _PLAYER_DEATH_DURATION := 2.0
var _death_burst_done := false
var _death_glitch_value := 0.0
var _death_landed := false
var _death_pose_timer := 0.0
var _death_flight_time := 0.0
var _death_impact_dir := Vector3.BACK
var _death_skin_basis_start := Basis.IDENTITY
# Stealth-fall timeline clock. -1 = inactive; stealth_kill() starts it at 0
# and _tick_stealth_fall() flips it back to -1 once the body settles.
var _stealth_fall_time := -1.0
var _regen_timer := 0.0
var _tint_timer := 0.0
## Absolute time (seconds) until which take_hit no-ops. -INF = never invuln.
## Set on respawn to give the player a grace window against enemies near the
## checkpoint.
var _invuln_until_time: float = -INF
## Absolute time (seconds) until which kill_plane_touched no-ops. Separate
## from `_invuln_until_time` so dash i-frames don't save you from falling
## off the world — only an explicit respawn grants kill-plane immunity, and
## only briefly (1s, vs the 2s damage-invuln window).
var _kill_plane_invuln_until_time: float = -INF

# Dash state
var _dash_timer: float = 0.0
## Decoupled visual hold — mirrors `dash_visual_duration` and gates the
## per-frame skin animation routing so the Sprinting Forward Roll plays
## through its apex even after the gameplay dash impulse has ended. See
## `dash_visual_duration` export note.
var _dash_visual_timer: float = 0.0
var _dash_cooldown_timer: float = 0.0
var _dash_direction: Vector3 = Vector3.ZERO
# Crouch state — tracked for edge detection so skin.crouch(active) only fires
# on press/release, not every tick.
var _was_crouched: bool = false

@onready var _last_input_direction := global_basis.z
@onready var _start_position := global_position

# Ordered list of RespawnMessageZone texts the player has crossed since the
# last respawn. Drained on the next respawn — overlay chains them with warp
# transitions. Adjacent duplicates are deduped so re-entering the same zone
# doesn't queue the same hint twice.
var _pending_respawn_messages: Array[String] = []

# Betrayal-walk lockout — non-zero direction = active. While active, the
# body discards the brain's Intent and substitutes a slow forward walk
# with no jump / dash / attack. Used by the betray ending scene.
var _betrayal_walk_dir: Vector3 = Vector3.ZERO
var _betrayal_walk_speed: float = 1.5

# Voiced sibling of _pending_respawn_messages. Each entry: {character, line}.
# Drained on respawn after a settle window (matches the label's show_delay)
# so Glitch doesn't start talking before the player has landed and oriented.
var _pending_voice_lines: Array[Dictionary] = []
const _VOICE_RESPAWN_DELAY: float = 2.0

@onready var _camera_pivot: Node3D = %CameraPivot
@onready var _camera: Camera3D = %Camera3D
@onready var _skin: CharacterSkin = %SophiaSkin
@onready var _landing_sound: AudioStreamPlayer3D = %LandingSound
@onready var _jump_sound: AudioStreamPlayer3D = %JumpSound

# Round-robin'd landing impacts. Cycled sequentially each touchdown so the
# same clip never plays twice in a row. Lives on Audio's recursive sfx
# preload (audio/sfx/lands/) so first-play decode hitches don't surface.
const _LAND_SOUNDS: Array[AudioStream] = [
	preload("res://audio/sfx/lands/land1.mp3"),
	preload("res://audio/sfx/lands/land2.mp3"),
	preload("res://audio/sfx/lands/land3.mp3"),
	preload("res://audio/sfx/lands/land4.mp3"),
	preload("res://audio/sfx/lands/land5.mp3"),
	preload("res://audio/sfx/lands/land6.mp3"),
]
var _land_idx: int = 0
@onready var _grind_sparks: GPUParticles3D = %GrindSparks
@onready var _grind_sound: AudioStreamPlayer3D = %GrindSound
@onready var _grind_sound_b: AudioStreamPlayer3D = %GrindSoundB
# Crossfade-loop state. Two parallel players ping-pong the same clip with
# `_GRIND_OVERLAP_S` of overlap so long grinds don't expose the loop seam.
# `_grind_sound_active` is whichever player started most recently — the one
# we poll for the next swap. The other one drains its tail and stops on its
# own. Both are killed in lockstep on grind exit.
const _GRIND_OVERLAP_S: float = 0.5
var _grind_sound_active: AudioStreamPlayer3D = null
var _grind_sound_length: float = 0.0
## Brain found by type, not by name — lets AI pawns drop in EnemyAIBrain,
## NetworkBrain, etc., without the body caring which one.
@onready var _brain: Brain = _find_first_brain()


func _find_first_brain() -> Brain:
	for c: Node in get_children():
		if c is Brain:
			return c
	push_error("PlayerBody has no Brain child")
	return null


func _exit_tree() -> void:
	# Release the singleton slot so a future PlayerBody can claim it. This
	# is rare in practice (Player persists across scenes via game.tscn) but
	# matters for tests, scene unloads, and explicit player teardown.
	if _player_singleton == self:
		_player_singleton = null


func _ready() -> void:
	# Note: set_faction() below joins the proper physics group; pawn_group is
	# kept around as the singleton-check / "is this the player" tag, NOT for
	# runtime group membership.
	_swap_skin_if_overridden()
	_swap_brain_if_overridden()
	# Resolve initial faction. Empty @export = derive from pawn_group;
	# otherwise the inspector value wins (e.g. splice-controlled enemies
	# explicitly set "red").
	var initial: StringName = faction if faction != &"" else _initial_faction_from_pawn_group()
	set_faction(initial)
	# Singleton check: only the first PlayerBody with pawn_group == "player"
	# wins the camera + listener + abilities. Any duplicate is routed through
	# the enemy branch below (camera freed, no listener, no abilities) so
	# we can't end up with two of anything player-only at runtime.
	var is_active_player: bool = pawn_group == "player"
	if is_active_player:
		if _player_singleton != null and _player_singleton != self and is_instance_valid(_player_singleton):
			push_error(
				"PlayerBody: duplicate active player detected. Existing=%s new=%s. " %
				[_player_singleton.get_path(), get_path()] +
				"Routing this instance through the enemy path (no camera/listener/abilities)."
			)
			is_active_player = false
		else:
			_player_singleton = self
	# Abilities are player-only. If we're running as an enemy / companion,
	# strip the Abilities node so their _unhandled_input handlers don't
	# hijack the player's inputs (e.g. enemies firing flares when the
	# player presses Y).
	if not is_active_player:
		var abilities_node := get_node_or_null(^"Abilities")
		if abilities_node != null:
			abilities_node.queue_free()
		# Non-player pawns get NO camera at all. The Camera3D node is freed
		# entirely so it can't appear in the viewport's camera registry —
		# regardless of `current` flag, scene-load timing, inspector overrides,
		# or anything else. _camera is nulled so downstream null-checks work.
		# Per user invariant: only the player's body owns a camera, period.
		var enemy_cam := get_node_or_null(^"%Camera3D") as Camera3D
		if enemy_cam != null:
			print("[cam-dbg] free enemy/companion cam %s on %s" % [
				enemy_cam.get_path(), get_path()])
			enemy_cam.queue_free()
			_camera = null
	else:
		# Player owns the active camera slot — claim it explicitly. This is
		# the ONLY place make_current() is called on a non-cinematic camera.
		var player_cam := get_node_or_null(^"%Camera3D") as Camera3D
		if player_cam != null:
			player_cam.make_current()
			print("[cam-dbg] player claim: %s" % player_cam.get_path())
		# AudioListener3D wins over the Camera3D as the listener for 3D
		# audio. Putting it on the player body (not the camera) means
		# distance attenuation measures from the player, not from where the
		# SpringArm parks the camera ~9m back. Player-only — enemies
		# attached to player_body don't get listeners (only the player has
		# "ears" in this game).
		var listener := AudioListener3D.new()
		listener.name = "AudioListener3D"
		add_child(listener)
		listener.make_current()
		print("[cam-dbg] player audio listener attached: %s" % listener.get_path())
	# Pick the initial profile. start_in_walk_mode wins over skate_profile
	# existence so enemies / NPCs can hold both profiles (for a future
	# power-up toggle) but spawn in walk mode.
	# Player pawn: also gated by powerup_love — spawn in walk until the
	# L1 pickup is collected. Enemies/NPCs bypass the flag.
	var player_has_skate: bool = bool(GameState.get_flag(&"powerup_love", false))
	var force_walk: bool = pawn_group == "player" and not player_has_skate
	if (start_in_walk_mode or force_walk) and walk_profile != null:
		_current_profile = walk_profile
	else:
		_current_profile = skate_profile if skate_profile != null else walk_profile
	# Seed the skin's skate-mode visual state so wheels / root offset match
	# the initial profile before the player presses any toggle.
	if _skin != null:
		_skin.set_skate_mode(_current_profile == skate_profile)
	# Camera rig setup is player-only — enemies / companions / duplicate
	# players had their Camera3D freed above, so deref'ing _camera here
	# would crash. Gate on is_active_player so duplicates (singleton check
	# above) also skip this.
	if is_active_player:
		_apply_follow_mode()
		_target_yaw = _camera_pivot.global_rotation.y
		_spring = _camera_pivot.get_node("SpringArm3D")
		_base_pitch = _spring.rotation.x
		_camera_original_z = _camera.position.z
		_current_camera_z = _camera_original_z
		# Replace the SeparationRayShape3D (meant for character floor separation)
		# with a sphere so margin acts as a real physical buffer around obstacles.
		var sphere := SphereShape3D.new()
		sphere.radius = spring_cast_radius
		_spring.shape = sphere
		_spring.margin = spring_margin
		_spring.add_excluded_object(self.get_rid())
		# Exclude every other pawn currently in the scene so the camera
		# doesn't push in when an enemy or ally body crosses the spring
		# arm's shape-cast path. Same mechanism we use for the player
		# itself; just applied to every pawn. Pawns spawned later
		# self-register via `add_camera_exclusion` below.
		_exclude_existing_pawns_from_camera()
	# Late-spawning AI pawns (enemies, allies via portal, etc.) find the
	# active player and add themselves to its camera exclusion list. Deferred
	# so the active player has its _spring ready before we try to register.
	if not is_active_player and pawn_group != "player":
		call_deferred(&"_register_with_player_camera")
	_setup_pawn_audio()
	if is_active_player:
		_register_debug_panel()
	Events.rail_touched.connect(_on_rail_touched)
	Events.rail_left.connect(_on_rail_left)
	Events.checkpoint_reached.connect(_on_checkpoint_reached)
	# Player-only: hold the most recent RespawnMessageZone text. Enemies don't
	# subscribe (they don't respawn into hint UI). Duplicates skip too — only
	# the active player gets respawn-message hooks.
	if is_active_player:
		Events.respawn_message_armed.connect(_on_respawn_message_armed)
		Events.respawn_voice_armed.connect(_on_respawn_voice_armed)
	_health = max_health
	Events.kill_plane_touched.connect(func on_kill_plane_touched(body: PhysicsBody3D) -> void:
		# Global signal — filter to self so one pawn falling off doesn't kill
		# every other PlayerBody listening.
		if body != self:
			return
		# Falling off the world skips the HP system — it's always terminal.
		# Two guards: _dying prevents re-entering an in-progress death
		# sequence, and _kill_plane_invuln_until_time gives a 1s grace
		# window after respawn so a stale fall signal queued during the
		# respawn teleport can't insta-re-kill at the checkpoint. Damage
		# i-frames (_invuln_until_time) are deliberately NOT honored here —
		# dashing off a cliff still kills.
		if _dying:
			return
		if Time.get_ticks_msec() / 1000.0 < _kill_plane_invuln_until_time:
			return
		_start_death(Vector3.DOWN)
	)
	# enemy_hit_player and flag_reached are game-world events meant for the
	# human-controlled pawn only — gate on is_active_player so duplicates
	# (and enemy-PlayerBodies on the same autoload) don't all react.
	if is_active_player:
		Events.enemy_hit_player.connect(_on_enemy_hit_player)
		Events.flag_reached.connect(func on_flag_reached() -> void:
			set_physics_process(false)
			_skin.idle()
			_skin.set_dust_emitting(false)
		)


## If brain_scene is set, remove any default Brain child and instantiate the
## override. The default PlayerBrain stays wired in the base tscn so a plain
## instance is playable out of the box; variants (enemies, companions) set
## brain_scene to drop in AI or networked drivers.
func _swap_brain_if_overridden() -> void:
	if brain_scene == null:
		return
	var new_brain := brain_scene.instantiate()
	if not (new_brain is Brain):
		push_error("brain_scene root must extend Brain, got %s" % new_brain.get_class())
		new_brain.queue_free()
		return
	# Remove any existing Brain child (the default PlayerBrain from the tscn).
	for c: Node in get_children():
		if c is Brain:
			c.queue_free()
	add_child(new_brain)
	_brain = new_brain


## Permanently replace the brain at runtime and re-apply the current
## faction's brain config to the fresh instance. Used by the GOD blast on
## stealth pawns: the entire stealth kit — vision cone, patrol scan,
## alert/chase state, current target — dies with the old brain node.
## Total conversion, no residue, never comes back.
func replace_brain(scene: PackedScene) -> void:
	if scene == null:
		return
	var new_brain := scene.instantiate()
	if not (new_brain is Brain):
		push_error("replace_brain: scene root must extend Brain, got %s" % new_brain.get_class())
		new_brain.queue_free()
		return
	for c: Node in get_children():
		if c is Brain:
			c.queue_free()
	add_child(new_brain)
	_brain = new_brain
	# The per-variant default caches were read off the OLD brain — reset so
	# set_faction re-caches from the replacement's authored exports.
	_brain_default_detection_radius = -1.0
	_brain_default_chase_exit_radius = -1.0
	_brain_default_attack_cooldown = -1.0
	_brain_default_wind_up = -1.0
	print("[faction] %s brain replaced -> %s" % [name, scene.resource_path])
	set_faction(faction)


## If skin_scene is set, replace the default skin child with a fresh instance
## and rebind _skin. The default skin stays wired up in the tscn so running
## without an override still works out of the box.
func _swap_skin_if_overridden() -> void:
	if skin_scene == null:
		return
	var new_skin := skin_scene.instantiate()
	if not (new_skin is CharacterSkin):
		push_error("skin_scene root must extend CharacterSkin, got %s" % new_skin.get_class())
		new_skin.queue_free()
		return
	var anchor_xform := _skin.transform
	var parent := _skin.get_parent()
	_skin.queue_free()
	parent.add_child(new_skin)
	new_skin.transform = anchor_xform
	_skin = new_skin


## Idempotent: force skate profile on. Called by SkateAbility the moment the
## powerup_love flag flips true so the player starts rolling without needing
## to manually press R.
func set_profile_skate() -> void:
	if pawn_group == "player" and not GameState.get_flag(&"powerup_love", false):
		return
	if skate_profile == null or _current_profile == skate_profile:
		return
	_current_profile = skate_profile
	if _skin != null:
		_skin.set_skate_mode(true)


## Force-switch to the walking profile and hide the skin's skate gear.
## Bypasses the skate_locked / powerup_love gates that toggle_profile
## respects — used by scripted scenes (level_5 betrayal walk) that need to
## strip skating regardless of the player's normal progression state.
func set_profile_walk() -> void:
	if walk_profile == null:
		return
	_current_profile = walk_profile
	# Always force skate visuals OFF — even if the profile already matched.
	# Skin state can desync (e.g. wheels visible from a prior session) and
	# we want this hook to be idempotent for scripted scenes.
	if _skin != null and _skin.has_method(&"set_skate_mode"):
		_skin.set_skate_mode(false)
	print("[player_body] set_profile_walk → walk_profile, skin=%s" % _skin)


## When true, `toggle_profile` refuses to switch skate→walk. Set per-level
## by tutorial scripts (level_1) that mandate skates-stay-on once enabled.
## Cleared when the level is exited so the hub / later levels keep their
## free-toggle behavior. Walk→skate transitions are unaffected.
var skate_locked: bool = false


## Public hook called by PlayerBrain when the skate/walk toggle is pressed.
## Notifies the active skin so it can switch gear visuals (Sophia's wheels).
## Gated by powerup_love — no-op until the L1 pickup is collected.
func toggle_profile() -> void:
	if pawn_group == "player" and not GameState.get_flag(&"powerup_love", false):
		return
	# Tutorial gate — level 1 sets skate_locked so the player can't toggle
	# back to walk once they've enabled skates.
	if skate_locked and _current_profile == skate_profile:
		return
	if _current_profile == skate_profile and walk_profile != null:
		_current_profile = walk_profile
	elif skate_profile != null:
		_current_profile = skate_profile
	if _skin != null:
		_skin.set_skate_mode(_current_profile == skate_profile)


## Called by child Ability nodes when their owned-flag flips true. Re-emits
## on the body so the HUD powerup_row can add a slot.
func notify_ability_granted(id: StringName) -> void:
	print("[pw] PlayerBody.ability_granted.emit(%s)" % id)
	ability_granted.emit(id)


## Called by child Ability nodes when their enabled state flips (e.g. hack
## mode toggled on/off). HUD powerup_row tints accordingly.
func notify_ability_enabled_changed(id: StringName, enabled: bool) -> void:
	ability_enabled_changed.emit(id, enabled)


## Public hook called by PlayerBrain when follow-mode toggle is pressed.
func toggle_follow_mode() -> void:
	follow_mode = FollowMode.DETACHED if follow_mode == FollowMode.PARENTED else FollowMode.PARENTED
	_apply_follow_mode()


## True during the active-swing window after _start_attack_jostle. Read by
## InteractionSensor to suppress door activations mid-attack.
func is_attacking() -> bool:
	return _attack_active_timer > 0.0


## HUD + external-consumer getters for pawn state. Keep these one-line so
## they stay free to inline; the privates stay private for body's own use.
func get_health() -> int: return _health
func get_max_health() -> int: return max_health
func is_dying() -> bool: return _dying


## Suppress all jump input (ground, air, coyote) for `duration` seconds.
## Used by BouncyPlatform so only its timed-boost pickup can act on a jump
## press during a bounce — accidental air-jumps don't add bonus height.
## Latest-wins via maxf so two overlapping calls extend the window correctly.
func suppress_jump_for(duration: float) -> void:
	if duration <= 0.0:
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	_jump_suppressed_until = maxf(_jump_suppressed_until, now + duration)


func _start_attack_jostle() -> void:
	if _attack_timer > 0.0:
		return
	_attack_timer = _attack_duration
	# Kick — fires at swing start, regardless of whether anything's hit.
	_play_random_attack_kick_sfx()
	_attack_impact_played = false
	# Forward = flattened camera direction (player); enemies have no camera
	# (it's freed in _ready), so they fall back to character facing.
	var forward: Vector3
	if _camera != null:
		forward = -_camera.global_basis.z
		forward.y = 0.0
		if forward.length_squared() <= 0.0001:
			forward = -global_basis.z
	else:
		forward = -global_basis.z
	if forward.length_squared() > 0.0001:
		forward = forward.normalized()
	# Auto-orient: if a target sits inside the cone, snap aim toward it before
	# the lunge fires. This is the AAA "tight hitbox + soft assist" pattern —
	# the hitbox stays small (1.5m) but the player rarely misses because the
	# attack aims at whoever they're roughly looking at. Snaps both the lunge
	# direction AND the visual yaw so the swing reads as deliberate.
	var target: Node3D = _find_auto_orient_target(forward)
	if target != null:
		var to_target: Vector3 = target.global_position - global_position
		to_target.y = 0.0
		if to_target.length_squared() > 0.0001:
			forward = to_target.normalized()
			_target_yaw = atan2(forward.x, forward.z)
			_yaw_state = _target_yaw
		# Lunge fires only when locked on. Without a target the swing still
		# happens (sweep + visual), but no forward burst — keeps stationary
		# attacks from sliding the player off ledges or into walls.
		velocity.x += forward.x * attack_lunge_speed
		velocity.z += forward.z * attack_lunge_speed
		velocity.y = maxf(velocity.y, attack_lunge_hop)
	# Open the active swing window. The sweep runs each frame in physics.
	_attack_active_timer = attack_active_duration
	_attack_visual_timer = maxf(attack_active_duration, attack_visual_duration)
	_attack_forward = forward
	_attack_hit_enemies.clear()
	# Tell the skin to play its attack animation. Skins with a real punch /
	# kick clip (KayKit) fire their state; minimal skins (Sophia, cop_riot)
	# fall back to the EdgeGrab pose or inherit the no-op.
	if _skin != null:
		_skin.attack()
	_sweep_attack()


func _on_enemy_hit_player(impulse: Vector3) -> void:
	# Legacy Enemy.gd fires this signal with a pre-computed impulse vector.
	# Route it through the universal take_hit so player damage handling
	# stays in one place regardless of attacker type.
	if impulse.length_squared() < 0.0001:
		return
	take_hit(impulse.normalized(), impulse.length())


func _tick_health_regen(delta: float) -> void:
	if health_regen_delay <= 0.0 or _health >= max_health:
		return
	_regen_timer += delta
	if _regen_timer >= health_regen_delay:
		var old_health := _health
		_health = max_health
		_regen_timer = 0.0
		if old_health != _health:
			health_changed.emit(_health, old_health)


func _tick_damage_tint(delta: float) -> void:
	if _tint_timer <= 0.0 or _skin == null:
		return
	_tint_timer = maxf(0.0, _tint_timer - delta)
	if damage_tint_duration <= 0.0:
		_skin.damage_tint = 0.0
		return
	var fraction: float = _tint_timer / damage_tint_duration
	_skin.damage_tint = fraction * damage_tint_max


## Add `rid` to the active player's camera SpringArm exclusion list, so the
## camera passes through that body instead of pushing inward against it.
## Public entry point — late-spawning pawns call this on the player to
## register themselves. No-op if this body isn't the active player (no
## _spring) or rid is invalid.
func add_camera_exclusion(rid: RID) -> void:
	if _spring != null and rid.is_valid():
		_spring.add_excluded_object(rid)


## Walk every pawn currently in the &"enemies" and &"allies" groups and
## exclude them from the SpringArm. Called once during active-player
## _ready. Future spawns register themselves via call_deferred in their
## own _ready (see _register_with_player_camera).
func _exclude_existing_pawns_from_camera() -> void:
	if _spring == null:
		return
	for grp in [&"enemies", &"allies"]:
		for pawn in get_tree().get_nodes_in_group(grp):
			if pawn is CollisionObject3D and pawn != self:
				_spring.add_excluded_object((pawn as CollisionObject3D).get_rid())


## Find the active player and ask its SpringArm to exclude this body.
## Called via call_deferred from non-player pawns' _ready so the player's
## _spring has time to initialize. Silent no-op if no active player
## exists yet (single-player scenes always have one; tests may not).
func _register_with_player_camera() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var active: Node = tree.get_first_node_in_group(&"player")
	if active != null and active != self and active.has_method(&"add_camera_exclusion"):
		active.call(&"add_camera_exclusion", self.get_rid())


## Build the footstep / death AudioStreamPlayer3D children and resolve the
## sample pools. Called once at _ready. Pools fall back to scanning the
## auto-load dir when the explicit @export array is empty — convenient for
## sample banks with dozens of files.
func _setup_pawn_audio() -> void:
	_walk_footstep_pool_resolved = walk_footstep_pool.duplicate()
	if _walk_footstep_pool_resolved.is_empty() and not walk_footstep_auto_load_dir.is_empty():
		_walk_footstep_pool_resolved = _load_audio_dir(walk_footstep_auto_load_dir)
	_skate_stride_pool_resolved = skate_stride_pool.duplicate()
	if _skate_stride_pool_resolved.is_empty() and not skate_stride_auto_load_dir.is_empty():
		_skate_stride_pool_resolved = _load_audio_dir(skate_stride_auto_load_dir)
	_death_sound_pool_resolved = death_sound_pool.duplicate()
	if _death_sound_pool_resolved.is_empty() and not death_sound_auto_load_dir.is_empty():
		_death_sound_pool_resolved = _load_audio_dir(death_sound_auto_load_dir)
	_attack_kick_pool_resolved = attack_kick_pool.duplicate()
	if _attack_kick_pool_resolved.is_empty() and not attack_kick_auto_load_dir.is_empty():
		_attack_kick_pool_resolved = _load_audio_dir(attack_kick_auto_load_dir)
	_attack_impact_pool_resolved = attack_impact_pool.duplicate()
	if _attack_impact_pool_resolved.is_empty() and not attack_impact_auto_load_dir.is_empty():
		_attack_impact_pool_resolved = _load_audio_dir(attack_impact_auto_load_dir)
	if pawn_group == "player":
		print("[atk-aud-dbg] %s pools: kick=%d (dir=%s) impact=%d (dir=%s)" % [
			get_path(),
			_attack_kick_pool_resolved.size(), attack_kick_auto_load_dir,
			_attack_impact_pool_resolved.size(), attack_impact_auto_load_dir])
	_footstep_player_a = _make_pawn_3d_player()
	_footstep_player_b = _make_pawn_3d_player()
	_death_sfx_player = _make_pawn_3d_player()
	_kick_sfx_player = _make_pawn_3d_player()
	_impact_sfx_player = _make_pawn_3d_player()
	if skate_roll_enabled and skate_roll_stream != null:
		_roll_player = _make_pawn_3d_player()
		_roll_player.stream = skate_roll_stream
		_roll_player.volume_db = -60.0


func _make_pawn_3d_player() -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.bus = &"SFX"
	# unit_size 12m: stays loud out to the player's camera arm (~9m back) so
	# the player hears their own footsteps clearly. Inverse-distance attenuation
	# kicks in past 12m, max_distance silences other pawns past 25m.
	p.unit_size = 12.0
	p.max_distance = 25.0
	add_child(p)
	return p


## Enumerate audio resources in a res:// directory and load each via
## ResourceLoader. Critical detail for exports: Godot strips raw .mp3/.wav/.ogg
## source files from export packs — only the .import sidecars + the imported
## form (.mp3str / .sample) ship. Scanning for .mp3 extensions in an export
## returns ZERO files. We scan for .import sidecars instead (they DO ship
## in both editor and export), strip the suffix to get the source name,
## then load() — ResourceLoader resolves to the imported form via the .import.
func _load_audio_dir(path: String) -> Array[AudioStream]:
	var out: Array[AudioStream] = []
	var dir := DirAccess.open(path)
	if dir == null:
		push_warning("PlayerBody: audio auto-load dir missing: %s" % path)
		return out
	dir.list_dir_begin()
	var sources: Dictionary = {}  # dedupe editor's source + .import sibling pairs
	while true:
		var f := dir.get_next()
		if f == "":
			break
		if dir.current_is_dir():
			continue
		# "wooshA.mp3.import" → source "wooshA.mp3". In editor we also see
		# the raw .mp3; the dict dedupes both into the same source key.
		var source_name: String = f
		if f.to_lower().ends_with(".import"):
			source_name = f.substr(0, f.length() - 7)
		var lower_src: String = source_name.to_lower()
		if lower_src.ends_with(".wav") or lower_src.ends_with(".ogg") or lower_src.ends_with(".mp3"):
			sources[source_name] = true
	dir.list_dir_end()
	var files: Array = sources.keys()
	files.sort()
	var loaded := 0
	var failed := 0
	for f: String in files:
		var s := load(path.path_join(f)) as AudioStream
		if s != null:
			out.append(s)
			loaded += 1
		else:
			failed += 1
	if pawn_group == "player":
		print("[aud-dbg] _load_audio_dir(%s) found=%d loaded=%d failed=%d" % [
			path, files.size(), loaded, failed])
	return out


## Drive walk-cycle anim time scale + footstep cadence from the body's actual
## horizontal speed. Single source of truth: both the visual and the audio
## scale off `h_speed / max_speed`, so stride length and click rate stay in
## lockstep automatically. Skating bypasses this entirely.
func _tick_walk_audio_visual(delta: float, h_speed: float, profile: MovementProfile) -> void:
	if profile == null or _skin == null:
		return
	var in_walk: bool = profile == walk_profile and walk_profile != null
	if walk_anim_speed_scaling:
		# Both modes: Move (and CrouchMove, on skins that wire it) plays at
		# speed/max_speed — so half stick = half-rate cycle, and the accel
		# ramp from standstill sweeps the rate up naturally. Crouched, the
		# ratio tops out at crouch_speed_multiplier, slowing the cycle to
		# match the reduced speed cap.
		var max_speed: float = maxf(profile.max_speed, 0.001)
		var ratio: float = clampf(h_speed / max_speed, 0.0, 1.0)
		# Gait-band tempo (both modes): each gait ramps gait_tempo_floor→1.0
		# across its own band (walk 0→cutover_start, run cutover_end→1.0);
		# through the cutover the tempo eases back to the floor so the
		# incoming run cycle starts unhurried. Which CLIP plays is the blend
		# space's job (set_gait_blend below). The band floor (0.7) also
		# means a slow glide never drops into slow-motion territory the way
		# the old walk_anim_min_scale floor (0.35) did.
		var anim_scale: float
		if ratio < gait_cutover_start:
			anim_scale = lerpf(gait_tempo_floor, 1.0,
				ratio / maxf(gait_cutover_start, 0.001))
		elif ratio < gait_cutover_end:
			anim_scale = lerpf(1.0, gait_tempo_floor,
				(ratio - gait_cutover_start) / maxf(gait_cutover_end - gait_cutover_start, 0.001))
		else:
			anim_scale = lerpf(gait_tempo_floor, 1.0,
				(ratio - gait_cutover_end) / maxf(1.0 - gait_cutover_end, 0.001))
		if h_speed < walk_footstep_min_speed:
			# Below the walking threshold the Move state is unlikely to be
			# active anyway; reset to authored rate so anything that does
			# play (transitions, idle->move) reads natural.
			anim_scale = 1.0
		_skin.set_walk_speed_scale(anim_scale)
		# Speed drives the walk↔run blend in BOTH modes — slow skate glide
		# reads as steps, cruising reads as the run cycle.
		_skin.set_gait_blend(ratio)
	else:
		# Scaling disabled on this pawn (AI variants — see
		# walk_anim_speed_scaling). Authored playback speed regardless of
		# body velocity.
		_skin.set_walk_speed_scale(1.0)
		_skin.set_gait_blend(1.0)
	# --- walk footsteps ---
	if walk_footsteps_enabled and not _walk_footstep_pool_resolved.is_empty():
		if not in_walk or _dying or not is_on_floor() or h_speed < walk_footstep_min_speed:
			# Rising edge of "no longer striding": cut any audio still ringing
			# out (matters for skate; harmless for short walk clicks). Then
			# reset phase so the next stride fires immediately on resume.
			if _footstep_phase != 0.0:
				_stop_stride_audio()
			_footstep_phase = 0.0
		elif _footstep_phase == 0.0:
			_play_random_footstep()
			_footstep_phase = 0.0001
		else:
			var max_speed_w: float = maxf(profile.max_speed, 0.001)
			_footstep_phase += (h_speed / max_speed_w) * walk_footstep_cadence_at_max * delta
			if _footstep_phase >= 1.0:
				_footstep_phase -= 1.0
				_play_random_footstep()
	# --- skate strides (synced to the sway stroke clock) ---
	# One stride per sway extreme (_sway_phase crossing π/2 + k·π): the roll,
	# the accel pulse, and the push sound all peak on the same beat, and two
	# clips + no-immediate-repeat reads as L/R alternation for free.
	var in_skate: bool = profile == skate_profile and skate_profile != null
	if skate_strides_enabled and not _skate_stride_pool_resolved.is_empty():
		if not in_skate or _dying or not is_on_floor() or h_speed < skate_stride_min_speed:
			if _stride_stroke_idx != _STROKE_IDX_INACTIVE:
				_stop_stride_audio()
			_stride_stroke_idx = _STROKE_IDX_INACTIVE
		else:
			var stroke_idx: int = int(floorf((_sway_phase + PI * 0.5) / PI))
			if _stride_stroke_idx == _STROKE_IDX_INACTIVE:
				# Entry stride on the start-moving edge, matching the old
				# play-immediately behavior; subsequent strides ride the phase.
				_play_random_skate_stride()
				_stride_stroke_idx = stroke_idx
			elif stroke_idx != _stride_stroke_idx:
				_stride_stroke_idx = stroke_idx
				_play_random_skate_stride()
	# --- walk strides layered on top of skate (occasional keyboard-bursts
	# while rolling). Same pool + cadence as walk mode but each stride rolls
	# the dropout dice — at 0.5, ~half the strides play, which reads as
	# clusters thanks to random distribution.
	if walk_during_skate_enabled and in_skate \
			and walk_footsteps_enabled and not _walk_footstep_pool_resolved.is_empty():
		if _dying or not is_on_floor() or h_speed < walk_footstep_min_speed:
			_skate_walk_phase = 0.0
		elif _skate_walk_phase == 0.0:
			if randf() >= walk_during_skate_dropout:
				_play_random_footstep()
			_skate_walk_phase = 0.0001
		else:
			var max_speed_skw: float = maxf(profile.max_speed, 0.001)
			_skate_walk_phase += (h_speed / max_speed_skw) * walk_footstep_cadence_at_max * delta
			if _skate_walk_phase >= 1.0:
				_skate_walk_phase -= 1.0
				if randf() >= walk_during_skate_dropout:
					_play_random_footstep()
	else:
		_skate_walk_phase = 0.0
	# --- wheel-roll bed --- volume swells with speed (full skate_roll_volume_db
	# at max, −18dB down at a crawl), pitch spreads across the speed range.
	# Smoothed chase both directions so ground gaps / brief stops don't gate
	# the loop on and off; player stops once faded below audibility.
	if _roll_player != null:
		var roll_on: bool = in_skate and not _dying and is_on_floor() and h_speed > 0.5
		var ratio: float = clampf(h_speed / maxf(profile.max_speed, 0.001), 0.0, 1.0)
		var target_db: float = (skate_roll_volume_db - 18.0 * (1.0 - ratio)) if roll_on else -60.0
		var k: float = 1.0 - exp(-10.0 * delta)
		_roll_player.volume_db = lerpf(_roll_player.volume_db, target_db, k)
		if roll_on:
			_roll_player.pitch_scale = lerpf(1.0 - skate_roll_pitch_spread,
					1.0 + skate_roll_pitch_spread, ratio)
			if not _roll_player.playing:
				_roll_player.play()
		elif _roll_player.playing and _roll_player.volume_db < -50.0:
			_roll_player.stop()


func _stop_stride_audio() -> void:
	if _footstep_player_a != null and _footstep_player_a.playing:
		_footstep_player_a.stop()
	if _footstep_player_b != null and _footstep_player_b.playing:
		_footstep_player_b.stop()


func _play_random_footstep() -> void:
	var n: int = _walk_footstep_pool_resolved.size()
	if n == 0:
		return
	var idx: int = randi() % n
	if n > 1 and idx == _last_footstep_idx:
		idx = (idx + 1) % n
	_last_footstep_idx = idx
	var p: AudioStreamPlayer3D = _footstep_player_b if _footstep_player_toggle else _footstep_player_a
	_footstep_player_toggle = not _footstep_player_toggle
	p.stream = _walk_footstep_pool_resolved[idx]
	p.volume_db = walk_footstep_volume_db
	p.pitch_scale = 1.0 + randf_range(-walk_footstep_pitch_jitter, walk_footstep_pitch_jitter)
	p.play()


func _play_random_skate_stride() -> void:
	var n: int = _skate_stride_pool_resolved.size()
	if n == 0:
		return
	var idx: int = randi() % n
	if n > 1 and idx == _last_skate_stride_idx:
		idx = (idx + 1) % n
	_last_skate_stride_idx = idx
	var p: AudioStreamPlayer3D = _footstep_player_b if _footstep_player_toggle else _footstep_player_a
	_footstep_player_toggle = not _footstep_player_toggle
	p.stream = _skate_stride_pool_resolved[idx]
	p.volume_db = skate_stride_volume_db
	p.pitch_scale = 1.0 + randf_range(-skate_stride_pitch_jitter, skate_stride_pitch_jitter)
	p.play()


func _play_random_death_sfx() -> void:
	# Pawn-specific death pool selection. Player pawn sets
	# death_sfx_uses_attack_impact_pool=true to dodge its cheesy cartoon
	# horns; enemies leave it false so their authored glitch death sounds
	# (audio/sfx/enemy_deaths/glitch_death_*.wav) play on death. Either
	# branch falls back to the OTHER pool if the preferred one is empty.
	var pool: Array[AudioStream]
	if death_sfx_uses_attack_impact_pool:
		pool = _attack_impact_pool_resolved
		if pool.is_empty():
			pool = _death_sound_pool_resolved
	else:
		pool = _death_sound_pool_resolved
		if pool.is_empty():
			pool = _attack_impact_pool_resolved
	if pool.is_empty() or _death_sfx_player == null:
		return
	var n: int = pool.size()
	var idx: int = randi() % n
	if n > 1 and idx == _last_death_sfx_idx:
		idx = (idx + 1) % n
	_last_death_sfx_idx = idx
	_death_sfx_player.stream = pool[idx]
	_death_sfx_player.volume_db = death_sound_volume_db
	_death_sfx_player.pitch_scale = 1.0 + randf_range(-death_sound_pitch_jitter, death_sound_pitch_jitter)
	_death_sfx_player.play()


func _play_random_attack_kick_sfx() -> void:
	var pool: Array[AudioStream] = _attack_kick_pool_resolved
	if pool.is_empty() or _kick_sfx_player == null:
		print("[atk-aud-dbg] kick skip: pool=%d player=%s" % [pool.size(), _kick_sfx_player])
		return
	var n: int = pool.size()
	var idx: int = randi() % n
	if n > 1 and idx == _last_attack_kick_idx:
		idx = (idx + 1) % n
	_last_attack_kick_idx = idx
	_kick_sfx_player.stream = pool[idx]
	_kick_sfx_player.volume_db = attack_kick_volume_db
	_kick_sfx_player.pitch_scale = 1.0 + randf_range(-attack_kick_pitch_jitter, attack_kick_pitch_jitter)
	_kick_sfx_player.play()
	var sfx_idx := AudioServer.get_bus_index(&"SFX")
	print("[atk-aud-dbg] kick play: idx=%d stream=%s vol_db=%.1f sfx_bus_db=%.1f sfx_muted=%s" % [
		idx, pool[idx].resource_path, attack_kick_volume_db,
		AudioServer.get_bus_volume_db(sfx_idx), AudioServer.is_bus_mute(sfx_idx)])


func _play_random_attack_impact_sfx() -> void:
	var pool: Array[AudioStream] = _attack_impact_pool_resolved
	if pool.is_empty() or _impact_sfx_player == null:
		print("[atk-aud-dbg] impact skip: pool=%d player=%s" % [pool.size(), _impact_sfx_player])
		return
	var n: int = pool.size()
	var idx: int = randi() % n
	if n > 1 and idx == _last_attack_impact_idx:
		idx = (idx + 1) % n
	_last_attack_impact_idx = idx
	_impact_sfx_player.stream = pool[idx]
	_impact_sfx_player.volume_db = attack_impact_volume_db
	_impact_sfx_player.pitch_scale = 1.0 + randf_range(-attack_impact_pitch_jitter, attack_impact_pitch_jitter)
	_impact_sfx_player.play()


func _start_death(impact_direction: Vector3) -> void:
	_dying = true
	# Drop out of the collision layer immediately so the player can't bump
	# into the corpse mid-knockback. Mask stays — the dying body still
	# collides WITH the floor so it falls and lands. Layer is restored on
	# respawn (_finish_death) for non-permanent dying pawns.
	_pre_death_collision_layer = collision_layer
	collision_layer = 0
	_skin.damage_tint = 0.0
	_death_burst_done = false
	_death_glitch_value = 0.0
	# Death sfx is now played from _spawn_death_confetti() so it lands with
	# the burst, not at launch. (Legacy path spawns confetti immediately
	# below; knockback path waits for the pose-hold then bursts.)
	if _skin.uses_knockback_death:
		# Procedural knockback: launch along impact + lift, capture the skin's
		# current basis to slerp from, let physics carry them. Death tick
		# detects landing → freezes pose → holds → burst+flicker → poof.
		var dir: Vector3 = impact_direction
		dir.y = 0.0
		_death_impact_dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector3.BACK
		_death_landed = false
		_death_pose_timer = 0.0
		_death_flight_time = 0.0
		_death_skin_basis_start = _skin.basis if _skin != null else Basis.IDENTITY
		velocity = _death_impact_dir * death_knockback_horizontal + Vector3.UP * death_knockback_vertical
		# Hit_A/B reads as the killing-blow recoil during the flight; freeze
		# locks whatever frame is up when feet touch the ground.
		_skin.on_hit()
		_dying_timer = _DEATH_SAFETY_TIMEOUT if dies_permanently else _PLAYER_DEATH_DURATION
	else:
		# Legacy path (player/Sophia): pop straight up, immediate confetti —
		# the rise IS the death visual, then respawn at checkpoint.
		_dying_timer = death_duration
		_skin.die()
		_skin.jump()
		velocity = Vector3(0.0, death_rise_speed, 0.0)
		_spawn_death_confetti()
	died.emit()
	_emit_pending_respawn_hints()
	_drain_pending_voice_lines()


## Stealth-kill entry point. No knockback launch, no horizontal impulse —
## the pawn falls over in place: Hit anim plays once, skin tilts to lying-
## on-back via the existing pose curve, confetti bursts after the hold,
## queue_free. Intended for behind-the-back hack takedowns from a
## StealthKillTarget Area3D — see enemy/stealth_kill_target.gd.
func stealth_kill(impact_direction: Vector3 = Vector3.BACK) -> void:
	if _dying:
		return
	_dying = true
	if _skin != null:
		_skin.damage_tint = 0.0
	_death_burst_done = false
	_death_glitch_value = 0.0
	if _skin != null and _skin.uses_knockback_death:
		var dir: Vector3 = impact_direction
		dir.y = 0.0
		_death_impact_dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector3.BACK
		# Pre-landed: no knockback flight. _tick_knockback_death sees
		# _death_landed = true and runs the stealth-fall timeline (eased
		# tip-over + flop bounces) before the pose-hold sequence.
		_death_landed = true
		_death_pose_timer = 0.0
		_death_flight_time = 0.0
		_death_skin_basis_start = _skin.basis
		_stealth_fall_time = 0.0
		# Zero velocity = falls in place via gravity, no launch.
		velocity = Vector3.ZERO
		_skin.on_hit()
		_dying_timer = _DEATH_SAFETY_TIMEOUT if dies_permanently else _PLAYER_DEATH_DURATION
	else:
		# Legacy fallback path (skins without uses_knockback_death) — confetti
		# + die clip in place. No vertical pop.
		_dying_timer = death_duration
		if _skin != null and _skin.has_method(&"die"):
			_skin.die()
		velocity = Vector3.ZERO
		_spawn_death_confetti()
	died.emit()
	_emit_pending_respawn_hints()
	_drain_pending_voice_lines()


## Per-frame work for the knockback death sequence. Called from the dying
## branch of _physics_process for skins with uses_knockback_death = true.
## Enemies (dies_permanently) burst + flicker after the pose hold and
## queue_free; the player stays frozen until _DEATH_SAFETY_TIMEOUT triggers
## respawn (the death overlay + screen glitch carry the player visual).
func _tick_knockback_death(delta: float) -> void:
	if not _death_landed:
		_death_flight_time += delta
		var tilt_progress: float = clampf(_death_flight_time / death_tilt_duration, 0.0, 1.0)
		_apply_death_skin_pose(tilt_progress)
		if _death_flight_time > 0.05 and is_on_floor():
			_death_landed = true
			velocity = Vector3.ZERO
			_skin.freeze_animation()
			_apply_death_skin_pose(1.0)
		return
	if _stealth_fall_time >= 0.0:
		_stealth_fall_time += delta
		if _tick_stealth_fall(delta):
			return  # tip/bounce timeline still playing; pose hold starts after.
	_death_pose_timer += delta
	_apply_death_skin_pose(1.0)
	if not dies_permanently:
		# Player path: stay frozen until the safety timeout fires _finish_death.
		# The death overlay + screen glitch sequence is what the player sees.
		return
	# Enemy path: pose hold → confetti burst + glitch flicker → queue_free.
	if not _death_burst_done and _death_pose_timer >= _DEATH_POSE_HOLD:
		_death_burst_done = true
		_spawn_death_confetti()
	if _death_burst_done:
		_death_glitch_value = minf(_death_glitch_value + delta / _DEATH_GLITCH_RAMP, 1.0)
		_skin.set_glitch_progress(_death_glitch_value)
		if _death_pose_timer >= _DEATH_POSE_HOLD + _DEATH_FLICKER_DURATION:
			_dying_timer = 0.0


## Stealth-kill fall timeline. Phase 1: tip-over with a power ease-in
## (inverted-pendulum approximation — near-zero angular speed upright,
## maximum at impact). Phase 2: two ballistic flop bounces on the skin's
## Y, decaying by restitution² in height and restitution in duration.
## Returns true while animating; flips _stealth_fall_time to -1 and
## returns false once settled so the caller's pose-hold takes over.
func _tick_stealth_fall(delta: float) -> bool:
	if _skin == null:
		_stealth_fall_time = -1.0
		return false
	var t: float = _stealth_fall_time
	var tip_d: float = maxf(stealth_fall_tip_duration, 0.01)
	if t < tip_d:
		_apply_death_skin_pose(pow(t / tip_d, maxf(stealth_fall_tip_exponent, 1.0)))
		return true
	var after: float = t - tip_d
	# First grounded frame = impact: freeze the skin's animation mid-pose,
	# mirroring what the knockback flight path does on landing.
	if after - delta < 0.0:
		_skin.freeze_animation()
	var e: float = stealth_fall_restitution
	var b1: float = maxf(stealth_fall_bounce_duration, 0.01)
	var b2: float = b1 * e
	var bounce_y: float = 0.0
	if after < b1:
		var u: float = after / b1
		bounce_y = 4.0 * stealth_fall_bounce_height * u * (1.0 - u)
	elif b2 > 0.0 and after < b1 + b2:
		var u: float = (after - b1) / b2
		bounce_y = 4.0 * stealth_fall_bounce_height * e * e * u * (1.0 - u)
	else:
		_stealth_fall_time = -1.0
		_apply_death_skin_pose(1.0)
		return false
	_apply_death_skin_pose(1.0)
	_skin.position.y += bounce_y
	return true


## Build the skin basis at `tilt_progress` ∈ [0, 1] from upright (captured
## at death start) to lying flat on back with head pointed along the impact
## direction. Slerp in rotation space, re-apply uniform_scale, lift the skin
## by death_pose_lift × tilt_progress so the body's back rests above ground
## instead of clipping into it (rotation pivot is at the feet).
func _apply_death_skin_pose(tilt_progress: float) -> void:
	if _skin == null:
		return
	var head: Vector3 = _death_impact_dir
	var face: Vector3 = Vector3.UP
	var right: Vector3 = head.cross(face).normalized()
	if right.length_squared() < 0.0001:
		return
	var t: float = clampf(tilt_progress, 0.0, 1.0)
	var dead_basis: Basis = Basis(right, head, face)
	var upright: Basis = _death_skin_basis_start.orthonormalized()
	var rot: Basis = upright.slerp(dead_basis, t)
	var s: float = _skin.uniform_scale
	if not is_equal_approx(s, 1.0):
		rot = rot.scaled(Vector3.ONE * s)
	_skin.transform = Transform3D(rot, Vector3(0.0, death_pose_lift * t, 0.0))


func _finish_death() -> void:
	# Terminal-death pawns (enemies) poof and are gone; respawning pawns
	# (players) snap back to their last checkpoint.
	if dies_permanently:
		queue_free()
		return
	# Force halfpipe disengage BEFORE the position snap. Without this, the
	# engaged-state up_direction + floor_max_angle + tilted basis survive
	# the respawn — the body teleports back to the checkpoint still in
	# "on the wall" mode and immediately accelerates along the stale
	# tangent. Mirror of snap_to_spawn:2291 which already does this for
	# cross-level teleports; in-level death respawn was missing it.
	_halfpipe_disengage()
	# Body basis may have been rotated by the kinematic align path. Reset
	# to identity so the respawned pose isn't tilted.
	global_rotation = Vector3.ZERO
	_hp_needs_reupright = false
	global_position = _start_position
	velocity = Vector3.ZERO
	var old_health := _health
	_health = max_health
	_dying = false
	# Restore the collision layer we saved on death so the respawned pawn
	# can be bumped/hit again.
	if _pre_death_collision_layer != 0:
		collision_layer = _pre_death_collision_layer
	if old_health != _health:
		health_changed.emit(_health, old_health)
	_attack_timer = 0.0
	_tint_timer = 0.0
	# Start the post-respawn grace window. take_hit no-ops until this elapses.
	# Kill-plane gets a shorter 1s window — long enough to absorb a stale
	# fall signal queued during the respawn teleport, short enough that a
	# checkpoint placed near a ledge can still kill you if you walk off.
	var now: float = Time.get_ticks_msec() / 1000.0
	_invuln_until_time = now + respawn_invuln_duration
	_kill_plane_invuln_until_time = now + 1.0
	if _skin != null:
		_skin.damage_tint = 0.0
		# Knockback death froze the AnimationTree and rotated the skin onto
		# its back; reset both so respawn isn't stuck flat in the freeze pose.
		_skin.unfreeze_animation()
		_skin.transform = Transform3D.IDENTITY
		if not is_equal_approx(_skin.uniform_scale, 1.0):
			_skin.scale = Vector3.ONE * _skin.uniform_scale
	_skin.idle()
	respawned.emit()
	# Global hook for HUD/world systems that just need "the player came back"
	# without tracking every PlayerBody. Enemies that respawn don't fire this.
	if is_in_group("player"):
		Events.player_respawned.emit()
	# Hints + voice already drained at _start_death. Both timers count from
	# the death event so the message warp-in and Companion line both land at
	# ~1s after death (mid-rise, before the respawn snap). See
	# _emit_pending_respawn_hints + _drain_pending_voice_lines.
	_snap_camera_to_player()
	set_physics_process(true)


func _spawn_death_confetti() -> void:
	# Glitch sfx fires together with the burst so the audio + visual land on
	# the same frame. Moved here from _start_death (which was at launch time
	# for the knockback path, sometimes ~1s before the burst actually appeared).
	_play_random_death_sfx()
	if death_burst_scene == null:
		return
	var burst: Node3D = death_burst_scene.instantiate()
	burst.call("set_direction", Vector3.UP)
	# Glitch-style enemies (KayKit) override the confetti material so the
	# burst reads as scrambled debris instead of party confetti.
	if _skin != null and _skin.confetti_glitch_material != null:
		burst.call("set_overlay_material", _skin.confetti_glitch_material)
	get_parent().add_child(burst)
	burst.global_position = global_position


## Universal damage entry point. Decrement HP, apply knockback, flash tint;
## trigger death sequence when HP hits zero. Works for player (max_health=3,
## respawns) and enemies (max_health=1, dies_permanently=true → queue_free).
## Pawns outside a sweep's attack_target_group are simply never called — no
## faction gating needed inside the method.
func take_hit(impact_direction: Vector3, force: float, damage: int = 1, attacker: Node = null) -> void:
	if _dying:
		return
	# Provoked aggression: ANY hit (even one blocked by invuln) snaps the AI
	# brain to HOSTILE on the attacker. Without this, splice_stealth shrugs
	# off your swing and keeps patrolling because invuln short-circuits the
	# damage path before any state change. Fires before the invuln check on
	# purpose — we want the aggro reaction whether or not damage applied.
	if _brain != null and attacker != null and _brain.has_method(&"aggro_to"):
		_brain.call(&"aggro_to", attacker)
	# Faction-aware invuln. Red blocks player attacks (you can't punch them
	# yourself — recruit golds). Splice_stealth blocks everything via this
	# path; only StealthKillTarget's backstab calls stealth_kill() directly.
	# Gold blocks splice_enemies (red+stealth) IF the conversion-time dodge
	# roll passed — the % scales with coin completion so collecting coins
	# makes your posse more reliable in fights.
	if _is_invuln_against(attacker):
		return
	# Post-respawn grace window: ignore damage for respawn_invuln_duration
	# seconds after _finish_death. Fixes the checkpoint death-loop.
	if Time.get_ticks_msec() / 1000.0 < _invuln_until_time:
		return
	var old_health := _health
	_health -= maxi(damage, 0)
	# DEBUG: trace each landed hit so we can diagnose "instant kill" reports.
	# Prints attacker faction + the damage value the attacker thinks it has,
	# alongside the actual damage applied and resulting hp. Strip once the
	# red-splice one-shot mystery is closed.
	var atk_faction: String = "?"
	var atk_dmg: int = -1
	if attacker != null and is_instance_valid(attacker):
		if "faction" in attacker:
			atk_faction = String(attacker.get(&"faction"))
		if "_faction_attack_damage" in attacker:
			atk_dmg = int(attacker.get(&"_faction_attack_damage"))
	print("[hit-trace] %s ← attacker=%s faction=%s atk_dmg=%d  applied=%d  hp %d → %d" % [
		name,
		attacker.name if attacker != null and is_instance_valid(attacker) else "<null>",
		atk_faction, atk_dmg, damage, old_health, _health,
	])
	_regen_timer = 0.0
	# Additive knockback: direction-along-impact plus a small vertical pop so
	# the hit reads kinetically regardless of current motion.
	var dir := impact_direction.normalized() if impact_direction.length_squared() > 0.0001 else Vector3.BACK
	velocity += dir * force + Vector3.UP * 3.5
	_tint_timer = damage_tint_duration
	if _skin != null:
		_skin.damage_tint = damage_tint_max
		_skin.on_hit()
	health_changed.emit(_health, old_health)
	if _health <= 0:
		# Order matters when dying mid-dialogue: _start_death FIRST so _dying
		# flips true before Dialogue.fire_death_interrupt fires _close →
		# Events.dialogue_ended → DialogueTrigger._exit_cinematic. The exit
		# checks actor._dying to take the snap-restore fast path; if force_close
		# ran before _start_death, _exit_cinematic would queue the slow camera
		# tween and the death timer would stay frozen while it played out.
		_start_death(impact_direction)
		if pawn_group == "player" and Dialogue.is_open():
			Dialogue.fire_death_interrupt()


# Faction-relational invuln. Returns true if THIS pawn is immune to a hit
# from `attacker`. Per-faction rules:
#   red:            blocks attackers in the player group only
#   splice_stealth: blocks every attacker (universal); the [E] backstab
#                   uses stealth_kill() directly so it bypasses take_hit
#   gold:           blocks splice_enemies attackers IF this gold rolled
#                   the coin-progression dodge at conversion time
#   anything else:  not invuln
# attacker = null is treated as a player attack (legacy callers + traps).
func _is_invuln_against(attacker: Node) -> bool:
	var attacker_is_player: bool = attacker == null \
		or (attacker is Node and (attacker as Node).is_in_group(&"player"))
	var attacker_faction: StringName = &""
	if attacker is Node and "faction" in attacker:
		attacker_faction = StringName(attacker.get(&"faction"))
	match faction:
		&"red":
			# Was: return attacker_is_player (player couldn't punch reds —
			# they had to recruit golds via portals). Now: red takes player
			# damage normally, max_health gates how many hits to kill.
			return false
		&"splice_stealth":
			# Stealth is invulnerable to gold ally attackers — the posse
			# isn't allowed to clear stealth pawns for you; the player has
			# to handle stealth themselves (typically via StealthKillTarget
			# backstab, which calls stealth_kill() directly and bypasses
			# this whole take_hit path). Player attacks + any other faction
			# pass through and damage stealth normally.
			return attacker_faction == &"gold"
		&"gold":
			# Dodge applies vs RED only — not vs splice_stealth. Preserved
			# as-is: gold posse still has the coin-completion-scaled
			# survival roll against red attacks.
			return _gold_dodges_splice and attacker_faction == &"red"
		_:
			return false


# Pick the nearest auto-orient candidate within attack_auto_orient_range AND
# inside the cone defined by attack_auto_orient_cone_deg around `facing`.
# Both inputs are world-space horizontal-flat vectors. Returns null if no
# valid target — caller leaves `forward` unchanged.
func _find_auto_orient_target(facing: Vector3) -> Node3D:
	if attack_auto_orient_cone_deg <= 0.0 or attack_auto_orient_range <= 0.0:
		return null
	if facing.length_squared() <= 0.0001:
		return null
	# Half-angle drives the cone test (dot product against facing). 70°
	# full cone → 35° half → cos ≈ 0.819.
	var cos_threshold: float = cos(deg_to_rad(attack_auto_orient_cone_deg * 0.5))
	var best: Node3D = null
	var best_dist_sq: float = attack_auto_orient_range * attack_auto_orient_range
	# Union candidates from every group in attack_target_groups. The
	# `seen` dict dedupes pawns that are in multiple groups.
	var seen: Dictionary = {}
	for grp in attack_target_groups:
		for n: Node in get_tree().get_nodes_in_group(grp):
			if seen.has(n):
				continue
			seen[n] = true
			if not (n is Node3D):
				continue
			var node3d: Node3D = n as Node3D
			var to_target: Vector3 = node3d.global_position - global_position
			to_target.y = 0.0
			var dist_sq: float = to_target.length_squared()
			if dist_sq <= 0.0001 or dist_sq > best_dist_sq:
				continue
			var dir: Vector3 = to_target / sqrt(dist_sq)
			if dir.dot(facing) < cos_threshold:
				continue
			best = node3d
			best_dist_sq = dist_sq
	return best


func _sweep_attack() -> void:
	var range_sq := attack_range * attack_range
	var hit_any: bool = false
	# Union candidates across all target groups. `seen` dedupes — a pawn in
	# two groups (rare but possible) only checked once per swing.
	var seen: Dictionary = {}
	for grp in attack_target_groups:
		for enemy: Node in get_tree().get_nodes_in_group(grp):
			if seen.has(enemy):
				continue
			seen[enemy] = true
			if not (enemy is Node3D):
				continue
			if _attack_hit_enemies.has(enemy):
				continue
			# Horizontal reach uses attack_range; vertical uses attack_vertical_range.
			# Splitting the two axes means a jumping player reliably clears an
			# enemy swing — straight up = out of reach — while side-by-side hits
			# still land cleanly at the full attack_range.
			var dx: float = (enemy as Node3D).global_position.x - global_position.x
			var dy: float = (enemy as Node3D).global_position.y - global_position.y
			var dz: float = (enemy as Node3D).global_position.z - global_position.z
			if dx * dx + dz * dz > range_sq:
				continue
			if absf(dy) > attack_vertical_range:
				continue
			# Confetti sprays outward along the player→enemy vector (so a hit
			# to the side confettis sideways, not along the player's facing).
			var to_enemy := Vector3(dx, 0.0, dz)
			var impact_dir := to_enemy.normalized() if to_enemy.length_squared() > 0.0001 else _attack_forward
			# Unified damage dispatch: prefer take_hit (new universal API, now
			# 3-arg with damage), fall back to hit() for legacy enemy/enemy.gd
			# until it's retired. _faction_attack_damage is 1 for everyone
			# except splice (red, 99 — one-shot kill on max_health=3).
			if enemy.has_method("take_hit"):
				enemy.take_hit(impact_dir, attack_knockback, _faction_attack_damage, self)
			elif enemy.has_method("hit"):
				enemy.hit(impact_dir, attack_knockback)
			_attack_hit_enemies.append(enemy)
			hit_any = true
	# One impact play per swing if anything connected. _sweep_attack runs
	# every tick of the active window; the _attack_impact_played gate makes
	# the sfx fire on the first connecting tick only.
	if hit_any and not _attack_impact_played:
		_play_random_attack_impact_sfx()
		_attack_impact_played = true


func _apply_follow_mode() -> void:
	_camera_pivot.top_level = (follow_mode == FollowMode.DETACHED)
	_snap_camera_to_player()


func _snap_camera_to_player() -> void:
	if follow_mode == FollowMode.DETACHED:
		_camera_pivot.global_position = global_position + pivot_offset
	else:
		_camera_pivot.position = pivot_offset


# Broad-phase only: the rail's Area3D box entered/exited maintain the
# candidate set; _try_grab_candidate_rails does the real distance check
# per tick. Grabbing on this edge alone was the "sticky rails" bug — the
# box is the curve's AABB and bloats badly on curved/diagonal rails.
func _on_rail_touched(rail: Node, body: Node) -> void:
	if body != self:
		return
	var path_rail: Path3D = rail as Path3D
	if path_rail == null or path_rail.curve == null:
		return
	if not _candidate_rails.has(path_rail):
		_candidate_rails.append(path_rail)


func _on_rail_left(rail: Node, body: Node) -> void:
	if body != self:
		return
	_candidate_rails.erase(rail as Path3D)


## Per-tick narrow phase: while inside any rail's broad-phase box, grab the
## first rail whose curve passes within rail_grab_radius of the body. Runs
## from _physics_process; near-free when the candidate set is empty.
func _try_grab_candidate_rails() -> void:
	if _grinding or _candidate_rails.is_empty():
		return
	if (Time.get_ticks_msec() / 1000.0) < _rail_regrab_block_until:
		return
	var profile: MovementProfile = _current_profile
	if profile == null or profile.grind_speed <= 0.0:
		return
	# Skates-only gate: anyone on blades grinds, regardless of faction.
	# Matches the wheels-visible and halfpipe-stick rule (see line 646-647).
	# Walkers (no skate_profile or not currently in skate mode) skip rails.
	if skate_profile == null or _current_profile != skate_profile:
		return
	for i in range(_candidate_rails.size() - 1, -1, -1):
		var path_rail: Path3D = _candidate_rails[i]
		if path_rail == null or not is_instance_valid(path_rail) or path_rail.curve == null:
			_candidate_rails.remove_at(i)
			continue
		var local_pos: Vector3 = path_rail.to_local(global_position)
		var closest: Vector3 = path_rail.curve.sample_baked(
			path_rail.curve.get_closest_offset(local_pos))
		if path_rail.to_global(closest).distance_to(global_position) <= rail_grab_radius:
			_grab_rail(path_rail)
			return


func _grab_rail(path_rail: Path3D) -> void:
	_grind_rail = path_rail
	_grind_progress = _grind_rail.closest_progress(global_position)
	var pf: PathFollow3D = _grind_rail.get_node_or_null("PathFollow3D") as PathFollow3D
	# Pick direction by comparing velocity to curve tangent at the entry
	# point. If they disagree, grind backward along the curve.
	_grind_direction = 1.0
	if pf != null:
		pf.progress = _grind_progress
		var tangent: Vector3 = -pf.global_transform.basis.z
		var h_vel: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
		if h_vel.length() > 0.1 and h_vel.dot(tangent) < 0.0:
			_grind_direction = -1.0
	_grinding = true
	_grind_snap_t = 0.0
	_grind_start_pos = global_position
	# Suppress jump for the snap-in window so a queued jump from approach
	# doesn't yeet the player off the rail the instant it grabs. Player
	# only — allies don't typically jump on rails anyway, and locking AI
	# bodies' jump for a fixed window during a non-jump action is wrong.
	if pawn_group == "player" and rail_jump_lockout_seconds > 0.0:
		suppress_jump_for(rail_jump_lockout_seconds)
	_natural_lean_roll = 0.0
	_skin.idle()
	if _grind_sparks != null:
		_grind_sparks.restart()
		_grind_sparks.emitting = true
	_start_grind_loop()


func _on_checkpoint_reached(pos: Vector3) -> void:
	_start_position = pos


func _on_respawn_message_armed(text: String) -> void:
	# Skip if it matches the most recent — re-entering the same zone shouldn't
	# stack the same hint, but distinct zones in sequence should chain.
	if not _pending_respawn_messages.is_empty() and _pending_respawn_messages.back() == text:
		return
	_pending_respawn_messages.append(text)


# Fired from _start_death (and stealth_kill) for non-permanent pawns. Pushes
# every pending hint with a pre_delay equal to the death duration plus a
# Lead-in (seconds) from the death event to the first visible frame of the
# respawn hint. Overlapping with the death sequence is intentional — the
# message is meant to read alongside the player's "what just happened?"
# beat, not after a long settle. dies_permanently=true pawns (enemies)
# skip this entirely; they have no respawn flow and the hint queue stays
# empty by construction.
const _RESPAWN_HINT_LEAD_IN: float = 3.0

func _emit_pending_respawn_hints() -> void:
	if dies_permanently or _pending_respawn_messages.is_empty():
		return
	for msg: String in _pending_respawn_messages:
		Events.respawn_message_show.emit(msg, _RESPAWN_HINT_LEAD_IN)
	_pending_respawn_messages.clear()


func _on_respawn_voice_armed(character: String, line: String) -> void:
	# Same dedupe-by-last as the message variant.
	if not _pending_voice_lines.is_empty():
		var last: Dictionary = _pending_voice_lines.back()
		if last.character == character and last.line == line:
			return
	_pending_voice_lines.append({"character": character, "line": line})


func _drain_pending_voice_lines() -> void:
	if _pending_voice_lines.is_empty():
		return
	var lines := _pending_voice_lines.duplicate()
	_pending_voice_lines.clear()
	# Settle window: let the player land + orient before Glitch starts talking.
	# Companion's FIFO sequences the lines themselves; we just gate the start.
	await get_tree().create_timer(_VOICE_RESPAWN_DELAY).timeout
	for entry: Dictionary in lines:
		Companion.speak(entry.character, entry.line)


## Public hook used when the player is teleported into a new level. Resets
## the respawn point so dying before hitting a phone-booth checkpoint drops
## the player at the new level's PlayerSpawn instead of the old level's
## coordinates. Also zeroes velocity so mid-air state doesn't leak across
## a level swap.
func set_respawn_point(pos: Vector3) -> void:
	_start_position = pos
	velocity = Vector3.ZERO


## Lock the player into a slow forward walk in `world_dir` (Y stripped) at
## `speed` m/s. Brain Intent is discarded each tick until exit_betrayal_walk
## fires. Disables jump / dash / attack / crouch / interact intents; leaves
## animation, camera, gravity, and the skin's idle-vs-move logic untouched.
## Used by the betray ending scene (level_5) — see docs/splice_arc.md §5b.
func enter_betrayal_walk(world_dir: Vector3, speed: float = 1.5) -> void:
	var d: Vector3 = world_dir
	d.y = 0.0
	if d.length_squared() < 0.0001:
		push_warning("enter_betrayal_walk: zero direction; ignored")
		return
	_betrayal_walk_dir = d.normalized()
	_betrayal_walk_speed = speed


func exit_betrayal_walk() -> void:
	_betrayal_walk_dir = Vector3.ZERO
	if _brain != null:
		var intent: Variant = _brain.get(&"_intent")
		if intent != null:
			intent.face_yaw_override_set = false


## Initialize spawn facing from the marker's basis. The body itself stays at
## identity yaw — body rotation is treated as not-meaningful in this codebase
## (skin handles visual facing, camera handles logical facing). Baking the
## marker's basis into body.global_transform causes a double-rotation: the
## skin's per-tick yaw is computed in world space and then applied as a
## LOCAL transform under the body, so a non-identity body yaw flips the skin
## opposite the movement direction (looks like running backward).
##
## Forward is `-marker.basis.z` (Godot convention). We seed _last_input_direction
## (so frame-0 skin yaw faces the marker), _yaw_state + _target_yaw (so the
## camera and skin don't lerp out of an old cache), and snap the camera pivot.
func snap_to_spawn(spawn_xform: Transform3D) -> void:
	# Force halfpipe disengage. The per-tick stick logic (line ~3198)
	# intentionally HOLDS engagement when no surface hits this frame —
	# letting the player hop briefly off the curve without losing it. A
	# teleport is a different beast: the player has been moved arbitrarily
	# far away and the engaged-state floor_max_angle / floor_snap_length
	# overrides would otherwise survive into the destination level
	# (hub feels like a halfpipe — sticks to slopes, slides oddly).
	# Canonical repro: Nyx post-L4 convo → advance() → hub spawn while
	# halfpipe state was hot.
	_halfpipe_disengage()

	# Convention: the marker's BLUE Z arrow points where the player faces.
	# (Godot's standard "forward = -Z" convention is for cameras; for spawn
	# markers it's more intuitive to rotate the gizmo to point where the
	# character should look.)
	var fwd: Vector3 = spawn_xform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() > 0.0001:
		fwd = fwd.normalized()
		_last_input_direction = fwd
	var yaw: float = Vector3.BACK.signed_angle_to(fwd, Vector3.UP)
	_yaw_state = yaw
	_target_yaw = yaw
	# Body rotation is reset to identity so skin world-yaw == skin local-yaw.
	global_rotation = Vector3.ZERO
	# Camera yaw at spawn = marker yaw + camera_spawn_yaw_offset_deg. Lets
	# the camera start behind / off-axis from the player without rotating
	# the player themselves. Player faces marker forward; camera looks at
	# whatever angle is configured.
	var cam_yaw: float = yaw + deg_to_rad(camera_spawn_yaw_offset_deg)
	_target_yaw = cam_yaw
	# Apply cam_yaw to the pivot in BOTH follow modes. Previously the
	# attached branch set pivot.rotation = Vector3.ZERO and threw cam_yaw
	# away — the per-frame lerp at _update_follow_camera:3321 only fires
	# when the body is moving, so stationary spawn meant the camera stayed
	# at world rotation 0 regardless of camera_spawn_yaw_offset_deg.
	# Body rotation is set to identity above (line 2096), so local-yaw on
	# the pivot equals world-yaw — same effective placement as detached.
	if _camera_pivot != null:
		if _camera_pivot.top_level:
			_camera_pivot.global_rotation = Vector3(0.0, cam_yaw, 0.0)
		else:
			_camera_pivot.rotation = Vector3(0.0, cam_yaw, 0.0)
	velocity = Vector3.ZERO
	_snap_camera_to_player()


## Snap the character's facing to point toward a horizontal world position.
## Mirrors the yaw-seeding half of snap_to_spawn (sets _yaw_state, _target_yaw,
## _last_input_direction) but doesn't touch position or camera. Called by
## PlayerBrain after a respawn so the player isn't standing with their back
## to the next objective beacon.
func face_toward(world_pos: Vector3) -> void:
	var to: Vector3 = world_pos - global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return
	var fwd: Vector3 = to.normalized()
	_last_input_direction = fwd
	var yaw: float = Vector3.BACK.signed_angle_to(fwd, Vector3.UP)
	_yaw_state = yaw
	_target_yaw = yaw


## Snap the camera pivot to sit directly behind the character's current
## _yaw_state. Reuses the cam_yaw assignment from snap_to_spawn (lines
## 2143-2147) without the camera_spawn_yaw_offset_deg export — respawn
## doesn't want the off-axis aesthetic spawn offset, it wants the camera
## squared up. Pairs with face_toward() in the respawn flow.
func snap_camera_behind() -> void:
	if _camera_pivot == null:
		return
	if _camera_pivot.top_level:
		_camera_pivot.global_rotation = Vector3(0.0, _yaw_state, 0.0)
	else:
		_camera_pivot.rotation = Vector3(0.0, _yaw_state, 0.0)
	_snap_camera_to_player()


# ---- Save/load (called by SaveService on save / scene_entered) ----------

## Serializes the per-pawn state that can't be reconstructed from flags alone:
## current position (for mid-level saves), last-touched checkpoint (so dying
## on Continue drops you at the phone booth, not the level's default spawn),
## and current health.
func get_save_dict() -> Dictionary:
	var d := {
		"position": [global_position.x, global_position.y, global_position.z],
		"checkpoint": [_start_position.x, _start_position.y, _start_position.z],
		"health": _health,
	}
	print("[player] get_save_dict pos=%s checkpoint=%s" % [global_position, _start_position])
	return d


## Applied by SaveService on scene_entered after a Continue. Overrides the
## Game._spawn_player teleport so the player resumes exactly where the save
## was triggered (checkpoint / flag) with the right checkpoint banked.
func load_save_dict(d: Dictionary) -> void:
	print("[player] load_save_dict incoming=%s pre_pos=%s" % [d, global_position])
	var pos: Variant = d.get("position")
	if pos is Array and (pos as Array).size() == 3:
		global_position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	var cp: Variant = d.get("checkpoint")
	if cp is Array and (cp as Array).size() == 3:
		_start_position = Vector3(float(cp[0]), float(cp[1]), float(cp[2]))
	var h: Variant = d.get("health")
	if h != null:
		var new_health := int(h)
		if new_health != _health:
			var old := _health
			_health = new_health
			health_changed.emit(_health, old)
	velocity = Vector3.ZERO
	print("[player] load_save_dict applied pos=%s checkpoint=%s" % [global_position, _start_position])


func _physics_process(delta: float) -> void:
	# Brain pushes per-tick intent (movement direction, jump/attack edges).
	# Body never touches Input directly — same code path drives player, AI, net.
	var intent: Intent = _brain.tick(self, delta)

	# Non-player skaters: AI brains fire jump_pressed for gap traversal +
	# chase, but on skates the jump pop kills the carve momentum (zeroes
	# tangent velocity through gravity arc). Strip brain-driven jumps so
	# gold allies + hostile skaters keep their speed on the halfpipe.
	# Player is exempt — they need their jump.
	if disable_brain_jump_on_skates and pawn_group != "player" \
			and skate_profile != null and _current_profile == skate_profile:
		intent.jump_pressed = false

	# Betrayal-walk override: substitute Intent so the player loses agency.
	# Used by the betray ending scene (level_5) — slow forced forward, no
	# jump / dash / attack. Body still does animation + camera + skin work
	# normally, just from the substituted Intent.
	if _betrayal_walk_dir.length_squared() > 0.0001:
		var max_speed: float = _current_profile.max_speed if _current_profile != null else 6.0
		var mag: float = clampf(_betrayal_walk_speed / maxf(max_speed, 0.001), 0.0, 1.0)
		intent.move_direction = _betrayal_walk_dir * mag
		intent.jump_pressed = false
		intent.attack_pressed = false
		intent.dash_pressed = false
		intent.crouch_held = false
		intent.interact_pressed = false
		# With speed=0 the body's velocity-based yaw derivation freezes at
		# spawn yaw. Force-face the walk direction via the existing override
		# so the skin lerps to face Splice.
		intent.face_yaw_override = Vector3.BACK.signed_angle_to(_betrayal_walk_dir, Vector3.UP)
		intent.face_yaw_override_set = true

	if _dying:
		_dying_timer -= delta
		velocity.y += _gravity * delta
		move_and_slide()
		_update_follow_camera(delta)
		if _skin != null and _skin.uses_knockback_death:
			_tick_knockback_death(delta)
		if _dying_timer <= 0.0:
			_finish_death()
		return

	_tick_health_regen(delta)
	_tick_damage_tint(delta)
	_try_grab_candidate_rails()

	# Attack: edge-triggered from intent (formerly handled in _input).
	if intent.attack_pressed:
		_start_attack_jostle()

	var profile := _current_profile

	# Dash: edge-triggered, blocked while grinding/wall-riding. Picks a
	# direction from current intent or last-faced direction.
	_update_dash(delta, intent)

	# Crouch: skin callback fires only on press/release (edge dedupe). Walk-
	# only gate is enforced when applying the speed multiplier below.
	if intent.crouch_held != _was_crouched:
		if _skin != null:
			_skin.crouch(intent.crouch_held)
		_was_crouched = intent.crouch_held

	if _grinding:
		_update_grind(delta, profile, intent)
		_update_follow_camera(delta)
		return

	# Move direction comes pre-converted to world-space from the brain.
	# Body applies its own threshold for "is the pawn pushing" logic.
	# Magnitude [0, 1] scales target speed — lets AI wander at 0.3× and chase
	# at 1.0× off the same max_speed config.
	var move_direction: Vector3 = intent.move_direction
	var move_magnitude: float = clampf(move_direction.length(), 0.0, 1.0)
	if move_direction.length() > 0.2:
		_last_input_direction = move_direction.normalized()
	# Main movement code below expects a normalized direction.
	if move_direction.length() > 0.01:
		move_direction = move_direction.normalized()

	# Skin facing. When the brain sets intent.face_yaw_override_set, that
	# value wins — lets a brain rotate the pawn during stationary phases
	# (e.g., stealth patrol's "stop and look side-to-side") where the
	# velocity-tracking default would freeze yaw because h_vel < 0.5.
	# Otherwise: existing path — face the velocity direction when moving,
	# else keep facing _last_input_direction.
	var h_vel := Vector3(velocity.x, 0.0, velocity.z)
	var target_angle: float
	if intent.face_yaw_override_set:
		target_angle = intent.face_yaw_override
	else:
		var face_target := _last_input_direction
		if profile.face_velocity and h_vel.length() > 0.5:
			face_target = h_vel.normalized()
		target_angle = Vector3.BACK.signed_angle_to(face_target, Vector3.UP)
	var new_yaw: float = lerp_angle(_yaw_state, target_angle, profile.rotation_speed * delta)
	_yaw_state = new_yaw

	# Body lean: forward tilt scales with speed; side roll scales with
	# angular turn rate × speed (centripetal force feel).
	var d_yaw: float = wrapf(new_yaw - _prev_skin_yaw, -PI, PI) / max(delta, 0.0001)
	_prev_skin_yaw = new_yaw
	_prev_h_vel = h_vel
	var speed: float = h_vel.length()
	# Walk-mode footstep cadence + Run-cycle time scale, both driven by the
	# same h_speed/max_speed ratio so visuals and audio stay in lockstep. Skip
	# in skate mode (silent + no time scaling).
	_tick_walk_audio_visual(delta, speed, profile)
	# Startup sway: side-to-side rocking for the first couple seconds of motion.
	var is_moving: bool = speed > 0.5
	if is_moving and not _was_moving:
		_speedup_timer = 0.0
		_sway_phase = 0.0
	if is_moving:
		_speedup_timer += delta
	_was_moving = is_moving
	var speedup_roll := 0.0
	if is_moving:
		var amp: float = profile.cruise_sway_amplitude
		if _speedup_timer < profile.speedup_duration:
			var t: float = _speedup_timer / max(profile.speedup_duration, 0.001)
			amp = lerpf(profile.speedup_amplitude, profile.cruise_sway_amplitude, t)
		# Pendulum rate tracks body speed (same speed/max ratio the anim
		# scale uses): slow glide = slow rock, full speed = authored
		# frequency. Phase is ACCUMULATED (not sin(f·t)) so a changing
		# ratio bends the oscillation smoothly instead of popping.
		var sway_ratio: float = clampf(speed / maxf(profile.max_speed, 0.001), 0.0, 1.0)
		_sway_phase += TAU * profile.speedup_frequency * sway_ratio * delta
		speedup_roll = amp * sin(_sway_phase)
	# Kill the sway while airborne (jumps read clean) and while crouched
	# (a sneaking body doesn't rock).
	if not is_on_floor() or intent.crouch_held:
		speedup_roll = 0.0
	var target_pitch: float = clamp(-speed * profile.forward_lean_amount, -0.6, 0.6)
	# Smooth the lean/centripetal components only. Sway is applied unsmoothed
	# on top so the oscillation isn't damped out by lean_smoothing.
	var centripetal_roll: float = clamp(-d_yaw * speed * profile.side_lean_amount, -0.6, 0.6)
	var lean_factor := 1.0 - exp(-profile.lean_smoothing * delta)
	_current_lean_pitch = lerp(_current_lean_pitch, target_pitch, lean_factor)
	_current_lean_roll = lerp(_current_lean_roll, centripetal_roll, lean_factor)

	# Brake impulse: fire a one-shot reversed-lean the instant movement input
	# is released at speed; exp-decay back to zero. "Pressing forward" in the
	# world-space intent model means "movement intent has magnitude" —
	# releasing all keys drops move_direction to zero.
	var pressing_forward: bool = intent.move_direction.length() > 0.2
	if _was_pressing_forward and not pressing_forward and speed > 1.0:
		_brake_impulse = profile.brake_impulse_amount
	_was_pressing_forward = pressing_forward
	_brake_impulse = lerp(_brake_impulse, 0.0, 1.0 - exp(-profile.brake_impulse_decay * delta))

	# Procedural attack "jostle": additive forward pitch that peaks mid-swing
	# and decays, so the attack reads without touching the animation state.
	var attack_pitch := 0.0
	if _attack_timer > 0.0 and _attack_duration > 0.0:
		var p: float = 1.0 - _attack_timer / _attack_duration
		attack_pitch = sin(p * PI) * attack_lunge_pitch

	# Lean is scaled by the active skin — Sophia leans dramatically, cops
	# stiffer. Null skin (shouldn't happen for a valid pawn) falls back to 1.
	var lean_mult: float = _skin.lean_multiplier if _skin != null else 1.0
	# Wall-ride lean: tilt the skin INTO the wall by the side it's on.
	# `_wall_normal` points away from the wall; dotting against the player's
	# local +X (right) gives sign — negative when wall is on the right (lean
	# right) and positive when wall is on the left. Stacks atop the regular
	# centripetal roll so a curved wall-ride still reads.
	var wall_ride_roll: float = 0.0
	if _wall_ride_active:
		var player_right: Vector3 = Basis(Vector3.UP, new_yaw) * Vector3.RIGHT
		wall_ride_roll = _wall_normal.dot(player_right) * profile.wall_ride_lean_amount
	var final_pitch: float = (_current_lean_pitch + _brake_impulse + attack_pitch) * lean_mult
	var final_roll: float = (_current_lean_roll + speedup_roll + wall_ride_roll) * lean_mult

	# Rotate the skin around a head-height pivot: the basis holds yaw+pitch+roll,
	# and we shift the skin's origin so the pivot point stays fixed in space.
	# Pivot height is per-skin, not per-movement-profile — different character
	# proportions need different lean pivots.
	var pivot: Vector3 = Vector3(0, _skin.lean_pivot_height, 0)
	var tilt_basis: Basis = Basis(Vector3.RIGHT, final_pitch) * Basis(Vector3.BACK, final_roll)
	var full_basis: Basis = Basis(Vector3.UP, new_yaw) * tilt_basis
	# Halfpipe tilt: align the skin's UP toward the curve surface normal,
	# weighted by curve_factor (0 at trough = no change, 1 at vertical wall =
	# full lean against wall). Re-orthogonalizes around the new up so forward
	# stays roughly forward. Skipped entirely when not on a curve surface.
	if _on_halfpipe and _halfpipe_curve_factor > 0.0:
		var current_up: Vector3 = full_basis.y
		var blend_up: Vector3 = current_up.lerp(_halfpipe_normal, _halfpipe_curve_factor)
		if blend_up.length_squared() > 0.0001:
			blend_up = blend_up.normalized()
			var fwd: Vector3 = full_basis.z
			fwd = fwd - blend_up * fwd.dot(blend_up)
			if fwd.length_squared() > 0.0001:
				fwd = fwd.normalized()
				var right: Vector3 = blend_up.cross(fwd).normalized()
				full_basis = Basis(right, blend_up, fwd)
	# Pivot-compensation offset uses the UNSCALED rotation basis, otherwise
	# scale gets multiplied into the pivot and drops the skin below the floor.
	var origin_offset: Vector3 = pivot - full_basis * pivot
	var tilt_magnitude: float = sqrt(final_pitch * final_pitch + final_roll * final_roll)
	origin_offset.y -= tilt_magnitude * profile.tilt_height_drop
	# Speed lift: counteract the foot-sinks-into-floor side effect of the
	# forward pitch when running fast. Scales 0..1 with speed/max_speed and
	# is applied only on_floor (airborne skin offset stays identity).
	if profile.forward_speed_lift > 0.0 and is_on_floor():
		var max_s: float = maxf(profile.max_speed, 0.001)
		var speed_factor: float = clamp(speed / max_s, 0.0, 1.0)
		origin_offset.y += speed_factor * profile.forward_speed_lift
	# Halfpipe wall lift: when the skin tilts to match a vertical-ish wall,
	# its local feet (at -Y) rotate to face INTO the wall. Push the skin
	# back along the normal by curve_factor × halfpipe_skin_wall_lift so the
	# visual feet sit on the surface instead of inside it.
	if _on_halfpipe and _halfpipe_curve_factor > 0.0 and halfpipe_skin_wall_lift > 0.0:
		origin_offset += _halfpipe_normal * halfpipe_skin_wall_lift * _halfpipe_curve_factor
	# Scale is applied AFTER the offset is fixed — visuals only, no translation.
	var skin_scale: float = _skin.uniform_scale if _skin != null else 1.0
	if not is_equal_approx(skin_scale, 1.0):
		full_basis = full_basis.scaled(Vector3.ONE * skin_scale)
	_skin.transform = Transform3D(full_basis, origin_offset)

	# Double-jump front flip: spin 360° around a horizontal axis snapshotted
	# at jump time, pivoting at body center.
	if _flip_timer > 0.0:
		_flip_timer = maxf(0.0, _flip_timer - delta)
		var progress: float = 1.0 - (_flip_timer / _flip_duration)
		var flip_angle: float = progress * TAU
		var flip_rot := Basis(_flip_axis, flip_angle)
		var flip_pivot := Vector3(0, _skin.body_center_y, 0)
		var t: Transform3D = _skin.transform
		var new_basis: Basis = flip_rot * t.basis
		var new_origin: Vector3 = flip_pivot + flip_rot * (t.origin - flip_pivot)
		_skin.transform = Transform3D(new_basis, new_origin)

	# Halfpipe-stick probe (player + gold-ally only). Sets _on_halfpipe and
	# applies adhesion + speed boost. No-op when the master toggles are
	# false. Runs before the jump impulse so the curve-jump override below
	# can read _on_halfpipe.
	_update_halfpipe_stick(delta, intent)

	# Horizontal movement.
	var y_velocity := velocity.y
	var on_floor := is_on_floor()
	var air_mult := 1.0 if on_floor else profile.air_accel_mult
	var accel_now := profile.accel * air_mult
	# Stroke pulse: thrust surges with each sway extreme (push-off) and
	# slackens through center (glide). Same _sway_phase that drives the roll
	# and the stride SFX — one stroke clock, three outputs. Floor-only:
	# airborne there's nothing to push against.
	if on_floor and profile.stroke_accel_pulse > 0.0:
		accel_now *= 1.0 + profile.stroke_accel_pulse * (absf(sin(_sway_phase)) * 2.0 - 1.0)
	var friction_now := profile.friction * air_mult

	if intent.hard_brake:
		# Brain requested instant horizontal stop — bypasses both accel and
		# friction branches. Used by AI at ledges where friction-rate decay
		# can't stop a fast pawn (e.g. red 2.5×) before sliding off.
		h_vel = Vector3.ZERO
	elif move_direction.length() > 0.01:
		var h_dir := h_vel.normalized() if h_vel.length() > 0.1 else move_direction
		var steered := h_dir.slerp(move_direction, clamp(profile.turn_rate * delta, 0.0, 1.0))
		# Crouch / sneak slows the player in EITHER profile (the post-hacking
		# sneak mechanic engages while the player's still on skates from L1).
		# Skin's crouch state plays the same Crouching pose either way.
		var crouch_mult := 1.0
		if intent.crouch_held and is_on_floor():
			crouch_mult = profile.crouch_speed_multiplier
		# Halfpipe boost: when on a curve surface, max horizontal speed is
		# multiplied so the player can build skate momentum. Off the curve,
		# multiplier is 1.0 → no behavior change.
		var hp_speed_mult: float = halfpipe_max_speed_multiplier if _on_halfpipe else 1.0
		var target_vel := steered * profile.max_speed * move_magnitude * crouch_mult * _faction_speed_mult * hp_speed_mult
		# Halfpipe carve fix: when the player is on the curve AND pressing in
		# the direction of motion, input must never decelerate them — the
		# halfpipe boost (speed_boost / centripetal / gravity-along-tangent)
		# can push h_vel above target_vel.length() and move_toward would then
		# pull them BACK down toward the input ceiling. Bug felt as "pressing
		# forward makes me slower than coasting." Fix: when aligned, the
		# effective target along the input direction is at least the current
		# aligned speed, so move_toward only ever steers + accelerates.
		var effective_target: Vector3 = target_vel
		if _on_halfpipe and target_vel.length_squared() > 0.0001:
			var input_dir: Vector3 = target_vel.normalized()
			var aligned_speed: float = h_vel.dot(input_dir)
			if aligned_speed > target_vel.length():
				effective_target = input_dir * aligned_speed
		h_vel = h_vel.move_toward(effective_target, accel_now * delta)
	else:
		# Halfpipe wall escape: when engaged on a curve steeper than the
		# trough, skip horizontal friction so gravity-along-surface
		# (g·sin(θ)) can actually slide the body. Without this, friction
		# zeros the slide every tick and the player stands glued to a
		# vertical wall. Trough (curve ≈ 0) still gets full friction so
		# you don't coast forever on flat ground.
		var on_halfpipe_wall: bool = _on_halfpipe and _halfpipe_curve_factor > 0.1
		if not on_halfpipe_wall:
			# Trough friction scale: when engaged on the curve but down at the
			# trough (curve_factor < 0.1), the wall friction-skip above doesn't
			# fire, so normal-ground friction was killing the wall-to-wall
			# coast. Scale it down (or off) only while on the pipe.
			var effective_friction: float = friction_now
			if _on_halfpipe:
				effective_friction *= halfpipe_trough_friction_scale
			h_vel = h_vel.move_toward(Vector3.ZERO, effective_friction * delta)
			if profile.stopping_speed > 0.0 and h_vel.length_squared() < profile.stopping_speed * profile.stopping_speed:
				h_vel = Vector3.ZERO

	velocity = Vector3(h_vel.x, y_velocity + _gravity * delta, h_vel.z)
	# Halfpipe kinematic redirect/align — no-op unless engaged AND the
	# active pass raised the flags this tick. All behavior change is
	# gated on _on_halfpipe, so flat-ground / normal-skate is untouched.
	_apply_halfpipe_post_pipeline(delta)

	# Animations and FX.
	if on_floor:
		_air_jump_available = true
		_coyote_timer = profile.coyote_time
	else:
		_coyote_timer = maxf(0.0, _coyote_timer - delta)
	var ground_speed := Vector2(velocity.x, velocity.z).length()
	# Coyote: count a jump press shortly after stepping off a ledge as a
	# ground jump. Order matters — is_just_jumping is checked FIRST in the
	# branch below so an air jump never fires during the grace window.
	var in_coyote: bool = _coyote_timer > 0.0
	var jump_suppressed: bool = (Time.get_ticks_msec() / 1000.0) < _jump_suppressed_until
	var is_just_jumping := (intent.jump_pressed and not jump_suppressed
		and (on_floor or in_coyote))
	var is_air_jumping := (intent.jump_pressed and not jump_suppressed
		and not is_just_jumping
		and not on_floor and _air_jump_available and not _wall_ride_active)

	# Attack jostle is purely procedural (velocity kick + skin pitch) so we
	# just let the timer tick down — no animation state to enter/exit.
	if _attack_timer > 0.0:
		_attack_timer = maxf(0.0, _attack_timer - delta)
	# Active swing window: re-sweep each frame so the forward lunge can
	# catch enemies the initial press missed.
	if _attack_active_timer > 0.0:
		_attack_active_timer = maxf(0.0, _attack_active_timer - delta)
		_sweep_attack()
	if _attack_visual_timer > 0.0:
		_attack_visual_timer = maxf(0.0, _attack_visual_timer - delta)

	if is_just_jumping:
		# Halfpipe override: launch off the surface NORMAL instead of straight
		# up, so jumping the lip of a halfpipe sends you outward (real skater
		# physics). Cooldown prevents instant re-snap. When _on_halfpipe is
		# false, this branch is skipped — regular up-impulse below runs.
		if _on_halfpipe:
			var curve_impulse: float = profile.jump_impulse * (1.0 + _halfpipe_curve_factor)
			print("[halfpipe] JUMP     body=%s pawn=%s jump_pressed=%s on_floor=%s curve=%.2f v_in=%s" %
				[name, pawn_group, intent.jump_pressed, on_floor, _halfpipe_curve_factor, velocity])
			# Blend world-up with surface normal: 0.0 = pure vertical, 1.0 =
			# pure normal. A vertical wall still kicks slightly outward; a
			# gentle slope is essentially straight up.
			var jump_dir: Vector3 = Vector3.UP.lerp(_halfpipe_normal, halfpipe_jump_blend).normalized()
			# Momentum-preserving jump: keep the carve velocity that's parallel
			# to the surface (your "tangent speed") and ADD the jump impulse.
			# The old `velocity = jump_dir * curve_impulse` zeroed all prior
			# motion — jumping mid-carve felt like a dead stop. Now you fly
			# off the lip with your speed intact + the pop on top.
			var tangent_vel: Vector3 = velocity - _halfpipe_normal * velocity.dot(_halfpipe_normal)
			velocity = tangent_vel + jump_dir * curve_impulse
			_halfpipe_jump_timer = halfpipe_jump_cooldown_s
			# Disengage cleanly so floor_max_angle restores.
			_halfpipe_disengage()
			if pawn_group == "player":
				_jump_sound.play()
			_coyote_timer = 0.0
		# Coyote case: player has been falling, velocity.y is negative. Reset
		# (not add) so the jump reads as full-strength, like a true ground
		# jump from a standing start. Ground case: velocity.y ≈ 0 so behavior
		# is unchanged.
		elif on_floor:
			velocity.y += profile.jump_impulse
			if pawn_group == "player":
				_jump_sound.play()
			_coyote_timer = 0.0
		else:
			velocity.y = profile.jump_impulse
			if pawn_group == "player":
				_jump_sound.play()
			_coyote_timer = 0.0
	elif is_air_jumping:
		velocity.y = profile.jump_impulse
		if pawn_group == "player":
			_jump_sound.play()
		_air_jump_available = false
		_flip_axis = (Basis(Vector3.UP, new_yaw) * Vector3.RIGHT).normalized()
		_flip_timer = _flip_duration

	# One-shot states (dash, crouch, attack) must not be overwritten by the
	# per-frame idle/move/fall/jump travel calls. Gate here so the skin's
	# state machine can hold the pose until the body signals exit. Dash uses
	# the LONGER `_dash_visual_timer` so the Sprinting Forward Roll plays
	# through its apex even after the gameplay impulse + i-frames end.
	var is_visual_dashing := _dash_visual_timer > 0.0
	var is_crouching_now := intent.crouch_held and on_floor
	var is_attacking_now := _attack_visual_timer > 0.0
	if not _wall_ride_active and not is_visual_dashing and not is_attacking_now:
		if is_just_jumping or is_air_jumping:
			_skin.jump()
		elif not on_floor and velocity.y < 0 and not _on_halfpipe:
			# Halfpipe suppression: while engaged on a curve, snap-misses and
			# wall-tangential motion routinely flip is_on_floor() false even
			# though the stick system is keeping the body on the surface.
			# Showing Fall in that case is the rig lying about its state.
			_skin.fall()
		elif on_floor:
			# Crouch routes to crouch_move() while moving so the skin can play
			# Crouched Walking; idle-crouch holds Crouching Idle. Skins without
			# a CrouchMove state inherit the base default that forwards to
			# move(), so feet still animate instead of freezing.
			# Deadzone: physics-jitter (collisions, slope friction, pushback)
			# bounces velocity around 0 by ~0.001-0.05 m/s. Strict `> 0.0`
			# flips Move↔Idle every frame for AI bodies stuck against a wall
			# or in mid-zone follow hysteresis. 0.15 m/s is well below any
			# real movement (walk ≈ 3 m/s) but above the jitter floor.
			# Halfpipe idle/coast gate: while engaged, the carve can keep
			# the body moving fast even with zero input. Three states now:
			#   - input + moving → Move at authored speed
			#   - no input + moving → Move slowed by halfpipe_coast_anim_scale
			#     (relaxed coast; set to 0 to fall back to Idle pose)
			#   - no input + ground_speed ~ 0 → Idle
			# Off-halfpipe behavior is unchanged (speed-based as before).
			var is_visually_moving: bool = ground_speed > _MOVE_IDLE_DEADZONE
			var is_halfpipe_coasting: bool = false
			if _on_halfpipe:
				var has_input: bool = intent.move_direction.length() > 0.1
				if has_input:
					is_visually_moving = true
				elif ground_speed > _MOVE_IDLE_DEADZONE and halfpipe_coast_anim_scale > 0.0:
					is_visually_moving = true
					is_halfpipe_coasting = true
				else:
					is_visually_moving = false
			if is_crouching_now:
				if is_visually_moving:
					_skin.crouch_move()
				else:
					_skin.crouch(true)
			elif is_visually_moving:
				_skin.move()
				if is_halfpipe_coasting:
					# Overrides the 1.0 set by _tick_walk_audio_visual a few
					# lines up (we're in skate mode so that path went to the
					# else branch). Later overwrite = wins this frame.
					_skin.set_walk_speed_scale(halfpipe_coast_anim_scale)
			else:
				_skin.idle()

	# Ground dust — body decides "should it emit" (needs ground/speed/crouch
	# state), skin decides "from where" (emitter lives in skin-local space
	# so the offset auto-tracks yaw without extra math).
	_skin.set_dust_emitting(on_floor && ground_speed > _MOVE_IDLE_DEADZONE && not intent.crouch_held)

	if on_floor and not _was_on_floor_last_frame:
		if pawn_group == "player":
			_landing_sound.stream = _LAND_SOUNDS[_land_idx]
			_land_idx = (_land_idx + 1) % _LAND_SOUNDS.size()
			_landing_sound.play()
		# Skip the Land state visual if a one-shot is currently holding the
		# skin (attack, dash). The attack lunge adds an upward hop which
		# immediately tripped this branch and clobbered the kick clip; same
		# would happen for any one-shot that briefly leaves the floor.
		if _skin != null and not is_attacking_now and not is_visual_dashing:
			_skin.land()

	# Wall ride (only runs if the current profile enables it).
	if profile.wall_ride_duration > 0.0:
		_update_wall_ride(delta, profile, intent)

	_was_on_floor_last_frame = on_floor
	move_and_slide()
	_slide_off_enemy_head()

	_update_follow_camera(delta)


## Push this pawn horizontally off any OTHER pawn it's currently standing on.
## Symmetric: player-on-enemy AND enemy-on-player both fire, since every pawn
## runs this body script. Iterates this tick's slide collisions; if any contact
## has a roughly-upward normal AND the collider is a different CharacterBody3D
## pawn, override horizontal velocity to point away from that pawn. Vertical
## velocity is untouched (jumping off still works). Skipped entirely if
## `enemy_head_slide_speed` is 0 — designer can disable per-pawn or globally.
func _slide_off_enemy_head() -> void:
	if enemy_head_slide_speed <= 0.0:
		return
	for i in get_slide_collision_count():
		var col: KinematicCollision3D = get_slide_collision(i)
		if col == null: continue
		var collider: Object = col.get_collider()
		# Any other CharacterBody3D pawn — covers player, enemies, allies.
		# Excludes static/rigid geometry and self.
		if not (collider is CharacterBody3D) or collider == self:
			continue
		if col.get_normal().dot(Vector3.UP) < 0.5:
			continue  # not standing on top — side contact, ignore
		var other_node := collider as Node3D
		if other_node == null: continue
		var away: Vector3 = global_position - other_node.global_position
		away.y = 0.0
		if away.length() < 0.01:
			# Degenerate (perfectly stacked) — pick last input direction or arbitrary.
			away = _last_input_direction if _last_input_direction.length() > 0.01 else Vector3.RIGHT
		away = away.normalized()
		velocity.x = away.x * enemy_head_slide_speed
		velocity.z = away.z * enemy_head_slide_speed
		return  # one slide-off per tick is plenty


func _update_grind(delta: float, profile: MovementProfile, intent: Intent) -> void:
	if _grind_rail == null or not is_instance_valid(_grind_rail):
		_grinding = false
		return
	var pf: PathFollow3D = _grind_rail.get_node_or_null("PathFollow3D") as PathFollow3D
	if pf == null or _grind_rail.curve == null:
		_grinding = false
		return
	_grind_progress += profile.grind_speed * _grind_direction * delta
	var length: float = _grind_rail.curve.get_baked_length()
	var exit_end: bool = _grind_progress >= length or _grind_progress <= 0.0
	var jump_suppressed: bool = (Time.get_ticks_msec() / 1000.0) < _jump_suppressed_until
	var jumped: bool = intent.jump_pressed and not jump_suppressed
	pf.progress = clamp(_grind_progress, 0.0, length)
	# Smoothly lerp the character onto the rail over ~0.2s instead of snapping.
	# Ease-out curve so the approach feels smooth, not abrupt at the end.
	_grind_snap_t = minf(_grind_snap_t + delta / 0.35, 1.0)
	var eased: float = 1.0 - pow(1.0 - _grind_snap_t, 3.0)
	global_position = _grind_start_pos.lerp(pf.global_position, eased)
	var tangent: Vector3 = -pf.global_transform.basis.z * _grind_direction
	velocity = tangent * profile.grind_speed
	# Track curvature in rail-direction space (independent of the body's
	# sideways offset) so banking keys off the actual rail bend, not body yaw.
	var tangent_yaw: float = Vector3.BACK.signed_angle_to(tangent, Vector3.UP)
	var d_yaw: float = wrapf(tangent_yaw - _prev_skin_yaw, -PI, PI) / max(delta, 0.0001)
	_prev_skin_yaw = tangent_yaw
	# Natural centripetal lean — smoothed in its own tracked variable so the
	# counter input (applied later) can't artificially push us past the fall
	# threshold or mask a real fall.
	var centripetal: float = d_yaw * profile.grind_speed * profile.side_lean_amount * profile.grind_lean_multiplier
	var lean_factor: float = 1.0 - exp(-profile.lean_smoothing * delta)
	_natural_lean_roll = lerp(_natural_lean_roll, centripetal, lean_factor)
	_current_lean_pitch = lerp(_current_lean_pitch, 0.0, lean_factor)

	# Park sparks at the rail contact point and orient -Z along the travel
	# tangent so the local +Z emission axis (set in ProcMat) flows backward.
	if _grind_sparks != null:
		_grind_sparks.global_position = pf.global_position
		if absf(tangent.dot(Vector3.UP)) < 0.99:
			_grind_sparks.look_at(pf.global_position + tangent, Vector3.UP)

	_tick_grind_loop()

	# Player counter-balance: project world-space move intent onto the camera's
	# right axis so keyboard "A/D" gives the expected screen-relative lean.
	# AI pawns have _camera freed (see _ready), so skip — they have no
	# screen-relative input and the natural lean alone is fine.
	var balance_x: float = 0.0
	if _camera != null:
		var cam_right: Vector3 = _camera.global_basis.x
		balance_x = intent.move_direction.dot(cam_right)
	_current_lean_roll = clamp(_natural_lean_roll - balance_x * profile.grind_counter_strength * delta, -1.5, 1.5)


	# Build orientation: 1) face rail direction, 2) bank around rail tangent,
	# 3) rotate sideways around banked up (skater-style body offset).
	var rail_frame: Basis = Basis(Vector3.UP, tangent_yaw)
	var rail_forward: Vector3 = rail_frame * Vector3.FORWARD
	var banked: Basis = Basis(rail_forward, _current_lean_roll) * rail_frame
	var body_up: Vector3 = banked * Vector3.UP
	var full_basis: Basis = Basis(body_up, deg_to_rad(profile.grind_yaw_offset_deg)) * banked
	var grind_scale: float = _skin.uniform_scale if _skin != null else 1.0
	if not is_equal_approx(grind_scale, 1.0):
		full_basis = full_basis.scaled(Vector3.ONE * grind_scale)
	# Feet pivot so the body rotates like someone actually balancing on the rail.
	_skin.transform = Transform3D(full_basis, Vector3.ZERO)
	# Drive move_and_slide so render interpolation smooths visuals between ticks.
	move_and_slide()
	# Once snapped on, keep locked to the curve. During the entry lerp we let
	# the interpolated position win so the approach is smooth.
	if _grind_snap_t >= 1.0:
		global_position = pf.global_position
	if exit_end or jumped:
		if jumped:
			velocity += Vector3.UP * (profile.jump_impulse + profile.grind_exit_boost)
		_grinding = false
		_grind_rail = null
		_rail_regrab_block_until = Time.get_ticks_msec() / 1000.0 + rail_regrab_cooldown
		if _grind_sparks != null:
			_grind_sparks.emitting = false
		_stop_grind_loop()


# Crossfade-loop helpers — see `_grind_sound_active` / `_GRIND_OVERLAP_S`
# above. Two AudioStreamPlayer3Ds ping-pong the same clip; the next one
# starts when the active one is `_GRIND_OVERLAP_S` from finishing, so their
# tail/head overlap masks the seam. Stop kills both regardless of state.
func _start_grind_loop() -> void:
	if _grind_sound == null:
		return
	if _grind_sound_length <= 0.0 and _grind_sound.stream != null:
		_grind_sound_length = _grind_sound.stream.get_length()
	_grind_sound.stop()
	if _grind_sound_b != null:
		_grind_sound_b.stop()
	_grind_sound.play()
	_grind_sound_active = _grind_sound


func _tick_grind_loop() -> void:
	if _grind_sound_active == null or _grind_sound_length <= 0.0:
		return
	var pos: float = _grind_sound_active.get_playback_position()
	if pos < _grind_sound_length - _GRIND_OVERLAP_S:
		return
	var other: AudioStreamPlayer3D = _grind_sound_b if _grind_sound_active == _grind_sound else _grind_sound
	if other == null or other.playing:
		return
	other.play()
	_grind_sound_active = other


func _stop_grind_loop() -> void:
	if _grind_sound != null:
		_grind_sound.stop()
	if _grind_sound_b != null:
		_grind_sound_b.stop()
	_grind_sound_active = null


## Dash: velocity impulse along move_direction. Edge-triggered off the
## dash_pressed intent; cooldown-gated; blocked during grind / wall-ride.
## Grants a brief i-frame window via the shared _invuln_until_time timer.
func _update_dash(delta: float, intent: Intent) -> void:
	_dash_cooldown_timer = maxf(0.0, _dash_cooldown_timer - delta)
	_dash_timer = maxf(0.0, _dash_timer - delta)
	_dash_visual_timer = maxf(0.0, _dash_visual_timer - delta)
	# Fire on edge if cooldown elapsed and not currently in a locked state.
	if intent.dash_pressed and _dash_cooldown_timer <= 0.0 and _dash_timer <= 0.0 and not _grinding and not _wall_ride_active and not _dying:
		var dir := intent.move_direction if intent.move_direction.length() > 0.2 else _last_input_direction
		if dir.length_squared() > 0.0001:
			_dash_direction = dir.normalized()
		else:
			_dash_direction = -global_basis.z
		_dash_direction.y = 0.0
		_dash_timer = dash_duration
		_dash_cooldown_timer = dash_cooldown
		# Grant i-frames via the shared invuln window.
		var now: float = Time.get_ticks_msec() / 1000.0
		_invuln_until_time = maxf(_invuln_until_time, now + dash_iframes_duration)
		# Roll plays whether we're grounded or airborne — the visual timer
		# also gates routing so jump/fall won't clobber the roll mid-flight.
		_dash_visual_timer = dash_visual_duration
		if _skin != null:
			_skin.dash(_dash_direction)
	# While active, override horizontal velocity to the dash vector. Air
	# dash applies an extra reach multiplier so the in-air burst clears
	# bigger gaps without changing dash_duration. dash_preserves_y keeps
	# jump / fall momentum intact.
	if _dash_timer > 0.0:
		var speed: float = dash_speed
		if not is_on_floor():
			speed *= air_dash_speed_multiplier
		velocity.x = _dash_direction.x * speed
		velocity.z = _dash_direction.z * speed
		if not dash_preserves_y:
			velocity.y = 0.0


func _update_wall_ride(delta: float, profile: MovementProfile, intent: Intent) -> void:
	var horizontal_speed: float = Vector2(velocity.x, velocity.z).length()

	if _wall_ride_active:
		_wall_ride_timer += delta
		var detected: Vector3 = _find_wall(profile)
		var lost_contact: bool = detected == Vector3.ZERO
		var too_slow: bool = horizontal_speed < profile.wall_ride_min_speed * 0.5
		var expired: bool = _wall_ride_timer >= profile.wall_ride_duration
		var jumped: bool = intent.jump_pressed
		if lost_contact or too_slow or expired or jumped:
			if jumped:
				velocity += _wall_normal * profile.wall_ride_jump_push
				velocity.y = profile.jump_impulse
			_wall_ride_active = false
			return
		_wall_normal = detected
		# Scale gravity (we undo the physics_process gravity for this frame and
		# re-apply the scaled version).
		velocity.y -= _gravity * delta
		velocity.y += _gravity * profile.wall_ride_gravity_scale * delta
		# Strip any velocity component pushing into the wall so we slide along it.
		var into_wall: float = velocity.dot(_wall_normal)
		if into_wall < 0.0:
			velocity -= _wall_normal * into_wall
	else:
		if is_on_floor():
			return
		if horizontal_speed < profile.wall_ride_min_speed:
			return
		var detected: Vector3 = _find_wall(profile)
		if detected != Vector3.ZERO:
			_wall_ride_active = true
			_wall_ride_timer = 0.0
			_wall_normal = detected
			_skin.wall_slide()


func _find_wall(profile: MovementProfile) -> Vector3:
	var h_vel := Vector3(velocity.x, 0.0, velocity.z)
	if h_vel.length() < 0.1:
		return Vector3.ZERO
	var forward: Vector3 = h_vel.normalized()
	var right: Vector3 = forward.cross(Vector3.UP).normalized()
	var space := get_world_3d().direct_space_state
	var from: Vector3 = global_position + Vector3(0, 1.0, 0)
	for side: Vector3 in [right, -right]:
		var query := PhysicsRayQueryParameters3D.create(from, from + side * profile.wall_ride_reach)
		query.exclude = [self.get_rid()]
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty():
			var n: Vector3 = hit["normal"]
			var max_normal_y: float = sin(deg_to_rad(profile.wall_ride_max_tilt_deg))
			if absf(n.y) < max_normal_y:
				return n
	return Vector3.ZERO


var _dbg_last_active_cam: Camera3D = null


func _process(delta: float) -> void:
	# Camera-attaches-to-enemy debug. Player-side only (one tracker on the
	# player's body, not every pawn). Logs only when the active camera
	# changes — silent when stable. On switch, also enumerates every
	# Camera3D in the tree with current=true so we know exactly who's vying.
	if pawn_group == "player":
		var cur_cam: Camera3D = get_viewport().get_camera_3d()
		if cur_cam != _dbg_last_active_cam:
			var cur_path: String = cur_cam.get_path() if cur_cam != null else "<none>"
			var prev_path: String = _dbg_last_active_cam.get_path() if _dbg_last_active_cam != null and is_instance_valid(_dbg_last_active_cam) else "<none>"
			print("[cam-dbg] viewport switched: %s → %s" % [prev_path, cur_path])
			# Enumerate every Camera3D in the tree, mark which has current=true.
			var all_cams: Array = []
			_dbg_collect_cameras(get_tree().root, all_cams)
			for c in all_cams:
				print("[cam-dbg]   cam=%s current=%s" % [c.get_path(), c.current])
			_dbg_last_active_cam = cur_cam
	# Smooth SpringArm's snap. SpringArm scales the camera's positive local Z by
	# (hit_length / spring_length) each physics tick; we lerp toward that same
	# scaled target and write it back in _process so ours is the final write.
	if _spring == null or _camera == null:
		return
	if _spring.spring_length <= 0.0:
		return
	var motion_delta: float = clamp(_spring.get_hit_length() / _spring.spring_length, 0.0, 1.0)
	var target_z: float = max(_camera_original_z * motion_delta, min_camera_distance)
	var factor := 1.0 - exp(-spring_smooth_rate * delta)
	_current_camera_z = lerp(_current_camera_z, target_z, factor)
	_camera.position.z = _current_camera_z


func _dbg_collect_cameras(n: Node, out: Array) -> void:
	if n is Camera3D:
		out.append(n)
	for child in n.get_children():
		_dbg_collect_cameras(child, out)


func _register_debug_panel() -> void:
	# Halfpipe knobs are registered on the always-visible HalfpipeTuner
	# autoload (see _register_halfpipe_tuner below). Tuning is done as of
	# 2026-05-20 — autoload is commented out in project.godot, so the
	# registration call is too. Uncomment both to re-enable the panel.
	# _register_halfpipe_tuner()
	pass
	DebugPanel.add_enum("Camera/Follow/mode", PackedStringArray(["PARENTED", "DETACHED"]),
		func() -> int: return int(follow_mode),
		func(v: int) -> void:
			follow_mode = FollowMode.PARENTED if v == 0 else FollowMode.DETACHED
			_apply_follow_mode(),
		"player_body.gd")
	DebugPanel.add_slider("Camera/Follow/angle_smoothing", 0.001, 0.3, 0.001,
		func() -> float: return angle_smoothing,
		func(v: float) -> void: angle_smoothing = v,
		"player_body.gd")
	DebugPanel.add_slider("Camera/Follow/position_smoothing", 0.001, 0.3, 0.001,
		func() -> float: return position_smoothing,
		func(v: float) -> void: position_smoothing = v,
		"player_body.gd")
	DebugPanel.add_slider("Camera/Follow/pivot_offset_y", 0.0, 5.0, 0.05,
		func() -> float: return pivot_offset.y,
		func(v: float) -> void:
			var o := pivot_offset
			o.y = v
			pivot_offset = o,
		"player_body.gd")
	DebugPanel.add_slider("Camera/SpringArm/length", 1.0, 25.0, 0.1,
		func() -> float: return _spring.spring_length,
		func(v: float) -> void: _spring.spring_length = v,
		"player_body.gd")
	DebugPanel.add_slider("Camera/SpringArm/smooth_rate", 0.5, 30.0, 0.1,
		func() -> float: return spring_smooth_rate,
		func(v: float) -> void: spring_smooth_rate = v,
		"player_body.gd")
	DebugPanel.add_slider("Camera/SpringArm/margin", 0.0, 3.0, 0.05,
		func() -> float: return _spring.margin,
		func(v: float) -> void:
			_spring.margin = v
			spring_margin = v,
		"player_body.gd")
	DebugPanel.add_slider("Camera/SpringArm/cast_radius", 0.05, 1.0, 0.05,
		func() -> float: return spring_cast_radius,
		func(v: float) -> void:
			spring_cast_radius = v
			if _spring.shape is SphereShape3D:
				(_spring.shape as SphereShape3D).radius = v,
		"player_body.gd")
	DebugPanel.add_slider("Camera/SpringArm/min_distance", 0.0, 10.0, 0.1,
		func() -> float: return min_camera_distance,
		func(v: float) -> void: min_camera_distance = v,
		"player_body.gd")
	if walk_profile != null:
		DebugPanel.add_slider("Skin/Lean/walk/forward", -0.5, 0.5, 0.005,
			func() -> float: return walk_profile.forward_lean_amount,
			func(v: float) -> void: walk_profile.forward_lean_amount = v,
			"walk_profile.tres")
		DebugPanel.add_slider("Skin/Lean/walk/side", -0.15, 0.15, 0.001,
			func() -> float: return walk_profile.side_lean_amount,
			func(v: float) -> void: walk_profile.side_lean_amount = v,
			"walk_profile.tres")
		DebugPanel.add_slider("Skin/Lean/walk/smoothing", 0.5, 20.0, 0.1,
			func() -> float: return walk_profile.lean_smoothing,
			func(v: float) -> void: walk_profile.lean_smoothing = v,
			"walk_profile.tres")
	if skate_profile != null:
		DebugPanel.add_slider("Movement/skate/max_speed", 1.0, 30.0, 0.1,
			func() -> float: return skate_profile.max_speed,
			func(v: float) -> void: skate_profile.max_speed = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/accel", 0.5, 100.0, 0.5,
			func() -> float: return skate_profile.accel,
			func(v: float) -> void: skate_profile.accel = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/friction", 0.0, 60.0, 0.5,
			func() -> float: return skate_profile.friction,
			func(v: float) -> void: skate_profile.friction = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/air_accel_mult", 0.0, 1.0, 0.02,
			func() -> float: return skate_profile.air_accel_mult,
			func(v: float) -> void: skate_profile.air_accel_mult = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/turn_rate", 0.5, 50.0, 0.1,
			func() -> float: return skate_profile.turn_rate,
			func(v: float) -> void: skate_profile.turn_rate = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/jump_impulse", 1.0, 30.0, 0.25,
			func() -> float: return skate_profile.jump_impulse,
			func(v: float) -> void: skate_profile.jump_impulse = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/rotation_speed", 0.5, 30.0, 0.25,
			func() -> float: return skate_profile.rotation_speed,
			func(v: float) -> void: skate_profile.rotation_speed = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/stopping_speed", 0.0, 5.0, 0.05,
			func() -> float: return skate_profile.stopping_speed,
			func(v: float) -> void: skate_profile.stopping_speed = v,
			"skate_profile.tres")
		DebugPanel.add_toggle("Movement/skate/face_velocity",
			func() -> bool: return skate_profile.face_velocity,
			func(v: bool) -> void: skate_profile.face_velocity = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/wall_ride_duration", 0.0, 5.0, 0.1,
			func() -> float: return skate_profile.wall_ride_duration,
			func(v: float) -> void: skate_profile.wall_ride_duration = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/wall_ride_min_speed", 0.0, 20.0, 0.1,
			func() -> float: return skate_profile.wall_ride_min_speed,
			func(v: float) -> void: skate_profile.wall_ride_min_speed = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/wall_ride_gravity", 0.0, 1.0, 0.05,
			func() -> float: return skate_profile.wall_ride_gravity_scale,
			func(v: float) -> void: skate_profile.wall_ride_gravity_scale = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/wall_ride_reach", 0.3, 3.0, 0.05,
			func() -> float: return skate_profile.wall_ride_reach,
			func(v: float) -> void: skate_profile.wall_ride_reach = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/wall_ride_jump_push", 0.0, 40.0, 0.5,
			func() -> float: return skate_profile.wall_ride_jump_push,
			func(v: float) -> void: skate_profile.wall_ride_jump_push = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/wall_ride_max_tilt_deg", 0.0, 90.0, 0.5,
			func() -> float: return skate_profile.wall_ride_max_tilt_deg,
			func(v: float) -> void: skate_profile.wall_ride_max_tilt_deg = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/grind_speed", 0.0, 30.0, 0.25,
			func() -> float: return skate_profile.grind_speed,
			func(v: float) -> void: skate_profile.grind_speed = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/grind_exit_boost", 0.0, 15.0, 0.25,
			func() -> float: return skate_profile.grind_exit_boost,
			func(v: float) -> void: skate_profile.grind_exit_boost = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/grind_yaw_offset_deg", -90.0, 90.0, 1.0,
			func() -> float: return skate_profile.grind_yaw_offset_deg,
			func(v: float) -> void: skate_profile.grind_yaw_offset_deg = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/grind_counter_strength", 0.0, 10.0, 0.1,
			func() -> float: return skate_profile.grind_counter_strength,
			func(v: float) -> void: skate_profile.grind_counter_strength = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/grind_fall_threshold", 0.1, 12.0, 0.1,
			func() -> float: return skate_profile.grind_fall_threshold,
			func(v: float) -> void: skate_profile.grind_fall_threshold = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Movement/skate/grind_lean_multiplier", 0.0, 10.0, 0.1,
			func() -> float: return skate_profile.grind_lean_multiplier,
			func(v: float) -> void: skate_profile.grind_lean_multiplier = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Skin/Sway/skate/duration", 0.0, 5.0, 0.1,
			func() -> float: return skate_profile.speedup_duration,
			func(v: float) -> void: skate_profile.speedup_duration = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Skin/Sway/skate/amplitude", 0.0, 0.5, 0.005,
			func() -> float: return skate_profile.speedup_amplitude,
			func(v: float) -> void: skate_profile.speedup_amplitude = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Skin/Sway/skate/frequency", 0.2, 8.0, 0.1,
			func() -> float: return skate_profile.speedup_frequency,
			func(v: float) -> void: skate_profile.speedup_frequency = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Skin/Sway/skate/accel_pulse", 0.0, 1.0, 0.05,
			func() -> float: return skate_profile.stroke_accel_pulse,
			func(v: float) -> void: skate_profile.stroke_accel_pulse = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Skate/roll_volume_db", -40.0, 6.0, 0.5,
			func() -> float: return skate_roll_volume_db,
			func(v: float) -> void: skate_roll_volume_db = v,
			"player_body.gd")
		DebugPanel.add_slider("Skin/Sway/skate/pivot_height", 0.0, 3.0, 0.05,
			func() -> float: return _skin.lean_pivot_height,
			func(v: float) -> void: _skin.lean_pivot_height = v,
			"skin scene")
		DebugPanel.add_slider("Skin/Sway/skate/cruise_amplitude", 0.0, 1.0, 0.01,
			func() -> float: return skate_profile.cruise_sway_amplitude,
			func(v: float) -> void: skate_profile.cruise_sway_amplitude = v,
			"skate_profile.tres")
	if walk_profile != null:
		DebugPanel.add_slider("Skin/Lean/walk/tilt_height_drop", 0.0, 2.0, 0.02,
			func() -> float: return walk_profile.tilt_height_drop,
			func(v: float) -> void: walk_profile.tilt_height_drop = v,
			"walk_profile.tres")
	if skate_profile != null:
		DebugPanel.add_slider("Skin/Lean/skate/tilt_height_drop", 0.0, 2.0, 0.02,
			func() -> float: return skate_profile.tilt_height_drop,
			func(v: float) -> void: skate_profile.tilt_height_drop = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Skin/Lean/skate/brake_impulse", -0.6, 0.6, 0.02,
			func() -> float: return skate_profile.brake_impulse_amount,
			func(v: float) -> void: skate_profile.brake_impulse_amount = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Skin/Lean/skate/brake_decay", 0.5, 15.0, 0.1,
			func() -> float: return skate_profile.brake_impulse_decay,
			func(v: float) -> void: skate_profile.brake_impulse_decay = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Skin/Lean/skate/forward", -0.5, 0.5, 0.005,
			func() -> float: return skate_profile.forward_lean_amount,
			func(v: float) -> void: skate_profile.forward_lean_amount = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Skin/Lean/skate/side", -0.15, 0.15, 0.001,
			func() -> float: return skate_profile.side_lean_amount,
			func(v: float) -> void: skate_profile.side_lean_amount = v,
			"skate_profile.tres")
		DebugPanel.add_slider("Skin/Lean/skate/smoothing", 0.5, 20.0, 0.1,
			func() -> float: return skate_profile.lean_smoothing,
			func(v: float) -> void: skate_profile.lean_smoothing = v,
			"skate_profile.tres")
	DebugPanel.add_slider("Camera/SpringArm/base_pitch_deg", -60.0, 10.0, 0.5,
		func() -> float: return rad_to_deg(_base_pitch),
		func(v: float) -> void: _base_pitch = deg_to_rad(v),
		"player_body.gd")
	DebugPanel.add_slider("Camera/Mouse/pitch_return_delay", 0.0, 3.0, 0.05,
		func() -> float: return pitch_return_delay,
		func(v: float) -> void: pitch_return_delay = v,
		"player_body.gd")
	DebugPanel.add_slider("Camera/Mouse/pitch_return_rate", 0.1, 10.0, 0.1,
		func() -> float: return pitch_return_rate,
		func(v: float) -> void: pitch_return_rate = v,
		"player_body.gd")
	DebugPanel.add_slider("Camera/Camera3D/fov", 30.0, 110.0, 1.0,
		func() -> float: return _camera.fov,
		func(v: float) -> void: _camera.fov = v,
		"player_body.tscn")
	DebugPanel.add_slider("Camera/Mouse/x_sensitivity", 0.0, 0.02, 0.0005,
		func() -> float: return mouse_x_sensitivity,
		func(v: float) -> void: mouse_x_sensitivity = v,
		"player_body.gd")
	DebugPanel.add_slider("Camera/Mouse/y_sensitivity", 0.0, 0.02, 0.0005,
		func() -> float: return mouse_y_sensitivity,
		func(v: float) -> void: mouse_y_sensitivity = v,
		"player_body.gd")
	DebugPanel.add_toggle("Camera/Mouse/invert_y",
		func() -> bool: return invert_y,
		func(v: bool) -> void: invert_y = v,
		"player_body.gd")
	DebugPanel.add_slider("Camera/Mouse/release_delay", 0.0, 5.0, 0.1,
		func() -> float: return mouse_release_delay,
		func(v: float) -> void: mouse_release_delay = v,
		"player_body.gd")
	DebugPanel.add_slider("Camera/Mouse/blend_time", 0.0, 2.0, 0.05,
		func() -> float: return mouse_blend_time,
		func(v: float) -> void: mouse_blend_time = v,
		"player_body.gd")
	DebugPanel.add_readout("Debug/h_speed",
		func() -> String: return "%.1f m/s" % Vector2(velocity.x, velocity.z).length())
	# Footstep tuning — only register on the player pawn so enemy variants
	# don't spam the panel with N copies of the same controls.
	if pawn_group == "player":
		DebugPanel.add_toggle("Footsteps/enabled",
			func() -> bool: return walk_footsteps_enabled,
			func(v: bool) -> void: walk_footsteps_enabled = v,
			"player_body.gd")
		DebugPanel.add_slider("Footsteps/cadence_at_max", 0.5, 12.0, 0.1,
			func() -> float: return walk_footstep_cadence_at_max,
			func(v: float) -> void: walk_footstep_cadence_at_max = v,
			"player_body.gd")
		DebugPanel.add_slider("Footsteps/min_speed", 0.0, 4.0, 0.05,
			func() -> float: return walk_footstep_min_speed,
			func(v: float) -> void: walk_footstep_min_speed = v,
			"player_body.gd")
		DebugPanel.add_slider("Footsteps/volume_db", -30.0, 12.0, 0.5,
			func() -> float: return walk_footstep_volume_db,
			func(v: float) -> void: walk_footstep_volume_db = v,
			"player_body.gd")
		DebugPanel.add_slider("Footsteps/pitch_jitter", 0.0, 0.5, 0.01,
			func() -> float: return walk_footstep_pitch_jitter,
			func(v: float) -> void: walk_footstep_pitch_jitter = v,
			"player_body.gd")
		DebugPanel.add_slider("Footsteps/walk_anim_min_scale", 0.05, 1.0, 0.01,
			func() -> float: return walk_anim_min_scale,
			func(v: float) -> void: walk_anim_min_scale = v,
			"player_body.gd")
		DebugPanel.add_readout("Footsteps/pool_size",
			func() -> String: return "%d clips" % _walk_footstep_pool_resolved.size())
		DebugPanel.add_toggle("Skate/strides_enabled",
			func() -> bool: return skate_strides_enabled,
			func(v: bool) -> void: skate_strides_enabled = v,
			"player_body.gd")
		DebugPanel.add_slider("Skate/min_speed", 0.0, 6.0, 0.05,
			func() -> float: return skate_stride_min_speed,
			func(v: float) -> void: skate_stride_min_speed = v,
			"player_body.gd")
		DebugPanel.add_slider("Skate/volume_db", -30.0, 12.0, 0.5,
			func() -> float: return skate_stride_volume_db,
			func(v: float) -> void: skate_stride_volume_db = v,
			"player_body.gd")
		DebugPanel.add_slider("Skate/pitch_jitter", 0.0, 0.5, 0.01,
			func() -> float: return skate_stride_pitch_jitter,
			func(v: float) -> void: skate_stride_pitch_jitter = v,
			"player_body.gd")
		DebugPanel.add_readout("Skate/pool_size",
			func() -> String: return "%d clips" % _skate_stride_pool_resolved.size())


## Always-visible halfpipe tuning panel. Each pass shows ONLY its own
## 2-3 most important knobs — switching the pass swaps the panel contents.
## Comment the autoload entry in project.godot (HalfpipeTuner) or this
## whole function to remove the panel.
func _register_halfpipe_tuner() -> void:
	# Pass selector (drives the swap) + always-visible readouts.
	HalfpipeTuner.register_pass_selector(
		PackedStringArray(["Current", "Kinematic", "Kinematic+Pump", "Centripetal"]),
		func() -> int: return int(halfpipe_pass),
		func(v: int) -> void: halfpipe_pass = v as HalfpipePass)
	HalfpipeTuner.add_readout("Engaged",
		func() -> String: return "yes curve=%.2f" % _halfpipe_curve_factor if _on_halfpipe else "no")
	HalfpipeTuner.add_readout("speed",
		func() -> String: return "%.1f m/s" % velocity.length())

	# Pass 0 — Current. Three additive forces.
	HalfpipeTuner.register_pass(0, "CURRENT",
		"Three additive force-based knobs: a pull toward the trough, an extra slide when you're not pressing a direction, and a downhill speed multiplier. Tweakable but doesn't feel like skating physics.",
		[
			{"name": "stick_strength", "min": 0.0, "max": 300.0, "step": 5.0,
				"getter": func() -> float: return halfpipe_stick_strength,
				"setter": func(v: float) -> void: halfpipe_stick_strength = v,
				"desc": "How hard you're pulled toward the trough. Higher = stickier, but fights your own input on the way up."},
			{"name": "idle_slide_strength", "min": 0.0, "max": 1000.0, "step": 10.0,
				"getter": func() -> float: return halfpipe_idle_slide_strength,
				"setter": func(v: float) -> void: halfpipe_idle_slide_strength = v,
				"desc": "Extra downhill push when you let go of the stick. Stops you standing glued to a vertical wall."},
			{"name": "speed_boost", "min": 1.0, "max": 3.0, "step": 0.05,
				"getter": func() -> float: return halfpipe_speed_boost,
				"setter": func(v: float) -> void: halfpipe_speed_boost = v,
				"desc": "Arcade boost multiplied into downhill velocity. 1.0 = no boost; 1.4 = +40% downhill carry."},
		])

	# Pass 1 — Kinematic. Project velocity onto surface tangent, body aligns to normal.
	HalfpipeTuner.register_pass(1, "KINEMATIC",
		"Godot-recipe pattern. Each tick: velocity is projected onto the surface tangent (speed preserved, direction bent), gravity-along-tangent pulls you toward the trough, and the body's up-axis blends toward the surface normal. No glue forces. Feels like rails.",
		[
			{"name": "redirect_strength", "min": 0.0, "max": 1.0, "step": 0.02,
				"getter": func() -> float: return halfpipe_kin_redirect_strength,
				"setter": func(v: float) -> void: halfpipe_kin_redirect_strength = v,
				"desc": "0 = no constraint (fall off). 1 = fully on-rails (velocity always parallel to surface). 0.85 default."},
			{"name": "gravity_scale", "min": 0.0, "max": 3.0, "step": 0.05,
				"getter": func() -> float: return halfpipe_kin_gravity_scale,
				"setter": func(v: float) -> void: halfpipe_kin_gravity_scale = v,
				"desc": "How hard gravity-along-tangent pulls. 1.0 = real physics; >1 = arcade slide."},
			{"name": "align_rate", "min": 0.0, "max": 30.0, "step": 0.5,
				"getter": func() -> float: return halfpipe_kin_align_rate,
				"setter": func(v: float) -> void: halfpipe_kin_align_rate = v,
				"desc": "How fast the body rotates to match the surface. 12 is the Godot recipe's sweet spot."},
			{"name": "max_tilt", "min": 0.0, "max": 1.0, "step": 0.02,
				"getter": func() -> float: return halfpipe_kin_max_tilt,
				"setter": func(v: float) -> void: halfpipe_kin_max_tilt = v,
				"desc": "Tilt clamp. 1.0 = full lean to wall normal; 0.5 = halfway; 0 = always upright. Caps the extreme."},
		])

	# Pass 2 — Kinematic + Pump. Same as Kinematic plus a crouch-release boost.
	HalfpipeTuner.register_pass(2, "KINEMATIC + PUMP",
		"Kinematic (above) plus a one-shot tangent-velocity boost the moment you RELEASE crouch on the curve. Real skaters gain ~13-17% per pump cycle. Cooldown stops mashing.",
		[
			{"name": "pump_multiplier", "min": 1.0, "max": 1.4, "step": 0.01,
				"getter": func() -> float: return halfpipe_pump_multiplier,
				"setter": func(v: float) -> void: halfpipe_pump_multiplier = v,
				"desc": "Velocity multiplier per pump. 1.12 ≈ real-world. 1.30+ feels arcade-y."},
			{"name": "pump_cooldown_s", "min": 0.1, "max": 2.0, "step": 0.05,
				"getter": func() -> float: return halfpipe_pump_cooldown,
				"setter": func(v: float) -> void: halfpipe_pump_cooldown = v,
				"desc": "Seconds between pumps. 0.6 ≈ one pump per traversal of the trough."},
			{"name": "redirect_strength", "min": 0.0, "max": 1.0, "step": 0.02,
				"getter": func() -> float: return halfpipe_kin_redirect_strength,
				"setter": func(v: float) -> void: halfpipe_kin_redirect_strength = v,
				"desc": "(shared with KINEMATIC) Constraint strength to surface tangent."},
			{"name": "max_tilt", "min": 0.0, "max": 1.0, "step": 0.02,
				"getter": func() -> float: return halfpipe_kin_max_tilt,
				"setter": func(v: float) -> void: halfpipe_kin_max_tilt = v,
				"desc": "(shared with KINEMATIC) Tilt clamp."},
		])

	# Pass 3 — Centripetal. Current's forces plus v²/r inward grip.
	HalfpipeTuner.register_pass(3, "CENTRIPETAL",
		"Current's three forces PLUS an inward-grip force = (v² / r) × curve_factor. Going fast through the trough feels planted; standing still feels exactly like Current. radius_m MUST match the pipe geometry (level_4 = 18m).",
		[
			{"name": "radius_m", "min": 2.0, "max": 30.0, "step": 0.5,
				"getter": func() -> float: return halfpipe_centripetal_radius,
				"setter": func(v: float) -> void: halfpipe_centripetal_radius = v,
				"desc": "Pipe radius. level_4's HalfPipe inner radius is 18m. Per-level override needed for other pipes."},
			{"name": "grip_scale", "min": 0.0, "max": 3.0, "step": 0.05,
				"getter": func() -> float: return halfpipe_centripetal_grip_scale,
				"setter": func(v: float) -> void: halfpipe_centripetal_grip_scale = v,
				"desc": "Scalar on the grip force. 1.0 = real physics; 0 = current pass; >1 = sticky carve."},
			{"name": "stick_strength", "min": 0.0, "max": 300.0, "step": 5.0,
				"getter": func() -> float: return halfpipe_stick_strength,
				"setter": func(v: float) -> void: halfpipe_stick_strength = v,
				"desc": "(shared with CURRENT) Slow pull toward trough."},
		])

	# Shared knobs that apply to every pass.
	HalfpipeTuner.add_section_header("── Shared (every pass) ──")
	HalfpipeTuner.add_shared_slider("max_speed_multiplier", 0.5, 3.0, 0.05,
		func() -> float: return halfpipe_max_speed_multiplier,
		func(v: float) -> void: halfpipe_max_speed_multiplier = v,
		"Top-speed multiplier while engaged. 1.45 default.")
	HalfpipeTuner.add_shared_slider("exit_normal_speed", 0.0, 20.0, 0.25,
		func() -> float: return halfpipe_exit_normal_speed,
		func(v: float) -> void: halfpipe_exit_normal_speed = v,
		"Auto-disengage when v·normal exceeds this near the lip (you flew off naturally).")
	HalfpipeTuner.add_shared_slider("jump_blend", 0.0, 1.0, 0.02,
		func() -> float: return halfpipe_jump_blend,
		func(v: float) -> void: halfpipe_jump_blend = v,
		"0 = jump straight up; 1 = jump along surface normal. 0.2 = mostly-up with a wall-kick.")
	HalfpipeTuner.add_shared_slider("trough_friction_scale", 0.0, 1.0, 0.02,
		func() -> float: return halfpipe_trough_friction_scale,
		func(v: float) -> void: halfpipe_trough_friction_scale = v,
		"Scales friction in the trough (where the wall-friction-skip doesn't fire). 1.0 = ground-grippy; 0.3 = long coast wall-to-wall; 0 = never slows down.")


## Halfpipe-stick tick. Probes downward for a curved-surface body in the
## halfpipe_surface_group; if hit, sets `_on_halfpipe` + `_halfpipe_normal`
## + `_halfpipe_curve_factor` for the rest of the frame to consume (skin
## tilt below + jump impulse override). Also applies a speed boost +
## adhesion pull along the curve so dropping in feels like gaining speed.
##
## Master toggle is per-faction (player vs allies). When the relevant
## toggle is false, the function early-exits and clears state — body
## behaves exactly as if this system didn't exist.
func _update_halfpipe_stick(delta: float, intent: Intent) -> void:
	# Per-tick kinematic flags reset; only the currently-dispatched pass
	# re-raises them after the prelude resolves.
	_hp_kinematic_active_this_tick = false
	_hp_align_active_this_tick = false
	# Pump cooldown ticks regardless of pass / engagement so it doesn't
	# go stale across a disengage.
	if _hp_pump_cooldown_timer > 0.0:
		_hp_pump_cooldown_timer = maxf(0.0, _hp_pump_cooldown_timer - delta)
	# Live pass-switch: any change to halfpipe_pass forces a clean
	# disengage so per-pass state can't carry over (different passes own
	# velocity differently). Next valid probe re-engages under the new pass.
	if _hp_last_pass != int(halfpipe_pass):
		if _hp_last_pass != -1:
			_halfpipe_disengage()
		_hp_last_pass = int(halfpipe_pass)
	# Eligibility gate: master toggle + "blades on" (skate-mode active).
	# Same condition that makes the wheels visible — see _set_active_profile
	# calling _skin.set_skate_mode(true) when _current_profile == skate_profile.
	# Applies to player, converted gold allies, AND hostile pawns on skates.
	var should_run: bool = halfpipe_stick_enabled \
		and skate_profile != null \
		and _current_profile == skate_profile
	if not should_run:
		_halfpipe_disengage()
		return
	# Cooldown after curve-jump prevents instant re-snap.
	if _halfpipe_jump_timer > 0.0:
		_halfpipe_jump_timer = maxf(0.0, _halfpipe_jump_timer - delta)
		_halfpipe_disengage()
		return
	# Grapple is the second explicit-release input (jump is the first,
	# handled in the jump-impulse branch). Player only — allies don't
	# grapple. Pressing fires regardless of aim target so the contract is
	# predictable: press grapple = leave the curve.
	if pawn_group == "player" and Input.is_action_just_pressed(&"grapple_fire"):
		_halfpipe_disengage()
		return
	# Probe direction is state-dependent. When NOT engaged, cast straight
	# down — that's the "drop in from above" entry path. When engaged,
	# cast back along the LAST KNOWN surface normal so we hit the wall
	# beside us instead of empty space below us. Without this, a 70° wall
	# is missed by every downward ray (the wall isn't below the body, it's
	# next to it) and the body chatters in and out of engagement.
	var probe_dir: Vector3 = Vector3.DOWN
	if _hp_last_engaged and _halfpipe_normal.length_squared() > 0.0001:
		probe_dir = -_halfpipe_normal
	var space_state := get_world_3d().direct_space_state
	var from: Vector3 = global_position + Vector3(0, 0.5, 0)
	var to: Vector3 = from + probe_dir * halfpipe_probe_distance
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [self]
	var hit: Dictionary = space_state.intersect_ray(query)
	# Resolve whether the hit is a halfpipe surface (metadata or name match
	# walking up the parent chain). Returns null if no qualifying hit.
	var fresh_normal: Vector3 = Vector3.ZERO
	if not hit.is_empty():
		var hit_collider: Node = hit.get("collider")
		if hit_collider != null:
			var group_node: Node = hit_collider
			while group_node != null:
				if group_node.has_meta(halfpipe_surface_meta):
					break
				if halfpipe_surface_names.has(String(group_node.name)):
					break
				group_node = group_node.get_parent()
			if group_node != null:
				fresh_normal = hit.get("normal", Vector3.UP)
	# No hit this tick. If we were engaged, STAY engaged — only jump,
	# grapple, config-off, or post-jump cooldown disengage. Skip force
	# application: a stale normal would push the body in the wrong
	# direction as the surface curves away from us.
	if fresh_normal == Vector3.ZERO:
		return
	# Fresh hit — refresh state and apply forces.
	_on_halfpipe = true
	_halfpipe_normal = fresh_normal
	var angle_from_up: float = acos(clamp(_halfpipe_normal.dot(Vector3.UP), -1.0, 1.0))
	_halfpipe_curve_factor = clamp(angle_from_up / (PI * 0.5), 0.0, 1.0)
	# On first engage: stash the original floor_max_angle and bump it so
	# steep walls count as walkable for the duration of the engagement.
	if not _hp_last_engaged:
		_halfpipe_saved_floor_max_angle = floor_max_angle
		floor_max_angle = deg_to_rad(halfpipe_walk_max_angle_deg)
		_halfpipe_saved_up_direction = up_direction
		# Snap-length override only when the export is non-zero; 0.0 means
		# "leave snap alone" so the knob can be killed without code edits.
		# Actual per-tick value is computed below (tapers by curve_factor).
		if halfpipe_snap_length > 0.0:
			_halfpipe_saved_floor_snap_length = floor_snap_length
		print("[halfpipe] ENGAGED  body=%s on_floor=%s vy=%.2f curve=%.2f" %
			[name, is_on_floor(), velocity.y, _halfpipe_curve_factor])
		_hp_last_engaged = true
	# Per-tick up_direction tracking. Tells move_and_slide that "up" off
	# this surface is the surface normal — so is_on_floor() stays true on
	# vertical wall sections instead of flickering false (which was driving
	# the fall-animation bug + the snap penetration earlier).
	up_direction = _halfpipe_normal
	# Per-tick snap taper. Snap-cast goes along world -up_direction; on a
	# near-vertical wall that pulls the upright capsule SIDEWAYS into the
	# slanted wall geometry by ~radius. Taper keeps strong snap at the
	# trough (where the way-up bounce was) and zero snap at vertical
	# (where penetration starts). curve_factor 0 = flat → full snap;
	# curve_factor 1 = vertical → no snap, normal collision handles it.
	if halfpipe_snap_length > 0.0:
		floor_snap_length = halfpipe_snap_length * (1.0 - _halfpipe_curve_factor)
	# Penetration diagnostic — signed distance from probe-hit-point along
	# the surface normal. Negative = body center is INSIDE the wall by
	# that many meters. Deduped per 0.1m bucket so the log only fires when
	# depth moves a notch. Strip after we've fixed the snap geometry.
	var hit_point: Vector3 = hit.get("position", global_position)
	var pen: float = (global_position - hit_point).dot(_halfpipe_normal)
	var pen_bucket: float = roundf(pen * 10.0) / 10.0
	if pen_bucket != _hp_last_pen_bucket:
		_hp_last_pen_bucket = pen_bucket
		print("[halfpipe-pen] curve=%.2f snap=%.2f pen=%+.2f body=(%.1f,%.1f,%.1f) hit=(%.1f,%.1f,%.1f) normal=(%.2f,%.2f,%.2f)" % [
			_halfpipe_curve_factor, floor_snap_length, pen,
			global_position.x, global_position.y, global_position.z,
			hit_point.x, hit_point.y, hit_point.z,
			_halfpipe_normal.x, _halfpipe_normal.y, _halfpipe_normal.z])
	# Tangent along the surface pointing "downhill" (toward trough).
	var down: Vector3 = Vector3.DOWN
	var down_along_surface: Vector3 = down - _halfpipe_normal * down.dot(_halfpipe_normal)
	if down_along_surface.length_squared() < 0.0001:
		return
	down_along_surface = down_along_surface.normalized()
	# Per-pass dispatch. Each pass owns the velocity/force changes for
	# this tick. Shared epilogue below handles auto-exit + crouch edge.
	match halfpipe_pass:
		HalfpipePass.CURRENT:
			_hp_pass_current(delta, intent, down_along_surface)
		HalfpipePass.KINEMATIC:
			_hp_pass_kinematic(delta, intent, down_along_surface)
		HalfpipePass.KINEMATIC_PUMP:
			_hp_pass_kinematic_pump(delta, intent, down_along_surface)
		HalfpipePass.CENTRIPETAL:
			_hp_pass_centripetal(delta, intent, down_along_surface)
	# Shared auto-exit: if you're up on the wall AND moving outward fast
	# enough, you've effectively flown off the lip — let go without
	# requiring an explicit jump press. Mirrors the Unreal forum advice
	# ("ignore detection if player is ascending or moving too fast").
	if _halfpipe_curve_factor >= halfpipe_exit_curve_min:
		var v_out: float = velocity.dot(_halfpipe_normal)
		if v_out > halfpipe_exit_normal_speed:
			print("[halfpipe] AUTO-EXIT v·n=%.2f curve=%.2f" % [v_out, _halfpipe_curve_factor])
			_halfpipe_disengage()
			_hp_was_crouched_last_tick = intent.crouch_held
			return
	# Crouch-edge bookkeeping for the pump pass. Tracked here (not inside
	# the pass) so a pass switch doesn't lose the edge.
	_hp_was_crouched_last_tick = intent.crouch_held


# ── Per-pass force/velocity bodies ───────────────────────────────────────
# All four bodies are called ONLY from _update_halfpipe_stick, which only
# fires while engaged on a curve surface. None of them touch behavior on
# flat ground or normal skating.

## Pass 0 — current behavior. Three additive forces along the surface:
##   adhesion (constant pull toward trough),
##   idle slide (extra pull when no input),
##   speed boost (multiply downhill velocity component).
func _hp_pass_current(delta: float, intent: Intent, down_along_surface: Vector3) -> void:
	velocity += down_along_surface * halfpipe_stick_strength * _halfpipe_curve_factor * delta
	var has_input: bool = intent.move_direction.length() > 0.1
	if not has_input:
		velocity += down_along_surface * halfpipe_idle_slide_strength * _halfpipe_curve_factor * delta
	var v_along: float = velocity.dot(down_along_surface)
	if v_along > 0.0:
		velocity += down_along_surface * (halfpipe_speed_boost - 1.0) * v_along * delta


## Pass 1 — kinematic tangent (Godot-recipe pattern + projection).
## Two flags raised for the post-pipeline hook to consume:
##   redirect: project velocity onto the surface tangent plane each tick,
##   align:    blend the body's up axis toward _halfpipe_normal at align_rate.
## Gravity-along-tangent is the only "force" — added directly here so the
## standard pipeline's +gravity later is partly cancelled by the projection.
func _hp_pass_kinematic(_delta: float, _intent: Intent, down_along_surface: Vector3) -> void:
	_hp_kinematic_active_this_tick = true
	_hp_align_active_this_tick = true
	# Gravity-along-tangent component. Real "g·sin(θ)" pull toward trough.
	# down_along_surface already encodes (down minus normal-component) = the
	# unit-length tangent pointing toward the trough.
	var g_tangent: float = absf(_gravity) * _halfpipe_curve_factor * halfpipe_kin_gravity_scale
	velocity += down_along_surface * g_tangent * _delta


## Pass 2 — kinematic + pump. Inherits the kinematic redirect/align, adds
## a one-shot tangent-velocity multiplier the frame crouch is released
## while on the curve. Cooldown prevents mashing.
func _hp_pass_kinematic_pump(delta: float, intent: Intent, down_along_surface: Vector3) -> void:
	_hp_pass_kinematic(delta, intent, down_along_surface)
	if _hp_pump_cooldown_timer > 0.0:
		return
	if _halfpipe_curve_factor < halfpipe_pump_min_curve:
		return
	# Edge: crouch was held last tick, released this tick.
	var crouch_released: bool = _hp_was_crouched_last_tick and not intent.crouch_held
	if not crouch_released:
		return
	# Multiply only the component of velocity along the tangent (toward
	# trough OR away — doesn't matter, the skater is conserving angular
	# momentum either direction).
	var v_tangent: float = velocity.dot(down_along_surface)
	if absf(v_tangent) < 0.05:
		return  # standing still — no angular momentum to convert
	var boost: float = v_tangent * (halfpipe_pump_multiplier - 1.0)
	velocity += down_along_surface * boost
	_hp_pump_cooldown_timer = halfpipe_pump_cooldown
	print("[halfpipe] PUMP v_tangent=%.2f boost=%.2f curve=%.2f" %
		[v_tangent, boost, _halfpipe_curve_factor])


## Pass 3 — centripetal. Current's three additive forces PLUS an inward
## grip = (v² / r) × curve_factor × grip_scale, pulling along -normal.
## Going fast through the trough feels planted; standing still feels the
## same as current.
func _hp_pass_centripetal(delta: float, intent: Intent, down_along_surface: Vector3) -> void:
	_hp_pass_current(delta, intent, down_along_surface)
	if halfpipe_centripetal_radius <= 0.0:
		return
	var speed_sq: float = velocity.length_squared()
	# Centripetal acceleration magnitude: v² / r. Scaled by curve factor
	# (flat trough doesn't bend you, vertical wall does) and tunable scalar.
	var a_cent: float = (speed_sq / halfpipe_centripetal_radius) * _halfpipe_curve_factor * halfpipe_centripetal_grip_scale
	velocity += -_halfpipe_normal * a_cent * delta


## Post-pipeline hook called from _physics_process right after the
## standard velocity write (line ~2492). Consumes the per-tick flags
## raised by the kinematic passes. Safe to call unconditionally —
## flags are reset every tick and only set when on a kinematic pass.
func _apply_halfpipe_post_pipeline(delta: float) -> void:
	if _on_halfpipe:
		if _hp_kinematic_active_this_tick and halfpipe_kin_redirect_strength > 0.0:
			# Project velocity onto the surface tangent plane (perpendicular
			# to _halfpipe_normal). Strength=1 → fully constrained, =0 → no-op.
			var v_along_normal: float = velocity.dot(_halfpipe_normal)
			var redirect: Vector3 = _halfpipe_normal * v_along_normal * halfpipe_kin_redirect_strength
			velocity -= redirect
		if _hp_align_active_this_tick and halfpipe_kin_align_rate > 0.0 and halfpipe_kin_max_tilt > 0.0:
			# Align body's up axis to surface normal — but only up to the
			# user-clamped max_tilt fraction. blended_target is the world UP
			# lerped toward the normal by max_tilt, so even at curve_factor=1
			# (vertical wall) the body never leans past the configured limit.
			var blended_target: Vector3 = Vector3.UP.lerp(_halfpipe_normal, halfpipe_kin_max_tilt).normalized()
			var target_xform: Transform3D = _hp_align_with_y(global_transform, blended_target)
			var t: float = clamp(halfpipe_kin_align_rate * delta, 0.0, 1.0)
			global_transform = global_transform.interpolate_with(target_xform, t)
			_hp_needs_reupright = true
		return
	# Disengaged: lerp body back to upright if a kinematic pass had tilted
	# it. Uses the same align_rate as engaged so the visual recovery feels
	# continuous. Self-stops once basis.y is within ~1° of world UP.
	if _hp_needs_reupright and halfpipe_kin_align_rate > 0.0:
		var current_up: Vector3 = global_transform.basis.y
		if current_up.angle_to(Vector3.UP) < 0.02:
			_hp_needs_reupright = false
			return
		var target_xform: Transform3D = _hp_align_with_y(global_transform, Vector3.UP)
		var t: float = clamp(halfpipe_kin_align_rate * delta, 0.0, 1.0)
		global_transform = global_transform.interpolate_with(target_xform, t)


## Godot-recipe helper. Builds a transform whose Y axis points along
## new_y, preserving forward direction via cross product + orthonormalize.
func _hp_align_with_y(xform: Transform3D, new_y: Vector3) -> Transform3D:
	if new_y.length_squared() < 0.0001:
		return xform
	var basis_y: Vector3 = new_y.normalized()
	var basis_x: Vector3 = -xform.basis.z.cross(basis_y)
	if basis_x.length_squared() < 0.0001:
		return xform  # degenerate (looking straight up the normal)
	var new_basis: Basis = xform.basis
	new_basis.y = basis_y
	new_basis.x = basis_x
	new_basis = new_basis.orthonormalized()
	xform.basis = new_basis
	return xform


## Public wrapper for external systems (bouncy platforms, jump pads,
## cannons, scripted launches) that yank the body off a curve surface.
## Without calling this, the engaged state — up_direction, floor_max_angle,
## tilted basis, _on_halfpipe flag — survives the external impulse and
## the body either snaps back to the wall or rides invisible halfpipe
## physics on flat ground afterward. The post-disengage re-upright lerp
## handles the basis recovery (see _apply_halfpipe_post_pipeline).
func force_halfpipe_disengage() -> void:
	_halfpipe_disengage()


## Tear-down for halfpipe state. Clears flags AND restores the body's
## floor_max_angle to whatever it was before engagement so the next
## flat-floor section uses the project default. Only called from
## intentional-release sites: jump impulse, grapple input, post-jump
## cooldown, and the master-toggle config kill.
func _halfpipe_disengage() -> void:
	_on_halfpipe = false
	_halfpipe_curve_factor = 0.0
	_hp_last_pen_bucket = 999.0
	_hp_kinematic_active_this_tick = false
	_hp_align_active_this_tick = false
	if _hp_last_engaged:
		# Restore floor_max_angle to its pre-engage value.
		if _halfpipe_saved_floor_max_angle >= 0.0:
			floor_max_angle = _halfpipe_saved_floor_max_angle
			_halfpipe_saved_floor_max_angle = -1.0
		# Restore floor_snap_length too. Sentinel -1.0 means we never
		# overrode it (export was 0.0), so we leave it alone.
		if _halfpipe_saved_floor_snap_length >= 0.0:
			floor_snap_length = _halfpipe_saved_floor_snap_length
			_halfpipe_saved_floor_snap_length = -1.0
		# Restore up_direction. Sentinel ZERO means we never saved it.
		if _halfpipe_saved_up_direction.length_squared() > 0.0001:
			up_direction = _halfpipe_saved_up_direction
			_halfpipe_saved_up_direction = Vector3.ZERO
		print("[halfpipe] DISENGAGED body=%s on_floor=%s vy=%.2f snap=%.2f" %
			[name, is_on_floor(), velocity.y, floor_snap_length])
		_hp_last_engaged = false


func _update_follow_camera(delta: float) -> void:
	# No-op for non-player pawns — enemies / companions have no camera rig
	# (Camera3D freed in _ready, _spring never assigned). They still call
	# this from shared physics paths (death loop, grind, etc.), so the early
	# exit is required to avoid null derefs on _spring / _camera_pivot.
	if _spring == null or _camera_pivot == null:
		return
	# Mouse activity is tracked by the brain (player only). AI brains have no
	# mouse so we treat them as "no recent input" (999).
	var tsm: float = 999.0
	if _brain is PlayerBrain:
		tsm = (_brain as PlayerBrain).time_since_mouse_input
	# Track mouse activity: ramp manual weight up on active input, down after release delay.
	var target_weight: float = 1.0 if tsm < mouse_release_delay else 0.0
	var blend_factor := 1.0 - exp(-delta / max(mouse_blend_time, 0.001))
	_manual_weight = lerp(_manual_weight, target_weight, blend_factor)

	# Pitch returns only while the character is moving — stopped, it stays where aimed.
	var h_vel_for_pitch := Vector3(velocity.x, 0.0, velocity.z)
	if h_vel_for_pitch.length() > 0.5 and tsm > pitch_return_delay:
		var pitch_factor := 1.0 - exp(-pitch_return_rate * delta)
		_spring.rotation.x = lerp_angle(_spring.rotation.x, _base_pitch, pitch_factor)

	# Drive camera yaw to sit behind the player's horizontal motion —
	# but only while actually moving, so stopped the camera stays where the player put it.
	var h_vel := Vector3(velocity.x, 0.0, velocity.z)
	if h_vel.length() > 0.5:
		_target_yaw = atan2(h_vel.x, h_vel.z)
		var yaw_factor := (1.0 - exp(-angle_smoothing * 60.0 * delta)) * (1.0 - _manual_weight)
		_camera_pivot.global_rotation.y = lerp_angle(_camera_pivot.global_rotation.y, _target_yaw, yaw_factor)

	if follow_mode == FollowMode.DETACHED:
		var target_pos := global_position + pivot_offset
		var pos_factor := 1.0 - exp(-position_smoothing * 60.0 * delta)
		_camera_pivot.global_position = _camera_pivot.global_position.lerp(target_pos, pos_factor)
