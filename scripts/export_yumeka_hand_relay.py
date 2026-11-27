#!/usr/bin/env blender --background
"""Yumeka foreground relay right-hand GLB exporter for Scalebreaker (Phase 3B-1).

Pipeline (run from the repo root):
    blender --background --python scripts/export_yumeka_hand_relay.py -- --preview
    blender --background --python scripts/export_yumeka_hand_relay.py --

1. Locate YUMEKA_v1.0.4.zip (default ~/Downloads/) and extract YUMEKA_v1.0.4/Blend/Yumeka.blend
   to a temp directory outside the repository (zero licensed assets ever committed).
2. Rebuild the body & clothes materials with the exact same soft matte anime Principled BSDF
   used by `scripts/export_yumeka_seated.py` (2048px packed textures, zero emission).
3. Pose Yumeka's right arm and right hand into a natural single-finger poke gesture:
   - Index finger extended with a gentle organic curve (not stiff 0 deg),
   - Middle, ring, little fingers progressively curled into the palm about their verified
     anatomical flexion axis `local (1, 0, 0)` (negative degrees curl toward palm),
   - Thumb gently tucked beside the curled middle finger with zero palm self-clipping,
   - Slight wrist extension so the fingertip leads cleanly downward.
4. Bake the posed deformation onto the three right-arm meshes (`Yumeka_Body`,
   `Yumeka_Cos_Jacket`, `Yumeka_Cos_Vest_Shirt`), discard all non-arm geometry & torso/shoulder
   spill, keep the full forearm + sleeve cuff + lower upper-arm sleeve seamlessly.
5. Orient the baked right hand in 1:6,667 main-world scale (index finger width ~96-100 m)
   approaching diagonally downward from Yumeka's right shoulder in the southeast sky
   (`APPROACH_DIR_GODOT = (0.32, 0.90, 0.30)`), and shift the origin `(0, 0, 0)` directly
   onto the lowest contact point of the index fingertip pad so Godot placement at
   `(target.x, height, target.z)` is sub-metre exact.
6. Export static `assets/characters/yumeka/Yumeka_hand_relay.glb` (gitignored).
"""

import os
import sys
import tempfile
import zipfile
from math import radians

import bmesh
import bpy
from mathutils import Matrix, Vector

# --------------------------------------------------------------------------- #
# Authoring constants
# --------------------------------------------------------------------------- #

DEFAULT_ZIP = os.path.expanduser("~/Downloads/YUMEKA_v1.0.4.zip")
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DEFAULT_OUT = os.path.join(
    REPO_ROOT, "assets", "characters", "yumeka", "Yumeka_hand_relay.glb"
)

TEXTURE_SIZE = 2048
# Calibrated at 1:6,667 so Yumeka's petite anime index finger reads ~96-100 m wide
# across the intermediate/distal fingertip zone (destruction radius ~110 m).
TARGET_INDEX_WIDTH_M = 96.0

# Approach vector in Godot main-world space (pointing FROM landing spot UP toward
# Yumeka's right shoulder in the south-east sky: +X east, +Y up, +Z south).
# Steep ~20 deg slant keeps the sleeve cuff high above the hand and gives a crisp
# vertical pointing silhouette from downtown street angles.
APPROACH_DIR_GODOT = Vector((0.24, 0.94, 0.24)).normalized()

# Only the three meshes carrying right forearm skin, jacket sleeve, and shirt cuff.
RIGHT_ARM_MESHES = (
    "Yumeka_Body",
    "Yumeka_Cos_Jacket",
    "Yumeka_Cos_Vest_Shirt",
)

RIGHT_ARM_BONES = {
    "UpperArm_R",
    "UpperArm_twist_R",
    "LowerArm_R",
    "LowerArm_twist_R",
    "Hand_R",
    "ThumbProximal_R",
    "ThumbIntermediate_R",
    "ThumbDistal_R",
    "IndexProximal_R",
    "IndexIntermediate_R",
    "IndexDistal_R",
    "MiddleProximal_R",
    "MiddleIntermediate_R",
    "MiddleDistal_R",
    "RingProximal_R",
    "RingIntermediate_R",
    "RingDistal_R",
    "LittleProximal_R",
    "LittleIntermediate_R",
    "LittleDistal_R",
}

