extends SceneTree
## Automated biomechanical verification suite for the standalone giant turning prototype.
## Run with:
##   XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --fixed-fps 60 --script res://prototypes/giant_turn/turn_playtest.gd

const DT := 1.0 / 60.0
const GIANT_SCENE := preload("res://prototypes/giant_turn/giant_turn_actor.tscn")

var _passed := 0
var _failed := 0
var _giant: CharacterBody3D


func _init() -> void:
	call_deferred("_run_all")


func _check(cond: bool, label: String, detail := "") -> void:
	if cond:
		_passed += 1
		print("[PASS] %s%s" % [label, (" — " + detail) if detail != "" else ""])
	else:
		_failed += 1
		push_error("[FAIL] %s%s" % [label, (" — " + detail) if detail != "" else ""])
		print("[FAIL] %s%s" % [label, (" — " + detail) if detail != "" else ""])


func _spawn_giant() -> CharacterBody3D:
	var g := GIANT_SCENE.instantiate() as CharacterBody3D
	root.add_child(g)
	return g


func _run_all() -> void:
	_giant = _spawn_giant()
	await process_frame
	_giant.set_skin_by_name(&"Kawaii")
	_giant.reset_turn_state(Vector3.ZERO, 0.0)

	_test_cascade_order(1.0)
	_test_cascade_order(-1.0)
	_test_spine_s_curve_and_shoulders()
	_test_lean_scaling_and_weight_shift()
	_test_asymmetric_arms_and_bag_clearance()
	_test_standing_pivot_90_and_180()
	_test_walking_gentle_vs_sharp_turns()
	_test_all_skins_and_continuity()

	print("\n=== GIANT TURN PROTOTYPE TEST SUMMARY: %d passed, %d failed ===" % [_passed, _failed])
	_giant.queue_free()
	await process_frame
	quit(0 if _failed == 0 else 1)


func _test_cascade_order(dir: float) -> void:
	var tag := "LEFT" if dir > 0.0 else "RIGHT"
	_giant.reset_turn_state(Vector3.ZERO, 0.0)
	var target := dir * PI * 0.5 # 90 deg

	var t_eye := -1.0
	var t_head := -1.0
	var t_chest := -1.0
	var t_pelvis := -1.0
	var t_feet := -1.0

	var early_head_lead_ok := false
	var peak_head_rel := 0.0
	var chest_ratio_samples: Array[float] = []
	var max_eye_lead := 0.0

	for frame in 180:
		var t := float(frame + 1) * DT
		_giant.step_turn_demo(target, 0.0, DT)
		var tel: Dictionary = _giant.get_turn_telemetry()

		var eye_prog := dir * angle_difference(0.0, tel["bone_eye_world_yaw"])
		var head_prog := dir * angle_difference(0.0, tel["bone_head_world_yaw"])
		var chest_prog := dir * angle_difference(0.0, tel["bone_chest_world_yaw"])
		var pelvis_prog := dir * angle_difference(0.0, tel["pelvis_world_yaw"])
		var feet_prog := dir * angle_difference(0.0, tel["feet_mean_world_yaw"])

		# First crossing of visible onset threshold (5 deg for eye/head/chest/pelvis/feet).
		if t_eye < 0.0 and eye_prog >= deg_to_rad(5.0):
			t_eye = t
		if t_head < 0.0 and head_prog >= deg_to_rad(8.0):
			t_head = t
		if t_chest < 0.0 and chest_prog >= deg_to_rad(8.0):
			t_chest = t
		if t_pelvis < 0.0 and pelvis_prog >= deg_to_rad(8.0):
			t_pelvis = t
		if t_feet < 0.0 and feet_prog >= deg_to_rad(8.0):
			t_feet = t

		max_eye_lead = maxf(max_eye_lead, dir * float(tel["eye_local_yaw"]))
		var head_rel: float = dir * float(tel["head_rel_pelvis"])
		var chest_rel: float = dir * float(tel["chest_rel_pelvis"])
		peak_head_rel = maxf(peak_head_rel, head_rel)

		# Early window: head clearly turned while pelvis & feet haven't followed yet!
		if t >= 0.10 and t <= 0.28 and head_prog > deg_to_rad(18.0) and pelvis_prog < deg_to_rad(6.0) and feet_prog < deg_to_rad(2.0):
			early_head_lead_ok = true

		# Sample chest-to-head ratio during active established twist.
		if t >= 0.25 and head_rel > deg_to_rad(25.0):
			chest_ratio_samples.append(chest_rel / head_rel)

	var avg_ratio := 0.0
	for r in chest_ratio_samples:
		avg_ratio += r
	if not chest_ratio_samples.is_empty():
		avg_ratio /= float(chest_ratio_samples.size())

	_check(
		t_eye > 0.0 and t_head > 0.0 and t_chest > 0.0 and t_pelvis > 0.0 and t_feet > 0.0
		and t_eye < t_head and t_head < t_chest and t_chest < t_pelvis and t_pelvis <= t_feet + 0.02,
		"Cascade %s follows Eye -> Head -> Chest -> Pelvis -> Feet onset order" % tag,
		"t_eye=%.3f t_head=%.3f t_chest=%.3f t_pelvis=%.3f t_feet=%.3f" % [t_eye, t_head, t_chest, t_pelvis, t_feet]
	)
	_check(
		early_head_lead_ok and max_eye_lead > deg_to_rad(5.0) and peak_head_rel > deg_to_rad(38.0),
		"Cascade %s: eyes & head lead clearly before body/feet follow" % tag,
		"eye_lead=%.1f deg, peak_head_rel=%.1f deg" % [rad_to_deg(max_eye_lead), rad_to_deg(peak_head_rel)]
	)
	_check(
		avg_ratio >= 0.36 and avg_ratio <= 0.62,
		"Cascade %s: chest twists to ~half of head turn" % tag,
		"avg chest/head ratio=%.2f (n=%d)" % [avg_ratio, chest_ratio_samples.size()]
	)


