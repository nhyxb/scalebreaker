extends CharacterBody3D
## Standalone self-contained experimental prototype for realistic, weighty giant turning locomotion.
## Kept 100% isolated from production gameplay (scenes/giant_visual.gd) until reviewed and approved.
##
## Implements:
## 1. Strict top-down turn cascade: Eyes -> Head -> Chest (~half of head) -> Pelvis -> Feet.
## 2. Spine S-curve torsion & coronal counter-arc + shoulder girdle counter-twist.
## 3. Speed & turn-rate scaled inward banking, weight press onto inside support leg,
##    micro-flexed knees and lowered pelvis for tangible mass.
## 4. Asymmetric arm response (outside arm opens/swings wider, inside arm tucks tighter,
##    preserving Kawaii shoulder-bag clearance).
## 5. World-locked zero-slip footwork across all three regimes:
##    - Standing turns: ship-like multi-step alternating small steps with heel/ball in-place pivots.
##    - Gentle walking curves: toe subtly aims into curve while keeping natural stride.
##    - Sharp walking turns: shorter, faster cadence with outside-long / inside-short strides.
##    - Every step: toe pre-aims into new heading before descent, heel strikes first, then rolls flat.

const CONTACT_FRACTION := 0.60
const HALF_STEP := 0.285
const SWING_HEIGHT := 0.165
const WALK_REF_SPEED := 7.0
const IDLE_FOOT_YAW := 0.045

const PIVOT_HEEL := 0
const PIVOT_BALL := 1

# Exact model-space foot geometry matching kawaii.glb rest pose (verified via inspect_rig.gd).
const TOE_OFFSET := Vector3(0.0, -0.096, 0.064)
const LEFT_SOLE_CENTER := Vector3(0.06208, 0.0, 0.02071)
const HEEL_Z_FROM_ANKLE := -0.046
const BALL_Z_FROM_ANKLE := 0.064
const BALL_JOINT_Y := 0.029437
const ANKLE_GROUND_Y := 0.125219
const HEEL_TO_BALL_DIST := BALL_Z_FROM_ANKLE - HEEL_Z_FROM_ANKLE # 0.110

# Cascade & turn tuning.
const TURN_EYE_MAX_YAW := 0.135
const TURN_HEAD_OVER_CHEST_MAX := 0.78
const TURN_HEAD_OVER_PELVIS_MAX := 1.18
const TURN_CHEST_OVER_PELVIS_MAX := 0.54
const STAND_START_DEADZONE := 0.22      # ~12.6 deg: eyes/head glance without shuffling feet
const STAND_DONE_DEADZONE := 0.06       # ~3.4 deg: settle threshold
const STAND_STEP_MAX_YAW := 0.62        # ~35.5 deg per small ship-like step (~5-6 steps for 180 deg)
const STAND_ANTICIPATION_BASE := 0.15   # Brief look-first beat before first foot lifts
const STAND_STEP_BASE_DUR := 0.52       # Base duration per standing pivot step at 25.2m scale
const STAND_TRANSFER_FRAC := 0.22       # Double-support weight transfer before lifting swing foot
const HEEL_ROLL_SECONDS := 0.13         # Heel-strike to flat sole roll duration
const HEEL_STRIKE_PITCH := -0.25        # Clear anatomical heel-first dorsiflexion (~-14.3 deg)
const WALK_SHARP_ENTER := 0.40          # rad/s or combined metric above which turn becomes "sharp"
const WALK_SHARP_FULL := 1.50           # rad/s at which sharp turn reaches full stride adaptation

const HAIR_FRONT := 0
const HAIR_SIDE_L := 1
const HAIR_SIDE_R := 2
const HAIR_BACK := 3

const GiantSkin := preload("res://scenes/giant_skin.gd")
const SKINS := {
	&"Kawaii": null,
	&"Hina": preload("res://scenes/hina_skin.gd"),
	&"Chibi Catgirl": preload("res://scenes/chibi_catgirl_skin.gd"),
}

const CORE_BONES := [
	"spine", "spine.001", "spine.002", "spine.003", "spine.004",
	"Neck", "Head",
	"shoulder.L", "shoulder.R",
	"upper_arm.L", "upper_arm.R",
	"forearm.L", "forearm.R",
	"hand.L", "hand.R",
]

const FINGER_NAMES := ["f_index", "f_middle", "f_ring", "f_pinky"]


class Leg:
	var side: String
	var sign_x: float
	var thigh: int
	var shin: int
	var foot: int
	var toe: int
	var hip_socket: Vector3
	var upper_length: float
	var lower_length: float
	var thigh_rest: Quaternion
	var shin_rest: Quaternion
	var toe_rest: Quaternion
	var ankle_rest: Vector3
	var foot_basis: Quaternion
	var sole_center: Vector3
	var sole_forward: Vector3
	var ground_y := 0.0
	var ground_pitch := 0.0
	var ground_roll := 0.0
	var last_pitch := 0.0
	var last_roll := 0.0
	var last_yaw := 0.0
	var last_toe := 0.0


class HairChain:
	var bones: PackedInt32Array = PackedInt32Array()
	var rests: Array[Quaternion] = []
	var axes: Array[Basis] = []
	var zone: int = HAIR_BACK
	var phase_offset: float = 0.0
	var lateral_bias: float = 0.0


class FootTrack:
	var side: String = "L"
	var sign_x: float = 1.0
	var planted: bool = true
	var pivot_mode: int = PIVOT_HEEL
	var pivot_world: Vector3 = Vector3.ZERO
	var world_yaw: float = 0.0
	var foot_pitch: float = 0.0
	var toe_bend: float = 0.0
	var heel_settle_t: float = 1.0
	var active_pivoting: float = 0.0

	var swing_start_world: Vector3 = Vector3.ZERO
	var swing_target_world: Vector3 = Vector3.ZERO
	var swing_start_yaw: float = 0.0
	var swing_target_yaw: float = 0.0
	var swing_start_pitch: float = 0.0
	var swing_start_toe: float = 0.0
	var swing_start_lift: float = 0.0
	var swing_bow_sign: float = 1.0
	var swing_t: float = 0.0
	var last_step_length: float = 0.0
	var last_landing_pitch: float = 0.0
	var last_pre_land_yaw_err: float = 0.0


@onready var _skeleton: Skeleton3D = $Model/metarig/Skeleton3D
@onready var _model: Node3D = $Model

var skin_name: StringName = &"Kawaii"
var _active_skin: GiantSkin
var pace := 1.0
var fixed_walk_tempo := false
var size_scaled_walk := false
var use_layered_turn := true
var drive_root_transform := true

var _bone := {}
var _rest := {}
var _axes := {}
var _finger_bones := {}
var _hair_chains: Array[HairChain] = []
var _left: Leg
var _right: Leg
var _hip_rest := Vector3.ZERO
var _model_base_yaw := PI
var _model_base_scale := 14.8

var _left_ankle := Vector3.ZERO
var _right_ankle := Vector3.ZERO
var _pelvis_ground_drop := 0.0

# Locomotion & rhythm state.
var _cycle := 0.0
var _breath := 0.0
var _idle_look_time := 0.0
var _stride := 0.0
var _foot_stride := 0.0
var _step_scale := 1.0
var _move_drive := 0.0
var _turn_rate := 0.0
var _visual_yaw_offset := 0.0

# Secondary spring state (hair & impact jolt).
var _prev_head_world := Vector3.ZERO
var _prev_head_vel := Vector3.ZERO
var _head_tracked := false
var _hair_sway := Vector2.ZERO
var _hair_sway_vel := Vector2.ZERO
var _hair_tip_sway := Vector2.ZERO
var _hair_tip_sway_vel := Vector2.ZERO
var _hair_bounce := 0.0
var _hair_bounce_vel := 0.0
var _hair_tip_bounce := 0.0
var _hair_tip_bounce_vel := 0.0
var _hair_rot := 0.0
var _hair_rot_vel := 0.0
var _hair_tip_rot := 0.0
var _hair_tip_rot_vel := 0.0
var _impact_jolt := 0.0
var _impact_jolt_vel := 0.0

# Eyes & facial blend shapes.
var _eye_l := -1
var _eye_r := -1
var _eye_l_rest := Quaternion.IDENTITY
var _eye_r_rest := Quaternion.IDENTITY
var _eye_l_axes := Basis.IDENTITY
var _eye_r_axes := Basis.IDENTITY
var _eye_gaze := Vector2.ZERO
var _eye_idle_target := Vector2.ZERO
var _head_idle_gaze := Vector2.ZERO
var _gaze_timer := 1.4
var _blink_targets: Array[Dictionary] = []
var _blink_timer := 2.4
var _blink_progress := -1.0
var _double_blink_queued := false
var _blink_seed := 137

# Hierarchical world-space turn state (Eye -> Head -> Chest -> Pelvis -> Feet).
var _turn_ready := false
var _target_yaw := 0.0
var _desired_speed := 0.0
var _actual_speed := 0.0
var _actual_world_vel := Vector3.ZERO
var _turn_mode := "idle"

var _eye_world_yaw := 0.0
var _eye_local_yaw := 0.0
var _eye_override := 0.0
var _head_world_yaw := 0.0
var _head_yaw_vel := 0.0
var _chest_world_yaw := 0.0
var _chest_rel_pelvis := 0.0
var _chest_rel_vel := 0.0
var _pelvis_world_yaw := 0.0
var _pelvis_yaw_vel := 0.0

var _effective_turn_rate := 0.0
var _turn_urgency := 0.0
var _turn_sharpness := 0.0
var _turn_sign := 0.0
var _inward_lean := 0.0        # Signed: + = lean LEFT (+X), - = lean RIGHT (-X)
var _inward_lean_vel := 0.0
var _turn_crouch := 0.0
var _turn_stride_mult := 1.0
var _turn_cadence_mult := 1.0
var _turn_weight_x := 0.0
var _stand_arm_phase := 0.0

# Standing multi-step pivot state machine.
var _stand_turning := false
var _stand_dir := 0.0          # +1 left, -1 right
var _stand_anticipation := 0.0
var _stand_step_active := false
var _stand_step_side := ""
var _stand_last_step_side := ""
var _stand_step_elapsed := 0.0
var _stand_step_dur := STAND_STEP_BASE_DUR
var _stand_step_count := 0
var _stand_step_pelvis_start := 0.0
var _stand_step_pelvis_goal := 0.0
var _stand_support_yaw_start := 0.0
var _stand_support_yaw_goal := 0.0
var _stand_land_dip := 0.0
var _stand_just_landed := ""

# World-locked foot trackers.
var _foot_l: FootTrack
var _foot_r: FootTrack
var _walk_was_moving := false
var _walk_cycle_prev := 0.0

# Cached telemetry for inspection & automated tests.
var _last_hip_local := Vector3.ZERO
var _last_l_knee_deg := 0.0
var _last_r_knee_deg := 0.0
var _last_l_arm_open := 0.0
var _last_r_arm_open := 0.0
var _last_l_arm_amp := 0.0
var _last_r_arm_amp := 0.0
var _last_shoulder_counter := 0.0
var _last_spine_s_curve := 0.0


func _ready() -> void:
	set_process(false)
	for child in _model.get_children():
		if child.name != &"metarig":
			child.queue_free()
	_model_base_yaw = _model.rotation.y
	_model_base_scale = _model.scale.z

	for key in CORE_BONES:
		var index := _skeleton.find_bone(key)
		_bone[key] = index
		_rest[key] = _skeleton.get_bone_pose_rotation(index)
		_axes[key] = _skeleton.get_bone_global_rest(index).basis.orthonormalized().inverse()

	_init_fingers()
	_init_hair_chains()
	_init_face()

	_left = _make_leg("L")
	_right = _make_leg("R")
	_hip_rest = _skeleton.get_bone_pose_position(_bone["spine"])
	_left_ankle = _left.ankle_rest
	_right_ankle = _right.ankle_rest

	_ensure_turn_initialized()
	reset_turn_state(global_position, global_rotation.y)


func _ensure_turn_initialized() -> void:
	if _turn_ready:
		return
	_foot_l = FootTrack.new()
	_foot_l.side = "L"
	_foot_l.sign_x = 1.0
	_foot_r = FootTrack.new()
	_foot_r.side = "R"
	_foot_r.sign_x = -1.0
	_turn_ready = true


func set_skin_by_name(next: StringName) -> void:
	if next == skin_name:
		return
	if _active_skin != null:
		_active_skin.free()
		_active_skin = null
	skin_name = next
	var skin_script: Script = SKINS[next]
	if skin_script != null:
		_active_skin = skin_script.new()
		_active_skin.name = next
		_model.add_child(_active_skin)
		_active_skin.configure(_skeleton)
		_active_skin.follow_pose()
	_skeleton.visible = _active_skin == null


func set_height_meters(height_m: float) -> void:
	var factor := clampf(height_m / 25.2, 0.25, 25.0)
	_model.scale = Vector3.ONE * (_model_base_scale * factor)
	reset_turn_state(global_position, _pelvis_world_yaw)


