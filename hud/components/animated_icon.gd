extends TextureRect
class_name AnimatedIcon

## Cycles through a folder of numbered PNGs as a HUD-friendly animation.
## Lives on a TextureRect so it composes naturally with Control layouts
## (unlike AnimatedSprite2D which is Node2D and doesn't play nice in HUDs).
##
## Use case: walkie talkie pulse on the counters HUD — preserves the
## source GIF's transparency (Theora can't), avoids the deprecated
## AnimatedTexture, and is cheap (16×16 frames, ~26KB total).
##
## Behavior:
##   - At _ready, scans `frames_dir` for PNG/JPG files (sorted), preloads each.
##   - `playing = true` advances at `frames_per_second`; loops by default.
##   - `playing = false` freezes on the current frame.
##   - `reset_on_stop = true` snaps back to frame 0 on stop.

@export_dir var frames_dir: String = ""
@export var frames_per_second: float = 20.0
@export var loop: bool = true
@export var reset_on_stop: bool = true
## Set true to start playing immediately on _ready.
@export var autoplay: bool = false
## Optional skin tint applied via `modulate` on top of any parent tint.
## (Parent VBox/HBox modulate still applies; this is per-icon.)
@export var tint: Color = Color.WHITE

var _frames: Array[Texture2D] = []
var _index: int = 0
var _accum: float = 0.0
var playing: bool = false:
	set(value):
		if value == playing:
			return
		playing = value
		if not value and reset_on_stop:
			_index = 0
			_accum = 0.0
			if not _frames.is_empty():
				texture = _frames[0]


func _ready() -> void:
	modulate = tint
	_load_frames()
	if not _frames.is_empty():
		texture = _frames[0]
	if autoplay:
		playing = true


func _load_frames() -> void:
	if frames_dir.is_empty():
		push_warning("AnimatedIcon: frames_dir is empty — %s" % get_path())
		return
	var dir := DirAccess.open(frames_dir)
	if dir == null:
		push_warning("AnimatedIcon: frames_dir not found: %s" % frames_dir)
		return
	var entries: Array[String] = []
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if not dir.current_is_dir():
			var lower := name.to_lower()
			if lower.ends_with(".png") or lower.ends_with(".jpg") or lower.ends_with(".jpeg"):
				entries.append(name)
		name = dir.get_next()
	entries.sort()  # numeric-leading filenames sort correctly as strings
	for entry: String in entries:
		var tex: Texture2D = load(frames_dir.path_join(entry)) as Texture2D
		if tex != null:
			_frames.append(tex)


func _process(delta: float) -> void:
	if not playing or _frames.size() <= 1:
		return
	_accum += delta
	var step: float = 1.0 / maxf(frames_per_second, 1.0)
	while _accum >= step:
		_accum -= step
		_index += 1
		if _index >= _frames.size():
			if loop:
				_index = 0
			else:
				_index = _frames.size() - 1
				playing = false
				return
	texture = _frames[_index]
