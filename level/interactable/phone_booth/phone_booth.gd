@tool
class_name PhoneBooth extends Node3D


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var area: Area3D = get_node_or_null("Area3D")
	if area != null:
		area.body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	# Only the player banks checkpoints — if an enemy wanders through a booth
	# it shouldn't move the player's respawn point to wherever the enemy was.
	if not body.is_in_group("player"):
		return
	Events.checkpoint_reached.emit(global_position)
