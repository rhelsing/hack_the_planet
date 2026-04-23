class_name Transition
extends RefCounted
## Abstract transition effect for scene changes / menu swaps.
##
## Call `play_out` → await its Signal → swap scene → call `play_in` → await
## its Signal. Concrete implementations own their own UI root (typically a
## CanvasLayer with a ColorRect), parent it to get_tree().root, and free it
## after the in-phase.

signal finished


func play_out(_host: SceneTree) -> Signal:
	finished.emit.call_deferred()
	return finished


func play_in(_host: SceneTree) -> Signal:
	finished.emit.call_deferred()
	return finished


static func from_style(style: String) -> Transition:
	match style:
		"glitch":
			return GlitchTransition.new()
		"instant", _:
			return InstantTransition.new()
