extends Node3D
class_name ControlPortal

## One-shot conversion portal. Step on it (palette tweens grey → yellow),
## every PlayerBody currently inside the wired ConvertZone whose faction is
## in `target_factions` flips to `resulting_faction` (default gold). Allies
## then chase enemies in their detection radius and idle 3m from the player
## otherwise; the player can punch them dead via the friendly-fire rule on
## the player faction's attack_target_groups.
##
## Conversion is zone-wired, NOT radial-from-portal: drop a designer-shaped
## Area3D (ConvertZone) anywhere in the level the portal "controls". Pawns
## that enter the zone after activation are NOT auto-converted — this is a
## one-shot trigger, not a polling field.

const _PLATFORM_MATERIAL: ShaderMaterial = preload("res://level/platforms.tres")
# Preload by path so the class_name doesn't need to resolve at parse-time
# under SceneTree-mode tests (where class_name registries can be empty).
const _CONVERT_ZONE_SCRIPT: Script = preload("res://level/interactable/convert_zone/convert_zone.gd")

@export_group("Color")
@export var palette_base: Color = Color(0.05, 0.05, 0.06, 1.0):
	set(value):
		palette_base = value
		_apply_palette()
## Idle (grey) highlight. Tweens to `palette_active` on activation.
@export var palette_highlight: Color = Color(0.4, 0.4, 0.42, 1.0):
	set(value):
		palette_highlight = value
		if not _activated:
			_apply_palette()
## Active (yellow) highlight. Used after the portal triggers.
@export var palette_active: Color = Color(1.0, 0.85, 0.10, 1.0)
## Seconds for the grey → yellow tween on activation.
@export var activate_duration: float = 0.5

@export_group("Shape")
@export var size: Vector3 = Vector3(4.0, 0.4, 4.0):
	set(value):
		size = value
		_apply_size()

@export_group("Conversion")
## Factions eligible for conversion. Pawns whose current faction is NOT in
## this list are ignored — keeps the player from accidentally flipping
## allies they already converted.
@export var target_factions: Array[StringName] = [&"green", &"red"]
## Faction matched pawns get flipped to. Defaults to gold (player allies).
@export var resulting_faction: StringName = &"gold"
## ID linking this portal to one or more ConvertZone nodes in the level.
## Empty (default) = no-op. Drop ConvertZone scenes wherever you want the
## conversion to apply, set their `id` to match this. Many zones can share
## an id (a single portal flipping enemies in multiple rooms at once).
@export var convert_zone_id: StringName = &""
## GameState flag that records whether this portal was activated. Empty =
## no persistence (re-activates on every load). Set to a unique string
## like &"l3_control_north" so reloading a level where the portal was
## already triggered keeps enemies converted + palette yellow.
@export var persistence_id: StringName = &""

@export_group("SFX")
@export var activation_sound: AudioStream

@onready var _deck: Node3D = $Deck
@onready var _box: CSGBox3D = $Deck/Box
@onready var _trigger: Area3D = $Trigger
@onready var _trigger_shape: CollisionShape3D = $Trigger/Shape

var _material: ShaderMaterial = null
var _activated: bool = false
var _sfx_player: AudioStreamPlayer3D = null


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
	# Restore prior activation: if the player triggered this portal in a
	# previous session AND we have a persistence_id, snap to the activated
	# visual state and replay the conversion so enemies respawn already
	# converted instead of as their authored faction. GameState looked up
	# via /root rather than the global identifier so this script compiles
	# under SceneTree-mode tests (autoloads not registered there).
	if persistence_id != &"":
		var gs: Node = get_tree().root.get_node_or_null(^"GameState")
		if gs != null and bool(gs.call(&"get_flag", persistence_id, false)):
			_activated = true
			_set_highlight_color(palette_active)
			_replay_conversion_on_load.call_deferred()


# Wait one physics frame so the ConvertZone's overlapping_bodies query
# can populate (enemies' physics need a tick to register), then re-run
# the same conversion the live activation would have. Idempotent.
func _replay_conversion_on_load() -> void:
	await get_tree().physics_frame
	_apply_conversion()


func _on_body_entered(body: Node) -> void:
	if _activated:
		return
	if not body.is_in_group("player"):
		return
	_activate()


func _activate() -> void:
	_activated = true
	# Palette tween grey → yellow. Drives both shader uniforms in step so
	# the highlight color rises while the base stays dark.
	var tween := create_tween()
	tween.tween_method(_set_highlight_color, palette_highlight, palette_active, activate_duration)
	if activation_sound != null and _sfx_player != null:
		_sfx_player.stream = activation_sound
		_sfx_player.play()
	_apply_conversion()
	# Persist for save-restore. Empty persistence_id = no save (portal re-
	# activates on every fresh load, useful for pure-test placements).
	# Same /root lookup as _ready for SceneTree-mode test compatibility.
	if persistence_id != &"":
		var gs: Node = get_tree().root.get_node_or_null(^"GameState")
		if gs != null:
			gs.call(&"set_flag", persistence_id, true)


func _set_highlight_color(c: Color) -> void:
	if _material != null:
		_material.set_shader_parameter(&"palette_purple", c)


# Walk every ConvertZone matching convert_zone_id, flip every PlayerBody
# overlapping any of them whose faction is in target_factions to
# resulting_faction. One-shot — pawns that enter the zone later aren't
# picked up. Multiple zones can share an id (1 portal → many regions).
func _apply_conversion() -> void:
	if convert_zone_id == &"":
		return
	var seen: Dictionary = {}
	var zones: Array = _CONVERT_ZONE_SCRIPT.call(&"zones_for", convert_zone_id) as Array
	for zone in zones:
		if not (zone is Area3D):
			continue
		for body in (zone as Area3D).get_overlapping_bodies():
			if seen.has(body):
				continue
			seen[body] = true
			# Duck-type so this script compiles in SceneTree-mode tests
			# without forcing the PlayerBody class import.
			if not body.has_method(&"set_faction"):
				continue
			var current_faction: StringName = StringName(body.get(&"faction"))
			if current_faction in target_factions:
				body.call(&"set_faction", resulting_faction)


func _apply_palette() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"palette_black", palette_base)
	_material.set_shader_parameter(&"palette_purple",
		palette_active if _activated else palette_highlight)


func _apply_size() -> void:
	if _box != null:
		_box.size = size
	if _trigger_shape != null and _trigger_shape.shape is BoxShape3D:
		var trigger_box: BoxShape3D = _trigger_shape.shape as BoxShape3D
		trigger_box.size = Vector3(size.x, 0.6, size.z)
		_trigger_shape.position.y = size.y * 0.5 + 0.3
