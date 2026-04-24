extends "res://puzzle/puzzle.gd"

## Circuit / pipe-flow puzzle. A grid of pipe tiles scrambled at random
## rotations; the "live wire" (yellow) advances tile-by-tile along connected
## pipes at flow_speed_tiles_sec. Player moves a cursor with arrow keys,
## presses Space to rotate the highlighted tile 90° CW. Connect start→end
## before the wire reaches a dead end.
##
## Rules:
##   - Start tile (top-left) has only a SOUTH connection — wire exits there.
##   - End tile (bottom-right) has only a NORTH connection — wire entering
##     from N solves the puzzle.
##   - Middle tiles are straights (N-S) or elbows (N-E), randomly rotated.
##   - Wire stalls + fails if it tries to leave a tile into nothing, or enter
##     a tile that doesn't have a matching inbound connection.

@export var grid_size: Vector2i = Vector2i(2, 2)
@export var tile_size_px: int = 120
@export var flow_speed_tiles_sec: float = 0.5
## Pre-flow window — seconds the player has to rotate tiles before the wire
## starts flowing. Countdown hits 0 → wire begins advancing from the start.
## 0 = wire flows immediately (old behavior).
@export var solve_window_sec: float = 5.0

# Direction bitmask: N=1, E=2, S=4, W=8
const _N: int = 1
const _E: int = 2
const _S: int = 4
const _W: int = 8
const _SHAPE_STRAIGHT: int = _N | _S     # vertical pipe (rotate to get E-W)
const _SHAPE_ELBOW: int    = _N | _E     # corner pipe (rotate for 4 variants)
const _SHAPE_START: int    = _E          # source (top-left) — exits east
const _SHAPE_END: int      = _N          # sink (bottom-right) — enters from north

const _COLOR_PIPE: Color      = Color(0.35, 0.9, 1.0, 1.0)       # cyan
const _COLOR_WIRE: Color      = Color(1.0, 0.95, 0.15, 1.0)      # yellow
const _COLOR_BG: Color        = Color(0.08, 0.10, 0.13, 1.0)
const _COLOR_CELL_BG: Color   = Color(0.14, 0.16, 0.20, 1.0)
const _COLOR_CURSOR: Color    = Color(1.0, 1.0, 1.0, 0.9)
const _COLOR_START_END: Color = Color(0.2, 1.0, 0.5, 1.0)

# One per cell: [base_connections: int, rotation: int (0..3)]
var _base: PackedInt32Array = PackedInt32Array()
var _rot: PackedInt32Array = PackedInt32Array()
var _locked: PackedByteArray = PackedByteArray()   # 1 for start/end (non-rotatable)

var _start_cell: Vector2i
var _end_cell: Vector2i
var _cursor: Vector2i
var _wire_cell: Vector2i           # tile the wire head is currently in
var _wire_from_dir: int = 0        # bitmask of the side the wire entered from
var _wire_progress: float = 0.0    # 0..1 across current tile
var _traversed: Array[Vector2i] = []
var _finished: bool = false
var _time_left: float = 0.0
# Two-phase lifecycle: SOLVING = countdown ticking, player rotates tiles,
# wire is frozen at start. FLOWING = countdown done, wire advances along
# the configured path until it reaches end (win) or a dead end (fail).
var _flowing: bool = false

@onready var _grid_root: Control = %GridRoot
@onready var _title: Label = %Title
@onready var _instructions: Label = %Instructions
@onready var _countdown: Label = %CountdownLabel


func _ready() -> void:
	super._ready()
	var size_px := Vector2(grid_size.x * tile_size_px, grid_size.y * tile_size_px)
	_grid_root.custom_minimum_size = size_px
	_grid_root.size = size_px
	# Re-center the grid Control around its own bounds now that size is known.
	_grid_root.offset_left = -size_px.x * 0.5
	_grid_root.offset_top = -size_px.y * 0.5
	_grid_root.offset_right = size_px.x * 0.5
	_grid_root.offset_bottom = size_px.y * 0.5
	_grid_root.draw.connect(_draw_grid)
	_build_grid()
	_cursor = Vector2i(1, 0) if grid_size.x > 1 else Vector2i(0, 0)
	_start_wire()
	_time_left = solve_window_sec
	_flowing = solve_window_sec <= 0.0
	_update_countdown_label()


