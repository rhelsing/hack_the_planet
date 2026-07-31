extends Node3D

## Interactive ragdoll tuning sandbox. Spawns a bare KayKit skin (no body,
## no AI), a knob panel for launch + joint stiffness, and Kill / Reset /
## Print buttons. Rings mark 5 / 10 / 15 m so slide distance reads at a
## glance; the HUD shows measured hips travel live.
##
## Run from the editor: open tests/ragdoll_tuning.tscn and Play Scene.
## Keys: K = kill, R = reset, P = print values.
##
## Knob → real property mapping (for baking values back):
##   back/up/side       → PlayerBody ragdoll_launch_backward / _vertical / _side_bias
##   gravity, clamp     → KayKitSkin ragdoll_gravity_scale / ragdoll_max_bone_speed
##   damp / spans / bias / softness → per-bone properties on the Physical Bone
##   nodes inside kaykit_skin.tscn (Print values lists them per bone).

const SKIN_SCENE := "res://player/skins/kaykit/kaykit_skin.tscn"

# name, label, min, max, step, default
const KNOBS := [
	["back_speed", "Launch back m/s", 0.0, 50.0, 0.5, 19.0],
	["up_speed", "Launch up m/s", 0.0, 15.0, 0.25, 4.5],
	["side_bias", "Side bias (R→L)", -2.0, 2.0, 0.05, 0.6],
	["gravity", "Gravity scale", 0.5, 6.0, 0.1, 4.2],
	["damp_all", "Angular damp (all)", 0.0, 60.0, 0.5, 29.0],
	["limit_bias", "Limit bias (all)", 0.0, 0.3, 0.005, 0.01],
	["limit_soft", "Limit softness (all)", 0.3, 2.0, 0.05, 1.5],
	["max_speed", "Bone speed clamp", 5.0, 80.0, 1.0, 55.0],
	["head_damp", "Head damp", 0.0, 60.0, 0.5, 41.0],
	["head_swing", "Head swing °", 0.0, 60.0, 1.0, 30.0],
	["head_twist", "Head twist °", 0.0, 60.0, 1.0, 25.0],
	["head_mass", "Head mass", 0.25, 4.0, 0.05, 1.0],
	["shoulder_swing", "Shoulder swing °", 0.0, 90.0, 1.0, 50.0],
	["elbow_bend", "Elbow bend max °", 0.0, 140.0, 1.0, 110.0],
	["knee_bend", "Knee bend max °", 0.0, 140.0, 1.0, 120.0],
	["freeze_land", "Freeze on land (0/1)", 0.0, 1.0, 1.0, 1.0],
	["freeze_drop", "Freeze min drop m", 0.0, 1.0, 0.05, 0.2],
	["freeze_delay", "Freeze delay s", 0.0, 2.0, 0.05, 0.3],
	["slide_damp", "Slide damp on land", 0.0, 20.0, 0.5, 6.0],
	["rest_speed", "Rest speed m/s", 0.0, 2.0, 0.05, 0.4],
	["rest_lift", "Rest lift m", 0.0, 0.8, 0.05, 0.3],
	["spin_yaw", "Spin yaw max rad/s", 0.0, 30.0, 0.25, 15.0],
	["spin_roll", "Backroll max rad/s", 0.0, 30.0, 0.25, 15.0],
]

var _values := {}
var _skin: Node3D
var _camera: Camera3D
var _status: Label
var _kill_button: Button
var _slide_dist := 0.0
var _prev_hips := Vector3.INF


func _ready() -> void:
	_build_world()
	_build_ui()
	_spawn_skin()


func _build_world() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80, 1, 80)
	cs.shape = box
	floor_body.add_child(cs)
	var floor_mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(80, 1, 80)
	floor_mesh.mesh = bm
	floor_body.add_child(floor_mesh)
	floor_body.position = Vector3(0, -0.5, 0)
	add_child(floor_body)

	# Distance rings at 5 / 10 / 15 m around the spawn point.
	for r: float in [5.0, 10.0, 15.0]:
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = r - 0.05
		torus.outer_radius = r + 0.05
		ring.mesh = torus
		ring.position = Vector3(0, 0.02, 0)
		add_child(ring)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -30, 0)
	light.shadow_enabled = true
	add_child(light)

	_camera = Camera3D.new()
	_camera.position = Vector3(13, 8, 9)
	add_child(_camera)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(8, 8)
	layer.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(340, 0)
	panel.add_child(vbox)

	for k: Array in KNOBS:
		_values[k[0]] = k[5]
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = k[1]
		label.custom_minimum_size = Vector2(150, 0)
		row.add_child(label)
		var slider := HSlider.new()
		slider.min_value = k[2]
		slider.max_value = k[3]
		slider.step = k[4]
		slider.value = k[5]
		slider.custom_minimum_size = Vector2(120, 0)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(slider)
		var readout := Label.new()
		readout.text = str(k[5])
		readout.custom_minimum_size = Vector2(48, 0)
		readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(readout)
		var knob_name: String = k[0]
		slider.value_changed.connect(func on_changed(v: float) -> void:
			_values[knob_name] = v
			readout.text = ("%.3f" % v).rstrip("0").rstrip("."))
		vbox.add_child(row)

	var buttons := HBoxContainer.new()
	_kill_button = Button.new()
	_kill_button.text = "KILL (K)"
	_kill_button.pressed.connect(_kill)
	buttons.add_child(_kill_button)
	var reset_button := Button.new()
	reset_button.text = "RESET (R)"
	reset_button.pressed.connect(_reset)
	buttons.add_child(reset_button)
	var print_button := Button.new()
	print_button.text = "PRINT (P)"
	print_button.pressed.connect(_print_values)
	buttons.add_child(print_button)
	vbox.add_child(buttons)

	_status = Label.new()
	_status.text = "alive — set knobs, press KILL"
	vbox.add_child(_status)


