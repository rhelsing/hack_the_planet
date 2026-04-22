class_name CopRiotSkin
extends CharacterSkin

## Wraps the cop_riot GLB to conform to the CharacterSkin contract. The GLB
## only ships with Riot_Idle + Riot_Run, so jump/fall/attack/edge_grab/wall_slide
## fall back to Run — visually minimal but the body never crashes on a call.


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
	if _anim == null or not _anim.has_animation(clip):
		return
	if _anim.current_animation == clip and _anim.is_playing():
		return
	_anim.play(clip)


func idle() -> void: _play("Riot_Idle")
func move() -> void: _play("Riot_Run")
# The cop rig has no dedicated clips for these states — run is the best
# fallback (beats a rigid T-pose mid-jump).
func fall() -> void: _play("Riot_Run")
func jump() -> void: _play("Riot_Run")
func edge_grab() -> void: _play("Riot_Run")
func wall_slide() -> void: _play("Riot_Run")
func attack() -> void: _play("Riot_Run")
