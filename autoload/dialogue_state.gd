extends Node

## Sidecar persistence for dialogue meta-state — separate from save slots.
##
## Owns visited (Phase A), and later seen (Phase B) + story_vec (Phase D).
## Survives load_from_slot BY DESIGN: only wiped on begin_new_game. Fixes the
## long-standing "reload from checkpoint loses dialogue history" bug
## (manifest: pick "About those Sentinels...", die at kill plane, reload —
## option un-dimmed because GameState.from_dict overwrote dialogue_visited
## with the pre-conversation save snapshot).
##
## Phase A.1 — SKELETON ONLY. Sidecar file I/O ships in A.2; scroll_balloon
## migration in A.3; SaveService lifecycle hooks in A.4. Until those phases
## land, this module is standalone — registered in project.godot but not
## referenced by any other code. That keeps Phase A.1 zero-regression.
##
## Visit key shape matches the existing GameState convention so callers can
## migrate transparently in A.3:  `text + "→" + next_id`.

const SCHEMA_VERSION: int = 1

## { character: { key: true } }. Same shape GameState.dialogue_visited uses.
var visited: Dictionary = {}

## { character: { text: true } }. Every response option that has ever been
## rendered for this character. Drives the "new-unlock" highlight in
## scroll_balloon — an option visible NOW but not in `seen` is "new" this
## render (gets green outline + reorder to top), then gets marked seen.
##
## Keyed by raw response text (NOT the visit-zip key). Two distinct probes
## sharing text but routing to different places are still "the same probe"
## from the player's POV — same text on screen.
var seen: Dictionary = {}

## Cumulative curiosity counters — across every conversation, how many
## distinct non-exit response options the player actually picked (explored)
## out of everything that was offered on screen. scroll_balloon commits one
## (explored, offered) pair per conversation at balloon close. The percent-
## curious at any moment is curiosity_ratio().
var curiosity_explored: int = 0
var curiosity_offered: int = 0

## Active save slot — empty when no slot bound (e.g. main menu, before
## begin_new_game / load_from_slot). Sidecar I/O is gated on this; if no
## slot is bound, visit() still mutates in-memory state but never writes.
## That keeps tests and main-menu interactions side-effect-free.
var _active_slot: StringName = &""

## True when in-memory state has changed since the last flush. The deferred
## flush coalesces bursts (e.g. several visit() calls in one frame from a
## single click producing both a parent + child key) into one file write.
var _dirty: bool = false


# ---- Low-level API (key precomputed by caller) -------------------------

func visit(character: String, key: String) -> void:
	if character.is_empty(): return
	if not visited.has(character):
		visited[character] = {}
	visited[character][key] = true
	_mark_dirty()


func has_visited(character: String, key: String) -> bool:
	return visited.get(character, {}).has(key)


# ---- Seen tracking (Phase B) ------------------------------------------

## Mark a response option as having appeared in a menu render for this
## character. Idempotent. Triggers a deferred sidecar flush.
func mark_seen(character: String, text: String) -> void:
	if character.is_empty(): return
	if not seen.has(character):
		seen[character] = {}
	if seen[character].has(text):
		return  # already seen — no dirty bump, no flush
	seen[character][text] = true
	_mark_dirty()


func has_seen(character: String, text: String) -> bool:
	return seen.get(character, {}).has(text)


# ---- Curiosity accumulation ---------------------------------------------

## Add one conversation's exploration numbers to the running totals.
## Called by scroll_balloon when a conversation ends. offered <= 0 means
## the conversation had no menus — not a curiosity sample, records nothing.
func record_curiosity(explored: int, offered: int) -> void:
	if offered <= 0: return
	curiosity_explored += clampi(explored, 0, offered)
	curiosity_offered += offered
	_mark_dirty()


## Fraction [0, 1] of offered dialogue paths the player has explored across
## all conversations so far. 0.0 before any menu has ever been offered.
func curiosity_ratio() -> float:
	if curiosity_offered <= 0: return 0.0
	return float(curiosity_explored) / float(curiosity_offered)


# ---- High-level API (matches GameState.visit_dialogue shape) -----------

## Convenience that mirrors GameState.visit_dialogue's signature so the
## A.3 migration is a one-line swap. `next_id` defaults to "" — current
## callers all pass empty (the key is `text + "→"`), but the parameter is
## kept so a future per-destination key can land without a signature change.
func visit_dialogue(character: String, text: String, next_id: String = "") -> void:
	visit(character, _zip(text, next_id))


func has_visited_dialogue(character: String, text: String, next_id: String = "") -> bool:
	return has_visited(character, _zip(text, next_id))


func _zip(text: String, next_id: String) -> String:
	return "%s→%s" % [text, next_id]


# ---- Persistence (no I/O yet — that's A.2) -----------------------------

func to_dict() -> Dictionary:
	# Phase D — vector state piggybacks on this sidecar. Pulled live from
	# StoryVec at flush time so we don't have to mirror it field-by-field.
	var story_vec_dict: Dictionary = {}
	var sv := get_node_or_null(^"/root/StoryVec")
	if sv != null and sv.has_method(&"to_dict"):
		story_vec_dict = sv.call(&"to_dict")
	return {
		"version": SCHEMA_VERSION,
		"visited": visited.duplicate(true),
		"seen": seen.duplicate(true),
		"story_vec": story_vec_dict,
		"curiosity_explored": curiosity_explored,
		"curiosity_offered": curiosity_offered,
	}