TORSO_EXCLUDE_BONES = {"Shoulder_R", "Chest", "Spine", "Hips", "Neck"}

# Rest-space X cutoff along the right arm (-X extends toward hand; elbow is at -0.248,
# wrist at -0.416, fingertip at -0.531). Cutting at -0.19 keeps the full hand, wrist,
# shirt cuff, jacket sleeve, elbow, and lower upper-arm seamlessly with zero shoulder bleed.
ARM_CUTOFF_X = -0.19

# Material map (same matte PBR recipe as export_yumeka_seated.py).
MATERIAL_MAP = {
    "Yumeka_Body": ("Yumeka_body", False),
    "Yumeka_Clothes": ("Yumeka_clothes", False),
}

# Local-axis finger & wrist twists for a natural single-finger poke gesture.
# Verified anatomical flexion axis for all fingers is local (1, 0, 0) with negative
# angles curling smoothly downward toward the palm.
POKE_LOCAL_TWISTS = [
    # Subtle natural wrist angle so the pointing index finger leads cleanly out of the cuff.
    ("Hand_R", (1, 0, 0), 6.0),
    ("Hand_R", (0, 0, 1), -3.0),
    # Index finger: extended cleanly with a soft, natural curve (never a rigid rod).
    ("IndexProximal_R", (1, 0, 0), -4.0),
    ("IndexIntermediate_R", (1, 0, 0), -9.0),
    ("IndexDistal_R", (1, 0, 0), -7.0),
    # Middle, ring, little fingers: cleanly curled into the palm so the index finger dominates.
    ("MiddleProximal_R", (1, 0, 0), -74.0),
    ("MiddleIntermediate_R", (1, 0, 0), -86.0),
    ("MiddleDistal_R", (1, 0, 0), -44.0),
    ("RingProximal_R", (1, 0, 0), -80.0),
    ("RingIntermediate_R", (1, 0, 0), -90.0),
    ("RingDistal_R", (1, 0, 0), -48.0),
    ("LittleProximal_R", (1, 0, 0), -84.0),
    ("LittleIntermediate_R", (1, 0, 0), -92.0),
    ("LittleDistal_R", (1, 0, 0), -50.0),
    # Thumb: adducted inward (-Z) and curled across the palm beside the curled middle finger.
    ("ThumbProximal_R", (0, 0, 1), -34.0),
    ("ThumbProximal_R", (1, 0, 0), -40.0),
    ("ThumbIntermediate_R", (1, 0, 0), -44.0),
    ("ThumbDistal_R", (1, 0, 0), -30.0),
]


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

def _log(msg: str) -> None:
    print(f"[yumeka-hand-relay] {msg}", flush=True)


def locate_blend(override: str) -> str:
    if override and override.endswith(".blend"):
        return override
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
    return inner


def _texture_for(image_substring: str) -> bpy.types.Image:
    for img in bpy.data.images:
        if image_substring.lower() in img.name.lower():
            if img.size[0] > TEXTURE_SIZE:
                try:
                    img.scale(TEXTURE_SIZE, TEXTURE_SIZE)
                except Exception as exc:  # noqa: BLE001
                    _log(f"texture rescale skipped for {img.name}: {exc}")
            return img
    raise SystemExit(f"no packed image matches '{image_substring}'")


def rebuild_materials() -> None:
    cache = {}
    for mat in list(bpy.data.materials):
        name = mat.name
        if name not in MATERIAL_MAP:
            continue
        image_sub, use_alpha = MATERIAL_MAP[name]
        image = _texture_for(image_sub)

        fresh = bpy.data.materials.new(name + "_Relay")
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
        # Unified soft matte anime look matching Yumeka_seated.glb.
        bsdf.inputs["Roughness"].default_value = 0.88
        bsdf.inputs["Metallic"].default_value = 0.0
        bsdf.inputs["Specular IOR Level"].default_value = 0.35
        tree.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
        cache[name] = fresh
        _log(f"material rebuilt: {name} (tex={image.name})")

    for ob in bpy.data.objects:
        if ob.type != "MESH":
            continue
        for slot in ob.material_slots:
            if slot.material is not None and slot.material.name in cache:
                slot.material = cache[slot.material.name]

    for old_name, fresh in cache.items():
        fresh.name = old_name
        for mat in list(bpy.data.materials):
            if mat != fresh and mat.users == 0:
                bpy.data.materials.remove(mat)


