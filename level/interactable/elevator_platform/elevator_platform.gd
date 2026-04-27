extends Node3D
class_name ElevatorPlatform

## Vertical elevator with the platforms shader + overrideable palette colors
## (default teal). Same rise/hold/fall/hold cycle as `level/elevator.gd` —
## adapted into the bouncy/crumble family layout (Node3D root + Deck child)
## so all palette-overrideable platforms share a skeleton.
##
## Carries the player via Godot 4's `AnimatableBody3D`. The deck IS the
## kinematic body — we set `position.y` per frame and the engine derives
## platform velocity, which `CharacterBody3D.move_and_slide()` inherits via
## `get_platform_velocity()`. No reparent trick: the body never has its
## parent rewired, which means descent (where the deck moves down faster
## than gravity) doesn't cause the local-offset drift that the reparent
## approach hit on long fall_durations.

const _PLATFORM_MATERIAL: ShaderMaterial = preload("res://level/platforms.tres")

@export_group("Color")
@export var palette_base: Color = Color(0.0, 0.04, 0.04, 1.0):
	set(value):
		palette_base = value
		_apply_palette()
@export var palette_highlight: Color = Color(0.05, 0.85, 0.85, 1.0):
	set(value):
		palette_highlight = value
		_apply_palette()

@export_group("Shape")
@export var size: Vector3 = Vector3(8.0, 1.0, 8.0):
	set(value):
		size = value
		_apply_size()

@export_group("Cycle")
## Climb height in meters. Deck rises this much above its base position at
## the peak of the cycle.
@export var amplitude: float = 10.0
@export var rise_duration: float = 5.0
@export var peak_pause: float = 1.0
@export var fall_duration: float = 5.0
@export var trough_pause: float = 2.0
## 0..1 fraction of the total cycle to start phase-shifted. Use to stagger
## multiple instances so they don't lockstep.
@export_range(0.0, 1.0) var phase_offset: float = 0.0

@onready var _deck: AnimatableBody3D = $Deck
@onready var _visual: CSGBox3D = $Deck/Visual
@onready var _collision: CollisionShape3D = $Deck/CollisionShape3D

var _material: ShaderMaterial = null
var _deck_base_y: float = 0.0
var _t: float = 0.0


func _ready() -> void:
	_material = _PLATFORM_MATERIAL.duplicate() as ShaderMaterial
	_visual.material_override = _material
	_apply_palette()
	_apply_size()
	_deck_base_y = _deck.position.y


func _physics_process(delta: float) -> void:
	# Drive the deck in physics-process (not idle) so AnimatableBody3D's
	# velocity inference syncs with CharacterBody3D's move_and_slide tick.
	# Setting position on an AnimatableBody3D with sync_to_physics=true
	# (set in the .tscn) makes the engine compute platform velocity from
	# the per-frame delta and expose it to riders.
	_t += delta
	_deck.position.y = _deck_base_y + _offset()


# Cosine-blended rise / pause / fall / pause. Identical math to elevator.gd —
# kept inline rather than importing because the shape pattern differs and
# there's no other consumer to share with.
func _offset() -> float:
	var total: float = rise_duration + peak_pause + fall_duration + trough_pause
	if total <= 0.0:
		return 0.0
	var t: float = fposmod(_t + phase_offset * total, total)
	if t < rise_duration:
		return (1.0 - cos(PI * t / rise_duration)) * 0.5 * amplitude
	t -= rise_duration
	if t < peak_pause:
		return amplitude
	t -= peak_pause
	if t < fall_duration:
		return (1.0 + cos(PI * t / fall_duration)) * 0.5 * amplitude
	return 0.0


func _apply_palette() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"palette_black", palette_base)
	_material.set_shader_parameter(&"palette_purple", palette_highlight)


func _apply_size() -> void:
	if _visual != null:
		_visual.size = size
	if _collision != null and _collision.shape is BoxShape3D:
		var box: BoxShape3D = _collision.shape as BoxShape3D
		box.size = size
