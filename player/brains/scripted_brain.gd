class_name ScriptedBrain
extends Brain

## Plays back a fixed sequence of Intents, one per physics tick. When the
## sequence ends, returns empty Intents. Useful for tests, cutscenes,
## and reproducing gameplay from recorded input.

var intents: Array[Intent] = []
var _cursor: int = 0


static func from_sequence(sequence: Array[Intent]) -> ScriptedBrain:
	var b := ScriptedBrain.new()
	b.intents = sequence
	return b


func tick(_body: Node3D, _delta: float) -> Intent:
	if _cursor < intents.size():
		var i := intents[_cursor]
		_cursor += 1
		return i
	return Intent.new()
