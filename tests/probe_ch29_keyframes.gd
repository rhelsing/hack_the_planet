extends SceneTree

# Sample rotation values from a few key bones in Running, across multiple
# keyframes. If values are flat (no variation), the action's FCurves never
# bound to the character's bones during the Blender merge.

const GLB_PATH := "res://player/skins/ch29_nonpbr/model/ch29_nonpbr.glb"


func _init() -> void:
	var packed: PackedScene = load(GLB_PATH)
	var inst: Node = packed.instantiate()
	var ap := _find_ap(inst)
	for clip_name in ["Running", "Walking", "Punching"]:
		print("\n--- ", clip_name, " ---")
		var anim := ap.get_animation(clip_name)
		# Find rotation tracks for the leg bones; print first vs last keyframe
		# value. If they're identical, this clip is dead.
		for i in anim.get_track_count():
			var path := str(anim.track_get_path(i))
			if not (path.contains("LeftUpLeg") or path.contains("Hips")):
				continue
			if anim.track_get_type(i) != Animation.TYPE_ROTATION_3D:
				continue
			var keys := anim.track_get_key_count(i)
			if keys < 2:
				print("  %s: only %d keys — skipping" % [path, keys])
				continue
			var k0: Quaternion = anim.track_get_key_value(i, 0)
			var k_mid: Quaternion = anim.track_get_key_value(i, keys / 2)
			var k_last: Quaternion = anim.track_get_key_value(i, keys - 1)
			var dist := k0.angle_to(k_last)
			print("  %s  keys=%d  first=%.3f,%.3f,%.3f,%.3f  last=%.3f,%.3f,%.3f,%.3f  angle_diff=%.4f" % [
				path, keys, k0.x, k0.y, k0.z, k0.w, k_last.x, k_last.y, k_last.z, k_last.w, dist
			])
	inst.queue_free()
	quit(0)


func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer: return n
	for c: Node in n.get_children():
		var r := _find_ap(c)
		if r != null: return r
	return null
