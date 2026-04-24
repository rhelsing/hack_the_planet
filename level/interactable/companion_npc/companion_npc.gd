extends DialogueTrigger

## Glitch (and any future hub companion). Inherits the press-to-talk + walk +
## cinematic camera flow from DialogueTrigger and adds a lazy "swivel toward
## the player" yaw on the Skin child so the model always reads as paying
## attention without requiring an animation state.

## Skin node to swivel. Rotated around Y only — pitch/roll are left alone so
## the rig stays upright and idle animations play untouched.
@export var swivel_target_path: NodePath = ^"Skin"
## Lerp rate (radians per second of catch-up). Lower = lazier swivel.
@export var swivel_speed: float = 3.5
## Don't bother rotating if the player is closer than this — avoids spinning
## like a top when the player walks through the NPC.
@export var min_track_distance: float = 0.6
## If non-empty, the NPC stays hidden + non-interactable until this flag is
## set on GameState. Used to chain reveals — e.g. Glitch2 only appears after
## Glitch1's dialogue ends ("glitch1_done" flag).
@export var visible_when_flag: StringName = &""
## If non-empty, the NPC scales away + becomes non-interactable when this
## flag is set. Lets a NPC "leave" via the same dialogue beat that summons
## a successor — e.g. Glitch1 vanishes when its own "glitch1_done" fires.
@export var hide_when_flag: StringName = &""
## Seconds for the scale-in / scale-out animation.
@export var presence_anim_duration: float = 0.5

# Skins built on the body system natively face +basis.z, so a yaw of
# atan2(dir.x, dir.z) points the basis.z axis at the target.
const _MODEL_FORWARD_OFFSET: float = 0.0

var _swivel: Node3D
var _player: Node3D = null


func _ready() -> void:
	super()
	_swivel = get_node_or_null(swivel_target_path) as Node3D
	_apply_initial_presence()
	if visible_when_flag != &"" or hide_when_flag != &"":
		Events.flag_set.connect(_on_flag_set)


# Snap to the right state at scene load — no animation. Animation only fires
# when a flag flips at runtime.
func _apply_initial_presence() -> void:
	if hide_when_flag != &"" and bool(GameState.get_flag(hide_when_flag, false)):
		_set_present_snap(false)
		return
	if visible_when_flag != &"" and not bool(GameState.get_flag(visible_when_flag, false)):
		_set_present_snap(false)
		return
	_set_present_snap(true)


func _set_present_snap(present: bool) -> void:
	visible = present
	monitoring = present
	monitorable = present
	if _swivel != null:
		_swivel.scale = Vector3.ONE if present else Vector3.ZERO


func _on_flag_set(id: StringName, value: Variant) -> void:
	if not value:
		return
	if id == hide_when_flag:
		_animate_leave()
	elif id == visible_when_flag:
		_animate_arrive()


func _animate_arrive() -> void:
	if _swivel == null:
		return
	visible = true
	monitoring = true
	monitorable = true
	_swivel.scale = Vector3.ZERO
	var tw := create_tween()
	tw.tween_property(_swivel, "scale", Vector3.ONE, presence_anim_duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _animate_leave() -> void:
	if _swivel == null:
		return
	# Disable interaction immediately so a frame-perfect press during the
	# fade can't re-open dialogue.
	monitoring = false
	monitorable = false
	var tw := create_tween()
	tw.tween_property(_swivel, "scale", Vector3.ZERO, presence_anim_duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void: visible = false)


func _process(delta: float) -> void:
	if _swivel == null:
		return
	if _player == null or not is_instance_valid(_player):
		_player = _find_player()
		if _player == null:
			return
	var to_player: Vector3 = _player.global_position - _swivel.global_position
	to_player.y = 0.0
	if to_player.length_squared() < min_track_distance * min_track_distance:
		return
	var target_yaw: float = atan2(to_player.x, to_player.z) + _MODEL_FORWARD_OFFSET
	var t: float = 1.0 - exp(-swivel_speed * delta)
	_swivel.rotation.y = lerp_angle(_swivel.rotation.y, target_yaw, t)


# Find the player by group; cached after first lookup until invalidated.
func _find_player() -> Node3D:
	for node in get_tree().get_nodes_in_group("player"):
		if node is Node3D:
			return node
	return null
