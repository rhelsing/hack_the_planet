extends SceneTree

## Proves anime_character_skin.tscn conforms to CharacterSkin and that the
## rig GLB ships every clip referenced by the AnimationTree state machine.
## All 24 clips live inside the model GLB — no extra_animation_sources merge.

var _failures: Array[String] = []
var _skin: Node = null
var _cs: CharacterSkin = null

func _init() -> void:
	var scene: PackedScene = load("res://player/skins/anime_character/anime_character_skin.tscn")
	if scene == null:
		_failures.append("could not load anime_character_skin.tscn")
		_finish()
		return

	_skin = scene.instantiate()
	if not (_skin is CharacterSkin):
		_failures.append("anime_character scene root doesn't extend CharacterSkin (got %s)" % _skin.get_class())
		_finish()
		return

	_cs = _skin as CharacterSkin
	if _cs.lean_pivot_height <= 0.0:
		_failures.append("lean_pivot_height should be > 0, got %s" % _cs.lean_pivot_height)
	if _cs.body_center_y <= 0.0:
		_failures.append("body_center_y should be > 0, got %s" % _cs.body_center_y)
	for m: String in ["idle", "move", "fall", "jump", "edge_grab", "wall_slide", "attack", "dash", "crouch", "die", "land", "on_hit"]:
		if not _cs.has_method(m):
			_failures.append("anime_character missing contract method: %s" % m)
	_cs.damage_tint = 5.0
	if _cs.damage_tint > 1.0:
		_failures.append("damage_tint should clamp to [0,1], got %s" % _cs.damage_tint)

	_skin.ready.connect(_on_skin_ready)
	root.add_child(_skin)

func _on_skin_ready() -> void:
	var anim: AnimationPlayer = _find_any_animation_player(_cs)
	if anim == null:
		_failures.append("anime_character skin has no AnimationPlayer")
	else:
		# Clips referenced by the AnimationTree + idle/attack/hit variants.
		var expected := [
			"Idle",                 # Idle state + cycle base
			"Idle_Talking",         # idle cycle variant
			"Idle Listening",       # idle cycle variant (note the space)
			"Jog_Fwd",              # Move / Run / RunTiltL/R
			"Jump_Start",           # Jump state
			"Jump",                 # Fall state (looping mid-air pose)
			"Jump_Land",            # Land state
			"Crouch_Fwd",           # Crouch state
			"Roll",                 # Dash state
			"Fighting Left Jab",    # EdgeGrab/attack default + variant
			"Fighting Right Jab",   # attack variant
			"Death01",              # Die state
			"Hit_Chest",            # Hit state default + variant
			"Hit_Knockback",        # hit variant
			"Slide",                # WallSlide state
		]
		for clip: String in expected:
			if not anim.has_animation(clip):
				_failures.append("rig GLB missing expected clip: %s" % clip)
	_finish()

func _find_any_animation_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c: Node in n.get_children():
		var r := _find_any_animation_player(c)
		if r != null:
			return r
	return null

func _finish() -> void:
	if _skin != null:
		_skin.queue_free()
	if _failures.is_empty():
		print("PASS test_anime_character_skin_contract: anime_character conforms to CharacterSkin")
		quit(0)
	else:
		for f: String in _failures:
			printerr("FAIL test_anime_character_skin_contract: " + f)
		quit(1)
