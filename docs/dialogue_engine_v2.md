# Dialogue Engine v2 — Requirements

Working draft for the next dialogue refactor. Scope: keep the DRY authoring
pattern (`docs/dialogue_dry_pattern.md`), add four new mechanics on top —
recursive dim, new-unlock highlight, story-vector accumulator, vector-gated
content. Reference: Disco Elysium's "branch unlocked / red→green / dim only
when fully explored / thought cabinet drift" feel, scoped to what fits an
indie hacker-skater story.

This is a requirements doc, not a design doc. The "Engine work" sections
sketch where code lands but don't commit to APIs yet. Open questions at the
bottom — those need user decisions before design.

---

## Constraints (the three pillars)

Every decision below has to honor these three at once. If a proposed
mechanic strains one, it doesn't ship.

1. **Standards.** One way to write a hub. One way to declare an exit. One
   way to nudge the vector. One way to gate on it. Writers don't choose
   between styles; they fill in the blanks. The DRY pattern stays canonical
   and grows by adding rules, not alternatives.
2. **Flexibility and depth.** The story can express nested probe subtrees,
   gated unlocks, slow-drift vector consequences, and content that reshapes
   based on accumulated choices. Nothing in the writer surface forces a
   "flatten or work around it" workaround.
3. **Low writer complexity.** New mechanics add at most one syntax element
   each. `[#exit]`, `[if StoryVec.in_quadrant("...") /]`, and
   `do StoryVec.nudge(x, y)` are the entire new surface. No new block
   types, no nested response menus, no per-axis directives.

If a section below trades any of these off, that's an open question, not
a decision.

---

## Goals

1. **Reading a hub should answer "have I seen everything here?"** at a glance.
   A probe with un-asked sub-questions feels different from a probe whose
   subtree is fully explored.
2. **New content should announce itself.** When a probe unlocks a follow-up
   the player hasn't seen yet, the follow-up sits at top of list with a
   green outline so the player notices.
3. **Choices should accrete into the story.** Some answers should nudge a
   slow-moving narrative vector — not "this branch unlocks if you said X
   once," but "this branch unlocks if your behavior over the last several
   conversations has trended toward Y." Disco Elysium's drift, not a flag
   gate.
4. **Vector state should reshape the world.** Story content (later
   conversations, scene options, even level beats) reads the vector and
   shows/hides accordingly. Not just dialogue — anything in the game can
   ask the vector "where is the player on the map?".
5. **Authoring stays terse.** Adding tree depth or a vector nudge should be
   one line of `.dialogue` syntax, not a side block per branch.

---

## Non-goals (this pass)

- Disco Elysium-style **skill checks** (red/green outcome banners) — already
  partially done via `[SKILL PCT%]` prefix; not touching here.
- Voice variants per vector quadrant — out of scope.
- Authored sub-graphs that bypass the DRY four-block shape — the existing
  pattern stays canonical. New mechanics layer on top.

---

## Mechanic 1 — Recursive dim ("everything touched")

### What

A probe is dim **only when every visible child probe has also been picked**.
Leaf probes (no sub-menu) are dim when picked, same as today. Parent probes
in a hub-with-sub-hubs structure roll up: child fully explored → child dim →
parent dim only when all siblings are also dim.

### Why

A flat hub of ten probes shows ten dim items once explored — fine. A nested
hub where Probe A leads to a five-option sub-hub should give the player a
visual "you've finished A" cue, distinct from "you've asked A once." The
current dim is per-text, not per-subtree.

### Authoring

Sub-hubs already exist in the codebase as side blocks (Rule 8 of
`dialogue_dry_pattern.md`). Example shape:

```
~ post_2_questions
- What's the plan?
    => post_2_plan_sub
- Who is Splice?
    DialTone: Black-hat. Exiled.
=> post_2_questions

~ post_2_plan_sub
- Three angles?
    DialTone: ...
- Why split?
    DialTone: ...
- Got it. [#exit]
    => post_2_questions
```

No new syntax. The engine walks `response.next_id` → body → if it lands on
another response set, those are children. Sub-hub exits via `[#exit]` already
established.

### Engine work

