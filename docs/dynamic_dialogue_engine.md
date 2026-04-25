# dynamic_dialogue_engine.md — Templated Voice Lines + Background Priming

Roadmap for the device-aware, template-driven voice line system. Not yet implemented; this doc encodes the design so we can pick it up after the Companion-bus voiced-respawn flow ships (see `level_one_arc.md` walkie pieces + the Companion autoload).

Status as of 2026-04-25: **layers 1-3 shipped**. Templates resolve `{player_handle}` via `LineLocalizer`; sibling variants synth in the background through `VoicePrimer` at trigger time (no pre-warm, no scene registry). Device-token resolution (`{jump}`/`{dash}`) is the remaining stub — `LineLocalizer` is structured to accept it but `device_labels.tres` and `DeviceProfile.detect_active()` aren't built yet.

---

## Why

Glitch (and DialTone, Nyx, future companions) frequently say things like *"press {jump} to jump"*. The literal key/button label depends on what's plugged in. Currently every voiced line is a fixed string baked at authoring time — fine until a controller arrives. We need:

1. Lines authored as templates with action tokens.
2. Tokens resolve to device-appropriate text per playback (keyboard → "Space", Xbox → "A", PS → "X").
3. A finite, deterministic set of variants per template (one per supported device profile).
4. All variants synthesized and cached **ahead of need**, so swapping controllers mid-game never causes a stutter.
5. The shipped game ships the union of all variants; no API key needed at runtime.

---

## Architecture overview

```
Author writes:                  "Press {jump} to jump."
                                          │
                  ┌───────────────────────┴───────────────────────┐
                  │  LineLocalizer.resolve(template, device) →    │
                  │  per-device strings:                          │
                  │    keyboard      → "Press Space to jump."     │
                  │    xbox/generic  → "Press A to jump."         │
                  │    playstation   → "Press X to jump."         │
                  │    switch        → "Press B to jump."         │
                  └───────────────────┬───────────────────────────┘
                                      │
              ┌───────────────────────┴───────────────────────┐
              │  Cache key = md5(character__resolved__voice)  │
              │  → one mp3 per variant on disk                │
              └───────────────────────┬───────────────────────┘
                                      │
            ┌─────────────────────────┴─────────────────────────┐
            │                                                   │
   Foreground playback                              Background priming
   (Companion / Walkie):                            (VoicePrimer):
   - resolve to current device                     - on level load: enumerate
   - check cache → play                               registered templates
   - miss + active → await                          - expand × all device profiles
   - miss + in-flight → join wait                   - skip cached, queue misses
                                                    - drain via dedicated HTTPRequest
                                                      one-at-a-time, never blocks gameplay
```

---

## Variation primitive — action-key templates

The smallest unit of variation is an **InputMap action token** in the line text, written as `{action_name}`.

```gdscript
# Authoring:
voice_line = "{jump} jumps. Try it next time, yeah?"

# Resolved (keyboard):
"Space jumps. Try it next time, yeah?"

# Resolved (xbox):
"A jumps. Try it next time, yeah?"
```

### Token registry — `device_labels.tres`

A new resource keyed on `(action_name, device_profile)` → display string. Hand-curated. Lives next to `voices.tres`.

| action | keyboard | xbox/generic | playstation | switch |
|---|---|---|---|---|
| `jump` | "Space" | "A" | "X" | "B" |
| `dash` | "Q" | "RB" | "R1" | "R" |
| `crouch` | "Ctrl" | "B" | "Circle" | "A" |
| `attack` | "Left Click" | "X" | "Square" | "Y" |
| `pause` | "Esc" | "Start" | "Options" | "+" |
| `interact` | "E" | "Y" | "Triangle" | "X" |

We do NOT derive these from `InputMap` directly because Godot's auto-generated text ("Joypad Button 0") is unfriendly. Hand-curated, ~30 entries total.

### Device profile detection

```gdscript
class_name DeviceProfile

enum Profile { KEYBOARD, XBOX, PLAYSTATION, SWITCH, GENERIC_GAMEPAD }

static func detect_active() -> Profile:
    var pads := Input.get_connected_joypads()
    if pads.is_empty():
        return Profile.KEYBOARD
    var name := Input.get_joy_name(pads[0]).to_lower()
    if "xbox" in name: return Profile.XBOX
    if "playstation" in name or "ps4" in name or "ps5" in name or "dualshock" in name: return Profile.PLAYSTATION
    if "switch" in name or "joycon" in name or "pro controller" in name: return Profile.SWITCH
    return Profile.GENERIC_GAMEPAD
```

