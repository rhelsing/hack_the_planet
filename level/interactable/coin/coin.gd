extends Area3D

## Full rotations per second while idle.
@export var spin_speed := 0.7
## Seconds for the coin to fly into the player after being triggered.
@export var collect_duration := 0.28
## Local offset on the player to aim the absorb at (roughly torso height).
@export var collect_target_offset := Vector3(0.0, 1.0, 0.0)

@onready var _mesh: Node3D = $Sketchfab_Scene

var _target: Node3D
var _collect_timer := 0.0
var _collect_start_pos := Vector3.ZERO


func _ready() -> void:
	# Permanence: if this coin's path is in the persisted collected-set,
	# it was picked up in this or an earlier session. Vanish silently
	# without registering or arming — the HUD's coin_total / coin_count
	# already reflect this coin via the loaded sets.
	if GameState.is_coin_collected(self):
		queue_free()
		return
	body_entered.connect(_on_body_entered)
	# Register with the global tally so the HUD denominator (#/total) and
	# completion ratio reflect every authored coin in the session. Path-
	# deduped — re-entering a level doesn't double-count.
	GameState.register_coin(self)


func _process(delta: float) -> void:
	if _target != null and is_instance_valid(_target):
		_update_collect(delta)
		return
	if _mesh != null:
		_mesh.rotate_y(spin_speed * TAU * delta)


func _update_collect(delta: float) -> void:
	_collect_timer += delta
	var t: float = clampf(_collect_timer / maxf(collect_duration, 0.0001), 0.0, 1.0)
	# Ease-in: slow start, accelerates toward the player — reads as "sucked up."
	var eased: float = t * t
	var target_pos: Vector3 = _target.global_position + collect_target_offset
	global_position = _collect_start_pos.lerp(target_pos, eased)
	scale = Vector3.ONE * (1.0 - eased)
	# Spin up as it shrinks for extra "absorb" flair.
	if _mesh != null:
		_mesh.rotate_y(spin_speed * TAU * (1.0 + 3.0 * eased) * delta)
	if t >= 1.0:
		queue_free()


func _on_body_entered(body: Node) -> void:
	if _target != null:
		return
	if not body.is_in_group("player"):
		return
	# Emit on trigger (not on animation end) so sound / score respond instantly.
	Events.coin_collected.emit(self)
	_target = body as Node3D
	_collect_start_pos = global_position
	_collect_timer = 0.0
	# Prevent re-triggering if the player lingers overlapping us. Deferred
	# because Godot 4 disallows mutating Area3D state inside its own signal
	# dispatch — direct assignment works but spams an engine error per coin.
	set_deferred("monitoring", false)
