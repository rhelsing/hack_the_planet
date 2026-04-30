extends Control
## Full-screen "CONNECTION TERMINATED" card. Shown on PlayerBody.died, hidden
## on PlayerBody.respawned (or after its own lifecycle ends, whichever first).
##
## Disables user-triggered pause during the sequence so Esc on the death
## card doesn't layer the pause menu on top (per menus.md §13.3(c)).

const FADE_IN_S := 0.4
const TITLE_REVEAL_S := 0.7
const SUBLINE_REVEAL_S := 0.5
const HOLD_S := 1.2
const FADE_OUT_S := 0.5
## Peak opacity of the overlay. <1.0 keeps the screen-glitch chromatic
## aberration partially visible behind the card.
const PEAK_ALPHA := 0.8

@onready var _blackout:      ColorRect     = %Blackout
@onready var _title_label:   RichTextLabel = %TitleLabel
@onready var _subline_label: RichTextLabel = %SublineLabel

var _player: Node = null
var _active: bool = false


func _ready() -> void:
	visible = false
	_blackout.mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_filter = Control.MOUSE_FILTER_STOP
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
	if _active:
		# Re-entry (rapid second death before overlay finished) — restart cleanly.
		_finish(true)
	_play()


func _on_respawned() -> void:
	if _active:
		_finish(false)


func _play() -> void:
	_active = true
	_set_pause_allowed(false)
	modulate.a = 0.0
	visible = true
	# Force the rect to fill the viewport. In editor the layout pass
	# auto-runs every frame so the anchors resolve fine; in exported
	# builds a Control that's been `visible = false` since _ready can
	# stay at size 0,0 (top-left collapse) when shown the first time.
	# Setting size + position explicitly side-steps the issue without
	# touching the scene tree wrapper above us.
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	position = Vector2.ZERO
	size = vp_size

	_title_label.text   = "[color=#ff5577]CONNECTION TERMINATED[/color]"
	_subline_label.text = "[color=#33ff66]> reconnecting to last checkpoint...[/color]"
	_title_label.visible_ratio = 0.0
	_subline_label.visible_ratio = 0.0

	var tw := create_tween()
	tw.tween_property(self, "modulate:a", PEAK_ALPHA, FADE_IN_S)
	tw.tween_property(_title_label, "visible_ratio", 1.0, TITLE_REVEAL_S)
	tw.tween_property(_subline_label, "visible_ratio", 1.0, SUBLINE_REVEAL_S)
	tw.tween_interval(HOLD_S)
	tw.tween_property(self, "modulate:a", 0.0, FADE_OUT_S)
	tw.tween_callback(func() -> void: _finish(true))


func _finish(hide: bool) -> void:
	_active = false
	_set_pause_allowed(true)
	if hide:
		visible = false


func _set_pause_allowed(value: bool) -> void:
	var pc := get_tree().root.get_node_or_null(^"PauseController")
	if pc != null:
		pc.user_pause_allowed = value


# Absorb any input while the overlay is visible so the player can't mash
# through to gameplay or open the pause menu.
func _input(event: InputEvent) -> void:
	if not visible or not _active:
		return
	if event is InputEventKey or event is InputEventMouseButton or event is InputEventJoypadButton:
		get_viewport().set_input_as_handled()
