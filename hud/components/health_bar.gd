extends HBoxContainer
## ASCII health bar: HP [████████░░░░]. Twelve cells, filled proportional to
## health/max_health. Subscribes to the player's local `health_changed`
## signal if available; otherwise polls once at ready and stays static.
##
## Guarded against missing getters — if char_dev's Patch C hasn't landed, we
## show "HP [ ... ]" rather than crashing.

const CELLS := 12
const FILLED := "█"
const EMPTY  := "░"
const COLOR_NORMAL := Color(0, 1, 1)            # accent_cyan
const COLOR_FLASH  := Color(1.0, 0.33, 0.47)    # alert_red
const SHAKE_PX := 3.0
const FLASH_S := 0.20

@onready var _prefix: Label = %Prefix
@onready var _bar:    Label = %Bar

var _player: Node = null
var _max: int = 0


func _ready() -> void:
	_prefix.text = "HP"
	_bar.modulate = COLOR_NORMAL
	call_deferred(&"_bind")


func _bind() -> void:
	_player = get_tree().get_first_node_in_group(&"player")
	if _player == null:
		_render(-1, 0)
		return
	if _player.has_signal(&"health_changed"):
		_player.health_changed.connect(_on_health_changed)
	var max_health := _safe_int(_player, &"get_max_health")
	var health     := _safe_int(_player, &"get_health")
	_max = max(max_health, 1)
	_render(health, _max)


func _on_health_changed(new_hp: int, old_hp: int) -> void:
	_render(new_hp, _max)
	if new_hp < old_hp:
		_flash()


func _render(hp: int, max_hp: int) -> void:
	if max_hp <= 0 or hp < 0:
		_bar.text = "[ %s ]" % EMPTY.repeat(CELLS)
		return
	var filled := clampi(int(round(float(hp) / float(max_hp) * CELLS)), 0, CELLS)
	_bar.text = "[%s%s]" % [FILLED.repeat(filled), EMPTY.repeat(CELLS - filled)]


func _flash() -> void:
	var tw := create_tween()
	tw.tween_property(_bar, "modulate", COLOR_FLASH, FLASH_S * 0.4)
	tw.tween_property(_bar, "modulate", COLOR_NORMAL, FLASH_S * 0.6)
	var shake := create_tween()
	shake.tween_property(self, "position:x", position.x + SHAKE_PX, FLASH_S * 0.2)
	shake.tween_property(self, "position:x", position.x - SHAKE_PX, FLASH_S * 0.2)
	shake.tween_property(self, "position:x", position.x, FLASH_S * 0.2)


# Minimal reflective call — returns -1 if method missing so _render shows placeholder.
func _safe_int(target: Object, method: StringName) -> int:
	if not target.has_method(method):
		return -1
	return int(target.call(method))
