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
## Delay between the squash impact and the boing playing. Matched to
## `squash_duration` so the boing fires at the exact moment of launch.
## Centers the boost-jump window on this value, so changing it slides
## the window along the timeline. Tuned 2026-05-22.
@export_range(0.0, 2.0) var bounce_sound_delay: float = 0.05

@export_group("Timed Boost")
## (Deprecated — chain now press-driven; see chain logic in _apply_boost
## and _on_body_entered. Kept on the export so old .tscn overrides don't
## fail to load. Not currently read by any code path.)
@export var chain_reset_window: float = 2.0
## (Deprecated 2026-05-22 — chain now tracks any press during the airtime
## via a boolean flag, no time buffer needed. Kept on the export so old
## .tscn overrides don't fail to load.)
@export var jump_buffer_seconds: float = 0.5
## Extra Y velocity (m/s) added to the launched body for each chained
## press. Stacked on top of the regular launch_v —
## with default launch ~19.7 m/s, +7 m/s ≈ +6m peak height. 0 disables.
@export var bounce_boost_velocity: float = 7.0
## Total window width (seconds) centered on the bounce sound. 0.2 = ±0.1s
## from the audio cue. Tighter feels more skill-based; looser more forgiving.
@export_range(0.0, 2.0) var bounce_boost_window: float = 1.0

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
## Compression time. Slower = more anticipation before the launch. This
## is ALSO the total time before the player sees themselves go up — the
## launch impulse fires at the end of this. Tuned 2026-05-22.
@export var squash_duration: float = 0.05
## Spring-back duration; the player has already left at this point — the
## elastic ringing is purely cosmetic. Longer = more wobble after launch.
## Tuned 2026-05-22.
@export var spring_duration: float = 0.8
## Peak overshoot of the spring above the deck's rest Y (meters). Drives
## how dramatic the post-launch ringing reads visually without changing
## spring_duration. The deck oscillates above + below base by progressively
## smaller fractions of this until it settles. 0.0 = no overshoot, deck
## just rises smoothly to base. Tuned 2026-05-22.
@export var spring_overshoot_amplitude: float = 1.0

@onready var _deck: Node3D = $Deck
@onready var _box: CSGBox3D = $Deck/Box
@onready var _body_shape: CollisionShape3D = $Deck/Body/BodyShape
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
# (Boost-window mechanic removed 2026-05-22 — replaced by jump-buffer.)

# Chain-bounce state (press-driven trampoline double-bounce). Each
# successful boost press (jump within the boost window) increments
# _chain_count. Landing WITHOUT a press in the previous window resets
# chain to 0. Next launch adds (chain_count × bounce_boost_velocity).
var _chain_count: int = 0
var _chain_body: Node3D = null
# Press tracking: was jump pressed at any point since the last launch?
# Reset on every _launch; set true by _input listening for the jump
# action. Robust to any airtime length — at chain-2 the round trip is
# ~2.25s, way past a fixed buffer window. Now: if you press jump
# anywhere from leaving the deck to landing back on it, you chain.
var _jump_pressed_since_launch: bool = false
# Diagnostic only: timestamp of last press, used for log readability.
var _last_jump_press_msec: int = -10000

# Squash-commit window. While Time.get_ticks_msec() < this, body_exited is
# ignored — the bounce is a committed event and the CarryZone Area3D
# routinely fires spurious exit/enter cycles during the 50ms squash as
# the deck dips and the player capsule slips across the fixed trigger
# boundary. Without this gate, each spurious exit clears _carried_body
# and the next spurious enter restarts the bounce from scratch
# (kills the tween, resets chain state, replays SFX).
var _squash_commit_until_msec: int = 0
# Post-launch lockout. While Time.get_ticks_msec() < this, _on_body_entered
# refuses to start a fresh bounce. After a launch, the deck springs UP
# rapidly (2m+ overshoot) and re-detects the player in CarryZone before
# they've physically risen above it — that spurious "fresh land" was
# wiping the chain. Player can't legitimately re-land sooner than
# their airtime (≥1.3s at base launch), so a ~200ms gate is safe.
var _post_launch_lockout_until_msec: int = 0

