extends Node

## Gameplay root. Hosts the Player + HUD + a swappable Level child.
##
## LevelProgression + hub pedestals call `load_level(path)` to swap which
## level scene is mounted under the "Level" slot. This keeps Player state
## (health, abilities, powerup flags) + HUD continuous across level changes.
## The full-scene SceneLoader.goto is reserved for main-menu → game boundary.

const TransitionScript := preload("res://menu/transitions/transition.gd")
const LOADER_UI_SCENE := "res://menu/scene_loader.tscn"

## Fallback level loaded at _ready if SaveService has no current_level set
## (e.g. a fresh New Game before LevelProgression points at the hub).
@export var default_level_scene: PackedScene

# The level currently mounted as our "Level" child. Updated whenever we
# swap. Null before _ready finishes.
var _current_level: Node3D = null
# Busy guard: a second load_level() call while one is in progress is dropped
# (with a push_warning) instead of stacking transitions and racing _mount_level.
var _is_loading: bool = false


func _ready() -> void:
	# If game.tscn ships with a pre-baked Level child, treat it as the
	# initial level so the previous flow (boot straight into level.tscn)
	# still works.
	var pre_baked := get_node_or_null(^"Level") as Node3D
	if pre_baked != null:
		_current_level = pre_baked
	# Honor a saved current_level if it resolves to a real scene; else
	# fall back to whatever's wired in.
	var saved_scene := _resolve_initial_level()
	print("[game] _ready: SaveService.current_level=%s resolved_scene=%s" % [
		SaveService.current_level, saved_scene])
	if saved_scene != null:
		_mount_level(saved_scene)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_fullscreen"):
		get_viewport().mode = (
			Window.MODE_FULLSCREEN if
			get_viewport().mode != Window.MODE_FULLSCREEN else
			Window.MODE_WINDOWED
		)


## Public API — LevelProgression + hub pedestals call this to swap levels.
## Path is absolute res:// path to the level scene (e.g. "res://level/hub.tscn").
##
## The user-selected Transition (glitch / instant) wraps the swap so scene
## changes get a visual bookend rather than a hard cut. The actual mount
## happens during the opaque play_out window — the player snaps to the new
## spawn invisibly under cover of the fade. await this from callers (e.g.
## LevelProgression) that need to know when the mount is complete (so the
## save file records the player at the new spawn, not the old position).
func load_level(path: String) -> void:
	if _is_loading:
		push_warning("Game.load_level: already loading, ignoring %s" % path)
		return
	_is_loading = true
	var style := "glitch"
	var settings := get_tree().root.get_node_or_null(^"Settings")
	if settings != null and settings.has_method(&"get_value"):
		style = String(settings.call(&"get_value", "graphics", "transition_style", "glitch"))
	var transition: Transition = TransitionScript.from_style(style)
	# Suppress the interaction prompt for the duration of the swap. Without
	# this, a stale "[E] enter" lingers on screen through the fade because
	# the sensor's focused interactable (e.g., the pedestal you just pressed)
	# is still alive until _mount_level frees the old level — and the prompt
	# UI gates on modal_count, not focus liveness. PromptUI hides while
	# modal_count > 0; we restore it after the new scene is mounted and
	# scene_entered has had a tick to update sensor focus.
	Events.modal_opened.emit(&"level_transition")
	await transition.play_out(get_tree())
	# Threaded load + the same loader UI the main menu uses. Previously this
	# was a synchronous load() that hitched the main thread on big levels;
	# now the player sees the loading bar (covers the hitch + matches the
	# menu→game transition aesthetic). See docs/remediation_roadmap.md G4.
	var packed: PackedScene = await _threaded_load_with_ui(path)
	if packed == null:
		push_error("Game.load_level: cannot load %s" % path)
		Events.modal_closed.emit(&"level_transition")
		_is_loading = false
		return
	_mount_level(packed)
	SaveService.set_current_level(StringName(path.get_file().trim_suffix(".tscn")))
	await transition.play_in(get_tree())
	Events.modal_closed.emit(&"level_transition")
	_is_loading = false


