# Level 1 Arc — The DialTone Rescue (Prank) Mission

Narrative + systems plan for Level 1. Pairs with `docs/level_progression.md` (the 4-level meta arc) and `docs/interactables.md` (dialogue/audio primitives).

Core idea: Level 1 is a **double prank**. DialTone tells the player his friend Nyx is locked out of the Gibson mid-jack, stuck between sectors — please, runner, rescue her. Player rolls through Level 1 expecting a rescue, reaches the end, and finds Nyx perfectly fine. The joke is on **both** the player (who just ran a fake mission) and Nyx (who cannot stand being told she needs rescuing — DialTone knew that sending a stranger to "save" her would enrage her, which is the half of the prank he's actually enjoying). The level stakes the player into the world tone (cyberpunk-Gibson-dial-tone), grants the **rollerblade** power-up (`powerup_love`), and establishes DialTone + walkie-talkie as the player's running narrator for the rest of the game.

---

## 1. Cast

| Handle | Role | Location | Voice (ElevenLabs) |
|---|---|---|---|
| **DialTone** | Narrator / mission-giver. Prankster. Anime-character skin, always on hub Ground. Unlike Glitch, DialTone is *not* a trusted source — half of what he says is a setup. | Hub (persistent) | Liam — energetic, social-media-creator |
| **Nyx** | DialTone's friend. Not his girlfriend — the "save my girl" framing is part of the prank-flavor. Never actually in danger. Will be confused / annoyed when a stranger shows up to "rescue" her. Handle nods to Greek night goddess — unknowable, shadowy. | Level 1, end zone | Jessica — playful, bright, warm |
| **Glitch / Glitch2** | Tutorial helper. Toad-style — always trustworthy, says only what's useful. Cleanly contrasts DialTone's unreliability so the player learns who to believe. Already shipped in `dialogue/companion.dialogue` + `glitch_2.dialogue`. | Hub (pre-Nyx arc) + platforming path | Will — relaxed optimist, young chill |
| **Player** | Runner. Gets a hacker handle of their own during DialTone's intro — pick-one-from-four from a 20-name pool (see §9). Persisted in `GameState.flags["player_handle"]`. | — | — |

---

## 2. Beat map

### Beat 1 — Hub, first talk (pre-L1)

DialTone intro fires on first interaction. Gated in `dialogue/dial_tone.dialogue` by absence of `dialtone_greeted`.

- DialTone: "Hey — over here. Name's DialTone."
- "My friend Nyx — the Gibson locked her out mid-jack. She's stuck between sectors."
- "Can't pull out, can't push through. Just drifting in the static. You gotta jack in and break her loose."
- Player-choice flavor branch: Who is she / What am I looking for / Why can't you go.
- Closer: "Portal's right behind me. Step on, press enter, you're in."
- **Grants walkie-talkie** to the player's inventory (see §4).
- Sets flag `dialtone_greeted = true`.

### Beat 2 — Hub → Level 1 portal

Player steps onto **PedestalLove** (level_num=1). Standard `LevelProgression.goto_level(1)` transition.

### Beat 3 — Level 1 opening, walkie chatter

Immediately on level load, DialTone fires over walkie (see §4): "You're in. Signal's bouncing — head deep. Sector one, watch the rails."

Intent: cement the walkie as the mission-update channel before the player has done anything unusual.

### Beat 4 — Mid-level, escalating urgency

One or two scripted walkie cues on distance thresholds (player crosses X/Z bands) or on collecting the `powerup_love` rollerblade pickup.

- On rollerblade pickup: "Those are hers. She must've dropped them. Keep moving."
  - (Double meaning: player assumes "she's in deep trouble." Real reason: prank setup.)
- On reaching the final platform: "Almost there. She's right up ahead. Don't let her see you coming."

### Beat 5 — Reveal

Player reaches end-zone. Nyx is there, **not** in distress — visibly fine, immediately annoyed. A short in-level dialogue:

- **Nyx:** "Let me guess. DialTone sent you."
- Player-choice: ("He said you were stuck between sectors." / "Are you okay?")
- **Nyx:** "Of *course* he did. I'm going to kill him."
- **Nyx:** "I'm not stuck. I've never been stuck. He does this — tells people I need rescuing so he can watch me lose it. You're the third runner this month."
- **Nyx:** "Go on back and tell him his joke landed. And tell him Nyx says he's a dead man."
- Ends level (standard end-of-level dialogue → `LevelProgression.advance()` → `level_1_completed = true`).

### Beat 6 — Back to hub, DialTone post-reveal

DialTone's hub dialogue branches to `stage_post_1` (already scaffolded in `dial_tone.dialogue`):

- Laughing, unrepentant.
- Short apology + hook to Level 2 ("Alright alright, real one next time. Secret's real, trust me.").
- `PedestalSecret` has already auto-popped-in on `level_1_completed` flag flip (existing behavior).

---

## 3. Dialogue routing (implemented skeleton)

`dialogue/dial_tone.dialogue` already has the stage gate:

```
~ start
if GameState.get_flag("level_4_completed", false)   → stage_post_4
elif GameState.get_flag("level_3_completed", false) → stage_post_3
elif GameState.get_flag("level_2_completed", false) → stage_post_2
elif GameState.get_flag("level_1_completed", false) → stage_post_1  (prank reveal)
elif GameState.get_flag("dialtone_greeted", false)  → stage_nudge
else                                                 → stage_intro
```

Stubs to fill before ship:
- `stage_post_1` — prank reveal copy.
- `stage_post_2/3/4` — progression reactions + next hooks.
- `stage_nudge` — currently one-liner; may want 2-3 variants.

---

## 4. Walkie-talkie system

New subsystem — DialTone hands off a walkie during the intro; it's the vehicle for all in-level narration from Beat 3 onward, and the template for any future companion/ally who talks while the player moves.

### 4.1 Contract

- **Grant**: `GameState.set_flag("walkie_talkie_owned", true)` at end of `stage_intro_tail`.
- **Trigger**: `Walkie.speak("DialTone", "line text")` — plays a TTS-synthesized line on the `Walkie` bus, shows subtitle + portrait, dismisses on audio-end. **Both DialTone and Nyx use this channel** — the speaker's name selects voice + portrait. Nyx starts talking over walkie post-Beat 5 once the player has "met" her.
- **Inventory / HUD**: a single HUD item slot, next to the powerup row, showing a walkie icon. Greyed until owned. Lights when a line is playing.

### 4.2 Pieces

| Piece | Where | Size |
|---|---|---|
| `Walkie` audio bus | `default_bus_layout.tres` | 3 lines (bus + bandpass + distortion) |
| `autoload/walkie.gd` | new autoload | ~50 LOC (reuses `autoload/dialogue.gd` TTS path, just plays on `Walkie` bus instead of `Dialogue`) |
| `WalkieUI` CanvasLayer | `hud/walkie_ui/` | portrait slot + subtitle label + audio-synced fade |
| Walkie inventory chip | `hud/components/walkie_chip.tscn` | small Control; subscribes to `walkie_talkie_owned` flag |
| `WalkieTrigger` area node | `interactable/walkie_trigger/` | drop in level to fire a line on overlap |

### 4.3 Phone FX

New `Walkie` bus in `default_bus_layout.tres`:

1. `AudioEffectBandLimitFilter` (~400 Hz low cut — kill bass)
2. `AudioEffectHighShelfFilter` (~3000 Hz high cut — kill sparkle)
3. `AudioEffectDistortion` mode `WAVESHAPE`, drive ~0.4 (crunch)
4. Optional: `AudioEffectChorus` subtle for radio flutter

Tune by ear against a reference Hackers / cyberpunk radio clip.

### 4.4 TTS cache — ship mp3s, don't ship ElevenLabs key

Hard requirement: **the exported game must not depend on the ElevenLabs API.** Voice lines synthesized once during authoring, cached as mp3s inside the project, played back from disk at runtime.

**Audit of `autoload/dialogue.gd` (done):**
- `CACHE_DIR = "user://tts_cache/"` (line 19). **This is the bug.** `user://` is writable per-install but empty on fresh exports — shipped builds have no cached clips.
- Filename is already stable and machine-independent: `md5(character + "__" + text + "__" + voice_id).left(15)` → `<safe_char>_<hash>.mp3` (lines 303-307).
- Runtime checks `FileAccess.file_exists(path)` → cache hit plays; miss enqueues API request (lines 237-261).
- `_play_cached` routes to `Audio.play_dialogue(mp3)` on the Dialogue bus (line 389).

**Fix — two-tier cache lookup** (~10 LOC in `autoload/dialogue.gd`):

```gdscript
const SHIPPED_CACHE_DIR: String = "res://audio/voice_cache/"
const DEV_CACHE_DIR: String = "user://tts_cache/"

func _cache_path_read(character, text, voice_id) -> String:
    var shipped = SHIPPED_CACHE_DIR + _cache_filename(...)
    if FileAccess.file_exists(shipped): return shipped
    return DEV_CACHE_DIR + _cache_filename(...)  # dev fallback

func _cache_path_write(...) -> String:
    return DEV_CACHE_DIR + _cache_filename(...)  # always user:// during authoring
```

Workflow:
- **In-editor:** synth writes to `user://tts_cache/` (unchanged). Dev can play through scenes; clips accumulate locally.
- **Before ship:** run a `tools/sync_voice_cache.gd` script (new, ~20 LOC) that copies `user://tts_cache/*` → `res://audio/voice_cache/` and leaves a manifest. Commit `res://audio/voice_cache/`.
- **In exports:** two-tier lookup finds clips under `res://audio/voice_cache/` first. No API key needed. No cache miss for any shipped line.

Export config note: `.mp3` under `res://` is included by default in Godot exports (no extension filter needed).

### 4.5 Dialogue Manager interpolation audit — confirmed

`{{ expression }}` mustache substitution works in BOTH dialogue text AND response labels.
- `dialogue_manager.gd:355-428` — `get_resolved_line_data()` extracts and resolves `{{ }}` for `data.type in [TYPE_DIALOGUE, TYPE_RESPONSE]`.
- `dialogue_manager.gd:694-708` — `create_response()` runs every response label through the same resolver before presenting the menu.
- Autoloads listed in `project.godot` `dialogue_manager/general/states` are available to those expressions. `HandlePicker` is registered (verified).

So `{{HandlePicker.option(0)}}` in `dial_tone.dialogue:22-29` response labels IS resolved at choice-render time. No additional plumbing.

### 4.6 Subtitle + portrait UI

Bottom-center band, ~80% screen width, two-row layout. Lives as its own `CanvasLayer` (same pattern as `dialogue/scroll_balloon.gd:1`), so it coexists with the press-E balloon instead of fighting it.

```
┌────────────────────────────────────────┐
│ [Portrait 64x64]  DIALTONE              │
│                   "Those are hers..."   │
└────────────────────────────────────────┘
```

- Portrait: per-character `Texture2D`. Lookup via new `dialogue/voice_portraits.tres` keyed on character name (mirrors `voices.tres`). For v1: placeholder = solid-color `ColorRect` with the character's initial letter. Replace with real art when ready.
- Subtitle text: typewrites as the audio plays; fully written at midpoint, holds until audio ends + 0.3s grace, fades.
- Dismissible via skip key (Space).

**Concurrency rule with press-E balloon** (see §4.7).

### 4.7 Walkie ⟷ balloon concurrency rule

Both UIs are CanvasLayers on screen at once. The question is audio + attention:

- **Visuals**: coexist. Balloon at bottom, walkie band above it (or repositioned if overlap bad). Non-conflicting.
- **Audio**: mutually exclusive. Pattern already in `autoload/dialogue.gd:117` — `Audio.stop_dialogue()` fires when a new line starts to kill the previous one's tail. Walkie follows same rule: starting a walkie line calls `Audio.stop_dialogue()`; starting a press-E line calls `Audio.stop_walkie()`. Last speaker wins.
- **Queuing within walkie**: if a walkie line is playing and another fires, **queue** — don't interrupt. Prevents rapid triggers from sounding chaotic. Autoload maintains a FIFO, dispatches next on `audio_finished`.

---

## 5. Level 1 content

Out of this doc's scope to fully lay out — level geometry + rail placements are level-design work. But the systems hooks Level 1 needs:

- **Spawn**: player enters at level-1-start spawn.
- **Rollerblade pickup** (`PowerUpPickup` with `powerup_flag = "powerup_love"`) — already scaffolded (`interactable/pickup/powerup_pickup.gd`). Grants skate mode.
- **2-3 `WalkieTrigger` zones** — at entry, at rollerblade pickup, at final approach.
- **End-of-level NPC — Nyx.** Uses the `companion_npc.tscn` pattern (same scene that hosts Glitch and DialTone) with `skin_scene` overridden.
  - **Placeholder skin until import**: `res://player/skins/universal_female/universal_female_skin.tscn`. Drops in as the `skin_scene` export. Swap to the final Nyx model when delivered.
  - **Dialogue**: new `dialogue/level_1_nyx.dialogue` for the reveal (per §2 Beat 5).
  - **Voice**: pending pick (see §8 question 3).
- **End dialogue** calls `LevelProgression.advance()` via `do` line — pattern already used by other end-of-level dialogues.

---

## 6. Voice casting

Girlfriend voice — pick one from `dialogue/voices.gd` roster. Candidates:

| Voice | Read | Fits |
|---|---|---|
| Laura | Enthusiast, quirky | Good for the "hah, got you" prank tone |
| Jessica | Playful, bright, warm | Matches "chill, playing on phone" reveal |
| Matilda | Knowledgable, professional | If we want her read as more deadpan |
| Alice (British) | Clear, engaging | Different accent from DialTone — useful for auditory distinction |

**Suggested pick**: **Laura** or **Jessica** for playful prank delivery. Alice if we want contrast to DialTone.

---

## 7. Player handle picker (shipped)

Irreversible hacker-name pick during DialTone's intro. Pool of 20 handles; 4 randomly offered; player picks one; persisted forever.

**Files:**
- `autoload/handle_picker.gd` — pool, reactions, `roll_options(4)` / `pick(i)` / `option(i)` / `chosen_name()` / `reaction()`. Registered in `project.godot` autoload + `dialogue_manager.general/states`.
- `dialogue/dial_tone.dialogue` — `stage_intro` starts with `do HandlePicker.roll_options(4)`, then 4 response choices using `{{HandlePicker.option(N)}}` labels, each firing `do HandlePicker.pick(N)`. Next line is `DialTone: {{HandlePicker.chosen_name()}}, huh? {{HandlePicker.reaction()}}.`
- `GameState.flags["player_handle"]` — persisted.

**Reaction pool:** 20 cycled lines, all variations of "not what I would've picked, but okay." Random pick at `pick()` time, stable for the session.

**Not covered yet:** downstream dialogues don't reference `{{HandlePicker.chosen_name()}}` yet. When Nyx / DialTone speak to the player by handle in later stages or walkie lines, wire the interpolation in.

---

## 8. Open decisions

All prior blockers resolved. Full list, for posterity:

1. ~~Friend handle~~ — **Nyx** ✓
2. ~~Player handle~~ — pick-one-from-four, 20-pool ✓ (shipped §7)
3. ~~TTS cache audit~~ — two-tier lookup (§4.4), ~10 LOC.
4. ~~DM `{{ }}` in response labels~~ — verified (§4.5).
5. ~~Walkie ⟷ balloon concurrency~~ — coexist visually, audio mutually exclusive, within-walkie FIFO (§4.7).
6. ~~Portrait art~~ — placeholder `ColorRect` + initial letter for v1.
7. ~~Nyx skin~~ — placeholder `universal_female_skin.tscn` until real import.
8. ~~Nyx's voice~~ — **Jessica** (registered in `dialogue/voices.gd:63`).
9. ~~Walkie direction~~ — **one-way only** for v1. Pure narration. No reply-choice UI. Revisit for Level 2+ if needed.
10. ~~Nyx reveal mechanic~~ — **standard press-E dialogue**, no auto-fire, no new mechanic. Player walks up, interacts, Nyx is confused about why they're there to "rescue" her. Reuses `companion_npc.tscn` pattern unchanged.

### Non-decisions concretized in the plan

- Walkie stream interrupts: never interrupt mid-line; queue.
- Skip key: Space dismisses walkie line.
- Handle interpolation downstream: later DialTone/Nyx lines will reference `{{HandlePicker.chosen_name()}}` wherever the speaker addressing the player reads natural. Tune as we write copy.

---

## 9. Shipping order

Each step is small, verifiable, and smoke-testable before moving on.

### Step 1 — TTS cache two-tier fix (isolated, ~15 LOC)

`autoload/dialogue.gd`:
- Add `SHIPPED_CACHE_DIR = "res://audio/voice_cache/"` const.
- `_cache_path_for` splits into `_cache_path_read` (checks shipped dir first, falls back to user) and `_cache_path_write` (always user).
- Write path in `_on_http_completed` stays on user://.
- Add `tools/sync_voice_cache.gd` — dev-only editor script, copies `user://tts_cache/*` → `res://audio/voice_cache/`.
- Create the dir `res://audio/voice_cache/` (empty, committed as placeholder).
- **Smoke test**: existing dialogues still voice-synth on cache miss, play on cache hit. No behavioral change in editor.

### Step 2 — Walkie audio bus + FX (isolated, ~20 LOC)

- `default_bus_layout.tres`: add `Walkie` bus routed to Master. Effects: `AudioEffectBandLimitFilter` (cutoff ~3200 Hz), `AudioEffectHighPassFilter` (cutoff ~400 Hz), `AudioEffectDistortion` (WAVESHAPE, drive 0.4).
- `autoload/audio.gd`: add `play_walkie(stream: AudioStream)` + `stop_walkie()` — mirror `play_dialogue`, route to `Walkie` bus.
- **Smoke test**: from editor console, `Audio.play_walkie(some_mp3)` plays through the phone-FX chain. Listen by ear; tune drive/cutoffs.

### Step 3 — `autoload/walkie.gd` autoload (~60 LOC)

- Mirror of `autoload/dialogue.gd`'s `speak_line` flow: cache check (reuses `dialogue.gd`'s `_cache_path_read`), FIFO queue for concurrent triggers, `Audio.play_walkie` on ready.
- `Walkie.speak(character, text)` public API.
- `Walkie.stop()` for scene transitions.
- Registered in `project.godot` autoloads + `dialogue_manager/general/states`.
- **Smoke test**: call `Walkie.speak("DialTone", "You're in. Signal's bouncing.")` from a test script, verify TTS → cache → phone-FX playback.

