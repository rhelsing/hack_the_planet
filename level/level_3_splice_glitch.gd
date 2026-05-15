extends Node
## Fires a fullscreen glitch pulse during the chaotic patch-in moment of
## the Splice offer dialogue (when Nyx/DialTone cut through Splice's signal
## in the splice_refused branch). Quiet during the rest of the conversation
## — only the patch-in triggers anything. Same shader the menu transitions
## and level_5 end-card use.

const _SHADER_PATH: String = "res://menu/transitions/glitch.gdshader"

## Which dialogue this watches. Matches companion_npc.interactable_id.
@export var conversation_id: StringName = &"npc_splice_offer"

## Characters whose first line spawns the glitch overlay and starts the
## pulse. These are the walkie patch-ins during splice_refused — DialTone
## and Nyx cutting through Splice's signal. First match wins.
@export var intensify_on_characters: Array[StringName] = [&"Nyx", &"DialTone"]
@export_range(0.0, 1.0, 0.05) var pulse_peak: float = 0.32
@export_range(0.05, 2.0, 0.05) var pulse_period: float = 0.22
@export_range(0.0, 0.05, 0.001) var aberration_max: float = 0.04
@export_range(0.0, 0.2, 0.001) var jitter_amplitude: float = 0.053

var _canvas: CanvasLayer = null
var _rect: ColorRect = null
var _mat: ShaderMaterial = null
var _tween: Tween = null
var _active: bool = false
var _firing: bool = false


func _ready() -> void:
	Events.dialogue_started.connect(_on_dialogue_started)
	Events.dialogue_ended.connect(_on_dialogue_ended)
	Events.dialogue_line_shown.connect(_on_line_shown)


func _on_dialogue_started(id: StringName) -> void:
	if id != conversation_id:
		return
	_active = true
	_firing = false


func _on_dialogue_ended(id: StringName) -> void:
	if id != conversation_id:
		return
	_active = false
	_firing = false
	_teardown()


func _on_line_shown(character: StringName, _text: String) -> void:
	if not _active or _firing:
		return
	if character not in intensify_on_characters:
		return
	_firing = true
	_spawn_overlay()
	_start_pulse()


func _spawn_overlay() -> void:
	if _canvas != null:
		return
	_canvas = CanvasLayer.new()
	# Above gameplay HUD (~100) but below transition layer (2000) so
	# scene transitions still cleanly cover the pulse.
	_canvas.layer = 1500
	add_child(_canvas)
	_rect = ColorRect.new()
	_rect.anchor_right = 1.0
	_rect.anchor_bottom = 1.0
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = load(_SHADER_PATH)
	_mat.set_shader_parameter(&"alpha", 0.0)
	_mat.set_shader_parameter(&"aberration_max", aberration_max)
	_mat.set_shader_parameter(&"jitter_amplitude", jitter_amplitude)
	_rect.material = _mat
	_canvas.add_child(_rect)


func _start_pulse() -> void:
	if _mat == null:
		return
	_tween = create_tween().set_loops()
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_method(_set_alpha, 0.0, pulse_peak, pulse_period * 0.5)
	_tween.tween_method(_set_alpha, pulse_peak, 0.0, pulse_period * 0.5)


func _set_alpha(v: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter(&"alpha", v)


func _teardown() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	if _canvas != null and is_instance_valid(_canvas):
		_canvas.queue_free()
	_canvas = null
	_rect = null
	_mat = null
