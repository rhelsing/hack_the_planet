extends Node

## Phase B test — scroll_balloon's new-unlock render pass.
##
## Strategy: instantiate the balloon directly, populate its ResponsesMenu
## with fake Button children carrying meta("response", DialogueResponse),
## drive _last_known_speaker (so _resolve_speaker returns), then call the
## render helpers and assert on the resulting button stylebox + child order.
##
## Avoids loading a real DialogueResource through DialogueManager — that
## would inflate test runtime and tangle this test in DM internals. The
## render helpers we're testing only read meta/text/tags, which we can fake.
##
## Asserts:
##   1. First render of an unseen hub: NO options flagged new (the "any
##      sibling already seen" gate prevents first-time-here flagging).
##   2. After all options marked seen + a new option appears (simulating
##      an [if /] gate flipping): the new option IS flagged new, seen
##      siblings are not.
##   3. New options get the green outline stylebox (border_color matches
##      NEW_UNLOCK_OUTLINE).
##   4. Reorder: a new option ends up near the top of the menu (move_child
##      to slot 1, above the response_template at slot 0).
##   5. Exit-tagged options are never flagged "new" or marked "seen".
##
## Scene-mode (autoloads needed). Backs up sidecar for slot a.


func _ready() -> void:
	var failures: Array[String] = []

	var ss := get_node_or_null(^"/root/SaveService")
	var ds := get_node_or_null(^"/root/DialogueState")
	if ss == null or ds == null:
		_finish(["SaveService or DialogueState autoload missing"]); return

	# Back up slot a's files.
	var prior_active: StringName = ss.active_slot
	var ds_p: String = ss._dialogue_state_path(&"a")
	var sp: String = ss._save_path(&"a")
	var mp: String = ss._meta_path(&"a")
	var had_ds := FileAccess.file_exists(ds_p)
	var had_sp := FileAccess.file_exists(sp)
	var had_mp := FileAccess.file_exists(mp)
	if had_ds: DirAccess.rename_absolute(ds_p, ds_p + ".test_bak")
	if had_sp: DirAccess.rename_absolute(sp, sp + ".test_bak")
	if had_mp: DirAccess.rename_absolute(mp, mp + ".test_bak")

	ss.begin_new_game(&"a")  # fresh slot a; binds DialogueState

	# Instantiate balloon.
	var balloon_packed: PackedScene = load("res://dialogue/scroll_balloon.tscn")
	var balloon: CanvasLayer = balloon_packed.instantiate()
	add_child(balloon)
	# Wait one frame for @onready references to bind.
	await get_tree().process_frame

	# Set the speaker fallback so _resolve_speaker returns "Glitch" without
	# a real dialogue_line.
	balloon.set("_last_known_speaker", "Glitch")

	var responses_menu: Node = balloon.get("responses_menu")
	if responses_menu == null:
		_finish(["responses_menu @onready did not bind"]); return

	# Pre-existing template button (placed by .tscn).
	var template: Node = balloon.get("responses_menu").get_child(0)
	if template == null:
		failures.append("expected response_template child in slot 0")

	# Helper to populate responses_menu from a list of {text, tags} dicts.
	var populate := func(rows: Array) -> void:
		# Clear any prior buttons (keep the template at slot 0).
		var to_remove: Array[Node] = []
		for child in responses_menu.get_children():
			if child.has_meta("response"):
				to_remove.append(child)
		for child in to_remove:
			responses_menu.remove_child(child)
			child.queue_free()
		for d in rows:
			var btn := Button.new()
			btn.text = d["text"]
			var resp := DialogueResponse.new({
				id = "fake_%s" % d["text"],
				type = "response",
				next_id = "fake_next",
				is_allowed = true,
				condition_as_text = "",
				character = "",
				character_replacements = [] as Array[Dictionary],
				text = d["text"],
				text_replacements = [] as Array[Dictionary],
				tags = PackedStringArray(d["tags"]),
				static_id = d["text"],
			})
			btn.set_meta("response", resp)
			responses_menu.add_child(btn)

	# ---- 1. First render of an unseen hub: NO options flagged new ----
	# Initial menu: Alpha, Beta, Onward. None seen yet. The "any-sibling-seen"
	# gate should suppress flagging — first time here, no green outline.
	populate.call([
		{"text": "Probe Alpha", "tags": []},
		{"text": "Probe Beta", "tags": []},
		{"text": "Onward.", "tags": ["exit"]},
	])
	balloon.call("_compute_new_responses")
	var new_set_first: Dictionary = balloon.get("_new_response_texts")
	if not new_set_first.is_empty():
		failures.append("First render of unseen hub should highlight NOTHING (got %s)" % new_set_first.keys())

	# Mark Alpha + Beta seen (simulating the player having seen this hub).
	balloon.call("_mark_responses_seen")
	if not ds.has_seen("Glitch", "Probe Alpha"):
		failures.append("Probe Alpha should be marked seen after _mark_responses_seen")
	if not ds.has_seen("Glitch", "Probe Beta"):
		failures.append("Probe Beta should be marked seen after _mark_responses_seen")

	# ---- 5. Exit-tagged options NEVER tracked ----
	if ds.has_seen("Glitch", "Onward."):
		failures.append("Exit-tagged option must not be marked seen")

	# ---- 2. New unlock: re-render with extra option, only it flagged ----
	# Simulates an [if /] gate flipping. Alpha + Beta are seen, Charlie is new.
	populate.call([
		{"text": "Probe Alpha", "tags": []},
		{"text": "Probe Beta", "tags": []},
		{"text": "Probe Charlie", "tags": []},
		{"text": "Onward.", "tags": ["exit"]},
	])
	balloon.call("_compute_new_responses")
	var new_set_unlock: Dictionary = balloon.get("_new_response_texts")
	if not new_set_unlock.has("Probe Charlie"):
		failures.append("Probe Charlie should be flagged new (sibling already seen)")
	if new_set_unlock.has("Probe Alpha"):
		failures.append("Already-seen Probe Alpha should NOT be flagged new")
	if new_set_unlock.has("Probe Beta"):
		failures.append("Already-seen Probe Beta should NOT be flagged new")
	if new_set_unlock.has("Onward."):
		failures.append("Exit-tagged Onward must never be flagged new")
	if new_set_unlock.size() != 1:
		failures.append("Expected exactly 1 newly-unlocked option, got %d" % new_set_unlock.size())

	# ---- 3 & 4. Styling: outline + reorder on Charlie only ----
	balloon.call("_style_new_responses")
	var found_charlie := false
	var charlie_at_top := false
	for i in range(responses_menu.get_child_count()):
		var c: Node = responses_menu.get_child(i)
		if c is Button and (c as Button).text == "Probe Charlie":
			found_charlie = true
			# move_child(btn, 1) — slot 0 is template, so Charlie should be ≤ 2.
			if i <= 2:
				charlie_at_top = true
			var sb: StyleBoxFlat = (c as Button).get_theme_stylebox("normal") as StyleBoxFlat
			if sb == null:
				failures.append("Probe Charlie missing 'normal' stylebox override")
			else:
				var expected := Color(0.353, 0.910, 0.353, 1.0)
				if not sb.border_color.is_equal_approx(expected):
					failures.append("Probe Charlie border_color != NEW_UNLOCK_OUTLINE (got %s)" % sb.border_color)
				if sb.border_width_left < 1:
					failures.append("Probe Charlie border_width should be > 0")

	if not found_charlie:
		failures.append("Probe Charlie button not found in responses_menu")
	if not charlie_at_top:
		failures.append("Probe Charlie should be near top of menu after reorder")

	# ---- Cleanup ----
	balloon.queue_free()
	await get_tree().process_frame
	ds.bind_slot(&"")
	for p in [ds_p, sp, mp]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	if had_ds: DirAccess.rename_absolute(ds_p + ".test_bak", ds_p)
	if had_sp: DirAccess.rename_absolute(sp + ".test_bak", sp)
	if had_mp: DirAccess.rename_absolute(mp + ".test_bak", mp)
	ss.active_slot = prior_active

	_finish(failures)


func _finish(failures: Array) -> void:
	if failures.is_empty():
		print("PASS test_balloon_new_unlock_render: 5 cases clean")
		get_tree().quit(0)
	else:
		for f in failures:
			printerr("FAIL test_balloon_new_unlock_render: " + str(f))
		get_tree().quit(1)
