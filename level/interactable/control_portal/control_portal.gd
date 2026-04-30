extends Node3D
class_name ControlPortal

## Stand-on conversion platform. While the player is standing on it, every
## hostile in the linked ConvertZone gets a one-shot 70% roll: pass → flip
## to gold (your ally with rollerblades), fail → stay red. Each body rolls
## at most once ever (re-standing won't re-roll losers). Step off → 1s
## debounce → every body THIS portal flipped to gold reverts to green
## permanently. Net effect: red-population siphons toward green over
## successive stand-on cycles, with a temporary gold-ally posse while
## standing.
##
## Conversion is zone-wired, not radial-from-portal: drop a designer-shaped
## Area3D (ConvertZone) anywhere in the level and link via convert_zone_id.

const _PLATFORM_MATERIAL: ShaderMaterial = preload("res://level/platforms.tres")
const _CONVERT_ZONE_SCRIPT: Script = preload("res://level/interactable/convert_zone/convert_zone.gd")

@export_group("Color")
@export var palette_base: Color = Color(0.05, 0.05, 0.06, 1.0):
	set(value):
		palette_base = value
		_apply_palette()
## Idle (grey) highlight. Tweens to `palette_active` while standing on.
@export var palette_highlight: Color = Color(0.4, 0.4, 0.42, 1.0):
	set(value):
		palette_highlight = value
		if not _engaged:
			_apply_palette()
## Active (yellow) highlight. Tweens in on stand, out on revert.
@export var palette_active: Color = Color(1.0, 0.85, 0.10, 1.0)
## Seconds for the grey ↔ yellow palette tween.
@export var activate_duration: float = 0.5

@export_group("Shape")
@export var size: Vector3 = Vector3(4.0, 0.4, 4.0):
	set(value):
		size = value
		_apply_size()

@export_group("Conversion")
## Factions eligible for the 70% roll. Pawns whose current faction is NOT
## in this list are ignored. Default = reds only — greens are already
## neutral, splice_stealth has its own kill path.
@export var target_factions: Array[StringName] = [&"red"]
## Faction matched pawns get flipped to while the player stands. Defaults
## to gold (your rollerblade ally posse).
@export var resulting_faction: StringName = &"gold"
## Faction the gold ones revert to when the player steps off + debounce
## expires. Defaults to green — the platform permanently downgrades reds
## to vanilla enemies, even though the gold ally state is temporary.
@export var revert_faction: StringName = &"green"
## Conversion-probability floor and ceiling — driven by the player's coin
## completion ratio. lerp(min, max, GameState.coin_completion_ratio()):
##   0 coins   → min_conversion_probability  (floor — earn nothing, get
##               this baseline anyway).
##   full coins → max_conversion_probability (full power — every red rolls
##               at this rate).
## One roll per body ever — losers stay red forever, winners stay gold-
## then-green. Re-evaluated at engage-time so picking up a coin between
## stands of the platform raises your odds.
@export_range(0.0, 1.0) var min_conversion_probability: float = 0.30
@export_range(0.0, 1.0) var max_conversion_probability: float = 0.80
## Seconds after the player steps off before reverting golds to green.
## Re-entering during this window cancels the revert.
@export var revert_debounce: float = 1.0
## ID linking this portal to one or more ConvertZone nodes in the level.
@export var convert_zone_id: StringName = &""

@export_group("Gating")
## When non-empty, the platform is fully inert until this GameState flag
## is true: stays grey, no palette tween, no conversion roll. Engagement
## quietly ignores body_entered while gated. Used to lock a platform
## behind a hack/puzzle reveal — see Level 4 Glitch's invention.
@export var require_flag: StringName = &""
## When non-empty, sets this GameState flag = true the FIRST time the
## player engages a non-gated platform. Fires once, persists via save.
## Used to downstream-gate dialogue / HUD on first-use of the platform —
## see Level 4 Glitch's `~ post_solve` celebration on l4_invention_terminal_solved.
@export var done_flag: StringName = &""

@export_group("SFX")
## Played once when the player first steps on (any-time replay disabled).
@export var activation_sound: AudioStream

@onready var _deck: Node3D = $Deck
@onready var _box: CSGBox3D = $Deck/Box
@onready var _trigger: Area3D = $Trigger
@onready var _trigger_shape: CollisionShape3D = $Trigger/Shape

var _material: ShaderMaterial = null
var _engaged: bool = false  # player currently standing on
var _sfx_player: AudioStreamPlayer3D = null
# Per-body roll outcomes — sticky for the lifetime of this portal instance.
# Keyed by NodePath string. Value: true = won the roll (currently or formerly
# gold), false = lost the roll (stays red forever).
var _rolled: Dictionary = {}
# Bodies currently flipped to gold by THIS portal. Cleared on revert.
var _active_gold: Array[Node] = []
# Counts down while not engaged + has pending revert. Re-entering trigger
# clears it without firing the revert.
var _debounce_timer: float = -1.0