def bend_local(arm_obj: bpy.types.Object, bone_name: str, local_axis, deg: float) -> None:
    pb = arm_obj.pose.bones.get(bone_name)
    if pb is None:
        raise SystemExit(f"missing pose bone: {bone_name}")
    cur = pb.matrix.copy()
    head = cur.translation
    arm_axis = (cur.to_3x3().normalized() @ Vector(local_axis)).normalized()
    rot = Matrix.Rotation(radians(deg), 4, arm_axis)
    pb.matrix = Matrix.Translation(head) @ rot @ Matrix.Translation(-head) @ cur
    bpy.context.view_layer.update()


def pose_finger_poke(arm_obj: bpy.types.Object) -> None:
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="POSE")
    for pb in arm_obj.pose.bones:
        pb.location = (0.0, 0.0, 0.0)
        pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        pb.rotation_euler = (0.0, 0.0, 0.0)
        pb.scale = (1.0, 1.0, 1.0)
    bpy.context.view_layer.update()
    for bone_name, local_axis, deg in POKE_LOCAL_TWISTS:
        bend_local(arm_obj, bone_name, local_axis, deg)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.context.view_layer.update()
    _log(f"posed single-finger poke on {len(POKE_LOCAL_TWISTS)} local twists")


def drop_unused_objects(arm_obj: bpy.types.Object) -> list[bpy.types.Object]:
    keep_names = set(RIGHT_ARM_MESHES)
    kept = []
    for ob in list(bpy.data.objects):
        if ob == arm_obj:
            continue
        if ob.type == "MESH" and ob.name in keep_names:
            kept.append(ob)
        else:
            bpy.data.objects.remove(ob, do_unlink=True)
    if len(kept) != len(RIGHT_ARM_MESHES):
        raise SystemExit(f"expected meshes {RIGHT_ARM_MESHES}, found {[o.name for o in kept]}")
    return kept


