#!/usr/bin/env blender --background
"""Yumeka seated GLB exporter for the Scalebreaker desktop-sandbox skybox (phase 3A).

Pipeline (run from the repo root):
    blender --background --python scripts/export_yumeka_seated.py -- --preview
    blender --background --python scripts/export_yumeka_seated.py –

1. Locate YUMEKA_v1.0.4.zip (default ~/Downloads/), extract it to a temporary
   directory OUTSIDE the repo, and open Blend/Yumeka.blend from there. Neither the
   zip nor the .blend ever lands inside the repository.
2. Prune shape keys down to a small facial set (blink / soft smile / gaze pitch),
   cutting hundreds of unused body-sizer & MMD morphs for a small, cheap GLB.
3. Rebuild every lilToon-inspired emissive material as a Principled BSDF bound to
   the packed PNG textures (the raw files are unlit emissive node setups that do
   not survive glTF export).
4. Pose a natural seated posture against FK world-space joint twists (see
   POSE_TWISTS): horizontal thighs under the 0.75 m desk, near-vertical shins,
   8–12° torso lean, ~20° head tilt gazing down at the 21.27 cm sandbox, hands
   resting on the thighs.
5. Measure the seated butt-contact / eye / foot heights, uniformly scale so the
   seated eye height above the chair cushion is ~0.745 m (total seated eye height
   1.20 m for a 0.4553 m cushion), and rebase the origin onto the cushion contact
   plane so the GLB roots exactly at skybox_bedroom.gd's ultra_giant_anchor.
6. Apply the pose as the rest pose and export only what the sandbox needs as
   assets/characters/yumeka/Yumeka_seated.glb (texture PNGs embedded).

The output stays gitignored (assets/characters/yumeka/): the Yumeka model and
textures are licensed assets and must never be pushed to the public repo.
"""

import os
import shutil
import sys
import tempfile
import zipfile
from math import radians

import bpy
from mathutils import Matrix, Vector

# --------------------------------------------------------------------------- #
# Authoring constants (tune POSE_TWISTS by iterating --preview renders).
# --------------------------------------------------------------------------- #

BLEND_INNER = os.path.join("YUMEKA_v1.0.4", "Blend", "Yumeka.blend")
DEFAULT_ZIP = os.path.expanduser("~/Downloads/YUMEKA_v1.0.4.zip")
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DEFAULT_OUT = os.path.join(REPO_ROOT, "assets", "characters", "yumeka", "Yumeka_seated.glb")

## Bedroom facts mirrored from scenes/skybox_bedroom.gd (metres):
DESK_TOP = 0.75              # desk surface
SEAT_TOP = 0.4553            # chair cushion surface == ultra_giant_anchor height
SEALED_EYE_TARGET = 1.20     # desired seated eye height above the bedroom floor
TARGET_EYE_ABOVE_SEAT = SEALED_EYE_TARGET - SEAT_TOP  # 0.7447 m
SANDBOX_TOP = 0.7548         # diorama tray surface (DESK_TOP + 32 * SKY_SCALE)

## Every ~2048² packed image rescales to this size (GLB stays light).
TEXTURE_SIZE = 2048

## Seated pose: ordered (bone, armature-space axis, degrees) FK twists, applied
## parent-first. She faces Blender -Y (the desk/sandbox direction), Z is up.
POSE_TWISTS = [
    # -- thighs: horizontal, sinking slightly into the cushion (knees over toes)
    ("UpperLeg_L", (1, 0, 0), -84.0),
    ("UpperLeg_R", (1, 0, 0), -84.0),
    # -- knees: shins near vertical, toes slightly tucked under the desk front
    ("LowerLeg_L", (1, 0, 0), 82.0),
    ("LowerLeg_R", (1, 0, 0), 82.0),
    # -- feet: flat on the floor
    ("Foot_L", (1, 0, 0), 6.0),
    ("Foot_R", (1, 0, 0), 6.0),
    # -- spine chain: gentle 10° forward lean focused low in the back
    ("Spine", (1, 0, 0), 5.0),
    ("Chest", (1, 0, 0), 5.0),
    # -- neck relaxed, head bowed to watch the 21.27 cm diorama
    ("Neck", (1, 0, 0), 3.0),
    ("Head", (1, 0, 0), 18.0),
    # -- arms: hang, then 12° forward so the hands land on the thighs
    ("UpperArm_L", (0, 0, 1), -12.0),
    ("UpperArm_R", (0, 0, 1), 12.0),
    ("UpperArm_L", (0, 1, 0), 88.0),
    ("UpperArm_R", (0, 1, 0), -88.0),
    # -- elbows: fold forearms onto the thighs near the knees
    ("LowerArm_L", (1, 0, 0), -52.0),
    ("LowerArm_R", (1, 0, 0), -52.0),
    # -- hands: rest flat-ish on the thighs
    ("Hand_L", (1, 0, 0), -14.0),
    ("Hand_R", (1, 0, 0), -14.0),
]

