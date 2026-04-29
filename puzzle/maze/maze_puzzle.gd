extends "res://puzzle/puzzle.gd"

## Witness-style maze trace puzzle. Loads a .maze file authored in
## tools/maze_editor/, draws the maze as a translucent overlay, lets the
## player trace from start to end with arrows / WASD / D-pad / left stick.
##
## Movement model (Witness-faithful, adapted for keyboard + analog):
##   - The cursor lives at a continuous position along grid edges. It can
##     rest mid-edge between nodes — no snap-to-node.
##   - Input is sampled every frame. Magnitude controls speed (analog stick
##     proportional; keys are full-strength). Direction projected onto the
##     current edge axis determines along-edge motion. Perpendicular input
##     ignored — you can't turn mid-edge.
##   - At a node, dominant input axis chooses which edge to enter (if any).
##   - Strict no-cross: cannot revisit a node already in the trail, except
##     for the immediate predecessor (backtrack).
##   - Reaching end node → solved. Cancel (Esc / B) → fail.
##   - Optional countdown (time_limit > 0) — drains and fails if hit zero.

const MazeData = preload("res://puzzle/maze/maze_data.gd")

const _COLOR_EDGE: Color = Color(1, 1, 1, 0.8)
const _COLOR_TRAIL: Color = Color(1, 1, 1, 0.95)
const _COLOR_CURSOR: Color = Color(1, 1, 1, 1)
const _COLOR_HALO: Color = Color(1, 1, 1, 0.25)
const _COLOR_START: Color = Color(0.35, 1.0, 0.65, 1.0)
const _COLOR_END: Color = Color(1.0, 0.42, 0.42, 1.0)
const _COLOR_TIMER_FULL: Color = Color(0.35, 1.0, 0.65, 1.0)
const _COLOR_TIMER_LOW: Color = Color(1.0, 0.42, 0.42, 1.0)
const _COLOR_WATER: Color = Color(0.30, 0.62, 1.0, 1.0)   # blue circle
const _COLOR_OIL: Color = Color(0.70, 0.53, 1.0, 1.0)     # purple square
const _COLOR_FAIL: Color = Color(1.0, 0.22, 0.28, 1.0)    # red flash on conflict markers
const _MARKER_RADIUS: float = 9.0
const _MARKER_SQUARE_SIZE: float = 16.0
# Hold the red flash for ~0.4s before the glitch transition kicks in. Long
# enough to read which markers conflicted; short enough to feel snappy.
const _FAIL_HOLD_DURATION: float = 0.4

# Last-N-seconds warning glitch — chromatic-aberration overlay that pulses
# faster + harder as the timer drains. At 0s, it locks at peak and fails.
const _WARNING_THRESHOLD: float = 5.0
const _WARNING_FREQ_START: float = 1.0   # Hz at 5s remaining
const _WARNING_FREQ_END: float = 8.0     # Hz at 0s remaining
const _WARNING_AMP_START: float = 0.15   # alpha amplitude at 5s remaining
const _WARNING_AMP_END: float = 1.0      # alpha amplitude at 0s remaining
const _WARNING_PEAK_HOLD: float = 0.18   # solid-glitch hold before fade-out
const _WARNING_FADE_OUT: float = 0.45

const _GlitchTransition: GDScript = preload("res://menu/transitions/glitch_transition.gd")
const _GLITCH_SHADER_PATH: String = "res://menu/transitions/glitch.gdshader"

const _CELL_SPACING: float = 80.0
const _PADDING: float = 30.0
const _EDGE_THICK: float = 6.0
const _TRAIL_THICK: float = 10.0
const _START_RADIUS: float = 11.0
const _END_RADIUS: float = 11.0
const _CURSOR_CORE_RADIUS: float = 7.0
const _CURSOR_HALO_RADIUS: float = 16.0
const _TIMER_BAR_WIDTH: float = 600.0

# Grid units traveled per second at full input deflection. ~8 cells/s feels
# crisp without robbing precision; analog stick scales it lower for fine
# control. Tunable per puzzle if needed.
const _CURSOR_SPEED_GRID_PER_SEC: float = 7.0
# Stick noise floor — below this magnitude, no input.
const _INPUT_DEADZONE: float = 0.18
# Junction grace: when the cursor crosses a node, perpendicular input above
# this magnitude is treated as a turn intent (preferred over continuing
# straight even when not strictly dominant). Lower = more eager to turn;
# higher = sticks to the entry axis. 0.4 means a stick deflection of >~22°
# off the entry axis counts as a turn.
const _TURN_BIAS_THRESHOLD: float = 0.4
# Sentinel — "no active edge" (cursor sitting on a node). Coordinates are
# negative so they can never collide with a real grid node.
const _NO_NEIGHBOR: Vector2i = Vector2i(-99, -99)

