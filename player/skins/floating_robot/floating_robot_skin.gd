class_name FloatingRobotSkin
extends CharacterSkin

## Floating robot — Glitch's visual. Used as a companion_npc skin only (never
## driven by PlayerBody), so all CharacterSkin contract methods inherit the
## base no-ops. Plays its single hover loop forever via the GLB's own
## AnimationPlayer; companion_npc's Wave logic graceful-skips because the
## clip "Wave" doesn't exist on this rig.

const _HOVER_CLIP := &"Take 001"

## Playback rate for the hover loop. >1.0 plays faster; tune in the inspector.
@export var animation_speed: float = 1.8


func _ready() -> void:
	var ap := _find_anim_player(self)
	if ap == null:
		push_error("[floating_robot_skin] no AnimationPlayer under skin")
		return
	if not ap.has_animation(_HOVER_CLIP):
		push_error("[floating_robot_skin] missing clip '%s'" % _HOVER_CLIP)
		return
	ap.get_animation(_HOVER_CLIP).loop_mode = Animation.LOOP_LINEAR
	ap.speed_scale = animation_speed
	ap.play(_HOVER_CLIP)


func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c: Node in n.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null
