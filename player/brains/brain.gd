class_name Brain
extends Node

## Base class for anything that drives a PlayerBody. Subclasses override tick()
## to fill an Intent from whatever source they represent: human input, AI
## decisions, scripted sequences, or network-replicated remote input.
##
## The body calls tick(self, delta) once per physics frame and consumes the
## returned Intent. Order is deterministic: body pulls, brain pushes — no
## _physics_process ordering dance.

func tick(_body: Node3D, _delta: float) -> Intent:
	return Intent.new()