# Set by PuzzleTerminal via Puzzles.start setup_data injection BEFORE _ready.
var maze_path: String = ""

@export_group("Audio")
## Played when the puzzle resolves to success (cursor reaches end, separation
## passes if markers exist). Defaults to the phone-booth checkpoint sound.
@export var success_sound: AudioStream = preload("res://audio/sfx/checkpoint_active.mp3")
## One stream picked at random plays on every fail path (separation,
## timer expire, ui_cancel). Glitch-death stingers fit the chromatic-
## aberration effect; the variety stops repeated fails feeling stale.
@export var fail_sounds: Array[AudioStream] = [
	preload("res://audio/sfx/enemy_deaths/glitch_death_1.wav"),
	preload("res://audio/sfx/enemy_deaths/glitch_death_2.wav"),
	preload("res://audio/sfx/enemy_deaths/glitch_death_3.wav"),
	preload("res://audio/sfx/enemy_deaths/glitch_death_4.wav"),
	preload("res://audio/sfx/enemy_deaths/glitch_death_5.wav"),
]
## Bus name to route SFX to. Project's audio config has an "SFX" bus that
## phone_booth and other interactables use.
@export var sfx_bus: StringName = &"SFX"
## Hack-music loop. Plays on the Music bus while the puzzle is open. The
## world's main music is paused for the duration (and resumes on close from
## the same position). Routed through Music so it gets the same dialogue
## sidechain ducking as the main soundtrack.
@export var hack_music_loop: AudioStream = preload("res://audio/music/maze_hack_loop.mp3")
@export var hack_music_volume_db: float = 8.0
## Ambient drone — loops continuously while the puzzle is open (from _ready
## until queue_free).
@export var ambient_loop: AudioStream = preload("res://audio/sfx/maze_drone.mp3")
## Slide buzz — loops only while the cursor is actively moving. Toggles on
## per-frame when the cursor's visual position changed this frame.
@export var slide_loop: AudioStream = preload("res://audio/sfx/maze_buzz.mp3")
## Volume offsets (dB) for the two loops — tunable so the drone sits
## under combat audio and the buzz reads over it without dominating.
@export var ambient_volume_db: float = -13.0
@export var slide_volume_db: float = -8.0

@export_group("Slide Flair")
## Directory scanned at _ready for footstep streams. Plays a randomized one-
## shot every cadence tick while the cursor is actively moving — gives the
## trace a "running" feel layered over the buzz loop. +5dB over the player's
## normal walk volume per spec; loud and busy on purpose.
@export_dir var footstep_dir: String = "res://audio/sfx/footsteps_keyboard"
## Footstep cadence at full input deflection. Scales with input magnitude
## (half-stick = half-cadence).
@export var footstep_cadence_at_max: float = 12.0
## Probability that any individual footstep tick is skipped — produces the
## "random dropouts" pattern the user asked for.
@export_range(0.0, 1.0) var footstep_dropout_chance: float = 0.3
## Volume in dB. Player walk default is +6dB; this is +5dB over that.
@export var footstep_volume_db: float = 11.0
@export_range(0.0, 0.3) var footstep_pitch_jitter: float = 0.07
## Pool of "coin pickup" streams sprinkled in occasionally while sliding —
## same sounds the world's coin interactable uses. Defaults match
## audio/cues/coin_pickup.tres.
@export var coin_streams: Array[AudioStream] = [
	preload("res://audio/sfx/coin_click_a.mp3"),
	preload("res://audio/sfx/coin_click_b.mp3"),
]
@export var coin_interval_min: float = 0.45
@export var coin_interval_max: float = 1.2
@export var coin_volume_db: float = -3.0
@export_range(0.0, 0.3) var coin_pitch_jitter: float = 0.05

var _data: RefCounted
var _path: Array = []                       # Array[Vector2i] — visited nodes
var _active_neighbor: Vector2i = _NO_NEIGHBOR  # node the cursor is moving toward
var _cursor_t: float = 0.0                  # 0..1 along edge from path[-1] to _active_neighbor
var _time_left: float = 0.0
var _finished_local: bool = false
var _failing: bool = false                  # in fail-flash + glitch sequence
var _conflict_cells: Array = []             # Array[Vector2i] — cells in mixed regions
var _fail_t0: float = 0.0                   # secs (msec/1000) when fail flash started
var _last_device: String = ""

# Last-5s warning glitch state — owns its own canvas so the puzzle can free
# without taking the visual with it.
var _warning_canvas: CanvasLayer = null
var _warning_mat: ShaderMaterial = null
var _warning_phase: float = 0.0

# Looping audio — ambient drone runs the whole puzzle, slide buzz toggles
# with cursor motion. Both are children of the puzzle so they auto-free.
var _ambient_player: AudioStreamPlayer = null
var _slide_player: AudioStreamPlayer = null
var _hack_music_player: AudioStreamPlayer = null
var _ducked_main_music: bool = false