Subscribe to `Input.joy_connection_changed` to swap profiles live.

### Resolver

```gdscript
class_name LineLocalizer

static func resolve(template: String, profile: DeviceProfile.Profile) -> String:
    var out := template
    var labels := load("res://dialogue/device_labels.tres") as DeviceLabels
    var regex := RegEx.create_from_string("\\{(\\w+)\\}")
    for m in regex.search_all(template):
        var action := m.get_string(1)
        var replacement := labels.get_label(action, profile)
        out = out.replace(m.get_string(0), replacement)
    return out
```

Pure function. No side effects. Templates without tokens pass through unchanged — current Companion / Walkie call sites can pipe through `LineLocalizer.resolve()` immediately for a no-op.

---

## Why the cache scheme already supports it

`autoload/dialogue.gd` cache filename:
```
md5(character + "__" + text + "__" + voice_id).left(15)
```

The `text` arg is the **resolved** string. Different device variants → different hashes → different mp3s. Zero changes to the cache key; the existing `Dialogue._cache_path_read` / `_cache_path_write` path is reused as-is. The `res://audio/voice_cache/` directory just grows by N×variant_count files.

---

## Background variant gen — kicked at trigger time

**No pre-warming.** When a tokenized voice line is triggered to play, the foreground synthesizes the chosen variant exactly the way it does today — cache check, miss → ElevenLabs → cache → play. Foreground path unchanged.

**At the same moment**, every OTHER variant of that template (the 3 unused handles, or the 4 alternate device profiles) is enqueued into a background processing queue. They synth in the background, get cached, and never play this session — they're cached so future runs (or a different player on the shipped build with a different handle) hit instantly.

```
Companion.speak(character, template) called
  ├─ resolve to current device + chosen handle → foreground (existing path,
  │    cache check → on miss synth + write + play)
  └─ for each OTHER variant in the cartesian product of token expansions:
        if not cached + not in flight:
            VoicePrimer.enqueue(character, resolved_text, voice_id, write_path)

VoicePrimer worker:
  - dedicated HTTPRequest, separate from Walkie/Companion foreground requests
  - drains queue serially, one at a time, never blocks gameplay
  - writes mp3 to user://tts_cache/, no playback
```

```gdscript
extends Node

# In-flight map keyed on cache path so duplicate enqueues fold.
var _queue: Array = []           # [{character, text, voice_id, path}, ...]
var _in_flight: Dictionary = {}  # path → true while HTTP request is open
var _http: HTTPRequest           # dedicated background request

func enqueue(character: String, resolved_text: String, voice_id: String, path: String) -> void:
    if _in_flight.has(path): return
    if FileAccess.file_exists(path): return
    for q in _queue:
        if q.path == path: return
    _queue.append({
        "character": character,
        "text": resolved_text,
        "voice_id": voice_id,
        "path": path,
    })
    _drain_if_idle()
```

Why this is dramatically simpler than scene-walk priming:
- **No registry.** Every tokenized voice line is its own self-contained trigger; no central list to maintain.
- **No flag-flip pre-warm.** `Input.joy_connection_changed` doesn't need a subscription either — next time a tokenized line fires, the new device's variants get queued automatically.
- **No foreground/background race.** Foreground always operates on the chosen variant directly (existing path); background queue contains only the siblings, so they can't collide on the same hash.
- **Organic cache fill.** Over the course of dev playthroughs, every line × every variant gets cached because every line gets played at least once during dev. Pre-ship `tools/sync_voice_cache.gd` flushes `user://` → `res://audio/voice_cache/` and we ship the union.

---

## Pre-ship bake

A one-shot tools script `tools/bake_voice_cache.gd`:

1. Walk every `RespawnMessageZone`, `WalkieTrigger`, dialogue resource for templates.
2. Expand × every supported `DeviceProfile`.
3. Force synth on every miss (writes to `user://tts_cache/`).
4. Copy `user://tts_cache/*` → `res://audio/voice_cache/`.
5. Manifest commit — every shipped variant is in the repo.

