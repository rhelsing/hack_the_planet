extends Node

## Gameplay root. Hosts the Player + HUD + a swappable Level child.
##
## LevelProgression + hub pedestals call `load_level(path)` to swap which
## level scene is mounted under the "Level" slot. This keeps Player state
## (health, abilities, powerup flags) + HUD continuous across level changes.
## The full-scene SceneLoader.goto is reserved for main-menu → game boundary.

## Fallback level loaded at _ready if SaveService has no current_level set
## (e.g. a fresh New Game before LevelProgression points at the hub).
@export var default_level_scene: PackedScene

# The level currently mounted as our "Level" child. Updated whenever we
# swap. Null before _ready finishes.
var _current_level: Node3D = null


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
func load_level(path: String) -> void:
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		push_error("Game.load_level: cannot load %s" % path)
		return
	_mount_level(packed)
	SaveService.set_current_level(StringName(path.get_file().trim_suffix(".tscn")))


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


func _spawn_player(level: Node) -> void:
	var player := get_node_or_null(^"Player") as Node3D
	if player == null:
		return
	var marker := level.get_node_or_null(^"PlayerSpawn") as Marker3D
	if marker == null:
		return
	# Position from the marker; basis is consumed by snap_to_spawn (see
	# player_body.gd) which seeds skin facing + camera yaw without baking
	# rotation into body.global_transform.
	player.global_position = marker.global_position
	if player.has_method(&"set_respawn_point"):
		player.call(&"set_respawn_point", marker.global_position)
	if player.has_method(&"snap_to_spawn"):
		player.call(&"snap_to_spawn", marker.global_transform)