# Slide-flair scratchpad. Footstep pool cached statically so multiple puzzle
# launches in one session don't rescan the 124 wavs.
static var _STATIC_FOOTSTEP_POOL: Array[AudioStream] = []
var _footstep_pool: Array[AudioStream] = []
var _footstep_phase: float = 0.0
var _coin_timer: float = 0.0
var _coin_next_at: float = 0.6

@onready var _maze_root: Control = %MazeRoot
@onready var _timer_bg: ColorRect = %TimerBG
@onready var _timer_bar: ColorRect = %TimerBar
@onready var _instructions: Label = %Instructions


func _ready() -> void:
	super._ready()
	if maze_path == "":
		push_error("MazePuzzle: maze_path is empty — terminal didn't forward it")
		_finish(false)
		return
	_data = MazeData.new()
	_data.load_path(maze_path)
	if not _data.is_valid():
		push_error("MazePuzzle: %s — %s" % [maze_path, _data.error])
		_finish(false)
		return
	print("[maze] loaded %s (%d×%d, time_limit=%.1fs)" % [
		maze_path, _data.cols, _data.rows, _data.time_limit])
	_layout_maze()
	_path = [_data.start]
	_time_left = _data.time_limit
	_setup_timer_ui()
	_setup_loop_audio()
	_resolve_footstep_pool()
	_coin_next_at = randf_range(coin_interval_min, coin_interval_max)
	_maze_root.draw.connect(_draw_maze)
	_refresh_instructions()
	_maze_root.queue_redraw()


# Cached scan of footstep_dir. First puzzle in a session pays the load
# cost; subsequent puzzles reuse the static pool.
func _resolve_footstep_pool() -> void:
	if not _STATIC_FOOTSTEP_POOL.is_empty():
		_footstep_pool = _STATIC_FOOTSTEP_POOL
		return
	var dir: DirAccess = DirAccess.open(footstep_dir)
	if dir == null:
		push_warning("MazePuzzle: footstep_dir not found: " + footstep_dir)
		return
	dir.list_dir_begin()
	var f: String = dir.get_next()
	while f != "":
		if not dir.current_is_dir() and not f.begins_with("."):
			if f.ends_with(".wav") or f.ends_with(".mp3") or f.ends_with(".ogg"):
				var s: Resource = load(footstep_dir + "/" + f)
				if s is AudioStream:
					_footstep_pool.append(s)
		f = dir.get_next()
	_STATIC_FOOTSTEP_POOL = _footstep_pool
	print("[maze] footstep pool resolved: %d streams" % _footstep_pool.size())


# Spawn looping audio players. Loop flag is set on a duplicate of each
# stream so we don't mutate a shared resource (other puzzles / future uses
# of the same MP3 elsewhere stay unaffected).
func _setup_loop_audio() -> void:
	# Duck the world's main music + ambience so the hack music sits alone.
	# Audio.pause_music preserves position; resume_music on close picks it up.
	var audio: Node = get_node_or_null(^"/root/Audio")
	if audio != null and audio.has_method(&"pause_music"):
		audio.call(&"pause_music")
		_ducked_main_music = true
	# Hack music loop on the Music bus.
	if hack_music_loop != null:
		var hm: AudioStream = hack_music_loop.duplicate()
		if "loop" in hm:
			hm.loop = true
		_hack_music_player = AudioStreamPlayer.new()
		_hack_music_player.stream = hm
		_hack_music_player.bus = &"Music"
		_hack_music_player.volume_db = hack_music_volume_db
		add_child(_hack_music_player)
		_hack_music_player.play()
	if ambient_loop != null:
		var stream: AudioStream = ambient_loop.duplicate()
		if "loop" in stream:
			stream.loop = true
		_ambient_player = AudioStreamPlayer.new()
		_ambient_player.stream = stream
		_ambient_player.bus = sfx_bus
		_ambient_player.volume_db = ambient_volume_db
		add_child(_ambient_player)
		_ambient_player.play()
	if slide_loop != null:
		var stream2: AudioStream = slide_loop.duplicate()
		if "loop" in stream2:
			stream2.loop = true
		_slide_player = AudioStreamPlayer.new()
		_slide_player.stream = stream2
		_slide_player.bus = sfx_bus
		_slide_player.volume_db = slide_volume_db
		add_child(_slide_player)
		# Don't play yet — toggled by motion in _process.


func _layout_maze() -> void:
	var w: float = (_data.cols - 1) * _CELL_SPACING + _PADDING * 2.0
	var h: float = (_data.rows - 1) * _CELL_SPACING + _PADDING * 2.0
	_maze_root.custom_minimum_size = Vector2(w, h)
	_maze_root.offset_left = -w * 0.5
	_maze_root.offset_top = -h * 0.5
	_maze_root.offset_right = w * 0.5
	_maze_root.offset_bottom = h * 0.5


