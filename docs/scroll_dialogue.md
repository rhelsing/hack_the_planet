# Scroll Dialogue (DE-style) — Implementation Plan

Right-side 33% panel, scrolling log, skill checks with probability/cooldown,
italics-not-voiced, camera/character framing on dialogue enter. Built on top of
`autoload/dialogue.gd` + Nathan Hoad's DialogueManager 3.10.1. Keeps `dialogue/balloon.tscn` as reference; `dialogue/scroll_balloon.tscn` becomes the default.

**Design decisions (locked with user, 2026-04-22):**
| Decision | Value |
|---|---|
| Screen position | Right side, 33% width, "like a mobile phone overlay" |
| Background | Dim ONLY the text column — world stays bright elsewhere |
| Typography | Monospace |
| Portraits | None — speaker labels only |
| Default balloon | Scroll balloon — old `balloon.tscn` kept as reference |
| Past lines | Instant (no re-typing). Current line types on. |
| Picked response in log | `YOU: "text"` styled dim/italic |
| Italics in dialogue | Rendered in UI, **never sent to TTS** (voice stays clean) |
| Skill checks | Percent-chance roll + cooldown + outcome branch + optional animation |
| Character approach | Player walks to a conversation spot, camera tweens to framing |
| Own voice (Me) TTS | Deferred — silent for now |
| Other-character interjection | Deferred but must not be architecturally blocked |

---

## Phase 0 — Scaffold + placeholder (zero-risk)

**Goal:** make a new balloon that's an EXACT copy of the current one, switch the project to use it. Prove boot doesn't regress.

### Tasks
0.1. Copy `dialogue/balloon.gd` → `dialogue/scroll_balloon.gd`. Copy `dialogue/balloon.tscn` → `dialogue/scroll_balloon.tscn`. Repoint script path in the new tscn.
0.2. Update `project.godot` `[dialogue_manager] general/balloon_path = "res://dialogue/scroll_balloon.tscn"`.
0.3. Boot demo → talk to Troll.

### Smoke test — P0
- [ ] Demo boots clean (no parse errors)
- [ ] Troll dialogue works identically to before (prompts, choices, TTS fires, music ducks)
- [ ] Old `balloon.tscn` still exists untouched as reference

**If P0 fails:** back out; the scroll balloon isn't the problem yet — something else regressed.

---

## Phase 1 — Right-panel layout (visual only, no new behavior)

**Goal:** strip the old centered-balloon layout. New scene: right 33% of screen, dim column behind text, monospace.

### Tasks
1.1. Redesign `scroll_balloon.tscn` scene tree:
```
ScrollBalloon (CanvasLayer, layer=100)
└─ Root (Control, fullscreen, mouse_filter=Ignore)
   └─ RightPanel (Control)
      ├─ anchors: anchor_left=0.67, anchor_right=1.0, anchor_top=0, anchor_bottom=1.0
      ├─ ColumnDim (ColorRect, black, alpha≈0.72, covers RightPanel)
      ├─ Margin (MarginContainer, padding 20px all sides)
      │  └─ VBox (VBoxContainer, grow_vertical=2)
      │     ├─ ScrollContainer (expands to fill) 
      │     │  └─ LogContainer (VBoxContainer, separation=8)
      │     │     └─ [runtime: RichTextLabel per past line appended here]
      │     ├─ DialogueLabel (live typing — the plugin's DialogueLabel)
      │     └─ ResponsesMenu (fixed at bottom; DialogueResponsesMenu)
      └─ (no 3D-world dim — world stays visible on the left 67%)
```
1.2. Apply a monospace theme override at RightPanel level. Use `JetBrainsMono-Regular.ttf` if ui_dev shipped it; else Godot's default mono. Single `theme_override_fonts/font` on RightPanel.
1.3. Remove `@onready var balloon: Control = %Balloon` chain — no outer Panel anymore, just the column.
1.4. Keep plugin behavior intact: DialogueLabel + ResponsesMenu still hooked up via `@onready` with updated paths.
1.5. **Still no new behavior.** Past lines aren't preserved yet. Just the layout is new.

