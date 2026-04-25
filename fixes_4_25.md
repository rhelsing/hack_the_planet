# fixes_4_25.md — Pending Fixes (2026-04-25)

Each fix below: **what I understand**, **where it touches**, and **the design decision** before implementation. None of these are coded yet.

---

## Fix 1 — DialTone "are you who messaged me?" thread

**What you want.** First convo with DialTone, the **top** option in the intro choice menu is *"Are you who messaged me?"* DialTone replies coyly — confirms without confirming, hints he's been watching the player poke around message boards and wanted to see what they're made of. The thread continues across each subsequent DialTone visit (post-1, post-2, post-3, post-4), revealing more each time. **Confirmed: gated on asking the original question** — if the player skips the intro option, the thread never opens, post-stages never show the follow-up.

**Where it touches.** `dialogue/dial_tone.dialogue`. Specifically:
- `~ intro_menu` (line 24) — insert the new option as the first choice, branching to a new sub-stage `~ intro_messenger`.
- New stage `~ intro_messenger` — coy reply + sets `dialtone_messenger_thread = 1` so subsequent post-stages know the thread is active.
- `~ stage_post_1` / `_post_2` / `_post_3` / `_post_4` — each gets a new optional menu item gated on the thread counter, opening one beat that bumps it forward. **One-shot per stage** — asked once, gone, like a real conversation progressing.

**Design decision.** Single integer flag `dialtone_messenger_thread = 0..5` controls progression:
- `0` = never asked. No post-stage option appears.
- `1` = intro beat fired. Post-1 shows the next beat option.
- `2` = post-1 fired. Post-2 shows the next beat option.
- ... etc.

Each beat checks `if int(GameState.get_flag("dialtone_messenger_thread", 0)) == N` (exact match, not `>=`) — that gives one-shot semantics: once you've fired post-1's beat, the counter is `2`, post-1's option no longer matches `== 1` and goes away. Branches stay scoped within `dial_tone.dialogue` — no new dialogue files.

### Drafted beats (redirect any line)

