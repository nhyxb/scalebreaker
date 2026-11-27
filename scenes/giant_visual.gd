extends CharacterBody3D
## Procedural heavy gait, terrain foot IK, multi-layer hair spring dynamics,
## and living eye/facial animation on the imported Kawaii skeleton.
## The skeleton faces +Z in model space, while the gameplay CharacterBody3D faces -Z.

const CONTACT_FRACTION := 0.60
const HALF_STEP := 0.285
const SWING_HEIGHT := 0.35
const WALK_REF_SPEED := 7.0
const STOP_SWING_SECONDS := 0.56
const STANCE_SETTLE_SECONDS := 0.50

# Crouch -> pick up from ground -> stand up -> crush -> recover animation tuning.
const PICKUP_CRUSH_TIME := 0.745
const PALM_GRASP_OFFSET_R := Vector3(-0.036, 0.078, 0.008)
const PALM_GRASP_OFFSET_L := Vector3(0.036, 0.078, 0.008)

# Heavy sweeping giant punch (挥拳) -> follow-through -> recover animation tuning.
const PUNCH_IMPACT_TIME := 0.455
const PUNCH_TARGET_LOCAL := Vector3(-0.02, 1.22, 0.74)

# Heavy area sit-crush (坐压) -> hold & pack -> slow hand-assisted push-up recovery.
const SIT_CRUSH_DURATION := 4.80
const SIT_CRUSH_DROP_START := 0.30
const SIT_CRUSH_IMPACT_TIME := 0.375
const SIT_CRUSH_ROCK_START := 0.44
const SIT_CRUSH_RISE_START := 0.67
const SIT_CRUSH_PALM_GROUND_Y := 0.008
const SIT_CRUSH_RADIUS_SCALE := 0.295 # Tight seated footprint radius relative to model scale (~4.4m at 25.2m height).

const STOP_NONE := 0
const STOP_SWING := 1
const STOP_SETTLE := 2
const HEAD_ATTACHMENTS := [&"Eye Line", &"Eyebrows", &"Eyelashes", &"Eyes", &"Hair", &"Headband", &"Nose Line"]
## Sub-centimetre face pieces that vanish long before a full silhouette does. They are turned
## off for the farthest detail tier so a 60-actor brawl stops drawing lashes nobody can see.
const FACE_DETAIL_PARTS: PackedStringArray = ["Eye Line", "Eyebrows", "Eyelashes", "Eyes", "Nose Line",
		"eye", "Eye", "lash", "Lash", "brow", "Brow"]
# First-person eye placement, as fractions of the actor height. The eye sits a little above
# and in front of the Head joint so looking around does not clip into the neck hole; these
# values are mirrored by round.rs for the look-down lean.
const FIRST_PERSON_EYE_UP := 0.055
const FIRST_PERSON_EYE_FORWARD := 0.045
const FIRST_PERSON_EYE_FALLBACK := 0.90
const GiantSkin := preload("res://scenes/giant_skin.gd")
const SKINS := {
	&"Kawaii": null,
	&"Hina": preload("res://scenes/hina_skin.gd"),
	&"Chibi Catgirl": preload("res://scenes/chibi_catgirl_skin.gd"),
	&"Snow Fox": preload("res://scenes/snow_fox_skin.gd"),
}

# Foot pivot geometry in model space (derived from foot/toe rest and shoe sole).
const TOE_OFFSET := Vector3(0.0, -0.096, 0.064)

const IDLE_FOOT_YAW := 0.045

# World-locked foot pivot & hierarchical turn cascade constants.
const PIVOT_HEEL := 0
const PIVOT_BALL := 1
const HEEL_Z_FROM_ANKLE := -0.046
const BALL_Z_FROM_ANKLE := 0.064
const BALL_JOINT_Y := 0.029437
const ANKLE_GROUND_Y := 0.125219
const HEEL_TO_BALL_DIST := BALL_Z_FROM_ANKLE - HEEL_Z_FROM_ANKLE # 0.110

const TURN_EYE_MAX_YAW := 0.135
const TURN_HEAD_OVER_PELVIS_MAX := 1.18
const TURN_CHEST_OVER_PELVIS_MAX := 0.54
const STAND_START_DEADZONE := 0.22      # ~12.6 deg: eyes/head glance without shuffling feet
const STAND_DONE_DEADZONE := 0.06       # ~3.4 deg: standing turn settle threshold
const STAND_STEP_MAX_YAW := 0.62        # ~35.5 deg per small ship-like step (~6 steps for 180 deg)
const STAND_ANTICIPATION_BASE := 0.15   # Look-first anticipation beat before first foot lifts
const STAND_STEP_BASE_DUR := 0.52       # Base duration per standing pivot step at 25.2m scale
const STAND_TRANSFER_FRAC := 0.22       # Double-support weight transfer before lifting swing foot
const HEEL_ROLL_SECONDS := 0.13         # Heel-strike to flat sole roll duration
const HEEL_STRIKE_PITCH := -0.25        # Clear anatomical heel-first dorsiflexion (~-14.3 deg)
const WALK_SHARP_ENTER := 0.40          # Metric above which walking curve transitions into sharp turn
const WALK_SHARP_FULL := 1.50           # Metric at which sharp turn reaches full stride adaptation
const SWING_TARGET_LOCK := 0.46

# Bounds and silhouettes measured from the lower shoe vertices of each imported skin.
# Offsets and half extents are in the unscaled driver model's units; X is world right
# and -Z is forward. Alternate-skin centers are expressed in that skin's foot-bone space.
const KAWAII_SOLE: Array[Vector2] = [
	Vector2(-1.0, -0.21), Vector2(-0.93, -0.58), Vector2(-0.65, -0.77),
	Vector2(0.14, -1.0), Vector2(0.59, -1.0), Vector2(0.91, -0.91),
	Vector2(1.0, -0.76), Vector2(0.95, -0.23), Vector2(0.74, 0.17),
	Vector2(0.16, 0.96), Vector2(-0.02, 1.0), Vector2(-0.52, 0.89),
	Vector2(-0.85, 0.58),
]
const HINA_SOLE_L: Array[Vector2] = [
	Vector2(-1.0, -0.42), Vector2(-0.85, -0.66), Vector2(-0.43, -0.92),
	Vector2(0.06, -1.0), Vector2(0.56, -0.94), Vector2(1.0, -0.44),
	Vector2(0.81, 0.58), Vector2(0.54, 0.94), Vector2(0.21, 1.0),
	Vector2(-0.35, 0.83), Vector2(-0.51, 0.60), Vector2(-0.99, -0.18),
]
const HINA_SOLE_R: Array[Vector2] = [
	Vector2(-1.0, -0.40), Vector2(-0.62, -0.92), Vector2(-0.16, -1.0),
	Vector2(0.33, -0.94), Vector2(0.72, -0.68), Vector2(1.0, -0.20),
	Vector2(0.57, 0.81), Vector2(0.37, 0.94), Vector2(0.05, 1.0),
	Vector2(-0.38, 0.94), Vector2(-0.62, 0.60), Vector2(-0.95, -0.19),
]
const CHIBI_SOLE: Array[Vector2] = [
	Vector2(-1.0, -0.01), Vector2(-0.96, -0.36), Vector2(-0.77, -0.68),
	Vector2(-0.41, -0.93), Vector2(0.05, -1.0), Vector2(0.51, -0.94),
	Vector2(0.80, -0.75), Vector2(0.95, -0.46), Vector2(1.0, -0.07),
	Vector2(0.94, 0.34), Vector2(0.75, 0.69), Vector2(0.43, 0.92),
	Vector2(0.0, 1.0), Vector2(-0.43, 0.91), Vector2(-0.73, 0.70),
	Vector2(-0.93, 0.37),
]
const SNOW_FOX_SOLE: Array[Vector2] = [
	Vector2(-1.0, -0.22), Vector2(-0.94, -0.50), Vector2(-0.76, -0.77),
	Vector2(-0.24, -0.94), Vector2(0.35, -1.0), Vector2(0.75, -0.86),
	Vector2(0.90, -0.75), Vector2(1.0, -0.35), Vector2(0.75, 0.67),
	Vector2(0.67, 0.90), Vector2(0.21, 1.0), Vector2(-0.37, 0.87),
	Vector2(-0.54, 0.63),
]

const HAIR_FRONT := 0
const HAIR_SIDE_L := 1
const HAIR_SIDE_R := 2
const HAIR_BACK := 3

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
	var sole_offset: Vector3
	var skin_sole_center: Vector3
	var sole_half_extents: Vector2
	var sole_profile: PackedVector2Array
	var ground_y := 0.0
	var ground_pitch := 0.0
	var ground_roll := 0.0
	var last_pitch := 0.0
	var last_roll := 0.0
	var last_yaw := 0.0
	var last_toe := 0.0


class Arm:
	var side: String
	var sign_x: float
	var shoulder: int
	var upper: int
	var forearm: int
	var hand: int
	var upper_offset: Vector3
	var upper_length: float
	var lower_length: float
	var upper_rest: Quaternion
	var forearm_rest: Quaternion
	var hand_rest: Quaternion
	var palm_offset: Vector3


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
	var swing_start_phase: float = CONTACT_FRACTION
	var swing_t: float = 0.0
	var swing_remaining: float = 0.0
	var last_step_length: float = 0.0
	var last_landing_pitch: float = 0.0
	var last_pre_land_yaw_err: float = 0.0


@onready var _skeleton: Skeleton3D = $Model/metarig/Skeleton3D
@onready var _model: Node3D = $Model
@onready var _human_model: Node3D = $HumanModel
@onready var _human_anim: AnimationPlayer = $HumanModel/AnimationPlayer
var _human_head: MeshInstance3D
var _human_meshes: Array[MeshInstance3D] = []
var _human_stage := false
var _human_dying := false
var _human_step_segment := -1
@onready var _health_bar: MeshInstance3D = $HealthBar
var _health_bar_height := 0.0
var _shown_health := 1.0
@onready var _body_mesh: MeshInstance3D = _skeleton.get_node("Body")
@onready var _body_mesh_with_head: ArrayMesh = _body_mesh.mesh
static var _headless_body_meshes := {}
static var _skin_rng := RandomNumberGenerator.new()

var skin_name: StringName = &"Kawaii"
var _active_skin: GiantSkin
var _kawaii_meshes: Array[MeshInstance3D] = []
var _first_person_enabled := false
var _silhouette_overlay: StandardMaterial3D
var _distant_clipped := false

var pace := 1.0
var human_pace := 1.0
var fixed_walk_tempo := false
var size_scaled_walk := false
var _bone := {}
var _rest := {}
var _axes := {}
var _finger_bones := {} # side -> Array of Dictionaries {idx, rest, weight, thumb, sign}
var _hair_chains: Array[HairChain] = []
var _left: Leg
var _right: Leg
var _arm_l: Arm
var _arm_r: Arm
var _hip_rest: Vector3
var _model_base_yaw := PI
var _model_base_scale := 14.8
var _prev_model_scale := 14.8
var _growth_surge := 0.0

# Locomotion & rhythm state (all driven strictly by show_motion delta so pause freezes everything).
var _cycle := 0.0
var _breath := 0.0
var _idle_look_time := 0.0
var _stride := 0.0
var _foot_stride := 0.0
var _step_scale := 1.0
var _move_drive := 0.0
var _last_walk_speed := WALK_REF_SPEED
var _stop_phase := STOP_NONE
var _stop_carry_enabled := false
var _stop_heading := Vector3.FORWARD
var _stop_support_is_left := false
var _stop_support_world := Vector3.ZERO
var _stop_support_yaw := 0.0
var _stop_swing_start_world := Vector3.ZERO
var _stop_swing_target_world := Vector3.ZERO
var _stop_swing_start_yaw := 0.0
var _stop_swing_target_yaw := 0.0
var _stop_swing_start_y := 0.0
var _stop_swing_start_pitch := 0.0
var _stop_swing_start_toe := 0.0
var _stop_swing_rem := 0.5
var _stop_swing_elapsed := 0.0
var _stop_swing_dur := 0.40
var _stop_swing_v0 := 0.0
var _stop_swing_v1 := 0.0
var _stop_swing_landing := 0.5
var _stop_lead_is_left := true
var _stop_lead_world := Vector3.ZERO
var _stop_trail_start_world := Vector3.ZERO
var _stop_trail_target_world := Vector3.ZERO
var _stop_lead_yaw := 0.0
var _stop_trail_start_yaw := 0.0
var _stop_trail_target_yaw := 0.0
var _stop_carry_dist := 0.0
var _stop_settle_elapsed := 0.0
var _stop_settle_dur := 0.50
var _stop_just_landed := "" # "", "L", or "R"
var _prev_giant_pos := Vector3.ZERO
var _giant_pos_tracked := false
var _prev_speed := 0.0
var _stop_momentum := 0.0
var _was_on_floor := true
var _air_weight := 0.0
var _prev_body_yaw := 0.0
var _yaw_initialized := false
var _turn_rate := 0.0
var _visual_yaw_offset := 0.0

# Hierarchical top-down turn cascade (Eyes -> Head -> Chest -> Pelvis -> Feet) & world-locked feet.
var _foot_l: FootTrack
var _foot_r: FootTrack
var _foot_tracks_ready := false
var _prev_foot_scale := 14.8
var _turn_target_yaw := 0.0
var _eye_world_yaw := 0.0
var _eye_local_yaw := 0.0
var _eye_turn_override := 0.0
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
var _actual_world_vel := Vector3.ZERO
var _turn_mode := "idle"

# Standing multi-step pivot state machine ("小碎步，像掉头的大船").
var _stand_turning := false
var _stand_dir := 0.0
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
var _walk_was_moving := false
var _walk_init_step := false
var _walk_cycle_prev := 0.0
var _walk_just_landed := ""
var _last_hip_local := Vector3.ZERO
var _last_l_knee_deg := 0.0
var _last_r_knee_deg := 0.0
var _last_l_arm_open := 0.0
var _last_r_arm_open := 0.0
var _last_l_arm_amp := 0.0
var _last_r_arm_amp := 0.0
var _last_shoulder_counter := 0.0
var _last_spine_s_curve := 0.0

# Current & transition pose tracking.
var _left_ankle: Vector3
var _right_ankle: Vector3
var _snap_hip: Vector3
var _snap_rots := {}
var _snap_left_ankle: Vector3
var _snap_right_ankle: Vector3
var _snap_left_foot := Vector4.ZERO   # pitch, roll, yaw, toe
var _snap_right_foot := Vector4.ZERO
var _pelvis_ground_drop := 0.0

# Crouch-pickup-crush action state.
var _pickup_crush_active := false
var _pickup_crushed_emitted := false
var _pickup_exit_blend := 0.0
var _pickup_brow_target := 0.0
var _pickup_eye_target := Vector2.ZERO
var _pickup_eye_override := 0.0
var _pickup_squint := 0.0
var _left_at_pickup: Vector3
var _right_at_pickup: Vector3

# Heavy punch (挥拳) action state.
var _hand_aim := Vector3.ZERO
var _hand_start_yaw := 0.0
var _punch_active := false
var _punch_impact_emitted := false
var _punch_exit_blend := 0.0
var _punch_brow_target := 0.0
var _punch_eye_target := Vector2.ZERO
var _punch_eye_override := 0.0
var _punch_squint := 0.0
var _left_at_punch: Vector3
var _right_at_punch: Vector3

# Heavy area sit-crush (坐压) action state.
var _sit_crush_active := false
var _sit_crush_impact_emitted := false
var _sit_crush_exit_blend := 0.0
var _sit_crush_from_idle_blend := 0.0
var _sit_crush_brow_target := 0.0
var _sit_crush_eye_target := Vector2.ZERO
var _sit_crush_eye_override := 0.0
var _sit_crush_squint := 0.0
var _sit_crush_hair_float := 0.0
var _sit_crush_start_yaw := 0.0
var _left_at_sit: Vector3
var _right_at_sit: Vector3

# Seated idle (坐姿待机) state after sitting down.
var _sit_idle_active := false
var _sit_idle_time := 0.0
var _sit_idle_enter_blend := 0.0
var _sit_idle_exit_blend := 0.0
var _sit_idle_eye_bias := Vector2.ZERO
var _left_at_sit_idle: Vector3
var _right_at_sit_idle: Vector3

# Secondary spring state (two-layer overlapping hair wave & weighted body impact jolt).
var _prev_head_world := Vector3.ZERO
var _prev_head_vel := Vector3.ZERO
var _head_tracked := false
var _hair_sway := Vector2.ZERO        # root spring: x lateral, y fore-aft
var _hair_sway_vel := Vector2.ZERO
var _hair_tip_sway := Vector2.ZERO    # delayed tip wave spring
var _hair_tip_sway_vel := Vector2.ZERO
var _hair_bounce := 0.0
var _hair_bounce_vel := 0.0
var _hair_tip_bounce := 0.0
var _hair_tip_bounce_vel := 0.0
var _hair_rot := 0.0                  # rotational yaw lag spring
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
var _eye_gaze := Vector2.ZERO         # x: yaw (+left), y: pitch (+down)
var _eye_idle_target := Vector2.ZERO
var _head_idle_gaze := Vector2.ZERO
var _gaze_timer := 1.4
var _blink_targets: Array[Dictionary] = []
var _eyebrow_mesh: MeshInstance3D
var _brow_angry_l := -1
var _brow_angry_r := -1
var _brow_down_l := -1
var _brow_down_r := -1
var _brow_up_l := -1
var _brow_up_r := -1
var _blink_timer := 2.4
var _blink_progress := -1.0
var _double_blink_queued := false
var _blink_seed := 137
var _brow_tension := 0.0
var _impact_flinch := 0.0


func _ready() -> void:
	set_process(false)
	# Humans reuse the same imported character used by the evacuation mode.
	_human_head = _human_model.find_child("head-mesh", true, false) as MeshInstance3D
	for mesh in _human_model.find_children("*", "MeshInstance3D", true, false):
		_human_meshes.append(mesh as MeshInstance3D)
	for clip in [&"idle", &"walk"]:
		_human_anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	_human_anim.play(&"idle")
	_human_model.visible = false
	# Keep only the rig. The source file also contains reference planes and anchors.
	for child in _model.get_children():
		if child.name != &"metarig":
			child.queue_free()
	for child in _skeleton.get_children():
		if child is MeshInstance3D:
			_kawaii_meshes.append(child)
	GiantSkin.shade_anime_materials(_kawaii_meshes)
	_model_base_yaw = _model.rotation.y

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
	_configure_soles()
	_arm_l = _make_arm("L")
	_arm_r = _make_arm("R")
	_hip_rest = _skeleton.get_bone_pose_position(_bone["spine"])
	_left_ankle = _left.ankle_rest
	_right_ankle = _right.ankle_rest
	_left_at_pickup = _left_ankle
	_right_at_pickup = _right_ankle
	_left_at_punch = _left_ankle
	_right_at_punch = _right_ankle
	_left_at_sit = _left_ankle
	_right_at_sit = _right_ankle
	_left_at_sit_idle = _left_ankle
	_right_at_sit_idle = _right_ankle
	_snap_hip = _hip_rest
	_snap_left_ankle = _left_ankle
	_snap_right_ankle = _right_ankle
	_model_base_scale = _model.scale.z
	_prev_model_scale = _model.scale.y
	_prev_foot_scale = _model.scale.z
	_init_foot_tracks()

	show_motion(0.0, -1.0, 0.0)
	_roll_skin()


## The growth round starts every actor as a human and swaps to this giant rig at the
## demolition height. The giant skin is rolled once per round and survives respawns.
func set_stage(human: bool) -> void:
	if _human_stage == human:
		return
	_human_stage = human
	_human_dying = false
	set_distant_clip(_distant_clipped)
	if human:
		_human_step_segment = -1
		_human_anim.play(&"idle")
		_human_anim.speed_scale = 1.0
		_set_head_part_hidden(_human_head, _first_person_enabled)
	else:
		_human_step_segment = -1
		_human_anim.stop()
		set_first_person(_first_person_enabled)
	_clear_hit_overlay()


func _human_motion(speed: float, delta: float) -> bool:
	if _human_dying:
		_human_step_segment = -1
		return false
	var dt := clampf(delta, 0.0, 0.05)
	if dt <= 0.0:
		return false
	var clip := &"walk" if speed > 0.000001 else &"idle"
	if _human_anim.current_animation != clip:
		_human_anim.play(clip, 0.12)
		_human_step_segment = -1
	var reference := 5.8 * human_pace * maxf(_human_model.scale.y, 0.0000001)
	_human_anim.speed_scale = clampf(speed / reference, 0.25, 1.8) if clip == &"walk" else 1.0
	if clip == &"idle" or not is_on_floor() or _human_anim.current_animation_length <= 0.0:
		_human_step_segment = -1
		return false
	var phase := fposmod(_human_anim.current_animation_position / _human_anim.current_animation_length, 1.0)
	var segment := int(phase * 2.0)
	var footfall := _human_step_segment >= 0 and segment != _human_step_segment
	_human_step_segment = segment
	return footfall


func _roll_skin() -> void:
	_set_skin(SKINS.keys()[_skin_rng.randi_range(0, SKINS.size() - 1)])


func _set_skin(next: StringName) -> void:
	if next == skin_name:
		return
	_clear_hit_overlay()
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
	_configure_soles()
	_skeleton.visible = _active_skin == null
	set_first_person(_first_person_enabled)
	_refresh_silhouette_overlay()


func _active_skin_meshes() -> Array[MeshInstance3D]:
	return _active_skin.meshes if _active_skin != null else _kawaii_meshes


func _current_meshes() -> Array[MeshInstance3D]:
	return _human_meshes if _human_stage else _active_skin_meshes()


func set_distant_clip(clipped: bool) -> void:
	_distant_clipped = clipped
	_model.visible = not clipped and not _human_stage
	_human_model.visible = not clipped and _human_stage


func set_silhouette_opacity(opacity: float) -> void:
	var was_visible := _silhouette_visible()
	if _silhouette_overlay == null:
		if opacity <= 0.0:
			return
		_silhouette_overlay = StandardMaterial3D.new()
		_silhouette_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_silhouette_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_silhouette_overlay.disable_fog = true
	_silhouette_overlay.albedo_color = Color(0.36, 0.45, 0.50, opacity)
	if was_visible != _silhouette_visible():
		_refresh_silhouette_overlay()


func _silhouette_visible() -> bool:
	return _silhouette_overlay != null and _silhouette_overlay.albedo_color.a > 0.0


func _refresh_silhouette_overlay() -> void:
	if _silhouette_overlay == null:
		return
	var visible_far := _silhouette_visible()
	for mesh in _active_skin_meshes():
		if visible_far:
			mesh.material_overlay = _silhouette_overlay
		elif mesh.material_overlay == _silhouette_overlay:
			mesh.material_overlay = null


## World-space eye point for the first-person camera. Reads the live Head bone of the rig
## that is currently drawn, so the view rides walking bob, heavy ground contact, hand actions and
## the sit-down drop instead of a fixed fraction of the capsule. The human stage and any rig
## without a usable Head bone fall back to the old height formula.
func first_person_eye_position() -> Vector3:
	var height := capsule_height()
	var fallback := global_position + Vector3.UP * (height * FIRST_PERSON_EYE_FALLBACK)
	if _human_stage:
		return fallback
	var rig := _skeleton
	var bone_name := &"Head"
	if _active_skin != null and _active_skin.skeleton != null:
		rig = _active_skin.skeleton
		bone_name = _active_skin.head_bone
	if rig == null:
		return fallback
	var bone := rig.find_bone(bone_name)
	if bone < 0:
		return fallback
	var head := rig.global_transform * rig.get_bone_global_pose(bone).origin
	var forward := Vector3.FORWARD.rotated(Vector3.UP, global_rotation.y)
	return head + forward * (height * FIRST_PERSON_EYE_FORWARD) \
			+ Vector3.UP * (height * FIRST_PERSON_EYE_UP)


## Capsule height doubles as the actor height, both for the human stage and the giant rig.
func capsule_height() -> float:
	var collision := get_node_or_null(^"Collision") as CollisionShape3D
	var capsule := collision.shape as CapsuleShape3D if collision != null else null
	return capsule.height if capsule != null else 1.8


## 0 = full detail, 1 = no real-time shadows and no hair/tail springs, 2 = face details off.
## Driven by round.rs from the camera distance so distant giants stop paying for pixels that
## cannot be seen.
var _detail_tier := 0
var _tier_shadow: Dictionary = {}


func set_detail_tier(tier: int) -> void:
	tier = clampi(tier, 0, 2)
	if tier == _detail_tier:
		return
	_detail_tier = tier
	_apply_detail_tier()


func detail_tier() -> int:
	return _detail_tier


func _apply_detail_tier() -> void:
	var shadows_off := _detail_tier >= 1
	for geometry in find_children("*", "MeshInstance3D", true, false):
		var mesh := geometry as GeometryInstance3D
		if mesh == null:
			continue
		if mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			# First person owns the hidden head parts; the tier never overrides them.
			continue
		if shadows_off:
			if not _tier_shadow.has(mesh):
				_tier_shadow[mesh] = mesh.cast_shadow
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		elif _tier_shadow.has(mesh):
			mesh.cast_shadow = int(_tier_shadow[mesh])
	if _detail_tier < 2:
		for part: String in FACE_DETAIL_PARTS:
			for node in find_children(part, "Node3D", true, false):
				(node as Node3D).visible = true
		return
	for part: String in FACE_DETAIL_PARTS:
		for node in find_children(part, "Node3D", true, false):
			(node as Node3D).visible = false


func set_first_person(enabled: bool) -> void:
	_first_person_enabled = enabled
	if _human_stage:
		_set_head_part_hidden(_human_head, enabled)
		return
	if _active_skin != null:
		for body in _active_skin.body_meshes:
			_apply_body_visibility(body, _active_skin.body_meshes[body], _active_skin.head_bone, enabled)
		for attachment in _active_skin.head_parts:
			_set_head_part_hidden(attachment, enabled)
	else:
		_apply_body_visibility(_body_mesh, _body_mesh_with_head, &"Head", enabled)
		for attachment: StringName in HEAD_ATTACHMENTS:
			_set_head_part_hidden(_skeleton.get_node(NodePath(attachment)), enabled)


## First person hides the head from the camera by switching it to shadows-only, so the
## giant keeps a complete head silhouette on the ground instead of a neck stump.
func _set_head_part_hidden(node: Node3D, hidden: bool) -> void:
	if node == null:
		return
	if node is GeometryInstance3D:
		var geometry := node as GeometryInstance3D
		geometry.visible = true
		if hidden:
			geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		else:
			geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	else:
		node.visible = not hidden


func _apply_body_visibility(body: MeshInstance3D, source: ArrayMesh, head_bone: StringName, enabled: bool) -> void:
	if enabled and not _headless_body_meshes.has(source):
		_headless_body_meshes[source] = _make_headless_body_mesh(body.skin, source, head_bone)
	body.mesh = _headless_body_meshes[source] if enabled else source


static func _make_headless_body_mesh(skin: Skin, source: ArrayMesh, head_bone: StringName) -> ArrayMesh:
	var head_bind := -1
	for bind in skin.get_bind_count():
		if skin.get_bind_name(bind) == head_bone:
			head_bind = bind
			break
	assert(head_bind >= 0)
	var result := ArrayMesh.new()
	result.blend_shape_mode = source.blend_shape_mode
	for shape in source.get_blend_shape_count():
		result.add_blend_shape(source.get_blend_shape_name(shape))
	for surface in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var binds: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var influences := binds.size() / vertices.size()
		var is_head := PackedByteArray()
		is_head.resize(vertices.size())
		for vertex in vertices.size():
			var head_weight := 0.0
			for slot in influences:
				var index := vertex * influences + slot
				if binds[index] == head_bind:
					head_weight += weights[index]
			is_head[vertex] = int(head_weight >= 0.5)
		var body_triangles := PackedInt32Array()
		for i in range(0, indices.size(), 3):
			var a := indices[i]
			var b := indices[i + 1]
			var c := indices[i + 2]
			if not (is_head[a] or is_head[b] or is_head[c]):
				body_triangles.append(a)
				body_triangles.append(b)
				body_triangles.append(c)
		if body_triangles.is_empty():
			continue
		arrays[Mesh.ARRAY_INDEX] = body_triangles
		# Keep skinning and the imported morph layout so the rig can keep using the same indices.
		var bone_flags := source.surface_get_format(surface) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		result.add_surface_from_arrays(source.surface_get_primitive_type(surface), arrays, source.surface_get_blend_shape_arrays(surface), {}, bone_flags)
		result.surface_set_material(surface, source.surface_get_material(surface))
	return result if result.get_surface_count() > 0 else null


var _defeat_tween: Tween
var _hit_tween: Tween
var _hit_overlay: StandardMaterial3D


func show_health(height: float, health: float, nearby: bool) -> void:
	if _health_bar.visible != nearby:
		_health_bar.visible = nearby
		set_process(nearby)
	if nearby:
		_health_bar_height = height
		if _shown_health != health:
			_shown_health = health
			(_health_bar.material_override as ShaderMaterial).set_shader_parameter("health", health)


func set_growth_name(giant_name: String) -> void:
	var nameplate: Label3D = $HealthBar/GiantName
	nameplate.text = giant_name
	nameplate.show()


