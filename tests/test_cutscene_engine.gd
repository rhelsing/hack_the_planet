extends SceneTree

## Static smoke test for the cutscene engine. Verifies every step class
## instantiates and inherits from CutsceneStep, and that a CutsceneTimeline
## can hold a heterogeneous list of them. Doesn't exercise the runtime
## (autoloads aren't available in --script mode); for runtime testing,
## drop a CutscenePlayer in a level and bind debug_hotkey.
##
## Run:
##   godot --headless --script res://tests/test_cutscene_engine.gd --quit


func _init() -> void:
	var failures: Array[String] = []

	# Each step subclass instantiates and is a CutsceneStep.
	var line := LineStep.new()
	line.character = &"Splice"
	line.text = "Test line."
	line.channel = "companion"
	if not (line is CutsceneStep): failures.append("LineStep not CutsceneStep")

	var cut := CutStep.new()
	cut.camera = ^"SomeCam"
	if not (cut is CutsceneStep): failures.append("CutStep not CutsceneStep")

	var pan := PanStep.new()
	pan.duration = 5.0
	if not (pan is CutsceneStep): failures.append("PanStep not CutsceneStep")

	var wait := WaitStep.new()
	wait.seconds = 1.5
	if not (wait is CutsceneStep): failures.append("WaitStep not CutsceneStep")

	var music := MusicStep.new()
	if not (music is CutsceneStep): failures.append("MusicStep not CutsceneStep")

	var stinger := StingerStep.new()
	if not (stinger is CutsceneStep): failures.append("StingerStep not CutsceneStep")

	var flag := FlagStep.new()
	flag.flag = &"test_flag"
	flag.value = true
	if not (flag is CutsceneStep): failures.append("FlagStep not CutsceneStep")

	var parallel := ParallelStep.new()
	parallel.steps = [line, pan]
	if not (parallel is CutsceneStep): failures.append("ParallelStep not CutsceneStep")

	var sub := SubsequenceStep.new()
	if not (sub is CutsceneStep): failures.append("SubsequenceStep not CutsceneStep")

	var skip := SkipPointStep.new()
	skip.label = "halftime"
	if not (skip is CutsceneStep): failures.append("SkipPointStep not CutsceneStep")

	# Timeline holds a heterogeneous Array[CutsceneStep] and round-trips
	# through field assignment + iteration without type complaints.
	var tl := CutsceneTimeline.new()
	tl.steps = [line, cut, pan, wait, music, stinger, flag, parallel, sub, skip]
	tl.freeze_player = true
	tl.hide_hud = false
	tl.done_flag = &"test_done"
	tl.cancelled_flag = &""
	tl.skip_action = &"ui_cancel"
	tl.allow_skip = true

	if tl.steps.size() != 10:
		failures.append("Timeline should have 10 steps; has %d" % tl.steps.size())

	# Iteration matches the order we authored.
	var expected_classes: Array = [
		"LineStep", "CutStep", "PanStep", "WaitStep", "MusicStep",
		"StingerStep", "FlagStep", "ParallelStep", "SubsequenceStep",
		"SkipPointStep",
	]
	for i in tl.steps.size():
		var got: String = tl.steps[i].get_script().resource_path.get_file().get_basename()
		# get_script gives "line_step", expected "LineStep" — convert
		var got_camel: String = ""
		for part in got.split("_"):
			got_camel += part.capitalize()
		if got_camel != expected_classes[i]:
			failures.append("Step[%d] expected %s, got %s" % [i, expected_classes[i], got_camel])

	if failures.is_empty():
		print("PASS test_cutscene_engine — 10 step types, timeline ok")
		quit(0)
	else:
		for f in failures:
			print("FAIL: %s" % f)
		quit(1)
