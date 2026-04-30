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
	if forbid_enemy_jump:
		# Tag every overlapping body with a refcounted "jump inhibit" meta
		# while they're inside this zone. enemy_ai_brain reads the meta and
		# skips ALL jump-decision logic for the tick — they don't even
		# enter the jump-considering code path. Refcount handles stacked
		# zones correctly: only fully clears on exit from the last one.
		body_entered.connect(_on_body_entered_forbid)
		body_exited.connect(_on_body_exited_forbid)
	if id == &"":
		return
	var arr: Array = _registry.get(id, [])
	arr.append(self)
	_registry[id] = arr


func _on_body_entered_forbid(body: Node) -> void:
	if body == null:
		return
	var count: int = int(body.get_meta(&"jump_inhibit_count", 0))
	body.set_meta(&"jump_inhibit_count", count + 1)


func _on_body_exited_forbid(body: Node) -> void:
	if body == null:
		return
	var count: int = int(body.get_meta(&"jump_inhibit_count", 0))
	body.set_meta(&"jump_inhibit_count", maxi(0, count - 1))


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


## Returns true if `body` is currently inside one or more ConvertZones with
## forbid_enemy_jump=true. Reads a refcount meta tag set by body_entered /
## body_exited handlers — no per-tick zone iteration. enemy_ai_brain calls
## this once at the top of jump-decision branches; the body itself "knows"
## it can't jump while inside a forbid zone.
static func is_jump_forbidden_for(body: Node) -> bool:
	if body == null:
		return false
	return int(body.get_meta(&"jump_inhibit_count", 0)) > 0