# Class-level live overrides driven by the debug panel. NAN = "use my @export
# value." Shared across all instances so panel sliders tune the global feel
# without per-instance bookkeeping. Reset every run (panel is ephemeral).
static var _override_bounce_height: float = NAN
static var _override_squash_depth: float = NAN
static var _override_squash_duration: float = NAN
static var _override_spring_duration: float = NAN
static var _override_spring_overshoot_amplitude: float = NAN
static var _panel_registered: bool = false


func _ready() -> void:
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


## Enumerate audio resources in a res:// directory. Critical for exports:
## Godot strips raw .mp3/.wav source files; only .import sidecars + the
## imported form ship. Scan for .import siblings (which DO ship), strip
## the suffix, then load() — ResourceLoader resolves to whichever form is
## present. See player_body.gd::_load_audio_dir for the full rationale.
func _load_audio_dir(path: String) -> Array[AudioStream]:
	var out: Array[AudioStream] = []
	var dir := DirAccess.open(path)
	if dir == null:
		push_warning("BouncyPlatform: audio auto-load dir missing: %s" % path)
		return out
	dir.list_dir_begin()
	var sources: Dictionary = {}
	while true:
		var f := dir.get_next()
		if f == "":
			break
		if dir.current_is_dir():
			continue
		var source_name: String = f
		if f.to_lower().ends_with(".import"):
			source_name = f.substr(0, f.length() - 7)
		var lower_src: String = source_name.to_lower()
		if lower_src.ends_with(".wav") or lower_src.ends_with(".ogg") or lower_src.ends_with(".mp3"):
			sources[source_name] = true
	dir.list_dir_end()
	var files: Array = sources.keys()
	files.sort()
	for f: String in files:
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

func _eff_spring_overshoot_amplitude() -> float:
	return spring_overshoot_amplitude if is_nan(_override_spring_overshoot_amplitude) else _override_spring_overshoot_amplitude


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
	_override_spring_overshoot_amplitude = spring_overshoot_amplitude
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
	dp.call(&"add_slider", "Bouncy/spring_overshoot", 0.0, 2.0, 0.05,
		func() -> float: return _override_spring_overshoot_amplitude,
		func(v: float) -> void: _override_spring_overshoot_amplitude = v,
		"bouncy_platform.gd")


func _apply_palette() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"palette_black", palette_base)
	_material.set_shader_parameter(&"palette_purple", palette_highlight)


func _apply_size() -> void:
	if _box != null:
		_box.size = size
	# Hand-authored StaticBody3D / BoxShape3D collider sized to match the
	# visible box. Replaces the prefab's old reliance on CSG auto-collision
	# (which was being baked once by csg_collider_swap.gd at level _ready
	# and then frozen — leading to size mismatches when the platform was
	# resized in the inspector). The shape resource is local-to-scene so
	# resizing one instance never bleeds into others.
	if _body_shape != null and _body_shape.shape is BoxShape3D:
		var body_box: BoxShape3D = _body_shape.shape as BoxShape3D
		body_box.size = size
	if _carry_shape != null and _carry_shape.shape is BoxShape3D:
		var carry_box: BoxShape3D = _carry_shape.shape as BoxShape3D
		# Thin slab sitting just above the deck top so landing-from-above
		# triggers entry, but jumping up underneath does not.
		carry_box.size = Vector3(size.x, 0.6, size.z)
		_carry_shape.position.y = size.y * 0.5 + 0.3