# Generate a guaranteed-solvable layout by laying down an L-shaped path
# (east across the top row, then south down the rightmost column), filling
# each path tile with the pipe shape that connects its entry to its exit,
# populating non-path tiles with random decoys, then scrambling rotations
# on every movable tile so the player has to re-align them in time.
func _build_grid() -> void:
	var total: int = grid_size.x * grid_size.y
	_base.resize(total)
	_rot.resize(total)
	_locked.resize(total)
	_start_cell = Vector2i(0, 0)
	_end_cell = Vector2i(grid_size.x - 1, grid_size.y - 1)

	# Path: top-left → right along row 0 → down the rightmost column → bottom-right.
	# Tracks which tiles are on the path + what base shape each needs.
	var path_cells: Array[Vector2i] = []
	for x in grid_size.x:
		path_cells.append(Vector2i(x, 0))
	for y in range(1, grid_size.y):
		path_cells.append(Vector2i(grid_size.x - 1, y))

	# Default: fill every tile with a random decoy shape + random rotation.
	for y in grid_size.y:
		for x in grid_size.x:
			var i: int = y * grid_size.x + x
			_base[i] = _SHAPE_ELBOW if randf() < 0.6 else _SHAPE_STRAIGHT
			_rot[i] = randi() % 4
			_locked[i] = 0

	# Overwrite path tiles with the correct base shape (rotation still random).
	# For grid_size.x == 1 special case, start-and-end are directly stacked.
	var is_single_col: bool = grid_size.x == 1
	for p in path_cells:
		var i: int = p.y * grid_size.x + p.x
		if p == _start_cell:
			_base[i] = _SHAPE_START if not is_single_col else _S
			_locked[i] = 1
			_rot[i] = 0
		elif p == _end_cell:
			_base[i] = _SHAPE_END
			_locked[i] = 1
			_rot[i] = 0
		elif p.y == 0 and p.x == grid_size.x - 1:
			# Top-right corner — turns from W (incoming from left) to S (outgoing down).
			_base[i] = _SHAPE_ELBOW
		elif p.y == 0:
			# Middle of top row — straight horizontal pipe.
			_base[i] = _SHAPE_STRAIGHT
		else:
			# Rightmost column (below row 0) — straight vertical pipe.
			_base[i] = _SHAPE_STRAIGHT


# Rotate a direction bitmask 90° CW. N→E→S→W→N.
static func _rot_bits(bits: int, steps: int) -> int:
	var s: int = ((steps % 4) + 4) % 4
	var out: int = bits
	for _i in s:
		out = ((out << 1) | (out >> 3)) & 0xF
	return out


func _connections_at(cell: Vector2i) -> int:
	var i: int = cell.y * grid_size.x + cell.x
	return _rot_bits(_base[i], _rot[i])


func _opposite(dir_bit: int) -> int:
	match dir_bit:
		_N: return _S
		_E: return _W
		_S: return _N
		_W: return _E
	return 0


func _neighbor(cell: Vector2i, dir_bit: int) -> Vector2i:
	match dir_bit:
		_N: return cell + Vector2i(0, -1)
		_E: return cell + Vector2i(1, 0)
		_S: return cell + Vector2i(0, 1)
		_W: return cell + Vector2i(-1, 0)
	return cell


func _in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < grid_size.x and cell.y < grid_size.y


func _start_wire() -> void:
	_wire_cell = _start_cell
	_wire_from_dir = 0  # no incoming — origin
	_wire_progress = 0.0
	_traversed.clear()
	_traversed.append(_start_cell)


func _process(delta: float) -> void:
	if _finished:
		return
	if not _flowing:
		# SOLVING phase — wire frozen, countdown ticking.
		if solve_window_sec > 0.0:
			_time_left = maxf(_time_left - delta, 0.0)
			_update_countdown_label()
			if _time_left <= 0.0:
				_flowing = true
				_update_countdown_label()
		_grid_root.queue_redraw()
		return
	# FLOWING phase — wire advances. Countdown shows "FLOW" (or hidden) here.
	_wire_progress += flow_speed_tiles_sec * delta
	if _wire_progress >= 1.0:
		_wire_progress -= 1.0
		_advance_wire()
	_grid_root.queue_redraw()


func _update_countdown_label() -> void:
	if _countdown == null:
		return
	if solve_window_sec <= 0.0:
		_countdown.visible = false
		return
	if _flowing:
		_countdown.text = "FLOW"
		_countdown.modulate = Color(1.0, 0.95, 0.15, 1)
		return
	_countdown.text = "%0.1fs" % _time_left
	_countdown.modulate = Color(1, 0.4, 0.4, 1) if _time_left < 1.5 else Color(1, 1, 1, 1)


func _advance_wire() -> void:
	# Find the outgoing connection: current tile connections minus the side we came in on.
	var conns: int = _connections_at(_wire_cell)
	var out_dirs: int = conns & ~_wire_from_dir
	# For pipe shapes (straight / elbow / start) there's exactly one outbound dir.
	# If zero → stuck → fail.
	var exit_dir: int = _first_bit(out_dirs)
	if exit_dir == 0:
		_complete(false)
		_finished = true
		return
	var next_cell: Vector2i = _neighbor(_wire_cell, exit_dir)
	if not _in_bounds(next_cell):
		_complete(false)
		_finished = true
		return
	var need: int = _opposite(exit_dir)
	var next_conns: int = _connections_at(next_cell)
	if (next_conns & need) == 0:
		_complete(false)
		_finished = true
		return
	_wire_cell = next_cell
	_wire_from_dir = need
	_traversed.append(_wire_cell)
	if _wire_cell == _end_cell:
		_complete(true)
		_finished = true