func _setup_timer_ui() -> void:
	var has_timer: bool = _data.time_limit > 0.0
	_timer_bg.visible = has_timer
	_timer_bar.visible = has_timer
	if has_timer:
		_update_timer_visual()


func _update_timer_visual() -> void:
	if _data.time_limit <= 0.0:
		return
	var frac: float = clampf(_time_left / _data.time_limit, 0.0, 1.0)
	_timer_bar.offset_right = _timer_bar.offset_left + _TIMER_BAR_WIDTH * frac
	_timer_bar.color = _COLOR_TIMER_LOW.lerp(_COLOR_TIMER_FULL, frac)


func _process(delta: float) -> void:
	if _finished_local or _data == null:
		_set_sliding(false)
		return
	# In the fail-flash window: keep redrawing so the conflict pulse animates.
	# All other input/timer logic is suspended — outcome is locked.
	if _failing:
		_set_sliding(false)
		_maze_root.queue_redraw()
		return
	# Timer
	if _data.time_limit > 0.0:
		_time_left = maxf(_time_left - delta, 0.0)
		_update_timer_visual()
		# Warning glitch ramps in across the final _WARNING_THRESHOLD seconds.
		if _time_left > 0.0 and _time_left <= _WARNING_THRESHOLD:
			_update_warning_glitch(delta)
		if _time_left <= 0.0:
			_set_sliding(false)
			_begin_timer_fail_sequence()
			return
	# Refresh device-aware instructions on any device switch.
	_refresh_instructions()
	# Continuous input → continuous cursor motion.
	var input_v: Vector2 = _read_input()
	var magnitude: float = input_v.length()
	if magnitude < _INPUT_DEADZONE:
		_set_sliding(false)
		return
	var input_unit: Vector2 = input_v / magnitude
	# Magnitude scales speed: half-stick = half-speed.
	var distance: float = magnitude * _CURSOR_SPEED_GRID_PER_SEC * delta
	# Snapshot pre-step world pos so we can detect *actual* motion (input
	# may be held but cursor blocked against a wall — no buzz then).
	var prev_pos: Vector2 = _cursor_world_pos()
	_step_cursor(input_unit, distance)
	var moved: bool = prev_pos.distance_squared_to(_cursor_world_pos()) > 0.001
	_set_sliding(moved)
	if moved:
		_drive_slide_flair(delta, magnitude)
	else:
		# Reset accumulators so resuming motion doesn't immediately fire.
		_footstep_phase = 0.0
		_coin_timer = 0.0
	_maze_root.queue_redraw()


# Footstep flurry + coin sparkle — fires only when cursor is actually
# moving (called per frame from _process when `moved` is true).
func _drive_slide_flair(delta: float, intensity: float) -> void:
	# Footstep cadence scales with input intensity. `while` instead of `if`
	# so very high cadence at low FPS still fires multiple steps per frame.
	if not _footstep_pool.is_empty():
		_footstep_phase += footstep_cadence_at_max * intensity * delta
		while _footstep_phase >= 1.0:
			_footstep_phase -= 1.0
			if randf() >= footstep_dropout_chance:
				var s: AudioStream = _footstep_pool[randi() % _footstep_pool.size()]
				var pitch: float = 1.0 + randf_range(-footstep_pitch_jitter, footstep_pitch_jitter)
				_play_oneshot(s, footstep_volume_db, pitch)
	# Coin sparkle — independent of cadence, randomized interval.
	if not coin_streams.is_empty():
		_coin_timer += delta
		if _coin_timer >= _coin_next_at:
			_coin_timer = 0.0
			_coin_next_at = randf_range(coin_interval_min, coin_interval_max)
			var s2: AudioStream = coin_streams[randi() % coin_streams.size()]
			var pitch2: float = 1.0 + randf_range(-coin_pitch_jitter, coin_pitch_jitter)
			_play_oneshot(s2, coin_volume_db, pitch2)


# Toggle the slide-buzz loop. Idempotent — safe to call every frame.
func _set_sliding(on: bool) -> void:
	if _slide_player == null:
		return
	if on and not _slide_player.playing:
		_slide_player.play()
	elif not on and _slide_player.playing:
		_slide_player.stop()


# Combined input vector: ui_* (arrows + D-pad + left-stick axis) AND
# move_* (WASD + left-stick axis). Same axes overlap on the gamepad — clamp
# the sum to keep magnitude in [-1, 1]. y is screen-down-positive.
func _read_input() -> Vector2:
	var x: float = clampf(
			Input.get_axis(&"ui_left", &"ui_right")
			+ Input.get_axis(&"move_left", &"move_right"),
			-1.0, 1.0)
	var y: float = clampf(
			Input.get_axis(&"ui_up", &"ui_down")
			+ Input.get_axis(&"move_up", &"move_down"),
			-1.0, 1.0)
	return Vector2(x, y)


