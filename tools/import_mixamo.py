"""Merge a directory of Mixamo character FBXs with a directory of animation
FBXs into one GLB per character (each containing every animation as a clip).

Usage (run via Blender's Python, not stand-alone):

    /Applications/Blender.app/Contents/MacOS/Blender --background --python \\
        tools/import_mixamo.py -- \\
        ~/Downloads/characters \\
        ~/Downloads/characters/anims \\
        ~/Downloads/characters/output

The three positional args after `--` are: characters_dir, anims_dir, output_dir.
All three are interpreted as filesystem paths (the leading `~` is expanded).

Assumptions:
- All FBX files share Mixamo-style bone naming (`mixamorig:Hips`,
  `mixamorig:LeftFoot`, ...) so animations from one rig drive any other.
- Each animation FBX contains exactly one Action (Mixamo's default download).
- Character FBX may or may not ship its own animation; any that exists is
  preserved and named after the FBX's stem.
- "In place" Mixamo download is what you want for a character controller.
  This script can't fix root-motion clips.

Each animation lands as its own NLA track on the character armature, which
the glTF exporter writes out as separate clips (one per track) when
`export_animation_mode='NLA_TRACKS'`.
"""

import bpy
import os
import sys
import glob
import pathlib


# ---------- arg parsing ----------

def parse_args() -> tuple[str, str, str]:
    """Pulls the three required path args from after `--` on the Blender CLI."""
    if "--" not in sys.argv:
        raise SystemExit("Pass paths after `--`: characters_dir anims_dir output_dir")
    tail = sys.argv[sys.argv.index("--") + 1:]
    if len(tail) < 3:
        raise SystemExit("Need three args: characters_dir anims_dir output_dir")
    return (
        os.path.expanduser(tail[0]),
        os.path.expanduser(tail[1]),
        os.path.expanduser(tail[2]),
    )


# ---------- scene helpers ----------

def reset_scene() -> None:
    """Wipe everything so each character runs in a clean Blender state."""
    bpy.ops.wm.read_factory_settings(use_empty=True)


def import_fbx(filepath: str) -> None:
    bpy.ops.import_scene.fbx(
        filepath=filepath,
        automatic_bone_orientation=True,
        use_custom_normals=True,  # preserve any authored split normals from the FBX
    )


def shade_smooth_all_meshes() -> None:
    """Mark every polygon of every mesh in the scene as smooth-shaded. Mixamo
    FBXs encode smoothing as smoothing groups; if any polygon ended up flat
    after FBX→Blender import, the GLB will look faceted. This is cheap and
    idempotent — already-smooth polys stay smooth."""
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH":
            continue
        for poly in obj.data.polygons:
            poly.use_smooth = True


def zero_metallic_on_all_materials() -> None:
    """Mixamo's Boy01-class FBXs export with the facial materials (eyes,
    brows, mouth) flagged as fully metallic — a misinterpretation of the
    FBX's specular workflow during Blender import. With no IBL configured,
    a metallic-1 surface renders pure black in Godot. Walks every mesh's
    materials and zeroes the metallic on the Principled BSDF node so the
    glTF exporter writes pbrMetallicRoughness.metallicFactor = 0."""
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH":
            continue
        for slot in obj.material_slots:
            mat = slot.material
            if mat is None or not mat.use_nodes:
                continue
            for node in mat.node_tree.nodes:
                if node.type == "BSDF_PRINCIPLED":
                    if "Metallic" in node.inputs:
                        node.inputs["Metallic"].default_value = 0.0


def get_armature_hips_prefix(arm: bpy.types.Object) -> str | None:
    """Return the prefix of the armature's `Hips` bone — e.g. `mixamorig:`,
    `mixamorig_`, `mixamorig1_`, or `""` for an unprefixed rig. Mixamo
    namespaces vary between character variants; we detect per-rig instead
    of hard-coding."""
    if arm is None or arm.data is None:
        return None
    for b in arm.data.bones:
        if b.name.endswith("Hips"):
            return b.name[: -len("Hips")]
    return None


