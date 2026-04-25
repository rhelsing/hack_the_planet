extends DialogueTrigger

## Glitch (and any future hub companion). Inherits the press-to-talk + walk +
## cinematic camera flow from DialogueTrigger and adds a lazy "swivel toward
## the player" yaw on the Skin child so the model always reads as paying
## attention without requiring an animation state.

## Skin node to swivel. Rotated around Y only — pitch/roll are left alone so
## the rig stays upright and idle animations play untouched.
@export var swivel_target_path: NodePath = ^"Skin"
## Lerp rate (radians per second of catch-up). Lower = lazier swivel.
@export var swivel_speed: float = 3.5
## Don't bother rotating if the player is closer than this — avoids spinning
## like a top when the player walks through the NPC.
@export var min_track_distance: float = 0.6
## If non-empty, the NPC stays hidden + non-interactable until this flag is
## set on GameState. Used to chain reveals — e.g. Glitch2 only appears after
## Glitch1's dialogue ends ("glitch1_done" flag).
@export var visible_when_flag: StringName = &""
## If non-empty, the NPC scales away + becomes non-interactable when this
## flag is set. Lets a NPC "leave" via the same dialogue beat that summons
## a successor — e.g. Glitch1 vanishes when its own "glitch1_done" fires.
@export var hide_when_flag: StringName = &""
## Seconds for the scale-in / scale-out animation.
@export var presence_anim_duration: float = 0.5
## Delay before _animate_arrive starts tweening up. Set this to (or above)
## the predecessor's `presence_anim_duration` so the leave-finishes-first /
## arrive-starts-after sequence reads as a hand-off, not a crossfade.
@export var arrive_delay: float = 0.0
## Optional warp SFX. Plays once at the start of the LEAVE animation only —
## arrive is silent. Lets a successor NPC scale in without competing audio.
@export var warp_sfx: AudioStream

## Idle behavior — periodic wave at randomized intervals so the NPC reads
## as actively engaged. Each tick after a wave finishes, picks a fresh
## interval from this list (all values in seconds).
@export var wave_intervals_sec: Array[float] = [5.0, 7.0, 13.0]
@export var wave_clip_name: StringName = &"Wave"

## Optional skin override — if set, the default Skin child is freed at _ready
## and replaced with an instance of this scene. Lets companion variants (Glitch,
## DialTone, ...) share the base scene while wearing different skins.
@export var skin_scene: PackedScene

## Ratchet system — companion travels through a sequence of CompanionStation
## markers in the level. When the current dialogue sets `advance_flag` on
## GameState, the companion elastic-tweens to the next station and adopts
## its dialogue + advance_flag. Single forward-only progression.
@export var stations: Array[NodePath] = []
## Flag the companion's CURRENT dialogue sets on completion (via
## `do GameState.set_flag`). When it flips true, the ratchet fires.
## Updated each time the companion advances to a new station.
@export var advance_flag: StringName = &""
## Seconds for the elastic travel tween between stations. Long because the
## elastic settle feels right when the actual translation reads as a
## deliberate glide rather than a snap-with-bounce.
@export var travel_duration: float = 16.0

# Skins built on the body system natively face +basis.z, so a yaw of
# atan2(dir.x, dir.z) points the basis.z axis at the target.
const _MODEL_FORWARD_OFFSET: float = 0.0

var _swivel: Node3D
var _player: Node3D = null
var _sfx: AudioStreamPlayer
var _wave_anim_player: AnimationPlayer
var _wave_anim_tree: AnimationTree
var _wave_timer: float = 0.0
var _next_wave_at: float = 0.0
var _waving: bool = false
var _station_idx: int = -1   # -1 = sitting at the initial spawn position
var _traveling: bool = false
# Dance loop — when active, AnimationTree is disabled and the underlying
# AnimationPlayer plays a random clip from `_dance_clips`, holds for a
# random interval from `_dance_intervals`, then picks again. Used by the
# post-L4 victory hub state to make companions celebrate.
var _dance_clips: Array[StringName] = []
var _dance_intervals: Array[float] = []
var _dancing: bool = false


