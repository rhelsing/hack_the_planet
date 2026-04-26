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

## Group the attack sweep targets when this pawn lunges. Player hits "enemies";
## an enemy pawn would hit "player". Cross-faction combat routed by groups.
@export var attack_target_group: String = "enemies"

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
## Max distance (meters) from player center to enemy center for a hit to land.
@export var attack_range := 3.0
## Max vertical distance at which a sweep can land. Prevents ground pawns
## from hitting things far above/below them — so jumping dodges reliably.
@export var attack_vertical_range := 1.5
## Seconds the swing stays "live" after pressing J. While active, any enemy
## that enters attack_range gets hit — so the forward lunge sweeps through
## enemies that were just out of reach at the press frame. Each enemy can
## only be hit once per swing.
@export var attack_active_duration := 0.22
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

@export_group("Camera Occlusion")
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
@export var spring_cast_radius := 0.2


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
var _speedup_timer := 999.0
var _was_moving := false
var _brake_impulse := 0.0
var _was_pressing_forward := false
var _wall_ride_active := false
var _wall_ride_timer := 0.0
var _wall_normal := Vector3.ZERO
var _grinding := false
var _grind_rail: Path3D = null
var _grind_progress := 0.0
var _grind_direction := 1.0
var _grind_snap_t := 1.0
var _grind_start_pos := Vector3.ZERO
var _air_jump_available := false
var _flip_timer := 0.0
var _flip_duration := 0.55
var _flip_axis := Vector3.RIGHT
var _yaw_state := 0.0
var _attack_timer := 0.0
var _attack_duration := 0.3
var _attack_active_timer := 0.0
var _attack_forward := Vector3.ZERO
var _attack_hit_enemies: Array[Node] = []
var _health := 3
var _dying := false
var _dying_timer := 0.0
var _regen_timer := 0.0
var _tint_timer := 0.0
## Absolute time (seconds) until which take_hit no-ops. -INF = never invuln.
## Set on respawn to give the player a grace window against enemies near the
## checkpoint.
var _invuln_until_time: float = -INF

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
const _VOICE_RESPAWN_DELAY: float = 3.0

@onready var _camera_pivot: Node3D = %CameraPivot
@onready var _camera: Camera3D = %Camera3D
@onready var _skin: CharacterSkin = %SophiaSkin
@onready var _landing_sound: AudioStreamPlayer3D = %LandingSound
@onready var _jump_sound: AudioStreamPlayer3D = %JumpSound
## Brain found by type, not by name — lets AI pawns drop in EnemyAIBrain,
## NetworkBrain, etc., without the body caring which one.
@onready var _brain: Brain = _find_first_brain()


func _find_first_brain() -> Brain:
	for c: Node in get_children():
		if c is Brain:
			return c
	push_error("PlayerBody has no Brain child")
	return null


func _ready() -> void:
	if not pawn_group.is_empty():
		add_to_group(pawn_group)
	_swap_skin_if_overridden()
	_swap_brain_if_overridden()
	# Abilities are player-only. If we're running as an enemy / companion,
	# strip the Abilities node so their _unhandled_input handlers don't
	# hijack the player's inputs (e.g. enemies firing flares when the
	# player presses Y).
	if pawn_group != "player":
		var abilities_node := get_node_or_null(^"Abilities")
		if abilities_node != null:
			abilities_node.queue_free()
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
	_register_debug_panel()
	Events.rail_touched.connect(_on_rail_touched)
	Events.checkpoint_reached.connect(_on_checkpoint_reached)
	# Player-only: hold the most recent RespawnMessageZone text. Enemies don't
	# subscribe (they don't respawn into hint UI).
	if pawn_group == "player":
		Events.respawn_message_armed.connect(_on_respawn_message_armed)
		Events.respawn_voice_armed.connect(_on_respawn_voice_armed)
	_health = max_health
	Events.kill_plane_touched.connect(func on_kill_plane_touched(body: PhysicsBody3D) -> void:
		# Global signal — filter to self so one pawn falling off doesn't kill
		# every other PlayerBody listening.
		if body != self:
			return
		# Falling off the world skips the HP system — it's always terminal.
		if not _dying:
			_start_death()
	)
	# enemy_hit_player and flag_reached are game-world events meant for the
	# human-controlled pawn only — gate on pawn_group so enemy-PlayerBodies
	# listening on the same autoload don't all react.
	if pawn_group == "player":
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