func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var anchor := global_position + Vector3.UP * (_health_bar_height * 1.04 + 0.001)
	var width := maxf(0.0006, camera.global_position.distance_to(anchor) * 0.10)
	_health_bar.global_transform = Transform3D(camera.global_basis.scaled(Vector3.ONE * width), anchor)


func show_hit() -> void:
	if _human_stage:
		if _hit_tween and _hit_tween.is_valid():
			_hit_tween.kill()
		if _hit_overlay == null:
			_hit_overlay = StandardMaterial3D.new()
			_hit_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			_hit_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_hit_overlay.albedo_color = Color(1.0, 0.22, 0.095, 0.46)
		for mesh in _current_meshes():
			mesh.material_overlay = _hit_overlay
		_hit_tween = create_tween()
		_hit_tween.tween_property(_hit_overlay, "albedo_color:a", 0.0, 0.24)
		_hit_tween.tween_callback(_clear_hit_overlay)
		return
	_trigger_impact_impulse(0.58)
	_impact_flinch = 1.0
	if _hit_tween and _hit_tween.is_valid():
		_hit_tween.kill()
	if _hit_overlay == null:
		_hit_overlay = StandardMaterial3D.new()
		_hit_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_hit_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hit_overlay.albedo_color = Color(1.0, 0.22, 0.095, 0.46)
	if not _silhouette_visible():
		for mesh in _current_meshes():
			mesh.material_overlay = _hit_overlay
	_hit_tween = create_tween()
	_hit_tween.tween_property(_hit_overlay, "albedo_color:a", 0.0, 0.24)
	_hit_tween.tween_callback(_clear_hit_overlay)


func _clear_hit_overlay() -> void:
	for mesh in _current_meshes():
		if mesh.material_overlay == _hit_overlay:
			mesh.material_overlay = null


func show_defeat() -> void:
	if _human_stage:
		_human_dying = true
		_human_anim.play(&"die", 0.08)
		return
	_defeat_tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_defeat_tween.tween_property(self, "rotation:x", -PI * 0.5, 0.42)
	_defeat_tween.tween_interval(0.55)
	_defeat_tween.tween_callback(hide)


func show_respawn() -> void:
	if _defeat_tween and _defeat_tween.is_valid():
		_defeat_tween.kill()
	set_silhouette_opacity(0.0)
	set_distant_clip(false)
	_human_dying = false
	if _human_stage:
		_human_model.visible = true
		_human_anim.play(&"idle", 0.1)
		_human_anim.speed_scale = 1.0
		_set_head_part_hidden(_human_head, _first_person_enabled)
	else:
		_reset_turn_tracks()
	show()


func stop_carry_velocity(delta: float) -> Vector3:
	_check_teleport()
	var dt := clampf(delta, 0.0, 0.05)
	_stop_carry_enabled = true
	if dt <= 0.0 or not is_on_floor():
		return Vector3.ZERO
	if _stop_phase == STOP_NONE:
		if _foot_stride <= 0.15:
			return Vector3.ZERO
		if has_step_in_flight():
			_begin_stop_swing(true)
		else:
			_begin_stop_settle(true)
	if _stop_phase == STOP_SWING:
		var u := clampf(_stop_swing_elapsed / maxf(_stop_swing_dur, 0.01), 0.0, 1.0)
		var v := lerpf(_stop_swing_v0, _stop_swing_v1, smoothstep(0.0, 1.0, u))
		return _stop_heading * v
	if _stop_phase == STOP_SETTLE:
		if _stop_carry_dist <= 0.005 or _stop_settle_dur <= 0.01:
			return Vector3.ZERO
		var u0 := clampf(_stop_settle_elapsed / _stop_settle_dur, 0.0, 1.0)
		var u1 := clampf((_stop_settle_elapsed + dt) / _stop_settle_dur, 0.0, 1.0)
		var step_dist := _stop_carry_dist * (sin(u1 * PI * 0.5) - sin(u0 * PI * 0.5))
		return _stop_heading * (step_dist / dt)
	return Vector3.ZERO


func show_hand_action(kind: int, progress: float, delta: float, target: Vector3) -> Vector3:
	var dt := clampf(delta, 0.0, 0.05)
	_check_teleport()
	if not _pickup_crush_active and not _punch_active:
		_capture_snapshot()
		_left_at_pickup = _left_ankle
		_right_at_pickup = _right_ankle
		_left_at_punch = _left_ankle
		_right_at_punch = _right_ankle
		_pickup_crush_active = kind == 0
		_punch_active = kind == 1
		_pickup_crushed_emitted = false
		_punch_impact_emitted = false
		_pickup_exit_blend = 0.0
		_punch_exit_blend = 0.0
		_hand_start_yaw = angle_difference(global_rotation.y, _prev_body_yaw + _visual_yaw_offset)
		_prev_body_yaw = global_rotation.y
		_stride = 0.0
		_foot_stride = 0.0
		_move_drive = 0.0
		_prev_speed = 0.0
		_cycle = 0.0
		_clear_stop_state()
		_cancel_standing_turn()
		_walk_was_moving = false
	_visual_yaw_offset = lerpf(_hand_start_yaw, 0.0, smoothstep(0.0, 0.2, progress))
	_model.rotation.y = _model_base_yaw + _visual_yaw_offset
	_hand_aim = _skeleton.to_local(target)
	_breath = fmod(_breath + dt * 1.55, TAU)
	_idle_look_time = fmod(_idle_look_time + dt, 1000.0)
	if _pickup_crush_active:
		_pickup_crush_pose(progress, dt)
	else:
		_punch_pose(progress, dt)
	_prev_giant_pos = global_position
	_update_impact_jolt(dt)
	_update_hair(dt, true)
	_update_face(dt)
	if _active_skin != null:
		_active_skin.follow_pose()
	return _skeleton.to_global(_skeleton.get_bone_global_pose(_arm_r.hand) * _arm_r.palm_offset)


func finish_hand_action() -> void:
	if _pickup_crush_active or _punch_active:
		_capture_snapshot()
		_pickup_exit_blend = 1.0 if _pickup_crush_active else 0.0
		_punch_exit_blend = 1.0 if _punch_active else 0.0
		_pickup_crush_active = false
		_punch_active = false
		_reset_turn_tracks()


func show_sit_crush(progress: float, delta: float) -> Dictionary:
	var t := clampf(progress, 0.0, 1.0)
	var dt := clampf(delta, 0.0, 0.05)
	_check_teleport()
	if not _sit_crush_active:
		var from_sit_idle := _sit_idle_active
		_capture_snapshot()
		_left_at_sit = _left_ankle
		_right_at_sit = _right_ankle
		_sit_crush_active = true
		_sit_idle_active = false
		_sit_idle_enter_blend = 0.0
		_sit_idle_exit_blend = 0.0
		_sit_crush_from_idle_blend = 1.0 if from_sit_idle else 0.0
		_sit_crush_impact_emitted = t >= SIT_CRUSH_IMPACT_TIME and from_sit_idle
		_sit_crush_exit_blend = 0.0
		_pickup_exit_blend = 0.0
		_punch_exit_blend = 0.0
		_sit_crush_start_yaw = angle_difference(global_rotation.y, _prev_body_yaw + _visual_yaw_offset)
		_prev_body_yaw = global_rotation.y
		_stride = 0.0
		_foot_stride = 0.0
		_move_drive = 0.0
		_prev_speed = 0.0
		_cycle = 0.0
		_clear_stop_state()
		_cancel_standing_turn()
		_walk_was_moving = false
	if t < SIT_CRUSH_IMPACT_TIME - 0.02:
		_sit_crush_impact_emitted = false
	if dt > 0.0 and _sit_crush_from_idle_blend > 0.0:
		_sit_crush_from_idle_blend = move_toward(_sit_crush_from_idle_blend, 0.0, dt * 3.0)
	_visual_yaw_offset = lerpf(_sit_crush_start_yaw, 0.0, smoothstep(0.0, 0.16, t))
	_model.rotation.y = _model_base_yaw + _visual_yaw_offset
	_breath = fmod(_breath + dt * 1.55, TAU)
	_idle_look_time = fmod(_idle_look_time + dt, 1000.0)
	var impact_just_hit := _sit_crush_pose(t, dt)
	_prev_giant_pos = global_position
	_update_impact_jolt(dt)
	_update_hair(dt, true)
	_update_face(dt)
	if _active_skin != null:
		_active_skin.follow_pose(_active_skin.pelvis_height_ratio())
	var phase := "prepare"
	if t >= SIT_CRUSH_RISE_START:
		phase = "rise"
	elif t >= SIT_CRUSH_IMPACT_TIME:
		phase = "hold"
	elif t >= SIT_CRUSH_DROP_START:
		phase = "drop"
	var hip_pose := _skeleton.get_bone_global_pose(_bone["spine"])
	var pelvis_world := _skeleton.to_global(Vector3(hip_pose.origin.x, 0.0, hip_pose.origin.z))
	var dust_alpha := 0.0
	if t >= SIT_CRUSH_IMPACT_TIME:
		var burst := smoothstep(SIT_CRUSH_IMPACT_TIME, SIT_CRUSH_IMPACT_TIME + 0.03, t)
		var fade := 1.0 - smoothstep(SIT_CRUSH_RISE_START + 0.05, 0.99, t)
		dust_alpha = burst * fade
	return {
		"impact_just_hit": impact_just_hit,
		"phase": phase,
		"progress": t,
		"pelvis_world": pelvis_world,
		"dust_alpha": dust_alpha,
	}


func finish_sit_crush(immediate := false) -> void:
	if _sit_crush_active:
		if not immediate:
			_capture_snapshot()
		_sit_crush_exit_blend = 0.0 if immediate else 1.0
		_sit_crush_active = false
		_sit_crush_from_idle_blend = 0.0
		_sit_crush_hair_float = 0.0
		_sit_crush_impact_emitted = false
		_reset_turn_tracks()
	elif immediate:
		_sit_crush_exit_blend = 0.0


func step_turn_in_place(target_yaw: float, delta: float) -> Dictionary:
	# Reuses the live standing ship-like pivot animation verbatim via show_motion().
	show_motion(0.0, -1.0, delta, target_yaw, true)
	var yaw_err := absf(angle_difference(global_rotation.y, target_yaw))
	var feet_mean := _mean_angle(_foot_l.world_yaw, _foot_r.world_yaw)
	var feet_err := absf(angle_difference(feet_mean, target_yaw))
	var settled := (
		not _stand_turning
		and not _stand_step_active
		and _foot_l.heel_settle_t >= 0.99
		and _foot_r.heel_settle_t >= 0.99
		and yaw_err <= STAND_DONE_DEADZONE + 0.02
		and feet_err <= STAND_DONE_DEADZONE + 0.04
	)
	return {
		"done": settled,
		"yaw_error": yaw_err,
		"standing_turning": _stand_turning,
		"step_count": _stand_step_count,
		"mode": _turn_mode,
	}


func show_sit_idle(delta: float, blend_in := true) -> Dictionary:
	var dt := clampf(delta, 0.0, 0.05)
	_check_teleport()
	if not _sit_idle_active:
		_capture_snapshot()
		_left_at_sit_idle = _left_ankle
		_right_at_sit_idle = _right_ankle
		_sit_idle_active = true
		_sit_crush_active = false
		_sit_crush_from_idle_blend = 0.0
		_sit_crush_hair_float = 0.0
		_sit_crush_exit_blend = 0.0
		_sit_idle_exit_blend = 0.0
		_pickup_exit_blend = 0.0
		_punch_exit_blend = 0.0
		_sit_idle_enter_blend = 1.0 if (blend_in and dt > 0.0) else 0.0
		_sit_idle_time = 0.0
		_prev_body_yaw = global_rotation.y
		_stride = 0.0
		_foot_stride = 0.0
		_move_drive = 0.0
		_prev_speed = 0.0
		_cycle = 0.0
		_clear_stop_state()
		_cancel_standing_turn()
		_walk_was_moving = false
	if dt > 0.0:
		_sit_idle_time = fmod(_sit_idle_time + dt, 1000.0)
		_breath = fmod(_breath + dt * 1.32, TAU)
		_idle_look_time = fmod(_idle_look_time + dt, 1000.0)
		_sit_idle_enter_blend = move_toward(_sit_idle_enter_blend, 0.0, dt * 2.2)
		if absf(_visual_yaw_offset) > 0.0005:
			_visual_yaw_offset = lerpf(_visual_yaw_offset, 0.0, minf(dt * 8.0, 1.0))
		else:
			_visual_yaw_offset = 0.0
	_model.rotation.y = _model_base_yaw + _visual_yaw_offset
	_sit_idle_pose(dt)
	_prev_giant_pos = global_position
	_update_impact_jolt(dt)
	_update_hair(dt, false)
	_update_face(dt)
	if _active_skin != null:
		_active_skin.follow_pose(_active_skin.pelvis_height_ratio())
	var hip_pose := _skeleton.get_bone_global_pose(_bone["spine"])
	var pelvis_world := _skeleton.to_global(Vector3(hip_pose.origin.x, 0.0, hip_pose.origin.z))
	return {
		"phase": "sit_idle",
		"time": _sit_idle_time,
		"enter_blend": _sit_idle_enter_blend,
		"pelvis_world": pelvis_world,
	}


func finish_sit_idle(immediate := false) -> void:
	if _sit_idle_active:
		if not immediate:
			_capture_snapshot()
		_sit_idle_exit_blend = 0.0 if immediate else 1.0
		_sit_idle_active = false
		_sit_idle_enter_blend = 0.0
		_reset_turn_tracks()
	elif immediate:
		_sit_idle_exit_blend = 0.0


func show_motion(speed: float, _legacy_pose: float, delta: float,
		turn_target: float = NAN, allow_standing_turn: bool = false) -> Variant:
	if _human_stage:
		return _human_motion(speed, delta)
	_init_foot_tracks()
	_check_teleport()
	var dt := clampf(delta, 0.0, 0.05)
	_breath = fmod(_breath + dt * 1.55, TAU)
	_idle_look_time = fmod(_idle_look_time + dt, 1000.0)

	# Detect active scale growth for subtle empowering breath & hair shimmer.
	if dt > 0.0:
		var scale_rate := (_model.scale.y - _prev_model_scale) / maxf(_prev_model_scale * dt, 0.001)
		if scale_rate > 0.015:
			_growth_surge = move_toward(_growth_surge, clampf(scale_rate * 4.5, 0.0, 1.0), dt * 6.0)
		else:
			_growth_surge = move_toward(_growth_surge, 0.0, dt * 3.2)
		_prev_model_scale = _model.scale.y

	# Keep world-locked foot trackers synced across smooth growth or sudden resize.
	if absf(_model.scale.z - _prev_foot_scale) > 0.0001:
		var ratio := _model.scale.z / maxf(_prev_foot_scale, 0.0001)
		_prev_foot_scale = _model.scale.z
		if ratio > 1.25 or ratio < 0.80:
			_reset_turn_tracks()
		else:
			_foot_l.pivot_world.y = global_position.y
			_foot_r.pivot_world.y = global_position.y

	# Detect landing after briefly leaving ground (e.g., stepping off tall rubble mounds).
	var on_floor := is_on_floor()
	if dt > 0.0:
		if not _was_on_floor and on_floor:
			_trigger_impact_impulse(0.32)
		_air_weight = move_toward(_air_weight, 0.0 if on_floor else 1.0, dt * 8.0)
		_was_on_floor = on_floor

	# Track body yaw velocity and decay any remaining action turn offset.
	var body_yaw := global_rotation.y
	if not _yaw_initialized:
		_prev_body_yaw = body_yaw
		_pelvis_world_yaw = body_yaw
		_chest_world_yaw = body_yaw
		_head_world_yaw = body_yaw
		_eye_world_yaw = body_yaw
		_yaw_initialized = true
	var yaw_step := angle_difference(_prev_body_yaw, body_yaw)
	_prev_body_yaw = body_yaw
	var prev_visual_offset := _visual_yaw_offset
	if dt > 0.0:
		if absf(_visual_yaw_offset) > 0.0005:
			_visual_yaw_offset = lerpf(_visual_yaw_offset, 0.0, minf(dt * 8.0, 1.0))
		else:
			_visual_yaw_offset = 0.0
	var raw_body_yaw_vel := 0.0
	if dt > 0.0:
		var visual_yaw_step := angle_difference(0.0, yaw_step + (_visual_yaw_offset - prev_visual_offset))
		var raw_turn := clampf(visual_yaw_step / dt, -4.5, 4.5)
		if absf(visual_yaw_step) > 0.55:
			raw_turn = 0.0
		raw_body_yaw_vel = raw_turn
		_turn_rate = lerpf(_turn_rate, raw_turn, minf(dt * 7.5, 1.0))
	_model.rotation.y = _model_base_yaw + _visual_yaw_offset

	# Stop / acceleration momentum for weighty settling.
	if dt > 0.0:
		var accel := (speed - _prev_speed) / dt
		if accel < -12.0 and _prev_speed > 2.5:
			_stop_momentum = clampf(_stop_momentum + 0.60, 0.0, 1.0)
		_stop_momentum = move_toward(_stop_momentum, 0.0, dt * 2.6)
	_prev_speed = speed

	_pickup_exit_blend = move_toward(_pickup_exit_blend, 0.0, dt * 6.5)
	_punch_exit_blend = move_toward(_punch_exit_blend, 0.0, dt * 6.5)
	_sit_crush_exit_blend = move_toward(_sit_crush_exit_blend, 0.0, dt * 6.5)
	_sit_idle_exit_blend = move_toward(_sit_idle_exit_blend, 0.0, dt * 6.5)
	_stop_just_landed = ""
	_walk_just_landed = ""
	_advance_walk(speed, dt, turn_target, allow_standing_turn, raw_body_yaw_vel, on_floor)
	var landed_side := _stop_just_landed if not _stop_just_landed.is_empty() else _walk_just_landed
	var landed := on_floor and not landed_side.is_empty()
	if landed:
		_trigger_impact_impulse(1.0)
		_impact_flinch = 0.65
	_update_impact_jolt(dt)
	_walk_pose(dt)
	_stop_carry_enabled = false
	_prev_giant_pos = global_position
	_update_hair(dt, false)
	_update_face(dt)
	if _active_skin != null:
		_active_skin.follow_pose()
		if maxf(maxf(_pickup_exit_blend, _punch_exit_blend), maxf(_sit_crush_exit_blend, _sit_idle_exit_blend)) <= 0.001:
			_pin_skin_feet()
	if landed:
		return _foot_contact(_left if landed_side == "L" else _right)
	return null


func has_step_in_flight() -> bool:
	if _stop_phase == STOP_SWING:
		return is_on_floor()
	if _stop_phase == STOP_SETTLE:
		return false
	return is_on_floor() and _walk_was_moving and (not _foot_l.planted or not _foot_r.planted)


func has_standing_step_in_flight() -> bool:
	return _stand_step_active


func heavy_step_preview() -> Dictionary:
	if _human_stage or not is_on_floor() or _stand_step_active:
		return {}
	var leg: Leg
	var ankle: Vector3
	var yaw: float
	var progress: float
	var eta: float
	var locked: bool
	match _stop_phase:
		STOP_SWING:
			leg = _right if _stop_support_is_left else _left
			ankle = _stop_swing_target_world
			yaw = _stop_swing_target_yaw
			progress = clampf(_stop_swing_elapsed / _stop_swing_dur, 0.0, 1.0)
			eta = _stop_swing_dur - _stop_swing_elapsed
			locked = true
		STOP_SETTLE:
			progress = clampf(inverse_lerp(0.08, 0.92, _stop_settle_elapsed / _stop_settle_dur), 0.0, 1.0)
			if progress <= 0.0 or progress >= 1.0 or not _stop_trail_is_stepping():
				return {}
			leg = _right if _stop_lead_is_left else _left
			ankle = _stop_trail_target_world
			yaw = _stop_trail_target_yaw
			eta = _stop_settle_dur * 0.92 - _stop_settle_elapsed
			locked = true
		_:
			if not _walk_was_moving or (_foot_l.planted and _foot_r.planted):
				return {}
			var track := _foot_r if _foot_l.planted else _foot_l
			leg = _right if _foot_l.planted else _left
			ankle = track.swing_target_world
			yaw = track.swing_target_yaw
			progress = track.swing_t
			eta = track.swing_remaining
			locked = progress >= SWING_TARGET_LOCK
	var center := ankle + (leg.sole_offset * _model.scale.z).rotated(Vector3.UP, yaw)
	center.y = _foot_ground_height(center)
	var area := _sole_payload(leg, center, yaw)
	var pose := _skeleton.get_bone_global_pose(leg.foot)
	area["eta"] = maxf(eta, 0.0)
	area["progress"] = progress
	area["locked"] = locked
	area["lift"] = maxf(_source_sole_world(leg, pose).y - center.y, 0.0)
	return area


func _check_teleport() -> void:
	if not _giant_pos_tracked:
		_prev_giant_pos = global_position
		_giant_pos_tracked = true
		return
	var scale_ratio := maxf(_model.scale.z / _model_base_scale, 0.25)
	var jump := Vector2(global_position.x - _prev_giant_pos.x, global_position.z - _prev_giant_pos.z).length()
	var yaw_jump := absf(angle_difference(_prev_body_yaw, global_rotation.y)) if _yaw_initialized else 0.0
	var external_yaw_snap := (not _pickup_crush_active and not _punch_active and not _sit_crush_active and not _sit_idle_active and yaw_jump > 0.65)
	if jump > maxf(2.5 * scale_ratio, 2.5) or external_yaw_snap:
		_clear_stop_state()
		_foot_stride = 0.0
		_stride = 0.0
		_move_drive = 0.0
		_cycle = 0.0
		_prev_giant_pos = global_position
		_prev_body_yaw = global_rotation.y
		_reset_turn_tracks()


func _clear_stop_state() -> void:
	_stop_phase = STOP_NONE
	_stop_swing_elapsed = 0.0
	_stop_settle_elapsed = 0.0
	_stop_carry_dist = 0.0
	_stop_just_landed = ""


func _world_heading() -> Vector3:
	var h := (-global_basis.z).slide(Vector3.UP)
	if h.length_squared() < 0.0001:
		return Vector3.FORWARD
	return h.normalized()


func _stop_time_scale() -> float:
	if fixed_walk_tempo:
		return 1.0 / pace
	return sqrt(maxf(_model.scale.z / _model_base_scale, 0.15)) / maxf(pace, 0.25)


func _begin_stop_swing(with_carry: bool) -> void:
	var right_swing := not _foot_r.planted
	_stop_phase = STOP_SWING
	_stop_support_is_left = right_swing
	_stop_heading = _world_heading()
	_stop_swing_elapsed = 0.0
	_stop_swing_landing = 0.5 if right_swing else 1.0

	var sup_leg := _left if _stop_support_is_left else _right
	var swg_leg := _right if _stop_support_is_left else _left
	var sup_ankle := _left_ankle if _stop_support_is_left else _right_ankle
	var swg_ankle := _right_ankle if _stop_support_is_left else _left_ankle
	var sup_track := _foot_l if _stop_support_is_left else _foot_r
	var swg_track := _foot_r if _stop_support_is_left else _foot_l
	_stop_support_world = _skeleton.to_global(sup_ankle)
	_stop_support_yaw = sup_track.world_yaw
	_stop_swing_start_world = _skeleton.to_global(swg_ankle)
	_stop_swing_start_yaw = swg_track.world_yaw
	_stop_swing_target_yaw = swg_track.swing_target_yaw
	_stop_swing_start_y = maxf(swg_ankle.y - swg_leg.ankle_rest.y - swg_leg.ground_y, 0.0)
	_stop_swing_start_pitch = swg_leg.last_pitch - swg_leg.ground_pitch
	_stop_swing_start_toe = swg_leg.last_toe

	var rem := clampf((_stop_swing_landing - _cycle) / (1.0 - CONTACT_FRACTION), 0.12, 1.0)
	_stop_swing_rem = rem
	_stop_swing_dur = clampf(STOP_SWING_SECONDS * _stop_time_scale() * rem, 0.08, 1.4)

	var eff_half_world := HALF_STEP * _step_scale * _model.scale.z
	var swing_travel := 0.0
	if with_carry:
		_stop_swing_v0 = clampf(_last_walk_speed, 0.0, WALK_REF_SPEED * pace * 1.15)
		_stop_swing_v1 = _stop_swing_v0 * 0.72
		swing_travel = 0.5 * (_stop_swing_v0 + _stop_swing_v1) * _stop_swing_dur
		# Ensure carrying forward during the swing never over-stretches the world-locked support leg.
		var sup_ahead := (_stop_support_world - global_position).dot(_stop_heading)
		var max_swing_travel := maxf(sup_ahead + eff_half_world * 0.90, 0.0)
		if swing_travel > max_swing_travel and swing_travel > 0.001:
			var k := max_swing_travel / swing_travel
			_stop_swing_v0 *= k
			_stop_swing_v1 *= k
			swing_travel = max_swing_travel
	else:
		_stop_swing_v0 = 0.0
		_stop_swing_v1 = 0.0

	var brake_ahead := eff_half_world * (0.40 if with_carry else 0.70)
	var swg_rest_world := _skeleton.to_global(swg_leg.ankle_rest)
	var rest_fwd := (swg_rest_world - global_position).dot(_stop_heading)
	var cur_swg_fwd := (_stop_swing_start_world - global_position).dot(_stop_heading)
	var sup_fwd := (_stop_support_world - global_position).dot(_stop_heading)
	var min_fwd := maxf(cur_swg_fwd + eff_half_world * 0.30, sup_fwd + eff_half_world * 0.28)
	var target_fwd := clampf(maxf(swing_travel + brake_ahead, min_fwd), min_fwd, swing_travel + eff_half_world * 0.94)
	_stop_swing_target_world = swg_track.swing_target_world if swg_track.swing_t >= SWING_TARGET_LOCK \
			else swg_rest_world + _stop_heading * (target_fwd - rest_fwd)


func _begin_stop_settle(with_carry: bool) -> void:
	_stop_phase = STOP_SETTLE
	_stop_settle_elapsed = 0.0
	_stop_heading = _world_heading()
	_stop_lead_is_left = _left_ankle.z >= _right_ankle.z

	var lead_leg := _left if _stop_lead_is_left else _right
	var trail_leg := _right if _stop_lead_is_left else _left
	var lead_ankle := _left_ankle if _stop_lead_is_left else _right_ankle
	var trail_ankle := _right_ankle if _stop_lead_is_left else _left_ankle
	_stop_lead_world = _skeleton.to_global(lead_ankle)
	_stop_trail_start_world = _skeleton.to_global(trail_ankle)
	_stop_lead_yaw = global_rotation.y + lead_leg.last_yaw
	_stop_trail_start_yaw = global_rotation.y + trail_leg.last_yaw
	_stop_trail_target_yaw = global_rotation.y + trail_leg.sign_x * IDLE_FOOT_YAW

	var lead_ahead := maxf(lead_ankle.z - lead_leg.ankle_rest.z, 0.0) * _model.scale.z
	_stop_carry_dist = lead_ahead if with_carry else 0.0
	var end_position := global_position + _stop_heading * _stop_carry_dist
	_stop_trail_target_world = _rest_ankle_world(trail_leg, end_position, global_rotation.y, 0.0, 0.0)
	if not _stop_trail_is_stepping():
		_stop_trail_target_world = _stop_trail_start_world
		_stop_trail_target_yaw = _stop_trail_start_yaw

	var time_scale := _stop_time_scale()
	var base_dur := STANCE_SETTLE_SECONDS * time_scale
	var eff_half_world := HALF_STEP * _step_scale * _model.scale.z
	var ref_v := maxf(_stop_swing_v1 if _stop_swing_v1 > 1.0 else _last_walk_speed, WALK_REF_SPEED * pace * 0.65)
	var speed_dur := (PI * 0.5) * _stop_carry_dist / maxf(ref_v, 1.0)
	var scaled_base := base_dur * clampf(lead_ahead / maxf(eff_half_world * 0.45, 0.1), 0.62, 1.0)
	var max_duration := maxf(0.26, 0.95 * time_scale)
	_stop_settle_dur = clampf(maxf(scaled_base, speed_dur), 0.26, max_duration)
	_stop_swing_v0 = 0.0
	_stop_swing_v1 = 0.0


func _stop_trail_is_stepping() -> bool:
	var offset := _stop_trail_target_world - _stop_trail_start_world
	return Vector2(offset.x, offset.z).length() > 0.022 * _model.scale.z


