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
## VOICE LIBRARY CANDIDATES — community-shared via tools/browse_voices.gd
## These are NOT in the premade roster. Before assigning one below, the
## voice must be added to the account (ElevenLabs website → Voice Library
## → "Add to my voices", or via POST /v1/voices/add/{owner}/{voice_id}).
## Once added, it shows up under tools/list_voices.gd output.
## ─────────────────────────────────────────────────────────────────────
##
## ── African American + femme-fatale intersection (top picks for Nyx) ──
## NQMJRVvPew6HsaebYnZj  Cecily       — Intelligent AA woman, smooth calm delivery, subtle West Coast accent (middle_aged confident, advertisement) — backup #2
## zWoalRDt5TZrmW4ROIA7  Brooklyn     — Urban, confident, conversational AA New Yorker (middle_aged confident, conversational) — backup #1
## Z5JpFCNFIz8Nhe4KEikq  Kelli LaShae — 43yo AA Southern, naturally deep alto, warm rich (middle_aged confident, narrative)
## MHPwHxLx0nmGIb5Jnbly  Empress      — Strong confident 60yo Black woman, smoky breathy (old deep, narrative)
## P0hCzXsmThfWdItxdbMw  Janay        — AA, warm but direct, slightly persuasive (middle_aged intense, narrative)
##
## ── Femme-fatale vibe (not necessarily AA) ──
## 54Cze5LrTSyLgbO6Fhlc  Caty         — Droll, wry, dry. Sarcastic 'whatever' vibe (young sassy, characters_animation) ✓ ACTIVE on Nyx
## 4tRn1lSkEn13EVTuqb0g  Serafina     — ★ featured. Sensual temptress, deep smooth velvety captivating (young mature, characters_animation) — backup #1
## o9yXv9EFSasRrRM3x6xK  Glinda       — Confident, sly, sultry, hint of smirk, in charge (middle_aged serious, social_media) — backup #4
## TC0Zp7WVFzhA8zpTlRqV  Aria         — Dark velvet for female villain or seductress (young confident, characters_animation)
## VURZ3kCSkbLjDYld5lne  Celeste      — Deep, sultry, husky, sensual tone with dark femme (young husky, characters_animation)
## eVItLK1UvXctxuaRV2Oq  Jean         — Seductive dangerous femme fatale, drips with sexy allure (young confident, characters_animation)
## cENJycK4Wg62xVikqkaA  Izumi        — Sultry demanding diva, smooth playful, rich and powerful (middle_aged husky, characters_animation)
##
## ── Male character voices ──
## cgLpYGyXZhkyalKZ0xeZ  Knox         — Philosophical Gym Bro: bro-dude hype-man turned heart-on-sleeve philosopher (american young excited, characters_animation) ✓ ACTIVE on Splice
## dPah2VEoifKnZT37774q  Knox Dark    — Serious, deep, slow methodical and particular (american middle_aged serious, narrative)
## ktrGUw7rURIQyMrQZqCu  Cassius      — Velvety, measured, commanding. British RP, calm deliberate cadence (british middle_aged wise, characters_animation)
## wSqOdjeNqDrHcoK0zorF  Lukas        — Excited youthful young man, passion + hope + confidence (american young, characters/social)
##
## ── Witty / sarcastic young male (DialTone candidates) ──
## Fz7HYdHHCP1EF1FLn46C  Erik            — Natural Easygoing Millennial, funny and sarcastic (canadian young casual, conversational) ✓ ACTIVE on DialTone — starter
## 1SqpcpYtkf66sVj4eNEv  Toni            — Easygoing & Personable, witty best friend, 20-something (american young casual, narrative_story) — starter
## QzclONYwRWvec152I3wf  Brandon         — Youthful, slightly nasal, dry subtle sarcasm (american young chill, social_media) — starter
## gBDv2oGht23KfZZMSUEi  Ryan            — Smooth, effortlessly cool, dry wit, disaffected charm (american young calm, conversational) — starter
## eZm9vdjYgL9PZKtf7XMM  Noah            — Slightly sarcastic, 'watching videos with a friend' (canadian young chill, conversational) — starter
## uPdPVJPZIryn3WAH8mKG  Moses           — Witty, conversational tone, relatable storyteller, 20s-30s (american young calm, conversational) — starter
## NXaTw4ifg0LAguvKuIwZ  Posh Josh       — Arrogant, smug, prideful, witty, charismatic (british young classy, characters_animation) — starter
## ZuMNkNpj8VN6FgJXZxSi  Evan Byers      — Quirky modern narrator, dry vocal fry, subtle sarcastic edge (american casual, narrative_story) — ❌ creator+
## 7Nn6g4wKiuh6PdenI9wx  Dave            — Witty, Deadpan and Dry, casual podcast host (american anxious, conversational) — ❌ creator+
##
## ── Austin candidates (kept for reference) ──
## MiqnIapt7vNssNQNFXlf  Lucas Austin    — Relaxed, expressive, narration/storytelling (american middle_aged calm, conversational) — starter
## eN7WPylhvgvOGdskN6bn  Austin Quinton  — Conversational salesman, confident open (american middle_aged confident, conversational) — starter
## Xb3zeLrTi6F4ziIcXdwk  Austin (Timid)  — Young timid orphan boy, soft tone (american young soft, characters_animation) — ❌ creator+
## Bj9UqZbhQsanLzgalpEG  Austin (Texas)  — Texas drawl, low gravelly (us southern middle_aged deep, characters_animation) — starter
## fA2wlAJGF6MeyLM32my8  Austin (Calm Leader) — Calm results-driven leadership (american middle_aged calm, conversational) — starter
## TZl0VZDEkMLBwlPLAKD9  Austin (Formal) — Formal, clear, deep tone training-style (american middle_aged formal, informative_educational) — starter
## VAnZB441uRGQ8uoZunqz  Austin (Gentleman) — Deep gravelly storytelling (american middle_aged casual, narrative_story) — starter
## NMilCCbfoygNnI2VZ7ME  Austin (Narration) — Clear expressive audiobook style (american middle_aged professional, narrative_story) — starter
##
## To re-browse with different search terms, edit QUERIES in
## tools/browse_voices.gd and re-run. Full preview_url for each shows up
## in stdout — paste into a browser to listen before adding.
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
	"Glitch": "onwK4e9ZLuTAKqWW03F9",        # Daniel — British, steady broadcaster, formal
	"DialTone": "Fz7HYdHHCP1EF1FLn46C",      # Erik — Natural Easygoing Millennial: laid back, funny, sarcastic (Canadian)
	"Splice": "cgLpYGyXZhkyalKZ0xeZ",        # Knox — Philosophical Gym Bro: bro-dude hype-man turned heart-on-sleeve philosopher
	"Nyx": "54Cze5LrTSyLgbO6Fhlc",           # Caty — droll, wry, dry, sarcastic 'whatever' vibe; backup queue: Serafina → Brooklyn → Cecily → Glinda
}


func get_voice_id(character: String) -> String:
	return voices.get(character, "") as String


func has_voice(character: String) -> bool:
	return voices.has(character) and not String(voices[character]).is_empty()
