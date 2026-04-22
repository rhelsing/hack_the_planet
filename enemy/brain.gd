class_name EnemyBrain
extends Brain

## AI brain base — extends the universal Brain so the same bodies can be
## driven by player input, AI, or networked replication.
##
## Subclasses override tick(body, delta) and return an Intent. For enemies,
## intent.move_direction carries desired horizontal velocity in m/s (the
## Enemy body applies it directly, then layers gravity). Magnitude > 1 is
## fine — it just means "go faster". intent.jump_pressed and attack_pressed
## are edge-triggered; set them true for exactly one tick to fire.
##
## Legacy helper: subclasses that just want to return a velocity can still
## use think(), which this base wraps into an Intent for them.
func tick(body: Node3D, delta: float) -> Intent:
	var intent := Intent.new()
	# Back-compat: if a subclass overrides think(), route its Vector3 return
	# into intent.move_direction. Subclasses that want richer control
	# (jump/attack) should override tick() directly.
	if body is Enemy:
		intent.move_direction = think(body as Enemy, delta)
	return intent


## Legacy hook for velocity-only brains. New brains should override tick()
## directly and return a full Intent.
func think(_enemy: Enemy, _delta: float) -> Vector3:
	return Vector3.ZERO