# Move the cursor `distance` grid units (cells) in `input_unit`'s direction.
# Loops to spend remaining distance across multiple edges in one frame, so a
# held direction flows continuously through straight runs of nodes without
# pausing on each.
func _step_cursor(input_unit: Vector2, distance: float) -> void:
	var iter: int = 0
	while distance > 1.0e-4 and iter < 8:
		iter += 1
		if _is_at_tip():
			if not _try_enter_edge_from_tip(input_unit):
				return
		var here: Vector2i = _path[_path.size() - 1]
		var edge_vec: Vector2 = Vector2(_active_neighbor - here)  # cardinal unit
		var aligned: float = input_unit.dot(edge_vec)
		if aligned > 1.0e-4:
			# Forward toward _active_neighbor.
			var step: float = aligned * distance
			var capacity: float = 1.0 - _cursor_t
			if step <= capacity + 1.0e-6:
				_cursor_t = clampf(_cursor_t + step, 0.0, 1.0)
				return
			_cursor_t = 1.0
			distance -= capacity / aligned
			_commit_active_edge()
		elif aligned < -1.0e-4:
			# Reverse toward path[-1].
			var step: float = -aligned * distance
			var capacity: float = _cursor_t
			if step <= capacity + 1.0e-6:
				_cursor_t = clampf(_cursor_t - step, 0.0, 1.0)
				return
			_cursor_t = 0.0
			distance -= capacity / -aligned
			_active_neighbor = _NO_NEIGHBOR
		else:
			# Perpendicular input — can't turn mid-edge.
			return


func _is_at_tip() -> bool:
	return _active_neighbor == _NO_NEIGHBOR


# Pick the dominant axis of input_unit and try to enter the edge from
# path[-1] in that direction. Honors no-cross and allows the predecessor
# (backtrack). Returns true if an edge was entered (and _active_neighbor /
# _cursor_t are now set), false if blocked.
func _try_enter_edge_from_tip(input_unit: Vector2) -> bool:
	var dir: Vector2i
	if absf(input_unit.x) >= absf(input_unit.y):
		dir = Vector2i(int(signf(input_unit.x)), 0)
	else:
		dir = Vector2i(0, int(signf(input_unit.y)))
	if dir == Vector2i.ZERO:
		return false
	var here: Vector2i = _path[_path.size() - 1]
	var candidate: Vector2i = here + dir
	if not _data.has_edge(here, candidate):
		return false
	# Backtrack permitted — the predecessor is the only revisitable node.
	if _path.size() >= 2 and _path[_path.size() - 2] == candidate:
		_active_neighbor = candidate
		_cursor_t = 0.0
		return true
	# Strict no-cross: any other revisit is blocked.
	if candidate in _path:
		return false
	_active_neighbor = candidate
	_cursor_t = 0.0
	return true


# Cursor reached _active_neighbor. Forward push appends; backtrack pops.
func _commit_active_edge() -> void:
	var nb: Vector2i = _active_neighbor
	if _path.size() >= 2 and _path[_path.size() - 2] == nb:
		_path.pop_back()  # backtrack: the old tip drops
	else:
		_path.append(nb)
	_active_neighbor = _NO_NEIGHBOR
	_cursor_t = 0.0
	if _path[_path.size() - 1] == _data.end:
		_resolve_end()


# Reaching end node: separation rule decides success vs. failure. With no
# markers on the grid, separation is vacuously satisfied (always pass). With
# markers, the trail must divide cells into regions where each region holds
# only one marker type — Witness rule.
func _resolve_end() -> void:
	if not _data.has_markers():
		_play_oneshot(success_sound)
		_finish(true)
		return
	var conflicts: Array = _find_conflict_cells()
	if conflicts.is_empty():
		_play_oneshot(success_sound)
		_finish(true)
		return
	print("[maze] reached end but separation failed — %d conflict cells" % conflicts.size())
	_play_fail_sound()
	_conflict_cells = conflicts
	_begin_fail_sequence()


# Flood-fill cells, treating trail edges as walls between adjacent cells.
# Returns the cells in any region that contains both water and oil markers.
# Empty array iff every region is monochromatic (separation passes).
func _find_conflict_cells() -> Array:
	var trail_edges: Dictionary = {}
	for i in range(_path.size() - 1):
		trail_edges[_edge_key(_path[i], _path[i + 1])] = true
	var visited: Dictionary = {}
	var dirs: Array = [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]
	var conflicts: Array = []
	for cy in _data.rows - 1:
		for cx in _data.cols - 1:
			var seed: Vector2i = Vector2i(cx, cy)
			if visited.has(seed):
				continue
			# Flood the region, recording every cell it touches.
			var region: Array = []
			var water: int = 0
			var oil: int = 0
			var queue: Array = [seed]
			visited[seed] = true
			while not queue.is_empty():
				var cur: Vector2i = queue.pop_front()
				region.append(cur)
				match _data.cell_marker(cur.x, cur.y):
					_data.MARKER_WATER: water += 1
					_data.MARKER_OIL: oil += 1
				for d in dirs:
					var nb: Vector2i = cur + d
					if nb.x < 0 or nb.y < 0 or nb.x >= _data.cols - 1 or nb.y >= _data.rows - 1:
						continue
					if visited.has(nb):
						continue
					if _cells_blocked_by_trail(cur, nb, trail_edges):
						continue
					visited[nb] = true
					queue.append(nb)
			if water > 0 and oil > 0:
				conflicts.append_array(region)
	return conflicts


