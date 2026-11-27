extends Node3D
## Seated Yumeka: the licensed anime avatar (assets/characters/yumeka/Yumeka_seated.glb,
## gitignored) mounted directly inside the single-world bedroom (`Bedroom`, scaled
## 6666.67x, VisualInstance3D Layer 2). If the GLB asset is absent (fresh public-repo
## clone) this node either never spawns or stays inert, and `desk_hazards.gd` falls back
## to its procedural placeholder arm.
##
## Directly drives Yumeka's own full Skeleton3D for:
##   - Idle life: breathing (Spine -> Chest), blinking, and head/neck/conjugate eyeball
##     player-tracking gaze;
##   - Tabletop desk hazards (`finger_poke` & future 3B-2 gestures): real-time analytical
##     2-Bone IK (`UpperArm_R -> LowerArm_R -> Hand_R` + forearm pronation split onto
##     `LowerArm_twist_R`), verified `local (1, 0, 0)` finger gesture blending (`0.0`
##     desk-resting curl <-> `1.0` single-finger poke), and subtle `Chest`/`Shoulder_R`
##     forward lean — 100% seamless single mesh with zero detached hand relay.

const GLB_PATH := "res://assets/characters/yumeka/Yumeka_seated.glb"
const CityNightLights := preload("res://scenes/city_night_lights.gd")
const BEDROOM_LAYER := 2
const DIORAMA_CENTRE_WORLD := Vector3.ZERO

## Idle animation tick rate (during active desk-hazard IK we update every frame for 60 fps).
const ANIM_HZ := 18.0
const BREATH_PERIOD := 4.2
## Breathing amplitudes (radians, applied over the baked SeatedPose).
const BREATH_CHEST_RAD := 0.011
const BREATH_SPINE_RAD := 0.006
const BLINK_MIN_GAP := 3.0
const BLINK_MAX_GAP := 6.0
const BLINK_CLOSE_TIME := 0.07
const BLINK_OPEN_TIME := 0.14
## Comfort limits around the baked seated rest orientation (degrees).
const GAZE_YAW_LIMIT := 15.0
const GAZE_PITCH_LIMIT := 10.0
## Anatomical eyeball rotation limits inside the sockets (degrees).
const EYE_YAW_LIMIT := 14.0
const EYE_PITCH_LIMIT := 10.0
## Soft anime matte (Vulkan mobile + AGX friendly).
const MATTE_ROUGHNESS := 0.88
const MATTE_SPECULAR := 0.16
const SCISSOR_THRESHOLD := 0.42
## Generous local-space cull margin (2.0 m local -> ~14 km world) so extended arms/fingers
## never get frustum-culled when a downtown camera looks down at the fingertip.
const EXTENDED_ARM_CULL_MARGIN := 2.0

## Right-arm 2-Bone IK tuning (skeleton-space & world-space).
const FALLBACK_SHOULDER_MAIN_WORLD := Vector3(636.0, 823.8, 2928.7)
const FALLBACK_ELBOW_REST_MAIN_WORLD := Vector3(1486.9, 326.3, 2462.5)
const FALLBACK_HAND_REST_MAIN_WORLD := Vector3(1125.5, 283.0, 1348.5)
const FALLBACK_ARM_L1_WORLD := 1090.28
const FALLBACK_ARM_L2_WORLD := 1171.96
const FALLBACK_POKE_TIP_LOCAL_WORLD := Vector3(-108.0, 755.0, -78.0)
## Keep at least ~17 deg natural elbow flexion before soft axial reach kicks in.
const IK_SOFT_REACH_RATIO := 0.955
const IK_MAX_STRETCH := 1.48
## Ventral offset (metres at 1:6,667) from IndexDistal_R centerline to fingertip skin pad.
const INDEX_PAD_VENTRAL_OFFSET_WORLD := 26.0
## Subtle torso & clavicle participation when reaching across the harbour diorama (degrees).
const HAZARD_CHEST_PITCH_DEG := 3.0
const HAZARD_CHEST_YAW_DEG := 2.5
const HAZARD_SHOULDER_PROTRACT_DEG := 4.5
const HAZARD_SHOULDER_ELEVATE_DEG := 3.0

## Reusable hand-gesture library: REST_RELAXED <-> FINGER_POKE (plus OPEN_PALM / PINCH_GRIP
## reserved for future tabletop interactions).
enum HandGesture { REST_RELAXED, FINGER_POKE, OPEN_PALM, PINCH_GRIP }

const FINGER_BONES := [
	"ThumbProximal_R", "ThumbIntermediate_R", "ThumbDistal_R",
	"IndexProximal_R", "IndexIntermediate_R", "IndexDistal_R",
	"MiddleProximal_R", "MiddleIntermediate_R", "MiddleDistal_R",
	"RingProximal_R", "RingIntermediate_R", "RingDistal_R",
	"LittleProximal_R", "LittleIntermediate_R", "LittleDistal_R",
]