## Run a threaded ResourceLoader request with the same loader UI the main
## menu transitions use. Returns the loaded PackedScene or null on failure.
## Awaits internally — caller blocks until the load completes.
func _threaded_load_with_ui(path: String) -> PackedScene:
	var ui: Node = null
	if ResourceLoader.exists(LOADER_UI_SCENE):
		var ui_packed: PackedScene = load(LOADER_UI_SCENE)
		if ui_packed != null:
			ui = ui_packed.instantiate()
			ui.process_mode = Node.PROCESS_MODE_ALWAYS
			get_tree().root.add_child(ui)
	ResourceLoader.load_threaded_request(path)
	var progress: Array[float] = [0.0]
	var packed: PackedScene = null
	while true:
		await get_tree().process_frame
		var status := ResourceLoader.load_threaded_get_status(path, progress)
		if ui != null and ui.has_method(&"set_progress"):
			ui.call(&"set_progress", progress[0] if progress.size() > 0 else 0.0)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			packed = ResourceLoader.load_threaded_get(path) as PackedScene
			break
		elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			break
	if ui != null and is_instance_valid(ui):
		ui.queue_free()
	return packed


# ── Internals ────────────────────────────────────────────────────────────

func _resolve_initial_level() -> PackedScene:
	var cur: StringName = SaveService.current_level
	# Treat empty OR the shell's own id ("game") as unset — we never mount
	# game.tscn inside itself. Saves written before the level-host refactor
	# may still carry "game"; treat them as "start fresh at default".
	if cur == &"" or cur == &"game":
		return default_level_scene
	# Try standard locations for the level scene.
	var candidates: Array[String] = [
		"res://level/%s.tscn" % cur,
		"res://%s.tscn" % cur,
	]
	for p in candidates:
		if ResourceLoader.exists(p):
			return load(p) as PackedScene
	return default_level_scene


func _mount_level(packed: PackedScene) -> void:
	# Free the old level before adding the new one so both don't render.
	if _current_level != null and is_instance_valid(_current_level):
		# Remove synchronously so the group/signal de-registration runs now;
		# queue_free would leave the old level alive for the rest of this
		# frame which can double-fire kill_plane / flag signals.
		var old := _current_level
		# Rescue any pawn that's been reparented onto a level node (elevator
		# CarryZone reparent-trick, glitch_lift, etc.). Without this they're
		# descendants of `old` and would be queue_free'd along with it —
		# camera goes with the player and the new level mounts to a grey
		# void with no Player. See sync_up: 2026-04-26 regression.
		_rescue_pawns_from(old)
		remove_child(old)
		old.queue_free()
	var new_level := packed.instantiate() as Node3D
	if new_level == null:
		push_error("Game._mount_level: scene root must be Node3D")
		return
	new_level.name = "Level"
	add_child(new_level)
	_current_level = new_level
	_spawn_player(new_level)


## Walk the doomed level and reparent any "player"-group node back onto
## game.tscn root so freeing the level doesn't free the player along with
## it. Triggered by elevator/lift scripts that reparent pawns for the
## physics carry-trick — if the player is mid-ride when a transition
## fires, they're descendants of the level until they exit the carry zone.
func _rescue_pawns_from(level: Node) -> void:
	for n in get_tree().get_nodes_in_group("player"):
		if n is Node3D and level.is_ancestor_of(n):
			print("[game] rescue: reparenting %s out of doomed level %s" % [n.name, level.name])
			n.reparent(self, true)


func _spawn_player(level: Node) -> void:
	var player := get_node_or_null(^"Player") as Node3D
	if player == null:
		return
	var marker := level.get_node_or_null(^"PlayerSpawn") as Marker3D
	if marker == null:
		return
	# If a save's player_state is pending, the SaveService is about to apply
	# it on scene_entered (which fires AFTER our _ready). We still call
	# snap_to_spawn for camera yaw/skin facing, but skip overwriting position
	# + respawn_point — load_save_dict will set both from the save.
	var ss := get_tree().root.get_node_or_null(^"SaveService")
	var has_pending: bool = ss != null and ss.get("_pending_player_state") != null \
		and not (ss.get("_pending_player_state") as Dictionary).is_empty()
	if has_pending:
		print("[game] _spawn_player: save pending — skipping marker overwrite")
		if player.has_method(&"snap_to_spawn"):
			player.call(&"snap_to_spawn", marker.global_transform)
		return
	# Position from the marker; basis is consumed by snap_to_spawn (see
	# player_body.gd) which seeds skin facing + camera yaw without baking
	# rotation into body.global_transform.
	player.global_position = marker.global_position
	if player.has_method(&"set_respawn_point"):
		player.call(&"set_respawn_point", marker.global_position)
	if player.has_method(&"snap_to_spawn"):
		player.call(&"snap_to_spawn", marker.global_transform)
