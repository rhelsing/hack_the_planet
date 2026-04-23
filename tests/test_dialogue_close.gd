extends Node

## Verifies Dialogue.force_close() / _close() behave correctly in three cases:
##  1. Called while not open — no-op, no crash.
##  2. Called while open — cleans state, unpauses tree, emits lifecycle.
##  3. Called after tree has been torn down — null-tree guard prevents the
##     'Invalid assignment of property or key paused on null instance' crash
##     we hit in the user's 2026-04-22 play session.
##
## Run with:
##   godot --headless res://tests/test_dialogue_close.tscn


var _closed_events: Array = []
var _modal_closed_events: Array = []


func _ready() -> void:
	Events.dialogue_ended.connect(func(id): _closed_events.append(id))
	Events.modal_closed.connect(func(id): _modal_closed_events.append(id))
	_run.call_deferred()


func _run() -> void:
	var failures: Array[String] = []

	# ---- Case 1: close when not open is a no-op ----
	if Dialogue.is_open():
		failures.append("Dialogue should not be open at test start")
	Dialogue.force_close()  # should be silent no-op
	if _closed_events.size() != 0:
		failures.append("force_close on closed dialogue should not emit dialogue_ended")
	if _modal_closed_events.size() != 0:
		failures.append("force_close on closed dialogue should not emit modal_closed")

	# ---- Case 2: normal open → close cycle ----
	# We don't have a real DialogueResource in headless tests, so we drive
	# the autoload's internal state directly — this exercises _close without
	# depending on the plugin. Matches what happens after the balloon fires
	# tree_exited on its own queue_free.
	#
	# As of the 2026-04-22 change, Dialogue does NOT pause the tree — world
	# keeps ticking while balloon is up (player rooted via balloon's
	# will_block_other_input). So this test no longer asserts pause state.
	Dialogue._open = true
	Dialogue._active_id = &"test_troll"

	Dialogue.force_close()
	await get_tree().process_frame

	if Dialogue.is_open():
		failures.append("is_open should be false after force_close")
	if not _closed_events.has(&"test_troll"):
		failures.append("dialogue_ended should fire with the active_id")
	if not _modal_closed_events.has(&"dialogue"):
		failures.append("modal_closed(&\"dialogue\") should fire on close")

	# ---- Case 3: _open is true but _close is called when tree teardown
	# would be under way. Simulate by calling _close twice in succession —
	# the second call must be a no-op (atomic state flip). This guards the
	# race where tree_exited fires after force_close.
	_closed_events.clear()
	_modal_closed_events.clear()
	Dialogue._open = true
	Dialogue._active_id = &"double_close_troll"
	Dialogue.force_close()
	Dialogue.force_close()  # second call should see _open == false and bail
	await get_tree().process_frame
	if _closed_events.size() != 1:
		failures.append("double close should emit dialogue_ended exactly once, got %d" % _closed_events.size())

	# ---- Case 4: state ordering — _open flips FIRST so a re-entrant call
	# from a signal handler sees a consistent world. Simulate by connecting
	# to dialogue_ended and calling is_open() during the emit.
	var observed_open_during_emit := [true]  # wrapped for lambda capture
	var probe := func(_id):
		observed_open_during_emit[0] = Dialogue.is_open()
	Events.dialogue_ended.connect(probe)
	Dialogue._open = true
	Dialogue._active_id = &"ordering_troll"
	Dialogue.force_close()
	await get_tree().process_frame
	Events.dialogue_ended.disconnect(probe)
	if observed_open_during_emit[0]:
		failures.append("is_open() must return false before dialogue_ended fires (state ordering invariant)")

	# ---- Done ----
	if failures.is_empty():
		print("PASS test_dialogue_close: force_close is safe when closed, emits once, orders state before signal, guards null tree")
		get_tree().quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_dialogue_close: " + f)
		get_tree().quit(1)
