# Rules for Dialogue

How we write `.dialogue` files for NPCs, walkie-talkie chatter, and respawn
hints. The goal is fast, voiced, optional depth — never block the player from
getting back into the action.

---

## 1. Core sentiment

> Short and sweet by default. Optional probes for the curious. First visit
> reads differently from a revisit.

Three rules:

1. **The default beat is short.** A greeting, the new information, a single
   "I'm done, move on" exit. Do not infodump on first contact.
2. **Lore and mechanics live behind opt-in branches.** Anything beyond the
   one essential beat is offered as a player choice ("What is the Gibson?",
   "What are those things ahead?"). Players who want speed are back in the
   level in five seconds; players who want flavor pick deeper.
3. **Revisit greets shorter, exposes the same probes.** The first visit gets
   a brief in-fiction hook ("Well executed."). Revisit gets a two-word
   acknowledgment ("At your service."). The probe menu is identical so the
   player can come back when they remember they wanted to ask.

This pattern keeps NPCs feeling like patient subject-matter experts rather
than monologuing tutorials.

---

## 2. Structural template

Every NPC dialogue should fit this skeleton:

```
~ start

if GameState.get_flag("<npc>_done", false)
    Speaker: <revisit greeting>
    => menu

Speaker: <first-visit hook>
=> menu

~ menu

- Onward.
    => done
- <Probe option A>
    => topic_a
- <Probe option B>
    => topic_b

~ topic_a

Speaker: <one or two lines>
Speaker: Anything else?
- <Cross-link to topic_b>
    => topic_b
- That's all.
    => done

~ topic_b
…

~ done

do GameState.set_flag("<npc>_done", true)
Speaker: <sign-off line>
=> END
```

Conventions baked in:

- **`~ menu` is the hub.** Every probe ends by either looping back through a
  cross-link choice or jumping to `~ done`. Never strand the player at the
  end of a topic node.
- **`do GameState.set_flag(...)` lives in `~ done`.** Setting the flag from
  the terminal node guarantees it fires on every completed conversation
  regardless of which probes the player explored.
- **The flag name pairs with the CompanionNPC's `advance_flag`** when the
  NPC ratchets to a future station. See companion_npc.gd's ratchet system —
  the dialogue's terminal flag is what advances the companion forward.
- **Cross-link probe topics** so the player can chain explorations without
  hitting `~ done` and starting the menu over.

---

## 3. Voice and tone

- Speaker names match the `voices.gd` map case-sensitively. `Glitch:` not
  `glitch:`. Mismatches log `no voice configured for character="..."` and
  the line plays silent.
- **Match the line to the assigned voice.** Glitch uses Daniel (British,
  formal broadcaster) — write his lines with restraint and Jarvis-style
  precision ("Quite. One addendum…"). Don't hand a formal voice slangy
  lines unless the contrast is the joke.
- One sentence per line is the default. Long monologues fragment naturally
  in the bubble UI and break the voiced playback rhythm.
- Italics (`*like this*`) get spoken by the Narrator voice — useful for
  parenthetical asides that aren't from the speaker's voice.

---

## 4. Flags vs ratchet

Two reasons to set a flag:

1. **Mark "this dialogue done"** — pair with `if GameState.get_flag(...)`
   at the top of `~ start` so revisits use the shorter greeting. Convention:
   `<npc>_done`.
2. **Trigger an external state change** — open a door, advance a companion
   to the next station, unlock a pedestal. Convention: meaningful flag name
   that consumers grep for (`door_locked_hack`, `glitch1_done`,
   `powerup_secret`). The CompanionNPC's `advance_flag` matches one of
   these.

Don't set flags inside individual probe nodes — surfacing them in `~ done`
keeps the contract clean and the side effects predictable.

---

## 5. Walkie-talkie mechanic (TBD)

Walkie chatter is an unprompted dialogue — a remote NPC pings the player
mid-action without requiring a press-E interaction. The player can choose
to listen or dismiss but can't deeply branch like a face-to-face talk.

> **TODO**: codify the walkie usage rules once the WalkieUI and trigger
> system are stable. Topics to pin down:
>
> - Trigger conditions (proximity, flag-set, level event, manual remote).
> - Speaker conventions (different name suffix? Daniel vs a separate voice?).
> - Dismiss vs auto-end timing.
> - Modal vs non-modal — does walkie pause the game (no), can the player
>   keep playing through the chatter (yes).
> - Branching: do walkies allow choices, or are they always one-way?
> - Cooldowns / dedupe (walkie should not pile on top of itself).
> - Persistence: which walkies replay on respawn vs fire-once-and-forget.

Until this is filled out, walkie lines should still follow §1 (short and
sweet) and §3 (voice match). Treat them as monologues with no choices.

---

## 6. Post-respawn hint (TBD)

Hints surfaced by RespawnMessageZone after the player dies. Currently a
single line per zone, displayed by the RespawnMessageOverlay (see
`interactable/respawn_message_overlay/`).

> **TODO**: codify hint authoring rules. Topics to pin down:
>
> - Style guide: imperative ("Try jumping earlier") vs descriptive
>   ("The wall climb activates at high speed").
> - Length cap (current overlay handles ~one short sentence comfortably).
> - Voicing: are these spoken by Glitch, the Narrator, or silent text?
> - Chaining: how multiple zone hits in sequence read on respawn (chain
>   already supported, but should we cap the chain length?).
> - When to use a hint vs an in-world tutorial (Glitch dialogue beat).
> - First-time-only hints vs every-respawn nags.

---

## 7. Authoring checklist

Before committing a new `.dialogue`:

- [ ] Speaker names match `voices.gd`.
- [ ] First visit and revisit greeting paths exist (or it's intentionally
      single-shot and there's a comment explaining why).
- [ ] At least one "Onward" / "That's all" exit from every menu state.
- [ ] All probe nodes loop back to `~ menu` OR jump to `~ done`.
- [ ] `do GameState.set_flag(...)` lives in `~ done`, not inside a probe.
- [ ] Lines match the assigned voice's register.
- [ ] Tested in-game by triggering the dialogue and walking each branch.