func reset_turn_state(world_pos: Vector3, world_yaw: float) -> void:
	_ensure_turn_initialized()
	global_position = world_pos
	global_rotation = Vector3(0.0, world_yaw, 0.0)
	_target_yaw = world_yaw
	_eye_world_yaw = world_yaw
	_eye_local_yaw = 0.0
	_eye_override = 0.0
	_head_world_yaw = world_yaw
	_head_yaw_vel = 0.0
	_chest_world_yaw = world_yaw
	_chest_rel_pelvis = 0.0
	_chest_rel_vel = 0.0
	_pelvis_world_yaw = world_yaw
	_pelvis_yaw_vel = 0.0
	_visual_yaw_offset = 0.0
	_model.rotation.y = _model_base_yaw
	_turn_rate = 0.0
	_effective_turn_rate = 0.0
	_turn_urgency = 0.0
	_turn_sharpness = 0.0
	_turn_sign = 0.0
	_inward_lean = 0.0
	_inward_lean_vel = 0.0
	_turn_crouch = 0.0
	_turn_stride_mult = 1.0
	_turn_cadence_mult = 1.0
	_turn_weight_x = 0.0
	_stand_arm_phase = 0.0
	_desired_speed = 0.0
	_actual_speed = 0.0
	_actual_world_vel = Vector3.ZERO
	_turn_mode = "idle"
	_stride = 0.0
	_foot_stride = 0.0
	_move_drive = 0.0
	_cycle = 0.0
	_walk_cycle_prev = 0.0
	_walk_was_moving = false
	_head_tracked = false
	_impact_jolt = 0.0
	_impact_jolt_vel = 0.0

	_stand_turning = false
	_stand_dir = 0.0
	_stand_anticipation = 0.0
	_stand_step_active = false
	_stand_step_side = ""
	_stand_last_step_side = ""
	_stand_step_elapsed = 0.0
	_stand_step_count = 0
	_stand_land_dip = 0.0
	_stand_just_landed = ""

	_reset_foot_to_rest(_foot_l, _left, world_pos, world_yaw)
	_reset_foot_to_rest(_foot_r, _right, world_pos, world_yaw)
	_apply_layered_pose(0.0)
	_update_face(0.0)
	if _active_skin != null:
		_active_skin.follow_pose()


func _reset_foot_to_rest(ft: FootTrack, leg: Leg, body_pos: Vector3, body_yaw: float) -> void:
	var S := _model.scale.z
	var foot_yaw := body_yaw + leg.sign_x * IDLE_FOOT_YAW
	var ankle_w := _rest_ankle_world(leg, body_pos, body_yaw, 0.0, 0.0)
	ft.planted = true
	ft.pivot_mode = PIVOT_HEEL
	ft.world_yaw = foot_yaw
	ft.foot_pitch = 0.0
	ft.toe_bend = 0.0
	ft.heel_settle_t = 1.0
	ft.active_pivoting = 0.0
	ft.pivot_world = ankle_w - Vector3.UP * (ANKLE_GROUND_Y * S) + _yaw_forward(foot_yaw) * (HEEL_Z_FROM_ANKLE * S)
	ft.swing_start_world = ankle_w
	ft.swing_target_world = ankle_w
	ft.swing_start_yaw = foot_yaw
	ft.swing_target_yaw = foot_yaw
	ft.swing_t = 0.0
	ft.last_step_length = 0.0
	ft.last_landing_pitch = 0.0
	ft.last_pre_land_yaw_err = 0.0


## Main standalone prototype entry point: advances desired heading & locomotion speed by delta.
func step_turn_demo(target_yaw: float, desired_speed: float, delta: float) -> Variant:
	_ensure_turn_initialized()
	var dt := clampf(delta, 0.0, 0.05)
	_target_yaw = target_yaw
	_desired_speed = maxf(desired_speed, 0.0)

	_breath = fmod(_breath + dt * 1.55, TAU)
	_idle_look_time = fmod(_idle_look_time + dt, 1000.0)
	_stand_just_landed = ""

	if not use_layered_turn:
		return _step_legacy_comparison(target_yaw, _desired_speed, dt)

	var body_ratio := _model.scale.z / _model_base_scale
	var scale_ratio := maxf(body_ratio, 0.15)
	var tempo_scale := clampf(pace / sqrt(scale_ratio), 0.35, 2.5)
	var moving := _desired_speed > 0.12 * minf(body_ratio, 1.0)

	# 1. Advance pelvis & world-locked footwork according to standing vs walking regime.
	var contact: Variant = null
	if moving:
		contact = _step_walking_turn(dt, scale_ratio, tempo_scale)
	else:
		contact = _step_standing_turn(dt, scale_ratio, tempo_scale)

	# 2. Update top-down yaw cascade: Eyes -> Head -> Chest (Pelvis already updated above).
	_update_yaw_cascade(dt, tempo_scale, moving)

	# 3. Update inward banking, crouch depth, and lateral weight shift.
	_update_body_dynamics(dt, tempo_scale, moving)

	# 4. Sync CharacterBody3D / Model orientation cleanly.
	if drive_root_transform:
		global_rotation = Vector3(0.0, _pelvis_world_yaw, 0.0)
		_visual_yaw_offset = 0.0
	else:
		_visual_yaw_offset = angle_difference(global_rotation.y, _pelvis_world_yaw)
	_model.rotation.y = _model_base_yaw + _visual_yaw_offset

	var head_ang_vel := _head_yaw_vel if absf(_head_yaw_vel) > absf(_pelvis_yaw_vel) else _pelvis_yaw_vel
	_turn_rate = lerpf(_turn_rate, clampf(head_ang_vel, -4.5, 4.5), minf(dt * 8.0, 1.0)) if dt > 0.0 else 0.0

	# 5. Pose full skeleton.
	_apply_layered_pose(dt)

	if contact != null:
		_trigger_impact_impulse(0.26 * maxf(_stride, 0.42))

	_update_impact_jolt(dt)
	_update_hair(dt)
	_update_face(dt)
	if _active_skin != null:
		_active_skin.follow_pose()
	return contact


## Legacy comparison path (reproduces the original rigid body-block turn for A/B preview comparison).
func _step_legacy_comparison(target_yaw: float, desired_speed: float, dt: float) -> Variant:
	var scale := maxf(_model.scale.z / _model_base_scale, 0.15)
	var diff := angle_difference(global_rotation.y, target_yaw)
	var size_factor := clampf(pow(scale, -0.16), 0.75, 1.0)
	var max_speed := 3.4 * size_factor
	var stiffness := 22.0 * size_factor
	var damping := 9.0 * sqrt(size_factor)
	var eff_dt := dt * pace
	var accel := diff * stiffness - _pelvis_yaw_vel * damping
	_pelvis_yaw_vel = clampf(_pelvis_yaw_vel + accel * eff_dt, -max_speed, max_speed)
	var yaw_step := _pelvis_yaw_vel * eff_dt
	var next_yaw := global_rotation.y + yaw_step
	if absf(diff) < 0.002 and absf(_pelvis_yaw_vel) < 0.02:
		_pelvis_yaw_vel = 0.0
		next_yaw = target_yaw
	elif absf(yaw_step) > absf(diff) and signf(yaw_step) == signf(diff):
		_pelvis_yaw_vel = 0.0
		next_yaw = target_yaw
	global_rotation = Vector3(0.0, next_yaw, 0.0)
	_model.rotation.y = _model_base_yaw
	if desired_speed > 0.01:
		global_position += _yaw_forward(next_yaw) * desired_speed * dt
		_stride = move_toward(_stride, 1.0, dt * 5.2)
		_move_drive = move_toward(_move_drive, 1.0, dt * 5.5)
		var stride_len := 2.0 * HALF_STEP * _model.scale.z / CONTACT_FRACTION
		_cycle = fposmod(_cycle + desired_speed * dt / stride_len, 1.0)
	else:
		_stride = move_toward(_stride, 0.0, dt * 4.2)
		_move_drive = move_toward(_move_drive, 0.0, dt * 4.5)
	_pelvis_world_yaw = next_yaw
	_chest_world_yaw = next_yaw
	_head_world_yaw = next_yaw
	_eye_world_yaw = next_yaw
	_eye_local_yaw = 0.0
	_inward_lean = 0.0
	_turn_crouch = 0.0
	_turn_weight_x = 0.0
	_turn_rate = lerpf(_turn_rate, clampf(_pelvis_yaw_vel, -4.5, 4.5), minf(dt * 7.5, 1.0)) if dt > 0.0 else 0.0
	_turn_mode = "legacy_walk" if desired_speed > 0.12 else "legacy_stand"
	_reset_foot_to_rest(_foot_l, _left, global_position, next_yaw)
	_reset_foot_to_rest(_foot_r, _right, global_position, next_yaw)
	_apply_layered_pose(dt)
	_update_hair(dt)
	_update_face(dt)
	if _active_skin != null:
		_active_skin.follow_pose()
	return null


func _step_standing_turn(dt: float, scale_ratio: float, tempo_scale: float) -> Variant:
	_actual_speed = move_toward(_actual_speed, 0.0, dt * 18.0)
	_actual_world_vel = _actual_world_vel.move_toward(Vector3.ZERO, dt * 18.0)
	_stride = move_toward(_stride, 0.0, dt * 5.0)
	_foot_stride = move_toward(_foot_stride, 0.0, dt * 5.0)
	_move_drive = move_toward(_move_drive, 0.0, dt * 5.0)
	_turn_stride_mult = lerpf(_turn_stride_mult, 1.0, minf(dt * 5.0, 1.0))
	_turn_cadence_mult = lerpf(_turn_cadence_mult, 1.0, minf(dt * 5.0, 1.0))
	_walk_was_moving = false

	# If we stopped walking while a foot was mid-swing, finish landing it cleanly first!
	if not _stand_step_active and (not _foot_l.planted or not _foot_r.planted):
		var air_ft := _foot_l if not _foot_l.planted else _foot_r
		var air_leg := _left if air_ft == _foot_l else _right
		_begin_finish_walk_foot_for_stand(air_ft, air_leg)

	var pelvis_err := angle_difference(_pelvis_world_yaw, _target_yaw)
	var feet_mean_yaw := _mean_angle(_foot_l.world_yaw, _foot_r.world_yaw)
	var feet_err := angle_difference(feet_mean_yaw, _target_yaw)
	var foot_mismatch := absf(angle_difference(_foot_l.world_yaw - IDLE_FOOT_YAW, _foot_r.world_yaw + IDLE_FOOT_YAW))

	var needs_turn := absf(pelvis_err) >= STAND_START_DEADZONE or absf(feet_err) >= STAND_START_DEADZONE
	var needs_square := _stand_turning and (absf(pelvis_err) >= STAND_DONE_DEADZONE or absf(feet_err) >= STAND_DONE_DEADZONE or foot_mismatch >= 0.14)

	if not _stand_turning and needs_turn:
		_stand_turning = true
		_stand_dir = 1.0 if pelvis_err >= 0.0 else -1.0
		_stand_anticipation = STAND_ANTICIPATION_BASE / maxf(tempo_scale, 0.5)
		_stand_step_count = 0
		_stand_last_step_side = ""

	if _stand_turning and not _stand_step_active:
		if not needs_turn and not needs_square:
			_stand_turning = false
			_stand_dir = 0.0
			_stand_anticipation = 0.0
			_turn_mode = "idle"
		else:
			if absf(pelvis_err) >= STAND_DONE_DEADZONE:
				var next_dir := 1.0 if pelvis_err >= 0.0 else -1.0
				if next_dir != _stand_dir and _stand_step_count > 0:
					_stand_dir = next_dir
					_stand_last_step_side = ""
			_turn_mode = "standing_turn"
			if _stand_anticipation > 0.0:
				_stand_anticipation = maxf(_stand_anticipation - dt, 0.0)
				# Pelvis begins yielding gently into the chest torsion right before step 1 lifts,
				# so you see Eye -> Head -> Chest -> Pelvis turning BEFORE the feet even move!
				var ant_frac := 1.0 - clampf(_stand_anticipation / maxf(STAND_ANTICIPATION_BASE / maxf(tempo_scale, 0.5), 0.01), 0.0, 1.0)
				var feet_anchor_yaw := _mean_angle(_foot_l.world_yaw, _foot_r.world_yaw)
				var pre_pelvis_lead := clampf(angle_difference(feet_anchor_yaw, _target_yaw) * 0.22, -0.18, 0.18) * smoothstep(0.25, 1.0, ant_frac)
				var prev_py := _pelvis_world_yaw
				_pelvis_world_yaw = lerp_angle(_pelvis_world_yaw, feet_anchor_yaw + pre_pelvis_lead, minf(dt * 8.0, 1.0))
				if dt > 0.0:
					_pelvis_yaw_vel = angle_difference(prev_py, _pelvis_world_yaw) / dt
			else:
				_start_standing_pivot_step(tempo_scale)
	elif not _stand_step_active:
		_turn_mode = "idle"
		_pelvis_yaw_vel = lerpf(_pelvis_yaw_vel, 0.0, minf(dt * 10.0, 1.0))

	var contact: Variant = null
	if _stand_step_active:
		_turn_mode = "standing_turn"
		_stand_step_elapsed += dt
		var u := clampf(_stand_step_elapsed / maxf(_stand_step_dur, 0.01), 0.0, 1.0)
		var swg_ft := _foot_l if _stand_step_side == "L" else _foot_r
		var sup_ft := _foot_r if _stand_step_side == "L" else _foot_l
		var swg_leg := _left if _stand_step_side == "L" else _right
		var sup_leg := _right if _stand_step_side == "L" else _left

		if u < STAND_TRANSFER_FRAC:
			swg_ft.planted = true
			sup_ft.planted = true
			sup_ft.active_pivoting = 0.0
			_advance_heel_settle(swg_ft, dt)
			_advance_heel_settle(sup_ft, dt)
			var pre_u := smoothstep(0.0, STAND_TRANSFER_FRAC, u)
			var prev_py := _pelvis_world_yaw
			_pelvis_world_yaw = lerp_angle(_stand_step_pelvis_start, _stand_step_pelvis_goal, pre_u * 0.32)
			if dt > 0.0:
				_pelvis_yaw_vel = angle_difference(prev_py, _pelvis_world_yaw) / dt
		else:
			var swing_t := clampf((u - STAND_TRANSFER_FRAC) / (1.0 - STAND_TRANSFER_FRAC), 0.0, 1.0)
			if swg_ft.planted:
				var start_ankle := _foot_ankle_world(swg_ft, swg_leg)
				swg_ft.planted = false
				swg_ft.swing_start_world = start_ankle
				swg_ft.swing_start_yaw = swg_ft.world_yaw
				swg_ft.swing_start_pitch = swg_ft.foot_pitch
				swg_ft.swing_start_toe = swg_ft.toe_bend
				swg_ft.swing_start_lift = maxf(start_ankle.y - (global_position.y + ANKLE_GROUND_Y * _model.scale.z), 0.0)
				var sup_is_inside := (sup_leg.sign_x * _stand_dir > 0.0)
				_switch_planted_pivot(sup_ft, PIVOT_HEEL if sup_is_inside else PIVOT_BALL)

			swg_ft.swing_t = swing_t
			_advance_heel_settle(sup_ft, dt)

			# Support foot in-place pivot strictly around its locked heel or ball (ZERO horizontal slip!).
			var piv_u := smoothstep(0.18, 0.92, swing_t)
			sup_ft.world_yaw = lerp_angle(_stand_support_yaw_start, _stand_support_yaw_goal, piv_u)
			var piv_env := sin(PI * clampf(inverse_lerp(0.18, 0.92, swing_t), 0.0, 1.0))
			sup_ft.active_pivoting = piv_env if absf(angle_difference(_stand_support_yaw_start, _stand_support_yaw_goal)) > 0.03 else 0.0
			if sup_ft.heel_settle_t >= 1.0:
				if sup_ft.pivot_mode == PIVOT_BALL:
					sup_ft.foot_pitch = 0.085 * sup_ft.active_pivoting
					sup_ft.toe_bend = sup_ft.foot_pitch * 0.85
				else:
					sup_ft.foot_pitch = -0.055 * sup_ft.active_pivoting
					sup_ft.toe_bend = 0.0

			# Pelvis leads the swinging foot smoothly (still lagging behind chest & head!).
			var prev_py := _pelvis_world_yaw
			var pelv_u := 0.32 + 0.68 * smoothstep(0.0, 0.82, swing_t)
			_pelvis_world_yaw = lerp_angle(_stand_step_pelvis_start, _stand_step_pelvis_goal, pelv_u)
			if dt > 0.0:
				_pelvis_yaw_vel = angle_difference(prev_py, _pelvis_world_yaw) / dt

			# Swing foot pre-aims toe into new heading BEFORE descent & dorsiflexes for heel-first contact!
			swg_ft.world_yaw = lerp_angle(swg_ft.swing_start_yaw, swg_ft.swing_target_yaw, smoothstep(0.08, 0.76, swing_t))
			if swing_t < 0.30:
				var k := smoothstep(0.0, 0.30, swing_t)
				swg_ft.foot_pitch = lerpf(swg_ft.swing_start_pitch, 0.14, k)
				swg_ft.toe_bend = lerpf(swg_ft.swing_start_toe, 0.0, k)
			else:
				var k := smoothstep(0.30, 0.88, swing_t)
				swg_ft.foot_pitch = lerpf(0.14, HEEL_STRIKE_PITCH, k)
				swg_ft.toe_bend = 0.0

			if swing_t >= 0.80 and swing_t < 0.96:
				swg_ft.last_pre_land_yaw_err = absf(angle_difference(swg_ft.world_yaw, swg_ft.swing_target_yaw))

			var side_sign := 1.0 if _stand_step_side == "L" else -1.0
			_stand_arm_phase = lerpf(_stand_arm_phase, side_sign * sin(PI * swing_t), minf(dt * 12.0, 1.0))

			if u >= 1.0:
				swg_ft.world_yaw = swg_ft.swing_target_yaw
				swg_ft.foot_pitch = HEEL_STRIKE_PITCH
				swg_ft.toe_bend = 0.0
				swg_ft.last_landing_pitch = swg_ft.foot_pitch
				swg_ft.planted = true
				swg_ft.pivot_mode = PIVOT_HEEL
				swg_ft.heel_settle_t = 0.0
				swg_ft.active_pivoting = 0.0
				var S := _model.scale.z
				var land_heel := swg_ft.swing_target_world - Vector3.UP * (ANKLE_GROUND_Y * S) + _yaw_forward(swg_ft.world_yaw) * (HEEL_Z_FROM_ANKLE * S)
				land_heel.y = global_position.y
				swg_ft.pivot_world = land_heel

				sup_ft.active_pivoting = 0.0
				sup_ft.foot_pitch = 0.0
				sup_ft.toe_bend = 0.0
				_stand_step_active = false
				_stand_last_step_side = _stand_step_side
				_stand_land_dip = 1.0
				_stand_just_landed = _stand_step_side
				contact = _foot_contact(swg_leg)
	else:
		_advance_heel_settle(_foot_l, dt)
		_advance_heel_settle(_foot_r, dt)
		_stand_arm_phase = move_toward(_stand_arm_phase, 0.0, dt * 4.5)

	_stand_land_dip = move_toward(_stand_land_dip, 0.0, dt * 3.8)
	var _unused_scale := scale_ratio
	return contact


