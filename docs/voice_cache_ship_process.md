# Voice Cache Ship Process

How to bake ElevenLabs voice lines into the shipped build so the exported game never calls the ElevenLabs API.

**Read this before cutting a release.** Also re-read it after adding new dialogue or walkie lines.

---

## Why

`autoload/dialogue.gd` synthesizes voice lines via ElevenLabs and caches them to disk by a stable hash of `character + text + voice_id`. That cache is the "ship cache" — at runtime, lines play from mp3 files on disk; the API is only called on a cache miss.

**The API key must never land in an exported build, and the exported build must never need to hit the API.** That means: every voiced line the player could hear must already be cached inside `res://audio/voice_cache/` before export.

The cache lives in two tiers:

| Tier | Location | Purpose |
|---|---|---|
| Dev | `user://tts_cache/` | Where fresh synths land in-editor (always writable). |
| Shipped | `res://audio/voice_cache/` | Committed to repo. Exported builds read from here. |

Runtime read order (see `autoload/dialogue.gd:_cache_path_read`):
1. `res://audio/voice_cache/<hash>.mp3` — shipped cache.
2. `user://tts_cache/<hash>.mp3` — dev-only fallback.
3. API call (only in editor with a key set).

---

## The workflow

### 1. Author voice lines

Write new dialogue (`.dialogue` files), walkie lines (`WalkieTrigger.line`), etc. with the final character + text you want voiced.

### 2. Trigger every line at least once in-editor

Play through the scenes that contain the new lines. Each trigger calls `Dialogue.speak_line` or `Walkie.speak`, which hits the API on cache miss and writes the mp3 to `user://tts_cache/`.

Verify in the console — you should see:

```
[Dialogue] speak_line: CACHE HIT (...)          # already cached
[Dialogue] speak_line: cache MISS — enqueue ElevenLabs request
[Dialogue] _on_http_completed: cached N bytes to user://tts_cache/...
```

If you see only `CACHE HIT` for every line, you're already good — step 2 was unnecessary.

**Listen to each line.** If it reads awkwardly, edit the text, trigger again, and delete the old orphan later (see step 5).

### 3. Sync dev cache → shipped cache

Run the sync tool from the project root:

```
/Applications/Godot.app/Contents/MacOS/Godot --headless --script res://tools/sync_voice_cache.gd
```

Output:

```
=== sync_voice_cache ===
  dev:     .../app_userdata/.../tts_cache/
  shipped: .../hack_the_planet/audio/voice_cache/
  + dialtone_abc123....mp3
  + nyx_def456....mp3
Summary:
  copied:  2
  skipped: 100 (already in shipped cache)
  orphans: 0 (in shipped but not in dev)
```

The tool is idempotent — safe to re-run. Already-shipped files are not re-copied.

### 4. Verify the arc plays with no API key

This is the critical safety check.

```
unset ELEVEN_LABS_API_KEY
rm -f ~/Library/Application\ Support/Godot/app_userdata/*/tts_config.tres  # only if you use the .tres key path
```

Boot the game. Play through the full Level 1 arc:
- Hub → DialTone intro (picks handle, grants walkie)
- Portal → Level 1 → walkie cues fire
- Find Nyx → her reveal dialogue
- Return to hub → DialTone's post-L1 dialogue

Every line must play. If any line is silent, you have a cache miss that didn't get synced. Find the offending line in the console:

```
[Dialogue] speak_line: cache MISS — enqueue ElevenLabs request
[Dialogue] _maybe_dispatch: SKIP — no api key configured
```

Re-set your API key, re-trigger the line in-editor, re-run sync, re-verify.

### 5. Commit the shipped cache

```
git add audio/voice_cache/
git commit -m "voice: bake DialTone + Nyx Level 1 lines"
```

**Yes, these are binaries in the repo.** Each clip is ~20-50 KB; a full 4-level arc with plenty of chatter is maybe 10-20 MB committed. That's the price of shippable audio.

### 6. Export

Godot's export profile includes `res://audio/voice_cache/*.mp3` by default (no export filter changes needed — `.mp3` is a standard whitelisted extension). Confirm once by:
- Export → open the exported PCK/ZIP → grep for `audio/voice_cache/` entries.

---

## Orphans

"Orphans" are mp3s in `res://audio/voice_cache/` whose text is no longer spoken by any character (you edited the line, renamed the character, or removed it entirely). The sync tool reports them but never deletes them.

To clean orphans, delete them manually after confirming they're truly unused:

```
# List orphans (from sync_voice_cache output):
# orphans: N (in shipped but not in dev)
#   ? old_line_abc.mp3

# Manually rm the ones you're sure about, then commit.
```

**Do not auto-delete.** An "orphan" can be a line that you haven't synth'd yet in your current user://, but another dev already synthed months ago. Safer to review by hand.

---

## Hash stability

Filename format: `<character_lower_underscores>_<md5(character + "__" + text + "__" + voice_id).left(15)>.mp3`

This is machine-stable — another dev synthesizing the same line on another machine produces the same filename. So you don't get collisions or duplicates when multiple devs sync the cache.

If you change a character's voice_id in `voices.gd`, all lines for that character get new hashes → all old clips become orphans on next sync. Plan your re-voice commits accordingly.

---

## Changing model version

If you swap `ELEVEN_MODEL_ID` (e.g., `eleven_flash_v2_5` → `eleven_v3`) in `autoload/dialogue.gd`:
- The filename hash doesn't include model_id.
- Existing cache hits will still play (old-model audio).
- New synths will use the new model but reuse old filenames if the `character + text + voice_id` matches.
- To force re-synth everything: delete `user://tts_cache/` and `res://audio/voice_cache/`, then re-trigger all lines, re-sync, re-commit.

This is rare (model bumps typically happen once a year when ElevenLabs retires an old model).

---

## Emergency: key leaked in an export

If an exported build somehow contains `tts_config.tres` or the API key in any form:
1. **Revoke the key immediately** via ElevenLabs dashboard.
2. Regenerate. Update `user://tts_config.tres` or `ELEVEN_LABS_API_KEY` env with the new one.
3. Re-export, verify the new build has no key (grep the PCK).

The system is designed to make this unlikely: the key is only in `user://` or env, never committed. But: review your export presets' "Resources" tab to confirm `user://` isn't accidentally included (it shouldn't be — user:// is never shipped by default, but double-check).

---

## Related files

- `autoload/dialogue.gd` — cache path logic, HTTP requests, playback routing.
- `autoload/walkie.gd` — same cache, plays through the Walkie bus with phone FX.
- `tools/sync_voice_cache.gd` — the sync tool.
- `audio/voice_cache/README.md` — short note in the cache dir itself.
- `dialogue/voices.gd` + `voices.tres` — character → voice_id map. Changing this invalidates existing hashes for that character.