## Finger pose presets expressed as T-pose-relative Vector3(flex_x_deg, twist_y_deg, spread_z_deg)
## around each bone's verified local flexion axis (local (1, 0, 0), negative = curl toward palm).
## Since Yumeka_seated.glb bakes REST_RELAXED into its SeatedPose rest transforms, runtime deltas
## are precomputed as `q_rest_relaxed.inverse() * q_target` so weight 0.0 == exact SeatedPose.
const GESTURE_PRESETS := {
	HandGesture.REST_RELAXED: {
		"ThumbProximal_R": Vector3(-10.0, 0.0, 0.0),
		"ThumbIntermediate_R": Vector3(-18.0, 0.0, 0.0),
		"ThumbDistal_R": Vector3(-22.0, 0.0, 0.0),
		"IndexProximal_R": Vector3(-20.0, 0.0, 0.0),
		"IndexIntermediate_R": Vector3(-32.0, 0.0, 0.0),
		"IndexDistal_R": Vector3(-20.0, 0.0, 0.0),
		"MiddleProximal_R": Vector3(-24.0, 0.0, 0.0),
		"MiddleIntermediate_R": Vector3(-36.0, 0.0, 0.0),
		"MiddleDistal_R": Vector3(-24.0, 0.0, 0.0),
		"RingProximal_R": Vector3(-28.0, 0.0, 0.0),
		"RingIntermediate_R": Vector3(-40.0, 0.0, 0.0),
		"RingDistal_R": Vector3(-26.0, 0.0, 0.0),
		"LittleProximal_R": Vector3(-32.0, 0.0, 0.0),
		"LittleIntermediate_R": Vector3(-44.0, 0.0, 0.0),
		"LittleDistal_R": Vector3(-28.0, 0.0, 0.0),
	},
	HandGesture.FINGER_POKE: {
		"IndexProximal_R": Vector3(-4.0, 0.0, 0.0),
		"IndexIntermediate_R": Vector3(-8.0, 0.0, 0.0),
		"IndexDistal_R": Vector3(-6.0, 0.0, 0.0),
		"MiddleProximal_R": Vector3(-78.0, 0.0, 0.0),
		"MiddleIntermediate_R": Vector3(-90.0, 0.0, 0.0),
		"MiddleDistal_R": Vector3(-46.0, 0.0, 0.0),
		"RingProximal_R": Vector3(-84.0, 0.0, 0.0),
		"RingIntermediate_R": Vector3(-94.0, 0.0, 0.0),
		"RingDistal_R": Vector3(-50.0, 0.0, 0.0),
		"LittleProximal_R": Vector3(-88.0, 0.0, 0.0),
		"LittleIntermediate_R": Vector3(-96.0, 0.0, 0.0),
		"LittleDistal_R": Vector3(-52.0, 0.0, 0.0),
		"ThumbProximal_R": Vector3(16.0, 0.0, -28.0),
		"ThumbIntermediate_R": Vector3(0.0, 0.0, -26.0),
		"ThumbDistal_R": Vector3(0.0, 0.0, -20.0),
	},
	HandGesture.OPEN_PALM: {
		"ThumbProximal_R": Vector3(-4.0, 0.0, 12.0),
		"ThumbIntermediate_R": Vector3(-6.0, 0.0, 4.0),
		"ThumbDistal_R": Vector3(-4.0, 0.0, 0.0),
		"IndexProximal_R": Vector3(-4.0, 0.0, -4.0),
		"IndexIntermediate_R": Vector3(-6.0, 0.0, 0.0),
		"IndexDistal_R": Vector3(-4.0, 0.0, 0.0),
		"MiddleProximal_R": Vector3(-4.0, 0.0, 0.0),
		"MiddleIntermediate_R": Vector3(-6.0, 0.0, 0.0),
		"MiddleDistal_R": Vector3(-4.0, 0.0, 0.0),
		"RingProximal_R": Vector3(-5.0, 0.0, 3.0),
		"RingIntermediate_R": Vector3(-7.0, 0.0, 0.0),
		"RingDistal_R": Vector3(-4.0, 0.0, 0.0),
		"LittleProximal_R": Vector3(-6.0, 0.0, 6.0),
		"LittleIntermediate_R": Vector3(-8.0, 0.0, 0.0),
		"LittleDistal_R": Vector3(-5.0, 0.0, 0.0),
	},
	HandGesture.PINCH_GRIP: {
		"ThumbProximal_R": Vector3(-8.0, 0.0, -24.0),
		"ThumbIntermediate_R": Vector3(-24.0, 0.0, -14.0),
		"ThumbDistal_R": Vector3(-26.0, 0.0, -6.0),
		"IndexProximal_R": Vector3(-38.0, 0.0, 0.0),
		"IndexIntermediate_R": Vector3(-44.0, 0.0, 0.0),
		"IndexDistal_R": Vector3(-28.0, 0.0, 0.0),
		"MiddleProximal_R": Vector3(-56.0, 0.0, 0.0),
		"MiddleIntermediate_R": Vector3(-68.0, 0.0, 0.0),
		"MiddleDistal_R": Vector3(-34.0, 0.0, 0.0),
		"RingProximal_R": Vector3(-68.0, 0.0, 0.0),
		"RingIntermediate_R": Vector3(-78.0, 0.0, 0.0),
		"RingDistal_R": Vector3(-40.0, 0.0, 0.0),
		"LittleProximal_R": Vector3(-74.0, 0.0, 0.0),
		"LittleIntermediate_R": Vector3(-84.0, 0.0, 0.0),
		"LittleDistal_R": Vector3(-44.0, 0.0, 0.0),
	},
}

var _model: Node3D
var _skeleton: Skeleton3D
var _bedroom: Node3D
var _sky: Node
var _morph_carriers := {}          # morph name -> MeshInstance3D carrying it
var _head_idx := -1
var _neck_idx := -1
var _chest_idx := -1
var _spine_idx := -1
var _eye_l_idx := -1
var _eye_r_idx := -1
var _shoulder_r_idx := -1
var _upper_arm_r_idx := -1
var _upper_arm_twist_r_idx := -1
var _lower_arm_r_idx := -1
var _lower_arm_twist_r_idx := -1
var _hand_r_idx := -1
var _idx_int_r_idx := -1
var _idx_dist_r_idx := -1
var _finger_indices := {}          # String bone name -> int bone index
var _finger_seated_quats := {}     # int bone index -> Quaternion SeatedPose local rotation
var _gesture_delta_quats := {}     # HandGesture -> { int bone index -> Quaternion delta from SeatedPose }
var _lower_twist_seated_q := Quaternion.IDENTITY
var _upper_twist_seated_q := Quaternion.IDENTITY
## SeatedPose transforms per animated bone: breathing, gaze, and right-arm IK
## compose parent-to-child over these, never over raw T-pose.
var _posed_bases := {}
var _local_bases := {}             # child bone idx -> local transform relative to parent in SeatedPose
var _rest_eye_mid_local := Vector3.ZERO

## Dynamically measured skeleton-local right-arm dimensions.
var _arm_l1_skel := 0.155754
var _arm_l2_skel := 0.167423
var _index_distal_len_skel := 0.01535
var _poke_tip_in_hand_local_skel := Vector3(-0.0154, 0.1079, -0.0111)

## Active right-arm IK state (driven directly by scenes/desk_hazards.gd).
var _arm_ik_active := false
var _arm_ik_wrist_world := FALLBACK_HAND_REST_MAIN_WORLD
var _arm_ik_hand_basis_world := Basis.IDENTITY
var _arm_ik_pole_world := Vector3(0.92, 0.16, 0.34)
var _arm_ik_gesture_from: int = HandGesture.REST_RELAXED
var _arm_ik_gesture_to: int = HandGesture.FINGER_POKE
var _arm_ik_gesture_weight := 0.0
var _arm_ik_lean := 0.0
var _arm_ik_target_world := Vector3.ZERO
var _last_shoulder_world := FALLBACK_SHOULDER_MAIN_WORLD
var _last_elbow_world := FALLBACK_ELBOW_REST_MAIN_WORLD
var _last_wrist_world := FALLBACK_HAND_REST_MAIN_WORLD
var _last_fingertip_world := FALLBACK_HAND_REST_MAIN_WORLD
var _last_elbow_bend_deg := 0.0
var _last_ik_stretch := 1.0

var _anim_acc := 0.0
var _time := 0.0
var _breath_lift := 0.0            # [-1, +1] sine shared with main-world looming shadow
var _blink_state := 0.0            # 0 = open, 1 = closed (animated weight)
var _blink_timer := 2.2            # seconds until the next blink
var _blink_anim := -1.0            # < 0: idle; else seconds into the blink
var _gaze_yaw := 0.0               # smoothed head+neck degrees around SeatedPose
var _gaze_pitch := 0.0             # positive = lower the gaze further
var _eye_yaw := 0.0                # smoothed Eye_L/Eye_R degrees in current head space
var _eye_pitch := 0.0              # positive = lower irises toward diorama
var _gaze_swing := Vector2.ZERO    # neutral (diorama) gaze angle (degrees), subtracted
var _gaze_override := Vector3.ZERO # main-world debug/test target (Vector3.ZERO = off)
var _mobile := false