func _begin_finish_walk_foot_for_stand(air_ft: FootTrack, air_leg: Leg) -> void:
	# Continue the airborne foot seamlessly from its exact current world position and height (zero pop!).
	var cur_ankle := _foot_ankle_world(air_ft, air_leg)
	var S := _model.scale.z
	_stand_step_active = true
	_stand_step_side = air_ft.side
	var rem := clampf(1.0 - air_ft.swing_t, 0.25, 1.0)
	_stand_step_dur = clampf(0.32 * rem / (1.0 - STAND_TRANSFER_FRAC), 0.14, 0.42)
	# Start immediately in the swing portion (u = STAND_TRANSFER_FRAC) so the foot NEVER snaps back to planted!
	_stand_step_elapsed = STAND_TRANSFER_FRAC * _stand_step_dur
	_stand_step_pelvis_start = _pelvis_world_yaw
	_stand_step_pelvis_goal = _pelvis_world_yaw
	var sup_ft := _foot_r if air_ft == _foot_l else _foot_l
	_stand_support_yaw_start = sup_ft.world_yaw
	_stand_support_yaw_goal = sup_ft.world_yaw
	air_ft.planted = false
	air_ft.swing_start_world = cur_ankle
	air_ft.swing_start_yaw = air_ft.world_yaw
	air_ft.swing_start_pitch = air_ft.foot_pitch
	air_ft.swing_start_toe = air_ft.toe_bend
	air_ft.swing_start_lift = maxf(cur_ankle.y - (global_position.y + ANKLE_GROUND_Y * S), 0.0)
	air_ft.swing_t = 0.0
	air_ft.swing_target_yaw = _pelvis_world_yaw + air_leg.sign_x * IDLE_FOOT_YAW
	air_ft.swing_target_world = _rest_ankle_world(air_leg, global_position, _pelvis_world_yaw, 0.0, 0.0)


func _start_standing_pivot_step(tempo_scale: float) -> void:
	var pelvis_err := angle_difference(_pelvis_world_yaw, _target_yaw)
	var dir := 1.0 if pelvis_err >= 0.0 else -1.0
	if absf(pelvis_err) < STAND_DONE_DEADZONE:
		dir = _stand_dir if _stand_dir != 0.0 else 1.0
	_stand_dir = dir

	# Outside foot ALWAYS steps first while weight presses into inside leg; then strictly alternate!
	var outside_side := "R" if dir > 0.0 else "L"
	var step_side: String
	if _stand_last_step_side == "":
		step_side = outside_side
	else:
		step_side = "R" if _stand_last_step_side == "L" else "L"

	var swg_ft := _foot_l if step_side == "L" else _foot_r
	var sup_ft := _foot_r if step_side == "L" else _foot_l
	var swg_leg := _left if step_side == "L" else _right
	var sup_leg := _right if step_side == "L" else _left

	var swg_idle_off := swg_leg.sign_x * IDLE_FOOT_YAW
	var sup_idle_off := sup_leg.sign_x * IDLE_FOOT_YAW
	var sup_heading := sup_ft.world_yaw - sup_idle_off
	var swg_heading := swg_ft.world_yaw - swg_idle_off

	var rem_from_sup := angle_difference(sup_heading, _target_yaw)
	var rem_from_swg := angle_difference(swg_heading, _target_yaw)

	var step_heading: float
	if absf(rem_from_sup) <= STAND_STEP_MAX_YAW * 1.08:
		step_heading = _target_yaw
	else:
		step_heading = sup_heading + clampf(rem_from_sup, -STAND_STEP_MAX_YAW, STAND_STEP_MAX_YAW)

	var swg_advance := angle_difference(swg_heading, step_heading)
	if absf(swg_advance) < 0.06 and absf(rem_from_swg) > 0.08:
		step_heading = swg_heading + clampf(rem_from_swg, -STAND_STEP_MAX_YAW, STAND_STEP_MAX_YAW)

	# Controlled in-place heel/ball pivot on planted support foot.
	var sup_rem := angle_difference(sup_heading, step_heading)
	var sup_pivot_delta := clampf(sup_rem * 0.34, -0.22, 0.22)
	if signf(sup_pivot_delta) == signf(rem_from_sup) and absf(sup_pivot_delta) > absf(rem_from_sup):
		sup_pivot_delta = rem_from_sup
	var sup_next_heading := sup_heading + sup_pivot_delta

	var pelv_goal := _mean_angle(sup_next_heading, step_heading)
	if absf(angle_difference(step_heading, _target_yaw)) < 0.04 and absf(angle_difference(sup_next_heading, _target_yaw)) < 0.24:
		pelv_goal = lerp_angle(pelv_goal, _target_yaw, 0.65)

	var widen := 0.016
	var target_ankle := _rest_ankle_world(swg_leg, global_position, step_heading, 0.0, widen)
	var sup_ankle := _foot_ankle_world(sup_ft, sup_leg)
	var S := _model.scale.z
	var min_sep := 0.135 * S
	var horiz_sep := Vector3(target_ankle.x - sup_ankle.x, 0.0, target_ankle.z - sup_ankle.z)
	if horiz_sep.length() < min_sep:
		var push_dir := _yaw_left(step_heading) * swg_leg.sign_x
		target_ankle += push_dir * (min_sep - horiz_sep.length())

	var cur_ankle := _foot_ankle_world(swg_ft, swg_leg)
	swg_ft.swing_start_world = cur_ankle
	swg_ft.swing_target_world = target_ankle
	swg_ft.swing_start_yaw = swg_ft.world_yaw
	swg_ft.swing_target_yaw = step_heading + swg_idle_off
	swg_ft.last_step_length = Vector2(target_ankle.x - cur_ankle.x, target_ankle.z - cur_ankle.z).length()
	swg_ft.swing_bow_sign = swg_leg.sign_x
	swg_ft.swing_t = 0.0

	_stand_step_active = true
	_stand_step_side = step_side
	_stand_step_elapsed = 0.0
	var mag_factor := clampf(absf(angle_difference(swg_heading, step_heading)) / STAND_STEP_MAX_YAW, 0.65, 1.0)
	_stand_step_dur = clampf((STAND_STEP_BASE_DUR * lerpf(0.76, 1.05, mag_factor)) / maxf(tempo_scale, 0.45), 0.24, 1.15)
	_stand_step_pelvis_start = _pelvis_world_yaw
	_stand_step_pelvis_goal = pelv_goal
	_stand_support_yaw_start = sup_ft.world_yaw
	_stand_support_yaw_goal = sup_next_heading + sup_idle_off
	_stand_step_count += 1


