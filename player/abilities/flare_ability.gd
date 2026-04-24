class_name FlareAbility
extends Ability

## Lobbed projectile flare. On flare_shoot input, spawns a RigidBody3D
## projectile (flare_projectile.tscn) with an arcing initial velocity. The
## projectile handles its own physics + lifetime + enemy-damage.

const _PROJECTILE_SCENE := preload("res://player/abilities/flare_projectile.tscn")
## Forward velocity (m/s) along the camera's look direction.
const _LAUNCH_FORWARD: float = 12.0
## Upward boost (m/s) added on top. Tuned so aiming horizontally produces a
## clear arc that lands ~24m ahead — the flare visibly lobs over and comes
## down to hit something straight ahead without aiming up.
const _LAUNCH_UP: float = 10.0


func _ready() -> void:
	if ability_id == &"":
		ability_id = &"FlareAbility"
	if powerup_flag == &"":
		powerup_flag = &"powerup_god"
	super._ready()


func _unhandled_input(event: InputEvent) -> void:
	if not owned:
		return
	if event.is_action_pressed("flare_shoot"):
		_fire()


func _fire() -> void:
	var body := _find_body()
	if body == null:
		return
	var body_3d: Node3D = body as Node3D
	if body_3d == null:
		return
	var camera: Camera3D = body.get_node_or_null(^"CameraPivot/SpringArm3D/Camera3D") as Camera3D
	if camera == null:
		return

	var forward: Vector3 = -camera.global_transform.basis.z
	var spawn_pos: Vector3 = body_3d.global_position + Vector3(0, 1.2, 0) + forward * 0.6
	var launch_velocity: Vector3 = forward * _LAUNCH_FORWARD + Vector3.UP * _LAUNCH_UP

	var projectile := _PROJECTILE_SCENE.instantiate()
	get_tree().current_scene.add_child(projectile)
	projectile.global_position = spawn_pos
	if projectile.has_method(&"setup"):
		projectile.call(&"setup", body, launch_velocity)
