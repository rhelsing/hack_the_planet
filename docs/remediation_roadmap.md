# Remediation Roadmap

Issues uncovered by the 2026-04-27 playthrough (`docs/debug_log_play1.md`, ~37k lines) plus user-reported gameplay issues. Diagnostic only — **no fixes have been applied**. Use this as the prioritized work list.

---

## P0 — Blockers for production builds

### A1. Cached voice lines miss in exported builds → ElevenLabs hit instead

> **Update from log audit:** there are actually TWO compounding bugs here. The FileAccess one is below. The new finding follows.

**Bug A1a — synth writes go to `user://`, not `res://`, even in editor playtest:**
The log shows 8 `[Walkie] synth OK — cached … bytes to user://tts_cache/dialtone_….mp3` lines. The check at `dialogue.gd:355` is `OS.has_feature("editor") if … else …`, but `OS.has_feature("editor")` returns `true` ONLY inside the editor's main process — **NOT** when you click "Play" to launch the game from the editor (that's a debug build of a template, which is `OS.has_feature("template")`). Net effect:

- Every editor playtest fills the dev cache (`user://tts_cache/`)
- The shipped cache (`res://audio/voice_cache/`) only gets filled by manually running `tools/sync_voice_cache.gd`
- A line you edit and play through in the editor is silently invalidating cache and only landing in `user://`. If you don't run sync before exporting, production has no audio for that line — even after the FileAccess fix below.

**Fix:** in `_cache_path_write`, change the gate from `OS.has_feature("editor")` to writing to `res://` whenever it's writable (it is in editor builds; not in exports). Simplest: drop the gate and always write to `SHIPPED_CACHE_DIR` in editor builds (detect via `OS.is_debug_build() and ResourceLoader.exists("res://")` — or just `not OS.has_feature("template")` which is the inverse and reliable). Production builds (templates) write to `user://` since `res://` is read-only.

**Log evidence:** 0 `CACHE HIT` / 55 `cache MISS` / 55 ElevenLabs POSTs / 8 `synth OK` in the playthrough. Of the 55 lines that fired, only 8 finished synthesizing — the user heard ~14% of intended dialogue audio, even in the editor. Remaining 47 either timed out or finished after the user moved past the moment.

---

**Bug A1b — `FileAccess.open` won't read source mp3s in exported builds**

**Symptom (user report):** "in production it only seems to want to pull from eleven labs… the opposite of what we need." Every dialogue line in the shipped build either is silent (no API key) or burns API quota that should be served by the on-disk cache.

**Root cause:** `autoload/dialogue.gd::_play_cached` (line 433–443) reads cached voice mp3s with raw `FileAccess.open(path, READ)` followed by `file.get_buffer(...)`. This loads the **literal source bytes** from `res://audio/voice_cache/<character>_<hash>.mp3`. In Godot 4 default export behavior the source `.mp3` files are *not* packed — only the **imported** form (`.godot/imported/X.mp3-HASH.mp3str`) ships. So in exported builds (assuming A1a is also fixed and lines actually got into shipped cache):

- `FileAccess.file_exists("res://audio/voice_cache/foo.mp3")` returns `false` (source not in pack)
- `_cache_path_read` falls through to the dev cache (`user://tts_cache/`) which is empty on a fresh install
- `speak_line` enqueues an ElevenLabs request

In editor + dev environment, the source `.mp3` files exist on disk so `FileAccess` works and the cache hits.

**Two fix paths (pick one):**

1. **Switch to ResourceLoader.** Replace `FileAccess.open` + `get_buffer` with `load(path) as AudioStreamMP3`. Godot's resource pipeline knows how to find the imported form via the `.import` sidecar. No export config changes needed. Single function change in `dialogue.gd`. Minor: `AudioStreamMP3.data` would no longer be the access vector — would call `Audio.play_dialogue(stream)` with the resource directly.
2. **Force source `.mp3`s into the export.** Set `export_presets.cfg`'s `include_filter` to `"*.mp3"` so source files ship alongside imported. Bigger build size; brittle if other mp3s shouldn't ship.

**Recommended:** path 1. Cleaner, smaller export, leverages Godot's intended resource flow.

