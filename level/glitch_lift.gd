extends CSGBox3D

## One-shot vertical lift attached to Ground7 (Glitch's platform). Listens
## for `trigger_flag` on GameState; when it flips true, tweens this platform
## up to `destination_path`'s Y (or by `lift_height` if destination is unset)
## over `lift_duration`. Carries:
##   - the player, via the same reparent-trick used in level/elevator.gd
##     (CarryZone Area3D child detects entry/exit);
##   - the rider (typically Glitch), via direct global_position tween — he's
##     a sibling of this platform, not a child, so transform inheritance
##     doesn't carry him otherwise.
##
## After the lift completes, the rider adopts `post_lift_station_path`'s
## dialogue + advance_flag. The next CompanionNPC ratchet (e.g., to
## GlitchStation2) then fires when that new flag flips.

@export var lift_height: float = 7.0
@export var lift_duration: float = 3.0
@export var trigger_flag: StringName = &"glitch_lift_ready"
## If set, lift's destination Y comes from this Marker3D's world position
## (overrides lift_height).
@export_node_path("Marker3D") var destination_path: NodePath
## Sibling node lifted in lockstep with the platform (typically Glitch).
@export_node_path("Node3D") var rider_path: NodePath
## After the lift, the rider's dialogue_resource + advance_flag are set
## to this station's values — the rider effectively "arrives" at this
## station without using the elastic-tween ratchet.
@export_node_path("Marker3D") var post_lift_station_path: NodePath

var _carry_zone: Area3D = null
var _original_player_parent: Node = null
var _has_fired: bool = false


func _ready() -> void:
	_carry_zone = get_node_or_null(^"CarryZone") as Area3D
	if _carry_zone != null:
		_carry_zone.body_entered.connect(_on_carry_body_entered)
		_carry_zone.body_exited.connect(_on_carry_body_exited)
	Events.flag_set.connect(_on_flag_set)
	# Restore branch: if the trigger flag is already true on a load, the
	# lift has already played out — snap to the destination and adopt the
	# post-lift station data immediately so saves that landed past the
	# lift don't reset the platform back to the bottom.
	if bool(GameState.get_flag(trigger_flag, false)):
		_has_fired = true
		_snap_to_destination()
		print("[glitch_lift] restore: %s already true — snapped to dest" % trigger_flag)


func _on_flag_set(id: StringName, value: Variant) -> void:
	if _has_fired or not value:
		return
	if id != trigger_flag:
		return
	_has_fired = true
	_run_lift()


func _run_lift() -> void:
	var rider: Node3D = get_node_or_null(rider_path) as Node3D
	var dest_y: float = global_position.y + lift_height
	var dest_marker: Marker3D = get_node_or_null(destination_path) as Marker3D
	if dest_marker != null:
		dest_y = dest_marker.global_position.y
	var delta_y: float = dest_y - global_position.y
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "global_position:y", dest_y, lift_duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	if rider != null:
		tw.tween_property(rider, "global_position:y", rider.global_position.y + delta_y, lift_duration) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tw.chain().tween_callback(_on_lift_finished)


func _on_lift_finished() -> void:
	_adopt_post_lift_station()


func _adopt_post_lift_station() -> void:
	var rider: Node = get_node_or_null(rider_path)
	var station: CompanionStation = get_node_or_null(post_lift_station_path) as CompanionStation
	if rider == null or station == null:
		return
	if "dialogue_resource" in rider:
		rider.set("dialogue_resource", station.dialogue_resource)
	if "advance_flag" in rider:
		rider.set("advance_flag", station.advance_flag)


func _snap_to_destination() -> void:
	var dest_marker: Marker3D = get_node_or_null(destination_path) as Marker3D
	if dest_marker == null:
		return
	var dest_y: float = dest_marker.global_position.y
	var delta_y: float = dest_y - global_position.y
	global_position.y = dest_y
	var rider: Node3D = get_node_or_null(rider_path) as Node3D
	if rider != null:
		rider.global_position.y += delta_y
	# Adopt synchronously — Ground7._ready fires BEFORE Glitch._ready
	# (sibling tree order), so setting Glitch's advance_flag here lets
	# CompanionNPC._restore_progress see the right value when it runs and
	# ratchet forward if subsequent flags (e.g., glitch_grind_done) are
	# also already set in this saved session.
	_adopt_post_lift_station()


func _on_carry_body_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	if body.get_parent() == self:
		return
	_original_player_parent = body.get_parent()
	body.call_deferred(&"reparent", self, true)


func _on_carry_body_exited(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	if body.get_parent() != self:
		return
	if _original_player_parent == null or not is_instance_valid(_original_player_parent):
		return
	body.call_deferred(&"reparent", _original_player_parent, true)
