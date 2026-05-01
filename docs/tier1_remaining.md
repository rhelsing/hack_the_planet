# TIER 1 — Remaining Bugs

Items confirmed or corrected from playtest review. Items marked **[CONFIRM]** need verification that they're actually fixed or still present.

---

### Progression / Softlocks

| # | Bug | Level | Notes |
|---|-----|-------|-------|
| 4 | **Crouching on angled platform — player gets stuck** | L3, L4 | Locks player in place. Occurs on both levels. |
| 11 | **Terminal next to Glitch visible before dialogue** | L4 | ✅ **FIXED** — BuriedReveal child added to HackingTerminal, `bury_depth = 3.0`, `reveal_flag = &"l4_glitch_pitched"`, `reveal_after_walkie_line_ends = true`. Walkie2 now writes `persist_flag = &"l4_glitch_pitched"` so the terminal slides up after Glitch's "Will you do the honors?" line ends. ControlPlatform 1+2 now have `require_flag = &"l4_terminal_5"` and `done_flag = &"l4_invention_terminal_solved"`. |
| 14 | **Have to jump to install God** | L4 | Player gets stuck. Jump shouldn't be required. Needs fix. |
| 170 | **Player falls under the floor** | L4 | Dial Tone is raised, Nix is on par, but player clips through and ends up under the floor. |
| 171 | **Post-terminal scene not working** | L4 | Scene doesn't trigger/play. Needs positioning of the other version of Glitch. |
| 175 | **Have to jump to talk to Glitch** | L4 | Glitch is way too high on the platform. Player has to jump repeatedly to trigger talk prompt. Lower model or extend interaction radius vertically. |
| 179 | **Bonus puzzle broken** | L4 | "A little bit fucked" — needs debugging. No further detail yet. |
| 180 | **Splice "Well shit" camera sequence not choreographed** | L4 | Sequence must be: camera pulls back → linger on Splice 3s → play BRAM.mp3 → he says "well shit" → 3s quarantine animation with warp SFX → hold 2s → trigger Nix. Current camera position is good. Timing/sequence is not wired up. |

### Dialogue System

| # | Bug | Level | Notes |
|---|-----|-------|-------|
| 18 | **Bold text makes 11 Labs read hex color codes aloud** | All | Any bold/color-formatted line causes TTS to read the hex code. Splice's L2 lines don't have this — diff those. |
| 19 | **Dash-B (/B) showing in dialogue bubbles** | All | **[CONFIRM]** — Raw formatting tags in UI. Need to verify this is fixed. |
| 20 | **Can talk to Nix before Dial Tone (post-level scenes)** | Post-L1, Post-L2 | Breaks conversation flow. Also: when talking to Nix first, player walks to the wrong spot — should face and walk toward the point in front of Dial Tone. |
| 21 | **Post-level scene re-trigger — no exit** | Post-level scenes | Correction: not just a completion flag. Need to track when the full conversation is done, then switch to an "anything else you wanna chat about?" version. Player can either continue or say "that's all." Current state: player gets stuck for minutes with no way out. |
| 40 | **Multiple lines need 11 Labs re-rendering** | Various | Full list: "she tell you never stuck never been stuck" / "Bite your signal as stabilized" / "Well, isn't this a surprise? Some of my tracking code seems to be paying off" / "Look at you go, that's so awesome" / "I was them I left them because I figured it out" / "Sheepel" / "Their keys, those power ups in your pocket" / "I'm deleting the part of the wire that has you on it" / "No no no no" / "We can't do that again we can't" / "The…" / "We know where the last disk is. He doesn't know" / "You're better than I planned for runner" / "we split stay synced on the channel, first one to spot it pings" / "He thinks the rules are rigged against him" |
| 41 | **"Chuckles" and emotes spoken by TTS** | Various | Stage directions being rendered as speech and displayed on screen. Should be silent/acted. |
| 43 | **Dialogue memory/dimming not persisting** | All | Dims after one round then resets. Big issue — breaks dialogue tracking across full conversations. |
| 166 | **"Got it" choice does NOT sound like "no way"** | L3 | Splice scene. This is not intentional — "got it" absolutely must convey "no way." Needs re-rendering or new line. |
| 177 | **"…" (ellipsis) does not work with 11 Labs** | All | Every instance of ellipsis fails in TTS. Cross-cutting — affects every level. Need an alternative representation 11 Labs can handle. |
| 178 | **Do not use 11 Labs V3** | All | V3 sounds different from the rest of the game. All V3 renders need to be redone on the previous version. Blanket rule. |

### Movement & Rails

| # | Bug | Level | Notes |
|---|-----|-------|-------|
| 23 | **Rail jump fix — first 2 seconds** | All | As soon as rail grabs player, lock jumping for 2 seconds. |
| 24 | **Rails go through buildings** | L2, L3 | Visual clipping. Confusing and looks bad. |
| 25 | **Grapple animation is just standing** | L3 | Should use midair/falling dynamic animation. |
| 26 | **Controller shows "G to grapple"** | All | **[CONFIRM]** — Hardcoded to keyboard. Need to verify this reads controller bindings now. |

### Enemies & Balance

| # | Bug | Level | Notes |
|---|-----|-------|-------|
| 39 | **Spawn less enemies at top of Level 1** | L1 | Too many. Reduce count. |
| 173 | **Remaining reds don't despawn after terminal hack** | L4 | After finishing the hack, all remaining red sentinels should disappear. Currently they persist. |
| 174 | **Splice doesn't start dancing** | L4 | In the Splice conversation, he's supposed to start dancing at a certain point. Animation not triggering. |

### HUD & UI

| # | Bug | Level | Notes |
|---|-----|-------|-------|
| 45 | **Power-up/disc icons too small** | All | J Cola, skate label, all power-up disc icons — double the size. |
| 46 | **Remove HP bar from HUD** | All | Not needed. Remove from grid and HUD. |
| 47 | **Walkie-talkie icon — dark on dark** | All | Dark emoji on dark background. New emoji or custom image. |
| 172 | **Final hub screen labels disappear** | L4 Hub | "E to talk" and similar labels not showing. Intermittent — they came back later. Needs debugging. |

### Checkpoints

| # | Bug | Level | Notes |
|---|-----|-------|-------|
| 49 | **Checkpoint grab radius too small** | All | Hard to trigger. Make registration area much bigger. |
| 50 | **Checkpoint sound too loud** | All | Down ~10 dB. |
| 51 | **Need checkpoint mid-Level 1** | L1 | Near middle + near top buildings so falling doesn't reset too far. |
| 52 | **Need more checkpoints top of Level 2** | L2 | |
| 53 | **Need checkpoint before/after God install** | L4 | Player has gone very far with no save point. |

---

### CONFIRM checklist

- [x] #11 — Terminal next to Glitch: ✅ buried 3u, reveals on Walkie2 line-end via `l4_glitch_pitched` flag
- [ ] #19 — Dash-B (/B): still showing in bubbles?
- [ ] #26 — Controller "G to grapple": reads controller binding now?
