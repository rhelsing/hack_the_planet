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

**Root cause (loading screen):** `menu/scene_loader.tscn` puts the loader UI on `CanvasLayer` 1000 (correctly above the menu's default layer 1). BUT both the `Dim` Panel and the `Root` CenterContainer have `mouse_filter = 2` (`MOUSE_FILTER_IGNORE`). That means the loader **renders on top** but **does not consume mouse input** — every click falls through the loader straight to the main_menu Buttons sitting on the lower CanvasLayer. The visual cover and the input cover are decoupled, and only the visual is wired.

**Fix:** flip `mouse_filter` on the `Dim` Panel from `2 → 0` (`MOUSE_FILTER_STOP`). One-property edit. Optionally also set the root `CanvasLayer.layer` higher on the menu side, but with STOP on the dim panel the layering already works.

**Root cause (cinematics):** `autoload/cutscene.gd` correctly applies `MOUSE_FILTER_STOP` on its bg ColorRect, so still-image cutscenes block input. The bug is in the **NPC-dialogue cinematic camera** path (`level/interactable/companion_npc/companion_npc.gd` + `interactable/dialogue_trigger/dialogue_trigger.gd`). When that fires:
- The camera switches to a `CameraTarget` Marker3D
- The dialogue balloon opens for player choices
- BUT no input-consuming overlay covers the rest of the screen

If the player has somehow returned to a state where the main_menu (or any other Control with focus_mode != NONE) is still in the tree, those controls receive input. The log shows `[cinematic] enter: actor=Player … cam=CameraTarget` followed by `[Dialogue] _on_line_shown` — no overlay creation in between.

**Suggested fix:** at cinematic enter, push a transparent input-stopping overlay (one ColorRect with `Color(0,0,0,0)` and `MOUSE_FILTER_STOP`) on a high CanvasLayer; remove on cinematic exit. The dialogue balloon's own modal handling intercepts UI navigation but doesn't blanket-block raw mouse clicks against world-space buttons or other Controls.

**Files to touch:**
- `menu/scene_loader.tscn` — flip mouse_filter on Dim Panel.
- `level/interactable/companion_npc/companion_npc.gd` (or DialogueTrigger) — add input-blocker overlay during cinematic.

**Verify:** click madly on the menu while the loading screen is up; should do nothing. Open an NPC dialogue and click on a remembered button location of the menu (or anywhere outside the dialogue balloon); should do nothing.

---

### G1. Attack swing ("woosh") and impact sounds not playing

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

> **Log diagnostic limit:** the player did NOT die during this playthrough — no `take_hit`, `_dying`, `_finish_death`, or `death_overlay` events anywhere in 37k lines. Cannot verify behavior from this log. Capture a session that includes a death to confirm root cause.


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

### G3. Skate toggle still works on controller and keyboard — should be permanent

> **Log diagnostic limit:** no `toggle_skate`, `toggle_profile`, or profile-swap events appear anywhere in this playthrough — the user didn't actually exercise the toggle in this session. Behavior assumed from code review (input map + handler trace). Capture a session where you press R / button 9 to verify there isn't a second handler.


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

### G4. Portal transitions (hub ↔ level) hitch — preload during teleporter approach

**Symptom (user):** "we may need some preloading between the portal transitions from hub to levels?"

**Diagnostic context from log:**
- `WARNING: SceneLoader.goto called while already loading res://game.tscn` — racey transitions (menu firing goto twice OR portal trigger overlapping main-menu click).
- `ERROR: SceneLoader failed to load: res://game.tscn` — `scene_loader.gd:66` push_error in the threaded-load failure branch. Single occurrence in log.
- `_mount_level` (game.gd:120) runs synchronously after threaded load completes. The `scene_loader.gd` already uses `ResourceLoader.load_threaded_request` so the load itself is off the main thread, but the `instantiate()` + `add_child(new_level)` chain at game.gd:120 **is not** — that's where you'd see the visible hitch when a 100k-poly level enters the tree.

**Recommended approach:**
1. **Pre-warm the next level's PackedScene** when the player enters the portal's "approach zone" (e.g., 6m before the trigger). Call `ResourceLoader.load_threaded_request("res://level/level_X.tscn")` early; the bytes are decompressed and resource graph built in the background. By the time the player hits the trigger, `load_threaded_get_status` returns LOADED instantly.
2. **Async instantiate** if the hitch persists. Spread `instantiate()` across frames using `ResourceLoader.LOAD_THREADED_LOAD_AS_FAR_AS_POSSIBLE` flag, or render a transition curtain (the existing GlitchTransition could double here) so the hitch is hidden behind a visual.
3. **Debounce SceneLoader.goto.** Track `_loading: bool` in `scene_loader.gd`; ignore further `goto()` calls until the current load completes. Solves the "goto-while-loading" warning.

**Files to touch:** `autoload/scene_loader.gd` (add preload entrypoint + busy guard), and the portal interactable script (call preload on body-entered-approach-area, fire goto on body-entered-trigger-area).

---

### G5. Nyx beacon — log shows it actually works after the previous-turn fix

User flagged earlier that the Nyx waypoint didn't show. Log confirms the fix from `level/level_1.tscn:Nyx/Beacon` IS firing correctly:

- `5762: [beacon] ready: /root/Game/Level/Nyx/Beacon visible=false voice_gate=DialTone flag_gate=/`
- `17393: [beacon] Beacon armed by voice: DialTone 'Runner. Nyx is in your vicinity!…'`
- `18882: [beacon] Beacon visible -> true`
- Immediately after: `[beacon_layer] drawing Beacon at (-66.69823, 65.97045, -97.31536)` `drawn=1 (registered=2)`

Either the user's earlier complaint predates the fix, or the on-screen marker was visually subtle / off-screen at the moment of reveal. **Worth confirming with the user before marking resolved** — if they still don't notice it in-game, the issue is BeaconLayer rendering style (size, color, offscreen-arrow visibility), not the trigger system.

---

## P2 — Engine warnings flooding the log (cleanup)

### W1. DebugPanel duplicate-registration storm — 3959 warnings

**Symptom:** every PlayerBody (player + every enemy + every spawned enemy) calls `_register_debug_panel()` in `_ready`. Each call attempts to register the same `~40` paths (`Camera/Follow/...`, `Movement/skate/...`, etc.). After the first PlayerBody registers them, every subsequent one push_warns "path X already registered, skipping." With ~10 enemies in the level that's `10 × 40 ≈ 400` warnings per level load. Across multiple level transitions in the playthrough this hits 3959.

**Root cause:** `_register_debug_panel` is unconditionally called from `_ready` — `player_body.gd:489`. No `pawn_group == "player"` gate.

**Fix:** wrap the `_register_debug_panel()` call in `if pawn_group == "player":`. The debug panel readouts are inherently per-player (they tune live — only one set is meaningful). Enemies don't need to register the same paths.

**Side effect:** the `det == 0` engine errors (61 occurrences, no GDScript trace) appear *interleaved* with the duplicate-registration warnings. The most parsimonious explanation is that the DebugPanel duplicate-add path is doing math on a degenerate state when it tries to compute a position for a slider it skipped. Worth re-checking after the gate fix — they may evaporate.

---

### W2. coin.gd sets `monitoring = false` inside its own signal callback

**Symptom:**
```
ERROR: Function blocked during in/out signal. Use set_deferred("monitoring", true/false).
   at: set_monitoring (scene/3d/physics/area_3d.cpp:379)
   GDScript backtrace (most recent call first):
       [0] _on_body_entered (res://level/interactable/coin/coin.gd:55)
```
Fires every coin pickup. ~14 occurrences in the log.

**Root cause:** `level/interactable/coin/coin.gd:55` — `monitoring = false` is set directly inside the `body_entered` signal handler. Godot 4 forbids physics-state mutation during signal dispatch.

**Fix:** `set_deferred("monitoring", false)`. One-line change.

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

| Order | Item | Effort | Impact |
|---|---|---|---|
| 1 | **A1a**: Cache write path — drop `OS.has_feature("editor")` gate so editor playtests fill `res://audio/voice_cache/` directly | XS | Stops silent cache poisoning during dev playtests |
| 2 | **A1b**: Production audio cache (ResourceLoader switch + production dispatch gate) | M | **Ships** the audio drama everyone wrote |
| 3 | **G0**: Loading screen + cinematic input passthrough (`mouse_filter` + cinematic input blocker) | XS | Stops UX-shattering click-through to menu |
| 4 | **G3**: Permanent blades (gate `toggle_profile` on editor feature) | XS | Matches design intent |
| 5 | **G2**: Death overlay anchors (verify on a death-included playthrough first) | XS | Visible UX bug |
| 6 | **W1**: Gate `_register_debug_panel` to player only | XS | Kills 3959 warnings + likely the 61 det==0 errors |
| 7 | **W2**: `set_deferred` on coin monitoring | XS | Kills per-coin error spam |
| 8 | **G1**: Bouncy/attack/impact sound volume tuning (bump `unit_size` + `volume_db`, switch bouncy to 2D player to match comment intent) | S | Combat + traversal feel |
| 9 | **G4 + W3 + W4**: SceneLoader debounce + portal pre-warm | M | Smoother hub→level transitions, kills the loader race |
| 10 | **G5**: Confirm with user that Nyx beacon visually reads (log shows it draws) | XS | May be no-op |
| 11 | **W5**: Investigate ObjectDB leaks | S | Cleanliness |

Total scope is small — most items are 1-line fixes. A1a + A1b are the only items with real complexity, and they're the only true user-facing production blockers. The rest is hygiene + tuning.

---

## Diagnostic gaps (need new logs to confirm)

| Item | Why log can't confirm | What to capture |
|---|---|---|
| G2 — death overlay top-left | Player never died in playthrough | Log of a player death sequence start to respawn |
| G3 — controller toggle works | Player never pressed R / button 9 | Log of pressing the toggle, ideally on both keyboard and controller |
| Audio cache HIT rate baseline | Every line in log was recently edited (100% miss) | After A1a fix + a fresh sync, log should show CACHE HIT lines for unedited dialogue |