- New helper `_subtree_fully_explored(response, character)` in scroll_balloon.
  Walks the body of `response.next_id` until it lands on a TYPE_RESPONSE,
  collects child option texts, recurses.
- Dim logic becomes: leaf options dim if visited; parent options dim if
  visited **AND** every visible child fully-explored. `[#exit]` children
  don't count toward exploration (they always exist, never "explored").
- Cost: O(subtree size) per dim pass. Hubs are small (≤10 probes, ≤2 levels
  deep in practice). Acceptable; cache per-render if it's not.

### Open Qs

- **Hidden children**: a probe with `[if /]`-gated children that are currently
  hidden — does the parent count as fully explored?  Recommendation: yes.
  Hidden = doesn't exist for the player right now. If a gate later opens,
  the parent flips back to "not fully explored" and re-highlights (see
  Mechanic 2).
- **Loop-back children**: `=> back_to_parent` shouldn't recurse. Cycle detection
  by tracking visited block ids during the walk.

---

## Mechanic 2 — New-unlock highlight (green outline, top of list)

### What

When a hub renders and one of its visible options is one **the player has
never seen** (in any prior render with this character), that option:
- jumps to the top of the menu,
- gets a green outline (similar to existing `[CAN]` styling but distinct color),
- holds the green outline for the duration of *that menu render only*.

After the menu re-shows, the option is "seen" and rejoins normal order.

### Why

Disco Elysium's "[NEW]" badge. Without it, a flag-gated unlock just
silently appears in the list and the player misses it. With it, the unlock
announces itself once.

### Authoring

Zero. This is automatic for any `[if /]`-gated option whose condition newly
flips true. Falls out of seen-tracking.

### Engine work

- `dialogue_seen` dict on GameState (parallel to `dialogue_visited`):
  `{character: {text: true}}`. Set on every render for every visible option.
- On menu render, BEFORE marking options as seen, compute the "new" set:
  visible options not in seen[character]. Bump them to top, apply outline.
- Then mark them seen.
- Outline color: provisional `#5AE85A` (matches the existing skill-check
  pass banner). Distinct from `[CAN]` blue/speaker-tinted.

### Decisions (locked)

- **Reorder, not annotate.** New options move to top of the list with the
  outline. Re-order is the stronger signal.
- **Visual: green outline only.** Color `#5AE85A` (matches passed
  skill-check banner). No `[NEW]` text prefix. Outline disappears on the
  next render of the same menu.
- **Audio cue: yes.** Plays the existing menu / page-turn cue when a menu
  renders containing one or more newly-unlocked options. The sfx name is a
  `const` at the top of `scroll_balloon.gd` so it's a one-line swap if you
  pick a different cue later.
- **Once seen, always seen.** Persists in the dialogue sidecar (see
  Persistence). Reopening the game doesn't re-flag old unlocks as new.

---

## Mechanic 3 — Story-vector accumulator

### What

A 2D vector (`StoryVec.x`, `StoryVec.y`) accumulates over the run. Some
choices nudge it; most don't. Each axis is a continuous scalar (provisional
range -10 to +10, clamped). The vector persists with the run.

### Why

Disco Elysium's thoughts/skills, scoped to story tone rather than mechanics.
Current alternatives are flags (binary, named after specific decisions) or
counters (one-dimensional). A 2D vector lets one choice pull the player
along a tone gradient without committing to a binary "you are X type now"
flag.

### Engine is generic. Axes are configured per game.

The vector machinery is N-dimensional with **named** axes and
**author-defined** regions. Nothing about the engine knows what an axis
"means." A second project can drop the autoload in, point at a different
config, and use it.

Axes are referenced by `StringName` in the DSL:

```
do StoryVec.nudge(&"ai_tech", 1)
do StoryVec.nudge(&"humanity", -1)
```

Regions are named predicates the writer defines once in
`res://dialogue/story_vec_config.tres` (or equivalent), then references
by name everywhere:

```
- [if StoryVec.in_region(&"pro_ai_pro_people") /] You and Glitch — you click.
```

The config resource owns: axis list, axis bounds (clamp), region
definitions (each region = a list of per-axis thresholds, ANDed). Engine
clamps writes; reads return raw floats; predicates evaluate the named
config.

### Hack The Planet's axes (configured for this game)

