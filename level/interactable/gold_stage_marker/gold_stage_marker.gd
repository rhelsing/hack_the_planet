@tool
class_name GoldStageMarker extends Marker3D

## Position placeholder where a gold ally will be staged at the start of a
## cutscene. Drop one anywhere in a level and instance siblings of it as
## needed — every instance auto-registers with the group declared below,
## so the cutscene trigger can scoop them up at fire-time without
## per-marker wiring.
##
## Authoring: this is a scene so you can duplicate / instance one and have
## it pre-set with the right group registration. Edit pos in the inspector;
## that's it.

## Group every marker registers with on _ready. The cutscene trigger
## (PhoneBooth's gold-staging hook) iterates this group and spawns one
## gold pawn per marker. Distinct group per gameplay context if you ever
## need scene-specific staging — for now this one group covers L4.
const STAGE_GROUP: StringName = &"l4_gold_stage"


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	add_to_group(STAGE_GROUP)