@onready var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_mobile = OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")
	var packed: PackedScene = null
	if ResourceLoader.exists(GLB_PATH, "PackedScene"):
		packed = load(GLB_PATH) as PackedScene
	if packed == null:
		# Public-repo clones (or a half-synced assets folder) must stay silent.
		return
	_model = packed.instantiate()
	_model.name = "Model"
	# The baked GLB faces its local +Z (glTF forward); `ultra_giant_anchor`'s -Z
	# faces the sandbox, so flip the model to complete the mount.
	rotation.y = PI
	add_child(_model)
	_strip_collisions(_model)
	_apply_matte_materials()
	_find_animation_rig()
	if _skeleton == null or _head_idx < 0:
		push_warning("Yumeka seated GLB has no animatable rig: static mount only")
		return
	# Land the 1-frame `SeatedPose` action first, then freeze AnimationPlayer so
	# runtime breathing, gaze, and right-arm 2-Bone IK own the skeleton cleanly.
	_land_seated_pose()
	_cache_posed_bases()
	_bind_right_arm_ik()
	_cache_neutral_gaze()
	_set_idle_face()
	set_meta(&"mounted", true)


# --------------------------------------------------------------------------- #
# Mount-time setup
# --------------------------------------------------------------------------- #

func _strip_collisions(node: Node) -> void:
	for child in node.get_children():
		if child is CollisionObject3D:
			node.remove_child(child)
			child.free()
			continue
		_strip_collisions(child)


func _apply_matte_materials() -> void:
	# Soft anime matte isolated onto Layer 2 (lit exclusively by bedroom lights),
	# with alpha-scissor eyelashes/hair-cards and generous cull margin for extended arms.
	if _model == null:
		return
	_walk(_model, func(node: Node) -> void:
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			return
		mi.layers = BEDROOM_LAYER
		mi.extra_cull_margin = EXTENDED_ARM_CULL_MARGIN
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if _mobile \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		for surf in mi.mesh.get_surface_count():
			var src := mi.get_active_material(surf) as StandardMaterial3D
			if src == null:
				continue
			var dup := src.duplicate() as StandardMaterial3D
			dup.roughness = MATTE_ROUGHNESS
			dup.metallic = 0.0
			dup.metallic_specular = MATTE_SPECULAR
			if src.emission_enabled:
				dup.emission_enabled = false
			if src.resource_name.to_lower().contains("transparent"):
				dup.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				dup.alpha_scissor_threshold = SCISSOR_THRESHOLD
				dup.cull_mode = BaseMaterial3D.CULL_DISABLED
			mi.set_surface_override_material(surf, dup)
	)


func _walk(node: Node, fn: Callable) -> void:
	fn.call(node)
	for child in node.get_children():
		_walk(child, fn)


func _find_animation_rig() -> void:
	if _model == null:
		return
	_walk(_model, func(node: Node) -> void:
		if _skeleton == null and node is Skeleton3D:
			_skeleton = node
		var mi := node as MeshInstance3D
		if mi != null and mi.mesh != null:
			for i in mi.mesh.get_blend_shape_count():
				var shape := String(mi.mesh.get_blend_shape_name(i))
				if not _morph_carriers.has(shape):
					_morph_carriers[shape] = mi
	)
	if _skeleton == null:
		return
	_head_idx = _skeleton.find_bone("Head")
	_neck_idx = _skeleton.find_bone("Neck")
	_chest_idx = _skeleton.find_bone("Chest")
	_spine_idx = _skeleton.find_bone("Spine")
	_eye_l_idx = _skeleton.find_bone("Eye_L")
	_eye_r_idx = _skeleton.find_bone("Eye_R")
	_shoulder_r_idx = _skeleton.find_bone("Shoulder_R")
	_upper_arm_r_idx = _skeleton.find_bone("UpperArm_R")
	_upper_arm_twist_r_idx = _skeleton.find_bone("UpperArm_twist_R")
	_lower_arm_r_idx = _skeleton.find_bone("LowerArm_R")
	_lower_arm_twist_r_idx = _skeleton.find_bone("LowerArm_twist_R")
	_hand_r_idx = _skeleton.find_bone("Hand_R")
	_idx_int_r_idx = _skeleton.find_bone("IndexIntermediate_R")
	_idx_dist_r_idx = _skeleton.find_bone("IndexDistal_R")
	# Locate enclosing Bedroom (for 1:1 bedroom-local debug readouts) and Skybox parent.
	var p := get_parent()
	while p != null:
		if _bedroom == null and p.name == "Bedroom" and p is Node3D:
			_bedroom = p as Node3D
		if _sky == null and p.has_method(&"mark_dirty"):
			_sky = p
		p = p.get_parent()


func _land_seated_pose() -> void:
	var players: Array = []
	_walk(_model, func(node: Node) -> void:
		if node is AnimationPlayer and players.is_empty():
			players.append(node)
	)
	if players.is_empty():
		push_warning("Yumeka GLB carries no SeatedPose animation")
		return
	var player: AnimationPlayer = players[0]
	var pick: StringName = &"SeatedPose"
	var found := false
	for anim in player.get_animation_list():
		if String(anim).contains("Seated"):
			pick = anim
			found = true
	if not found and player.get_animation_list().size() > 0:
		pick = player.get_animation_list()[0]
	player.play(pick)
	player.seek(0.0, true)
	player.pause()
	player.speed_scale = 0.0
	if _skeleton != null and not _skeleton.has_meta(&"seat_landed"):
		_skeleton.set_meta(&"seat_landed", true)


func _cache_posed_bases() -> void:
	for idx in [
		_spine_idx, _chest_idx, _neck_idx, _head_idx, _eye_l_idx, _eye_r_idx,
		_shoulder_r_idx, _upper_arm_r_idx, _lower_arm_r_idx, _hand_r_idx,
	]:
		if idx >= 0:
			_posed_bases[idx] = _skeleton.get_bone_global_pose(idx)
	var pairs := [
		[_chest_idx, _spine_idx],
		[_neck_idx, _chest_idx],
		[_head_idx, _neck_idx],
		[_eye_l_idx, _head_idx],
		[_eye_r_idx, _head_idx],
		[_shoulder_r_idx, _chest_idx],
		[_upper_arm_r_idx, _shoulder_r_idx],
		[_lower_arm_r_idx, _upper_arm_r_idx],
		[_hand_r_idx, _lower_arm_r_idx],
	]
	for pair in pairs:
		var child_i: int = pair[0]
		var parent_i: int = pair[1]
		if child_i >= 0 and parent_i >= 0 and _posed_bases.has(child_i) and _posed_bases.has(parent_i):
			var p_base: Transform3D = _posed_bases[parent_i]
			var c_base: Transform3D = _posed_bases[child_i]
			_local_bases[child_i] = p_base.affine_inverse() * c_base
	if _eye_l_idx >= 0 and _eye_r_idx >= 0:
		var el: Transform3D = _posed_bases[_eye_l_idx]
		var er: Transform3D = _posed_bases[_eye_r_idx]
		_rest_eye_mid_local = (el.origin + er.origin) * 0.5
	elif _head_idx >= 0:
		_rest_eye_mid_local = (_posed_bases[_head_idx] as Transform3D).origin + Vector3(0.0, 0.04, 0.04)


