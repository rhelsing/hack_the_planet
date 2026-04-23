extends SceneTree

## Proves kaykit_skin.tscn conforms to CharacterSkin and that the runtime
## animation-library merge populates the AnimationPlayer before the
## AnimationTree tries to consume clips.

var _failures: Array[String] = []
var _skin: Node = null
var _cs: CharacterSkin = null

func _init() -> void:
	var scene: PackedScene = load("res://player/skins/kaykit/kaykit_skin.tscn")
	if scene == null:
		_failures.append("could not load kaykit_skin.tscn")
		_finish()
		return

	_skin = scene.instantiate()
	if not (_skin is CharacterSkin):
		_failures.append("kaykit scene root doesn't extend CharacterSkin (got %s)" % _skin.get_class())
		_finish()
		return

	_cs = _skin as CharacterSkin
	if _cs.lean_pivot_height <= 0.0:
		_failures.append("lean_pivot_height should be > 0, got %s" % _cs.lean_pivot_height)
	if _cs.body_center_y <= 0.0:
		_failures.append("body_center_y should be > 0, got %s" % _cs.body_center_y)
	for m: String in ["idle", "move", "fall", "jump", "edge_grab", "wall_slide", "attack", "dash", "crouch", "die", "land", "on_hit"]:
		if not _cs.has_method(m):
			_failures.append("kaykit missing contract method: %s" % m)
	_cs.damage_tint = 5.0
	if _cs.damage_tint > 1.0:
		_failures.append("damage_tint should clamp to [0,1], got %s" % _cs.damage_tint)

	# Attach so _ready fires and the merge runs. Check the resulting library
	# actually has both the base (Idle_A) and merged (Running_A, Punch_A,
	# Running_Strafe_Left) clips.
	_skin.ready.connect(_on_skin_ready)
	root.add_child(_skin)

func _on_skin_ready() -> void:
	var anim: AnimationPlayer = _find_any_animation_player(_cs)
	if anim == null:
		_failures.append("KayKit skin has no AnimationPlayer")
	else:
		var expected := [
			"Idle_A",                           # base
			"Idle_B",                           # base (cycled variant)
			"Running_A",                        # MovementBasic
			"Running_Strafe_Left",              # MovementAdvanced (tilt blend)
			"Running_Strafe_Right",             # MovementAdvanced
			"Melee_Unarmed_Attack_Punch_A",     # CombatMelee (attack)
			"Melee_Unarmed_Attack_Kick",        # CombatMelee (attack variant)
			"Jump_Start",                       # MovementBasic
			"Jump_Idle",                        # MovementBasic
			"Jump_Land",                        # MovementBasic (landing)
			"Crouching",                        # MovementAdvanced
			"Death_A",                          # General (die)
			"Hit_A",                            # General (on_hit)
			"Hit_B",                            # General (on_hit variant)
		]
		for clip: String in expected:
			if not anim.has_animation(clip):
				_failures.append("merge missing expected clip: %s" % clip)
	_finish()

# Standalone recursive walk — KayKitSkin used to expose _anim but no longer
# does; we rediscover the AnimationPlayer the same way the skin does.
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
		print("PASS test_kaykit_skin_contract: KayKit conforms to CharacterSkin")
		quit(0)
	else:
		for f: String in _failures:
			printerr("FAIL test_kaykit_skin_contract: " + f)
		quit(1)
