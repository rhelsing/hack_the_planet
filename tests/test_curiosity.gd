extends Node

## Curiosity counters test — DialogueState.record_curiosity / curiosity_ratio.
##
## Asserts:
##   1. Fresh state: ratio 0.0, counters zero.
##   2. record_curiosity accumulates across calls; ratio = explored/offered.
##   3. offered <= 0 records nothing; explored clamps to [0, offered].
##   4. Counters persist through the sidecar (flush → unbind → rebind).
##   5. begin_new_game wipes them.
##
## Scene-mode test — needs autoloads. Run via:
##   godot --headless res://tests/test_curiosity.tscn
## Exits 0 on pass, 1 on fail.


func _ready() -> void:
	var failures: Array[String] = []

	var ss := get_node_or_null(^"/root/SaveService")
	var ds := get_node_or_null(^"/root/DialogueState")
	if ss == null or ds == null:
		_finish(["SaveService / DialogueState autoload missing"]); return

	# Back up slot a's files so the dev's saves survive the test run.
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

	# ---- 1. Fresh state ----
	if ds.curiosity_offered != 0 or ds.curiosity_explored != 0:
		failures.append("fresh state should have zero counters, got %d/%d" %
				[ds.curiosity_explored, ds.curiosity_offered])
	if ds.curiosity_ratio() != 0.0:
		failures.append("fresh ratio should be 0.0, got %f" % ds.curiosity_ratio())

	# ---- 2. Accumulation ----
	ds.record_curiosity(2, 4)   # conversation 1: 2 of 4
	ds.record_curiosity(3, 3)   # conversation 2: 3 of 3
	if ds.curiosity_explored != 5 or ds.curiosity_offered != 7:
		failures.append("after (2,4)+(3,3) expected 5/7, got %d/%d" %
				[ds.curiosity_explored, ds.curiosity_offered])
	if absf(ds.curiosity_ratio() - 5.0 / 7.0) > 0.0001:
		failures.append("ratio should be 5/7, got %f" % ds.curiosity_ratio())

	# ---- 3. Degenerate inputs ----
	ds.record_curiosity(1, 0)   # no menus — must record nothing
	ds.record_curiosity(-2, 0)
	if ds.curiosity_offered != 7:
		failures.append("offered<=0 should be a no-op, offered drifted to %d" % ds.curiosity_offered)
	ds.record_curiosity(9, 2)   # explored can't exceed offered
	if ds.curiosity_explored != 7 or ds.curiosity_offered != 9:
		failures.append("explored should clamp to offered: expected 7/9, got %d/%d" %
				[ds.curiosity_explored, ds.curiosity_offered])

	# ---- 4. Sidecar persistence ----
	ds.flush()
	ds.bind_slot(&"")
	if ds.curiosity_offered != 0:
		failures.append("unbind should zero counters, got offered=%d" % ds.curiosity_offered)
	ds.bind_slot(&"a")
	if ds.curiosity_explored != 7 or ds.curiosity_offered != 9:
		failures.append("rebind should reload 7/9 from sidecar, got %d/%d" %
				[ds.curiosity_explored, ds.curiosity_offered])

	# ---- 5. begin_new_game wipes ----
	ss.begin_new_game(&"a")
	if ds.curiosity_offered != 0 or ds.curiosity_explored != 0:
		failures.append("begin_new_game should wipe counters, got %d/%d" %
				[ds.curiosity_explored, ds.curiosity_offered])

	# ---- Cleanup ----
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
		print("PASS test_curiosity: 5 cases clean")
		get_tree().quit(0)
	else:
		for f in failures:
			printerr("FAIL test_curiosity: " + str(f))
		get_tree().quit(1)
