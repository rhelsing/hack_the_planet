class_name NavBakeResult
extends Resource

## Offline nav-bake artifact for one level: the baked navmesh plus the
## generated jump/drop link table. Produced by tools/bake_nav.sh (or the
## NavRegion's bake_now inspector button); consumed by nav_region_bake.gd at
## level load so runtime never bakes. Lives at level/nav/baked/<level>.res —
## level .tscn files are never rewritten by the bake.

@export var mesh: NavigationMesh
@export var link_starts: PackedVector3Array
@export var link_ends: PackedVector3Array
@export var link_bidirectional: Array[bool] = []
## Capability tier per link (NavLayers bit values). Absent entries (older
## sidecars) default to NavLayers.WALK on apply.
@export var link_layers: PackedInt32Array = PackedInt32Array()
