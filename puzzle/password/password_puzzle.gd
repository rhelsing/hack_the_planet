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
## Special-action row; cursor lands on these the same way it does letters.
## Tokens: "SPACE" inserts a literal space, "DEL" backspaces, "OK" submits.
## The on-screen labels are styled separately so they don't share width with
## the letter rows.
const _SPECIAL_ROW: Array[String] = ["SPACE", "DEL", "OK"]
const _KEY_SIZE := Vector2(46, 46)
const _SPECIAL_KEY_SIZE := Vector2(140, 46)
const _KEY_GAP := 6.0

const _COLOR_KEY_BG: Color     = Color(0.18, 0.20, 0.24, 1)
const _COLOR_KEY_HIT: Color    = Color(0.30, 0.85, 1.0, 1)
const _COLOR_KEY_CURSOR: Color = Color(1.0, 0.65, 0.18, 1)
const _COLOR_KEY_TEXT: Color   = Color(0.85, 0.90, 1.0, 1)

var _entered: String = ""
var _finished: bool = false
var _key_flash: Dictionary = {}   # {StringName letter: float remaining_ms}

var _key_labels: Dictionary = {}   # letter → ColorRect panel
## (row, col) the cursor sits on. Row 0–2 = QWERTY; row 3 = _SPECIAL_ROW.
## Cursor is shown unconditionally — keyboard players can ignore it; controller
## players steer it with d-pad / left-stick.
var _cursor: Vector2i = Vector2i(0, 0)
## Inverse lookup: (row, col) → token string. Built alongside _key_labels in
## _build_keyboard so cursor navigation knows which token each cell maps to.
var _grid_tokens: Array = []  # Array of Arrays; _grid_tokens[row][col] = "Q"/"SPACE"/etc.


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

	# --- Cursor / on-screen keyboard navigation (controller-friendly) ----
	# Bound to ui_* actions so d-pad, left-stick, AND arrow keys all drive
	# the cursor. ui_accept presses the focused key; routing to letter / space
	# / del / ok happens inside _press_focused_key().
	if event.is_action_pressed(&"ui_up"):
		_move_cursor(0, -1); get_viewport().set_input_as_handled(); return
	if event.is_action_pressed(&"ui_down"):
		_move_cursor(0, 1); get_viewport().set_input_as_handled(); return
	if event.is_action_pressed(&"ui_left"):
		_move_cursor(-1, 0); get_viewport().set_input_as_handled(); return
	if event.is_action_pressed(&"ui_right"):
		_move_cursor(1, 0); get_viewport().set_input_as_handled(); return
	if event.is_action_pressed(&"ui_accept"):
		_press_focused_key(); get_viewport().set_input_as_handled(); return

	# --- Physical keyboard typing path (unchanged) ------------------------
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


# --- Cursor navigation ----------------------------------------------------

## Step the cursor by (dx, dy). Wraps to the nearest valid column when the
## target row is shorter or longer than the current row (e.g. moving down
## from "OP" of QWERTYUIOP into the 3-button special row).
func _move_cursor(dx: int, dy: int) -> void:
	if _grid_tokens.is_empty():
		return
	var row_count: int = _grid_tokens.size()
	var new_row: int = clampi(_cursor.y + dy, 0, row_count - 1)
	# Snap col to the new row's range using a proportional remap so movement
	# from a wide row to a narrow row feels natural (lands roughly under
	# where you came from, not always at column 0).
	var old_row_len: int = (_grid_tokens[_cursor.y] as Array).size()
	var new_row_len: int = (_grid_tokens[new_row] as Array).size()
	var fraction: float = float(_cursor.x) / max(1.0, float(old_row_len - 1)) if old_row_len > 1 else 0.0
	var snapped_col: int = int(round(fraction * float(new_row_len - 1))) if new_row_len > 1 else 0
	var new_col: int = clampi(snapped_col + dx if dy == 0 else snapped_col, 0, new_row_len - 1)
	# When dy is non-zero we only switch rows; dx is applied separately.
	if dy != 0:
		new_col = clampi(snapped_col, 0, new_row_len - 1)
	_cursor = Vector2i(new_col, new_row)
	_refresh_key_colors()


