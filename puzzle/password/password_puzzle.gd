extends "res://puzzle/puzzle.gd"

## Password-entry puzzle. Type the accepted word on a physical keyboard; an
## on-screen QWERTY keyboard mirrors which key the player just pressed so
## the interaction reads as "real" data entry. Enter submits, Backspace
## deletes, Esc cancels.
##
## One accepted password per instance (`@export password`). Case-insensitive
## match so the player doesn't have to hold Shift.

## Accepted password for this terminal. Set per-instance in the inspector
## (e.g. "love", "sex", "secret", "god"). Matched case-insensitively.
@export var password: String = "love"
## Max length of the entry field — stops accidental runaway typing. Set to
## at least `password.length() + a few` for forgiveness after mistyping.
@export var max_length: int = 12

@onready var _entry_label: Label = %EntryLabel
@onready var _shake_target: Control = %EntryRoot
@onready var _keyboard_root: Control = %KeyboardRoot

const _KEYBOARD_ROWS: Array[String] = [
	"QWERTYUIOP",
	"ASDFGHJKL",
	"ZXCVBNM",
]
const _KEY_SIZE := Vector2(46, 46)
const _KEY_GAP := 6.0

const _COLOR_KEY_BG: Color    = Color(0.18, 0.20, 0.24, 1)
const _COLOR_KEY_HIT: Color   = Color(0.30, 0.85, 1.0, 1)
const _COLOR_KEY_TEXT: Color  = Color(0.85, 0.90, 1.0, 1)

var _entered: String = ""
var _finished: bool = false
var _key_flash: Dictionary = {}   # {StringName letter: float remaining_ms}

var _key_labels: Dictionary = {}   # letter → Label (for highlight on press)


func _ready() -> void:
	super._ready()
	_build_keyboard()
	_refresh_entry()


func _process(delta: float) -> void:
	# Decay key flashes; redraw the one that changed.
	if _key_flash.is_empty():
		return
	var done: Array = []
	for letter in _key_flash:
		_key_flash[letter] -= delta
		if _key_flash[letter] <= 0.0:
			done.append(letter)
	for letter in done:
		_key_flash.erase(letter)
	_refresh_key_colors()


func _input(event: InputEvent) -> void:
	# Base handles ui_cancel, but we also need to flip _finished.
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		_finished = true
		_complete(false)
		return
	if _finished:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key_event: InputEventKey = event as InputEventKey
	if key_event.keycode == KEY_ENTER or key_event.keycode == KEY_KP_ENTER:
		_submit()
		get_viewport().set_input_as_handled()
		return
	if key_event.keycode == KEY_BACKSPACE:
		if _entered.length() > 0:
			_entered = _entered.substr(0, _entered.length() - 1)
			_refresh_entry()
		get_viewport().set_input_as_handled()
		return
	# Letter / space — use unicode so layout variants don't matter.
	var ch: String = char(key_event.unicode) if key_event.unicode != 0 else ""
	if ch.length() != 1:
		return
	var lower := ch.to_lower()
	if (lower >= "a" and lower <= "z") or lower == " ":
		if _entered.length() < max_length:
			_entered += lower
			_refresh_entry()
			_flash_key(lower.to_upper())
		get_viewport().set_input_as_handled()


func _submit() -> void:
	if _entered.to_lower() == password.to_lower():
		_finished = true
		_complete(true)
		return
	# Miss — shake the entry box + clear.
	_entered = ""
	_refresh_entry()
	_shake()


func _refresh_entry() -> void:
	# Show typed chars + an underscore cursor to indicate the entry is live.
	_entry_label.text = "%s_" % _entered.to_upper()


func _shake() -> void:
	var tw := create_tween()
	var base := _shake_target.position
	for i in 6:
		var off := Vector2(randf_range(-8.0, 8.0), 0)
		tw.tween_property(_shake_target, "position", base + off, 0.04)
	tw.tween_property(_shake_target, "position", base, 0.04)


# --- On-screen keyboard layout + highlight --------------------------------

func _build_keyboard() -> void:
	var rows: Array[String] = _KEYBOARD_ROWS
	var row_h: float = _KEY_SIZE.y + _KEY_GAP
	var max_row_w: float = 0.0
	for row in rows:
		var w: float = row.length() * (_KEY_SIZE.x + _KEY_GAP) - _KEY_GAP
		max_row_w = maxf(max_row_w, w)
	_keyboard_root.custom_minimum_size = Vector2(max_row_w, rows.size() * row_h)

	for ri in rows.size():
		var row: String = rows[ri]
		var row_w: float = row.length() * (_KEY_SIZE.x + _KEY_GAP) - _KEY_GAP
		var x_start: float = (max_row_w - row_w) * 0.5
		for ci in row.length():
			var letter: String = row[ci]
			var panel := ColorRect.new()
			panel.color = _COLOR_KEY_BG
			panel.position = Vector2(x_start + ci * (_KEY_SIZE.x + _KEY_GAP), ri * row_h)
			panel.size = _KEY_SIZE
			_keyboard_root.add_child(panel)
			var lbl := Label.new()
			lbl.text = letter
			lbl.anchor_right = 1.0
			lbl.anchor_bottom = 1.0
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			lbl.add_theme_font_size_override(&"font_size", 22)
			lbl.add_theme_color_override(&"font_color", _COLOR_KEY_TEXT)
			panel.add_child(lbl)
			_key_labels[letter] = panel


func _flash_key(letter: String) -> void:
	if not _key_labels.has(letter):
		return
	_key_flash[letter] = 0.18
	_refresh_key_colors()


func _refresh_key_colors() -> void:
	for letter in _key_labels:
		var panel: ColorRect = _key_labels[letter]
		panel.color = _COLOR_KEY_HIT if _key_flash.has(letter) else _COLOR_KEY_BG
