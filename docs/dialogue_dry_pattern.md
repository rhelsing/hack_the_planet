# Dialogue DRY Pattern — Elegant Question Hubs

The shape every multi-stage NPC conversation in this project should follow.
Pattern is in production across `dial_tone.dialogue`, `hub_nyx.dialogue`,
`glitch_2.dialogue`, `hub_post4_glitch.dialogue`, `hub_post4_splice.dialogue`,
and `level_4_glitch_post.dialogue`. Reference any of those when in doubt;
this doc covers the why and the rules.

---

## The shape

For any NPC that the player can revisit (hub characters, post-level
checkpoints, anywhere a "second conversation" is meaningful), structure
the dialogue file as **four blocks**:

```
~ stage_X
    Opener (obligatory beat — runs once per save)
    => [stage]_entry on revisit, => [stage]_questions on first

~ [stage]_entry
    Abbreviated greeting (one short line)
    => [stage]_questions

~ [stage]_questions
    All probe options inline with their mini-dialogue
    Self-loop trailing => [stage]_questions

~ [stage]_done   (when needed)
    Exit beat that sets progression flags
    => END
```

Three labels, one self-loop. **Never** write per-probe blocks (`~ stage_who`,
`~ stage_what`, `~ stage_why`) unless a probe genuinely needs to escape the
loop (rare — see "When to break the pattern" below).

### Worked example

```
~ stage_post_2

# Obligatory opener — runs once. Re-talks route through the entry block
# for an abbreviated greeting, then drop into the questions hub.
if GameState.get_flag("post_2_opener_seen", false)
    => post_2_entry

DialTone: {{HandlePicker.chosen_name()}}. You made it back.
Nyx: He wouldn't have made it back if we weren't there to pull him out.
DialTone: The bad news is Splice is on your trail.
do GameState.set_flag("post_2_opener_seen", true)
=> post_2_questions


# Re-talk greeting. Fires once per dialogue session because the questions
# hub self-loops to itself, never back to entry.

~ post_2_entry

DialTone: You got the plan?
=> post_2_questions


# Single shared question hub.

~ post_2_questions

- So what's the plan?
    DialTone: Three ways to look. Three of us looking.
    DialTone: We split.. stay synced up on the channel..
    do GameState.set_flag("level_3_unlocked", true)
- Who is Splice?
    DialTone: Black-hat. Exiled.
    Nyx: He used to run with us.
    do GameState.set_flag("post_2_asked_who", true)
- [if GameState.get_flag("post_2_asked_who", false) /] Pull that thread.
    DialTone: They were a thing. ...
- I'm in.
    => post_2_done
=> post_2_questions


~ post_2_done

DialTone: We move when you do.
do GameState.set_flag("level_3_unlocked", true)
=> END
```

---

## The rules

### Rule 1 — One opener block per stage, gated on a `*_opener_seen` flag

The obligatory beat (Splice surfacing, the prank reveal, the post-L3 argument
between Nyx and DialTone) is non-negotiable narrative content. It fires once
when the player reaches the stage, then never replays.

```
if GameState.get_flag("post_2_opener_seen", false)
    => post_2_entry

[opener content]
do GameState.set_flag("post_2_opener_seen", true)
=> post_2_questions
```

The flag set is **at the END** of the opener (right before the `=> *_questions`
line), so the opener completes before flagging itself "seen." If the player
quits mid-opener, the flag isn't set, and they get the opener again next time.

### Rule 2 — Abbreviated greeting in `*_entry`, fires once per dialogue session

The entry block exists for one reason: speak ONE short re-talk greeting, then
drop into the questions hub. **Never** put probe content in entry; it's a
greeting block, not a menu.

```
~ post_2_entry

DialTone: You got the plan?
=> post_2_questions
```

It fires **once per dialogue session** because the questions hub self-loops to
itself, never back to entry. Player walks away, comes back later → fresh
session → fresh greeting.

### Rule 3 — One questions hub per stage, all probes inline, self-loop

The hub holds **every** probe as an inline option with its mini-dialogue
attached. No `=> stage_who` jumps to dedicated blocks. The trailing
`=> *_questions` makes the menu re-show after each probe.

```
~ post_2_questions

- So what's the plan?
    DialTone: Three ways to look. ...
- Who is Splice?
    DialTone: Black-hat. Exiled. ...
- I'm in.
    => post_2_done
=> post_2_questions
```

### Rule 4 — Either/or prompt: block-level `if`, never inline `[if/else]`

**The single most-violated rule.** The questions hub's prompt line —
"Anything else?" / "What's on your mind?" / etc. — must:

- **Not speak** on the first visit (the opener was the greeting).
- **Speak** on every menu re-show within a re-engagement session, **only if**
  there was a re-engagement.

The inline `[if/else]` form is **wrong** because it always speaks something:

```
# WRONG — speaks the [else] text on first visit
DialTone: [if seen]Anything else?[else]Where do you want to start?[/if]
```

The block-level `if` is **correct** — when the flag is false, the entire line
is skipped:

```
# RIGHT — speaks nothing on first visit, "Anything else?" on revisits
if GameState.get_flag("post_2_questions_seen", false)
    DialTone: Anything else?
```

But where does that flag get set? See Rule 5.

### Rule 5 — Use `*_opener_seen` for the prompt gate, NOT `*_questions_seen`

Don't introduce a separate `*_questions_seen` flag. Use the existing
`*_opener_seen`. Reasoning:

