class_name NavLayers

## Navigation capability tiers (docs/nav_stack.md "Capability bits", now
## BUILT — first consumers: skating reds + skating gold allies).
##
## Links carry a tier in `navigation_layers`; each pawn's NavigationAgent3D
## carries a mask of the tiers it can traverse; A* simply never plans
## through links the pawn can't make. Granting a capability (rollerblades)
## = flipping the agent mask — routes re-plan automatically, no AI code.
## Jump strength is a bucket, never a per-creature mesh: apex is speed-
## independent, so tiers only widen HORIZONTAL reach.

## Base tier: the walkable mesh + links within the walking jump envelope.
const WALK: int = 1
## Long links only the skate-boosted jump envelope can cross.
const SKATE_JUMP: int = 2
## Agent mask for skating pawns (walk mesh + long links).
const WALK_AND_SKATE: int = 3