def get_action_hips_prefix(action: bpy.types.Action) -> str | None:
    """Same idea, but read off the action's FCurves. Looks for the first
    FCurve whose data_path mentions a Hips bone and pulls the prefix out."""
    if action is None:
        return None
    needle = '"'
    for _cb, fc in _iter_action_fcurves(action):
        path = fc.data_path
        # Format: pose.bones["<prefix>Hips"].rotation_quaternion (etc.)
        anchor = path.find('pose.bones["')
        if anchor == -1:
            continue
        start = anchor + len('pose.bones["')
        end = path.find('"]', start)
        if end == -1:
            continue
        bone_name = path[start:end]
        if bone_name.endswith("Hips"):
            return bone_name[: -len("Hips")]
    return None


def remap_action_bone_prefix(action: bpy.types.Action, from_prefix: str, to_prefix: str) -> int:
    """Rewrite every FCurve's `data_path` so `pose.bones["<from_prefix>X"]`
    becomes `pose.bones["<to_prefix>X"]`. Used when an imported anim's bone
    namespace doesn't match the character's armature (e.g. action uses
    `mixamorig:Hips` but character has `mixamorig1:Hips`); without this the
    NLA strip plays but drives no bones, and the exported GLB ends up with
    keyframe-less T-pose clips.

    In Blender 4.4+ Animation 2.0, FCurves live inside channelbags whose
    slot is bound to a specific identifier. Patching `data_path` in place
    isn't enough — we have to remove the FCurve and recreate it under the
    new path so the channelbag's internal binding refreshes. Returns the
    number of FCurves rewritten."""
    if from_prefix == to_prefix:
        return 0
    target = f'pose.bones["{from_prefix}'
    replacement = f'pose.bones["{to_prefix}'
    count = 0

    # Walk per-channelbag so we can recreate fcurves on the same container.
    for layer in action.layers:
        for strip in layer.strips:
            for cb in getattr(strip, "channelbags", []):
                # Collect specs for fcurves that need rewriting.
                to_recreate: list[dict] = []
                fcs_to_remove: list = []
                for fc in cb.fcurves:
                    if target not in fc.data_path:
                        continue
                    new_path = fc.data_path.replace(target, replacement)
                    # Snapshot keyframes (frame, value, interpolation) so we
                    # can rebuild after deletion.
                    keys = []
                    for kp in fc.keyframe_points:
                        keys.append((kp.co.x, kp.co.y, kp.interpolation))
                    to_recreate.append({
                        "data_path": new_path,
                        "array_index": fc.array_index,
                        "keys": keys,
                    })
                    fcs_to_remove.append(fc)
                for fc in fcs_to_remove:
                    cb.fcurves.remove(fc)
                for spec in to_recreate:
                    new_fc = cb.fcurves.new(spec["data_path"], index=spec["array_index"])
                    new_fc.keyframe_points.add(len(spec["keys"]))
                    for i, (frame, value, interp) in enumerate(spec["keys"]):
                        kp = new_fc.keyframe_points[i]
                        kp.co = (frame, value)
                        kp.interpolation = interp
                    new_fc.update()
                    count += 1
    return count


def _iter_action_fcurves(action: bpy.types.Action):
    """Yield (channelbag, fcurve) pairs walking Blender 4.4+ Animation 2.0
    layered structure. The legacy `action.fcurves` flat list was removed in
    Blender 5.0 in favor of layers→strips→channelbags→fcurves. We yield the
    channelbag too because removal happens through the channelbag's
    fcurves collection, not the action's."""
    for layer in action.layers:
        for strip in layer.strips:
            for cb in getattr(strip, "channelbags", []):
                for fc in cb.fcurves:
                    yield cb, fc