func _start_attack_jostle() -> void:
	if _attack_timer > 0.0:
		return
	_attack_timer = _attack_duration
	# Forward = flattened camera direction; fall back to character facing.
	var forward := -_camera.global_basis.z
	forward.y = 0.0
	if forward.length_squared() > 0.0001:
		forward = forward.normalized()
	else:
		forward = -global_basis.z
	# Additive velocity kick. The existing friction handles decay; we don't
	# need to lock out other movement or change animation state.
	velocity.x += forward.x * attack_lunge_speed
	velocity.z += forward.z * attack_lunge_speed
	velocity.y = maxf(velocity.y, attack_lunge_hop)
	# Open the active swing window. The sweep runs each frame in physics.
	_attack_active_timer = attack_active_duration
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


func _start_death() -> void:
	_dying = true
	_dying_timer = death_duration
	# Skin's die() picks the real death anim if it has one (KayKit's Death_A);
	# skins without a death clip inherit the no-op and we fall through to
	# the jump-rise-pose fallback that was the original Sophia behavior.
	_skin.die()
	_skin.jump()
	# Clear the damage tint so the death rise isn't red — the confetti is
	# the death visual; the red overlay is strictly for the damaged-but-alive
	# state leading up to this moment.
	_skin.damage_tint = 0.0
	# Pop straight up so the arc reads clearly no matter which way the player
	# was moving; horizontal motion is zeroed so they don't fly off mid-death.
	velocity = Vector3(0.0, death_rise_speed, 0.0)
	# Fire confetti immediately so the player rises up through the burst
	# instead of poofing only at the peak.
	_spawn_death_confetti()
	died.emit()


func _finish_death() -> void:
	# Terminal-death pawns (enemies) poof and are gone; respawning pawns
	# (players) snap back to their last checkpoint.
	if dies_permanently:
		queue_free()
		return
	global_position = _start_position
	velocity = Vector3.ZERO
	var old_health := _health
	_health = max_health
	_dying = false
	if old_health != _health:
		health_changed.emit(_health, old_health)
	_attack_timer = 0.0
	_tint_timer = 0.0
	# Start the post-respawn grace window. take_hit no-ops until this elapses.
	_invuln_until_time = Time.get_ticks_msec() / 1000.0 + respawn_invuln_duration
	if _skin != null:
		_skin.damage_tint = 0.0
	_skin.idle()
	respawned.emit()
	for msg: String in _pending_respawn_messages:
		Events.respawn_message_show.emit(msg)
	_pending_respawn_messages.clear()
	_drain_pending_voice_lines()
	_snap_camera_to_player()
	set_physics_process(true)


func _spawn_death_confetti() -> void:
	if death_burst_scene == null:
		return
	var burst: Node3D = death_burst_scene.instantiate()
	burst.call("set_direction", Vector3.UP)
	get_parent().add_child(burst)
	burst.global_position = global_position


## Universal damage entry point. Decrement HP, apply knockback, flash tint;
## trigger death sequence when HP hits zero. Works for player (max_health=3,
## respawns) and enemies (max_health=1, dies_permanently=true → queue_free).
## Pawns outside a sweep's attack_target_group are simply never called — no
## faction gating needed inside the method.
func take_hit(impact_direction: Vector3, force: float) -> void:
	if _dying:
		return
	# Post-respawn grace window: ignore damage for respawn_invuln_duration
	# seconds after _finish_death. Fixes the checkpoint death-loop.
	if Time.get_ticks_msec() / 1000.0 < _invuln_until_time:
		return
	var old_health := _health
	_health -= 1
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
		_start_death()


