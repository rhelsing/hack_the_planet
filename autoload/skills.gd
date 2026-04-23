extends Node

## Skill-check system — percent-chance rolls with per-skill cooldowns and
## character-progression levels. Exposed to .dialogue files via
## [dialogue_manager] general/states so you can call
## Skills.roll(...) / Skills.can_attempt(...) / Skills.grant(...)
## directly from dialogue syntax.
##
## Progression model
## -----------------
##   Level 0 = untrained. `roll(skill, base_pct)` uses base_pct.
##   Each level adds +CHANCE_PER_LEVEL (+15% by default).
##   Effective chance is clamped [MIN_CHANCE, MAX_CHANCE] = [5%, 95%], so
##   an untrained character always has a chance (never 0) and a maxed
##   skill is never a lock (never 100%).
##
## Usage in .dialogue
## ------------------
##   # Gate an option while the skill is on cooldown
##   - [COMPOSURE 30%] Stare him down [if Skills.can_attempt("composure") /]
##       if Skills.roll("composure", 30):
##           Troll: You didn't flinch.
##       else:
##           Troll: Rookie move.
##           do Skills.start_cooldown("composure")
##
##   # Teach the skill (level 0 -> 1)
##   - Got any tips? [if Skills.get_level("composure") == 0 /]
##       Troll: Breathe through your nose. Hands still.
##       do Skills.grant("composure")
##
## Grant sources — how the player acquires skill levels
## ----------------------------------------------------
## The `grant(skill, delta=1)` method is the single entry point for
## increasing a skill level. Call it from any of the following patterns
## (all plumbed through the same Events.skill_granted signal so HUDs /
## SFX can react uniformly):
##
##   1. Dialogue `do` call — `do Skills.grant("composure")` in a branch.
##      Example: tutor NPCs, mentors, inner-monologue realizations.
##
##   2. Pickup interactable — Pickup.gd checks `grants_skill` export.
##      (Hook is stubbed in docs/scroll_dialogue.md P7; wire when needed.)
##
##   3. Puzzle solved — PuzzleTerminal on Events.puzzle_solved for its id,
##      call `do Skills.grant("logic")`. Or bake into the puzzle scene's
##      `_complete(success=true)` handler.
##
##   4. Book / file / terminal read — any Interactable whose `interact()`
##      calls Skills.grant directly.
##
##   5. Cybermod / gear — equip-on-body effects. Call grant() on equip,
##      grant(-1) on unequip. Pairs with a persistent "equipped" GameState
##      flag so the bonus doesn't stack on reload.
##
##   6. Character creation / "choose a specialization" — batch grant at
##      new-game start from a chargen UI.
##
## Cooldowns are tracked in-memory only (reset on game restart). If you
## want them persistent, snapshot _cooldown_end_ms into GameState via
## to_dict/from_dict. Same story for levels (`_level` dict).

const DEFAULT_COOLDOWN_SEC: float = 30.0

# Progression knobs. Level 0 = untrained; rolls use base_pct from the dialogue
# line. Each level adds +CHANCE_PER_LEVEL (can be overridden per-skill via
# set_level_bonus). Clamped [MIN_CHANCE, MAX_CHANCE] so an untrained character
# still has a puncher's chance (never 0%) and a maxed skill isn't a lock
# (never 100%).
const CHANCE_PER_LEVEL: int = 15
const MIN_CHANCE: int = 5
const MAX_CHANCE: int = 95

# skill StringName → absolute msec (Time.get_ticks_msec) when cooldown ends
var _cooldown_end_ms: Dictionary = {}

# skill StringName → int level (default 0 via .get fallback)
var _level: Dictionary = {}

# skill StringName → int bonus-per-level override. Absent = CHANCE_PER_LEVEL.
# Use for "insight" unlocks (big one-time jumps) vs gradual training.
var _level_bonus: Dictionary = {}


## Roll a single check. `base_chance_pct` is the untrained probability (0-100).
## The player's skill level adds +CHANCE_PER_LEVEL% each. Final chance clamped
## [MIN_CHANCE, MAX_CHANCE] so untrained still has a chance and maxed isn't
## guaranteed. Emits Events.skill_check_rolled(skill, effective_pct, ok).
func roll(skill: StringName, base_chance_pct: int) -> bool:
	var effective: int = effective_chance(skill, base_chance_pct)
	# 1-100 roll. Roll <= effective = success.
	var ok: bool = randi_range(1, 100) <= effective
	Events.skill_check_rolled.emit(skill, effective, ok)
	return ok


## Returns the effective chance a roll would use, given a base percentage and
## the player's current level + per-skill level-bonus. Pure calculation.
func effective_chance(skill: StringName, base_chance_pct: int) -> int:
	var total: int = base_chance_pct + get_level(skill) * get_level_bonus(skill)
	return clampi(total, MIN_CHANCE, MAX_CHANCE)


## Bonus added per level for this skill. Default = CHANCE_PER_LEVEL (+15).
## Override via set_level_bonus for skills where a single "insight" or
## "breakthrough" grant should unlock a dramatic jump instead of gentle
## progression.
func get_level_bonus(skill: StringName) -> int:
	return _level_bonus.get(skill, CHANCE_PER_LEVEL)


## Sets the per-level bonus for a skill. Usually called once near the point of
## teaching (before or during the grant) so the jump takes effect immediately.
##   do Skills.set_level_bonus("composure", 84)
##   do Skills.grant("composure")        # → 5% base + 84 = 89% at level 1
func set_level_bonus(skill: StringName, bonus_per_level: int) -> void:
	_level_bonus[skill] = bonus_per_level


## Current level (0 = untrained). Persisted in memory; save/load via GameState
## snapshot later.
func get_level(skill: StringName) -> int:
	return _level.get(skill, 0)


## Grant N levels in the skill (default +1). Called from .dialogue files
## (`do Skills.grant("composure")`) or world interactables (books, trainers,
## mods). Emits Events.skill_granted(skill, new_level).
func grant(skill: StringName, delta: int = 1) -> void:
	var new_level: int = max(0, get_level(skill) + delta)
	_level[skill] = new_level
	Events.skill_granted.emit(skill, new_level)


## True when the skill has no active cooldown. Use in `[if ... /]` response
## gates to hide the option during cooldown (works with hide_failed_responses).
func can_attempt(skill: StringName) -> bool:
	return cooldown_remaining_sec(skill) <= 0.0


## Seconds remaining on the cooldown, 0 if ready.
func cooldown_remaining_sec(skill: StringName) -> float:
	var end_ms: int = _cooldown_end_ms.get(skill, 0)
	if end_ms == 0: return 0.0
	return maxf(0.0, float(end_ms - Time.get_ticks_msec()) / 1000.0)


## Start or extend a cooldown for the given skill.
func start_cooldown(skill: StringName, seconds: float = DEFAULT_COOLDOWN_SEC) -> void:
	_cooldown_end_ms[skill] = Time.get_ticks_msec() + int(seconds * 1000.0)
	Events.skill_cooldown_started.emit(skill, seconds)


## Clears all cooldowns — debug/testing convenience. Not called in production.
func reset_all_cooldowns() -> void:
	_cooldown_end_ms.clear()


## Clears all skill levels + per-skill bonuses — debug/testing only.
func reset_all_levels() -> void:
	_level.clear()
	_level_bonus.clear()
