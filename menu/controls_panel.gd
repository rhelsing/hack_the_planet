extends Control
## Pause-menu sub-panel showing the player's input bindings as a 2-column
## table (action name ↔ glyph). Populated dynamically from the Glyphs
## autoload so keyboard / gamepad swaps follow the active device.
##
## Pushed onto the pause MenuStack via _push_sub_menu (pause_menu.gd:225);
## emits `back_requested` so the controller pops us off — same contract as
## settings_menu / save_slots.

signal back_requested

## Display order + human-readable labels for each glyph entry. Action keys
## must match keys in Glyphs._GLYPHS. Skipping a key here hides it from the
## table without removing it from the glyph table itself.
const ROWS: Array = [
	["move",         "Move"],
	["look",         "Look"],
	["jump",         "Jump"],
	["dash",         "Dash"],
	["attack",       "Attack"],
	["interact",     "Interact"],
	["sneak_toggle", "Sneak"],
	["crouch",       "Crouch"],
	["grapple_fire", "Grapple"],
	["flare_shoot",  "Flare"],
	["music_prev",   "Music Back"],
	["music_next",   "Music Forward"],
	["pause",        "Pause"],
]

@onready var _grid: GridContainer = %Grid
@onready var _back_btn: Button = %BackBtn


func configure(_args: Dictionary) -> void:
	pass


func _ready() -> void:
	Events.modal_opened.emit(&"controls")
	tree_exited.connect(func() -> void: Events.modal_closed.emit(&"controls"))
	_populate_grid()
	_back_btn.pressed.connect(func() -> void: back_requested.emit())
	_back_btn.grab_focus()


func _populate_grid() -> void:
	for child in _grid.get_children():
		child.queue_free()
	for row: Array in ROWS:
		var key: String = row[0]
		var display: String = row[1]
		var name_label := Label.new()
		name_label.text = display
		name_label.add_theme_color_override(&"font_color", Color(0.85, 0.85, 0.85, 1.0))
		_grid.add_child(name_label)
		var glyph_label := Label.new()
		glyph_label.text = Glyphs.for_action(key)
		glyph_label.add_theme_color_override(&"font_color", Color(0.0, 1.0, 1.0, 1.0))
		_grid.add_child(glyph_label)
