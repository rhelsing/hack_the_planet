extends SceneTree

## Diagnostic dump for a 3D model's mesh + material setup. Walks every
## MeshInstance3D under the loaded scene and prints surface count, material
## class, albedo color, bound texture path, and any surface override. Use
## when a new GLB lands and you need to know "is this one shared material
## or six separate ones, is the albedo texture bound, what's the resource
## name." See docs/character_setup.md §5.2 for usage.
##
## Edit TARGET, then run:
##   /Applications/Godot.app/Contents/MacOS/Godot --headless \
##       --script res://tests/probe_model_materials.gd --quit
const TARGET := "res://player/skins/kaykit/model/kaykit_general.glb"


func _init() -> void:
	var scene: PackedScene = load(TARGET)
	if scene == null:
		printerr("could not load: ", TARGET)
		quit(1)
		return
	var root: Node = scene.instantiate()
	print("=== Material probe: %s ===" % TARGET)
	_walk(root, 0)
	quit(0)


func _walk(n: Node, depth: int) -> void:
	var pad := "  ".repeat(depth)
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var mesh := mi.mesh
		print("%sMeshInstance3D: %s  surfaces=%d" % [pad, mi.name, mesh.get_surface_count() if mesh else -1])
		if mesh:
			for i in mesh.get_surface_count():
				var mat := mesh.surface_get_material(i)
				var override := mi.get_surface_override_material(i)
				var mname := mat.resource_name if mat else "<none>"
				var oname := override.resource_name if override else "<none>"
				var mclass := mat.get_class() if mat else "-"
				print("%s  surf[%d] mat=%s (%s)  override=%s" % [pad, i, mname, mclass, oname])
				if mat is BaseMaterial3D:
					var bm := mat as BaseMaterial3D
					var tex := bm.albedo_texture
					var tname := tex.resource_path if tex else "<none>"
					print("%s    albedo=%s  texture=%s" % [pad, bm.albedo_color, tname])
	else:
		print("%s%s [%s]" % [pad, n.name, n.get_class()])
	for c in n.get_children():
		_walk(c, depth + 1)
