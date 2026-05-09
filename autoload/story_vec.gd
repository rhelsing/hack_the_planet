extends Node

## Generic N-dimensional story-state vector.
##
## Choices made during dialogue can nudge any number of named axes by
## arbitrary deltas — `do StoryVec.nudge(&"ai_tech", 1)`. Other content
## (later dialogue, scene gates, level beats) can read raw axis values
## (`StoryVec.value(&"ai_tech") > 3`) or test against author-defined
## named regions (`StoryVec.in_region(&"pro_ai_pro_people")`).
##
## Engine is generic — knows nothing about specific axis names or region
## semantics. All those live in the per-game StoryVecConfig resource at
## `res://dialogue/story_vec_config.tres`. A second project drops the same
## autoload in with its own config.
##
## Persistence piggybacks on DialogueState's per-slot sidecar (Phase D.3)
## so vector state survives load_from_slot the same way visited / seen do.
##
## ── API surface (writers' perspective) ─────────────────────────────────
##   do StoryVec.nudge(&"axis_name", delta)        # accumulates, clamped
##   [if StoryVec.value(&"axis_name") > threshold /]
##   [if StoryVec.in_region(&"region_name") /]
##
## ── API surface (engine / runtime) ─────────────────────────────────────
##   StoryVec.value(axis) -> float
##   StoryVec.region() -> StringName  (first matching region or &"")
##   StoryVec.set_value(axis, v)      (tests + fresh-state helpers)
##   StoryVec.to_dict() / from_dict() (sidecar persistence)
##   signal vec_changed(axis, new_value)


const CONFIG_PATH: String = "res://dialogue/story_vec_config.tres"
const StoryVecConfigScript = preload("res://dialogue/story_vec_config.gd")

## Emitted on every nudge / set_value, AFTER the value is clamped and
## stored. Listeners (debug HUD, analytics) can read the new value via
## value(axis) or use the signal arg directly.
signal vec_changed(axis: StringName, new_value: float)


## { axis_name: float }. Keys are exactly the axes declared in the config;
## any nudge to an unknown axis is a no-op + push_warning.
var _values: Dictionary = {}

var _config: Resource = null  # typed Resource — actual type is StoryVecConfigScript


func _ready() -> void:
	_load_config()


func _load_config() -> void:
	if not ResourceLoader.exists(CONFIG_PATH):
		push_warning("StoryVec: no config at %s — vector will be inert" % CONFIG_PATH)
		_config = StoryVecConfigScript.new()
		return
	var res: Resource = load(CONFIG_PATH)
	if res is StoryVecConfigScript:
		_config = res
	else:
		push_error("StoryVec: %s loaded but is not a StoryVecConfig" % CONFIG_PATH)
		_config = StoryVecConfigScript.new()
	# Seed every declared axis to zero so reads before any nudge work.
	for axis: StringName in _config.axes:
		if not _values.has(axis):
			_values[axis] = 0.0


# ---- Mutation ----------------------------------------------------------

func nudge(axis: StringName, delta: float) -> void:
	if _config == null or not (axis in _config.axes):
		push_warning("StoryVec.nudge: unknown axis %s — config declares %s" %
				[axis, _config.axes if _config != null else "<no config>"])
		return
	var old: float = _values.get(axis, 0.0)
	var new_v: float = clamp(old + delta, _config.bounds_min, _config.bounds_max)
	_values[axis] = new_v
	vec_changed.emit(axis, new_v)


## Absolute set — mainly for tests + fresh-state helpers. Production code
## should call nudge() so deltas accumulate naturally.
func set_value(axis: StringName, v: float) -> void:
	if _config == null or not (axis in _config.axes):
		push_warning("StoryVec.set_value: unknown axis %s" % axis)
		return
	var clamped: float = clamp(v, _config.bounds_min, _config.bounds_max)
	_values[axis] = clamped
	vec_changed.emit(axis, clamped)


# ---- Read --------------------------------------------------------------

func value(axis: StringName) -> float:
	return float(_values.get(axis, 0.0))


## True if the vector is currently inside the named region's bounds. Region
## semantics are author-defined in the config (see StoryVecConfig docstring).
## Returns false for unknown regions.
func in_region(region_name: StringName) -> bool:
	if _config == null: return false
	for r: Dictionary in _config.regions:
		if r.get("name", &"") != region_name: continue
		var thresholds: Dictionary = r.get("thresholds", {})
		for axis_v in thresholds.keys():
			var axis: StringName = axis_v
			var range_pair: Array = thresholds[axis]
			if range_pair.size() < 2: continue
			var v: float = value(axis)
			if v < float(range_pair[0]) or v > float(range_pair[1]):
				return false
		return true
	return false  # unknown region


## Returns the StringName of the first region the vector is currently
## inside (config order). Returns &"" if no region matches — e.g. the
## vector is at the origin and no neutral region is defined.
func region() -> StringName:
	if _config == null: return &""
	for r: Dictionary in _config.regions:
		var name: StringName = r.get("name", &"")
		if in_region(name):
			return name
	return &""


# ---- Persistence (Phase D.3 wires this into DialogueState) -------------

func to_dict() -> Dictionary:
	return _values.duplicate()


func from_dict(d: Dictionary) -> void:
	_values.clear()
	for k_v in d.keys():
		var k: StringName = k_v
		_values[k] = float(d[k])
	# Re-seed any declared axis missing from the loaded dict so reads always
	# return a number.
	if _config != null:
		for axis: StringName in _config.axes:
			if not _values.has(axis):
				_values[axis] = 0.0


func reset() -> void:
	_values.clear()
	if _config != null:
		for axis: StringName in _config.axes:
			_values[axis] = 0.0
