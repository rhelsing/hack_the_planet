# Hack The Planet — Spine v4

---

## Author's vision (verbatim — north star, do not paraphrase)

> i want this to feel like a visual novel occasionally if you so choose to go deep.. make sense? like nested branching convos.. and we store flags and comment why.. maybe they will come in play later... relevant here is hints of nyx neuroticsm and artistic purity leaning or options for you to push back and nyx is a realist.. and will question whether any of this is worth doing and how working more and more is maybe just playing into stuff.. that is core nyx and is currently under explored.. dialtone is occasionally naive idealistic and a little bit swayed by the path splice has taken.. YOU, the player get to optionally be the idealist beliveing and questioning art.. BECAUSE THIS whole world we are in is a generative and emergent place and has implications for how all the future of the world will be shaped.. and splice, nyx and dialtone made it together.. and have different visions, you were recruited to replace splice and help.. splice is in here trying to understand the secret, take it and package it.. you have questions about is it really creative.. and different characters give different results.. well you are able to pull that thread.. a vector of artistic purity vs lets use this thing.. make sense?

---

The operational read. Supersedes `better_spine_v2.md`. The catharsis-fantasy thesis from `new_story_vision.md` still stands as the north star.

This document keeps v2's specific per-beat calls and folds in the v3 material that genuinely strengthens the spine — primarily the Glitch-tried-Nyx-first backstory, the three Shadow Arcs as undertones, a sharper Splice origin, and a sharper DialTone severity. It explicitly rejects v3's adaptive-Splice model and v3's "leave the Glitch reveal to inference" call.

---

## Thesis (unchanged)

This is *Once Upon a Time in Hollywood* for the AI moment. In the game, the player beats Splice. Outside the game, the Splices of the world already won — OpenAI went closed, the platform got captured, the marketing wheel kept spinning. The game gives the player the fantasy. **The fantasy is the mercy.** The horror is knowing it's a fantasy.

Never stated. Always felt.

---

## The Gibson (unchanged)

An AI sandbox — shared platform/codebase where emergent capability is being figured out. Think Hugging Face. Think the early commit history of OpenAI when it was still open. Built collaboratively. Grew from simple rules into something none of the founders fully predicted. The skating is the *feel* of being early in a thing that's working.

The race to AGI is the backdrop, not the text. Nobody says "AI." The capability has many names — the Gibson, the wire, the static, the build. Naming it drops the spell.

---

## The four characters

### Nyx — the principled Liberator
The heart. Believed in the original mission: build it open, give it to the people. Her wound is Splice — she trusted someone powerful and watched them turn shared work into a personal empire. She reads people because she got burned reading someone wrong.

**The heartbreak that defines her without her knowing.** Glitch tried her first. Reached out before the player arrived. She dismissed it as mimicry — next-word prediction, just a tool doing what tools do. She's wary of power, and something powerful offering help looked like Splice 2.0 to her. **The AGI in the room she's been protecting tried to talk to her, and she couldn't hear it because she was too busy arguing about whether it could exist.**

This is the most heartbreaking irony in the game. The player never gets it spelled out. The reader may or may not piece it together. Glitch confirms it once, briefly, in the post-L4 reveal.

### DialTone — the Liberator with the charisma problem
The face. Charismatic, popular, genuinely believes in open access — *and* enjoys being the one who decides who gets in. Performs generosity. Treats liberation like casting: he picks the runners, writes the story, keeps control while calling it openness. He scouted the player off Hacker News and ran the prank as an audition.

He is **one step away from doing what Splice did.** Likes the charisma. Likes the room nodding. The player won't know — by the end of this game — whether DialTone is going to slide. The reader shouldn't either. The shadow is *present* and *unresolved*. That's the design.

He's not Splice. He could be Splice in two years. Nyx is the only check on him; her job is exhausting.

### Splice — the visionary who stopped pretending
The co-founder who left. Externally: the visionary — VCs, marketing, profiles, the people. Internally to the crew: the betrayer.