## Tolerant load — missing fields default to empty so legacy sidecars (or
## future schema additions read by old code) don't blow up.
func from_dict(d: Dictionary) -> void:
	visited = d.get("visited", {}).duplicate(true)
	seen = d.get("seen", {}).duplicate(true)
	curiosity_explored = int(d.get("curiosity_explored", 0))
	curiosity_offered = int(d.get("curiosity_offered", 0))
	# Push vector state into StoryVec so its in-memory dict matches the
	# sidecar. Tolerant of missing field — first-run / pre-D saves won't
	# have story_vec at all; StoryVec.from_dict({}) re-zeroes axes.
	var sv := get_node_or_null(^"/root/StoryVec")
	if sv != null and sv.has_method(&"from_dict"):
		sv.call(&"from_dict", d.get("story_vec", {}))


## Full wipe — used by SaveService.begin_new_game (A.4) and tests.
## Synchronous flush (not deferred): caller's intent is to clear the file.
func reset() -> void:
	visited.clear()
	seen.clear()
	curiosity_explored = 0
	curiosity_offered = 0
	# Phase D — vector state lives in StoryVec autoload; reset it too.
	var sv := get_node_or_null(^"/root/StoryVec")
	if sv != null and sv.has_method(&"reset"):
		sv.call(&"reset")
	if not _active_slot.is_empty():
		_flush_to_disk()


func _ready() -> void:
	# Hook StoryVec.vec_changed so nudges trigger a deferred sidecar flush.
	# Deferred via call_deferred so autoload init order doesn't matter — by
	# the next idle frame, every autoload is ready.
	call_deferred(&"_connect_story_vec")


func _connect_story_vec() -> void:
	var sv := get_node_or_null(^"/root/StoryVec")
	if sv == null: return
	if not sv.has_signal(&"vec_changed"): return
	if sv.vec_changed.is_connected(_on_vec_changed): return
	sv.vec_changed.connect(_on_vec_changed)


func _on_vec_changed(_axis: StringName, _v: float) -> void:
	_mark_dirty()


# ---- Slot binding + sidecar I/O ----------------------------------------

## Point at a save slot's sidecar file and load it into memory. Replaces
## any in-memory state. Empty slot un-binds (no I/O until re-bound).
##
## Called from SaveService.begin_new_game (after reset) and load_from_slot,
## once those hooks land in A.4. Until then this function is dormant.
func bind_slot(slot: StringName) -> void:
	if slot.is_empty():
		_active_slot = &""
		visited.clear()
		seen.clear()
		curiosity_explored = 0
		curiosity_offered = 0
		var sv := get_node_or_null(^"/root/StoryVec")
		if sv != null and sv.has_method(&"reset"):
			sv.call(&"reset")
		return
	_active_slot = slot
	# Drop the previous slot's state before loading the new one. Counters
	# too — a slot with no sidecar file yet must not inherit the old slot's.
	visited.clear()
	seen.clear()
	curiosity_explored = 0
	curiosity_offered = 0
	_load_from_disk()


## True iff a slot is currently bound (sidecar reads/writes will fire).
func has_active_slot() -> bool:
	return not _active_slot.is_empty()


## Force-flush in-memory state to disk now. Tests use this to bypass the
## deferred coalescer; production code shouldn't need it.
func flush() -> void:
	_flush_to_disk()


func _save_path(slot: StringName) -> String:
	return "user://dialogue_state_%s.json" % slot


func _load_from_disk() -> void:
	if _active_slot.is_empty(): return
	var path := _save_path(_active_slot)
	if not FileAccess.file_exists(path):
		# No file for this slot yet — fresh-game default. Don't error.
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("DialogueState: failed to open %s for read" % path)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		from_dict(parsed)
	else:
		push_error("DialogueState: corrupt sidecar %s — ignoring" % path)


func _flush_to_disk() -> void:
	_dirty = false
	if _active_slot.is_empty(): return  # No slot bound — silent no-op.
	var path := _save_path(_active_slot)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("DialogueState: failed to open %s for write" % path)
		return
	f.store_string(JSON.stringify(to_dict()))
	# Ratchet the main save forward in lockstep with the sidecar. Without
	# this, GameState.flags set by `do GameState.set_flag(...)` mutations
	# inside dialogue live in memory only until the next checkpoint —
	# causing drift between the sidecar (immediate) and save_slot (lazy).
	# Symptom of the drift: re-enter a hub after quit-without-checkpoint,
	# see an option dimmed (sidecar says visited) but its [if /]-gated
	# follow-up missing (GameState.flags reverted to last-checkpoint).
	#
	# Guards:
	#   - SaveService autoload exists.
	#   - SaveService.active_slot is set AND matches our slot. During
	#     begin_new_game's setup the slot isn't bound on SaveService yet,
	#     so we don't fire prematurely; the explicit save_to_slot at the
	#     end of begin_new_game handles that path.
	var ss := get_node_or_null(^"/root/SaveService")
	if ss != null and ss.has_method(&"has_active_slot") and ss.has_method(&"save_to_slot"):
		if bool(ss.call(&"has_active_slot")) and ss.active_slot == _active_slot:
			ss.call(&"save_to_slot", _active_slot)


## Marks state dirty and schedules a deferred flush. Coalesces multiple
## visits in the same frame into one file write.
func _mark_dirty() -> void:
	if _dirty: return
	if _active_slot.is_empty(): return  # No-op until a slot is bound.
	_dirty = true
	call_deferred(&"_flush_to_disk")
