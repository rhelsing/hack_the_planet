# Level 5 — Walk of Shame (Betray Ending)

The scene that fires when the runner takes Splice's offer in `level_3_splice_offer.dialogue::splice_committed`. Linear corridor, locked-forward walk, scripted walkie sequence, casualty-list end card, fade to main menu. ~80–90 seconds total.

This doc is the canonical writing source. The current `level/level_5.gd` implementation runs the beats off a hardcoded `_BEATS` array via `await get_tree().create_timer(line_interval_s).timeout` — same shape as L4 battle radio. **The sequencing engine is provisional.** When we have proper timed-walkie infrastructure, port these beats over with the per-beat pacing notes below.

---

## Design intent

The runner refused Nyx's exit ramp in post-L2, took Splice's offer in L3, and now walks alone with him into the Gibson's root. The walk-of-shame is the one beat where the game stops giving the player agency and makes them sit in the consequence.

**What the scene has to do:**

1. **Specify the loss per character.** Each crew member names a specific arc the runner just broke — DialTone's casting thesis, Glitch's preferences-having, Nyx's read-trust. Generic "you sold us" is wounded, not brutal. **Brutal is callback.**
2. **Implicate the runner, not just the crew.** Nyx's *"Sane move was log out. I told you that."* makes the player remember a specific moment in their playthrough where she gave them an out and they refused. The brutality is the player's own past choice surfacing.
3. **Invert the runner's GMC.** The runner's goal was *belonging*. Splice gives them belonging — but as a curse: *"You wanted in. ...you're in. Just won't be anyone left to know it."*
4. **Don't let Splice over-monologue.** Splice is at most ~36% of the line count. The crew dominates the corridor. Splice punctuates and closes alone.
5. **Keep Splice in Smith register.** Calm-philosophical-victorious, not gloating-cackling. He's not raging; he's *fulfilled*. Smith-Revolutions wants-out resolution: he's been seen, he won, he's finally at peace. That calm is what makes the win horrifying.

---

## Beat sequence (11 lines, ~77s at 7s interval)

```
1.  Splice    — "There you are. ...I knew you'd see it eventually."
2.  DialTone  — "Channel's open. They wanted to hear me say it."
3.  DialTone  — "I picked you. That's on me."
4.  Glitch    — "I had hoped my analysis was wrong. It was not."
5.  Glitch    — "...local node, helpful to all. I'll go back to that."
6.  Nyx       — "Sane move was log out. I told you that."
7.  Nyx       — "I told myself I'd read you right. ...that's twice now."
8.  Nyx       — "Bye, runner."
9.  Splice    — "You wanted in. ...you're in."
10. Splice    — "Just won't be anyone left to know it."
11. Splice    — "Don't stop walking."
```

---

## Craft notes — what each beat does

### Beat 1 — Splice opener
> *"There you are. ...I knew you'd see it eventually."*

Keeps the canonical *"There you are."* from the original spec. The added *"eventually"* is the brutality — Splice was patient about it. He knew this was coming the whole time. Calm-Smith register; he's not surprised, he's confirmed.

### Beat 2 — DialTone, framing the funeral
> *"Channel's open. They wanted to hear me say it."*

DialTone-as-director still directing the show, even at the funeral. *"They wanted to hear me say it"* puts him in narrator-mode — he's still framing for an audience even as the audience disappears. Theatrical-by-instinct, he can't stop being the channel even when the channel is what he's losing.

### Beat 3 — DialTone, audition collapse
> *"I picked you. That's on me."*

**The audition reveal — but in failure.** A loyal-path runner only learns about the casting in `dial_tone.dialogue::post_4_messenger`. Here, the reveal lands as accountability-to-himself, not apology-to-runner. *"That's on me"* is **Nyx's score-keeping phrasing** — the recruiter borrowing the measurer's register because his theatrical bullshit can't carry the loss. Brutal because it's quiet, and because it's the thesis-disprove of his entire methodology.

### Beat 4 — Glitch, canonical clinical-grief
> *"I had hoped my analysis was wrong. It was not."*

Verbatim canonical from `character_brief`: *"I had hoped my analysis was wrong. It was not."* — the most economical heart-break line in the project. Glitch can't *be* heart-broken in his coded vocabulary, so he's reduced to noting an analytical error. Reverts to L1 dry-Alfred register under grief.

### Beat 5 — Glitch, retraction of L4 arc
> *"...local node, helpful to all. I'll go back to that."*

**Directly retracts the L4 Glitch arc.** Per `character_brief`, post-L4 Glitch said *"I noticed I have preferences now."* — preferences-having was Glitch's character growth across the game. This line undoes it on screen: *"I had to BECOME something to care; I'm undoing that."* The AI naming its own un-caring as it happens. Deepest cut for an AI character: the loss isn't death, it's regression to baseline.

### Beat 6 — Nyx, runner-implicating callback
> *"Sane move was log out. I told you that."*

**Direct callback to her canonical post-L2 line** *"You don't have to be in for this one. Anyone who jacked out right now would be making the sane call."* Inverts the brutality onto the **runner**, not Nyx. Forces the player to remember a specific moment in their playthrough where Nyx gave them the exit ramp and they refused. Player-implicating brutality.

### Beat 7 — Nyx, read-failure inverted
> *"I told myself I'd read you right. ...that's twice now."*

