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
4. Pose a forward-leaning desk-braced posture against FK twists (see POSE_TWISTS):
   horizontal thighs well under the 0.69 m desk underside, near-vertical shins,
   ~30° forward Spine+Chest lean, neck/head aligned onto the 21.27 cm sandbox so
   seated eye height lands at ~0.95–1.08 m, and forearms resting wide on the oak
   tabletop outside the sandbox.
5. Measure the un-tilted seated cushion contact plane first (LEG_POSE_TWISTS),
   apply the bedroom-calibrated BODY_SCALE + cushion compression, and verify
   eye height (0.95–1.08 m) and thigh clearance (< 0.688 m) before exporting.
6. Keyframe the 1-frame `SeatedPose` Action (NEVER call `armature_apply()`, which
   corrupts glTF skin binding) so all 14 facial shape keys stay lossless, and
   export assets/characters/yumeka/Yumeka_seated.glb (texture PNGs embedded).

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
CHAIR_Z = 0.60               # ChairDesk z (moved 4.0 cm closer to desk from 0.64)
ANCHOR_Z = CHAIR_Z - 0.047 * 1.95  # 0.50835 m (ultra_giant_anchor z in bedroom)
# Petite anime schoolgirl body scale (1.343 m raw -> ~1.41 m seated-calibrated)
# paired with soft swivel-chair cushion compression so thighs sit 8.7 cm below the
# 0.69 m desk underside, elbows/palms rest flat on the 0.75 m oak tabletop flanking
# the sandbox, and seated eye height lands at ~0.97 m (both giant eyes cleanly fill
# the upper sky on 25 m & 100 m strictly horizontal south-facing gameplay views).
BODY_SCALE = 1.05
CUSHION_COMPRESSION = 0.042  # soft swivel-chair pad sink (cushion thickness is 8.5 cm)
SANDBOX_TOP = 0.7548         # diorama tray surface (DESK_TOP + 32 * SKY_SCALE)

## Every ~2048² packed image rescales to this size (GLB stays light).
TEXTURE_SIZE = 2048

## Leg-only seated twists used first to measure the un-tilted pelvis/cushion plane
## cleanly before applying upper-body forward lean.
LEG_POSE_TWISTS = [
    # -- thighs: horizontal under the 0.69 m desk underside with gentle natural knee splay
    ("UpperLeg_L", (1, 0, 0), -89.0),
    ("UpperLeg_R", (1, 0, 0), -89.0),
    ("UpperLeg_L", (0, 0, 1), -3.0),
    ("UpperLeg_R", (0, 0, 1), 3.0),
    # -- knees: shins near vertical under the desk
    ("LowerLeg_L", (1, 0, 0), 86.0),
    ("LowerLeg_R", (1, 0, 0), 86.0),
    # -- feet: softly resting near the floor
    ("Foot_L", (1, 0, 0), 10.0),
    ("Foot_R", (1, 0, 0), 10.0),
]

## Upper-body forward-leaning desk-resting twists: 30° lean across Spine + Chest (4° + 26°),
## neck pitched forward and head counter-lifted so her eyes sit ~23 cm above the desk
## gazing straight into the 21.27 cm sandbox; upper arms drop naturally along the torso
## onto elbows resting on the oak desk (|x| ~0.22, y ~0.80, z ~0.37), and bent forearms
## angle inward in a soft A-frame (/\) flanking the south outer edge of the sandbox.
UPPER_POSE_TWISTS = [
    # -- spine/chest: 30° forward lean concentrated above desk height (zero torso-desk clip)
    ("Spine", (1, 0, 0), 4.0),
    ("Chest", (1, 0, 0), 26.0),
    # -- neck & head: lean face close over the diorama, chin raised for clean eye/bangs reveal
    ("Neck", (1, 0, 0), 14.0),
    ("Head", (1, 0, 0), -14.0),
    # -- shoulders: relaxed natural downward drop toward the desk surface
    ("Shoulder_L", (0, 1, 0), 8.0),
    ("Shoulder_R", (0, 1, 0), -8.0),
    ("Shoulder_L", (0, 0, 1), -12.0),
    ("Shoulder_R", (0, 0, 1), 12.0),
    # -- upper arms: tucked close beside torso, sloping down onto the oak tabletop
    ("UpperArm_L", (0, 1, 0), 36.0),
    ("UpperArm_R", (0, 1, 0), -36.0),
    ("UpperArm_L", (1, 0, 0), -38.0),
    ("UpperArm_R", (1, 0, 0), -38.0),
    ("UpperArm_L", (0, 0, 1), 9.0),
    ("UpperArm_R", (0, 0, 1), -9.0),
    # -- forearms: natural A-frame (/\) resting forward along the desk south of the sandbox
    ("LowerArm_L", (1, 0, 0), -31.0),
    ("LowerArm_R", (1, 0, 0), -31.0),
    ("LowerArm_L", (0, 1, 0), -4.0),
    ("LowerArm_R", (0, 1, 0), 4.0),
    ("LowerArm_L", (0, 0, 1), -70.0),
    ("LowerArm_R", (0, 0, 1), 70.0),
]