# Fail-flash + glitch transition then close. Tree stays paused throughout —
# GlitchTransition's tweens bind to its own PROCESS_MODE_ALWAYS canvas so they
# tick under pause. play_in is fire-and-forget; the canvas owns its lifecycle
# and self-frees once the fade completes (after the puzzle has queue_freed).
func _begin_fail_sequence() -> void:
	_failing = true
	_fail_t0 = Time.get_ticks_msec() / 1000.0
	# If the timer's warning glitch is up, dismiss it — GlitchTransition
	# below spawns its own canvas and we don't want two stacking.
	_cleanup_warning_glitch()
	_maze_root.queue_redraw()
	# Hold the red flash so the player reads which markers conflicted.
	await get_tree().create_timer(_FAIL_HOLD_DURATION, true).timeout
	if _finished_local: return
	# Glitch out → puzzle close → glitch in (over the now-visible world).
	var transition: Object = _GlitchTransition.new()
	await transition.play_out(get_tree())
	if _finished_local: return
	transition.play_in(get_tree())  # async; canvas survives our queue_free
	_finish(false)


# True iff the trail traces along the grid edge that separates cells `a`
# and `b` (assumed 4-adjacent). The 4 cases map cell-adjacency directions to
# the corresponding node-pair edge on the grid.
func _cells_blocked_by_trail(a: Vector2i, b: Vector2i, trail_edges: Dictionary) -> bool:
	var d: Vector2i = b - a
	if d == Vector2i(1, 0):
		return trail_edges.has(_edge_key(Vector2i(a.x + 1, a.y), Vector2i(a.x + 1, a.y + 1)))
	if d == Vector2i(-1, 0):
		return trail_edges.has(_edge_key(Vector2i(a.x, a.y), Vector2i(a.x, a.y + 1)))
	if d == Vector2i(0, 1):
		return trail_edges.has(_edge_key(Vector2i(a.x, a.y + 1), Vector2i(a.x + 1, a.y + 1)))
	if d == Vector2i(0, -1):
		return trail_edges.has(_edge_key(Vector2i(a.x, a.y), Vector2i(a.x + 1, a.y)))
	return false


static func _edge_key(a: Vector2i, b: Vector2i) -> String:
	# Canonical: smaller-endpoint first so (a,b) and (b,a) hash the same.
	if a.x < b.x or (a.x == b.x and a.y < b.y):
		return "%d,%d-%d,%d" % [a.x, a.y, b.x, b.y]
	return "%d,%d-%d,%d" % [b.x, b.y, a.x, a.y]


func _input(event: InputEvent) -> void:
	if _finished_local or _failing: return
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		_play_fail_sound()
		_finish(false)


func _finish(success: bool) -> void:
	if _finished_local: return
	_finished_local = true
	_cleanup_warning_glitch()
	_restore_main_music()
	_complete(success)


# Stop the hack-music loop and tell the Audio autoload to un-pause the
# world music + ambience. Idempotent — safe even if setup never ran.
func _restore_main_music() -> void:
	if _hack_music_player != null and is_instance_valid(_hack_music_player):
		_hack_music_player.stop()
	_hack_music_player = null
	if _ducked_main_music:
		var audio: Node = get_node_or_null(^"/root/Audio")
		if audio != null and audio.has_method(&"resume_music"):
			audio.call(&"resume_music")
		_ducked_main_music = false


# --- Warning glitch (last 5s of countdown) ------------------------------

# Spawn the chromatic-aberration overlay. Same shader used by
# GlitchTransition; we drive its alpha manually with a sine pulse.
# Layer 2000 puts it above any other UI (menu = 1000, puzzle = 10).
func _spawn_warning_glitch() -> void:
	if _warning_canvas != null:
		return
	_warning_canvas = CanvasLayer.new()
	_warning_canvas.layer = 2000
	_warning_canvas.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(_warning_canvas)
	var rect := ColorRect.new()
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	# IGNORE — the player is still tracing under the glitch; don't eat input.
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_warning_mat = ShaderMaterial.new()
	_warning_mat.shader = load(_GLITCH_SHADER_PATH)
	_warning_mat.set_shader_parameter(&"alpha", 0.0)
	rect.material = _warning_mat
	_warning_canvas.add_child(rect)


