class_name KayKitSkin
extends CharacterSkin

## Wraps a KayKit animation pack (default: Rig_Medium_General — Idle, Hit,
## Death, etc.). The General pack has Idle_A but no running/jumping, so
## move/jump/fall fall back to Idle_A. This is a proof-of-concept skin:
## polish later by merging MovementBasic animations via AnimationLibrary so
## Running_A can drive move() and Jump_Start drives jump().


@onready var _anim: AnimationPlayer = _find_anim_player(self)


func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c: Node in n.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null


func _play(clip: String) -> void:
	if _anim == null:
		return
	if not _anim.has_animation(clip):
		return
	if _anim.current_animation == clip and _anim.is_playing():
		return
	_anim.play(clip)


func idle() -> void: _play("Idle_A")
# No run clip in General pack — holds Idle_A. Future: AnimationLibrary merge
# pulls Running_A from MovementBasic and wires it in here.
func move() -> void: _play("Idle_A")
func fall() -> void: _play("Idle_A")
func jump() -> void: _play("Idle_A")
func edge_grab() -> void: _play("Idle_A")
func wall_slide() -> void: _play("Idle_A")
func attack() -> void: _play("Hit_A")