def bake_and_extract_right_arm(
    arm_obj: bpy.types.Object, meshes: list[bpy.types.Object]
) -> tuple[list[bpy.types.Object], Vector, float, dict]:
    """Evaluate posed right arm, prune non-arm faces, measure finger width, and bake static meshes."""
    deps = bpy.context.evaluated_depsgraph_get()
    baked_objs: list[bpy.types.Object] = []
    index_distal_pts: list[Vector] = []
    index_mid_pts: list[Vector] = []
    curled_pts: list[Vector] = []
    curled_groups = {
        "MiddleProximal_R", "MiddleIntermediate_R", "MiddleDistal_R",
        "RingProximal_R", "RingIntermediate_R", "RingDistal_R",
        "LittleProximal_R", "LittleIntermediate_R", "LittleDistal_R",
        "ThumbIntermediate_R", "ThumbDistal_R",
    }

    for src in meshes:
        # Capture rest-space eligibility mask BEFORE baking deformation.
        arm_gids = {vg.index for vg in src.vertex_groups if vg.name in RIGHT_ARM_BONES}
        torso_gids = {vg.index for vg in src.vertex_groups if vg.name in TORSO_EXCLUDE_BONES}
        idx_dist_gid = src.vertex_groups.get("IndexDistal_R").index if src.vertex_groups.get("IndexDistal_R") else -1
        idx_mid_gids = {
            vg.index for vg in src.vertex_groups
            if vg.name in {"IndexIntermediate_R", "IndexDistal_R"}
        }
        curled_gids = {vg.index for vg in src.vertex_groups if vg.name in curled_groups}

        keep_vert = [False] * len(src.data.vertices)
        is_idx_dist = [False] * len(src.data.vertices)
        is_idx_mid = [False] * len(src.data.vertices)
        is_curled = [False] * len(src.data.vertices)

        for i, v in enumerate(src.data.vertices):
            wa = sum(g.weight for g in v.groups if g.group in arm_gids)
            wt = sum(g.weight for g in v.groups if g.group in torso_gids)
            if wa >= 0.45 and wt < 0.25 and v.co.x <= ARM_CUTOFF_X:
                keep_vert[i] = True
            if src.name == "Yumeka_Body":
                if idx_dist_gid >= 0 and any(g.group == idx_dist_gid and g.weight > 0.5 for g in v.groups):
                    is_idx_dist[i] = True
                if sum(g.weight for g in v.groups if g.group in idx_mid_gids) > 0.5:
                    is_idx_mid[i] = True
                if sum(g.weight for g in v.groups if g.group in curled_gids) > 0.5:
                    is_curled[i] = True

        # Evaluate deformed mesh (Armature + Smooth-by-Angle applied cleanly).
        ev = src.evaluated_get(deps)
        eval_mesh = bpy.data.meshes.new_from_object(
            ev, preserve_all_data_layers=True, depsgraph=deps
        )
        # Apply object world transform directly into vertices so everything shares world space.
        eval_mesh.transform(ev.matrix_world)

        if len(eval_mesh.vertices) != len(keep_vert):
            raise SystemExit(
                f"vertex count mismatch on {src.name}: {len(eval_mesh.vertices)} vs {len(keep_vert)}"
            )

        if src.name == "Yumeka_Body":
            for i, v in enumerate(eval_mesh.vertices):
                if is_idx_dist[i]:
                    index_distal_pts.append(v.co.copy())
                if is_idx_mid[i]:
                    index_mid_pts.append(v.co.copy())
                if is_curled[i]:
                    curled_pts.append(v.co.copy())

        # Remove every non-right-arm face cleanly with bmesh.
        bm = bmesh.new()
        bm.from_mesh(eval_mesh)
        bm.verts.ensure_lookup_table()
        bm.faces.ensure_lookup_table()
        drop_faces = [f for f in bm.faces if not all(keep_vert[v.index] for v in f.verts)]
        bmesh.ops.delete(bm, geom=drop_faces, context="FACES")
        # Remove loose verts / edges left behind.
        loose_verts = [v for v in bm.verts if not v.link_faces]
        if loose_verts:
            bmesh.ops.delete(bm, geom=loose_verts, context="VERTS")

        # Pull Yumeka's oversized cardigan/shirt moe-sleeves naturally back to the wrist
        # (as gravity does when reaching downward) and cinch the 11 cm bell flare so the
        # cuff frames her bare wrist cleanly without ringing the hand like a hollow pipe.
        if src.name in ("Yumeka_Cos_Jacket", "Yumeka_Cos_Vest_Shirt"):
            is_jacket = src.name == "Yumeka_Cos_Jacket"
            pull_back = 0.056 if is_jacket else 0.044
            base_r = 0.036 if is_jacket else 0.027
            flare_keep = 0.20 if is_jacket else 0.18
            arm_cy, arm_cz = 0.034, 1.058
            for v in bm.verts:
                v.co.x += pull_back
                dy = v.co.y - arm_cy
                dz = v.co.z - arm_cz
                r = (dy * dy + dz * dz) ** 0.5
                if r > base_r and r > 1e-6:
                    r_new = base_r + (r - base_r) * flare_keep
                    ratio = r_new / r
                    v.co.y = arm_cy + dy * ratio
                    v.co.z = arm_cz + dz * ratio

        bm.to_mesh(eval_mesh)
        bm.free()

        # Drop shape keys and vertex groups on the static relay mesh.
        baked = bpy.data.objects.new(src.name + "_Relay", eval_mesh)
        bpy.context.scene.collection.objects.link(baked)
        baked_objs.append(baked)
        _log(
            f"baked {baked.name}: {len(eval_mesh.vertices)} verts, "
            f"{len(eval_mesh.polygons)} polys"
        )

    # Read forearm-to-knuckle axis so the forearm plunges steeply down along APPROACH_DIR
    # while the gently curved index finger extends naturally downward out of the palm.
    pb_arm = arm_obj.pose.bones["LowerArm_R"]
    pb_prox = arm_obj.pose.bones["IndexProximal_R"]
    pb_dist = arm_obj.pose.bones["IndexDistal_R"]
    arm_start = arm_obj.matrix_world @ pb_arm.head
    arm_end = arm_obj.matrix_world @ pb_prox.head
    arm_dir_raw = (arm_end - arm_start).normalized()
    finger_start = arm_obj.matrix_world @ pb_prox.head
    finger_end = arm_obj.matrix_world @ pb_dist.tail
    finger_dir_raw = (finger_end - finger_start).normalized()

    # Measure perpendicular width of the index finger across Intermediate+Distal in raw metres.
    # Back-of-hand normal in posed space is roughly +Z; width axis is cross(finger_dir, +Z).
    width_axis = finger_dir_raw.cross(Vector((0.0, 0.0, 1.0))).normalized()
    w_proj = [p.dot(width_axis) for p in index_mid_pts]
    raw_finger_width = max(w_proj) - min(w_proj)
    scale = TARGET_INDEX_WIDTH_M / raw_finger_width

    # Remove original rigged meshes and armature now that baked static copies exist.
    for src in meshes:
        bpy.data.objects.remove(src, do_unlink=True)
    bpy.data.objects.remove(arm_obj, do_unlink=True)

    # Compute rotation aligning the posed right forearm & hand to the steep southeast poke.
    # glTF exports Blender (bx, by, bz) -> Godot (bx, bz, -by), so Godot (gx, gy, gz) maps to
    # Blender (gx, -gz, gy).
    def godot_to_blender(v: Vector) -> Vector:
        return Vector((v.x, -v.z, v.y))

    # Desired forearm/pointing axis in Godot: steeply DOWN along -APPROACH_DIR_GODOT.
    d_finger = godot_to_blender(-APPROACH_DIR_GODOT).normalized()
    # Desired thumb side in Godot: WEST / inward toward Yumeka's chest (-X, slightly +Z).
    d_thumb_hint = godot_to_blender(Vector((-1.0, 0.0, 0.25))).normalized()
    d_back = d_finger.cross(d_thumb_hint).normalized()
    d_thumb = d_back.cross(d_finger).normalized()

    # Source basis in posed Blender space anchored on the forearm axis:
    s_finger = arm_dir_raw
    s_back = s_finger.cross(Vector((0.0, -1.0, 0.0))).normalized()
    s_thumb = s_back.cross(s_finger).normalized()

    src_basis = Matrix((s_finger, s_thumb, s_back)).transposed()  # columns = source axes
    dst_basis = Matrix((d_finger, d_thumb, d_back)).transposed()  # columns = target axes
    rot_3x3 = dst_basis @ src_basis.transposed()
    rot_4x4 = rot_3x3.to_4x4()

    # Transform all baked meshes by (scale * rot), then rebase origin to exact fingertip contact!
    scale_rot = Matrix.Scale(scale, 4) @ rot_4x4
    xformed_tip = [scale_rot @ p for p in index_distal_pts]
    # Lowest Z in Blender == lowest Y (ground contact) in Godot!
    lowest_tip = min(xformed_tip, key=lambda p: p.z)
    # Center X/Y of fingertip pad around the lowest 20% of distal vertices for dead-center contact.
    pad_z_cut = lowest_tip.z + 14.0
    pad_pts = [p for p in xformed_tip if p.z <= pad_z_cut]
    pad_cx = sum(p.x for p in pad_pts) / len(pad_pts)
    pad_cy = sum(p.y for p in pad_pts) / len(pad_pts)
    tip_origin = Vector((pad_cx, pad_cy, lowest_tip.z))

    final_xf = Matrix.Translation(-tip_origin) @ scale_rot
    for ob in baked_objs:
        ob.data.transform(final_xf)
        ob.data.update()

    # QA stats in Godot coordinates: (x, y_up=z_bl, z_south=-y_bl)
    all_pts = []
    for ob in baked_objs:
        for v in ob.data.vertices:
            all_pts.append(Vector((v.co.x, v.co.z, -v.co.y)))
    tip_godot = [Vector((p.x, p.z, -p.y)) for p in [final_xf @ q for q in index_distal_pts]]
    curled_godot = [Vector((p.x, p.z, -p.y)) for p in [final_xf @ q for q in curled_pts]]

    stats = {
        "raw_index_width_m": round(raw_finger_width, 5),
        "world_scale": round(scale, 1),
        "final_index_width_m": round(raw_finger_width * scale, 1),
        "tip_min_y_m": round(min(p.y for p in tip_godot), 3),
        "tip_center_xz_m": (
            round(sum(p.x for p in tip_godot) / len(tip_godot), 1),
            round(sum(p.z for p in tip_godot) / len(tip_godot), 1),
        ),
        "curled_fingers_min_y_m": round(min(p.y for p in curled_godot), 1),
        "bounds_godot_min": tuple(
            round(min(p[i] for p in all_pts), 1) for i in range(3)
        ),
        "bounds_godot_max": tuple(
            round(max(p[i] for p in all_pts), 1) for i in range(3)
        ),
        "total_polys": sum(len(o.data.polygons) for o in baked_objs),
        "total_verts": sum(len(o.data.vertices) for o in baked_objs),
    }
    return baked_objs, tip_origin, scale, stats


