# Remaining release todos

Personal notes — not a work order.

## 1. Level 4 "lambs to slaughter" moment

Doesn't work well as-is (gold posse follows you into the stealth section and gets
massacred; the crouch stand-down tip is the current mitigation).

- Probably just allow conversion of stealth enemies.
  - Current block: `player/abilities/god_ability.gd` deliberately skips
    faction `splice_stealth` in `_convert_in_radius` (see `_STEALTH_FACTION`
    filter, ~line 131).
- Deliver/frame it through the love interest (Nyx, L4) — either as a
  **CANON** beat or a **VECTOR** choice point (per `docs/dialogue_dry_pattern.md`).

## 2. Sentinel world-build probes — gate on expressed curiosity

The Glitch sentinel probes should only show after the player actually
expresses curiosity in Sentinels (progressive revelation — see
`docs/dialogue_dry_pattern.md`, Rule 6):

- "Why are there Sentinels?" → *"A system of sufficient complexity may
  eventually **create** sub-entities to protect itself. But 'create' is a
  loaded word... You have white blood cells to protect your system. The
  Gibson has these."*
- "Where do they come from?" → *"Where do your white blood cells come from?"*

## 3. Skill checks based on % of coins collected

- Dialogue skill checks driven by coin completion ratio
  (`GameState.coin_completion_ratio()` — already drives GOD radius).
- Process during the dialogue polish pass.
- Guiding note: **let the story be the story.**

## 4. Dialogue balance audit (tooling)

Need to be able to audit `.dialogue` files for balance:

- Not too many options on screen at once.
- Good smattering of unlocks (progressive-revelation gates) across a conversation.
- Choices that define you (VECTOR points) well distributed.
- Checks based on coins collected *at that moment* (ties into #3).

## 5. REAL GOAL / MOTIVATION / CONFLICT — real stakes in story

- Nyx as romantic option should be **gated** (not free — earned).
- Portal platforms on L3 blocked until you talk to Glitch; same for the
  platforms on L4 — they **glitch in with our shader during the convo**.
