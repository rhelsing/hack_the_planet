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


func _ready() -> void:
	super()
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
	# Cache the underlying AnimationPlayer + AnimationTree once so wave
	# triggers don't walk the scene every tick.
	if _swivel != null:
		_wave_anim_tree = _swivel.get_node_or_null(^"%AnimationTree") as AnimationTree
		_wave_anim_player = _find_anim_player(_swivel)
	_pick_next_wave_interval()


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
	monitorable = true
	var tw := create_tween()
	if arrive_delay > 0.0:
		tw.tween_interval(arrive_delay)
	tw.tween_property(_swivel, "scale", Vector3.ONE, presence_anim_duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _animate_leave() -> void:
	if _swivel == null:
		return
	monitoring = false
	monitorable = false
	if _sfx != null and _sfx.stream != null:
		_sfx.play()
	var tw := create_tween()
	tw.tween_property(_swivel, "scale", Vector3.ZERO, presence_anim_duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void: visible = false)


func _process(delta: float) -> void:
	if _swivel == null:
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


# --- Idle wave -----------------------------------------------------------

func _tick_wave(delta: float) -> void:
	if _waving or not visible:
		return
	if _wave_anim_player == null:
		return
	_wave_timer += delta
	if _wave_timer < _next_wave_at:
		return
	_wave_timer = 0.0
	_pick_next_wave_interval()
	_play_wave()


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


func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c: Node in n.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null
