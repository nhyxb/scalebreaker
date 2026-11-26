extends "res://scenes/giant_skin.gd"
## Snow fox (VRoid/VRM humanoid) giant skin: retargets J_Bip_* bones onto the Kawaii
## driver, re-shades the MToon/unlit materials, and swings hair + fox tail from the
## giant's existing two-layer springs (no physics bodies, no skirt drive).

const MODEL := preload("res://assets/characters/snow_fox.glb")

# 1.4398 m tall VRM -> 1.7047 m Kawaii, so the 25.2 m giant capsule is filled exactly.
const FIT_SCALE := 1.1840

# Keep the body clear of the ground; tuned against the sit / sit-idle poses.
const FLOOR_OFFSET := 0.0

# Unlit MToon base color is too hot under the harbor sun, so every PBR copy gets a
# fully matte, zero-specular finish. The near-white maps are also tinted per material
# family instead of one shared multiplier: the white maid dress and stockings used to
# clip to plain white because only SKIN/HAIR were dimmed.
const SHADE_ROUGHNESS := 1.0
const SHADE_SPECULAR := 0.0
# Warm, slightly darker than the dress so the face still reads as skin next to white cloth.
const TINT_SKIN := Color(0.80, 0.73, 0.70)
# Everything not skin/hair/eye: white dress, apron, sleeve frills and stockings.
const TINT_CLOTH := Color(0.70, 0.71, 0.75)
# Hair and the fox tail: cool white, a touch brighter than the dress.
const TINT_HAIR := Color(0.75, 0.78, 0.84)
const NO_TINT := Color(1.0, 1.0, 1.0)
const SKIN_HINTS := ["SKIN", "FACE"]
const HAIR_HINTS := ["HAIR", "TAIL"]
# Only the eye balls/highlights keep their authored brightness; eyelashes and eyelines
# belong to the face and follow the skin tint.
const EYE_HINTS := ["_EYE"]

const HAIR_ZONE := 0
const TAIL_ZONE := 1


class SecondaryChain:
	var bones: PackedInt32Array = PackedInt32Array()
	var rests: Array[Quaternion] = []
	var axes: Array[Basis] = []
	var zone := HAIR_ZONE
	var phase := 0.0


var diffuse_mode := BaseMaterial3D.DIFFUSE_TOON

var _chains: Array[SecondaryChain] = []
var _sec_ready := false
var _sec_time := 0.0
var _sec_sway := Vector2.ZERO
var _sec_tip_sway := Vector2.ZERO
var _sec_bounce := 0.0
var _sec_tip_bounce := 0.0
var _sec_rot := 0.0
var _sec_tip_rot := 0.0
var _sec_head_tilt := 0.0

# VRM humanoid joint -> Kawaii driver joint.
const DRIVER_BONES := {
	"J_Bip_C_Hips": "spine",
	"J_Bip_C_Spine": "spine.001",
	"J_Bip_C_Chest": "spine.002",
	"J_Bip_C_UpperChest": "spine.003",
	"J_Bip_C_Neck": "Neck",
	"J_Bip_C_Head": "Head",
	"J_Bip_L_Shoulder": "shoulder.L",
	"J_Bip_L_UpperArm": "upper_arm.L",
	"J_Bip_L_LowerArm": "forearm.L",
	"J_Bip_L_Hand": "hand.L",
	"J_Bip_R_Shoulder": "shoulder.R",
	"J_Bip_R_UpperArm": "upper_arm.R",
	"J_Bip_R_LowerArm": "forearm.R",
	"J_Bip_R_Hand": "hand.R",
	"J_Bip_L_UpperLeg": "thigh.L",
	"J_Bip_L_LowerLeg": "shin.L",
	"J_Bip_L_Foot": "foot.L",
	"J_Bip_L_ToeBase": "toe.L",
	"J_Bip_R_UpperLeg": "thigh.R",
	"J_Bip_R_LowerLeg": "shin.R",
	"J_Bip_R_Foot": "foot.R",
	"J_Bip_R_ToeBase": "toe.R",
}