### Step 4 — WalkieUI CanvasLayer (~90 LOC + scene)

- `hud/walkie_ui/walkie_ui.tscn` + `.gd` — bottom band, portrait slot (`TextureRect`), subtitle `Label`, typewrite animation synced to audio length. Subscribes to `Walkie.line_started(character, text, duration)` signal.
- `dialogue/voice_portraits.tres` — Resource mapping character names → `Texture2D`. Empty for v1 (placeholders synthesized as `ColorRect` + initial letter).
- Add `WalkieUI` instance to `game.tscn` (where HUD lives).
- **Smoke test**: `Walkie.speak(...)` now shows the portrait band with typewriting subtitle during playback.

### Step 5 — HUD walkie-owned chip (~30 LOC)

- `hud/components/walkie_chip.tscn` — small icon, greyed when `walkie_talkie_owned` flag is false, lit when true, pulses when a line is playing.
- Subscribes to `GameState.flag_set` (for the owned state) and `Walkie.line_started` / `line_ended`.
- Drop into existing HUD.
- **Smoke test**: set `GameState.set_flag("walkie_talkie_owned", true)` — chip lights up.

### Step 6 — Grant walkie in DialTone's intro (1 line)

In `dialogue/dial_tone.dialogue` `~ stage_intro_tail`:
```
do GameState.set_flag("walkie_talkie_owned", true)
```
- **Smoke test**: complete the hub intro → walkie chip appears in HUD.