def export_glb(path: str, objs: list[bpy.types.Object]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    for ob in objs:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.preferences.addon_enable(module="io_scene_gltf2")
    bpy.ops.export_scene.gltf(
        filepath=path,
        use_selection=True,
        export_format="GLB",
        export_animations=False,
        export_morph=False,
        export_skins=False,
        export_apply=True,
        export_extras=False,
        export_yup=True,
    )
    size_mb = os.path.getsize(path) / (1024 * 1024)
    _log(f"exported {path} ({size_mb:.2f} MB)")


def render_preview(out_dir: str, objs: list[bpy.types.Object]) -> None:
    """Quick Blender EEVEE silhouette preview of the posed hand relative to a 110 m circle."""
    scene = bpy.context.scene
    bpy.ops.mesh.primitive_cylinder_add(radius=110.0, depth=2.0, location=(0.0, 0.0, -1.0))
    disc = bpy.context.active_object
    disc.name = "PreviewZone"
    mat = bpy.data.materials.new("zone")
    mat.use_nodes = False
    mat.diffuse_color = (0.95, 0.55, 0.15, 1.0)
    disc.data.materials.append(mat)

    sun_data = bpy.data.lights.new("prev_sun", "SUN")
    sun_data.energy = 2.8
    sun = bpy.data.objects.new("prev_sun", sun_data)
    scene.collection.objects.link(sun)
    sun.rotation_euler = (radians(48), radians(15), radians(35))

    fill_data = bpy.data.lights.new("prev_fill", "SUN")
    fill_data.energy = 1.2
    fill = bpy.data.objects.new("prev_fill", fill_data)
    scene.collection.objects.link(fill)
    fill.rotation_euler = (radians(115), radians(-25), radians(160))

    if scene.world is None:
        scene.world = bpy.data.worlds.new("world")
    scene.world.use_nodes = False
    scene.world.color = (0.32, 0.36, 0.44)

    cam_data = bpy.data.cameras.new("prev_cam")
    cam_data.lens = 35
    cam_data.clip_start = 1.0
    cam_data.clip_end = 10000.0
    cam = bpy.data.objects.new("prev_cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 800
    scene.render.resolution_y = 800

    # Blender coords: X east, Y north (-Z Godot), Z up (+Y Godot).
    shots = {
        "hand_front_north": (Vector((-120.0, 820.0, 260.0)), Vector((80.0, -60.0, 340.0))),
        "hand_side_west": (Vector((-860.0, 40.0, 240.0)), Vector((80.0, -80.0, 340.0))),
    }
    os.makedirs(out_dir, exist_ok=True)
    for name, (pos, aim) in shots.items():
        cam.location = pos
        cam.rotation_euler = (pos - aim).to_track_quat("Z", "Y").to_euler()
        scene.render.filepath = os.path.join(out_dir, f"{name}.png")
        bpy.ops.render.render(write_still=True)
        _log(f"preview saved: {scene.render.filepath}")


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

    blend_path = locate_blend(zip_override)
    _log(f"opening {blend_path}")
    bpy.ops.wm.open_mainfile(filepath=blend_path)
    arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")

    meshes = drop_unused_objects(arm)
    rebuild_materials()
    pose_finger_poke(arm)
    baked, _, _, stats = bake_and_extract_right_arm(arm, meshes)
    for k, v in stats.items():
        _log(f"{k} = {v}")

    if stats["curled_fingers_min_y_m"] < 80.0:
        raise SystemExit(
            f"curled fingers too close to ground ({stats['curled_fingers_min_y_m']} m)"
        )
    if abs(stats["tip_min_y_m"]) > 0.1:
        raise SystemExit(f"fingertip origin misaligned: tip_min_y_m={stats['tip_min_y_m']}")

    if preview_only:
        render_preview(os.path.join(REPO_ROOT, "build", "tmp", "yumeka_hand_preview"), baked)
        return

    export_glb(out_path, baked)
    print("[yumeka-hand-relay] DONE")


if __name__ == "__main__":
    main()