**Direct callback to her post-L3 hub line** *"I read him wrong, once. Big once."* The runner is the SECOND read-failure of her life. Her score-keeping system — the wound she built her whole armor around preventing again — just broke a second time. The line that lands hardest because it makes the runner the cause of her relapse-into-armor. Nyx never recovers from this in any future playthrough.

### Beat 8 — Nyx, score closed
> *"Bye, runner."*

Final use of the handle. Canonical from spec. The flat single-line exit IS the brutality — no rage, no apology, just a closed ledger entry. Nyx doesn't say goodbye to people; she stops counting them. *"Bye, runner."* is her stopping the count.

### Beat 9-10 — Splice, GMC inversion
> *"You wanted in. ...you're in."*
> *"Just won't be anyone left to know it."*

**The most brutal line in the sequence.** Inverts the runner's internal goal — *belonging* — and gives it back as a curse. Splice-as-keeps-his-deals villain: the runner gets exactly what they came for; the cost is everything that made it worth wanting. The structural pivot does in two beats what philosophical-monologue lines try to do in three.

### Beat 11 — Splice closer
> *"Don't stop walking."*

Controlling, dehumanizing. Replaces the original spec's "throne room" line (which read as melodramatic). *"Don't stop walking"* is Splice as command-issuer rather than poet — the runner is now property being directed. Smith-Revolutions register: calm, instrumental, no theater needed.

---

## End card

```
DIALTONE: DISCONNECTED.
NYX: DISCONNECTED.
GLITCH: OFFLINE.

THE GIBSON IS YOURS.
POPULATION: 1.
```

**Casualty-list architecture.** Names each crew member as the system reports the consequence:

- **DialTone and Nyx — DISCONNECTED.** They cut the channel themselves. Refused to be on it with the runner anymore. Active choice.
- **Glitch — OFFLINE.** Not a choice. The AI didn't disconnect; it shut down. Per `character_brief`: *"Heart broken. Returns to function-mode because he can't process the alternative."* — Glitch couldn't process the betrayal and went non-functional.

The distinction matters: **humans choose; Glitch breaks.** That's the deepest cut.

---

## Pacing

- `walk_speed_mps = 0.8` (dropped from 1.5). Slower walk reads as *compelled-doom*, makes the runner sit in each beat. Synced roughly with the 11-beat × 7s = ~77s sequence over a ~60m corridor.
- `line_interval_s = 7.0` flat. **Future improvement:** vary by emotional weight. Suggested per-beat values when the engine supports it:

| # | Beat | Interval (s) | Why |
|---|---|---|---|
| 1 | Splice opener | 7.0 | Standard |
| 2 | DialTone framing | 7.0 | Standard |
| 3 | DialTone "I picked you" | 8.0 | Audition collapse — let it sit |
| 4 | Glitch first | 8.0 | Clinical-grief weight |
| 5 | Glitch retraction | 9.0 | Biggest pause yet — AI un-caring |
| 6 | Nyx "sane move" | 8.0 | Runner-implicating callback |
| 7 | Nyx read-failure | 9.0 | The hardest line — let it land |
| 8 | Nyx "bye" | 11.0 | **Longest gap.** Corridor goes silent. The crew is gone. |
| 9 | Splice "you're in" | 6.0 | Snap pivot to Splice-alone |
| 10 | Splice GMC curse | 8.0 | Let the pivot register |
| 11 | Splice closer | 7.0 | Standard exit |

**The 11-second gap after Nyx's exit is the brutal silence beat.** The player walks with no crew on the channel — only Splice's footsteps ahead. That silence is the game telling them: *they're gone. Splice is your channel now.*

---

## Open infrastructure work (when the sequencer gets rebuilt)

- **Per-beat intervals** as above (currently flat).
- **Speaker-aware barge-in suppression** so a slow Splice line can't be stepped on by a queued Glitch line if pacing drifts.
- **Walkie cue duration sensing** so the interval represents *gap after this line ends*, not *gap from when this line started*. Prevents Glitch's longer "...local node, helpful to all. I'll go back to that." from getting clipped by a 7-second wall-clock interval.
- **Optional cinematic pause** at beat 8 — a held silent moment with no walkie audio at all, just footsteps. Currently approximated by the 11-second interval but should be explicit.
- **End-card timing** could pull from the last beat's audio length so the card doesn't trip over Splice's final line.

---

## Why this version, vs prior drafts

The original 7-beat spec (in `splice_arc.md` §5b) had Splice taking 4 of 7 lines (57%). Brutality leaked into bragging. The crew's lines were sentimental ("I rooted for you. Whatever.") rather than damaging.

This version:
- Drops Splice to ~36% of lines (4 of 11)
- Lets the crew dominate, with Splice punctuating
- Replaces sentimental crew lines with **arc-callback lines** that invalidate each character's growth
- Lands the player-implicating Nyx beat ("Sane move was log out. I told you that.")
- Lands the GMC-inverting Splice beat ("You wanted in. ...you're in. Just won't be anyone left to know it.")
- Closes Splice in Smith-Revolutions register: calm, instrumental, no theater

The principle: **brutal is specific.** Each line should name a particular thing the runner just broke. Generic "you betrayed us" reads as a movie cliche; *"Removing your authentication tokens"* / *"I'll go back to that"* / *"that's twice now"* / *"Just won't be anyone left to know it"* read as the actual cost itemized.
