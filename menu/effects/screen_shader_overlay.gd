class_name ScreenShaderOverlay
extends CanvasLayer

## Full-screen screen-space shader overlay. Builds a fullscreen ColorRect with
## a ShaderMaterial that samples the framebuffer below (hint_screen_texture),
## so any canvas_item post-effect becomes one line to wire up:
##
##   var fx := ScreenShaderOverlay.spawn(host_node, SHADER_PATH, layer)
##   fx.set_param(&"opacity", 0.6)
##   fx.queue_free()   # remove
##
## Renders while the tree is paused (menus, puzzles) and ignores input so it
## never eats clicks from what's underneath. Used by the CRT filter setting
## and the hacking double-vision effect. The existing GlitchTransition and the
## maze warning glitch predate this helper and keep their own hand-rolled
## overlays — new effects should use this.

var mat: ShaderMaterial


## Create the overlay, wire the shader, and add it under `parent`. Returns the
## overlay so the caller can drive uniforms or free it.
static func spawn(parent: Node, shader_path: String, canvas_layer: int) -> ScreenShaderOverlay:
	var fx := ScreenShaderOverlay.new()
	fx.layer = canvas_layer
	fx.process_mode = Node.PROCESS_MODE_ALWAYS
	fx.mat = ShaderMaterial.new()
	fx.mat.shader = load(shader_path)
	var rect := ColorRect.new()
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.material = fx.mat
	fx.add_child(rect)
	parent.add_child(fx)
	return fx


func set_param(param: StringName, value) -> void:
	if mat != null:
		mat.set_shader_parameter(param, value)
