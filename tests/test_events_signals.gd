extends SceneTree
## Smoke test: events.gd declares every signal the ui_dev spec requires.
## Run with:
##   godot --headless --path . --script res://tests/test_events_signals.gd --quit
## Godot doesn't initialize project autoloads when you --script into a
## standalone SceneTree, so we preload the script and instance it directly
## rather than relying on the Events global identifier.

const EventsScript := preload("res://autoload/events.gd")

func _init() -> void:
	var failures: Array[String] = []
	var inst: Node = EventsScript.new()

	var required := [
		# Existing world events (owned by other devs) — verify intact.
		"kill_plane_touched",
		"flag_reached",
		"checkpoint_reached",
		# ui_dev additions (docs/menus.md §14, sync_up 2026-04-22).
		"modal_opened",
		"modal_closed",
		"modal_count_reset",
		"settings_applied",
		"game_saved",
		"game_loaded",
		"menu_opened",
		"menu_closed",
	]

	for sig in required:
		if not inst.has_signal(sig):
			failures.append("Events missing signal: %s" % sig)

	inst.free()

	if failures.is_empty():
		print("PASS test_events_signals: all required signals declared")
		quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_events_signals: " + f)
		quit(1)
