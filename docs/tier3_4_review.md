# NEXT UP — Tier 3 & 4 (filtered)

Filtered to **actionable next steps only**. Items already shipped or punted to scope are at the bottom for reference. Last update: 2026-04-30.

Three buckets:
1. **Quick clarifications** — one user line each unblocks a one-minute edit
2. **Small numeric/wiring tweaks** — designer says the value, I apply
3. **Discrete content/feature wires** — bigger but bounded, single sitting

---

## 1. Quick clarifications — unblock with one line each (12 items)

These are dialogue text edits I cross-referenced and located, but couldn't apply without a design call. Each is a single-line answer from you, then a 30-sec edit.

| # | Question I need answered |
|---|---|
| 66 (rest) | Should I sweep ALL dialogue files for "we are gonna" → "we're gonna" and similar contractions? Or only the L1 Nyx line you flagged? |
| 68 | Mission framing → "hacking financial data". Is this a rewrite of the Glitch L1 platform pitch, the L2 mission brief, or both? Give me one sentence of the new framing. |
| 78 | Where's the duplicate "we move when you do"? I only found one in `dial_tone.dialogue:271`. Is the second instance maybe verbal-paraphrase that I missed? |
| 79 | "Got it" → "not a chance" at end of Splice convo. `level_3_splice_offer.dialogue` has multiple "Got it." choices (in `splice_consider`, `splice_catch`, etc.) — which one? |
| 83 | Nyx's "I'm not seeing him on my end either." Add a preceding DialTone line so it's a response, OR reword Nyx to stand alone? Pick one. |
| 90 | "Never mind" probe — where? Which dialogue file, which menu? |
| 92 | "Still in one piece?" — I can't find this verbatim. Is this a NEW Nyx line you want added to `level_2_nyx.dialogue` post-rescue, with player "thanks" before her next line? |
| 95 | "Hot shot" on L1 walkie — replace with what? Current: *"I see the hot shot has blades now."* `level_1.tscn:181` |
| 97 | Glitch L3: "cool check it out, jump on the platform next to me" should chain to "brilliant it worked". Both lines exist separately. Do you want me to add a flag-trigger so the platform-arrival fires the second line? |
| 98 | After-first-power-up Glitch walkie "come chat with me" — needs a new WalkieTrigger. Where (which level, which approximate position)? Gated on which flag? |
| 99 | "Glitch hint of weirdness in L2 dialogue" — what specifically? L2 Glitch is in warming register per character_brief; you want a small peak-glitchy seed, but where in the file? |
| 181 | Nyx's "..." lines — which specific lines do you want reviewed? There are 10+. Want me to list them and you mark which need rework? |

---

## 2. Small numeric / wiring tweaks — fast once you say the values

These are one-node editor tweaks. Trivial in the editor, also trivial for me to apply if you give me the value.

### Puzzle tuning
| # | Item | Tell me |
|---|---|---|
| 101 | Loki puzzle — less time | New time value (or % cut)? |
| 102 | Fizz Buzz puzzle — half the time | Confirm "half" or specific seconds? |
| 103 | Terminal 3 — shorten 40% | Which terminal is "Terminal 3"? `terminal_hack` / `terminal_the` / `terminal_planet`? |
| 104 | Terminal 4 — shorten 40% | Same — which terminal? |
| 106 | Maze cursor speed — slower | Current value vs new value? |
| 109 | gibson.log puzzle L4 — verify duplicate | Want me to diff the maze content against the others and flag if it's a copy? |

### Audio
| # | Item | Tell me |
|---|---|---|
| 110 | Phone booth volume −50% | Locate the AudioStreamPlayer3D, dial volume_db. Want me to do it? |
| 116 | Bounce effect 1 broken — remove, cycle 2/3/4 | Which bounce SFX file? Show me where the "1" is referenced. |
| 117 | "E Hack" behind sentinel glitch SFX | New SFX asset, or reuse existing? Which file? |

### Skip / Flow (small wires)
| # | Item | Tell me |
|---|---|---|
| 148 | Walkie above L4 portal — gate on "talked to Glitch" | Confirm the flag name (`l4_glitch_pitched` or another)? |
| 149 | Nyx "oh God this isn't good" walkie — relocate to Splice walkie position, remove after puzzle done | Confirm which Splice walkie's position to copy + which puzzle's "done" flag |
| 150 | Portal shows only when DialTone says "your portals queued behind us" | Confirm which portal node + which flag (post_2_plan path) |
| 154 | Nyx walkie L3 — shouldn't open extraction beacon | Which walkie? What does "open extraction beacon" mean — UI element to suppress? |

---

## 3. Discrete bounded features

| # | Item | Notes |
|---|---|---|
| 146 | Hold E/X to skip on intro videos / AV references | Add long-press handler to `Cutscene.show_video` flow. ~30 LOC. |
| 147 | Respawn hints — play immediately on response, no delay | Find the delay in respawn message overlay; cut it. Probably one-line. |
| 151 | Dialogue completion state — "anything else?" / exit | This is the same feature as Tier-1 #21. Bigger — needs design. |
| 152 | Control portal — verify unpowered step doesn't trigger gold conversion | ✅ already verified — `control_portal.gd:128-129` gates `_apply_conversion` behind `require_flag`. Mark resolved? |
| 153 | Can't talk to Nix until Dial Tone first (post-L2) | Same as Tier-1 #20. Add a `require_flag` gate to Nyx hub interactability post-L2. |

---

## 4. Visual position tweaks (defer or batch)

These are all single-node `transform` edits in the editor. Faster for you to do in the inspector than for me to do blind. Listed here as a checklist:

128 (fog distance), 129 (camera margin), 130 (disc glow), 131 (pink glow), 132 (crumble drop speed), 133 (orange platforms L1), 134 (balance platform L2), 135 (phone booth radius), 137 (telephone L4 height), 138 (god object), 139 (Splice pedestal forward), 140 (L4 first bouncy), 142 (walkies before 6th powerup), 143 (grinding anim), 145 (endgame fog).

If you want me to handle any specifically, call them out.

---

## 5. Content additions (deferred)

155 (more coins), 156 (cans on L3+L4), 157 (kick NPC bounce-back anim), 159 (high-up wall bug), 160 (final jump platforms allies), 161 (endgame too long), 162 (yellow allies invuln), 165 (Splice parsing), 167 (DialTone L1-top voice note).

These are scope-y. Pick any to escalate.

---

## Reference — what already shipped this pass

For traceability — these are no longer actionable but are cross-referenced from the original list:

**Dialogue text done (24):** 60, 61, 62, 63, 64, 65, 66 (partial — only `level_3.tscn`), 67, 69, 70, 71, 72, 73, 74, 75, 77, 80, 81, 82+85, 86+87, 89, 91, 93, 94, 182.

**Found already correct (4):** 76, 84, 88, 96, 100.

**Visual/wiring done in earlier sessions:** 136 (BouncyPlatform burial), 152 (ControlPlatform require_flag).

**Files touched in this dialogue pass:** `level_1_glitch.dialogue`, `level_1_glitch_2.dialogue`, `level_1_nyx.dialogue`, `dial_tone.dialogue`, `hub_nyx.dialogue`, `level_4_glitch_post.dialogue`, `level/level_1.tscn`, `level/level_2.tscn`, `level/level_3.tscn`, `level/level_4.tscn`.
