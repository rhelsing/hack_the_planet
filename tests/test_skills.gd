extends Node

## Tests Skills autoload:
##   - roll() distribution over many samples
##   - roll(0) never succeeds, roll(100) always succeeds
##   - Events.skill_check_rolled fires with correct args
##   - can_attempt / start_cooldown / cooldown_remaining_sec
##
## Run with:
##   godot --headless res://tests/test_skills.tscn


func _ready() -> void:
	var failures: Array[String] = []

	Skills.reset_all_cooldowns()
	Skills.reset_all_levels()

	# ---- Clamp: base 0 (untrained) → MIN_CHANCE (5%), never fully zero.
	# 10k samples of roll(base=0): expect ~500 successes (4-6% band).
	var min_hits := 0
	for i in range(10000):
		if Skills.roll(&"t", 0): min_hits += 1
	if min_hits < 250 or min_hits > 750:
		failures.append("roll(0) clamped to MIN_CHANCE=5%%: expected 250-750 hits in 10k, got %d" % min_hits)

	# ---- Clamp: base 100 → MAX_CHANCE (95%), never guaranteed.
	var max_misses := 0
	for i in range(10000):
		if not Skills.roll(&"t", 100): max_misses += 1
	if max_misses < 250 or max_misses > 750:
		failures.append("roll(100) clamped to MAX_CHANCE=95%%: expected 250-750 misses in 10k, got %d" % max_misses)

	# ---- Mid-range distribution: roll(50) over 10k should land ~5000 ±500 ----
	var successes := 0
	var n := 10000
	for i in range(n):
		if Skills.roll(&"t", 50): successes += 1
	if successes < 4500 or successes > 5500:
		failures.append("roll(50) over 10000: got %d successes, expected 4500-5500" % successes)

	# ---- Levels: effective_chance adds +CHANCE_PER_LEVEL per level ----
	Skills.reset_all_levels()
	if Skills.get_level(&"composure") != 0:
		failures.append("fresh skill should be level 0")
	if Skills.effective_chance(&"composure", 30) != 30:
		failures.append("level 0 base 30 should stay 30, got %d" % Skills.effective_chance(&"composure", 30))
	Skills.grant(&"composure")
	if Skills.get_level(&"composure") != 1:
		failures.append("after grant, level should be 1")
	if Skills.effective_chance(&"composure", 30) != 45:
		failures.append("level 1 base 30 should be 45 (30+15), got %d" % Skills.effective_chance(&"composure", 30))
	Skills.grant(&"composure", 5)  # now at level 6 — should cap at MAX (95%)
	if Skills.effective_chance(&"composure", 30) != 95:
		failures.append("level 6 base 30 should cap at MAX_CHANCE=95, got %d" % Skills.effective_chance(&"composure", 30))

	# ---- Per-skill level-bonus override (for "insight" unlocks) ----
	Skills.reset_all_levels()
	Skills.set_level_bonus(&"composure", 84)
	if Skills.get_level_bonus(&"composure") != 84:
		failures.append("get_level_bonus should return 84 after set, got %d" % Skills.get_level_bonus(&"composure"))
	if Skills.get_level_bonus(&"logic") != Skills.CHANCE_PER_LEVEL:
		failures.append("non-overridden skill should use default CHANCE_PER_LEVEL")
	Skills.grant(&"composure")
	if Skills.effective_chance(&"composure", 5) != 89:
		failures.append("base 5 + level 1 * bonus 84 should = 89, got %d" % Skills.effective_chance(&"composure", 5))
	# Events.skill_granted firing
	var caught_grants: Array = []
	var grant_cb := func(skill: StringName, new_level: int):
		caught_grants.append([skill, new_level])
	Events.skill_granted.connect(grant_cb)
	Skills.grant(&"logic")
	Events.skill_granted.disconnect(grant_cb)
	if caught_grants.size() != 1 or caught_grants[0][0] != &"logic" or caught_grants[0][1] != 1:
		failures.append("skill_granted emit: expected [logic, 1], got %s" % str(caught_grants))
	Skills.reset_all_levels()

	# ---- Events.skill_check_rolled fires with the right args ----
	var caught_rolls: Array = []
	var cb := func(skill: StringName, pct: int, ok: bool):
		caught_rolls.append([skill, pct, ok])
	Events.skill_check_rolled.connect(cb)
	Skills.roll(&"composure", 72)
	Skills.roll(&"logic", 33)
	Events.skill_check_rolled.disconnect(cb)
	if caught_rolls.size() != 2:
		failures.append("skill_check_rolled should fire once per roll, got %d" % caught_rolls.size())
	if caught_rolls.size() > 0:
		var first: Array = caught_rolls[0]
		if first[0] != &"composure" or first[1] != 72:
			failures.append("skill_check_rolled args wrong: %s" % str(first))

	# ---- Cooldown starts + remaining counts down ----
	Skills.reset_all_cooldowns()
	if not Skills.can_attempt(&"composure"):
		failures.append("fresh skill should be ready (can_attempt=true)")
	Skills.start_cooldown(&"composure", 1.0)  # 1s cooldown for test
	if Skills.can_attempt(&"composure"):
		failures.append("after start_cooldown, can_attempt should be false")
	var remaining := Skills.cooldown_remaining_sec(&"composure")
	if remaining <= 0.0 or remaining > 1.2:
		failures.append("cooldown_remaining should be ~1.0, got %f" % remaining)

	# ---- Events.skill_cooldown_started fires ----
	var caught_cooldowns: Array = []
	var cb2 := func(skill: StringName, seconds: float):
		caught_cooldowns.append([skill, seconds])
	Events.skill_cooldown_started.connect(cb2)
	Skills.start_cooldown(&"logic", 15.0)
	Events.skill_cooldown_started.disconnect(cb2)
	if caught_cooldowns.size() != 1 or caught_cooldowns[0][0] != &"logic" or caught_cooldowns[0][1] != 15.0:
		failures.append("skill_cooldown_started: expected [logic, 15.0], got %s" % str(caught_cooldowns))

	# ---- Cooldown expires — poll process_frame + real clock (headless safe) ----
	Skills.reset_all_cooldowns()
	Skills.start_cooldown(&"quick", 0.15)
	var wait_start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - wait_start < 400:
		await get_tree().process_frame
	if not Skills.can_attempt(&"quick"):
		var rem := Skills.cooldown_remaining_sec(&"quick")
		failures.append("cooldown should have expired after 400ms (cooldown was 150ms); remaining=%f" % rem)

	Skills.reset_all_cooldowns()

	if failures.is_empty():
		print("PASS test_skills: roll distribution + signal emits + cooldown lifecycle")
		get_tree().quit(0)
	else:
		for f: String in failures:
			printerr("FAIL test_skills: " + f)
		get_tree().quit(1)
