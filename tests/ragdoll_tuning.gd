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
	["back_speed", "Launch back m/s", 0.0, 50.0, 0.5, 7.5],
	["up_speed", "Launch up m/s", 0.0, 15.0, 0.25, 4.75],
	["side_bias", "Side bias (R→L)", -2.0, 2.0, 0.05, 0.6],
	["gravity", "Gravity scale", 0.5, 6.0, 0.1, 4.2],
	["damp_all", "Angular damp (all)", 0.0, 60.0, 0.5, 1.5],
	["limit_bias", "Limit bias (all)", 0.0, 0.3, 0.005, 0.01],
	["limit_soft", "Limit softness (all)", 0.3, 2.0, 0.05, 1.5],
	["max_speed", "Bone speed clamp", 5.0, 80.0, 1.0, 55.0],
	["head_damp", "Head damp", 0.0, 60.0, 0.5, 1.5],
	["head_swing", "Head swing °", 0.0, 60.0, 1.0, 30.0],
	["head_twist", "Head twist °", 0.0, 60.0, 1.0, 25.0],
	["head_mass", "Head mass", 0.25, 4.0, 0.05, 1.0],
	["shoulder_swing", "Shoulder swing °", 0.0, 90.0, 1.0, 50.0],
	["elbow_bend", "Elbow bend max °", 0.0, 140.0, 1.0, 110.0],
	["knee_bend", "Knee bend max °", 0.0, 140.0, 1.0, 120.0],
	["freeze_land", "A: freeze on land", 0.0, 1.0, 1.0, 0.0],
	["freeze_drop", "A: freeze min drop m", 0.0, 1.0, 0.05, 0.2],
	["freeze_delay", "A: freeze delay s", 0.0, 2.0, 0.05, 0.3],
	["slide_damp", "A: slide damp on land", 0.0, 20.0, 0.5, 6.0],
	["rest_speed", "A: rest speed m/s", 0.0, 2.0, 0.05, 0.4],
	["rest_lift", "A: rest lift m", 0.0, 0.8, 0.05, 0.0],
	["spin_yaw", "Spin yaw max rad/s", 0.0, 30.0, 0.25, 15.0],
	["spin_roll", "Backroll max rad/s", 0.0, 30.0, 0.25, 15.0],
	["ease_speed", "B: ease-in speed", 0.2, 12.0, 0.2, 6.0],
]

var _values := {}
var _skin: Node3D
var _camera: Camera3D
var _status: Label
var _kill_button: Button
var _slide_dist := 0.0
var _prev_hips := Vector3.INF

# Swappable fall engines. One entry per implemented engine; only the selected
# one is ever instanced (the rest are inert). B (passive) and C (active-spring
# KO) get appended in later steps — rotating this list is how we A/B on screen.
# "B · game" is a live pass-through to the skin's start_ragdoll (= the shipping
# Engine B), so tuning it IS tuning the enemy death. "C" is the loose-cone KO
# comparison (standalone). The old standalone A/B experiments were folded into
# the game path and dropped from the picker.
const _EngineBGame := preload("res://player/ragdoll/engine_a_stabilized.gd")
const _EngineC := preload("res://player/ragdoll/engine_c_ko.gd")
var _engine_factories: Array = [_EngineBGame, _EngineC]
var _engine_index := 0
var _engine                       # current RagdollEngine instance (RefCounted)
var _engine_option: OptionButton

# Collider viz + control. The physical-bone capsules/spheres are the same
# authored shapes for every engine, so this is a SHARED control. Overlay meshes
# parent under each CollisionShape3D so they track the bones through the fall.
var _show_colliders := false
var _collider_radius_scale := 1.4
var _collider_length_scale := 1.25
# Head has its own track — the body sliders skip it, these drive it.
var _head_radius_scale := 3.0
var _head_length_scale := 3.0
# Slide the head COLLISION shape up its own long axis (away from the chest)
# without moving the bone, so growing it doesn't shove the head off the neck.
var _head_offset := 0.21

# [display_name, property_name] for every control added OUTSIDE the KNOBS table.
# Print iterates this so anything we add is output automatically.
var _extra_props: Array = []