- `ai_tech` — pro-AI-tech (+) ↔ anti-AI-tech (−). Glitch-aligned answers
  push +; "tools serve people, not the other way" answers push −.
- `humanity` — for-the-people (+) ↔ for-profit (−). Anti-Ellingson /
  anti-Splice answers push +; expedience / "I'm just paid to be here"
  answers push −.

Bounds and regions live in the config resource — designer can rename them,
add a third axis, redefine regions without touching engine code.

### Authoring

```
- Trust me on this.
    Nyx: I'd like to.
    do StoryVec.nudge(1, 0)
- I'll figure it out alone.
    Nyx: Suit yourself.
    do StoryVec.nudge(-1, 0)
```

Most options call no nudge — the default is neutral. Nudge magnitudes are
small (1 or 2); the player needs many choices to drift the vector
significantly. This matches DE's "individual lines barely move skills, but
patterns do."

### Engine work

- New autoload `story_vec.gd` with:
  - `var x: float`, `var y: float`
  - `nudge(dx: float, dy: float)` — adds to accumulators, emits a
    `vec_changed` signal.
  - `to_dict()` / `from_dict()` for save integration.
  - `quadrant() -> StringName` — returns `&"insider_earnest"` etc., for
    convenience predicates.
- Persistence: piggyback on the new dialogue sidecar (see Persistence below)
  rather than the save slot. The vector should persist with the run, not
  the player's checkpoint.

### Decisions (locked)

- **Visibility**: opaque. Engine exposes a render-friendly accessor
  (`StoryVec.value(axis_name) -> float`) so a future debug HUD or
  designer overlay is trivial to build, but no UI ships in v1.
- **Dimensionality**: variable. Default is whatever the config declares.
  Hack The Planet ships with 2D; nothing in the engine assumes 2.
- **Decay**: none. Vector accumulates per-conversation forever within a
  run. Choices are permanent.

---

## Mechanic 4 — Vector-gated content

### What

Story content can show/hide based on the vector's region. Reuses the
existing `[if /]` syntax with new predicates.

### Authoring

```
- [if StoryVec.value(&"ai_tech") > 3 /] You and Glitch — you click.
    Glitch: We do.
- [if StoryVec.in_region(&"pro_ai_pro_people") /] Whatever it takes.
    DialTone: Mood.
```

`StoryVec.in_region(name)` is the preferred form — designers think in
named regions, not raw axis numbers. Raw `value(axis)` reads are allowed
for one-off thresholds (e.g. tutorial gates) but discouraged for general
content gating.

### Engine work

Just register the autoload with DialogueManager; the `[if expr /]` machinery
already evaluates against autoloads. No new parser plumbing.

### Decisions (locked)

- **Region naming**: author's choice, in `story_vec_config.tres`. Engine
  doesn't know what regions exist until the config is loaded. Hack The
  Planet provisional names: `pro_ai_pro_people`, `pro_ai_for_profit`,
  `anti_ai_pro_people`, `anti_ai_for_profit`, `neutral`. Subject to
  rename — no engine code references them.
- **Neutral zone**: optional, author-defined. Engine doesn't impose one;
  the writer can add a `neutral` region with bounds `||v|| < 2` (or
  whatever) in the config. If a value is in no region, `in_region(any)`
  returns false — that's the implicit "uncommitted" state.

---

## Persistence model

### Today's bug

`dialogue_visited` lives in `GameState`, which is wiped by `from_dict` on
every save load. A player who explores a conversation, then dies and
respawns from checkpoint, loses every visit recorded since the last
`save_to_slot`. Confirmed in console logs (`[gs] from_dict CALLED ...`
between conversations).

### Proposed split

Move all dialogue-meta state — `dialogue_visited`, `dialogue_seen`,
`StoryVec` — out of `GameState` and into a separate sidecar file:
`user://dialogue_state_<slot>.json`.

Properties:
- **Auto-flushes** after every visit / nudge / seen update. File is small,
  writes are cheap.
- **Not touched by `load_from_slot`.** Death-respawn / pause-checkpoint /
  pause-restart all keep dialogue history intact. Loading a different slot
  loads that slot's dialogue file too.
- **Wiped only on `begin_new_game`.**