### Smoke test — P1
- [ ] Right 33% of screen is a dark column; left 67% shows the 3D world unchanged
- [ ] Text renders in monospace
- [ ] Troll dialogue opens, types out, responses work, TTS fires
- [ ] No JS crash when resizing window (anchor math correct)
- [ ] Old balloon is untouched; if we flip `balloon_path` back, old balloon reappears

**Visual acceptance:** it looks like a mobile phone UI pinned to the right edge.

---

## Phase 2 — Scrolling log (the DE core)

**Goal:** lines persist, scroll up, auto-scroll to newest. Your picked response appears in the log.

### Tasks
2.1. Override `apply_dialogue_line(next_line)` in `scroll_balloon.gd`:
  - Before calling `super.apply_dialogue_line(next_line)`, snapshot the CURRENT `dialogue_line` (if any) into a new `RichTextLabel` appended to `LogContainer`.
  - Snapshot format: `[color=<speaker_color>][b]<SPEAKER>:[/b][/color] <text>` — BBCode, past-tense (no typing).
  - Speaker color derived from a small per-character palette (Troll=amber, Me=cyan, others=white). Extensible via `voices.tres`-style map.
2.2. Override `_on_responses_menu_response_selected(response)`:
  - Before calling plugin's handling, append `[color=#888888][i]YOU: "<response.text>"[/i][/color]` to `LogContainer`.
  - Then call the normal handler.
2.3. Auto-scroll to bottom:
  - After any log append, set `scroll_container.scroll_vertical = scroll_container.get_v_scroll_bar().max_value` on the next frame (deferred to let the append lay out).
2.4. Manual scrollback:
  - ScrollContainer's default wheel/arrow behavior = user can scroll up to re-read.
  - Don't force-snap back to bottom if user scrolled up manually. Track `_user_scrolled_up: bool` via the scrollbar's `value_changed` signal — only auto-scroll when at bottom AND new line arrives.
2.5. Visited-dimming + failed-condition-hiding still work (plugin features unchanged).

### Smoke test — P2
- [ ] Multi-line monologue: Troll's 3 intro lines all remain in the log, newest at bottom
- [ ] Pick a response → response shows as `YOU: "..."` in the log (grey italic), THEN Troll's reply appends below
- [ ] Scroll wheel up reveals old lines; new incoming line does not yank view back down mid-read
- [ ] After user scrolls back to bottom manually, auto-scroll resumes
- [ ] Visited choices dimmed; failed-condition choices hidden (regression check)

---

## Phase 3 — Italics that don't go to TTS

**Goal:** narration / action beats in italic display-only. TTS stays clean (no weird "asterisk" reads).

### Tasks
3.1. Convention in `.dialogue` lines:
  - Wrap action/narration with asterisks: `Troll: He scratches his head. *A spark escapes his hat.* That was the MHz spike.`
  - OR a dedicated speaker "NARRATOR" for pure narration lines.
3.2. Balloon-side rendering:
  - Before displaying the line, convert `*...*` spans to `[i]...[/i]` BBCode.
  - Works for both live `DialogueLabel` (BBCode enabled) and the historical log entries.
3.3. TTS-side strip:
  - In `autoload/dialogue.gd._on_line_shown`, add a pre-process step:
    - Strip all `*...*` spans from the text BEFORE calling `speak_line(char, text)`.
    - If the stripped result is empty (whole line was narration), skip `speak_line` entirely.
3.4. Narrator speaker handling:
  - If `line.character == "" or "NARRATOR"`, render the whole line italicized by default; skip TTS regardless.

### Smoke test — P3
- [ ] Line with inline `*italic bit*`: log shows italic portion; TTS audio ONLY has the non-italic words (listen to cached mp3; verify by file size dropping vs the naive-text length)
- [ ] Whole-line narration (`Narrator: ...` or `: *...*`) shows italic in log, NO ElevenLabs request fires for it (log shows "skipping TTS for pure narration")
- [ ] Non-italic text renders normally, TTS normal
- [ ] Cache filename still hashes the stripped-for-TTS text so subsequent runs hit the same cache

