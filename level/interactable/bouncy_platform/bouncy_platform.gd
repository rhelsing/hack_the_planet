extends Node3D
class_name BouncyPlatform

## Catches the player on landing and springs them upward with an elastic
## animation. Uses the same shader material as static platforms but exposes
## both palette colors so each bouncy can be tinted (default: orange).
##
## Reparent trick (mirrors `level/elevator.gd`): when the player enters
## CarryZone we reparent under the moving Deck so they ride the squash
## without per-frame velocity transfer. At peak compression we hand them
## back to the world and apply the launch velocity — the elastic spring-up
## is purely visual after that.

const _PLATFORM_MATERIAL: ShaderMaterial = preload("res://level/platforms.tres")

@export_group("Color")
@export var palette_base: Color = Color(0.04, 0.02, 0.0, 1.0):
	set(value):
		palette_base = value
		_apply_palette()
@export var palette_highlight: Color = Color(1.0, 0.45, 0.05, 1.0):
	set(value):
		palette_highlight = value
		_apply_palette()

@export_group("Shape")
@export var size: Vector3 = Vector3(4.0, 1.0, 4.0):
	set(value):
		size = value
		_apply_size()

@export_group("Sound")
## Pool of one-shot boing sounds. Random clip per bounce, no immediate
## repeat. Plays from an AudioStreamPlayer3D on the deck so the bounce
## reads from the platform's location.
@export var bounce_sound_pool: Array[AudioStream] = []
## If bounce_sound_pool is empty, auto-load every wav/ogg/mp3 in this dir
## at _ready. Same pattern as PlayerBody's footstep/death pools.
@export_dir var bounce_sound_auto_load_dir: String = ""
@export_range(-30.0, 12.0) var bounce_sound_volume_db: float = 0.0
@export_range(0.0, 0.5) var bounce_sound_pitch_jitter: float = 0.06
## Delay between the squash impact and the boing playing. Lets the audio
## land on the spring-back rather than the compression. 0 = play immediately.
@export_range(0.0, 2.0) var bounce_sound_delay: float = 0.2

@export_group("Timed Boost")
## Extra Y velocity (m/s) added to the launched body when the player presses
## jump inside the boost window. Stacked on top of the regular launch_v —
## with default launch ~19.7 m/s, +7 m/s ≈ +6m peak height. 0 disables.
@export var bounce_boost_velocity: float = 7.0
## Total window width (seconds) centered on the bounce sound. 0.2 = ±0.1s
## from the audio cue. Tighter feels more skill-based; looser more forgiving.
@export_range(0.0, 1.0) var bounce_boost_window: float = 0.2

@export_group("Bounce")
## Peak height (meters) the player reaches above the deck top. Velocity is
## derived from gravity and includes squash compensation, so the value
## you set is honest. Default 6.0 ≈ 2.5× the player's ~2.4m jump peak.
@export var bounce_height: float = 6.0
## Gravity used for the velocity calc. Must match `_gravity` in player_body
## (defaults to 30.0 there). Tweak only if you change project gravity.
@export var gravity: float = 30.0
## How far the deck dips before springing back.
@export var squash_depth: float = 0.5
## Compression time. Slower = more anticipation before the launch.
@export var squash_duration: float = 0.18
## Spring-back duration; the player has already left at this point — the
## elastic ringing is purely cosmetic. Longer = more wobble after launch.
@export var spring_duration: float = 1.0

@onready var _deck: Node3D = $Deck
@onready var _box: CSGBox3D = $Deck/Box
@onready var _carry_zone: Area3D = $CarryZone
@onready var _carry_shape: CollisionShape3D = $CarryZone/Shape

