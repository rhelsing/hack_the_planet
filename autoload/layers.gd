extends Node

## Single source of truth for 3D physics layer assignments. Bitmask values
## suitable for direct assignment to collision_layer / collision_mask on
## CollisionObject3D nodes. Layer indices match the names registered in
## Project Settings → Layer Names → 3D Physics.
##
## See docs/interactables.md §10.1 for the assignment rationale.

const WORLD: int        = 1 << 0   # layer 1 — static level geometry, CSG
const PLAYER: int       = 1 << 1   # layer 2 — PlayerBody when pawn_group == "player"
const ENEMY: int        = 1 << 2   # layer 3 — PlayerBody when pawn_group == "enemies"
const INTERACTABLE: int = 1 << 9   # layer 10 — all Interactable subclasses
