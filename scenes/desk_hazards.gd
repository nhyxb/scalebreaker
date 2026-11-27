extends Node3D
## Reusable tabletop desk-hazard controller & Phase 3B-1/3B-2 rigged arm IK driver.
##
## Mounted as a direct child of `HarborRound` (`scenes/round.tscn`), inheriting
## `PROCESS_MODE_PAUSABLE` so pausing freezes timers and animation automatically,
## and leaving/restarting a round cleanly resets Yumeka's background arm and gaze
## relay in `_exit_tree()`.
##
## Scheme 2 Architecture (Single Rigged Foreground Right Arm + Analytical 2-Bone IK):
##   - `Yumeka_hand_relay.glb` keeps the 20-bone right-arm skeleton (`UpperArm_R`
##     root aligned to `(0, 0, 0)` at exact 1:6,667 scale) and 3 skinned meshes.
##   - Every active frame anchors `_hand_root.global_position` directly onto
##     `yumeka_ultra_giant.gd::get_right_shoulder_main_world_pos()`, solves
##     analytical Law-of-Cosines 2-Bone IK (`UpperArm_R` / `LowerArm_R` + twist
##     distribution) from dynamically measured `L1`/`L2`, orients `Hand_R`, and
##     smoothly blends reusable finger gestures around verified `local (1, 0, 0)`.
##   - 5-phase zero-teleport continuous animation:
##       RAISE (0.65s) -> WINDUP (1.75s) -> HOLD (0.50s) -> RETRACT (0.65s) -> RETURN (0.75s)
##     starting & landing directly on `get_right_hand_rest_main_world_pos()`.
##   - Missing licensed Yumeka GLB gracefully falls back to an articulated procedural
##     arm driven by the exact same 2-Bone IK & 5-phase motion curve with zero errors.
##
## Architectural invariants:
##   - Foreground hazard geometry NEVER registers into Rust's `giants`, `rivals`,
##     or `targets` arrays and carries ZERO `CollisionObject3D` nodes.
##   - Active warning circles register with `HarborRound.set_hazard_warning()` so
##     Phase 4 Utility AI and civilians immediately flee outside the strike zone.

const CityNightLights := preload("res://scenes/city_night_lights.gd")

const HAND_GLB_PATH := "res://assets/characters/yumeka/Yumeka_hand_relay.glb"
const HAZARD_ID_POKE := 1

## Auto-trigger cadence (seconds) when `desk_hazards` is enabled in Sandbox/Growth/Brawl.
const AUTO_MIN_DELAY := 45.0
const AUTO_MAX_DELAY := 90.0

## Five-phase continuous cadence for `finger_poke` (total pre-impact warning = 2.40 s).
const POKE_RAISE_SECONDS := 0.65
const POKE_WINDUP_SECONDS := 1.75
const POKE_HOLD_SECONDS := 0.50
const POKE_RETRACT_SECONDS := 0.65
const POKE_RETURN_SECONDS := 0.75
const POKE_RADIUS := 110.0
const POKE_DAMAGE_FRACTION := 0.85
const POKE_KNOCKBACK_SPEED := 68.0

## Fallback anchors & bone lengths when licensed Yumeka GLBs are absent (true 1:6,667 m).
const FALLBACK_SHOULDER_POS := Vector3(636.0, 823.8, 2928.7)
const FALLBACK_ELBOW_REST_POS := Vector3(1486.9, 326.3, 2462.5)
const FALLBACK_HAND_REST_POS := Vector3(1125.5, 283.0, 1348.5)
const FALLBACK_ARM_L1 := 1090.28
const FALLBACK_ARM_L2 := 1171.96
const FALLBACK_POKE_TIP_LOCAL := Vector3(-108.0, 755.0, -78.0)

## Trajectory & IK tuning (metres / degrees in main-world scale).
const HIGH_AIM_HEIGHT := 440.0
const HIGH_AIM_SOUTH_BIAS := 125.0
const RAISE_ARC_HEIGHT := 175.0
const RAISE_ARC_OUTWARD := 95.0
const RETURN_ARC_HEIGHT := 150.0
const RETURN_ARC_OUTWARD := 80.0
const WINDUP_ANTICIPATION_LIFT := 30.0
const HOLD_PRESS_DEPTH := 3.0
const WINDUP_PITCH_DOWN_DEG := 34.0
const IMPACT_PITCH_DOWN_DEG := 38.0
const HAND_ERGONOMIC_ROLL_DEG := -6.0
const IMPACT_WRIST_CUSHION_DEG := 6.5
## Keep at least ~17 deg natural elbow flexion before soft axial reach kicks in.
const IK_SOFT_REACH_RATIO := 0.955
const IK_MAX_STRETCH := 1.48
## Ventral offset (metres at 1:6,667) from IndexDistal_R centerline to fingertip skin pad.
const INDEX_PAD_VENTRAL_OFFSET := 26.0
## Natural outward-dominant, gently lifted elbow pole vector (keeps elbow around shoulder
## level & cleanly bent outward like a human leaning over a desk, never hyper-raised).
const RAISED_ELBOW_POLE := Vector3(0.92, 0.16, 0.34)

## Unified matte anime shading constants matching Yumeka_seated.glb bedroom bounce fill
## (main-world Sun is behind Yumeka at +Z, so subtle warm bounce keeps backlit sleeve/palm
## seamless with her background warm cocoa cardigan & creamy peach skin).
const MATTE_ROUGHNESS := 0.90
const MATTE_SPECULAR := 0.14
const BODY_TINT := Color(0.98, 0.95, 0.93)
const CLOTHES_TINT := Color(1.06, 1.00, 0.96)
const BODY_BOUNCE_DAY := 0.22
const CLOTHES_BOUNCE_DAY := 0.32
const BOUNCE_NIGHT_SCALE := 0.34

enum HazardKind { NONE, FINGER_POKE }
enum Phase { IDLE, RAISE, WINDUP, HOLD, RETRACT, RETURN }
## Reusable hand-gesture library: Phase 3B-1 uses REST_RELAXED <-> FINGER_POKE;
## OPEN_PALM and PINCH_GRIP are ready for Phase 3B-2 drag/palm/coin/eraser events.
enum HandGesture { REST_RELAXED, FINGER_POKE, OPEN_PALM, PINCH_GRIP }

const FINGER_BONES := [
	"ThumbProximal_R", "ThumbIntermediate_R", "ThumbDistal_R",
	"IndexProximal_R", "IndexIntermediate_R", "IndexDistal_R",
	"MiddleProximal_R", "MiddleIntermediate_R", "MiddleDistal_R",
	"RingProximal_R", "RingIntermediate_R", "RingDistal_R",
	"LittleProximal_R", "LittleIntermediate_R", "LittleDistal_R",
]