def strip_hip_translation(action: bpy.types.Action, threshold: float = 30.0) -> int:
    """Selectively remove FCurves that animate the Hips bone's location or
    the Armature object's root `location`. Strips a track only if its value
    range exceeds `threshold` Blender units (≈ cm in Mixamo's authoring units).

    Why selective: Mixamo's "In Place" toggle only zeros XZ motion. Natural
    Y-bob (breathing/walk weight-shift) lives in a small range — typically
    1–5 cm. Forward locomotion that gets axis-mangled into Y during the
    FBX→glTF conversion shows up as 100+ cm range. The cyclic leg/foot
    rotations are authored assuming the natural bob is present — strip the
    bob and the leg rotations over-correct → feet visually slide on idle.

    A 30-cm threshold cleanly separates the two: natural bob is always
    under ~5 cm, axis-mangled locomotion is always over ~50 cm. Returns
    count of FCurves removed; left-alone curves keep driving the bone."""
    if action is None:
        return 0
    to_remove: list[tuple] = []
    for cb, fcurve in _iter_action_fcurves(action):
        path: str = fcurve.data_path
        # Three forms to match:
        #   1. pose.bones["mixamorig:Hips"].location   (FBX colon-form)
        #   2. pose.bones["mixamorig_Hips"].location   (underscore variant)
        #   3. location                                 (root object translation)
        is_hip_loc = "Hips" in path and path.endswith(".location")
        is_root_loc = path == "location"
        if not (is_hip_loc or is_root_loc):
            continue
        if not fcurve.keyframe_points:
            continue
        # kp.co = (frame, value); the .y on co is the value channel.
        values = [kp.co.y for kp in fcurve.keyframe_points]
        val_range = max(values) - min(values)
        if val_range > threshold:
            to_remove.append((cb, fcurve))
    for cb, fc in to_remove:
        cb.fcurves.remove(fc)
    return len(to_remove)


def find_armatures() -> list[bpy.types.Object]:
    return [o for o in bpy.context.scene.objects if o.type == "ARMATURE"]


def push_action_to_nla(arm: bpy.types.Object, action: bpy.types.Action, clip_name: str) -> None:
    """Put `action` on its own NLA track named `clip_name`. The glTF exporter
    will then emit it as a separate animation in the GLB."""
    if arm.animation_data is None:
        arm.animation_data_create()
    track = arm.animation_data.nla_tracks.new()
    track.name = clip_name
    start = int(action.frame_range[0]) if action.frame_range else 1
    strip = track.strips.new(clip_name, start, action)
    strip.name = clip_name


def remove_objects_recursive(objs: list[bpy.types.Object]) -> None:
    """Delete a list of objects and their children. We use this to scrub the
    duplicate armature/mesh that each anim FBX import drags in."""
    seen: set[str] = set()

    def _collect(o: bpy.types.Object) -> None:
        if o.name in seen:
            return
        seen.add(o.name)
        for child in list(o.children):
            _collect(child)

    for o in objs:
        if o is not None:
            _collect(o)
    for name in seen:
        obj = bpy.data.objects.get(name)
        if obj is not None:
            bpy.data.objects.remove(obj, do_unlink=True)


def clip_name_from_path(p: str) -> str:
    """`Aj@Walking.fbx` → `Walking`; `Idle.fbx` → `Idle`. Mixamo per-character
    packs prefix the character name with `@`."""
    stem = pathlib.Path(p).stem
    if "@" in stem:
        stem = stem.split("@", 1)[1]
    return stem


# ---------- main per-character pipeline ----------

