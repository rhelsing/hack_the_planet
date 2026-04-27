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