# The VRM binds in a T-pose while the Kawaii driver rests in an A-pose. Aligning each
# segment's rest direction to the driver's removes that bind-pose difference.
const ALIGN_TOWARD := {
	"J_Bip_C_Hips": "J_Bip_C_Spine",
	"J_Bip_C_Spine": "J_Bip_C_Chest",
	"J_Bip_C_Chest": "J_Bip_C_UpperChest",
	"J_Bip_C_UpperChest": "J_Bip_C_Neck",
	"J_Bip_C_Neck": "J_Bip_C_Head",
	"J_Bip_L_Shoulder": "J_Bip_L_UpperArm",
	"J_Bip_L_UpperArm": "J_Bip_L_LowerArm",
	"J_Bip_L_LowerArm": "J_Bip_L_Hand",
	"J_Bip_R_Shoulder": "J_Bip_R_UpperArm",
	"J_Bip_R_UpperArm": "J_Bip_R_LowerArm",
	"J_Bip_R_LowerArm": "J_Bip_R_Hand",
	"J_Bip_L_UpperLeg": "J_Bip_L_LowerLeg",
	"J_Bip_L_LowerLeg": "J_Bip_L_Foot",
	"J_Bip_R_UpperLeg": "J_Bip_R_LowerLeg",
	"J_Bip_R_LowerLeg": "J_Bip_R_Foot",
}
# Keep the shoes level instead of inheriting Kawaii's heeled ankle pitch.
const ALIGN_YAW := {
	"J_Bip_L_Foot": "J_Bip_L_ToeBase",
	"J_Bip_R_Foot": "J_Bip_R_ToeBase",
}

const FINGERS := {
	"Index": "f_index",
	"Middle": "f_middle",
	"Ring": "f_ring",
	"Little": "f_pinky",
	"Thumb": "thumb",
}


func configure(driver: Skeleton3D) -> void:
	_load_model(MODEL)
	# The face and hair (which carries the fox ears) are separate skins, so first person
	# hides those; the body mesh is cropped at the neck instead, because the scalp skin and
	# the blue-grey HairBack lock live in that mesh and would hang in view from above.
	_configure_visibility(&"J_Bip_C_Head", [&"Face", &"Hair"], [&"Body"])
	scale = Vector3.ONE * FIT_SCALE
	position.y = FLOOR_OFFSET

	var mapping := DRIVER_BONES.duplicate()
	for side in ["L", "R"]:
		for prefix in FINGERS:
			for segment in [1, 2, 3]:
				var vrm := "J_Bip_%s_%s%d" % [side, prefix, segment]
				if skeleton.find_bone(vrm) < 0:
					continue
				mapping[vrm] = "%s.%02d.%s" % [FINGERS[prefix], segment, side]

	_shade_unlit_materials()
	_configure_pose(driver, mapping, ALIGN_TOWARD, ALIGN_YAW)
	_init_secondary_chains()


# Optional secondary-motion hook fed by giant_visual._update_hair().
func apply_secondary_motion(sway: Vector2, tip_sway: Vector2, bounce: float, tip_bounce: float,
		rot_lag: float, tip_rot: float, head_down_tilt: float, dt: float) -> void:
	_sec_sway = sway
	_sec_tip_sway = tip_sway
	_sec_bounce = bounce
	_sec_tip_bounce = tip_bounce
	_sec_rot = rot_lag
	_sec_tip_rot = tip_rot
	_sec_head_tilt = head_down_tilt
	_sec_time += dt
	_sec_ready = true


func follow_pose(pelvis_scale := 1.0) -> void:
	super.follow_pose(pelvis_scale)
	if _sec_ready:
		_apply_secondary_motion()


# MToon arrives as KHR_materials_unlit, which shades nothing. Re-shade the albedo-only
# StandardMaterial3D copies so the giant reads with form under the game sun.
func _shade_unlit_materials() -> void:
	for mesh in meshes:
		for surface in mesh.mesh.get_surface_count():
			var mat := mesh.mesh.surface_get_material(surface) as StandardMaterial3D
			if mat == null or mat.shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED:
				continue
			var shaded := mat.duplicate() as StandardMaterial3D
			shaded.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			shaded.diffuse_mode = diffuse_mode
			shaded.roughness = SHADE_ROUGHNESS
			shaded.metallic = 0.0
			shaded.metallic_specular = SHADE_SPECULAR
			shaded.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
			shaded.emission_enabled = false
			var tint := material_tint(shaded.resource_name)
			shaded.albedo_color = Color(
				shaded.albedo_color.r * tint.r,
				shaded.albedo_color.g * tint.g,
				shaded.albedo_color.b * tint.b,
				shaded.albedo_color.a)
			mesh.set_surface_override_material(surface, shaded)