## Local-axis forearm pronation (levels palms flat onto the oak tabletop), soft wrist
## extension, and true anatomical 5-finger semi-curled relaxation (-deg about local X on
## both _L and _R curls fingers symmetrically downward toward the palm).
LOCAL_POSE_TWISTS = [
    ("LowerArm_L", (0, 1, 0), 59.0),
    ("LowerArm_R", (0, 1, 0), -59.0),
    ("Hand_L", (1, 0, 0), 10.0),
    ("Hand_R", (1, 0, 0), 10.0),
    # -- relaxed thumb inward curl
    ("ThumbProximal_L", (1, 0, 0), -10.0),
    ("ThumbIntermediate_L", (1, 0, 0), -18.0),
    ("ThumbDistal_L", (1, 0, 0), -22.0),
    ("ThumbProximal_R", (1, 0, 0), -10.0),
    ("ThumbIntermediate_R", (1, 0, 0), -18.0),
    ("ThumbDistal_R", (1, 0, 0), -22.0),
    # -- progressive relaxed curl from index to little finger (semi-relaxed resting hand)
    ("IndexProximal_L", (1, 0, 0), -20.0),
    ("IndexIntermediate_L", (1, 0, 0), -32.0),
    ("IndexDistal_L", (1, 0, 0), -20.0),
    ("MiddleProximal_L", (1, 0, 0), -24.0),
    ("MiddleIntermediate_L", (1, 0, 0), -36.0),
    ("MiddleDistal_L", (1, 0, 0), -24.0),
    ("RingProximal_L", (1, 0, 0), -28.0),
    ("RingIntermediate_L", (1, 0, 0), -40.0),
    ("RingDistal_L", (1, 0, 0), -26.0),
    ("LittleProximal_L", (1, 0, 0), -32.0),
    ("LittleIntermediate_L", (1, 0, 0), -44.0),
    ("LittleDistal_L", (1, 0, 0), -28.0),
    ("IndexProximal_R", (1, 0, 0), -20.0),
    ("IndexIntermediate_R", (1, 0, 0), -32.0),
    ("IndexDistal_R", (1, 0, 0), -20.0),
    ("MiddleProximal_R", (1, 0, 0), -24.0),
    ("MiddleIntermediate_R", (1, 0, 0), -36.0),
    ("MiddleDistal_R", (1, 0, 0), -24.0),
    ("RingProximal_R", (1, 0, 0), -28.0),
    ("RingIntermediate_R", (1, 0, 0), -40.0),
    ("RingDistal_R", (1, 0, 0), -26.0),
    ("LittleProximal_R", (1, 0, 0), -32.0),
    ("LittleIntermediate_R", (1, 0, 0), -44.0),
    ("LittleDistal_R", (1, 0, 0), -28.0),
]

## Subtle wrist pitch polish applied after local palm leveling.
HAND_POSE_TWISTS = []

POSE_TWISTS = LEG_POSE_TWISTS + UPPER_POSE_TWISTS + LOCAL_POSE_TWISTS + HAND_POSE_TWISTS

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


def bend_local(arm_obj: bpy.types.Object, bone_name: str, local_axis, deg: float) -> None:
    """Twist pose bone about one of its OWN current local axes (used for forearm pronation)."""
    pb = arm_obj.pose.bones.get(bone_name)
    if pb is None:
        raise SystemExit(f"missing pose bone: {bone_name}")
    cur = pb.matrix.copy()
    head = cur.translation
    arm_axis = (cur.to_3x3().normalized() @ Vector(local_axis)).normalized()
    rot = Matrix.Rotation(radians(deg), 4, arm_axis)
    pb.matrix = Matrix.Translation(head) @ rot @ Matrix.Translation(-head) @ cur
    bpy.context.view_layer.update()


