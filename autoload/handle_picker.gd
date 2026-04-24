extends Node

## Persistent hacker-handle picker. DialTone's intro dialogue calls roll_options
## to pick 4 random handles from the pool, shows them as choice labels, then
## pick() locks in the player's handle (stored in GameState.flags.player_handle)
## and chooses one of 20 DialTone-reaction lines to splice into his reply.

const POOL: Array[String] = [
	"Cipher", "Vex", "Siren", "Static", "Glyph", "Lux", "Echo", "Raze",
	"Pixel", "Shiv", "Omen", "Ghost", "Kairos", "Vapor", "Crash", "Prism",
	"Tempest", "Noise", "Neon", "Byte",
]

## DialTone's reaction after you pick. Cycled randomly. 20 variants keeps the
## re-roll moment from feeling canned on replays.
const REACTIONS: Array[String] = [
	"well, that's not what I'd have picked, but okay",
	"huh — solid choice, actually",
	"that's what we're going with? alright",
	"okay, bold. I respect it",
	"not a bad read on yourself",
	"you sure? ... okay",
	"eh, it'll do",
	"that's... that's a name. sure",
	"I was gonna pitch you something snappier, but go off",
	"noted. in the log forever now",
	"fine — but if anyone asks, I pitched you something cooler",
	"really? that one?",
	"punchy. I like it",
	"bit of a mouthful, but fine",
	"half the grid's got that handle, but okay",
	"that's what my uncle calls his firewall, but sure",
	"classy. retro. works",
	"you know what, yeah. that tracks",
	"could be worse. alright",
	"lock it in, then. no takebacks",
]

var _options: Array[int] = []
var _reaction_idx: int = -1


## Pick `count` distinct indices from POOL for this session's choices.
func roll_options(count: int = 4) -> void:
	var indices: Array = range(POOL.size())
	indices.shuffle()
	_options = []
	for i in min(count, indices.size()):
		_options.append(int(indices[i]))


## Label for the i-th rolled option. Used from dialogue via {{ }} interpolation.
func option(i: int) -> String:
	if i < 0 or i >= _options.size():
		return ""
	return POOL[_options[i]]


## Lock in the i-th option as the player's handle. Irreversible — persisted via
## GameState so later dialogues + saves see the same name. Also picks a reaction.
func pick(i: int) -> void:
	if i < 0 or i >= _options.size():
		return
	GameState.set_flag(&"player_handle", POOL[_options[i]])
	_reaction_idx = randi() % REACTIONS.size()


## The player's locked-in handle (empty before first pick).
func chosen_name() -> String:
	return String(GameState.get_flag(&"player_handle", ""))


## Reaction line chosen at pick-time. Stable for this session until re-picked.
func reaction() -> String:
	if _reaction_idx < 0:
		_reaction_idx = randi() % REACTIONS.size()
	return REACTIONS[_reaction_idx]