func _test_spine_s_curve_and_shoulders() -> void:
	var skel: Skeleton3D = _giant.get_node("Model/metarig/Skeleton3D")
	for dir in [1.0, -1.0]:
		var tag := "LEFT" if dir > 0.0 else "RIGHT"
		_giant.reset_turn_state(Vector3.ZERO, 0.0)
		var saw_s_curve := false
		var saw_shoulder_counter := false
		var max_twist_deg := 0.0
		var sample_detail := ""

		for frame in 60:
			_giant.step_turn_demo(dir * PI * 0.5, 0.0, DT)
			var tel: Dictionary = _giant.get_turn_telemetry()
			var chest_twist: float = tel["chest_rel_pelvis"]
			max_twist_deg = maxf(max_twist_deg, absf(rad_to_deg(chest_twist)))

			if absf(chest_twist) > deg_to_rad(14.0):
				# Inspect actual pelvis/mid-spine/upper-spine roll deltas to verify S-curve inflection!
				var p_rot := skel.get_bone_pose_rotation(skel.find_bone("spine"))
				var s2_rot := skel.get_bone_pose_rotation(skel.find_bone("spine.002"))
				var s4_rot := skel.get_bone_pose_rotation(skel.find_bone("spine.004"))
				var p_rest := skel.get_bone_rest(skel.find_bone("spine")).basis.orthonormalized().get_rotation_quaternion()
				var s2_rest := skel.get_bone_rest(skel.find_bone("spine.002")).basis.orthonormalized().get_rotation_quaternion()
				var s4_rest := skel.get_bone_rest(skel.find_bone("spine.004")).basis.orthonormalized().get_rotation_quaternion()
				var p_roll := (p_rest.inverse() * p_rot).get_euler().z
				var s2_roll := (s2_rest.inverse() * s2_rot).get_euler().z
				var s4_roll := (s4_rest.inverse() * s4_rot).get_euler().z

				# Pelvis & spine.004 roll opposite to mid-spine spine.002 => genuine S-curve, not rigid straight stick!
				if signf(p_roll) != signf(s2_roll) and signf(s4_roll) != signf(s2_roll) and absf(s2_roll) > 0.03:
					saw_s_curve = true

				# Shoulder counter-twist opposes chest_twist!
				var sh_c: float = tel["shoulder_counter_z"]
				var sh_line: float = tel["shoulder_line_local_yaw"]
				# Verify shoulder line yaw lags behind ribcage bone yaw (counter-twisted against ribcage!).
				var rib_local_yaw := angle_difference(tel["model_world_yaw"], tel["bone_chest_world_yaw"])
				if signf(sh_c) == -signf(chest_twist) and absf(sh_c) > 0.04 and absf(sh_line) < absf(rib_local_yaw) - 0.02:
					saw_shoulder_counter = true
					sample_detail = "p_roll=%.3f s2_roll=%.3f s4_roll=%.3f rib_yaw=%.1f deg sh_line=%.1f deg" % [
						p_roll, s2_roll, s4_roll, rad_to_deg(rib_local_yaw), rad_to_deg(sh_line)
					]

		_check(saw_s_curve and max_twist_deg > 16.0,
			"Spine %s turn forms genuine S-curve between chest and pelvis" % tag,
			"max_twist=%.1f deg %s" % [max_twist_deg, sample_detail])
		_check(saw_shoulder_counter,
			"Shoulders %s counter-twist slightly against chest torsion" % tag,
			sample_detail)


