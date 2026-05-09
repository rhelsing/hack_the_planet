extends Node

## Phase B test — DialogueState.seen tracking.
##
## Asserts:
##   1. has_seen returns false for unseen text.
##   2. mark_seen flips it to true; idempotent on second call.
##   3. seen scoped per character — same text under different speakers stays
##      independently tracked.
##   4. seen persists in the sidecar across bind_slot round-trip.
##   5. reset() clears seen alongside visited.
##   6. Per-slot isolation: slot a's seen doesn't leak into slot b.
##
## Scene-mode (autoloads needed). Backs up + restores any existing sidecars
## for slots a and b so dev's saves are untouched.

const TEST_SLOTS: Array[StringName] = [&"a", &"b"]


func _ready() -> void:
	var failures: Array[String] = []

	var ss := get_node_or_null(^"/root/SaveService")
	var ds := get_node_or_null(^"/root/DialogueState")
	if ss == null or ds == null:
		_finish(["SaveService or DialogueState autoload missing"]); return

	# Back up sidecars + save/meta files for slots a and b.
	var prior_active: StringName = ss.active_slot
	var backups: Dictionary = {}
	for slot in TEST_SLOTS:
		var ds_p: String = ss._dialogue_state_path(slot)
		var sp: String = ss._save_path(slot)
		var mp: String = ss._meta_path(slot)
		backups[slot] = {
			&"ds": FileAccess.file_exists(ds_p),
			&"save": FileAccess.file_exists(sp),
			&"meta": FileAccess.file_exists(mp),
		}
		if backups[slot][&"ds"]: DirAccess.rename_absolute(ds_p, ds_p + ".test_bak")
		if backups[slot][&"save"]: DirAccess.rename_absolute(sp, sp + ".test_bak")
		if backups[slot][&"meta"]: DirAccess.rename_absolute(mp, mp + ".test_bak")

	# ---- 1 & 2. has_seen / mark_seen basics ----
	ss.begin_new_game(&"a")
	if ds.has_seen("Glitch", "Refresh the controls."):
		failures.append("has_seen should be false for unseen text on a fresh slot")
	ds.mark_seen("Glitch", "Refresh the controls.")
	if not ds.has_seen("Glitch", "Refresh the controls."):
		failures.append("mark_seen should flip has_seen to true")
	# Idempotent — second call shouldn't change anything observable.
	ds.mark_seen("Glitch", "Refresh the controls.")
	if not ds.has_seen("Glitch", "Refresh the controls."):
		failures.append("mark_seen second call should leave seen=true")

	# ---- 3. Per-character scoping ----
	ds.mark_seen("DialTone", "Refresh the controls.")
	if not ds.has_seen("DialTone", "Refresh the controls."):
		failures.append("Same text under different speaker should track independently")
	# Glitch's flag should still be true; DialTone's shouldn't bleed back.
	if not ds.has_seen("Glitch", "Refresh the controls."):
		failures.append("DialTone's mark_seen should NOT clobber Glitch's")

	# ---- 4. Persists across bind_slot round-trip ----
	ds.flush()  # bypass the deferred coalescer
	ds.bind_slot(&"")  # unbind — clears in-memory
	if ds.has_seen("Glitch", "Refresh the controls."):
		failures.append("bind_slot('') should clear in-memory seen")
	ds.bind_slot(&"a")  # rebind — should reload sidecar
	if not ds.has_seen("Glitch", "Refresh the controls."):
		failures.append("bind_slot(a) should reload seen from sidecar")
	if not ds.has_seen("DialTone", "Refresh the controls."):
		failures.append("DialTone's seen should also persist")

	# ---- 5. reset() wipes seen + visited together ----
	ds.visit_dialogue("Glitch", "Topic")
	ds.reset()
	if ds.has_seen("Glitch", "Refresh the controls."):
		failures.append("reset() should clear seen")
	if ds.has_visited_dialogue("Glitch", "Topic"):
		failures.append("reset() should clear visited (regression check on Phase A)")

	# ---- 6. Per-slot isolation for seen ----
	ds.mark_seen("Glitch", "ProbeA")
	ds.flush()
	ss.begin_new_game(&"b")  # binds + wipes b
	ds.mark_seen("Glitch", "ProbeB")
	ds.flush()
	if ds.has_seen("Glitch", "ProbeA"):
		failures.append("slot b should not see slot a's ProbeA seen")
	ds.bind_slot(&"a")
	if not ds.has_seen("Glitch", "ProbeA"):
		failures.append("rebinding to a should restore ProbeA seen")
	if ds.has_seen("Glitch", "ProbeB"):
		failures.append("slot a should not see slot b's ProbeB seen")

	# ---- Cleanup ----
	ds.bind_slot(&"")
	for slot in TEST_SLOTS:
		var ds_p: String = ss._dialogue_state_path(slot)
		var sp: String = ss._save_path(slot)
		var mp: String = ss._meta_path(slot)
		for p in [ds_p, sp, mp]:
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(p)
		var b: Dictionary = backups.get(slot, {})
		if b.get(&"ds", false): DirAccess.rename_absolute(ds_p + ".test_bak", ds_p)
		if b.get(&"save", false): DirAccess.rename_absolute(sp + ".test_bak", sp)
		if b.get(&"meta", false): DirAccess.rename_absolute(mp + ".test_bak", mp)
	ss.active_slot = prior_active

	_finish(failures)


func _finish(failures: Array) -> void:
	if failures.is_empty():
		print("PASS test_dialogue_seen: 6 cases clean")
		get_tree().quit(0)
	else:
		for f in failures:
			printerr("FAIL test_dialogue_seen: " + str(f))
		get_tree().quit(1)