func _advance_walk(speed: float, dt: float, turn_target := NAN,
		allow_standing_turn := false, raw_body_yaw_vel := 0.0, on_floor := true) -> void:
	var body_ratio := _model.scale.z / _model_base_scale
	var scale_ratio := maxf(body_ratio, 0.15)
	var tempo_scale := clampf(pace / sqrt(scale_ratio), 0.35, 2.5)
	var model_world_yaw := global_rotation.y + _visual_yaw_offset

	if speed > 0.12 * minf(body_ratio, 1.0):
		var was_standing_turn := _stand_turning or _stand_step_active
		if _stop_phase != STOP_NONE:
			_clear_stop_state()
			_sync_feet_to_current_ankles()
		_stand_turning = false
		_stand_step_active = false
		_stand_anticipation = 0.0
		_last_walk_speed = speed

		_pelvis_world_yaw = model_world_yaw
		_pelvis_yaw_vel = lerpf(_pelvis_yaw_vel, raw_body_yaw_vel, minf(dt * 12.0, 1.0)) if dt > 0.0 else raw_body_yaw_vel
		_turn_target_yaw = turn_target if not is_nan(turn_target) else (_pelvis_world_yaw + clampf(_pelvis_yaw_vel * 0.48, -1.1, 1.1))

		# Evaluate gentle curve vs sharp turn sharpness.
		var diff := angle_difference(_pelvis_world_yaw, _turn_target_yaw)
		var turn_metric := maxf(absf(_pelvis_yaw_vel), absf(diff) * 0.90)
		var target_sharp := smoothstep(WALK_SHARP_ENTER, WALK_SHARP_FULL, turn_metric)
		_turn_sharpness = lerpf(_turn_sharpness, target_sharp, minf(dt * 7.5, 1.0)) if dt > 0.0 else target_sharp
		if absf(diff) > 0.03 or absf(_pelvis_yaw_vel) > 0.05:
			var raw_sign := 1.0 if (_pelvis_yaw_vel + diff * 1.4) >= 0.0 else -1.0
			_turn_sign = lerpf(_turn_sign, raw_sign, minf(dt * 10.0, 1.0)) if dt > 0.0 else raw_sign
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

		# Adapt stride amplitude smoothly once the giant reaches super-colossal height (>88m),
		# while locking stride_length identically so flat-ground foot slip stays zero.
		var target_step_scale := clampf(pow(minf(3.5 / scale_ratio, 1.0), 0.62), 0.30, 1.0)
		if dt > 0.0:
			_step_scale = lerpf(_step_scale, target_step_scale, minf(dt * 4.5, 1.0))
		else:
			_step_scale = target_step_scale

		var cycle_speed := WALK_REF_SPEED * pace if fixed_walk_tempo else speed
		var reference_speed := cycle_speed if fixed_walk_tempo else WALK_REF_SPEED * 0.80 * clampf(pace, 0.1, 1.0)
		if size_scaled_walk or fixed_walk_tempo:
			reference_speed *= minf(body_ratio, 1.0)
		var target := clampf(speed / maxf(reference_speed, 0.0001), 0.0, 1.0)
		_stride = move_toward(_stride, target, dt * (5.2 if target > _stride else 4.2))
		_foot_stride = move_toward(_foot_stride, target, dt * 5.2)
		_move_drive = move_toward(_move_drive, target, dt * 5.5)

		var stride_scale := _model_base_scale if fixed_walk_tempo else _step_scale * _model.scale.z
		var base_stride_length := maxf(2.0 * HALF_STEP * stride_scale / CONTACT_FRACTION, 0.0001)
		var eff_stride_length := base_stride_length * _turn_stride_mult
		var ref_walk_speed := WALK_REF_SPEED * pace * (1.0 if fixed_walk_tempo else minf(body_ratio, 1.0))
		var base_walk_rate := ref_walk_speed / base_stride_length
		var straight_rate := cycle_speed / base_stride_length
		var cycle_rate := cycle_speed / maxf(eff_stride_length, 0.0001)
		# Keep sharp-turn cadence smoothly bounded around ~1.25-1.32x normal walking pace (never
		# frantic rapid steps when suddenly pressing Left/Right while walking).
		var turn_floor_rate := base_walk_rate * lerpf(0.0, 1.24, _turn_sharpness)
		var turn_ceil_rate := maxf(base_walk_rate, straight_rate) * 1.32
		cycle_rate = clampf(maxf(cycle_rate, turn_floor_rate), 0.0, turn_ceil_rate)

		# Extrapolate actual translation. A blocked body can still reach a target with its swing leg.
		var world_disp := Vector3(global_position.x - _prev_giant_pos.x, 0.0, global_position.z - _prev_giant_pos.z)
		var expected_disp := speed * dt
		if dt > 0.0 and world_disp.length() > expected_disp * 0.25:
			_actual_world_vel = world_disp / dt
		else:
			_actual_world_vel = Vector3.ZERO

		if not _walk_was_moving:
			_walk_was_moving = true
			_walk_init_step = false
			if was_standing_turn and not _foot_l.planted:
				_cycle = clampf(CONTACT_FRACTION + _foot_l.swing_t * (1.0 - CONTACT_FRACTION), CONTACT_FRACTION, 0.96)
				_foot_l.swing_start_phase = CONTACT_FRACTION
				_foot_r.planted = true
			elif was_standing_turn and not _foot_r.planted:
				var r_p := clampf(CONTACT_FRACTION + _foot_r.swing_t * (1.0 - CONTACT_FRACTION), CONTACT_FRACTION, 0.96)
				_cycle = fposmod(r_p - 0.5, 1.0)
				_foot_r.swing_start_phase = CONTACT_FRACTION
				_foot_l.planted = true
			else:
				# Both feet start under the pelvis, so lift earlier than in a full stride.
				_cycle = 0.17 if _turn_sign >= -0.25 else 0.67
				_walk_init_step = _cycle < 0.5
				_foot_l.planted = true
				_foot_r.planted = true
			_walk_cycle_prev = _cycle

		if _walk_init_step and _cycle >= 0.5:
			# Gait initiation from standstill starts with both feet under the hips (half a stance),
			# so once the first right step lands at 0.5 the trailing left leg catches up briskly into steady stride.
			cycle_rate *= 1.80

		_walk_cycle_prev = _cycle
		_cycle = fposmod(_cycle + minf(cycle_rate * dt, 0.49), 1.0)
		if _walk_init_step and _cycle < _walk_cycle_prev:
			_walk_init_step = false

		var swing_dur := (1.0 - CONTACT_FRACTION) / maxf(cycle_rate, 0.15)
		if _update_walk_foot(_foot_l, _left, _foot_r, _right, _cycle, _walk_cycle_prev, swing_dur, dt):
			_walk_just_landed = "L"
		var r_phase := fposmod(_cycle + 0.5, 1.0)
		var r_prev := fposmod(_walk_cycle_prev + 0.5, 1.0)
		if _update_walk_foot(_foot_r, _right, _foot_l, _left, r_phase, r_prev, swing_dur, dt):
			_walk_just_landed = "R"

		_update_yaw_cascade(dt, tempo_scale)
		_update_body_dynamics(dt, tempo_scale, true, speed)
		return

	_walk_init_step = false
	_actual_world_vel = Vector3.ZERO
	if _stop_phase == STOP_NONE and _foot_stride > 0.15 and on_floor:
		if has_step_in_flight():
			_begin_stop_swing(_stop_carry_enabled)
		else:
			_begin_stop_settle(_stop_carry_enabled)
	_walk_was_moving = false

	if _stop_phase == STOP_SWING:
		_cancel_standing_turn()
		_pelvis_world_yaw = model_world_yaw
		_pelvis_yaw_vel = raw_body_yaw_vel
		_turn_target_yaw = _pelvis_world_yaw
		_turn_sharpness = move_toward(_turn_sharpness, 0.0, dt * 5.0)
		_turn_stride_mult = lerpf(_turn_stride_mult, 1.0, minf(dt * 5.0, 1.0))
		_turn_cadence_mult = lerpf(_turn_cadence_mult, 1.0, minf(dt * 5.0, 1.0))
		_stop_swing_elapsed += dt
		_move_drive = move_toward(_move_drive, _stride * 0.42, dt * 3.5)
		var u := clampf(_stop_swing_elapsed / maxf(_stop_swing_dur, 0.01), 0.0, 1.0)
		_cycle = fposmod(lerpf(_stop_swing_landing - (1.0 - CONTACT_FRACTION) * _stop_swing_rem, _stop_swing_landing, u), 1.0)
		_update_yaw_cascade(dt, tempo_scale)
		_update_body_dynamics(dt, tempo_scale, false, 0.0)
		if u >= 1.0:
			# Snap landed ankle cleanly to its world landing spot and hand off to forward-carry settle.
			var sup_leg := _left if _stop_support_is_left else _right
			var swg_leg := _right if _stop_support_is_left else _left
			var sup_local := _skeleton.to_local(_stop_support_world)
			sup_local.y = sup_leg.ankle_rest.y
			var swg_local := _skeleton.to_local(_stop_swing_target_world)
			swg_local.y = swg_leg.ankle_rest.y
			if _stop_support_is_left:
				_left_ankle = sup_local
				_right_ankle = swg_local
				_stop_just_landed = "R"
			else:
				_right_ankle = sup_local
				_left_ankle = swg_local
				_stop_just_landed = "L"
			swg_leg.last_pitch = swg_leg.ground_pitch
			swg_leg.last_yaw = angle_difference(global_rotation.y, _stop_swing_target_yaw)
			_cycle = fposmod(_stop_swing_landing, 1.0)
			_begin_stop_settle(_stop_carry_enabled)
		return

	if _stop_phase == STOP_SETTLE:
		_cancel_standing_turn()
		_pelvis_world_yaw = model_world_yaw
		_pelvis_yaw_vel = raw_body_yaw_vel
		_turn_target_yaw = _pelvis_world_yaw
		_turn_sharpness = move_toward(_turn_sharpness, 0.0, dt * 5.0)
		_turn_stride_mult = lerpf(_turn_stride_mult, 1.0, minf(dt * 5.0, 1.0))
		_turn_cadence_mult = lerpf(_turn_cadence_mult, 1.0, minf(dt * 5.0, 1.0))
		var previous_u := clampf(_stop_settle_elapsed / maxf(_stop_settle_dur, 0.01), 0.0, 1.0)
		_stop_settle_elapsed += dt
		var u := clampf(_stop_settle_elapsed / maxf(_stop_settle_dur, 0.01), 0.0, 1.0)
		_stride = move_toward(_stride, 0.0, dt * 3.2)
		_move_drive = move_toward(_move_drive, 0.0, dt * 3.8)
		_foot_stride = lerpf(_foot_stride, 0.0, smoothstep(0.0, 1.0, u))
		_update_yaw_cascade(dt, tempo_scale)
		_update_body_dynamics(dt, tempo_scale, false, 0.0)
		if previous_u < 0.92 and u >= 0.92 and _stop_trail_is_stepping():
			_stop_just_landed = "R" if _stop_lead_is_left else "L"
		if u >= 1.0:
			_foot_stride = 0.0
			_stride = 0.0
			_move_drive = 0.0
			_cycle = 0.0
			_clear_stop_state()
			_sync_feet_to_current_ankles()
		return

	# Standing still: decay residual walk scalars cleanly.
	_stride = move_toward(_stride, 0.0, dt * 4.2)
	_move_drive = move_toward(_move_drive, 0.0, dt * 4.5)
	_foot_stride = move_toward(_foot_stride, 0.0, dt * 4.5)
	_turn_sharpness = move_toward(_turn_sharpness, 0.0, dt * 5.0)
	_turn_stride_mult = lerpf(_turn_stride_mult, 1.0, minf(dt * 5.0, 1.0)) if dt > 0.0 else 1.0
	_turn_cadence_mult = lerpf(_turn_cadence_mult, 1.0, minf(dt * 5.0, 1.0)) if dt > 0.0 else 1.0
	if _foot_stride <= 0.001:
		_foot_stride = 0.0
		_cycle = 0.0

	if allow_standing_turn and on_floor and not is_nan(turn_target) and _foot_stride <= 0.15:
		_turn_target_yaw = turn_target
		_step_standing_turn_live(dt, tempo_scale)
		if _stand_turning or _stand_step_active:
			global_rotation = Vector3(0.0, _pelvis_world_yaw, 0.0)
			_prev_body_yaw = _pelvis_world_yaw
			_visual_yaw_offset = 0.0
			_model.rotation.y = _model_base_yaw
		else:
			_pelvis_world_yaw = model_world_yaw
			_foot_l.pivot_world.y = global_position.y
			_foot_r.pivot_world.y = global_position.y
			var rest_l := _rest_ankle_world(_left, global_position, model_world_yaw, 0.0, 0.0)
			var rest_r := _rest_ankle_world(_right, global_position, model_world_yaw, 0.0, 0.0)
			var cur_l := _foot_ankle_world(_foot_l, _left)
			var cur_r := _foot_ankle_world(_foot_r, _right)
			var drift_limit := 0.16 * _model.scale.z
			if Vector2(cur_l.x - rest_l.x, cur_l.z - rest_l.z).length() > drift_limit \
					or Vector2(cur_r.x - rest_r.x, cur_r.z - rest_r.z).length() > drift_limit:
				_sync_feet_to_rest()
	elif on_floor and _stand_step_active and _foot_stride <= 0.15:
		# Player released directional input mid-pivot: finish placing the airborne small step
		# cleanly heel-first with zero slip, then settle without starting another step.
		_turn_target_yaw = _stand_step_pelvis_goal
		_step_standing_turn_live(dt, tempo_scale)
		global_rotation = Vector3(0.0, _pelvis_world_yaw, 0.0)
		_prev_body_yaw = _pelvis_world_yaw
		_visual_yaw_offset = 0.0
		_model.rotation.y = _model_base_yaw
		if not _stand_step_active:
			_stand_turning = false
			_stand_dir = 0.0
			_stand_anticipation = 0.0
			_turn_mode = "idle"
	else:
		_cancel_standing_turn()
		_pelvis_world_yaw = model_world_yaw
		_pelvis_yaw_vel = raw_body_yaw_vel
		_turn_target_yaw = turn_target if not is_nan(turn_target) else _pelvis_world_yaw
		_turn_mode = "idle"
		_advance_heel_settle(_foot_l, dt)
		_advance_heel_settle(_foot_r, dt)
		_foot_l.pivot_world.y = global_position.y
		_foot_r.pivot_world.y = global_position.y
		var rest_l := _rest_ankle_world(_left, global_position, model_world_yaw, 0.0, 0.0)
		var rest_r := _rest_ankle_world(_right, global_position, model_world_yaw, 0.0, 0.0)
		var cur_l := _foot_ankle_world(_foot_l, _left)
		var cur_r := _foot_ankle_world(_foot_r, _right)
		var drift_limit := 0.38 * _model.scale.z
		var l_yaw_err := absf(angle_difference(model_world_yaw + IDLE_FOOT_YAW, _foot_l.world_yaw))
		var r_yaw_err := absf(angle_difference(model_world_yaw - IDLE_FOOT_YAW, _foot_r.world_yaw))
		if not _foot_l.planted or not _foot_r.planted or not on_floor \
				or Vector2(cur_l.x - rest_l.x, cur_l.z - rest_l.z).length() > drift_limit \
				or Vector2(cur_r.x - rest_r.x, cur_r.z - rest_r.z).length() > drift_limit \
				or l_yaw_err > 0.38 or r_yaw_err > 0.38:
			_sync_feet_to_rest()

	_update_yaw_cascade(dt, tempo_scale)
	_update_body_dynamics(dt, tempo_scale, false, 0.0)
	var head_ang_vel := _head_yaw_vel if absf(_head_yaw_vel) > absf(_pelvis_yaw_vel) else _pelvis_yaw_vel
	if dt > 0.0 and (_stand_turning or _stand_step_active):
		_turn_rate = lerpf(_turn_rate, clampf(head_ang_vel, -4.5, 4.5), minf(dt * 8.0, 1.0))


func _walk_pose(dt: float) -> void:
	var left_base: Vector3
	var right_base: Vector3
	var l_step_pitch: float
	var r_step_pitch: float
	var l_step_toe: float
	var r_step_toe: float
	var l_grounded: float
	var r_grounded: float
	var l_foot_yaw: float
	var r_foot_yaw: float
	var settle_hip_x := 0.0
	var settle_hip_y := 0.0
	var model_world_yaw := global_rotation.y + _visual_yaw_offset

	if _stop_phase == STOP_SWING:
		# Support foot stays 100% locked in world space while body smoothly carries forward
		# and the airborne foot finishes swinging cleanly down to its braking landing point.
		var u := clampf(_stop_swing_elapsed / maxf(_stop_swing_dur, 0.01), 0.0, 1.0)
		var sup_leg := _left if _stop_support_is_left else _right
		var swg_leg := _right if _stop_support_is_left else _left
		var sup_local := _skeleton.to_local(_stop_support_world)
		sup_local.y = sup_leg.ankle_rest.y
		var swg_world := _stop_swing_start_world.lerp(_stop_swing_target_world, smoothstep(0.0, 0.8, u))
		var swg_local := _skeleton.to_local(swg_world)
		var arc_boost := SWING_HEIGHT * 0.32 * _stop_swing_rem * lerpf(0.55, 1.0, clampf(_step_scale, 0.30, 1.0))
		var swg_y := _stop_swing_start_y * pow(1.0 - u, 0.70) + _heavy_swing_arc(u) * arc_boost
		swg_local.y = swg_leg.ankle_rest.y + swg_y
		var swg_pitch := lerpf(_stop_swing_start_pitch, 0.0, smoothstep(0.25, 0.94, u))
		var swg_toe := lerpf(_stop_swing_start_toe, 0.0, smoothstep(0.0, 0.35, u))
		var sup_yaw := angle_difference(model_world_yaw, _stop_support_yaw)
		var swg_yaw := angle_difference(model_world_yaw, lerp_angle(_stop_swing_start_yaw, _stop_swing_target_yaw, smoothstep(0.0, 0.60, u)))

		if _stop_support_is_left:
			left_base = sup_local
			right_base = swg_local
			l_step_pitch = 0.0
			r_step_pitch = swg_pitch
			l_step_toe = 0.0
			r_step_toe = swg_toe
			l_grounded = 1.0
			r_grounded = 0.0
			settle_hip_x = 0.022 * (1.0 - u)
			l_foot_yaw = sup_yaw
			r_foot_yaw = swg_yaw
		else:
			right_base = sup_local
			left_base = swg_local
			r_step_pitch = 0.0
			l_step_pitch = swg_pitch
			r_step_toe = 0.0
			l_step_toe = swg_toe
			r_grounded = 1.0
			l_grounded = 0.0
			settle_hip_x = -0.022 * (1.0 - u)
			l_foot_yaw = swg_yaw
			r_foot_yaw = sup_yaw
	elif _stop_phase == STOP_SETTLE:
		# Front (lead) foot stays 100% locked in world space while the body continues gliding
		# smoothly forward over it; trailing foot peels heel-first and steps FORWARD beside it!
		var u := clampf(_stop_settle_elapsed / maxf(_stop_settle_dur, 0.01), 0.0, 1.0)
		var lead_leg := _left if _stop_lead_is_left else _right
		var trail_leg := _right if _stop_lead_is_left else _left

		var lead_local := _skeleton.to_local(_stop_lead_world)
		lead_local.y = lead_leg.ankle_rest.y
		var trail_u := smoothstep(0.08, 0.92, u)
		var trail_dist := clampf(_stop_trail_start_world.distance_to(_stop_trail_target_world) /
				maxf(HALF_STEP * _model.scale.z, 0.01), 0.0, 1.0)
		var trail_swing := clampf(inverse_lerp(0.08, 0.92, u), 0.0, 1.0)
		var trail_lift := _heavy_swing_arc(trail_swing) if _stop_trail_is_stepping() else 0.0
		var trail_world := _stop_trail_start_world.lerp(_stop_trail_target_world, trail_u)
		var trail_local := _skeleton.to_local(trail_world)
		trail_local.y = trail_leg.ankle_rest.y + 0.16 * trail_lift * trail_dist
		var trail_pitch := -0.22 * trail_lift * trail_dist
		var trail_yaw := angle_difference(model_world_yaw,
				lerp_angle(_stop_trail_start_yaw, _stop_trail_target_yaw, trail_u))
		var lead_yaw := angle_difference(model_world_yaw, _stop_lead_yaw)
		var weight_over_lead := sin(PI * clampf(inverse_lerp(0.0, 0.92, u), 0.0, 1.0))

		if _stop_lead_is_left:
			left_base = lead_local
			right_base = trail_local
			l_step_pitch = 0.0
			r_step_pitch = trail_pitch
			l_step_toe = 0.0
			r_step_toe = 0.0
			l_grounded = 1.0
			r_grounded = 1.0 - trail_lift * 0.90
			settle_hip_x = 0.034 * weight_over_lead * trail_dist
			l_foot_yaw = lead_yaw
			r_foot_yaw = trail_yaw
		else:
			right_base = lead_local
			left_base = trail_local
			r_step_pitch = 0.0
			l_step_pitch = trail_pitch
			r_step_toe = 0.0
			l_step_toe = 0.0
			r_grounded = 1.0
			l_grounded = 1.0 - trail_lift * 0.90
			settle_hip_x = -0.034 * weight_over_lead * trail_dist
			l_foot_yaw = trail_yaw
			r_foot_yaw = lead_yaw
		settle_hip_y = -0.012 * sin(PI * clampf(u * 1.25, 0.0, 1.0))
	else:
		# World-locked footwork for walking (straight, gentle curve, sharp turn), standing ship-like pivot, & idle!
		var l_ankle_w := _foot_ankle_world(_foot_l, _left)
		var r_ankle_w := _foot_ankle_world(_foot_r, _right)
		left_base = _skeleton.to_local(l_ankle_w)
		right_base = _skeleton.to_local(r_ankle_w)
		l_step_pitch = _foot_l.foot_pitch
		r_step_pitch = _foot_r.foot_pitch
		l_step_toe = _foot_l.toe_bend
		r_step_toe = _foot_r.toe_bend
		l_grounded = 1.0 if _foot_l.planted else 0.0
		r_grounded = 1.0 if _foot_r.planted else 0.0
		l_foot_yaw = angle_difference(model_world_yaw, _foot_l.world_yaw)
		r_foot_yaw = angle_difference(model_world_yaw, _foot_r.world_yaw)

	# Probe terrain under each foot for rubble slope adaptation (zero delta on flat roads).
	_update_leg_ground(_left, left_base, l_grounded, dt)
	_update_leg_ground(_right, right_base, r_grounded, dt)

	var left_ground_lift := _left.ground_y * lerpf(0.35, 1.0, l_grounded)
	var right_ground_lift := _right.ground_y * lerpf(0.35, 1.0, r_grounded)
	if l_grounded < 0.5:
		left_ground_lift = maxf(left_ground_lift, maxf(_left.ground_y, _right.ground_y) * 0.55)
	if r_grounded < 0.5:
		right_ground_lift = maxf(right_ground_lift, maxf(_left.ground_y, _right.ground_y) * 0.55)

	_left_ankle = left_base + Vector3(0.0, left_ground_lift, 0.0)
	_right_ankle = right_base + Vector3(0.0, right_ground_lift, 0.0)


	# Lower pelvis slightly on slopes so the downhill leg never over-stretches.
	var target_drop := minf(_left.ground_y, _right.ground_y)
	if dt > 0.0:
		_pelvis_ground_drop = lerpf(_pelvis_ground_drop, target_drop, minf(dt * 12.0, 1.0))
	else:
		_pelvis_ground_drop = target_drop

	# Biomechanically accurate gait phases.
	var angle := _cycle * TAU
	var stride_phase := cos(angle)
	var weight_shift := sin(angle - 0.10)
	var bob_wave := -cos(2.0 * (angle - 0.25))
	var arm_lag := cos(angle - 0.15)
	var elbow_lag := cos(angle - 0.40)
	var upper_drive := _move_drive
	var step_amp := lerpf(0.62, 1.0, clampf(_step_scale, 0.28, 1.0)) * lerpf(0.76, 1.0, _turn_stride_mult)

	# Subtle living idle contrapposto & multi-harmonic breathing (muted while actively turning).
	var idle_weight := 1.0 - _stride
	var calm_idle := idle_weight * (1.0 - clampf(_turn_urgency * 3.0, 0.0, 1.0))
	var breath_sin := sin(_breath)
	var contra := (sin(_idle_look_time * 0.42 + 0.5) * 0.72 + sin(_idle_look_time * 0.19) * 0.28) * calm_idle
	var idle_sway_x := contra * 0.014
	var idle_yaw := _head_idle_gaze.x * calm_idle
	var idle_pitch := _head_idle_gaze.y * calm_idle

	# Pelvis position: poised idle (-0.016), grounded turn crouch (-_turn_crouch), weight press (_turn_weight_x).
	var base_hip_drop := lerpf(-0.016, -0.050, _stride * step_amp)
	var bob_y := bob_wave * 0.026 * _stride * step_amp
	var breath_y := breath_sin * (0.0042 * calm_idle + 0.002 * (1.0 - calm_idle))
	var stop_dip := -sin(_stop_momentum * PI) * 0.014
	var air_tuck := -0.022 * _air_weight
	var hip := _hip_rest + Vector3(
		weight_shift * 0.058 * _stride * step_amp + _turn_weight_x + idle_sway_x + settle_hip_x,
		base_hip_drop - _turn_crouch + bob_y + breath_y + stop_dip + settle_hip_y + air_tuck + _pelvis_ground_drop - _impact_jolt * 0.038,
		0.014 * upper_drive + 0.008 * clampf(absf(_inward_lean) * 4.0, 0.0, 1.0) + sin(_stop_momentum * PI) * 0.018
	)

	# Hierarchical Spine S-Curve:
	#   chest_twist > 0 => chest twisted LEFT (+yaw) relative to pelvis (~half of head turn).
	#   lean > 0 => body banking LEFT (+X), which is NEGATIVE roll around +Z!
	var chest_twist := angle_difference(_pelvis_world_yaw, _chest_world_yaw)
	var head_over_chest := angle_difference(_chest_world_yaw, _head_world_yaw)
	var lean := _inward_lean
	var turn_mag := clampf(absf(chest_twist) * 2.4 + absf(lean) * 3.5, 0.0, 1.0)

	var grow_lift := -0.028 * _growth_surge
	var pelvis_pitch := 0.050 * upper_drive + 0.032 * turn_mag + sin(_stop_momentum * PI) * 0.040 + _impact_jolt * 0.024
	var pelvis_yaw := stride_phase * 0.095 * _stride * step_amp - chest_twist * 0.12 + contra * 0.020
	var pelvis_roll := weight_shift * 0.046 * _stride * step_amp + 0.08 * lean + 0.025 * chest_twist + _turn_weight_x * 0.24 + contra * 0.020 + settle_hip_x * 0.7
	var hip_rot := _pose("spine", pelvis_pitch, pelvis_yaw, pelvis_roll)
	_skeleton.set_bone_pose_position(_bone["spine"], hip)

	var s1_roll := -weight_shift * 0.020 * _stride * step_amp - 0.30 * lean - 0.06 * chest_twist - contra * 0.010
	var s2_roll := -weight_shift * 0.030 * _stride * step_amp - 0.32 * lean - 0.05 * chest_twist - contra * 0.012
	var s3_roll := -weight_shift * 0.022 * _stride * step_amp - 0.05 * lean + 0.06 * chest_twist - contra * 0.008
	var s4_roll := 0.14 * lean + 0.04 * chest_twist

	_pose("spine.001", 0.010 * upper_drive + 0.018 * turn_mag + _impact_jolt * 0.020,
		-stride_phase * 0.040 * upper_drive * step_amp + chest_twist * 0.24, s1_roll)
	_pose("spine.002", 0.014 * upper_drive + 0.012 * turn_mag + breath_sin * 0.013 + grow_lift * 0.6,
		-stride_phase * 0.062 * upper_drive * step_amp + chest_twist * 0.42, s2_roll)
	_pose("spine.003", -0.012 * upper_drive - 0.014 * turn_mag + breath_sin * 0.024 + grow_lift + _impact_jolt * 0.020,
		-stride_phase * 0.068 * upper_drive * step_amp + chest_twist * 0.46, s3_roll)
	_pose("spine.004", -0.026 * upper_drive - 0.018 * turn_mag - breath_sin * 0.012,
		stride_phase * 0.024 * upper_drive * step_amp + head_over_chest * 0.22, s4_roll)

	_last_spine_s_curve = absf(s1_roll + s2_roll) + absf(pelvis_roll - s2_roll)

	# Vestibular head stabilization + strong leading gaze into the turn.
	var head_counter_yaw := stride_phase * 0.055 * upper_drive * step_amp + head_over_chest * 0.78 + idle_yaw
	var head_counter_roll := weight_shift * 0.024 * _stride * step_amp + 0.72 * lean - contra * 0.014
	var head_pitch := -0.020 * upper_drive - 0.014 * turn_mag - breath_sin * 0.014 + idle_pitch - _impact_jolt * 0.030
	_pose("Neck", head_pitch * 0.44, head_counter_yaw * 0.44, head_counter_roll * 0.42)
	_pose("Head", head_pitch * 0.56, head_counter_yaw * 0.56, head_counter_roll * 0.58)

	# Shoulders counter-twist slightly against chest torsion & counter-tilt with inward lean.
	var breath_shrug := breath_sin * 0.020 * calm_idle + _growth_surge * 0.035 - _impact_jolt * 0.022
	var sh_counter_z := clampf(-chest_twist * 0.28, -0.16, 0.16)
	_last_shoulder_counter = sh_counter_z
	var sh_tilt := clampf(lean * 0.16 + chest_twist * 0.05, -0.055, 0.055)
	var stand_sh_z := _stand_arm_phase * 0.045
	_pose_local("shoulder.L", breath_shrug - sh_tilt + maxf(-arm_lag, 0.0) * 0.036 * upper_drive, 0.0,
		arm_lag * 0.054 * upper_drive * step_amp + sh_counter_z + stand_sh_z)
	_pose_local("shoulder.R", breath_shrug + sh_tilt + maxf(arm_lag, 0.0) * 0.036 * upper_drive, 0.0,
		arm_lag * 0.054 * upper_drive * step_amp + sh_counter_z + stand_sh_z)

	# Asymmetric arms: outside arm opens & swings wider, inside arm tucks closer with tighter elbow bend,
	# preserving explicit clearance around Kawaii's yellow bear shoulder bag (X=-0.235).
	var turn_bias := clampf(lean * 7.2 + chest_twist * 1.35, -1.0, 1.0)
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

	var out_scale := lerpf(0.15, 0.19, _stride)
	var l_open_delta := out_scale * l_out - 0.075 * l_in
	var r_open_delta := out_scale * r_out - 0.040 * r_in
	_last_l_arm_open = l_open_delta
	_last_r_arm_open = r_open_delta

	var l_lean_clear := maxf(lean, 0.0) * 0.40
	var r_lean_clear := maxf(-lean, 0.0) * 0.88 + maxf(-chest_twist, 0.0) * 0.16
	var l_roll := -0.44 + arm_breath_out + l_pass + l_open_delta + l_lean_clear + contra * 0.015
	var r_roll := 0.29 - arm_breath_out - r_pass - r_open_delta - r_lean_clear + contra * 0.015

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

	var l_foot_pitch := l_step_pitch + _left.ground_pitch * l_grounded
	var r_foot_pitch := r_step_pitch + _right.ground_pitch * r_grounded
	var l_foot_roll := _left.ground_roll * l_grounded
	var r_foot_roll := _right.ground_roll * r_grounded
	var l_foot_toe := l_step_toe
	var r_foot_toe := r_step_toe

	# Blend smoothly back into locomotion after hand or seated actions.
	var exit_blend := maxf(maxf(_sit_crush_exit_blend, _sit_idle_exit_blend), maxf(_pickup_exit_blend, _punch_exit_blend))
	if exit_blend > 0.001:
		var t := smoothstep(0.0, 1.0, exit_blend)
		hip = hip.lerp(_snap_hip, t)
		_skeleton.set_bone_pose_position(_bone["spine"], hip)
		hip_rot = _blend_core_from_snapshot(t)
		_left_ankle = _left_ankle.lerp(_snap_left_ankle, t)
		_right_ankle = _right_ankle.lerp(_snap_right_ankle, t)
		l_foot_pitch = lerpf(l_foot_pitch, _snap_left_foot.x, t)
		l_foot_roll = lerpf(l_foot_roll, _snap_left_foot.y, t)
		l_foot_yaw = lerpf(l_foot_yaw, _snap_left_foot.z, t)
		l_foot_toe = lerpf(l_foot_toe, _snap_left_foot.w, t)
		r_foot_pitch = lerpf(r_foot_pitch, _snap_right_foot.x, t)
		r_foot_roll = lerpf(r_foot_roll, _snap_right_foot.y, t)
		r_foot_yaw = lerpf(r_foot_yaw, _snap_right_foot.z, t)
		r_foot_toe = lerpf(r_foot_toe, _snap_right_foot.w, t)
	else:
		# Preserve the contact even at full leg extension. Give at the pelvis
		# rather than dragging a target toward the body as the stride stretches.
		if l_grounded >= 0.75:
			hip.y = minf(hip.y, _max_hip_height(_left, _left_ankle, hip, hip_rot))
		if r_grounded >= 0.75:
			hip.y = minf(hip.y, _max_hip_height(_right, _right_ankle, hip, hip_rot))
		_skeleton.set_bone_pose_position(_bone["spine"], hip)

	_last_hip_local = hip
	var turn_knee_splay := 0.05 * turn_mag
	_plant(_left, _left_ankle, hip, hip_rot, l_foot_pitch, l_foot_roll, l_foot_yaw, l_foot_toe, turn_knee_splay)
	_plant(_right, _right_ankle, hip, hip_rot, r_foot_pitch, r_foot_roll, r_foot_yaw, r_foot_toe, turn_knee_splay)
	_last_l_knee_deg = _compute_knee_bend_deg(_left)
	_last_r_knee_deg = _compute_knee_bend_deg(_right)


