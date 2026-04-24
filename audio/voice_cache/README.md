# Shipped TTS cache

mp3 files here are synthesized once in-editor (via ElevenLabs), then copied from `user://tts_cache/` by `tools/sync_voice_cache.gd`, then committed. Exported builds play from this directory — no ElevenLabs API call at runtime, no API key leak.

**Do not hand-edit.** Run `tools/sync_voice_cache.gd` to refresh after authoring new lines.

Filename format: `<character>_<md5(char + text + voice_id).left(15)>.mp3` — machine-stable. Regenerating the same line on any dev's machine produces the same filename, so merges don't duplicate.

Read path in `autoload/dialogue.gd`: `_cache_path_read` checks this dir first, then `user://tts_cache/` (dev fallback), else enqueues an API call. Write path always goes to `user://` (res:// is read-only in exported builds).