## Finger pose presets expressed as Vector3(flex_x_deg, twist_y_deg, spread_z_deg)
## about each bone's own local axes (verified true flexion axis is local (1, 0, 0),
## negative = curl downward toward the palm).
const GESTURE_PRESETS := {
	# Exact match to 59c8440 SeatedPose desk-resting five-finger gentle curl.
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
	# Single-finger poke: gently curved extended index, curled middle/ring/little, adducted thumb.
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
	# Reserved for Phase 3B-2 open-palm sweep / press.
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
	# Reserved for Phase 3B-2 coin / eraser pinch grip.
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

var _rng := RandomNumberGenerator.new()
var _hazard: HazardKind = HazardKind.NONE
var _phase: Phase = Phase.IDLE
var _phase_time := 0.0
var _next_auto_in := 60.0
var _target := Vector3.ZERO
var _last_shoulder_pos := FALLBACK_SHOULDER_POS
var _last_rest_hand_pos := FALLBACK_HAND_REST_POS
var _last_elbow_pos := FALLBACK_ELBOW_REST_POS
var _last_wrist_pos := FALLBACK_HAND_REST_POS
var _last_fingertip_pos := FALLBACK_HAND_REST_POS
var _last_elbow_bend_deg := 0.0
var _last_ik_stretch := 1.0
var _gesture_weight := 0.0
var _active_gesture: HandGesture = HandGesture.FINGER_POKE
var _whoosh_played := false
var _trigger_count := 0
var _last_impact_summary: Dictionary = {}

## Foreground arm rig & dynamically measured skeleton geometry.
var _hand_root: Node3D
var _hand_visual: Node3D
var _hand_skeleton: Skeleton3D
var _b_upper := -1
var _b_upper_twist := -1
var _b_lower := -1
var _b_lower_twist := -1
var _b_hand := -1
var _b_idx_int := -1
var _b_idx_dist := -1
var _finger_indices := {}          # String bone name -> int bone index
var _finger_rest_quats := {}       # int bone index -> Quaternion rest local rotation
var _gesture_delta_quats := {}     # HandGesture -> { int bone index -> Quaternion }
var _lower_twist_rest_q := Quaternion.IDENTITY
var _arm_l1 := FALLBACK_ARM_L1
var _arm_l2 := FALLBACK_ARM_L2
var _index_distal_len := 107.5
var _poke_tip_in_hand_local := FALLBACK_POKE_TIP_LOCAL

## Articulated placeholder fallback nodes (share the exact same 2-Bone IK solver).
var _ph_upper: Node3D
var _ph_lower: Node3D
var _ph_hand: Node3D
var _ph_index: Node3D
var _ph_curled_group: Node3D
var _hand_materials: Array[Dictionary] = []  # [{mat: StandardMaterial3D, base_bounce: float}]
var _using_placeholder := false
var _force_placeholder := false

var _warning_root: Node3D
var _shadow_quad: MeshInstance3D
var _shadow_mat: ShaderMaterial
var _warn_quad: MeshInstance3D
var _warn_mat: ShaderMaterial
var _vfx_root: Node3D


func _ready() -> void:
	_rng.randomize()
	_next_auto_in = _rng.randf_range(AUTO_MIN_DELAY, AUTO_MAX_DELAY)
	_vfx_root = Node3D.new()
	_vfx_root.name = "HazardVfx"
	add_child(_vfx_root)
	# Instantiate hidden foreground rig upfront so Skeleton3D L1/L2 & finger offsets
	# are dynamically measured in _ready() and ready with zero hitch on first trigger.
	_ensure_hand_visual()


func _exit_tree() -> void:
	_clear_rust_warning()
	_sync_background_yumeka(false, Vector3.ZERO, 0.0)


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	var is_f8 := (key.keycode == KEY_F8 or key.physical_keycode == KEY_F8)
	if not (key.pressed and not key.echo and is_f8):
		return
	if key.ctrl_pressed or key.alt_pressed or key.meta_pressed:
		return
	if get_tree().paused or not _is_round_playing() or not _is_enabled():
		return
	if trigger_finger_poke():
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if get_tree().paused:
		return
	var dt := minf(delta, 0.1)
	if not _is_round_playing() or not _is_enabled():
		if _phase != Phase.IDLE:
			_abort_to_idle()
		return

	if _phase == Phase.IDLE:
		_next_auto_in -= dt
		if _next_auto_in <= 0.0:
			trigger_finger_poke()
		return

	match _hazard:
		HazardKind.FINGER_POKE:
			_step_finger_poke(dt)
		_:
			_abort_to_idle()


# --------------------------------------------------------------------------- #
# Public / Reusable Hazard & Gesture Entry Points
# --------------------------------------------------------------------------- #

## Trigger a single-finger poke immediately (used by auto scheduler, F8 hotkey,
## and tests). Returns false if desk hazards are disabled, round is inactive,
## or a hazard is already running.
func trigger_finger_poke(target_override := Vector3.INF) -> bool:
	if _phase != Phase.IDLE or not _is_enabled() or not _is_round_playing():
		return false
	var chosen := target_override
	if not chosen.is_finite():
		chosen = _pick_target()
	_target = Vector3(chosen.x, 0.0, chosen.z)
	_hazard = HazardKind.FINGER_POKE
	_active_gesture = HandGesture.FINGER_POKE
	_phase = Phase.RAISE
	_phase_time = 0.0
	_gesture_weight = 0.0
	_whoosh_played = false
	_trigger_count += 1
	_last_impact_summary = {}

	_ensure_hand_visual()
	_ensure_warning_visuals()

	# Collapse background UpperArm_R immediately (with arm_lift = 0.0 so Shoulder_R
	# stays in exact SeatedPose) and show foreground rigged right arm starting right
	# on the desk resting wrist point `rest_pos` (ZERO teleport!).
	_sync_background_yumeka(true, _target, 0.0)
	_hand_root.visible = true
	_pose_raise_frame(0.0)

	_warning_root.visible = true
	_warning_root.global_position = _target
	_shadow_quad.visible = true
	_warn_quad.visible = true
	_update_warning_visuals(0.0, 0.0, true, 0.0)

	_register_rust_warning(_target, POKE_RADIUS)

	var audio := get_node_or_null("/root/HarborAudio")
	if audio != null and audio.has_method(&"play_desk_hazard_warn"):
		audio.call(&"play_desk_hazard_warn", _target)
	return true


## Reusable finger-gesture blending API (supports REST_RELAXED <-> FINGER_POKE now,
## and OPEN_PALM / PINCH_GRIP for upcoming Phase 3B-2 events without re-exporting).
func set_hand_gesture_blend(from_gesture: HandGesture, to_gesture: HandGesture, weight: float) -> void:
	var w := clampf(weight, 0.0, 1.0)
	_gesture_weight = w
	if _hand_skeleton != null:
		var from_map: Dictionary = _gesture_delta_quats.get(from_gesture, {})
		var to_map: Dictionary = _gesture_delta_quats.get(to_gesture, {})
		for bname in FINGER_BONES:
			var idx: int = _finger_indices.get(bname, -1)
			if idx < 0:
				continue
			var rest_q: Quaternion = _finger_rest_quats.get(idx, Quaternion.IDENTITY)
			var qa: Quaternion = from_map.get(idx, Quaternion.IDENTITY)
			var qb: Quaternion = to_map.get(idx, Quaternion.IDENTITY)
			_hand_skeleton.set_bone_pose_rotation(idx, rest_q * qa.slerp(qb, w))
	elif _ph_index != null and _ph_curled_group != null:
		# Mirror finger curl/extension cleanly on the procedural placeholder fallback.
		_ph_index.rotation.x = lerpf(deg_to_rad(-24.0), deg_to_rad(-6.0), w)
		_ph_curled_group.rotation.x = lerpf(deg_to_rad(-28.0), deg_to_rad(-88.0), w)


# --------------------------------------------------------------------------- #
# 5-Phase Continuous State Machine: RAISE -> WINDUP -> HOLD -> RETRACT -> RETURN
# --------------------------------------------------------------------------- #

func _step_finger_poke(dt: float) -> void:
	_phase_time += dt
	match _phase:
		Phase.RAISE:
			var p := clampf(_phase_time / POKE_RAISE_SECONDS, 0.0, 1.0)
			_pose_raise_frame(p)
			var fade_in := smoothstep(0.0, 0.78, p)
			_sync_background_yumeka(true, _target, smoothstep(0.0, 1.0, p))
			_update_warning_visuals(0.0, fade_in * 0.42, true, fade_in)
			if _phase_time >= POKE_RAISE_SECONDS:
				_phase = Phase.WINDUP
				_phase_time = 0.0

		Phase.WINDUP:
			var p := clampf(_phase_time / POKE_WINDUP_SECONDS, 0.0, 1.0)
			_pose_windup_frame(p)
			_sync_background_yumeka(true, _target, 1.0)
			_update_warning_visuals(p, lerpf(0.42, 1.0, smoothstep(0.0, 1.0, p)), true, 1.0)
			if not _whoosh_played and p >= 0.62:
				_whoosh_played = true
				var audio := get_node_or_null("/root/HarborAudio")
				if audio != null and audio.has_method(&"play_desk_hazard_whoosh"):
					audio.call(&"play_desk_hazard_whoosh", _target)
			if _phase_time >= POKE_WINDUP_SECONDS:
				_enter_poke_impact()

		Phase.HOLD:
			var p := clampf(_phase_time / POKE_HOLD_SECONDS, 0.0, 1.0)
			_pose_hold_frame(p)
			_sync_background_yumeka(true, _target, 1.0)
			_update_warning_visuals(1.0, 1.0, false, 0.0)
			if _phase_time >= POKE_HOLD_SECONDS:
				_phase = Phase.RETRACT
				_phase_time = 0.0

		Phase.RETRACT:
			var p := clampf(_phase_time / POKE_RETRACT_SECONDS, 0.0, 1.0)
			_pose_retract_frame(p)
			var shadow_fade := 1.0 - smoothstep(0.0, 0.82, p)
			_sync_background_yumeka(true, _target, 1.0)
			_update_warning_visuals(1.0 - p * 0.55, shadow_fade, false, 0.0)
			if _phase_time >= POKE_RETRACT_SECONDS:
				_phase = Phase.RETURN
				_phase_time = 0.0

		Phase.RETURN:
			var p := clampf(_phase_time / POKE_RETURN_SECONDS, 0.0, 1.0)
			_pose_return_frame(p)
			_update_warning_visuals(0.0, 0.0, false, 0.0)
			if _phase_time >= POKE_RETURN_SECONDS:
				# Landed completely at rest_pos with gesture 0.0 -> hide foreground arm
				# and hand back seamlessly to background UpperArm_R on the same frame.
				_finish_hazard()
			else:
				_sync_background_yumeka(true, _target, 1.0 - smoothstep(0.0, 1.0, p))


func _pose_raise_frame(p: float) -> void:
	var shoulder := _right_shoulder_main_pos()
	var rest_hand := _right_hand_rest_main_pos()
	var rest_pole := _rest_elbow_pole(shoulder, rest_hand)
	var rest_basis := _right_hand_rest_basis()
	var aim_basis := _poke_hand_basis(shoulder, _target, WINDUP_PITCH_DOWN_DEG, 0.0)
	var wrist_high := _high_aim_wrist_pos(shoulder, aim_basis)

	var u := smoothstep(0.0, 1.0, p)
	# Elbow lifts early so the forearm peels naturally off the desk before reaching across.
	var pole_u := smoothstep(0.0, 0.62, p)
	var pole := rest_pole.lerp(RAISED_ELBOW_POLE.normalized(), pole_u).normalized()
	var arc := Vector3(sin(u * PI) * RAISE_ARC_OUTWARD, sin(u * PI) * RAISE_ARC_HEIGHT, 0.0)
	var wrist_pos := rest_hand.lerp(wrist_high, u) + arc
	var hand_basis := Basis(rest_basis.get_rotation_quaternion().slerp(
			aim_basis.get_rotation_quaternion(), u))
	var gesture_u := smoothstep(0.08, 0.92, p)

	set_hand_gesture_blend(HandGesture.REST_RELAXED, _active_gesture, gesture_u)
	_solve_arm_ik(shoulder, wrist_pos, hand_basis, pole)


func _pose_windup_frame(p: float) -> void:
	var shoulder := _right_shoulder_main_pos()
	var tip_high := _high_aim_tip_pos(shoulder)
	var tip_land := _target + Vector3(0.0, -HOLD_PRESS_DEPTH, 0.0)
	var tip_pos: Vector3
	var pitch_u: float
	if p < 0.22:
		# Brief poised anticipation at high hover before descending.
		var u := p / 0.22
		var poise := sin(u * PI) * WINDUP_ANTICIPATION_LIFT
		tip_pos = tip_high + Vector3(0.0, poise, 0.0)
		pitch_u = 0.0
	elif p < 0.76:
		# Looming steady descent over the amber warning ring.
		var u := (p - 0.22) / 0.54
		var s := smoothstep(0.0, 1.0, u)
		tip_pos = tip_high.lerp(tip_land, s * 0.68)
		pitch_u = s * 0.68
	else:
		# Weighty accelerated plunge into the city block.
		var u := (p - 0.76) / 0.24
		var frac := lerpf(0.68, 1.0, u * u)
		tip_pos = tip_high.lerp(tip_land, frac)
		pitch_u = frac

	var pitch_deg := lerpf(WINDUP_PITCH_DOWN_DEG, IMPACT_PITCH_DOWN_DEG, pitch_u)
	var hand_basis := _poke_hand_basis(shoulder, _target, pitch_deg, 0.0)
	var wrist_pos := tip_pos - hand_basis * _poke_tip_in_hand_local

	set_hand_gesture_blend(HandGesture.REST_RELAXED, _active_gesture, 1.0)
	_solve_arm_ik(shoulder, wrist_pos, hand_basis, RAISED_ELBOW_POLE.normalized())


func _pose_hold_frame(p: float) -> void:
	var shoulder := _right_shoulder_main_pos()
	# Fingertip presses firmly into rubble with subtle damped settle while the wrist
	# yields slightly backward (dorsal impact cushion).
	var settle := sin(p * PI * 2.5) * exp(-p * 5.0) * 1.4
	var tip_pos := _target + Vector3(0.0, -HOLD_PRESS_DEPTH + settle, 0.0)
	var cushion_deg := IMPACT_WRIST_CUSHION_DEG * sin(minf(p * 1.85, 1.0) * PI) * exp(-p * 1.5)
	var hand_basis := _poke_hand_basis(shoulder, _target, IMPACT_PITCH_DOWN_DEG, cushion_deg)
	var wrist_pos := tip_pos - hand_basis * _poke_tip_in_hand_local

	set_hand_gesture_blend(HandGesture.REST_RELAXED, _active_gesture, 1.0)
	_solve_arm_ik(shoulder, wrist_pos, hand_basis, RAISED_ELBOW_POLE.normalized())


func _pose_retract_frame(p: float) -> void:
	var shoulder := _right_shoulder_main_pos()
	var tip_high := _high_aim_tip_pos(shoulder)
	var tip_land := _target + Vector3(0.0, -HOLD_PRESS_DEPTH, 0.0)
	var u := smoothstep(0.0, 1.0, p)
	var tip_pos := tip_land.lerp(tip_high, u)
	var pitch_deg := lerpf(IMPACT_PITCH_DOWN_DEG, WINDUP_PITCH_DOWN_DEG, u)
	var hand_basis := _poke_hand_basis(shoulder, _target, pitch_deg, 0.0)
	var wrist_pos := tip_pos - hand_basis * _poke_tip_in_hand_local

	set_hand_gesture_blend(HandGesture.REST_RELAXED, _active_gesture, 1.0)
	_solve_arm_ik(shoulder, wrist_pos, hand_basis, RAISED_ELBOW_POLE.normalized())


func _pose_return_frame(p: float) -> void:
	var shoulder := _right_shoulder_main_pos()
	var rest_hand := _right_hand_rest_main_pos()
	var rest_pole := _rest_elbow_pole(shoulder, rest_hand)
	var rest_basis := _right_hand_rest_basis()
	var aim_basis := _poke_hand_basis(shoulder, _target, WINDUP_PITCH_DOWN_DEG, 0.0)
	var wrist_high := _high_aim_wrist_pos(shoulder, aim_basis)

	var u := smoothstep(0.0, 1.0, p)
	# Wrist arcs back toward desk while elbow stays poised until settling gently last.
	var pole_u := smoothstep(0.22, 1.0, p)
	var pole := RAISED_ELBOW_POLE.normalized().lerp(rest_pole, pole_u).normalized()
	var arc := Vector3(sin(u * PI) * RETURN_ARC_OUTWARD, sin(u * PI) * RETURN_ARC_HEIGHT, 0.0)
	var wrist_pos := wrist_high.lerp(rest_hand, u) + arc
	var hand_basis := Basis(aim_basis.get_rotation_quaternion().slerp(
			rest_basis.get_rotation_quaternion(), u))
	var gesture_u := 1.0 - smoothstep(0.06, 0.90, p)

	set_hand_gesture_blend(HandGesture.REST_RELAXED, _active_gesture, gesture_u)
	_solve_arm_ik(shoulder, wrist_pos, hand_basis, pole)


func _enter_poke_impact() -> void:
	_phase = Phase.HOLD
	_phase_time = 0.0
	_pose_hold_frame(0.0)
	_warn_quad.visible = false
	_update_warning_visuals(1.0, 1.0, false, 0.0)
	_clear_rust_warning()

	var round := get_parent()
	if round != null and round.has_method(&"apply_desk_hazard_impact"):
		_last_impact_summary = round.call(
			&"apply_desk_hazard_impact",
			_target,
			POKE_RADIUS,
			POKE_DAMAGE_FRACTION,
			POKE_KNOCKBACK_SPEED,
		)

	var audio := get_node_or_null("/root/HarborAudio")
	if audio != null and audio.has_method(&"play_desk_hazard_impact"):
		audio.call(&"play_desk_hazard_impact", _target)
	_spawn_impact_vfx(_target)


func _finish_hazard() -> void:
	_phase = Phase.IDLE
	_hazard = HazardKind.NONE
	_phase_time = 0.0
	_gesture_weight = 0.0
	_clear_rust_warning()
	if _hand_root != null:
		_hand_root.visible = false
	if _warning_root != null:
		_warning_root.visible = false
	_sync_background_yumeka(false, Vector3.ZERO, 0.0)
	_next_auto_in = _rng.randf_range(AUTO_MIN_DELAY, AUTO_MAX_DELAY)


func _abort_to_idle() -> void:
	_finish_hazard()


# --------------------------------------------------------------------------- #
# Real-Time Analytical 2-Bone IK Solver (Law of Cosines + Twist Distribution)
# --------------------------------------------------------------------------- #

func _solve_arm_ik(shoulder_pos: Vector3, wrist_target: Vector3, hand_basis: Basis, pole_dir: Vector3) -> void:
	if _hand_root == null:
		return
	# Anchor foreground arm root directly on Yumeka's live right shoulder (UpperArm_R.head).
	_hand_root.global_position = shoulder_pos
	_hand_root.global_basis = Basis.IDENTITY
	_hand_root.scale = Vector3.ONE

	var w := wrist_target - shoulder_pos
	var raw_dist := w.length()
	var min_d := absf(_arm_l1 - _arm_l2) + 80.0
	var d := maxf(raw_dist, min_d)
	var u := w / raw_dist if raw_dist > 1e-4 else Vector3.FORWARD

	# Soft-IK uniform axial reach ONLY when target exceeds 95.5% of natural L1+L2
	# (keeps a natural >= ~17 deg human elbow bend everywhere & guarantees downtown/north
	# reach without hyperextending; Hand_R stays strictly 1.0 unscaled).
	var max_natural := (_arm_l1 + _arm_l2) * IK_SOFT_REACH_RATIO
	var stretch := 1.0
	if d > max_natural:
		stretch = clampf(d / max_natural, 1.0, IK_MAX_STRETCH)
	var e1 := _arm_l1 * stretch
	var e2 := _arm_l2 * stretch
	var d_eff := minf(d, (e1 + e2) * 0.992)
	var w_eff := u * d_eff

	# Project elbow pole vector orthogonal to shoulder->wrist chord.
	var pole := pole_dir - u * pole_dir.dot(u)
	if pole.length_squared() < 1e-5:
		pole = Vector3.RIGHT - u * u.x
		if pole.length_squared() < 1e-5:
			pole = Vector3.UP - u * u.y
	var v := pole.normalized()

	# Law of Cosines in triangle (Shoulder, Elbow, Wrist).
	var cos_a := clampf((e1 * e1 + d_eff * d_eff - e2 * e2) / (2.0 * e1 * d_eff), -1.0, 1.0)
	var sin_a := sqrt(maxf(0.0, 1.0 - cos_a * cos_a))
	var elbow_skel := u * (e1 * cos_a) + v * (e1 * sin_a)

	# Compute twist-free anatomical elbow hinge basis:
	#   +Y = bone axis (shoulder->elbow / elbow->wrist)
	#   +Z = dorsal hinge axis == (ua_y x la_y).normalized() (aligned skyward/outward)
	#   +X = lateral outward axis == (ua_y x hinge_z).normalized()
	var ua_y := elbow_skel.normalized()
	var la_vec := w_eff - elbow_skel
	var la_y := la_vec.normalized() if la_vec.length_squared() > 1e-4 else ua_y
	var hinge_z := ua_y.cross(la_y)
	if hinge_z.length_squared() < 1e-5:
		hinge_z = Vector3.UP - ua_y * ua_y.y
		if hinge_z.length_squared() < 1e-5:
			hinge_z = Vector3.RIGHT
	hinge_z = hinge_z.normalized()
	# Ensure dorsal +Z stays consistently upper-hemisphere (never flips upside down).
	if hinge_z.dot(Vector3.UP) < -0.15:
		hinge_z = -hinge_z

	var ua_x := ua_y.cross(hinge_z).normalized()
	var ua_z := ua_x.cross(ua_y).normalized()
	var ua_basis := Basis(ua_x, ua_y, ua_z)

	# Untwisted forearm basis shares the exact elbow hinge axis (zero elbow twist),
	# then splits forearm pronation smoothly across LowerArm_R (55%) & LowerArm_twist_R (45%).
	var la_x0 := la_y.cross(hinge_z).normalized()
	var la_z0 := la_x0.cross(la_y).normalized()
	var la_base := Basis(la_x0, la_y, la_z0)

	var target_z_proj := hand_basis.z - la_y * hand_basis.z.dot(la_y)
	var pronation := 0.0
	if target_z_proj.length_squared() > 1e-5:
		var tz := target_z_proj.normalized()
		pronation = atan2(la_z0.cross(tz).dot(la_y), clampf(la_z0.dot(tz), -1.0, 1.0))
		pronation = clampf(pronation, deg_to_rad(-85.0), deg_to_rad(85.0))
	var la_basis := Basis(la_y, pronation * 0.55) * la_base
	var twist_rem := pronation * 0.45

	if _hand_skeleton != null:
		var seg_scale := Vector3.ONE * stretch
		_hand_skeleton.set_bone_global_pose(_b_upper, Transform3D(ua_basis.scaled(seg_scale), Vector3.ZERO))
		_hand_skeleton.set_bone_global_pose(_b_lower, Transform3D(la_basis.scaled(seg_scale), elbow_skel))
		if _b_lower_twist >= 0:
			_hand_skeleton.set_bone_pose_rotation(
					_b_lower_twist, _lower_twist_rest_q * Quaternion(Vector3.UP, twist_rem))
		# Hand_R stays strictly 1.0 unscaled orthonormal so hand & fingers preserve exact 1:6,667 scale.
		_hand_skeleton.set_bone_global_pose(_b_hand, Transform3D(hand_basis, w_eff))
		if _b_idx_dist >= 0:
			var dist_pose := _hand_skeleton.get_bone_global_pose(_b_idx_dist)
			_last_fingertip_pos = shoulder_pos + dist_pose * Vector3(0.0, _index_distal_len, -INDEX_PAD_VENTRAL_OFFSET)
		else:
			_last_fingertip_pos = shoulder_pos + w_eff + hand_basis * _poke_tip_in_hand_local
	elif _ph_upper != null and _ph_lower != null and _ph_hand != null:
		_ph_upper.transform = Transform3D(ua_basis.scaled(Vector3.ONE * stretch), Vector3.ZERO)
		_ph_lower.transform = Transform3D(la_basis.scaled(Vector3.ONE * stretch), elbow_skel)
		_ph_hand.transform = Transform3D(hand_basis, w_eff)
		_last_fingertip_pos = shoulder_pos + w_eff + hand_basis * _poke_tip_in_hand_local

	_last_elbow_pos = shoulder_pos + elbow_skel
	_last_wrist_pos = shoulder_pos + w_eff
	_last_ik_stretch = stretch
	_last_elbow_bend_deg = rad_to_deg(acos(clampf(ua_y.dot(la_y), -1.0, 1.0)))
	_sync_hand_material_lighting()

	if _shadow_mat != null:
		var arm_xz := Vector2(shoulder_pos.x - _target.x, shoulder_pos.z - _target.z)
		if arm_xz.length_squared() > 1e-5:
			_shadow_mat.set_shader_parameter(&"u_arm_dir", arm_xz.normalized())


func _high_aim_tip_pos(shoulder_pos: Vector3) -> Vector3:
	var to_sh_xz := Vector3(shoulder_pos.x - _target.x, 0.0, shoulder_pos.z - _target.z)
	var bias_dir := to_sh_xz.normalized() if to_sh_xz.length_squared() > 1e-4 else Vector3.BACK
	return _target + Vector3(0.0, HIGH_AIM_HEIGHT, 0.0) + bias_dir * HIGH_AIM_SOUTH_BIAS


func _high_aim_wrist_pos(shoulder_pos: Vector3, aim_basis: Basis) -> Vector3:
	return _high_aim_tip_pos(shoulder_pos) - aim_basis * _poke_tip_in_hand_local


func _poke_hand_basis(shoulder_pos: Vector3, target: Vector3, pitch_down_deg: float, cushion_deg: float) -> Basis:
	var horiz := Vector3(target.x - shoulder_pos.x, 0.0, target.z - shoulder_pos.z)
	var h_dir := horiz.normalized() if horiz.length_squared() > 1e-4 else Vector3.FORWARD
	var pitch := deg_to_rad(clampf(pitch_down_deg - cushion_deg, 8.0, 72.0))
	var hand_y := (h_dir * cos(pitch) + Vector3(0.0, -sin(pitch), 0.0)).normalized()
	var hand_x := hand_y.cross(Vector3.UP)
	if hand_x.length_squared() < 1e-5:
		hand_x = Vector3.RIGHT
	else:
		hand_x = hand_x.normalized()
	var hand_z := hand_x.cross(hand_y).normalized()
	var base := Basis(hand_x, hand_y, hand_z)
	return Basis(hand_y, deg_to_rad(HAND_ERGONOMIC_ROLL_DEG)) * base


func _rest_elbow_pole(shoulder_pos: Vector3, rest_hand_pos: Vector3) -> Vector3:
	var rest_elbow := _right_elbow_rest_main_pos()
	var mid := (shoulder_pos + rest_hand_pos) * 0.5
	var dir := rest_elbow - mid
	if dir.length_squared() < 1e-4:
		return Vector3(0.84, -0.31, 0.45).normalized()
	return dir.normalized()


# --------------------------------------------------------------------------- #
# Rust Round & Background Skybox Bridges
# --------------------------------------------------------------------------- #

func _is_enabled() -> bool:
	var round := get_parent()
	if round == null or not round.has_method(&"desk_hazards_enabled"):
		return false
	return bool(round.call(&"desk_hazards_enabled"))


func _is_round_playing() -> bool:
	var round := get_parent()
	if round == null:
		return false
	var game := _harbor_game()
	if game != null and game.has_method(&"get_screen"):
		return String(game.call(&"get_screen")) == "playing"
	return true


func _harbor_game() -> Node:
	var p := get_parent()
	while p != null:
		if p.has_method(&"get_screen") and p.has_node("Skybox"):
			return p
		p = p.get_parent()
	return get_tree().current_scene if get_tree() != null else null


func _background_yumeka() -> Node:
	var game := _harbor_game()
	if game == null:
		return null
	var sky := game.get_node_or_null("Skybox")
	if sky == null or not sky.has_method(&"get_yumeka"):
		return null
	return sky.call(&"get_yumeka")


func _pick_target() -> Vector3:
	var round := get_parent()
	if round != null and round.has_method(&"pick_hazard_target"):
		return round.call(&"pick_hazard_target")
	return Vector3.ZERO


func _register_rust_warning(center: Vector3, radius: float) -> void:
	var round := get_parent()
	if round != null and round.has_method(&"set_hazard_warning"):
		round.call(&"set_hazard_warning", HAZARD_ID_POKE, center, radius)


func _clear_rust_warning() -> void:
	var round := get_parent()
	if round != null and round.has_method(&"clear_hazard_warning"):
		round.call(&"clear_hazard_warning", HAZARD_ID_POKE)


func _sync_background_yumeka(active: bool, main_world_target: Vector3, arm_lift: float) -> void:
	var yumeka := _background_yumeka()
	if yumeka != null and yumeka.has_method(&"set_hazard_relay"):
		yumeka.call(&"set_hazard_relay", active, main_world_target, arm_lift)


func _right_shoulder_main_pos() -> Vector3:
	var yumeka := _background_yumeka()
	if yumeka != null and yumeka.has_method(&"get_right_shoulder_main_world_pos"):
		_last_shoulder_pos = yumeka.call(&"get_right_shoulder_main_world_pos")
		return _last_shoulder_pos
	_last_shoulder_pos = FALLBACK_SHOULDER_POS
	return _last_shoulder_pos


func _right_hand_rest_main_pos() -> Vector3:
	var yumeka := _background_yumeka()
	if yumeka != null and yumeka.has_method(&"get_right_hand_rest_main_world_pos"):
		_last_rest_hand_pos = yumeka.call(&"get_right_hand_rest_main_world_pos")
		return _last_rest_hand_pos
	_last_rest_hand_pos = FALLBACK_HAND_REST_POS
	return _last_rest_hand_pos


func _right_elbow_rest_main_pos() -> Vector3:
	var yumeka := _background_yumeka()
	if yumeka != null and yumeka.has_method(&"get_right_elbow_rest_main_world_pos"):
		return yumeka.call(&"get_right_elbow_rest_main_world_pos")
	return FALLBACK_ELBOW_REST_POS


func _right_hand_rest_basis() -> Basis:
	var yumeka := _background_yumeka()
	if yumeka != null and yumeka.has_method(&"get_right_hand_rest_main_world_basis"):
		return yumeka.call(&"get_right_hand_rest_main_world_basis")
	return Basis(
		Vector3(0.89, 0.36, -0.28),
		Vector3(-0.37, 0.22, -0.90),
		Vector3(-0.26, 0.90, 0.33),
	).orthonormalized()


# --------------------------------------------------------------------------- #
# Foreground Hand Visual (Rigged GLB with Articulated Placeholder Fallback)
# --------------------------------------------------------------------------- #

func _ensure_hand_visual() -> void:
	if _hand_root != null and is_instance_valid(_hand_root):
		return
	_hand_root = Node3D.new()
	_hand_root.name = "ForegroundHand"
	_hand_root.visible = false
	add_child(_hand_root)
	_build_hand_model()


func _build_hand_model() -> void:
	if _hand_visual != null and is_instance_valid(_hand_visual):
		_hand_root.remove_child(_hand_visual)
		_hand_visual.free()
		_hand_visual = null
	_hand_skeleton = null
	_ph_upper = null
	_ph_lower = null
	_ph_hand = null
	_ph_index = null
	_ph_curled_group = null
	_b_upper = -1
	_b_upper_twist = -1
	_b_lower = -1
	_b_lower_twist = -1
	_b_hand = -1
	_b_idx_int = -1
	_b_idx_dist = -1
	_finger_indices.clear()
	_finger_rest_quats.clear()
	_gesture_delta_quats.clear()
	_hand_materials.clear()
	_arm_l1 = FALLBACK_ARM_L1
	_arm_l2 = FALLBACK_ARM_L2
	_poke_tip_in_hand_local = FALLBACK_POKE_TIP_LOCAL

	var packed: PackedScene = null
	if not _force_placeholder and ResourceLoader.exists(HAND_GLB_PATH, "PackedScene"):
		packed = load(HAND_GLB_PATH) as PackedScene

	if packed != null:
		_hand_visual = packed.instantiate() as Node3D
		if _hand_visual != null:
			_hand_visual.name = "YumekaHandRelay"
			_hand_root.add_child(_hand_visual)
			_strip_collisions(_hand_visual)
			_apply_hand_materials(_hand_visual)
			if _bind_hand_skeleton(_hand_visual):
				_using_placeholder = false
				return
			# Loaded GLB lacks expected right-arm skeleton -> fall back cleanly.
			_hand_root.remove_child(_hand_visual)
			_hand_visual.free()
			_hand_visual = null

	_hand_visual = _build_placeholder_hand()
	_using_placeholder = true
	_hand_root.add_child(_hand_visual)


func _bind_hand_skeleton(root_node: Node) -> bool:
	var skels: Array = []
	_walk(root_node, func(node: Node) -> void:
		if node is Skeleton3D and skels.is_empty():
			skels.append(node)
	)
	if skels.is_empty():
		return false
	var skel: Skeleton3D = skels[0]
	var b_upper := skel.find_bone("UpperArm_R")
	var b_lower := skel.find_bone("LowerArm_R")
	var b_hand := skel.find_bone("Hand_R")
	if b_upper < 0 or b_lower < 0 or b_hand < 0:
		return false

	_hand_skeleton = skel
	_b_upper = b_upper
	_b_upper_twist = skel.find_bone("UpperArm_twist_R")
	_b_lower = b_lower
	_b_lower_twist = skel.find_bone("LowerArm_twist_R")
	_b_hand = b_hand
	_b_idx_int = skel.find_bone("IndexIntermediate_R")
	_b_idx_dist = skel.find_bone("IndexDistal_R")
	if _b_lower_twist >= 0:
		_lower_twist_rest_q = skel.get_bone_rest(_b_lower_twist).basis.get_rotation_quaternion()

	# Dynamically measure exact 1:6,667 upper-arm & forearm lengths from Skeleton3D rest poses.
	var p_sh := skel.get_bone_global_rest(_b_upper).origin
	var p_el := skel.get_bone_global_rest(_b_lower).origin
	var p_wr := skel.get_bone_global_rest(_b_hand).origin
	_arm_l1 = maxf(p_sh.distance_to(p_el), 100.0)
	_arm_l2 = maxf(p_el.distance_to(p_wr), 100.0)

	if _b_idx_int >= 0 and _b_idx_dist >= 0:
		var p_int := skel.get_bone_global_rest(_b_idx_int).origin
		var p_dist := skel.get_bone_global_rest(_b_idx_dist).origin
		_index_distal_len = maxf(p_int.distance_to(p_dist) * 0.985, 40.0)

	for bname in FINGER_BONES:
		var idx := skel.find_bone(bname)
		if idx >= 0:
			_finger_indices[bname] = idx
			_finger_rest_quats[idx] = skel.get_bone_rest(idx).basis.get_rotation_quaternion()

	# Precompute local delta quaternions for every gesture preset.
	for g_key in GESTURE_PRESETS.keys():
		var preset: Dictionary = GESTURE_PRESETS[g_key]
		var qmap := {}
		for bname in FINGER_BONES:
			var idx: int = _finger_indices.get(bname, -1)
			if idx < 0:
				continue
			var ang: Vector3 = preset.get(bname, Vector3.ZERO)
			var q := Quaternion.IDENTITY
			if absf(ang.z) > 1e-4:
				q = q * Quaternion(Vector3.BACK, deg_to_rad(ang.z))
			if absf(ang.x) > 1e-4:
				q = q * Quaternion(Vector3.RIGHT, deg_to_rad(ang.x))
			if absf(ang.y) > 1e-4:
				q = q * Quaternion(Vector3.UP, deg_to_rad(ang.y))
			qmap[idx] = q
		_gesture_delta_quats[g_key] = qmap

	# Measure exact index-fingertip pad offset in Hand_R local coordinates under FINGER_POKE.
	skel.reset_bone_poses()
	set_hand_gesture_blend(HandGesture.REST_RELAXED, HandGesture.FINGER_POKE, 1.0)
	if _b_idx_dist >= 0:
		var hand_rest := skel.get_bone_global_pose(_b_hand)
		var dist_posed := skel.get_bone_global_pose(_b_idx_dist)
		var tip_skel := dist_posed * Vector3(0.0, _index_distal_len, -INDEX_PAD_VENTRAL_OFFSET)
		_poke_tip_in_hand_local = hand_rest.affine_inverse() * tip_skel
	set_hand_gesture_blend(HandGesture.REST_RELAXED, HandGesture.FINGER_POKE, 0.0)
	return true


func _strip_collisions(node: Node) -> void:
	for child in node.get_children():
		if child is CollisionObject3D:
			node.remove_child(child)
			child.free()
			continue
		_strip_collisions(child)


func _apply_hand_materials(root_node: Node) -> void:
	_hand_materials.clear()
	_walk(root_node, func(node: Node) -> void:
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			return
		# Disable 180 m directional shadow-map casting on the 3 km foreground arm
		# so it never corrupts city shadow cascades; ground shadow is rendered by
		# our dedicated world-aligned soft penumbra projection (`FingerShadow`).
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = 1600.0
		for surf in mi.mesh.get_surface_count():
			var src := mi.get_active_material(surf) as StandardMaterial3D
			if src == null:
				continue
			var dup := src.duplicate() as StandardMaterial3D
			dup.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			dup.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT_WRAP
			dup.roughness = MATTE_ROUGHNESS
			dup.metallic = 0.0
			dup.metallic_specular = MATTE_SPECULAR
			var lower := src.resource_name.to_lower()
			var is_clothes := lower.contains("clothes") or lower.contains("jacket") or lower.contains("vest")
			dup.albedo_color = CLOTHES_TINT if is_clothes else BODY_TINT
			var base_bounce := CLOTHES_BOUNCE_DAY if is_clothes else BODY_BOUNCE_DAY
			if dup.albedo_texture != null:
				# Soft warm bedroom wall/desk bounce fill via the albedo texture itself:
				# counters main-world Sun backlighting so the brown cardigan & peach skin
				# match background Yumeka's bedroom lighting seamlessly with zero new lights.
				dup.emission_enabled = true
				dup.emission_texture = dup.albedo_texture
				dup.emission = Color(1.0, 0.96, 0.92)
				dup.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
				dup.emission_energy_multiplier = base_bounce
				_hand_materials.append({"mat": dup, "base_bounce": base_bounce})
			else:
				dup.emission_enabled = false
			mi.set_surface_override_material(surf, dup)
	)
	_sync_hand_material_lighting()


func _sync_hand_material_lighting() -> void:
	if _hand_materials.is_empty():
		return
	var night := CityNightLights.get_night_glow()
	var bounce_scale := lerpf(1.0, BOUNCE_NIGHT_SCALE, night)
	var bounce_col := Color(1.0, 0.96, 0.92).lerp(Color(1.0, 0.86, 0.68), night)
	for entry in _hand_materials:
		var mat: StandardMaterial3D = entry["mat"]
		var base_b: float = float(entry["base_bounce"])
		mat.emission = bounce_col
		mat.emission_energy_multiplier = base_b * bounce_scale


func _build_placeholder_hand() -> Node3D:
	# Articulated procedural right arm using the exact same bone-local axes as the
	# rigged GLB (+Y along segment, +Z dorsal up, +X outer-right / little-finger side)
	# so it executes the identical 2-Bone IK & 5-phase motion curve with zero errors.
	var root_node := Node3D.new()
	root_node.name = "PlaceholderHandRelay"

	var skin := StandardMaterial3D.new()
	skin.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	skin.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	skin.albedo_color = Color(0.92, 0.80, 0.74)
	skin.roughness = MATTE_ROUGHNESS
	skin.metallic = 0.0
	skin.metallic_specular = MATTE_SPECULAR

	var nail_mat := StandardMaterial3D.new()
	nail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	nail_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	nail_mat.albedo_color = Color(0.95, 0.88, 0.87)
	nail_mat.roughness = 0.52
	nail_mat.metallic = 0.0
	nail_mat.metallic_specular = 0.25

	var cuff_mat := StandardMaterial3D.new()
	cuff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	cuff_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	cuff_mat.albedo_color = Color(0.84, 0.86, 0.90)
	cuff_mat.roughness = 0.90
	cuff_mat.metallic = 0.0
	cuff_mat.metallic_specular = 0.14

	var sleeve_mat := StandardMaterial3D.new()
	sleeve_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	sleeve_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	sleeve_mat.albedo_color = Color(0.30, 0.18, 0.15)
	sleeve_mat.roughness = 0.92
	sleeve_mat.metallic = 0.0
	sleeve_mat.metallic_specular = 0.14

	# 1. UpperArm segment (origin = shoulder, length = _arm_l1 along +Y).
	_ph_upper = Node3D.new()
	_ph_upper.name = "PlaceholderUpperArm"
	root_node.add_child(_ph_upper)
	var ua_mesh := CylinderMesh.new()
	ua_mesh.top_radius = 195.0
	ua_mesh.bottom_radius = 228.0
	ua_mesh.height = _arm_l1
	ua_mesh.radial_segments = 20
	_add_placeholder_part(_ph_upper, "UpperSleeve", ua_mesh, Vector3(0.0, _arm_l1 * 0.5, 0.0), Vector3.ZERO, sleeve_mat)

	# 2. LowerArm segment (origin = elbow, length = _arm_l2 along +Y).
	_ph_lower = Node3D.new()
	_ph_lower.name = "PlaceholderLowerArm"
	root_node.add_child(_ph_lower)
	var la_mesh := CylinderMesh.new()
	la_mesh.top_radius = 165.0
	la_mesh.bottom_radius = 195.0
	la_mesh.height = _arm_l2 * 0.84
	la_mesh.radial_segments = 20
	_add_placeholder_part(_ph_lower, "LowerSleeve", la_mesh, Vector3(0.0, _arm_l2 * 0.42, 0.0), Vector3.ZERO, sleeve_mat)
	var cuff_mesh := CylinderMesh.new()
	cuff_mesh.top_radius = 135.0
	cuff_mesh.bottom_radius = 152.0
	cuff_mesh.height = _arm_l2 * 0.18
	cuff_mesh.radial_segments = 20
	_add_placeholder_part(_ph_lower, "ShirtCuff", cuff_mesh, Vector3(0.0, _arm_l2 * 0.91, 0.0), Vector3.ZERO, cuff_mat)

	# 3. Hand segment (origin = wrist, +Y -> fingers, +Z dorsal, +X pinky side).
	_ph_hand = Node3D.new()
	_ph_hand.name = "PlaceholderHand"
	root_node.add_child(_ph_hand)

	var wrist_mesh := CylinderMesh.new()
	wrist_mesh.top_radius = 96.0
	wrist_mesh.bottom_radius = 108.0
	wrist_mesh.height = 170.0
	wrist_mesh.radial_segments = 16
	_add_placeholder_part(_ph_hand, "Wrist", wrist_mesh, Vector3(0.0, 85.0, 0.0), Vector3.ZERO, skin)

	var palm_mesh := BoxMesh.new()
	palm_mesh.size = Vector3(260.0, 290.0, 110.0)
	_add_placeholder_part(_ph_hand, "Palm", palm_mesh, Vector3(0.0, 265.0, 0.0), Vector3.ZERO, skin)

	_ph_index = Node3D.new()
	_ph_index.name = "PlaceholderIndexPivot"
	_ph_index.position = Vector3(-92.0, 395.0, 0.0)
	_ph_hand.add_child(_ph_index)
	var idx_mesh := CapsuleMesh.new()
	idx_mesh.radius = 37.0
	idx_mesh.height = 385.0
	idx_mesh.radial_segments = 18
	idx_mesh.rings = 8
	_add_placeholder_part(_ph_index, "IndexFinger", idx_mesh, Vector3(0.0, 192.0, 0.0), Vector3.ZERO, skin)
	var nail_mesh := SphereMesh.new()
	nail_mesh.radius = 26.0
	nail_mesh.height = 52.0
	var nail := _add_placeholder_part(_ph_index, "IndexNail", nail_mesh, Vector3(0.0, 338.0, 24.0), Vector3.ZERO, nail_mat)
	nail.scale = Vector3(0.85, 1.15, 0.28)

	_ph_curled_group = Node3D.new()
	_ph_curled_group.name = "PlaceholderCurledPivot"
	_ph_curled_group.position = Vector3(36.0, 395.0, -8.0)
	_ph_hand.add_child(_ph_curled_group)
	for spec in [
		["MiddleFinger", Vector3(-34.0, 110.0, 0.0), 34.0, 220.0],
		["RingFinger", Vector3(36.0, 102.0, 0.0), 31.0, 200.0],
		["LittleFinger", Vector3(102.0, 88.0, 0.0), 27.0, 175.0],
	]:
		var cap := CapsuleMesh.new()
		cap.radius = float(spec[2])
		cap.height = float(spec[3])
		cap.radial_segments = 14
		cap.rings = 6
		_add_placeholder_part(_ph_curled_group, String(spec[0]), cap, spec[1] as Vector3, Vector3.ZERO, skin)

	var thumb_cap := CapsuleMesh.new()
	thumb_cap.radius = 34.0
	thumb_cap.height = 175.0
	_add_placeholder_part(_ph_hand, "Thumb", thumb_cap, Vector3(-125.0, 210.0, -35.0), Vector3(-0.35, 0.0, -0.55), skin)

	return root_node


func _add_placeholder_part(parent: Node3D, part_name: String, mesh: Mesh, pos: Vector3,
		rot: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = mesh
	mi.position = pos
	mi.rotation = rot
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 1600.0
	parent.add_child(mi)
	return mi


func _walk(node: Node, fn: Callable) -> void:
	fn.call(node)
	for child in node.get_children():
		_walk(child, fn)


# --------------------------------------------------------------------------- #
# Ground Shadow, Pulsing Amber Warning Circle & Impact Shockwave VFX
# --------------------------------------------------------------------------- #

func _ensure_warning_visuals() -> void:
	if _warning_root != null and is_instance_valid(_warning_root):
		return
	_warning_root = Node3D.new()
	_warning_root.name = "HazardWarning"
	_warning_root.visible = false
	add_child(_warning_root)

	# 1. Soft giant finger ground shadow (penumbra tightens & darkens as finger approaches).
	var shadow_mesh := QuadMesh.new()
	shadow_mesh.size = Vector2(460.0, 460.0)
	_shadow_mat = ShaderMaterial.new()
	var shadow_shader := Shader.new()
	shadow_shader.code = """
shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled;

uniform float u_progress = 0.0;
uniform float u_alpha_scale = 1.0;
uniform float u_night = 0.0;
uniform vec2 u_arm_dir = vec2(0.73, 0.68);

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0; // [-1, 1] across 460 m (1.0 == 230 m)
	float tight = mix(1.48, 0.96, smoothstep(0.0, 1.0, u_progress));
	// Core fingertip shadow centered at (0, 0)
	float r_tip = length(p / vec2(0.56 * tight));
	float m_tip = exp(-r_tip * r_tip * 1.95);
	// Trailing hand & forearm canopy extending along +u_arm_dir (southeast)
	vec2 d_arm = p - u_arm_dir * (0.48 * tight);
	float along = dot(d_arm, u_arm_dir);
	vec2 perp = d_arm - u_arm_dir * along;
	float r_arm = length(vec2(along / (0.86 * tight), length(perp) / (0.52 * tight)));
	float m_arm = exp(-r_arm * r_arm * 1.65) * 0.78;
	float mask = clamp(1.0 - (1.0 - m_tip) * (1.0 - m_arm), 0.0, 1.0);
	float edge_fade = 1.0 - smoothstep(0.72, 1.0, length(p));
	float peak = mix(0.30, 0.68, smoothstep(0.0, 1.0, u_progress)) * mix(1.0, 0.56, u_night);
	ALBEDO = mix(vec3(0.06, 0.09, 0.16), vec3(0.03, 0.04, 0.09), u_night);
	ALPHA = clamp(mask * edge_fade * peak * u_alpha_scale, 0.0, 0.76);
}
"""
	_shadow_mat.shader = shadow_shader
	var arm_xz := Vector2(_last_shoulder_pos.x - _target.x, _last_shoulder_pos.z - _target.z)
	if arm_xz.length_squared() < 1e-5:
		arm_xz = Vector2(0.22, 0.97)
	_shadow_mat.set_shader_parameter(&"u_arm_dir", arm_xz.normalized())

	_shadow_quad = MeshInstance3D.new()
	_shadow_quad.name = "FingerShadow"
	_shadow_quad.mesh = shadow_mesh
	_shadow_quad.material_override = _shadow_mat
	_shadow_quad.rotation_degrees.x = -90.0
	# Clears 0.15 m raised sidewalks cleanly with zero Z-fighting.
	_shadow_quad.position = Vector3(0.0, 0.24, 0.0)
	_shadow_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_warning_root.add_child(_shadow_quad)

	# 2. Pulsing amber warning circle (radius = POKE_RADIUS = 110 m).
	var warn_mesh := QuadMesh.new()
	var warn_size := POKE_RADIUS * 2.18
	warn_mesh.size = Vector2(warn_size, warn_size)
	_warn_mat = ShaderMaterial.new()
	var warn_shader := Shader.new()
	warn_shader.code = """
shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled;

uniform float u_progress = 0.0;
uniform float u_time = 0.0;
uniform float u_alpha_scale = 1.0;

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.18; // radius 1.0 == POKE_RADIUS (110 m)
	float r = length(p);
	if (r > 1.06) {
		discard;
	}
	float pulse = 0.5 + 0.5 * sin(u_time * mix(7.5, 16.0, u_progress));
	// Crisp outer perimeter ring at r = 1.0
	float outer = smoothstep(0.945, 0.975, r) * (1.0 - smoothstep(1.015, 1.045, r));
	// Subtle hazard tick accents around outer ring
	float ang = atan(p.y, p.x);
	float ticks = step(0.18, fract((ang / 6.2831853) * 24.0 + u_time * 0.12));
	float outer_bright = outer * mix(0.68, 1.0, ticks);
	// Expanding progress ring sweeping from center out to 1.0 on impact
	float sweep_r = mix(0.12, 0.99, u_progress);
	float sweep = smoothstep(sweep_r - 0.045, sweep_r - 0.008, r) * (1.0 - smoothstep(sweep_r + 0.008, sweep_r + 0.032, r));
	// Translucent amber fill inside the danger zone
	float fill = (1.0 - smoothstep(0.96, 1.0, r)) * (0.13 + 0.10 * pulse + 0.10 * u_progress);
	// Subtle inner bullseye ring at r = 0.42
	float inner = smoothstep(0.395, 0.415, r) * (1.0 - smoothstep(0.435, 0.455, r)) * 0.42;

	vec3 amber = vec3(1.00, 0.62, 0.22);
	vec3 hot = vec3(1.00, 0.88, 0.58);
	vec3 danger = vec3(1.00, 0.36, 0.16);
	vec3 base_col = mix(amber, danger, smoothstep(0.55, 1.0, u_progress) * 0.55);
	vec3 col = mix(base_col, hot, clamp(sweep * 0.85 + outer_bright * 0.35, 0.0, 1.0));
	float alpha = clamp(fill + outer_bright * (0.78 + 0.20 * pulse) + sweep * 0.88 + inner, 0.0, 0.95);
	ALBEDO = col;
	ALPHA = alpha * clamp(u_alpha_scale, 0.0, 1.0);
}
"""
	_warn_mat.shader = warn_shader

	_warn_quad = MeshInstance3D.new()
	_warn_quad.name = "WarningCircle"
	_warn_quad.mesh = warn_mesh
	_warn_quad.material_override = _warn_mat
	_warn_quad.rotation_degrees.x = -90.0
	_warn_quad.position = Vector3(0.0, 0.34, 0.0)
	_warn_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_warning_root.add_child(_warn_quad)


func _update_warning_visuals(progress: float, shadow_alpha: float, show_circle: bool,
		warn_alpha := 1.0) -> void:
	if _shadow_mat != null:
		_shadow_mat.set_shader_parameter(&"u_progress", clampf(progress, 0.0, 1.0))
		_shadow_mat.set_shader_parameter(&"u_alpha_scale", clampf(shadow_alpha, 0.0, 1.0))
		_shadow_mat.set_shader_parameter(&"u_night", CityNightLights.get_night_glow())
	if _warn_quad != null:
		_warn_quad.visible = show_circle
	if show_circle and _warn_mat != null:
		_warn_mat.set_shader_parameter(&"u_progress", clampf(progress, 0.0, 1.0))
		_warn_mat.set_shader_parameter(&"u_time", _phase_time)
		_warn_mat.set_shader_parameter(&"u_alpha_scale", clampf(warn_alpha, 0.0, 1.0))


func _spawn_impact_vfx(center: Vector3) -> void:
	var burst := Node3D.new()
	burst.name = "PokeShockwave"
	burst.position = Vector3(center.x, 0.5, center.z)
	_vfx_root.add_child(burst)

	# Giant expanding shockwave ring (110 m -> 270 m).
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 0.82
	ring_mesh.outer_radius = 1.0
	ring_mesh.rings = 48
	ring_mesh.ring_segments = 8
	var ring := MeshInstance3D.new()
	ring.mesh = ring_mesh
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	ring_mat.albedo_color = Color(1.0, 0.85, 0.56, 0.86)
	ring.material_override = ring_mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.scale = Vector3(POKE_RADIUS * 0.72, 6.0, POKE_RADIUS * 0.72)
	burst.add_child(ring)

	var tween := burst.create_tween().set_parallel(true)
	tween.tween_property(ring, "scale", Vector3(POKE_RADIUS * 2.45, 2.5, POKE_RADIUS * 2.45), 0.85) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(ring_mat, "albedo_color:a", 0.0, 0.88)

	# 14 smooth soft-edged billowing dust clouds erupting around the fingertip rim.
	var puff_mesh := SphereMesh.new()
	puff_mesh.radial_segments = 18
	puff_mesh.rings = 10
	var dust_shader := Shader.new()
	dust_shader.code = """
shader_type spatial;
render_mode unshaded, depth_draw_never;

uniform vec3 u_color : source_color = vec3(0.80, 0.70, 0.58);
uniform float u_alpha = 0.56;

void fragment() {
	float fres = pow(clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 1.65);
	ALBEDO = u_color;
	ALPHA = clamp(fres * u_alpha, 0.0, 0.72);
}
"""
	var night := CityNightLights.get_night_glow()
	var dust_col := Color(0.82, 0.73, 0.62).lerp(Color(0.36, 0.38, 0.48), night * 0.65)
	var puff_count := 14
	for i in puff_count:
		var ang := float(i) * TAU / float(puff_count) + _rng.randf_range(-0.14, 0.14)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var puff := MeshInstance3D.new()
		puff.mesh = puff_mesh
		var puff_mat := ShaderMaterial.new()
		puff_mat.shader = dust_shader
		puff_mat.set_shader_parameter(&"u_color", dust_col)
		puff_mat.set_shader_parameter(&"u_alpha", 0.58)
		puff.material_override = puff_mat
		puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var start_r := _rng.randf_range(POKE_RADIUS * 0.42, POKE_RADIUS * 0.88)
		puff.position = dir * start_r + Vector3(0.0, _rng.randf_range(4.0, 14.0), 0.0)
		var base_sz := _rng.randf_range(18.0, 34.0)
		puff.scale = Vector3.ONE * base_sz
		burst.add_child(puff)
		var end_pos := puff.position + dir * _rng.randf_range(55.0, 130.0) \
				+ Vector3(0.0, _rng.randf_range(34.0, 78.0), 0.0)
		var dur := _rng.randf_range(1.15, 1.55)
		tween.tween_property(puff, "position", end_pos, dur) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(puff, "scale", Vector3.ONE * (base_sz * 2.3), dur)
		tween.tween_property(puff_mat, "shader_parameter/u_alpha", 0.0, dur)

	tween.chain().tween_callback(burst.queue_free)


# --------------------------------------------------------------------------- #
# Debug / Test Inspection Helpers
# --------------------------------------------------------------------------- #

func debug_force_placeholder(enabled: bool) -> void:
	_force_placeholder = enabled
	if _hand_root != null and is_instance_valid(_hand_root):
		_build_hand_model()


func debug_state() -> Dictionary:
	var phase_names := {
		Phase.IDLE: "idle",
		Phase.RAISE: "raise",
		Phase.WINDUP: "windup",
		Phase.HOLD: "hold",
		Phase.RETRACT: "retract",
		Phase.RETURN: "return",
	}
	var kind_names := {
		HazardKind.NONE: "none",
		HazardKind.FINGER_POKE: "finger_poke",
	}
	return {
		"enabled": _is_enabled(),
		"active": _phase != Phase.IDLE,
		"phase": phase_names.get(_phase, "idle"),
		"phase_time": _phase_time,
		"hazard": kind_names.get(_hazard, "none"),
		"target": _target,
		"fingertip_pos": _last_fingertip_pos,
		"shoulder_pos": _last_shoulder_pos,
		"arm_root_pos": _hand_root.global_position if _hand_root != null else Vector3.ZERO,
		"elbow_pos": _last_elbow_pos,
		"wrist_pos": _last_wrist_pos,
		"rest_hand_pos": _last_rest_hand_pos,
		"elbow_bend_deg": _last_elbow_bend_deg,
		"gesture_weight": _gesture_weight,
		"arm_l1": _arm_l1,
		"arm_l2": _arm_l2,
		"ik_stretch": _last_ik_stretch,
		"hand_visible": _hand_root != null and _hand_root.visible,
		"warning_visible": _warn_quad != null and _warn_quad.visible,
		"shadow_visible": _shadow_quad != null and _shadow_quad.visible and _warning_root != null and _warning_root.visible,
		"using_placeholder": _using_placeholder,
		"has_skeleton": _hand_skeleton != null,
		"bone_count": _hand_skeleton.get_bone_count() if _hand_skeleton != null else 0,
		"next_auto_in": _next_auto_in,
		"trigger_count": _trigger_count,
		"last_impact": _last_impact_summary.duplicate(),
	}
