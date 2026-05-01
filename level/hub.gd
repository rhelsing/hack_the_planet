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
# Set at the end of dialogue/glitch_2.dialogue. Reaching that node requires
# HandlePicker.pick() (the handle-pick happens in ~stage_pick before the
# warn → menu → done chain), so this flag implies names are chosen. Used as
# the ratchet for first_enemies: park the group +20 Y until set, lower on
# flip, skip the raise entirely on resume once persisted.
const FLAG_GLITCH2_DONE: StringName = &"glitch2_done"
const FIRST_ENEMIES_RAISE_Y: float = 20.0
const FIRST_ENEMIES_LOWER_DURATION: float = 1.5

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
	_setup_first_enemies()
	# Splice's dance unlocks via dialogue: the player offers, Splice accepts
	# ("...it's a fine song."), `hub_post4_splice_danced` flips true. Listen
	# for it live so we can put his caged skin into the dance loop the
	# moment the flag fires. Replay (re-entering hub with the flag already
	# set) is handled inside _enter_victory_state.
	Events.flag_set.connect(_on_flag_set_for_splice_dance)


# Park the first_enemies group up high until the player finishes the Glitch
# intro dialogue (which guarantees handle-pick + warning landed). The
# ratchet is `glitch2_done` — already persisted in GameState — so resuming
# a save where it's true skips the raise; resuming where it's false reparks
# the group and rewires the listener.
func _setup_first_enemies() -> void:
	var first_enemies := get_node_or_null(^"first_enemies") as Node3D
	if first_enemies == null:
		return
	if GameState.get_flag(FLAG_GLITCH2_DONE, false):
		return
	first_enemies.position.y += FIRST_ENEMIES_RAISE_Y
	Events.flag_set.connect(_on_flag_set_for_first_enemies)


func _on_flag_set_for_first_enemies(id: StringName, value: Variant) -> void:
	if id != FLAG_GLITCH2_DONE or not bool(value):
		return
	var first_enemies := get_node_or_null(^"first_enemies") as Node3D
	if first_enemies == null:
		return
	var target_y: float = first_enemies.position.y - FIRST_ENEMIES_RAISE_Y
	var tw := create_tween()
	tw.tween_property(first_enemies, ^"position:y", target_y, FIRST_ENEMIES_LOWER_DURATION) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	Events.flag_set.disconnect(_on_flag_set_for_first_enemies)


# Splice dance trigger. Fires when the player completes his dance dialogue
# branch in hub_post4_splice.dialogue (`do GameState.set_flag(
# "hub_post4_splice_danced", true)`). Loud logs at every gate so a missed
# dance is immediately obvious in the console.
func _on_flag_set_for_splice_dance(id: StringName, value: Variant) -> void:
	if id != &"hub_post4_splice_danced":
		return
	if not bool(value):
		return
	_start_splice_dance_loop("flag flipped live")


func _start_splice_dance_loop(reason: String) -> void:
	var splice := get_node_or_null(^"postL4Show/Splice")
	if splice == null:
		push_warning("[hub] splice-dance(%s) — postL4Show/Splice not found" % reason)
		return
	if not splice.has_method(&"enter_dance_loop"):
		push_warning("[hub] splice-dance(%s) — Splice node lacks enter_dance_loop" % reason)
		return
	print("[hub] splice-dance(%s) — kick-off, clips=%s" % [reason, victory_player_dance_clips])
	splice.call(&"enter_dance_loop", victory_player_dance_clips)


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
	# Reveal the post-L4 victory tableau (Splice in the cage, Nyx celebrating).
	# Parked Y+30 + invisible by default in the tscn so it can't be reached
	# or interacted with before victory. Snap it to its authored position on
	# entry — no animation, just appears where it belongs.
	var post4 := get_node_or_null(^"postL4Show") as Node3D
	if post4 != null:
		post4.position.y = 0.0
		post4.visible = true
		# Both NPCs in the tableau dance through the same Mixamo dance pool the
		# player skin uses — keeps the choreography synchronized in vibe.
		# Splice MAY be hidden by his own `hide_when_flag = "refused_splice"`
		# guard if the player took the betray-Splice branch; the call is a
		# no-op then because the node is detached. Nyx lives at the hub root
		# now (revealed post-L1 via visible_when_flag), not under postL4Show —
		# we still wire her into the dance loop on victory entry.
		for path in [^"Nyx"]:
			var npc := get_node_or_null(path)
			if npc != null and npc.has_method(&"enter_dance_loop"):
				npc.call(&"enter_dance_loop", victory_player_dance_clips)
		# Replay: if the player already convinced Splice to dance in a prior
		# session and is re-entering the hub, kick him back into the loop.
		# The flag-set listener won't fire again since the flag's already true.
		if GameState.get_flag(&"hub_post4_splice_danced", false):
			_start_splice_dance_loop("re-entry replay")
	# AJ / Nyx (the player skin — whichever is mounted) idle-dances when
	# standing still. Skin owns the threshold + interval logic; we just
	# flip the flag and hand it the clip list. Skin auto-exits the dance
	# the moment the player moves.
	_set_player_idle_dance(true)
	# Credits roll on every post-L4 hub entry — overlays the victory state
	# without blocking gameplay. Self-frees on scroll completion or Esc.
	_spawn_credits_overlay()


func _spawn_credits_overlay() -> void:
	var packed: PackedScene = load("res://menu/credits.tscn")
	if packed == null:
		return
	var layer := CanvasLayer.new()
	# Below pause_menu (layer 100) so pause renders on top; above HUD.
	layer.layer = 50
	add_child(layer)
	var inst: Node = packed.instantiate()
	layer.add_child(inst)
	if inst.has_signal(&"back_requested"):
		inst.connect(&"back_requested", func() -> void: layer.queue_free(),
			CONNECT_ONE_SHOT)


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
