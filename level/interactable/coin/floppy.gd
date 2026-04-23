extends Area3D
## Auto-trigger floppy pickup — mirrors coin.gd's "fly into the player" feel
## but adds to GameState inventory as `&"floppy_disk"` so interactables_dev's
## GameState subscriber bumps `floppy_count` and the HUD counter pops the
## 💾 row. Visually uses floppy.glb (same model coin.tscn uses).

@export var spin_speed := 0.7
@export var collect_duration := 0.28
@export var collect_target_offset := Vector3(0.0, 1.0, 0.0)

@onready var _mesh: Node3D = $Sketchfab_Scene

var _target: Node3D
var _collect_timer := 0.0
var _collect_start_pos := Vector3.ZERO


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _process(delta: float) -> void:
	if _target != null and is_instance_valid(_target):
		_update_collect(delta)
		return
	if _mesh != null:
		_mesh.rotate_y(spin_speed * TAU * delta)


func _update_collect(delta: float) -> void:
	_collect_timer += delta
	var t: float = clampf(_collect_timer / maxf(collect_duration, 0.0001), 0.0, 1.0)
	var eased: float = t * t
	var target_pos: Vector3 = _target.global_position + collect_target_offset
	global_position = _collect_start_pos.lerp(target_pos, eased)
	scale = Vector3.ONE * (1.0 - eased)
	if _mesh != null:
		_mesh.rotate_y(spin_speed * TAU * (1.0 + 3.0 * eased) * delta)
	if t >= 1.0:
		queue_free()


func _on_body_entered(body: Node) -> void:
	if _target != null:
		return
	if not body.is_in_group("player"):
		return
	# Floppies are *counters*, not inventory items — pick up 10 of them and
	# you want count 10, not a deduped set. `GameState.add_item(&"floppy_disk")`
	# would no-op from the second floppy onward because inventory is a set.
	# So we bump the counter directly and fire `item_added` manually — that
	# way Audio's `pickup_ding` subscription still plays and HUD's Counters
	# still pops the 💾 row, but inventory stays clean.
	GameState.floppy_count += 1
	Events.item_added.emit(&"floppy_disk")
	_target = body as Node3D
	_collect_start_pos = global_position
	_collect_timer = 0.0
	monitoring = false