## Shape keys kept in the GLB (anything else is removed). Names arriving with
## characters that break NodePath property addressing ("vrc.looking_down" style
## dots or unicode) are renamed below so Godot can drive them through
## `blend_shapes/<name>` without parsing pitfalls.
KEEP_SHAPE_KEYS = [
    "eye_close", "eye_close_L", "eye_close_R",     # blink
    "eye_joy",                                     # happy squint
    "eye_nagomi_1",                                # soft warm gaze
    "eye_under_up_1",                              # gentle lower lid
    "vrc.looking_up", "vrc.looking_down",         # gaze pitch helpers
    "mouth_smile_1", "mouth_smile_2",              # smiles
    "mouth_a", "mouth_i_1", "mouth_u",             # idle mouth shapes
    "mouth_ω_1",                                   # cute omega mouth
]

SHAPE_KEY_RENAMES = {
    "vrc.looking_up": "look_up",
    "vrc.looking_down": "look_down",
    "mouth_ω_1": "mouth_w_1",
}

## Fresh materials: slot material name -> (image name substring, use alpha).
MATERIAL_MAP = {
    "Yumeka_Face": ("Yumeka_face", False),
    "Yumeka_Face_Transparent": ("Yumeka_face", True),
    "Yumeka_Body": ("Yumeka_body", False),
    "Yumeka_Clothes": ("Yumeka_clothes", False),
    "Yumeka_Hair": ("Yumeka_hair", False),
    "Yumeka_Hair_Transparent": ("Yumeka_hair", True),
    "Yumeka_Wing_Transparent": ("Yumeka_clothes", True),
}


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

def _log(msg: str) -> None:
    print(f"[yumeka-export] {msg}", flush=True)


def locate_blend(override: str) -> tuple[str, str]:
    """Return (blend_path, cleanup_dir). Extracts the zip to a temp dir if needed."""
    if override and override.endswith(".blend"):
        return override, ""
    zip_path = override or DEFAULT_ZIP
    if not os.path.isfile(zip_path):
        raise SystemExit(f"Yumeka zip not found: {zip_path}")
    dest = os.path.join(tempfile.gettempdir(), "yumeka_src_export")
    inner = os.path.join(dest, "YUMEKA_v1.0.4", "Blend", "Yumeka.blend")
    if not os.path.isfile(inner) or os.path.getmtime(zip_path) > os.path.getmtime(inner):
        _log(f"extracting {zip_path} -> {dest}")
        os.makedirs(dest, exist_ok=True)
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(dest)
    return inner, ""


def prune_shape_keys() -> None:
    removed = 0
    renamed = 0
    for ob in bpy.data.objects:
        if ob.type != "MESH":
            continue
        keys = ob.data.shape_keys
        if keys is None:
            continue
        for key in list(keys.key_blocks):
            if key.name not in KEEP_SHAPE_KEYS and key.name != "Basis":
                ob.shape_key_remove(key)
                removed += 1
        for key in keys.key_blocks:
            if key.name in SHAPE_KEY_RENAMES:
                key.name = SHAPE_KEY_RENAMES[key.name]
                renamed += 1
            key.value = 0.0
    _log(f"shape keys pruned: removed {removed}, renamed {renamed}, "
         f"kept {sum(len(o.data.shape_keys.key_blocks) for o in bpy.data.objects if o.type == 'MESH' and o.data.shape_keys)}")


def _texture_for(image_substring: str) -> bpy.types.Image:
    for img in bpy.data.images:
        if image_substring.lower() in img.name.lower():
            if img.size[0] > TEXTURE_SIZE:
                try:
                    img.scale(TEXTURE_SIZE, TEXTURE_SIZE)
                except Exception as exc:  # noqa: BLE001 - packed scale can fail
                    _log(f"texture rescale skipped for {img.name}: {exc}")
            return img
    raise SystemExit(f"no packed image matches '{image_substring}'")