func _bind_right_arm_ik() -> void:
	if _skeleton == null or _upper_arm_r_idx < 0 or _lower_arm_r_idx < 0 or _hand_r_idx < 0:
		return
	var p_sh: Vector3 = (_posed_bases[_upper_arm_r_idx] as Transform3D).origin
	var p_el: Vector3 = (_posed_bases[_lower_arm_r_idx] as Transform3D).origin
	var p_wr: Vector3 = (_posed_bases[_hand_r_idx] as Transform3D).origin
	_arm_l1_skel = maxf(p_sh.distance_to(p_el), 0.02)
	_arm_l2_skel = maxf(p_el.distance_to(p_wr), 0.02)

	if _lower_arm_twist_r_idx >= 0:
		_lower_twist_seated_q = _skeleton.get_bone_pose_rotation(_lower_arm_twist_r_idx)
	if _upper_arm_twist_r_idx >= 0:
		_upper_twist_seated_q = _skeleton.get_bone_pose_rotation(_upper_arm_twist_r_idx)
	if _idx_int_r_idx >= 0 and _idx_dist_r_idx >= 0:
		var p_int := _skeleton.get_bone_global_pose(_idx_int_r_idx).origin
		var p_dist := _skeleton.get_bone_global_pose(_idx_dist_r_idx).origin
		_index_distal_len_skel = maxf(p_int.distance_to(p_dist) * 0.985, 0.005)

	_finger_indices.clear()
	_finger_seated_quats.clear()
	_gesture_delta_quats.clear()
	for bname in FINGER_BONES:
		var idx := _skeleton.find_bone(bname)
		if idx >= 0:
			_finger_indices[bname] = idx
			_finger_seated_quats[idx] = _skeleton.get_bone_pose_rotation(idx)

	# Precompute exact SeatedPose-relative delta quaternions for every gesture preset:
	# SeatedPose already embeds REST_RELAXED, so delta = q_rest_relaxed.inverse() * q_target.
	var rest_preset: Dictionary = GESTURE_PRESETS[HandGesture.REST_RELAXED]
	for g_key in GESTURE_PRESETS.keys():
		var preset: Dictionary = GESTURE_PRESETS[g_key]
		var qmap := {}
		for bname in FINGER_BONES:
			var idx: int = _finger_indices.get(bname, -1)
			if idx < 0:
				continue
			var q_rest := _euler_to_finger_quat(rest_preset.get(bname, Vector3.ZERO))
			var q_target := _euler_to_finger_quat(preset.get(bname, Vector3.ZERO))
			qmap[idx] = q_rest.inverse() * q_target
		_gesture_delta_quats[g_key] = qmap

	# Measure exact index-fingertip skin-pad offset in Hand_R local coordinates under FINGER_POKE.
	set_hand_gesture_blend(HandGesture.REST_RELAXED, HandGesture.FINGER_POKE, 1.0)
	if _idx_dist_r_idx >= 0:
		var hand_pose := _skeleton.get_bone_global_pose(_hand_r_idx)
		var dist_pose := _skeleton.get_bone_global_pose(_idx_dist_r_idx)
		var pad_off := INDEX_PAD_VENTRAL_OFFSET_WORLD / _skel_to_world_scale()
		var tip_skel := dist_pose * Vector3(0.0, _index_distal_len_skel, -pad_off)
		_poke_tip_in_hand_local_skel = hand_pose.affine_inverse() * tip_skel
	set_hand_gesture_blend(HandGesture.REST_RELAXED, HandGesture.FINGER_POKE, 0.0)


func _euler_to_finger_quat(ang_deg: Vector3) -> Quaternion:
	var q := Quaternion.IDENTITY
	if absf(ang_deg.z) > 1e-4:
		q = q * Quaternion(Vector3.BACK, deg_to_rad(ang_deg.z))
	if absf(ang_deg.x) > 1e-4:
		q = q * Quaternion(Vector3.RIGHT, deg_to_rad(ang_deg.x))
	if absf(ang_deg.y) > 1e-4:
		q = q * Quaternion(Vector3.UP, deg_to_rad(ang_deg.y))
	return q


func _skel_to_world_scale() -> float:
	if _skeleton == null:
		return 7000.0
	var s := _skeleton.global_transform.basis.get_scale().x
	return s if s > 1e-4 else 7000.0


func _cache_neutral_gaze() -> void:
	_gaze_swing = _swing_to(DIORAMA_CENTRE_WORLD)


func _set_idle_face() -> void:
	set_morph("eye_nagomi_1", 0.32)
	set_morph("eye_under_up_1", 0.18)
	set_morph("mouth_smile_1", 0.22)
	set_morph("look_down", 0.14)
	set_morph("eye_close", 0.0)


func set_morph(shape: String, value: float) -> void:
	var mi: MeshInstance3D = _morph_carriers.get(shape, null)
	if mi != null:
		mi.set("blend_shapes/" + shape, clampf(value, 0.0, 1.0))


func get_morph(shape: String) -> float:
	var mi: MeshInstance3D = _morph_carriers.get(shape, null)
	if mi != null:
		return float(mi.get("blend_shapes/" + shape))
	return 0.0


# --------------------------------------------------------------------------- #
# Animation loop (18 Hz idle; full frame rate while right-arm IK is active)
# --------------------------------------------------------------------------- #

func _process(delta: float) -> void:
	if _model == null or _skeleton == null:
		return
	var dt := delta
	if not _arm_ik_active:
		_anim_acc += delta
		var tick := 1.0 / ANIM_HZ
		if _anim_acc < tick:
			return
		dt = _anim_acc
		_anim_acc = 0.0
	else:
		_anim_acc = 0.0
	_time += dt

	_drive_breathing()
	if _arm_ik_active:
		_apply_right_arm_ik_now()
	_drive_blink(dt)
	_drive_gaze(dt)