# ==============================================================================
# Layered Top-Down Turning & World-Locked Zero-Slip Footwork
# ==============================================================================

func _init_foot_tracks() -> void:
	if _foot_tracks_ready:
		return
	_foot_l = FootTrack.new()
	_foot_l.side = "L"
	_foot_l.sign_x = 1.0
	_foot_r = FootTrack.new()
	_foot_r.side = "R"
	_foot_r.sign_x = -1.0
	_foot_tracks_ready = true
	_reset_turn_tracks()


func _cancel_standing_turn() -> void:
	_stand_turning = false
	_stand_dir = 0.0
	_stand_anticipation = 0.0
	_stand_step_active = false
	_stand_step_side = ""
	_stand_last_step_side = ""
	_stand_step_elapsed = 0.0
	_stand_arm_phase = 0.0
	_stand_land_dip = 0.0


func _reset_turn_tracks() -> void:
	if not _foot_tracks_ready or _left == null or _right == null:
		return
	var yaw := global_rotation.y + _visual_yaw_offset
	_turn_target_yaw = yaw
	_eye_world_yaw = yaw
	_eye_local_yaw = 0.0
	_eye_turn_override = 0.0
	_head_world_yaw = yaw
	_head_yaw_vel = 0.0
	_chest_world_yaw = yaw
	_chest_rel_pelvis = 0.0
	_chest_rel_vel = 0.0
	_pelvis_world_yaw = yaw
	_pelvis_yaw_vel = 0.0
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
	_actual_world_vel = Vector3.ZERO
	_turn_mode = "idle"
	_walk_was_moving = false
	_walk_init_step = false
	_prev_foot_scale = _model.scale.z
	_cancel_standing_turn()
	_stand_step_count = 0
	_sync_feet_to_rest()


func _sync_feet_to_rest() -> void:
	if not _foot_tracks_ready or _left == null or _right == null:
		return
	var yaw := global_rotation.y + _visual_yaw_offset
	_reset_foot_to_rest(_foot_l, _left, global_position, yaw)
	_reset_foot_to_rest(_foot_r, _right, global_position, yaw)


func _sync_feet_to_current_ankles() -> void:
	if not _foot_tracks_ready or _left == null or _right == null:
		return
	var yaw := global_rotation.y + _visual_yaw_offset
	var S := _model.scale.z
	for pair in [[_foot_l, _left, _left_ankle], [_foot_r, _right, _right_ankle]]:
		var ft: FootTrack = pair[0]
		var leg: Leg = pair[1]
		var ank_local: Vector3 = pair[2]
		var ank_w := _skeleton.to_global(ank_local)
		var foot_yaw := yaw + leg.last_yaw
		ft.planted = true
		ft.pivot_mode = PIVOT_HEEL
		ft.world_yaw = foot_yaw
		ft.foot_pitch = clampf(leg.last_pitch - leg.ground_pitch, -0.35, 0.45)
		ft.toe_bend = leg.last_toe
		ft.heel_settle_t = 1.0
		ft.active_pivoting = 0.0
		ft.pivot_world = ank_w - Vector3.UP * (ANKLE_GROUND_Y * S) + _yaw_forward(foot_yaw) * (HEEL_Z_FROM_ANKLE * S)
		ft.pivot_world.y = global_position.y
		ft.swing_start_world = ank_w
		ft.swing_target_world = ank_w
		ft.swing_start_yaw = foot_yaw
		ft.swing_target_yaw = foot_yaw


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
	ft.pivot_world.y = body_pos.y
	ft.swing_start_world = ankle_w
	ft.swing_target_world = ankle_w
	ft.swing_start_yaw = foot_yaw
	ft.swing_target_yaw = foot_yaw
	ft.swing_t = 0.0


func _step_standing_turn_live(dt: float, tempo_scale: float) -> void:
	var pelvis_err := angle_difference(_pelvis_world_yaw, _turn_target_yaw)
	var feet_mean_yaw := _mean_angle(_foot_l.world_yaw, _foot_r.world_yaw)
	var feet_err := angle_difference(feet_mean_yaw, _turn_target_yaw)
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
				var ant_frac := 1.0 - clampf(_stand_anticipation / maxf(STAND_ANTICIPATION_BASE / maxf(tempo_scale, 0.5), 0.01), 0.0, 1.0)
				var feet_anchor_yaw := _mean_angle(_foot_l.world_yaw, _foot_r.world_yaw)
				var pre_pelvis_lead := clampf(angle_difference(feet_anchor_yaw, _turn_target_yaw) * 0.22, -0.18, 0.18) * smoothstep(0.25, 1.0, ant_frac)
				var prev_py := _pelvis_world_yaw
				_pelvis_world_yaw = lerp_angle(_pelvis_world_yaw, feet_anchor_yaw + pre_pelvis_lead, minf(dt * 8.0, 1.0))
				if dt > 0.0:
					_pelvis_yaw_vel = angle_difference(prev_py, _pelvis_world_yaw) / dt
			else:
				_start_standing_pivot_step(tempo_scale)
	elif not _stand_step_active:
		_turn_mode = "idle"
		_pelvis_yaw_vel = lerpf(_pelvis_yaw_vel, 0.0, minf(dt * 10.0, 1.0)) if dt > 0.0 else 0.0

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

			# Support foot in-place pivot around locked heel or ball (ZERO horizontal slip!).
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

			var prev_py := _pelvis_world_yaw
			var pelv_u := 0.32 + 0.68 * smoothstep(0.0, 0.82, swing_t)
			_pelvis_world_yaw = lerp_angle(_stand_step_pelvis_start, _stand_step_pelvis_goal, pelv_u)
			if dt > 0.0:
				_pelvis_yaw_vel = angle_difference(prev_py, _pelvis_world_yaw) / dt

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
				_trigger_impact_impulse(0.18)
	else:
		_advance_heel_settle(_foot_l, dt)
		_advance_heel_settle(_foot_r, dt)
		_stand_arm_phase = move_toward(_stand_arm_phase, 0.0, dt * 4.5)

	_stand_land_dip = move_toward(_stand_land_dip, 0.0, dt * 3.8)


func _start_standing_pivot_step(tempo_scale: float) -> void:
	var pelvis_err := angle_difference(_pelvis_world_yaw, _turn_target_yaw)
	var dir := 1.0 if pelvis_err >= 0.0 else -1.0
	if absf(pelvis_err) < STAND_DONE_DEADZONE:
		dir = _stand_dir if _stand_dir != 0.0 else 1.0
	_stand_dir = dir

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

	var rem_from_sup := angle_difference(sup_heading, _turn_target_yaw)
	var rem_from_swg := angle_difference(swg_heading, _turn_target_yaw)

	var step_heading: float
	if absf(rem_from_sup) <= STAND_STEP_MAX_YAW * 1.08:
		step_heading = _turn_target_yaw
	else:
		step_heading = sup_heading + clampf(rem_from_sup, -STAND_STEP_MAX_YAW, STAND_STEP_MAX_YAW)

	var swg_advance := angle_difference(swg_heading, step_heading)
	if absf(swg_advance) < 0.06 and absf(rem_from_swg) > 0.08:
		step_heading = swg_heading + clampf(rem_from_swg, -STAND_STEP_MAX_YAW, STAND_STEP_MAX_YAW)

	var sup_rem := angle_difference(sup_heading, step_heading)
	var sup_pivot_delta := clampf(sup_rem * 0.34, -0.22, 0.22)
	if signf(sup_pivot_delta) == signf(rem_from_sup) and absf(sup_pivot_delta) > absf(rem_from_sup):
		sup_pivot_delta = rem_from_sup
	var sup_next_heading := sup_heading + sup_pivot_delta

	var pelv_goal := _mean_angle(sup_next_heading, step_heading)
	if absf(angle_difference(step_heading, _turn_target_yaw)) < 0.04 and absf(angle_difference(sup_next_heading, _turn_target_yaw)) < 0.24:
		pelv_goal = lerp_angle(pelv_goal, _turn_target_yaw, 0.65)

	var is_final_square := absf(angle_difference(step_heading, _turn_target_yaw)) < 0.04
	var widen := 0.0 if is_final_square else 0.016
	var target_ankle := _rest_ankle_world(swg_leg, global_position, step_heading, 0.0, widen)
	var sup_ankle := _foot_ankle_world(sup_ft, sup_leg)
	var S := _model.scale.z
	var min_sep := 0.135 * S
	var horiz_sep := Vector3(target_ankle.x - sup_ankle.x, 0.0, target_ankle.z - sup_ankle.z)
	if horiz_sep.length() < min_sep:
		target_ankle += _yaw_left(step_heading) * (swg_leg.sign_x * (min_sep - horiz_sep.length()))

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


func _update_walk_foot(ft: FootTrack, leg: Leg, other_ft: FootTrack, other_leg: Leg,
		phase: float, prev_phase: float, swing_dur: float, dt: float) -> bool:
	var S := _model.scale.z
	var in_swing := phase >= CONTACT_FRACTION

	if in_swing:
		if ft.planted:
			var cur_ankle := _foot_ankle_world(ft, leg)
			ft.planted = false
			ft.swing_start_phase = clampf(phase, CONTACT_FRACTION, 0.90)
			ft.swing_start_world = cur_ankle
			ft.swing_start_yaw = ft.world_yaw
			ft.swing_start_pitch = ft.foot_pitch
			ft.swing_start_toe = ft.toe_bend
			ft.swing_start_lift = maxf(cur_ankle.y - (global_position.y + ANKLE_GROUND_Y * S), 0.0)
			ft.swing_bow_sign = leg.sign_x
			ft.active_pivoting = 0.0
		var swing_t := clampf(inverse_lerp(ft.swing_start_phase, 1.0, phase), 0.0, 1.0)
		ft.swing_t = swing_t
		ft.swing_remaining = (1.0 - swing_t) * swing_dur
		if swing_t <= SWING_TARGET_LOCK:
			var t_rem := ft.swing_remaining
			var pred_yaw := _pelvis_world_yaw + _pelvis_yaw_vel * t_rem * 0.78
			var yaw_err_rem := angle_difference(_pelvis_world_yaw, _turn_target_yaw)
			var gentle_toe_bias := clampf((_pelvis_yaw_vel * 0.28 + yaw_err_rem * 0.22), -0.22, 0.22) * (1.0 - _turn_sharpness * 0.4)
			var sharp_toe_lead := clampf(yaw_err_rem * 0.32, -0.30, 0.30) * _turn_sharpness
			var target_heading := pred_yaw + sharp_toe_lead

			var actual_spd := Vector2(_actual_world_vel.x, _actual_world_vel.z).length()
			var arc_mid_yaw := _pelvis_world_yaw + _pelvis_yaw_vel * t_rem * 0.45
			var pred_pos := global_position + _yaw_forward(arc_mid_yaw) * actual_spd * t_rem
			var is_inside := (leg.sign_x * _turn_sign > 0.0)
			var leg_diff_mult: float
			if is_inside:
				leg_diff_mult = lerpf(1.0, 0.72, _turn_sharpness * absf(_turn_sign))
			else:
				leg_diff_mult = lerpf(1.0, 1.18, _turn_sharpness * absf(_turn_sign))

			var forward_reach := HALF_STEP * _step_scale * _turn_stride_mult * leg_diff_mult
			var widen := 0.022 * _turn_sharpness
			var track_in := -0.006 * _stride * (1.0 - _turn_sharpness)
			var land_ankle := _rest_ankle_world(leg, pred_pos, pred_yaw, forward_reach, widen + track_in)

			var other_ankle := _foot_ankle_world(other_ft, other_leg)
			var fwd_axis := _yaw_forward(pred_yaw)
			var lat_axis := _yaw_left(pred_yaw) * leg.sign_x
			var other_fwd_gap := absf((land_ankle - other_ankle).dot(fwd_axis))
			# Only push away from the opposite foot when it is near the landing plane, and keep
			# the landing strictly inside a natural hip corridor so a trailing turn foot can never
			# shove the landing foot meters out to the side.
			if other_fwd_gap < 0.24 * S:
				var rel_lat := (land_ankle - other_ankle).dot(lat_axis)
				var min_lat := 0.132 * S
				if rel_lat < min_lat:
					land_ankle += lat_axis * (min_lat - rel_lat)
				var min_sep := 0.150 * S
				var sep := Vector3(land_ankle.x - other_ankle.x, 0.0, land_ankle.z - other_ankle.z)
				if sep.length() < min_sep:
					land_ankle += lat_axis * (min_sep - sep.length())
			var land_rel := land_ankle - pred_pos
			var lat_from_hip := land_rel.dot(lat_axis)
			var max_lat_from_hip := 0.135 * S
			var min_lat_from_hip := 0.055 * S
			if lat_from_hip > max_lat_from_hip:
				land_ankle -= lat_axis * (lat_from_hip - max_lat_from_hip)
			elif lat_from_hip < min_lat_from_hip:
				land_ankle += lat_axis * (min_lat_from_hip - lat_from_hip)

			ft.swing_target_world = land_ankle
			ft.swing_target_yaw = target_heading + leg.sign_x * IDLE_FOOT_YAW + gentle_toe_bias
			ft.last_step_length = Vector2(land_ankle.x - ft.swing_start_world.x, land_ankle.z - ft.swing_start_world.z).length()

		ft.world_yaw = lerp_angle(ft.swing_start_yaw, ft.swing_target_yaw, smoothstep(0.10, 0.70, swing_t))
		if swing_t >= 0.80 and swing_t < 0.96:
			ft.last_pre_land_yaw_err = absf(angle_difference(ft.world_yaw, ft.swing_target_yaw))

		var knee_drive := smoothstep(0.12, 0.44, swing_t) * (1.0 - smoothstep(0.72, 0.98, swing_t))
		ft.foot_pitch = ft.swing_start_pitch * (1.0 - smoothstep(0.0, 0.23, swing_t)) - 0.54 * knee_drive
		ft.toe_bend = lerpf(ft.swing_start_toe, 0.0, smoothstep(0.0, 0.24, swing_t))
		return false
	if prev_phase >= CONTACT_FRACTION and not ft.planted:
		ft.planted = true
		ft.world_yaw = ft.swing_target_yaw
		ft.foot_pitch = 0.0
		ft.toe_bend = 0.0
		ft.last_landing_pitch = ft.foot_pitch
		ft.pivot_mode = PIVOT_HEEL
		ft.heel_settle_t = 1.0
		ft.active_pivoting = 0.0
		ft.swing_start_phase = CONTACT_FRACTION
		ft.swing_remaining = 0.0
		var heel_w := ft.swing_target_world - Vector3.UP * (ANKLE_GROUND_Y * S) + _yaw_forward(ft.world_yaw) * (HEEL_Z_FROM_ANKLE * S)
		heel_w.y = global_position.y
		ft.pivot_world = heel_w
		return true
	_advance_heel_settle(ft, dt)
	ft.pivot_world.y = global_position.y
	return false


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


static func _heavy_swing_arc(t: float) -> float:
	# Lift and hold through the reach, then accelerate vertically into a flat-footed strike.
	var down := clampf(inverse_lerp(0.69, 1.0, t), 0.0, 1.0)
	return smoothstep(0.0, 0.43, t) * (1.0 - down * down)


func _foot_ankle_world(ft: FootTrack, _leg: Leg) -> Vector3:
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
		var xz_t := smoothstep(0.0, 1.0, t) if _stand_step_active else smoothstep(0.08, 0.76, t)
		var pos := ft.swing_start_world.lerp(ft.swing_target_world, xz_t)
		var bow_mag := (0.024 if _stand_step_active else 0.028 * _turn_sharpness) * S
		var bow_dir := _yaw_left(_pelvis_world_yaw) * ft.swing_bow_sign
		var bow := sin(PI * (t if _stand_step_active else clampf(t / 0.8, 0.0, 1.0)))
		pos += bow_dir * (bow * bow_mag)

		var other_ft := _foot_r if ft == _foot_l else _foot_l
		var other_leg := _right if ft == _foot_l else _left
		if other_ft.planted:
			var other_ankle := _foot_ankle_world(other_ft, other_leg)
			var lat_vec := _yaw_left(_pelvis_world_yaw) * ft.sign_x
			var fwd_vec := _yaw_forward(_pelvis_world_yaw)
			var rel := pos - other_ankle
			var fwd_dist := absf(rel.dot(fwd_vec))
			var lat_signed := rel.dot(lat_vec)
			var pass_weight := (1.0 - smoothstep(0.10 * S, 0.34 * S, fwd_dist)) * bow
			var min_lat_clear := 0.135 * S
			if lat_signed < min_lat_clear and pass_weight > 0.001:
				pos += lat_vec * ((min_lat_clear - lat_signed) * clampf(pass_weight * 1.45, 0.0, 1.0))

		var base_y := global_position.y + ANKLE_GROUND_Y * S
		var start_lift := ft.swing_start_lift * pow(1.0 - t, 1.35)
		if _stand_step_active:
			var v_land := Quaternion(Vector3.RIGHT, HEEL_STRIKE_PITCH) * Vector3(0.0, ANKLE_GROUND_Y, -HEEL_Z_FROM_ANKLE)
			var land_blend := smoothstep(0.55, 1.0, t)
			pos += _yaw_forward(ft.world_yaw) * (v_land.z + HEEL_Z_FROM_ANKLE) * S * land_blend
			pos.y = base_y + start_lift + (0.105 * sin(PI * pow(t, 0.86)) + (v_land.y - ANKLE_GROUND_Y) * land_blend) * S
		else:
			var step_h_scale := lerpf(0.66, 1.0, clampf(_step_scale, 0.28, 1.0)) * lerpf(1.0, 0.78, _turn_sharpness)
			pos.y = base_y + start_lift + SWING_HEIGHT * step_h_scale * S * _heavy_swing_arc(t)
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