Save slot still owns: position, health, checkpoint, level flags, inventory.
Dialogue meta is its own file.

### Engine work

- New autoload `dialogue_state.gd`. Owns `visited`, `seen`, `story_vec`.
- `SaveService.begin_new_game(slot)` also calls `DialogueState.reset(slot)`.
- `SaveService.load_from_slot(slot)` calls `DialogueState.load(slot)` —
  reads the sidecar, doesn't mutate it.
- Every `visit_dialogue` / mark-seen / `StoryVec.nudge` writes the sidecar
  immediately (debounce by 1 frame if the cost shows up).

### Open Qs

- **Multi-slot collision**: player A on slot a explores conversation X.
  Player switches to slot b, plays differently. Switches back to slot a —
  dialogue history per slot, right? Recommendation: yes. One sidecar per
  slot, named with the slot id.
- **What happens on schema break**: dialogue_state.json from v1 won't have
  `story_vec`. Recommendation: tolerate missing fields, default to zero.

---

## Authoring rules — additions to `dialogue_dry_pattern.md`

These slot in as new rules at the end of the existing pattern doc.

### Rule 9 — `[#exit]` tags on every "leave the conversation" option

Already in production. Marks options that should never dim and never
record visits. Standard targets: anything routing to `=> *_done` or
directly to `=> END`.

### Rule 10 — Sub-hubs use side blocks, exit with `[#exit]` back to parent

When a probe's subtree has its own probe menu, factor to a side block. The
sub-hub's exit option uses `[#exit]` and goes `=> parent_questions`. Engine
infers the parent-child relationship by walking `response.next_id`.

```
- What's the plan?
    => post_2_plan_sub

~ post_2_plan_sub
- Three angles?
    DialTone: ...
- Why split?
    DialTone: ...
- Back. [#exit]
    => post_2_questions
=> post_2_plan_sub
```

### Rule 11 — Vector nudges live in the option body, not on the option line

```
# RIGHT
- I trust you on this.
    Nyx: Thanks.
    do StoryVec.nudge(1, 0)

# WRONG — nudges before the response is shown / picked
- I trust you on this. [do StoryVec.nudge(1, 0)]
    Nyx: Thanks.
```

The nudge should fire **after** the line content, after the player has
committed by reading the response. This mirrors how `do GameState.set_flag`
already works in the codebase.

### Rule 12 — Don't gate on raw vector numbers in `.dialogue`; use named regions

```
# RIGHT
- [if StoryVec.in_quadrant("outsider_sardonic") /] ...

# WRONG — magic numbers
- [if StoryVec.x > 3 /] ...
```

Numbers drift as we tune; named regions stay stable.

---

## Phased rollout

Each phase is shippable on its own.

### Phase A — Persistence split (foundation)

- New `dialogue_state.gd` autoload.
- Move `dialogue_visited` out of GameState.
- Write/read sidecar on every visit.
- Acceptance: kill the "save reload wipes my conversation history" bug
  observed in the recent logs. Existing dim behavior unchanged.

### Phase B — Seen tracking + new-unlock highlight

- Add `seen` dict alongside `visited` in DialogueState.
- Mark seen on render.
- Highlight + reorder new options.
- Acceptance: flag-gated unlocks visibly announce themselves on the
  render they first become visible.

### Phase C — Recursive dim

- `_subtree_fully_explored` walker.
- Dim parent options based on subtree state.
- Acceptance: nested sub-hubs (e.g. a future `post_2_plan_sub`) dim their
  parent only when all sub-probes are picked.

### Phase D — Story vector

- `story_vec.gd` autoload.
- `nudge` / `in_quadrant` API.
- Persisted in DialogueState sidecar.
- Acceptance: a `do StoryVec.nudge(1, 0)` in a `.dialogue` file moves the
  vector, persists across reloads, and gates an `[if .../]`-marked option
  in another file.

---

## Testing — empirical acceptance per phase

Every phase below ships with a unit test that proves the rule, run via
`godot --headless --script res://tests/test_xxx.gd --quit`. Same pattern as
`tests/test_intent.gd` etc. — extends `SceneTree`, asserts in `_init()`,
exits 0 on pass.

