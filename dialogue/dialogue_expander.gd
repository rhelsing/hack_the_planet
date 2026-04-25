class_name DialogueExpander
extends RefCounted

## Expands a `.dialogue` line text into its full set of TTS-cacheable
## variants. Recursively walks four variation primitives:
##
##   1. Self-closing conditionals  [if X /]      → stripped (no text impact)
##   2. Block conditionals         [if X]a[else]b[/if]  → 2 branches (or 1 if no else)
##   3. Alternations               [[a|b|c]]     → N siblings
##   4. Mustache calls             {{Foo.bar()}} → table lookup; unknown → drop line
##
## Returns concrete strings with no remaining variation primitives. A line
## with no primitives returns [text]. A line whose only primitive is an
## unknown mustache call returns [] so the prime tool drops it (lazy fill
## at runtime). Cartesian explosion is bounded — if the expansion ever
## exceeds VARIANT_CAP, expand() returns [] with a warning so we don't
## bombard ElevenLabs.
##
## NOTE: this is the BUILD-TIME expander used by tools/prime_all_dialogue.
## At runtime, DialogueManager handles mustache and conditionals natively;
## we just want to enumerate every variant the player might ever hear.

const VARIANT_CAP: int = 256


## Expand `text` into all variants. Filters empty strings post-recursion.
static func expand(text: String) -> Array[String]:
	var raw: Array[String] = _expand(text)
	var out: Array[String] = []
	for v: String in raw:
		var s := v.strip_edges()
		if s.is_empty():
			continue
		out.append(s)
	if out.size() > VARIANT_CAP:
		push_warning("[DialogueExpander] %d variants exceeds cap %d for: %s"
			% [out.size(), VARIANT_CAP, text.substr(0, 80)])
		return []
	return out


# Recursive core. Finds the first variation primitive and expands it,
# splicing each alternative back into the source text and recursing.
static func _expand(text: String) -> Array[String]:
	# Self-closing conditionals — strip and recurse.
	var sc_re := RegEx.create_from_string("\\[if[^\\]]*?/\\s*\\]")
	var sc := sc_re.search(text)
	if sc != null:
		var stripped := text.substr(0, sc.get_start()) + text.substr(sc.get_end())
		return _expand(stripped)

	# Block conditionals  [if X] a [else] b [/if]
	var block_re := RegEx.create_from_string("\\[if[^\\]]*\\](.*?)(?:\\[else\\](.*?))?\\[/if\\]")
	var bm := block_re.search(text)
	if bm != null:
		var branches: Array[String] = [bm.get_string(1)]
		# get_string(2) returns "" both when [else] is absent and when present-but-empty;
		# treat both the same — single branch with the IF body.
		var else_body: String = bm.get_string(2)
		if else_body != "":
			branches.append(else_body)
		var out: Array[String] = []
		for b: String in branches:
			var replaced := text.substr(0, bm.get_start()) + b + text.substr(bm.get_end())
			out.append_array(_expand(replaced))
		return out

	# Alternations  [[a|b|c]]
	var alt_re := RegEx.create_from_string("\\[\\[([^\\]]+)\\]\\]")
	var am := alt_re.search(text)
	if am != null:
		var options := am.get_string(1).split("|")
		var out: Array[String] = []
		for opt: String in options:
			var replaced := text.substr(0, am.get_start()) + opt + text.substr(am.get_end())
			out.append_array(_expand(replaced))
		return out

	# Mustache  {{Foo.bar()}}
	var must_re := RegEx.create_from_string("\\{\\{([^}]+)\\}\\}")
	var mm := must_re.search(text)
	if mm != null:
		var expr := mm.get_string(1).strip_edges()
		var alts: Array = _mustache_alternatives(expr)
		if alts.is_empty():
			# Unknown call — drop this whole branch. Lazy fill at runtime.
			return []
		var out: Array[String] = []
		for alt in alts:
			var replaced := text.substr(0, mm.get_start()) + str(alt) + text.substr(mm.get_end())
			out.append_array(_expand(replaced))
		return out

	return [text]


# Static enumeration of every supported mustache call → its possible outputs.
# Add new shapes here as authors introduce them. Unknown returns [] so the
# caller can decide to drop or warn.
static func _mustache_alternatives(expr: String) -> Array:
	if expr == "HandlePicker.chosen_name()":
		return HandlePicker.POOL.duplicate()
	if expr == "HandlePicker.reaction()":
		var arr: Array = []
		for v in HandlePicker.REACTIONS.values():
			arr.append(v)
		return arr
	var opt_re := RegEx.create_from_string("^HandlePicker\\.option\\((\\d+)\\)$")
	var om := opt_re.search(expr)
	if om != null:
		var idx := int(om.get_string(1))
		if idx < 0 or idx >= HandlePicker.POOL.size():
			return []
		return [HandlePicker.POOL[idx]]
	var glyph_re := RegEx.create_from_string("^Glyphs\\.for_action\\([\"']([^\"']+)[\"']\\)$")
	var gm := glyph_re.search(expr)
	if gm != null:
		var action := gm.get_string(1)
		var alts: Array = []
		for device: String in Glyphs.DEVICES:
			alts.append(Glyphs.format_for("{" + action + "}", device))
		return alts
	push_warning("[DialogueExpander] unknown mustache call: %s" % expr)
	return []
