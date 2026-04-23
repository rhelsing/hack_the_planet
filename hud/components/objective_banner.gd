extends VBoxContainer
## Top-center level-name + objective banner. Subscribes to SceneLoader and
## reads `hud_level_title` / `hud_level_objective` off the scene root. If
## either field is absent or empty, the banner stays hidden for that scene.
##
## Self-revealing: when a scene with a title enters, the banner typewrites
## both lines, holds, fades out, and returns to hidden.

const TITLE_REVEAL_S := 0.6
const OBJ_REVEAL_S   := 0.5
const HOLD_S := 2.5
const FADE_S := 0.6

@onready var _title_label: RichTextLabel = %TitleLabel
@onready var _obj_label:   RichTextLabel = %ObjectiveLabel


func _ready() -> void:
	visible = false
	var loader := get_tree().root.get_node_or_null(^"SceneLoader")
	if loader != null and loader.has_signal(&"scene_entered"):
		loader.scene_entered.connect(_on_scene_entered)


func _on_scene_entered(scene: Node) -> void:
	if scene == null:
		return
	var title: String = _read_export(scene, &"hud_level_title")
	var objective: String = _read_export(scene, &"hud_level_objective")
	if title.is_empty():
		return
	_play(title, objective)


func _play(title: String, objective: String) -> void:
	_title_label.text = "[color=#00ffff]> %s[/color]" % title
	_obj_label.text   = "[color=#33ff66]%s[/color]" % objective
	_title_label.visible_ratio = 0.0
	_obj_label.visible_ratio   = 0.0
	_obj_label.visible = not objective.is_empty()
	modulate.a = 1.0
	visible = true

	var tw := create_tween()
	tw.tween_property(_title_label, "visible_ratio", 1.0, TITLE_REVEAL_S)
	if _obj_label.visible:
		tw.tween_property(_obj_label, "visible_ratio", 1.0, OBJ_REVEAL_S)
	tw.tween_interval(HOLD_S)
	tw.tween_property(self, "modulate:a", 0.0, FADE_S).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void:
		visible = false
	)


func _read_export(scene: Node, key: StringName) -> String:
	if key in scene:
		return String(scene.get(key))
	return ""
