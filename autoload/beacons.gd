extends Node

## World-space objective markers. Components register themselves at _ready
## and unregister at _exit_tree; the HUD's BeaconLayer iterates this list
## each frame to render the on-screen / off-screen indicators.
##
## See hud/components/beacon.gd for the per-target Node3D component and
## hud/components/beacon_layer.gd for the renderer.

signal added(beacon: Node)
signal removed(beacon: Node)
## Fired when a beacon transitions from hidden → visible (or registers
## while already visible). Distinct from `added`, which is purely about
## registration regardless of beacon_visible state. PlayerBrain uses this
## to kick a brief camera pan toward the closest visible beacon.
signal beacon_appeared(beacon: Node)

var _beacons: Array = []


func register(beacon: Node) -> void:
	if beacon in _beacons:
		return
	_beacons.append(beacon)
	added.emit(beacon)
	print("[beacons] register %s (count=%d)" % [beacon.name, _beacons.size()])


func unregister(beacon: Node) -> void:
	if not (beacon in _beacons):
		return
	_beacons.erase(beacon)
	removed.emit(beacon)
	print("[beacons] unregister %s (count=%d)" % [beacon.name, _beacons.size()])


## All currently-registered beacons, including hidden ones. Filter by
## `beacon.beacon_visible` (the component's runtime state) to render only
## active markers — kept here as a flat list so a future "scan all"
## minimap could iterate every known beacon.
func all() -> Array:
	return _beacons.duplicate()