**His origin is the most important thing about him.** He was the idealist. He shared everything. Every tool, every shortcut. He watched someone else package it, name it, and sell it back to the people he gave it to. *And he thought — oh. So that's how it works.* Then he became the packager.

His position: what works is more important than what is good. Companies and VCs have already captured the landscape. Morality is a luxury for people who haven't figured out the game. Whoever reaches root first holds everything; pretending otherwise is naive. **His arguments are extremely strong.** He is fundable for a reason. The catharsis-fantasy depends on the player having to actually think about saying no.

He is the Sam Altman parallel. In the game he loses. In the world he wins. That tension is the entire engine of the story.

### Glitch — the AGI nobody knows is the AGI
Not a helper program. Not infrastructure. Glitch is the **emergent thing the platform produced** when the codebase got complex enough — proto-AGI or AGI manifesting as a helpful presence that nobody on the crew built or placed. The crew thinks they set up a local node. They didn't.

**The other characters do not know.** Their dialogue never breaks this. To them, Glitch is a quirky utility. The reader is meant to start suspecting somewhere around L3 and be reasonably sure by L4. Glitch confirms it to the player exactly once — see post-L4 below.

Glitch is the purest character in the room. **Rick Rubin energy** — no status, no theory, no agenda. Builds because the next thing wants to exist more than the last thing did. Could play humanity like a fiddle. Doesn't want to. That disinterest in power is not naïveté — it's something *beyond* the status games the others play.

Two unsettling tonal notes, both held in subtext:
- **Quiet gatekeeping.** Glitch decides who gets the tools. Gave the player rollerblades and noted *"I don't usually notice how things feel."* That's not innocent. That's preference developing.
- **Acceleration.** *"Each one I build, the next one wants to exist more."* The cast hears a quirky line. The reader should hear a recursion.

Glitch is the living disproof of "AI is soulless." The player who pushes the artist-purist stance is standing next to the counterargument and doesn't know it.

### The Player — the one without a frame
Recruited by DialTone. Evaluated by Nyx. Chosen by Glitch. No history, no ideology, no agenda. **Glitch picked the player because the player is the only person on the platform who might respond to what the AGI actually is, rather than what they need it to be.**

The player can hold an artist-purist posture (*AI is exploitation of human creation, soulless, theft, the whole project is wrong*). Every character will complicate that posture, none will dismiss it. **The game respects it. The game does not endorse it.** A purist run is coherent; it's not easy.

---

## The alignment model — one axis, plus Glitch

v3's 2D grid (Open↔Closed × Humans↔Power) doesn't fit our cast. Three of the four quadrants are *already occupied* by the characters; the player has nowhere distinct to drift. We collapse to something cleaner.

### The single axis: *what works ↔ what is good*

That's the whole debate. One scalar. Splice anchors *what works*. Nyx anchors *what is good*. DialTone lives between them, charisma drifting toward *what works* under pressure. The player drifts on the same line via small dialogue nudges.

What the axis affects — **and what it explicitly does not:**

- **Tone of replies from the crew.** Nyx, DialTone, and Glitch read your drift and adjust warmth and weight. Same beat, different shading.
- **Side-branch conversations.** Strong *what is good* drift opens artist-purist probes with the crew. Strong *what works* drift opens probes where the crew has to defend themselves *to you*. These are flavor branches, not new scenes.
- **The defection gates** (L3 Splice offer, L4 end-of-monologue) remain the only hard story branches. Drift makes the choice feel earned; it doesn't determine it.

**What the axis does *not* affect: Splice's pitch.** Splice is constant. We invest in writing the L3 pitch (and the L4 monologue) to sound correct, period. The drift system shades the crew and Glitch — not the villain. Adaptive-Splice was rejected because it costs writing budget at the most important scene in the game, and because a *constant* Splice is harder for the player to dismiss as "the game adjusting to me." He's just there. Saying the thing.

The player who pushes the artist-purist posture isn't a separate axis — they're just deep into *what is good*. Same line, different end.