func _step_walking_turn(dt: float, scale_ratio: float, tempo_scale: float) -> Variant:
	_stand_turning = false
	_stand_step_active = false
	_stand_anticipation = 0.0

	var diff := angle_difference(_pelvis_world_yaw, _target_yaw)
	var size_factor := clampf(pow(scale_ratio, -0.16), 0.72, 1.0)
	var max_yaw_speed := 2.35 * size_factor * clampf(pace, 0.5, 2.2)
	var stiffness := 11.5 * size_factor * clampf(pace, 0.6, 2.0)
	var damping := 6.6 * sqrt(size_factor) * sqrt(clampf(pace, 0.6, 2.0))
	var yaw_acc := diff * stiffness - _pelvis_yaw_vel * damping
	_pelvis_yaw_vel = clampf(_pelvis_yaw_vel + yaw_acc * dt, -max_yaw_speed, max_yaw_speed)
	var yaw_step := _pelvis_yaw_vel * dt
	if absf(diff) < 0.002 and absf(_pelvis_yaw_vel) < 0.02:
		_pelvis_yaw_vel = 0.0
		_pelvis_world_yaw = _target_yaw
	elif absf(yaw_step) > absf(diff) and signf(yaw_step) == signf(diff):
		_pelvis_yaw_vel = 0.0
		_pelvis_world_yaw = _target_yaw
	else:
		_pelvis_world_yaw += yaw_step

	var turn_metric := maxf(absf(_pelvis_yaw_vel), absf(diff) * 0.90)
	var target_sharp := smoothstep(WALK_SHARP_ENTER, WALK_SHARP_FULL, turn_metric)
	_turn_sharpness = lerpf(_turn_sharpness, target_sharp, minf(dt * 7.5, 1.0)) if dt > 0.0 else target_sharp

	if absf(diff) > 0.03 or absf(_pelvis_yaw_vel) > 0.05:
		var raw_sign := 1.0 if (_pelvis_yaw_vel + diff * 1.4) >= 0.0 else -1.0
		_turn_sign = lerpf(_turn_sign, raw_sign, minf(dt * 10.0, 1.0))
	else:
		_turn_sign = move_toward(_turn_sign, 0.0, dt * 5.0)

	if _turn_sharpness > 0.20:
		_turn_mode = "walk_sharp_turn"
	elif turn_metric > 0.08:
		_turn_mode = "walk_gentle_turn"
	else:
		_turn_mode = "walk_straight"

	var target_stride_mult := lerpf(1.0, 0.58, _turn_sharpness)
	var target_cadence_mult := lerpf(1.0, 1.38, _turn_sharpness)
	_turn_stride_mult = lerpf(_turn_stride_mult, target_stride_mult, minf(dt * 7.0, 1.0)) if dt > 0.0 else target_stride_mult
	_turn_cadence_mult = lerpf(_turn_cadence_mult, target_cadence_mult, minf(dt * 7.0, 1.0)) if dt > 0.0 else target_cadence_mult

	var corner_speed_mult := lerpf(1.0, 0.80, _turn_sharpness)
	var target_speed := _desired_speed * corner_speed_mult
	_actual_speed = move_toward(_actual_speed, target_speed, dt * maxf(18.0, _desired_speed * 3.0))
	var heading_fwd := _yaw_forward(_pelvis_world_yaw)
	_actual_world_vel = heading_fwd * _actual_speed
	if drive_root_transform:
		global_position += _actual_world_vel * dt

	var body_ratio := _model.scale.z / _model_base_scale
	var target_step_scale := clampf(pow(minf(3.5 / scale_ratio, 1.0), 0.62), 0.30, 1.0)
	_step_scale = lerpf(_step_scale, target_step_scale, minf(dt * 4.5, 1.0)) if dt > 0.0 else target_step_scale

	var cycle_speed := WALK_REF_SPEED * pace if fixed_walk_tempo else _actual_speed
	var reference_speed := cycle_speed if fixed_walk_tempo else WALK_REF_SPEED * 0.80 * clampf(pace, 0.1, 1.0)
	if size_scaled_walk or fixed_walk_tempo:
		reference_speed *= minf(body_ratio, 1.0)
	var stride_target := clampf(_actual_speed / maxf(reference_speed, 0.01), 0.0, 1.0)
	_stride = move_toward(_stride, stride_target, dt * 5.2)
	_foot_stride = move_toward(_foot_stride, stride_target, dt * 5.2)
	_move_drive = move_toward(_move_drive, stride_target, dt * 5.5)

	var stride_scale := _model_base_scale if fixed_walk_tempo else _step_scale * _model.scale.z
	var eff_stride_len := 2.0 * HALF_STEP * stride_scale * _turn_stride_mult / CONTACT_FRACTION
	var cycle_rate := cycle_speed / maxf(eff_stride_len, 0.05)
	var min_turn_rate := _turn_sharpness * 0.68 * tempo_scale
	cycle_rate = maxf(cycle_rate, min_turn_rate)

	if not _walk_was_moving:
		_walk_was_moving = true
		# Preserve any mid-air standing foot seamlessly into the walking swing (ZERO single-frame pop!).
		if not _foot_l.planted:
			_cycle = clampf(CONTACT_FRACTION + _foot_l.swing_t * (1.0 - CONTACT_FRACTION), CONTACT_FRACTION, 0.96)
			_foot_r.planted = true
		elif not _foot_r.planted:
			var r_p := clampf(CONTACT_FRACTION + _foot_r.swing_t * (1.0 - CONTACT_FRACTION), CONTACT_FRACTION, 0.96)
			_cycle = fposmod(r_p - 0.5, 1.0)
			_foot_l.planted = true
		else:
			if _turn_sign > 0.25:
				_cycle = 0.08
			elif _turn_sign < -0.25:
				_cycle = 0.58
			else:
				_cycle = 0.06
			_foot_l.planted = true
			_foot_r.planted = true
		_walk_cycle_prev = _cycle

	_walk_cycle_prev = _cycle
	_cycle = fposmod(_cycle + minf(cycle_rate * dt, 0.45), 1.0)

	var swing_dur := (1.0 - CONTACT_FRACTION) / maxf(cycle_rate, 0.15)
	var contact: Variant = null
	if _update_walk_foot(_foot_l, _left, _foot_r, _right, _cycle, _walk_cycle_prev, swing_dur, dt):
		contact = _foot_contact(_left)
	var r_phase := fposmod(_cycle + 0.5, 1.0)
	var r_prev := fposmod(_walk_cycle_prev + 0.5, 1.0)
	if _update_walk_foot(_foot_r, _right, _foot_l, _left, r_phase, r_prev, swing_dur, dt):
		contact = _foot_contact(_right)

	return contact


func _update_walk_foot(ft: FootTrack, leg: Leg, other_ft: FootTrack, other_leg: Leg,
		phase: float, prev_phase: float, swing_dur: float, dt: float) -> bool:
	var S := _model.scale.z
	var in_swing := phase >= CONTACT_FRACTION
	var landed_now := false

	if in_swing:
		var swing_t := clampf(inverse_lerp(CONTACT_FRACTION, 1.0, phase), 0.0, 1.0)
		if ft.planted:
			var cur_ankle := _foot_ankle_world(ft, leg)
			ft.planted = false
			ft.swing_start_world = cur_ankle
			ft.swing_start_yaw = ft.world_yaw
			ft.swing_start_pitch = ft.foot_pitch
			ft.swing_start_toe = ft.toe_bend
			ft.swing_start_lift = maxf(cur_ankle.y - (global_position.y + ANKLE_GROUND_Y * S), 0.0)
			ft.swing_bow_sign = leg.sign_x
			ft.active_pivoting = 0.0

		ft.swing_t = swing_t
		if swing_t <= 0.82 or ft.swing_target_world == Vector3.ZERO:
			var t_rem := maxf(1.0 - swing_t, 0.0) * swing_dur
			var pred_yaw := _pelvis_world_yaw + _pelvis_yaw_vel * t_rem * 0.78
			var yaw_err_rem := angle_difference(_pelvis_world_yaw, _target_yaw)
			var gentle_toe_bias := clampf((_pelvis_yaw_vel * 0.28 + yaw_err_rem * 0.22), -0.22, 0.22) * (1.0 - _turn_sharpness * 0.4)
			var sharp_toe_lead := clampf(yaw_err_rem * 0.35, -0.34, 0.34) * _turn_sharpness
			var target_heading := pred_yaw + sharp_toe_lead

			var pred_pos := global_position + _actual_world_vel * t_rem
			var is_inside := (leg.sign_x * _turn_sign > 0.0)
			var leg_diff_mult: float
			if is_inside:
				leg_diff_mult = lerpf(1.0, 0.72, _turn_sharpness * absf(_turn_sign))
			else:
				leg_diff_mult = lerpf(1.0, 1.18, _turn_sharpness * absf(_turn_sign))

			var forward_reach := HALF_STEP * _step_scale * _turn_stride_mult * leg_diff_mult
			var widen := 0.030 * _turn_sharpness
			var track_in := -0.006 * _stride * (1.0 - _turn_sharpness)
			var land_ankle := _rest_ankle_world(leg, pred_pos, target_heading, forward_reach, widen + track_in)

			# Guarantee landing spot stays cleanly on this leg's lateral side & well clear of the planted foot!
			var other_ankle := _foot_ankle_world(other_ft, other_leg)
			var lat_axis := _yaw_left(target_heading) * leg.sign_x
			var rel_lat := (land_ankle - other_ankle).dot(lat_axis)
			var min_lat := 0.138 * S
			if rel_lat < min_lat:
				land_ankle += lat_axis * (min_lat - rel_lat)
			var min_sep := 0.155 * S
			var sep := Vector3(land_ankle.x - other_ankle.x, 0.0, land_ankle.z - other_ankle.z)
			if sep.length() < min_sep:
				land_ankle += lat_axis * (min_sep - sep.length())

			ft.swing_target_world = land_ankle
			ft.swing_target_yaw = target_heading + leg.sign_x * IDLE_FOOT_YAW + gentle_toe_bias
			ft.last_step_length = Vector2(land_ankle.x - ft.swing_start_world.x, land_ankle.z - ft.swing_start_world.z).length()

		ft.world_yaw = lerp_angle(ft.swing_start_yaw, ft.swing_target_yaw, smoothstep(0.10, 0.78, swing_t))
		if swing_t >= 0.80 and swing_t < 0.96:
			ft.last_pre_land_yaw_err = absf(angle_difference(ft.world_yaw, ft.swing_target_yaw))

		if swing_t < 0.36:
			var k := smoothstep(0.0, 0.36, swing_t)
			ft.foot_pitch = lerpf(ft.swing_start_pitch, 0.20, k)
			ft.toe_bend = lerpf(ft.swing_start_toe, 0.0, smoothstep(0.0, 0.24, swing_t))
		else:
			var k := smoothstep(0.36, 0.92, swing_t)
			ft.foot_pitch = lerpf(0.20, HEEL_STRIKE_PITCH, k)
			ft.toe_bend = 0.0
	else:
		var u := clampf(phase / CONTACT_FRACTION, 0.0, 1.0)
		var wrapped := prev_phase >= CONTACT_FRACTION or not ft.planted
		if wrapped:
			ft.planted = true
			ft.world_yaw = ft.swing_target_yaw
			ft.foot_pitch = HEEL_STRIKE_PITCH
			ft.toe_bend = 0.0
			ft.last_landing_pitch = ft.foot_pitch
			ft.pivot_mode = PIVOT_HEEL
			ft.heel_settle_t = 0.0
			ft.active_pivoting = 0.0
			var heel_w := ft.swing_target_world - Vector3.UP * (ANKLE_GROUND_Y * S) + _yaw_forward(ft.world_yaw) * (HEEL_Z_FROM_ANKLE * S)
			heel_w.y = global_position.y
			ft.pivot_world = heel_w
			landed_now = true

		if u < 0.14:
			var h := 1.0 - smoothstep(0.0, 0.14, u)
			ft.foot_pitch = HEEL_STRIKE_PITCH * h
			ft.toe_bend = 0.0
			ft.heel_settle_t = u / 0.14
			ft.active_pivoting = 0.0
		elif u <= 0.72:
			ft.heel_settle_t = 1.0
			var is_inside := (leg.sign_x * _turn_sign > 0.0)
			var want_pivot := PIVOT_HEEL if is_inside else PIVOT_BALL
			if ft.pivot_mode != want_pivot:
				_switch_planted_pivot(ft, want_pivot)
			var body_foot_twist := angle_difference(ft.world_yaw, _pelvis_world_yaw + leg.sign_x * IDLE_FOOT_YAW)
			var piv_active := 0.0
			if absf(_pelvis_yaw_vel) > 0.25 and absf(body_foot_twist) > 0.18:
				var max_piv_step := clampf(absf(_pelvis_yaw_vel) * 0.55, 0.0, 1.1) * dt
				var step_yaw := clampf(body_foot_twist, -max_piv_step, max_piv_step)
				ft.world_yaw += step_yaw
				piv_active = clampf(absf(step_yaw / maxf(dt, 0.001)) / 0.75, 0.0, 1.0)
			ft.active_pivoting = lerpf(ft.active_pivoting, piv_active, minf(dt * 12.0, 1.0)) if dt > 0.0 else piv_active
			if ft.pivot_mode == PIVOT_BALL:
				ft.foot_pitch = 0.065 * ft.active_pivoting
				ft.toe_bend = ft.foot_pitch * 0.85
			else:
				ft.foot_pitch = -0.045 * ft.active_pivoting
				ft.toe_bend = 0.0
		else:
			if ft.pivot_mode != PIVOT_BALL:
				_switch_planted_pivot(ft, PIVOT_BALL)
			ft.heel_settle_t = 1.0
			ft.active_pivoting = 0.0
			var p := smoothstep(0.72, 1.0, u)
			var push_max := lerpf(0.24, 0.40, clampf(_step_scale * _turn_stride_mult, 0.28, 1.0))
			ft.foot_pitch = push_max * p
			ft.toe_bend = ft.foot_pitch * 0.90

		var ankle_w := _foot_ankle_world(ft, leg)
		var hip_w := global_position + Vector3.UP * (_hip_rest.y * S)
		var max_horiz := 0.56 * S
		var horiz := Vector3(ankle_w.x - hip_w.x, 0.0, ankle_w.z - hip_w.z)
		if horiz.length() > max_horiz:
			var excess := horiz.normalized() * (horiz.length() - max_horiz)
			ft.pivot_world -= excess

	return landed_now


func _advance_heel_settle(ft: FootTrack, dt: float) -> void:
	if not ft.planted:
		return
	if ft.heel_settle_t < 1.0:
		ft.heel_settle_t = minf(ft.heel_settle_t + dt / HEEL_ROLL_SECONDS, 1.0)
		var h := 1.0 - smoothstep(0.0, 1.0, ft.heel_settle_t)
		ft.foot_pitch = HEEL_STRIKE_PITCH * h
		ft.toe_bend = 0.0


func _switch_planted_pivot(ft: FootTrack, next_mode: int) -> void:
	if ft.pivot_mode == next_mode:
		return
	var S := _model.scale.z
	var fwd := _yaw_forward(ft.world_yaw)
	if ft.pivot_mode == PIVOT_HEEL and next_mode == PIVOT_BALL:
		ft.pivot_world += fwd * (HEEL_TO_BALL_DIST * S)
	elif ft.pivot_mode == PIVOT_BALL and next_mode == PIVOT_HEEL:
		ft.pivot_world -= fwd * (HEEL_TO_BALL_DIST * S)
	ft.pivot_mode = next_mode