### Step 7 — WalkieTrigger interactable (~40 LOC + scene)

- `interactable/walkie_trigger/walkie_trigger.tscn` + `.gd` — Area3D with `@export var character: StringName` + `@export var line: String`. Fires `Walkie.speak(character, line)` on first `body_entered` for a player body; one-shot (frees after triggering or sets a flag to not re-fire).
- **Smoke test**: drop one in the hub as a sanity check — step into it, walkie line plays.

### Step 8 — Level 1 integration

- Drop 3 `WalkieTrigger` instances in Level 1 geometry (entry, rollerblade pickup, final approach) with DialTone lines.
- Create `dialogue/level_1_nyx.dialogue` with the reveal copy (per §2 Beat 5).
- Place Nyx NPC at end zone: `companion_npc.tscn` instance with `skin_scene = universal_female_skin.tscn`, `dialogue_resource = level_1_nyx.dialogue`. Option: wrap in an auto-fire `Area3D` per §8 decision 3.
- Fill `stage_post_1` copy in `dial_tone.dialogue` (prank reveal).

### Step 9 — Voice synth pass + cache commit

- Pick Nyx's voice (§8 decision 1).
- Play through all new DialTone + Nyx lines once in-editor to populate `user://tts_cache/`.
- Run `tools/sync_voice_cache.gd` → moves clips to `res://audio/voice_cache/`.
- Commit the cache directory.
- **Smoke test**: revoke the ElevenLabs key, play the arc end-to-end in-editor, no silent lines.
