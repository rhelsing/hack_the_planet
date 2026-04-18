class_name Enemy extends CharacterBody3D

@export var move_speed := 3.0
@export var death_burst_scene: PackedScene = preload("res://enemy/confetti_burst.tscn")

@export_group("Animations")
## Animation played when the enemy is standing still.
@export var idle_anim_name := "Riot_Idle"
## Animation played while the enemy is moving (wandering, chasing, or slamming).
@export var run_anim_name := "Riot_Run"
## Animation explicitly played during the killing-blow pause before confetti.
## Usually a tense/attack pose; falls back to idle if the model lacks it.
@export var attack_anim_name := "Riot_Run"
## Horizontal speed above which the run animation is chosen over idle.
@export var anim_run_threshold := 0.4

@export_group("Facing")
## How snappily the enemy rotates around Y to face its heading. Higher = snappier.
@export var face_turn_rate := 10.0

@export_group("Hover")
## If > 0, the enemy floats at this height above whatever ground is directly
## below it (raycast-driven). Gravity is skipped during normal movement and
## only re-enabled during the death jostle so hits send the body arcing.
@export var hover_height := 0.0
@export var hover_smooth := 8.0
@export var hover_probe_depth := 30.0

@export_group("Attack")
## Horizontal distance at which the enemy triggers an attack sequence.
@export var attack_range := 2.0
## Distance within which the slam lands a hit. Keep smaller than attack_range.
@export var attack_strike_range := 1.4
## Seconds between completing one attack and being able to start another.
@export var attack_cooldown := 1.6
## Wind-up — drone pulls back from the player before the slam.
@export var wind_up_duration := 0.35
@export var wind_up_back_speed := 2.0
## Slam — drone rushes toward the player's wind-up-end position.
@export var slam_duration := 0.18
@export var slam_speed := 16.0
## Recover — brief stall before handing control back to the brain.
@export var recover_duration := 0.4
## Knockback applied to the player on a successful slam.
@export var player_knockback_speed := 10.0
@export var player_knockback_up := 3.5

@export_group("Hit Reaction")
## Player hits the enemy can absorb before the death animation fires.
@export var max_health := 3
@export var hit_jostle_speed := 11.0
@export var hit_jostle_hop := 4.5
@export var hit_jostle_duration := 0.12
@export var hit_jostle_drag := 8.0
## Seconds the drone's Attack animation plays on the killing blow before the
## confetti burst. Stops in place mid-hover — the final wind-up and boom.
@export var death_anim_duration := 0.9

enum AttackPhase { IDLE, WIND_UP, SLAM, RECOVER }

var _brain: EnemyBrain
var _gravity := -30.0
var _jostle_timer := 0.0
var _pending_impact := Vector3.RIGHT
var _attack_cooldown_timer := 0.0
var _player: Node3D
var _anim: AnimationPlayer
var _attack_phase: AttackPhase = AttackPhase.IDLE
var _attack_phase_timer := 0.0
var _slam_target := Vector3.ZERO
var _slam_landed := false
var _health := 3
var _death_anim_timer := 0.0


func _ready() -> void:
	add_to_group("enemies")
	_health = max_health
	for child: Node in get_children():
		if child is EnemyBrain:
			_brain = child
			break
	_anim = _find_animation_player(self)
	_play_anim(idle_anim_name)


func _physics_process(delta: float) -> void:
	if _death_anim_timer > 0.0:
		# Hold position while the enemy plays its final anim, then poof.
		_death_anim_timer -= delta
		velocity = Vector3.ZERO
		if hover_height > 0.0:
			move_and_slide()
			_apply_hover(delta)
		if _death_anim_timer <= 0.0:
			_explode()
		return

	if _jostle_timer > 0.0:
		_jostle_timer -= delta
		velocity.y += _gravity * delta
		velocity.x = move_toward(velocity.x, 0.0, hit_jostle_drag * delta)
		velocity.z = move_toward(velocity.z, 0.0, hit_jostle_drag * delta)
		move_and_slide()
		if _jostle_timer <= 0.0 and _health <= 0:
			_begin_death_anim()
		return

	if _attack_cooldown_timer > 0.0:
		_attack_cooldown_timer -= delta

	match _attack_phase:
		AttackPhase.IDLE:
			_physics_idle(delta)
		AttackPhase.WIND_UP:
			_physics_wind_up(delta)
		AttackPhase.SLAM:
			_physics_slam(delta)
		AttackPhase.RECOVER:
			_physics_recover(delta)

	_update_facing(delta)
	_update_movement_anim()


func _physics_idle(delta: float) -> void:
	var h_vel := Vector3.ZERO
	if _brain != null:
		h_vel = _brain.think(self, delta)

	if hover_height > 0.0:
		velocity = Vector3(h_vel.x, 0.0, h_vel.z)
		move_and_slide()
		_apply_hover(delta)
	else:
		velocity = Vector3(h_vel.x, velocity.y + _gravity * delta, h_vel.z)
		move_and_slide()

	_try_trigger_attack()


func _physics_wind_up(delta: float) -> void:
	var back := Vector3.ZERO
	if _player != null and is_instance_valid(_player):
		var to: Vector3 = _player.global_position - global_position
		var horizontal := Vector3(to.x, 0.0, to.z)
		if horizontal.length_squared() > 0.0001:
			back = -horizontal.normalized() * wind_up_back_speed
	velocity = Vector3(back.x, 0.0, back.z)
	if hover_height > 0.0:
		move_and_slide()
		_apply_hover(delta)
	else:
		velocity.y += _gravity * delta
		move_and_slide()

	_attack_phase_timer -= delta
	if _attack_phase_timer <= 0.0:
		_begin_slam()


