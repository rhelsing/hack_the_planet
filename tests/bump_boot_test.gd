extends Node3D

## Behavioral gate for pawn↔pawn bump physics (_apply_contact_physics).
## A ScriptedBrain walker plows into a stationary pawn. Kinematic bodies
## exchange no momentum on their own, so any target displacement comes from
## the bump pass — that's the assert.
## Run: godot --headless --fixed-fps 60 res://tests/bump_boot_test.tscn --quit-after 500

const BODY_SCENE := "res://player/body/player_body.tscn"

var _target: CharacterBody3D
var _walker: CharacterBody3D
var _frame := 0
var _target_start := Vector3.INF
var _last_logged := Vector3.INF


func _ready() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 1, 40)
	cs.shape = box
	floor_body.add_child(cs)
	floor_body.position = Vector3(0, -0.5, 0)
	add_child(floor_body)

	var scene: PackedScene = load(BODY_SCENE)
	_target = scene.instantiate()
	add_child(_target)
	_target.global_position = Vector3(0, 0.1, 0)

	_walker = scene.instantiate()
	add_child(_walker)
	_walker.global_position = Vector3(0, 0.1, 3)
	# Replace the walker's input-driven PlayerBrain with a scripted one that
	# walks -Z (into the target) for 8 seconds straight.
	for c: Node in _walker.get_children():
		if c is Brain:
			c.queue_free()
	var seq: Array[Intent] = []
	for i: int in 480:
		var intent := Intent.new()
		intent.move_direction = Vector3(0, 0, -1)
		seq.append(intent)
	var sb := ScriptedBrain.from_sequence(seq)
	_walker.add_child(sb)
	_walker._brain = sb
	print("[bump-test] pawns spawned: target z=0, walker z=3 walking -Z")


func _physics_process(_delta: float) -> void:
	_frame += 1
	if _frame == 20:
		_target_start = _target.global_position
		return
	if _frame < 20:
		return

	var pos: Vector3 = _target.global_position
	if _last_logged == Vector3.INF or pos.distance_to(_last_logged) > 0.1:
		_last_logged = pos
		print("[bump-test] f=%d target=(%.2f, %.2f, %.2f) walker_z=%.2f" % [
			_frame, pos.x, pos.y, pos.z, _walker.global_position.z])

	if _frame == 320:
		var d: Vector3 = pos - _target_start
		d.y = 0.0
		var walker_reached: bool = _walker.global_position.z < 1.5
		print("[bump-test] RESULT target_displaced=%.2fm walker_reached=%s" % [d.length(), walker_reached])
		var ok: bool = walker_reached and d.length() > 0.5
		print("[bump-test] %s" % ("PASS" if ok else "FAIL"))
		get_tree().quit(0 if ok else 1)
