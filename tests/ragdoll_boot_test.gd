extends Node3D

## Behavioral gate for the ragdoll death. Boots with full autoloads (run as a
## scene, not a SceneTree script): floor + one green KayKit enemy, kill it,
## log what the physical bones actually do, then verify the corpse ragdolled,
## drifted from the body origin, and queue_freed at the end of the timeline.
## Run: godot --headless --fixed-fps 60 res://tests/ragdoll_boot_test.tscn --quit-after 900
## (--fixed-fps is required: uncapped headless iterations outrun the 60 Hz
## physics clock, so without it only ~20 physics ticks happen in 900 frames.)

const ENEMY_SCENE := "res://enemy/enemy_kaykit.tscn"

var _enemy: CharacterBody3D
var _enemy_ref: WeakRef
var _skin: Node
var _frame := 0
var _kill_frame := -1
var _last_logged_hips := Vector3.INF
var _ragdoll_seen := false
var _hips_path_len := 0.0
var _prev_hips := Vector3.INF


func _ready() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	cs.shape = box
	floor_body.add_child(cs)
	floor_body.position = Vector3(0, -0.5, 0)
	add_child(floor_body)

	var scene: PackedScene = load(ENEMY_SCENE)
	_enemy = scene.instantiate()
	add_child(_enemy)
	_enemy.global_position = Vector3(0, 0.1, 0)
	_enemy_ref = weakref(_enemy)
	print("[ragdoll-test] enemy spawned")


func _physics_process(_delta: float) -> void:
	_frame += 1
	if _frame == 30:
		_skin = _find_kaykit_skin(_enemy)
		if _skin == null:
			print("[ragdoll-test] FAIL: no KayKitSkin found on enemy")
			get_tree().quit(1)
			return
		_kill_frame = _frame
		print("[ragdoll-test] killing enemy (take_hit) at frame %d" % _frame)
		_enemy.take_hit(Vector3.FORWARD, 10.0, 99)
		return
	if _kill_frame < 0:
		return

	var alive: bool = _enemy_ref.get_ref() != null
	if alive and not _ragdoll_seen and _skin.call(&"is_ragdolled"):
		_ragdoll_seen = true
		print("[ragdoll-test] ragdoll ACTIVE at frame %d (+%d after kill)" % [_frame, _frame - _kill_frame])

	if alive and _ragdoll_seen:
		var hips: Vector3 = _skin.call(&"ragdoll_reference_position")
		if _prev_hips != Vector3.INF:
			_hips_path_len += hips.distance_to(_prev_hips)
		_prev_hips = hips
		# Deduped state log: only when hips moved > 10 cm since last print.
		if _last_logged_hips == Vector3.INF or hips.distance_to(_last_logged_hips) > 0.1:
			_last_logged_hips = hips
			print("[ragdoll-test] f=%d hips=(%.2f, %.2f, %.2f)" % [_frame, hips.x, hips.y, hips.z])

	if not alive:
		# Final state, flat: did we ragdoll, how far did the hips travel, did
		# the corpse land near the floor before the poof?
		var landed: bool = _prev_hips != Vector3.INF and _prev_hips.y < 0.6
		print("[ragdoll-test] enemy freed at frame %d (+%d after kill)" % [_frame, _frame - _kill_frame])
		print("[ragdoll-test] RESULT ragdolled=%s hips_path=%.2fm final_hips_y=%.2f landed=%s" % [
			_ragdoll_seen, _hips_path_len, _prev_hips.y if _prev_hips != Vector3.INF else -99.0, landed])
		var ok: bool = _ragdoll_seen and _hips_path_len > 0.5 and landed
		print("[ragdoll-test] %s" % ("PASS" if ok else "FAIL"))
		get_tree().quit(0 if ok else 1)


func _find_kaykit_skin(n: Node) -> Node:
	if n.get_script() != null and n.has_method(&"start_ragdoll"):
		return n
	for c: Node in n.get_children():
		var r := _find_kaykit_skin(c)
		if r != null:
			return r
	return null