Run before each release. CI can run it to validate "no untranslated lines" without writing artifacts.

Shipped exports never touch ElevenLabs. Players plugging in a new controller mid-game never wait — every variant is on disk.

---

## Three layers, ship in order

### Layer 1 — Companion bus + voiced respawn (DONE)

- New `Companion` audio bus with reverb + low-pass.
- `Audio.play_companion / stop_companion / companion_finished`.
- `autoload/companion.gd` — FIFO queue, no `require_flag` gate, plays on Companion bus.
- `RespawnMessageZone` extended with `voice_character` + `voice_line` exports. If set, fires `Events.respawn_voice_armed(character, line)` and skips the label arm.
- `PlayerBody` — `_pending_voice_lines` queue, dedupe-by-last, drained on respawn after a 3s settle window.
- Three `RespawnHintZone` instances in `hub.tscn` rerouted from `message` to Glitch voice.

**Lines are fixed strings.** No tokens, no variants, no priming. Foundation for layers 2-3.

### Layer 2 — Templates + LineLocalizer (DONE)

- `dialogue/device_labels.tres` resource + `DeviceLabels` resource class.
- `DeviceProfile.detect_active()` static helper.
- `LineLocalizer.resolve(template, profile)` static.
- Pipe every `Companion.speak()` / `Walkie.speak()` call through `LineLocalizer.resolve(template, DeviceProfile.detect_active())` before reaching cache lookup.
- One device profile only at first (keyboard). Adding gamepad still works; just resolves to the same string until layer 2.5 wires gamepad labels.
- Convert the three Glitch respawn lines from fixed strings to templates. Verify cache hit on existing files (it'll miss because the resolved text is identical but the cache hash is recomputed — actually, since the text is unchanged when there's no token, the hash is identical → existing mp3s still hit). Smoke gate after wiring.

### Layer 3 — VoicePrimer (DONE for handle variants; device variants still TODO)

- `device_labels.tres` filled out for all 4 gamepad profiles.
- `autoload/voice_primer.gd` registered.
- Scene-walk on `Events.scene_loaded` (or whatever signal SceneLoader emits when a level finishes loading).
- Background `HTTPRequest` worker draining the queue.
- Foreground/background coordination via `_in_flight` callbacks.
- `Input.joy_connection_changed` → re-prime missing variants for newly-relevant device.
- `tools/bake_voice_cache.gd` CLI script for pre-ship.

---

## Open questions

1. **Variant count for v1 of layer 3.** Start with 2 (keyboard + generic gamepad), expand to 4 only after gamepad-label feel is validated? Or all 5 from day one because the synth is a one-time cost?
2. **Where do we draw the line on what's tokenized?** Just InputMap action labels, or also character names (`{player_handle}` already works via DialogueManager mustache, but not in voice lines)? Voice lines with `{player_handle}` are an interesting feature but multiply variant count by handle-pool size (20) — probably not worth it. Keep voice-line tokens limited to InputMap actions for v1.
3. **Cache eviction.** None for v1. The shipped cache is bounded (templates × profiles × characters); ~MB-scale. Revisit only if size becomes a concern.
4. **TTS provider lock-in.** Everything routes through `Dialogue._cache_path_*` and the ElevenLabs HTTP request. If we ever swap providers, the cache hashes regenerate and old mp3s become orphans. Acceptable — just nuke `res://audio/voice_cache/` and re-bake.

---

## File touchpoints (for layer 2-3 work)

- `autoload/dialogue.gd` — leaves alone; reuse `_cache_path_read`, `_cache_path_write`, `_voices`.
- `autoload/companion.gd` — wrap `speak()` body with `LineLocalizer.resolve` call.
- `autoload/walkie.gd` — same wrap.
- `autoload/voice_primer.gd` — new.
- `dialogue/device_labels.tres` + `dialogue/device_labels.gd` — new resource + class.
- `dialogue/line_localizer.gd` — new static helpers.
- `dialogue/device_profile.gd` — new enum + detect.
- `tools/bake_voice_cache.gd` — new pre-ship script.
- Existing `RespawnMessageZone` / `WalkieTrigger` — add to group `"voice_template_source"`, expose template through a method.

No edits to PlayerBody, Audio, Events, or any existing scenes are required for layer 2-3.
