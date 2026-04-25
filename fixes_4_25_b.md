# fixes 4_25_b — pre-implementation alignment

Five issues queued. Don't touch any of them yet — confirm the understanding + scope on each before I start. Each entry: what's broken, where it lives, what the fix shape looks like, and the one or two unknowns that need a quick verify before I commit.

---

## 1. DialTone over-explains the story

**What's broken.** DialTone's lines spell out game mechanics where they should be cryptic. Worst offender: `"Secret pedestal's lit. Next one's a real job — I swear on my uptime."` and the three sibling lines that name each pedestal by its powerup ("God pedestal's hot", "Sex pedestal's primed"). Reads as tutorial copy, not character voice.

**Where.** `dialogue/dial_tone.dialogue:117, 131, 189, 248`. Plus possibly walkie-trigger `line=` overrides inside level scenes (none found in `level/*.tscn` on a quick grep, but could've been authored as voice_lines on hub RespawnMessageZones).

**Fix shape.** Rewrite the four `pedestal` lines in his voice — more "next job's ready / they're moving / signal's hot, runner". Strip mechanics-naming. Keep length similar so timing doesn't drift in the cached audio.

**Cache implication.** Each line is cached by `(character, text, voice_id)` hash → rewrites mean fresh ElevenLabs synths on next play and the old mp3s become orphans in `audio/voice_cache/`. Acceptable.

**Need from you.** Pass on each line if you want to author it personally vs. me drafting; currently I'd write replacements and you eyeball.

---

## 2. Password puzzle doesn't accept controller input

**What's broken.** `puzzle/password/password_puzzle.gd` reads only `InputEventKey` events for character entry. Player on controller has no way to type the password.

**Where.** `puzzle/password/password_puzzle.gd:61–93` — the `_input` handler filters to `event is InputEventKey`. There's no on-screen keyboard, no controller-driven cursor, nothing.

**Fix shape — two real options:**

a. **On-screen keyboard with controller cursor.** Add a Control grid of letter buttons. Use d-pad / left-stick to navigate (`ui_left/right/up/down` already wired post the gamepad pass). X = press selected letter. Square or Circle = backspace. Triangle = submit. Show only when `last_device == "gamepad"` so keyboard players don't see it.

b. **Hybrid: existing keyboard input + a single controller "cycle through characters" affordance.** Less polish, faster. Press d-pad up/down to scroll the active slot's letter, press right to commit and advance to next slot. Less ergonomic but minimal UI work.

**My pick: option (a)** — every controller-friendly password input I can think of in shipped games uses an on-screen keyboard, and the project already has the device-detection plumbing.

**Need from you.** Pick a or b. If (a): are we OK with using the existing pause-menu Button visual style, or should this match the "scroll dialogue" aesthetic established elsewhere?

---

## 3. Dialogue option dimming doesn't track multi-pick correctly

**What's broken.** When you pick option A → return to the question menu → pick option B → the second time you see the menu, **both A and B should be dimmed**. User reports only one (or neither?) is dimmed.

**Where.** `dialogue/scroll_balloon.gd`:
- Visit-recording at line 351: `GameState.visit_dialogue(character, response.id, response.text)` — fires when a response is selected.
- Dim pass at line 476: `_dim_visited_responses()` — runs every time a new dialogue line is shown.
- `GameState.has_visited()` keys on `"<id>_<text>"`.

**On paper this should work.** Visits are recorded BEFORE `next()` advances; the next render of the menu should see A as visited.

**Suspected actual bug.** Need a trace before fixing — three possibilities ranked by likelihood:
1. **`response.id` is empty or non-stable across renders.** Nathan Hoad's dialogue manager assigns IDs from line position; if the menu is re-entered through a different code path, IDs might mismatch between record-time and check-time. Easy diagnostic: log `(character, id, text)` at both `visit_dialogue` and `_dim_visited_responses`.
2. **Dim pass runs before `dialogue_visited` is updated.** Unlikely given the call order, but possible if there's a deferred call chain I haven't traced.
3. **The menu isn't being re-rendered between picks.** If `next()` doesn't trigger a fresh `_show_dialogue_line`, dim pass never runs.

**Fix shape.** Add the trace logs, reproduce the bug, watch the output, then write the small fix (one-line guard or ID-normalization based on what the logs show). Not a rewrite — per debug protocol, big restructure usually means wrong diagnosis.

**Need from you.** Which conversation reproduces it most reliably? (e.g., DialTone in hub, or a specific pedestal NPC) — gives me a fast repro target instead of clicking through every NPC.

---

## 4. Player input not gated during dialogue

**What's broken.** While dialogue is open you can still jump, dash, attack, etc. The body responds to controller buttons even though the player is in a modal conversation.

**Where.** `player/brains/player_brain.gd:tick()` polls `Input.is_action_just_pressed(...)` every physics tick regardless of game state. `Input.*` polling is not pause-aware.

**Why it's controller-specific** (per user's framing). Mouse + keyboard players don't notice because the cursor is captured/UI-focused during dialogue and there's typically only one button being pressed (Enter to advance). Controllers fire button events that the dialogue UI handles via `ui_accept` AND simultaneously the polled actions in `player_brain.tick()` see the same `Input` state — so jump / dash / interact all get consumed twice.