func _test_lean_scaling_and_weight_shift() -> void:
	# 1. Left turn leans LEFT, Right turn leans RIGHT!
	var left_lean_peak := _measure_peak_lean(1.0, 7.0, 1.5)
	var right_lean_peak := _measure_peak_lean(-1.0, 7.0, 1.5)
	_check(left_lean_peak > deg_to_rad(7.0) and right_lean_peak < -deg_to_rad(7.0),
		"Inward banking tilts LEFT on left turn and RIGHT on right turn",
		"left=+%.1f deg, right=%.1f deg" % [rad_to_deg(left_lean_peak), rad_to_deg(right_lean_peak)])

	# 2. Faster turn & faster walk produce progressively deeper inward lean!
	var gentle_lean := absf(_measure_continuous_curve_lean(0.28, 7.0))
	var sharp_walk_lean := absf(_measure_peak_lean(1.0, 7.0, 1.6))
	var fast_sharp_lean := absf(_measure_peak_lean(1.0, 13.5, 1.6))
	_check(gentle_lean > deg_to_rad(1.5) and sharp_walk_lean > gentle_lean + deg_to_rad(3.0) and fast_sharp_lean > sharp_walk_lean + deg_to_rad(2.0),
		"Inward lean increases with both turn sharpness and walking speed",
		"gentle=%.1f deg < sharp_7m/s=%.1f deg < fast_13.5m/s=%.1f deg" % [
			rad_to_deg(gentle_lean), rad_to_deg(sharp_walk_lean), rad_to_deg(fast_sharp_lean)
		])

	# 3. Standing turn weight presses onto inside support foot BEFORE outside leg lifts + knees bend + pelvis drops!
	for dir in [1.0, -1.0]:
		var tag := "LEFT" if dir > 0.0 else "RIGHT"
		_giant.reset_turn_state(Vector3.ZERO, 0.0)
		var idle_tel: Dictionary = _giant.get_turn_telemetry()
		var idle_drop: float = idle_tel["pelvis_drop_y"]
		var shift_before_lift := 0.0
		var lifted_outside := false
		var min_drop := idle_drop
		var min_knee_during_turn := 180.0
		var max_knee_during_turn := 0.0

		for frame in 120:
			_giant.step_turn_demo(dir * PI * 0.5, 0.0, DT)
			var tel: Dictionary = _giant.get_turn_telemetry()
			var outside_planted: bool = tel["right_planted"] if dir > 0.0 else tel["left_planted"]
			var inside_planted: bool = tel["left_planted"] if dir > 0.0 else tel["right_planted"]
			if not lifted_outside:
				if not outside_planted:
					lifted_outside = true
					shift_before_lift = tel["pelvis_shift_x"]
					_check(inside_planted, "Standing %s: inside foot stays planted when outside foot lifts" % tag)
			min_drop = minf(min_drop, tel["pelvis_drop_y"])
			if frame >= 15 and frame <= 90:
				var sup_knee: float = tel["left_knee_bend_deg"] if tel["left_planted"] else tel["right_knee_bend_deg"]
				min_knee_during_turn = minf(min_knee_during_turn, sup_knee)
				max_knee_during_turn = maxf(max_knee_during_turn, sup_knee)

		_check(lifted_outside and dir * shift_before_lift > 0.04,
			"Standing %s: weight presses onto inside support leg before outside leg lifts" % tag,
			"pelvis_shift_x=%.4f (expected %s > 0.04)" % [shift_before_lift, "+" if dir > 0 else "-"])
		_check(min_drop < idle_drop - 0.020 and min_knee_during_turn >= 20.0 and max_knee_during_turn <= 46.0,
			"Standing %s: pelvis lowers and knees stay micro-flexed for grounded mass" % tag,
			"idle_drop=%.3f -> turn_drop=%.3f, support knee=%.1f..%.1f deg" % [idle_drop, min_drop, min_knee_during_turn, max_knee_during_turn])


func _measure_peak_lean(dir: float, speed: float, turn_angle: float) -> float:
	_giant.reset_turn_state(Vector3.ZERO, 0.0)
	# Establish steady walking first.
	for _i in 30:
		_giant.step_turn_demo(0.0, speed, DT)
	var peak := 0.0
	for _i in 80:
		_giant.step_turn_demo(dir * turn_angle, speed, DT)
		var lean: float = _giant.get_turn_telemetry()["actual_torso_lean_rad"]
		if absf(lean) > absf(peak):
			peak = lean
	return peak


