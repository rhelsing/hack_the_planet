extends SceneTree

## Proves universal_male_skin.tscn conforms to CharacterSkin and that the
## runtime animation-library merge populates the AnimationPlayer before the
## AnimationTree tries to consume clips.

var _failures: Array[String] = []
var _skin: Node = null
var _cs: CharacterSkin = null

func _init() -> void:
	var scene: PackedScene = load("res://player/skins/universal_male/universal_male_skin.tscn")
	if scene == null:
		_failures.append("could not load universal_male_skin.tscn")
		_finish()
		return

	_skin = scene.instantiate()
	if not (_skin is CharacterSkin):
		_failures.append("universal_male scene root doesn't extend CharacterSkin (got %s)" % _skin.get_class())
		_finish()
		return

	_cs = _skin as CharacterSkin
	if _cs.lean_pivot_height <= 0.0:
		_failures.append("lean_pivot_height should be > 0, got %s" % _cs.lean_pivot_height)
	if _cs.body_center_y <= 0.0:
		_failures.append("body_center_y should be > 0, got %s" % _cs.body_center_y)
	for m: String in ["idle", "move", "fall", "jump", "edge_grab", "wall_slide", "attack", "dash", "crouch", "die", "land", "on_hit"]:
		if not _cs.has_method(m):
			_failures.append("universal_male missing contract method: %s" % m)
	_cs.damage_tint = 5.0
	if _cs.damage_tint > 1.0:
		_failures.append("damage_tint should clamp to [0,1], got %s" % _cs.damage_tint)

	# Attach so _ready fires and the merge runs. Check the resulting library
	# has both base (UAL1) and merged (UAL2: Slide) clips.
	_skin.ready.connect(_on_skin_ready)
	root.add_child(_skin)

func _on_skin_ready() -> void:
	var anim: AnimationPlayer = _find_any_animation_player(_cs)
	if anim == null:
		_failures.append("universal_male skin has no AnimationPlayer")
	else:
		# Only clips actually referenced by the AnimationTree + required by
		# the idle cycle + attack/hit variants.
		var expected := [
			"Idle",                 # UAL1 base (Idle state)
			"Idle_FoldArms",        # UAL2 (idle cycle variant)
			"Jog_Fwd",              # UAL1 (Move / Run state)
			"Jump_Start",           # UAL1 (Jump state)
			"Jump",                 # UAL1 (Fall state, looping mid-air)
			"Jump_Land",            # UAL1 (Land state)
			"Crouch_Idle",          # UAL1 (Crouch state)
			"Roll",                 # UAL1 (Dash state)
			"Punch_Cross",          # UAL1 (EdgeGrab/attack)
			"Punch_Jab",            # UAL1 (attack variant)
			"Death01",              # UAL1 (Die state)
			"Hit_Chest",            # UAL1 (Hit state)
			"Hit_Head",             # UAL1 (hit variant)
			"Slide",                # UAL2 (WallSlide state)
		]
		for clip: String in expected:
			if not anim.has_animation(clip):
				_failures.append("merge missing expected clip: %s" % clip)
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
		print("PASS test_universal_male_skin_contract: universal_male conforms to CharacterSkin")
		quit(0)
	else:
		for f: String in _failures:
			printerr("FAIL test_universal_male_skin_contract: " + f)
		quit(1)