func _drive_breathing() -> void:
	var phase := fposmod(_time / BREATH_PERIOD, 1.0) * TAU
	_breath_lift = sin(phase)
	_twist_bone_from_base(_spine_idx, _posed_bases.get(_spine_idx, Transform3D.IDENTITY),
			Vector3.RIGHT, -_breath_lift * BREATH_SPINE_RAD)
	if _chest_idx >= 0 and not _arm_ik_active:
		var chest_base: Transform3D = _composed_base(_chest_idx, _spine_idx)
		_twist_bone_from_base(_chest_idx, chest_base, Vector3.RIGHT, -_breath_lift * BREATH_CHEST_RAD)
	CityNightLights.set_giant_shadow_pulse(_breath_lift)


func _drive_blink(dt: float) -> void:
	if not _morph_carriers.has("eye_close"):
		return
	if _blink_anim < 0.0:
		_blink_timer -= dt
		if _blink_timer <= 0.0:
			_blink_anim = 0.0
			_blink_timer = _rng.randf_range(BLINK_MIN_GAP, BLINK_MAX_GAP)
		return
	_blink_anim += dt
	if _blink_anim < BLINK_CLOSE_TIME:
		_blink_state = _blink_anim / BLINK_CLOSE_TIME
	elif _blink_anim < BLINK_CLOSE_TIME + BLINK_OPEN_TIME:
		_blink_state = 1.0 - (_blink_anim - BLINK_CLOSE_TIME) / BLINK_OPEN_TIME
	else:
		_blink_state = 0.0
		_blink_anim = -1.0
	set_morph("eye_close", _blink_state)


func _main_world_player() -> Node3D:
	for scene_root in get_tree().root.get_children():
		var round := (scene_root as Node).get_node_or_null("MapSlot/Round")
		if round == null:
			continue
		var human := round.get_node_or_null("Human")
		if human != null:
			return human as Node3D
		return round.get_node_or_null("Giant") as Node3D
	return null


func _resolve_gaze_world_target() -> Vector3:
	if _gaze_override != Vector3.ZERO:
		return _gaze_override
	if _arm_ik_active:
		return _arm_ik_target_world
	var actor := _main_world_player()
	if actor != null:
		return actor.global_position
	return DIORAMA_CENTRE_WORLD


func _drive_gaze(dt: float) -> void:
	if _head_idx < 0:
		return
	var world_target := _resolve_gaze_world_target()
	var swing := _swing_to(world_target)
	var delta_yaw := swing.x - _gaze_swing.x
	var delta_pitch := swing.y - _gaze_swing.y
	var desired_yaw := clampf(delta_yaw * 0.68, -GAZE_YAW_LIMIT, GAZE_YAW_LIMIT)
	var desired_pitch := clampf(delta_pitch * 0.60, -GAZE_PITCH_LIMIT, GAZE_PITCH_LIMIT)
	var head_smooth := 1.0 - exp(-dt * 4.2)
	_gaze_yaw = lerpf(_gaze_yaw, desired_yaw, head_smooth)
	_gaze_pitch = lerpf(_gaze_pitch, desired_pitch, head_smooth)

	_recompose_head_only()
	_drive_eyes(world_target, dt)


func _recompose_head_only() -> void:
	if _neck_idx >= 0:
		var neck_base := _composed_base(_neck_idx, _chest_idx)
		_twist_bone_from_base(_neck_idx, neck_base,
				Vector3.UP, deg_to_rad(_gaze_yaw) * 0.35,
				Vector3.RIGHT, deg_to_rad(_gaze_pitch) * 0.35)
	if _head_idx >= 0:
		var head_base := _composed_base(_head_idx, _neck_idx)
		_twist_bone_from_base(_head_idx, head_base,
				Vector3.UP, deg_to_rad(_gaze_yaw) * 0.65,
				Vector3.RIGHT, deg_to_rad(_gaze_pitch) * 0.65)


func _recompose_head_and_eyes() -> void:
	_recompose_head_only()
	if _eye_l_idx < 0 or _eye_r_idx < 0:
		return
	var eye_l_base := _composed_base(_eye_l_idx, _head_idx)
	var eye_r_base := _composed_base(_eye_r_idx, _head_idx)
	var eye_rot := Basis(Vector3.UP, deg_to_rad(_eye_yaw)) \
			* Basis(Vector3.RIGHT, deg_to_rad(_eye_pitch))
	_skeleton.set_bone_global_pose(_eye_l_idx,
			Transform3D(eye_l_base.basis * eye_rot, eye_l_base.origin))
	_skeleton.set_bone_global_pose(_eye_r_idx,
			Transform3D(eye_r_base.basis * eye_rot, eye_r_base.origin))


func _drive_eyes(world_target: Vector3, dt: float) -> void:
	if _eye_l_idx < 0 or _eye_r_idx < 0:
		return
	var eye_l_base := _composed_base(_eye_l_idx, _head_idx)
	var eye_r_base := _composed_base(_eye_r_idx, _head_idx)
	var eye_mid := (eye_l_base.origin + eye_r_base.origin) * 0.5
	var target_skel := _skeleton.global_transform.affine_inverse() * world_target
	var dir_skel := target_skel - eye_mid
	if dir_skel.length_squared() < 1e-8:
		dir_skel = eye_l_base.basis.z
	var dir_eye := eye_l_base.basis.inverse() * dir_skel
	var horiz := Vector2(dir_eye.x, dir_eye.z).length()
	var desired_eye_yaw := clampf(rad_to_deg(atan2(dir_eye.x, maxf(dir_eye.z, 1e-4))),
			-EYE_YAW_LIMIT, EYE_YAW_LIMIT)
	var desired_eye_pitch := clampf(rad_to_deg(atan2(-dir_eye.y, maxf(horiz, 1e-4))),
			-EYE_PITCH_LIMIT, EYE_PITCH_LIMIT)
	var eye_smooth := 1.0 - exp(-dt * 11.0)
	_eye_yaw = lerpf(_eye_yaw, desired_eye_yaw, eye_smooth)
	_eye_pitch = lerpf(_eye_pitch, desired_eye_pitch, eye_smooth)

	var eye_rot := Basis(Vector3.UP, deg_to_rad(_eye_yaw)) \
			* Basis(Vector3.RIGHT, deg_to_rad(_eye_pitch))
	_skeleton.set_bone_global_pose(_eye_l_idx,
			Transform3D(eye_l_base.basis * eye_rot, eye_l_base.origin))
	_skeleton.set_bone_global_pose(_eye_r_idx,
			Transform3D(eye_r_base.basis * eye_rot, eye_r_base.origin))

	if _blink_anim < 0.0:
		var lid_follow := clampf(0.10 + maxf(_eye_pitch, 0.0) / EYE_PITCH_LIMIT * 0.14, 0.08, 0.24)
		set_morph("look_down", lid_follow)


func _composed_base(child_idx: int, parent_idx: int) -> Transform3D:
	if parent_idx >= 0 and _local_bases.has(child_idx):
		return _skeleton.get_bone_global_pose(parent_idx) * (_local_bases[child_idx] as Transform3D)
	if _posed_bases.has(child_idx):
		return _posed_bases[child_idx] as Transform3D
	return _skeleton.get_bone_global_pose(child_idx)