**Unit test candidate:** `tests/test_dialogue_italics_strip.tscn` — feed known input/output pairs to a helper and assert.

---

## Phase 4 — Skill checks (the DE mechanic)

**Goal:** `COMPOSURE 65%` style rolls in responses, with cooldown, outcome branching, optional animation hook.

### Tasks
4.1. **Create `autoload/skills.gd`** — the `Skills` autoload:
```gdscript
extends Node

# Records:
# - when a skill last rolled: _last_roll_ms[skill] = ms
# - cooldown duration per skill: _cooldown_ms[skill] = ms
# - failed-attempts tracker: _failed_at_ms[skill] = ms (for cooldown starts)

const DEFAULT_COOLDOWN_SEC: float = 30.0

func roll(skill: StringName, chance_pct: int) -> bool:
    # Rolls once. Emits Events.skill_check_rolled(skill, chance_pct, ok).
    # Caller is responsible for starting cooldown after a fail if they want one.
    var ok: bool = randf() * 100.0 < float(chance_pct)
    _last_roll_ms[skill] = Time.get_ticks_msec()
    Events.skill_check_rolled.emit(skill, chance_pct, ok)
    return ok

func can_attempt(skill: StringName) -> bool:
    # True if no active cooldown for this skill.
    return cooldown_remaining_sec(skill) <= 0.0

func cooldown_remaining_sec(skill: StringName) -> float:
    var end_ms: int = _cooldown_end_ms.get(skill, 0)
    if end_ms == 0: return 0.0
    return max(0.0, (end_ms - Time.get_ticks_msec()) / 1000.0)

func start_cooldown(skill: StringName, seconds: float = DEFAULT_COOLDOWN_SEC) -> void:
    _cooldown_end_ms[skill] = Time.get_ticks_msec() + int(seconds * 1000.0)
    Events.skill_cooldown_started.emit(skill, seconds)
```

4.2. **Extend `autoload/events.gd`:**
```gdscript
@warning_ignore("unused_signal") signal skill_check_rolled(skill: StringName, chance_pct: int, succeeded: bool)
@warning_ignore("unused_signal") signal skill_cooldown_started(skill: StringName, seconds: float)
```

4.3. **Register `Skills` autoload** in `project.godot`. Add to `[dialogue_manager] general/states` so `.dialogue` files can call `Skills.roll(...)` directly.

4.4. **Convention in `.dialogue` response text** — visual prefix parsed by balloon:
```
- [COMPOSURE 65%] Keep your face straight [if Skills.can_attempt("composure") /]
    if Skills.roll("composure", 65):
        Troll: Damn. Didn't even flinch. Respect.
        set GameState.set_flag("impressed_troll", true)
    else:
        Troll: Your eye twitched, kid. Rookie.
        do Skills.start_cooldown("composure")
```
  - Balloon renders the `[COMPOSURE 65%]` prefix as a colored badge: `[color=#E4C57A][COMPOSURE — 65%][/color] rest of text`.
  - The `[if Skills.can_attempt("composure") /]` hides the option while on cooldown (plugin feature).
  - The response body contains `if Skills.roll(...)` which rolls once and branches.

4.5. **Visual rendering in scroll_balloon.gd:**
  - New helper `_format_response_text(raw: String) -> String`: detects leading `[SKILL PCT%]` via regex, wraps in color BBCode.
  - Called from `_apply_responses` override, OR — simpler — loop children after `responses_menu.responses = ...` and rewrite their text (each button exposes `.text`).

4.6. **Cooldown display:**
  - When a skill's cooldown is active, the response is auto-hidden by `[if Skills.can_attempt /]`.
  - Optionally: a grayed-out response showing remaining cooldown. Defer — for P4 just hide.

4.7. **Animation hook on outcome:**
  - `Events.skill_check_rolled(skill, chance_pct, succeeded)` fires after each roll.
  - Skin/character controller can subscribe; on fail, play e.g. "wince" anim; on success, "smirk".
  - For the demo: skin connects to Events.skill_check_rolled with `has_method("play_skill_anim")`. If present, call it. Otherwise no-op. Graceful degradation — works without skin cooperation.

