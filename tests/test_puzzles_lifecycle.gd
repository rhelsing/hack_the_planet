extends Node

## Integration test for Puzzles autoload + Puzzle base + HackingPuzzle
## end-to-end. Verifies modal_opened/closed pairing, puzzle_started/solved
## emission, pause toggle, and clean teardown.
##
## Run with:
##   godot --headless res://tests/test_puzzles_lifecycle.tscn


const HackingPuzzleScene = preload("res://puzzle/hacking/hacking_puzzle.tscn")


var _modal_opens: Array = []
var _modal_closes: Array = []
var _puzzle_started: Array = []
var _puzzle_solved: Array = []
var _puzzle_failed: Array = []


func _ready() -> void:
	Events.modal_opened.connect(func(id): _modal_opens.append(id))
	Events.modal_closed.connect(func(id): _modal_closes.append(id))
	Events.puzzle_started.connect(func(id): _puzzle_started.append(id))
	Events.puzzle_solved.connect(func(id): _puzzle_solved.append(id))
	Events.puzzle_failed.connect(func(id): _puzzle_failed.append(id))

	_run.call_deferred()


func _run() -> void:
	var failures: Array[String] = []

	# Start: Puzzles.is_active() should be false initially.
	if Puzzles.is_active():
		failures.append("Puzzles.is_active should be false at startup")

	# Kick off the puzzle. Don't await the call — start() awaits internally.
	Puzzles.start(HackingPuzzleScene, &"test_hack_01")

	# Give the instantiation a frame to settle.
	await get_tree().process_frame
	await get_tree().process_frame

	if not Puzzles.is_active():
		failures.append("is_active should be true during puzzle")
	if Puzzles.is_active() and not get_tree().paused:
		failures.append("tree should be paused while puzzle active")
	if not _modal_opens.has(&"puzzle"):
		failures.append("modal_opened(&\"puzzle\") should have fired")
	if not _puzzle_started.has(&"test_hack_01"):
		failures.append("puzzle_started should carry the id")

	# Find the puzzle instance and force-complete it with success.
	var puzzle := _find_puzzle_node()
	if puzzle == null:
		failures.append("could not locate running Puzzle instance in tree")
	else:
		puzzle._complete(true)

	# Let the await resolve.
	await get_tree().process_frame
	await get_tree().process_frame

	if Puzzles.is_active():
		failures.append("is_active should be false after _complete")
	if get_tree().paused:
		failures.append("tree should be unpaused after puzzle close")
	if not _modal_closes.has(&"puzzle"):
		failures.append("modal_closed(&\"puzzle\") should have fired")
	if not _puzzle_solved.has(&"test_hack_01"):
		failures.append("puzzle_solved should fire on success=true")
	if _puzzle_failed.size() > 0:
		failures.append("puzzle_failed should NOT fire on success path")

	# Modal counter symmetry.
	if _modal_opens.size() != _modal_closes.size():
		failures.append("modal open/close counts must match: %d vs %d" %
			[_modal_opens.size(), _modal_closes.size()])

	if failures.is_empty():
		print("PASS test_puzzles_lifecycle: start → complete(true) cycle emits all signals, restores pause state")
		get_tree().quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_puzzles_lifecycle: " + f)
		get_tree().quit(1)


func _find_puzzle_node() -> Node:
	# Puzzles.start added the instance to get_tree().root — find by having
	# a `finished` signal and being a CanvasLayer child of root.
	for c: Node in get_tree().root.get_children():
		if c is CanvasLayer and c.has_signal(&"finished"):
			return c
	return null