func _ready() -> void:
	super()
	_maybe_swap_skin()
	_swivel = get_node_or_null(swivel_target_path) as Node3D
	_sfx = AudioStreamPlayer.new()
	_sfx.bus = &"SFX" if AudioServer.get_bus_index(&"SFX") != -1 else &"Master"
	_sfx.process_mode = Node.PROCESS_MODE_ALWAYS
	if warp_sfx != null:
		_sfx.stream = warp_sfx
	add_child(_sfx)
	_apply_initial_presence()
	if visible_when_flag != &"" or hide_when_flag != &"":
		Events.flag_set.connect(_on_flag_set)
	# Ratchet system — listen for advance_flag firing if we have stations
	# wired up. Connection is independent of the legacy hide/visible flow.
	if not stations.is_empty():
		Events.flag_set.connect(_on_advance_flag_set)
		# Restore prior progress: if the player already completed any of our
		# advance flags in a saved session, walk forward (snap, no tween) so
		# we land at the correct station with the correct dialogue + flag.
		# Persistence lives in GameState.flags via the existing save system.
		_restore_progress()
	# Cache the underlying AnimationPlayer + AnimationTree once so wave
	# triggers don't walk the scene every tick.
	if _swivel != null:
		_wave_anim_tree = _swivel.get_node_or_null(^"%AnimationTree") as AnimationTree
		_wave_anim_player = _find_anim_player(_swivel)
	_pick_next_wave_interval()
	# Companions never move — kill the skin's dust emitter so we don't get a
	# permanent skate-dust trail under an idle NPC.
	if _swivel != null and _swivel.has_method(&"set_dust_emitting"):
		_swivel.call(&"set_dust_emitting", false)


# Snap to the right state at scene load — no animation. Animation only fires
# when a flag flips at runtime.
func _apply_initial_presence() -> void:
	if hide_when_flag != &"" and bool(GameState.get_flag(hide_when_flag, false)):
		_set_present_snap(false)
		return
	if visible_when_flag != &"" and not bool(GameState.get_flag(visible_when_flag, false)):
		_set_present_snap(false)
		return
	_set_present_snap(true)


func _set_present_snap(present: bool) -> void:
	visible = present
	monitoring = present
	monitorable = present
	_set_bump_enabled(present)
	if _swivel != null:
		_swivel.scale = Vector3.ONE if present else Vector3.ZERO


func _on_flag_set(id: StringName, value: Variant) -> void:
	if not value:
		return
	if id == hide_when_flag:
		_animate_leave()
	elif id == visible_when_flag:
		_animate_arrive()