func _foot_ankle_world(ft: FootTrack, leg: Leg) -> Vector3:
	var S := _model.scale.z
	var fwd := _yaw_forward(ft.world_yaw)
	if ft.planted:
		if ft.pivot_mode == PIVOT_HEEL:
			var v_rest := Vector3(0.0, ANKLE_GROUND_Y, -HEEL_Z_FROM_ANKLE)
			var v_rot := Quaternion(Vector3.RIGHT, ft.foot_pitch) * v_rest
			return ft.pivot_world + Vector3.UP * (v_rot.y * S) + fwd * (v_rot.z * S)
		else:
			var v_rest := Vector3(0.0, ANKLE_GROUND_Y - BALL_JOINT_Y, -BALL_Z_FROM_ANKLE)
			var v_rot := Quaternion(Vector3.RIGHT, ft.foot_pitch) * v_rest
			return ft.pivot_world + Vector3.UP * ((BALL_JOINT_Y + v_rot.y) * S) + fwd * (v_rot.z * S)
	else:
		var t := clampf(ft.swing_t, 0.0, 1.0)
		var xz_t := smoothstep(0.0, 1.0, t)
		var pos := ft.swing_start_world.lerp(ft.swing_target_world, xz_t)
		var bow_mag := (0.024 if _stand_step_active else 0.028 * _turn_sharpness) * S
		var bow_dir := _yaw_left(_pelvis_world_yaw) * ft.swing_bow_sign
		pos += bow_dir * (sin(PI * t) * bow_mag)

		# Dynamic anti-crossing swing clearance: smoothly arc swinging ankle around the planted shin/ankle
		# even during high-speed tight corners (ZERO leg crossing or ankle overlap!).
		var other_ft := _foot_r if ft == _foot_l else _foot_l
		var other_leg := _right if ft == _foot_l else _left
		if other_ft.planted:
			var other_ankle := _foot_ankle_world(other_ft, other_leg)
			var lat_vec := _yaw_left(_pelvis_world_yaw) * ft.sign_x
			var fwd_vec := _yaw_forward(_pelvis_world_yaw)
			var rel := pos - other_ankle
			var fwd_dist := absf(rel.dot(fwd_vec))
			var lat_signed := rel.dot(lat_vec)
			# Whenever swinging foot passes beside the planted leg, keep comfortable outward lateral clearance.
			var pass_weight := (1.0 - smoothstep(0.10 * S, 0.34 * S, fwd_dist)) * sin(PI * t)
			var min_lat_clear := 0.135 * S
			if lat_signed < min_lat_clear and pass_weight > 0.001:
				pos += lat_vec * ((min_lat_clear - lat_signed) * clampf(pass_weight * 1.45, 0.0, 1.0))

		var arc := sin(PI * pow(t, 0.86))
		var lift_h: float
		if _stand_step_active:
			lift_h = 0.105 * S
		else:
			var step_h_scale := lerpf(0.55, 1.0, clampf(_step_scale, 0.28, 1.0)) * lerpf(1.0, 0.78, _turn_sharpness)
			lift_h = SWING_HEIGHT * step_h_scale * S
		var v_land := Quaternion(Vector3.RIGHT, HEEL_STRIKE_PITCH) * Vector3(0.0, ANKLE_GROUND_Y, -HEEL_Z_FROM_ANKLE)
		var land_extra_y := (v_land.y - ANKLE_GROUND_Y) * S * smoothstep(0.55, 1.0, t)
		var base_y := global_position.y + ANKLE_GROUND_Y * S
		pos.y = base_y + lift_h * arc + ft.swing_start_lift * pow(1.0 - t, 1.35) + land_extra_y
		return pos


func _foot_heel_world(ft: FootTrack, leg: Leg) -> Vector3:
	var S := _model.scale.z
	if ft.planted and ft.pivot_mode == PIVOT_HEEL:
		return ft.pivot_world
	var ankle := _foot_ankle_world(ft, leg)
	var rot_off := Quaternion(Vector3.RIGHT, ft.foot_pitch) * Vector3(0.0, -ANKLE_GROUND_Y, HEEL_Z_FROM_ANKLE)
	return ankle + Vector3.UP * (rot_off.y * S) + _yaw_forward(ft.world_yaw) * (rot_off.z * S)


func _foot_ball_world(ft: FootTrack, leg: Leg) -> Vector3:
	var S := _model.scale.z
	if ft.planted and ft.pivot_mode == PIVOT_BALL:
		return ft.pivot_world
	var ankle := _foot_ankle_world(ft, leg)
	var rot_off := Quaternion(Vector3.RIGHT, ft.foot_pitch) * Vector3(0.0, -(ANKLE_GROUND_Y - BALL_JOINT_Y), BALL_Z_FROM_ANKLE)
	return ankle + Vector3.UP * ((rot_off.y - BALL_JOINT_Y) * S) + _yaw_forward(ft.world_yaw) * (rot_off.z * S)


func _rest_ankle_world(leg: Leg, body_pos: Vector3, heading_yaw: float, extra_fwd: float, extra_lat: float) -> Vector3:
	var S := _model.scale.z
	var lat := (leg.ankle_rest.x + leg.sign_x * extra_lat) * S
	var fwd := (leg.ankle_rest.z + extra_fwd) * S
	return body_pos + Vector3.UP * (leg.ankle_rest.y * S) + _yaw_left(heading_yaw) * lat + _yaw_forward(heading_yaw) * fwd


func _update_yaw_cascade(dt: float, tempo_scale: float, moving: bool) -> void:
	# Layer 2: Head chases target_yaw FIRST and most noticeably ("头转得最明显，视线要先到").
	var head_goal := _pelvis_world_yaw + clampf(
		angle_difference(_pelvis_world_yaw, _target_yaw),
		-TURN_HEAD_OVER_PELVIS_MAX,
		TURN_HEAD_OVER_PELVIS_MAX
	)
	var head_omega := 11.5 * clampf(tempo_scale, 0.55, 1.8)
	var head_err := angle_difference(_head_world_yaw, head_goal)
	if dt > 0.0:
		var head_acc := head_err * (head_omega * head_omega) - _head_yaw_vel * (2.0 * 0.96 * head_omega)
		_head_yaw_vel += head_acc * dt
		_head_world_yaw += _head_yaw_vel * dt
		var rel_hp := angle_difference(_pelvis_world_yaw, _head_world_yaw)
		if absf(rel_hp) > TURN_HEAD_OVER_PELVIS_MAX:
			_head_world_yaw = _pelvis_world_yaw + clampf(rel_hp, -TURN_HEAD_OVER_PELVIS_MAX, TURN_HEAD_OVER_PELVIS_MAX)
			_head_yaw_vel *= 0.5
	else:
		_head_world_yaw = head_goal

	# Layer 3: Chest twists in PELVIS-RELATIVE space to ~half of head's turn ("胸转到头的一半左右就够了"),
	# half a beat behind the head, so it stays smoothly halfway between pelvis and head throughout the turn!
	var head_rel_pelvis := angle_difference(_pelvis_world_yaw, _head_world_yaw)
	var head_onset := smoothstep(0.08, 0.28, absf(head_rel_pelvis))
	var chest_rel_goal := clampf(head_rel_pelvis * 0.50, -TURN_CHEST_OVER_PELVIS_MAX, TURN_CHEST_OVER_PELVIS_MAX) * head_onset
	var chest_omega := 7.6 * clampf(tempo_scale, 0.55, 1.8)
	if dt > 0.0:
		var chest_acc := (chest_rel_goal - _chest_rel_pelvis) * (chest_omega * chest_omega) - _chest_rel_vel * (2.0 * 0.96 * chest_omega)
		_chest_rel_vel += chest_acc * dt
		_chest_rel_pelvis = clampf(_chest_rel_pelvis + _chest_rel_vel * dt, -TURN_CHEST_OVER_PELVIS_MAX, TURN_CHEST_OVER_PELVIS_MAX)
	else:
		_chest_rel_pelvis = chest_rel_goal
	_chest_world_yaw = _pelvis_world_yaw + _chest_rel_pelvis

	# Layer 1: Eyes dart to target_yaw FIRST (fastest response, leading head!).
	var eye_err := angle_difference(_head_world_yaw, _target_yaw)
	var eye_target_local := clampf(eye_err * 0.85, -TURN_EYE_MAX_YAW, TURN_EYE_MAX_YAW)
	if dt > 0.0:
		_eye_local_yaw = lerpf(_eye_local_yaw, eye_target_local, minf(dt * 28.0, 1.0))
	else:
		_eye_local_yaw = eye_target_local
	_eye_world_yaw = _head_world_yaw + _eye_local_yaw

	var active_gaze := clampf(absf(angle_difference(_pelvis_world_yaw, _target_yaw)) * 3.5 + absf(_pelvis_yaw_vel) * 1.5, 0.0, 1.0)
	_eye_override = lerpf(_eye_override, active_gaze, minf(dt * 12.0, 1.0)) if dt > 0.0 else active_gaze
	var _unused_m := moving


func _update_body_dynamics(dt: float, tempo_scale: float, moving: bool) -> void:
	var yaw_err := angle_difference(_pelvis_world_yaw, _target_yaw)
	var signed_rate := _pelvis_yaw_vel
	_effective_turn_rate = lerpf(_effective_turn_rate, signed_rate, minf(dt * 9.0, 1.0)) if dt > 0.0 else signed_rate
	_turn_urgency = clampf(maxf(absf(yaw_err) / 1.1, absf(signed_rate) / 1.6), 0.0, 1.0)

	var speed_norm := clampf(_actual_speed / maxf(WALK_REF_SPEED * clampf(pace, 0.5, 1.5), 1.0), 0.0, 2.4)
	var target_lean := 0.0
	if moving:
		var rate_term := _effective_turn_rate * (0.075 + 0.068 * speed_norm)
		var lead_term := clampf(yaw_err, -1.2, 1.2) * (0.036 + 0.024 * speed_norm)
		target_lean = clampf(rate_term + lead_term, -0.34, 0.34)
	elif _stand_turning or _stand_step_active:
		target_lean = clampf(yaw_err * 0.16 + _stand_dir * 0.095, -0.20, 0.20)
	else:
		target_lean = clampf(yaw_err * 0.06, -0.05, 0.05)

	if dt > 0.0:
		var lean_omega := 7.2 * clampf(tempo_scale, 0.6, 1.6)
		var lean_acc := (target_lean - _inward_lean) * (lean_omega * lean_omega) - _inward_lean_vel * (2.0 * 0.94 * lean_omega)
		_inward_lean_vel += lean_acc * dt
		_inward_lean = clampf(_inward_lean + _inward_lean_vel * dt, -0.36, 0.36)
	else:
		_inward_lean = target_lean

	# Micro-flexed knees & grounded pelvis sink ("膝盖微屈，胯稍微下沉一点", poised ~26-36 deg knee bend, never squatting!).
	var target_crouch := 0.0
	if moving:
		target_crouch = 0.010 * clampf(absf(_effective_turn_rate) / 0.45, 0.0, 1.0) + 0.020 * _turn_sharpness + 0.008 * clampf(absf(_inward_lean) / 0.22, 0.0, 1.0)
	elif _stand_turning or _stand_step_active:
		target_crouch = 0.018 + 0.008 * clampf(absf(yaw_err) / 1.5, 0.0, 1.0) + 0.008 * sin(_stand_land_dip * PI)
	else:
		target_crouch = 0.006 * clampf(absf(yaw_err) / 0.3, 0.0, 1.0)
	_turn_crouch = lerpf(_turn_crouch, target_crouch, minf(dt * 8.0, 1.0)) if dt > 0.0 else target_crouch

	var target_wx := 0.0
	if _stand_step_active:
		var sup_sign := -1.0 if _stand_step_side == "L" else 1.0
		var u := clampf(_stand_step_elapsed / maxf(_stand_step_dur, 0.01), 0.0, 1.0)
		var shift_env := smoothstep(0.0, STAND_TRANSFER_FRAC * 0.95, u) * (1.0 - smoothstep(0.86, 1.0, u) * 0.35)
		var inward_bias := _stand_dir * 0.016
		target_wx = sup_sign * 0.072 * shift_env + inward_bias
	elif _stand_turning:
		target_wx = _stand_dir * 0.068
	elif moving:
		target_wx = clampf(_inward_lean * 0.19 + _turn_sign * 0.022 * _turn_sharpness, -0.055, 0.055)
	else:
		target_wx = 0.0
	_turn_weight_x = lerpf(_turn_weight_x, target_wx, minf(dt * 9.5, 1.0)) if dt > 0.0 else target_wx


