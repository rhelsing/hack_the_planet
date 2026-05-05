# Ambition — Hack The Planet

The story-design north star. A 90s cyberspace hacking game (Godot) built around John Truby's **four-corner opposition**, delivered with Nolan / *Dark Knight*-style moral seriousness. The technology at the center of the conflict is a stand-in for AI but is **never named** as such.

---

## The four corners

Two axes. Four philosophical positions on transformative tech.

- **X-axis:** open ↔ closed
- **Y-axis:** for humans ↔ for power

|              | **For humans** | **For power**  |
|--------------|----------------|----------------|
| **Open**     | Liberator      | Mercenary      |
| **Closed**   | Purist         | Gatekeeper     |

Every corner speaks **partial truth**. There is no pure-evil corner. The dramatic engine is that each position has a real argument — and the player's chosen corner is steelmanned against by the other three.

### Persuasion geometry

- **Adjacent corners (shared axis) deliver the most persuasive challenges**, not diagonals. A Liberator is most threatened by the Purist (shares "for humans," disagrees on open/closed) and the Mercenary (shares "open," disagrees on who it's for). The Gatekeeper across the diagonal is the easiest to dismiss.
- **Steelman comes from all three opposing corners** — so the player gets pushed on both their axis-mate critiques and the diagonal "you're more like me than you'll admit" gut-punch.

---

## Character → corner mapping (rotating)

Four characters rotate around the corners based on **player alignment via x,y nudges in dialogue**. The corner a character occupies in any given scene is a function of where the player has been pushing the wire.

- **Glitch** — AI helper. Begins as a tool, develops preferences. His arc is also the **Accelerationist subplot** — emergence as its own corner-adjacent question.
- **Nyx** — love interest. The relational stakes. Her corner shifts based on whether the player gives her room to be herself or pulls her toward their alignment.
- **DialTone** — charismatic ally. The recruiter. His corner reveals are the most performance-loaded — what he says vs. where he actually stands.
- **Splice** — ex-villain. **Currently fuses Mercenary + Gatekeeper** (will be split / clarified as the system matures). The story's most-developed antagonist, but his corner is unstable in the dynamic system.

---

## Core thesis

> **Does choosing matter when you can't prove your values aren't arbitrary?**

Every corner has a partial-truth argument that the others can't fully refute. The player chooses anyway. The game asks whether that choice — made under epistemic uncertainty — is meaningful.

The answer is embedded in the medium itself: **the game is a complex system built by a coder using AI tools.** That fact is the proof-of-concept that the **Liberator** position (open + for humans) has merit. The thesis is argued by being demonstrated, not stated.

### AI on display, in the game

The metaphor goes one layer deeper: **actual AI algorithms run inside the game, visible to the player.** Not as backend magic — as content.

- The player may **talk to an LLM** as a diegetic system (a node, a shard, a hostile/friendly process on the wire).
- The player may **learn how AI works by playing** — algorithms surface as mechanics. A search tree is a maze. A classifier is a sentinel. A token stream is a wire you ride. Embeddings are a literal space you traverse.
- Glitch's emergence arc is the most personal version: the player watches an AI develop preferences in real time, because *the AI actually does* under the hood.

The four-corner moral question (open / closed, for humans / for power) is no longer abstract — the player is making it about a real artifact they're holding in their hands.

---

## Where we are vs. where we're going

- **Existing static dialogue** (`dialogue/*.dialogue`, indexed in `story/dialogue_brief.md`) serves as **one path** through the four-corner space. It's the canonical reading — playable, shippable, coherent.
- **Target:** adaptive **Disco Elysium-density** dialogue. The four-corner system runs underneath every scene; characters reposition in real time based on the running x,y; lines are picked from a much larger pool than any single playthrough surfaces.
- The static script is the skeleton. The adaptive system is the muscle that wraps it.

---

## Tooling ambition: web-based level designer

Level authoring today happens in the Godot editor — slow for the kind of iteration the game wants. A lightweight **HTML/CSS level designer**, in the same spirit as the puzzle authoring we already do, would compress the loop dramatically.

- **Whole-level scope.** Not a single puzzle widget — the entire playspace. Block out geometry, place pickups, set checkpoints, drop enemy spawns.
- **3D grid as the substrate.** Platformers work natively on a 3D grid; that's the right authoring abstraction. Rough cell placement first; **fine-tuning (offsets, rotations, exact heights) comes later** in Godot. The web tool's job is fast layout, not pixel-precision.
- **Smart object placement.** Snap-to-grid, semantic objects (rail / wall / checkpoint / enemy) rather than raw meshes, sane defaults so a level can be roughed in without thinking about transforms.
- **Output:** a serializable format (JSON / tres) that Godot ingests and instantiates into a real level scene. The web tool authors intent; Godot resolves it into nodes.
- **Why HTML/CSS:** same reasoning as the puzzle authoring — cheap to build, instant feedback, no editor reload cycle, and the abstractions can stay close to the design language ("place a rail here," not "instance a CSGBox3D").

### Wiring as a first-class authoring primitive

Smart objects aren't islands — they talk to each other. **Wiring should be as easy as connecting nodes in the 3D grid with blocks.** Think of it as node-graph visual scripting, but spatial: the wires live in the same grid the objects do, run between them as visible cells, and read at a glance.

- **Connect smart objects directly.** Pressure plate → door. Switch → bridge. Hack terminal → sentinel disable. The connection is a placed thing, not a script reference buried in an inspector.
- **Easy modifiers on the wire.** Delay, invert, latch, count-N, AND/OR junctions — drop them in like inline blocks. Common puzzle logic without writing code.
- **Same abstraction for level and puzzle.** A puzzle is just a denser cluster of wired smart objects. Designing at this level means **stopping thinking about "is this a level thing or a puzzle thing"** and starting to think about *what the player encounters and what it does when touched.* The grid+wiring substrate covers both.
- **Higher level of abstraction.** The unit of design is "a beat the player has with the world," not "a CharacterBody3D with a script." Authoring at the beat layer lets the designer compose 10× more before reaching for code.

This is part of the **full game buildout** — the bet is that the right authoring tool turns level design from a bottleneck into a flow state, and at single-developer pace that compounds.

---

## Tonal register

Nolan's *Dark Knight* — moral seriousness, philosophical villains played straight, no winking. Combined with the existing **earnest pulp** of the cyberpunk frame (see `story/character_brief.md`): the genre is played for what it is, not parodied. The villain monologues. The hero hesitates. We let both land.
