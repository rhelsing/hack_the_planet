class_name VoiceMap
extends Resource

## Maps dialogue-character names (e.g. "Glitch", "Sophia", "Narrator") to
## ElevenLabs voice IDs. Edit the .tres in the Inspector or this file to
## add/change voices. See docs/interactables.md §9.3.
##
## ElevenLabs rotates default voices yearly. If a voice 404s, rerun
##   `godot --headless res://tools/list_voices.tscn --quit-after 600`
## to fetch the current live roster.
##
## ─────────────────────────────────────────────────────────────────────
## FULL VOICE ROSTER — 21 premade voices (verified 2026-04-23)
## Names, descriptions, and labels are pulled verbatim from the
## ElevenLabs /v1/voices endpoint. Copy a voice_id below into the
## `voices` dict to assign it.
## ─────────────────────────────────────────────────────────────────────
##
## ── Male, american ──
## CwhRBWXzGAHq8TQ4Fs17  Roger    — Laid-Back, Casual, Resonant   (middle_aged classy, conversational)
## IKne3meq5aSn9XLyUdCD  Charlie  — Deep, Confident, Energetic    (young hyped, conversational, AUSTRALIAN)
## N2lVS1w4EtoT3dr4eOWO  Callum   — Husky Trickster                (middle_aged, characters_animation)
## SOYHLrjzK2X1ezoPC6cr  Harry    — Fierce Warrior                 (young rough, characters_animation)
## TX3LPaxmHKxFdv7VOQHJ  Liam     — Energetic, Social Media Creator (young confident, social_media)
## bIHbv24MWmeRgasZH58o  Will     — Relaxed Optimist               (young chill, conversational)
## cjVigY5qzO86Huf0OWal  Eric     — Smooth, Trustworthy            (middle_aged classy, conversational)
## iP95p4xoKVk53GoZ742B  Chris    — Charming, Down-to-Earth        (middle_aged casual, conversational)
## nPczCjzI2devNBz1zQrb  Brian    — Deep, Resonant and Comforting  (middle_aged classy, social_media)
## pNInz6obpgDQGcFmaJgB  Adam     — Dominant, Firm                 (middle_aged, social_media)
## pqHfZKP75CvOlQylNhV4  Bill     — Wise, Mature, Balanced         (old crisp, advertisement)
##
## ── Male, british ──
## JBFqnCBsd6RMkjVDRZzb  George   — Warm, Captivating Storyteller (middle_aged mature, narrative_story)
## onwK4e9ZLuTAKqWW03F9  Daniel   — Steady Broadcaster             (middle_aged formal, informative_educational)
##
## ── Female, american ──
## EXAVITQu4vr4xnSDxMaL  Sarah    — Mature, Reassuring, Confident (young professional, entertainment_tv)
## FGY2WhTYpPnrIDTdsKH5  Laura    — Enthusiast, Quirky Attitude   (young sassy, social_media)
## XrExE9yKIg1WjnnlVkGX  Matilda  — Knowledgable, Professional    (middle_aged upbeat, informative_educational)
## cgSgspJ2msm6clMCkdW9  Jessica  — Playful, Bright, Warm          (young cute, conversational)
## hpp4J3VqNfWAUOO0d1Us  Bella    — Professional, Bright, Warm     (middle_aged professional, informative_educational)
##
## ── Female, british ──
## Xb7hH8MSUJpSbSDYk0k2  Alice    — Clear, Engaging Educator       (middle_aged professional, informative_educational)
## pFZP5JQG7iQjIQuC4Bku  Lily     — Velvety Actress                (middle_aged confident, informative_educational)
##
## ── Gender-neutral ──
## SAz9YHcvj6GT2YYXdXww  River    — Relaxed, Neutral, Informative (middle_aged calm, conversational)
##
## ─────────────────────────────────────────────────────────────────────
@export var voices: Dictionary = {
	"Grit": "N2lVS1w4EtoT3dr4eOWO",          # Callum (formerly "Troll")
	"Me": "EXAVITQu4vr4xnSDxMaL",            # Sarah
	"Narrator": "JBFqnCBsd6RMkjVDRZzb",      # George
	"Sophia": "hpp4J3VqNfWAUOO0d1Us",        # Bella
	"Frog": "CwhRBWXzGAHq8TQ4Fs17",          # Roger
	"Squirrel": "pNInz6obpgDQGcFmaJgB",      # Adam
	"Apple Tree": "cgSgspJ2msm6clMCkdW9",    # Jessica
	"Snail": "pFZP5JQG7iQjIQuC4Bku",         # Lily
	"Glitch": "bIHbv24MWmeRgasZH58o",        # Will — relaxed optimist, young chill
}


func get_voice_id(character: String) -> String:
	return voices.get(character, "") as String


func has_voice(character: String) -> bool:
	return voices.has(character) and not String(voices[character]).is_empty()
