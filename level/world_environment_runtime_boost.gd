extends WorldEnvironment

## Re-enables heavy post-FX at runtime that are saved disabled in the scene
## so the editor preview stays cheap on weak GPUs. Tuning values (intensities,
## radii, fog densities, etc.) live on the saved Environment resource and are
## untouched here — only the *_enabled bools flip.
##
## The duplicate is critical: without it we'd mutate the canonical sub-resource
## that the .tscn references, and the scene file would re-save with the
## boosted bools — defeating the editor-lite point.

func _ready() -> void:
	if environment == null:
		return
	var live: Environment = environment.duplicate() as Environment
	# live.ssr_enabled = true
	live.ssao_enabled = true
	# live.ssil_enabled = true
	live.glow_enabled = true
	live.fog_enabled = true
	environment = live