def rebuild_materials() -> None:
    """Replace lilToon-era emissive materials with PBR Principled materials."""
    cache = {}
    for mat in list(bpy.data.materials):
        name = mat.name
        if name not in MATERIAL_MAP:
            continue
        image_sub, use_alpha = MATERIAL_MAP[name]
        image = _texture_for(image_sub)

        fresh = bpy.data.materials.new(name + "_GB")
        fresh.use_nodes = True
        tree = fresh.node_tree
        tree.nodes.clear()
        out = tree.nodes.new("ShaderNodeOutputMaterial")
        bsdf = tree.nodes.new("ShaderNodeBsdfPrincipled")
        tex = tree.nodes.new("ShaderNodeTexImage")
        tex.image = image
        out.location = (400, 0)
        bsdf.location = (100, 0)
        tex.location = (-300, 0)
        tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        if use_alpha:
            tree.links.new(tex.outputs["Alpha"], bsdf.inputs["Alpha"])
            try:
                fresh.surface_render_method = "BLENDED"
            except Exception:  # noqa: BLE001 - older API fallback
                fresh.blend_method = "BLEND"
        # Soft matte anime look (the skybox light is gentle; Godot re-tunes too).
        bsdf.inputs["Roughness"].default_value = 0.88
        bsdf.inputs["Metallic"].default_value = 0.0
        bsdf.inputs["Specular IOR Level"].default_value = 0.35
        tree.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])

        cache[name] = fresh
        _log(f"material rebuilt: {name} -> {fresh.name} (alpha={use_alpha}, tex={image.name})")

    for ob in bpy.data.objects:
        if ob.type != "MESH":
            continue
        for slot in ob.material_slots:
            if slot.material is not None and slot.material.name in cache:
                slot.material = cache[slot.material.name]
    # Drop the originals and give the fresh ones the clean final names.
    for old_name, fresh in cache.items():
        fresh.name = old_name
        for mat in list(bpy.data.materials):
            if mat.name.startswith(old_name) and mat != fresh and mat.name != old_name:
                if mat.users == 0:
                    bpy.data.materials.remove(mat)


def bend(arm_obj: bpy.types.Object, bone_name: str, axis, deg: float) -> None:
    """Twist pose bone `bone_name` about an ARMATURE-space axis through its head.

    Writing the full armature-space matrix lets Blender solve per-bone locals, so
    every twist is expressed in world terms (Z up, facing -Y) without hand-deriving
    per-bone Euler signs or rolls. Children follow their parents automatically.
    Pose matrix writes are DEFERRED: the read-back right after a write still
    returns the stale matrix until the view layer is updated, so every write is
    flushed immediately (otherwise stacked twists on one bone silently drop and
    children solve against an outdated parent pose).
    """
    pb = arm_obj.pose.bones.get(bone_name)
    if pb is None:
        raise SystemExit(f"missing pose bone: {bone_name}")
    cur = pb.matrix.copy()
    head = cur.translation
    rot = Matrix.Rotation(radians(deg), 4, axis)
    pb.matrix = Matrix.Translation(head) @ rot @ Matrix.Translation(-head) @ cur
    bpy.context.view_layer.update()


def pose_seated(arm_obj: bpy.types.Object) -> None:
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="POSE")
    for bone_name, axis, deg in POSE_TWISTS:
        bend(arm_obj, bone_name, axis, deg)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.context.view_layer.update()


def remove_helpers() -> None:
    """Drop light/camera/leftover helper objects; keep only armature + meshes."""
    for ob in list(bpy.data.objects):
        if ob.type not in {"ARMATURE", "MESH"}:
            bpy.data.objects.remove(ob, do_unlink=True)
    # All meshes must carry an armature modifier so the pose deforms them.
    arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
    for ob in bpy.data.objects:
        if ob.type != "MESH":
            continue
        if not any(m.type == "ARMATURE" for m in ob.modifiers):
            mod = ob.modifiers.new("Armature", "ARMATURE")
            mod.object = arm
            _log(f"added missing armature modifier on {ob.name}")


def _pose_matrices(arm_obj):
    return {pb.name: pb.matrix.copy() for pb in arm_obj.pose.bones}


