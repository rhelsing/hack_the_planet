# Remaining release todos

Personal notes — not a work order.

## 1. Level 4 "lambs to slaughter" moment

Doesn't work well as-is (gold posse follows you into the stealth section and gets
massacred; the crouch stand-down tip is the current mitigation).

✅ **Gate lifted** — the `splice_stealth` filter in
`player/abilities/god_ability.gd::_convert_in_radius` is removed; the GOD
blast now converts stealth sentinels like any other splice.

- **Remove Walkie15** (Nyx: "Try to convert some sentinels here, and save
  them for the battle to come...").
- **Crouch stand-down no longer needs to be a thing at all — rip it out:**
  - Dialogue: remove the crouch-tip lines from
    `dialogue/level_4_glitch_post.dialogue` (the "crouch = stand-down" /
    "sentinel apostles... lambs to the slaughter" opener).
  - Mechanic: rip out the crouch stand-down behavior — allies holding
    position on crouch, and the crouch check in
    `enemy/brains/stealth_sentinel_brain.gd`
    (`_is_player_crouched_for_filter` + the `_ensure_target` ally-filter
    that keys off it).
  - Glitch-post NPC stands at (365, -8, -249), inside the stealth yard —
    candidate mouthpiece for the coin/blast explainer instead.

Then walkie support around the stealth yard (where Walkie15 was):

- Nyx: "you'll want to collect some more here" — prompt to grab coins.
- Glitch: explains the mechanism (coin % collected → bigger conversion blast).

## 2. Sentinel world-build probes — gate on expressed curiosity

The Glitch sentinel probes should only show after the player actually
expresses curiosity in Sentinels (progressive revelation — see
`docs/dialogue_dry_pattern.md`, Rule 6):

- "Why are there Sentinels?" → *"A system of sufficient complexity may
  eventually **create** sub-entities to protect itself. But 'create' is a
  loaded word... You have white blood cells to protect your system. The
  Gibson has these."*
- "Where do they come from?" → *"Where do your white blood cells come from?"*

These are new lines — natural home is `dialogue/glitch_2.dialogue::sentinels_subhub`,
which already has the Rule 6 gate scaffolding ("Several configurations?" unlocks
the follow-ups) and an existing, different "Where do they come from?" probe
(Ellingson origin lore) to reconcile with.

## 3. Skill checks based on % of coins collected

- Dialogue skill checks driven by coin completion ratio
  (`GameState.coin_completion_ratio()` — already drives GOD radius).
- Process during the dialogue polish pass.
- Guiding note: **let the story be the story.**
- **First live instance shipped (L1):** `level_1_glitch_3.dialogue` — "[CANS 0%]
  Why did you give me rollerblades?" — a `cans` derived skill synced to
  `GameState.coin_count` at 10%/can (`Skills.set_level`, new method), rolled
  via the existing `Skills.roll` + amber check-button UI. Pattern to reuse
  for the rest of the polish pass. Answer lines are placeholder — color them.

## 4. Dialogue balance audit (tooling)

Need to be able to audit `.dialogue` files for balance:

- Not too many options on screen at once.
- Good smattering of unlocks (progressive-revelation gates) across a conversation.
- Choices that define you (VECTOR points) well distributed.
- Checks based on coins collected *at that moment* (ties into #3).

## 5. REAL GOAL / MOTIVATION / CONFLICT — real stakes in story

- Nyx as romantic option should be **gated** (not free — earned).
- ✅ **DONE** — Portal platforms on L3 blocked until you talk to Glitch; same
  for the platforms on L4 — they **glitch in with our shader during the convo**.
  Shipped as `level/interactable/glitch_reveal/glitch_reveal.gd` + children on
  the 6 L3 portals (flag `glitch_l3_portal_revealed`, already set by "Jump on
  the platform behind me") and the 2 L4 control platforms (new flag
  `l4_platforms_revealed`, set on "That platform. Over there."). Contract test:
  `tests/test_glitch_reveal.tscn`. Needs an eyeball pass in-editor for the
  materialize look. Note: L3 rude path (refusing Glitch twice) now means the
  portals never appear — portals must stay optional, or give rude players a
  later re-offer.
  - L3 targets: the three portal pairs (PortalAlpha/Beta/Gamma in
    `level_3.tscn`) — currently visible + active from level start, no gate.
  - L4 targets: ControlPlatform1/2 — currently visible-but-inert until
    `l4_terminal_5` (`require_flag` on control_portal.gd keeps them grey).
  - **Not buried** — platforms start fully **invisible**, then **glitch in**
    using the existing glitch shader we already apply to dying enemies
    (`death_glitch.gdshader`), run in reverse (materialize-in).
  - Trigger: during the convo with the nearby Glitch NPC, on the line where
    **he mentions the portal** (line-match trigger model like
    `level/glitch_set.gd` uses — fire when the line plays).
