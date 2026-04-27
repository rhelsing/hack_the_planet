class_name EnemySpawner
extends Node3D

## Proximity-triggered enemy spawner. When `trigger_group` enters the
## TriggerArea, instantiates `enemy_scene`, parks it at FromMarker, and
## glitches it in to ToMarker over `spawn_duration` (lerped position +
## glitch overlay ramped 1→0 on the skin). Enemy physics is disabled
## during the glitch-in so they don't fall mid-arrival.

## Enemy variant to spawn — typically enemy_kaykit.tscn or a tinted variant.
@export var enemy_scene: PackedScene
## Seconds for the glitch-in (position lerp + glitch fade).
@export var spawn_duration: float = 1.0
## Group whose entry triggers the spawn. Empty = any body.
@export var trigger_group: String = "player"
## True = spawns once per playthrough. False = spawns every time the trigger
## fires (with a brief cooldown to avoid double-fires from the same entry).
@export var one_shot: bool = true
## Cooldown between spawns when one_shot is false.
@export var retrigger_cooldown: float = 2.0

@onready var _trigger: Area3D = $TriggerArea
@onready var _from: Node3D = $FromMarker
@onready var _to: Node3D = $ToMarker

var _spawned: bool = false
var _cooldown_until_msec: int = 0


func _ready() -> void:
	if _trigger != null:
		_trigger.body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	if enemy_scene == null:
		return
	if _spawned and one_shot:
		return
	if Time.get_ticks_msec() < _cooldown_until_msec:
		return
	if trigger_group != "" and not body.is_in_group(trigger_group):
		return
	_spawned = true
	_cooldown_until_msec = Time.get_ticks_msec() + int(retrigger_cooldown * 1000.0)
	_spawn_glitch_in()


func _spawn_glitch_in() -> void:
	var enemy: Node3D = enemy_scene.instantiate() as Node3D
	if enemy == null:
		push_error("EnemySpawner: enemy_scene root is not a Node3D")
		return
	# Park the spawned enemy under the current scene root so it survives this
	# spawner being freed (e.g., level reload during the glitch-in).
	get_tree().current_scene.add_child(enemy)
	enemy.global_position = _from.global_position
	# Freeze physics during the glitch-in: gravity + move_and_slide live in
	# PlayerBody._physics_process, so disabling that holds them in midair
	# while the tween drives global_position directly.
	enemy.set_physics_process(false)
	var skin: Node = enemy.get(&"_skin") if &"_skin" in enemy else null
	if skin != null and skin.has_method(&"set_glitch_progress"):
		skin.set_glitch_progress(1.0)
	var to_pos: Vector3 = _to.global_position
	var tw := create_tween()
	tw.tween_property(enemy, "global_position", to_pos, spawn_duration)
	if skin != null and skin.has_method(&"set_glitch_progress"):
		tw.parallel().tween_method(skin.set_glitch_progress, 1.0, 0.0, spawn_duration)
	tw.tween_callback(func() -> void:
		if is_instance_valid(enemy):
			enemy.set_physics_process(true)
	)
