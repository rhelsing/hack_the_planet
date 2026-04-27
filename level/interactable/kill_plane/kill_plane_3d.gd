extends Area3D


func _ready() -> void:
	body_entered.connect(func (body_that_entered: PhysicsBody3D) -> void:
		# One-frame defer keeps physics callbacks clean (Godot warns against
		# mutating physics state inside body_entered). The overlaps_body check
		# is critical: between the entry and the deferred emit, the body may
		# have teleported out — most commonly the player respawning at a
		# checkpoint after a previous fall — and a stale emit would re-kill
		# them post-respawn. Drop those.
		await get_tree().process_frame
		if not is_instance_valid(body_that_entered):
			return
		if not overlaps_body(body_that_entered):
			return
		Events.kill_plane_touched.emit(body_that_entered)
	)