func _measure_continuous_curve_lean(rate: float, speed: float) -> float:
	_giant.reset_turn_state(Vector3.ZERO, 0.0)
	var yaw := 0.0
	var accum := 0.0
	var n := 0
	for frame in 120:
		yaw += rate * DT
		_giant.step_turn_demo(yaw, speed, DT)
		if frame >= 50:
			accum += _giant.get_turn_telemetry()["actual_torso_lean_rad"]
			n += 1
	return accum / maxf(float(n), 1.0)


func _test_asymmetric_arms_and_bag_clearance() -> void:
	var skel: Skeleton3D = _giant.get_node("Model/metarig/Skeleton3D")
	for dir in [1.0, -1.0]:
		var tag := "LEFT" if dir > 0.0 else "RIGHT"
		_giant.reset_turn_state(Vector3.ZERO, 0.0)
		for _i in 20:
			_giant.step_turn_demo(0.0, 7.0, DT)

		var sum_out_open := 0.0
		var sum_in_open := 0.0
		var sum_out_amp := 0.0
		var sum_in_amp := 0.0
		var samples := 0
		var min_bag_x_clearance := 99.0

		for frame in 55:
			_giant.step_turn_demo(dir * PI * 0.65, 7.0, DT)
			var tel: Dictionary = _giant.get_turn_telemetry()
			if frame >= 10 and frame <= 42:
				var out_open: float = tel["right_arm_open"] if dir > 0.0 else tel["left_arm_open"]
				var in_open: float = tel["left_arm_open"] if dir > 0.0 else tel["right_arm_open"]
				var out_amp: float = tel["right_arm_amp"] if dir > 0.0 else tel["left_arm_amp"]
				var in_amp: float = tel["left_arm_amp"] if dir > 0.0 else tel["right_arm_amp"]
				sum_out_open += out_open
				sum_in_open += in_open
				sum_out_amp += out_amp
				sum_in_amp += in_amp
				samples += 1

			# Check right forearm/hand clearance against yellow bear shoulder bag in pelvis (spine) rest frame!
			var spine_idx := skel.find_bone("spine")
			var inv_sp := skel.get_bone_global_pose(spine_idx).affine_inverse()
			var sp_rest := skel.get_bone_global_rest(spine_idx)
			var hand_r := sp_rest * (inv_sp * skel.get_bone_global_pose(skel.find_bone("hand.R")).origin)
			var forearm_r := sp_rest * (inv_sp * skel.get_bone_global_pose(skel.find_bone("forearm.R")).origin)
			for pt in [hand_r, forearm_r, hand_r.lerp(forearm_r, 0.5)]:
				if pt.z >= -0.08 and pt.z <= 0.115 and pt.y >= 0.87 and pt.y <= 1.12:
					# Positive means safely outside (-X further negative than -0.235)
					min_bag_x_clearance = minf(min_bag_x_clearance, -0.235 - pt.x)

		var avg_out_open := sum_out_open / float(samples)
		var avg_in_open := sum_in_open / float(samples)
		var avg_out_amp := sum_out_amp / float(samples)
		var avg_in_amp := sum_in_amp / float(samples)
		_check(avg_out_open > avg_in_open + 0.14 and avg_out_amp > avg_in_amp * 1.20,
			"Arms %s turn: outside arm opens & swings wider while inside arm tucks tighter" % tag,
			"open out=%.3f vs in=%.3f, amp out=%.3f vs in=%.3f" % [avg_out_open, avg_in_open, avg_out_amp, avg_in_amp])
		_check(min_bag_x_clearance > -0.015,
			"Arms %s turn: right arm clears Kawaii shoulder bag without clipping" % tag,
			"min_clearance=%.4f (99=never entered bag box)" % min_bag_x_clearance)


