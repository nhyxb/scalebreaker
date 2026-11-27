#!/usr/bin/env blender --background
"""Yumeka foreground relay RIGGED right-arm GLB exporter for Scalebreaker (Phase 3B-1/3B-2).

Pipeline (run from the repo root):
    blender --background --python scripts/export_yumeka_hand_relay.py --

1. Locate YUMEKA_v1.0.4.zip (default ~/Downloads/) and extract YUMEKA_v1.0.4/Blend/Yumeka.blend
   to a temp directory outside the repository (zero licensed assets ever committed).
2. Rebuild `Yumeka_Body` & `Yumeka_Clothes` with the exact same soft matte anime
   Principled BSDF used by `scripts/export_yumeka_seated.py` (2048px packed textures).
3. Keep ONLY the complete right-arm meshes (`Yumeka_Body`, `Yumeka_Cos_Jacket`,
   `Yumeka_Cos_Vest_Shirt`) trimmed cleanly at the shoulder seam (`rest_x <= -0.075`)
   and prune all shape keys. Gently tidy ONLY the oversized lower wrist cuff overhang
   in rest pose so the palm/fingers read clearly without hollow bell-sleeve clipping,
   while keeping the upper arm & shoulder seam 100% unmodified.
4. Keep ONLY the 20-bone right-arm skeleton chain (`UpperArm_R`, `UpperArm_twist_R`,
   `LowerArm_R`, `LowerArm_twist_R`, `Hand_R`, and all 15 right-hand finger bones)
   with clean normalized skinning weights (shoulder transition weights folded onto
   `UpperArm_R`, max 4 influences per vertex).
5. Rebase BOTH edit bones and rest-pose mesh vertices by the exact similarity
   transform `p -> (p - UpperArm_R.head) * WORLD_SCALE` (`1.05 * 6666.67 = 7000.0035`,
   matching `Yumeka_seated.glb` at true 1:6,667 scale) WITHOUT calling `armature_apply()`:
   - Armature root & `UpperArm_R.head` sit at exact `(0, 0, 0)` so Godot anchors
     the foreground arm root directly onto `get_right_shoulder_main_world_pos()`;
   - Clean T-pose rest & bone rolls are preserved verbatim so runtime analytical
     2-Bone IK and gesture blending (`local (1, 0, 0)` flexion) work seamlessly
     across `finger_poke` and future 3B-2 hand events (drag/palm/pinch).
6. Export rigged `assets/characters/yumeka/Yumeka_hand_relay.glb` (gitignored).
"""

import os
import sys
import tempfile
import zipfile

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
        raise SystemExit(
            f"expected meshes {RIGHT_ARM_MESHES}, found {[o.name for o in kept]}"
        )
    return kept


def clear_all_shape_keys(meshes: list[bpy.types.Object]) -> None:
    total_removed = 0
    for ob in meshes:
        keys = ob.data.shape_keys
        if keys is None:
            continue
        total_removed += len(keys.key_blocks)
        ob.shape_key_clear()
    _log(f"cleared {total_removed} shape keys across {len(meshes)} meshes")


def reset_pose_and_clear_actions(
    arm_obj: bpy.types.Object, meshes: list[bpy.types.Object]
) -> None:
    for ob in [arm_obj, *meshes]:
        if ob.animation_data is not None:
            ob.animation_data_clear()
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)

    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="POSE")
    for pb in arm_obj.pose.bones:
        pb.location = (0.0, 0.0, 0.0)
        pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        pb.rotation_euler = (0.0, 0.0, 0.0)
        pb.scale = (1.0, 1.0, 1.0)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.context.view_layer.update()


