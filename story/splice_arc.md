# Splice Arc — Levels 2 → 4

Narrative + systems plan for the post-tutorial main story (L2 → L3 → L4).
Pairs with `story/level_one_arc.md` (the rescue prank that establishes the
crew + walkie) and `story/rules_for_dialogue.md` (the menu / probe pattern
all dialogue files follow).

**Core idea:** the player has earned a name with the crew (Glitch +
DialTone + Nyx). The Gibson's old containment routines start failing —
**Splice**, an exiled black-hat with history with Nyx, is back on the
grid and rebuilding control. Across L2 → L4, Splice goes from a voice
on a hijacked channel to a recruiter to an open enemy. The player's
single meaningful choice is at the L3 midpoint: **refuse Splice or
betray the crew.** One ending each.

---

## 1. Cast additions

| Handle | Role | First seen | Voice |
|---|---|---|---|
| **Splice** | Antagonist. Exiled hacker, calm menace, never raises his voice. Used to run with Nyx. Owns enough of the Gibson's routing to push his voice into the player's walkie at will. | L2 mid-level (voice only) | TBD — pick from candidate library, leaning Eric / Brian / Glinda for "smooth-trustworthy-villain" |
| **Nyx (hub presence)** | Joins the hub after L2 — uses the existing CompanionStation ratchet, ratcheting in next to DialTone. Voice on walkie throughout L2-L4. | Hub, post-L2 ratchet | Cecily (already cast) |

Glitch and DialTone keep their existing roles. Glitch stays the
trustworthy tutorial / mechanic-explainer; DialTone stays the
mission-giver and primary walkie voice; Nyx layers in as the
"actually-does-the-work" voice once she's in the hub.

---

## 2. Level 2 — Sneak + Hack, Splice surfaces

**Mechanic emphasis:** stealth, terminal hacking. Player picks up
`powerup_secret` (already in code — the SECRET / hack power-up).

### Beats

1. **Hub → L2 portal** via PedestalSecret. DialTone briefs over walkie:
   "Real thing this time, runner. Skim some clout off a low-tier node.
   Quiet in, quiet out."
2. **Hack terminal #1** — uses the existing puzzle systems (hacking /
   flow / password). Player picks up `powerup_secret`.
3. **Sentinel patrols.** Stealth-leaning section, player avoids or
   hacks past.
4. **Splice intercept (mid-level walkie cut-in):** distorted, calm,
   amused. Doesn't introduce himself yet — just *"Hm. New IP.
   Interesting."*
5. **Crew reaction on walkie.** Nyx: "Who the hell was that?" DialTone:
   "...not a friendly. Keep moving." Nyx introduced as voice.
6. **Splice direct walkie line, names himself.** Comments on the
   player's skill. Polite menace.
7. **Sentinel difficulty spike.** Splice has tweaked routines — the
   level's existing enemies become noticeably harder past this beat.
8. **Final segment: chase.** Splice's elite sentinels hunt the player
   to extraction. Walkie chatter tense — DialTone + Nyx coaching escape.
9. **Escape, back to hub.** `level_2_completed = true`.

### Open implementation tasks
- L2 walkie cue placement (3-5 `WalkieTrigger` zones).
- Splice voice cast + voice ID in `voices.gd`.
- Sentinel difficulty pass — does Splice physically alter the existing
  enemy_kaykit.tscn / enemy_cop_riot.tscn behaviour, or do we drop in a
  new "splice_sentinel" variant? Cheaper option: same enemy scene with
  a `splice_modified: bool` export that bumps speed/damage.
- Nyx in hub: ratchet in via CompanionStation pattern after L2 done.
  New file `dialogue/hub_nyx.dialogue` follows the menu-pattern (see §6).

---

## 3. Level 3 — Grapple + The Fork

**Mechanic emphasis:** grapple hook (`powerup_sex`). Mix of every prior
mechanic — skate + jump + dash + hack + grapple. Two enemy archetypes
formally introduced (the visual cues land here even if Splice's
sentinel tweaks already showed fragments in L2).

### Enemy types (introduced in L3)

- **Red droids** — run-only. They one-shot or overwhelm the player.
  Visual cue: red pulse / outline. Player has no answer to them in L3
  (the answer is the L4 flare gun). Used to gate areas / force routing.
- **Green droids** — fight-able. Punch dispatches. The "antivirus"
  archetype Glitch foreshadowed in `glitch_2.dialogue`.

### Beats

1. **Hub → L3 portal** via PedestalSex. Nyx briefs over walkie (her
   first mission-control beat — DialTone is more recon, she's the
   operator). New gear arriving: grapple.
2. **Pickup `powerup_sex` (grapple).** Tutorial swing.
3. **Mixed-mechanic platforming sections.** Combine all prior verbs.
4. **Mid-level: Splice's offer.** Splice opens a private walkie
   channel (DialTone + Nyx are heard on the channel — Splice can't
   block them, just grandstand over them). Triggers the fork dialogue
   (see §4).
