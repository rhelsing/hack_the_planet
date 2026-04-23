class_name VoiceMap
extends Resource

## Maps dialogue-character names (e.g. "Troll", "Sophia", "Narrator") to
## ElevenLabs voice IDs. Seeded from 3dPFormer's character_mapping dict;
## edit the .tres in the Inspector to add/change voices.
## See docs/interactables.md §9.3.

## Voice IDs confirmed accessible on this project's ElevenLabs account,
## verified via tools/list_voices.tscn (April 2026 — 21 premade voices).
##
## ElevenLabs rotates default voices yearly. If any of these 402 in the
## future, rerun `godot --headless res://tools/list_voices.tscn` to fetch
## the current live roster and update this map accordingly.
##
## Category labels mapped to our characters (use_case from the API):
##   - Troll      → Callum  (characters_animation, husky trickster)
##   - Me         → Sarah   (entertainment_tv, young female professional)
##   - Narrator   → George  (narrative_story, British warm storyteller)
##   - Sophia     → Bella   (informative_educational, bright warm female)
##   - Frog       → Roger   (conversational, laid-back male)
##   - Squirrel   → Adam    (social_media, dominant firm male)
##   - Apple Tree → Jessica (conversational, playful warm female)
##   - Snail      → Lily    (informative_educational, British velvety female)
@export var voices: Dictionary = {
	"Troll": "N2lVS1w4EtoT3dr4eOWO",         # Callum
	"Me": "EXAVITQu4vr4xnSDxMaL",            # Sarah
	"Narrator": "JBFqnCBsd6RMkjVDRZzb",      # George
	"Sophia": "hpp4J3VqNfWAUOO0d1Us",        # Bella
	"Frog": "CwhRBWXzGAHq8TQ4Fs17",          # Roger
	"Squirrel": "pNInz6obpgDQGcFmaJgB",      # Adam
	"Apple Tree": "cgSgspJ2msm6clMCkdW9",    # Jessica
	"Snail": "pFZP5JQG7iQjIQuC4Bku",         # Lily
}


func get_voice_id(character: String) -> String:
	return voices.get(character, "") as String


func has_voice(character: String) -> bool:
	return voices.has(character) and not String(voices[character]).is_empty()
