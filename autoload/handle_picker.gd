extends Node

## Persistent hacker-handle picker. Glitch's first conversation calls option(0..3)
## to render the four fixed handles as choices, then pick(i) locks one in
## (stored in GameState.flags.player_handle).
##
## The pool is FIXED at 4 — never random, never expanded. This bound is what
## makes per-handle voice-line variant gen tractable: every voice line that
## tokenizes {player_handle} has exactly four cached mp3 variants, no more.
## See docs/dynamic_dialogue_engine.md.

const POOL: Array[String] = ["Pixel", "Neon", "Cipher", "Byte"]

## Glitch's per-name reaction at pick time. Resigned-British backhand — the
## through-line is "odd choice, but logged anyway." Pixel and Byte get the
## "to each their own" shrug; Neon and Cipher get pointed digs in the same
## resigned tone.
const REACTIONS: Dictionary = {
	"Pixel": "Pixel. Not what I would have picked, but to each their own.",
	"Neon": "Neon. Subtle as a road flare. Brave.",
	"Cipher": "Cipher. Predictable. Every third runner picks Cipher.",
	"Byte": "Byte. Not what I would have picked, but to each their own.",
}

## Fallback when no handle has been picked yet — used by post-level dialogue
## that fires before the player has talked to Glitch (edge case, but real).
const FALLBACK: String = "Runner"


## Label for the i-th option. Stable for all sessions — index N always returns
## POOL[N], so the cache hash is deterministic across runs.
func option(i: int) -> String:
	if i < 0 or i >= POOL.size():
		return ""
	return POOL[i]


## Lock in the i-th option. Irreversible — persisted via GameState so later
## dialogues + saves see the same name.
func pick(i: int) -> void:
	if i < 0 or i >= POOL.size():
		return
	GameState.set_flag(&"player_handle", POOL[i])


## True once a pick has happened. Use this to gate first-convo vs return-convo
## branches in dialogue files.
func has_picked() -> bool:
	return not String(GameState.get_flag(&"player_handle", "")).is_empty()


## The player's locked-in handle, or FALLBACK if not yet picked.
func chosen_name() -> String:
	var stored := String(GameState.get_flag(&"player_handle", ""))
	return stored if not stored.is_empty() else FALLBACK


## Glitch's per-handle reaction. Returns "" if called before a pick.
func reaction() -> String:
	return String(REACTIONS.get(chosen_name(), ""))
