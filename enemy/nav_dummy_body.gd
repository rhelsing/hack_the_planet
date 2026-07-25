class_name NavDummyBody
extends CharacterBody3D

## Standalone pawn for the nav sandbox — deliberately INDEPENDENT of
## PlayerBody. No shared profiles, camera rig, abilities, factions, or save
## hooks, so nav iteration can never touch game-pawn code paths (the
## skate-profile jump gate bug is the cautionary tale). It shares only the
## Brain/Intent contract: finds a Brain child by type, ticks it, applies
## the intent. A brain proven here drives a real PlayerBody variant later
## with zero changes.

@export var max_speed: float = 5.0
@export var accel: float = 30.0
@export var jump_impulse: float = 14.25
## Horizontal launch speed = max_speed + this, set at the jump instant and
## held constant while airborne (pure ballistic arc, no air steering). Link
## jump reach = (max_speed + boost) * (2 * jump_impulse / gravity) — the
## number nav_test's link insets are tuned against.
@export var jump_horizontal_boost: float = 4.0

## Falling below this Y = fell off the level (the game's KillPlane only
## handles the player). Respawn beside the nearest phone-booth checkpoint,
## or back at the spawn point when the level has none.
@export var kill_y: float = -15.0

# Matches PlayerBody's hardcoded -30.0 so arcs feel like the rest of the game.
const _GRAVITY: float = 30.0

var _brain: Brain = null
var _spawn_transform: Transform3D
# First CharacterSkin child — the swappable visual (cylinder today, kaykit
# or a dog tomorrow). Driven purely through the CharacterSkin contract so
# swapping never touches brain/nav/physics code.
var _skin: CharacterSkin = null
var _anim_state: StringName = &""


func _ready() -> void:
	add_to_group("enemies")
	_spawn_transform = global_transform
	for c: Node in get_children():
		if c is Brain and _brain == null:
			_brain = c
		if c is CharacterSkin and _skin == null:
			_skin = c
	if _brain == null:
		push_error("NavDummyBody %s: no Brain child — pawn will stand still" % name)
	if _skin == null:
		print("[nav] %s: no CharacterSkin child — pawn is invisible" % name)


func _respawn() -> void:
	velocity = Vector3.ZERO
	var best: Node3D = null
	var best_d: float = INF
	for n: Node in get_tree().get_nodes_in_group(&"phone_booths"):
		if n is Node3D:
			var d: float = (n as Node3D).global_position.distance_squared_to(global_position)
			if d < best_d:
				best_d = d
				best = n as Node3D
	if best != null:
		# Beside the booth, not inside its collider.
		global_position = best.global_position + Vector3(1.5, 0.5, 0)
	else:
		global_transform = _spawn_transform
	print("[nav] %s fell below kill_y — respawned at %s" % [
		name, best.name if best != null else "spawn point"])


func _physics_process(delta: float) -> void:
	if global_position.y < kill_y:
		_respawn()
	var intent: Intent = _brain.tick(self, delta) if _brain != null else null
	if intent != null and is_on_floor():
		var h_vel := Vector3(velocity.x, 0.0, velocity.z)
		h_vel = h_vel.move_toward(intent.move_direction * max_speed, accel * delta)
		velocity.x = h_vel.x
		velocity.z = h_vel.z
		if intent.jump_pressed:
			var dir := intent.move_direction.normalized() \
				if intent.move_direction.length() > 0.01 else Vector3.ZERO
			var launch := max_speed + jump_horizontal_boost
			velocity.y = jump_impulse
			velocity.x = dir.x * launch
			velocity.z = dir.z * launch
	if intent != null and intent.attack_pressed and _skin != null:
		_skin.attack()
	velocity.y -= _GRAVITY * delta
	move_and_slide()
	_drive_skin()


## Duck-typed hit contract (PlayerBody's attack sweep calls take_hit on
## group members that expose it). The dummy has no health — a hit WAKES it
## (aggro) and shoves it for feedback instead of hurting it.
func take_hit(impact_direction: Vector3, _force: float, _damage: int = 1, attacker: Node = null) -> void:
	if _brain != null and _brain.has_method(&"aggro_to") and attacker != null:
		_brain.aggro_to(attacker)
	var shove := Vector3(impact_direction.x, 0.0, impact_direction.z)
	if shove.length() > 0.01:
		velocity += shove.normalized() * 3.0


## Facing + animation dispatch through the CharacterSkin contract, states
## deduped so skins get one call per transition (idle/move/jump/fall).
func _drive_skin() -> void:
	if _skin == null:
		return
	var h := Vector3(velocity.x, 0.0, velocity.z)
	if h.length() > 0.5:
		_skin.rotation.y = atan2(h.x, h.z)  # skins face +Z
	_skin.set_walk_speed_scale(clampf(h.length() / maxf(max_speed, 0.001), 0.0, 1.0))
	var next: StringName
	if not is_on_floor():
		next = &"jump" if velocity.y > 0.5 else &"fall"
	elif h.length() > 0.5:
		next = &"move"
	else:
		next = &"idle"
	if next == _anim_state:
		return
	_anim_state = next
	match next:
		&"idle": _skin.idle()
		&"move": _skin.move()
		&"jump": _skin.jump()
		&"fall": _skin.fall()