### Phase A tests — persistence split

`tests/test_dialogue_state_persistence.gd`:
- `DialogueState.visit("Glitch", "Onward.→")` → file written.
- Reload (simulate `from_dict` on GameState with empty visited dict) →
  `DialogueState.has_visited("Glitch", "Onward.→") == true`.
- `SaveService.begin_new_game(slot)` → file wiped.
- Switching slots reads the right per-slot file.

### Phase B tests — seen tracking + new-unlock

`tests/test_dialogue_seen.gd`:
- First render of a hub with options [A, B, C] → all three flagged "new".
- Second render → none flagged "new".
- An `[if /]`-gated D becomes visible later → only D flagged "new".
- `seen` survives a from_dict reload (Phase A integration).

`tests/test_balloon_new_unlock_render.gd`:
- Mock a `responses_menu` with three responses, none in seen.
- Run the highlight pass.
- Assert all three buttons have the new-unlock outline applied.
- Assert reorder put them at the top.

### Phase C tests — recursive dim

`tests/test_subtree_explored.gd`:
- Build a fixture DialogueResource with a parent hub → child sub-hub.
- Visit only the parent option → `_subtree_fully_explored(parent) == false`.
- Visit all child options → `_subtree_fully_explored(parent) == true`.
- Hide one child via `[if /]` (gate false) → still `true` (hidden ≠
  required).
- Cycle (sub-hub `=> parent_hub`) → walker doesn't infinite-loop.

### Phase D tests — story vector

`tests/test_story_vec.gd`:
- `StoryVec.x == 0`, `y == 0` at boot.
- `StoryVec.nudge(1, 0)` × 4 → `x == 4`, `y == 0`.
- Clamp at boundaries (e.g. ±10).
- `in_quadrant("insider_earnest")` returns true when in region, false at
  origin (neutral zone), false in opposite quadrant.
- Persists across reload via DialogueState sidecar.
- Emits `vec_changed` exactly once per nudge.

`tests/test_dialogue_vec_gate.gd`:
- Fixture .dialogue file with `[if StoryVec.in_quadrant("X") /]` on one
  option.
- Set vector to inside region → option visible.
- Set to outside → option hidden.

### Cross-phase smoke

After each phase: existing tests still pass, plus
`godot --headless --quit-after 120 2>&1 | grep -Ei "SCRIPT ERROR"` returns
nothing. Same gate as the rest of the project.

### Why this shape of testing

- **Empirical, not "the docs say so".** Each rule has a test that fails if
  the rule is broken. Refactor confidence comes from running them, not
  from re-reading code.
- **Fixture-based for engine logic.** Build a small DialogueResource in code
  for Phase C; don't depend on real `.dialogue` files for unit tests
  (those files are story content, they'll change).
- **Use real files for integration smoke.** Phase D's `test_dialogue_vec_gate`
  loads a fixture `.dialogue` file because the assertion is about the
  parser/runtime, not the vector logic alone.

---

## Decisions log (locked)

All open questions from earlier drafts are now resolved:

- Engine is **generic / N-dimensional / config-driven**. Reusable across
  projects.
- Hack The Planet's axes: `ai_tech`, `humanity`. Regions named in
  `story_vec_config.tres` (designer-owned).
- New-unlock visual: **green outline (#5AE85A), reorder to top**.
- New-unlock audio: **existing menu / page-turn sfx**, `const` for easy swap.
- Vector visibility to player: **opaque**, but reads/regions are accessible
  for a future debug HUD.
- Sidecar persistence: **per save slot**, separate from save_slot file,
  survives `load_from_slot` (the bug that made you mad).
- Hidden `[if /]` children count as **fully explored** (don't block parent
  dim).
- "Once seen, always seen" across reloads.
- No vector decay — choices accumulate permanently within a run.
- Phase order: **A → B → C → D**.

---

## What this doc does NOT decide

- API shapes (`StoryVec.nudge` vs `StoryVec.add` vs an Events signal).
- File format of the sidecar (JSON vs binary).
- How `DialogueState` interacts with the existing `Events` autoload.
- Whether to migrate existing `dialogue_visited` data on first run or wipe it.

Those land in the design doc that follows once the open questions above are
resolved.