func _swing_to(world_target: Vector3) -> Vector2:
	var eye_pos := _skeleton.global_transform * _rest_eye_mid_local
	var dir := world_target - eye_pos
	if dir.length_squared() < 1e-8:
		dir = Vector3(0.0, -0.1, -1.0)
	var dir_local := _skeleton.global_transform.basis.orthonormalized().inverse() * dir
	var yaw := rad_to_deg(atan2(dir_local.x, maxf(dir_local.z, 1e-4)))
	var pitch := rad_to_deg(atan2(-dir_local.y, Vector2(dir_local.x, dir_local.z).length()))
	return Vector2(yaw, pitch)


func _twist_bone_from_base(bone_idx: int, base: Transform3D, axis_a: Vector3, angle_a: float,
		axis_b := Vector3.ZERO, angle_b := 0.0) -> void:
	if bone_idx < 0 or _skeleton == null:
		return
	var basis := Basis(axis_a.normalized(), angle_a)
	if axis_b != Vector3.ZERO:
		basis = Basis(axis_b.normalized(), angle_b) * basis
	var pivot := base.origin
	var pose := Transform3D(Basis(), pivot) * Transform3D(basis, Vector3.ZERO) \
			* Transform3D(Basis(), -pivot) * base
	_skeleton.set_bone_global_pose(bone_idx, pose)


# --------------------------------------------------------------------------- #
# Full-Body Right-Arm Analytical 2-Bone IK & Finger Gesture Blending
# --------------------------------------------------------------------------- #

func is_right_arm_ik_ready() -> bool:
	return _model != null and _skeleton != null and _upper_arm_r_idx >= 0 \
			and _lower_arm_r_idx >= 0 and _hand_r_idx >= 0


func get_arm_l1_world() -> float:
	if not is_right_arm_ik_ready():
		return FALLBACK_ARM_L1_WORLD
	return _arm_l1_skel * _skel_to_world_scale()


func get_arm_l2_world() -> float:
	if not is_right_arm_ik_ready():
		return FALLBACK_ARM_L2_WORLD
	return _arm_l2_skel * _skel_to_world_scale()


func get_poke_tip_in_hand_local_world() -> Vector3:
	if not is_right_arm_ik_ready():
		return FALLBACK_POKE_TIP_LOCAL_WORLD
	return _poke_tip_in_hand_local_skel * _skel_to_world_scale()


## Composes the un-leaned SeatedPose right-arm chain over the current breathing Chest
## so start/end desk-rest anchors stay exact even while IK is actively driving the arm.
func _seated_right_arm_chain() -> Dictionary:
	if not is_right_arm_ik_ready():
		return {}
	var chest_pose: Transform3D
	if _chest_idx >= 0:
		var chest_base := _composed_base(_chest_idx, _spine_idx)
		var pivot := chest_base.origin
		var b := Basis(Vector3.RIGHT, -_breath_lift * BREATH_CHEST_RAD)
		chest_pose = Transform3D(Basis(), pivot) * Transform3D(b, Vector3.ZERO) \
				* Transform3D(Basis(), -pivot) * chest_base
	else:
		chest_pose = Transform3D.IDENTITY
	var sh_pose: Transform3D
	if _shoulder_r_idx >= 0 and _local_bases.has(_shoulder_r_idx):
		sh_pose = chest_pose * (_local_bases[_shoulder_r_idx] as Transform3D)
	elif _shoulder_r_idx >= 0 and _posed_bases.has(_shoulder_r_idx):
		sh_pose = _posed_bases[_shoulder_r_idx] as Transform3D
	else:
		sh_pose = chest_pose
	var ua_pose: Transform3D = sh_pose * (_local_bases[_upper_arm_r_idx] as Transform3D) \
			if _local_bases.has(_upper_arm_r_idx) else (_posed_bases[_upper_arm_r_idx] as Transform3D)
	var la_pose: Transform3D = ua_pose * (_local_bases[_lower_arm_r_idx] as Transform3D) \
			if _local_bases.has(_lower_arm_r_idx) else (_posed_bases[_lower_arm_r_idx] as Transform3D)
	var hand_pose: Transform3D = la_pose * (_local_bases[_hand_r_idx] as Transform3D) \
			if _local_bases.has(_hand_r_idx) else (_posed_bases[_hand_r_idx] as Transform3D)
	return {"ua": ua_pose, "la": la_pose, "hand": hand_pose}


func get_right_shoulder_main_world_pos() -> Vector3:
	if not is_right_arm_ik_ready():
		return FALLBACK_SHOULDER_MAIN_WORLD
	var ua_base := _composed_base(_upper_arm_r_idx, _shoulder_r_idx)
	return _skeleton.global_transform * ua_base.origin


func get_right_hand_rest_main_world_pos() -> Vector3:
	var chain := _seated_right_arm_chain()
	if chain.is_empty():
		return FALLBACK_HAND_REST_MAIN_WORLD
	return _skeleton.global_transform * (chain["hand"] as Transform3D).origin


func get_right_elbow_rest_main_world_pos() -> Vector3:
	var chain := _seated_right_arm_chain()
	if chain.is_empty():
		return FALLBACK_ELBOW_REST_MAIN_WORLD
	return _skeleton.global_transform * (chain["la"] as Transform3D).origin


func get_right_hand_rest_main_world_basis() -> Basis:
	var chain := _seated_right_arm_chain()
	if chain.is_empty():
		return Basis(
			Vector3(0.89, 0.36, -0.28),
			Vector3(-0.37, 0.22, -0.90),
			Vector3(-0.26, 0.90, 0.33),
		).orthonormalized()
	return (_skeleton.global_transform.basis * (chain["hand"] as Transform3D).basis).orthonormalized()


## Smoothly blends right-hand fingers on Yumeka's real Skeleton3D around each bone's
## verified local flexion axis `(1, 0, 0)` (0.0 = SeatedPose desk-rest, 1.0 = target).
func set_hand_gesture_blend(from_gesture: int, to_gesture: int, weight: float) -> void:
	if _skeleton == null:
		return
	var w := clampf(weight, 0.0, 1.0)
	var from_map: Dictionary = _gesture_delta_quats.get(from_gesture, {})
	var to_map: Dictionary = _gesture_delta_quats.get(to_gesture, {})
	for bname in FINGER_BONES:
		var idx: int = _finger_indices.get(bname, -1)
		if idx < 0:
			continue
		var seated_q: Quaternion = _finger_seated_quats.get(idx, Quaternion.IDENTITY)
		var qa: Quaternion = from_map.get(idx, Quaternion.IDENTITY)
		var qb: Quaternion = to_map.get(idx, Quaternion.IDENTITY)
		_skeleton.set_bone_pose_rotation(idx, seated_q * qa.slerp(qb, w))