**Also do:** gate `_maybe_dispatch_next_tts` on `OS.has_feature("editor")` (or a project setting like `tts.allow_runtime_synthesis`) so production builds *never* hit ElevenLabs even on a true cache miss. Today, an edited line with no cached audio in production silently burns API quota; with the gate it stays silent and we know to pre-bake.

**Files to touch:** `autoload/dialogue.gd` (lines 270–290 dispatch, lines 433–443 `_play_cached`), `autoload/walkie.gd` (mirror-fix for the walkie path which uses the same cache resolution but its own HTTP).

**Verify:** export a debug build, launch, watch for `speak_line: CACHE HIT` lines. No `cache MISS — requesting from ElevenLabs` should appear in production logs.

---

## P1 — User-flagged gameplay issues

### G0. Main menu is visible and **interactable** beneath loading screens and cinematics

**Symptom (user report):** "the menu is still seen and interactable below loading menus and the cinematics.. thats crazy and dumb."

**Root cause (loading screen):** the loader UI on `CanvasLayer` 1000 visually covers the menu, but the menu underneath is still **keyboard- and controller-interactable**. `mouse_filter` on the loader's panels only blocks **mouse** input; Godot's UI focus system is independent and `ui_accept` / `ui_cancel` / `ui_up` / `ui_down` still reach whichever menu Button currently holds focus on the lower CanvasLayer.

**Fix:** the loader UI needs to (a) grab focus on spawn, AND (b) intercept all `ui_*` actions while visible. ~5 lines in `menu/scene_loader.gd`:
```gdscript
func _ready() -> void:
    grab_focus()  # or focus a no-op spacer Control inside the loader

func _input(event: InputEvent) -> void:
    if event.is_action_type():
        get_viewport().set_input_as_handled()
```
Optional belt-and-suspenders: also flip Dim Panel `mouse_filter = 2 → 0` so mouse clicks are eaten too (the menu still loses focus once the loader grabs it, so this is mostly cosmetic).

**Root cause (cinematics):** `autoload/cutscene.gd` correctly applies `MOUSE_FILTER_STOP` on its bg ColorRect, so the still-image cutscene path is fine. The bug is **specifically in the NPC-dialogue cinematic camera** (`level/interactable/companion_npc/companion_npc.gd` + `interactable/dialogue_trigger/dialogue_trigger.gd`). When the player approaches an NPC and the cinematic camera engages:
- The camera switches to a `CameraTarget` Marker3D (good)
- The dialogue balloon opens for player choices (good — its own UI handles balloon-internal input)
- BUT **no overlay covers the rest of the screen**, so any other Control still in the scene tree (HUD buttons, leftover menu state) receives raw mouse clicks

The log confirms: `[cinematic] enter: actor=Player … cam=CameraTarget` immediately followed by `[Dialogue] _on_line_shown` — no overlay creation in between.

**Suggested fix:** at cinematic enter, push a transparent input-stopping overlay (one full-screen `ColorRect` with `Color(0,0,0,0)` and `MOUSE_FILTER_STOP`) onto a CanvasLayer that sits **below** the dialogue balloon's layer but **above** the world UI. Remove it on cinematic exit. This blanket-blocks raw clicks against any underlying Controls without interfering with the balloon's interactive choices.

**Files to touch:**
- `menu/scene_loader.tscn` — flip mouse_filter on Dim Panel.
- `level/interactable/companion_npc/companion_npc.gd` (or DialogueTrigger) — add input-blocker overlay during cinematic.

**Verify:** click madly on the menu while the loading screen is up; should do nothing. Open an NPC dialogue and click on a remembered button location of the menu (or anywhere outside the dialogue balloon); should do nothing.

---

### G1. ~~Attack swing ("woosh") and impact sounds not playing~~ **(resolved by user via volume tuning)**



**Symptom (user):** "the woosh sounds for attack, the impact hit sounds, the bounce sounds are not playing."

**State on disk (verified):**
- `audio/sfx/attack_kicks/` — 2 files (`wooshA.mp3`, `wooshB.mp3`) ✓
- `audio/sfx/attack_impacts/` — 5 files (`hit1`–`hit5.mp3`) ✓
- `audio/sfx/bounces/` — 4 files (`bounce1`–`bounce4.mp3`) ✓

