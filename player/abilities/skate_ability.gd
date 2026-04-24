class_name SkateAbility
extends Ability

## Flag mirror for the HUD + an auto-enable hook: the moment powerup_love
## flips true (fresh pickup or Continue-from-save where we didn't force
## walk mode), tell the body to switch to the skate profile so the player
## starts rolling immediately without having to press R.


func _ready() -> void:
	if ability_id == &"":
		ability_id = &"Skate"
	if powerup_flag == &"":
		powerup_flag = &"powerup_love"
	super._ready()


func _sync_from_flag() -> void:
	var was_owned := owned
	super._sync_from_flag()
	if owned and not was_owned:
		# Defer so PlayerBody._ready has time to set up _current_profile +
		# _skin on scene boot. The call is idempotent, so running it later
		# when skate is already on is a safe no-op.
		call_deferred(&"_auto_enable_skate")


func _auto_enable_skate() -> void:
	var body := _find_body()
	if body != null and body.has_method(&"set_profile_skate"):
		body.call(&"set_profile_skate")