func _apply_layered_pose(dt: float) -> void:
	var l_ankle_w := _foot_ankle_world(_foot_l, _left)
	var r_ankle_w := _foot_ankle_world(_foot_r, _right)
	var l_local := _skeleton.to_local(l_ankle_w)
	var r_local := _skeleton.to_local(r_ankle_w)

	var l_grounded := 1.0 if _foot_l.planted else 0.0
	var r_grounded := 1.0 if _foot_r.planted else 0.0
	_update_leg_ground(_left, l_local, l_grounded, dt)
	_update_leg_ground(_right, r_local, r_grounded, dt)

	_left_ankle = l_local + Vector3(0.0, _left.ground_y * lerpf(0.35, 1.0, l_grounded), 0.0)
	_right_ankle = r_local + Vector3(0.0, _right.ground_y * lerpf(0.35, 1.0, r_grounded), 0.0)

	var target_drop := minf(_left.ground_y, _right.ground_y)
	_pelvis_ground_drop = lerpf(_pelvis_ground_drop, target_drop, minf(dt * 12.0, 1.0)) if dt > 0.0 else target_drop

	var angle := _cycle * TAU
	var stride_phase := cos(angle)
	var weight_shift := sin(angle - 0.16)
	var bob_wave := -cos(2.0 * (angle - 0.32))
	var arm_lag := cos(angle - 0.15)
	var elbow_lag := cos(angle - 0.40)
	var upper_drive := _move_drive
	var step_amp := lerpf(0.62, 1.0, clampf(_step_scale, 0.28, 1.0)) * lerpf(0.76, 1.0, _turn_stride_mult)

	var idle_weight := 1.0 - _stride
	var calm_idle := idle_weight * (1.0 - clampf(_turn_urgency * 3.0, 0.0, 1.0))
	var breath_sin := sin(_breath)
	var contra := (sin(_idle_look_time * 0.42 + 0.5) * 0.72 + sin(_idle_look_time * 0.19) * 0.28) * calm_idle
	var idle_sway_x := contra * 0.014

	var base_hip_drop := lerpf(-0.016, -0.036, _stride * step_amp)
	var bob_y := bob_wave * 0.018 * _stride * step_amp
	var breath_y := breath_sin * (0.0042 * calm_idle + 0.002 * (1.0 - calm_idle))
	var hip := _hip_rest + Vector3(
		weight_shift * 0.040 * _stride * step_amp + _turn_weight_x + idle_sway_x,
		base_hip_drop - _turn_crouch + bob_y + breath_y + _pelvis_ground_drop - _impact_jolt * 0.014,
		0.014 * upper_drive + 0.008 * clampf(absf(_inward_lean) * 4.0, 0.0, 1.0)
	)
	_last_hip_local = hip

	var chest_twist := angle_difference(_pelvis_world_yaw, _chest_world_yaw)
	var head_over_chest := angle_difference(_chest_world_yaw, _head_world_yaw)
	var lean := _inward_lean
	var turn_mag := clampf(absf(chest_twist) * 2.4 + absf(lean) * 3.5, 0.0, 1.0)

	var pelvis_pitch := 0.050 * upper_drive + 0.048 * turn_mag + _impact_jolt * 0.024
	var pelvis_yaw := stride_phase * 0.095 * _stride * step_amp - chest_twist * 0.12 + contra * 0.020
	var pelvis_roll := weight_shift * 0.046 * _stride * step_amp + 0.18 * lean + 0.065 * chest_twist + _turn_weight_x * 0.38 + contra * 0.020
	var hip_rot := _pose("spine", pelvis_pitch, pelvis_yaw, pelvis_roll)
	_skeleton.set_bone_pose_position(_bone["spine"], hip)

	var s1_roll := -weight_shift * 0.020 * _stride * step_amp - 0.56 * lean - 0.11 * chest_twist - contra * 0.010
	var s2_roll := -weight_shift * 0.030 * _stride * step_amp - 0.58 * lean - 0.08 * chest_twist - contra * 0.012
	var s3_roll := -weight_shift * 0.022 * _stride * step_amp - 0.18 * lean + 0.10 * chest_twist - contra * 0.008
	var s4_roll := 0.14 * lean + 0.06 * chest_twist

	_pose("spine.001", 0.010 * upper_drive + 0.024 * turn_mag + _impact_jolt * 0.020,
		-stride_phase * 0.040 * upper_drive * step_amp + chest_twist * 0.24, s1_roll)
	_pose("spine.002", 0.014 * upper_drive + 0.016 * turn_mag + breath_sin * 0.013,
		-stride_phase * 0.062 * upper_drive * step_amp + chest_twist * 0.42, s2_roll)
	_pose("spine.003", -0.012 * upper_drive - 0.018 * turn_mag + breath_sin * 0.024 + _impact_jolt * 0.020,
		-stride_phase * 0.068 * upper_drive * step_amp + chest_twist * 0.46, s3_roll)
	_pose("spine.004", -0.026 * upper_drive - 0.024 * turn_mag - breath_sin * 0.012,
		stride_phase * 0.024 * upper_drive * step_amp + head_over_chest * 0.22, s4_roll)

	_last_spine_s_curve = absf(s1_roll + s2_roll) + absf(pelvis_roll - s2_roll)

	var idle_yaw := _head_idle_gaze.x * calm_idle
	var idle_pitch := _head_idle_gaze.y * calm_idle
	var head_yaw := stride_phase * 0.055 * upper_drive * step_amp + head_over_chest * 0.78 + idle_yaw
	var head_roll := weight_shift * 0.024 * _stride * step_amp + 0.56 * lean - contra * 0.014
	var head_pitch := -0.020 * upper_drive - 0.018 * turn_mag - breath_sin * 0.014 + idle_pitch - _impact_jolt * 0.030
	_pose("Neck", head_pitch * 0.44, head_yaw * 0.44, head_roll * 0.42)
	_pose("Head", head_pitch * 0.56, head_yaw * 0.56, head_roll * 0.58)

	var breath_shrug := breath_sin * 0.020 * calm_idle - _impact_jolt * 0.022
	var sh_counter_z := clampf(-chest_twist * 0.28, -0.16, 0.16)
	_last_shoulder_counter = sh_counter_z
	var sh_tilt := clampf(lean * 0.24 + chest_twist * 0.08, -0.09, 0.09)
	var stand_sh_z := _stand_arm_phase * 0.045
	_pose_local("shoulder.L",
		breath_shrug - sh_tilt + maxf(-arm_lag, 0.0) * 0.036 * upper_drive,
		0.0,
		arm_lag * 0.054 * upper_drive * step_amp + sh_counter_z + stand_sh_z)
	_pose_local("shoulder.R",
		breath_shrug + sh_tilt + maxf(arm_lag, 0.0) * 0.036 * upper_drive,
		0.0,
		arm_lag * 0.054 * upper_drive * step_amp + sh_counter_z + stand_sh_z)

	var turn_bias := clampf(lean * 4.2 + chest_twist * 1.15, -1.0, 1.0)
	var l_out := clampf(-turn_bias, 0.0, 1.0)
	var l_in := clampf(turn_bias, 0.0, 1.0)
	var r_out := clampf(turn_bias, 0.0, 1.0)
	var r_in := clampf(-turn_bias, 0.0, 1.0)

	var base_arm_amp := upper_drive * lerpf(0.70, 1.05, clampf(_step_scale, 0.28, 1.12))
	var l_amp := base_arm_amp * (1.0 + 0.34 * l_out - 0.34 * l_in)
	var r_amp := base_arm_amp * (1.0 + 0.34 * r_out - 0.34 * r_in)
	_last_l_arm_amp = l_amp + (0.18 * (1.0 + 0.55 * l_out - 0.45 * l_in) if (_stand_turning or _stand_step_active) else 0.0)
	_last_r_arm_amp = r_amp + (0.18 * (1.0 + 0.55 * r_out - 0.45 * r_in) if (_stand_turning or _stand_step_active) else 0.0)

	var stand_swing_l := _stand_arm_phase * 0.22 * (1.0 + 0.55 * l_out - 0.48 * l_in)
	var stand_swing_r := -_stand_arm_phase * 0.22 * (1.0 + 0.55 * r_out - 0.48 * r_in)
	var l_arm_swing := arm_lag * 0.40 * l_amp + stand_swing_l + 0.06 * l_out - 0.05 * l_in
	var r_arm_swing := -arm_lag * 0.40 * r_amp + stand_swing_r + 0.06 * r_out - 0.05 * r_in

	var arm_breath_out := breath_sin * 0.015 * calm_idle
	var l_pass := (1.0 - absf(arm_lag)) * 0.045 * upper_drive
	var r_bag_zone := clampf((1.0 - absf(arm_lag)) * 0.60 + maxf(arm_lag, 0.0) * 1.0, 0.0, 1.0)
	var r_pass := (0.045 + r_bag_zone * 0.145) * upper_drive + maxf(-weight_shift, 0.0) * 0.04 * _stride

	# Graceful, relaxed outside-arm counterbalance vs compact tucked inside arm (never stiff T-pose wing!).
	var out_scale := lerpf(0.15, 0.19, _stride)
	var l_open_delta := out_scale * l_out - 0.075 * l_in
	var r_open_delta := out_scale * r_out - 0.040 * r_in
	_last_l_arm_open = l_open_delta
	_last_r_arm_open = r_open_delta

	# Counteract ribcage banking jamming the inside arm into the hip/thigh/yellow bear bag,
	# while preserving unmistakably wider outside-arm openness vs compact tucked inside arm!
	var l_lean_clear := maxf(lean, 0.0) * 0.40
	var r_lean_clear := maxf(-lean, 0.0) * 0.88 + maxf(-chest_twist, 0.0) * 0.16
	var l_roll := -0.44 + arm_breath_out + l_pass + l_open_delta + l_lean_clear + contra * 0.015
	var r_roll := 0.29 - arm_breath_out - r_pass - r_open_delta - r_lean_clear + contra * 0.015

	# Tuck inside arm slightly forward-compactly; outside arm carries a relaxed athletic elbow bend too!
	var l_in_tuck_fwd := -0.10 * l_in
	var r_in_tuck_fwd := -0.14 * r_in
	_pose("upper_arm.L", l_arm_swing + l_in_tuck_fwd + 0.02, -0.05 - maxf(-arm_lag, 0.0) * 0.04 * l_amp - 0.06 * l_in, l_roll)
	_pose("upper_arm.R", r_arm_swing + r_in_tuck_fwd + 0.03, 0.06 + maxf(arm_lag, 0.0) * 0.06 * r_amp, r_roll)

	var l_elbow := 0.19 + (0.08 + maxf(-elbow_lag, 0.0) * 0.34 + maxf(elbow_lag, 0.0) * 0.06) * l_amp + 0.28 * l_in + 0.10 * l_out
	var r_elbow := 0.20 + (0.08 + maxf(elbow_lag, 0.0) * 0.36 + maxf(-elbow_lag, 0.0) * 0.06) * r_amp + 0.28 * r_in + 0.10 * r_out
	_pose_local("forearm.L", clampf(l_elbow, 0.16, 0.95), 0.0, 0.0)
	_pose_local("forearm.R", clampf(r_elbow, 0.16, 0.95), 0.0, 0.0)

	var l_wrist_drag := clampf((arm_lag - elbow_lag) * 0.24 * l_amp, -0.14, 0.14)
	var r_wrist_drag := clampf((-arm_lag + elbow_lag) * 0.24 * r_amp, -0.14, 0.14)
	_pose_local("hand.L", 0.06 + l_wrist_drag, 0.14, -0.22)
	_pose_local("hand.R", 0.06 + r_wrist_drag, -0.14, 0.22)

	_pose_fingers("L", 0.32 + maxf(-arm_lag, 0.0) * 0.10 * l_amp + 0.08 * l_in)
	_pose_fingers("R", 0.32 + maxf(arm_lag, 0.0) * 0.10 * r_amp + 0.08 * r_in)

	var model_world_yaw := global_rotation.y + _visual_yaw_offset
	var l_foot_yaw := clampf(angle_difference(model_world_yaw, _foot_l.world_yaw), -1.15, 1.15)
	var r_foot_yaw := clampf(angle_difference(model_world_yaw, _foot_r.world_yaw), -1.15, 1.15)
	var l_foot_pitch := _foot_l.foot_pitch + _left.ground_pitch * l_grounded
	var r_foot_pitch := _foot_r.foot_pitch + _right.ground_pitch * r_grounded
	var l_foot_roll := _left.ground_roll * l_grounded
	var r_foot_roll := _right.ground_roll * r_grounded

	var l_knee_splay := 0.05 * turn_mag
	var r_knee_splay := 0.05 * turn_mag
	_plant(_left, _left_ankle, hip, hip_rot, l_foot_pitch, l_foot_roll, l_foot_yaw, _foot_l.toe_bend, l_knee_splay)
	_plant(_right, _right_ankle, hip, hip_rot, r_foot_pitch, r_foot_roll, r_foot_yaw, _foot_r.toe_bend, r_knee_splay)

	_last_l_knee_deg = _compute_knee_bend_deg(_left)
	_last_r_knee_deg = _compute_knee_bend_deg(_right)


# ==============================================================================
# Core rig & IK helpers (mirrored cleanly from scenes/giant_visual.gd)
# ==============================================================================

func _make_leg(side: String) -> Leg:
	var leg := Leg.new()
	leg.side = side
	leg.sign_x = 1.0 if side == "L" else -1.0
	leg.thigh = _skeleton.find_bone("thigh." + side)
	leg.shin = _skeleton.find_bone("shin." + side)
	leg.foot = _skeleton.find_bone("foot." + side)
	leg.toe = _skeleton.find_bone("toe." + side)
	leg.hip_socket = _skeleton.get_bone_pose_position(leg.thigh)
	leg.upper_length = _skeleton.get_bone_pose_position(leg.shin).length()
	leg.lower_length = _skeleton.get_bone_pose_position(leg.foot).length()
	leg.thigh_rest = _skeleton.get_bone_pose_rotation(leg.thigh)
	leg.shin_rest = _skeleton.get_bone_pose_rotation(leg.shin)
	leg.toe_rest = _skeleton.get_bone_pose_rotation(leg.toe) if leg.toe >= 0 else Quaternion.IDENTITY
	var ankle := _skeleton.get_bone_global_rest(leg.foot)
	leg.ankle_rest = ankle.origin
	leg.foot_basis = ankle.basis.orthonormalized().get_rotation_quaternion()
	var center := LEFT_SOLE_CENTER
	center.x *= leg.sign_x
	leg.sole_center = ankle.affine_inverse() * center
	leg.sole_forward = ankle.basis.inverse() * Vector3.BACK
	return leg


func _foot_contact(leg: Leg) -> Vector4:
	var pose := _skeleton.get_bone_global_pose(leg.foot)
	var center := _skeleton.to_global(pose * leg.sole_center)
	var forward := _skeleton.global_basis * (pose.basis * leg.sole_forward)
	return Vector4(center.x, center.y, center.z, atan2(-forward.x, -forward.z))