func _test_standing_pivot_90_and_180() -> void:
	for cfg in [
		{"name": "90° Left", "target": PI * 0.5, "min_steps": 2, "max_frames": 260},
		{"name": "90° Right", "target": -PI * 0.5, "min_steps": 2, "max_frames": 260},
		{"name": "180° U-Turn Left", "target": PI - 0.01, "min_steps": 4, "max_frames": 420},
	]:
		_giant.reset_turn_state(Vector3.ZERO, 0.0)
		var target: float = cfg["target"]
		var dir := 1.0 if target >= 0.0 else -1.0
		var step_sequence: Array[String] = []
		var prev_side := ""
		var max_l_pivot_slip := 0.0
		var max_r_pivot_slip := 0.0
		var prev_l_planted := true
		var prev_r_planted := true
		var prev_l_mode := -1
		var prev_r_mode := -1
		var prev_l_piv := Vector3.ZERO
		var prev_r_piv := Vector3.ZERO
		var heel_strikes := 0
		var pre_aimed_landings := 0
		var min_foot_sep := 999.0
		var saw_in_place_pivot := false
		var prev_l_yaw := 0.0
		var prev_r_yaw := 0.0

		for frame in int(cfg["max_frames"]):
			_giant.step_turn_demo(target, 0.0, DT)
			var tel: Dictionary = _giant.get_turn_telemetry()

			var cur_side: String = tel["standing_step_side"] if tel["standing_step_active"] else ""
			if cur_side != "" and cur_side != prev_side:
				step_sequence.append(cur_side)
			prev_side = cur_side

			# Measure TRUE world-space slip of the active contact pivot while planted!
			var l_pl: bool = tel["left_planted"]
			var r_pl: bool = tel["right_planted"]
			var l_mode: int = tel["left_pivot_mode"]
			var r_mode: int = tel["right_pivot_mode"]
			var l_piv: Vector3 = tel["left_heel_world"] if l_mode == 0 else tel["left_ball_world"]
			var r_piv: Vector3 = tel["right_heel_world"] if r_mode == 0 else tel["right_ball_world"]

			if frame > 0 and l_pl and prev_l_planted and l_mode == prev_l_mode:
				var slip := Vector2(l_piv.x - prev_l_piv.x, l_piv.z - prev_l_piv.z).length()
				max_l_pivot_slip = maxf(max_l_pivot_slip, slip)
				if absf(angle_difference(prev_l_yaw, tel["left_foot_world_yaw"])) > 0.002 and slip < 0.005:
					saw_in_place_pivot = true
			if frame > 0 and r_pl and prev_r_planted and r_mode == prev_r_mode:
				var slip := Vector2(r_piv.x - prev_r_piv.x, r_piv.z - prev_r_piv.z).length()
				max_r_pivot_slip = maxf(max_r_pivot_slip, slip)
				if absf(angle_difference(prev_r_yaw, tel["right_foot_world_yaw"])) > 0.002 and slip < 0.005:
					saw_in_place_pivot = true

			# Check touchdown heel-strike & pre-aimed toe!
			if l_pl and not prev_l_planted:
				if tel["left_last_landing_pitch"] < -0.14:
					heel_strikes += 1
				if tel["left_pre_land_yaw_err"] < deg_to_rad(8.0):
					pre_aimed_landings += 1
			if r_pl and not prev_r_planted:
				if tel["right_last_landing_pitch"] < -0.14:
					heel_strikes += 1
				if tel["right_pre_land_yaw_err"] < deg_to_rad(8.0):
					pre_aimed_landings += 1

			# Check zero shoe/ankle overlap.
			var l_ank: Vector3 = tel["left_ankle_world"]
			var r_ank: Vector3 = tel["right_ankle_world"]
			min_foot_sep = minf(min_foot_sep, Vector2(l_ank.x - r_ank.x, l_ank.z - r_ank.z).length())

			prev_l_planted = l_pl
			prev_r_planted = r_pl
			prev_l_mode = l_mode
			prev_r_mode = r_mode
			prev_l_piv = l_piv
			prev_r_piv = r_piv
			prev_l_yaw = tel["left_foot_world_yaw"]
			prev_r_yaw = tel["right_foot_world_yaw"]

		var final_tel: Dictionary = _giant.get_turn_telemetry()
		var final_pelvis_err := absf(angle_difference(final_tel["pelvis_world_yaw"], target))
		var final_feet_err := absf(angle_difference(final_tel["feet_mean_world_yaw"], target))
		var final_flat := absf(final_tel["left_foot_pitch"]) < 0.02 and absf(final_tel["right_foot_pitch"]) < 0.02

		# Verify strict alternation and outside-foot-first!
		var alternating := step_sequence.size() >= int(cfg["min_steps"])
		var expected_first := "R" if dir > 0.0 else "L"
		var first_is_outside := (not step_sequence.is_empty()) and step_sequence[0] == expected_first
		for i in range(1, step_sequence.size()):
			if step_sequence[i] == step_sequence[i - 1]:
				alternating = false

		_check(alternating and first_is_outside,
			"Standing %s: multi-step alternating small steps starting with outside foot" % cfg["name"],
			"steps=%s (count=%d)" % [str(step_sequence), step_sequence.size()])
		_check(max_l_pivot_slip < 0.015 and max_r_pivot_slip < 0.015 and saw_in_place_pivot,
			"Standing %s: planted support foot pivots in-place on heel/ball with ZERO slip" % cfg["name"],
			"max_slip L=%.4fm R=%.4fm, in_place_pivot=%s" % [max_l_pivot_slip, max_r_pivot_slip, str(saw_in_place_pivot)])
		_check(heel_strikes == step_sequence.size() and pre_aimed_landings == step_sequence.size() and final_flat,
			"Standing %s: every step pre-aims toe, lands heel-first, and rolls flat" % cfg["name"],
			"heel_strikes=%d/%d pre_aimed=%d/%d final_flat=%s" % [heel_strikes, step_sequence.size(), pre_aimed_landings, step_sequence.size(), str(final_flat)])
		_check(final_pelvis_err < deg_to_rad(5.0) and final_feet_err < deg_to_rad(6.0) and min_foot_sep > 1.35,
			"Standing %s: converges cleanly to target heading with safe foot separation" % cfg["name"],
			"pelvis_err=%.1f deg feet_err=%.1f deg min_sep=%.2fm" % [rad_to_deg(final_pelvis_err), rad_to_deg(final_feet_err), min_foot_sep])


