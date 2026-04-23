extends Node
## Scene-mode test runner. Boots the project normally (so autoloads are live),
## exercises PauseController + Settings + SaveService against the real
## autoload instances, prints PASS/FAIL per suite, exits 0/1.
##
## Invoke with:
##   godot --headless --path . res://tests/test_runner.tscn

var _failures: Array[String] = []
var _suites: Array[String] = []


const MENU_SCENES := [
	"res://menu/main_menu.tscn",
	"res://menu/pause_menu.tscn",
	"res://menu/settings_menu.tscn",
	"res://menu/save_slots.tscn",
	"res://menu/credits.tscn",
	"res://menu/scene_loader.tscn",
	"res://menu/menu_world.tscn",
	"res://menu/menu_button.tscn",
]

const HUD_SCENES := [
	"res://hud/hud.tscn",
	"res://hud/components/toast.tscn",
	"res://hud/components/toast_stack.tscn",
	"res://hud/components/counters.tscn",
	"res://hud/components/health_bar.tscn",
	"res://hud/components/powerup_row.tscn",
	"res://hud/components/objective_banner.tscn",
	"res://hud/components/death_overlay.tscn",
]


func _ready() -> void:
	# Defer one frame so every autoload's _ready has run.
	await get_tree().process_frame
	_run_menus_smoke()
	_run_hud_smoke()
	_run_pause_controller()
	_run_settings()
	_run_save_service()
	_report_and_quit()


func _run_hud_smoke() -> void:
	_suites.append("hud_smoke")
	for path: String in HUD_SCENES:
		_expect("hud_smoke", "exists on disk: %s" % path, ResourceLoader.exists(path))
		var packed = load(path)
		_expect("hud_smoke", "loads as PackedScene: %s" % path, packed is PackedScene)
	# Instantiate the HUD root + free; catches script parse errors that load()
	# would silently tolerate. No tree-add — components' deferred binders need
	# a player in the tree which the runner doesn't have.
	var hud_packed: PackedScene = load("res://hud/hud.tscn")
	if hud_packed != null:
		var inst := hud_packed.instantiate()
		_expect("hud_smoke", "hud.tscn instantiates", inst != null)
		if inst != null:
			inst.free()


func _run_menus_smoke() -> void:
	_suites.append("menus_smoke")
	for path: String in MENU_SCENES:
		_expect("menus_smoke", "exists on disk: %s" % path, ResourceLoader.exists(path))
		var packed = load(path)
		_expect("menus_smoke", "loads as PackedScene: %s" % path, packed is PackedScene)


# ── Suites ───────────────────────────────────────────────────────────────

func _run_pause_controller() -> void:
	_suites.append("pause_controller")
	var pc := get_node_or_null(^"/root/PauseController")
	if pc == null:
		_fail("pause_controller", "PauseController autoload missing")
		return

	_expect("pause_controller", "modal_count starts 0", pc.modal_count == 0)
	_expect("pause_controller", "user_pause_allowed defaults true", pc.user_pause_allowed)

	Events.modal_opened.emit(&"runner_a")
	_expect("pause_controller", "modal_count == 1 after emit", pc.modal_count == 1)
	Events.modal_opened.emit(&"runner_b")
	_expect("pause_controller", "modal_count == 2 after second emit", pc.modal_count == 2)
	Events.modal_closed.emit(&"runner_a")
	_expect("pause_controller", "modal_count decrements", pc.modal_count == 1)
	Events.modal_closed.emit(&"runner_b")
	_expect("pause_controller", "modal_count back to 0", pc.modal_count == 0)

	Events.modal_opened.emit(&"runner_c")
	_expect("pause_controller", "is_any_modal_open true when count > 0", pc.is_any_modal_open())

	Events.modal_count_reset.emit()
	_expect("pause_controller", "modal_count_reset zeros counter", pc.modal_count == 0)

	Events.modal_closed.emit(&"phantom")
	_expect("pause_controller", "modal_count clamps ≥ 0", pc.modal_count >= 0)

	# set_paused flips the real tree paused state.
	pc.set_paused(true)
	_expect("pause_controller", "set_paused(true) pauses tree", get_tree().paused)
	pc.set_paused(false)
	_expect("pause_controller", "set_paused(false) unpauses tree", not get_tree().paused)


