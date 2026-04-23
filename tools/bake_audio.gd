extends SceneTree

## One-shot audio baker. Synthesizes placeholder .wav audio via sine + noise
## and saves them as .tres resources under library/audio/. Run once:
##
##   godot --headless --script res://tools/bake_audio.gd --quit
##
## Writes:
##   library/audio/door_open.tres     (low thud + rising sweep)
##   library/audio/pickup_ding.tres   (short rising chime)
##   library/audio/hack_success.tres  (ascending arpeggio)
##   library/audio/hack_fail.tres     (descending dissonant)
##   library/audio/music_loop.tres    (looping pad)
##   library/audio/ambience_loop.tres (looping drone + noise bed)
##
## Replace these .tres files with real audio from your sound designer later —
## cue_registry.tres just references paths.

const SR: int = 44100


func _init() -> void:
	DirAccess.make_dir_recursive_absolute("res://library/audio")

	_save(_synth_sfx_door_open(), "res://library/audio/door_open.tres")
	_save(_synth_sfx_ding(), "res://library/audio/pickup_ding.tres")
	_save(_synth_sfx_hack_success(), "res://library/audio/hack_success.tres")
	_save(_synth_sfx_hack_fail(), "res://library/audio/hack_fail.tres")
	_save(_synth_music_loop(), "res://library/audio/music_loop.tres")
	_save(_synth_ambience_loop(), "res://library/audio/ambience_loop.tres")

	print("PASS bake_audio: 6 placeholder streams baked to library/audio/")
	quit(0)


# ---- Synths --------------------------------------------------------------

func _synth_sfx_door_open() -> AudioStreamWAV:
	# 0.4s: low thud (60Hz) layered with rising tone (120→600Hz), fades out.
	var dur := 0.4
	return _mk(dur, func(t: float) -> float:
		var env: float = exp(-t * 5.0)
		var thud: float = sin(t * 60.0 * TAU) * env
		var sweep_freq: float = 120.0 + (t / dur) * 480.0
		var sweep: float = sin(t * sweep_freq * TAU) * env * 0.5
		return (thud + sweep) * 0.4
	)


func _synth_sfx_ding() -> AudioStreamWAV:
	# 0.25s chime: 800Hz + 1200Hz harmonics, quick fade.
	var dur := 0.25
	return _mk(dur, func(t: float) -> float:
		var env: float = exp(-t * 12.0)
		var fundamental: float = sin(t * 800.0 * TAU)
		var harmonic: float = sin(t * 1200.0 * TAU) * 0.5
		return (fundamental + harmonic) * env * 0.35
	)


func _synth_sfx_hack_success() -> AudioStreamWAV:
	# 0.6s ascending arpeggio: 400, 600, 900 Hz stepped through.
	var dur := 0.6
	return _mk(dur, func(t: float) -> float:
		var env: float = exp(-t * 3.0)
		var f: float = 400.0
		if t > 0.4: f = 900.0
		elif t > 0.2: f = 600.0
		return sin(t * f * TAU) * env * 0.35
	)


func _synth_sfx_hack_fail() -> AudioStreamWAV:
	# 0.5s descending dissonant — 500Hz + 520Hz beating, dropping.
	var dur := 0.5
	return _mk(dur, func(t: float) -> float:
		var env: float = exp(-t * 3.0)
		var drop: float = 1.0 - (t / dur) * 0.6
		var a: float = sin(t * 500.0 * drop * TAU)
		var b: float = sin(t * 520.0 * drop * TAU)
		return (a + b) * 0.5 * env * 0.35
	)


func _synth_music_loop() -> AudioStreamWAV:
	# 2s looping pad — layered thirds (C-E-G at 261/329/392 Hz).
	var dur := 2.0
	var wav := _mk(dur, func(t: float) -> float:
		var phase: float = t / dur
		# Slow pulse envelope.
		var env: float = 0.3 + 0.1 * sin(phase * TAU)
		var c: float = sin(t * 261.63 * TAU)
		var e: float = sin(t * 329.63 * TAU)
		var g: float = sin(t * 392.00 * TAU)
		return (c + e + g) * 0.15 * env
	)
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_end = int(dur * SR)
	return wav


func _synth_ambience_loop() -> AudioStreamWAV:
	# 4s looping drone — 80Hz sub + filtered noise.
	var dur := 4.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 42  # deterministic noise so the .tres is reproducible
	var wav := _mk(dur, func(t: float) -> float:
		var drone: float = sin(t * 80.0 * TAU) * 0.15
		var noise: float = (rng.randf() - 0.5) * 0.08
		return drone + noise
	)
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_end = int(dur * SR)
	return wav


# ---- Helpers -------------------------------------------------------------

func _mk(duration: float, sample_fn: Callable) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	wav.stereo = false
	var n := int(duration * SR)
	var buf := PackedByteArray()
	buf.resize(n * 2)
	for i in range(n):
		var t: float = float(i) / float(SR)
		var sample: float = clampf(sample_fn.call(t), -1.0, 1.0)
		var value: int = int(sample * 32767.0)
		if value < 0: value += 65536
		buf[i * 2] = value & 0xFF
		buf[i * 2 + 1] = (value >> 8) & 0xFF
	wav.data = buf
	return wav


func _save(stream: AudioStreamWAV, path: String) -> void:
	var result := ResourceSaver.save(stream, path)
	if result != OK:
		printerr("FAIL bake_audio: ResourceSaver.save('%s') returned %d" % [path, result])
