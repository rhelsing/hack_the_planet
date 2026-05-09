extends Node

## Phase A test — DialogueState sidecar persistence.
##
## Asserts:
##   1. visit() writes; sidecar file appears.
##   2. Survives a GameState.from_dict that doesn't carry dialogue_visited
##      (the bug that triggered v2 — load_from_slot used to clobber visit
##      history; DialogueState as a separate sidecar must not).
##   3. bind_slot reloads from disk into a fresh in-memory state.
##   4. begin_new_game wipes only the slot in question's sidecar.
##   5. Switching slots reads the right file per slot.
##
## Scene-mode test — needs autoloads. Run via:
##   godot --headless res://tests/test_dialogue_state_persistence.tscn
## Exits 0 on pass, 1 on fail.

const TEST_SLOTS: Array[StringName] = [&"a", &"b"]


func _ready() -> void:
	var failures: Array[String] = []

	# Back up any real sidecars + active slot before mutating, so dev's saves
	# survive the test run.
	var ss := get_node_or_null(^"/root/SaveService")
	var ds := get_node_or_null(^"/root/DialogueState")
	if ss == null:
		_finish(["SaveService autoload missing"]); return
	if ds == null:
		_finish(["DialogueState autoload missing"]); return

	var prior_active: StringName = ss.active_slot
	var backups: Dictionary = {}
	var backed_save_meta: Dictionary = {}  # {slot: {save: had, meta: had}}
	for slot in TEST_SLOTS:
		var p: String = ss._dialogue_state_path(slot)
		backups[slot] = FileAccess.file_exists(p)
		if backups[slot]: DirAccess.rename_absolute(p, p + ".test_bak")
		# Also back up save+meta files so begin_new_game's save_to_slot doesn't
		# stomp the dev's actual saves.
		var sp: String = ss._save_path(slot)
		var mp: String = ss._meta_path(slot)
		var had_sp := FileAccess.file_exists(sp)
		var had_mp := FileAccess.file_exists(mp)
		if had_sp: DirAccess.rename_absolute(sp, sp + ".test_bak")
		if had_mp: DirAccess.rename_absolute(mp, mp + ".test_bak")
		backed_save_meta[slot] = {&"save": had_sp, &"meta": had_mp}

	# ---- 1. visit writes; sidecar appears ----
	ss.begin_new_game(&"a")  # binds slot a, wipes sidecar
	ds.visit_dialogue("Glitch", "About those Sentinels...")
	ds.flush()  # bypass the deferred coalescer
	if not FileAccess.file_exists(ss._dialogue_state_path(&"a")):
		failures.append("after visit + flush, sidecar file should exist for slot a")
	if not ds.has_visited_dialogue("Glitch", "About those Sentinels..."):
		failures.append("in-memory has_visited_dialogue should be true after visit")

	# ---- 2. Survives GameState.from_dict with empty dialogue_visited ----
	# Simulates load_from_slot's _apply_game_state path. DialogueState must NOT
	# be touched by that — sidecar reload is a separate code path.
	var gs := get_node_or_null(^"/root/GameState")
	if gs != null and gs.has_method(&"from_dict"):
		gs.call(&"from_dict", {"version": 3, "inventory": [], "flags": {}, "dialogue_visited": {}})
	if not ds.has_visited_dialogue("Glitch", "About those Sentinels..."):
		failures.append("DialogueState should survive GameState.from_dict (the v2-fix bug)")

	# ---- 3. bind_slot reloads from disk into a fresh in-memory state ----
	ds.bind_slot(&"")  # unbind
	if ds.has_visited_dialogue("Glitch", "About those Sentinels..."):
		failures.append("bind_slot('') should clear in-memory visited")
	ds.bind_slot(&"a")  # rebind — should reload sidecar from disk
	if not ds.has_visited_dialogue("Glitch", "About those Sentinels..."):
		failures.append("bind_slot(a) should reload visited from sidecar")

	# ---- 4. begin_new_game wipes the slot's sidecar ----
	ss.begin_new_game(&"a")
	if ds.has_visited_dialogue("Glitch", "About those Sentinels..."):
		failures.append("begin_new_game should wipe DialogueState in-memory")
	if FileAccess.file_exists(ss._dialogue_state_path(&"a")):
		var f := FileAccess.open(ss._dialogue_state_path(&"a"), FileAccess.READ)
		var parsed = JSON.parse_string(f.get_as_text()) if f != null else null
		if parsed is Dictionary and not parsed.get("visited", {}).is_empty():
			failures.append("begin_new_game should wipe sidecar visited dict on disk")

	# ---- 5. Per-slot isolation ----
	# Slot a: visit X. Switch to b: visit Y. Switch back to a: should see X, not Y.
	ds.visit_dialogue("Glitch", "TopicA")
	ds.flush()
	ss.begin_new_game(&"b")
	ds.visit_dialogue("Glitch", "TopicB")
	ds.flush()
	if ds.has_visited_dialogue("Glitch", "TopicA"):
		failures.append("slot b should not see slot a's visits (TopicA leaked)")
	ds.bind_slot(&"a")
	if not ds.has_visited_dialogue("Glitch", "TopicA"):
		failures.append("rebinding to slot a should restore TopicA")
	if ds.has_visited_dialogue("Glitch", "TopicB"):
		failures.append("slot a should not see slot b's visits (TopicB leaked)")

	# ---- Cleanup: restore originals ----
	ds.bind_slot(&"")
	for slot in TEST_SLOTS:
		var p: String = ss._dialogue_state_path(slot)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		if backups.get(slot, false):
			DirAccess.rename_absolute(p + ".test_bak", p)
		var sp: String = ss._save_path(slot)
		var mp: String = ss._meta_path(slot)
		for q in [sp, mp]:
			if FileAccess.file_exists(q):
				DirAccess.remove_absolute(q)
		var entry: Dictionary = backed_save_meta.get(slot, {})
		if entry.get(&"save", false): DirAccess.rename_absolute(sp + ".test_bak", sp)
		if entry.get(&"meta", false): DirAccess.rename_absolute(mp + ".test_bak", mp)
	ss.active_slot = prior_active

	_finish(failures)


func _finish(failures: Array) -> void:
	if failures.is_empty():
		print("PASS test_dialogue_state_persistence: 5 cases clean")
		get_tree().quit(0)
	else:
		for f in failures:
			printerr("FAIL test_dialogue_state_persistence: " + str(f))
		get_tree().quit(1)