5. **Branch on the choice:**
   - **REFUSED → continue L3.** Splice escalates: red sentinel waves,
     final platforming sequence with mixed enemies. Escape →
     `level_3_completed = true` → hub.
   - **BETRAYED → exit to betray ending scene.** L3's last segment
     never plays. Player is funneled into the walk-of-shame scene
     (see §5). Game ends from there.

---

## 4. The fork — Splice's offer

**The single meaningful choice in the game.** Mid-L3 dialogue with
Splice. Two-step commit on the betray side so curiosity doesn't lock
the player into the bad path by accident.

```
~ splice_offer
  Splice: "Walk with me, runner. Nyx is a relic. DialTone is a court jester.
           You're better than them."
  - Get off my channel.        → splice_refused      (LOYAL — locks immediately)
  - Tell me more.              → splice_consider     (curiosity, not commitment)

~ splice_consider
  Splice: "You'll have the run of the Gibson. They'll be uplinks under your boot. Say it."
  - I'm with you.              → splice_committed    (LOCKS BETRAY)
  - Actually — get off my channel. → splice_refused  (the late-no, still LOYAL)

~ splice_committed
  do GameState.set_flag("betrayed_friends", true)
  Splice: "Excellent. Stay where you are. I'm coming for you."
  → END  → triggers betray ending scene transition

~ splice_refused
  do GameState.set_flag("refused_splice", true)
  Splice: "...pity."
  (DialTone + Nyx hear the whole exchange — channel is open both ways.
   The act of refusing IS the confession. No separate "tell them" beat.)
  → END  → continues L3
```

**Implementation:** new `dialogue/level_3_splice_offer.dialogue`. Trigger
fires from a `DialogueTrigger` placed at the appropriate L3 mid-point
(after grapple tutorial, before the final segment). On END, a script on
the trigger checks `betrayed_friends` and either spawns the betray
ending scene transition or lets play continue.

---

## 5. Level 4 — Loyal endgame OR Betray walk-of-shame

### 5a. Loyal path — `level_4`

**Mechanic:** flare guns (`powerup_god`). Trivializes green droids,
counters red droids for the first time.

Beats:
1. **Hub → L4 portal** via PedestalGod (which is now lit because
   `level_3_completed` fired in the loyal branch).
2. **Walkie cue:** DialTone — "Splice is consolidating. We push now or
   we don't push."
3. **Pickup `powerup_god`.** Tutorial fire — burst a green droid
   trivially. A previously-red droid that was untouchable becomes
   shootable.
4. **Splice's stronghold.** Mix of all enemy types, dense.
5. **Splice confrontation.** Boss arena OR a final terminal where the
   player overwrites Splice's privileges and **quarantines** him —
   contains him without destroying him. Sequel hook lives.
6. **End:** `level_4_completed = true`. Returns to hub for the final
   DialTone scene (see §6).

### 5b. Betray path — `level_betray_ending.tscn` (NEW SCENE)

**Cheap, intentional cheap.** Single scripted scene, ~90 seconds.
No L4 proper.

**Setup:** linear corridor or descending tunnel. Splice walks ~3m
ahead, never quite reachable. The player follows.

**Mechanics override:** PlayerBody enters a "compelled walk" state.
- Input ignored except to advance (forced forward at ~1 m/s).
- Punch / dash / jump disabled.
- Camera locked behind the player.
- Implementation hook: new method `PlayerBody.enter_betrayal_walk()`
  that flips a flag the brain reads — brain ignores input axes,
  disables attack/jump/dash intent. Scene script flips it on entry.

**Scripted dialogue beats** (timed, walkie + cinematic audio):

| Beat | Speaker | Line |
|---|---|---|
| 1 | Splice (smug) | "There you are. I knew you'd see it." |
| 2 | DialTone (cold, no patter) | "Channel's open. Wanted you to hear me say it. You sold us." |
| 3 | Splice | "What's a runner without a contract? You belong to me now." |
| 4 | Glitch (clinical, hurt) | "I had hoped my analysis was wrong. It was not." |
| 5 | Splice | "We start with the lower nodes. By morning we'll own the dial-up." |
| 6 | Nyx (final, quiet — lands hardest) | "I rooted for you. Whatever. Bye, runner." |
| 7 | Splice | "Keep walking. The throne room's just ahead." |

**End:** player reaches a terminal at corridor's end → screen fades →
**"The Gibson is yours. Population: 1."** → credits / main menu.

No save-slot recovery. Game over. Player can start a new run from
main menu and pick differently.

---

## 6. Hub dialogues — the ratchet

### 6a. DialTone (existing file, refactored)

`dialogue/dial_tone.dialogue` follows `story/rules_for_dialogue.md`
menu pattern. All five stages are wired:

