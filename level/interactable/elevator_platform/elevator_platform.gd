extends Node3D
class_name ElevatorPlatform

## Vertical elevator with the platforms shader + overrideable palette colors
## (default yellow). Same rise/hold/fall/hold cycle as `level/elevator.gd` —
## adapted into the bouncy/crumble family layout (Node3D root + Deck child)
## so all palette-overrideable platforms share a skeleton.
##
## Reparent trick: when the player enters CarryZone they're parented under
## Deck so the lift carries them via parent transform inheritance, no
## per-frame velocity transfer. On exit, restored to their original parent.

const _PLATFORM_MATERIAL: ShaderMaterial = preload("res://level/platforms.tres")

@export_group("Color")
@export var palette_base: Color = Color(0.04, 0.03, 0.0, 1.0):
	set(value):
		palette_base = value
		_apply_palette()
@export var palette_highlight: Color = Color(1.0, 0.82, 0.08, 1.0):
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

@onready var _deck: Node3D = $Deck
@onready var _box: CSGBox3D = $Deck/Box
@onready var _carry_zone: Area3D = $CarryZone
@onready var _carry_shape: CollisionShape3D = $CarryZone/Shape

var _material: ShaderMaterial = null
var _deck_base_y: float = 0.0
var _t: float = 0.0
var _original_player_parent: Node = null


func _ready() -> void:
	_material = _PLATFORM_MATERIAL.duplicate() as ShaderMaterial
	_box.material_override = _material
	_apply_palette()
	_apply_size()
	_deck_base_y = _deck.position.y
	_carry_zone.body_entered.connect(_on_carry_body_entered)
	_carry_zone.body_exited.connect(_on_carry_body_exited)


func _process(delta: float) -> void:
	_t += delta
	_deck.position.y = _deck_base_y + _offset()


# Cosine-blended rise / pause / fall / pause. Identical math to elevator.gd —
# kept inline rather than importing because the shape pattern (Deck child)
# differs and there's no other consumer to share with.
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


func _on_carry_body_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	if body.get_parent() == _deck:
		return
	_original_player_parent = body.get_parent()
	body.call_deferred(&"reparent", _deck, true)


func _on_carry_body_exited(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	if body.get_parent() != _deck:
		return
	if _original_player_parent == null or not is_instance_valid(_original_player_parent):
		return
	body.call_deferred(&"reparent", _original_player_parent, true)


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
		# Carry slab: full deck footprint, 2m thick, centered 1m above the
		# deck top. Tall on purpose — the player capsule needs sustained
		# overlap during bunny-hops or jumps mid-ride, otherwise we'd fire
		# body_exited / re-enter and reparent on every hop, causing jitter.
		carry_box.size = Vector3(size.x, 2.0, size.z)
		_carry_shape.position.y = size.y * 0.5 + 1.0