# Per-frame: integrate phase with the current frequency (so freq can vary
# without phase discontinuities), then drive alpha = amp * (0.5 + 0.5 * sin
# phase). Fraction = 0 at 5s remaining → 1 at 0s remaining.
func _update_warning_glitch(delta: float) -> void:
	if _warning_canvas == null:
		_spawn_warning_glitch()
	var fraction: float = 1.0 - clampf(_time_left / _WARNING_THRESHOLD, 0.0, 1.0)
	var freq_hz: float = lerpf(_WARNING_FREQ_START, _WARNING_FREQ_END, fraction)
	var amp: float = lerpf(_WARNING_AMP_START, _WARNING_AMP_END, fraction)
	_warning_phase += freq_hz * delta * TAU
	var alpha: float = amp * (0.5 + 0.5 * sin(_warning_phase))
	_warning_mat.set_shader_parameter(&"alpha", alpha)


func _cleanup_warning_glitch() -> void:
	if _warning_canvas != null and is_instance_valid(_warning_canvas):
		_warning_canvas.queue_free()
	_warning_canvas = null
	_warning_mat = null


# Timer hit zero. Lock the warning glitch at peak briefly, then fade out as
# the puzzle queue_frees. The warning canvas is reused as the close visual —
# no separate GlitchTransition needed (we're already glitching).
func _begin_timer_fail_sequence() -> void:
	if _failing: return
	_failing = true
	_play_fail_sound()
	if _warning_canvas == null:
		# Defensive: timer expired without entering the warning window
		# (e.g., time_limit < _WARNING_THRESHOLD). Spawn now so the close
		# still glitches.
		_spawn_warning_glitch()
	_warning_mat.set_shader_parameter(&"alpha", 1.0)
	await get_tree().create_timer(_WARNING_PEAK_HOLD, true).timeout
	if _finished_local: return
	# Fade out — tween bound to the canvas (PROCESS_MODE_ALWAYS) so it
	# survives the puzzle's queue_free.
	var canvas := _warning_canvas
	var mat := _warning_mat
	var tw := canvas.create_tween()
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_method(func(a: float) -> void:
		if mat != null:
			mat.set_shader_parameter(&"alpha", a)
	, 1.0, 0.0, _WARNING_FADE_OUT)
	tw.finished.connect(func() -> void:
		if is_instance_valid(canvas):
			canvas.queue_free()
	)
	# We've handed canvas/mat ownership to the tween; clear our refs so
	# _cleanup_warning_glitch in _finish doesn't double-free.
	_warning_canvas = null
	_warning_mat = null
	_finish(false)


# --- Device-aware instructions ------------------------------------------

# Pulls active device from the player brain (same path Glyphs uses). Falls
# back to keyboard if no player is in scene (puzzle launched in isolation).
func _detect_device() -> String:
	for player: Node in get_tree().get_nodes_in_group(&"player"):
		for child: Node in player.get_children():
			if "last_device" in child:
				return child.last_device
	return "keyboard"


func _refresh_instructions() -> void:
	if _instructions == null:
		return
	var device: String = _detect_device()
	if device == _last_device:
		return
	_last_device = device
	if device == "gamepad":
		_instructions.text = "left stick to trace · Circle to abort"
	else:
		_instructions.text = "WASD or arrows to trace · Esc to abort"


# --- Audio --------------------------------------------------------------

# Spawns a temp AudioStreamPlayer parented to the root so playback survives
# the puzzle's queue_free. PROCESS_MODE_ALWAYS so the sound starts during the
# paused puzzle frame; auto-frees once finished. volume_db / pitch_scale
# default to neutral — slide-flair callers override for jitter and gain.
func _play_oneshot(stream: AudioStream, volume_db: float = 0.0, pitch_scale: float = 1.0) -> void:
	if stream == null:
		return
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = sfx_bus
	p.volume_db = volume_db
	p.pitch_scale = pitch_scale
	p.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(p)
	p.finished.connect(p.queue_free, CONNECT_ONE_SHOT)
	p.play()


func _play_fail_sound() -> void:
	if fail_sounds.is_empty():
		return
	_play_oneshot(fail_sounds[randi() % fail_sounds.size()])


# --- Drawing -------------------------------------------------------------

func _draw_maze() -> void:
	_draw_base_maze()
	_draw_markers()
	_draw_trail()
	# Start = filled green disc; End = red ring.
	_maze_root.draw_circle(_node_pos(_data.start), _START_RADIUS, _COLOR_START)
	_maze_root.draw_arc(_node_pos(_data.end), _END_RADIUS, 0.0, TAU, 32,
			_COLOR_END, 3.0, true)
	# Cursor — soft halo + bright core.
	var cursor_pos: Vector2 = _cursor_world_pos()
	_maze_root.draw_circle(cursor_pos, _CURSOR_HALO_RADIUS, _COLOR_HALO)
	_maze_root.draw_circle(cursor_pos, _CURSOR_CORE_RADIUS, _COLOR_CURSOR)