func _physics_slam(delta: float) -> void:
	# Fly straight at the stored slam target (player's pos at slam start).
	# Gravity + hover are skipped so the lunge reads as a ballistic strike.
	var to_target: Vector3 = _slam_target - global_position
	if to_target.length_squared() > 0.0001:
		velocity = to_target.normalized() * slam_speed
	else:
		velocity = Vector3.ZERO
	move_and_slide()

	if not _slam_landed and _player != null and is_instance_valid(_player):
		var dx: float = _player.global_position.x - global_position.x
		var dz: float = _player.global_position.z - global_position.z
		if dx * dx + dz * dz <= attack_strike_range * attack_strike_range:
			_land_slam()

	_attack_phase_timer -= delta
	if _attack_phase_timer <= 0.0:
		_begin_recover()


func _physics_recover(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, 10.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 10.0 * delta)
	if hover_height > 0.0:
		velocity.y = 0.0
		move_and_slide()
		_apply_hover(delta)
	else:
		velocity.y += _gravity * delta
		move_and_slide()

	_attack_phase_timer -= delta
	if _attack_phase_timer <= 0.0:
		_attack_phase = AttackPhase.IDLE


func _try_trigger_attack() -> void:
	if _attack_cooldown_timer > 0.0:
		return
	if _player == null or not is_instance_valid(_player):
		_player = _find_player()
		if _player == null:
			return
	var dx: float = _player.global_position.x - global_position.x
	var dz: float = _player.global_position.z - global_position.z
	if dx * dx + dz * dz > attack_range * attack_range:
		return
	_begin_wind_up()


func _begin_wind_up() -> void:
	_attack_phase = AttackPhase.WIND_UP
	_attack_phase_timer = wind_up_duration
	_play_anim(attack_anim_name)


func _begin_slam() -> void:
	_attack_phase = AttackPhase.SLAM
	_attack_phase_timer = slam_duration
	_slam_landed = false
	if _player != null and is_instance_valid(_player):
		_slam_target = _player.global_position
	else:
		_slam_target = global_position - global_basis.z


func _land_slam() -> void:
	_slam_landed = true
	var to: Vector3 = _player.global_position - global_position
	var horizontal := Vector3(to.x, 0.0, to.z)
	var dir: Vector3
	if horizontal.length_squared() > 0.0001:
		dir = horizontal.normalized()
	else:
		dir = -global_basis.z
	var impulse: Vector3 = dir * player_knockback_speed + Vector3.UP * player_knockback_up
	Events.enemy_hit_player.emit(impulse)


func _begin_recover() -> void:
	_attack_phase = AttackPhase.RECOVER
	_attack_phase_timer = recover_duration
	_attack_cooldown_timer = attack_cooldown
	_play_anim(idle_anim_name)


func _update_facing(delta: float) -> void:
	# While attacking, face the player so wind-up (moving backward) still
	# reads as the enemy keeping the player in sight.
	var face_dir := Vector3.ZERO
	if _attack_phase != AttackPhase.IDLE and _player != null and is_instance_valid(_player):
		face_dir = _player.global_position - global_position
		face_dir.y = 0.0
	else:
		face_dir = Vector3(velocity.x, 0.0, velocity.z)
	if face_dir.length_squared() < 0.04:
		return
	var target_yaw: float = Vector3.BACK.signed_angle_to(face_dir.normalized(), Vector3.UP)
	var factor := 1.0 - exp(-face_turn_rate * delta)
	rotation.y = lerp_angle(rotation.y, target_yaw, factor)


func _update_movement_anim() -> void:
	# Attack-phase and death animations are explicitly driven — don't override.
	if _death_anim_timer > 0.0 or _jostle_timer > 0.0:
		return
	if _attack_phase != AttackPhase.IDLE:
		_play_anim(run_anim_name)
		return
	var speed_sq: float = velocity.x * velocity.x + velocity.z * velocity.z
	if speed_sq > anim_run_threshold * anim_run_threshold:
		_play_anim(run_anim_name)
	else:
		_play_anim(idle_anim_name)


func _apply_hover(delta: float) -> void:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3.UP * 0.1
	var to := from + Vector3.DOWN * hover_probe_depth
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return
	var ground_y: float = (hit["position"] as Vector3).y
	var target_y: float = ground_y + hover_height
	var factor := 1.0 - exp(-hover_smooth * delta)
	global_position.y = lerpf(global_position.y, target_y, factor)


func _find_player() -> Node3D:
	var tree := get_tree()
	if tree == null:
		return null
	for node: Node in tree.get_nodes_in_group("player"):
		if node is Node3D:
			return node
	return null


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child: Node in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null


func _play_anim(anim_name: String) -> void:
	if _anim == null or anim_name.is_empty():
		return
	if not _anim.has_animation(anim_name):
		return
	if _anim.current_animation == anim_name and _anim.is_playing():
		return
	_anim.play(anim_name)


## Instant-kill. The player's swing is the only thing that calls this, so
## any hit is terminal — spawn confetti aimed along the impact vector and
## despawn the enemy this frame. Second calls during the same frame are
## harmless no-ops because queue_free is deferred.
func hit(impact_direction: Vector3, _force: float) -> void:
	if _death_anim_timer > 0.0:
		return
	_pending_impact = impact_direction
	_explode()


func _begin_death_anim() -> void:
	_death_anim_timer = death_anim_duration
	velocity = Vector3.ZERO
	_play_anim(attack_anim_name)


func _explode() -> void:
	if death_burst_scene != null:
		var burst: Node3D = death_burst_scene.instantiate()
		var aim := (_pending_impact + Vector3.UP * 0.6).normalized()
		burst.call("set_direction", aim)
		get_parent().add_child(burst)
		burst.global_position = global_position
	queue_free()
