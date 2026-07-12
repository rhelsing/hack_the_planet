extends SceneTree

## One-shot baker for the skate wheel-roll loop placeholder. Same recipe as
## tools/bake_audio.gd (deterministic synth → AudioStreamWAV .tres) plus a
## loop-seam crossfade — this loop plays continuously under skating, so a
## click every 2s would be audible in a way the ambience placeholder's isn't.
## Replace with a real wheel recording later; player_body.gd just preloads
## the path.
##
##   godot --headless --script res://tools/bake_wheel_roll.gd --quit
##
## Writes: audio/sfx/skate_roll_loop.tres

const SR: int = 44100
const OUT_PATH: String = "res://audio/sfx/skate_roll_loop.tres"


func _init() -> void:
	var dur := 2.0
	var n := int(dur * SR)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337  # deterministic so the .tres is reproducible

	# Wheel rumble: leaky-integrated (brown-ish) noise for the low roll body,
	# a faint 45Hz surface drone, and a slow amplitude wobble so it doesn't
	# read as a perfectly static bed.
	var samples := PackedFloat32Array()
	samples.resize(n)
	var brown := 0.0
	for i in range(n):
		var t: float = float(i) / float(SR)
		brown += (rng.randf() - 0.5) * 0.35
		brown *= 0.985
		var drone: float = sin(t * 45.0 * TAU) * 0.06
		var wobble: float = 1.0 + 0.15 * sin(t * 1.7 * TAU)
		samples[i] = (brown * 0.5 + drone) * wobble

	# Crossfade the last 100ms into the first 100ms so the loop seam is
	# continuous despite the noise integrator ending on an arbitrary value.
	var fade_n := int(0.1 * SR)
	for i in range(fade_n):
		var w: float = float(i) / float(fade_n)  # 0 → 1 across the tail
		samples[n - fade_n + i] = lerpf(samples[n - fade_n + i], samples[i], w)

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	wav.stereo = false
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_end = n
	var buf := PackedByteArray()
	buf.resize(n * 2)
	for i in range(n):
		var value: int = int(clampf(samples[i], -1.0, 1.0) * 32767.0)
		if value < 0: value += 65536
		buf[i * 2] = value & 0xFF
		buf[i * 2 + 1] = (value >> 8) & 0xFF
	wav.data = buf

	var result := ResourceSaver.save(wav, OUT_PATH)
	if result != OK:
		printerr("FAIL bake_wheel_roll: ResourceSaver.save('%s') returned %d" % [OUT_PATH, result])
		quit(1)
		return
	print("PASS bake_wheel_roll: %s (%.1fs loop, seam crossfaded)" % [OUT_PATH, dur])
	quit(0)