# Witness-style cell markers — water = blue circle, oil = purple square.
# Drawn between base maze and trail so the trail visually slices over them.
# During the fail flash, conflict-region markers pulse toward red.
func _draw_markers() -> void:
	if not _data.has_markers():
		return
	var pulse: float = 0.0
	if _failing:
		var elapsed: float = Time.get_ticks_msec() / 1000.0 - _fail_t0
		pulse = 0.5 + 0.5 * sin(elapsed * 22.0)
	for cy in _data.rows - 1:
		for cx in _data.cols - 1:
			var marker: int = _data.cell_marker(cx, cy)
			if marker == _data.MARKER_NONE:
				continue
			var center: Vector2 = _cell_center_pos(cx, cy)
			var base_color: Color = _COLOR_WATER if marker == _data.MARKER_WATER else _COLOR_OIL
			var color: Color = base_color
			if _failing and Vector2i(cx, cy) in _conflict_cells:
				color = base_color.lerp(_COLOR_FAIL, 0.55 + 0.45 * pulse)
			if marker == _data.MARKER_WATER:
				_maze_root.draw_circle(center, _MARKER_RADIUS, color)
			else:
				var half: float = _MARKER_SQUARE_SIZE * 0.5
				_maze_root.draw_rect(
						Rect2(center - Vector2(half, half),
								Vector2(_MARKER_SQUARE_SIZE, _MARKER_SQUARE_SIZE)),
						color)


func _cell_center_pos(cx: int, cy: int) -> Vector2:
	return Vector2(_PADDING + (cx + 0.5) * _CELL_SPACING,
			_PADDING + (cy + 0.5) * _CELL_SPACING)


func _cursor_world_pos() -> Vector2:
	if _is_at_tip():
		return _node_pos(_path[_path.size() - 1])
	return _node_pos(_path[_path.size() - 1]).lerp(
			_node_pos(_active_neighbor), _cursor_t)


# Base maze: every open edge from h/v matrices, antialiased, with corner
# discs at every junction node so 90° turns and T-junctions don't show
# a pointy seam.
func _draw_base_maze() -> void:
	for y in _data.rows:
		for x in _data.cols - 1:
			if bool(_data.h[y][x]):
				_maze_root.draw_line(_node_pos(Vector2i(x, y)),
						_node_pos(Vector2i(x + 1, y)),
						_COLOR_EDGE, _EDGE_THICK, true)
	for y in _data.rows - 1:
		for x in _data.cols:
			if bool(_data.v[y][x]):
				_maze_root.draw_line(_node_pos(Vector2i(x, y)),
						_node_pos(Vector2i(x, y + 1)),
						_COLOR_EDGE, _EDGE_THICK, true)
	var node_radius: float = _EDGE_THICK * 0.5
	for y in _data.rows:
		for x in _data.cols:
			var node: Vector2i = Vector2i(x, y)
			if not _data.neighbors(node).is_empty():
				_maze_root.draw_circle(_node_pos(node), node_radius, _COLOR_EDGE)


# Trail: visited path drawn as solid segments, with the active edge rendered
# partial during in-progress motion. Anchor of the partial depends on push
# (path[-1] → cursor) vs. backtrack (path[-2] → cursor).
func _draw_trail() -> void:
	var sz: int = _path.size()
	if sz == 0:
		return
	var trail_node_radius: float = _TRAIL_THICK * 0.5
	var is_backtrack: bool = false
	if not _is_at_tip():
		is_backtrack = sz >= 2 and _path[sz - 2] == _active_neighbor
	var solid_count: int = sz - 1
	if is_backtrack:
		solid_count = sz - 2
	for i in range(solid_count):
		_maze_root.draw_line(_node_pos(_path[i]), _node_pos(_path[i + 1]),
				_COLOR_TRAIL, _TRAIL_THICK, true)
	if not _is_at_tip():
		var anchor_idx: int = (sz - 2) if is_backtrack else (sz - 1)
		_maze_root.draw_line(_node_pos(_path[anchor_idx]), _cursor_world_pos(),
				_COLOR_TRAIL, _TRAIL_THICK, true)
	# Corner discs at every visited node — but during backtrack, the soon-
	# to-be-popped tip's disc is omitted so it doesn't strand visually.
	for i in range(sz):
		if is_backtrack and i == sz - 1:
			continue
		_maze_root.draw_circle(_node_pos(_path[i]), trail_node_radius, _COLOR_TRAIL)


func _node_pos(node: Vector2i) -> Vector2:
	return Vector2(_PADDING + node.x * _CELL_SPACING, _PADDING + node.y * _CELL_SPACING)