def pose_seated(arm_obj: bpy.types.Object) -> float:
    """Apply the seated legs first to read the un-tilted pelvis cushion contact,
    then layer the upper-body leaning/elbow-prop pose, forearm pronation, and
    relaxed hands on top. Returns raw butt_z."""
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="POSE")
    for bone_name, axis, deg in LEG_POSE_TWISTS:
        bend(arm_obj, bone_name, axis, deg)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.context.view_layer.update()

    def seat_region(pt: Vector) -> bool:
        return abs(pt.x) < 0.12 and -0.14 < pt.y < 0.10 and 0.45 < pt.z < 0.78
    raw_butt_z = _mesh_lowest(arm_obj, seat_region)

    bpy.ops.object.mode_set(mode="POSE")
    for bone_name, axis, deg in UPPER_POSE_TWISTS:
        bend(arm_obj, bone_name, axis, deg)
    for bone_name, local_axis, deg in LOCAL_POSE_TWISTS:
        bend_local(arm_obj, bone_name, local_axis, deg)
    for bone_name, axis, deg in HAND_POSE_TWISTS:
        bend(arm_obj, bone_name, axis, deg)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.context.view_layer.update()
    return raw_butt_z


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


def measure_and_scale(arm_obj, raw_butt_z: float) -> dict:
    """Apply the bedroom-calibrated body scale, rebase onto the chair cushion,
    and report exact room-space clearances (eyes, hands, elbows, thighs, feet)."""
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
    eye_zs = []
    for side in ("Eye_L", "Eye_R"):
        pb = arm_obj.pose.bones.get(side)
        if pb is not None:
            eye_zs.append((arm_obj.matrix_world @ pb.matrix.translation).z)
    eye_z = sum(eye_zs) / max(len(eye_zs), 1)
    def foot_region(pt: Vector) -> bool:
        return abs(pt.x) < 0.42 and pt.y < -0.12 and pt.z < 0.25
    foot_z = _mesh_lowest(arm_obj, foot_region)

    scale = BODY_SCALE
    cushion_sink = CUSHION_COMPRESSION
    stats.update(raw_eye_z=eye_z, raw_butt_z=raw_butt_z, raw_foot_z=foot_z, scale=scale)

    # Uniform scale + origin rebase: cushion contact plane sits at z = -cushion_sink
    # (gentle foam compression inside the 8.5 cm thick swivel-chair pad).
    arm_obj.scale = (scale, scale, scale)
    arm_obj.location.z -= raw_butt_z * scale + cushion_sink
    bpy.context.view_layer.update()

    world = arm_obj.matrix_world
    eye_pts = []
    for side in ("Eye_L", "Eye_R"):
        pb = arm_obj.pose.bones.get(side)
        if pb is not None:
            eye_pts.append(world @ pb.matrix.translation)
    eye_mid = sum(eye_pts, Vector()) / max(len(eye_pts), 1)
    foot_world = _mesh_lowest(arm_obj, foot_region)

    eye_room = Vector((-eye_mid.x, eye_mid.z + SEAT_TOP, eye_mid.y + ANCHOR_Z))
    sb_centre = Vector((0.0, SANDBOX_TOP, 0.0))
    face_room = eye_room + Vector((0.0, -0.04, -0.01))

    stats["eye_above_cushion"] = eye_mid.z
    stats["foot_below_cushion"] = foot_world
    stats["eye_height_in_room"] = eye_room.y
    stats["eye_z_in_room"] = eye_room.z
    stats["eye_dist_to_sandbox"] = (eye_room - sb_centre).length
    stats["face_dist_to_sandbox"] = (face_room - sb_centre).length
    stats["foot_height_in_room"] = foot_world + SEAT_TOP
    stats["cushion_sink"] = cushion_sink
    dump_lowest(10)

    # Report room-space key bone positions (elbows, hands, knees, feet) for QA.
    for bname in ("LowerArm_L", "LowerArm_R", "Hand_L", "Hand_R", "LowerLeg_L", "Foot_L"):
        pb = arm_obj.pose.bones.get(bname)
        if pb is not None:
            v = world @ pb.matrix.translation
            stats[f"room_{bname}"] = (round(-v.x, 4), round(v.z + SEAT_TOP, 4), round(v.y + ANCHOR_Z, 4))

    # Thigh-top clearance probe under the desk (leg-weighted vertices only, z_room < 0.382).
    thigh_top_room = 0.0
    deps = bpy.context.evaluated_depsgraph_get()
    leg_names = {"UpperLeg_L", "UpperLeg_R", "LowerLeg_L", "LowerLeg_R"}
    for ob in bpy.data.objects:
        if ob.type != "MESH":
            continue
        leg_ids = {vg.index for vg in ob.vertex_groups if vg.name in leg_names}
        if not leg_ids:
            continue
        ev = ob.evaluated_get(deps)
        me = ev.to_mesh(preserve_all_data_layers=True, depsgraph=deps)
        mx = ev.matrix_world
        for i, v in enumerate(ob.data.vertices):
            if any(g.group in leg_ids and g.weight > 0.3 for g in v.groups):
                pt = mx @ me.vertices[i].co
                if pt.y + ANCHOR_Z < 0.382:
                    thigh_top_room = max(thigh_top_room, pt.z + SEAT_TOP)
        ev.to_mesh_clear()
    stats["thigh_top_in_room"] = thigh_top_room

    # Absolute posed bounds for clipping checks against the desk plane.
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for pt in _eval_world(arm_obj):
        lo = Vector((min(lo.x, pt.x), min(lo.y, pt.y), min(lo.z, pt.z)))
        hi = Vector((max(hi.x, pt.x), max(hi.y, pt.y), max(hi.z, pt.z)))
    stats["bounds_lo"] = tuple(round(c, 4) for c in lo)
    stats["bounds_hi"] = tuple(round(c, 4) for c in hi)
    return stats


