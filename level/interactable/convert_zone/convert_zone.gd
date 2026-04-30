extends Area3D
class_name ConvertZone

## Faction-conversion target zone. Drop one (or many) into a level scene,
## set `id` to match a hack terminal's or control portal's `convert_zone_id`,
## shape the CollisionShape3D to cover the room/courtyard. On trigger, the
## terminal/portal queries `ConvertZone.zones_for(id)` and converts every
## PlayerBody overlapping any matching zone.
##
## Supports 1-to-many: multiple zones can share an id (covering disjoint
## rooms a single hack should affect), and a single zone can be triggered
## by multiple terminals (less common but supported — the registry doesn't
## care who reads it). Self-registers in a static dict at _ready, unhooks
## on _exit_tree so scene swaps don't leak stale references.

## ID this zone responds to. Empty id = unregistered (silent). Set to a
## meaningful name like &"l2_lobby" or &"control_courtyard". Triggers
## reference this same id via their `convert_zone_id` export.
@export var id: StringName = &""

## When true, any enemy whose body overlaps this zone has its jump intent
## suppressed by enemy_ai_brain. Used to keep boss-arena reds grounded so
## they can't escape the platform-conversion siphon by jumping out — see
## Level 4 ConvertZone / ConvertZone2.
@export var forbid_enemy_jump: bool = false

# id → Array[ConvertZone]. Multiple zones with the same id are all queried.
static var _registry: Dictionary = {}


func _ready() -> void:
	if id == &"":
		return
	var arr: Array = _registry.get(id, [])
	arr.append(self)
	_registry[id] = arr


func _exit_tree() -> void:
	if id == &"":
		return
	var arr: Array = _registry.get(id, [])
	arr.erase(self)
	if arr.is_empty():
		_registry.erase(id)
	else:
		_registry[id] = arr


## Lookup zones by id. Returns an Array (possibly empty) of ConvertZone
## instances. Callers iterate and call get_overlapping_bodies() on each.
static func zones_for(zone_id: StringName) -> Array:
	if zone_id == &"":
		return []
	return _registry.get(zone_id, []) as Array


## Returns true if `body` overlaps any registered ConvertZone with
## forbid_enemy_jump=true. Walks every registered zone (id-agnostic) so a
## single forbid-jump zone applies regardless of which id it carries.
## Called per-frame from enemy_ai_brain when jump intent is about to fire —
## hot-path-safe: most ConvertZones default forbid=false so the inner
## overlaps_body() never runs.
static func is_jump_forbidden_for(body: Node) -> bool:
	if body == null:
		return false
	for arr: Array in _registry.values():
		for zone: ConvertZone in arr:
			if not zone.forbid_enemy_jump:
				continue
			if zone.overlaps_body(body):
				return true
	return false
