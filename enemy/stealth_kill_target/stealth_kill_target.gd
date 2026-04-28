class_name StealthKillTarget
extends Interactable

## Press-E hack-takedown for splice-stealth enemies. Drops as a child of
## the pawn (a PlayerBody-based enemy). The InteractionSensor offers the
## "[E] hack" prompt only when:
##   1. Player has the powerup_secret flag (the hacker power-up).
##   2. Player is BEHIND the pawn — dot-product check against the pawn's
##      facing, gated by `behind_dot_threshold`.
##   3. Pawn isn't already dying / dead.
##
## On interact, the parent pawn's stealth_kill() runs: glitch overlay
## ramps to 1, skin tilts to lying-on-back, confetti bursts, queue_free.
## No knockback launch — they fall over in place.

## How "behind" the player must be. dot(pawn_forward, pawn→player) ≤ this
## threshold = behind. -1.0 = directly behind only; 0.0 = anywhere in the
## back hemisphere (180° arc); 0.3 = ~70° back arc (forgiving, easy to
## sneak up on). Default 0.0 = back-hemisphere only.
@export_range(-1.0, 1.0) var behind_dot_threshold: float = 0.0

## Required GameState flag for the prompt to even show. Empty = always
## show. Defaults to "powerup_secret" so only hackers see the [E] hack
## prompt on splice-stealth pawns.
@export var required_powerup: StringName = &"powerup_secret"


func _ready() -> void:
	super._ready()
	if prompt_verb == "interact":
		prompt_verb = "hack"


# Powerup gate + behind-the-back gate. The base Interactable.can_interact
# already covers requires_key / requires_flag — we layer the powerup +
# behind checks on top so the prompt visibility tracks position in real
# time (sensor scoring re-evaluates each tick).
func can_interact(actor: Node3D) -> bool:
	var super_pass: bool = super.can_interact(actor)
	if not super_pass:
		print("[skt-dbg] FAIL super.can_interact (requires_key=%s requires_flag=%s) actor=%s" % [
			requires_key, requires_flag, actor])
		return false
	# Global gates: powerup + alive. is_locked() calls this with actor=null;
	# we want "no powerup" → locked, "in front of enemy" → just hidden.
	if required_powerup != &"":
		var has_powerup: bool = bool(GameState.get_flag(required_powerup, false))
		if not has_powerup:
			print("[skt-dbg] FAIL powerup '%s' not set actor=%s" % [required_powerup, actor])
			return false
	var pawn: Node3D = get_parent() as Node3D
	if pawn == null or not is_instance_valid(pawn):
		print("[skt-dbg] FAIL pawn invalid (parent=%s) actor=%s" % [pawn, actor])
		return false
	if "is_dying" in pawn and bool(pawn.call(&"is_dying")):
		print("[skt-dbg] FAIL pawn is_dying actor=%s" % [actor])
		return false
	# Dynamic behind check — skipped when actor is null (is_locked path).
	if actor == null:
		print("[skt-dbg] PASS (null actor / lock-check) — unlocked")
		return true
	var pawn_forward: Vector3 = _pawn_forward(pawn)
	if pawn_forward.length_squared() < 0.0001:
		print("[skt-dbg] PASS (no facing) actor=%s" % actor)
		return true
	var to_actor: Vector3 = actor.global_position - pawn.global_position
	to_actor.y = 0.0
	if to_actor.length_squared() < 0.0001:
		return true
	to_actor = to_actor.normalized()
	var dot: float = pawn_forward.dot(to_actor)
	var behind: bool = dot <= behind_dot_threshold
	print("[skt-dbg] %s behind-check dot=%.2f thresh=%.2f → %s" % [
		"PASS" if behind else "FAIL", dot, behind_dot_threshold,
		"behind" if behind else "in front"])
	return behind


func describe_lock() -> String:
	if required_powerup != &"" and not GameState.get_flag(required_powerup, false):
		return "needs " + str(required_powerup).capitalize()
	return super.describe_lock()


func interact(actor: Node3D) -> void:
	var pawn: Node3D = get_parent() as Node3D
	if pawn == null or not pawn.has_method(&"stealth_kill"):
		push_warning("StealthKillTarget %s: parent %s has no stealth_kill()" % [
			interactable_id, pawn])
		return
	# Push the pawn from the player's direction so the lying pose orients
	# their head away from the kill — same skin-tilt the regular knockback
	# death uses, just no launch.
	var from_dir: Vector3 = (pawn.global_position - actor.global_position) if actor != null else Vector3.BACK
	pawn.call(&"stealth_kill", from_dir)


# Best-effort "what direction is the pawn facing" lookup. PlayerBody stores
# yaw in _yaw_state and applies it to its skin each tick. Convention:
# yaw=0 → forward = Vector3.BACK (matching the body's face_target math
# at line ~1711 of player_body.gd), so forward = BACK rotated by yaw.
static func _pawn_forward(pawn: Node3D) -> Vector3:
	if "_yaw_state" in pawn:
		var yaw: float = float(pawn.get(&"_yaw_state"))
		return Vector3.BACK.rotated(Vector3.UP, yaw)
	return -pawn.global_basis.z