def _eval_world(arm_obj) -> list:
    """Snapshot every mesh's posed world-space vertices (armature modifier applied)."""
    deps = bpy.context.evaluated_depsgraph_get()
    out = []
    for ob in bpy.data.objects:
        if ob.type != "MESH":
            continue
        ev = ob.evaluated_get(deps)
        me = ev.to_mesh(preserve_all_data_layers=True, depsgraph=deps)
        mx = ev.matrix_world
        out.extend((mx @ v.co) for v in me.vertices)
        ev.to_mesh_clear()
    return out


def _per_mesh_eval(arm_obj):
    """Posed world-space vertices grouped per mesh, with the mesh name."""
    deps = bpy.context.evaluated_depsgraph_get()
    for ob in bpy.data.objects:
        if ob.type != "MESH":
            continue
        ev = ob.evaluated_get(deps)
        me = ev.to_mesh(preserve_all_data_layers=True, depsgraph=deps)
        mx = ev.matrix_world
        yield ([(mx @ v.co) for v in me.vertices], ob.name)
        ev.to_mesh_clear()


def _mesh_lowest(arm_obj, region=None) -> float:
    lowest = None
    lowest_owner = ""
    for ob in bpy.data.objects:
        if ob.type != "MESH":
            continue
        for pt in _eval_world(ob):
            if region is not None and not region(pt):
                continue
            if lowest is None or pt.z < lowest:
                lowest = pt.z
                lowest_owner = ob.name
    if region is not None and lowest is not None:
        _log(f"  lowest vertex owner: {lowest_owner} at z={lowest:.4f}")
    return lowest


def measure_and_scale(arm_obj) -> dict:
    """Scale to the seated eye-height spec and rebase the origin at the cushion."""
    bpy.context.view_layer.update()

    def dump_lowest(count: int) -> None:
        rows = []
        for pt_list in _per_mesh_eval(arm_obj):
            for pt in pt_list[0]:
                rows.append((pt.z, pt_list[1], tuple(round(c, 3) for c in pt)))
            if len(rows) > 200000:
                rows.sort()
                rows = rows[:100]
        rows.sort()
        for row in rows[:count]:
            _log(f"  LOW: z={row[0]:.4f} mesh={row[1]} pos={row[2]}")

    stats = {}
    # Eye height: mean of the posed Eye_L / Eye_R bone heads (true eye centres).
    eye_zs = []
    for side in ("Eye_L", "Eye_R"):
        pb = arm_obj.pose.bones.get(side)
        if pb is not None:
            eye_zs.append((arm_obj.matrix_world @ pb.matrix.translation).z)
    eye_z = sum(eye_zs) / max(len(eye_zs), 1)
    # Butt contact plane: lowest seat-region vertex around the pelvis (thigh gap
    # excluded via the x/y window; the cushion plane is a small contact patch).
    def seat_region(pt: Vector) -> bool:
        # Pelvis/isglial contact patch only: the pleated skirt hem drapes ~20 cm
        # below the real cushion contact, so the z window must hug the pelvis
        # underside and exclude that hanging fabric.
        return abs(pt.x) < 0.12 and -0.14 < pt.y < 0.10 and 0.45 < pt.z < 0.75
    butt_z = _mesh_lowest(arm_obj, seat_region)
    # Foot contact: lowest toe-region vertex in front of the shin.
    def foot_region(pt: Vector) -> bool:
        return abs(pt.x) < 0.42 and pt.y < -0.12 and pt.z < 0.20
    foot_z = _mesh_lowest(arm_obj, foot_region)

    scale = TARGET_EYE_ABOVE_SEAT / max(eye_z - butt_z, 1e-6)
    stats.update(raw_eye_z=eye_z, raw_butt_z=butt_z, raw_foot_z=foot_z, scale=scale)

    # Uniform scale + origin rebase: cushion contact plane becomes z == 0.
    arm_obj.scale = (scale, scale, scale)
    arm_obj.location.z -= butt_z * scale
    bpy.context.view_layer.update()

    world = arm_obj.matrix_world
    eye_world = None
    foot_world = None
    for side in ("Eye_L", "Eye_R"):
        pb = arm_obj.pose.bones.get(side)
        if pb is not None:
            eye_world = (world @ pb.matrix.translation).z
    foot_world = _mesh_lowest(arm_obj, foot_region)

    # Petite-figure leg reach vs the 0.4553 m bench reality: her shin+shoe line
    # measures a few centimetres short of the floor, so the sole would dig in.
    # Soft-cushion compensation: sink the pelvis into the chair pad just deep
    # enough to plant the shoe soles flush on the bedroom floor.
    cushion_sink = 0.0
    if foot_world is not None and foot_world + SEAT_TOP < 0.0:
        cushion_sink = min(-(foot_world + SEAT_TOP), 0.08)
        arm_obj.location.z += cushion_sink
        bpy.context.view_layer.update()
        foot_world = _mesh_lowest(arm_obj, foot_region)

    stats["eye_above_cushion"] = eye_world
    stats["foot_below_cushion"] = foot_world
    stats["eye_height_in_room"] = eye_world + SEAT_TOP - cushion_sink
    stats["foot_height_in_room"] = foot_world + SEAT_TOP
    stats["cushion_sink"] = cushion_sink
    dump_lowest(14)
    # Thigh-top clearance probe: highest vertex over the thighs, checked against
    # the desk underside when mounted (desk board ~2-3 cm thick).
    thigh_top = max((pt.z for pt in _eval_world(arm_obj)
                     if abs(pt.x) < 0.25 and -0.62 < pt.y < -0.30), default=0.0)
    stats["thigh_top_in_room"] = thigh_top + SEAT_TOP
    # Absolute posed bounds for clipping checks against the desk plane.
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for pt in _eval_world(arm_obj):
        lo = Vector((min(lo.x, pt.x), min(lo.y, pt.y), min(lo.z, pt.z)))
        hi = Vector((max(hi.x, pt.x), max(hi.y, pt.y), max(hi.z, pt.z)))
    stats["bounds_lo"] = tuple(round(c, 4) for c in lo)
    stats["bounds_hi"] = tuple(round(c, 4) for c in hi)
    return stats


