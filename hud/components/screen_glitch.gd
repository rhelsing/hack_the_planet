extends Control
## Full-screen chromatic-aberration glitch that runs from the moment the
## player dies until they respawn. Reuses the menu's transition shader
## (RGB split + jitter rows). Sits on its own CanvasLayer below the death
## overlay so the "CONNECTION TERMINATED" card lands on top cleanly.

const FADE_IN_S := 0.18
const FADE_OUT_S := 0.35
## Peak alpha of the chromatic glitch — the shader's `alpha` uniform scales
## RGB split + jitter intensity. 1.0 = full menu-transition look.
const PEAK_ALPHA := 0.9

@onready var _rect: ColorRect = %GlitchRect
var _mat: ShaderMaterial = null
var _player: Node = null
var _tween: Tween = null


func _ready() -> void:
	_mat = _rect.material as ShaderMaterial
	_set_alpha(0.0)
	_rect.visible = false
	call_deferred(&"_bind")


func _bind() -> void:
	_player = get_tree().get_first_node_in_group(&"player")
	if _player == null:
		return
	if _player.has_signal(&"died"):
		_player.died.connect(_on_died)
	if _player.has_signal(&"respawned"):
		_player.respawned.connect(_on_respawned)


func _on_died() -> void:
	_rect.visible = true
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_method(_set_alpha, _current_alpha(), PEAK_ALPHA, FADE_IN_S)


func _on_respawned() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_method(_set_alpha, _current_alpha(), 0.0, FADE_OUT_S)
	_tween.tween_callback(func() -> void: _rect.visible = false)


func _set_alpha(v: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter(&"alpha", v)


func _current_alpha() -> float:
	if _mat == null:
		return 0.0
	var v: Variant = _mat.get_shader_parameter(&"alpha")
	return float(v) if v != null else 0.0
