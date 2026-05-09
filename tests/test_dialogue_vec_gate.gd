extends Node

## Phase D test — `[if StoryVec.in_region(...) /]` integration in dialogue.
##
## Builds a fixture DialogueResource with a vector-gated response option,
## flips the vector in/out of the region, and asserts the option's
## is_allowed flag follows.
##
## DM exposes autoloads to its expression parser, so writing
## `[if StoryVec.in_region("region_name") /]` in a .dialogue file Just
## Works — String auto-coerces to StringName at the call boundary.
##
## Asserts:
##   1. Vector inside the region → conditional option is_allowed=true.
##   2. Vector outside the region → is_allowed=false.

const FIXTURE: String = """~ start

- Always shown
- [if StoryVec.in_region("pro_ai_pro_people") /] Vector-gated option
=> start
"""


func _ready() -> void:
	var failures: Array[String] = []

	var ss := get_node_or_null(^"/root/SaveService")
	var ds := get_node_or_null(^"/root/DialogueState")
	var sv := get_node_or_null(^"/root/StoryVec")
	var dm := get_node_or_null(^"/root/DialogueManager")
	if ss == null or ds == null or sv == null or dm == null:
		_finish(["SaveService / DialogueState / StoryVec / DialogueManager autoload missing"]); return

	# Back up sidecar files for slot a.
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

	var resource: DialogueResource = dm.create_resource_from_text(FIXTURE)
	if resource == null:
		_finish(["create_resource_from_text returned null"]); return

	# ---- 1. Vector inside region → option allowed ----
	sv.set_value(&"ai_tech", 5.0)
	sv.set_value(&"humanity", 5.0)
	if not sv.in_region(&"pro_ai_pro_people"):
		_finish(["test setup error: (5,5) should be in pro_ai_pro_people"]); return

	var line_in: DialogueLine = await dm.get_next_dialogue_line(resource, "start", [self])
	var gated_in: DialogueResponse = null
	for r in line_in.responses:
		if r.text == "Vector-gated option":
			gated_in = r
			break
	if gated_in == null:
		failures.append("Vector-gated option not in responses list")
	elif not gated_in.is_allowed:
		failures.append("In-region: gated option should be is_allowed=true (got false)")

	# ---- 2. Vector outside region → option NOT allowed ----
	sv.set_value(&"ai_tech", -5.0)
	sv.set_value(&"humanity", -5.0)
	if sv.in_region(&"pro_ai_pro_people"):
		_finish(["test setup error: (-5,-5) should NOT be in pro_ai_pro_people"]); return

	var line_out: DialogueLine = await dm.get_next_dialogue_line(resource, "start", [self])
	var gated_out: DialogueResponse = null
	for r in line_out.responses:
		if r.text == "Vector-gated option":
			gated_out = r
			break
	if gated_out == null:
		failures.append("Vector-gated option not in responses list (out)")
	elif gated_out.is_allowed:
		failures.append("Out-of-region: gated option should be is_allowed=false (got true)")

	# Cleanup
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
		print("PASS test_dialogue_vec_gate: 2 cases clean")
		get_tree().quit(0)
	else:
		for f in failures:
			printerr("FAIL test_dialogue_vec_gate: " + str(f))
		get_tree().quit(1)