**Beat 0 — `~ intro_messenger`** (gates the thread, fires from intro_menu's new top option)

```
- Are you who messaged me?
    => intro_messenger

~ intro_messenger

DialTone: ...maybe.
DialTone: Let's just say I noticed you. The way you asked questions on hacker news intrigued me.
DialTone: I wanted to see what you were made of.
do GameState.set_flag("dialtone_messenger_thread", 1)
DialTone: Anything else?
- Who's Nyx?
    => intro_who
- What am I looking for?
    => intro_what
- Why can't you go yourself?
    => intro_why
- Let's go.
    => intro_done
```

**Beat 1 — post-1 follow-up** (gated on `== 1`)

```
- Back to those questions you mentioned…
    => post_1_messenger

~ post_1_messenger

DialTone: Oh, *those*. Yeah.
DialTone: Spent a few weeks just lurking. You had a particular flavor — kept asking what nobody else was asking.
do GameState.set_flag("dialtone_messenger_thread", 2)
=> post_1_done
```

**Beat 2 — post-2 follow-up** (gated on `== 2`) — names a forum / old handle

```
- About those boards…
    => post_2_messenger

~ post_2_messenger

DialTone: neon-archive. The 0xCirca threads, mostly. You were under a different handle then.
DialTone: That's where I knew. The way you walked at a question other people ran from.
do GameState.set_flag("dialtone_messenger_thread", 3)
=> post_2_done
```

**Beat 3 — post-3 follow-up** (gated on `== 3`) — admits deliberate recruitment

```
- Let's talk about how I got here.
    => post_3_messenger

~ post_3_messenger

DialTone: You found the breadcrumbs because I left them. Every dead-drop hint, every loose link — placed.
DialTone: Splice's offer wasn't the first test. It was the third.
DialTone: You passed all three.
do GameState.set_flag("dialtone_messenger_thread", 4)
=> post_3_done
```

**Beat 4 — post-4 follow-up** (gated on `== 4`) — the meta-reveal

```
- The whole thing was an audition, wasn't it?
    => post_4_messenger

~ post_4_messenger

DialTone: Yeah. Nyx was never stuck — you know that now. But the casting was real.
DialTone: The grid's not built; it's chosen who builds it. I needed someone who'd show up for nothing and figure it out anyway.
DialTone: You're in. For real this time.
do GameState.set_flag("dialtone_messenger_thread", 5)
=> post_4_done
```

Tone target: Liam voice (energetic, prankster, social-media-creator) — coy, smug, slowly admits more. Each beat lands ~10s of voiced audio so it's a side-pulse, not a major detour. Player who skips the intro option never sees any of it; player who asks gets a thread that pays off across the whole game.

---

## Fix 2 — Glitch transition on every scene change

**What you want.** The glitch shader transition (currently the menu → hub bookend) plays on **every** scene swap: hub → level1, level1 → hub, hub → level2, etc.

**Why it doesn't today.** Two parallel scene-swap paths exist:
- `SceneLoader.goto(path)` — full-scene replacement, **already wraps the transition** (`autoload/scene_loader.gd:47-48` `play_out` / `:99` `play_in`). Used only for `MainMenu → Game`.
- `Game.load_level(path)` — in-game *Level child swap* under the `Game` host, keeps Player + HUD persistent across level changes. **Does NOT play the transition.** This is what `LevelProgression._goto` prefers when `current_scene` has the `load_level` method (i.e., always, in real gameplay).

So the transition never fires on hub ↔ level swaps because they go through `Game.load_level` directly, bypassing `SceneLoader`.

**Where it touches.** `game.gd:44` — `load_level(path)`. Wrap the existing `_mount_level` body with the same `Transition.play_out` → mount → `play_in` bookend that `SceneLoader.goto` uses. Pull the same `Settings.graphics.transition_style` lookup so user choice is honored consistently.

**Design decision.** Implement it inside `Game.load_level` rather than rerouting all level swaps through `SceneLoader.goto`, because the in-game path is intentional — it preserves player state across levels (health, abilities, powerup flags). Adding the transition there is a one-place edit; rerouting would lose that preservation.

The TransitionScript is already a preload constant in `scene_loader.gd:14` — we'll add the same const to `game.gd` (or extract to a shared autoload, but a single duplicate const is cheaper than a new autoload for one consumer).

**Side effect to watch for.** `play_out` and `play_in` are async (`await`). The current `_mount_level` is synchronous. Wrapping with awaits means `load_level` becomes async — any caller that depends on `_current_level` being mounted by return time will need to switch to `await` or to the `scene_entered` signal. Need to audit callers.

---

## Fix 3 — `[E]` and `[G]` everywhere become device-aware -- pull from GLYPH

**What you want.** Every "press [E] to talk" / "press [G] to grapple" hint adapts to the active controller config. Same `Glyphs` system you just wired into `respawn_message_zone.gd`.

**Where it touches** (audited via grep for `[E]` / `[G]` / `[e]` / `[g]` / "press E" / "press G"):

| File | Line | Current | Fix |
|---|---|---|---|
| `interactable/prompt_ui/prompt_ui.gd` | 12-13, 124, 130-135 | hardcoded `glyph_keyboard = "E"` and `glyph_gamepad = "X"` exports, with `_pick_glyph()` switching based on `last_device` | Replace `_pick_glyph()` with `Glyphs.for_action("interact")` so the gamepad glyph is `"Triangle"` (canonical mapping in `glyphs.gd:27`) instead of the local `"X"`. Single source of truth. |
| `interactable/grappleable/grappleable.gd` | 12 | `prompt_text: String = "[G] grapple"` (literal) | Make it a template — `prompt_text: String = "[{grapple_fire}] grapple"`, then resolve at draw-time via `Glyphs.format(prompt_text)` |
| `puzzle/hacking/hacking_puzzle.tscn` | 81 | `text = "Press [E] when the indicator is in the green zone"` | Either set the text via script at `_ready` using `Glyphs.format("Press [{interact}] when…")`, or change the literal to the template and have the hacking_puzzle script run it through `Glyphs.format()` once at `_ready` |
| `puzzle/hacking/hacking_puzzle.gd` | (its `_ready` is the place to do the format pass) | n/a | Add the format call |

**What's already correct, leave alone.**
- `respawn_message_zone.gd` — already runs through `Glyphs.format` (just shipped).
- `dialogue/glitch_2.dialogue:48` — Glitch verbal controls hint says `"Space, or A on a controller, initiates a jump."`. This is voiced via TTS through the Companion bus. Could be re-templated to `{jump} initiates a jump.` and let `LineLocalizer` resolve it (already wired in `Companion.speak`). **But** the current dual-name phrasing intentionally narrates both bindings in one line. Easier to just leave it as-is for now — fix only the on-screen UI hints.

**Design decision.** PromptUI is the load-bearing case. Right now its `glyph_gamepad = "X"` is inconsistent with `glyphs.gd`'s `interact → "Triangle"`. Aligning to Glyphs means **one** dictionary controls every prompt label across the game; if you swap the canonical gamepad mapping later (e.g. switch from PS button names to Xbox button names), one edit propagates everywhere.

For prompts authored as static strings in .tscn files (like the hacking puzzle label), prefer `Glyphs.format()` at `_ready` in the parent script — keeps the .tscn human-readable.

---

## Fix 4 — Glitch1 phone booth wording: "near", not "in"

**What you want.** Glitch's phone-booth mention says "go in the phone booth" (paraphrased) but should say "go **near** the phone booth" because the trigger is proximity, not entry.

**Where it touches.** `dialogue/companion.dialogue:5` — the line I just added. Currently:

```
Glitch: One more thing — those phone booths around the grid. Step into one and it lights up green. Bank that, and you respawn there if you fall.
```

**Fix.** Change to:

```
Glitch: One more thing — those phone booths around the grid. Walk near one and it lights up green. Bank that, and you respawn there if you fall.
```

**Verification.** Confirmed by `phone_booth.tscn:15-17` — the activation `Area3D` uses a `BoxShape3D` of size `13.85 × 6.5 × 6.0`, which is a **massive** trigger zone (~13m × 6m around the booth). Player walks within ~7m horizontally → triggers. So "near" is accurate; "in" would mislead the player into trying to enter the booth.

**Design decision.** Single one-line copy edit. No code change. Smallest fix in the batch.

---

## Order of execution

1. **Fix 4** — one-line copy edit. Trivial.
2. **Fix 3** — UI prompt alignment. Touches 3-4 files, all small.
3. **Fix 2** — transition wiring in `game.gd:load_level`. One file, ~10 LOC + an audit of callers for the async signature change.
4. **Fix 1** — DialTone messenger thread. Largest. Touches one file but adds 5+ new beats with cross-stage gating.

Each step gets a smoke gate (`godot --headless --quit-after 60` + grep for SCRIPT ERROR). Stop and confirm visual feel for #2 (transition timing) and #1 (copy tone) before moving on.

---

## Resolutions (2026-04-25)

1. **Fix 1 gating** — Locked: thread only opens if intro question is asked; post-stage beats are one-shot, gated on counter exact-match.
2. **Fix 1 draft beats** — Drafted above. Redirect any line.
3. **Fix 3 mapping** — Locked: align to Glyphs, single dictionary controls every prompt label.
4. **Fix 2 async** — Locked: cascade async through `Game.load_level` and `LevelProgression._goto`/`advance`/`goto_level`/`goto_path`. Mount happens under the play_out fade; save fires after mount; play_in reveals.
