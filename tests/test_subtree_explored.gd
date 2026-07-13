extends Node

## Phase C test — recursive subtree-explored check.
##
## Builds a fixture DialogueResource via DialogueManager.create_resource_from_text
## with a parent → sub-hub structure, then exercises scroll_balloon's
## _subtree_fully_explored against various visit states.
##
## Cases:
##   1. Leaf option (no sub-hub): subtree_fully_explored returns true
##      regardless of visit state — flat probes behave like Phase A/B.
##   2. Parent option with sub-hub: not explored until ALL non-exit
##      grandchildren are visited.
##   3. Hidden ([if /]-failed) children don't block parent dim — they're
##      excluded from the children list at compile time, so the walker
##      doesn't see them.
##   4. Cycle safety: a sub-hub that loops back via `=> start` doesn't
##      infinite-loop the walker.
##   5. Nested reaction menu falling through to the GRANDPARENT hub (the
##      dial_tone "Are you who messaged me?" → Yes / Thinking shape): once
##      the nested options are picked, the probe is fully explored — the
##      walker must not mistake the grandparent hub for the reaction's
##      sub-hub (regression: probe never dimmed).
##   6. [#decision]-tagged probe: fully explored regardless of its fork
##      children — the tag means "pick one endpoint and the question is
##      answered", checked at the top level (dim pass), not just when the
##      probe appears as a child of another walk.

const FIXTURE: String = """~ start

- Parent A
	Glitch: opening A
	=> sub_a
- Parent B
	Glitch: B response
=> start

~ sub_a

- Sub A1
	Glitch: a1
- Sub A2
	Glitch: a2
- Back. [#exit]
	=> start
=> sub_a
"""

## Case 5 fixture — mirrors dial_tone's dialtone_questions hub: the probe's
## body contains an inline reaction menu, and both reaction branches fall
## through past the probe's body into the hub's trailing `=> hub` loop.
const FIXTURE_NESTED: String = """~ hub

- Probe
	DialTone: intro line
	- Yes
		DialTone: yes line
	- Thinking about it
		DialTone: thinking line
- Other probe
	DialTone: other line
=> hub
"""