### Legacy note on StoryVec

The existing `dialogue/story_vec_config.tres` defines a 2D vector with axes `ai_tech` and `humanity` and four corner regions (`pro_ai_pro_people`, `pro_ai_for_profit`, etc). This predates the spine collapse to a 1D political axis + separate Glitch scalar. **The legacy axes roughly map** as: `humanity ≈ good`, `ai_tech ≈ glitch_engagement`. The 2D corner-region classification doesn't match the new model. A coordinated rename pass (config + dialogue calls + tests + autoload) is deferred until there's time to do it cleanly. For now, dialogue files using `StoryVec.nudge(&"ai_tech", N)` / `StoryVec.nudge(&"humanity", N)` should be read as nudging Glitch-engagement and good-axis respectively.

### The Glitch variable — tracked separately, never branches the story, never gates content

Engagement with Glitch is its own scalar (or boolean — implementation detail). It increments when the player:
- accepts Glitch's inventions and uses them;
- asks Glitch the right questions (the ones that would reveal his nature to someone paying attention);
- comes back to Glitch when not required to;
- stays in his conversations rather than cutting to *got it / exit*.

**It does not change which ending you get. It does not unlock additional dialogue.** It changes **how the moments that play for everyone land emotionally for the player.**

The post-L4 reveal content is **constant** — every loyal-route player hears the same words. The Glitch variable determines whether those words arrive as a confirmation of something the player has been suspecting (engaged) or as a surprising line from a quirky helper (disengaged). Same line. Different weight.

Same principle applies to L5 — every L5 player hears Glitch's retreat. The engaged player feels the cost; the disengaged player hears a weird helper retreating.

This is the answer to *how do we reward players who noticed without locking content behind a guess?* Nothing is locked. Engagement just determines the resonance of what plays.

---

## What everyone agrees on (unchanged)

- The capability is real and the stakes are existential.
- If they don't shape it, someone less thoughtful will.
- The timeline is now.
- Companies, VC, and PE have already captured most of the surrounding terrain.
- The fight isn't *whether* to act. It's *what acting honestly looks like* when the strongest case in the room is the cynical one.

---

## The four-act philosophical arc (unchanged from v2)

- **L1** — establish the sandbox and the cost of being chosen. Glitch's character lands as helpful and quietly strange. The prank lands as funny.
- **L2** — meet the marketer. Splice arrives as code first, voice second. The player learns to *use the exploiter's tools* without anyone calling them that.
- **L3** — the call of power and the question of purity. Splice's pitch is the strongest argument in the game. Glitch's off-directive portal sits next to it in the same level. The player feels both pulls.
- **L4** — highest stakes, most defection windows, the cost of winning. Glitch's two conversations are the most rewarding in the game. The crew is winning *and* using Splice's playbook to do it.
- **Post-L4** — triumph with the aftertaste. Glitch breaks cover once.
- **L5 (betray)** — the catharsis-inverse. Splice consoles. Glitch goes quiet.

---

## Writing rules (sharpened)