## Drives Yumeka's full right arm (`Chest` subtle lean + `Shoulder_R` follow + analytical
## Law-of-Cosines 2-Bone IK on `UpperArm_R -> LowerArm_R -> Hand_R` + forearm pronation
## split onto `LowerArm_twist_R` + finger gesture blend) directly in her real Skeleton3D.
func apply_right_arm_ik(wrist_world: Vector3, hand_basis_world: Basis, pole_world: Vector3,
		gesture_from: int, gesture_to: int, gesture_weight: float,
		target_world: Vector3, lean_weight := 1.0) -> Dictionary:
	_arm_ik_active = true
	_arm_ik_wrist_world = wrist_world
	_arm_ik_hand_basis_world = hand_basis_world.orthonormalized()
	_arm_ik_pole_world = pole_world.normalized() if pole_world.length_squared() > 1e-6 else Vector3(0.92, 0.16, 0.34).normalized()
	_arm_ik_gesture_from = gesture_from
	_arm_ik_gesture_to = gesture_to
	_arm_ik_gesture_weight = clampf(gesture_weight, 0.0, 1.0)
	_arm_ik_target_world = target_world
	_arm_ik_lean = clampf(lean_weight, 0.0, 1.0)
	return _apply_right_arm_ik_now()


func _apply_right_arm_ik_now() -> Dictionary:
	if not is_right_arm_ik_ready():
		return {
			"shoulder_pos": FALLBACK_SHOULDER_MAIN_WORLD,
			"elbow_pos": FALLBACK_ELBOW_REST_MAIN_WORLD,
			"wrist_pos": _arm_ik_wrist_world,
			"fingertip_pos": _arm_ik_wrist_world,
			"elbow_bend_deg": 0.0,
			"ik_stretch": 1.0,
		}

	var lean := _arm_ik_lean
	var aim_x := clampf(_arm_ik_target_world.x / 700.0, -1.0, 1.0)

	# 1. Subtle Chest forward lean + horizontal aim over live breathing Spine.
	if _chest_idx >= 0:
		var chest_base := _composed_base(_chest_idx, _spine_idx)
		var chest_pitch := -_breath_lift * BREATH_CHEST_RAD + deg_to_rad(HAZARD_CHEST_PITCH_DEG) * lean
		var chest_yaw := -aim_x * deg_to_rad(HAZARD_CHEST_YAW_DEG) * lean
		_twist_bone_from_base(_chest_idx, chest_base, Vector3.RIGHT, chest_pitch, Vector3.UP, chest_yaw)

	# 2. Subtle Shoulder_R protraction (+Y skel) and gentle elevation (-Z skel) so cardigan
	#    fabric & shoulder collar deform naturally into the reach with zero seam.
	if _shoulder_r_idx >= 0:
		var sh_base := _composed_base(_shoulder_r_idx, _chest_idx)
		_twist_bone_from_base(
			_shoulder_r_idx,
			sh_base,
			Vector3.UP, deg_to_rad(HAZARD_SHOULDER_PROTRACT_DEG) * lean,
			Vector3.BACK, deg_to_rad(-HAZARD_SHOULDER_ELEVATE_DEG) * lean,
		)

	# 3. Solve analytical 2-Bone IK directly in Skeleton3D space from the live post-lean shoulder.
	var ua_base := _composed_base(_upper_arm_r_idx, _shoulder_r_idx)
	var sh_skel := ua_base.origin
	var world_scale := _skel_to_world_scale()
	var skel_inv := _skeleton.global_transform.affine_inverse()
	var skel_basis_inv := _skeleton.global_transform.basis.orthonormalized().inverse()
	var wr_skel := skel_inv * _arm_ik_wrist_world
	var hand_basis_skel := (skel_basis_inv * _arm_ik_hand_basis_world).orthonormalized()
	var pole_skel := (skel_basis_inv * _arm_ik_pole_world).normalized()

	var w := wr_skel - sh_skel
	var raw_dist := w.length()
	var min_d := absf(_arm_l1_skel - _arm_l2_skel) + 80.0 / world_scale
	var d := maxf(raw_dist, min_d)
	var u := w / raw_dist if raw_dist > 1e-6 else Vector3.BACK

	var max_natural := (_arm_l1_skel + _arm_l2_skel) * IK_SOFT_REACH_RATIO
	var stretch := 1.0
	if d > max_natural:
		stretch = clampf(d / max_natural, 1.0, IK_MAX_STRETCH)
	var e1 := _arm_l1_skel * stretch
	var e2 := _arm_l2_skel * stretch
	var d_eff := minf(d, (e1 + e2) * 0.992)
	var w_eff := u * d_eff

	var pole := pole_skel - u * pole_skel.dot(u)
	if pole.length_squared() < 1e-6:
		pole = Vector3.LEFT - u * (-u.x)
		if pole.length_squared() < 1e-6:
			pole = Vector3.UP - u * u.y
	var v := pole.normalized()

	var cos_a := clampf((e1 * e1 + d_eff * d_eff - e2 * e2) / (2.0 * e1 * d_eff), -1.0, 1.0)
	var sin_a := sqrt(maxf(0.0, 1.0 - cos_a * cos_a))
	var elbow_off := u * (e1 * cos_a) + v * (e1 * sin_a)
	var elbow_skel := sh_skel + elbow_off
	var wrist_eff_skel := sh_skel + w_eff

	# Anatomical twist-free hinge basis (+Y along segment, +Z dorsal skyward, +X pinky/outer).
	var ua_y := elbow_off.normalized()
	var la_vec := w_eff - elbow_off
	var la_y := la_vec.normalized() if la_vec.length_squared() > 1e-6 else ua_y
	var hinge_z := ua_y.cross(la_y)
	if hinge_z.length_squared() < 1e-6:
		hinge_z = Vector3.UP - ua_y * ua_y.y
		if hinge_z.length_squared() < 1e-6:
			hinge_z = Vector3.LEFT
	hinge_z = hinge_z.normalized()
	if hinge_z.dot(Vector3.UP) < -0.15:
		hinge_z = -hinge_z

	var ua_x := ua_y.cross(hinge_z).normalized()
	var ua_z := ua_x.cross(ua_y).normalized()
	var ua_basis := Basis(ua_x, ua_y, ua_z)

	var la_x0 := la_y.cross(hinge_z).normalized()
	var la_z0 := la_x0.cross(la_y).normalized()
	var la_base := Basis(la_x0, la_y, la_z0)

	var target_z_proj := hand_basis_skel.z - la_y * hand_basis_skel.z.dot(la_y)
	var pronation := 0.0
	if target_z_proj.length_squared() > 1e-6:
		var tz := target_z_proj.normalized()
		pronation = atan2(la_z0.cross(tz).dot(la_y), clampf(la_z0.dot(tz), -1.0, 1.0))
		pronation = clampf(pronation, deg_to_rad(-85.0), deg_to_rad(85.0))
	var la_basis := Basis(la_y, pronation * 0.55) * la_base
	var twist_rem := pronation * 0.45

	# Apply in strict parent-to-child order; Hand_R stays strictly 1.0 unscaled orthonormal.
	var seg_scale := Vector3.ONE * stretch
	_skeleton.set_bone_global_pose(_upper_arm_r_idx, Transform3D(ua_basis.scaled(seg_scale), sh_skel))
	if _upper_arm_twist_r_idx >= 0:
		_skeleton.set_bone_pose_rotation(_upper_arm_twist_r_idx, _upper_twist_seated_q)
	_skeleton.set_bone_global_pose(_lower_arm_r_idx, Transform3D(la_basis.scaled(seg_scale), elbow_skel))
	if _lower_arm_twist_r_idx >= 0:
		_skeleton.set_bone_pose_rotation(
			_lower_arm_twist_r_idx, _lower_twist_seated_q * Quaternion(Vector3.UP, twist_rem)
		)
	_skeleton.set_bone_global_pose(_hand_r_idx, Transform3D(hand_basis_skel, wrist_eff_skel))
	set_hand_gesture_blend(_arm_ik_gesture_from, _arm_ik_gesture_to, _arm_ik_gesture_weight)

	# Keep head, neck & irises riding the subtle Chest lean seamlessly on the same frame.
	_recompose_head_and_eyes()

	_last_shoulder_world = _skeleton.global_transform * sh_skel
	_last_elbow_world = _skeleton.global_transform * elbow_skel
	_last_wrist_world = _skeleton.global_transform * wrist_eff_skel
	if _idx_dist_r_idx >= 0:
		var dist_pose := _skeleton.get_bone_global_pose(_idx_dist_r_idx)
		var pad_off := INDEX_PAD_VENTRAL_OFFSET_WORLD / world_scale
		_last_fingertip_world = _skeleton.global_transform * (dist_pose * Vector3(0.0, _index_distal_len_skel, -pad_off))
	else:
		_last_fingertip_world = _last_wrist_world + _arm_ik_hand_basis_world * get_poke_tip_in_hand_local_world()
	_last_elbow_bend_deg = rad_to_deg(acos(clampf(ua_y.dot(la_y), -1.0, 1.0)))
	_last_ik_stretch = stretch

	return {
		"shoulder_pos": _last_shoulder_world,
		"elbow_pos": _last_elbow_world,
		"wrist_pos": _last_wrist_world,
		"fingertip_pos": _last_fingertip_world,
		"elbow_bend_deg": _last_elbow_bend_deg,
		"ik_stretch": _last_ik_stretch,
	}


