# Nav stealth parity plan — restoring what the port dropped

Status: **executed 2026-07-25** (§1–§9 landed with R1–R10 folded in; §10
debug labels and §11 perf governor remain open — see Resolutions at the
bottom). Companion to `docs/nav_stack.md` — every fix below lands in
exactly **one** layer per the stack contract. If a fix wants two layers,
the cut is wrong; that's flagged, not smuggled.

Source comparison: `player/brains/enemy_ai_brain.gd` (2,811 lines) +
`enemy/brains/stealth_sentinel_brain.gd` + `enemy/brains/stealth_sentinel_ai.tscn`
(the shipped sentinel numbers) vs the current nav stack + `enemy/brains/nav_stealth.tscn`.

Locked design decision (per Ryan): **the cone stays visual-only** — a
strictly read-only LOOK component, exactly as `nav_cone_visual.gd` is
architected today — but it must *look* like the old cone (wall-clipped,
smooth swivel, crouch shrink, radial fade, hack flicker) and the *detection
underneath it* must function like the old cone. The old code fused the two
("the visible fan IS the LOS volume"); the new stack deliberately splits
them: **NavPerception owns the truth, NavConeVisual paints the truth.**
Parity is preserved because both read the same effective numbers.

---

## Gap → layer map

| # | Gap | Layer | File touched |
|---|---|---|---|
| 1 | Hack freeze + `is_chasing` gate (silent duck-type miss) | DECIDE (NavBrain public API) | `nav_brain.gd` (+ 1 warning in `stealth_kill_target.gd`) |
| 2 | Crouch-stealth sight model (range ×0.5, arc ×0.3) | DECIDE/senses (NavPerception) | `nav_perception.gd` (+ 1-line public read on PlayerBody) |
| 3 | Hostile-zone instant HOSTILE (standing, ≤20m) | DECIDE/senses (NavPerception) | `nav_perception.gd` |
| 4 | SUSPECT freeze-and-stare | DECIDE (NavBrain state) | `nav_brain.gd` |
| 5 | Chase tucker-out (8s give-up) | DECIDE (NavBrain state) | `nav_brain.gd` |
| 6 | Mid-HOSTILE swarm lock (chase ignores LOS/cover) | DECIDE (NavBrain awareness) | `nav_brain.gd` |
| 7 | Priority targets (golds in the bubble) | DECIDE (NavBrain targeting) | `nav_brain.gd` |
| 8 | Cone visual: wall clip, swivel, gradient, flickers, truth-scale | LOOK (NavConeVisual) | `nav_cone_visual.gd` |
| 9 | Preset tuning drift (45m vs 30m, eye 1.4 vs 1.0, colors) | config | `nav_stealth.tscn`, `enemy_kaykit_stealth_nav.tscn` |
| 10 | F3 per-pawn debug labels | game-side debug component | new `enemy/nav_debug_label.gd` + `game.gd` |
| 11 | Perf (anim LOD, offscreen pause) | shared body component | deferred — measure first |

Nothing touches NavSteering, the bake, or the body's physics. The stack's
"game knows the stack, never the reverse" rule holds everywhere below.

---

## 1. Hack integration — `set_hack_active` + `is_chasing` on NavBrain

**Parity target.** `StealthKillTarget` duck-types two brain methods
(`stealth_kill_target.gd:211` and `:239`). Old brain: `set_hack_active`
froze the pawn (early return at `enemy_ai_brain.gd:581` — no patrol, no
chase, no swing) and drove the cone's flicker-to-0; `is_chasing()` killed
the hack prompt once HOSTILE. NavBrain has neither; both lookups fail
silently.