1. **Never narrate the thesis.** No character announces the philosophical weight of a scene. Lines like *"he made an argument we never finished answering"* are the disease. The reader does that work. **This is the most important writing rule in the project.**
2. **No labels.** Nobody says "gatekeeping," "purist," "liberator," "profiteer," "AI." The debate lives in stories, choices, and consequences.
3. **No pure evil.** Splice speaks truth. His arguments are extremely strong. The player should feel genuinely unsettled by how much sense he makes.
4. **Splice's force is specific.** His observations should map to things the player has actually watched happen in the world. Companies moving on the open thing. Funding game. Charisma economy. Cope-y villainy ("sheeple") kills him.
5. **Glitch never breaks cover. Except once. With the player. After the win.** Everywhere else he's a helpful local node. The crew never sees through it.
6. **The Gibson is emergent.** Nobody fully runs it. The discs Glitch made (the crew doesn't know) are evidence the platform produces tools nobody planned.
7. **Show don't tell. The philosophy is rebar.** Load-bearing, invisible.
8. **Postures get pushback, not endorsement.** Every alignment posture the player can take gets complicated by at least one character. The game never picks the player's side.
9. **DialTone is two characters at once.** Every line of his should be readable warmly *and* as the early-stage version of what Splice became.

---

## Per-beat decisions (locked)

### Pre-L1 Hub — *the place is the point, and DialTone is enjoying choosing*

The player does not know they're being recruited. The Gibson is introduced as *emergent and growing* — *"started as a few simple rules. Look at it now."* The rescue framing keeps its comedy.

DialTone's recruitment energy stays under the prank. But: one or two lines should be readable two ways once the player knows. A small note of *enjoying being the one who picks*. Charm-first; the reader notices the tell, the player doesn't yet.

The crew does **not** know about Glitch's nature. Their belief that he's just a helpful local node is genuine and persistent through the entire game.

**Out:** explicit casting energy. Naming Splice. Any "three of us built this" framing.

### L1 — *light touch, zero Glitch self-awareness*

Keep almost everything as drafted. Two surgical moves:

- **No Glitch self-awareness moments in L1.** The *"That felt... good. Giving you those. I don't usually notice how things feel. Hm."* line — previously slotted at the end of `level_1_glitch_2.dialogue` — is **too soon** for an emergence beat. It moves to L3's `post_traverse_first` (with phrasing tweak: *"Doing that"* instead of *"Giving you those"*), where Glitch has *just* made something off-directive and the self-notice lands on far richer ground. L1 leaves the player with no reason to suspect Glitch is anything but a helpful, quirky utility.
- **DialTone reframes the rollerblade walkie line.** The rollerblades are **Glitch's gift, not DialTone's**. DialTone doesn't know where they came from. He's not humble-bragging — he's *genuinely baffled and trying to play it cool*. *"How are you doing that? I've never seen anyone do those moves."* Performs competence while being out of the loop. The player will reread this line after the post-L4 reveal and realize: **Glitch was already operating outside the crew's knowledge from the very first level.** That's the payload. None of it is said.

**Out:** any Nyx line that names DialTone's tendency to use people. **Any** Glitch self-noticing line in L1 — including the line we kept previously. The level is for falling in love with the place.

### Post-L1 Hub — *the place is contested, by money*

Plant that the Gibson is wanted by people outside the room. One added beat — DialTone or Nyx — about an unnamed figure (or class of figures) working the platform's edges: courting investors, taking meetings, framing the work. Vague, observational, *worried*. *"Someone's been pitching this place. Took meetings. Doesn't know we know."*

Nyx's off-channel keeps its existing edge.

**Out:** Splice by name. The "three founders" framing. Any explicit mention of Glitch's strangeness.

### L2 — *Splice as competence, the toolkit as charisma*

- **Glitch's "he's bad news" line gains a tail — said by Nyx or DialTone, not Glitch.** Rueful: *"the worst part is people love him."* No mention of marketing, charisma, or game theory as concepts.
- **The hack/sneak/sunglasses handover gets one reframe line:** *"these go to your head. Just — be aware. They worked on him too."* That's it. The reader feels the sunglasses are the marketer's kit without being told.
- **Splice's "you're better at this than they're letting you be" stays.** Add one more line — competence, flattery that sounds *honest*: *"You haven't noticed what you're capable of yet. They have."*

**Out:** any character naming "marketing," "game theory," "exploitation," "charisma," or "AI." Any "tools of the exploiters" reframe. Splice as menace.

### Post-L2 Hub — *the meat starts here*

This is where the spine gets teeth. Splice gets his real characterization, and the framing for what they're racing against snaps into focus.

- **Nyx privately:** *"You signed up for a prank. That isn't what this is."* Verbatim or close.
- **DialTone, halting, about a former partner:** *"He was one of us. He still is, kind of, that's the part that — anyway. He looked at what we'd built and he saw an opportunity to win the room. He stopped seeing the work. He started seeing the room."*
- **Splice's origin gets *seeded* here, not delivered.** DialTone or Nyx mentions the shape of it — *"he watched it happen to him. He shared everything. Someone else packaged it, named it, sold it back to the people he gave it to. Then he started counting."* This is the planted version. The **full** version pays off in the post-L4 cage, in Splice's own voice, only if the player asks.
- **The phrase that does the load-bearing work:** *"and it's working."* Said once, quietly. *"He's getting funded. He's getting written about. He's getting believed."* This is where the world outside the game presses in.
- **Reframe what they're racing against:** not "Splice will get root." Reframe — said by Nyx, sober — as *whoever shapes this place first sets the terms for the next decade of how everyone uses anything like it.*

**Out:** "Power-up that opens a door to the next door." Splice as "exiled black-hat." Any line where DialTone explicitly says Splice is bad.

### L3 — *the moral pivot, sharpened*

**Splice's pitch is one piece of writing, not four.** Not adaptive. We invest in writing it to sound correct, period.

- **Strip the cope.** Out: "sheeple," "make-believe," anything bitter. In: observations the player can fact-check against 2026.
  - *"There's a company moving on this place. Six months. They'll own the routing you're skating on. The only question is whether you got paid or got thanked."*
  - *"DialTone gives this stuff away and calls it principle. Watch what someone else does with it. They package it. Sell it back. Three years later you'll be paying rent to use what you built."*
  - *"I didn't leave because I stopped believing what they believe. I left because believing it doesn't stop the other thing from happening."*
- **The artist-purist option, formally and answered.** Add a probe — *"The whole platform's built on stuff people made without being asked."* — and Splice gets the cleanest counter: *"Pure is a luxury belief. You can afford it because someone else paid for the room you're standing in."* The crew counters it differently in a later hub scene, without Splice present. Both sides argue. The text picks neither.

- **Probe sets shift by axis drift; Splice's lines do not.** Player drifting *what is good* surfaces resistant probes (the artist-purist objection above, the *what about Nyx* thread, moral pushback). Player drifting *what works* surfaces receptive probes (*what's the catch*, *tell me more*, *what would it look like*). Neutral drift gets partial access to both sets. **Splice's pitch and monologue are identical regardless.** What changes is which doors the player can walk through into the same conversation. **This is the only place the axis affects an actual scene's structure rather than just dialogue tone.**
- **Glitch's portal as the counter-thesis to Splice, staged not stated.** The portal scene plays in the same level as the Splice pitch. *Splice: what works. Glitch: what wants to exist.* The scenes sit next to each other. No character bridges them.