func _press_focused_key() -> void:
	if _grid_tokens.is_empty():
		return
	var token: String = (_grid_tokens[_cursor.y] as Array)[_cursor.x]
	match token:
		"SPACE":
			if _entered.length() < max_length:
				_entered += " "
				_refresh_entry()
		"DEL":
			if _entered.length() > 0:
				_entered = _entered.substr(0, _entered.length() - 1)
				_refresh_entry()
		"OK":
			_submit()
		_:
			# Letter token — append the lowercase form like physical typing.
			if token.length() == 1 and _entered.length() < max_length:
				_entered += token.to_lower()
				_refresh_entry()
				_flash_key(token)


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
	# Plus one extra row for the special keys.
	var special_row_w: float = _SPECIAL_ROW.size() * (_SPECIAL_KEY_SIZE.x + _KEY_GAP) - _KEY_GAP
	max_row_w = maxf(max_row_w, special_row_w)
	_keyboard_root.custom_minimum_size = Vector2(max_row_w, (rows.size() + 1) * row_h)

	# Letter rows.
	_grid_tokens.clear()
	for ri in rows.size():
		var row: String = rows[ri]
		var row_w: float = row.length() * (_KEY_SIZE.x + _KEY_GAP) - _KEY_GAP
		var x_start: float = (max_row_w - row_w) * 0.5
		var row_tokens: Array = []
		for ci in row.length():
			var letter: String = row[ci]
			row_tokens.append(letter)
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
		_grid_tokens.append(row_tokens)

	# Special-action row (SPACE, DEL, OK) — wider keys.
	var special_x_start: float = (max_row_w - special_row_w) * 0.5
	var special_y: float = rows.size() * row_h
	var special_row_tokens: Array = []
	for ci in _SPECIAL_ROW.size():
		var token: String = _SPECIAL_ROW[ci]
		special_row_tokens.append(token)
		var panel := ColorRect.new()
		panel.color = _COLOR_KEY_BG
		panel.position = Vector2(special_x_start + ci * (_SPECIAL_KEY_SIZE.x + _KEY_GAP), special_y)
		panel.size = _SPECIAL_KEY_SIZE
		_keyboard_root.add_child(panel)
		var lbl := Label.new()
		lbl.text = token
		lbl.anchor_right = 1.0
		lbl.anchor_bottom = 1.0
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override(&"font_size", 18)
		lbl.add_theme_color_override(&"font_color", _COLOR_KEY_TEXT)
		panel.add_child(lbl)
		_key_labels[token] = panel
	_grid_tokens.append(special_row_tokens)

	# Paint the initial cursor position.
	_refresh_key_colors()


func _flash_key(letter: String) -> void:
	if not _key_labels.has(letter):
		return
	_key_flash[letter] = 0.18
	_refresh_key_colors()


func _refresh_key_colors() -> void:
	# Resolve the focused token from cursor position. Used to paint the cursor
	# tile in a distinct color so the player can see what ui_accept will press.
	var focused_token: String = ""
	if not _grid_tokens.is_empty() and _cursor.y < _grid_tokens.size():
		var row: Array = _grid_tokens[_cursor.y]
		if _cursor.x < row.size():
			focused_token = row[_cursor.x]
	for letter in _key_labels:
		var panel: ColorRect = _key_labels[letter]
		if _key_flash.has(letter):
			panel.color = _COLOR_KEY_HIT  # flash on press wins over cursor
		elif letter == focused_token:
			panel.color = _COLOR_KEY_CURSOR  # the controller-cursor highlight
		else:
			panel.color = _COLOR_KEY_BG