def apply_pose_as_rest(arm_obj) -> None:
    for ob in bpy.data.objects:
        ob.select_set(ob.type in {"ARMATURE", "MESH"})
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="POSE")
    bpy.ops.pose.select_all(action="SELECT")
    bpy.ops.pose.armature_apply()
    bpy.ops.pose.select_all(action="DESELECT")
    bpy.ops.object.mode_set(mode="OBJECT")


def render_preview(out_dir: str, arm_obj: bpy.types.Object) -> None:
    """Studio preview: final-scale silhouette of the seated pose against desk/seat blocks."""
    scene = bpy.context.scene
    for ob in [o for o in bpy.data.objects if o.type not in {"ARMATURE", "MESH"}]:
        bpy.data.objects.remove(ob, do_unlink=True)

    # Debug: where did the limbs end up?
    for probe in ("Hand_L", "Hand_R", "LowerArm_L", "UpperLeg_L", "Foot_L", "Head", "Eye_L"):
        pb = arm_obj.pose.bones.get(probe)
        if pb is not None:
            w = arm_obj.matrix_world @ pb.matrix.translation
            _log(f"pose probe {probe} world=({w.x:.3f}, {w.y:.3f}, {w.z:.3f})")

    def _block(sizev, pos, color):
        bpy.ops.mesh.primitive_cube_add(size=1, location=pos)
        ob = bpy.context.active_object
        ob.scale = sizev
        ob.name = "PreviewProp"
        mat = bpy.data.materials.new("preview")
        mat.use_nodes = False
        mat.diffuse_color = (*color, 1)
        ob.data.materials.append(mat)
        return ob

    # seat cushion block: top at SEAT_TOP
    _block((0.42, 0.30, SEAT_TOP * 0.5), (0, 0.05, SEAT_TOP * 0.5), (0.7, 0.5, 0.4))
    # desk slab: top at DESK_TOP, front face at y = -0.35, depth 0.7
    depth = 0.7
    front = -0.35
    _block((1.6, depth * 0.5, 0.035), (0, front - depth * 0.5, DESK_TOP - 0.035), (0.75, 0.6, 0.45))
    # sandbox diorama on top of the desk: 0.2127² footprint at the desk centre
    _block((0.2127 * 0.5, 0.2127 * 0.5, 0.0048 * 0.5), (0, -0.5484, SANDBOX_TOP + 0.0024), (0.3, 0.8, 0.35))

    sun_data = bpy.data.lights.new("prev_sun", "SUN")
    sun_data.energy = 2.6
    sun = bpy.data.objects.new("prev_sun", sun_data)
    scene.collection.objects.link(sun)
    sun.rotation_euler = (radians(50), radians(15), radians(30))
    fill_data = bpy.data.lights.new("prev_fill", "SUN")
    fill_data.energy = 1.4
    fill = bpy.data.objects.new("prev_fill", fill_data)
    scene.collection.objects.link(fill)
    fill.rotation_euler = (radians(120), radians(-20), radians(160))

    if scene.world is None:
        scene.world = bpy.data.worlds.new("world")
    scene.world.use_nodes = False
    scene.world.color = (0.35, 0.34, 0.36)

    cam_data = bpy.data.cameras.new("prev_cam")
    cam_data.lens = 60
    cam = bpy.data.objects.new("prev_cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 900
    scene.render.resolution_y = 1100

    shots = {
        "front_left": (Vector((-1.9, -1.9, 1.5)), Vector((0, 0, 0.8))),
        "side_left": (Vector((-1.6, 0.0, 1.1)), Vector((0, -0.25, 0.7))),
        "front_straight": (Vector((0.0, -2.0, 1.0)), Vector((0, 0, 0.85))),
        "lap_closeup": (Vector((-0.9, -0.9, 0.9)), Vector((0, -0.25, 0.62))),
        "sandbox_pov": (Vector((0.0, -0.62, 0.86)), Vector((0, 0.1, 1.12))),
        "floor_feet": (Vector((-0.95, -0.85, 0.16)), Vector((0.0, -0.15, -0.10))),
    }
    os.makedirs(out_dir, exist_ok=True)
    for name, (pos, aim) in shots.items():
        cam.location = pos
        # to_track_quat('Z', 'Y') points the camera's +Z along this vector, i.e. its
        # looking -Z axis ends up at `aim`, so feed it (pos - aim).
        cam.rotation_euler = (pos - aim).to_track_quat("Z", "Y").to_euler()
        scene.render.filepath = os.path.join(out_dir, f"yumeka_{name}.png")
        bpy.ops.render.render(write_still=True)
        _log(f"preview render saved: {scene.render.filepath}")


def export_glb(path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="DESELECT")
    for ob in bpy.data.objects:
        if ob.type in {"ARMATURE", "MESH"}:
            ob.select_set(True)
    # The glTF2 exporter lives in addons_core but is not auto-registered in
    # background mode; Blender 5.3 exposes it as export_scene.gltf.
    bpy.ops.preferences.addon_enable(module="io_scene_gltf2")
    bpy.ops.export_scene.gltf(
        filepath=path,
        use_selection=True,
        export_format="GLB",
        export_animations=False,
        export_skins=True,
        export_morph=True,
        export_apply=False,
        export_extras=False,
    )
    size = os.path.getsize(path) / (1024 * 1024)
    _log(f"exported {path} ({size:.1f} MB, scale rebased at cushion plane, "
         f"{len(bpy.data.meshes)} meshes, morphs pruned)")


# --------------------------------------------------------------------------- #
# Entry point
# --------------------------------------------------------------------------- #

def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    zip_override = ""
    out_path = DEFAULT_OUT
    preview_only = False
    it = iter(argv)
    for arg in it:
        if arg == "--zip":
            zip_override = next(it, "")
        elif arg == "--out":
            out_path = next(it, DEFAULT_OUT)
        elif arg == "--preview":
            preview_only = True

    blend_path, _ = locate_blend(zip_override)
    _log(f"opening {blend_path}")
    bpy.ops.wm.open_mainfile(filepath=blend_path)
    arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")

    remove_helpers()
    prune_shape_keys()
    rebuild_materials()
    pose_seated(arm)
    stats = measure_and_scale(arm)
    for key, value in stats.items():
        _log(f"{key} = {value}")

    if preview_only:
        render_preview(os.path.join(REPO_ROOT, "build", "tmp", "yumeka_preview"), arm)
        return

    # Validation window, then bake and export.
    eye_ok = 1.10 <= stats["eye_height_in_room"] <= 1.30
    foot_off = stats["foot_height_in_room"]
    _log(f"eye height in room: {stats['eye_height_in_room']:.3f} m (spec 1.15-1.25; window 1.10-1.30)")
    _log(f"foot over floor: {foot_off:+.3f} m (natural resting; negative digs in)")
    if not eye_ok:
        raise SystemExit("seated eye height out of spec; adjust POSE_TWISTS")

    apply_pose_as_rest(arm)
    export_glb(out_path)
    print("[yumeka-export] DONE")


main()