func _test_walking_gentle_vs_sharp_turns() -> void:
	# Baseline straight walk cadence & stride.
	var straight := _simulate_walk_regime("straight", 0.0, 0.0, 7.0, 220)
	# Gentle continuous curve (~16 deg/s = 0.28 rad/s).
	var gentle := _simulate_walk_regime("gentle", 0.28, 0.0, 7.0, 220)
	# Sharp continuous/stepped left turn (target stays ahead by 75 deg so she turns sharply!).
	var sharp_l := _simulate_walk_regime("sharp_left", 0.0, deg_to_rad(78.0), 7.0, 240)
	# Sharp right turn.
	var sharp_r := _simulate_walk_regime("sharp_right", 0.0, -deg_to_rad(78.0), 7.0, 240)

	_check(
		gentle["avg_stride_mult"] > 0.94 and gentle["avg_cadence_mult"] < 1.06
		and gentle["toe_bias_deg"] > 2.5 and gentle["max_slip"] < 0.02,
		"Gentle walking turn: stride unchanged, toe biases subtly into curve, ZERO slip",
		"stride_mult=%.2f cadence=%.2f toe_bias=%.1f deg max_slip=%.4fm" % [
			gentle["avg_stride_mult"], gentle["avg_cadence_mult"], gentle["toe_bias_deg"], gentle["max_slip"]
		]
	)
	_check(
		sharp_l["avg_stride_mult"] < 0.72 and sharp_l["steps_per_sec"] > straight["steps_per_sec"] * 1.15
		and sharp_l["avg_r_step"] > sharp_l["avg_l_step"] * 1.20 and sharp_l["max_slip"] < 0.03,
		"Sharp LEFT walking turn: shorter & faster steps, outside (R) longer than inside (L), ZERO slip",
		"stride_mult=%.2f rate=%.2f vs straight %.2f steps/s; R=%.2fm > L=%.2fm; slip=%.4fm" % [
			sharp_l["avg_stride_mult"], sharp_l["steps_per_sec"], straight["steps_per_sec"],
			sharp_l["avg_r_step"], sharp_l["avg_l_step"], sharp_l["max_slip"]
		]
	)
	_check(
		sharp_r["avg_stride_mult"] < 0.72 and sharp_r["steps_per_sec"] > straight["steps_per_sec"] * 1.15
		and sharp_r["avg_l_step"] > sharp_r["avg_r_step"] * 1.20 and sharp_r["max_slip"] < 0.03,
		"Sharp RIGHT walking turn: shorter & faster steps, outside (L) longer than inside (R), ZERO slip",
		"stride_mult=%.2f rate=%.2f vs straight %.2f steps/s; L=%.2fm > R=%.2fm; slip=%.4fm" % [
			sharp_r["avg_stride_mult"], sharp_r["steps_per_sec"], straight["steps_per_sec"],
			sharp_r["avg_l_step"], sharp_r["avg_r_step"], sharp_r["max_slip"]
		]
	)
	# Fast sharp turns (13.0 m/s): verify ZERO leg crossing and clean ankle clearance!
	var fast_l := _simulate_walk_regime("fast_sharp_left", 0.0, deg_to_rad(85.0), 13.0, 200)
	var fast_r := _simulate_walk_regime("fast_sharp_right", 0.0, -deg_to_rad(85.0), 13.0, 200)
	_check(
		fast_l["min_ankle_sep"] > 1.35 and fast_r["min_ankle_sep"] > 1.35
		and fast_l["min_lat_order"] > 0.65 and fast_r["min_lat_order"] > 0.65,
		"Fast sharp walking turns (13 m/s): ZERO leg crossing or ankle overlap",
		"L_sep=%.2fm (lat=%.2fm), R_sep=%.2fm (lat=%.2fm)" % [
			fast_l["min_ankle_sep"], fast_l["min_lat_order"], fast_r["min_ankle_sep"], fast_r["min_lat_order"]
		]
	)

	_check(
		sharp_l["heel_strikes"] >= 3 and sharp_l["heel_strikes"] == sharp_l["total_landings"]
		and sharp_r["heel_strikes"] >= 3 and sharp_r["heel_strikes"] == sharp_r["total_landings"],
		"Sharp walking turns: every landing strikes heel-first",
		"L_turn=%d/%d R_turn=%d/%d" % [sharp_l["heel_strikes"], sharp_l["total_landings"], sharp_r["heel_strikes"], sharp_r["total_landings"]]
	)


