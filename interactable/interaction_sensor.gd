class_name InteractionSensor
extends Node

## Lives as a child of PlayerBrain — NOT on PlayerBody, so enemy pawns (same
## body class, different brain) carry zero interaction cost. See sync_up.md
## 2026-04-22 and docs/interactables.md §4 for the rationale.
##
## Hybrid scoring: proximity + body-forward + optional camera-forward. The
## body is injected by PlayerBrain at _ready, so this node has no hard
## assumption about tree shape above it.

## Detection radius, meters. 2.5 is tuned for third-person platformer — big
## enough to catch point-blank clutter without swallowing background props.
@export var detection_range: float = 2.5

@export_group("Scoring Weights")
## Weights are additive; only relative ordering matters. Tune against a scene
## with 3+ close interactables.
@export_range(0.0, 1.0) var weight_proximity: float = 0.4
@export_range(0.0, 1.0) var weight_body_facing: float = 0.4
## Camera-crosshair bias. Small in third-person — the spring-arm camera whips
## around and shouldn't dominate focus selection. 0 disables the camera sample.
@export_range(0.0, 1.0) var weight_camera_facing: float = 0.2

## Candidates whose (body.forward · dir) is below this floor are rejected
## outright (prevents "interact with the thing behind me"). -0.5 allows
## slight over-shoulder.
@export var facing_cutoff: float = -0.5

## Local signal — 1-to-1 wire between sensor and PromptUI. Not on Events bus.
## PromptUI discovers the sensor via the "interaction_sensor" group.
signal focus_changed(focused: Interactable)

## Emitted when try_activate hits a locked interactable. PromptUI listens and
## shows a transient toast with the reason (e.g., "Locked — needs Red Key").
signal locked(it: Interactable, reason: String)

## Currently focused interactable. null when nothing is in range + valid.
var focused: Interactable = null

## Injected by PlayerBrain at _ready. CharacterBody3D — the pawn this sensor
## is reporting for.
var body: CharacterBody3D = null

## True when nothing external (a brain) is dispatching input. In standalone
## mode the sensor handles `interact` directly via _unhandled_input.
## Auto-set to true when _auto_wire_body runs — i.e., no brain injected body.
var _standalone: bool = false

@onready var _area: Area3D = $SensorArea


func _ready() -> void:
	add_to_group(&"interaction_sensor")
	# Auto-wire fallback: if PlayerBrain hasn't injected `body` by now (e.g.,
	# in a demo scene without Patch A), find the first "player"-group node.
	# Production path: PlayerBrain sets body BEFORE we reach _ready. This
	# fallback only runs when body is still null.
	if body == null:
		_standalone = true
		call_deferred(&"_auto_wire_body")


func _auto_wire_body() -> void:
	if body != null: return
	var found := get_tree().get_first_node_in_group(&"player")
	if found is CharacterBody3D:
		body = found


## Standalone-mode input handling. Production path: PlayerBrain dispatches
## via try_activate — this method is a no-op when not standalone.
func _unhandled_input(event: InputEvent) -> void:
	if not _standalone: return
	if event.is_action_pressed(&"interact"):
		try_activate(body)


func _physics_process(_delta: float) -> void:
	if body == null: return
	# Sync the Area3D sphere to the body's world position each frame. Required
	# because the sensor's Node parent (PlayerBrain in production, this script
	# in standalone) isn't a Node3D, so transform inheritance skips to the
	# nearest Node3D ancestor (scene root / origin). Per docs §16 Risk #1.
	_area.global_position = body.global_position

	var best: Interactable = null
	var best_score: float = -INF
	for a: Node in _area.get_overlapping_areas():
		var it := a as Interactable
		if it == null: continue
		# Note: we DO NOT gate on can_interact here — we want the prompt to
		# still surface locked interactables so the player knows what's there
		# and why it's gated. try_activate emits `locked` with the reason.
		var score := _score(it)
		if score > best_score:
			best_score = score
			best = it
	_set_focused(best)


## Called by PlayerBrain.try_activate on intent.interact_pressed.
func try_activate(actor: Node3D) -> void:
	if focused == null: return
	# Gate: no interactions while attacking. Prevents door-open mid-swing.
	# has_method safety net — drops after character_dev Patch A ships
	# PlayerBody.is_attacking() as a stable accessor.
	if body != null and body.has_method(&"is_attacking") and body.is_attacking():
		return
	if not focused.can_interact(actor):
		# Emit with the interactable's own reason string so subclasses can
		# customize (e.g., "Needs power" for a broken terminal).
		var reason := focused.describe_lock()
		if reason.is_empty(): reason = "Locked"
		locked.emit(focused, reason)
		return
	focused.interact(actor)


## Scoring math lives in interactable/scoring.gd (pure, zero-dep, unit-tested).

func _score(it: Interactable) -> float:
	# Godot's -Z is "forward" for Node3Ds (same as camera default).
	var body_forward := -body.global_basis.z
	var cam_forward := Vector3.ZERO
	if weight_camera_facing > 0.0:
		var cam := body.get_viewport().get_camera_3d()
		if cam != null:
			cam_forward = -cam.global_basis.z

	var effective_range: float = it.detection_range_override if it.detection_range_override > 0.0 else detection_range
	return InteractionScoring.score(
		body.global_position,
		body_forward,
		it.global_position,
		it.focus_priority,
		effective_range,
		weight_proximity,
		weight_body_facing,
		weight_camera_facing,
		cam_forward,
		facing_cutoff,
	)


func _set_focused(next: Interactable) -> void:
	if next == focused: return
	if focused != null:
		focused.set_highlighted(false)
	focused = next
	if focused != null:
		focused.set_highlighted(true)
	focus_changed.emit(focused)
	# Walk-in auto-trigger: if the newly focused interactable opts in, fire
	# try_activate immediately. One-shot per focus cycle — drops when the
	# player walks out of range and re-arms on re-entry.
	if focused != null and focused.auto_interact_on_focus and body != null:
		try_activate(body)
