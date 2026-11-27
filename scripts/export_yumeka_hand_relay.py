#!/usr/bin/env blender --background
"""Yumeka foreground relay FULL right-arm GLB exporter for Scalebreaker (Phase 3B-1).

Pipeline (run from the repo root):
    blender --background --python scripts/export_yumeka_hand_relay.py --

1. Locate YUMEKA_v1.0.4.zip (default ~/Downloads/) and extract YUMEKA_v1.0.4/Blend/Yumeka.blend
   to a temp directory outside the repository (zero licensed assets ever committed).
2. Rebuild `Yumeka_Body` & `Yumeka_Clothes` with the exact same soft matte anime
   Principled BSDF used by `scripts/export_yumeka_seated.py` (2048px packed textures).
3. Pose Yumeka's complete right arm into a natural reaching single-finger poke:
   - Subtle elbow arch (`LowerArm_R -14 deg`) and wrist flexion (`Hand_R -18 deg`) so the
     arm reaches cleanly from her real right shoulder over the southern harbour while the
     extended index fingertip descends steeply onto the city block,
   - Index finger extended with a gentle curve (`-4/-9/-7 deg`),
   - Middle, ring, little fingers tightly curled into the palm about `local (1, 0, 0)`,
   - Thumb adducted inward (`local Z -34 deg`) and tucked cleanly across the palm.
4. Keep the COMPLETE right arm (`Yumeka_Body`, `Yumeka_Cos_Jacket`, `Yumeka_Cos_Vest_Shirt`)
   all the way up to the shoulder joint (`UpperArm_R.head`) at the EXACT true 1:6,667 scale
   matching `Yumeka_seated.glb` (`BODY_SCALE = 1.05 * 6666.67 = 7000.0`, no stretch!).
   Keep the upper arm & shoulder seam 100% unmodified so it joins background Yumeka's right
   shoulder seamlessly; only gently tidy the loose lower cuff right around the wrist.
5. Align to canonical Godot local axes for zero-effort runtime shoulder alignment:
   - Origin `(0, 0, 0)`       == index fingertip pad contact point
   - Local `+Z`               == fingertip -> `UpperArm_R.head` (`(0, 0, +ARM_CHORD_LENGTH)`)
   - Local `+Y`               == dorsal / skyward (back of hand & elbow arch)
   - Local `+X`               == outer-right / little-finger side (`-X` == thumb / chest side)
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

# Exact 1:6,667 world scale matching `export_yumeka_seated.py::BODY_SCALE = 1.05`
# and `skybox_bedroom.gd::SKY_SCALE = 1.0 / 6666.67` (zero distortion vs background body).
BODY_SCALE = 1.05
SKY_INV_SCALE = 6666.67
WORLD_SCALE = BODY_SCALE * SKY_INV_SCALE  # 7000.0035

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

# Rest-space X cutoff right over the shoulder joint (`UpperArm_R.head` is at -0.0928):
# captures the complete upper-arm brown cardigan sleeve seamlessly with zero chest bleed.
ARM_CUTOFF_X = -0.075

MATERIAL_MAP = {
    "Yumeka_Body": ("Yumeka_body", False),
    "Yumeka_Clothes": ("Yumeka_clothes", False),
}

# Local-axis arm, wrist & finger twists for a graceful reaching single-finger poke.
# Verified anatomical flexion axis for elbow/wrist/fingers is local (1, 0, 0) where
# negative angles flex downward toward the palm (creating a natural upward elbow arch
# relative to the fingertip-to-shoulder chord and pitching the fingertip steeply down).
POKE_LOCAL_TWISTS = [
    # Graceful natural elbow arch & downward wrist tilt so the forearm & curled hand
    # stay cleanly above downtown skyscrapers while the fingertip lands steeply first.
    ("LowerArm_R", (1, 0, 0), -20.0),
    ("Hand_R", (1, 0, 0), -16.0),
    ("Hand_R", (0, 0, 1), -3.0),
    # Index finger: extended cleanly with a soft organic curve.
    ("IndexProximal_R", (1, 0, 0), -4.0),
    ("IndexIntermediate_R", (1, 0, 0), -8.0),
    ("IndexDistal_R", (1, 0, 0), -6.0),
    # Middle, ring, little fingers: tightly curled into the palm.
    ("MiddleProximal_R", (1, 0, 0), -78.0),
    ("MiddleIntermediate_R", (1, 0, 0), -90.0),
    ("MiddleDistal_R", (1, 0, 0), -46.0),
    ("RingProximal_R", (1, 0, 0), -84.0),
    ("RingIntermediate_R", (1, 0, 0), -94.0),
    ("RingDistal_R", (1, 0, 0), -50.0),
    ("LittleProximal_R", (1, 0, 0), -88.0),
    ("LittleIntermediate_R", (1, 0, 0), -96.0),
    ("LittleDistal_R", (1, 0, 0), -52.0),
    # Thumb: adducted across the palm (-Z) and gently elevated so it rests cleanly
    # against the curled middle finger well clear of city rooftops.
    ("ThumbProximal_R", (0, 0, 1), -28.0),
    ("ThumbProximal_R", (1, 0, 0), 16.0),
    ("ThumbIntermediate_R", (0, 0, 1), -26.0),
    ("ThumbDistal_R", (0, 0, 1), -20.0),
]


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

def _log(msg: str) -> None:
    print(f"[yumeka-hand-relay] {msg}", flush=True)


def _smoothstep(edge0: float, edge1: float, x: float) -> float:
    t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3.0 - 2.0 * t)


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
    _log(f"posed reaching single-finger poke on {len(POKE_LOCAL_TWISTS)} local twists")


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


def bake_and_extract_full_right_arm(
    arm_obj: bpy.types.Object, meshes: list[bpy.types.Object]
) -> tuple[list[bpy.types.Object], dict]:
    """Bake full right arm from UpperArm_R shoulder cap to index fingertip at true 1:6,667 scale,
    oriented into canonical Godot axes (+Z toward shoulder, +Y dorsal/up, +X outer-right)."""
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

    # Posed bone landmarks in Blender world space (before rebasing).
    pb_ua = arm_obj.pose.bones["UpperArm_R"]
    pb_la = arm_obj.pose.bones["LowerArm_R"]
    pb_hand = arm_obj.pose.bones["Hand_R"]
    pb_idx_prox = arm_obj.pose.bones["IndexProximal_R"]
    pb_idx_dist = arm_obj.pose.bones["IndexDistal_R"]
    shoulder_raw = arm_obj.matrix_world @ pb_ua.head
    elbow_raw = arm_obj.matrix_world @ pb_la.head
    wrist_raw = arm_obj.matrix_world @ pb_hand.head
    forearm_dir = (wrist_raw - elbow_raw).normalized()

    for src in meshes:
        arm_gids = {vg.index for vg in src.vertex_groups if vg.name in RIGHT_ARM_BONES}
        idx_dist_gid = (
            src.vertex_groups.get("IndexDistal_R").index
            if src.vertex_groups.get("IndexDistal_R")
            else -1
        )
        idx_mid_gids = {
            vg.index for vg in src.vertex_groups
            if vg.name in {"IndexIntermediate_R", "IndexDistal_R"}
        }
        curled_gids = {vg.index for vg in src.vertex_groups if vg.name in curled_groups}

        keep_vert = [False] * len(src.data.vertices)
        rest_x = [v.co.x for v in src.data.vertices]
        is_idx_dist = [False] * len(src.data.vertices)
        is_idx_mid = [False] * len(src.data.vertices)
        is_curled = [False] * len(src.data.vertices)

        for i, v in enumerate(src.data.vertices):
            wa = sum(g.weight for g in v.groups if g.group in arm_gids)
            if wa >= 0.25 and v.co.x <= ARM_CUTOFF_X:
                keep_vert[i] = True
            if src.name == "Yumeka_Body":
                if idx_dist_gid >= 0 and any(
                    g.group == idx_dist_gid and g.weight > 0.5 for g in v.groups
                ):
                    is_idx_dist[i] = True
                if sum(g.weight for g in v.groups if g.group in idx_mid_gids) > 0.5:
                    is_idx_mid[i] = True
                if sum(g.weight for g in v.groups if g.group in curled_gids) > 0.5:
                    is_curled[i] = True

        ev = src.evaluated_get(deps)
        eval_mesh = bpy.data.meshes.new_from_object(
            ev, preserve_all_data_layers=True, depsgraph=deps
        )
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

        # Gently tidy ONLY the oversized lower wrist cuff overhang (rest_x < -0.34),
        # leaving the upper arm & shoulder seam (rest_x >= -0.26) 100% untouched so it
        # connects seamlessly onto background Yumeka's cardigan shoulder.
        if src.name in ("Yumeka_Cos_Jacket", "Yumeka_Cos_Vest_Shirt"):
            is_jacket = src.name == "Yumeka_Cos_Jacket"
            pull_max = 0.036 if is_jacket else 0.028
            base_r = 0.042 if is_jacket else 0.030
            flare_keep = 0.24 if is_jacket else 0.22
            for i, v in enumerate(eval_mesh.vertices):
                if not keep_vert[i]:
                    continue
                t = _smoothstep(-0.32, -0.43, rest_x[i])
                if t <= 0.0:
                    continue
                # Pull cuff smoothly back along posed forearm axis toward elbow.
                v.co -= forearm_dir * (pull_max * t)
                # Cinch extreme bell flare around the posed forearm centerline.
                rel = v.co - elbow_raw
                along = rel.dot(forearm_dir)
                radial = rel - forearm_dir * along
                r = radial.length
                if r > base_r and r > 1e-6:
                    r_target = base_r + (r - base_r) * flare_keep
                    r_new = r + (r_target - r) * t
                    v.co = elbow_raw + forearm_dir * along + radial * (r_new / r)

        bm = bmesh.new()
        bm.from_mesh(eval_mesh)
        bm.verts.ensure_lookup_table()
        bm.faces.ensure_lookup_table()
        drop_faces = [f for f in bm.faces if not all(keep_vert[v.index] for v in f.verts)]
        bmesh.ops.delete(bm, geom=drop_faces, context="FACES")
        loose_verts = [v for v in bm.verts if not v.link_faces]
        if loose_verts:
            bmesh.ops.delete(bm, geom=loose_verts, context="VERTS")
        bm.to_mesh(eval_mesh)
        bm.free()

        baked = bpy.data.objects.new(src.name + "_Relay", eval_mesh)
        bpy.context.scene.collection.objects.link(baked)
        baked_objs.append(baked)
        _log(
            f"baked {baked.name}: {len(eval_mesh.vertices)} verts, "
            f"{len(eval_mesh.polygons)} polys"
        )

    # Measure true index finger width at 1:6,667 scale.
    finger_dir_raw = (
        (arm_obj.matrix_world @ pb_idx_dist.tail) - (arm_obj.matrix_world @ pb_idx_prox.head)
    ).normalized()
    width_axis = finger_dir_raw.cross(Vector((0.0, 0.0, 1.0))).normalized()
    w_proj = [p.dot(width_axis) for p in index_mid_pts]
    raw_finger_width = max(w_proj) - min(w_proj)

    # Compute fingertip pad contact point: most-distal tip of IndexDistal_R along
    # the vector away from the shoulder (and slightly toward the ventral pad -Z).
    approx_dir = (
        sum(index_distal_pts, Vector()) / len(index_distal_pts) - shoulder_raw
    ).normalized()
    pad_score = [p.dot(approx_dir) - 0.25 * p.z for p in index_distal_pts]
    best_score = max(pad_score)
    pad_pts = [p for p, sc in zip(index_distal_pts, pad_score) if sc >= best_score - 0.0025]
    tip_raw = sum(pad_pts, Vector()) / len(pad_pts)

    # Remove original rigged meshes & armature now that static copies are baked.
    for src in meshes:
        bpy.data.objects.remove(src, do_unlink=True)
    bpy.data.objects.remove(arm_obj, do_unlink=True)

    # Canonical Godot local frame:
    #   +Z (Godot) -> (0, -1, 0) in Blender : fingertip (0,0,0) -> shoulder UpperArm_R.head
    #   +Y (Godot) -> (0,  0, 1) in Blender : dorsal / back of hand / elbow arch
    #   +X (Godot) -> (1,  0, 0) in Blender : outer-right / little-finger side
    src_z = (shoulder_raw - tip_raw).normalized()
    src_x = Vector((0.0, 0.0, 1.0)).cross(src_z).normalized()  # +Y in Blender == little finger
    src_y = src_z.cross(src_x).normalized()                    # +Z in Blender == dorsal/up

    dst_x = Vector((1.0, 0.0, 0.0))
    dst_y = Vector((0.0, 0.0, 1.0))
    dst_z = Vector((0.0, -1.0, 0.0))

    src_basis = Matrix((src_x, src_y, src_z)).transposed()
    dst_basis = Matrix((dst_x, dst_y, dst_z)).transposed()
    rot_4x4 = (dst_basis @ src_basis.transposed()).to_4x4()

    # Rebase origin to exact fingertip contact `tip_raw` and apply true 1:6,667 scale!
    final_xf = Matrix.Scale(WORLD_SCALE, 4) @ rot_4x4 @ Matrix.Translation(-tip_raw)
    for ob in baked_objs:
        ob.data.transform(final_xf)
        ob.data.update()

    # Convert QA landmarks to Godot coordinates: (x, y_up=z_bl, z_back=-y_bl).
    def to_godot(p: Vector) -> Vector:
        q = final_xf @ p
        return Vector((q.x, q.z, -q.y))

    tip_g = to_godot(tip_raw)
    shoulder_g = to_godot(shoulder_raw)
    elbow_g = to_godot(elbow_raw)
    wrist_g = to_godot(wrist_raw)
    all_g = [Vector((v.co.x, v.co.z, -v.co.y)) for ob in baked_objs for v in ob.data.vertices]
    curled_g = [to_godot(p) for p in curled_pts]
    # Check approximate world clearance of curled palm/thumb when aimed at downtown (~15.1 deg elevation).
    curled_world_y = [p.z * 0.261 + p.y * 0.965 for p in curled_g]

    stats = {
        "world_scale": round(WORLD_SCALE, 2),
        "raw_index_width_m": round(raw_finger_width, 5),
        "true_index_width_m": round(raw_finger_width * WORLD_SCALE, 1),
        "arm_chord_length_m": round(shoulder_g.z, 1),
        "tip_godot": tuple(round(c, 2) for c in tip_g),
        "wrist_godot": tuple(round(c, 1) for c in wrist_g),
        "elbow_godot": tuple(round(c, 1) for c in elbow_g),
        "shoulder_godot": tuple(round(c, 1) for c in shoulder_g),
        "curled_min_z_m": round(min(p.z for p in curled_g), 1),
        "curled_min_world_y_downtown_m": round(min(curled_world_y), 1),
        "bounds_godot_min": tuple(round(min(p[i] for p in all_g), 1) for i in range(3)),
        "bounds_godot_max": tuple(round(max(p[i] for p in all_g), 1) for i in range(3)),
        "total_polys": sum(len(o.data.polygons) for o in baked_objs),
        "total_verts": sum(len(o.data.vertices) for o in baked_objs),
    }
    return baked_objs, stats


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


# --------------------------------------------------------------------------- #
# Entry point
# --------------------------------------------------------------------------- #

def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    zip_override = ""
    out_path = DEFAULT_OUT
    it = iter(argv)
    for arg in it:
        if arg == "--zip":
            zip_override = next(it, "")
        elif arg == "--out":
            out_path = next(it, DEFAULT_OUT)

    blend_path = locate_blend(zip_override)
    _log(f"opening {blend_path}")
    bpy.ops.wm.open_mainfile(filepath=blend_path)
    arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")

    meshes = drop_unused_objects(arm)
    rebuild_materials()
    pose_finger_poke(arm)
    baked, stats = bake_and_extract_full_right_arm(arm, meshes)
    for k, v in stats.items():
        _log(f"{k} = {v}")

    if abs(stats["shoulder_godot"][0]) > 1.0 or abs(stats["shoulder_godot"][1]) > 1.0:
        raise SystemExit(f"shoulder not aligned to +Z axis: {stats['shoulder_godot']}")
    if stats["arm_chord_length_m"] < 2400.0 or stats["arm_chord_length_m"] > 3400.0:
        raise SystemExit(f"unexpected 1:6,667 arm chord length: {stats['arm_chord_length_m']} m")

    export_glb(out_path, baked)
    print("[yumeka-hand-relay] DONE")


if __name__ == "__main__":
    main()