# Camera: sits at _cam_dir * _cam_distance from the focus point and looks at it,
# so the fall stays framed while distance is tunable.
var _cam_dir := Vector3(13, 8, 9).normalized()
var _cam_distance := 4.0


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

	# Fall-engine selector — dropdown to pick + a ▶ button to cycle. Switching
	# respawns the character with the newly selected engine's rig.
	var engine_row := HBoxContainer.new()
	var engine_title := Label.new()
	engine_title.text = "Fall engine"
	engine_title.custom_minimum_size = Vector2(90, 0)
	engine_row.add_child(engine_title)
	_engine_option = OptionButton.new()
	_engine_option.focus_mode = Control.FOCUS_NONE
	_engine_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	engine_row.add_child(_engine_option)
	var cycle_button := Button.new()
	cycle_button.text = "▶"
	cycle_button.focus_mode = Control.FOCUS_NONE
	cycle_button.pressed.connect(_cycle_engine)
	engine_row.add_child(cycle_button)
	vbox.add_child(engine_row)
	_refresh_engine_option()
	_engine_option.item_selected.connect(_on_engine_selected)

	# Collider viz + control (shared across engines — same authored shapes).
	var coll_btn := Button.new()
	coll_btn.focus_mode = Control.FOCUS_NONE
	coll_btn.text = "Show colliders: OFF"
	coll_btn.pressed.connect(func() -> void:
		_show_colliders = not _show_colliders
		coll_btn.text = "Show colliders: " + ("ON" if _show_colliders else "OFF")
		_apply_collider_settings())
	vbox.add_child(coll_btn)
	_extra_props.append(["show_colliders", "_show_colliders"])
	_add_plain_slider(vbox, "Collider radius × (body)", 0.2, 3.0, 0.05, _collider_radius_scale,
		func(v: float) -> void: _collider_radius_scale = v; _apply_collider_settings(), "_collider_radius_scale")
	_add_plain_slider(vbox, "Collider length × (body)", 0.2, 3.0, 0.05, _collider_length_scale,
		func(v: float) -> void: _collider_length_scale = v; _apply_collider_settings(), "_collider_length_scale")
	_add_plain_slider(vbox, "Head radius ×", 0.2, 3.0, 0.05, _head_radius_scale,
		func(v: float) -> void: _head_radius_scale = v; _apply_collider_settings(), "_head_radius_scale")
	_add_plain_slider(vbox, "Head length ×", 0.2, 3.0, 0.05, _head_length_scale,
		func(v: float) -> void: _head_length_scale = v; _apply_collider_settings(), "_head_length_scale")
	_add_plain_slider(vbox, "Head offset (up)", -0.1, 0.4, 0.01, _head_offset,
		func(v: float) -> void: _head_offset = v; _apply_collider_settings(), "_head_offset")
	_add_plain_slider(vbox, "Camera distance", 3.0, 45.0, 0.5, _cam_distance,
		func(v: float) -> void: _cam_distance = v, "_cam_distance")

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
	if _engine != null:
		_engine.teardown()
		_engine = null
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
	# Build the selected fall engine against this fresh skin's skeleton.
	_engine = _engine_factories[_engine_index].new()
	_engine.setup(_skin, _find_skeleton(_skin))
	_engine.build()
	_apply_collider_settings()
	_slide_dist = 0.0
	_prev_hips = Vector3.INF
	_kill_button.disabled = false
	_status.text = "alive [%s] — set knobs, press KILL" % _engine.engine_name()


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


## Populate the engine dropdown from the registry (each engine names itself).
func _refresh_engine_option() -> void:
	_engine_option.clear()
	for f: Variant in _engine_factories:
		_engine_option.add_item(f.new().engine_name())
	_engine_option.select(_engine_index)


func _on_engine_selected(idx: int) -> void:
	_engine_index = clampi(idx, 0, _engine_factories.size() - 1)
	_spawn_skin()


func _cycle_engine() -> void:
	_engine_index = (_engine_index + 1) % _engine_factories.size()
	_engine_option.select(_engine_index)
	_spawn_skin()


## Hand the current knob values to the selected engine, compute the launch
## velocity, and fire. Each engine decides how (or whether) to use the launch.
func _kill() -> void:
	if _skin == null or _engine == null or _engine.is_active():
		return
	_engine.apply_tuning(_values)
	# Same launch math as PlayerBody._start_death: backward, biased across the
	# body toward the victim's own left (+X in skin space).
	var backward: Vector3 = -_skin.global_transform.basis.z
	var left: Vector3 = _skin.global_transform.basis.x
	var dir: Vector3 = (backward + left * _values.side_bias).normalized()
	_engine.start(dir * _values.back_speed + Vector3.UP * _values.up_speed)
	_kill_button.disabled = true


func _print_values() -> void:
	print("=== ragdoll tuning values ===")
	print("engine = %s" % (_engine.engine_name() if _engine != null else "?"))
	for k: Array in KNOBS:
		print("%s = %s" % [k[0], _values[k[0]]])
	# Everything added outside KNOBS (collider / head / camera / toggles).
	for e: Array in _extra_props:
		print("%s = %s" % [e[0], get(e[1])])
	print("=============================")


func _physics_process(delta: float) -> void:
	if _skin == null or _engine == null:
		return
	_engine.physics_tick(delta)
	var focus: Vector3 = _skin.global_position + Vector3.UP
	if _engine.is_active():
		var hips: Vector3 = _engine.reference_position()
		focus = hips
		if _prev_hips != Vector3.INF:
			_slide_dist += hips.distance_to(_prev_hips)
		_prev_hips = hips
		_status.text = "[%s] ragdolled — travel %.2f m — RESET/▶" % [_engine.engine_name(), _slide_dist]
	_camera.global_position = focus + _cam_dir * _cam_distance
	_camera.look_at(focus)


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c: Node in n.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null