func _ready() -> void:
	_material = _PLATFORM_MATERIAL.duplicate() as ShaderMaterial
	_box.material_override = _material
	_apply_palette()
	_apply_size()
	_sfx_player = AudioStreamPlayer3D.new()
	_sfx_player.bus = &"SFX"
	_sfx_player.unit_size = 6.0
	_sfx_player.max_distance = 35.0
	_deck.add_child(_sfx_player)
	_trigger.body_entered.connect(_on_body_entered)
	_trigger.body_exited.connect(_on_body_exited)


func _process(delta: float) -> void:
	if _debounce_timer < 0.0:
		return
	_debounce_timer -= delta
	if _debounce_timer <= 0.0:
		_debounce_timer = -1.0
		_apply_revert()


func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	# Locked platforms stay grey + don't fire activation/conversion. The
	# player can still physically stand on them; they just don't do anything.
	if require_flag != &"" and not bool(GameState.get_flag(require_flag, false)):
		return
	# First non-gated engagement fires done_flag once. Persists via GameState
	# so dialogue gates / HUD beats can react on subsequent reads.
	if done_flag != &"" and not bool(GameState.get_flag(done_flag, false)):
		GameState.set_flag(done_flag, true)
	# Cancel any pending revert — player came back before debounce expired.
	_debounce_timer = -1.0
	if _engaged:
		return
	_engaged = true
	_tween_palette(palette_active)
	if activation_sound != null and _sfx_player != null:
		_sfx_player.stream = activation_sound
		_sfx_player.play()
	_apply_conversion()


func _on_body_exited(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	# Tolerate jitter: only react if the player isn't still overlapping the
	# trigger (multiple shapes / re-entries can fire body_exited spuriously).
	if _trigger.overlaps_body(body):
		return
	if not _engaged:
		return
	_engaged = false
	_tween_palette(palette_highlight)
	# Schedule the revert if there's anyone to revert. Empty fast-path keeps
	# the timer dormant so we don't tick _process needlessly.
	if not _active_gold.is_empty():
		_debounce_timer = revert_debounce


# Walk every ConvertZone matching convert_zone_id, find every PlayerBody
# overlapping any of them whose faction is in target_factions and which
# hasn't been rolled before. Roll 70% per body. Pass → flip to gold +
# remember; fail → mark rolled + skip. Sticky outcomes — re-engagement
# only catches bodies that weren't in the zone last time.
func _apply_conversion() -> void:
	if convert_zone_id == &"":
		return
	var seen: Dictionary = {}
	var zones: Array = _CONVERT_ZONE_SCRIPT.call(&"zones_for", convert_zone_id) as Array
	var prob: float = lerp(min_conversion_probability, max_conversion_probability, GameState.coin_completion_ratio())
	for zone in zones:
		if not (zone is Area3D):
			continue
		for body in (zone as Area3D).get_overlapping_bodies():
			if seen.has(body):
				continue
			seen[body] = true
			if not body.has_method(&"set_faction"):
				continue
			var path_key: String = String(body.get_path())
			var current_faction: StringName = StringName(body.get(&"faction"))
			if _rolled.has(path_key):
				# Already rolled. Winners get re-imprinted to gold every time
				# the player stands on the platform — they "remember" being
				# converted. Losers (failed the original roll) stay red
				# forever, even if the player re-steps. This preserves the
				# "no farming" rule: each body has exactly one outcome,
				# determined the first time they were exposed to the portal.
				if _rolled[path_key] and current_faction == revert_faction:
					body.call(&"set_faction", resulting_faction)
					_active_gold.append(body)
				continue
			# First exposure — only eligible if currently a target faction.
			if not (current_faction in target_factions):
				continue
			var passed: bool = randf() < prob
			_rolled[path_key] = passed
			if passed:
				body.call(&"set_faction", resulting_faction)
				_active_gold.append(body)


# Debounce expired with the player still off the platform: every body
# THIS portal flipped to gold reverts to revert_faction (green). Bodies
# that died / were freed in the interim are skipped.
func _apply_revert() -> void:
	for body in _active_gold:
		if not is_instance_valid(body):
			continue
		if not body.has_method(&"set_faction"):
			continue
		body.call(&"set_faction", revert_faction)
	_active_gold.clear()


func _tween_palette(target: Color) -> void:
	var tween := create_tween()
	tween.tween_method(_set_highlight_color, _current_highlight_color(), target, activate_duration)


func _current_highlight_color() -> Color:
	if _material == null:
		return palette_highlight
	var c: Variant = _material.get_shader_parameter(&"palette_purple")
	if c is Color:
		return c as Color
	return palette_highlight


func _set_highlight_color(c: Color) -> void:
	if _material != null:
		_material.set_shader_parameter(&"palette_purple", c)


func _apply_palette() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"palette_black", palette_base)
	_material.set_shader_parameter(&"palette_purple",
		palette_active if _engaged else palette_highlight)


func _apply_size() -> void:
	if _box != null:
		_box.size = size
	if _trigger_shape != null and _trigger_shape.shape is BoxShape3D:
		var trigger_box: BoxShape3D = _trigger_shape.shape as BoxShape3D
		trigger_box.size = Vector3(size.x, 0.6, size.z)
		_trigger_shape.position.y = size.y * 0.5 + 0.3