**Fix shape.** Two clean spots to gate:

a. **In `player_brain.tick()`**: early-return an empty Intent (or one with all actions zeroed) if `Dialogue._is_open()` (existing autoload state) is true. Two lines.

b. **In `PlayerBody._physics_process()` consumer**: ignore intent's action booleans while modal is open.

**My pick: (a)** — gate at the brain layer so the body always sees a clean intent. Aligns with the project's brain/body/skin contract.

Nathan Hoad's plugin doesn't need to "explain" anything specific here — its responsibility ends at the dialogue UI. Gating gameplay input during dialogue is the host project's job, which is what we're adding.

**Need from you.** OK with the empty-intent approach? Alternative is to keep movement live (player can still walk while talking, like Skyrim) and only zero the action edges.

---

## 5. Splice dialogue → hub: state doesn't progress

**What's broken.** Now that the level-3 ending is triggered by Splice's dialogue (not a separate end-of-level NPC), the refused branch calls `LevelProgression.goto_path("res://level/hub.tscn")` — which just swaps scene without marking level 3 complete. So the hub doesn't progress to the next pedestal / unlock state when you return.

**Where.** `dialogue/level_3_splice_offer.dialogue:38` (the `splice_refused` branch).

**Why goto_path was wrong here.** I added `LevelProgression.goto_path()` last session as a generic "scene swap that bypasses the 1-4 gating + completion bookkeeping" — useful for the level 5 betrayal branch, but explicitly *skips* the bookkeeping the refused-and-return-to-hub path *needs*.

**Fix shape.** Change the refused branch to call `LevelProgression.advance()` instead. That marks the current level complete (sets `level_3_completed = true`), sets `SaveService.current_level = "hub"`, transitions to hub, saves. The pedestal that gates on `level_3_completed` will now read true and unlock the next one.

```diff
 ~ splice_refused
 Splice: ...wow. Wow okay. Your loss, runner. Truly.
 do GameState.set_flag("refused_splice", true)
-do LevelProgression.goto_path("res://level/hub.tscn")
+do LevelProgression.advance()
 => END
```

**Open question on the committed branch.** Currently:
```
do GameState.set_flag("betrayed_friends", true)
do LevelProgression.goto_path("res://level/level_5.tscn")
=> END
```

Does the betrayal branch ALSO need to mark level 3 complete (so hub state reflects it if/when the player ever returns), or is going-to-level-5 a one-way commit that bypasses normal hub progression entirely? Two interpretations:
- **One-way:** L5 is the endgame for traitors. Don't pollute hub progression because you'll never come back.
- **Branch:** Mark L3 complete + go to L5; if anything pulls them back to hub later, state is consistent.

**Need from you.** Confirm refused-branch fix shape, and pick the betrayal-branch interpretation.

---

## Order I'd implement in

If we ship them all: **5 first** (smallest, unblocks the level 3 → hub flow which is gameplay-critical) → **4** (small, quality-of-life) → **3** (bug, needs diagnosis pass) → **1** (writing pass) → **2** (most work, on-screen keyboard).

Any of these can be deferred. Tell me which you want done now.