def process_character(char_path: str, anim_paths: list[str], out_path: str) -> None:
    print(f"\n=== {pathlib.Path(char_path).name} ===")
    reset_scene()

    # Import the character. Capture object names before/after so we can
    # identify the imported armature unambiguously even if Blender renames.
    before_objs = {o.name for o in bpy.context.scene.objects}
    import_fbx(char_path)
    char_arms = [o for o in find_armatures() if o.name not in before_objs]
    if not char_arms:
        print("  [skip] no armature found in character FBX")
        return
    char_arm = char_arms[0]
    char_prefix = get_armature_hips_prefix(char_arm) or ""
    print(f"  character armature: {char_arm.name}  bones={len(char_arm.data.bones)}  hips_prefix={char_prefix!r}")

    # If the character FBX shipped its own animation, name+keep it.
    if char_arm.animation_data and char_arm.animation_data.action:
        existing = char_arm.animation_data.action
        clip_name = pathlib.Path(char_path).stem
        existing.name = clip_name
        strip_hip_translation(existing)
        push_action_to_nla(char_arm, existing, clip_name)
        char_arm.animation_data.action = None
        print(f"  preserved character's own action -> {clip_name}")

    # For each animation FBX: import, transfer the action onto the
    # character's armature as an NLA track, then strip the duplicate rig.
    for anim_path in anim_paths:
        clip_name = clip_name_from_path(anim_path)

        before_objs_inner = {o.name for o in bpy.context.scene.objects}
        before_actions = {a.name for a in bpy.data.actions}

        try:
            import_fbx(anim_path)
        except Exception as e:
            print(f"  [skip anim] import failed for {anim_path}: {e}")
            continue

        new_objs = [o for o in bpy.context.scene.objects if o.name not in before_objs_inner]
        new_actions = [a for a in bpy.data.actions if a.name not in before_actions]

        if not new_actions:
            print(f"  [skip anim] no Action in {pathlib.Path(anim_path).name}")
            remove_objects_recursive(new_objs)
            continue

        action = new_actions[0]
        # Disambiguate if name collides with one already on the character.
        final_name = clip_name
        n = 2
        while final_name in {t.name for t in (char_arm.animation_data.nla_tracks if char_arm.animation_data else [])}:
            final_name = f"{clip_name}.{n:03d}"
            n += 1
        action.name = final_name
        action_prefix = get_action_hips_prefix(action) or ""
        remapped = remap_action_bone_prefix(action, action_prefix, char_prefix)
        stripped = strip_hip_translation(action)
        push_action_to_nla(char_arm, action, final_name)

        # Drop any extra Actions the importer pulled in but didn't assign.
        for extra in new_actions[1:]:
            try:
                bpy.data.actions.remove(extra, do_unlink=True)
            except Exception:
                pass

        remove_objects_recursive(new_objs)
        suffix_parts: list[str] = []
        if remapped:
            suffix_parts.append(f"remapped {remapped} fcurves {action_prefix!r}→{char_prefix!r}")
        if stripped:
            suffix_parts.append(f"stripped {stripped} hip-loc")
        suffix = "  [" + " | ".join(suffix_parts) + "]" if suffix_parts else ""
        print(f"  + {final_name}  ({pathlib.Path(anim_path).name}){suffix}")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    # Force smooth shading on every polygon of the character mesh before export
    # so Mixamo's smoothing groups don't get baked as flat in the GLB.
    shade_smooth_all_meshes()

    # Mixamo Boy01-class facial materials come in as metallic=1 (Blender misreads
    # the FBX's specular workflow). Zero them so eyes/brows/mouth aren't black.
    zero_metallic_on_all_materials()

    # Select the character armature + its mesh children so the GLB only
    # exports what we want (no leftover anim-armature ghosts).
    bpy.ops.object.select_all(action="DESELECT")
    char_arm.select_set(True)
    for o in bpy.context.scene.objects:
        if o.type == "MESH" and o.find_armature() is char_arm:
            o.select_set(True)
    bpy.context.view_layer.objects.active = char_arm

    bpy.ops.export_scene.gltf(
        filepath=out_path,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_animations=True,
        export_animation_mode="NLA_TRACKS",
        export_optimize_animation_size=True,
    )
    nla_count = len(char_arm.animation_data.nla_tracks) if char_arm.animation_data else 0
    print(f"  → {out_path}  ({nla_count} NLA tracks)")


# ---------- entry point ----------

def main() -> None:
    chars_dir, anims_dir, output_dir = parse_args()

    char_fbxs = sorted(glob.glob(os.path.join(chars_dir, "*.fbx")))
    anim_fbxs = sorted(glob.glob(os.path.join(anims_dir, "*.fbx"))) if os.path.isdir(anims_dir) else []

    print(f"[mixamo→glb] characters_dir = {chars_dir}")
    print(f"[mixamo→glb] anims_dir      = {anims_dir}  ({len(anim_fbxs)} anims)")
    print(f"[mixamo→glb] output_dir     = {output_dir}")
    print(f"[mixamo→glb] characters     = {len(char_fbxs)}")

    if not char_fbxs:
        raise SystemExit(f"No .fbx files found in {chars_dir}")

    for char_path in char_fbxs:
        out_name = pathlib.Path(char_path).stem.lower() + ".glb"
        out_path = os.path.join(output_dir, out_name)
        try:
            process_character(char_path, anim_fbxs, out_path)
        except Exception as e:
            print(f"  [FAILED] {char_path}: {e}")
            import traceback; traceback.print_exc()


if __name__ == "__main__":
    main()