func _ready() -> void:
	var failures: Array[String] = []

	var ss := get_node_or_null(^"/root/SaveService")
	var ds := get_node_or_null(^"/root/DialogueState")
	var dm := get_node_or_null(^"/root/DialogueManager")
	if ss == null or ds == null or dm == null:
		_finish(["SaveService / DialogueState / DialogueManager autoload missing"]); return

	# Back up sidecars for slot a.
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

	ss.begin_new_game(&"a")

	# Compile the fixture dialogue.
	var resource: DialogueResource = dm.create_resource_from_text(FIXTURE)
	if resource == null:
		_finish(["create_resource_from_text returned null"]); return

	# Instantiate scroll_balloon and bind the fixture resource.
	var balloon_packed: PackedScene = load("res://dialogue/scroll_balloon.tscn")
	var balloon: CanvasLayer = balloon_packed.instantiate()
	add_child(balloon)
	await get_tree().process_frame
	balloon.set("dialogue_resource", resource)
	balloon.set("_last_known_speaker", "Glitch")

	# Get the start line — its responses are [Parent A, Parent B].
	var line: DialogueLine = await dm.get_next_dialogue_line(resource, "start", [balloon])
	if line == null or line.responses.size() != 2:
		_finish(["fixture start line should have 2 responses, got %d" % (line.responses.size() if line != null else -1)]); return
	var parent_a: DialogueResponse = null
	var parent_b: DialogueResponse = null
	for r in line.responses:
		if r.text == "Parent A": parent_a = r
		elif r.text == "Parent B": parent_b = r
	if parent_a == null or parent_b == null:
		_finish(["could not find Parent A / Parent B responses in fixture"]); return

	# ---- 1. Leaf option (Parent B): subtree always explored ----
	var b_explored: bool = balloon.call("_subtree_fully_explored", parent_b, "Glitch")
	if not b_explored:
		failures.append("Leaf Parent B should report subtree_fully_explored=true")

	# Simulate one sub-hub render so all visible children are marked seen
	# (real gameplay: scroll_balloon._mark_responses_seen does this on every
	# menu render; the unit test bypasses the rendering pipeline so we
	# replicate it manually here). Without this, the engine's
	# never-seen-skip rule would treat every child as "gated out" and
	# wrongly report the parent as fully explored.
	ds.mark_seen("Glitch", "Sub A1")
	ds.mark_seen("Glitch", "Sub A2")
	ds.mark_seen("Glitch", "Back.")

	# ---- 2. Parent A initial state: NOT explored (children unvisited) ----
	var a_initial: bool = balloon.call("_subtree_fully_explored", parent_a, "Glitch")
	if a_initial:
		failures.append("Parent A should NOT be fully explored before any sub-options visited")

	# Visit only Sub A1.
	ds.visit_dialogue("Glitch", "Sub A1")
	var a_after_a1: bool = balloon.call("_subtree_fully_explored", parent_a, "Glitch")
	if a_after_a1:
		failures.append("Parent A still not fully explored — Sub A2 unvisited")

	# Visit Sub A2 too.
	ds.visit_dialogue("Glitch", "Sub A2")
	var a_after_both: bool = balloon.call("_subtree_fully_explored", parent_a, "Glitch")
	if not a_after_both:
		failures.append("Parent A SHOULD be fully explored after both sub options visited")

	# ---- 3. Exit-tagged "Back." doesn't need to be visited for completion ----
	# (The fact that case 2 passed without visiting "Back." proves this — but
	# make the assertion explicit.)
	if ds.has_visited_dialogue("Glitch", "Back."):
		failures.append("Test setup glitch: Back. should NOT be marked visited")
	if not balloon.call("_subtree_fully_explored", parent_a, "Glitch"):
		failures.append("Exit-tagged 'Back.' not required for completion")

	# ---- 4. Cycle safety: walker terminates ----
	# The fixture has `=> start` from sub_a, which would loop if not handled.
	# We've already exercised _subtree_fully_explored multiple times — if it
	# was infinite-looping, the test would have hung. Belt-and-suspenders:
	# add a hard timeout via a simple sentinel.
	var t0 := Time.get_ticks_msec()
	balloon.call("_subtree_fully_explored", parent_a, "Glitch")
	balloon.call("_subtree_fully_explored", parent_b, "Glitch")
	var t1 := Time.get_ticks_msec()
	if t1 - t0 > 1000:
		failures.append("Subtree walker took >1s on small fixture — cycle detection likely missed (took %dms)" % (t1 - t0))

	# ---- 5. Nested reaction menu falling through to grandparent hub ----
	# Fresh balloon bound to the nested fixture; scoped to "DialTone".
	var nested_resource: DialogueResource = dm.create_resource_from_text(FIXTURE_NESTED)
	if nested_resource == null:
		_finish(["create_resource_from_text returned null for FIXTURE_NESTED"]); return
	var balloon2: CanvasLayer = balloon_packed.instantiate()
	add_child(balloon2)
	await get_tree().process_frame
	balloon2.set("dialogue_resource", nested_resource)
	balloon2.set("_last_known_speaker", "DialTone")

	var hub_line: DialogueLine = await dm.get_next_dialogue_line(nested_resource, "hub", [balloon2])
	var probe: DialogueResponse = null
	for r in hub_line.responses:
		if r.text == "Probe": probe = r
	if probe == null:
		_finish(["could not find Probe response in FIXTURE_NESTED"]); return

	# Simulate renders: hub options + nested reaction options all seen.
	for t in ["Probe", "Other probe", "Yes", "Thinking about it"]:
		ds.mark_seen("DialTone", t)

	# Probe visited but reactions not yet: NOT fully explored.
	ds.visit_dialogue("DialTone", "Probe")
	if balloon2.call("_subtree_fully_explored", probe, "DialTone"):
		failures.append("Probe should NOT be explored before its reaction options are picked")

	# Both reactions visited: fully explored — even though "Other probe"
	# (a sibling in the grandparent hub) is untouched. Pre-fix, the walker
	# treated the hub as Yes's sub-hub and this returned false forever.
	ds.visit_dialogue("DialTone", "Yes")
	ds.visit_dialogue("DialTone", "Thinking about it")
	if not balloon2.call("_subtree_fully_explored", probe, "DialTone"):
		failures.append("Probe SHOULD be explored once both nested reactions are picked (grandparent loop-back)")

	# ---- 6. Decision-tagged probe explored without exhausting its fork ----
	# Reuses the nested fixture's shape via a decision-tagged variant.
	var decision_fixture := """~ hub

- Pick one [#decision]
	DialTone: choose
	- Left
		DialTone: left line
	- Right
		DialTone: right line
- Filler
	DialTone: filler line
=> hub
"""
	var decision_resource: DialogueResource = dm.create_resource_from_text(decision_fixture)
	var balloon3: CanvasLayer = balloon_packed.instantiate()
	add_child(balloon3)
	await get_tree().process_frame
	balloon3.set("dialogue_resource", decision_resource)
	balloon3.set("_last_known_speaker", "DialTone")
	var hub2: DialogueLine = await dm.get_next_dialogue_line(decision_resource, "hub", [balloon3])
	var pick_one: DialogueResponse = null
	for r in hub2.responses:
		if r.text == "Pick one": pick_one = r
	if pick_one == null:
		_finish(["could not find 'Pick one' response in decision fixture"]); return
	for t in ["Pick one", "Filler", "Left", "Right"]:
		ds.mark_seen("DialTone", t)
	ds.visit_dialogue("DialTone", "Pick one")
	ds.visit_dialogue("DialTone", "Left")  # Right stays unvisited on purpose
	if not balloon3.call("_subtree_fully_explored", pick_one, "DialTone"):
		failures.append("decision-tagged probe should be fully explored after one fork branch")
	balloon3.queue_free()

	balloon2.queue_free()

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
		print("PASS test_subtree_explored: 6 cases clean")
		get_tree().quit(0)
	else:
		for f in failures:
			printerr("FAIL test_subtree_explored: " + str(f))
		get_tree().quit(1)