**Fix (NavBrain, migration-map row "Hack freeze → external CONTROL state").**
- Internal generic state: `_frozen: bool` + `_freeze_progress: float`.
  In `tick()`, right after edge-flag clearing and **before**
  `_update_awareness`: if `_frozen`, zero `move_direction` and return.
  Timers stop, senses stop, patrol stops — matching the old early-return
  placement (a hacked pawn also doesn't *detect* you mid-hack).
- Game-facing thin setters, names matching the existing caller so
  `stealth_kill_target.gd` ships **unmodified**:
  `set_hack_active(active, progress)` → writes `_frozen`/`_freeze_progress`;
  `is_chasing()` → `_state == State.CHASE or _state == State.WIND_UP`.
  (Generic freeze is the mechanism, hack is one client — any future stun
  system calls the same two fields.)
- `perception_view()` gains `hack_active` + `hack_progress` so the visual
  can render the dying-signal flicker (see §8). The brain reports facts;
  the LOOK layer owns the presentation of them.
- Hardening: one-time `push_warning` in `StealthKillTarget`'s brain lookup
  when no child has the method — this exact silent failure is how the
  regression shipped unnoticed (CLAUDE.md: silent failure is the enemy).

**Tests.** `test_nav_brain.gd`: frozen brain returns zero-move intent and
fires no attack with a target in range; suspicion does not rise while
frozen; `is_chasing()` false in WANDER/SUSPECT, true in CHASE/WIND_UP.

## 2. Crouch-stealth sight model — NavPerception

**Parity target.** Old: target crouched → detection range ×
`crouch_range_multiplier` (0.5 in the sentinel preset → 30m becomes 15m),
cone arc × `crouch_cone_multiplier` (0.3 → 100° becomes 30°). Crouching
*inside* the visual field was the core sneak verb. New NavPerception is
stance-blind on sight (crouch only silences hearing).

**Fix (NavPerception — pure logic, stays unit-testable).**
- Config: `crouch_range_multiplier := 1.0`, `crouch_cone_multiplier := 1.0`
  (forwarded from new NavBrain exports like every other perception number;
  the stealth preset sets 0.5 / 0.3).
- Stance seam, mirroring the existing `loudness_of()` pattern:
  `static func crouched_of(target) -> bool` duck-types a public
  `is_crouched()` method (absent = false). PlayerBody gains the one-line
  public `is_crouched() -> bool: return _was_crouched` — the old brain read
  the private `_was_crouched` directly; the duck-typed method keeps the
  stack portable and drops the private-var reach-in.
- `effective_range()` / `effective_cone_deg()` methods apply the
  multipliers when the *current candidate/target* is crouched; the
  `_sight_strength` gates use them instead of the raw values. Hearing is
  already stance-gated via loudness — unchanged.
- `perception_view()` reports the **effective** values plus
  `target_crouched` — this is what makes the visual shrink for free in §8,
  with zero cone-specific logic in the brain.

**Non-goal.** Old `crouch_suspect_multiplier` (preset never set it ≠ 1.0)
and the crouched linear suspect-ramp: the accumulator's distance×centrality
fill-rate already produces "closer = faster fuse" continuously, which is
the same feel by construction. Not ported; noted for the A/B pass in §9.

**Tests.** `test_nav_perception.gd`: crouched target at 0.6× range unseen
with mult 0.5, seen standing; crouched target at 40° off-axis unseen with
arc mult 0.3, seen standing; hearing unaffected by the new multipliers.

## 3. Hostile-zone snap — NavPerception

**Parity target.** Old (`enemy_ai_brain.gd:2297-2303`): a **standing**
target with LOS inside `hostile_zone_radius` (20m) skipped SUSPECT entirely
— instant HOSTILE. The new 1.2s accumulator gives a point-blank standing
player a grace window the old design deliberately denied. (Old code ran the
crouched case through the distance ramp, not the zone — the export comment
claiming otherwise is stale; parity targets the code.)

**Fix (NavPerception).** Config `hostile_zone_radius := 0.0` (stealth
preset 20). In `_sight_strength`: seen && **not crouched** && flat distance
≤ zone → return a snap strength (1000.0). `integrate()` is untouched —
strength × delta / suspect_time saturates to 1.0 in a single tick. Greens/
reds keep 0.0 → dead code for them.

**Tests.** standing @ 19m + LOS → hostile in one tick; crouched @ 19m →
normal accumulation; standing @ 21m → normal accumulation.

## 4. SUSPECT freeze-and-stare — NavBrain

**Parity target.** Old stealth pawn, on seeing you sub-hostile: stood
still, locked the cone on you, and let the fuse burn
(`enemy_ai_brain.gd:606-614` + `:2386-2392`). That stand-and-stare is the
readable "I'm being noticed" beat. New pawn keeps patrolling while
suspicion climbs, then *walks toward* the LKP.

**Fix (NavBrain state logic — no new export needed).** In the tick state
dispatch: when no hostile target yet but `_sensed_this_tick` and
`0 < suspicion < 1` → enter SUSPECT with `move_direction = ZERO` and
`_facing` locked on the sensed position (the cone visual follows facing, so
the stare comes free). The existing investigate branch (suspect + LKP +
**not** currently sensing) is untouched — the two conditions are disjoint,
so the composed behavior is: stare while you're in view ramping; break LOS
mid-ramp → walk to your LKP. That's the old beat plus the new search.

Greens/reds have `suspect_time = 0` → they snap hostile the same tick they
sense → the freeze branch is unreachable → **provably no behavior change**
for ported archetypes (same collapse argument the accumulator used).

**Tests.** mocked-sight brain with suspect_time > 0: intent is zero-move
while sensing sub-hostile; facing points at the target; investigate still
walks when sight is cut.

## 5. Chase tucker-out — NavBrain

**Parity target.** Old HOSTILE gave up after `chase_max_duration` (8s),
dropping to a ~3s ALERT scan then CALM — during ALERT it could not
reacquire, giving the player a genuine escape beat. New chase sustains
forever while sensed.

**Fix (NavBrain).** Exports `chase_max_duration := 0.0` (preset 8) and
`tucker_recover_duration := 3.0`. Track `_chase_elapsed` while in
CHASE/WIND_UP; on expiry: `_set_target(null)`, suspicion clamped to just
under `suspect_threshold`, LKP cleared (so it scans, not investigates), and
a `_tucker_cooldown` during which positive sense integration is skipped
(the old cannot-reacquire ALERT window). Suspicion then decays amber→calm
on the existing memory path — visually the old yellow cool-down, driven by
the accumulator instead of a fourth phase enum.

**Tests.** chase a mocked always-visible target > 8s → target dropped,
no reacquire for the cooldown, reacquires after.

## 6. Mid-HOSTILE swarm lock — NavBrain

**Parity target.** Old aggressive sentinels, once HOSTILE
(`enemy_ai_brain.gd:2274-2276`): detection became a raw sphere at
`chase_exit_radius` (36m) — no LOS, no cone, no crouch. Cover did not break
the chase; only distance > 36m or tucker-out did. New sustain still
requires LOS, so ducking behind a wall starts the forget clock — the escape
rules changed under the player.

**Fix (NavBrain awareness).** Exports `hostile_lock_ignores_los := false`
(preset true) + `hostile_lock_radius := 0.0` (preset **54**; 0 = distance
never breaks it). **Invariant (R5 fold-in): `hostile_lock_radius ≥
detection_radius`.** A lock smaller than acquisition decays a
plainly-visible target into a stale-LKP zombie chase (acquire at 40m →
sphere says gone → chase old LKP for 8s in plain sight → forget →
re-acquire → repeat); 54 preserves the old 1.2× detect→exit ratio at the
45m cone. While the flag is set and a target is HELD, the sphere is the
ONLY sustain — no falling back to sight outside it (that reopens the same
oscillation at the sphere edge). In the holding-target branch of
`_update_awareness`: bypass `sense_strength` entirely — `s2 = 1.0` if flat
distance ≤ radius else `0.0`. Mirrors the old code shape one-for-one, and beyond the
radius the normal memory decay takes over (old snapped to ALERT; with §5's
tucker also in play the practical difference is a softer tail — flagged for
the A/B pass).

**Tests.** locked brain with sight mocked *blocked* keeps its target inside
36m, decays beyond it.

## 7. Priority targets — NavBrain

**Parity target.** Old preset: `priority_target_groups = [allies]`,
`priority_target_radius = 10` — a gold ally inside the bubble snaps target
priority even when the player is closer (sentinels execute the gold first).
NavBrain is nearest-wins only.

**Fix (NavBrain targeting).** Same two exports; `_nearest_candidate` gains
a pre-pass: nearest member of the priority groups within the priority
radius wins outright, else fall through to the existing nearest-wins sweep.
(Old also bypassed a 2:1 hysteresis — the nav brain never had that
hysteresis, so there's nothing to bypass.)

**Deferred, same code region, needs a design call:** the old crouched
ally-*filter* (player crouched → sentinels stop pre-targeting golds,
`stealth_sentinel_brain.gd:128`). Doc already lists it as a deferral until
gold-vs-sentinel interplay is exercised. If review wants it now, the clean
cut is exports `stance_filtered_groups: Array[StringName]` +
`stance_subject_group := &"player"` so no literal game knowledge lands in
the brain. Otherwise it stays deferred — noted here so it isn't re-lost.

**Tests.** gold at 8m + player at 4m → gold targeted; gold at 12m → player.

## 8. Cone visual parity — NavConeVisual (LOOK layer only)

**Parity target.** The old fan: 16 slice rays clipped at walls, drawn at
eye height with an apex→rim alpha fade, yaw eased by `lerp_angle`
(0.15s), shrank with crouch, fluorescent-flickered on crouch entry,
stochastically flickered out during a hack, truth-scale radius,
`ALPHA_DEPTH_PRE_PASS` so walls occlude it. The new fan has none of that.

**Fix — rebuild the renderer, keep the contract.** NavConeVisual stays a
sibling component consuming `perception_view()` and writing **nothing**
back. Raycasts are reads; the component remains removable-without-
behavior-change by construction.

- **Wall clipping**: the visual casts its own `segments + 1` slice rays per
  frame from `eye_height`, clipped at first hit — a direct port of
  `_compute_slice_distances` (`enemy_ai_brain.gd:2407`) into LOOK, parent
  body RID excluded. Detection LOS stays the brain's single ray: the old
  brain's *primary* detection path was already the direct 3D ray
  (`enemy_ai_brain.gd:716`, slice fallback only ever broadened it), so
  splitting truth from picture does not change what the sentinel sees.
- **Mesh**: ImmediateMesh rebuilt per frame (as old), one triangle per
  slice reaching its clipped distance; per-vertex color, apex at phase
  alpha × alpha-mult, rim at 1% — the radial fade. Material ported
  verbatim: `vertex_color_use_as_albedo`, `TRANSPARENCY_ALPHA_DEPTH_PRE_PASS`,
  unshaded, cull off.
- **Smooth swivel**: the visual keeps its own smoothed yaw —
  `lerp_angle` toward `view.facing` with export
  `swivel_smoothing := 0.15`. After §4, brain facing already locks on the
  target during the stare and sweeps during the pause scan, so the old
  SUSPECT cone-lock behavior falls out of the same field.
- **Crouch shrink**: free — §2 makes `perception_view()` report effective
  range/arc; the fan rebuild triggers off exactly those values. The
  crouch-entry fluorescent flicker pattern (`enemy_ai_brain.gd:2739`,
  with the 1s debounce) ports verbatim, edge-triggered off
  `view.target_crouched`.
- **Hack flicker**: from `view.hack_active/hack_progress` (§1), the old
  envelope verbatim: 35%-per-tick dropout at `(1 - progress)` alpha,
  hard 0 at progress ≥ 1 (`enemy_ai_brain.gd:2668`).
- **Draw height**: default `draw_height` moves from 0.15 (feet) to the eye
  height used for the rays, so low cover blocks the *drawn* slices exactly
  where it blocks the old ones — the "fan stops at the crate" read.
- **Perf guard**: slice rays only when the fan is on-screen-ish — skip
  raycasts (draw nothing or a plain fan) beyond a camera-distance export
  (~60m). Old cost was identical (17 rays × pawn × tick) so this is
  strictly better than shipped behavior.

**Tests.** Visual components have no headless test seam; the gate is the
smoke boot + eyeball pass in §9. The one assertable contract — visual
never mutates brain state — is already structural (no writes exist).

## 9. Preset re-tune + A/B — config only

Numbers drifted during the port and some were compensating for the missing
crouch model:

| knob | old sentinel | current nav | resolved (R5 synthesis) |
|---|---|---|---|
| detection range | 30 (×0.5 crouched = 15) | 45, stance-blind | **45** standing + crouch mult **0.33** (= 15 crouched, the exact old sneak envelope) |
| cone arc | 100° (×0.3 crouched) | 100°, stance-blind | 100° + crouch mult 0.3 |
| eye height | 1.0 (waist — low cover blocks) | brain default 1.4 (preset doesn't set it — R10) | explicit `eye_height = 1.0` in the preset |
| hostile zone | 20m instant | none | 20m (§3) |
| chase give-up | 8s tucker | never | 8s (§5) |
| chase lock | sphere 36m, no LOS | LOS-gated | ignores-LOS + **54m** (§6 invariant: lock ≥ detection; 1.2× ratio preserved) |
| cone draw scale | 1.0 (truth) | 0.5 (half-size lie) | **1.0** |
| cone colors | green/yellow/red @ 0.30-0.40α | cyan/amber/red | old palette |

RESOLVED (Ryan, 2026-07-25): 45m standing was the intentional direction
(paired with skin-tint telegraphing), so the synthesis stands — keep 45,
restore the crouched 15m via the multiplier. If the A/B says standing-45
reads unfair even with color telegraphing, drop to 30/0.5 then — as an A/B
outcome, not a default. All live-tunable via F10 + Remote-tree.

Acceptance: A/B on level_2 against a hand-restored old sentinel (old brain
preset is one inspector revert away, per the port procedure) — cone reads
identically through walls/crouch/hack, sneak-past and backstab loops play
the same. Plus the standing test gates: both nav tests green, greens/reds
untouched (every new export defaults to off/1.0 — parity by default), boot
level_1/level_2/default with no SCRIPT ERROR.

## 10. F3 debug labels — game-side component

Port the Label3D overlay (`enemy_ai_brain.gd:2763-2811`) as
`enemy/nav_debug_label.gd`, a sibling listener like `alert_tint.gd`
reading `perception_view()` + state (archetype / state / suspicion / dist),
with its own static `debug_visible`; `game.gd` F3 flips both statics.
Low priority, big QoL while tuning §9.

## 11. Perf governance — deferred, measure first

Old per-brain machinery (anim LOD to 20Hz, off-screen animation pause,
distance tick bands) didn't port; nav has `wander_tick_every` and the
crowd gym's `EnemyDistanceSleep` only. Per the debugging protocol: no
build until a measured need — profile level_2 with 8 sentinels; if frame
time says so, build the shared **PerfGovernor** body component the doc
already calls for (edge case #6), usable by both brains during the
transition. Explicitly out of scope for this parity pass.

---

## Sequencing — one PR-sized change per step, each gated

1. **§1 hack hooks** — smallest fix, biggest player-facing break restored.
2. **§2 + §3 perception crouch model** — pure-logic + unit tests.
3. **§4 + §5 + §6 + §7 NavBrain states/targeting** — behavior parity,
   each with its `test_nav_brain.gd` case.
4. **§8 cone visual rebuild** — lands last among code so it can render the
   already-correct effective values; zero behavior risk by construction.
5. **§9 preset retune + level_2 A/B** — the acceptance gate for the whole
   pass.
6. **§10** opportunistic; **§11** deferred.

Every step: `/Applications/Godot.app/Contents/MacOS/Godot --headless`
smoke grep for SCRIPT ERROR, full test sweep, and tscn files re-Read after
edit (doubled-override anti-pattern).

---

## Review comments (Claude, 2026-07-25)

Verdict: the plan is sound, the layer cuts are correct, and the sequencing
is right. I verified the load-bearing premises at the source before
commenting: `stealth_kill_target.gd` duck-types exactly
`set_hack_active(active: bool, progress: float)` and `is_chasing() -> bool`
via lazy child scans that today no-op silently (`if _brain_cached == null:
return`) — §1's signatures and its hardening rationale are both accurate.
The suspect_time=0 collapse arguments in §3/§4 are valid; every new export
defaulting to off/1.0 keeps greens/reds provably untouched. Specific
comments, most severe first:

**R1 — §1 ordering bug waiting to happen: the freeze check must sit BEFORE
the wander-stagger early-return.** `tick()`'s perf stagger returns the
*previous* intent on skipped frames. If the freeze gate lands after it (the
plan says "after edge-flag clearing", which is before the stagger — keep it
that way and say so explicitly), a WANDER-state pawn frozen mid-stagger
window would replay its last non-zero move for up to `wander_tick_every`
frames: a hacked sentinel that keeps strolling. One-line placement rule,
worth a dedicated test case (freeze while mid-patrol, assert zero move the
same tick).

**R2 — missing item: conversion shed for every new export.** `set_faction`
currently sheds `cone_deg` / `wander_style` / `suspect_time` on conversion.
This plan adds crouch multipliers (§2), `hostile_zone_radius` (§3),
`chase_max_duration` (§5), and `hostile_lock_ignores_los` +
`hostile_lock_radius` (§6) — none of which are in the shed list. A
GOD-blast gold that keeps a 20m instant-hostile zone and a 36m no-LOS lock
is a hyper-aggressive ally bug. Either extend the guarded-poke list (the
cached-default pattern scales, but this is now ~9 keys), or accept that the
poke list has outgrown itself and route nav-pawn conversion through
`replace_brain(nav_gold.tscn)` the way legacy stealth already does — one
mechanism, zero per-key bookkeeping, and the "total conversion, no residue"
comment in `player_body.gd` becomes true for both brain generations. I lean
replace_brain; either way this must land in step 3, not after.

**R3 — §5/§3/alerts interplay: the tucker cooldown must gate all three
reacquisition paths.** The plan gates "positive sense integration." The
hostile-zone snap (§3) lives in the acquisition branch and must respect the
cooldown, and — new since the old brain — `receive_alert()` can bump a
tucker-dropped sentinel straight back to investigating, which un-does the
escape beat the tucker exists to create (old ALERT could not reacquire *at
all*). Recommend the cooldown suppresses snap, integration, AND incoming
alerts; peers who are themselves hostile are unaffected.

**R4 — §6, say the quiet part out loud:** the swarm lock deliberately
reinstates the memory-window wallhack for locked hostiles (steering at true
position with no LOS). That's correct — it IS the old escape ruleset the
player learned — but the LKP anti-wallhack behavior shipped this session as
an all-archetype improvement, so the plan should state explicitly that
locked stealth *suspends* it inside 36m and the A/B should check that
ducking cover inside the radius feels like the old game, not the new one.

**R5 — §9, the 45m revert re-litigates an explicit design call.** The 45m
stance-blind cone wasn't port drift — it was Ryan's stated direction this
session ("we could extend their vision cone" once skin color telegraphs
state). Recommend the synthesis instead of the revert: keep 45m standing
and set `crouch_range_multiplier ≈ 0.33`, giving crouched ≈ 15m — the
*exact* old sneak envelope the loop was tuned against, plus the intended
hotter standing cone. If the A/B says standing-45 reads unfair even with
color telegraphing, drop to 30/0.5 then — but as an A/B outcome, not a
default. On `radius_scale` 1.0 (truth-size fan): agreed, the 0.5 was my
readability guess and wall-clipping (§8) solves what it was guessing at.

**R6 — §2 implementation note: perception is per-candidate, the view is
not.** Effective range/arc depend on *whose* stance is being evaluated;
`perception_view()` needs a "last evaluated target stance + effective
numbers" memo (set alongside `mark_sensed`) or the visual will flicker
between candidates in crowds. Trivial, but decide it consciously.

**R7 — §4, emergent behavior worth blessing:** hearing-triggered sensing
(behind, ≤10m, standing) now produces freeze-and-stare with `_facing`
locked toward the *sound* — the sentinel visibly turns its cone toward a
noise behind it. That's better than the old brain (which only did this for
sight) and exactly the readable beat hearing should have. Confirm intended,
then keep it.

**R8 — §8 minor:** skip the slice raycasts when `visible_mode == NEVER`
and in the `WHEN_SUSPICIOUS` hidden state, not just beyond camera distance
— 17 rays × 12 stealth pawns on level_4 is only ~200 rays/frame, fine, but
free is free. Also note the fan currently parents to the body root:
per-frame ImmediateMesh rebuild in body space is correct as planned since
slice distances change with world geometry every frame anyway.

**R9 — tests: add one composed sequence case.** Each §-gate passes
individually, but the interactions are where this plan lives: a single
scripted run (mocked sight) asserting stare → LOS cut → LKP walk →
reacquire → 8s tucker → no-reacquire window → clean reacquire would have
caught R1 and R3 by construction. Cheap insurance on top of the unit gates.

**R10 — one small omission in §9's table:** old eye height 1.0 is listed,
but `nav_stealth.tscn` today doesn't set `eye_height` at all (brain default
1.4) — add the explicit `eye_height = 1.0` line to the preset diff so the
low-cover LOS behavior actually changes with the retune.

With R1–R3 folded in, I'd call this plan ready to execute in the proposed
sequence.

---

## Resolutions (accepted 2026-07-25, Ryan sign-off — plan is now executable)

- **R1 accepted +addendum**: freeze gate sits after edge-flag clearing,
  BEFORE the wander stagger (§1 text updated implicitly). Addendum: the
  frozen branch also **consumes `_skip_accum`** so unfreezing doesn't flush
  the whole freeze duration as one giant delta into suspicion decay and
  wander timers; attack/aggro cooldowns still tick inside the frozen branch
  (old brain ticked cooldowns during a hack but froze the alert machine —
  `enemy_ai_brain.gd:560` vs `:581`). Dedicated test included.
- **R2 accepted, replace_brain chosen**: verified `replace_brain` exists
  (`player_body.gd:1409`) and `god_ability.gd:131` already routes legacy
  stealth through it. NavBrain has since grown `follow_subject_group` /
  `follow_distance` + State.FOLLOW, so `nav_gold.tscn` is a pure preset.
  Scope: author the preset; god_ability replaces NavBrain pawns' brains on
  gold conversion; the four new stealth-kit exports (crouch mults, hostile
  zone, chase_max, lock pair) ALSO join the set_faction guarded-poke list
  for non-gold conversions; visual/tint components get a `rewire_brain()`
  hook called by replace_brain (legacy freed its brain-internal cone on
  swap — nav components must re-resolve instead of crashing on a freed
  ref); NavConeVisual hides at cone_deg ≥ 360 (a full disc isn't a cone —
  covers converted pawns and omni brains). Bonus: this fixes the
  already-live bug where god-blasting a nav sentinel yields a
  non-following gold.
- **R3 accepted +addendum**: tucker cooldown suppresses hostile-zone snap,
  positive integration, AND `receive_alert`. Addendum: **`aggro_to`
  punches through** — damage always woke the old brain; it clears the
  cooldown.
- **R4 accepted**: §6 now states the lock suspends LKP anti-wallhack inside
  the sphere; A/B checks cover-ducking inside the radius feels like the
  old game.
- **R5 accepted with consequence fix**: 45m standing confirmed
  intentional; crouch mult 0.33 restores the exact old 15m sneak envelope.
  The synthesis exposed a radius inversion in §6 (lock 36 < detect 45 →
  hostile-decay oscillation on a visible target) — fixed via the new
  invariant `hostile_lock_radius ≥ detection_radius`, preset 54.
- **R6 accepted**: brain computes a per-tick view memo — stance of
  `_target` if held, else the nearest scan candidate — and
  `perception_view()` reports effective range/arc from it. Deduped by the
  brain, so no crowd flicker.
- **R7 accepted/blessed**: hearing-triggered stare stays. Parity footnote:
  the old cone already diverged from the skin during SUSPECT
  (`stealth_sentinel_brain.gd:189` aimed the cone at the target while body
  yaw stayed), so cone-turns-toward-noise-while-skin-doesn't matches the
  old presentation.
- **R8 accepted**: rays skipped in NEVER mode, in WHEN_SUSPICIOUS's hidden
  state, and beyond the camera-distance guard; per-frame body-space
  ImmediateMesh rebuild confirmed as planned. Raycasts + rebuild run at
  physics rate (`_physics_process`) — same cadence the old brain used, and
  direct-space-state queries belong there.
- **R9 accepted**: composed sequence test added to step 3's gate (stare →
  LOS cut → LKP walk → reacquire → tucker → no-reacquire window → clean
  reacquire).
- **R10 accepted**: explicit `eye_height = 1.0` in the preset diff (§9
  table updated).