### Smoke test — P4
- [ ] Add the `COMPOSURE 65%` branch to Troll's dialogue. Roll it 20 times manually:
  - [ ] ~13/20 succeed ("Didn't flinch" branch), ~7/20 fail (other branch). Rough distribution; stat noise OK.
  - [ ] On fail, `Skills.start_cooldown("composure")` fires → response disappears
  - [ ] 30s later, response reappears
- [ ] Events.skill_check_rolled fires with correct args (subscribe in a test scene, verify)
- [ ] Badge `[COMPOSURE — 65%]` renders colored in the response button
- [ ] Cooldown hides the option (no dead option showing)
- [ ] If a skin implements `play_skill_anim(skill, ok)`, fails trigger a wince (demo-level — stub is fine for v1)

**Automated test:** `tests/test_skills_roll.tscn` — 10,000 `Skills.roll("t", 50)` calls, assert count is 4800–5200 (distribution check). And unit-test cooldown timing.

---

## Phase 5 — Camera framing + character approach

**Goal:** when dialogue starts, player navigates to a conversation spot and the camera moves to a cinematic framing. On end, they release back to normal control.

### Tasks
5.1. **`DialogueTrigger` gains markers:**
  - `@export var conversation_spot: NodePath` — a Marker3D in scene for where player stands
  - `@export var conversation_camera: NodePath` — a Marker3D for camera position+rotation
  - Both optional; if null, dialogue starts immediately with no cinematic.
5.2. **DialogueTrigger.interact** flow update:
  - If markers set: emit `Events.cinematic_entered(player_target: Transform3D, camera_target: Transform3D)` and AWAIT `Events.cinematic_ready` before calling `Dialogue.start(...)`.
  - If markers null: call Dialogue.start immediately (current behavior).
5.3. **Coordinate with character_dev** for the actual implementation:
  - Expose `PlayerBrain.enter_cinematic(player_target, camera_target)` — freezes input, tweens player to position, tweens camera to target, emits `cinematic_ready` when settled.
  - Expose `PlayerBrain.exit_cinematic()` — releases to normal follow.
  - On `Events.dialogue_ended`, DialogueTrigger (or PlayerBrain) calls `exit_cinematic()`.
5.4. **Demo scene update:**
  - Add `ConversationSpot` (Marker3D) 2m in front of Troll.
  - Add `ConversationCamera` (Marker3D) offset to the side for a framed shot.
  - Wire to `DialogueNPC.conversation_spot/camera`.

### Smoke test — P5
- [ ] Walk to Troll from any angle; press E.
- [ ] Player smoothly walks to ConversationSpot (no teleport)
- [ ] Camera smoothly tweens to ConversationCamera position (~0.5s)
- [ ] `Dialogue.start` fires only AFTER camera settles
- [ ] On dialogue end, camera releases back to spring-arm follow, player control restored
- [ ] Works with Troll facing any direction (rotation handled)

**Blocked on CC dev.** Plan: I ship P5 spec + hooks; CC implements `enter_cinematic/exit_cinematic`. Until then, DialogueTrigger falls through to straight Dialogue.start (current behavior — non-regressive).

---

## Phase 6 — Demo integration + polish

**Goal:** a Troll conversation that demonstrates every feature end-to-end.

### Tasks
6.1. **Rewrite `dialogue/demo.dialogue`** with skill-check + italic + multi-line:
  - First-visit intro (block-if, existing)
  - Questions loop (existing)
  - One NEW "COMPOSURE" check branch
  - One line with inline narration italic: `Troll: Listen, kid. *He glances over his shoulder.* There's security on this floor.`
6.2. **Add cooldown ack** in the dialogue: on fail, Troll says "Come back in 30 seconds and try again" (just flavor; cooldown is enforced by `[if Skills.can_attempt /]`).
6.3. **Camera markers** wired in demo (per Phase 5).
6.4. **End-to-end walkthrough test:** write `tests/test_scroll_dialogue_e2e.md` — a manual checklist for playtesting (not automated; too visual).

