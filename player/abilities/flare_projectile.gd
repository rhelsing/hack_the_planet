extends RigidBody3D

## Simple lobbed flare. Spawned by FlareAbility with an initial velocity,
## falls under gravity, lights the environment via the OmniLight3D child,
## and self-destructs on contact OR after MAX_LIFE seconds. If the contact
## body is in the "enemies" group, forwards a take_hit call so the flare
## doubles as an anti-enemy projectile.

const MAX_LIFE: float = 3.0
const IMPACT_FORCE: float = 8.0

var _life: float = 0.0
var _expired: bool = false
## The pawn that fired us — body_entered skips it so the flare doesn't
## detonate on the shooter's own collision shape the frame it spawns.
var _owner_pawn: Node = null


func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_body_entered)


## Called immediately after instantiation. owner is the firing pawn (the
## flare skips self-damage); initial_velocity is world-space m/s.
func setup(owner_pawn: Node, initial_velocity: Vector3) -> void:
	_owner_pawn = owner_pawn
	linear_velocity = initial_velocity


func _physics_process(delta: float) -> void:
	if _expired:
		return
	_life += delta
	if _life >= MAX_LIFE:
		_impact(null)


func _on_body_entered(body: Node) -> void:
	if _expired:
		return
	if body == _owner_pawn:
		return
	# Only detonate on enemies. World hits (ground, walls) let the RigidBody3D
	# handle a physical bounce — the flare keeps rolling until it hits an
	# enemy or MAX_LIFE expires. Means a short-arc shot can still connect
	# after bouncing once or twice.
	if body.is_in_group(&"enemies"):
		print("[flare] hit enemy %s" % body.name)
		_impact(body)


func _impact(hit: Node) -> void:
	_expired = true
	if hit != null and hit.is_in_group(&"enemies") and hit.has_method(&"take_hit"):
		var impact_dir: Vector3 = Vector3.UP
		if hit is Node3D:
			var d: Vector3 = (hit as Node3D).global_position - global_position
			if d.length_squared() > 0.0001:
				impact_dir = d.normalized()
		hit.call(&"take_hit", impact_dir, IMPACT_FORCE)
	queue_free()