func _sweep_attack() -> void:
	var range_sq := attack_range * attack_range
	for enemy: Node in get_tree().get_nodes_in_group(attack_target_group):
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
		# Unified damage dispatch: prefer take_hit (new universal API), fall
		# back to hit() for legacy enemy/enemy.gd until it's retired.
		if enemy.has_method("take_hit"):
			enemy.take_hit(impact_dir, attack_knockback)
		elif enemy.has_method("hit"):
			enemy.hit(impact_dir, attack_knockback)
		_attack_hit_enemies.append(enemy)


func _apply_follow_mode() -> void:
	_camera_pivot.top_level = (follow_mode == FollowMode.DETACHED)
	_snap_camera_to_player()


func _snap_camera_to_player() -> void:
	if follow_mode == FollowMode.DETACHED:
		_camera_pivot.global_position = global_position + pivot_offset
	else:
		_camera_pivot.position = pivot_offset


func _on_rail_touched(rail: Node, body: Node) -> void:
	if body != self or _grinding:
		return
	var profile: MovementProfile = _current_profile
	if profile == null or profile.grind_speed <= 0.0:
		return
	_grind_rail = rail as Path3D
	_grind_progress = _grind_rail.closest_progress(global_position)
	# Pick direction: compare player's velocity to the curve tangent at the entry
	# point. If they disagree, grind backward along the curve.
	var pf: PathFollow3D = _grind_rail.get_node_or_null("PathFollow3D") as PathFollow3D
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
	_natural_lean_roll = 0.0
	_skin.idle()


func _on_checkpoint_reached(pos: Vector3) -> void:
	_start_position = pos


func _on_respawn_message_armed(text: String) -> void:
	# Skip if it matches the most recent — re-entering the same zone shouldn't
	# stack the same hint, but distinct zones in sequence should chain.
	if not _pending_respawn_messages.is_empty() and _pending_respawn_messages.back() == text:
		return
	_pending_respawn_messages.append(text)


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
	if _camera_pivot != null:
		if _camera_pivot.top_level:
			_camera_pivot.global_rotation = Vector3(0.0, yaw, 0.0)
		else:
			_camera_pivot.rotation = Vector3.ZERO
	velocity = Vector3.ZERO
	_snap_camera_to_player()


# ---- Save/load (called by SaveService on save / scene_entered) ----------

## Serializes the per-pawn state that can't be reconstructed from flags alone:
## current position (for mid-level saves), last-touched checkpoint (so dying
## on Continue drops you at the phone booth, not the level's default spawn),
## and current health.
func get_save_dict() -> Dictionary:
	return {
		"position": [global_position.x, global_position.y, global_position.z],
		"checkpoint": [_start_position.x, _start_position.y, _start_position.z],
		"health": _health,
	}


## Applied by SaveService on scene_entered after a Continue. Overrides the
## Game._spawn_player teleport so the player resumes exactly where the save
## was triggered (checkpoint / flag) with the right checkpoint banked.
func load_save_dict(d: Dictionary) -> void:
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


