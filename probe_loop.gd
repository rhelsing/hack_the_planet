extends SceneTree

func _init() -> void:
	var scn: PackedScene = load("res://player/skins/anime_character/anime_character_skin.tscn")
	var inst := scn.instantiate()
	root.add_child(inst)
	# Wait one frame so _ready runs (which calls _force_loop_linear).
	await process_frame
	var ap: AnimationPlayer = _find_ap(inst)
	if ap == null:
		print("ERR: no AnimationPlayer")
		quit(1); return
	for clip_name: String in ["Dance", "Dance Body Roll", "Dance Charleston", "Victory", "Idle", "Walk"]:
		if not ap.has_animation(clip_name):
			print("%-22s  MISSING" % clip_name)
			continue
		var anim := ap.get_animation(clip_name)
		var mode_str := "?"
		match anim.loop_mode:
			Animation.LOOP_NONE: mode_str = "LOOP_NONE"
			Animation.LOOP_LINEAR: mode_str = "LOOP_LINEAR"
			Animation.LOOP_PINGPONG: mode_str = "LOOP_PINGPONG"
		print("%-22s  loop_mode=%s  length=%.2fs" % [clip_name, mode_str, anim.length])
	quit(0)

func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer: return n
	for c: Node in n.get_children():
		var r := _find_ap(c)
		if r != null: return r
	return null