**Code path is wired:**
- `player_body.gd:231-241` — `attack_kick_pool` + `attack_impact_pool` + auto-load dirs declared as `@export`s
- `game.tscn` — sets `attack_kick_auto_load_dir = "res://audio/sfx/attack_kicks"` and `attack_impact_auto_load_dir = "res://audio/sfx/attack_impacts"`
- `player_body.gd:727-737` — `_setup_pawn_audio` resolves both pools from auto-load dirs and creates `_kick_sfx_player` + `_impact_sfx_player` via `_make_pawn_3d_player()`
- `_play_random_attack_kick_sfx()` is called from `_start_attack_jostle` (line 636)
- `_play_random_attack_impact_sfx()` is called when sweep hits an enemy (line 1155)
- For bouncy: `level/interactable/bouncy_platform/bouncy_platform.tscn` has `bounce_sound_auto_load_dir = "res://audio/sfx/bounces"` and the `.gd` mirrors the same auto-load → AudioStreamPlayer3D pattern.

**Likely causes (must be verified at runtime — log doesn't include `_play_random_attack_*` calls):**
1. **Volume is 0 dB authored, attenuation eats it.** `_make_pawn_3d_player` was recently bumped to `unit_size = 12.0` (good for footsteps in the player's ear) but `attack_kick_volume_db = 0.0` (default) is below the +6 dB we set on footsteps. The attack source is at the body but the camera is ~9m back — the click could be inaudible behind world ambience and the louder footstep cadence.
2. **Pool resolution failed silently.** If `_setup_pawn_audio` ran before the dirs were imported (race during initial load), the pool would be empty and `_play_random_attack_kick_sfx` would bail at the `pool.is_empty()` check. Verify by adding a one-time print of `_attack_kick_pool_resolved.size()` in `_setup_pawn_audio`. Symptom would be near-silent `MISSING:` warning in console — none seen in current log.

**Bouncy platform — log evidence:**
The log does NOT contain the `BouncyPlatform: bounce_sfx silent` warning that `_play_random_bounce_sfx` would push if its pool failed to resolve. So **the pool resolved AND `play()` was called** when the player bounced. Two more findings:
- The inline comment in `bouncy_platform.gd:75` claims the player is "2D so the bounce sound plays at full SFX-bus volume regardless of camera distance." **The actual code (line 105) instantiates `AudioStreamPlayer3D.new()`.** Comment is stale, and 3D attenuation IS in play.
- `unit_size = 6.0`, `max_distance = 35.0`, `volume_db = 0.0`. With the camera ~9m back from the deck, attenuation eats ~3.5 dB on top of the 0 dB authored level — quiet by design.
- Player gets reparented under `BouncyPlatform17/Deck` during the squash/carry phase (confirmed by `[cam-dbg] cam=/root/Game/Level/BouncyPlatform17/Deck/Player/...` in log), so the camera distance to the bounce source is roughly constant.

**Fix:** bump `bounce_sound_volume_db` to +6, `unit_size` to 12 — match the footstep tuning we already validated. Or honor the original intent and switch to `AudioStreamPlayer.new()` (2D, no attenuation), updating the comment. The 2D path is cheaper and matches the coin-click pattern.

**Investigation steps for attack/impact:**
- Add a one-line `print` in `_play_random_attack_kick_sfx` and `_play_random_attack_impact_sfx` — confirm they fire, check resolved pool size and `p.playing` post-`play()`.

**If volume is the culprit (most likely):** bump `attack_kick_volume_db` and `attack_impact_volume_db` defaults +4 to +6 like we did for footsteps.

---

### G2. "CONNECTION TERMINATED" card renders in top-left, not full-screen

> **User-confirmed in-game** (the log just didn't capture the death event since the death code is mostly silent — no debug prints fire on `_start_death` / `_finish_death`). Card visible top-left during a real death.


**Symptom (user):** "the connection terminated screen doesnt display overlayed, its up in top left."

**Diagnosis:** `hud/components/death_overlay.tscn` root has `anchor_right = 1.0` + `anchor_bottom = 1.0` — that's correct full-screen. Parent is `Fullscreen` Control inside `hud.tscn` which also has full anchors. **HOWEVER** the `Blackout` ColorRect inside death_overlay has `anchor_right = 1.0, anchor_bottom = 1.0` only — no `anchor_left=0, anchor_top=0` explicit. In Godot 4 a Control inheriting only the right/bottom anchors with default left/top of 0.0 SHOULD stretch full-screen. Likely the issue is one of:

1. **Center container collapsing.** The CenterContainer wraps the title block and is sized by its child Panel (640×420 minimum). If `modulate.a` ramps the WHOLE overlay including the blackout, but the Panel renders inside the CenterContainer which is positioned by anchors, the visible card might be centered but the blackout fade-in is also tied to overall modulate — looking like a top-left card if anchors are off.
2. **`anchor_left/anchor_top` defaults missing on the root Control node** — when instanced inside `hud.tscn` at `Fullscreen/DeathOverlay`, the inherited offsets from instance wrap might pin it to top-left rather than spanning. Default Control anchors are 0,0,0,0 (top-left point) until an explicit full-rect override.

**Files to inspect:**
- `hud/components/death_overlay.tscn` — root node anchors. Should be all-four set: `anchor_left = 0.0, anchor_top = 0.0, anchor_right = 1.0, anchor_bottom = 1.0` and offsets all 0.
- `hud/hud.tscn:79-86` — `Fullscreen` parent looks correct (anchor_right=1, anchor_bottom=1).
- The new `ScreenGlitch` sibling (added in same chunk) uses the same anchors and would have the same bug if it exists. Worth checking if the chromatic glitch is also broken.

**Fix shape:** force the root Control to full-rect. In tscn: explicit `anchor_left = 0.0`, `anchor_top = 0.0`, `offset_left = 0.0`, `offset_top = 0.0`, `offset_right = 0.0`, `offset_bottom = 0.0`. Or set `Layout → Anchors Preset → Full Rect` in the editor.

---

### G3. Skate toggle — remove the keyboard / controller binding entirely

**Refined intent (corrected from prior turn):** blades are already always-on once unlocked (the underlying state machine handles that). The user's complaint is that pressing R or controller button 9 still flips between walk and skate. They want **no input toggle at all** — input shouldn't change the mode under any circumstances.

**Fix (pick one):**

1. **Surgical** — delete `player_brain.gd:103-104`:
   ```gdscript
   if event.is_action_pressed("toggle_skate") and body.has_method("toggle_profile"):
       body.toggle_profile()
   ```
   Two lines removed. The `toggle_skate` input action stays in `project.godot` as orphaned binding; harmless.

2. **Cleaner** — also strip the `toggle_skate` mapping from `project.godot` so the action vanishes from the project entirely. Slightly more invasive but kills dead config.

Recommended: option 1 first; revisit option 2 in a config sweep later.


**Symptom (user):** "i shouldnt still be able to to turn off an on rollerblades from controller or keyboard.. can from controller.. i want permanent blades."

**Diagnosis:**
- `project.godot` has `toggle_skate` action mapped to keyboard **R** (`physical_keycode = 82`) AND joypad **button 9** (right-stick-click on Xbox / Y on Switch).
- `player/brains/player_brain.gd:103` listens: `if event.is_action_pressed("toggle_skate") and body.has_method("toggle_profile"): body.toggle_profile()`.
- `player_body.gd::toggle_profile` swaps between `walk_profile` and `skate_profile` whenever called.
- `level/level_mockup.gd:21` shows the rollerblade howto caption was already changed to "You have blades!" — confirming design intent is permanent skate after pickup.

**Three fix options (pick one):**

1. **Remove the input mappings entirely.** Edit `project.godot` to drop both `InputEventKey` and `InputEventJoypadButton` from the `toggle_skate` action. The brain handler becomes dead code but harmless. Cleanest for shipping.
2. **Gate `toggle_profile` behind `OS.has_feature("editor")`** — keep the toggle as a dev convenience, hide from players.
3. **Gate the brain handler on a `GameState.flags` debug flag** — same as 2 but configurable per-build.

**Recommended:** option 2. Designers and devs still get fast walk/skate testing in the editor; players in the export get the always-on rollerblades the design calls for.

**Also clean up:** `player_body.gd:58-60` comment "a future skate pickup can toggle into skate mode without requiring the player to press R" is now misleading — skate IS the pickup, R should be retired. Update or delete.

---

### G4. Portal transitions (hub ↔ level) — route through SceneLoader so the loading screen actually appears

**Symptom (user, refined):** "i'd prefer our loading screen we use between menu and level also. to make sure everything is loaded well."

**Current state:** the menu→game transition uses `SceneLoader.goto(...)` which spawns the proper loading UI from `menu/scene_loader.tscn` (visible loader, progress bar, glitch transition). The hub→level portal transition does NOT — it instead calls `Game._mount_level(packed)` directly (game.gd:120), which is synchronous and gives no loading feedback. Hence the visible hitch + no UI cover.

**Diagnostic context from log:**
- `WARNING: SceneLoader.goto called while already loading res://game.tscn` — racey transitions (menu firing goto twice OR portal trigger overlapping main-menu click).
- `ERROR: SceneLoader failed to load: res://game.tscn` — `scene_loader.gd:66` push_error in the threaded-load failure branch. Single occurrence in log.
- `_mount_level` (game.gd:120) runs synchronously when fired from a portal. The `scene_loader.gd` already uses `ResourceLoader.load_threaded_request` so the load itself is off the main thread when goto is used; portals bypass it entirely.

**Recommended approach (in priority order):**
1. **Route portal transitions through SceneLoader.goto.** Find the portal interactable script(s) in `level/interactable/` (likely `phone_booth` or a dedicated portal scene). Replace any direct `Game.set_level(...)` / `_mount_level` invocation with `SceneLoader.goto("res://level/level_X.tscn")`. This gives portals the same loader UI + glitch transition + threaded load that the main menu already enjoys.
2. **Debounce SceneLoader.goto.** Track `_loading: bool` (or just check `_target_path != ""`) in `scene_loader.gd`; ignore further `goto()` calls until the current load completes. Solves the "goto-while-loading" warning + the failed-load that follows it.
3. *(Optional, later)* **Pre-warm the next level's PackedScene** when the player enters a portal's "approach zone" (e.g., 6m before the trigger). Call `ResourceLoader.load_threaded_request("res://level/level_X.tscn")` early; the bytes are decompressed in the background. By the time the player hits the trigger, `load_threaded_get_status` returns LOADED. Only worth doing if the routing-through-SceneLoader fix doesn't fully hide the hitch.

**Files to touch:** the portal interactable script(s) under `level/interactable/`, `autoload/scene_loader.gd` (add busy guard).

---

### G5. ~~Nyx beacon~~ **(resolved by previous-turn fix; confirmed in log + user)**



## P2 — Engine warnings flooding the log (cleanup)

### W1. DebugPanel duplicate-registration storm — 3959 warnings

**Symptom:** every PlayerBody (player + every enemy + every spawned enemy) calls `_register_debug_panel()` in `_ready`. Each call attempts to register the same `~40` paths.

**User has already done most of the work.** A `_player_singleton` static var + `is_active_player` flag now correctly gates abilities, camera setup, and signal subscriptions. **One line missed:** `_register_debug_panel()` at `player_body.gd:562` is still called unconditionally.

**Fix:** wrap line 562 in the existing flag:
```gdscript
if is_active_player:
    _register_debug_panel()
```

**Side effect:** the `det == 0` engine errors (61 occurrences, no GDScript trace) appear *interleaved* with the duplicate-registration warnings. The most parsimonious explanation is that the DebugPanel duplicate-add path is doing math on a degenerate state when it tries to compute a position for a slider it skipped. Worth re-checking after the gate fix — they may evaporate.

**Be careful with this class:** the DebugPanel uses paths-as-keys, so all the existing UI bindings depend on the path strings staying stable. The fix is purely "don't call the registration function for non-player pawns" — no internal DebugPanel changes needed.

---

### W2. coin.gd sets `monitoring = false` inside its own signal callback

**Symptom:**
```
ERROR: Function blocked during in/out signal. Use set_deferred("monitoring", true/false).
```
Fires every coin pickup. ~14 occurrences in the log.

**Important context:** this error is **engine log noise — nothing functionally broken.** Godot still applies the change after the signal completes; the coin still stops detecting. The coin pickup audio (which user got working via a player-side listener) is a completely separate system unaffected by this. The fix is purely log hygiene so the actual errors aren't drowned out.

**Root cause:** `level/interactable/coin/coin.gd:55` — `monitoring = false` is set directly inside the `body_entered` signal handler. Godot 4 forbids physics-state mutation during signal dispatch (engine treats it as an error even though it semi-applies).

**Fix:** `monitoring = false` → `set_deferred("monitoring", false)`. One-character-class change. Same outcome, no error.

---

### W3. SceneLoader race: goto-while-loading

**Symptom:** `WARNING: SceneLoader.goto called while already loading res://game.tscn`. Single occurrence near initial main-menu → hub transition.

**Root cause:** main_menu fires `SceneLoader.goto("game.tscn")`; before threaded load completes, save service auto-resumes and may fire another goto for the saved level. Or the player is in the portal trigger as it's instantiated.

**Fix:** debounce in `scene_loader.gd` — see G4 above. Same fix.

---

### W4. SceneLoader failed to load res://game.tscn (1 occurrence)

**Symptom:** `ERROR: SceneLoader failed to load: res://game.tscn` from `scene_loader.gd:66` (the FAILED + INVALID_RESOURCE branch of the threaded load). Single instance, paired with the goto-while-loading warning above.

**Likely cause:** the racey re-entry from W3 — second goto's threaded-load conflicts with first. Once W3 is debounced, this should disappear.

**Verify:** after fixing W3, replay through the same sequence (main-menu → hub) and watch for this error.

---

### W5. ObjectDB instances leaked at exit (17 resources in use)

**Symptom:** `ERROR: 17 resources still in use at exit`. Only on shutdown.

**Severity:** cosmetic. Doesn't affect gameplay. Worth investigating later — typically caused by a circular signal connection or a Resource holding a strong ref to a Node that should free.

**Investigation:** run with `--verbose` to dump the ObjectDB state and identify the leaked types. Probably related to dialogue queue / TTS pending requests not being torn down on quit.

---

## Suggested execution order

### Dead-simple batch (one sitting, ~30 min including smoke tests)

| # | Item | Fix |
|---|---|---|
| 1 | **A1a** Cache write path | `dialogue.gd:355` — flip the OS check (one line) |
| 2 | **G0a** Loading screen accepts kbd/controller | `menu/scene_loader.gd` — `grab_focus()` on `_ready` + `_input` that consumes `is_action_type()` events (~5 lines) |
| 3 | **G3** Skate toggle binding | `player_brain.gd:103-104` — delete the two-line handler (toggle should never fire from input) |
| 4 | **W1** DebugPanel duplicate-register | `player_body.gd:562` — wrap in existing `if is_active_player:` (one line) |
| 5 | **W2** Coin signal mutation | `coin.gd:55` — `monitoring = false` → `set_deferred(...)` (one character class) |

### Verify-then-edit (small experiment first)

| # | Item | Verification → Fix |
|---|---|---|
| 6 | **A1b** Production audio cache | Smoke test passes (editor); proper test = build + export + listen. Then swap `_play_cached` from FileAccess → ResourceLoader. Add production gate so `_maybe_dispatch_next_tts` no-ops when `OS.has_feature("template")`. |
| 7 | **G2** Death overlay anchors | User-confirmed bug. Open `death_overlay.tscn`, set root Control to Layout → Full Rect. Test by killing player. |

### Iterative / requires playtest tuning

| # | Item | Notes |
|---|---|---|
| 8 | **G0b** Cinematic input blocker | Add transparent `MOUSE_FILTER_STOP` overlay on cinematic-enter, remove on exit. Layer needs to sit below dialogue balloon but above world UI — 1-2 attempts. |
| 9 | **G4** Portal → SceneLoader.goto | Find portal interactable, swap `_mount_level` direct call for `SceneLoader.goto(...)`. Also add `_loading` busy-guard. Test by walking through the portal repeatedly + stress-clicking. |
| 10 | **W5** ObjectDB leaks (17 instances) | Run with `--verbose`, identify leaked types, fix per-case. Could be 5 min or 5 hrs. |

### Done / removed from scope

- **G1** ~~bouncy/attack/impact volumes~~ (resolved by user)
- **G5** ~~Nyx beacon~~ (resolved by previous-turn fix; confirmed in log)

---

## Diagnostic gaps still open

| Item | Why log can't confirm | What to capture |
|---|---|---|
| G3 — controller toggle | Player never pressed R / button 9 in this playthrough | Log of toggle press on both inputs |
| Audio cache HIT rate baseline | Every line in log was recently edited (100% miss) | After A1a fix + a fresh sync, log should show CACHE HIT for unedited dialogue |