func _simulate_walk_regime(kind: String, curve_rate: float, lead_offset: float, speed: float, frames: int) -> Dictionary:
	_giant.reset_turn_state(Vector3.ZERO, 0.0)
	var target := 0.0
	var prev_l_pl := true
	var prev_r_pl := true
	var prev_l_mode := -1
	var prev_r_mode := -1
	var prev_l_piv := Vector3.ZERO
	var prev_r_piv := Vector3.ZERO

	var l_steps: Array[float] = []
	var r_steps: Array[float] = []
	var total_landings := 0
	var heel_strikes := 0
	var max_slip := 0.0
	var sum_stride_mult := 0.0
	var sum_cadence_mult := 0.0
	var sum_toe_bias := 0.0
	var meas_frames := 0
	var min_ankle_sep := 999.0
	var min_lat_order := 999.0

	for frame in frames:
		if curve_rate != 0.0:
			target += curve_rate * DT
		elif lead_offset != 0.0:
			var cur_pelvis: float = _giant.get_turn_telemetry()["pelvis_world_yaw"]
			target = cur_pelvis + lead_offset
		_giant.step_turn_demo(target, speed, DT)
		var tel: Dictionary = _giant.get_turn_telemetry()

		var l_ank: Vector3 = tel["left_ankle_world"]
		var r_ank: Vector3 = tel["right_ankle_world"]
		var pyaw: float = tel["pelvis_world_yaw"]
		var left_axis := Vector3(-cos(pyaw), 0.0, sin(pyaw))
		min_ankle_sep = minf(min_ankle_sep, Vector2(l_ank.x - r_ank.x, l_ank.z - r_ank.z).length())
		min_lat_order = minf(min_lat_order, (l_ank - r_ank).dot(left_axis))

		var l_pl: bool = tel["left_planted"]
		var r_pl: bool = tel["right_planted"]
		var l_mode: int = tel["left_pivot_mode"]
		var r_mode: int = tel["right_pivot_mode"]
		var l_piv: Vector3 = tel["left_heel_world"] if l_mode == 0 else tel["left_ball_world"]
		var r_piv: Vector3 = tel["right_heel_world"] if r_mode == 0 else tel["right_ball_world"]

		# Skip first 45 warm-up frames before measuring steady-state turn metrics.
		if frame >= 45:
			meas_frames += 1
			sum_stride_mult += tel["turn_stride_mult"]
			sum_cadence_mult += tel["turn_cadence_mult"]
			if l_pl and prev_l_pl and l_mode == prev_l_mode:
				max_slip = maxf(max_slip, Vector2(l_piv.x - prev_l_piv.x, l_piv.z - prev_l_piv.z).length())
			if r_pl and prev_r_pl and r_mode == prev_r_mode:
				max_slip = maxf(max_slip, Vector2(r_piv.x - prev_r_piv.x, r_piv.z - prev_r_piv.z).length())
			if l_pl and not prev_l_pl:
				total_landings += 1
				l_steps.append(tel["left_last_step_len"])
				if tel["left_last_landing_pitch"] < -0.14:
					heel_strikes += 1
				sum_toe_bias += rad_to_deg(angle_difference(tel["pelvis_world_yaw"], tel["left_foot_world_yaw"] - 0.045))
			if r_pl and not prev_r_pl:
				total_landings += 1
				r_steps.append(tel["right_last_step_len"])
				if tel["right_last_landing_pitch"] < -0.14:
					heel_strikes += 1
				sum_toe_bias += rad_to_deg(angle_difference(tel["pelvis_world_yaw"], tel["right_foot_world_yaw"] + 0.045))

		prev_l_pl = l_pl
		prev_r_pl = r_pl
		prev_l_mode = l_mode
		prev_r_mode = r_mode
		prev_l_piv = l_piv
		prev_r_piv = r_piv

	var avg_l := 0.0
	for s in l_steps:
		avg_l += s
	if not l_steps.is_empty():
		avg_l /= float(l_steps.size())
	var avg_r := 0.0
	for s in r_steps:
		avg_r += s
	if not r_steps.is_empty():
		avg_r /= float(r_steps.size())
	var meas_sec := float(meas_frames) * DT
	var _unused := kind
	return {
		"avg_stride_mult": sum_stride_mult / maxf(float(meas_frames), 1.0),
		"avg_cadence_mult": sum_cadence_mult / maxf(float(meas_frames), 1.0),
		"steps_per_sec": float(total_landings) / maxf(meas_sec, 0.01),
		"avg_l_step": avg_l,
		"avg_r_step": avg_r,
		"total_landings": total_landings,
		"heel_strikes": heel_strikes,
		"max_slip": max_slip,
		"toe_bias_deg": sum_toe_bias / maxf(float(total_landings), 1.0),
		"min_ankle_sep": min_ankle_sep,
		"min_lat_order": min_lat_order,
	}