var _material: ShaderMaterial = null
var _deck_base_y: float = 0.0
# A body is "carried" only during the squash phase. Once we launch, it's
# released — that way landing back on the deck while the cosmetic spring
# is still ringing kicks off a fresh bounce (continuous trampoline feel).
var _carried_body: Node3D = null
var _original_parent: Node = null
var _tween: Tween = null
var _bounce_sound_pool_resolved: Array[AudioStream] = []
var _last_bounce_sfx_idx: int = -1
# 3D so multiple bouncy platforms in a level pan + attenuate against the
# player's AudioListener3D (attached to player_body). One platform several
# rooms away should sound farther than one under your feet.
var _bounce_sfx_player: AudioStreamPlayer3D
# Timed-boost state. _boost_target tracks who to apply the boost to (set on
# squash start, used after the body is released by _launch). _boost_window_*
# bracket the input-listening window. _process is set on/off so non-active
# platforms don't poll input every frame.
var _boost_target: Node3D = null
var _boost_window_close_at: float = 0.0
var _boost_consumed: bool = false

# Class-level live overrides driven by the debug panel. NAN = "use my @export
# value." Shared across all instances so panel sliders tune the global feel
# without per-instance bookkeeping. Reset every run (panel is ephemeral).
static var _override_bounce_height: float = NAN
static var _override_squash_depth: float = NAN
static var _override_squash_duration: float = NAN
static var _override_spring_duration: float = NAN
static var _panel_registered: bool = false


func _ready() -> void:
	# Boost-window polling only runs when active (set true in _open_boost_window,
	# false in _close_boost_window); stays off the rest of the time so dozens
	# of bouncy platforms in a level don't poll input every frame.
	set_process(false)
	_material = _PLATFORM_MATERIAL.duplicate() as ShaderMaterial
	_box.material_override = _material
	_apply_palette()
	_apply_size()
	_deck_base_y = _deck.position.y
	_carry_zone.body_entered.connect(_on_body_entered)
	_carry_zone.body_exited.connect(_on_body_exited)
	_setup_bounce_audio()
	_register_debug_panel()


func _setup_bounce_audio() -> void:
	_bounce_sound_pool_resolved = bounce_sound_pool.duplicate()
	if _bounce_sound_pool_resolved.is_empty() and not bounce_sound_auto_load_dir.is_empty():
		_bounce_sound_pool_resolved = _load_audio_dir(bounce_sound_auto_load_dir)
	_bounce_sfx_player = AudioStreamPlayer3D.new()
	_bounce_sfx_player.bus = &"SFX"
	_bounce_sfx_player.unit_size = 6.0
	_bounce_sfx_player.max_distance = 35.0
	_deck.add_child(_bounce_sfx_player)


func _load_audio_dir(path: String) -> Array[AudioStream]:
	var out: Array[AudioStream] = []
	var dir := DirAccess.open(path)
	if dir == null:
		push_warning("BouncyPlatform: audio auto-load dir missing: %s" % path)
		return out
	dir.list_dir_begin()
	var files: Array[String] = []
	while true:
		var f := dir.get_next()
		if f == "":
			break
		if dir.current_is_dir():
			continue
		var lower: String = f.to_lower()
		if lower.ends_with(".wav") or lower.ends_with(".ogg") or lower.ends_with(".mp3"):
			files.append(f)
	dir.list_dir_end()
	files.sort()
	for f in files:
		var s := load(path.path_join(f)) as AudioStream
		if s != null:
			out.append(s)
	return out