- `*_opener_seen` is set at the END of the opener — so it's true for every
  visit AFTER the first. Exactly the condition we want for the entry-block
  greeting and the in-hub prompt.
- A separate `*_questions_seen` set inside the loop only fires if the player
  takes a probe that falls through to the loop. If they pick the exit option
  (`=> *_done`) on first visit, the flag never sets, and on revisit the prompt
  is silent.

Use the entry-block pattern (Rule 2) instead of the inline-prompt pattern.
The entry block sits between opener and hub, fires once per session, and
sidesteps the flag-tracking problem entirely.

### Rule 6 — Flag-gate follow-up probes off their parent

When a probe should only become visible after another has been asked
("Pull that thread." appears after "Who is Splice?"), use a flag set in the
parent probe and an `[if /]` guard on the follow-up:

```
- Who is Splice?
    DialTone: Black-hat. Exiled.
    do GameState.set_flag("post_2_asked_who", true)
- [if GameState.get_flag("post_2_asked_who", false) /] Pull that thread.
    DialTone: They were a thing. ...
```

The follow-up sits as a **top-level option** in the same hub, gated on the
parent's flag. This is the water-town pattern (see `3dPFormer/dialogue/villiage_level0.dialogue` if you have it).

**Don't nest options inside an option's content.** Dialogue Manager doesn't
support that pattern reliably. If a probe truly needs a sub-menu (the
"What's up?" stay-or-log-out beat in `nyx_post_2`), factor it to its own
block (Rule 8).

### Rule 7 — Name characters on first reference; pronouns thereafter

Pronoun ambiguity is the easiest dialogue bug to ship. When a beat first
mentions a character, use their name. Subsequent references in the same beat
can use pronouns.

Wrong (speaker is Nyx, "his plan" could mean DialTone or Splice):

```
Nyx: His plan's a good plan.
```

Right:

```
Nyx: DialTone's plan is a good plan.
```

This bites hardest in the inline mini-dialogue under each probe — the player
can ask probes in any order, so a pronoun's antecedent might never have been
established in this session.

### Rule 8 — When to break the pattern (rare)

A probe that has a **multi-step decision branch with one-way exits** doesn't
fit the inline pattern. Example: `nyx_post_2`'s "What's up?" path leads to
"Are you telling me to log out?" / "Would you?" / "Not logging out." —
each picks a different end card.

For those, factor into a side block:

```
- What's up?
    => nyx_post_2_stay_or_go

~ nyx_post_2_stay_or_go

Nyx: DialTone's plan is a good plan. ...
- Are you telling me to log out?
    Nyx: I'm telling you you can.
    => nyx_post_2_choice
- Would you?
    Nyx: I can't. Splice is mine to deal with.
    => nyx_post_2_choice
- Not logging out.
    Nyx: Then catch up. Portal's behind him.
    => END

~ nyx_post_2_choice

Nyx: Whatever you decide, I won't take it personally.
=> END
```

The side block is **explicitly NOT a probe hub** — no self-loop, no return
to questions, exits straight to END. This is fine; the player chose a
decision-branch, not a question.

---

## Visited-dim integration (FYI)

`scroll_balloon.gd:_dim_visited_responses` greys out probe options the
player has already asked, scoped per character. Implementation:

- On every option click, `GameState.visit_dialogue(character, response.id, response.text)` records it.
- Visit key is `text + "→" + next_id` per `GameState._zip` — captures
  semantic identity (same wording → same target = same key) without being
  fragile to dialogue-file edits.
- On menu render, `_dim_visited_responses` walks each button, looks up its
  response's key, and applies `VISITED_DIM` modulate if the key is set.
- The exit option (`EXIT_TEXT = "End the conversation"`) is exempted so
  "see you on the wire" / "I'm in." / similar exits never grey out.

You don't need to do anything to opt in — the pattern is automatic for any
inline option in a questions hub. Just use clear, distinct response text and
the dim layer handles itself.

---

## Pre-bake compatibility (FYI)

`tools/prime_all_dialogue.gd` walks every `.dialogue` file and pre-caches TTS
for every speaker line. The walker `strip_edges()` each line before the
speaker regex, so **indented inline dialogue under a `-` option** is matched
correctly. You don't need to outdent for the bake. `{{HandlePicker.chosen_name()}}`
and other mustache calls are expanded via `DialogueExpander.expand()` so
each handle variant gets its own cached MP3.

Both branches of a `[if]/[else]` block AND every line inside a block-level
`if` are walked, so conditional-only content is still cached.

---

## Quick checklist when authoring a new stage

1. Three blocks: `~ stage_X`, `~ [stage]_entry`, `~ [stage]_questions`. Plus
   `~ [stage]_done` if the stage has a progression-flag exit.
2. Opener gated on `*_opener_seen`; flag set at end of opener.
3. `*_entry` is one short greeting line then `=> *_questions`. No probes in
   entry.
4. `*_questions` lists every probe inline with its mini-dialogue, plus an
   exit option, plus a trailing `=> *_questions` self-loop.
5. Prompt line inside `_questions` (if any) gated on `*_opener_seen` via a
   block-level `if` — **never** inline `[if/else]`.
6. Follow-up probes flag-gated off their parent (Rule 6).
7. First mention of any character uses their name; pronouns thereafter.
8. Side blocks only for one-way decision branches (Rule 8).

If a stage starts feeling like 6+ blocks, you've drifted off the pattern —
re-read this doc.