func _plant(leg: Leg, ankle: Vector3, hip: Vector3, hip_rotation: Quaternion,
		foot_pitch: float, foot_roll := 0.0, foot_yaw := 0.0, toe_bend := 0.0, knee_splay := 0.0) -> void:
	leg.last_pitch = foot_pitch
	leg.last_roll = foot_roll
	leg.last_yaw = foot_yaw
	leg.last_toe = toe_bend

	var socket := hip + hip_rotation * leg.hip_socket
	var leg_vector := ankle - socket
	var raw_len := leg_vector.length()
	var axis := leg_vector / maxf(raw_len, 0.0001)
	var max_reach := leg.upper_length + leg.lower_length - 0.002
	var soft_start := max_reach * 0.992
	var reach := raw_len
	if raw_len > soft_start:
		var excess := raw_len - soft_start
		var span := max_reach - soft_start
		reach = soft_start + span * (1.0 - exp(-excess / span))
	reach = clampf(reach, 0.08, max_reach)

	var pole_yaw := leg.sign_x * (0.065 + knee_splay) + foot_yaw * 0.45
	var pole_dir := Vector3(sin(pole_yaw), 0.0, cos(pole_yaw)).normalized()
	var pole := (pole_dir - axis * axis.dot(pole_dir))
	if pole.length_squared() < 0.0001:
		pole = Vector3.BACK
	else:
		pole = pole.normalized()

	var along := (reach * reach + leg.upper_length ** 2 - leg.lower_length ** 2) / (2.0 * reach)
	var knee := socket + axis * along + pole * sqrt(maxf(0.0, leg.upper_length ** 2 - along ** 2))

	var thigh_dir := (knee - socket).normalized()
	var thigh_base := hip_rotation * leg.thigh_rest
	var thigh_swing := Quaternion(thigh_base * Vector3.UP, thigh_dir) * thigh_base
	var thigh_world := _align_limb_twist(thigh_swing, thigh_dir, pole)

	var shin_dir := (socket + axis * reach - knee).normalized()
	var shin_base := thigh_world * leg.shin_rest
	var shin_swing := Quaternion(shin_base * Vector3.UP, shin_dir) * shin_base
	var shin_world := _align_limb_twist(shin_swing, shin_dir, pole)

	var foot_orient := Quaternion(Vector3.UP, foot_yaw) * Quaternion(Vector3.BACK, foot_roll) * Quaternion(Vector3.RIGHT, foot_pitch)
	var foot_world := foot_orient * leg.foot_basis

	_skeleton.set_bone_pose_rotation(leg.thigh, hip_rotation.inverse() * thigh_world)
	_skeleton.set_bone_pose_rotation(leg.shin, thigh_world.inverse() * shin_world)
	_skeleton.set_bone_pose_rotation(leg.foot, shin_world.inverse() * foot_world)
	if leg.toe >= 0:
		_skeleton.set_bone_pose_rotation(leg.toe, leg.toe_rest * Quaternion(Vector3.RIGHT, clampf(toe_bend, -0.25, 0.65)))


func _align_limb_twist(q: Quaternion, limb_dir: Vector3, pole: Vector3) -> Quaternion:
	var cur_front := -(q * Vector3.BACK)
	cur_front = cur_front - limb_dir * limb_dir.dot(cur_front)
	var desired_front := pole - limb_dir * limb_dir.dot(pole)
	if cur_front.length_squared() < 0.0001 or desired_front.length_squared() < 0.0001:
		return q
	cur_front = cur_front.normalized()
	desired_front = desired_front.normalized()
	var twist := atan2(limb_dir.dot(cur_front.cross(desired_front)), cur_front.dot(desired_front))
	return Quaternion(limb_dir, twist) * q


func _update_leg_ground(leg: Leg, model_ankle: Vector3, ground_weight: float, dt: float) -> void:
	var target_y := 0.0
	var target_pitch := 0.0
	var target_roll := 0.0
	if is_inside_tree() and get_world_3d() != null:
		var space := get_world_3d().direct_space_state
		if space != null:
			var scale_mult := maxf(_model.scale.y / _model_base_scale, 0.35)
			var world_foot := _skeleton.to_global(Vector3(model_ankle.x, leg.ankle_rest.y, model_ankle.z))
			var from := Vector3(world_foot.x, global_position.y + 5.5 * scale_mult, world_foot.z)
			var to := Vector3(world_foot.x, global_position.y - 4.0 * scale_mult, world_foot.z)
			var query := PhysicsRayQueryParameters3D.create(from, to, collision_mask & 17)
			var hit := space.intersect_ray(query)
			if not hit.is_empty():
				var hit_pos: Vector3 = hit["position"]
				var hit_norm: Vector3 = hit["normal"]
				var rel_y := clampf(hit_pos.y - global_position.y, -2.2 * scale_mult, 2.8 * scale_mult)
				if absf(rel_y) > 0.04:
					target_y = rel_y / _model.scale.y
				if hit_norm.y > 0.55 and ground_weight > 0.3:
					var local_n := _skeleton.global_basis.orthonormalized().inverse() * hit_norm
					target_pitch = clampf(atan2(local_n.z, local_n.y), -0.34, 0.34)
					target_roll = clampf(-atan2(local_n.x, local_n.y), -0.28, 0.28)
					if absf(target_pitch) < 0.03:
						target_pitch = 0.0
					if absf(target_roll) < 0.03:
						target_roll = 0.0
	if dt > 0.0:
		var rate := 16.0 if ground_weight > 0.5 else 9.0
		var w := minf(dt * rate, 1.0)
		leg.ground_y = lerpf(leg.ground_y, target_y, w)
		leg.ground_pitch = lerpf(leg.ground_pitch, target_pitch, w)
		leg.ground_roll = lerpf(leg.ground_roll, target_roll, w)
	else:
		leg.ground_y = target_y
		leg.ground_pitch = target_pitch
		leg.ground_roll = target_roll


func _init_fingers() -> void:
	for side in ["L", "R"]:
		var list: Array[Dictionary] = []
		var finger_scale := [0.80, 0.94, 1.08, 1.22]
		var seg_scale := [0.55, 1.0, 0.78]
		for fi in FINGER_NAMES.size():
			for si in 3:
				var bname := "%s.%02d.%s" % [FINGER_NAMES[fi], si + 1, side]
				var idx := _skeleton.find_bone(bname)
				if idx >= 0:
					list.append({
						"idx": idx,
						"rest": _skeleton.get_bone_pose_rotation(idx),
						"weight": finger_scale[fi] * seg_scale[si],
						"thumb": false,
						"sign": 1.0 if side == "L" else -1.0,
					})
		var thumb_scale := [0.40, 0.56, 0.48]
		for si in 3:
			var tname := "thumb.%02d.%s" % [si + 1, side]
			var idx := _skeleton.find_bone(tname)
			if idx >= 0:
				list.append({
					"idx": idx,
					"rest": _skeleton.get_bone_pose_rotation(idx),
					"weight": thumb_scale[si],
					"thumb": true,
					"sign": 1.0 if side == "L" else -1.0,
				})
		_finger_bones[side] = list


func _pose_fingers(side: String, curl: float) -> void:
	var list: Array = _finger_bones.get(side, [])
	for item in list:
		var idx: int = item["idx"]
		var rest: Quaternion = item["rest"]
		var w: float = item["weight"]
		if item["thumb"]:
			var s: float = item["sign"]
			var rot := Quaternion(Vector3.BACK, s * curl * w * 0.75) * Quaternion(Vector3.RIGHT, -curl * w * 0.25)
			_skeleton.set_bone_pose_rotation(idx, rest * rot)
		else:
			_skeleton.set_bone_pose_rotation(idx, rest * Quaternion(Vector3.RIGHT, curl * w * 0.95))


func _init_hair_chains() -> void:
	var head_idx: int = _bone["Head"]
	if head_idx < 0:
		return
	var bone_count := _skeleton.get_bone_count()
	var chain_num := 0
	for i in bone_count:
		if _skeleton.get_bone_parent(i) != head_idx:
			continue
		var root_name := _skeleton.get_bone_name(i)
		if root_name.begins_with("Eye"):
			continue
		var chain := HairChain.new()
		if root_name.begins_with("Front"):
			chain.zone = HAIR_FRONT
		elif root_name.begins_with("Side Hair L"):
			chain.zone = HAIR_SIDE_L
		elif root_name.begins_with("Side Hair R"):
			chain.zone = HAIR_SIDE_R
		else:
			chain.zone = HAIR_BACK
		var rest_origin := _skeleton.get_bone_global_rest(i).origin
		chain.lateral_bias = clampf(rest_origin.x * 6.0, -1.0, 1.0)
		chain.phase_offset = float(chain_num) * 0.87
		chain_num += 1
		var cur := i
		while cur >= 0:
			chain.bones.append(cur)
			chain.rests.append(_skeleton.get_bone_pose_rotation(cur))
			chain.axes.append(_skeleton.get_bone_global_rest(cur).basis.orthonormalized().inverse())
			var next_child := -1
			for j in bone_count:
				if _skeleton.get_bone_parent(j) == cur:
					next_child = j
					break
			cur = next_child
		_hair_chains.append(chain)


func _trigger_impact_impulse(strength: float) -> void:
	_impact_jolt_vel += strength * 10.5
	_hair_bounce_vel += strength * 5.2
	_hair_sway_vel.y -= strength * 2.4


func _update_impact_jolt(dt: float) -> void:
	if dt <= 0.0:
		return
	var force := -_impact_jolt * 92.0 - _impact_jolt_vel * 13.5
	_impact_jolt_vel += force * dt
	_impact_jolt = clampf(_impact_jolt + _impact_jolt_vel * dt, -0.5, 1.2)


func _update_hair(dt: float) -> void:
	if _hair_chains.is_empty():
		return
	var head_idx: int = _bone["Head"]
	var head_pose := _skeleton.get_bone_global_pose(head_idx)
	var head_world := _skeleton.to_global(head_pose.origin)
	var head_accel_local := Vector3.ZERO
	if not _head_tracked:
		_prev_head_world = head_world
		_prev_head_vel = Vector3.ZERO
		_head_tracked = true
	elif dt > 0.0:
		var scale_norm := maxf(_model.scale.y / _model_base_scale, 0.25)
		var vel := (head_world - _prev_head_world) / dt
		if vel.length() > 45.0 * scale_norm:
			vel = Vector3.ZERO
			_prev_head_vel = Vector3.ZERO
		var accel := (vel - _prev_head_vel) / (dt * scale_norm)
		_prev_head_world = head_world
		_prev_head_vel = vel
		var inv_basis := _skeleton.global_basis.orthonormalized().inverse()
		head_accel_local = (inv_basis * accel).limit_length(24.0)

		var target_sway := Vector2(
			clampf(-head_accel_local.x * 0.016, -0.36, 0.36),
			clampf(-head_accel_local.z * 0.018 - _move_drive * 0.09, -0.40, 0.34)
		)
		var sway_acc := (target_sway - _hair_sway) * 46.0 - _hair_sway_vel * 8.0
		_hair_sway_vel += sway_acc * dt
		_hair_sway += _hair_sway_vel * dt

		var tip_sway_acc := (_hair_sway - _hair_tip_sway) * 30.0 - _hair_tip_sway_vel * 6.0
		_hair_tip_sway_vel += tip_sway_acc * dt
		_hair_tip_sway += _hair_tip_sway_vel * dt

		var target_bounce := clampf(-head_accel_local.y * 0.015, -0.20, 0.42)
		var bounce_acc := (target_bounce - _hair_bounce) * 50.0 - _hair_bounce_vel * 7.2
		_hair_bounce_vel += bounce_acc * dt
		_hair_bounce = clampf(_hair_bounce + _hair_bounce_vel * dt, -0.22, 0.50)

		var tip_bounce_acc := (_hair_bounce - _hair_tip_bounce) * 32.0 - _hair_tip_bounce_vel * 5.6
		_hair_tip_bounce_vel += tip_bounce_acc * dt
		_hair_tip_bounce = clampf(_hair_tip_bounce + _hair_tip_bounce_vel * dt, -0.24, 0.55)

		var target_rot := clampf(_turn_rate * 0.11, -0.38, 0.38)
		var rot_acc := (target_rot - _hair_rot) * 42.0 - _hair_rot_vel * 7.4
		_hair_rot_vel += rot_acc * dt
		_hair_rot += _hair_rot_vel * dt

		var tip_rot_acc := (_hair_rot - _hair_tip_rot) * 26.0 - _hair_tip_rot_vel * 5.4
		_hair_tip_rot_vel += tip_rot_acc * dt
		_hair_tip_rot += _hair_tip_rot_vel * dt

	var head_fwd_local := head_pose.basis.orthonormalized() * Vector3.BACK
	var head_down_tilt := clampf(-head_fwd_local.y, -0.35, 0.55)
	var centrifugal := clampf(absf(_hair_rot) * 0.65, 0.0, 0.25)
	var breeze := sin(_idle_look_time * 1.35) * 0.022 + sin(_idle_look_time * 2.55) * 0.011

	for chain in _hair_chains:
		var count := chain.bones.size()
		for k in count:
			var frac := float(k + 1) / float(count)
			var tip_mix := smoothstep(0.15, 1.0, frac)
			var weight := lerpf(0.28, 1.0, frac * frac)
			var sway := _hair_sway.lerp(_hair_tip_sway, tip_mix)
			var bounce := lerpf(_hair_bounce, _hair_tip_bounce, tip_mix)
			var rot_lag := lerpf(_hair_rot, _hair_tip_rot, tip_mix)
			var flutter := (breeze + sin(_idle_look_time * 2.2 + chain.phase_offset - float(k) * 0.85) * 0.020) * weight

			var pitch := 0.0
			var roll := 0.0
			match chain.zone:
				HAIR_FRONT:
					var lift := maxf(0.0, -sway.y * 0.45 + bounce * 0.48 + maxf(head_down_tilt, 0.0) * 0.14)
					pitch = -clampf(lift * 0.48 + absf(flutter) * 0.35, 0.0, 0.19) * weight
					roll = clampf(sway.x * 0.38 - rot_lag * 0.58 + flutter, -0.15, 0.15) * weight
				HAIR_SIDE_L:
					var flare := maxf(0.0, sway.x * 0.65 + bounce * 0.58 + centrifugal + maxf(head_down_tilt, 0.0) * 0.18)
					roll = clampf(flare * 0.60 + absf(flutter) * 0.45, -0.02, 0.30) * weight
					pitch = clampf(-sway.y * 0.78 - rot_lag * 0.50 - maxf(head_down_tilt, 0.0) * 0.16 + flutter, -0.22, 0.30) * weight
				HAIR_SIDE_R:
					var flare := maxf(0.0, -sway.x * 0.65 + bounce * 0.58 + centrifugal + maxf(head_down_tilt, 0.0) * 0.18)
					roll = -clampf(flare * 0.60 + absf(flutter) * 0.45, -0.02, 0.30) * weight
					pitch = clampf(-sway.y * 0.78 + rot_lag * 0.50 - maxf(head_down_tilt, 0.0) * 0.16 + flutter, -0.22, 0.30) * weight
				_:
					var back_lift := maxf(0.0, -sway.y * 0.85 + bounce * 0.82 + centrifugal * 0.65 + maxf(-head_down_tilt, 0.0) * 0.25)
					pitch = clampf(back_lift * 0.72 + maxf(flutter, 0.0) * 0.75, -0.02, 0.38) * weight
					var fan_out := chain.lateral_bias * maxf(bounce, 0.0) * 0.16
					roll = clampf(sway.x * 0.65 + rot_lag * 0.82 + fan_out + flutter * 0.85, -0.28, 0.28) * weight

			var axes: Basis = chain.axes[k]
			var delta_q := Quaternion(axes.z, roll) * Quaternion(axes.x, pitch)
			_skeleton.set_bone_pose_rotation(chain.bones[k], chain.rests[k] * delta_q)


