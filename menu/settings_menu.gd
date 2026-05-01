extends Control
## Settings UI with Audio + Graphics tabs. Binds sliders/option-buttons to the
## Settings autoload. Emits `back_requested` to let the pusher pop us off its
## stack (same contract as save_slots and credits — docs/menus.md §4).
##
## All writes go through Settings.set_value() which persists the key and
## fires Events.settings_applied — subsystems re-read their own keys.

signal back_requested

@onready var _master:   HSlider = %MasterSlider
@onready var _music:    HSlider = %MusicSlider
@onready var _sfx:      HSlider = %SfxSlider
@onready var _quality:  OptionButton = %QualityOption
@onready var _transition: OptionButton = %TransitionOption
@onready var _hud_scale: HSlider = %HudScaleSlider
@onready var _hud_scale_value: Label = %HudScaleValue
@onready var _back_btn: Button = %BackBtn


func configure(_args: Dictionary) -> void:
	pass


func _ready() -> void:
	# Inherit parent process_mode — see save_slots.gd for the rationale.
	Events.modal_opened.emit(&"settings")
	tree_exited.connect(func() -> void: Events.modal_closed.emit(&"settings"))
	_populate_quality_options()
	_populate_transition_options()
	_bind_from_settings()
	_wire_signals()
	_back_btn.grab_focus()


func _populate_quality_options() -> void:
	_quality.clear()
	_quality.add_item("Low", 0)
	_quality.add_item("Medium", 1)
	_quality.add_item("High", 2)
	_quality.add_item("Max", 3)


func _populate_transition_options() -> void:
	_transition.clear()
	_transition.add_item("None", 0)
	_transition.add_item("Glitch", 1)


func _bind_from_settings() -> void:
	var s := _settings()
	if s == null:
		return
	_master.value = _db_to_linear(s.call(&"get_value", "audio", "master_volume_db", 0.0))
	_music.value  = _db_to_linear(s.call(&"get_value", "audio", "music_volume_db", 0.0))
	_sfx.value    = _db_to_linear(s.call(&"get_value", "audio", "sfx_volume_db", 0.0))
	var q: String = String(s.call(&"get_value", "graphics", "quality", "medium"))
	_quality.selected = _quality_index(q)
	var t: String = String(s.call(&"get_value", "graphics", "transition_style", "instant"))
	_transition.selected = 1 if t == "glitch" else 0
	var hs: float = float(s.call(&"get_value", "hud", "scale", 1.5))
	_hud_scale.value = hs
	_hud_scale_value.text = "%.1fx" % hs


func _wire_signals() -> void:
	_master.value_changed.connect(func(v: float) -> void:
		_apply("audio", "master_volume_db", _linear_to_db(v))
	)
	_music.value_changed.connect(func(v: float) -> void:
		_apply("audio", "music_volume_db", _linear_to_db(v))
	)
	_sfx.value_changed.connect(func(v: float) -> void:
		_apply("audio", "sfx_volume_db", _linear_to_db(v))
	)
	_quality.item_selected.connect(func(idx: int) -> void:
		_apply("graphics", "quality", _quality_label(idx))
	)
	_transition.item_selected.connect(func(idx: int) -> void:
		_apply("graphics", "transition_style", "instant" if idx == 0 else "glitch")
	)
	_hud_scale.value_changed.connect(func(v: float) -> void:
		_hud_scale_value.text = "%.1fx" % v
		_apply("hud", "scale", v)
	)
	_back_btn.pressed.connect(func() -> void:
		_play_back_sfx()
		back_requested.emit()
	)


# ── Helpers ──────────────────────────────────────────────────────────────

func _apply(section: String, key: String, value) -> void:
	var s := _settings()
	if s == null:
		return
	s.call(&"set_value", section, key, value)


func _settings() -> Node:
	return get_tree().root.get_node_or_null(^"Settings")


func _db_to_linear(db: float) -> float:
	return clampf(db_to_linear(db), 0.0, 1.0)


func _linear_to_db(lin: float) -> float:
	return linear_to_db(maxf(lin, 0.0001))


func _quality_index(label: String) -> int:
	match label:
		"low": return 0
		"medium": return 1
		"high": return 2
		"max": return 3
	return 1


func _quality_label(idx: int) -> String:
	match idx:
		0: return "low"
		1: return "medium"
		2: return "high"
		3: return "max"
	return "medium"


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		_play_back_sfx()
		back_requested.emit()
		get_viewport().set_input_as_handled()


func _play_back_sfx() -> void:
	var audio := get_tree().root.get_node_or_null(^"Audio")
	if audio != null and audio.has_method(&"play_sfx"):
		audio.call(&"play_sfx", &"ui_back")
