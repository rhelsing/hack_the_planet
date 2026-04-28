extends SceneTree

## Smoke test for puzzle/maze/maze_data.gd against the level-2 fixture.
## Run: godot --headless --script res://tests/test_maze_data.gd --quit

const MazeData = preload("res://puzzle/maze/maze_data.gd")
const FIXTURE: String = "res://puzzle/maze/mazes/l2_hack_terminal.maze"


func _init() -> void:
	var d = MazeData.new()
	d.load_path(FIXTURE)
	assert(d.is_valid(), "parse failed: %s" % d.error)
	assert(d.cols == 5, "expected cols=5 got %d" % d.cols)
	assert(d.rows == 5, "expected rows=5 got %d" % d.rows)
	assert(d.start == Vector2i(0, 1), "start mismatch: %s" % d.start)
	assert(d.end == Vector2i(4, 4), "end mismatch: %s" % d.end)
	assert(d.is_perimeter(d.start), "start not on perimeter")
	assert(d.is_perimeter(d.end), "end not on perimeter")
	# At least one neighbor of start must be reachable through an open edge,
	# otherwise the editor's verify gate would have rejected the export.
	assert(not d.neighbors(d.start).is_empty(), "start has no open neighbors")
	# Adjacency consistency: has_edge agrees with neighbors().
	for nb in d.neighbors(d.start):
		assert(d.has_edge(d.start, nb), "neighbors() returned %s but has_edge() denies it" % nb)
	# BFS from start must reach end (editor enforces, parser must agree).
	var seen: Dictionary = {d.start: true}
	var queue: Array = [d.start]
	var found: bool = false
	while not queue.is_empty():
		var n: Vector2i = queue.pop_front()
		if n == d.end:
			found = true
			break
		for nb in d.neighbors(n):
			if not seen.has(nb):
				seen[nb] = true
				queue.append(nb)
	assert(found, "BFS could not reach end from start in fixture")
	# Untimed: time_limit should be 0 since the editor exported without timer.
	assert(d.time_limit == 0.0, "expected untimed (0.0), got %f" % d.time_limit)
	# Bad-shape rejection.
	var bad = MazeData.new()
	bad.load_text('{"cols": 5, "rows": 5}')
	assert(not bad.is_valid(), "expected error on missing start/end, got valid")
	print("test_maze_data OK — cols=%d rows=%d start=%s end=%s timed=%.1f" % [
		d.cols, d.rows, d.start, d.end, d.time_limit])
	quit(0)