## Tint for one imported material. Every family except the eyes is dimmed so nothing turns
## into blown-out white; the eyes stay exactly as authored.
static func material_tint(material_name: String) -> Color:
	var upper := material_name.to_upper()
	if _matches_hint(upper, EYE_HINTS):
		return NO_TINT
	if _matches_hint(upper, HAIR_HINTS):
		return TINT_HAIR
	if _matches_hint(upper, SKIN_HINTS):
		return TINT_SKIN
	return TINT_CLOTH


static func _matches_hint(upper: String, hints: Array) -> bool:
	for hint: String in hints:
		if upper.contains(hint):
			return true
	return false


func _init_secondary_chains() -> void:
	var head := skeleton.find_bone("J_Bip_C_Head")
	var hips := skeleton.find_bone("J_Bip_C_Hips")
	var hair_index := 0
	for bone in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(bone)
		var parent := skeleton.get_bone_parent(bone)
		if parent == head and bone_name.begins_with("J_Sec_Hair"):
			_add_secondary_chain(bone, HAIR_ZONE, float(hair_index) * 0.73)
			hair_index += 1
		elif parent == hips and bone_name.begins_with("J_Opt_C_FoxTail"):
			_add_secondary_chain(bone, TAIL_ZONE, 0.0)


func _add_secondary_chain(root: int, zone: int, phase: float) -> void:
	var chain := SecondaryChain.new()
	chain.zone = zone
	chain.phase = phase
	var current := root
	while current >= 0:
		chain.bones.append(current)
		chain.rests.append(skeleton.get_bone_pose_rotation(current))
		chain.axes.append(skeleton.get_bone_global_rest(current).basis.orthonormalized().inverse())
		current = _first_child_bone(current)
	_chains.append(chain)


func _first_child_bone(parent: int) -> int:
	for bone in skeleton.get_bone_count():
		if skeleton.get_bone_parent(bone) == parent:
			return bone
	return -1


func _apply_secondary_motion() -> void:
	var centrifugal := clampf(absf(_sec_rot) * 0.55, 0.0, 0.22)
	var down_tilt := maxf(-_sec_head_tilt, 0.0)
	var breeze := sin(_sec_time * 1.35) * 0.020 + sin(_sec_time * 2.55) * 0.010
	for chain in _chains:
		var count := chain.bones.size()
		for k in count:
			var frac := float(k + 1) / float(count)
			var tip_mix := smoothstep(0.15, 1.0, frac)
			var weight := lerpf(0.28, 1.0, frac * frac)
			var sway := _sec_sway.lerp(_sec_tip_sway, tip_mix)
			var bounce := lerpf(_sec_bounce, _sec_tip_bounce, tip_mix)
			var rot_lag := lerpf(_sec_rot, _sec_tip_rot, tip_mix)
			var flutter := (breeze + sin(_sec_time * 2.2 + chain.phase - float(k) * 0.85) * 0.018) * weight
			var pitch := 0.0
			var roll := 0.0
			if chain.zone == TAIL_ZONE:
				# The fox tail is long and heavy: it lifts on footfalls and trails the turn.
				var lift := maxf(0.0, -sway.y * 1.15 + bounce * 1.10 + centrifugal + down_tilt * 0.30)
				pitch = clampf(lift * 0.88 + maxf(flutter, 0.0) * 0.9, -0.04, 0.58) * weight
				roll = clampf(sway.x * 0.95 + rot_lag * 1.15 + flutter * 1.2, -0.42, 0.42) * weight
			else:
				# Hanging locks: lift backward on stride/stomp, flare out on turns.
				var back_lift := maxf(0.0, -sway.y * 0.85 + bounce * 0.82
					+ centrifugal * 0.65 + down_tilt * 0.25)
				pitch = clampf(back_lift * 0.72 + maxf(flutter, 0.0) * 0.75, -0.02, 0.40) * weight
				roll = clampf(sway.x * 0.65 + rot_lag * 0.82 + flutter * 0.85, -0.28, 0.28) * weight
			var delta_q := Quaternion(chain.axes[k].z, roll) * Quaternion(chain.axes[k].x, pitch)
			skeleton.set_bone_pose_rotation(chain.bones[k], chain.rests[k] * delta_q)