func _on_body_entered(body: Node) -> void:
	if _carried_body != null:
		print("[bouncy] enter SKIPPED %s — mid-squash carrying %s" % [body, _carried_body])
		return  # mid-squash already; ignore secondary entries.
	if Time.get_ticks_msec() < _post_launch_lockout_until_msec:
		# Same-frame re-entry caused by the spring-back overshoot catching
		# up to the still-on-the-deck capsule. Refusing here keeps the
		# chain state intact across actual bounces.
		print("[bouncy] enter IGNORED %s — post-launch lockout (%dms left)" %
			[body, _post_launch_lockout_until_msec - Time.get_ticks_msec()])
		return
	# Any CharacterBody3D bounces — player AND sentinels.
	if not (body is CharacterBody3D):
		return
	# Chain decision (trampoline model, airtime-bounded):
	#   - If this is the SAME body that bounced last AND jump was pressed
	#     at any point since the last launch (OR is currently held),
	#     chain_count += 1 — bonus stacks.
	#   - Otherwise reset to 0. Initial land (different body or chain_body
	#     null) NEVER gets a bonus regardless of input — "subsequent only."
	var now_msec: int = Time.get_ticks_msec()
	var buffer_dt_msec: int = now_msec - _last_jump_press_msec
	var jump_held: bool = Input.is_action_pressed(&"jump")
	var jump_buffered: bool = _jump_pressed_since_launch or jump_held
	var continuing: bool = (body == _chain_body)
	if continuing and jump_buffered:
		_chain_count += 1
	else:
		_chain_count = 0
	print("[bouncy] land chain=%d continuing=%s buffered=%s (held=%s, since_launch=%s, dt=%dms)" %
		[_chain_count, continuing, jump_buffered, jump_held,
		 _jump_pressed_since_launch, buffer_dt_msec])
	_carried_body = body as Node3D
	# Capture body's REAL parent BEFORE queuing the reparent. Defensive
	# guard: if for some reason the body is already a child of _deck (the
	# cascade bug observed in the logs), refuse to use _deck as "original"
	# — that'd make _restore_parent a no-op forever. Fall back to the
	# current scene root, which is guaranteed to be a real world parent.
	var captured_parent: Node = body.get_parent()
	if captured_parent == _deck:
		captured_parent = get_tree().current_scene
		print("[bouncy] _original_parent contaminated as _deck — using scene root %s" % captured_parent)
	_original_parent = captured_parent
	body.call_deferred(&"reparent", _deck, true)
	# Lock out spurious exits for the duration of the squash + a safety
	# margin to cover physics-tick alignment slop after the launch fires.
	_squash_commit_until_msec = Time.get_ticks_msec() + int(_eff_squash_duration() * 1000.0) + 100
	_start_bounce()