def extract_and_rig_right_arm(
    arm_obj: bpy.types.Object, meshes: list[bpy.types.Object]
) -> dict:
    """Trim meshes to the complete right arm, prune skeleton to the 20 right-arm bones,
    normalize skin weights, and rebase both skeleton & rest meshes onto UpperArm_R.head
    at exact 1:6,667 scale WITHOUT calling armature_apply()."""
    if arm_obj.matrix_world != Matrix.Identity(4):
        raise SystemExit(f"expected identity armature transform, got {arm_obj.matrix_world}")

    ua_bone = arm_obj.data.bones.get("UpperArm_R")
    la_bone = arm_obj.data.bones.get("LowerArm_R")
    hand_bone = arm_obj.data.bones.get("Hand_R")
    if ua_bone is None or la_bone is None or hand_bone is None:
        raise SystemExit("missing UpperArm_R / LowerArm_R / Hand_R in source armature")

    shoulder_head = ua_bone.head_local.copy()
    elbow_head = la_bone.head_local.copy()
    wrist_head = hand_bone.head_local.copy()
    rest_forearm_dir = (wrist_head - elbow_head).normalized()

    # 1. Trim each mesh to right-arm geometry while preserving UVs, materials & deform weights.
    for ob in meshes:
        # Remove non-Armature modifiers (e.g. Smooth by Angle geometry nodes) so clean skinning exports.
        for mod in list(ob.modifiers):
            if mod.type != "ARMATURE":
                ob.modifiers.remove(mod)
        arm_mod = next((m for m in ob.modifiers if m.type == "ARMATURE"), None)
        if arm_mod is None:
            arm_mod = ob.modifiers.new("Armature", "ARMATURE")
        arm_mod.object = arm_obj

        arm_gids = {vg.index for vg in ob.vertex_groups if vg.name in RIGHT_ARM_BONES}
        sh_vg = ob.vertex_groups.get("Shoulder_R")
        sh_gid = sh_vg.index if sh_vg is not None else -1
        keep_vert = [False] * len(ob.data.vertices)
        for i, v in enumerate(ob.data.vertices):
            wa = sum(g.weight for g in v.groups if g.group in arm_gids)
            ws = sum(g.weight for g in v.groups if g.group == sh_gid) if sh_gid >= 0 else 0.0
            radial_sh = Vector((0.0, v.co.y - shoulder_head.y, v.co.z - shoulder_head.z)).length
            in_arm = wa >= 0.25 and v.co.x <= ARM_CUTOFF_X
            # Include the full upper/front shoulder dome around UpperArm_R.head so the
            # proximal sleeve ring stays complete without missing sawtooth triangles.
            in_shoulder_cap = (
                v.co.x <= -0.078
                and radial_sh <= 0.088
                and (wa + ws) >= 0.22
                and v.co.z >= shoulder_head.z - 0.095
            )
            if in_arm or in_shoulder_cap:
                keep_vert[i] = True

        bm = bmesh.new()
        bm.from_mesh(ob.data)
        bm.verts.ensure_lookup_table()
        bm.faces.ensure_lookup_table()
        drop_faces = [f for f in bm.faces if not all(keep_vert[v.index] for v in f.verts)]
        bmesh.ops.delete(bm, geom=drop_faces, context="FACES")
        loose_verts = [v for v in bm.verts if not v.link_faces]
        if loose_verts:
            bmesh.ops.delete(bm, geom=loose_verts, context="VERTS")

        # Smoothly close any proximal open shoulder boundary loop into a rounded
        # shoulder dome centered inside Yumeka's shoulder socket (zero jagged cut rim).
        bm.verts.ensure_lookup_table()
        bm.edges.ensure_lookup_table()
        bm.faces.ensure_lookup_table()
        uv_layer = bm.loops.layers.uv.active
        deform_layer = bm.verts.layers.deform.active
        ua_vg = ob.vertex_groups.get("UpperArm_R")
        ua_gid = ua_vg.index if ua_vg is not None else -1
        prox_edges = [
            e for e in bm.edges
            if e.is_boundary and (e.verts[0].co.x + e.verts[1].co.x) * 0.5 > -0.155
        ]
        if prox_edges:
            prox_verts = list({v for e in prox_edges for v in e.verts})
            # Gently tuck outer proximal boundary vertices slightly inward toward the
            # shoulder ball so the dome blends flush inside background Yumeka's cardigan.
            dome_center = shoulder_head + Vector((0.012, 0.0, 0.0))
            for pv in prox_verts:
                pv.co = pv.co.lerp(dome_center, 0.14)
            cap_v = bm.verts.new(dome_center)
            if deform_layer is not None and ua_gid >= 0:
                cap_v[deform_layer][ua_gid] = 1.0
            for e in prox_edges:
                adj_face = e.link_faces[0] if e.link_faces else None
                # Match winding order opposite the adjacent boundary edge so normals face outward.
                v0, v1 = e.verts[0], e.verts[1]
                sample_uv = None
                mat_idx = adj_face.material_index if adj_face is not None else 0
                if adj_face is not None:
                    for loop in adj_face.loops:
                        if loop.edge == e:
                            if loop.vert == v0:
                                v0, v1 = v1, v0
                            if uv_layer is not None:
                                sample_uv = loop[uv_layer].uv.copy()
                            break
                try:
                    nf = bm.faces.new((v0, v1, cap_v))
                    nf.material_index = mat_idx
                    nf.smooth = True
                    if uv_layer is not None and sample_uv is not None:
                        for loop in nf.loops:
                            loop[uv_layer].uv = sample_uv
                except ValueError:
                    pass
            bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

        bm.to_mesh(ob.data)
        bm.free()

        # Gently tidy the oversized bell wrist cuff & lower forearm sag in rest pose,
        # leaving the upper arm & shoulder dome (x >= -0.18) 100% authentic cardigan volume.
        if ob.name in ("Yumeka_Cos_Jacket", "Yumeka_Cos_Vest_Shirt"):
            is_jacket = ob.name == "Yumeka_Cos_Jacket"
            pull_max = 0.038 if is_jacket else 0.032
            base_r = 0.025 if is_jacket else 0.020
            flare_keep = 0.14 if is_jacket else 0.12
            for v in ob.data.vertices:
                # Subtle mid-forearm sleeve trim to prevent sagging sack silhouette.
                if is_jacket:
                    t_mid = _smoothstep(-0.18, -0.32, v.co.x)
                    if t_mid > 0.0:
                        rel_m = v.co - elbow_head
                        along_m = rel_m.dot(rest_forearm_dir)
                        rad_m = rel_m - rest_forearm_dir * along_m
                        rm = rad_m.length
                        if rm > 0.036 and rm > 1e-6:
                            rm_new = rm + ((0.036 + (rm - 0.036) * 0.55) - rm) * t_mid
                            v.co = elbow_head + rest_forearm_dir * along_m + rad_m * (rm_new / rm)
                # Neat fitted wrist cuff pull-back and flare cinch.
                t = _smoothstep(-0.26, -0.43, v.co.x)
                if t <= 0.0:
                    continue
                v.co -= rest_forearm_dir * (pull_max * t)
                rel = v.co - elbow_head
                along = rel.dot(rest_forearm_dir)
                radial = rel - rest_forearm_dir * along
                r = radial.length
                if r > base_r and r > 1e-6:
                    r_target = base_r + (r - base_r) * flare_keep
                    r_new = r + (r_target - r) * t
                    v.co = elbow_head + rest_forearm_dir * along + radial * (r_new / r)

        # Clean vertex groups: fold dropped shoulder/chest weights onto UpperArm_R,
        # transfer stray ThumbProximal_R weight on sleeves onto Hand_R, prune non-arm
        # groups, keep top-4 influences, and normalize to sum == 1.0.
        gid_to_name = {vg.index: vg.name for vg in ob.vertex_groups}
        vert_weights: list[dict[str, float]] = []
        is_sleeve = ob.name in ("Yumeka_Cos_Jacket", "Yumeka_Cos_Vest_Shirt")
        for v in ob.data.vertices:
            acc: dict[str, float] = {}
            for g in v.groups:
                if g.weight <= 1e-6:
                    continue
                bname = gid_to_name[g.group]
                if bname not in RIGHT_ARM_BONES:
                    bname = "UpperArm_R"
                elif is_sleeve and bname == "ThumbProximal_R":
                    bname = "Hand_R"
                acc[bname] = acc.get(bname, 0.0) + g.weight
            if not acc:
                acc["UpperArm_R"] = 1.0
            # Cap to 4 strongest influences per vertex (glTF standard skinning limit).
            items = sorted(acc.items(), key=lambda kv: kv[1], reverse=True)[:4]
            total = sum(w for _, w in items)
            vert_weights.append({k: w / total for k, w in items})

        ob.vertex_groups.clear()
        vg_by_name = {name: ob.vertex_groups.new(name=name) for name in sorted(RIGHT_ARM_BONES)}
        for vi, wmap in enumerate(vert_weights):
            for bname, w in wmap.items():
                vg_by_name[bname].add([vi], w, "REPLACE")

        # Rebase rest mesh vertices onto UpperArm_R.head at true 1:6,667 scale.
        for v in ob.data.vertices:
            v.co = (v.co - shoulder_head) * WORLD_SCALE
        ob.data.update()

        ob.parent = arm_obj
        ob.matrix_parent_inverse = Matrix.Identity(4)
        ob.location = (0.0, 0.0, 0.0)
        ob.rotation_euler = (0.0, 0.0, 0.0)
        ob.scale = (1.0, 1.0, 1.0)
        _log(
            f"rigged mesh {ob.name}: {len(ob.data.vertices)} verts, "
            f"{len(ob.data.polygons)} polys, {len(ob.vertex_groups)} vgroups"
        )

    # 2. Prune Armature to ONLY the 20 right-arm bones and rebase edit bones identically.
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="EDIT")
    ebones = arm_obj.data.edit_bones
    for eb in list(ebones):
        if eb.name not in RIGHT_ARM_BONES:
            ebones.remove(eb)
    if "UpperArm_R" not in ebones:
        raise SystemExit("UpperArm_R missing after bone prune")
    ebones["UpperArm_R"].parent = None
    # Snapshot original edit-bone geometry before scaling so connected child bones
    # are never double-scaled when their parent tail moves.
    saved = {eb.name: (eb.head.copy(), eb.tail.copy(), eb.roll) for eb in ebones}

    def _depth(eb: bpy.types.EditBone) -> int:
        d = 0
        cur = eb.parent
        while cur is not None:
            d += 1
            cur = cur.parent
        return d

    for eb in sorted(ebones, key=_depth):
        old_head, old_tail, old_roll = saved[eb.name]
        eb.head = (old_head - shoulder_head) * WORLD_SCALE
        eb.tail = (old_tail - shoulder_head) * WORLD_SCALE
        eb.roll = old_roll
    bpy.ops.object.mode_set(mode="OBJECT")

    arm_obj.location = (0.0, 0.0, 0.0)
    arm_obj.rotation_euler = (0.0, 0.0, 0.0)
    arm_obj.scale = (1.0, 1.0, 1.0)
    bpy.context.view_layer.update()

    # Drop any unused materials on remaining meshes.
    for ob in meshes:
        used_mats = {p.material_index for p in ob.data.polygons}
        if len(ob.material_slots) > len(used_mats):
            bpy.context.view_layer.objects.active = ob
            for idx in reversed(range(len(ob.material_slots))):
                if idx not in used_mats:
                    ob.active_material_index = idx
                    bpy.ops.object.material_slot_remove()

    # Compute QA stats in Godot Y-up coordinates: (x, y_up=z_bl, z_back=-y_bl).
    def bl_to_godot(p: Vector) -> Vector:
        return Vector((p.x, p.z, -p.y))

    b_ua = arm_obj.data.bones["UpperArm_R"]
    b_la = arm_obj.data.bones["LowerArm_R"]
    b_hand = arm_obj.data.bones["Hand_R"]
    b_idx_d = arm_obj.data.bones["IndexDistal_R"]

    ua_g = bl_to_godot(b_ua.head_local)
    la_g = bl_to_godot(b_la.head_local)
    hand_g = bl_to_godot(b_hand.head_local)
    tip_g = bl_to_godot(b_idx_d.tail_local)

    stats = {
        "world_scale": round(WORLD_SCALE, 2),
        "bone_count": len(arm_obj.data.bones),
        "root_bones": [b.name for b in arm_obj.data.bones if b.parent is None],
        "upper_arm_origin_godot": tuple(round(c, 3) for c in ua_g),
        "lower_arm_origin_godot": tuple(round(c, 1) for c in la_g),
        "hand_origin_godot": tuple(round(c, 1) for c in hand_g),
        "index_tip_rest_godot": tuple(round(c, 1) for c in tip_g),
        "L1_m": round((la_g - ua_g).length, 2),
        "L2_m": round((hand_g - la_g).length, 2),
        "hand_to_index_tip_m": round((tip_g - hand_g).length, 2),
        "total_polys": sum(len(o.data.polygons) for o in meshes),
        "total_verts": sum(len(o.data.vertices) for o in meshes),
    }
    return stats


