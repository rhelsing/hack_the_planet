extends Node

## Phase D test — StoryVec autoload behavior + persistence.
##
## Asserts:
##   1. Boot zero — every declared axis defaults to 0.
##   2. nudge() accumulates across multiple calls.
##   3. nudge() clamps to [bounds_min, bounds_max].
##   4. in_region() matches when vector falls inside the region's bounds.
##   5. in_region() rejects when outside, including the opposite quadrant.
##   6. region() returns the StringName of the first matching region.
##   7. vec_changed signal fires once per nudge.
##   8. Vector persists in DialogueState sidecar across bind_slot round-trip.
##
## Scene-mode (autoloads needed). Backs up sidecars for slot a so dev's
## save state survives.

var _signal_count: int = 0
var _signal_last: Array = []  # [axis, value]


func _ready() -> void:
	var failures: Array[String] = []

	var ss := get_node_or_null(^"/root/SaveService")
	var ds := get_node_or_null(^"/root/DialogueState")
	var sv := get_node_or_null(^"/root/StoryVec")
	if ss == null or ds == null or sv == null:
		_finish(["SaveService / DialogueState / StoryVec autoload missing"]); return

	# Back up sidecars + save/meta files for slot a.
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

	ss.begin_new_game(&"a")  # binds DialogueState, resets StoryVec via reset() chain

	# ---- 1. Boot zero ----
	if sv.value(&"ai_tech") != 0.0:
		failures.append("ai_tech should default to 0.0, got %f" % sv.value(&"ai_tech"))
	if sv.value(&"humanity") != 0.0:
		failures.append("humanity should default to 0.0, got %f" % sv.value(&"humanity"))

	# ---- 7. Hook signal counter ----
	sv.vec_changed.connect(_on_vec_changed)

	# ---- 2. Nudge accumulates ----
	sv.nudge(&"ai_tech", 1.0)
	sv.nudge(&"ai_tech", 2.0)
	sv.nudge(&"ai_tech", 1.0)
	if sv.value(&"ai_tech") != 4.0:
		failures.append("ai_tech should be 4.0 after three nudges, got %f" % sv.value(&"ai_tech"))

	# ---- 3. Clamp at bounds ----
	sv.nudge(&"ai_tech", 100.0)
	if sv.value(&"ai_tech") != 10.0:
		failures.append("ai_tech should clamp at 10.0, got %f" % sv.value(&"ai_tech"))
	sv.nudge(&"humanity", -100.0)
	if sv.value(&"humanity") != -10.0:
		failures.append("humanity should clamp at -10.0, got %f" % sv.value(&"humanity"))

	# ---- 4. in_region matches inside ----
	# Currently ai_tech=10, humanity=-10 → pro_ai_for_profit quadrant.
	if not sv.in_region(&"pro_ai_for_profit"):
		failures.append("Vector at (10, -10) should match pro_ai_for_profit")

	# ---- 5. in_region rejects outside ----
	if sv.in_region(&"pro_ai_pro_people"):
		failures.append("Vector at (10, -10) should NOT match pro_ai_pro_people")
	if sv.in_region(&"anti_ai_pro_people"):
		failures.append("Vector at (10, -10) should NOT match anti_ai_pro_people")
	if sv.in_region(&"neutral"):
		failures.append("Vector at (10, -10) should NOT match neutral")
	if sv.in_region(&"nonexistent_region"):
		failures.append("Unknown region name should return false")

	# ---- 6. region() returns the matching name ----
	if sv.region() != &"pro_ai_for_profit":
		failures.append("region() should return pro_ai_for_profit, got %s" % sv.region())

	# Move to neutral and re-check.
	sv.set_value(&"ai_tech", 0.0)
	sv.set_value(&"humanity", 0.0)
	if sv.region() != &"neutral":
		failures.append("region() at origin should be neutral, got %s" % sv.region())

	# ---- 7. vec_changed fired once per nudge/set_value ----
	# Three nudges + clamp nudge × 2 + set_value × 2 = 7 total.
	if _signal_count != 7:
		failures.append("vec_changed should have fired 7 times, got %d" % _signal_count)

	# ---- 8. Persistence across slot rebind ----
	sv.set_value(&"ai_tech", 5.0)
	sv.set_value(&"humanity", -3.0)
	ds.flush()  # bypass deferred coalescer
	ds.bind_slot(&"")  # unbind — clears in-memory + StoryVec
	if sv.value(&"ai_tech") != 0.0:
		failures.append("bind_slot('') should reset StoryVec ai_tech to 0, got %f" % sv.value(&"ai_tech"))
	ds.bind_slot(&"a")  # rebind — should reload sidecar including story_vec
	if sv.value(&"ai_tech") != 5.0:
		failures.append("bind_slot(a) should restore ai_tech to 5.0, got %f" % sv.value(&"ai_tech"))
	if sv.value(&"humanity") != -3.0:
		failures.append("bind_slot(a) should restore humanity to -3.0, got %f" % sv.value(&"humanity"))

	# Cleanup
	if sv.vec_changed.is_connected(_on_vec_changed):
		sv.vec_changed.disconnect(_on_vec_changed)
	ds.bind_slot(&"")
	for p in [ds_p, sp, mp]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	if had_ds: DirAccess.rename_absolute(ds_p + ".test_bak", ds_p)
	if had_sp: DirAccess.rename_absolute(sp + ".test_bak", sp)
	if had_mp: DirAccess.rename_absolute(mp + ".test_bak", mp)
	ss.active_slot = prior_active

	_finish(failures)


func _on_vec_changed(axis: StringName, v: float) -> void:
	_signal_count += 1
	_signal_last = [axis, v]


func _finish(failures: Array) -> void:
	if failures.is_empty():
		print("PASS test_story_vec: 8 cases clean")
		get_tree().quit(0)
	else:
		for f in failures:
			printerr("FAIL test_story_vec: " + str(f))
		get_tree().quit(1)