- `~ stage_intro` — handle pick + Nyx-rescue mission framing + intro
  menu (Onward / Who's Nyx / What am I looking for / Why can't you go).
  Sign-off: walkie hand-off + 3 flag sets.
- `~ stage_nudge` — one-liner if greeted but L1 not done.
- `~ stage_post_1` — prank reveal. Menu: Onward / Want to explain /
  She said dead man.
- `~ stage_post_2` — Splice surfaces, near miss. Menu: Onward / Who is
  Splice / How did he get into sentinels / You weren't expecting him.
- `~ stage_post_3` — loyal-only. Menu: Onward / Why'd you let him talk
  to me alone / What's his angle / You didn't think I'd take it.
- `~ stage_post_4` — quarantine outcome. Menu: What now / Where's Nyx /
  About Splice — he's still in there / Sign me out. Final flag set:
  `game_completed`.

The betray path never reaches `stage_post_3` or `stage_post_4` —
`splice_committed` exits to the betray ending scene before the player
returns to hub.

### 6b. Nyx hub dialogue (NEW FILE)

Nyx ratchets into the hub after `level_2_completed`. Uses
CompanionStation pattern (same as Glitch1 → Glitch2).

**File:** `dialogue/hub_nyx.dialogue` (new). Follows menu pattern.
Sub-stages keyed off `level_2_completed`, `level_3_completed`,
`level_4_completed`, `betrayed_friends` (which she'd never see — but
worth scaffolding the if-branch for safety).

**Sketch:**

| Stage | Greet | Menu probes |
|---|---|---|
| Post L2 (just arrived in hub) | "Heard the new voice on the channel. Splice." | About Splice / Why now / What you don't know about him / Onward |
| Post L3 (after refusal) | "Knew you'd say no." | Why so confident / What's your history with him / Onward |
| Post L4 (quarantine) | "Not bad, runner." | What happens to him now / About DialTone / Onward |

### 6c. Walkie content

Walkie lines are short, one-way (per `story/rules_for_dialogue.md`
TBD section — the walkie spec). Drop `WalkieTrigger` zones in level
geometry to fire them. Per-level rough budget:

- **L2:** ~6 walkie cues — opening brief, mid-level Splice intercept,
  Nyx reaction, Splice direct line, chase opening, escape.
- **L3:** ~5 walkie cues — opening brief, grapple acknowledgment,
  pre-Splice-offer warning, post-fork reactions (loyal branch only),
  escape.
- **L4 (loyal):** ~4 walkie cues — opening, flare gun pickup
  acknowledgment, mid-level escalation, pre-quarantine commit.
- **L4 (betray):** the 7 scripted lines in §5b. No walkie triggers —
  fully linear scene script.

Walkie line authoring is a v1.5 task — placeholders fine for v1.

---

## 7. Open decisions

1. **Splice voice** — TBD. Pick from candidate library.
2. **Splice's L4 confrontation shape** — boss arena vs final terminal
   override. Boss arena is more dramatic, terminal is cheaper. Decide
   when L4 geometry starts.
3. **Sentinel difficulty modulation in L2/L3** — `splice_modified`
   bool on existing enemy variants vs new enemy scenes. Default to the
   former for v1 cost.
4. **Nyx hub model** — does she keep the universal_female_skin
   placeholder or get a final art pass before hub debut?
5. **Betray ending music + visual treatment** — currently spec'd as a
   scripted corridor with audio only. Could be more cinematic (camera
   pulls back, fade through the player) — depends on how much polish
   we want on the bad ending.

---

## 8. Shipping order

Cheapest-to-most-expensive, each verifiable in isolation:

1. **DialTone post_2/3/4 hub dialogues** — already shipped (this doc's
   update pass). Smoke: open hub at each stage flag, walk the menus.
2. **Nyx hub dialogue + CompanionStation in hub.tscn** — new file +
   one CompanionStation node + one ratchet wire. Smoke: complete L2,
   return to hub, see Nyx ratchet in.
3. **Splice voice cast + voices.gd entry** — one-line config. Smoke:
   any line spoken by `Splice` synthesizes correctly.
4. **L2/L3/L4 walkie line content** — placeholder lines per beat,
   stored in WalkieTrigger nodes in level scenes. Lock voice cast first.
5. **`level_3_splice_offer.dialogue`** — the fork. Smoke: trigger
   fires both branches in editor, flags set correctly.
6. **PlayerBody.enter_betrayal_walk()** — movement-lock hook. Smoke:
   call from console, player stuck on forward-walk, can't punch/jump.
7. **`level_betray_ending.tscn`** — corridor + scripted dialogue
   timing + end-of-game transition. Smoke: enter scene with
   `betrayed_friends=true`, scene plays through to end card.
8. **L4 loyal endgame content** — Splice confrontation / quarantine
   terminal + cinematic. Last because it's the most level-design work.