func _spawn_skin() -> void:
	if _skin != null:
		_skin.queue_free()
	var scene: PackedScene = load(SKIN_SCENE)
	_skin = scene.instantiate()
	add_child(_skin)
	_skin.global_position = Vector3.ZERO
	var tree := _skin.get_node_or_null("AnimationTree") as AnimationTree
	if tree != null:
		tree.active = true
	if _skin.has_method(&"idle"):
		_skin.call(&"idle")
	_slide_dist = 0.0
	_prev_hips = Vector3.INF
	_kill_button.disabled = false
	_status.text = "alive — set knobs, press KILL"


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_K: _kill()
		KEY_R: _reset()
		KEY_P: _print_values()


func _reset() -> void:
	_spawn_skin()


## Push the current knob values into the skin + its physical bones, then
## launch. Joint constraint values must land before simulation starts.
func _kill() -> void:
	if _skin == null or _skin.call(&"is_ragdolled"):
		return
	var skel := _find_skeleton(_skin)
	if skel == null:
		return
	_skin.set(&"ragdoll_gravity_scale", _values.gravity)
	_skin.set(&"ragdoll_max_bone_speed", _values.max_speed)
	_skin.set(&"ragdoll_freeze_rotation_on_land", _values.freeze_land >= 0.5)
	_skin.set(&"ragdoll_freeze_min_drop", _values.freeze_drop)
	_skin.set(&"ragdoll_freeze_delay", _values.freeze_delay)
	_skin.set(&"ragdoll_slide_damp", _values.slide_damp)
	_skin.set(&"ragdoll_rest_speed", _values.rest_speed)
	_skin.set(&"ragdoll_rest_lift", _values.rest_lift)
	_skin.set(&"ragdoll_spin_yaw_max", _values.spin_yaw)
	_skin.set(&"ragdoll_spin_roll_max", _values.spin_roll)
	for c: Node in skel.get_children():
		if not (c is PhysicalBone3D):
			continue
		var pb := c as PhysicalBone3D
		var bone: String = String(pb.get("bone_name"))
		pb.angular_damp = _values.head_damp if bone == "head" else _values.damp_all
		if pb.joint_type == PhysicalBone3D.JOINT_TYPE_CONE:
			pb.set("joint_constraints/bias", _values.limit_bias)
			pb.set("joint_constraints/softness", _values.limit_soft)
		elif pb.joint_type == PhysicalBone3D.JOINT_TYPE_HINGE:
			pb.set("joint_constraints/angular_limit_bias", _values.limit_bias)
			pb.set("joint_constraints/angular_limit_softness", _values.limit_soft)
		match bone:
			"head":
				pb.mass = _values.head_mass
				pb.set("joint_constraints/swing_span", _values.head_swing)
				pb.set("joint_constraints/twist_span", _values.head_twist)
			"upperarm.l", "upperarm.r":
				pb.set("joint_constraints/swing_span", _values.shoulder_swing)
			"lowerarm.l":
				pb.set("joint_constraints/angular_limit_lower", -_values.elbow_bend)
				pb.set("joint_constraints/angular_limit_upper", 10.0)
			"lowerarm.r":
				pb.set("joint_constraints/angular_limit_lower", -10.0)
				pb.set("joint_constraints/angular_limit_upper", _values.elbow_bend)
			"lowerleg.l", "lowerleg.r":
				pb.set("joint_constraints/angular_limit_lower", -10.0)
				pb.set("joint_constraints/angular_limit_upper", _values.knee_bend)

	# Same launch math as PlayerBody._start_death: backward, biased across
	# the body toward the victim's own left (+X in skin space).
	var backward: Vector3 = -_skin.global_transform.basis.z
	var left: Vector3 = _skin.global_transform.basis.x
	var dir: Vector3 = (backward + left * _values.side_bias).normalized()
	_skin.call(&"start_ragdoll", dir * _values.back_speed + Vector3.UP * _values.up_speed)
	_kill_button.disabled = true


func _print_values() -> void:
	print("=== ragdoll tuning values ===")
	for k: Array in KNOBS:
		print("%s = %s" % [k[0], _values[k[0]]])
	print("=============================")


func _physics_process(_delta: float) -> void:
	if _skin == null:
		return
	var focus: Vector3 = _skin.global_position + Vector3.UP
	if _skin.call(&"is_ragdolled"):
		var hips: Vector3 = _skin.call(&"ragdoll_reference_position")
		focus = hips
		if _prev_hips != Vector3.INF:
			_slide_dist += hips.distance_to(_prev_hips)
		_prev_hips = hips
		_status.text = "ragdolled — travel %.2f m — RESET to go again" % _slide_dist
	_camera.look_at(focus)


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c: Node in n.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null