### Smoke test — P6
Full-feature walkthrough, checked off one by one:
- [ ] Right 33% panel, dim column only
- [ ] Camera frames Troll, player walks into position
- [ ] First-visit intro plays, lines stack in log
- [ ] Narration line italicized in UI, not voiced
- [ ] "Show me what you've got" → "hack the planet" → get key, log shows the history
- [ ] Return conversation: visited options dimmed, condition-locked hidden
- [ ] `[COMPOSURE 65%]` option visible with colored badge
- [ ] Pick it: roll happens, outcome branches, animation fires (if skin supports)
- [ ] On fail, option disappears via cooldown; reappears after 30s
- [ ] End conversation: camera releases, player regains control, door-behind-Troll now unlockable
- [ ] Music never stops — ducks under TTS, back up between lines

---

## Phase 7 — Deferred (explicitly out of scope for this shipment)

- **Dialogue resumable across scene save/load.** Architecture hooks in place (modal lifecycle signals); implementation deferred.
- **Own-voice (Me) TTS.** Plumbing exists; flip in voices.tres when desired.
- **Multiple-interjection speakers** (Troll's boss chiming in mid-convo). The `got_dialogue` signal already carries `character`; any `character` with a voice mapping automatically gets TTS. Works "for free" if we just add speakers to voices.tres and write `.dialogue` lines as `OtherCharacter: ...`.
- **Skill stat UI overlay** (DE-style skill cabinet on the left showing current percentages). Pure visual; additive.
- **Skill-check animation** tied to skin contract (CC dev coordinates). Hook present; skin impl not required for P4 pass.
- **Dialogue history scrollback AFTER close** (save last convo to disk for review). Nice-to-have.
- **Multiple font weights** (bold narrator, italic for actions, thin for thoughts). Defer.

---

## Testing Matrix — what's automated vs manual

| Feature | Auto test | Manual check |
|---|---|---|
| Bus layout | `test_audio_bus_layout.tscn` | — |
| GameState round-trip | `test_game_state.tscn` | — |
| Door interact chain | `test_door_e2e.tscn` | — |
| Puzzle lifecycle | `test_puzzles_lifecycle.tscn` | — |
| Sensor scoring | `test_interaction_sensor.gd` | — |
| Locked-notice UX | `test_sensor_locked_signal.tscn` | P1 smoke |
| Dialogue close guards | `test_dialogue_close.tscn` | — |
| **Italic TTS strip (P3)** | NEW `test_dialogue_italics_strip.tscn` | P3 smoke listen test |
| **Skills roll distribution (P4)** | NEW `test_skills_roll.tscn` | P4 playtest |
| Scroll log behavior | — | P2 smoke |
| Right-panel layout | — | P1 smoke (visual) |
| Skill-check UI badges | — | P4 smoke |
| Camera framing | — | P5 smoke |
| End-to-end Troll convo | — | P6 walkthrough |

---

## Exit criteria for merging

Each phase's smoke test passes **on the actual running demo**, not just headless. We stop between phases for you to play and give feedback. Any phase that feels bad → we iterate before moving on.

Phase order is gated — do not jump. P2 depends on P1's scene tree. P4 depends on P3's TTS pipe (so italic skill-badges don't get voiced). P5 depends on CC dev coordination. P6 depends on all prior.

---

## Sources

- [Nathan Hoad GitHub Discussion #719 — "keep previous dialogue lines a la Disco Elysium"](https://github.com/nathanhoad/godot_dialogue_manager/discussions/719)
- [Nathan Hoad — Endless Scroll & Text Input example (paid $5 reference)](https://nathanhoad.itch.io/endless-scroll-text-input-godot-dialogue-example-project)
- [Dialogue Manager docs — Using Dialogue](https://github.com/nathanhoad/godot_dialogue_manager/blob/main/docs/Using_Dialogue.md)
- [Dialogue Manager docs — Dialogue Balloons](https://github.com/nathanhoad/godot_dialogue_manager/blob/main/docs/Dialogue_Balloons.md)
- `docs/interactables.md` §9 (existing Dialogue autoload spec)
- `sync_up.md` (existing cross-dev coordination for balloon / pause / etc.)
