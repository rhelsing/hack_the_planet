class_name InstantTransition
extends Transition
## No visual effect. Emits finished next frame so callers can `await` safely.

func play_out(host: SceneTree) -> Signal:
	host.process_frame.connect(func() -> void: finished.emit(), CONNECT_ONE_SHOT)
	return finished


func play_in(host: SceneTree) -> Signal:
	host.process_frame.connect(func() -> void: finished.emit(), CONNECT_ONE_SHOT)
	return finished