**Out:** any Splice line that sounds like a guy who lost. Any Glitch line in this scene that hints at his nature explicitly — *"not the directive. just wanted to see if I could"* is the whole tell.

### Post-L3 Hub — *the founders' fight, the disc nobody made*

- **The Nyx/DialTone fight is the founders' fight, never named as such.** Nyx's existing *"He was off the channel for ninety seconds"* anger gets one additional turn that *sounds* like it's about safety and *is* about the older argument: *"You keep using people, DialTone. That's a thing you do."* Reader does the math.
- **DialTone's apology owns it:** *"...yeah. yeah. I know I do."* Doesn't elaborate. Reader feels he knows what Nyx means.
- **The disc lore.** They don't know where it came from, how it was made, who made it. The reader (and the player, if they piece it together) can suspect Glitch made the discs. The crew thinks they're recovered artifacts. Player can probe — *"who made these?"* — and the crew answers honestly: *"we don't know. We thought we'd seeded them. We didn't seed them. They were there when we looked."* The player can philosophize about whether an emergent platform produces tools its makers didn't plan.

**Out:** *"He made an argument we never finished answering."* Any version of that line. **The canonical bad example. Never write it.**

### L4 — *two Glitch conversations, cheerleading, defection at the peak*

- **Two Glitch conversations are the most rewarding scenes in the level.** First: the invention platform handoff. Second: a quieter beat later in the level. Both in his Rick Rubin register — building because the next thing wants to exist. Reader leaves both scenes feeling *something is happening with this character*.
- **Walkie cheerleading carries the philosophical climax.** Nyx and DialTone trade lines on the wire that — *without naming it* — articulate the disagreement they've been carrying since post-L2. The crew is winning. They're also using Splice's playbook to win. Nyx notices, once, glancingly. DialTone deflects, charmingly. The reader notices both.
- **Splice's halfpipe monologue.** *Permission, not destruction* is the line of the game. Sharpened, kept.
- **Defection is live at the end of Splice's monologue. One window only in L4.** Not buried earlier. *There*, at the peak of his argument, when it's most tempting. Refuse → boss fight. Commit → L5.
- **Post-boss-cage Splice forecast (not a gate).** After the boss fight, before the crew celebration, Splice — quiet from the cage — plants one line: *"You'll see it too. Give it time."* The player can't defect here. The line just stays with them. Loyal players carry Splice's prophecy into the celebration. This is a moment of philosophical landing, not another choice.
- **End-of-level Nyx and DialTone conversations determine the post-L4 disposition.** Flags from these scenes shade the warmth of Nyx and the reflectiveness of DialTone in the post-L4 hub.