func _test_all_skins_and_continuity() -> void:
	# 1. Verify all 3 skins run through standing + walking turns with valid finite transforms and level planted feet.
	for sname: StringName in [&"Kawaii", &"Hina", &"Chibi Catgirl"]:
		_giant.set_skin_by_name(sname)
		_giant.reset_turn_state(Vector3.ZERO, 0.0)
		var max_jump := 0.0
		var prev_l := _giant.get_turn_telemetry()["left_ankle_world"] as Vector3
		var prev_r := _giant.get_turn_telemetry()["right_ankle_world"] as Vector3
		var finite_ok := true

		# Mid-turn reversal + walk transition stress test:
		# 0..70: standing turn left 120 deg
		# 70..140: mid-turn reverse right to -60 deg
		# 140..220: start walking into sharp right curve
		# 220..270: stop and settle
		for frame in 270:
			var target := deg_to_rad(120.0)
			var spd := 0.0
			if frame >= 70 and frame < 140:
				target = deg_to_rad(-60.0)
			elif frame >= 140 and frame < 220:
				target = deg_to_rad(-160.0)
				spd = 7.0
			elif frame >= 220:
				target = deg_to_rad(-160.0)
				spd = 0.0
			_giant.step_turn_demo(target, spd, DT)
			var tel: Dictionary = _giant.get_turn_telemetry()
			var cur_l: Vector3 = tel["left_ankle_world"]
			var cur_r: Vector3 = tel["right_ankle_world"]
			if not cur_l.is_finite() or not cur_r.is_finite():
				finite_ok = false
			max_jump = maxf(max_jump, maxf(cur_l.distance_to(prev_l), cur_r.distance_to(prev_r)))
			prev_l = cur_l
			prev_r = cur_r

		_check(finite_ok and max_jump < 0.75,
			"Skin %s: mid-turn reversal & walk/stop transitions stay smooth without ankle pops" % sname,
			"max_frame_ankle_jump=%.3fm (25.2m giant)" % max_jump)

	# 2. Verify multi-scale scaling (100m colossal giant standing turn keeps zero slip & clean convergence).
	_giant.set_skin_by_name(&"Kawaii")
	_giant.set_height_meters(100.0)
	_giant.reset_turn_state(Vector3.ZERO, 0.0)
	var max_big_slip := 0.0
	var prev_pl := true
	var prev_md := -1
	var prev_pv := Vector3.ZERO
	for f in 360:
		_giant.step_turn_demo(PI * 0.5, 0.0, DT)
		var tel: Dictionary = _giant.get_turn_telemetry()
		var pl: bool = tel["left_planted"]
		var md: int = tel["left_pivot_mode"]
		var pv: Vector3 = tel["left_heel_world"] if md == 0 else tel["left_ball_world"]
		if f > 0 and pl and prev_pl and md == prev_md:
			max_big_slip = maxf(max_big_slip, Vector2(pv.x - prev_pv.x, pv.z - prev_pv.z).length())
		prev_pl = pl
		prev_md = md
		prev_pv = pv
	var big_final: Dictionary = _giant.get_turn_telemetry()
	var big_err := absf(angle_difference(big_final["pelvis_world_yaw"], PI * 0.5))
	_check(max_big_slip < 0.02 and big_err < deg_to_rad(5.0) and int(big_final["standing_step_count"]) >= 3,
		"Colossal 100m giant scales standing pivot smoothly with ZERO slip",
		"max_slip=%.4fm err=%.1f deg steps=%d" % [max_big_slip, rad_to_deg(big_err), int(big_final["standing_step_count"])])
	_giant.set_height_meters(25.2)
