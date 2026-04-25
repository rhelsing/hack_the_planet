extends Node3D

## Between-levels hub. 4 pedestals (one per level) + 4 NPCs (one per theme).
## Pedestals gate on prior completion flags; NPCs branch their dialogue on
## level_N_completed + powerup_X flags.
##
## On _ready we tell the state machine this is our "current level" so a quit
## here resumes here on next launch.
##
## Once `level_4_completed` is set, the hub enters a victory state on every
## entry: directional-light specular slides up, disco music plays, and a
## stream of placeholder confetti bursts pops at random points on a sphere
## around the player. Every fx hook is @export so swapping the burst scene
## or retuning rate/radius is an inspector edit.

# First-time hub entry uses `tutorial_spawn`; every visit after uses the
# authored `PlayerSpawn` slot. We achieve this by copying tutorial_spawn's
# transform onto PlayerSpawn before Game._spawn_player consumes it.
const FLAG_HUB_VISITED: StringName = &"hub_visited"
const FLAG_LEVEL_4_COMPLETED: StringName = &"level_4_completed"

@export_group("Victory FX")
@export var victory_specular: float = 14.0
@export var victory_specular_fade_s: float = 1.5
@export var victory_music: AudioStream = preload("res://audio/music/disco_music.mp3")
@export var victory_music_fade_in_s: float = 2.0
## Placeholder burst — confetti for v1, swap to a real firework scene later.
@export var firework_scene: PackedScene = preload("res://enemy/confetti_burst.tscn")
@export var firework_radius: float = 20.0
@export var firework_interval_s: float = 2.0
## NPC to put into a celebratory dance loop on victory entry. Default points
## at DialTone (his anime_character skin has Dance / Dance Body Roll / Dance
## Charleston / Victory clips). Empty path = skip.
@export var victory_dance_target_path: NodePath = ^"Ground/DialTone"
@export var victory_dance_clips: Array[StringName] = [
	&"Dance", &"Dance Body Roll", &"Dance Charleston", &"Victory",
]
## Dance clips the PLAYER's skin (AJ / Nyx, both share the Mixamo dance
## library) cycles through after `idle_dance_threshold_s` of standing
## still. Only enabled inside the post-L4 hub session — disabled on
## hub exit so the player doesn't dance idle in other levels.
@export var victory_player_dance_clips: Array[StringName] = [
	&"Dancing Twerk", &"Hip Hop Dancing", &"Hip Hop Dancing(1)",
	&"Hip Hop Dancing(2)", &"Shuffling", &"Silly Dancing", &"Wave Hip Hop Dance",
]
@export_group("")

var _victory_active: bool = false
var _firework_timer: float = 0.0


func _ready() -> void:
	SaveService.set_current_level(LevelProgression.HUB_LEVEL_ID)
	# No register_level(num) call — hub isn't a numbered level.
	if not GameState.get_flag(FLAG_HUB_VISITED, false):
		var ps := get_node_or_null(^"PlayerSpawn") as Marker3D
		var ts := get_node_or_null(^"tutorial_spawn") as Marker3D
		if ps != null and ts != null:
			ps.global_transform = ts.global_transform
		GameState.set_flag(FLAG_HUB_VISITED, true)
	if GameState.get_flag(FLAG_LEVEL_4_COMPLETED, false):
		_enter_victory_state()


func _enter_victory_state() -> void:
	_victory_active = true
	var light := get_node_or_null(^"DirectionalLight3D") as DirectionalLight3D
	if light != null:
		var tw := create_tween()
		tw.tween_property(light, "light_specular", victory_specular, victory_specular_fade_s)
	if victory_music != null:
		Audio.play_music(victory_music, victory_music_fade_in_s)
	# DialTone (or whoever's wired) cycles through their dance clips for the
	# duration of the hub session. CompanionNPC.enter_dance_loop disables its
	# AnimationTree and rotates through the list on each animation_finished.
	if victory_dance_target_path != ^"" and not victory_dance_clips.is_empty():
		var dancer := get_node_or_null(victory_dance_target_path)
		if dancer != null and dancer.has_method(&"enter_dance_loop"):
			dancer.call(&"enter_dance_loop", victory_dance_clips)
	# AJ / Nyx (the player skin — whichever is mounted) idle-dances when
	# standing still. Skin owns the threshold + interval logic; we just
	# flip the flag and hand it the clip list. Skin auto-exits the dance
	# the moment the player moves.
	_set_player_idle_dance(true)


func _exit_tree() -> void:
	# Player skin lives on PlayerBody which persists across level swaps —
	# unset the idle-dance flag so AJ doesn't break out into Hip Hop in
	# Level 1 after we revisit the hub.
	_set_player_idle_dance(false)


func _set_player_idle_dance(on: bool) -> void:
	var tree := get_tree()
	if tree == null:
		print("[hub] _set_player_idle_dance(%s) — no tree" % on)
		return
	var player := tree.get_first_node_in_group(&"player")
	if player == null:
		print("[hub] _set_player_idle_dance(%s) — no player in 'player' group" % on)
		return
	var skin = player.get(&"_skin")
	if skin == null:
		print("[hub] _set_player_idle_dance(%s) — player has no _skin (player=%s)" % [on, player])
		return
	if not ("idle_dance_enabled" in skin):
		print("[hub] _set_player_idle_dance(%s) — skin %s lacks idle_dance_enabled (only AjSkin/NyxSkin support it)" % [on, skin])
		return
	skin.set(&"idle_dance_enabled", on)
	if on:
		skin.set(&"idle_dance_clips", victory_player_dance_clips)
	print("[hub] _set_player_idle_dance(%s) — wired skin=%s clips=%s" % [on, skin, victory_player_dance_clips])


func _process(delta: float) -> void:
	if not _victory_active:
		return
	_firework_timer -= delta
	if _firework_timer <= 0.0:
		_firework_timer = firework_interval_s
		_spawn_firework()


# Spawn the configured burst scene at a uniformly random point on a sphere
# of radius `firework_radius` centered on the player. No-op if the player
# isn't in the tree yet — _process keeps polling, so it self-heals once
# Game._spawn_player runs.
func _spawn_firework() -> void:
	if firework_scene == null:
		return
	var player := get_tree().get_first_node_in_group(&"player") as Node3D
	if player == null:
		return
	var dir := Vector3(
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0),
	)
	if dir.length_squared() < 0.0001:
		dir = Vector3.UP
	dir = dir.normalized()
	var burst := firework_scene.instantiate() as Node3D
	add_child(burst)
	burst.global_position = player.global_position + dir * firework_radius