func _physics_process(delta: float) -> void:
	# Brain pushes per-tick intent (movement direction, jump/attack edges).
	# Body never touches Input directly — same code path drives player, AI, net.
	var intent: Intent = _brain.tick(self, delta)

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

	if _dying:
		_dying_timer -= delta
		velocity.y += _gravity * delta
		move_and_slide()
		_update_follow_camera(delta)
		if _dying_timer <= 0.0:
			_finish_death()
		return

	_tick_health_regen(delta)
	_tick_damage_tint(delta)

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

	# Skin facing.
	var h_vel := Vector3(velocity.x, 0.0, velocity.z)
	var face_target := _last_input_direction
	if profile.face_velocity and h_vel.length() > 0.5:
		face_target = h_vel.normalized()
	var target_angle := Vector3.BACK.signed_angle_to(face_target, Vector3.UP)
	var new_yaw: float = lerp_angle(_yaw_state, target_angle, profile.rotation_speed * delta)
	_yaw_state = new_yaw

	# Body lean: forward tilt scales with speed; side roll scales with
	# angular turn rate × speed (centripetal force feel).
	var d_yaw: float = wrapf(new_yaw - _prev_skin_yaw, -PI, PI) / max(delta, 0.0001)
	_prev_skin_yaw = new_yaw
	_prev_h_vel = h_vel
	var speed: float = h_vel.length()
	# Startup sway: side-to-side rocking for the first couple seconds of motion.
	var is_moving: bool = speed > 0.5
	if is_moving and not _was_moving:
		_speedup_timer = 0.0
	if is_moving:
		_speedup_timer += delta
	_was_moving = is_moving
	var speedup_roll := 0.0
	if is_moving:
		var amp: float = profile.cruise_sway_amplitude
		if _speedup_timer < profile.speedup_duration:
			var t: float = _speedup_timer / max(profile.speedup_duration, 0.001)
			amp = lerpf(profile.speedup_amplitude, profile.cruise_sway_amplitude, t)
		speedup_roll = amp * sin(TAU * profile.speedup_frequency * _speedup_timer)
	# Kill the sway while airborne so jumps read clean.
	if not is_on_floor():
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
	var final_pitch: float = (_current_lean_pitch + _brake_impulse + attack_pitch) * lean_mult
	var final_roll: float = (_current_lean_roll + speedup_roll) * lean_mult

	# Rotate the skin around a head-height pivot: the basis holds yaw+pitch+roll,
	# and we shift the skin's origin so the pivot point stays fixed in space.
	# Pivot height is per-skin, not per-movement-profile — different character
	# proportions need different lean pivots.
	var pivot: Vector3 = Vector3(0, _skin.lean_pivot_height, 0)
	var tilt_basis: Basis = Basis(Vector3.RIGHT, final_pitch) * Basis(Vector3.BACK, final_roll)
	var full_basis: Basis = Basis(Vector3.UP, new_yaw) * tilt_basis
	# Pivot-compensation offset uses the UNSCALED rotation basis, otherwise
	# scale gets multiplied into the pivot and drops the skin below the floor.
	var origin_offset: Vector3 = pivot - full_basis * pivot
	var tilt_magnitude: float = sqrt(final_pitch * final_pitch + final_roll * final_roll)
	origin_offset.y -= tilt_magnitude * profile.tilt_height_drop
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

	# Horizontal movement.
	var y_velocity := velocity.y
	var on_floor := is_on_floor()
	var air_mult := 1.0 if on_floor else profile.air_accel_mult
	var accel_now := profile.accel * air_mult
	var friction_now := profile.friction * air_mult

	if move_direction.length() > 0.01:
		var h_dir := h_vel.normalized() if h_vel.length() > 0.1 else move_direction
		var steered := h_dir.slerp(move_direction, clamp(profile.turn_rate * delta, 0.0, 1.0))
		# Crouch / sneak slows the player in EITHER profile (the post-hacking
		# sneak mechanic engages while the player's still on skates from L1).
		# Skin's crouch state plays the same Crouching pose either way.
		var crouch_mult := 1.0
		if intent.crouch_held and is_on_floor():
			crouch_mult = crouch_speed_multiplier
		var target_vel := steered * profile.max_speed * move_magnitude * crouch_mult
		h_vel = h_vel.move_toward(target_vel, accel_now * delta)
	else:
		h_vel = h_vel.move_toward(Vector3.ZERO, friction_now * delta)
		if profile.stopping_speed > 0.0 and h_vel.length_squared() < profile.stopping_speed * profile.stopping_speed:
			h_vel = Vector3.ZERO

	velocity = Vector3(h_vel.x, y_velocity + _gravity * delta, h_vel.z)

	# Animations and FX.
	if on_floor:
		_air_jump_available = true
	var ground_speed := Vector2(velocity.x, velocity.z).length()
	var is_just_jumping := intent.jump_pressed and on_floor
	var is_air_jumping := (intent.jump_pressed and not on_floor and _air_jump_available
		and not _wall_ride_active)

	# Attack jostle is purely procedural (velocity kick + skin pitch) so we
	# just let the timer tick down — no animation state to enter/exit.
	if _attack_timer > 0.0:
		_attack_timer = maxf(0.0, _attack_timer - delta)
	# Active swing window: re-sweep each frame so the forward lunge can
	# catch enemies the initial press missed.
	if _attack_active_timer > 0.0:
		_attack_active_timer = maxf(0.0, _attack_active_timer - delta)
		_sweep_attack()

	if is_just_jumping:
		velocity.y += profile.jump_impulse
		_jump_sound.play()
	elif is_air_jumping:
		velocity.y = profile.jump_impulse
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
	var is_attacking_now := _attack_active_timer > 0.0
	if not _wall_ride_active and not is_visual_dashing and not is_crouching_now and not is_attacking_now:
		if is_just_jumping or is_air_jumping:
			_skin.jump()
		elif not on_floor and velocity.y < 0:
			_skin.fall()
		elif on_floor:
			if ground_speed > 0.0:
				_skin.move()
			else:
				_skin.idle()

	# Ground dust — body decides "should it emit" (needs ground/speed/crouch
	# state), skin decides "from where" (emitter lives in skin-local space
	# so the offset auto-tracks yaw without extra math).
	_skin.set_dust_emitting(on_floor && ground_speed > 0.0 && not intent.crouch_held)

	if on_floor and not _was_on_floor_last_frame:
		_landing_sound.play()
		if _skin != null:
			_skin.land()

	# Wall ride (only runs if the current profile enables it).
	if profile.wall_ride_duration > 0.0:
		_update_wall_ride(delta, profile, intent)

	_was_on_floor_last_frame = on_floor
	move_and_slide()

	_update_follow_camera(delta)


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
	var jumped: bool = intent.jump_pressed
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

	# Fall only when the smoothed NATURAL lean exceeds the threshold
	# (counter input is ignored for this check).
	if absf(_natural_lean_roll) > profile.grind_fall_threshold:
		_grinding = false
		_grind_rail = null
		velocity.y += 2.0
		return

	# Player counter-balance: project world-space move intent onto the camera's
	# right axis so keyboard "A/D" gives the expected screen-relative lean.
	var cam_right: Vector3 = _camera.global_basis.x
	var balance_x: float = intent.move_direction.dot(cam_right)
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
		# The Sprinting Forward Roll only reads as a roll if you're on the
		# ground. Air-dashing into a roll looks like a sideways flop — skip
		# the visual so the in-air dash just keeps the existing fall/jump
		# pose. Gameplay impulse + i-frames still fire either way.
		var grounded_now: bool = is_on_floor()
		if grounded_now:
			_dash_visual_timer = dash_visual_duration
			if _skin != null:
				_skin.dash(_dash_direction)
	# While active, override horizontal velocity to the dash vector.
	# dash_preserves_y keeps jump / fall momentum intact.
	if _dash_timer > 0.0:
		velocity.x = _dash_direction.x * dash_speed
		velocity.z = _dash_direction.z * dash_speed
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