func _first_bit(bits: int) -> int:
	if bits & _N: return _N
	if bits & _E: return _E
	if bits & _S: return _S
	if bits & _W: return _W
	return 0


# --- Input ---------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		_complete(false)
		_finished = true
		return
	if _finished:
		return
	var moved := false
	if event.is_action_pressed(&"ui_up"):
		_cursor.y = maxi(_cursor.y - 1, 0)
		moved = true
	elif event.is_action_pressed(&"ui_down"):
		_cursor.y = mini(_cursor.y + 1, grid_size.y - 1)
		moved = true
	elif event.is_action_pressed(&"ui_left"):
		_cursor.x = maxi(_cursor.x - 1, 0)
		moved = true
	elif event.is_action_pressed(&"ui_right"):
		_cursor.x = mini(_cursor.x + 1, grid_size.x - 1)
		moved = true
	elif event.is_action_pressed(&"ui_accept") or event.is_action_pressed(&"jump"):
		_rotate_cursor_tile()
		moved = true
	if moved:
		get_viewport().set_input_as_handled()
		_grid_root.queue_redraw()


func _rotate_cursor_tile() -> void:
	var i: int = _cursor.y * grid_size.x + _cursor.x
	if _locked[i] == 1:
		return
	_rot[i] = (_rot[i] + 1) % 4


# --- Rendering -----------------------------------------------------------

func _draw_grid() -> void:
	var size_f: float = float(tile_size_px)
	for y in grid_size.y:
		for x in grid_size.x:
			var cell := Vector2i(x, y)
			var origin := Vector2(x * size_f, y * size_f)
			_grid_root.draw_rect(Rect2(origin, Vector2(size_f - 2.0, size_f - 2.0)), _COLOR_CELL_BG)
			var conns: int = _connections_at(cell)
			var is_traversed: bool = _traversed.has(cell)
			_draw_tile_pipes(origin, size_f, conns, _COLOR_PIPE)
			if is_traversed:
				_draw_tile_pipes(origin, size_f, _traversed_bits(cell, conns), _COLOR_WIRE)
			# Start / end markers.
			if cell == _start_cell or cell == _end_cell:
				_grid_root.draw_circle(origin + Vector2(size_f, size_f) * 0.5, size_f * 0.12, _COLOR_START_END)
	# Wire head — draw partway into the NEXT tile along _wire_cell's outgoing dir.
	_draw_wire_head(size_f)
	# Cursor.
	var cur_origin := Vector2(_cursor.x * size_f, _cursor.y * size_f)
	_grid_root.draw_rect(Rect2(cur_origin + Vector2(2, 2), Vector2(size_f - 6.0, size_f - 6.0)), _COLOR_CURSOR, false, 3.0)


# For a traversed tile, yellow covers the portion actually flowed. Start/end
# tiles flow their whole connection; middle tiles flow entry→exit half-pipes.
func _traversed_bits(cell: Vector2i, conns: int) -> int:
	if cell == _start_cell or cell == _end_cell:
		return conns
	# Any traversed middle tile flowed both sides (entry + exit) — simplest
	# is to just light up the whole connection bitmask.
	return conns


func _draw_tile_pipes(origin: Vector2, size_f: float, conns: int, color: Color) -> void:
	var center := origin + Vector2(size_f, size_f) * 0.5
	var half: float = size_f * 0.5
	var thickness: float = maxf(6.0, size_f * 0.12)
	if conns & _N: _grid_root.draw_line(center, center + Vector2(0, -half), color, thickness)
	if conns & _E: _grid_root.draw_line(center, center + Vector2(half, 0), color, thickness)
	if conns & _S: _grid_root.draw_line(center, center + Vector2(0, half), color, thickness)
	if conns & _W: _grid_root.draw_line(center, center + Vector2(-half, 0), color, thickness)


func _draw_wire_head(size_f: float) -> void:
	# Compute head position: starts at the center of the wire_cell's EXIT side
	# (or the center if no exit yet) and eases toward the neighbor's entry center.
	var conns: int = _connections_at(_wire_cell)
	var out_dirs: int = conns & ~_wire_from_dir
	var exit_dir: int = _first_bit(out_dirs)
	if exit_dir == 0:
		return
	var here_center := Vector2(_wire_cell.x * size_f + size_f * 0.5, _wire_cell.y * size_f + size_f * 0.5)
	var next_cell: Vector2i = _neighbor(_wire_cell, exit_dir)
	var next_center := Vector2(next_cell.x * size_f + size_f * 0.5, next_cell.y * size_f + size_f * 0.5)
	var head := here_center.lerp(next_center, _wire_progress)
	_grid_root.draw_circle(head, maxf(8.0, size_f * 0.14), _COLOR_WIRE)
