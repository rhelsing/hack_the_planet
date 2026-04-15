@tool
class_name PhoneBooth extends Node3D


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var area: Area3D = get_node_or_null("Area3D")
	if area != null:
		area.body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if body is CharacterBody3D:
		Events.checkpoint_reached.emit(global_position)
