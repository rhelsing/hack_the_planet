extends RefCounted

## Parsed maze. Loaded from a .maze JSON file authored in tools/maze_editor.
##
## No `class_name` — preload by path from consumers. (SceneTree-mode tests
## load this script before its class registers, so self-typed annotations
## like `-> MazeData` fail to resolve.)
##
## Format:
##   { "version": 1,
##     "cols": int, "rows": int,
##     "start": [x,y], "end": [x,y],          # both must be on perimeter
##     "time_limit": float,                    # seconds; 0 = untimed
##     "h": [[0|1, ...], ...],                 # rows × (cols-1)
##                                             # h[y][x] = 1 means edge open
##                                             # between (x,y) and (x+1,y)
##     "v": [[0|1, ...], ...],                 # (rows-1) × cols
##                                             # v[y][x] = 1 means edge open
##                                             # between (x,y) and (x,y+1)
##     "cells": [[0|1|2, ...], ...] }          # (rows-1) × (cols-1)
##                                             # 0=none, 1=water, 2=oil
##                                             # Witness-style separation:
##                                             # if any markers present, the
##                                             # trail must divide cells into
##                                             # regions where each region
##                                             # contains only one marker
##                                             # type. Optional — defaults to
##                                             # all-zero (no separation).
##
## Use:
##   const MazeData = preload("res://puzzle/maze/maze_data.gd")
##   var data := MazeData.new()
##   data.load_path("res://puzzle/maze/mazes/foo.maze")
##   if not data.is_valid(): push_error(data.error); return

const SUPPORTED_VERSION: int = 1

const MARKER_NONE: int = 0
const MARKER_WATER: int = 1
const MARKER_OIL: int = 2

var cols: int = 0
var rows: int = 0
var start: Vector2i = Vector2i.ZERO
var end: Vector2i = Vector2i.ZERO
var time_limit: float = 0.0
var h: Array = []      # Array[Array[int]], rows × (cols-1)
var v: Array = []      # Array[Array[int]], (rows-1) × cols
var cells: Array = []  # Array[Array[int]], (rows-1) × (cols-1)
## Optional title shown in-game above the maze. Empty = falls back to
## the default "HACKING" label authored on the puzzle scene.
var puzzle_name: String = ""
## Optional secondary line shown under the title — flavor text, quote, etc.
var subline: String = ""
var error: String = ""


func load_path(path: String) -> void:
	if not FileAccess.file_exists(path):
		error = "file not found: %s" % path
		return
	load_text(FileAccess.get_file_as_string(path))


func load_text(text: String) -> void:
	var raw: Variant = JSON.parse_string(text)
	if not raw is Dictionary:
		error = "JSON root must be an object"
		return
	var dict: Dictionary = raw
	var version: int = int(dict.get("version", 1))
	if version > SUPPORTED_VERSION:
		error = "unsupported maze version %d (max %d)" % [version, SUPPORTED_VERSION]
		return
	cols = int(dict.get("cols", 0))
	rows = int(dict.get("rows", 0))
	if cols < 2 or rows < 2:
		error = "cols/rows must be >= 2 (got %d × %d)" % [cols, rows]
		return
	var s_raw: Variant = dict.get("start")
	var e_raw: Variant = dict.get("end")
	if not (s_raw is Array and (s_raw as Array).size() == 2):
		error = "start missing or not [x,y]"
		return
	if not (e_raw is Array and (e_raw as Array).size() == 2):
		error = "end missing or not [x,y]"
		return
	start = Vector2i(int(s_raw[0]), int(s_raw[1]))
	end = Vector2i(int(e_raw[0]), int(e_raw[1]))
	time_limit = float(dict.get("time_limit", 0.0))
	# Optional metadata. Type-check so a corrupted file with `"name": null`
	# doesn't produce GDScript's stringified "<null>" in the in-game label.
	# Missing key, wrong type, or null → empty string (no override).
	var name_raw: Variant = dict.get("name", "")
	puzzle_name = name_raw if name_raw is String else ""
	var subline_raw: Variant = dict.get("subline", "")
	subline = subline_raw if subline_raw is String else ""
	h = dict.get("h", [])
	v = dict.get("v", [])
	if h.size() != rows:
		error = "h matrix has %d rows, expected %d" % [h.size(), rows]
		return
	if v.size() != rows - 1:
		error = "v matrix has %d rows, expected %d" % [v.size(), rows - 1]
		return
	if not _in_bounds(start) or not _in_bounds(end):
		error = "start or end out of bounds"
		return
	if not is_perimeter(start) or not is_perimeter(end):
		error = "start and end must be on perimeter"
		return
	# Cells optional — default to empty matrix (no separation rule).
	var raw_cells: Variant = dict.get("cells", null)
	if raw_cells is Array and (raw_cells as Array).size() == rows - 1:
		cells = raw_cells
	else:
		cells = []
		for _y in rows - 1:
			var row: Array = []
			for _x in cols - 1:
				row.append(0)
			cells.append(row)


func is_valid() -> bool:
	return error == "" and cols > 0 and rows > 0


func _in_bounds(node: Vector2i) -> bool:
	return node.x >= 0 and node.x < cols and node.y >= 0 and node.y < rows


func is_perimeter(node: Vector2i) -> bool:
	return node.x == 0 or node.x == cols - 1 or node.y == 0 or node.y == rows - 1


## Returns true if a and b are adjacent grid nodes connected by an open edge.
## Bounds-tolerant: any node off the grid returns false (callers can probe
## "is this direction valid" without their own bounds check).
func has_edge(a: Vector2i, b: Vector2i) -> bool:
	if not _in_bounds(a) or not _in_bounds(b):
		return false
	if a.y == b.y and absi(a.x - b.x) == 1:
		var x: int = mini(a.x, b.x)
		return bool(h[a.y][x])
	if a.x == b.x and absi(a.y - b.y) == 1:
		var y: int = mini(a.y, b.y)
		return bool(v[y][a.x])
	return false


## True iff any cell holds a water or oil marker. When false, the puzzle
## skips the separation check entirely (legacy mazes + cell-free designs).
func has_markers() -> bool:
	for row: Array in cells:
		for v_marker in row:
			if int(v_marker) != MARKER_NONE:
				return true
	return false


## Marker integer for cell (cx, cy). 0 = none, 1 = water, 2 = oil. Returns 0
## for out-of-bounds cells (defensive — separation flood-fill never queries
## out of bounds, but cheap to be safe).
func cell_marker(cx: int, cy: int) -> int:
	if cy < 0 or cy >= rows - 1 or cx < 0 or cx >= cols - 1:
		return MARKER_NONE
	return int(cells[cy][cx])


## Returns the 0..4 grid neighbors of `node` reachable along an open edge.
func neighbors(node: Vector2i) -> Array:
	var out: Array = []
	if node.x > 0 and bool(h[node.y][node.x - 1]):
		out.append(node + Vector2i(-1, 0))
	if node.x < cols - 1 and bool(h[node.y][node.x]):
		out.append(node + Vector2i(1, 0))
	if node.y > 0 and bool(v[node.y - 1][node.x]):
		out.append(node + Vector2i(0, -1))
	if node.y < rows - 1 and bool(v[node.y][node.x]):
		out.append(node + Vector2i(0, 1))
	return out
