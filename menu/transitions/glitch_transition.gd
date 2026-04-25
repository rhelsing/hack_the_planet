class_name GlitchTransition
extends Transition
## Chromatic-aberration scene transition. Tweens a shader uniform from
## 0→1 (out) or 1→0 (in); the shader samples the live framebuffer and
## applies an RGB split that scales with alpha. Scene swap runs at the
## peak — visible through the glitch, not hidden by an overlay.

const DURATION := 0.4
const SHADER_PATH := "res://menu/transitions/glitch.gdshader"

var _canvas: CanvasLayer = null
var _rect: ColorRect = null
var _mat: ShaderMaterial = null


func play_out(host: SceneTree) -> Signal:
	_spawn(host)
	_mat.set_shader_parameter(&"alpha", 0.0)
	# SINE+IN_OUT: gradual ramp into the glitch — the world distorts smoothly
	# rather than slamming in. Symmetric with play_in for a back-and-forth feel.
	var tw := host.create_tween()
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_method(_set_alpha, 0.0, 1.0, DURATION)
	tw.finished.connect(func() -> void: finished.emit(), CONNECT_ONE_SHOT)
	return finished


func play_in(host: SceneTree) -> Signal:
	if _mat == null:
		# No matching play_out ran; fall back to instant.
		host.process_frame.connect(
			func() -> void: finished.emit(), CONNECT_ONE_SHOT
		)
		return finished
	_mat.set_shader_parameter(&"alpha", 1.0)
	# SINE+IN_OUT: gradual ramp out — the new scene reassembles smoothly
	# instead of snapping. Mirror of play_out's curve.
	var tw := host.create_tween()
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_method(_set_alpha, 1.0, 0.0, DURATION)
	tw.finished.connect(func() -> void:
		_free_canvas()
		finished.emit()
	, CONNECT_ONE_SHOT)
	return finished


func _spawn(host: SceneTree) -> void:
	if _canvas != null:
		return
	_canvas = CanvasLayer.new()
	_canvas.layer = 2000  # above scene_loader's 1000; transitions always win
	_canvas.process_mode = Node.PROCESS_MODE_ALWAYS
	host.root.add_child(_canvas)
	_rect = ColorRect.new()
	_rect.anchor_right = 1.0
	_rect.anchor_bottom = 1.0
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh: Shader = load(SHADER_PATH)
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_rect.material = _mat
	_canvas.add_child(_rect)


func _set_alpha(v: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter(&"alpha", v)


func _free_canvas() -> void:
	if _canvas != null and is_instance_valid(_canvas):
		_canvas.queue_free()
	_canvas = null
	_rect = null
	_mat = null