def export_glb(path: str, arm_obj: bpy.types.Object, meshes: list[bpy.types.Object]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="DESELECT")
    arm_obj.select_set(True)
    for ob in meshes:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.preferences.addon_enable(module="io_scene_gltf2")
    bpy.ops.export_scene.gltf(
        filepath=path,
        use_selection=True,
        export_format="GLB",
        export_animations=False,
        export_morph=False,
        export_skins=True,
        export_all_influences=False,
        export_apply=False,
        export_extras=False,
        export_yup=True,
    )
    size_mb = os.path.getsize(path) / (1024 * 1024)
    _log(f"exported rigged {path} ({size_mb:.2f} MB)")


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
    clear_all_shape_keys(meshes)
    rebuild_materials()
    reset_pose_and_clear_actions(arm, meshes)
    stats = extract_and_rig_right_arm(arm, meshes)
    for k, v in stats.items():
        _log(f"{k} = {v}")

    if stats["bone_count"] != len(RIGHT_ARM_BONES):
        raise SystemExit(
            f"unexpected bone count: {stats['bone_count']} vs {len(RIGHT_ARM_BONES)}"
        )
    if stats["root_bones"] != ["UpperArm_R"]:
        raise SystemExit(f"expected single root bone UpperArm_R, got {stats['root_bones']}")
    if max(abs(c) for c in stats["upper_arm_origin_godot"]) > 0.01:
        raise SystemExit(
            f"UpperArm_R.head not centered at origin: {stats['upper_arm_origin_godot']}"
        )
    if not (900.0 <= stats["L1_m"] <= 1300.0 and 950.0 <= stats["L2_m"] <= 1400.0):
        raise SystemExit(
            f"unexpected 1:6,667 arm bone lengths: L1={stats['L1_m']} L2={stats['L2_m']}"
        )

    export_glb(out_path, arm, meshes)
    print("[yumeka-hand-relay] DONE")


if __name__ == "__main__":
    main()
