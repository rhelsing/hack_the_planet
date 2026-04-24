extends CanvasLayer

## Full-width "INSTALLING [LABEL]..." banner shown when the player collects a
## powerup floppy. Fills a progress bar over INSTALL_S seconds, then emits
## `finished`. PowerupPickup awaits this before showing the how-to panel.

signal finished

const INSTALL_S: float = 1.5

@onready var _label: Label = %Label
@onready var _bar: ProgressBar = %Bar


func show_install(powerup_label: String) -> void:
	_label.text = "INSTALLING %s..." % powerup_label.to_upper()
	_bar.value = 0.0
	var tw := create_tween()
	tw.tween_property(_bar, "value", 100.0, INSTALL_S).set_trans(Tween.TRANS_LINEAR)
	tw.tween_callback(func() -> void:
		finished.emit()
		queue_free()
	)
