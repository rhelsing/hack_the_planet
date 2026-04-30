# Dialogue inconsistencies

Audit of the current dialogue draft against `story/character_brief.md`. Captured for review — **fixes not yet applied**. Each entry has the current text, the problem, and a suggested replacement to discuss.

Updated: 2026-04-29.

---

## Out-of-character moments

### 1. `dialogue/companion.dialogue` — Glitch's L1 hub sign-off says "Cool"

**Current:**
```
Glitch: Cool. Catch you on the other side.
```

**Problem:** L1 Glitch is dry-Alfred — formal, clipped, sardonic (per `character_brief.md` §Glitch / Voice — four-stage arc). "Cool" is L3-eager-show-off vocabulary leaking into L1. Breaks the staged arc the brief is explicit about.

**Suggested replacements (pick one):**
- *"Glitch: Confirmed. Catch you on the other side."* — minimal change, swap one word
- *"Glitch: Acknowledged. Best of luck out there."* — fully formal
- *"Glitch: Right. Catch you on the other side."* — middle ground (recommended)

---

### 2. `dialogue/level_4_nyx.dialogue` — placeholder line is wrong tone

**Current:**
```
Nyx: [L4 Nyx placeholder] You did it. Splice is finished, we're free.
```

**Problem:** Nyx doesn't do triumphal speeches. *"Splice is finished"* contradicts her own canonical line in `hub_post4_nyx.dialogue`: *"For now. Forever's a luxury we don't get on this grid."* And *"we're free"* is the kind of sentimental closure Nyx specifically refuses. Her register at this stage is *measured petty victory*, not *triumph*.

**Suggested replacements:**
- *"Nyx: He's in the box. That works for now."* — dry, measured
- *"Nyx: It worked. He's quarantined. We're not done — but we won the round."* — slightly warmer but still earned (recommended)
- *"Nyx: Splice's locked out. Doesn't mean it's over. Just means we won this one."* — caveats, no triumph

---

### 3. `dialogue/hub_post4_splice.dialogue` — generic-villain trope leak

**Current:**
```
Splice: Yeah. You did. Don't get used to it — perimeters fail.
Splice: I'll remember the move you pulled.
```

**Problem:** Mild. The first line ("perimeters fail") is solid Splice — calm-amused with a specific threat. The second line *"I'll remember the move you pulled"* trails into generic-villain-threat boilerplate. Splice is sharper than that.

**Suggested replacements (pick one):**
- *"Splice: I've already started the next plan. You don't get to know what."* — calm-amused threat with specificity
- *"Splice: You'll see me again. The wall's not as thick as they're telling you."* — undermines the crew's quarantine claim
- *"Splice: This wasn't the version of me you needed to worry about."* — chilling sequel-hook (recommended if a sequel is on the table)

---

## Placeholders / stubs that need writing (not "off-voice", not yet voice)

### A. `dialogue/level_4_dialtone.dialogue` — full-file placeholder

**Current:**
```
DialTone: [L4 DialTone placeholder] You actually pulled it off.
DialTone: [L4 DialTone placeholder] The grid's quieter than I've ever heard it.
```

**Notes:** Both lines are accidentally OK as DialTone-voice — could keep with minor polish ("You actually" is theatrical-DialTone; "quieter than I've ever heard it" has rhythmic compression). Decide whether to keep + polish or replace.

### B. `dialogue/hub_nyx.dialogue::stage_post_3` — full stage stub

**Current:**
```
~ stage_post_3

Nyx: [stub] Post-L3 line for Nyx — placeholder.
=> END
```

**Notes:** Player who refuses Splice in L3 then talks to Nyx in the hub before L4 hits this stub. Needs full content — probably similar in shape to her post-L1 / post-L2 hub conversations (off-channel intimate beat, three-probe menu).

---

## Things scanned and found clean (no fixes needed)

- `dial_tone.dialogue` post_1 / post_2 / post_3 / post_4 clusters — voice holds
- `hub_nyx.dialogue` post_1 / post_2 / post_4 — voice holds
- `level_3_splice_offer.dialogue` (after the splice_nyx beat fix) — voice holds
- `level_4_glitch.dialogue` (after the five surgical tweaks) — peak-glitchy register holds
- `hub_post4_nyx.dialogue` — perfect Nyx
- `hub_post4_splice.dialogue` (other than the "I'll remember" line) — solid Splice
- `level_3_glitch.dialogue` — eager-show-off register holds
- `level_2_glitch.dialogue` — warming register holds
- `level_1_glitch.dialogue` / `_2` / `_3` — dry-Alfred register holds
- `hub_post4_glitch.dialogue` — peak-glitchy / settled register, just authored
- `glitch_2.dialogue` — clean
- `companion.dialogue` other than the "Cool" sign-off
- All 53 walkie nodes across L1/L2/L3/L4 — voice consistent (after the splice4 character fix earlier)