# A plain labeled slider with a live callback (KNOBS sliders only store; these
# fire on change — used for the collider controls).
func _add_plain_slider(parent: VBoxContainer, label_txt: String, lo: float, hi: float,
		step: float, val: float, cb: Callable, prop: String = "") -> void:
	if prop != "":
		_extra_props.append([label_txt, prop])
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_txt
	label.custom_minimum_size = Vector2(150, 0)
	row.add_child(label)
	var slider := HSlider.new()
	slider.focus_mode = Control.FOCUS_NONE
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.value = val
	slider.custom_minimum_size = Vector2(120, 0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)
	var readout := Label.new()
	readout.text = str(val)
	readout.custom_minimum_size = Vector2(48, 0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(readout)
	slider.value_changed.connect(func(v: float) -> void:
		readout.text = ("%.2f" % v)
		cb.call(v))
	parent.add_child(row)


func _collect_phys_bones() -> Array:
	var out: Array = []
	if _skin != null:
		_gather_phys_bones(_skin, out)
	return out


func _gather_phys_bones(n: Node, out: Array) -> void:
	if n is PhysicalBone3D:
		out.append(n)
	for c: Node in n.get_children():
		_gather_phys_bones(c, out)


# Scale every physical bone's collision shape (radius / length) and refresh the
# translucent overlay meshes. Shapes are duplicated + base dims cached on first
# touch so scaling is absolute, not compounding. Applied per spawn and live.
func _apply_collider_settings() -> void:
	for pb: Node in _collect_phys_bones():
		# Head runs on its own scale track; every other bone on the body track.
		var is_head := String(pb.get("bone_name")) == "head"
		var rscale := _head_radius_scale if is_head else _collider_radius_scale
		var lscale := _head_length_scale if is_head else _collider_length_scale
		for cs: Node in pb.get_children():
			if not (cs is CollisionShape3D):
				continue
			var shape_holder := cs as CollisionShape3D
			if shape_holder.shape == null:
				continue
			if not shape_holder.has_meta("base_cached"):
				shape_holder.shape = shape_holder.shape.duplicate()
				shape_holder.set_meta("base_cached", true)
				shape_holder.set_meta("base_pos", shape_holder.position)
				var s: Shape3D = shape_holder.shape
				if s is CapsuleShape3D:
					shape_holder.set_meta("base_r", (s as CapsuleShape3D).radius)
					shape_holder.set_meta("base_h", (s as CapsuleShape3D).height)
				elif s is SphereShape3D:
					shape_holder.set_meta("base_r", (s as SphereShape3D).radius)
				elif s is BoxShape3D:
					shape_holder.set_meta("base_size", (s as BoxShape3D).size)
			var sh: Shape3D = shape_holder.shape
			if sh is CapsuleShape3D:
				# A capsule enforces radius <= height/2, so set height FIRST and
				# grow it to fit the requested radius — otherwise radius clamps
				# (fatal for the near-spherical head: any radius > 1.15x clamps).
				var cap := sh as CapsuleShape3D
				var target_r: float = shape_holder.get_meta("base_r") * rscale
				var target_h: float = maxf(shape_holder.get_meta("base_h") * lscale, target_r * 2.0)
				cap.height = target_h
				cap.radius = target_r
			elif sh is SphereShape3D:
				(sh as SphereShape3D).radius = shape_holder.get_meta("base_r") * rscale
			elif sh is BoxShape3D:
				(sh as BoxShape3D).size = shape_holder.get_meta("base_size") \
					* Vector3(rscale, lscale, rscale)
			# Head-only: slide the shape up its long axis so a bigger head
			# collider grows away from the chest instead of into it. Bone (and
			# thus the visual head) is untouched.
			if is_head:
				var axis: Vector3 = shape_holder.transform.basis.y.normalized()
				shape_holder.position = shape_holder.get_meta("base_pos") + axis * _head_offset
			_update_collider_viz(shape_holder)


func _update_collider_viz(cs: CollisionShape3D) -> void:
	var viz := cs.get_node_or_null("__viz") as MeshInstance3D
	if not _show_colliders:
		if viz != null:
			viz.queue_free()
		return
	if viz == null:
		viz = MeshInstance3D.new()
		viz.name = "__viz"
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.2, 0.9, 1.0, 0.35)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		# Draw the collider ON TOP of the character mesh (x-ray). Without this the
		# head capsule is fully enclosed by the opaque head mesh and never shows.
		mat.no_depth_test = true
		viz.material_override = mat
		cs.add_child(viz)
	var sh: Shape3D = cs.shape
	if sh is CapsuleShape3D:
		var m := CapsuleMesh.new()
		m.radius = (sh as CapsuleShape3D).radius
		m.height = (sh as CapsuleShape3D).height
		viz.mesh = m
	elif sh is SphereShape3D:
		var m := SphereMesh.new()
		m.radius = (sh as SphereShape3D).radius
		m.height = (sh as SphereShape3D).radius * 2.0
		viz.mesh = m
	elif sh is BoxShape3D:
		var m := BoxMesh.new()
		m.size = (sh as BoxShape3D).size
		viz.mesh = m