func _process(delta: float) -> void:
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


func _register_debug_panel() -> void:
	DebugPanel.add_enum("Camera/Follow/mode", PackedStringArray(["PARENTED", "DETACHED"]),
		func() -> int: return int(follow_mode),
		func(v: int) -> void:
			follow_mode = FollowMode.PARENTED if v == 0 else FollowMode.DETACHED
			_apply_follow_mode())
	DebugPanel.add_slider("Camera/Follow/angle_smoothing", 0.001, 0.3, 0.001,
		func() -> float: return angle_smoothing,
		func(v: float) -> void: angle_smoothing = v)
	DebugPanel.add_slider("Camera/Follow/position_smoothing", 0.001, 0.3, 0.001,
		func() -> float: return position_smoothing,
		func(v: float) -> void: position_smoothing = v)
	DebugPanel.add_slider("Camera/Follow/pivot_offset_y", 0.0, 5.0, 0.05,
		func() -> float: return pivot_offset.y,
		func(v: float) -> void:
			var o := pivot_offset
			o.y = v
			pivot_offset = o)
	DebugPanel.add_slider("Camera/SpringArm/length", 1.0, 25.0, 0.1,
		func() -> float: return _spring.spring_length,
		func(v: float) -> void: _spring.spring_length = v)
	DebugPanel.add_slider("Camera/SpringArm/smooth_rate", 0.5, 30.0, 0.1,
		func() -> float: return spring_smooth_rate,
		func(v: float) -> void: spring_smooth_rate = v)
	DebugPanel.add_slider("Camera/SpringArm/margin", 0.0, 3.0, 0.05,
		func() -> float: return _spring.margin,
		func(v: float) -> void:
			_spring.margin = v
			spring_margin = v)
	DebugPanel.add_slider("Camera/SpringArm/cast_radius", 0.05, 1.0, 0.05,
		func() -> float: return spring_cast_radius,
		func(v: float) -> void:
			spring_cast_radius = v
			if _spring.shape is SphereShape3D:
				(_spring.shape as SphereShape3D).radius = v)
	DebugPanel.add_slider("Camera/SpringArm/min_distance", 0.0, 10.0, 0.1,
		func() -> float: return min_camera_distance,
		func(v: float) -> void: min_camera_distance = v)
	if walk_profile != null:
		DebugPanel.add_slider("Skin/Lean/walk/forward", -0.5, 0.5, 0.005,
			func() -> float: return walk_profile.forward_lean_amount,
			func(v: float) -> void: walk_profile.forward_lean_amount = v)
		DebugPanel.add_slider("Skin/Lean/walk/side", -0.15, 0.15, 0.001,
			func() -> float: return walk_profile.side_lean_amount,
			func(v: float) -> void: walk_profile.side_lean_amount = v)
		DebugPanel.add_slider("Skin/Lean/walk/smoothing", 0.5, 20.0, 0.1,
			func() -> float: return walk_profile.lean_smoothing,
			func(v: float) -> void: walk_profile.lean_smoothing = v)
	if skate_profile != null:
		DebugPanel.add_slider("Movement/skate/max_speed", 1.0, 30.0, 0.1,
			func() -> float: return skate_profile.max_speed,
			func(v: float) -> void: skate_profile.max_speed = v)
		DebugPanel.add_slider("Movement/skate/accel", 0.5, 100.0, 0.5,
			func() -> float: return skate_profile.accel,
			func(v: float) -> void: skate_profile.accel = v)
		DebugPanel.add_slider("Movement/skate/friction", 0.0, 60.0, 0.5,
			func() -> float: return skate_profile.friction,
			func(v: float) -> void: skate_profile.friction = v)
		DebugPanel.add_slider("Movement/skate/air_accel_mult", 0.0, 1.0, 0.02,
			func() -> float: return skate_profile.air_accel_mult,
			func(v: float) -> void: skate_profile.air_accel_mult = v)
		DebugPanel.add_slider("Movement/skate/turn_rate", 0.5, 50.0, 0.1,
			func() -> float: return skate_profile.turn_rate,
			func(v: float) -> void: skate_profile.turn_rate = v)
		DebugPanel.add_slider("Movement/skate/jump_impulse", 1.0, 30.0, 0.25,
			func() -> float: return skate_profile.jump_impulse,
			func(v: float) -> void: skate_profile.jump_impulse = v)
		DebugPanel.add_slider("Movement/skate/rotation_speed", 0.5, 30.0, 0.25,
			func() -> float: return skate_profile.rotation_speed,
			func(v: float) -> void: skate_profile.rotation_speed = v)
		DebugPanel.add_slider("Movement/skate/stopping_speed", 0.0, 5.0, 0.05,
			func() -> float: return skate_profile.stopping_speed,
			func(v: float) -> void: skate_profile.stopping_speed = v)
		DebugPanel.add_toggle("Movement/skate/face_velocity",
			func() -> bool: return skate_profile.face_velocity,
			func(v: bool) -> void: skate_profile.face_velocity = v)
		DebugPanel.add_slider("Movement/skate/wall_ride_duration", 0.0, 5.0, 0.1,
			func() -> float: return skate_profile.wall_ride_duration,
			func(v: float) -> void: skate_profile.wall_ride_duration = v)
		DebugPanel.add_slider("Movement/skate/wall_ride_min_speed", 0.0, 20.0, 0.1,
			func() -> float: return skate_profile.wall_ride_min_speed,
			func(v: float) -> void: skate_profile.wall_ride_min_speed = v)
		DebugPanel.add_slider("Movement/skate/wall_ride_gravity", 0.0, 1.0, 0.05,
			func() -> float: return skate_profile.wall_ride_gravity_scale,
			func(v: float) -> void: skate_profile.wall_ride_gravity_scale = v)
		DebugPanel.add_slider("Movement/skate/wall_ride_reach", 0.3, 3.0, 0.05,
			func() -> float: return skate_profile.wall_ride_reach,
			func(v: float) -> void: skate_profile.wall_ride_reach = v)
		DebugPanel.add_slider("Movement/skate/wall_ride_jump_push", 0.0, 40.0, 0.5,
			func() -> float: return skate_profile.wall_ride_jump_push,
			func(v: float) -> void: skate_profile.wall_ride_jump_push = v)
		DebugPanel.add_slider("Movement/skate/wall_ride_max_tilt_deg", 0.0, 90.0, 0.5,
			func() -> float: return skate_profile.wall_ride_max_tilt_deg,
			func(v: float) -> void: skate_profile.wall_ride_max_tilt_deg = v)
		DebugPanel.add_slider("Movement/skate/grind_speed", 0.0, 30.0, 0.25,
			func() -> float: return skate_profile.grind_speed,
			func(v: float) -> void: skate_profile.grind_speed = v)
		DebugPanel.add_slider("Movement/skate/grind_exit_boost", 0.0, 15.0, 0.25,
			func() -> float: return skate_profile.grind_exit_boost,
			func(v: float) -> void: skate_profile.grind_exit_boost = v)
		DebugPanel.add_slider("Movement/skate/grind_yaw_offset_deg", -90.0, 90.0, 1.0,
			func() -> float: return skate_profile.grind_yaw_offset_deg,
			func(v: float) -> void: skate_profile.grind_yaw_offset_deg = v)
		DebugPanel.add_slider("Movement/skate/grind_counter_strength", 0.0, 10.0, 0.1,
			func() -> float: return skate_profile.grind_counter_strength,
			func(v: float) -> void: skate_profile.grind_counter_strength = v)
		DebugPanel.add_slider("Movement/skate/grind_fall_threshold", 0.1, 12.0, 0.1,
			func() -> float: return skate_profile.grind_fall_threshold,
			func(v: float) -> void: skate_profile.grind_fall_threshold = v)
		DebugPanel.add_slider("Movement/skate/grind_lean_multiplier", 0.0, 10.0, 0.1,
			func() -> float: return skate_profile.grind_lean_multiplier,
			func(v: float) -> void: skate_profile.grind_lean_multiplier = v)
		DebugPanel.add_slider("Skin/Sway/skate/duration", 0.0, 5.0, 0.1,
			func() -> float: return skate_profile.speedup_duration,
			func(v: float) -> void: skate_profile.speedup_duration = v)
		DebugPanel.add_slider("Skin/Sway/skate/amplitude", 0.0, 0.5, 0.005,
			func() -> float: return skate_profile.speedup_amplitude,
			func(v: float) -> void: skate_profile.speedup_amplitude = v)
		DebugPanel.add_slider("Skin/Sway/skate/frequency", 0.2, 8.0, 0.1,
			func() -> float: return skate_profile.speedup_frequency,
			func(v: float) -> void: skate_profile.speedup_frequency = v)
		DebugPanel.add_slider("Skin/Sway/skate/pivot_height", 0.0, 3.0, 0.05,
			func() -> float: return _skin.lean_pivot_height,
			func(v: float) -> void: _skin.lean_pivot_height = v)
		DebugPanel.add_slider("Skin/Sway/skate/cruise_amplitude", 0.0, 1.0, 0.01,
			func() -> float: return skate_profile.cruise_sway_amplitude,
			func(v: float) -> void: skate_profile.cruise_sway_amplitude = v)
	if walk_profile != null:
		DebugPanel.add_slider("Skin/Lean/walk/tilt_height_drop", 0.0, 2.0, 0.02,
			func() -> float: return walk_profile.tilt_height_drop,
			func(v: float) -> void: walk_profile.tilt_height_drop = v)
	if skate_profile != null:
		DebugPanel.add_slider("Skin/Lean/skate/tilt_height_drop", 0.0, 2.0, 0.02,
			func() -> float: return skate_profile.tilt_height_drop,
			func(v: float) -> void: skate_profile.tilt_height_drop = v)
		DebugPanel.add_slider("Skin/Lean/skate/brake_impulse", -0.6, 0.6, 0.02,
			func() -> float: return skate_profile.brake_impulse_amount,
			func(v: float) -> void: skate_profile.brake_impulse_amount = v)
		DebugPanel.add_slider("Skin/Lean/skate/brake_decay", 0.5, 15.0, 0.1,
			func() -> float: return skate_profile.brake_impulse_decay,
			func(v: float) -> void: skate_profile.brake_impulse_decay = v)
		DebugPanel.add_slider("Skin/Lean/skate/forward", -0.5, 0.5, 0.005,
			func() -> float: return skate_profile.forward_lean_amount,
			func(v: float) -> void: skate_profile.forward_lean_amount = v)
		DebugPanel.add_slider("Skin/Lean/skate/side", -0.15, 0.15, 0.001,
			func() -> float: return skate_profile.side_lean_amount,
			func(v: float) -> void: skate_profile.side_lean_amount = v)
		DebugPanel.add_slider("Skin/Lean/skate/smoothing", 0.5, 20.0, 0.1,
			func() -> float: return skate_profile.lean_smoothing,
			func(v: float) -> void: skate_profile.lean_smoothing = v)
	DebugPanel.add_slider("Camera/SpringArm/base_pitch_deg", -60.0, 10.0, 0.5,
		func() -> float: return rad_to_deg(_base_pitch),
		func(v: float) -> void: _base_pitch = deg_to_rad(v))
	DebugPanel.add_slider("Camera/Mouse/pitch_return_delay", 0.0, 3.0, 0.05,
		func() -> float: return pitch_return_delay,
		func(v: float) -> void: pitch_return_delay = v)
	DebugPanel.add_slider("Camera/Mouse/pitch_return_rate", 0.1, 10.0, 0.1,
		func() -> float: return pitch_return_rate,
		func(v: float) -> void: pitch_return_rate = v)
	DebugPanel.add_slider("Camera/Camera3D/fov", 30.0, 110.0, 1.0,
		func() -> float: return _camera.fov,
		func(v: float) -> void: _camera.fov = v)
	DebugPanel.add_slider("Camera/Mouse/x_sensitivity", 0.0, 0.02, 0.0005,
		func() -> float: return mouse_x_sensitivity,
		func(v: float) -> void: mouse_x_sensitivity = v)
	DebugPanel.add_slider("Camera/Mouse/y_sensitivity", 0.0, 0.02, 0.0005,
		func() -> float: return mouse_y_sensitivity,
		func(v: float) -> void: mouse_y_sensitivity = v)
	DebugPanel.add_toggle("Camera/Mouse/invert_y",
		func() -> bool: return invert_y,
		func(v: bool) -> void: invert_y = v)
	DebugPanel.add_slider("Camera/Mouse/release_delay", 0.0, 5.0, 0.1,
		func() -> float: return mouse_release_delay,
		func(v: float) -> void: mouse_release_delay = v)
	DebugPanel.add_slider("Camera/Mouse/blend_time", 0.0, 2.0, 0.05,
		func() -> float: return mouse_blend_time,
		func(v: float) -> void: mouse_blend_time = v)
	DebugPanel.add_readout("Debug/h_speed",
		func() -> String: return "%.1f m/s" % Vector2(velocity.x, velocity.z).length())


func _update_follow_camera(delta: float) -> void:
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