func _animate_arrive() -> void:
	if _swivel == null:
		return
	# Snap scale to ZERO BEFORE flipping visible so we don't render at scale=ONE
	# for a single frame (the "pop" otherwise visible if visible flips first).
	_swivel.scale = Vector3.ZERO
	visible = true
	monitoring = true
	_set_bump_enabled(true)
	monitorable = true
	var tw := create_tween()
	if arrive_delay > 0.0:
		tw.tween_interval(arrive_delay)
	tw.tween_property(_swivel, "scale", Vector3.ONE, presence_anim_duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _animate_leave() -> void:
	if _swivel == null:
		return
	# Disable everything the player could still hit: the interaction sensor
	# (Area3D monitor), the physical Bump collider that would otherwise still
	# block pathing, and finally visibility. Without the Bump disable the
	# player walks into an invisible wall after the NPC "leaves".
	monitoring = false
	monitorable = false
	_set_bump_enabled(false)
	if _sfx != null and _sfx.stream != null:
		_sfx.play()
	var tw := create_tween()
	tw.tween_property(_swivel, "scale", Vector3.ZERO, presence_anim_duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void: visible = false)


func _set_bump_enabled(on: bool) -> void:
	var bump_shape: CollisionShape3D = get_node_or_null(^"Bump/BumpShape") as CollisionShape3D
	if bump_shape != null:
		bump_shape.disabled = not on


func _process(delta: float) -> void:
	if _swivel == null:
		return
	# In travel mode the swivel + wave systems are frozen — facing was set
	# at travel-start so the model already points at the destination.
	if _traveling:
		return
	if _player == null or not is_instance_valid(_player):
		_player = _find_player()
		if _player == null:
			return
	var to_player: Vector3 = _player.global_position - _swivel.global_position
	to_player.y = 0.0
	if to_player.length_squared() >= min_track_distance * min_track_distance:
		var target_yaw: float = atan2(to_player.x, to_player.z) + _MODEL_FORWARD_OFFSET
		var t: float = 1.0 - exp(-swivel_speed * delta)
		_swivel.rotation.y = lerp_angle(_swivel.rotation.y, target_yaw, t)
	_tick_wave(delta)


# Find the player by group; cached after first lookup until invalidated.
func _find_player() -> Node3D:
	for node in get_tree().get_nodes_in_group("player"):
		if node is Node3D:
			return node
	return null


# --- Ratchet — travel to next CompanionStation --------------------------

func _on_advance_flag_set(id: StringName, value: Variant) -> void:
	# Ignore false/0 values (set_flag(name, false) shouldn't trigger advance).
	# Match check on `advance_flag` naturally guards against double-fire from
	# repeated set_flag calls — once we advance, advance_flag changes.
	if not value:
		return
	if id == &"" or id != advance_flag:
		return
	if _traveling:
		return
	_advance_to_next_station(false)


func _advance_to_next_station(snap: bool) -> void:
	var next_idx: int = _station_idx + 1
	if next_idx >= stations.size():
		return  # No more stops — companion stays where it is.
	var node: Node = get_node_or_null(stations[next_idx])
	var station: CompanionStation = node as CompanionStation
	if station == null:
		push_warning("[%s] station[%d] resolves to %s — not a CompanionStation; aborting ratchet." % [name, next_idx, node])
		return
	_station_idx = next_idx
	if snap:
		_snap_to(station)
	else:
		_travel_to(station)


func _travel_to(station: CompanionStation) -> void:
	_traveling = true
	# Snap-rotate skin to face destination so the elastic flight reads as a
	# committed move rather than a sideways slide. Swivel toward player is
	# disabled (see _process guard) so this rotation sticks for the duration.
	var dest: Vector3 = station.global_position
	var planar := Vector3(dest.x - global_position.x, 0.0, dest.z - global_position.z)
	if _swivel != null and planar.length_squared() > 0.0001:
		_swivel.rotation.y = atan2(planar.x, planar.z) + _MODEL_FORWARD_OFFSET
	var tw := create_tween()
	tw.tween_property(self, "global_position", dest, travel_duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(_on_travel_finished.bind(station))


func _snap_to(station: CompanionStation) -> void:
	# Used during save-load restore. No tween, no traveling state — just be
	# at the station with the right dialogue + advance flag, immediately.
	global_position = station.global_position
	dialogue_resource = station.dialogue_resource
	advance_flag = station.advance_flag


func _on_travel_finished(station: CompanionStation) -> void:
	_traveling = false
	dialogue_resource = station.dialogue_resource
	advance_flag = station.advance_flag


# Walk forward through stations whose advance_flag is already true on
# GameState — that means a prior session advanced past them. Each iteration
# updates `advance_flag` to the current station's, so the loop terminates
# at the first station whose flag is NOT yet set (or end of the list).
func _restore_progress() -> void:
	var safety: int = stations.size() + 1
	while safety > 0 and advance_flag != &"" and bool(GameState.get_flag(advance_flag, false)):
		var prev_idx: int = _station_idx
		_advance_to_next_station(true)
		if _station_idx == prev_idx:
			break  # ran out of stations — bail
		safety -= 1


# --- Idle wave -----------------------------------------------------------

func _tick_wave(delta: float) -> void:
	if _waving or _dancing or not visible:
		return
	if _wave_anim_player == null:
		return
	_wave_timer += delta
	if _wave_timer < _next_wave_at:
		return
	_wave_timer = 0.0
	_pick_next_wave_interval()
	_play_wave()


# --- Victory dance loop ---------------------------------------------------

## Disable the AnimationTree and cycle through `clips` on the underlying
## AnimationPlayer indefinitely. Picks a random clip every random interval
## (5 / 7 / 13 seconds by default — same flavour as the wave_intervals_sec
## pattern). Used by hub.gd's post-L4 victory state. Idempotent — calling
## again resets the picker.
func enter_dance_loop(clips: Array, intervals_sec: Array = [5.0, 7.0, 13.0]) -> void:
	if _wave_anim_player == null:
		return
	_dance_clips.clear()
	for c in clips:
		var sn: StringName = c if c is StringName else StringName(str(c))
		if _wave_anim_player.has_animation(sn):
			_dance_clips.append(sn)
	if _dance_clips.is_empty():
		return
	_dance_intervals.clear()
	for s in intervals_sec:
		_dance_intervals.append(float(s))
	if _dance_intervals.is_empty():
		_dance_intervals = [5.0, 7.0, 13.0]
	_dancing = true
	if _wave_anim_tree != null:
		_wave_anim_tree.active = false
	_play_random_dance_clip()


func exit_dance_loop() -> void:
	_dancing = false
	_dance_clips.clear()
	_dance_intervals.clear()
	if _wave_anim_tree != null:
		_wave_anim_tree.active = true


func _play_random_dance_clip() -> void:
	if not _dancing or _dance_clips.is_empty() or _wave_anim_player == null:
		return
	var clip: StringName = _dance_clips[randi() % _dance_clips.size()]
	# Force LOOP_LINEAR at play time so the dance keeps cycling for the full
	# hold interval. Don't rely on the skin's _force_loop_linear list — clips
	# missing from that list (e.g. Victory) would otherwise play once and
	# freeze. This mutates the shared Animation resource (Godot caches the
	# clip on the GLB), but every consumer of that clip wants it to loop in
	# the dance context anyway.
	var anim := _wave_anim_player.get_animation(clip)
	if anim != null:
		anim.loop_mode = Animation.LOOP_LINEAR
	_wave_anim_player.play(clip)
	var hold_s: float = _dance_intervals[randi() % _dance_intervals.size()]
	# create_timer respects the node's PROCESS_MODE (INHERIT) — dance pauses
	# during dialogue/pause menu, which matches the rest of the world.
	await get_tree().create_timer(hold_s).timeout
	_play_random_dance_clip()


func _pick_next_wave_interval() -> void:
	if wave_intervals_sec.is_empty():
		_next_wave_at = INF  # explicit disable
	else:
		_next_wave_at = wave_intervals_sec[randi() % wave_intervals_sec.size()]


func _play_wave() -> void:
	if not _wave_anim_player.has_animation(wave_clip_name):
		return
	_waving = true
	# Disable the AnimationTree so its state-machine output doesn't blend
	# over our direct AP play. Re-enable on finished.
	if _wave_anim_tree != null:
		_wave_anim_tree.active = false
	_wave_anim_player.play(wave_clip_name)
	if not _wave_anim_player.animation_finished.is_connected(_on_wave_finished):
		_wave_anim_player.animation_finished.connect(_on_wave_finished, CONNECT_ONE_SHOT)


func _on_wave_finished(_clip: StringName) -> void:
	if _wave_anim_tree != null:
		_wave_anim_tree.active = true
	_waving = false


func _maybe_swap_skin() -> void:
	if skin_scene == null:
		return
	var existing: Node = get_node_or_null(swivel_target_path)
	if existing != null:
		existing.name = "_SkinOld"
		existing.queue_free()
	var new_skin: Node = skin_scene.instantiate()
	new_skin.name = "Skin"
	add_child(new_skin)


func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c: Node in n.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null