## Releases right-arm IK and restores Chest, Shoulder_R, arm chain, twist bones & all 15
## fingers cleanly back to SeatedPose over live breathing.
func clear_right_arm_ik() -> void:
	_arm_ik_active = false
	_arm_ik_lean = 0.0
	_arm_ik_gesture_weight = 0.0
	if _skeleton == null:
		return
	if _chest_idx >= 0:
		var chest_base := _composed_base(_chest_idx, _spine_idx)
		_twist_bone_from_base(_chest_idx, chest_base, Vector3.RIGHT, -_breath_lift * BREATH_CHEST_RAD)
	for pair in [
		[_shoulder_r_idx, _chest_idx],
		[_upper_arm_r_idx, _shoulder_r_idx],
		[_lower_arm_r_idx, _upper_arm_r_idx],
		[_hand_r_idx, _lower_arm_r_idx],
	]:
		var child_i: int = pair[0]
		var parent_i: int = pair[1]
		if child_i >= 0:
			_skeleton.set_bone_global_pose(child_i, _composed_base(child_i, parent_i))
	if _upper_arm_twist_r_idx >= 0:
		_skeleton.set_bone_pose_rotation(_upper_arm_twist_r_idx, _upper_twist_seated_q)
	if _lower_arm_twist_r_idx >= 0:
		_skeleton.set_bone_pose_rotation(_lower_arm_twist_r_idx, _lower_twist_seated_q)
	set_hand_gesture_blend(HandGesture.REST_RELAXED, HandGesture.REST_RELAXED, 0.0)
	_recompose_head_and_eyes()


func debug_right_arm_ik_state() -> Dictionary:
	return {
		"active": _arm_ik_active,
		"lean": _arm_ik_lean,
		"gesture_weight": _arm_ik_gesture_weight,
		"elbow_bend_deg": _last_elbow_bend_deg,
		"ik_stretch": _last_ik_stretch,
		"arm_l1_world": get_arm_l1_world(),
		"arm_l2_world": get_arm_l2_world(),
		"shoulder_world": get_right_shoulder_main_world_pos(),
		"hand_rest_world": get_right_hand_rest_main_world_pos(),
		"elbow_world": _last_elbow_world,
		"wrist_world": _last_wrist_world,
		"fingertip_world": _last_fingertip_world,
		"bone_count": _skeleton.get_bone_count() if _skeleton != null else 0,
		"target_world": _arm_ik_target_world,
	}


# --------------------------------------------------------------------------- #
# Debug / test hooks
# --------------------------------------------------------------------------- #

func debug_eye_close() -> float:
	return _blink_state


## Returns a bone's position in 1:1 bedroom-local metres (independent of the
## 6666.67x single-world scale so posture bounds remain human-scale readable).
func debug_bone_pos(bone: String) -> Vector3:
	var wp := debug_bone_world_pos(bone)
	if not wp.is_finite():
		return Vector3.INF
	if _bedroom != null:
		return _bedroom.to_local(wp)
	return wp


## Returns a bone's exact position in main-world harbour metres.
func debug_bone_world_pos(bone: String) -> Vector3:
	if _skeleton == null:
		return Vector3.INF
	var idx := _skeleton.find_bone(bone)
	if idx < 0:
		return Vector3.INF
	return _skeleton.global_transform * _skeleton.get_bone_global_pose(idx).origin


func debug_force_blink() -> void:
	if _blink_anim < 0.0 and _morph_carriers.has("eye_close"):
		_blink_anim = 0.0


func debug_sky_wired() -> bool:
	return _sky != null


func debug_anim_time() -> float:
	return _time


func debug_head_swing() -> Vector2:
	return Vector2(_gaze_yaw, _gaze_pitch)


func debug_eye_swing() -> Vector2:
	return Vector2(_eye_yaw, _eye_pitch)


func debug_eye_bones_ready() -> bool:
	return _eye_l_idx >= 0 and _eye_r_idx >= 0


func get_breath_lift() -> float:
	return _breath_lift


func debug_set_gaze_override(world_pos_or_zero: Vector3) -> void:
	_gaze_override = world_pos_or_zero


func debug_is_mounted() -> bool:
	return _model != null and _skeleton != null and _head_idx >= 0