def keyframe_seated_pose(arm_obj) -> None:
    """Author a 1-frame `SeatedPose` action preserving the FK pose exactly.

    NEVER use `bpy.ops.pose.armature_apply()` here: "Apply Pose as Rest" merely
    rewrites the edit bones, so mesh vertex data stays at the T-pose and the
    glTF skin ends up binding identity -> Godot renders the raw T-pose block-
    through-the-chair (diagnosed 2026-11-26 on the side profile shot). Keying
    the pose at frame 1 keeps the original rest/mesh data (and every shape
    key) intact while the animation carries the seated pose into glTF.
    """
    scene = bpy.context.scene
    action = bpy.data.actions.new("SeatedPose")
    arm_obj.animation_data_create()
    arm_obj.animation_data.action = action
    scene.frame_set(1)
    # The armature object itself carries the eye-height scale + cushion rebase.
    arm_obj.keyframe_insert("location", frame=1)
    arm_obj.keyframe_insert("rotation_euler", frame=1)
    arm_obj.keyframe_insert("scale", frame=1)
    pose_bones = {bone for bone, _, _ in POSE_TWISTS}
    for pb in arm_obj.pose.bones:
        if pb.name not in pose_bones:
            continue
        pb.keyframe_insert("location", frame=1)
        pb.keyframe_insert("scale", frame=1)
        rot_channel = "rotation_quaternion" if pb.rotation_mode == "QUATERNION" \
            else "rotation_euler"
        pb.keyframe_insert(rot_channel, frame=1)
    scene.frame_set(1)
    bpy.context.view_layer.update()
    _log(f"keyframed SeatedPose on {len(pose_bones)} bones at frame 1")


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
    # desk slab: top at DESK_TOP, thickness 0.06 m, front face at room z = 0.3782 -> local y = 0.3782 - ANCHOR_Z
    depth = 0.76
    front = 0.3782 - ANCHOR_Z
    _block((1.63, depth, 0.06), (0, front - depth * 0.5, DESK_TOP - SEAT_TOP - 0.03), (0.75, 0.6, 0.45))
    # sandbox diorama on top of the desk: 0.2127² footprint at the desk centre (local y = -ANCHOR_Z)
    _block((0.2127, 0.2127, 0.0048), (0, -ANCHOR_Z, SANDBOX_TOP - SEAT_TOP + 0.0024), (0.3, 0.8, 0.35))

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
        export_animations=True,
        # Keep the armature's ORIGINAL rest (the raw blend file T-pose): the
        # seated pose travels as the 1-frame SeatedPose animation.
        export_rest_position_armature=False,
        export_force_sampling=True,
        export_morph=True,
        export_morph_animation=False,
        export_skins=True,
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
    raw_butt_z = pose_seated(arm)
    stats = measure_and_scale(arm, raw_butt_z)
    for key, value in stats.items():
        _log(f"{key} = {value}")

    if preview_only:
        render_preview(os.path.join(REPO_ROOT, "build", "tmp", "yumeka_preview"), arm)
        return

    # Validation window, then bake and export.
    eye_ok = 0.95 <= stats["eye_height_in_room"] <= 1.08
    thigh_ok = stats["thigh_top_in_room"] < 0.688
    foot_off = stats["foot_height_in_room"]
    _log(f"eye height in room: {stats['eye_height_in_room']:.3f} m (spec 0.95-1.08)")
    _log(f"thigh top in room:  {stats['thigh_top_in_room']:.3f} m (desk underside 0.690)")
    _log(f"foot over floor:    {foot_off:+.3f} m (natural resting; negative digs in)")
    if not eye_ok:
        raise SystemExit("seated eye height out of spec (0.95-1.08 m); adjust POSE_TWISTS")
    if not thigh_ok:
        raise SystemExit("thigh top exceeds desk underside clearance (0.688 m); adjust POSE_TWISTS")

    keyframe_seated_pose(arm)
    export_glb(out_path)
    print("[yumeka-export] DONE")


if __name__ == "__main__":
    main()