func _play_random_bounce_sfx() -> void:
	var n: int = _bounce_sound_pool_resolved.size()
	if n == 0 or _bounce_sfx_player == null:
		print("[bnc-aud-dbg] skip: pool=%d player=%s dir=%s" % [
			n, _bounce_sfx_player, bounce_sound_auto_load_dir])
		return
	var idx: int = randi() % n
	if n > 1 and idx == _last_bounce_sfx_idx:
		idx = (idx + 1) % n
	_last_bounce_sfx_idx = idx
	_bounce_sfx_player.stream = _bounce_sound_pool_resolved[idx]
	_bounce_sfx_player.volume_db = bounce_sound_volume_db
	_bounce_sfx_player.pitch_scale = 1.0 + randf_range(-bounce_sound_pitch_jitter, bounce_sound_pitch_jitter)
	_bounce_sfx_player.play()
	var sfx_idx := AudioServer.get_bus_index(&"SFX")
	print("[bnc-aud-dbg] play: stream=%s vol_db=%.1f sfx_bus_db=%.1f muted=%s" % [
		_bounce_sound_pool_resolved[idx].resource_path,
		bounce_sound_volume_db, AudioServer.get_bus_volume_db(sfx_idx),
		AudioServer.is_bus_mute(sfx_idx)])


# Effective getters: panel override takes precedence, otherwise this
# instance's @export. is_nan() because static floats default to 0.0; we use
# NAN as the "unset" sentinel so 0.0 remains a valid panel value.
func _eff_bounce_height() -> float:
	return bounce_height if is_nan(_override_bounce_height) else _override_bounce_height

func _eff_squash_depth() -> float:
	return squash_depth if is_nan(_override_squash_depth) else _override_squash_depth

func _eff_squash_duration() -> float:
	return squash_duration if is_nan(_override_squash_duration) else _override_squash_duration

func _eff_spring_duration() -> float:
	return spring_duration if is_nan(_override_spring_duration) else _override_spring_duration


func _register_debug_panel() -> void:
	# First instance wins; subsequent ones reuse the same sliders.
	if _panel_registered:
		return
	# Look up via /root rather than the global identifier so this script
	# still compiles under SceneTree-mode tests (no autoloads loaded).
	var dp: Node = get_tree().root.get_node_or_null(^"DebugPanel")
	if dp == null:
		return
	_panel_registered = true
	# Seed the static overrides from this instance's @export defaults so the
	# slider's initial position matches what's currently in effect.
	_override_bounce_height = bounce_height
	_override_squash_depth = squash_depth
	_override_squash_duration = squash_duration
	_override_spring_duration = spring_duration
	dp.call(&"add_slider", "Bouncy/bounce_height", 0.5, 20.0, 0.1,
		func() -> float: return _override_bounce_height,
		func(v: float) -> void: _override_bounce_height = v,
		"bouncy_platform.gd")
	dp.call(&"add_slider", "Bouncy/squash_depth", 0.05, 1.5, 0.05,
		func() -> float: return _override_squash_depth,
		func(v: float) -> void: _override_squash_depth = v,
		"bouncy_platform.gd")
	dp.call(&"add_slider", "Bouncy/squash_duration", 0.02, 0.6, 0.01,
		func() -> float: return _override_squash_duration,
		func(v: float) -> void: _override_squash_duration = v,
		"bouncy_platform.gd")
	dp.call(&"add_slider", "Bouncy/spring_duration", 0.1, 2.5, 0.05,
		func() -> float: return _override_spring_duration,
		func(v: float) -> void: _override_spring_duration = v,
		"bouncy_platform.gd")


func _apply_palette() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"palette_black", palette_base)
	_material.set_shader_parameter(&"palette_purple", palette_highlight)


func _apply_size() -> void:
	if _box != null:
		_box.size = size
	if _carry_shape != null and _carry_shape.shape is BoxShape3D:
		var carry_box: BoxShape3D = _carry_shape.shape as BoxShape3D
		# Thin slab sitting just above the deck top so landing-from-above
		# triggers entry, but jumping up underneath does not.
		carry_box.size = Vector3(size.x, 0.6, size.z)
		_carry_shape.position.y = size.y * 0.5 + 0.3


func _on_body_entered(body: Node) -> void:
	if _carried_body != null:
		return  # mid-squash already; ignore secondary entries.
	if not body.is_in_group("player"):
		return
	if not (body is Node3D):
		return
	_carried_body = body as Node3D
	_original_parent = body.get_parent()
	body.call_deferred(&"reparent", _deck, true)
	_start_bounce()


