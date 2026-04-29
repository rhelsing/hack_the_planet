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

## 7. Inline plugin syntax — quick reference

The DialogueManager plugin parses three bracket constructs inside line text
and choice labels. Mixing them up causes the literal `[if ...]` text to
render in the bubble, which is the single most common authoring bug.

### Choice gates (self-closing `/]`)

A choice button that should appear only when a condition holds. **The `[if]`
must self-close** — `/]` at the end, no closing `[/if]` later:

```
- [if GameState.get_flag("composure_passed", false) /] About that stare-down...
    => composure_topic
- [if int(GameState.get_flag("dialtone_messenger_thread", 0)) == 4 /] One more thing.
    => messenger_4
```

❌ **Wrong** — produces literal text in the bubble:

```
- [if GameState.get_flag("composure_passed", false)] About that stare-down...
```

The plugin saw `[if ...]` *without* the closing `/`, parsed it as the OPEN
of a block conditional, looked for `[/if]`, didn't find one, and gave up.

### Inline-text conditionals (block form)

Switching between two text fragments mid-line. **Open with `]`, close with
`[/if]`** — no `/` on the open. The `[else]` half is optional:

```
Grit: [if GameState.get_flag("troll_met", false)]Anything else?[else]What do you want to know?[/if]
```

If you want the line to disappear entirely when the condition fails, the
right move is usually a per-stage `if/elif` block at section boundaries —
not an inline conditional with empty branches.

### Random alternations

Pure flavor variation, no condition:

```
NPC: [[See you around, kid.|Later.|Don't step on any spikes.]]
```

Plugin picks one option uniformly at random per render.

### Mustache function calls

Plain `{{ }}` runs a GDScript expression and substitutes the result:

```
Glitch: {{HandlePicker.reaction()}}
DialTone: Hey, {{HandlePicker.chosen_name()}}.
Glitch: Press {{Glyphs.for_action("jump")}} to jump.
```

The supported sources in this project are listed in
`tools/prime_all_dialogue.gd` (under `_mustache_alternatives`) — it's the
build-time enumerator that needs to know every shape we author so it can
pre-cache every variant. **If you add a new mustache source, also extend
that table** or the variant won't ship pre-rendered (lazy fill at runtime
still works — it just costs an HTTP roundtrip the first time).

### What lives inside `[if ...]` — expression rules

The plugin's expression evaluator is **not full GDScript**. It exposes only:

- **Autoloads by name** (`GameState`, `HandlePicker`, `Skills`, `Glyphs`, ...).
- **Method calls on autoloads** (`GameState.get_flag("foo", 0)`, `Skills.can_attempt("composure")`).
- **Literals** — strings, numbers, `true` / `false`.
- **Operators** — `==`, `!=`, `<`, `>`, `<=`, `>=`, `and`, `or`, `not`, `!`.

It does **not** expose GDScript built-ins. Common gotchas:

```
[if int(GameState.get_flag("foo", 0)) == 1 /]   ← runtime error: "Method 'int' not found"
[if str(x) == "Cipher" /]                        ← same
[if GameState.flags["foo"] == 1 /]               ← subscript not supported
```

Compare against the value the autoload returns directly. Counters in
`GameState.flags` are stored as `int` natively when set with an int, so
no cast is needed:

```
[if GameState.get_flag("dialtone_messenger_thread", 0) == 1 /]
```

If you actually need a built-in transform, do it in the autoload (e.g.
add `HandlePicker.has_picked()` rather than checking
`HandlePicker.chosen_name() != ""` inside the bracket).

### Quick contrast — the `/` matters

| Form | Meaning |
|---|---|
| `[if X /]` | Self-closing — gates a single choice line |
| `[if X]a[else]b[/if]` | Block — two text branches inside one line |
| `[if X]a[/if]` | Block — single branch, removed when condition fails |
| `[if X]` (no `/`, no `[/if]`) | **Bug — renders literally** |

---

## 8. Authoring checklist

Before committing a new `.dialogue`:

- [ ] Speaker names match `voices.gd`.
- [ ] First visit and revisit greeting paths exist (or it's intentionally
      single-shot and there's a comment explaining why).
- [ ] At least one "Onward" / "That's all" exit from every menu state.
- [ ] All probe nodes loop back to `~ menu` OR jump to `~ done`.
- [ ] `do GameState.set_flag(...)` lives in `~ done`, not inside a probe.
- [ ] Lines match the assigned voice's register.
- [ ] Tested in-game by triggering the dialogue and walking each branch.
