extends "res://scenes/vrm_skin.gd"
## Snow fox (VRoid/VRM humanoid) giant skin: retargets J_Bip_* bones onto the Kawaii
## driver, re-shades the MToon/unlit materials, and swings hair + fox tail from the
## giant's existing two-layer springs (no physics bodies, no skirt drive).

const MODEL := preload("res://assets/characters/snow_fox.glb")

# Unlit MToon base color clips into flat chalky white under sunlight (especially with
# DIFFUSE_TOON's hard step). Use soft Burley matte PBR (roughness ~0.89, specular ~0.16)
# and restrain bright whites into the 0.84-0.90 range so facial features, bangs, and white
# maid-dress folds stay readable under AGX daylight and react naturally to dusk/night light.
# Warm peach-ivory skin tint so the face reads softly against the white hair and outfit.
const TINT_SKIN := Color(0.88, 0.83, 0.81)
# Everything not skin/hair/eye: white maid dress, apron, sleeve frills and stockings.
const TINT_CLOTH := Color(0.84, 0.85, 0.88)
# Hair and fox tail: cool snowy white, slightly brighter than the cloth.
const TINT_HAIR := Color(0.86, 0.87, 0.90)
const NO_TINT := Color(0.95, 0.95, 0.96)
const SKIN_HINTS := ["SKIN", "FACE"]
const HAIR_HINTS := ["HAIR", "TAIL"]
# Eyes keep near-authored brightness without clipping the eye whites.
const EYE_HINTS := ["_EYE"]

const HAIR_ZONE := 0
const TAIL_ZONE := 1


class SecondaryChain:
	var bones: PackedInt32Array = PackedInt32Array()
	var rests: Array[Quaternion] = []
	var axes: Array[Basis] = []
	var zone := HAIR_ZONE
	var phase := 0.0


static var _sole_calibration: Array[Sole] = []
static var _shaded_meshes: Dictionary = {}

var diffuse_mode := BaseMaterial3D.DIFFUSE_BURLEY

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

const VRM_BONES := {
	"hips": "J_Bip_C_Hips", "spine": "J_Bip_C_Spine", "chest": "J_Bip_C_Chest",
	"upperChest": "J_Bip_C_UpperChest", "neck": "J_Bip_C_Neck", "head": "J_Bip_C_Head",
}


func configure(driver: Skeleton3D) -> void:
	_load_model(MODEL)
	# The body contains a scalp and the back hair, so it also needs a first-person crop.
	_configure_visibility(&"J_Bip_C_Head", [&"Face", &"Hair"], [&"Body"])
	_fit_height()
	var bones := VRM_BONES.duplicate()
	for side in ["left", "right"]:
		var prefix := "J_Bip_L_" if side == "left" else "J_Bip_R_"
		for limb: String in LIMBS:
			bones[side + limb] = prefix + ("ToeBase" if limb == "Toes" else limb)
		for digit: String in FINGERS:
			var segments := ["Proximal", "Intermediate", "Distal"]
			if digit == "Thumb":
				segments = ["Metacarpal", "Proximal", "Distal"]
			for index in segments.size():
				bones[side + digit + segments[index]] = prefix + digit + str(index + 1)

	_shade_vrm_materials(material_tint, diffuse_mode, true, _shaded_meshes)
	_retarget(driver, bones)
	if _sole_calibration.is_empty():
		follow_pose()
		_measure_soles(bones)
		_sole_calibration = soles
	else:
		soles = _sole_calibration
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