func _on_body_exited(body: Node) -> void:
	# Walked off the side mid-squash without launching — restore parent so
	# the player doesn't keep riding a static deck.
	if body != _carried_body:
		return
	_restore_parent()
	_carried_body = null
	_original_parent = null


func _start_bounce() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if bounce_sound_delay > 0.0:
		get_tree().create_timer(bounce_sound_delay).timeout.connect(
			_play_random_bounce_sfx, CONNECT_ONE_SHOT)
	else:
		_play_random_bounce_sfx()
	# Timed-boost setup. Track who to apply the boost to (the launched body),
	# schedule the input-listening window centered on the sound, and suppress
	# the body's own jump for the same duration so accidental presses can't
	# bypass the timing requirement and stack extra height.
	_boost_target = _carried_body
	_boost_consumed = false
	if bounce_boost_velocity > 0.0 and _boost_target != null:
		var half: float = bounce_boost_window * 0.5
		var open_at: float = maxf(0.0, bounce_sound_delay - half)
		if open_at > 0.0:
			get_tree().create_timer(open_at).timeout.connect(
				_open_boost_window, CONNECT_ONE_SHOT)
		else:
			_open_boost_window()
		# Suppress the body's normal jump until just past the window's close.
		# 0.05s margin covers physics-tick alignment slop.
		if _boost_target.has_method(&"suppress_jump_for"):
			_boost_target.suppress_jump_for(bounce_sound_delay + half + 0.05)
	var depth: float = _eff_squash_depth()
	_tween = create_tween()
	_tween.tween_property(_deck, ^"position:y", _deck_base_y - depth, _eff_squash_duration()) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(_launch)
	_tween.tween_property(_deck, ^"position:y", _deck_base_y, _eff_spring_duration()) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _launch() -> void:
	# Hand the player back to the world and apply velocity. The cosmetic
	# spring-back continues after this, but the player is no longer carried —
	# if they land back on the deck mid-spring it kicks off a new bounce.
	if _carried_body == null or not is_instance_valid(_carried_body):
		return
	var body: Node3D = _carried_body
	# Compensate launch velocity for the squash dip so the configured
	# bounce_height is the real peak above the deck top, not deck-bottom.
	var launch_v: float = sqrt(2.0 * maxf(gravity, 0.0001) \
		* maxf(_eff_bounce_height() + _eff_squash_depth(), 0.0))
	_restore_parent()
	if "velocity" in body:
		var v: Vector3 = body.get(&"velocity")
		body.set(&"velocity", Vector3(v.x, launch_v, v.z))
	_carried_body = null
	_original_parent = null


func _open_boost_window() -> void:
	if _boost_consumed or _boost_target == null or not is_instance_valid(_boost_target):
		return
	_boost_window_close_at = Time.get_ticks_msec() / 1000.0 + bounce_boost_window
	set_process(true)


func _process(_delta: float) -> void:
	if _boost_consumed:
		set_process(false)
		return
	if Time.get_ticks_msec() / 1000.0 > _boost_window_close_at:
		set_process(false)
		return
	if Input.is_action_just_pressed(&"jump"):
		_apply_boost()
		set_process(false)


func _apply_boost() -> void:
	_boost_consumed = true
	if _boost_target == null or not is_instance_valid(_boost_target):
		return
	if not "velocity" in _boost_target:
		return
	var v: Vector3 = _boost_target.get(&"velocity")
	_boost_target.set(&"velocity", Vector3(v.x, v.y + bounce_boost_velocity, v.z))


func _restore_parent() -> void:
	if _carried_body == null or not is_instance_valid(_carried_body):
		return
	if _carried_body.get_parent() != _deck:
		return
	if _original_parent == null or not is_instance_valid(_original_parent):
		return
	_carried_body.call_deferred(&"reparent", _original_parent, true)