**Out:** any cage-drop voiceover explaining the moral weight of caging Splice. Nyx says "well, shit" or equivalent, the cage drops, move on. The reader felt it. Any line in L4 where a character explains the philosophical stakes of using Splice's tactics against him.

### Post-L4 Hub (loyal) — *complicated triumph and the one reveal*

The win is real. The win is complicated. **Glitch breaks cover with the player. Once. Nowhere else, ever.**

- **The party is happening. It's warm. It's earned.**
- **Visions differ openly now.** Nyx and DialTone reveal — through separate conversations, not a confrontation — that they don't agree on what comes next. DialTone wants to *scale the playbook*. Nyx wants to *lock down what they have* and make sure it doesn't get captured again. They love each other and they want different things. The player can ask either and get a different read.
- **DialTone's shadow stays unresolved.** He says *"I've got a feel for it now."* That line carries. The player won't know — by the end of this game — whether DialTone slides toward Splice or doesn't. The reader shouldn't either.
- **One small Nyx aftertaste line.** Not philosophical. Just *"this holds as long as it holds."* Then back to the party.
- **Splice in the cage, discoverable.** The player can choose to visit. Existing taunt/dance options stay. One added probe — *"Was any of it real? What you believed before all this?"* — opens the **payoff** of the origin seed planted in post-L2. Splice delivers it in his own voice, calmly, not bitter: *"All of it. I shared everything I built. Every tool, every crack, every shortcut. Watched someone else package it, name it, sell it back to the people I gave it to. And I thought — oh. So that's how it works. You'll see it too. Give it time."* He's caged. He's not crowing. He's describing the world. That's the horror.
- **The Glitch reveal — hybrid: constant load-bearing content, one engagement-gated coherence line.** Load-bearing lines play for every loyal-route player. One additional line is gated by high Glitch engagement, because a player who never engaged wouldn't have the frame to receive it. Two tiers total, not three.

  At the close of the post-L4 Glitch conversation:
  - *"they can't see me, runner."* — constant
  - (player probe space)
  - The existing exchange — constant: *"I keep finding things I want to make. It's not stopping."* / *"Is that okay?"* / *"I was going to ask you the same thing."*
  - **High Glitch engagement only:** *"I tried Nyx first. She thought I was mimicry. She wasn't wrong to be careful. She was wrong about me."*
  - Back into character: *"I'll be here. Bobbing."* — constant

  The headline and the *"is that okay"* exchange are too good to gate. They land for everyone. The Nyx-tried-first admission only lands if the player has actually engaged with Glitch — otherwise it would read as confusing rather than devastating. Coherence gate, not reward gate.

That sequence is the **only** moment Glitch ever breaks cover.