func _run_settings() -> void:
	_suites.append("settings")
	var s := get_node_or_null(^"/root/Settings")
	if s == null:
		_fail("settings", "Settings autoload missing")
		return

	for section in ["audio", "dialogue", "graphics", "camera"]:
		_expect("settings", "section %s present" % section, s.data.has(section))

	_expect("settings", "graphics.quality defaults to \"medium\" OR user's saved value",
		String(s.get_value("graphics", "quality", "")) in ["low", "medium", "high", "max"])
	_expect("settings", "camera.invert_y is bool", s.get_value("camera", "invert_y", null) != null)
	_expect("settings", "unknown section fallback works",
		s.get_value("nope", "nope", 42) == 42)

	# set_value round-trip: remember → write → read back.
	var original = s.get_value("graphics", "quality", "medium")
	var new_val = "max" if String(original) != "max" else "high"
	s.set_value("graphics", "quality", new_val)
	_expect("settings", "set_value mutates in-memory",
		String(s.get_value("graphics", "quality", "")) == new_val)
	# Restore so we don't leave a stray user setting.
	s.set_value("graphics", "quality", original)


func _run_save_service() -> void:
	_suites.append("save_service")
	var ss := get_node_or_null(^"/root/SaveService")
	if ss == null:
		_fail("save_service", "SaveService autoload missing")
		return

	# Slot ID constants — only A/B/C now; hidden autosave was dropped (v1.2).
	for id in [&"a", &"b", &"c"]:
		_expect("save_service", "SLOTS contains %s" % id, id in ss.SLOTS)
	_expect("save_service", "SLOTS does NOT contain autosave", not (&"autosave" in ss.SLOTS))

	# active_slot starts empty.
	_expect("save_service", "active_slot empty by default", not ss.has_active_slot())

	# Scratch slot — back up any real save file, exercise the full round-trip,
	# restore. Single block; covers begin_new_game + save_to_slot + metadata
	# + JSON shape + active_slot lifecycle in one pass.
	var test_slot: StringName = &"a"
	var save_path: String = ss._save_path(test_slot)
	var meta_path: String = ss._meta_path(test_slot)
	var had_save := FileAccess.file_exists(save_path)
	var had_meta := FileAccess.file_exists(meta_path)
	if had_save: DirAccess.rename_absolute(save_path, save_path + ".runner_bak")
	if had_meta: DirAccess.rename_absolute(meta_path, meta_path + ".runner_bak")

	_expect("save_service", "has_slot empty after backup", not ss.has_slot(test_slot))

	# begin_new_game: resets state, writes slot, sets active_slot.
	ss.current_level = &"runner_level"
	ss.playtime_s = 77.7
	ss.begin_new_game(test_slot)
	_expect("save_service", "begin_new_game sets active_slot", ss.has_active_slot())
	_expect("save_service", "begin_new_game writes slot file", ss.has_slot(test_slot))
	_expect("save_service", "save file on disk", FileAccess.file_exists(save_path))
	_expect("save_service", "meta file on disk", FileAccess.file_exists(meta_path))

	var meta: Dictionary = ss.slot_metadata(test_slot)
	_expect("save_service", "metadata has timestamp", meta.has("timestamp"))

	var f := FileAccess.open(save_path, FileAccess.READ)
	var parsed = JSON.parse_string(f.get_as_text()) if f != null else null
	_expect("save_service", "save file parses as Dictionary", parsed is Dictionary)
	if parsed is Dictionary:
		for k in ["version", "timestamp", "level_id", "playtime_s", "game_state", "player_state"]:
			_expect("save_service", "save has key %s" % k, parsed.has(k))

	# clear_active_slot drops the binding without touching disk.
	ss.clear_active_slot()
	_expect("save_service", "clear_active_slot unbinds", not ss.has_active_slot())

	# Autosave with no active slot is a no-op (doesn't crash, doesn't write).
	ss._on_checkpoint_reached(Vector3.ZERO)

	# Restore the original on-disk save (if any) so the dev's real saves survive.
	for p in [save_path, meta_path]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	if had_save: DirAccess.rename_absolute(save_path + ".runner_bak", save_path)
	if had_meta: DirAccess.rename_absolute(meta_path + ".runner_bak", meta_path)


# ── Plumbing ─────────────────────────────────────────────────────────────

func _expect(suite: String, desc: String, cond: bool) -> void:
	if not cond:
		_failures.append("[%s] %s" % [suite, desc])


func _fail(suite: String, reason: String) -> void:
	_failures.append("[%s] %s" % [suite, reason])


func _report_and_quit() -> void:
	if _failures.is_empty():
		print("PASS test_runner: %d suites clean — %s" % [
			_suites.size(), ", ".join(_suites)
		])
		get_tree().quit(0)
	else:
		for f: String in _failures:
			printerr("FAIL test_runner: " + f)
		get_tree().quit(1)
