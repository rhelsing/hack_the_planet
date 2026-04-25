class_name CompanionStation
extends Marker3D

## A future "stop" for a CompanionNPC. The companion ratchets through an
## ordered list of these — when the companion's current dialogue sets the
## current `advance_flag` on GameState, the companion elastic-tweens to
## this station's transform and adopts this station's dialogue + new
## advance_flag.
##
## Designer flow: drop a CompanionStation node into the level wherever the
## companion should next appear, set its dialogue_resource and advance_flag,
## then add its NodePath to the CompanionNPC's `stations` array.

@export var dialogue_resource: Resource
## Flag THIS station's dialogue sets on completion (via `do GameState.set_flag`).
## Triggers the next ratchet. Empty = terminal stop.
@export var advance_flag: StringName = &""