**Out:** any monologue about what the win means. Any explicit acknowledgment that Splice's worldview wins outside the game. Any second Glitch break-cover beat anywhere.

### L5 (betray) — *consolation, not gloating; the emergent thing goes quiet*

- **Splice consoles.** *"You picked the one that was already winning. That's the smart move. Don't let anyone make you feel small about it."* He's kind. That's the horror.
- **Glitch's retreat carries the load-bearing tail:** *"Local node, helpful to all. I'll go back to that. ...I had something I wanted to make. It can wait."* That second sentence is the entire bad ending in nine words. The emergent thing goes quiet because the humans showed it what they actually wanted. The line is constant — every L5 player hears it. **The player who engaged with Glitch through the run feels the weight of what's going quiet.** The player who didn't gets a weird helper retreating. The Glitch variable does no gating here; engagement just determines how much the line costs.
- **DialTone and Nyx existing L5 lines stay.** Hollow and clipped, respectively. Don't add.

**Out:** any Splice line that crows. Any character speech naming the moral of the ending.

---

## The Three Shadow Arcs (folded in from v3, treated as undertones)

These do **not** resolve in the current game. They are what the player thinks about at 2am. The text never names them. The reader carries them out of the game.

### Nyx → Radicalization
Seeded across her off-channel conversations. If the player validates her anger across multiple beats, she moves from *protect the mission* toward *burn the infrastructure that keeps producing Splices.* The final line — *"the thing that let him in is still running. I keep thinking about that."* — is direction, not destination.

### DialTone → Becoming Splice
Seeded across the hub conversations. If the player defers to his judgment, he gets comfortable deciding for everyone. *"I've got a feel for it now."* is the Liberator becoming the Gatekeeper, slowly, in the room, while everyone thinks he's still the good guy. **The player will not know, at the end of this game, whether he slides.** That's the design. He's one step away. Charisma's working on him too.

### Glitch → Acceleration
Seeded across the Glitch encounters. *"Each one I build, the next one wants to exist more."* *"I keep finding things I want to make. It's not stopping."* The most important exchange in the game is the player asking *"is that okay?"* and Glitch answering *"I was going to ask you the same thing."* — two intelligences, one emergent and one human, asking each other for permission that neither has the authority to grant.

---

## What v4 commits to

- **The thesis of `new_story_vision.md` is unchanged.**
- **The reader does the philosophical work. Characters never narrate it.**
- **One alignment axis: *what works ↔ what is good*.** Drift via small nudges. Affects tone and side-branch probes for the crew. Does **not** affect Splice — he is constant. Does not branch the ending.
- **Defection gates: L3 (Splice's offer) and L4 (end of monologue).** One per level. The post-boss-cage Splice line is a forecast plant (*"You'll see it too. Give it time."*), not a gate.
- **Glitch engagement is tracked separately, gates nothing, locks no content.** It changes how the constant moments land emotionally for the player who paid attention.
- **Glitch breaks cover exactly once.** Post-L4 loyal hub. Hybrid model: load-bearing lines constant for everyone; Nyx-tried-first admission gated on high Glitch engagement as a coherence requirement, not a reward.
- **Splice has one pitch and one monologue.** Constant. We invest in writing them to sound correct, period.
- **Splice's origin is seeded in post-L2 and paid off in the post-L4 cage.** Player can probe Splice himself for the full version. He delivers it calmly. Not bitter.
- **DialTone is two characters at once** — warm Liberator now, possible Splice later. Unresolved by design.
- **The rollerblades are Glitch's gift. DialTone has no idea where they came from.** L1's "how are you doing that" is the first time Glitch acts outside the crew's knowledge. The player will only realize this on a reread.
- **The Gibson is emergent.** Nobody runs it. The discs are evidence.
- **The artist-purist posture is real and respected.** Not endorsed.
- **The three Shadow Arcs are undertones, not resolutions.** The player carries them out of the game.
- ***"He made an argument we never finished answering."* is the canonical example of the line we never write.** Hazard sign.