func _update_yaw_cascade(dt: float, tempo_scale: float) -> void:
	# Layer 2: Head chases _turn_target_yaw FIRST and most noticeably.
	var head_goal := _pelvis_world_yaw + clampf(
		angle_difference(_pelvis_world_yaw, _turn_target_yaw),
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

	# Layer 3: Chest twists in pelvis-relative space to ~half of head turn, half a beat behind head.
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

	# Layer 1: Eyes dart to _turn_target_yaw FIRST (leading head!).
	var eye_err := angle_difference(_head_world_yaw, _turn_target_yaw)
	var eye_target_local := clampf(eye_err * 0.85, -TURN_EYE_MAX_YAW, TURN_EYE_MAX_YAW)
	if dt > 0.0:
		_eye_local_yaw = lerpf(_eye_local_yaw, eye_target_local, minf(dt * 28.0, 1.0))
	else:
		_eye_local_yaw = eye_target_local
	_eye_world_yaw = _head_world_yaw + _eye_local_yaw

	var active_gaze := clampf(absf(angle_difference(_pelvis_world_yaw, _turn_target_yaw)) * 3.5 + absf(_pelvis_yaw_vel) * 1.5, 0.0, 1.0)
	_eye_turn_override = lerpf(_eye_turn_override, active_gaze, minf(dt * 12.0, 1.0)) if dt > 0.0 else active_gaze


func _update_body_dynamics(dt: float, tempo_scale: float, moving: bool, walk_speed: float) -> void:
	var yaw_err := angle_difference(_pelvis_world_yaw, _turn_target_yaw)
	var signed_rate := _pelvis_yaw_vel
	_effective_turn_rate = lerpf(_effective_turn_rate, signed_rate, minf(dt * 9.0, 1.0)) if dt > 0.0 else signed_rate
	_turn_urgency = clampf(maxf(absf(yaw_err) / 1.1, absf(signed_rate) / 1.6), 0.0, 1.0)

	var body_ratio := maxf(_model.scale.z / _model_base_scale, 0.15)
	var ref_speed := maxf(WALK_REF_SPEED * clampf(pace, 0.5, 1.5) * minf(body_ratio, 1.0), 0.1)
	var speed_norm := clampf(walk_speed / ref_speed, 0.0, 2.4)
	var target_lean := 0.0
	if moving:
		var rate_term := _effective_turn_rate * (0.030 + 0.024 * speed_norm)
		var lead_term := clampf(yaw_err, -1.2, 1.2) * (0.015 + 0.009 * speed_norm)
		target_lean = clampf(rate_term + lead_term, -0.15, 0.15)
	elif _stand_turning or _stand_step_active:
		target_lean = clampf(yaw_err * 0.055 + _stand_dir * 0.032, -0.085, 0.085)
	else:
		target_lean = clampf(yaw_err * 0.03, -0.025, 0.025)

	if dt > 0.0:
		var lean_omega := 7.2 * clampf(tempo_scale, 0.6, 1.6)
		var lean_acc := (target_lean - _inward_lean) * (lean_omega * lean_omega) - _inward_lean_vel * (2.0 * 0.94 * lean_omega)
		_inward_lean_vel += lean_acc * dt
		_inward_lean = clampf(_inward_lean + _inward_lean_vel * dt, -0.16, 0.16)
	else:
		_inward_lean = target_lean

	var target_crouch := 0.0
	if moving:
		target_crouch = 0.008 * clampf(absf(_effective_turn_rate) / 0.45, 0.0, 1.0) + 0.016 * _turn_sharpness + 0.006 * clampf(absf(_inward_lean) / 0.14, 0.0, 1.0)
	elif _stand_turning or _stand_step_active:
		target_crouch = 0.015 + 0.007 * clampf(absf(yaw_err) / 1.5, 0.0, 1.0) + 0.007 * sin(_stand_land_dip * PI)
	else:
		target_crouch = 0.005 * clampf(absf(yaw_err) / 0.3, 0.0, 1.0)
	_turn_crouch = lerpf(_turn_crouch, target_crouch, minf(dt * 8.0, 1.0)) if dt > 0.0 else target_crouch

	var target_wx := 0.0
	if _stand_step_active:
		var sup_sign := -1.0 if _stand_step_side == "L" else 1.0
		var u := clampf(_stand_step_elapsed / maxf(_stand_step_dur, 0.01), 0.0, 1.0)
		var shift_env := smoothstep(0.0, STAND_TRANSFER_FRAC * 0.95, u) * (1.0 - smoothstep(0.86, 1.0, u) * 0.35)
		target_wx = sup_sign * 0.048 * shift_env + _stand_dir * 0.010
	elif _stand_turning:
		target_wx = _stand_dir * 0.044
	elif moving:
		target_wx = clampf(_inward_lean * 0.16 + _turn_sign * 0.014 * _turn_sharpness, -0.034, 0.034)
	_turn_weight_x = lerpf(_turn_weight_x, target_wx, minf(dt * 9.5, 1.0)) if dt > 0.0 else target_wx


func _compute_knee_bend_deg(leg: Leg) -> float:
	var p_hip := _skeleton.get_bone_global_pose(leg.thigh).origin
	var p_knee := _skeleton.get_bone_global_pose(leg.shin).origin
	var p_ank := _skeleton.get_bone_global_pose(leg.foot).origin
	var v1 := (p_knee - p_hip).normalized()
	var v2 := (p_ank - p_knee).normalized()
	return rad_to_deg(acos(clampf(v1.dot(v2), -1.0, 1.0)))


func get_turn_telemetry() -> Dictionary:
	_init_foot_tracks()
	var model_world_yaw := global_rotation.y + _visual_yaw_offset
	var feet_mean := _mean_angle(_foot_l.world_yaw, _foot_r.world_yaw)
	var head_rel := angle_difference(_pelvis_world_yaw, _head_world_yaw)
	var chest_rel := angle_difference(_pelvis_world_yaw, _chest_world_yaw)

	var spine_g := _skeleton.get_bone_global_pose(_bone["spine"])
	var chest_g := _skeleton.get_bone_global_pose(_bone["spine.003"])
	var head_g := _skeleton.get_bone_global_pose(_bone["Head"])
	var eye_g := _skeleton.get_bone_global_pose(_eye_l) if _eye_l >= 0 else head_g
	var spine_ax: Basis = _axes["spine"]
	var chest_ax: Basis = _axes["spine.003"]
	var head_ax: Basis = _axes["Head"]
	var chest_fwd := (_skeleton.global_basis * (chest_g.basis * (chest_ax * Vector3.BACK))).slide(Vector3.UP).normalized()
	var head_fwd := (_skeleton.global_basis * (head_g.basis * (head_ax * Vector3.BACK))).slide(Vector3.UP).normalized()
	var eye_fwd := (_skeleton.global_basis * (eye_g.basis * (_eye_l_axes * Vector3.BACK))).slide(Vector3.UP).normalized()
	var pelvis_fwd := (_skeleton.global_basis * (spine_g.basis * (spine_ax * Vector3.BACK))).slide(Vector3.UP).normalized()
	var chest_up_local := (chest_g.basis * (chest_ax * Vector3.UP)).normalized()

	return {
		"mode": _turn_mode,
		"target_yaw": _turn_target_yaw,
		"eye_world_yaw": _eye_world_yaw,
		"head_world_yaw": _head_world_yaw,
		"chest_world_yaw": _chest_world_yaw,
		"pelvis_world_yaw": _pelvis_world_yaw,
		"feet_mean_world_yaw": feet_mean,
		"bone_eye_world_yaw": _dir_to_yaw(eye_fwd) if eye_fwd.length_squared() > 0.01 else _eye_world_yaw,
		"bone_head_world_yaw": _dir_to_yaw(head_fwd) if head_fwd.length_squared() > 0.01 else _head_world_yaw,
		"bone_chest_world_yaw": _dir_to_yaw(chest_fwd) if chest_fwd.length_squared() > 0.01 else _chest_world_yaw,
		"bone_pelvis_world_yaw": _dir_to_yaw(pelvis_fwd) if pelvis_fwd.length_squared() > 0.01 else _pelvis_world_yaw,
		"eye_local_yaw": _eye_local_yaw,
		"head_rel_pelvis": head_rel,
		"chest_rel_pelvis": chest_rel,
		"chest_to_head_ratio": (chest_rel / head_rel) if absf(head_rel) > 0.04 else 0.0,
		"shoulder_counter_z": _last_shoulder_counter,
		"spine_s_curve": _last_spine_s_curve,
		"inward_lean_rad": _inward_lean,
		"actual_torso_lean_rad": atan2(chest_up_local.x, chest_up_local.y),
		"pelvis_shift_x": _last_hip_local.x - _hip_rest.x,
		"pelvis_drop_y": _last_hip_local.y - _hip_rest.y,
		"left_knee_bend_deg": _last_l_knee_deg,
		"right_knee_bend_deg": _last_r_knee_deg,
		"left_arm_open": _last_l_arm_open,
		"right_arm_open": _last_r_arm_open,
		"left_arm_amp": _last_l_arm_amp,
		"right_arm_amp": _last_r_arm_amp,
		"turn_sharpness": _turn_sharpness,
		"turn_stride_mult": _turn_stride_mult,
		"turn_cadence_mult": _turn_cadence_mult,
		"standing_turning": _stand_turning,
		"standing_step_active": _stand_step_active,
		"standing_step_side": _stand_step_side,
		"standing_step_count": _stand_step_count,
		"left_planted": _foot_l.planted,
		"right_planted": _foot_r.planted,
		"left_pivot_mode": _foot_l.pivot_mode,
		"right_pivot_mode": _foot_r.pivot_mode,
		"left_heel_world": _foot_heel_world(_foot_l, _left),
		"right_heel_world": _foot_heel_world(_foot_r, _right),
		"left_ball_world": _foot_ball_world(_foot_l, _left),
		"right_ball_world": _foot_ball_world(_foot_r, _right),
		"left_foot_world_yaw": _foot_l.world_yaw,
		"right_foot_world_yaw": _foot_r.world_yaw,
		"left_foot_pitch": _foot_l.foot_pitch,
		"right_foot_pitch": _foot_r.foot_pitch,
		"left_last_step_len": _foot_l.last_step_length,
		"right_last_step_len": _foot_r.last_step_length,
		"left_last_landing_pitch": _foot_l.last_landing_pitch,
		"right_last_landing_pitch": _foot_r.last_landing_pitch,
		"model_world_yaw": model_world_yaw,
	}


static func _yaw_forward(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


static func _yaw_left(yaw: float) -> Vector3:
	return Vector3(-cos(yaw), 0.0, sin(yaw))


static func _dir_to_yaw(dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z)


static func _mean_angle(a: float, b: float) -> float:
	return a + angle_difference(a, b) * 0.5


static func _smoother(edge0: float, edge1: float, x: float) -> float:
	var u := clampf(inverse_lerp(edge0, edge1, x), 0.0, 1.0)
	return u * u * u * (u * (u * 6.0 - 15.0) + 10.0)


static func _bell(x: float, a: float, b: float, c: float, d: float) -> float:
	return _smoother(a, b, x) * (1.0 - _smoother(c, d, x))


static func _eval_vec3_curve(keys: Array, t: float) -> Vector3:
	if keys.is_empty():
		return Vector3.ZERO
	if t <= keys[0][0]:
		return keys[0][1]
	var last := keys.size() - 1
	if t >= keys[last][0]:
		return keys[last][1]
	for i in last:
		var t0: float = keys[i][0]
		var t1: float = keys[i + 1][0]
		if t >= t0 and t <= t1:
			var p0: Vector3 = keys[i][1]
			var p1: Vector3 = keys[i + 1][1]
			var p_prev: Vector3 = keys[maxi(i - 1, 0)][1]
			var p_next: Vector3 = keys[mini(i + 2, last)][1]
			var span := maxf(t1 - t0, 0.0001)
			var u := clampf((t - t0) / span, 0.0, 1.0)
			# Catmull-Rom with clamped tangent length for overshoot-free organic arcs.
			var m0 := (p1 - p_prev) * 0.42
			var m1 := (p_next - p0) * 0.42
			if i == 0:
				m0 = (p1 - p0) * 0.5
			if i + 1 == last:
				m1 = (p1 - p0) * 0.5
			var u2 := u * u
			var u3 := u2 * u
			return (2.0 * u3 - 3.0 * u2 + 1.0) * p0 + (u3 - 2.0 * u2 + u) * m0 + (-2.0 * u3 + 3.0 * u2) * p1 + (u3 - u2) * m1
	return keys[last][1]


static func _eval_dir_curve(keys: Array, t: float) -> Vector3:
	if keys.is_empty():
		return Vector3.UP
	if t <= keys[0][0]:
		return (keys[0][1] as Vector3).normalized()
	var last := keys.size() - 1
	if t >= keys[last][0]:
		return (keys[last][1] as Vector3).normalized()
	for i in last:
		var t0: float = keys[i][0]
		var t1: float = keys[i + 1][0]
		if t >= t0 and t <= t1:
			var u := _smoother(t0, t1, t)
			var a: Vector3 = (keys[i][1] as Vector3).normalized()
			var b: Vector3 = (keys[i + 1][1] as Vector3).normalized()
			var mixed := a.lerp(b, u)
			if mixed.length_squared() < 0.0001:
				return a
			return mixed.normalized()
	return (keys[last][1] as Vector3).normalized()


func _pickup_crush_pose(t: float, dt: float) -> void:
	# Normalized timeline t in [0.0, 1.0] (4.5s default):
	# 0.00..0.24: Spot object -> left foot brace step -> deep athletic crouch (right heel lifts on toe pivot).
	# 0.24..0.35: Right hand descends palm-down onto ground target -> fingers + opposing thumb grasp object.
	# 0.35..0.57: Weighted ascent with spine follow-through -> left foot steps back -> hand lifts in arc to chest/eye height.
	# 0.57..0.64: Clear poised inspection hold looking down at held object in upturned right palm.
	# 0.64..0.78: Effort wind-up -> straining crush squeeze with tremor -> sharp shatter-through recoil snap at t=0.745.
	# 0.78..0.87: Turn palm down/out -> open fingers & subtle dust-off wrist flick while glancing down.
	# 0.87..1.00: Clear yellow bear bag cleanly -> lower arm and settle seamlessly into exact default idle pose.

	var enter_t := 1.0 - _smoother(0.0, 0.07, t)
	var idle_tail := _smoother(0.88, 1.0, t)

	# --- 1. Core phase envelopes ---
	var crouch := _smoother(0.05, 0.24, t) * (1.0 - _smoother(0.35, 0.54, t))
	var torso_lean := _smoother(0.06, 0.25, t) * (1.0 - _smoother(0.37, 0.57, t))
	var reach_twist := _bell(t, 0.09, 0.24, 0.33, 0.49)
	var grab_dip := _bell(t, 0.22, 0.28, 0.31, 0.36)
	var stand_overshoot := sin(PI * clampf(inverse_lerp(0.51, 0.62, t), 0.0, 1.0)) * 0.007
	var inspect_hold := _bell(t, 0.52, 0.59, 0.65, 0.72)
	var crush_windup := _bell(t, 0.63, 0.70, 0.74, 0.80)
	var crush_strain := _bell(t, 0.68, 0.725, 0.742, 0.755)
	var crush_recoil := _bell(t, 0.740, 0.755, 0.775, 0.84)
	var crush_effort := clampf(crush_windup * 0.85 + crush_recoil * 0.65, 0.0, 1.0)
	var release_phase := _bell(t, 0.78, 0.82, 0.86, 0.92)

	# Subtle living idle breath so entry & exit match default idle seamlessly.
	var breath_sin := sin(_breath)
	var idle_blend := clampf((1.0 - _smoother(0.0, 0.08, t)) + idle_tail, 0.0, 1.0)
	var contra := (sin(_idle_look_time * 0.42 + 0.5) * 0.72 + sin(_idle_look_time * 0.19) * 0.28) * idle_blend
	var idle_sway_x := contra * 0.014
	var breath_y := breath_sin * (0.0042 * idle_blend + 0.0018 * (1.0 - idle_blend))

	# --- 2. Footwork & Legs (Graceful one-knee-low split crouch, ZERO foot slip!) ---
	# Left foot stays 100% flat-planted at idle rest X/Z as the front stability anchor!
	_update_leg_ground(_left, _left.ankle_rest, 1.0, dt)
	_left_ankle = _left.ankle_rest + Vector3(0.0, _left.ground_y, 0.0)
	var l_pitch := _left.ground_pitch
	var l_roll := _left.ground_roll
	var l_toe := 0.0
	var l_yaw := lerpf(IDLE_FOOT_YAW, IDLE_FOOT_YAW + 0.10, crouch)

	# Right foot takes ONE clean lifted step backward (0.02..0.12), pivots smoothly onto toes
	# while right knee dips low above ground (0.12..0.44), then lifts cleanly back to idle rest (0.45..0.56).
	var r_step_target := _right.ankle_rest + Vector3(-0.032, 0.0, -0.240)
	var r_step_out_u := clampf(inverse_lerp(0.02, 0.12, t), 0.0, 1.0)
	var r_step_back_u := clampf(inverse_lerp(0.45, 0.56, t), 0.0, 1.0)
	var r_stance := _smoother(0.02, 0.12, t) * (1.0 - _smoother(0.45, 0.56, t))
	var r_lift_out := sin(PI * r_step_out_u) if (t > 0.02 and t < 0.12) else 0.0
	var r_lift_back := sin(PI * r_step_back_u) if (t > 0.45 and t < 0.56) else 0.0
	var r_air := clampf(r_lift_out + r_lift_back, 0.0, 1.0)
	var r_heel := _smoother(0.10, 0.24, t) * (1.0 - _smoother(0.35, 0.47, t))
	var r_pitch := 0.72 * r_heel + 0.14 * r_lift_out + 0.16 * r_lift_back * (1.0 - _smoother(0.51, 0.56, t)) + _right.ground_pitch * (1.0 - maxf(r_heel, r_air))
	var r_toe := 0.64 * r_heel + 0.10 * r_lift_back * (1.0 - _smoother(0.49, 0.54, t))
	var r_roll := _right.ground_roll * (1.0 - maxf(r_heel, r_air))
	var r_yaw := lerpf(-IDLE_FOOT_YAW, -IDLE_FOOT_YAW - 0.06, r_stance)
	var r_pivot := _toe_pivot_ankle_delta(0.72 * r_heel)
	var r_base := _right.ankle_rest.lerp(r_step_target, r_stance)
	_update_leg_ground(_right, r_base, 1.0 - r_air, dt)
	_right_ankle = r_base + r_pivot + Vector3(0.0, 0.048 * r_lift_out + 0.056 * r_lift_back + _right.ground_y * (1.0 - r_air * 0.5), 0.0)

	# --- 3. Pelvis & Spine (Poised split-crouch drop + overlapping rise + crush tension) ---
	# Weight transfers subtly onto planted left support leg whenever right foot steps back/in.
	var step_shift_x := 0.034 * (r_lift_out + r_lift_back)
	var slope_drop := minf(_left.ground_y, _right.ground_y)
	var air_tuck := -0.022 * _air_weight * idle_blend
	var hip := _hip_rest + Vector3(
		idle_sway_x + step_shift_x + 0.014 * crouch + 0.012 * crush_windup - 0.008 * crush_recoil,
		-0.016 + breath_y + air_tuck - 0.475 * crouch - 0.030 * grab_dip + stand_overshoot - 0.018 * crush_recoil + slope_drop - _impact_jolt * 0.012,
		-0.042 * crouch + 0.008 * grab_dip + 0.014 * crush_windup - 0.010 * crush_recoil
	)

	var hip_pitch := 0.26 * torso_lean + 0.14 * grab_dip + 0.03 * crush_recoil + _impact_jolt * 0.020
	var hip_yaw := 0.10 * reach_twist - 0.06 * crush_effort + contra * 0.022
	var hip_roll := -0.04 * (r_lift_out + r_lift_back) - 0.05 * crouch - 0.04 * grab_dip + 0.02 * crush_windup + contra * 0.022
	var hip_rot := _pose("spine", hip_pitch, hip_yaw, hip_roll)
	_skeleton.set_bone_pose_position(_bone["spine"], hip)

	# Graceful forward lean that dips smoothly during the actual grab so palm meets ground with soft bent elbow.
	_pose("spine.001",
		0.22 * torso_lean + 0.12 * grab_dip + 0.03 * crush_recoil + _impact_jolt * 0.015,
		0.09 * reach_twist - 0.05 * (inspect_hold + crush_effort),
		-0.03 * crouch - 0.04 * grab_dip - 0.02 * crush_windup - contra * 0.010)
	_pose("spine.002",
		0.32 * torso_lean + 0.15 * grab_dip + breath_sin * 0.013 * idle_blend - 0.02 * crush_windup + 0.05 * crush_recoil,
		0.13 * reach_twist - 0.06 * (inspect_hold + crush_effort),
		-0.06 * reach_twist - 0.05 * grab_dip - 0.025 * crush_windup - contra * 0.012)
	_pose("spine.003",
		0.30 * torso_lean + 0.14 * grab_dip + breath_sin * 0.024 * idle_blend - 0.03 * crush_windup + 0.06 * crush_recoil + _impact_jolt * 0.018,
		0.15 * reach_twist - 0.06 * (inspect_hold + crush_effort),
		-0.08 * reach_twist - 0.05 * grab_dip - 0.025 * crush_windup - contra * 0.008)
	_pose("spine.004",
		-0.16 * torso_lean - 0.08 * grab_dip - breath_sin * 0.012 * idle_blend + 0.02 * crush_recoil,
		0.02 * reach_twist - 0.02 * crush_effort,
		0.02 * reach_twist)

	# --- 4. Head & Gaze Tracking (Eyes lead -> follow object from ground up to palm -> dust drop -> idle) ---
	var spot_down := _bell(t, 0.005, 0.08, 0.16, 0.28)
	var look_ground_crouch := _bell(t, 0.12, 0.24, 0.33, 0.48)
	var look_hand_rise := _bell(t, 0.36, 0.48, 0.56, 0.66)
	var look_hand_hold := _bell(t, 0.52, 0.60, 0.77, 0.85)
	var look_crumbs := _bell(t, 0.79, 0.84, 0.88, 0.95)
	var head_pitch := (
		0.24 * spot_down
		- 0.36 * look_ground_crouch - 0.08 * grab_dip # Keep face clearly readable & looking straight at ground object!
		+ 0.12 * look_hand_rise
		+ 0.21 * look_hand_hold
		+ 0.07 * crush_recoil
		+ 0.25 * look_crumbs
		- breath_sin * 0.014 * idle_blend
		+ _head_idle_gaze.y * idle_blend
		- _impact_jolt * 0.024
	)
	var head_yaw := (
		-0.16 * look_ground_crouch
		- 0.12 * look_hand_hold
		- 0.08 * look_crumbs
		+ _head_idle_gaze.x * idle_blend
	)
	var head_roll := (
		-0.060 * inspect_hold
		+ 0.050 * crush_effort
		- 0.025 * look_crumbs
		- contra * 0.015
	)
	_pose("Neck", head_pitch * 0.44, head_yaw * 0.44, head_roll * 0.42)
	_pose("Head", head_pitch * 0.56, head_yaw * 0.56, head_roll * 0.58)

	# Facial targets (consumed by _update_face).
	_pickup_eye_override = 1.0 - idle_tail
	var eye_down := 0.105 * spot_down + 0.085 * look_ground_crouch + 0.068 * look_hand_hold + 0.095 * look_crumbs
	var eye_side := -0.060 * look_hand_hold - 0.045 * look_crumbs
	_pickup_eye_target = Vector2(clampf(eye_side, -0.10, 0.10), clampf(eye_down, -0.06, 0.105))
	_pickup_brow_target = clampf(
		0.18 * _bell(t, 0.22, 0.29, 0.34, 0.42)
		+ 0.90 * _bell(t, 0.64, 0.71, 0.76, 0.83),
		0.0, 1.0
	)
	_pickup_squint = 0.15 * crush_strain + 0.20 * crush_recoil

	# --- 5. Shoulders & Default Idle FK Arm Base ---
	var breath_shrug := breath_sin * 0.020 * idle_blend - _impact_jolt * 0.022
	var r_protract := 0.22 * reach_twist + 0.10 * grab_dip
	_pose_local("shoulder.L", breath_shrug + 0.04 * crush_windup - 0.02 * crouch, 0.0, 0.04 * crouch)
	_pose_local("shoulder.R", breath_shrug + 0.11 * crush_windup - 0.07 * crush_recoil - 0.22 * reach_twist - 0.15 * grab_dip, 0.0, r_protract - 0.05 * crush_windup)

	# Start both arms from exact default idle FK pose so ik_weight=0 is 100.0% identical to idle!
	# Nudge right upper arm cleanly outward during entry/exit bag-passage window so slerp stays well clear of bag!
	var arm_breath_out := breath_sin * 0.015 * idle_blend
	var r_bag_clear := _bell(t, 0.005, 0.045, 0.095, 0.15) + _bell(t, 0.865, 0.915, 0.955, 0.995)
	_pose("upper_arm.L", 0.02 + 0.10 * crush_effort, -0.05, -0.44 + arm_breath_out + 0.12 * crush_effort + contra * 0.015)
	_pose("upper_arm.R", 0.03 - 0.12 * r_bag_clear, 0.06, 0.29 - arm_breath_out - 0.28 * r_bag_clear + contra * 0.015)
	_pose_local("forearm.L", 0.17 + 0.28 * crush_effort, 0.0, 0.0)
	_pose_local("forearm.R", 0.18 + 0.08 * r_bag_clear, 0.0, 0.0)
	_pose_local("hand.L", 0.06, 0.14, -0.22)
	_pose_local("hand.R", 0.06, -0.14, 0.22)

	# Solve legs BEFORE arm IK so left knee world position is exact for left-hand thigh brace!
	if enter_t > 0.001:
		hip = hip.lerp(_snap_hip, enter_t)
		_skeleton.set_bone_pose_position(_bone["spine"], hip)
		hip_rot = _blend_core_from_snapshot(enter_t)
		_left_ankle = _left_ankle.lerp(_left_at_pickup, enter_t)
		_right_ankle = _right_ankle.lerp(_right_at_pickup, enter_t)
		l_pitch = lerpf(l_pitch, _snap_left_foot.x, enter_t)
		l_roll = lerpf(l_roll, _snap_left_foot.y, enter_t)
		l_yaw = lerpf(l_yaw, _snap_left_foot.z, enter_t)
		l_toe = lerpf(l_toe, _snap_left_foot.w, enter_t)
		r_pitch = lerpf(r_pitch, _snap_right_foot.x, enter_t)
		r_roll = lerpf(r_roll, _snap_right_foot.y, enter_t)
		r_yaw = lerpf(r_yaw, _snap_right_foot.z, enter_t)
		r_toe = lerpf(r_toe, _snap_right_foot.w, enter_t)

	_plant(_left, _left_ankle, hip, hip_rot, l_pitch, l_roll, l_yaw, l_toe, 0.12 * crouch)
	_plant(_right, _right_ankle, hip, hip_rot, r_pitch, r_roll, r_yaw, r_toe, 0.08 * crouch)

	# --- 6. Left Arm IK: Relaxed Hand Braced on Forward Left Thigh/Knee (natural downward elbow, zero chicken wing!) ---
	var l_brace_w := _bell(t, 0.08, 0.19, 0.36, 0.50) * (1.0 - enter_t)
	if l_brace_w > 0.001:
		var l_knee_pos := _skeleton.get_bone_global_pose(_left.shin).origin
		# Rest palm gently over the front-top of the forward left knee with elbow tucked cleanly OUT-AND-DOWN!
		var l_palm_target := l_knee_pos + Vector3(0.015, 0.050, 0.018)
		var l_palm_normal := Vector3(-0.22, -0.94, -0.24).normalized()
		var l_finger_dir := Vector3(-0.15, -0.35, 0.92).normalized()
		var l_elbow_pole := Vector3(0.68, -0.66, -0.32).normalized()
		_solve_arm_ik(_arm_l, l_palm_target, l_elbow_pole, l_palm_normal, l_finger_dir, l_brace_w)

	# --- 7. Right Arm IK: Clear Bag -> Reach Ground -> Grasp -> Centerline Lift -> Bent-Elbow Inspect & Crush -> Shake -> Idle ---
	var r_ik_w := _bell(t, 0.03, 0.11, 0.90, 0.985) * (1.0 - enter_t)
	var g_tgt := _hand_aim

	var palm_keys := [
		[0.03, Vector3(-0.335, 0.875, 0.110)], # Immediately clear outside yellow bear bag!
		[0.11, Vector3(-0.305, 0.620, 0.245)], # Wide forward-out sweep around bag
		[0.21, Vector3(g_tgt.x - 0.015, g_tgt.y + 0.105, g_tgt.z)],
		[0.27, g_tgt],                         # Palm pocket lands dead-center on ground object!
		[0.32, g_tgt + Vector3(0.0, 0.006, 0.0)],
		[0.36, g_tgt + Vector3(-0.015, 0.085, 0.015)],
		[0.45, Vector3(-0.058, 0.680, 0.345)], # Clean centerline rising arc, well clear of yellow bear bag!
		[0.57, Vector3(-0.095, 1.248, 0.264)], # Bent-elbow hero inspection hold clearly framed beside shoulder/chest!
		[0.64, Vector3(-0.092, 1.254, 0.262)],
		[0.70, Vector3(-0.082, 1.278, 0.244)], # Tight bent-elbow power windup (~98 deg elbow!)
		[0.735, Vector3(-0.078, 1.276, 0.240)],
		[0.755, Vector3(-0.068, 1.210, 0.225)], # Crisp downward-inward shatter snap recoil!
		[0.79, Vector3(-0.076, 1.218, 0.232)],
		[0.835, Vector3(-0.155, 1.135, 0.258)], # Relaxed bent-elbow dust-off shake!
		[0.875, Vector3(-0.245, 1.070, 0.255)],
		[0.925, Vector3(-0.335, 0.960, 0.165)], # Wide clearance arc past yellow bear bag!
		[0.985, Vector3(-0.305, 0.865, 0.055)],
	]
	var r_palm_target := _eval_vec3_curve(palm_keys, t)

	# Muscular effort tremor right before shatter snap (sells crushing force!).
	if crush_strain > 0.001:
		var vib := sin(t * 245.0) * 0.0045 * crush_strain
		var vib2 := cos(t * 310.0) * 0.0034 * crush_strain
		r_palm_target += Vector3(vib, vib2, vib * 0.6)

	# Subtle crisp wrist shake-off oscillation while dropping crushed debris.
	var shake_env := _bell(t, 0.805, 0.822, 0.858, 0.878)
	var shake_wave := sin((t - 0.805) * 92.0) * shake_env
	if shake_env > 0.001:
		r_palm_target += Vector3(shake_wave * 0.018, -absf(shake_wave) * 0.008, 0.0)

	var palm_normal_keys := [
		[0.03, Vector3(0.90, -0.32, 0.28)],
		[0.14, Vector3(0.35, -0.88, -0.32)],
		[0.24, Vector3(0.06, -0.98, -0.18)], # Palm straight DOWN over object
		[0.34, Vector3(0.08, -0.96, -0.25)],
		[0.45, Vector3(0.58, 0.05, -0.81)],  # Forearm supinating smoothly as hand rises
		[0.57, Vector3(0.30, 0.72, -0.62)],  # Palm cupped UP & INWARD so held object is proudly visible!
		[0.64, Vector3(0.30, 0.72, -0.62)],
		[0.71, Vector3(0.58, 0.16, -0.80)],  # Power-crush orientation (upright & clearly readable!)
		[0.78, Vector3(0.54, 0.06, -0.84)],
		[0.835, Vector3(0.14, -0.88, -0.45)], # Palm DOWN/OUT to drop crushed crumbs!
		[0.88, Vector3(0.42, -0.78, -0.46)],
		[0.93, Vector3(0.88, -0.40, 0.24)],
		[0.985, Vector3(0.92, -0.30, 0.25)],
	]
	var r_palm_normal := _eval_dir_curve(palm_normal_keys, t)

	var finger_dir_keys := [
		[0.03, Vector3(-0.24, -0.95, 0.18)],
		[0.14, Vector3(0.12, -0.62, 0.78)],
		[0.24, Vector3(0.18, -0.18, 0.96)],  # Fingers reaching forward over object
		[0.34, Vector3(0.22, -0.24, 0.94)],
		[0.45, Vector3(0.38, 0.72, 0.58)],
		[0.57, Vector3(0.42, 0.64, 0.64)],   # Cupped forward-upward-inward during inspect
		[0.64, Vector3(0.40, 0.66, 0.63)],
		[0.71, Vector3(0.30, 0.93, 0.22)],   # Upright clenched fist during crush!
		[0.755, Vector3(0.34, 0.85, 0.40)],  # Crisp slight wrist flexion snap on shatter!
		[0.79, Vector3(0.30, 0.87, 0.38)],
		[0.835, Vector3(-0.18, -0.38, 0.91)], # Pointing out-down while shaking off crumbs!
		[0.88, Vector3(-0.28, -0.65, 0.70)],
		[0.93, Vector3(-0.32, -0.90, 0.30)],
		[0.985, Vector3(-0.24, -0.95, 0.18)],
	]
	var r_finger_dir := _eval_dir_curve(finger_dir_keys, t)
	if shake_env > 0.001:
		r_palm_normal = (r_palm_normal + Vector3(shake_wave * 0.42, 0.0, 0.0)).normalized()
		r_finger_dir = (r_finger_dir + Vector3(shake_wave * 0.22, 0.0, 0.0)).normalized()

	var elbow_pole_keys := [
		[0.03, Vector3(-0.92, -0.15, -0.36)], # Elbow strongly outward clearing bag!
		[0.14, Vector3(-0.88, 0.10, -0.46)],
		[0.26, Vector3(-0.78, 0.28, -0.56)], # Natural elbow line during crouch reach!
		[0.45, Vector3(-0.74, -0.52, -0.42)],
		[0.58, Vector3(-0.46, -0.76, -0.45)], # Elbow hangs naturally down below chest during bent-elbow inspect!
		[0.72, Vector3(-0.68, -0.56, -0.47)], # Elbow flares slightly out with crushing effort!
		[0.835, Vector3(-0.66, -0.58, -0.48)],
		[0.93, Vector3(-0.92, -0.18, -0.35)], # Keep elbow cleanly outside yellow bear bag!
		[0.985, Vector3(-0.85, -0.25, -0.46)],
	]
	var r_elbow_pole := _eval_dir_curve(elbow_pole_keys, t)

	if r_ik_w > 0.001:
		_solve_arm_ik(_arm_r, r_palm_target, r_elbow_pole, r_palm_normal, r_finger_dir, r_ik_w)

	# --- 8. Expressive Hand & Finger Articulation ---
	# Left hand: relaxed on thigh during brace, subtle sympathetic clench during crush, idle=0.32.
	var l_curl := 0.32 - 0.10 * l_brace_w + 0.26 * crush_effort
	_pose_fingers("L", l_curl)

	# Right hand: idle(0.32) -> wide open(-0.16) -> cupped C-grasp(0.38, proudly showing held object!)
	# -> tight power crush(1.24) -> wide shake-off release(-0.14) -> smooth return to idle(0.32)!
	var open_pre := _bell(t, 0.12, 0.22, 0.255, 0.295)
	var grasp_hold := _bell(t, 0.265, 0.315, 0.68, 0.73)
	var crush_clench := _bell(t, 0.685, 0.745, 0.785, 0.825)
	var open_post := _bell(t, 0.795, 0.835, 0.875, 0.945)

	var r_finger_curl := 0.32
	r_finger_curl = lerpf(r_finger_curl, -0.16, open_pre)
	r_finger_curl = lerpf(r_finger_curl, 0.38, grasp_hold)
	r_finger_curl = lerpf(r_finger_curl, 1.24, crush_clench)
	r_finger_curl = lerpf(r_finger_curl, -0.14, open_post)
	var r_splay := 0.20 * open_pre + 0.24 * open_post
	var r_thumb_oppose := grasp_hold
	var r_thumb_clench := crush_clench
	_pose_hand_expressive("R", r_finger_curl, r_splay, r_thumb_oppose, r_thumb_clench, open_pre + open_post)

	# --- 9. Event Triggers (Grasp & Shatter Impulse) ---
	if t >= PICKUP_CRUSH_TIME and not _pickup_crushed_emitted:
		_pickup_crushed_emitted = true
		_trigger_impact_impulse(0.42)
		_impact_flinch = 0.68


func _punch_pose(t: float, dt: float) -> void:
	# Normalized timeline t in [0.0, 1.0] (2.40s default):
	# 0.00..0.34: Left foot forward lunge step + deep right-side coil & cocked right fist (left arm forward guard).
	# 0.34..0.50: Kinetic-chain haymaker swing (rear heel drive -> hips snap -> torso whips -> fist blasts through target at t=0.46).
	# 0.50..0.68: Heavy inertial follow-through across centerline + front knee momentum cushion + hair whip.
	# 0.68..1.00: Controlled arm retraction clearing yellow bear bag + left foot step back -> exact default idle pose.

	var enter_t := 1.0 - _smoother(0.0, 0.06, t)
	var idle_tail := _smoother(0.86, 1.0, t)

	# --- 1. Core kinetic-chain envelopes ---
	var stance_load := _bell(t, 0.04, 0.22, 0.68, 0.90)
	var coil := _bell(t, 0.05, 0.30, 0.34, 0.41)
	var hip_drive := _bell(t, 0.33, 0.43, 0.60, 0.80)
	var torso_whip := _bell(t, 0.355, 0.465, 0.61, 0.83)
	var follow_cushion := _bell(t, 0.45, 0.54, 0.60, 0.74)
	var strike_window := _bell(t, 0.34, 0.42, 0.54, 0.66)
	var low_strike := clampf(PUNCH_TARGET_LOCAL.y - _hand_aim.y, 0.0, 0.60)

	var breath_sin := sin(_breath)
	var idle_blend := clampf((1.0 - _smoother(0.0, 0.07, t)) + idle_tail, 0.0, 1.0)
	var contra := (sin(_idle_look_time * 0.42 + 0.5) * 0.72 + sin(_idle_look_time * 0.19) * 0.28) * idle_blend
	var idle_sway_x := contra * 0.014
	var breath_y := breath_sin * (0.0042 * idle_blend + 0.0018 * (1.0 - idle_blend))

	# --- 2. Footwork & Legs (Zero foot slip! Boxing lunge + rear heel pivot) ---
	# Right foot stays 100% anchored at rest X/Z; rear heel drives up & pivots inward around toe pivot during swing!
	var r_heel := _bell(t, 0.33, 0.43, 0.62, 0.75)
	var r_pitch := 0.44 * r_heel + _right.ground_pitch * (1.0 - r_heel)
	var r_toe := 0.42 * r_heel
	var r_roll := _right.ground_roll * (1.0 - r_heel)
	var r_yaw := -IDLE_FOOT_YAW - 0.05 * coil + 0.14 * r_heel
	var r_pivot := _toe_pivot_ankle_delta(0.44 * r_heel)
	_update_leg_ground(_right, _right.ankle_rest, 1.0, dt)
	_right_ankle = _right.ankle_rest + r_pivot + Vector3(0.0, _right.ground_y, 0.0)

	# Left foot takes ONE crisp forward-outward boxing lunge step (0.02..0.22), stays 100% locked flat
	# through coil, impact, and follow-through (0.22..0.70), then lifts cleanly back to rest (0.70..0.92).
	var l_step_target := _left.ankle_rest + Vector3(0.048, 0.0, 0.255)
	var l_out_u := clampf(inverse_lerp(0.02, 0.22, t), 0.0, 1.0)
	var l_back_u := clampf(inverse_lerp(0.70, 0.92, t), 0.0, 1.0)
	var l_stance := _smoother(0.02, 0.22, t) * (1.0 - _smoother(0.70, 0.92, t))
	var l_lift_out := sin(PI * l_out_u) if (t > 0.02 and t < 0.22) else 0.0
	var l_lift_back := sin(PI * l_back_u) if (t > 0.70 and t < 0.92) else 0.0
	var l_air := clampf(l_lift_out + l_lift_back, 0.0, 1.0)
	var l_base := _left.ankle_rest.lerp(l_step_target, l_stance)
	_update_leg_ground(_left, l_base, 1.0 - l_air, dt)
	_left_ankle = l_base + Vector3(0.0, 0.054 * l_lift_out + 0.056 * l_lift_back + _left.ground_y * (1.0 - l_air * 0.5), 0.0)
	var l_pitch := -0.10 * l_lift_out + 0.14 * l_lift_back * (1.0 - _smoother(0.84, 0.92, t)) + _left.ground_pitch * (1.0 - l_air)
	var l_toe := 0.12 * l_lift_back * (1.0 - _smoother(0.80, 0.88, t))
	var l_roll := _left.ground_roll * (1.0 - l_air)
	var l_yaw := lerpf(IDLE_FOOT_YAW, IDLE_FOOT_YAW + 0.06, l_stance)

	# --- 3. Pelvis & Spine (Coiled right -> explosive left whip with phase lag) ---
	var step_shift_x := -0.036 * (l_lift_out + l_lift_back)
	var slope_drop := minf(_left.ground_y, _right.ground_y)
	var air_tuck := -0.022 * _air_weight * idle_blend
	var hip := _hip_rest + Vector3(
		idle_sway_x + step_shift_x - 0.044 * coil + 0.052 * hip_drive + 0.014 * follow_cushion,
		-0.016 + breath_y + air_tuck - 0.102 * stance_load - 0.044 * follow_cushion + slope_drop - _impact_jolt * 0.016,
		-0.045 * coil + 0.142 * hip_drive + 0.024 * follow_cushion
	)

	var hip_pitch := 0.08 * coil + 0.11 * hip_drive + 0.03 * follow_cushion + _impact_jolt * 0.020
	var hip_yaw := -0.24 * coil + 0.24 * hip_drive + contra * 0.022
	var hip_roll := 0.06 * coil - 0.07 * hip_drive + 0.03 * (l_lift_out + l_lift_back) + contra * 0.022
	var hip_rot := _pose("spine", hip_pitch, hip_yaw, hip_roll)
	_skeleton.set_bone_pose_position(_bone["spine"], hip)

	_pose("spine.001",
		0.03 * coil + 0.07 * torso_whip + 0.02 * follow_cushion + _impact_jolt * 0.015,
		-0.16 * coil + 0.16 * torso_whip,
		0.03 * coil - 0.04 * torso_whip - contra * 0.010)
	_pose("spine.002",
		0.04 * coil + 0.09 * torso_whip + 0.03 * follow_cushion + breath_sin * 0.013 * idle_blend,
		-0.22 * coil + 0.22 * torso_whip,
		0.04 * coil - 0.05 * torso_whip - contra * 0.012)
	_pose("spine.003",
		0.03 * coil + 0.08 * torso_whip + 0.03 * follow_cushion + breath_sin * 0.024 * idle_blend + _impact_jolt * 0.018,
		-0.22 * coil + 0.24 * torso_whip,
		0.04 * coil - 0.05 * torso_whip - contra * 0.008)
	_pose("spine.004",
		-0.04 * coil - 0.07 * torso_whip - breath_sin * 0.012 * idle_blend,
		-0.04 * coil + 0.05 * torso_whip,
		-0.02 * coil + 0.02 * torso_whip)

	# --- 4. Head & Eyes (Laser-locked forward on impact target through coil & whip!) ---
	var head_pitch := (
		-0.05 * coil
		- 0.10 * torso_whip # Counter-lift against aggressive forward torso drive so eyes glare straight ahead!
		+ 0.07 * _bell(t, 0.45, 0.50, 0.56, 0.66) # Crisp chin-tuck determination through impact
		- breath_sin * 0.014 * idle_blend
		+ _head_idle_gaze.y * idle_blend
		- _impact_jolt * 0.022
	)
	# Counter-rotate neck/head against full spine yaw so gaze NEVER leaves the target!
	var head_yaw := 0.78 * coil - 0.80 * torso_whip + _head_idle_gaze.x * idle_blend
	var head_roll := -0.10 * coil + 0.10 * torso_whip - contra * 0.015
	_pose("Neck", head_pitch * 0.45, head_yaw * 0.46, head_roll * 0.45)
	_pose("Head", head_pitch * 0.55, head_yaw * 0.54, head_roll * 0.55)

	_punch_eye_override = 1.0 - idle_tail
	var eye_yaw := clampf(0.08 * coil - 0.08 * torso_whip, -0.10, 0.10)
	var eye_pitch := 0.035 * strike_window
	_punch_eye_target = Vector2(eye_yaw, eye_pitch)
	_punch_brow_target = clampf(
		0.72 * _bell(t, 0.08, 0.24, 0.34, 0.44)
		+ 0.96 * _bell(t, 0.32, 0.42, 0.64, 0.82),
		0.0, 1.0
	)
	_punch_squint = 0.18 * strike_window

	# --- 5. Shoulders & Default Idle FK Arm Base ---
	var breath_shrug := breath_sin * 0.020 * idle_blend - _impact_jolt * 0.020
	_pose_local("shoulder.L", breath_shrug + 0.08 * coil - 0.05 * torso_whip, 0.0, 0.14 * coil - 0.18 * torso_whip)
	_pose_local("shoulder.R", breath_shrug + 0.10 * coil + 0.08 * torso_whip, 0.0, -0.20 * coil + 0.34 * torso_whip)

	# Default idle FK base with subtle natural outward right-arm bag clearance during entry/exit blend windows!
	var arm_breath_out := breath_sin * 0.015 * idle_blend
	var r_bag_clear := _bell(t, 0.005, 0.045, 0.095, 0.145) + _bell(t, 0.84, 0.90, 0.955, 0.995)
	_pose("upper_arm.L", 0.02, -0.05, -0.44 + arm_breath_out + contra * 0.015)
	_pose("upper_arm.R", 0.03 - 0.06 * r_bag_clear, 0.06, 0.29 - arm_breath_out - 0.16 * r_bag_clear + contra * 0.015)
	_pose_local("forearm.L", 0.17, 0.0, 0.0)
	_pose_local("forearm.R", 0.18 + 0.05 * r_bag_clear, 0.0, 0.0)
	_pose_local("hand.L", 0.06, 0.14, -0.22)
	_pose_local("hand.R", 0.06, -0.14, 0.22)

	# Solve legs with entry snapshot blend
	if enter_t > 0.001:
		hip = hip.lerp(_snap_hip, enter_t)
		_skeleton.set_bone_pose_position(_bone["spine"], hip)
		hip_rot = _blend_core_from_snapshot(enter_t)
		_left_ankle = _left_ankle.lerp(_left_at_punch, enter_t)
		_right_ankle = _right_ankle.lerp(_right_at_punch, enter_t)
		l_pitch = lerpf(l_pitch, _snap_left_foot.x, enter_t)
		l_roll = lerpf(l_roll, _snap_left_foot.y, enter_t)
		l_yaw = lerpf(l_yaw, _snap_left_foot.z, enter_t)
		l_toe = lerpf(l_toe, _snap_left_foot.w, enter_t)
		r_pitch = lerpf(r_pitch, _snap_right_foot.x, enter_t)
		r_roll = lerpf(r_roll, _snap_right_foot.y, enter_t)
		r_yaw = lerpf(r_yaw, _snap_right_foot.z, enter_t)
		r_toe = lerpf(r_toe, _snap_right_foot.w, enter_t)

	_plant(_left, _left_ankle, hip, hip_rot, l_pitch, l_roll, l_yaw, l_toe, 0.10 * stance_load)
	_plant(_right, _right_ankle, hip, hip_rot, r_pitch, r_roll, r_yaw, r_toe, 0.08 * stance_load)

	# --- 6. Left Arm IK: Tight Boxer's Chin/Chest Guard -> Tucked Rib-Guard on Strike -> Natural Drop ---
	var l_ik_w := _bell(t, 0.04, 0.14, 0.82, 0.95) * (1.0 - enter_t)
	if l_ik_w > 0.001:
		var l_palm_keys := [
			[0.04, Vector3(0.205, 0.875, 0.055)],
			[0.16, Vector3(0.140, 1.125, 0.205)],
			[0.30, Vector3(0.065, 1.240, 0.265)], # Tight fighter's guard right in front of upper chest/chin!
			[0.35, Vector3(0.085, 1.230, 0.235)],
			[0.46, Vector3(0.175, 1.125, 0.015)], # Clean tucked boxer's guard beside left ribs (NO flapping wing!)
			[0.58, Vector3(0.195, 1.105, -0.010)],
			[0.75, Vector3(0.210, 0.995, 0.060)],
			[0.95, Vector3(0.200, 0.855, 0.030)],
		]
		var l_palm_target := _eval_vec3_curve(l_palm_keys, t)
		var l_palm_normal := _eval_dir_curve([
			[0.04, Vector3(-0.90, -0.32, 0.28)],
			[0.28, Vector3(-0.55, -0.18, -0.81)], # Guard palm facing inward toward face/chin
			[0.46, Vector3(-0.76, -0.10, 0.64)],  # Compact rib-guard fist facing inward
			[0.75, Vector3(-0.88, -0.22, 0.42)],
			[0.95, Vector3(-0.92, -0.30, 0.25)],
		], t)
		var l_finger_dir := _eval_dir_curve([
			[0.04, Vector3(0.24, -0.95, 0.18)],
			[0.28, Vector3(-0.38, 0.82, 0.43)],   # Upright boxer guard fist!
			[0.46, Vector3(-0.22, 0.68, 0.70)],   # Tucked upright guard fist
			[0.75, Vector3(0.18, -0.78, 0.60)],
			[0.95, Vector3(0.24, -0.95, 0.18)],
		], t)
		var l_elbow_pole := _eval_dir_curve([
			[0.04, Vector3(0.35, -0.75, -0.56)],  # Elbow stays naturally DOWN (zero chicken wing!)
			[0.28, Vector3(0.34, -0.88, -0.33)],  # Tight tucked boxing guard elbow
			[0.46, Vector3(0.38, -0.80, -0.46)],  # Compact down-back elbow during right cross!
			[0.75, Vector3(0.38, -0.76, -0.52)],
			[0.95, Vector3(0.35, -0.75, -0.56)],
		], t)
		_solve_arm_ik(_arm_l, l_palm_target, l_elbow_pole, l_palm_normal, l_finger_dir, l_ik_w)

	# --- 7. Right Arm IK: Compact Cocked Coil -> Wide Sweeping Haymaker Arc -> Impact -> Sweeping Follow-Through -> Relaxed Return ---
	var r_ik_w := _bell(t, 0.03, 0.12, 0.86, 0.975) * (1.0 - enter_t)
	if r_ik_w > 0.001:
		var r_palm_keys := [
			[0.03, Vector3(-0.275, 0.855, 0.045)],  # Smooth relaxed start clearing yellow bear bag
			[0.14, Vector3(-0.305, 0.995, -0.045)], # Elbow drops low-back while fist rises cleanly!
			[0.29, Vector3(-0.295, 1.145, -0.140)], # TEXTBOOK BOXER COIL: low cocked elbow, heavy fist loaded forward-up!
			[0.34, Vector3(-0.320, 1.155, -0.125)], # Taut anticipation hold before explosion!
			[0.40, Vector3(-0.425, 1.195, 0.235)],  # EXPLOSIVE WIDE HAYMAKER SWEEP ARC!
			[0.455, PUNCH_TARGET_LOCAL],            # PEAK IMPACT: committed full-power straight-hook strike!
			[0.53, Vector3(0.320, 1.215, 0.665)],   # Wide, sweeping horizontal follow-through across centerline!
			[0.63, Vector3(0.345, 1.145, 0.565)],   # Open athletic follow-through brake
			[0.75, Vector3(0.020, 1.035, 0.420)],   # Smooth relaxed lowering across front
			[0.87, Vector3(-0.290, 0.945, 0.195)],  # Soft long arm arc cleanly clearing yellow bear bag!
			[0.975, Vector3(-0.275, 0.855, 0.055)],
		]
		var r_palm_target := _eval_vec3_curve(r_palm_keys, t)
		r_palm_target += (_hand_aim - PUNCH_TARGET_LOCAL) * _bell(t, 0.35, 0.455, 0.46, 0.68)
		var r_palm_normal := _eval_dir_curve([
			[0.03, Vector3(0.90, -0.32, 0.28)],
			[0.16, Vector3(0.84, -0.08, 0.54)],
			[0.32, Vector3(0.86, 0.28, 0.42)],      # Chambered upright fist facing inward-up toward target!
			[0.40, Vector3(0.55, -0.76, -0.34)],    # Pronating aggressively through wide sweep
			[0.455, Vector3(0.28, -0.95, -0.12)],   # Textbook flat-knuckle pronated boxing punch!
			[0.55, Vector3(0.18, -0.90, -0.40)],    # Carrying through past centerline
			[0.75, Vector3(0.62, -0.72, -0.30)],
			[0.88, Vector3(0.88, -0.36, 0.30)],
			[0.975, Vector3(0.92, -0.30, 0.25)],
		], t)
		var r_finger_dir := _eval_dir_curve([
			[0.03, Vector3(-0.24, -0.95, 0.18)],
			[0.16, Vector3(-0.22, -0.05, 0.97)],
			[0.32, Vector3(-0.18, 0.34, 0.92)],     # Loaded fist aimed cleanly up-forward at target!
			[0.40, Vector3(0.52, 0.06, 0.85)],      # Sweeping forward-inward
			[0.455, Vector3(0.22, 0.02, 0.97)],     # Straight committed knuckle punch!
			[0.55, Vector3(0.78, -0.10, 0.62)],     # Follow-through arc left
			[0.75, Vector3(0.28, -0.58, 0.76)],
			[0.88, Vector3(-0.24, -0.90, 0.36)],
			[0.975, Vector3(-0.24, -0.95, 0.18)],
		], t)
		var r_elbow_pole := _eval_dir_curve([
			[0.03, Vector3(-0.38, -0.78, -0.50)],   # Elbow stays LOW & relaxed (zero crane wing!)
			[0.18, Vector3(-0.38, -0.80, -0.46)],   # Low-back tucked fighter's draw-back
			[0.32, Vector3(-0.42, -0.76, -0.50)],   # Low cocked rear elbow powering the loaded fist!
			[0.40, Vector3(-0.80, -0.36, -0.48)],   # Wide haymaker sweep elbow
			[0.455, Vector3(-0.78, -0.48, -0.40)],  # Powerful horizontal-down strike elbow
			[0.56, Vector3(-0.38, -0.84, -0.38)],   # Natural open follow-through elbow drop
			[0.76, Vector3(-0.46, -0.76, -0.46)],   # Smooth relaxed retraction
			[0.88, Vector3(-0.45, -0.70, -0.55)],   # Relaxed natural descent clearing bag
			[0.975, Vector3(-0.45, -0.72, -0.52)],
		], t)
		_solve_arm_ik(_arm_r, r_palm_target, r_elbow_pole, r_palm_normal, r_finger_dir, r_ik_w)

	# --- 8. Clenched Boxing Fists -> Smooth Idle Hand Relaxation ---
	var r_fist_env := _bell(t, 0.04, 0.14, 0.72, 0.92)
	var l_fist_env := _bell(t, 0.06, 0.18, 0.68, 0.88)
	_pose_hand_expressive("R", lerpf(0.32, 1.24, r_fist_env), 0.0, 0.0, r_fist_env, 0.0)
	_pose_hand_expressive("L", lerpf(0.32, 1.06, l_fist_env), 0.0, 0.0, l_fist_env * 0.85, 0.0)

	# --- 9. Peak Impact Event & Hair/Flinch Impulse ---
	if t >= PUNCH_IMPACT_TIME and not _punch_impact_emitted:
		_punch_impact_emitted = true
		_trigger_impact_impulse(0.74)
		_hair_rot_vel += 2.4
		_impact_flinch = 0.72


func _sit_crush_pose(t: float, dt: float) -> bool:
	# Normalized timeline t in [0.0, 1.0] (4.80s default):
	# 0.00..0.30: Look down at ground -> stagger-step feet wide with toes out -> slow invisible-chair
	#             squat with straight back & arms spread wide for balance + poised pre-drop beat.
	# 0.30..0.44: Fast, heavy gravity-accelerating drop (impact at t=0.375) -> legs fold wide to sides,
	#             knees splayed out, flat planted feet -> delayed spine compression, chin tuck, hair float-up & drop.
	# 0.44..0.67: Sustained heavy sit hold -> deliberate left-right weight rock to pack/flatten target -> settle center.
	# 0.67..1.00: Lean forward, plant both palms flat on ground -> push off with hands + drive legs up ->
	#             peel hands clear -> knees straighten slowly, feet step back in, spine unrolls upright to idle.

	var enter_t := 1.0 - _smoother(0.0, 0.055, t)
	var idle_tail := _smoother(0.92, 1.0, t)

	# --- 1. Core phase envelopes ---
	var squat_prep := _smoother(0.08, 0.27, t)
	var drop_u := clampf(inverse_lerp(SIT_CRUSH_DROP_START, SIT_CRUSH_IMPACT_TIME, t), 0.0, 1.0)
	var drop_slam := pow(drop_u, 2.35)
	var rise_u := _smoother(0.715, 0.945, t)
	var rise_curve := pow(rise_u, 1.38)
	# Total drop ~0.830 seats Jean shorts / buttocks firmly flush on Y=0.00 even from ground-level side view (zero gap!).
	var sit_depth := (0.280 * squat_prep + 0.550 * drop_slam) * (1.0 - rise_curve)
	var seated_w := _smoother(0.32, 0.375, t) * (1.0 - _smoother(0.70, 0.85, t))
	var impact_squash := _bell(t, 0.368, 0.398, 0.415, 0.465)
	var impact_press := _bell(t, 0.365, 0.408, 0.430, 0.510)
	var drop_freefall := _bell(t, 0.30, 0.355, 0.368, 0.395)

	# Deliberate left -> right -> steady-center seated weight rock ("重心左右晃一下，像在把底下的东西压实，再慢慢稳住").
	var rock_env := _bell(t, 0.44, 0.47, 0.60, 0.645)
	var rock_phase := clampf(inverse_lerp(0.45, 0.63, t), 0.0, 1.0)
	var rock_wave := sin(TAU * rock_phase) * rock_env

	# Breath & idle continuity at t=0 and t=1.
	var breath_sin := sin(_breath)
	var idle_blend := clampf((1.0 - _smoother(0.0, 0.06, t)) + idle_tail, 0.0, 1.0)
	var contra := (sin(_idle_look_time * 0.42 + 0.5) * 0.72 + sin(_idle_look_time * 0.19) * 0.28) * idle_blend
	var idle_sway_x := contra * 0.014
	var breath_y := breath_sin * (0.0042 * idle_blend + 0.0016 * (1.0 - idle_blend))

	# --- 2. Footwork & Legs (Balanced wide chair-squat -> locked flat feet with toes out -> clean step back in!) ---
	# Feet step wide (+-0.235) and forward (+0.235) so CoM balances squarely over feet in chair-squat,
	# AND hips drop cleanly down-and-back behind heels into full sit so knees ALWAYS fold forward-and-outward!
	var l_wide := Vector3(0.235, _left.ankle_rest.y, 0.235)
	var r_wide := Vector3(-0.235, _right.ankle_rest.y, 0.235)

	var l_out_u := clampf(inverse_lerp(0.04, 0.15, t), 0.0, 1.0)
	var r_out_u := clampf(inverse_lerp(0.11, 0.22, t), 0.0, 1.0)
	var r_back_u := clampf(inverse_lerp(0.86, 0.935, t), 0.0, 1.0)
	var l_back_u := clampf(inverse_lerp(0.91, 0.985, t), 0.0, 1.0)

	var l_stance := _smoother(0.04, 0.15, t) * (1.0 - _smoother(0.91, 0.985, t))
	var r_stance := _smoother(0.11, 0.22, t) * (1.0 - _smoother(0.86, 0.935, t))
	var l_lift_out := sin(PI * l_out_u) if (t > 0.04 and t < 0.15) else 0.0
	var r_lift_out := sin(PI * r_out_u) if (t > 0.11 and t < 0.22) else 0.0
	var r_lift_back := sin(PI * r_back_u) if (t > 0.86 and t < 0.935) else 0.0
	var l_lift_back := sin(PI * l_back_u) if (t > 0.91 and t < 0.985) else 0.0
	var l_air := clampf(l_lift_out + l_lift_back, 0.0, 1.0)
	var r_air := clampf(r_lift_out + r_lift_back, 0.0, 1.0)

	var l_base := _left.ankle_rest.lerp(l_wide, l_stance)
	var r_base := _right.ankle_rest.lerp(r_wide, r_stance)
	_update_leg_ground(_left, l_base, 1.0 - l_air, dt)
	_update_leg_ground(_right, r_base, 1.0 - r_air, dt)

	_left_ankle = l_base + Vector3(0.0, 0.054 * l_lift_out + 0.050 * l_lift_back + _left.ground_y * (1.0 - l_air * 0.5), 0.0)
	_right_ankle = r_base + Vector3(0.0, 0.054 * r_lift_out + 0.050 * r_lift_back + _right.ground_y * (1.0 - r_air * 0.5), 0.0)

	# Flat soles & outward-pointed toes throughout squat, drop, sit-hold, and push-up!
	var l_pitch := 0.09 * l_lift_out + 0.10 * l_lift_back + _left.ground_pitch * (1.0 - l_air)
	var r_pitch := 0.09 * r_lift_out + 0.10 * r_lift_back + _right.ground_pitch * (1.0 - r_air)
	var l_roll := _left.ground_roll * (1.0 - l_air)
	var r_roll := _right.ground_roll * (1.0 - r_air)
	var l_yaw := lerpf(IDLE_FOOT_YAW, 0.54, l_stance)
	var r_yaw := lerpf(-IDLE_FOOT_YAW, -0.54, r_stance)
	var l_toe := 0.08 * l_lift_back * (1.0 - _smoother(0.95, 0.985, t))
	var r_toe := 0.08 * r_lift_back * (1.0 - _smoother(0.90, 0.935, t))

	# --- 3. Pelvis & Spine (Straight back in prep -> heavy impact press -> rock -> forward push-off -> slow unroll) ---
	var step_shift_x := -0.030 * l_lift_out + 0.030 * r_lift_out + 0.028 * r_lift_back - 0.028 * l_lift_back
	var ground_y := minf(_left.ground_y, _right.ground_y)
	var air_tuck := -0.022 * _air_weight * idle_blend

	# Chair-squat centers pelvis near rest (+0.012); fast sit-drop shifts buttocks down-and-back (-0.155)
	# behind planted heels so thighs angle FORWARD & OUTWARD (knee.z always well ahead of hip.z!).
	# During push-off, hips glide smoothly forward over feet as knees extend back to standing.
	var hip_sit_z := 0.012 * squat_prep - 0.168 * drop_slam
	var hip_push_fwd := 0.095 * _bell(t, 0.74, 0.83, 0.88, 0.955)
	var hip_z := (hip_sit_z * (1.0 - rise_curve)) + hip_push_fwd

	var hip := _hip_rest + Vector3(
		idle_sway_x + step_shift_x + 0.056 * rock_wave,
		-0.016 + breath_y + air_tuck - sit_depth - 0.008 * impact_squash - 0.006 * absf(rock_wave) + ground_y - _impact_jolt * 0.008,
		hip_z
	)

	# Vertebra-by-vertebra forward lean for hand push-off and slow unroll ("背一点点挺直").
	var prep_upright := _bell(t, 0.08, 0.24, 0.30, 0.38)
	var push_pelvis := _bell(t, 0.63, 0.70, 0.79, 0.90)
	var push_s1 := _bell(t, 0.63, 0.70, 0.80, 0.92)
	var push_s2 := _bell(t, 0.64, 0.71, 0.81, 0.945)
	var push_s3 := _bell(t, 0.65, 0.72, 0.83, 0.965)
	var push_s4 := _bell(t, 0.64, 0.71, 0.82, 0.955)

	var hip_pitch := (
		0.07 * prep_upright
		- 0.02 * seated_w
		+ 0.07 * impact_press
		+ 0.26 * push_pelvis
		+ _impact_jolt * 0.018
	)
	var hip_yaw := 0.085 * rock_wave + contra * 0.022
	var hip_roll := (
		-0.125 * rock_wave
		+ 0.030 * (l_lift_out - r_lift_out + l_lift_back - r_lift_back)
		+ contra * 0.022
	)
	var hip_rot := _pose("spine", hip_pitch, hip_yaw, hip_roll)
	_skeleton.set_bone_pose_position(_bone["spine"], hip)

	_pose("spine.001",
		0.02 * prep_upright + 0.04 * seated_w + 0.09 * impact_press + 0.26 * push_s1 + _impact_jolt * 0.015,
		-0.025 * rock_wave,
		0.045 * rock_wave - contra * 0.010)
	_pose("spine.002",
		0.01 * prep_upright + 0.05 * seated_w + 0.13 * impact_press + 0.30 * push_s2 + breath_sin * 0.013 * idle_blend,
		-0.038 * rock_wave,
		0.062 * rock_wave - contra * 0.012)
	_pose("spine.003",
		0.00 * prep_upright + 0.05 * seated_w + 0.14 * impact_press + 0.26 * push_s3 + breath_sin * 0.024 * idle_blend + _impact_jolt * 0.018,
		-0.038 * rock_wave,
		0.052 * rock_wave - contra * 0.008)
	_pose("spine.004",
		-0.02 * prep_upright - 0.02 * seated_w - 0.04 * impact_press - 0.17 * push_s4 - breath_sin * 0.012 * idle_blend,
		0.015 * rock_wave,
		-0.020 * rock_wave)

	# --- 4. Head, Chin Tuck & Gaze (Spot ground -> chin tuck on slam -> calm seated glance -> rise last) ---
	var spot_down := _bell(t, 0.015, 0.09, 0.25, 0.345)
	var chin_tuck := _bell(t, 0.355, 0.398, 0.435, 0.52)
	var seated_look := _bell(t, 0.42, 0.50, 0.62, 0.70)
	var push_head_counter := _bell(t, 0.64, 0.71, 0.81, 0.945)
	var tail_look_down := _bell(t, 0.84, 0.90, 0.93, 0.985)

	var head_pitch := (
		0.34 * spot_down
		+ 0.22 * chin_tuck
		+ 0.18 * seated_look
		- 0.60 * push_head_counter
		+ 0.08 * tail_look_down
		- breath_sin * 0.014 * idle_blend
		+ _head_idle_gaze.y * idle_blend
		- _impact_jolt * 0.020
	)
	var head_yaw := 0.08 * rock_wave + _head_idle_gaze.x * idle_blend
	var head_roll := -0.070 * rock_wave - contra * 0.015
	_pose("Neck", head_pitch * 0.44, head_yaw * 0.44, head_roll * 0.42)
	_pose("Head", head_pitch * 0.56, head_yaw * 0.56, head_roll * 0.58)

	# Facial targets (consumed by _update_face).
	_sit_crush_eye_override = 1.0 - idle_tail
	var eye_down := (
		0.105 * spot_down
		+ 0.080 * chin_tuck
		+ 0.072 * seated_look
		+ 0.045 * push_head_counter
	)
	var eye_yaw := clampf(0.055 * rock_wave, -0.09, 0.09)
	_sit_crush_eye_target = Vector2(eye_yaw, clampf(eye_down, -0.04, 0.105))
	_sit_crush_brow_target = clampf(
		0.36 * _bell(t, 0.06, 0.22, 0.32, 0.46)
		+ 0.52 * _bell(t, 0.35, 0.39, 0.44, 0.52)
		+ 0.44 * _bell(t, 0.66, 0.74, 0.82, 0.90),
		0.0, 1.0
	)
	_sit_crush_squint = 0.20 * impact_squash + 0.10 * _bell(t, 0.70, 0.75, 0.80, 0.86)

	# Hair upward float during rapid drop & impact, then drifting gracefully back down ("头发往上飘一下再落回来").
	_sit_crush_hair_float = _bell(t, 0.302, 0.378, 0.398, 0.515)

	# --- 5. Shoulders & Default Idle FK Arm Base ---
	var breath_shrug := breath_sin * 0.020 * idle_blend - _impact_jolt * 0.022
	var wing_phase := _bell(t, 0.08, 0.22, 0.36, 0.52)
	var push_sh := _bell(t, 0.64, 0.71, 0.80, 0.87)
	_pose_local("shoulder.L", breath_shrug + 0.06 * wing_phase + 0.08 * drop_freefall - 0.11 * impact_press - 0.18 * push_sh, 0.0, -0.05 * wing_phase + 0.22 * push_sh)
	_pose_local("shoulder.R", breath_shrug + 0.06 * wing_phase + 0.08 * drop_freefall - 0.11 * impact_press - 0.18 * push_sh, 0.0, 0.05 * wing_phase - 0.22 * push_sh)

	var arm_breath_out := breath_sin * 0.015 * idle_blend
	var r_bag_clear := _bell(t, 0.005, 0.045, 0.10, 0.16) + _bell(t, 0.86, 0.91, 0.96, 0.995)
	_pose("upper_arm.L", 0.02, -0.05, -0.44 + arm_breath_out + contra * 0.015)
	_pose("upper_arm.R", 0.03 - 0.08 * r_bag_clear, 0.06, 0.29 - arm_breath_out - 0.24 * r_bag_clear + contra * 0.015)
	_pose_local("forearm.L", 0.17, 0.0, 0.0)
	_pose_local("forearm.R", 0.18 + 0.06 * r_bag_clear, 0.0, 0.0)
	_pose_local("hand.L", 0.06, 0.14, -0.22)
	_pose_local("hand.R", 0.06, -0.14, 0.22)

	# Smooth entry blend from pre-action snapshot so frame 0 has zero snap.
	if enter_t > 0.001:
		hip = hip.lerp(_snap_hip, enter_t)
		_skeleton.set_bone_pose_position(_bone["spine"], hip)
		hip_rot = _blend_core_from_snapshot(enter_t)
		_left_ankle = _left_ankle.lerp(_left_at_sit, enter_t)
		_right_ankle = _right_ankle.lerp(_right_at_sit, enter_t)
		l_pitch = lerpf(l_pitch, _snap_left_foot.x, enter_t)
		l_roll = lerpf(l_roll, _snap_left_foot.y, enter_t)
		l_yaw = lerpf(l_yaw, _snap_left_foot.z, enter_t)
		l_toe = lerpf(l_toe, _snap_left_foot.w, enter_t)
		r_pitch = lerpf(r_pitch, _snap_right_foot.x, enter_t)
		r_roll = lerpf(r_roll, _snap_right_foot.y, enter_t)
		r_yaw = lerpf(r_yaw, _snap_right_foot.z, enter_t)
		r_toe = lerpf(r_toe, _snap_right_foot.w, enter_t)

	# Legs fold cleanly forward-and-outward: knees stay well ahead of hips & splayed wider than ankles!
	var deep_sit := clampf(inverse_lerp(0.32, 0.78, sit_depth), 0.0, 1.0)
	var knee_splay := 0.24 * squat_prep * (1.0 - rise_curve) + 0.42 * deep_sit
	var knee_pole_up := 0.96 * deep_sit
	_plant(_left, _left_ankle, hip, hip_rot, l_pitch, l_roll, l_yaw, l_toe, knee_splay, knee_pole_up)
	_plant(_right, _right_ankle, hip, hip_rot, r_pitch, r_roll, r_yaw, r_toe, knee_splay, knee_pole_up)

	# --- 6. Dual-Arm IK: Wide Balance Wings -> Drop Trail & Catch -> Clear Seated Rock -> Ground Push-Off -> Clear Return ---
	var arm_ik_w := _bell(t, 0.035, 0.115, 0.90, 0.975) * (1.0 - enter_t)
	if arm_ik_w > 0.001:
		var sh_l_pos := _skeleton.get_bone_global_pose(_arm_l.shoulder).origin
		var sh_r_pos := _skeleton.get_bone_global_pose(_arm_r.shoulder).origin

		# Shoulder-relative offset trajectory: wide graceful balance wings in prep/drop, kept clearly
		# OUTSIDE splayed knees during seated hold & rock (zero knee/thigh clipping!), then swinging forward to ground.
		var l_rel_keys := [
			[0.035, Vector3(0.205, -0.450, 0.040)],  # Relaxed idle start
			[0.12, Vector3(0.380, -0.265, 0.065)],   # Spreading arms cleanly out for balance
			[0.24, Vector3(0.455, -0.175, 0.070)],   # Wide poised balance wings!
			[0.30, Vector3(0.460, -0.165, 0.070)],   # Poised beat before drop
			[0.365, Vector3(0.475, -0.015, 0.040)],  # Arms trail UPWARD during fast gravity drop!
			[0.425, Vector3(0.465, -0.185, 0.025)],  # Heavy downward inertia catch cleanly outside/above knees!
			[0.50, Vector3(0.450, -0.205, 0.005)],   # Seated balance clearly outside splayed knees during rock!
			[0.59, Vector3(0.440, -0.215, 0.025)],
			[0.645, Vector3(0.270, -0.300, 0.215)],  # Sweeping forward inside knees to plant palms!
			[0.86, Vector3(0.310, -0.340, 0.190)],   # Clean outward sweep after peeling off ground
			[0.92, Vector3(0.290, -0.415, 0.105)],
			[0.975, Vector3(0.200, -0.455, 0.040)],
		]
		var r_rel_keys := [
			[0.035, Vector3(-0.275, -0.450, 0.055)], # Immediately clear of yellow bear bag!
			[0.12, Vector3(-0.400, -0.265, 0.070)],  # Sweeping wide outside bear bag
			[0.24, Vector3(-0.455, -0.175, 0.070)],  # Symmetric wide poised balance wings!
			[0.30, Vector3(-0.460, -0.165, 0.070)],
			[0.365, Vector3(-0.475, -0.015, 0.040)], # Upward trail during fast drop!
			[0.425, Vector3(-0.465, -0.185, 0.025)], # Heavy downward inertia catch cleanly outside/above knees!
			[0.50, Vector3(-0.450, -0.205, 0.005)],  # Seated balance clearly outside splayed knees!
			[0.59, Vector3(-0.440, -0.215, 0.025)],
			[0.645, Vector3(-0.270, -0.300, 0.215)], # Sweeping forward inside knees to plant palms!
			[0.86, Vector3(-0.350, -0.325, 0.190)],  # Wide arc clearing yellow bear bag on recovery!
			[0.92, Vector3(-0.325, -0.405, 0.110)],
			[0.975, Vector3(-0.265, -0.455, 0.055)],
		]

		var l_air_target := sh_l_pos + _eval_vec3_curve(l_rel_keys, t)
		var r_air_target := sh_r_pos + _eval_vec3_curve(r_rel_keys, t)
		# Counter-balance arm sway during left-right seated rock!
		l_air_target += Vector3(0.024 * rock_wave, -0.048 * rock_wave, 0.0)
		r_air_target += Vector3(0.024 * rock_wave, 0.048 * rock_wave, 0.0)
		# Prevent airborne balance hands from ever dipping into ground.
		l_air_target.y = maxf(l_air_target.y, ground_y + 0.09)
		r_air_target.y = maxf(r_air_target.y, ground_y + 0.09)

		# Exact ground-planted push-off palm targets (between wide knees & directly under shoulders, zero hand slip!).
		var ground_lock := _bell(t, 0.635, 0.690, 0.780, 0.840)
		var peel_lift := sin(PI * clampf(inverse_lerp(0.780, 0.845, t), 0.0, 1.0)) * 0.050
		var l_ground_palm := Vector3(0.135, ground_y + SIT_CRUSH_PALM_GROUND_Y + peel_lift, 0.235)
		var r_ground_palm := Vector3(-0.135, ground_y + SIT_CRUSH_PALM_GROUND_Y + peel_lift, 0.235)

		var l_palm_target := l_air_target.lerp(l_ground_palm, ground_lock)
		var r_palm_target := r_air_target.lerp(r_ground_palm, ground_lock)

		var l_palm_normal := _eval_dir_curve([
			[0.035, Vector3(-0.88, -0.36, 0.28)],
			[0.18, Vector3(-0.14, -0.94, 0.30)],   # Graceful open balance palm facing down & slightly forward
			[0.37, Vector3(-0.16, -0.95, 0.26)],
			[0.54, Vector3(-0.22, -0.94, 0.24)],
			[0.69, Vector3(0.0, -1.0, 0.0)],       # Flat palm planted straight down on ground!
			[0.79, Vector3(0.0, -1.0, 0.0)],       # Locked flat throughout push-off!
			[0.86, Vector3(-0.45, -0.82, -0.35)],
			[0.975, Vector3(-0.90, -0.32, 0.25)],
		], t)
		var r_palm_normal := _eval_dir_curve([
			[0.035, Vector3(0.88, -0.36, 0.28)],
			[0.18, Vector3(0.14, -0.94, 0.30)],
			[0.37, Vector3(0.16, -0.95, 0.26)],
			[0.54, Vector3(0.22, -0.94, 0.24)],
			[0.69, Vector3(0.0, -1.0, 0.0)],       # Flat palm planted straight down on ground!
			[0.79, Vector3(0.0, -1.0, 0.0)],       # Locked flat throughout push-off!
			[0.86, Vector3(0.45, -0.82, -0.35)],
			[0.975, Vector3(0.90, -0.32, 0.25)],
		], t)

		var l_finger_dir := _eval_dir_curve([
			[0.035, Vector3(0.24, -0.95, 0.18)],
			[0.18, Vector3(0.94, -0.10, 0.32)],    # Smooth continuous line from forearm to fingertips (zero wrist kink!)
			[0.37, Vector3(0.92, 0.08, 0.36)],     # Natural upward trail during drop
			[0.54, Vector3(0.88, -0.22, 0.42)],
			[0.69, Vector3(0.22, 0.0, 0.97)],      # Flat fingers pointing forward-outward on pavement!
			[0.79, Vector3(0.22, 0.0, 0.97)],
			[0.855, Vector3(0.22, -0.45, 0.86)],   # Peel wrist smoothly off ground
			[0.975, Vector3(0.24, -0.95, 0.18)],
		], t)
		var r_finger_dir := _eval_dir_curve([
			[0.035, Vector3(-0.24, -0.95, 0.18)],
			[0.18, Vector3(-0.94, -0.10, 0.32)],
			[0.37, Vector3(-0.92, 0.08, 0.36)],
			[0.54, Vector3(-0.88, -0.22, 0.42)],
			[0.69, Vector3(-0.22, 0.0, 0.97)],     # Flat fingers pointing forward-outward on pavement!
			[0.79, Vector3(-0.22, 0.0, 0.97)],
			[0.855, Vector3(-0.22, -0.45, 0.86)],
			[0.975, Vector3(-0.24, -0.95, 0.18)],
		], t)

		var l_elbow_pole := _eval_dir_curve([
			[0.035, Vector3(0.45, -0.68, -0.58)],
			[0.24, Vector3(0.18, -0.58, -0.79)],   # Smooth athletic balance elbow line
			[0.42, Vector3(0.24, -0.64, -0.73)],
			[0.69, Vector3(0.44, 0.14, -0.88)],    # Elbows point backward & slightly out during ground push-off!
			[0.79, Vector3(0.42, 0.10, -0.90)],
			[0.88, Vector3(0.58, -0.55, -0.60)],
			[0.975, Vector3(0.45, -0.68, -0.58)],
		], t)
		var r_elbow_pole := _eval_dir_curve([
			[0.035, Vector3(-0.45, -0.68, -0.58)],
			[0.24, Vector3(-0.18, -0.58, -0.79)],
			[0.42, Vector3(-0.24, -0.64, -0.73)],
			[0.69, Vector3(-0.44, 0.14, -0.88)],   # Elbows point backward & slightly out during ground push-off!
			[0.79, Vector3(-0.42, 0.10, -0.90)],
			[0.88, Vector3(-0.72, -0.45, -0.52)],  # Clear bear bag on return!
			[0.975, Vector3(-0.45, -0.68, -0.58)],
		], t)

		_solve_arm_ik(_arm_l, l_palm_target, l_elbow_pole, l_palm_normal, l_finger_dir, arm_ik_w)
		_solve_arm_ik(_arm_r, r_palm_target, r_elbow_pole, r_palm_normal, r_finger_dir, arm_ik_w)

	# --- 7. Expressive Hand & Finger Pose (Open balance hands -> flat ground-push palms -> idle) ---
	var wing_open := _bell(t, 0.08, 0.20, 0.42, 0.56)
	var ground_flat := _bell(t, 0.64, 0.69, 0.805, 0.855)
	var hand_curl := 0.32
	hand_curl = lerpf(hand_curl, 0.04, wing_open)
	hand_curl = lerpf(hand_curl, -0.12, ground_flat)
	var hand_splay := 0.20 * wing_open + 0.24 * ground_flat
	var thumb_open := 0.55 * wing_open + 0.88 * ground_flat
	_pose_hand_expressive("L", hand_curl, hand_splay, 0.0, 0.0, thumb_open)
	_pose_hand_expressive("R", hand_curl, hand_splay, 0.0, 0.0, thumb_open)

	# Smooth handoff when resuming stand-up (t >= 0.65) directly from seated idle:
	# blend pelvis & upper-body/arms AFTER arm IK so hands glide smoothly off knees onto the ground!
	if _sit_crush_from_idle_blend > 0.001:
		var bt := smoothstep(0.0, 1.0, _sit_crush_from_idle_blend)
		hip = hip.lerp(_snap_hip, bt)
		_skeleton.set_bone_pose_position(_bone["spine"], hip)
		hip_rot = _blend_core_from_snapshot(bt)
		_left_ankle = _left_ankle.lerp(_left_at_sit, bt)
		_right_ankle = _right_ankle.lerp(_right_at_sit, bt)
		_plant(_left, _left_ankle, hip, hip_rot,
			lerpf(l_pitch, _snap_left_foot.x, bt), lerpf(l_roll, _snap_left_foot.y, bt),
			lerpf(l_yaw, _snap_left_foot.z, bt), lerpf(l_toe, _snap_left_foot.w, bt), knee_splay, knee_pole_up)
		_plant(_right, _right_ankle, hip, hip_rot,
			lerpf(r_pitch, _snap_right_foot.x, bt), lerpf(r_roll, _snap_right_foot.y, bt),
			lerpf(r_yaw, _snap_right_foot.z, bt), lerpf(r_toe, _snap_right_foot.w, bt), knee_splay, knee_pole_up)

	# --- 8. Impact Event Trigger (Heavy Ground Slam + Upward Hair Billow + Impact Reflex) ---
	var impact_just_hit := false
	if t >= SIT_CRUSH_IMPACT_TIME and not _sit_crush_impact_emitted:
		_sit_crush_impact_emitted = true
		impact_just_hit = true
		_trigger_impact_impulse(1.15)
		_hair_bounce_vel += 4.6
		_hair_sway_vel.y -= 1.8
		_impact_flinch = 1.0
	return impact_just_hit


func _sit_idle_pose(dt: float) -> void:
	# Living seated idle after sitting down:
	# - Buttocks stay firmly grounded on Y=0, wide flat feet locked with toes turned out, knees forward & splayed.
	# - Both palms rest naturally & relaxed on top of her wide knees (riding smoothly with subtle knee/hip sway).
	# - Calm deep giant breathing, slow two-harmonic contrapposto seated weight shift, and natural look-around
	#   with periodic curious downward glances at the crushed space between her feet.
	var breath_sin := sin(_breath)
	var breath_chest := sin(_breath - 0.35)
	var sway := sin(_sit_idle_time * 0.42 + 0.4) * 0.68 + sin(_sit_idle_time * 0.21) * 0.32
	var sway_slow := sin(_sit_idle_time * 0.28 + 1.1)

	# 1. Wide flat-planted feet (exact match to sit-crush settled stance, zero foot slip!).
	var l_wide := Vector3(0.235, _left.ankle_rest.y, 0.235)
	var r_wide := Vector3(-0.235, _right.ankle_rest.y, 0.235)
	_update_leg_ground(_left, l_wide, 1.0, dt)
	_update_leg_ground(_right, r_wide, 1.0, dt)
	_left_ankle = l_wide + Vector3(0.0, _left.ground_y, 0.0)
	_right_ankle = r_wide + Vector3(0.0, _right.ground_y, 0.0)
	var l_pitch := _left.ground_pitch
	var r_pitch := _right.ground_pitch
	var l_roll := _left.ground_roll
	var r_roll := _right.ground_roll
	var l_yaw := 0.54
	var r_yaw := -0.54

	# 2. Grounded pelvis & relaxed poised seated spine with deep breathing and slow weight shift.
	var ground_y := minf(_left.ground_y, _right.ground_y)
	var hip := _hip_rest + Vector3(
		sway * 0.018,
		-0.016 - 0.830 + breath_sin * 0.0018 + ground_y - _impact_jolt * 0.008,
		-0.156 + sway_slow * 0.004
	)
	var hip_rot := _pose(
		"spine",
		-0.02 + breath_sin * 0.008 + _impact_jolt * 0.015,
		sway * 0.032,
		-sway * 0.036
	)
	_skeleton.set_bone_pose_position(_bone["spine"], hip)

	_pose("spine.001", 0.045 + breath_sin * 0.010 + _impact_jolt * 0.012, -sway * 0.012, sway * 0.016)
	_pose("spine.002", 0.060 + breath_chest * 0.018, -sway * 0.018, sway * 0.022)
	_pose("spine.003", 0.055 + breath_chest * 0.026 + _impact_jolt * 0.014, -sway * 0.016, sway * 0.018)
	_pose("spine.004", -0.025 - breath_chest * 0.014, sway * 0.008, -sway * 0.008)

	# 3. Head & gaze: calm horizon look-around mixed with periodic curious downward glances at the crushed zone.
	var glance_down := smoothstep(0.35, 0.92, sin(_sit_idle_time * 0.36 + 0.8))
	var head_pitch := 0.12 + 0.16 * glance_down - breath_chest * 0.016 + _head_idle_gaze.y * 1.15 - _impact_jolt * 0.018
	var head_yaw := _head_idle_gaze.x * 1.35 + sin(_sit_idle_time * 0.23) * 0.075
	var head_roll := -sway * 0.028 + sin(_sit_idle_time * 0.31 + 0.6) * 0.035
	_pose("Neck", head_pitch * 0.44, head_yaw * 0.44, head_roll * 0.42)
	_pose("Head", head_pitch * 0.56, head_yaw * 0.56, head_roll * 0.58)
	_sit_idle_eye_bias = Vector2(sin(_sit_idle_time * 0.23) * 0.020, 0.028 + 0.052 * glance_down)

	# 4. Relaxed seated shoulders & legs (solve legs BEFORE arm IK so hands track exact live knee tops!).
	var breath_shrug := breath_chest * 0.022 - _impact_jolt * 0.018
	_pose_local("shoulder.L", breath_shrug - 0.03, 0.0, 0.05 + sway * 0.015)
	_pose_local("shoulder.R", breath_shrug - 0.03, 0.0, -0.05 + sway * 0.015)

	_pose("upper_arm.L", 0.02, -0.05, -0.44)
	_pose("upper_arm.R", 0.03, 0.06, 0.29)
	_pose_local("forearm.L", 0.17, 0.0, 0.0)
	_pose_local("forearm.R", 0.18, 0.0, 0.0)
	_pose_local("hand.L", 0.06, 0.14, -0.22)
	_pose_local("hand.R", 0.06, -0.14, 0.22)

	var knee_splay := 0.42 + breath_sin * 0.012 + sway_slow * 0.010
	var knee_pole_up := 0.96
	_plant(_left, _left_ankle, hip, hip_rot, l_pitch, l_roll, l_yaw, 0.0, knee_splay, knee_pole_up)
	_plant(_right, _right_ankle, hip, hip_rot, r_pitch, r_roll, r_yaw, 0.0, knee_splay, knee_pole_up)

	# 5. Dual-Arm IK: Wrists/palms resting firmly on the front-top of her splayed knees
	# (relaxed elbows hanging naturally down, fingers draping smoothly over upper shins, zero floating!).
	var l_knee_pos := _skeleton.get_bone_global_pose(_left.shin).origin
	var r_knee_pos := _skeleton.get_bone_global_pose(_right.shin).origin
	var l_palm_target := l_knee_pos + Vector3(0.006, 0.014 + breath_chest * 0.002, 0.052)
	var r_palm_target := r_knee_pos + Vector3(-0.006, 0.014 + breath_chest * 0.002, 0.052)
	var l_palm_normal := Vector3(-0.20, -0.78, -0.59).normalized()
	var r_palm_normal := Vector3(0.20, -0.78, -0.59).normalized()
	var l_finger_dir := Vector3(0.06, -0.60, 0.79).normalized()
	var r_finger_dir := Vector3(-0.06, -0.60, 0.79).normalized()
	var l_elbow_pole := Vector3(0.42, -0.84, -0.34).normalized()
	var r_elbow_pole := Vector3(-0.42, -0.84, -0.34).normalized()
	_solve_arm_ik(_arm_l, l_palm_target, l_elbow_pole, l_palm_normal, l_finger_dir, 1.0)
	_solve_arm_ik(_arm_r, r_palm_target, r_elbow_pole, r_palm_normal, r_finger_dir, 1.0)

	# Soft relaxed curved fingers resting comfortably over knees with subtle idle breath.
	var f_curl := 0.34 + sin(_sit_idle_time * 0.65) * 0.035
	_pose_fingers("L", f_curl)
	_pose_fingers("R", f_curl + 0.015 * sin(_sit_idle_time * 0.65 + 0.9))

	# 6. Smooth entry blend from pre-sit-idle snapshot (e.g., gliding arms from sit-crush balance wings onto knees!).
	if _sit_idle_enter_blend > 0.001:
		var bt := smoothstep(0.0, 1.0, _sit_idle_enter_blend)
		hip = hip.lerp(_snap_hip, bt)
		_skeleton.set_bone_pose_position(_bone["spine"], hip)
		hip_rot = _blend_core_from_snapshot(bt)
		_left_ankle = _left_ankle.lerp(_left_at_sit_idle, bt)
		_right_ankle = _right_ankle.lerp(_right_at_sit_idle, bt)
		_plant(_left, _left_ankle, hip, hip_rot,
			lerpf(l_pitch, _snap_left_foot.x, bt), lerpf(l_roll, _snap_left_foot.y, bt),
			lerpf(l_yaw, _snap_left_foot.z, bt), lerpf(0.0, _snap_left_foot.w, bt), knee_splay, knee_pole_up)
		_plant(_right, _right_ankle, hip, hip_rot,
			lerpf(r_pitch, _snap_right_foot.x, bt), lerpf(r_roll, _snap_right_foot.y, bt),
			lerpf(r_yaw, _snap_right_foot.z, bt), lerpf(0.0, _snap_right_foot.w, bt), knee_splay, knee_pole_up)


func _make_arm(side: String) -> Arm:
	var arm := Arm.new()
	arm.side = side
	arm.sign_x = 1.0 if side == "L" else -1.0
	arm.shoulder = _skeleton.find_bone("shoulder." + side)
	arm.upper = _skeleton.find_bone("upper_arm." + side)
	arm.forearm = _skeleton.find_bone("forearm." + side)
	arm.hand = _skeleton.find_bone("hand." + side)
	arm.upper_offset = _skeleton.get_bone_pose_position(arm.upper)
	arm.upper_length = _skeleton.get_bone_pose_position(arm.forearm).length()
	arm.lower_length = _skeleton.get_bone_pose_position(arm.hand).length()
	arm.upper_rest = _skeleton.get_bone_pose_rotation(arm.upper)
	arm.forearm_rest = _skeleton.get_bone_pose_rotation(arm.forearm)
	arm.hand_rest = _skeleton.get_bone_pose_rotation(arm.hand)
	arm.palm_offset = PALM_GRASP_OFFSET_L if side == "L" else PALM_GRASP_OFFSET_R
	return arm


func _solve_arm_ik(arm: Arm, palm_target: Vector3, elbow_pole: Vector3,
		palm_normal: Vector3, finger_dir: Vector3, weight: float) -> void:
	if weight <= 0.0001:
		return
	var shoulder_pose := _skeleton.get_bone_global_pose(arm.shoulder)
	var shoulder_rot := shoulder_pose.basis.orthonormalized().get_rotation_quaternion()
	var socket := shoulder_pose * arm.upper_offset

	# Build target hand basis in skeleton space: +Y=fingers, +/-X=palm normal, +Z=radial/thumb.
	var hy := finger_dir.normalized()
	var hx_raw := palm_normal if arm.side == "L" else -palm_normal
	var hx := hx_raw - hy * hy.dot(hx_raw)
	if hx.length_squared() < 0.0001:
		hx = Vector3.RIGHT if arm.side == "L" else Vector3.LEFT
	else:
		hx = hx.normalized()
	var hz := hx.cross(hy).normalized()
	hx = hy.cross(hz).normalized()
	var hand_basis := Basis(hx, hy, hz)
	var hand_world := hand_basis.get_rotation_quaternion()

	# Convert desired palm pocket position back to wrist (hand bone origin).
	var wrist_target := palm_target - hand_basis * arm.palm_offset

	var arm_vec := wrist_target - socket
	var raw_len := arm_vec.length()
	var axis := arm_vec / maxf(raw_len, 0.0001)
	var max_reach := arm.upper_length + arm.lower_length - 0.003
	var soft_start := max_reach * 0.965
	var reach := raw_len
	if raw_len > soft_start:
		var excess := raw_len - soft_start
		var span := max_reach - soft_start
		reach = soft_start + span * (1.0 - exp(-excess / span))
	reach = clampf(reach, 0.08, max_reach)

	var pole := elbow_pole - axis * axis.dot(elbow_pole)
	if pole.length_squared() < 0.0001:
		pole = Vector3(-arm.sign_x, 0.0, -1.0).normalized()
	else:
		pole = pole.normalized()

	var along := (reach * reach + arm.upper_length * arm.upper_length - arm.lower_length * arm.lower_length) / (2.0 * reach)
	var perp := sqrt(maxf(0.0, arm.upper_length * arm.upper_length - along * along))
	var elbow := socket + axis * along + pole * perp

	# Align upper_arm (+Y along humerus, +Z toward inner elbow crease = -pole).
	var ua_dir := (elbow - socket).normalized()
	var ua_base := shoulder_rot * arm.upper_rest
	var ua_swing := Quaternion(ua_base * Vector3.UP, ua_dir) * ua_base
	var ua_world := _align_arm_twist(ua_swing, ua_dir, -pole)

	# Align forearm (+Y along forearm, +Z toward -pole), then share 65% of pronation/supination twist.
	var fa_dir := (socket + axis * reach - elbow).normalized()
	var fa_base := ua_world * arm.forearm_rest
	var fa_swing := Quaternion(fa_base * Vector3.UP, fa_dir) * fa_base
	var fa_neutral := _align_arm_twist(fa_swing, fa_dir, -pole)

	var neutral_palm := (fa_neutral * Vector3.RIGHT) * arm.sign_x
	var cur_p := neutral_palm - fa_dir * fa_dir.dot(neutral_palm)
	var des_p := palm_normal - fa_dir * fa_dir.dot(palm_normal)
	var fa_world := fa_neutral
	if cur_p.length_squared() > 0.0001 and des_p.length_squared() > 0.0001:
		cur_p = cur_p.normalized()
		des_p = des_p.normalized()
		var pronate := atan2(fa_dir.dot(cur_p.cross(des_p)), cur_p.dot(des_p))
		pronate = clampf(pronate, -1.55, 1.55)
		fa_world = Quaternion(fa_dir, pronate * 0.65) * fa_neutral

	var ua_local := shoulder_rot.inverse() * ua_world
	var fa_local := ua_world.inverse() * fa_world
	var ha_local := fa_world.inverse() * hand_world

	if weight >= 0.999:
		_skeleton.set_bone_pose_rotation(arm.upper, ua_local)
		_skeleton.set_bone_pose_rotation(arm.forearm, fa_local)
		_skeleton.set_bone_pose_rotation(arm.hand, ha_local)
	else:
		_skeleton.set_bone_pose_rotation(arm.upper, _skeleton.get_bone_pose_rotation(arm.upper).slerp(ua_local, weight))
		_skeleton.set_bone_pose_rotation(arm.forearm, _skeleton.get_bone_pose_rotation(arm.forearm).slerp(fa_local, weight))
		_skeleton.set_bone_pose_rotation(arm.hand, _skeleton.get_bone_pose_rotation(arm.hand).slerp(ha_local, weight))


func _align_arm_twist(q: Quaternion, limb_dir: Vector3, inner_crease: Vector3) -> Quaternion:
	# Both upper_arm and forearm have local +Z pointing out the anterior (inner elbow crease) side.
	var cur_front := q * Vector3.BACK
	cur_front = cur_front - limb_dir * limb_dir.dot(cur_front)
	var desired_front := inner_crease - limb_dir * limb_dir.dot(inner_crease)
	if cur_front.length_squared() < 0.0001 or desired_front.length_squared() < 0.0001:
		return q
	cur_front = cur_front.normalized()
	desired_front = desired_front.normalized()
	var twist := atan2(limb_dir.dot(cur_front.cross(desired_front)), cur_front.dot(desired_front))
	return Quaternion(limb_dir, twist) * q


func _pose_hand_expressive(side: String, curl: float, splay: float,
		thumb_oppose: float, thumb_clench: float, thumb_open: float) -> void:
	var list: Array = _finger_bones.get(side, [])
	# Splay offsets for index, middle, ring, pinky (on R: -Z spreads toward thumb, +Z toward pinky).
	var splay_weights: Array[float] = [-1.0, -0.15, 0.55, 1.15]
	var finger_stagger: Array[float] = [0.92, 0.98, 1.05, 1.12]
	var seg_curl_scale: Array[float] = [0.85, 1.12, 0.82]
	var opp_x_arr: Array[float] = [0.22, 0.18, 0.16]
	var opp_z_arr: Array[float] = [-0.22, -0.12, 0.0]
	var cln_x_arr: Array[float] = [0.76, 0.52, 0.38]
	var cln_z_arr: Array[float] = [-0.22, -0.04, 0.0]
	var opn_x_arr: Array[float] = [-0.20, -0.08, -0.04]
	var opn_z_arr: Array[float] = [0.14, 0.06, 0.0]
	for item in list:
		var idx: int = item["idx"]
		var rest: Quaternion = item["rest"]
		var s: float = item["sign"]
		var si: int = item.get("si", 0)
		if item["thumb"]:
			# Blend cleanly between idle curl, wide open, opposing C-grasp, and clenched power fist!
			var idle_w: float = item["weight"]
			var idle_x := -curl * idle_w * 0.25
			var idle_z := s * curl * idle_w * 0.75
			# Verified on hand.R local axes: +X swings thumb across palm, -Z opposes outward in front of palm.
			var opp_x: float = opp_x_arr[si]
			var opp_z: float = opp_z_arr[si] * (-s)
			var cln_x: float = cln_x_arr[si]
			var cln_z: float = cln_z_arr[si] * (-s)
			var opn_x: float = opn_x_arr[si]
			var opn_z: float = opn_z_arr[si] * (-s)

			var active_w := clampf(thumb_oppose + thumb_clench + thumb_open, 0.0, 1.0)
			var tx := lerpf(idle_x, opp_x * thumb_oppose + cln_x * thumb_clench + opn_x * thumb_open, active_w)
			var tz := lerpf(idle_z, opp_z * thumb_oppose + cln_z * thumb_clench + opn_z * thumb_open, active_w)
			var rot := Quaternion(Vector3.BACK, tz) * Quaternion(Vector3.RIGHT, tx)
			_skeleton.set_bone_pose_rotation(idx, rest * rot)
		else:
			var fi: int = item.get("fi", 0)
			var base_w: float = item["weight"]
			# Smoothly blend from standard idle weight curve to deep C-curl / fist curve when gripping/crushing.
			var grip_blend := clampf(thumb_oppose + thumb_clench, 0.0, 1.0)
			var angle_idle := curl * base_w * 0.95
			var angle_grip := curl * finger_stagger[fi] * seg_curl_scale[si]
			var bend := lerpf(angle_idle, angle_grip, grip_blend)
			var spread: float = (splay * splay_weights[fi] * (-s)) if si == 0 else 0.0
			var rot := Quaternion(Vector3.BACK, spread) * Quaternion(Vector3.RIGHT, bend)
			_skeleton.set_bone_pose_rotation(idx, rest * rot)


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
	return leg


func _configure_soles() -> void:
	match skin_name:
		&"Hina":
			_set_sole(_left, Vector2(-0.00439, -0.05249), Vector2(0.04299, 0.11174),
					HINA_SOLE_L, Vector3(0.004431, 0.107319, 0.059587))
			_set_sole(_right, Vector2(0.00776, -0.05771), Vector2(0.04481, 0.11239),
					HINA_SOLE_R, Vector3(0.001811, 0.107269, 0.061577))
		&"Chibi Catgirl":
			_set_sole(_left, Vector2(0.00232, -0.05770), Vector2(0.06916, 0.10712),
					CHIBI_SOLE, Vector3(0.053673, 0.252530, 0.155612))
			_set_sole(_right, Vector2(-0.00112, -0.05898), Vector2(0.06962, 0.10730),
					_mirror_sole(CHIBI_SOLE), Vector3(-0.047441, 0.246573, 0.151885))
		&"Snow Fox":
			_set_sole(_left, Vector2(-0.00345, -0.06277), Vector2(0.03903, 0.10355),
					SNOW_FOX_SOLE, Vector3(0.002914, -0.076119, 0.053432))
			_set_sole(_right, Vector2(0.00345, -0.06270), Vector2(0.03903, 0.10362),
					_mirror_sole(SNOW_FOX_SOLE), Vector3(-0.002914, -0.076119, 0.053372))
		_:
			_set_sole(_left, Vector2(0.01038, -0.06827), Vector2(0.04747, 0.09271), KAWAII_SOLE)
			_set_sole(_right, Vector2(-0.01038, -0.06826), Vector2(0.04747, 0.09272), _mirror_sole(KAWAII_SOLE))


func _set_sole(leg: Leg, offset: Vector2, half_extents: Vector2, outline: Array[Vector2],
		skin_center := Vector3.ZERO) -> void:
	leg.sole_offset = Vector3(offset.x, -ANKLE_GROUND_Y, offset.y)
	leg.skin_sole_center = skin_center
	leg.sole_half_extents = half_extents
	leg.sole_profile = PackedVector2Array(outline)


static func _mirror_sole(outline: Array[Vector2]) -> Array[Vector2]:
	var mirrored: Array[Vector2] = []
	for i in range(outline.size() - 1, -1, -1):
		mirrored.append(Vector2(-outline[i].x, outline[i].y))
	return mirrored


func _source_sole_world(leg: Leg, source_pose: Transform3D) -> Vector3:
	var offset := Vector3(-leg.sole_offset.x, leg.sole_offset.y, -leg.sole_offset.z)
	return _skeleton.to_global(source_pose * (leg.foot_basis.inverse() * offset))


func _pin_skin_feet() -> void:
	_active_skin.pin_soles(_left.foot, _left.skin_sole_center,
			_source_sole_world(_left, _skeleton.get_bone_global_pose(_left.foot)),
			_right.foot, _right.skin_sole_center,
			_source_sole_world(_right, _skeleton.get_bone_global_pose(_right.foot)))


func _sole_payload(leg: Leg, center: Vector3, yaw: float) -> Dictionary:
	return {
		"center": center,
		"yaw": yaw,
		"half_extents": leg.sole_half_extents * _model.scale.z,
		"profile": leg.sole_profile,
		"left": leg.sign_x > 0.0,
	}


func _foot_contact(leg: Leg) -> Dictionary:
	var pose := _skeleton.get_bone_global_pose(leg.foot)
	var center := _source_sole_world(leg, pose)
	var forward := _skeleton.global_basis * (pose.basis * (leg.foot_basis.inverse() * Vector3.BACK))
	center.y = _foot_ground_height(center)
	return _sole_payload(leg, center, _dir_to_yaw(forward))


func _foot_ground_height(center: Vector3) -> float:
	var space := get_world_3d().direct_space_state
	var reach := _model.scale.z * 0.4
	var query := PhysicsRayQueryParameters3D.create(
			Vector3(center.x, global_position.y + reach, center.z),
			Vector3(center.x, global_position.y - reach, center.z), collision_mask & 17)
	var hit := space.intersect_ray(query)
	return global_position.y if hit.is_empty() else (hit["position"] as Vector3).y


static func _max_hip_height(leg: Leg, ankle: Vector3, hip: Vector3, hip_rotation: Quaternion) -> float:
	var socket_offset := hip_rotation * leg.hip_socket
	var delta := ankle - (hip + socket_offset)
	var reach := (leg.upper_length + leg.lower_length - 0.002) * 0.992
	var height := sqrt(maxf(reach * reach - delta.x * delta.x - delta.z * delta.z, 0.0))
	return ankle.y + height - socket_offset.y


func _plant(leg: Leg, ankle: Vector3, hip: Vector3, hip_rotation: Quaternion,
		foot_pitch: float, foot_roll := 0.0, foot_yaw := 0.0, toe_bend := 0.0,
		knee_splay := 0.0, pole_up := 0.0) -> void:
	leg.last_pitch = foot_pitch
	leg.last_roll = foot_roll
	leg.last_yaw = foot_yaw
	leg.last_toe = toe_bend

	var socket := hip + hip_rotation * leg.hip_socket
	var leg_vector := ankle - socket
	var raw_len := leg_vector.length()
	var axis := leg_vector / maxf(raw_len, 0.0001)
	var max_reach := leg.upper_length + leg.lower_length - 0.002
	# Soft compression only in the final 0.8% of extension so flat-ground stance stays rock-solid.
	var soft_start := max_reach * 0.992
	var reach := raw_len
	if raw_len > soft_start:
		var excess := raw_len - soft_start
		var span := max_reach - soft_start
		reach = soft_start + span * (1.0 - exp(-excess / span))
	reach = clampf(reach, 0.08, max_reach)

	# Forward pole with natural outward knee tracking steered by foot yaw (and optional upward lift for deep sitting).
	var pole_yaw := leg.sign_x * (0.065 + knee_splay) + foot_yaw * 0.45
	var pole_dir := Vector3(sin(pole_yaw), pole_up, cos(pole_yaw)).normalized()
	var pole := (pole_dir - axis * axis.dot(pole_dir))
	if pole.length_squared() < 0.0001:
		pole = Vector3.BACK
	else:
		pole = pole.normalized()

	var along := (reach * reach + leg.upper_length ** 2 - leg.lower_length ** 2) / (2.0 * reach)
	var knee := socket + axis * along + pole * sqrt(maxf(0.0, leg.upper_length ** 2 - along ** 2))

	# Twist-controlled two-bone IK: align bone +Y to limb direction and bone -Z (patella) to the pole plane.
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
		# Local +X on toe.L and toe.R dorsiflexes the toes upward to stay flat on ground during push-off.
		_skeleton.set_bone_pose_rotation(leg.toe, leg.toe_rest * Quaternion(Vector3.RIGHT, clampf(toe_bend, -0.25, 0.65)))


func _align_limb_twist(q: Quaternion, limb_dir: Vector3, pole: Vector3) -> Quaternion:
	# Both thigh and shin have local -Z pointing out the front of the knee/shin at rest.
	var cur_front := -(q * Vector3.BACK)
	cur_front = cur_front - limb_dir * limb_dir.dot(cur_front)
	var desired_front := pole - limb_dir * limb_dir.dot(pole)
	if cur_front.length_squared() < 0.0001 or desired_front.length_squared() < 0.0001:
		return q
	cur_front = cur_front.normalized()
	desired_front = desired_front.normalized()
	var twist := atan2(limb_dir.dot(cur_front.cross(desired_front)), cur_front.dot(desired_front))
	return Quaternion(limb_dir, twist) * q


func _toe_pivot_ankle_delta(foot_pitch: float) -> Vector3:
	# Keeps the toe pivot fixed on the ground as the heel lifts by foot_pitch (+X rotation).
	var v := -TOE_OFFSET
	var rotated := Quaternion(Vector3.RIGHT, foot_pitch) * v
	return rotated - v


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
				# Ignore tiny sub-centimeter floor noise so flat street contact remains rock-solid.
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


func _capture_snapshot() -> void:
	_snap_hip = _skeleton.get_bone_pose_position(_bone["spine"])
	_snap_left_ankle = _left_ankle
	_snap_right_ankle = _right_ankle
	_snap_left_foot = Vector4(_left.last_pitch, _left.last_roll, _left.last_yaw, _left.last_toe)
	_snap_right_foot = Vector4(_right.last_pitch, _right.last_roll, _right.last_yaw, _right.last_toe)
	for key in CORE_BONES:
		_snap_rots[key] = _skeleton.get_bone_pose_rotation(_bone[key])


func _blend_core_from_snapshot(weight: float) -> Quaternion:
	for key in CORE_BONES:
		if not _snap_rots.has(key):
			continue
		var idx: int = _bone[key]
		var cur := _skeleton.get_bone_pose_rotation(idx)
		var prev: Quaternion = _snap_rots[key]
		_skeleton.set_bone_pose_rotation(idx, cur.slerp(prev, weight))
	return _skeleton.get_bone_pose_rotation(_bone["spine"])


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
						"fi": fi,
						"si": si,
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
					"fi": -1,
					"si": si,
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
			# Local +X curls all four fingers inward toward the palm on both L and R.
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


func _update_hair(dt: float, action_pose: bool) -> void:
	if _detail_tier >= 1:
		# Mid and far tiers skip the hair/tail spring chain entirely.
		return
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
		# Ignore teleports (e.g., round restart or test repositioning).
		if vel.length() > 45.0 * scale_norm:
			vel = Vector3.ZERO
			_prev_head_vel = Vector3.ZERO
		var accel := (vel - _prev_head_vel) / (dt * scale_norm)
		_prev_head_world = head_world
		_prev_head_vel = vel
		var inv_basis := _skeleton.global_basis.orthonormalized().inverse()
		head_accel_local = (inv_basis * accel).limit_length(24.0)

		# Primary root spring in skeleton space (+Z forward, +X left, +Y up).
		var target_sway := Vector2(
			clampf(-head_accel_local.x * 0.016, -0.36, 0.36),
			clampf(-head_accel_local.z * 0.018 - (_move_drive * 0.09 if not action_pose else 0.0), -0.40, 0.34)
		)
		var sway_acc := (target_sway - _hair_sway) * 46.0 - _hair_sway_vel * 8.0
		_hair_sway_vel += sway_acc * dt
		_hair_sway += _hair_sway_vel * dt

		# Secondary tip wave spring lags root for genuine overlapping whip action.
		var tip_sway_acc := (_hair_sway - _hair_tip_sway) * 30.0 - _hair_tip_sway_vel * 6.0
		_hair_tip_sway_vel += tip_sway_acc * dt
		_hair_tip_sway += _hair_tip_sway_vel * dt

		# Vertical bounce wave (footfalls, growth surge, sit-crush upward float).
		var sit_float := _sit_crush_hair_float if _sit_crush_active else 0.0
		var vertical_drive := -head_accel_local.y * 0.015
		if _sit_crush_active and sit_float > 0.05:
			# During rapid sit-crush drop/impact, keep hair billowing upward before falling back down.
			vertical_drive = maxf(vertical_drive, 0.0) + sit_float * 0.68
		var target_bounce := clampf(vertical_drive + _growth_surge * 0.14, -0.20, 0.42 + sit_float * 0.48)
		var bounce_acc := (target_bounce - _hair_bounce) * 50.0 - _hair_bounce_vel * 7.2
		_hair_bounce_vel += bounce_acc * dt
		_hair_bounce = clampf(_hair_bounce + _hair_bounce_vel * dt, -0.22, 0.50 + sit_float * 0.48)

		var tip_bounce_acc := (_hair_bounce - _hair_tip_bounce) * 32.0 - _hair_tip_bounce_vel * 5.6
		_hair_tip_bounce_vel += tip_bounce_acc * dt
		_hair_tip_bounce = clampf(_hair_tip_bounce + _hair_tip_bounce_vel * dt, -0.24, 0.55 + sit_float * 0.50)

		# Dedicated rotational lag spring (+_turn_rate = left turn CCW from above):
		# Front (+Z) trails -X; Back (-Z) trails +X; Sides flare outward centrifugally.
		var target_rot := clampf(_turn_rate * 0.11, -0.38, 0.38)
		var rot_acc := (target_rot - _hair_rot) * 42.0 - _hair_rot_vel * 7.4
		_hair_rot_vel += rot_acc * dt
		_hair_rot += _hair_rot_vel * dt

		var tip_rot_acc := (_hair_rot - _hair_tip_rot) * 26.0 - _hair_tip_rot_vel * 5.4
		_hair_tip_rot_vel += tip_rot_acc * dt
		_hair_tip_rot += _hair_tip_rot_vel * dt

	# Head forward tilt (positive when looking down during attacks) for subtle gravity drape.
	var head_fwd_local := head_pose.basis.orthonormalized() * Vector3.BACK
	var head_down_tilt := clampf(-head_fwd_local.y, -0.35, 0.55)
	var centrifugal := clampf(absf(_hair_rot) * 0.65, 0.0, 0.25)

	var breeze := sin(_idle_look_time * 1.35) * 0.022 + sin(_idle_look_time * 2.55) * 0.011
	var float_boost := _sit_crush_hair_float if _sit_crush_active else 0.0
	if _active_skin != null:
		# The Kawaii hair is hidden behind the active skin, so spend the spring values on
		# the visible skin and skip the (invisible) driver-skeleton writes. Far distance
		# clipping and silhouettes skip the work entirely.
		if not _distant_clipped and not _silhouette_visible():
			_active_skin.apply_secondary_motion(_hair_sway, _hair_tip_sway, _hair_bounce,
				_hair_tip_bounce, _hair_rot, _hair_tip_rot, head_down_tilt, dt)
		return
	for chain in _hair_chains:
		var count := chain.bones.size()
		for k in count:
			var frac := float(k + 1) / float(count)
			var tip_mix := smoothstep(0.15, 1.0, frac)
			var weight := lerpf(0.28, 1.0, frac * frac)
			var sway := _hair_sway.lerp(_hair_tip_sway, tip_mix)
			var bounce := lerpf(_hair_bounce, _hair_tip_bounce, tip_mix) + float_boost * lerpf(0.18, 0.45, tip_mix)
			var rot_lag := lerpf(_hair_rot, _hair_tip_rot, tip_mix)
			var flutter := (breeze + sin(_idle_look_time * 2.2 + chain.phase_offset - float(k) * 0.85) * 0.020) * weight

			var pitch := 0.0 # +X rotates hanging hair (-Y) toward -Z (backward); -X lifts forward (+Z)
			var roll := 0.0  # +Z rotates hanging hair (-Y) toward +X (left); -Z toward -X (right)

			match chain.zone:
				HAIR_FRONT:
					# Bangs lift subtly outward (+Z -> negative pitch) and trail -X on left turn, staying clear of eyes/forehead.
					var lift := maxf(0.0, -sway.y * 0.45 + bounce * 0.48 + maxf(head_down_tilt, 0.0) * 0.14)
					pitch = -clampf(lift * 0.48 + absf(flutter) * 0.35, 0.0, 0.19 + float_boost * 0.11) * weight
					roll = clampf(sway.x * 0.38 - rot_lag * 0.58 + flutter, -0.15, 0.15) * weight
				HAIR_SIDE_L:
					# Left side locks flare outward (+X -> positive roll) on centrifugal/bounce, never into cheek.
					var flare := maxf(0.0, sway.x * 0.65 + bounce * 0.58 + centrifugal + maxf(head_down_tilt, 0.0) * 0.18)
					roll = clampf(flare * 0.60 + absf(flutter) * 0.45, -0.02, 0.30 + float_boost * 0.24) * weight
					pitch = clampf(-sway.y * 0.78 - rot_lag * 0.50 - maxf(head_down_tilt, 0.0) * 0.16 + flutter, -0.22, 0.30 + float_boost * 0.16) * weight
				HAIR_SIDE_R:
					# Right side locks flare outward (-X -> negative roll) on centrifugal/bounce, never into cheek.
					var flare := maxf(0.0, -sway.x * 0.65 + bounce * 0.58 + centrifugal + maxf(head_down_tilt, 0.0) * 0.18)
					roll = -clampf(flare * 0.60 + absf(flutter) * 0.45, -0.02, 0.30 + float_boost * 0.24) * weight
					pitch = clampf(-sway.y * 0.78 + rot_lag * 0.50 - maxf(head_down_tilt, 0.0) * 0.16 + flutter, -0.22, 0.30 + float_boost * 0.16) * weight
				_:
					# Back hair lifts backward (-Z -> positive pitch) on stride and impact,
					# and trails +X on left turn (exact angular inertia!), keeping a cohesive bob silhouette.
					var back_lift := maxf(0.0, -sway.y * 0.85 + bounce * 0.82 + centrifugal * 0.65 + maxf(-head_down_tilt, 0.0) * 0.25)
					pitch = clampf(back_lift * 0.72 + maxf(flutter, 0.0) * 0.75, -0.02, 0.38 + float_boost * 0.32) * weight
					var fan_out := chain.lateral_bias * maxf(bounce, 0.0) * 0.16
					roll = clampf(sway.x * 0.65 + rot_lag * 0.82 + fan_out + flutter * 0.85, -0.28 - float_boost * 0.10, 0.28 + float_boost * 0.10) * weight

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
			# Original Kawaii GLB spells right eye blink on Body mesh as "Blinl R".
			idx_r = mesh.find_blend_shape_by_name("Blinl R")
		if idx_l >= 0 or idx_r >= 0:
			_blink_targets.append({"mesh": mesh, "l": idx_l, "r": idx_r})

	_eyebrow_mesh = _skeleton.get_node_or_null("Eyebrows") as MeshInstance3D
	if _eyebrow_mesh != null:
		_brow_angry_l = _eyebrow_mesh.find_blend_shape_by_name("Angry L")
		_brow_angry_r = _eyebrow_mesh.find_blend_shape_by_name("Angry R")
		_brow_down_l = _eyebrow_mesh.find_blend_shape_by_name("Down L")
		_brow_down_r = _eyebrow_mesh.find_blend_shape_by_name("Down R")
		_brow_up_l = _eyebrow_mesh.find_blend_shape_by_name("Up L")
		_brow_up_r = _eyebrow_mesh.find_blend_shape_by_name("Up R")


func _next_rand() -> float:
	_blink_seed = (_blink_seed * 1103515245 + 12345) & 0x7fffffff
	return float(_blink_seed % 10000) / 10000.0


func _update_face(dt: float) -> void:
	if dt > 0.0:
		# Natural blinking with occasional double-blink for genuine life.
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

		# Idle eye saccades: eyes dart quickly to a new point of interest, head follows softly behind.
		_gaze_timer -= dt
		if _gaze_timer <= 0.0:
			_gaze_timer = 1.6 + _next_rand() * 2.4
			var gx := (_next_rand() - 0.5) * 0.18
			var gy := (_next_rand() - 0.42) * 0.09
			_eye_idle_target = Vector2(gx, gy)
		_head_idle_gaze = _head_idle_gaze.lerp(_eye_idle_target * 0.65, minf(dt * 2.4, 1.0))

		var target_eye := Vector2.ZERO
		if _pickup_crush_active and _pickup_eye_override > 0.001:
			target_eye = _pickup_eye_target * _pickup_eye_override
		elif _punch_active and _punch_eye_override > 0.001:
			target_eye = _punch_eye_target * _punch_eye_override
		elif _sit_crush_active and _sit_crush_eye_override > 0.001:
			target_eye = _sit_crush_eye_target * _sit_crush_eye_override
		elif _sit_idle_active:
			target_eye = Vector2(
				clampf((_eye_idle_target.x - _head_idle_gaze.x * 0.5) + _sit_idle_eye_bias.x, -TURN_EYE_MAX_YAW, TURN_EYE_MAX_YAW),
				clampf((_eye_idle_target.y - _head_idle_gaze.y * 0.5) + _sit_idle_eye_bias.y, -0.06, 0.105)
			)
		else:
			var idle_w := (1.0 - _stride) * (1.0 - _eye_turn_override)
			var turn_glance := _eye_local_yaw * _eye_turn_override
			target_eye = Vector2(
				clampf((_eye_idle_target.x - _head_idle_gaze.x * 0.5) * idle_w + turn_glance, -TURN_EYE_MAX_YAW, TURN_EYE_MAX_YAW),
				clampf((_eye_idle_target.y - _head_idle_gaze.y * 0.5) * idle_w, -0.065, 0.095)
			)
		if dt > 0.0:
			_eye_gaze = _eye_gaze.lerp(target_eye, minf(dt * 24.0, 1.0))
		else:
			_eye_gaze = target_eye

		var target_tension := 0.0
		if _pickup_crush_active:
			target_tension = _pickup_brow_target
		elif _punch_active:
			target_tension = _punch_brow_target
		elif _sit_crush_active:
			target_tension = _sit_crush_brow_target
		if dt > 0.0:
			_brow_tension = lerpf(_brow_tension, target_tension, minf(dt * 10.0, 1.0))
			_impact_flinch = move_toward(_impact_flinch, 0.0, dt * 5.2)
		else:
			_brow_tension = target_tension
	elif _pickup_crush_active:
		_eye_gaze = _pickup_eye_target * _pickup_eye_override
		_brow_tension = _pickup_brow_target
	elif _punch_active:
		_eye_gaze = _punch_eye_target * _punch_eye_override
		_brow_tension = _punch_brow_target
	elif _sit_crush_active:
		_eye_gaze = _sit_crush_eye_target * _sit_crush_eye_override
		_brow_tension = _sit_crush_brow_target

	# Drive Eye L / Eye R bones within tight safe anatomical limits.
	if _eye_l >= 0:
		var q_l := Quaternion(_eye_l_axes.y, _eye_gaze.x) * Quaternion(_eye_l_axes.x, _eye_gaze.y)
		_skeleton.set_bone_pose_rotation(_eye_l, _eye_l_rest * q_l)
	if _eye_r >= 0:
		var q_r := Quaternion(_eye_r_axes.y, _eye_gaze.x) * Quaternion(_eye_r_axes.x, _eye_gaze.y)
		_skeleton.set_bone_pose_rotation(_eye_r, _eye_r_rest * q_r)

	var blink_val := 0.0
	if _blink_progress >= 0.0:
		# Fast close (0..0.38), slightly gentler open (0..1.0).
		if _blink_progress < 0.38:
			blink_val = smoothstep(0.0, 0.38, _blink_progress)
		else:
			blink_val = 1.0 - smoothstep(0.38, 1.0, _blink_progress)
	# Subtle determined squint during crush/punch/sit-crush + brief impact-reflex flinch on touchdown/impact.
	var flinch_curve := sin(_impact_flinch * PI) * 0.24
	var action_squint := _pickup_squint if _pickup_crush_active else (_punch_squint if _punch_active else (_sit_crush_squint if _sit_crush_active else 0.0))
	blink_val = maxf(blink_val, maxf(_brow_tension * 0.14 + action_squint, flinch_curve))

	for target in _blink_targets:
		var mesh: MeshInstance3D = target["mesh"]
		var l: int = target["l"]
		var r: int = target["r"]
		if l >= 0:
			mesh.set_blend_shape_value(l, blink_val)
		if r >= 0:
			mesh.set_blend_shape_value(r, blink_val)

	if _eyebrow_mesh != null:
		var idle_curiosity := clampf(absf(_eye_gaze.x) * 0.75 * (1.0 - _stride) * (1.0 - _brow_tension), 0.0, 0.12)
		if _brow_angry_l >= 0:
			_eyebrow_mesh.set_blend_shape_value(_brow_angry_l, _brow_tension * 0.50)
		if _brow_angry_r >= 0:
			_eyebrow_mesh.set_blend_shape_value(_brow_angry_r, _brow_tension * 0.50)
		if _brow_down_l >= 0:
			_eyebrow_mesh.set_blend_shape_value(_brow_down_l, _brow_tension * 0.24)
		if _brow_down_r >= 0:
			_eyebrow_mesh.set_blend_shape_value(_brow_down_r, _brow_tension * 0.24)
		if _brow_up_l >= 0:
			_eyebrow_mesh.set_blend_shape_value(_brow_up_l, idle_curiosity)
		if _brow_up_r >= 0:
			_eyebrow_mesh.set_blend_shape_value(_brow_up_r, idle_curiosity)


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