func _on_body_exited(body: Node) -> void:
	# Squash-commit gate: physics jitter during the deck dip routinely
	# flips body overlap with the fixed CarryZone trigger. The bounce is
	# a committed event — once started, we ride it through to _launch.
	# Exits in this window are spurious; ignore them entirely so the
	# bounce isn't reset/restarted.
	if Time.get_ticks_msec() < _squash_commit_until_msec:
		print("[bouncy] exit %s IGNORED (mid-squash commit)" % body)
		return
	print("[bouncy] exit %s (carried=%s)" % [body, _carried_body])
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
	# Suppress the body's normal jump briefly so the buffered chain press
	# doesn't double-fire as a regular jump alongside the bounce.
	if _carried_body != null and _carried_body.has_method(&"suppress_jump_for"):
		_carried_body.suppress_jump_for(_eff_squash_duration() + 0.15)
	var depth: float = _eff_squash_depth()
	_tween = create_tween()
	_tween.tween_property(_deck, ^"position:y", _deck_base_y - depth, _eff_squash_duration()) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(_launch)
	# Manual decaying-overshoot spring. Replaces TRANS_ELASTIC because Godot's
	# built-in elastic has fixed amplitude — overshoot was barely visible
	# against squash_depth. Five segments: snap above base by full amplitude,
	# then oscillate around base with halving amplitude until settled. Same
	# total duration as before; ringing is now genuinely dramatic.
	var overshoot: float = _eff_spring_overshoot_amplitude()
	var spring_dur: float = _eff_spring_duration()
	if overshoot <= 0.0:
		# Disabled — smooth ease to base, no ringing.
		_tween.tween_property(_deck, ^"position:y", _deck_base_y, spring_dur) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	else:
		var seg: float = spring_dur * 0.20
		_tween.tween_property(_deck, ^"position:y", _deck_base_y + overshoot, seg) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_tween.tween_property(_deck, ^"position:y", _deck_base_y - overshoot * 0.5, seg) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_property(_deck, ^"position:y", _deck_base_y + overshoot * 0.25, seg) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_property(_deck, ^"position:y", _deck_base_y - overshoot * 0.12, seg) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_property(_deck, ^"position:y", _deck_base_y, seg) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)


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
	# Bouncing off the deck IS leaving the surface — same as a jump. Force
	# the body's halfpipe state to disengage so up_direction / floor_max_angle
	# / tilted basis don't survive the launch and pull the bounce back
	# toward the wall mid-flight.
	if body.has_method(&"force_halfpipe_disengage"):
		body.call(&"force_halfpipe_disengage")
	if "velocity" in body:
		var v: Vector3 = body.get(&"velocity")
		# Trampoline chain bonus: chain_count is the number of successful
		# boost presses in a row. Each adds one boost_velocity to launch.
		# No cap — by chain 10 you're launching at +70 m/s on top of base.
		var chain_bonus: float = float(_chain_count) * bounce_boost_velocity
		body.set(&"velocity", Vector3(v.x, launch_v + chain_bonus, v.z))
		if _chain_count > 0:
			print("[bouncy] chain %d → launch %.1f + bonus %.1f = %.1f m/s" %
				[_chain_count, launch_v, chain_bonus, launch_v + chain_bonus])
	# Track who holds the chain (so a different body landing resets).
	_chain_body = body
	_carried_body = null
	_original_parent = null
	# Block re-entry for 200ms. The spring tween yanks the deck upward
	# fast enough to overlap the player's collision shape before they
	# rise out of CarryZone. Without this gate, the same-frame re-enter
	# fires _on_body_entered and a spurious "fresh land" resets chain.
	_post_launch_lockout_until_msec = Time.get_ticks_msec() + 200
	# Reset the press-since-launch flag now so the next airtime starts
	# clean. Player must press jump again between this launch and the
	# next land to keep the chain alive.
	_jump_pressed_since_launch = false


## Global jump-press listener. Sets _jump_pressed_since_launch so the
## chain decision in _on_body_entered knows "did you press jump while
## airborne (or just before landing)?" Reset on every _launch.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"jump"):
		_jump_pressed_since_launch = true
		_last_jump_press_msec = Time.get_ticks_msec()
		print("[input] SPACE pressed t=%dms (since_launch_flag→true)" % _last_jump_press_msec)


func _restore_parent() -> void:
	if _carried_body == null or not is_instance_valid(_carried_body):
		print("[bouncy] restore SKIPPED — no _carried_body")
		return
	var parent_before: Node = _carried_body.get_parent()
	if parent_before != _deck:
		print("[bouncy] restore SKIPPED — parent is %s not _deck" % parent_before)
		return
	if _original_parent == null or not is_instance_valid(_original_parent):
		print("[bouncy] restore SKIPPED — _original_parent invalid")
		return
	# Direct reparent (not deferred). _launch runs in a tween-idle callback,
	# not a signal traversal, so the usual "don't mutate the tree while a
	# signal iterates" hazard doesn't apply.
	_carried_body.reparent(_original_parent, true)
	print("[bouncy] reparent %s: %s → %s (now %s)" %
		[_carried_body.name, parent_before, _original_parent,
		 _carried_body.get_parent()])