func _init_face() -> void:
	_eye_l = _skeleton.find_bone("Eye L")
	_eye_r = _skeleton.find_bone("Eye R")
	if _eye_l >= 0:
		_eye_l_rest = _skeleton.get_bone_pose_rotation(_eye_l)
		_eye_l_axes = _skeleton.get_bone_global_rest(_eye_l).basis.orthonormalized().inverse()
	if _eye_r >= 0:
		_eye_r_rest = _skeleton.get_bone_pose_rotation(_eye_r)
		_eye_r_axes = _skeleton.get_bone_global_rest(_eye_r).basis.orthonormalized().inverse()

	for mesh_name in ["Body", "Eye Line", "Eyelashes"]:
		var mesh := _skeleton.get_node_or_null(mesh_name) as MeshInstance3D
		if mesh == null:
			continue
		var idx_l := mesh.find_blend_shape_by_name("Blink L")
		var idx_r := mesh.find_blend_shape_by_name("Blink R")
		if idx_r < 0:
			idx_r = mesh.find_blend_shape_by_name("Blinl R")
		if idx_l >= 0 or idx_r >= 0:
			_blink_targets.append({"mesh": mesh, "l": idx_l, "r": idx_r})


func _next_rand() -> float:
	_blink_seed = (_blink_seed * 1103515245 + 12345) & 0x7fffffff
	return float(_blink_seed % 10000) / 10000.0


func _update_face(dt: float) -> void:
	if dt > 0.0:
		if _blink_progress >= 0.0:
			_blink_progress += dt / 0.16
			if _blink_progress >= 1.0:
				_blink_progress = -1.0
				if _double_blink_queued:
					_double_blink_queued = false
					_blink_timer = 0.14
				else:
					_double_blink_queued = _next_rand() < 0.18
					_blink_timer = 2.8 + _next_rand() * 2.6
		else:
			_blink_timer -= dt
			if _blink_timer <= 0.0:
				_blink_progress = 0.0

		_gaze_timer -= dt
		if _gaze_timer <= 0.0:
			_gaze_timer = 1.6 + _next_rand() * 2.4
			_eye_idle_target = Vector2((_next_rand() - 0.5) * 0.18, (_next_rand() - 0.42) * 0.09)
		_head_idle_gaze = _head_idle_gaze.lerp(_eye_idle_target * 0.65, minf(dt * 2.4, 1.0))

		var idle_w := (1.0 - _stride) * (1.0 - _eye_override)
		var target_eye := Vector2(
			clampf((_eye_idle_target.x - _head_idle_gaze.x * 0.5) * idle_w + _eye_local_yaw * _eye_override, -TURN_EYE_MAX_YAW, TURN_EYE_MAX_YAW),
			clampf((_eye_idle_target.y - _head_idle_gaze.y * 0.5) * idle_w, -0.065, 0.095)
		)
		_eye_gaze = _eye_gaze.lerp(target_eye, minf(dt * 24.0, 1.0))
	else:
		_eye_gaze = Vector2(_eye_local_yaw * _eye_override, 0.0)

	if _eye_l >= 0:
		var q_l := Quaternion(_eye_l_axes.y, _eye_gaze.x) * Quaternion(_eye_l_axes.x, _eye_gaze.y)
		_skeleton.set_bone_pose_rotation(_eye_l, _eye_l_rest * q_l)
	if _eye_r >= 0:
		var q_r := Quaternion(_eye_r_axes.y, _eye_gaze.x) * Quaternion(_eye_r_axes.x, _eye_gaze.y)
		_skeleton.set_bone_pose_rotation(_eye_r, _eye_r_rest * q_r)

	var blink_val := 0.0
	if _blink_progress >= 0.0:
		if _blink_progress < 0.38:
			blink_val = smoothstep(0.0, 0.38, _blink_progress)
		else:
			blink_val = 1.0 - smoothstep(0.38, 1.0, _blink_progress)
	for target in _blink_targets:
		var mesh: MeshInstance3D = target["mesh"]
		var l: int = target["l"]
		var r: int = target["r"]
		if l >= 0:
			mesh.set_blend_shape_value(l, blink_val)
		if r >= 0:
			mesh.set_blend_shape_value(r, blink_val)


func _pose(key: String, pitch: float, yaw := 0.0, roll := 0.0) -> Quaternion:
	var axes: Basis = _axes[key]
	var delta := Quaternion(axes.z, roll) * Quaternion(axes.y, yaw) * Quaternion(axes.x, pitch)
	var posed: Quaternion = _rest[key] * delta
	_skeleton.set_bone_pose_rotation(_bone[key], posed)
	return posed


func _pose_local(key: String, x_rot: float, y_rot := 0.0, z_rot := 0.0) -> Quaternion:
	var delta := Quaternion(Vector3.BACK, z_rot) * Quaternion(Vector3.UP, y_rot) * Quaternion(Vector3.RIGHT, x_rot)
	var posed: Quaternion = _rest[key] * delta
	_skeleton.set_bone_pose_rotation(_bone[key], posed)
	return posed


func _compute_knee_bend_deg(leg: Leg) -> float:
	var p_hip := _skeleton.get_bone_global_pose(leg.thigh).origin
	var p_knee := _skeleton.get_bone_global_pose(leg.shin).origin
	var p_ank := _skeleton.get_bone_global_pose(leg.foot).origin
	var v1 := (p_knee - p_hip).normalized()
	var v2 := (p_ank - p_knee).normalized()
	return rad_to_deg(acos(clampf(v1.dot(v2), -1.0, 1.0)))


func get_turn_telemetry() -> Dictionary:
	var model_world_yaw := global_rotation.y + _visual_yaw_offset
	var feet_mean := _mean_angle(_foot_l.world_yaw, _foot_r.world_yaw)
	var head_rel := angle_difference(_pelvis_world_yaw, _head_world_yaw)
	var chest_rel := angle_difference(_pelvis_world_yaw, _chest_world_yaw)

	var spine_g := _skeleton.get_bone_global_pose(_bone["spine"])
	var chest_g := _skeleton.get_bone_global_pose(_bone["spine.003"])
	var head_g := _skeleton.get_bone_global_pose(_bone["Head"])
	var eye_g := _skeleton.get_bone_global_pose(_eye_l) if _eye_l >= 0 else head_g
	var sh_l_pos := _skeleton.get_bone_global_pose(_bone["upper_arm.L"]).origin
	var sh_r_pos := _skeleton.get_bone_global_pose(_bone["upper_arm.R"]).origin
	var sh_vec := sh_l_pos - sh_r_pos
	var shoulder_line_yaw := atan2(-sh_vec.z, sh_vec.x)

	var spine_ax: Basis = _axes["spine"]
	var chest_ax: Basis = _axes["spine.003"]
	var head_ax: Basis = _axes["Head"]
	var chest_fwd := (_skeleton.global_basis * (chest_g.basis * (chest_ax * Vector3.BACK))).slide(Vector3.UP).normalized()
	var head_fwd := (_skeleton.global_basis * (head_g.basis * (head_ax * Vector3.BACK))).slide(Vector3.UP).normalized()
	var eye_fwd := (_skeleton.global_basis * (eye_g.basis * (_eye_l_axes * Vector3.BACK))).slide(Vector3.UP).normalized()
	var pelvis_fwd := (_skeleton.global_basis * (spine_g.basis * (spine_ax * Vector3.BACK))).slide(Vector3.UP).normalized()

	var l_ank_bone_w := _skeleton.to_global(_skeleton.get_bone_global_pose(_left.foot).origin)
	var r_ank_bone_w := _skeleton.to_global(_skeleton.get_bone_global_pose(_right.foot).origin)

	var chest_up_local := (chest_g.basis * (chest_ax * Vector3.UP)).normalized()
	var actual_torso_lean_rad := atan2(chest_up_local.x, chest_up_local.y)

	return {
		"mode": _turn_mode,
		"use_layered_turn": use_layered_turn,
		"target_yaw": _target_yaw,
		"model_world_yaw": model_world_yaw,
		"eye_world_yaw": _eye_world_yaw,
		"head_world_yaw": _head_world_yaw,
		"chest_world_yaw": _chest_world_yaw,
		"pelvis_world_yaw": _pelvis_world_yaw,
		"left_foot_world_yaw": _foot_l.world_yaw,
		"right_foot_world_yaw": _foot_r.world_yaw,
		"feet_mean_world_yaw": feet_mean,
		"bone_eye_world_yaw": _dir_to_yaw(eye_fwd) if eye_fwd.length_squared() > 0.01 else _eye_world_yaw,
		"bone_head_world_yaw": _dir_to_yaw(head_fwd) if head_fwd.length_squared() > 0.01 else _head_world_yaw,
		"bone_chest_world_yaw": _dir_to_yaw(chest_fwd) if chest_fwd.length_squared() > 0.01 else _chest_world_yaw,
		"bone_pelvis_world_yaw": _dir_to_yaw(pelvis_fwd) if pelvis_fwd.length_squared() > 0.01 else _pelvis_world_yaw,
		"eye_local_yaw": _eye_local_yaw,
		"head_rel_pelvis": head_rel,
		"chest_rel_pelvis": chest_rel,
		"chest_to_head_ratio": (chest_rel / head_rel) if absf(head_rel) > 0.04 else 0.0,
		"shoulder_line_local_yaw": shoulder_line_yaw,
		"shoulder_counter_z": _last_shoulder_counter,
		"spine_s_curve": _last_spine_s_curve,
		"inward_lean_rad": _inward_lean,
		"actual_torso_lean_rad": actual_torso_lean_rad,
		"pelvis_shift_x": _last_hip_local.x - _hip_rest.x,
		"pelvis_drop_y": _last_hip_local.y - _hip_rest.y,
		"turn_crouch": _turn_crouch,
		"left_knee_bend_deg": _last_l_knee_deg,
		"right_knee_bend_deg": _last_r_knee_deg,
		"left_arm_open": _last_l_arm_open,
		"right_arm_open": _last_r_arm_open,
		"left_arm_amp": _last_l_arm_amp,
		"right_arm_amp": _last_r_arm_amp,
		"turn_sharpness": _turn_sharpness,
		"turn_sign": _turn_sign,
		"turn_stride_mult": _turn_stride_mult,
		"turn_cadence_mult": _turn_cadence_mult,
		"actual_speed": _actual_speed,
		"standing_turning": _stand_turning,
		"standing_step_active": _stand_step_active,
		"standing_step_side": _stand_step_side,
		"standing_step_count": _stand_step_count,
		"left_planted": _foot_l.planted,
		"right_planted": _foot_r.planted,
		"left_pivot_mode": _foot_l.pivot_mode,
		"right_pivot_mode": _foot_r.pivot_mode,
		"left_pivot_world": _foot_l.pivot_world,
		"right_pivot_world": _foot_r.pivot_world,
		"left_heel_world": _foot_heel_world(_foot_l, _left),
		"right_heel_world": _foot_heel_world(_foot_r, _right),
		"left_ball_world": _foot_ball_world(_foot_l, _left),
		"right_ball_world": _foot_ball_world(_foot_r, _right),
		"left_ankle_world": l_ank_bone_w,
		"right_ankle_world": r_ank_bone_w,
		"left_foot_pitch": _foot_l.foot_pitch,
		"right_foot_pitch": _foot_r.foot_pitch,
		"left_last_step_len": _foot_l.last_step_length,
		"right_last_step_len": _foot_r.last_step_length,
		"left_last_landing_pitch": _foot_l.last_landing_pitch,
		"right_last_landing_pitch": _foot_r.last_landing_pitch,
		"left_pre_land_yaw_err": _foot_l.last_pre_land_yaw_err,
		"right_pre_land_yaw_err": _foot_r.last_pre_land_yaw_err,
	}


static func _yaw_forward(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


static func _yaw_left(yaw: float) -> Vector3:
	return Vector3(-cos(yaw), 0.0, sin(yaw))


static func _dir_to_yaw(dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z)


static func _mean_angle(a: float, b: float) -> float:
	return a + angle_difference(a, b) * 0.5
