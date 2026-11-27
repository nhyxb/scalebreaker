extends SceneTree
## Automated biomechanical, visual-contact, multi-skin, and preview-scene verification
## for the giant's sit-crush (坐压) animation (unintegrated test stage).

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	seed(20261125)
	await _verify_kawaii_sit_crush_biomechanics()
	await _verify_walk_transition_and_pause_freeze()
	await _verify_all_three_skins()
	await _verify_kawaii_sit_idle_biomechanics()
	await _verify_sit_idle_transitions()
	await _verify_all_three_skins_sit_idle()
	await _verify_preview_scene_end_to_end()
	await process_frame
	print("Sit-crush & sit-idle tests: %d passed, %d failed" % [_checks - _failures, _failures])
	quit(1 if _failures else 0)


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures += 1
		push_error("FAIL  " + description)


func _skinned_min_y(skel: Skeleton3D, mi: MeshInstance3D, y_rest_min := -999.0, y_rest_max := 999.0) -> float:
	var mesh := mi.mesh
	var skin := mi.skin
	var bone_mats: Array[Transform3D] = []
	bone_mats.resize(skin.get_bind_count())
	for b in skin.get_bind_count():
		var bidx := skel.find_bone(skin.get_bind_name(b))
		bone_mats[b] = (skel.get_bone_global_pose(bidx) * skin.get_bind_pose(b)) if bidx >= 0 else Transform3D.IDENTITY
	var min_y := 999.0
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var inf := bones.size() / maxi(verts.size(), 1)
		for i in verts.size():
			var v := verts[i]
			if v.y < y_rest_min or v.y > y_rest_max:
				continue
			var p := Vector3.ZERO
			var wsum := 0.0
			for k in inf:
				var w := weights[i * inf + k]
				if w > 0.0001:
					p += (bone_mats[bones[i * inf + k]] * v) * w
					wsum += w
			if wsum > 0.001:
				p /= wsum
			min_y = minf(min_y, p.y)
	return min_y


func _back_hair_tip_rel_head(giant: CharacterBody3D, skel: Skeleton3D) -> float:
	var head_y := skel.get_bone_global_pose(skel.find_bone("Head")).origin.y
	var sum := 0.0
	var count := 0
	for c in giant.get("_hair_chains"):
		if c.zone == 3:
			sum += skel.get_bone_global_pose(c.bones[c.bones.size() - 1]).origin.y - head_y
			count += 1
	return sum / maxf(float(count), 1.0)


func _verify_kawaii_sit_crush_biomechanics() -> void:
	var giant := (load("res://scenes/giant.tscn") as PackedScene).instantiate() as CharacterBody3D
	root.add_child(giant)
	await process_frame
	giant.call("_set_skin", &"Kawaii")
	giant.show_motion(0.0, -1.0, 0.0)

	var skel: Skeleton3D = giant.get_node("Model/metarig/Skeleton3D")
	var shorts: MeshInstance3D = skel.get_node("Jean shorts")
	var body: MeshInstance3D = skel.get_node("Body")
	var idx_hip := skel.find_bone("spine")
	var idx_head := skel.find_bone("Head")
	var idx_knee_l := skel.find_bone("shin.L")
	var idx_knee_r := skel.find_bone("shin.R")
	var idx_foot_l := skel.find_bone("foot.L")
	var idx_foot_r := skel.find_bone("foot.R")
	var idx_hand_l := skel.find_bone("hand.L")
	var idx_hand_r := skel.find_bone("hand.R")

	var idle_hip := skel.get_bone_global_pose(idx_hip).origin
	var idle_foot_l := skel.get_bone_global_pose(idx_foot_l).origin
	var idle_hair_rel := _back_hair_tip_rel_head(giant, skel)

	var duration: float = giant.SIT_CRUSH_DURATION
	_check(duration >= 4.2 and duration <= 6.0, "Sit-crush has weighty long commitment duration (%.2fs)" % duration)

	var total_frames := int(round(duration * 60.0))
	var dt := 1.0 / 60.0

	var impact_count := 0
	var impact_t := -1.0
	var max_prep_down_vel := 0.0
	var max_drop_down_vel := 0.0
	var max_rise_up_vel := 0.0
	var prev_hip := idle_hip
	var prev_foot_l := idle_foot_l
	var prev_hand_l := skel.get_bone_global_pose(idx_hand_l).origin

	var max_frame_hip_jump := 0.0
	var max_frame_foot_jump := 0.0
	var max_frame_hand_jump := 0.0
	var min_knee_ahead_of_hip := INF
	var max_planted_foot_slip := 0.0
	var planted_foot_ref := Vector3.ZERO
	var planted_foot_captured := false
	var max_planted_foot_tilt := 0.0

	var prep_head_looked_down := false
	var prep_arms_spread_wide := false
	var prep_feet_wide_and_out := false
	var prep_back_straight := false
	var sit_butt_on_ground := false
	var sit_knees_splayed_wide := false
	var sit_hair_floated_up := false
	var hair_peak_rel := -999.0
	var hair_settled_rel := 999.0
	var rock_left_max := -999.0
	var rock_right_min := 999.0
	var rock_settled_abs := 999.0
	var rock_arms_clear_knees := true
	var push_hand_min_y := 999.0
	var push_hand_slip := 0.0
	var push_hand_ref := Vector3.ZERO
	var push_hand_captured := false
	var push_hip_at_70 := 0.0
	var push_hip_at_78 := 0.0
	var max_dust_hold := 0.0
	var dust_at_95 := 999.0

	for f in total_frames + 1:
		var t := float(f) / float(total_frames)
		var res: Dictionary = giant.show_sit_crush(t, dt)
		var hip := skel.get_bone_global_pose(idx_hip).origin
		var knee_l := skel.get_bone_global_pose(idx_knee_l).origin
		var knee_r := skel.get_bone_global_pose(idx_knee_r).origin
		var foot_l := skel.get_bone_global_pose(idx_foot_l).origin
		var foot_r := skel.get_bone_global_pose(idx_foot_r).origin
		var hand_l := skel.get_bone_global_pose(idx_hand_l).origin
		var hand_r := skel.get_bone_global_pose(idx_hand_r).origin
		var head_fwd := skel.get_bone_global_pose(idx_head).basis.orthonormalized() * Vector3.BACK
		var torso_up := skel.get_bone_global_pose(skel.find_bone("spine.003")).basis.orthonormalized() * Vector3.UP

		if res["impact_just_hit"]:
			impact_count += 1
			impact_t = t

		if f > 0:
			var vy := (hip.y - prev_hip.y) / dt
			if t >= 0.08 and t <= 0.28:
				max_prep_down_vel = maxf(max_prep_down_vel, -vy)
			elif t >= 0.30 and t <= 0.38:
				max_drop_down_vel = maxf(max_drop_down_vel, -vy)
			elif t >= 0.70 and t <= 0.94:
				max_rise_up_vel = maxf(max_rise_up_vel, vy)
			max_frame_hip_jump = maxf(max_frame_hip_jump, hip.distance_to(prev_hip))
			max_frame_foot_jump = maxf(max_frame_foot_jump, foot_l.distance_to(prev_foot_l))
			max_frame_hand_jump = maxf(max_frame_hand_jump, hand_l.distance_to(prev_hand_l))
		prev_hip = hip
		prev_foot_l = foot_l
		prev_hand_l = hand_l

		min_knee_ahead_of_hip = minf(min_knee_ahead_of_hip, knee_l.z - hip.z)
		min_knee_ahead_of_hip = minf(min_knee_ahead_of_hip, knee_r.z - hip.z)

		# Phase 1 checks (chair squat preparation)
		if t >= 0.08 and t <= 0.25 and head_fwd.y < -0.25:
			prep_head_looked_down = true
		if t >= 0.22 and t <= 0.29:
			if absf(hand_l.x - hand_r.x) > 0.74:
				prep_arms_spread_wide = true
			if foot_l.x > 0.22 and foot_r.x < -0.22 and giant._left.last_yaw > 0.45 and giant._right.last_yaw < -0.45:
				prep_feet_wide_and_out = true
			if torso_up.y > 0.94:
				prep_back_straight = true

		# Planted foot lock (no sliding while squatting, dropping, sitting, or pushing up)
		if t >= 0.23 and t <= 0.85:
			if not planted_foot_captured:
				planted_foot_ref = foot_l
				planted_foot_captured = true
			else:
				max_planted_foot_slip = maxf(max_planted_foot_slip, foot_l.distance_to(planted_foot_ref))
			max_planted_foot_tilt = maxf(max_planted_foot_tilt, maxf(absf(giant._left.last_pitch), absf(giant._left.last_roll)))

		# Phase 2 checks (impact & seated contact)
		if t >= 0.375 and t <= 0.42:
			var s_min := _skinned_min_y(skel, shorts)
			if s_min >= -0.018 and s_min <= 0.006:
				sit_butt_on_ground = true
			if knee_l.x > foot_l.x + 0.05 and knee_r.x < foot_r.x - 0.05 and knee_l.y > foot_l.y + 0.15:
				sit_knees_splayed_wide = true
			var hrel := _back_hair_tip_rel_head(giant, skel)
			hair_peak_rel = maxf(hair_peak_rel, hrel)
			if hrel > idle_hair_rel + 0.065:
				sit_hair_floated_up = true

		# Phase 3 checks (seated hold, left-right packing rock, hair settle, arm clearance)
		if t >= 0.45 and t <= 0.64:
			rock_left_max = maxf(rock_left_max, hip.x)
			rock_right_min = minf(rock_right_min, hip.x)
			if t >= 0.50 and t <= 0.62:
				hair_settled_rel = minf(hair_settled_rel, _back_hair_tip_rel_head(giant, skel))
			if t >= 0.46 and t <= 0.59:
				if hand_l.distance_to(knee_l) < 0.06 or hand_r.distance_to(knee_r) < 0.06:
					rock_arms_clear_knees = false
			max_dust_hold = maxf(max_dust_hold, float(res["dust_alpha"]))
		if t >= 0.645 and t <= 0.67:
			rock_settled_abs = minf(rock_settled_abs, absf(hip.x))

		# Phase 4 checks (ground push-off hands locked & hips rising)
		if t >= 0.695 and t <= 0.775:
			if not push_hand_captured:
				push_hand_ref = hand_l
				push_hand_captured = true
			else:
				push_hand_slip = maxf(push_hand_slip, hand_l.distance_to(push_hand_ref))
			if absf(t - 0.705) < 0.008:
				push_hand_min_y = minf(push_hand_min_y, _skinned_min_y(skel, body, 0.85, 1.05))
				push_hip_at_70 = hip.y
		if absf(t - 0.780) < 0.008:
			push_hip_at_78 = hip.y
		if t >= 0.945 and t <= 0.96:
			dust_at_95 = minf(dust_at_95, float(res["dust_alpha"]))

	var end_hip := skel.get_bone_global_pose(idx_hip).origin
	var end_foot_l := skel.get_bone_global_pose(idx_foot_l).origin

	_check(impact_count == 1 and is_equal_approx(impact_t, giant.SIT_CRUSH_IMPACT_TIME),
			"Sit-crush emits exactly one impact event at t=%.3f (got %d at %.3f)" % [giant.SIT_CRUSH_IMPACT_TIME, impact_count, impact_t])
	_check(max_drop_down_vel > max_prep_down_vel * 2.5 and max_drop_down_vel > max_rise_up_vel * 2.0,
			"Drop slam (%.2f/s) is much faster and heavier than prep squat (%.2f/s) and slow rise (%.2f/s)" % [
				max_drop_down_vel, max_prep_down_vel, max_rise_up_vel])
	_check(prep_head_looked_down, "Giant looks clearly down at target during preparation")
	_check(prep_feet_wide_and_out, "Feet step wide to both sides with toes pointed outward")
	_check(prep_arms_spread_wide, "Arms spread wide to both sides for balance during chair-squat")
	_check(prep_back_straight, "Back stays upright during the invisible-chair squat preparation")
	_check(sit_butt_on_ground, "Buttocks/shorts contact ground cleanly without floating or sinking")
	_check(sit_knees_splayed_wide, "Legs fold to sides with knees splayed wider than flat planted feet")
	_check(min_knee_ahead_of_hip > 0.05, "Knees stay anatomically in front of hips throughout sit & push-off (min dz=%.3f)" % min_knee_ahead_of_hip)
	_check(max_planted_foot_slip < 0.001 and max_planted_foot_tilt < 0.015,
			"Planted feet stay flat and locked with zero slip during squat/sit/push-off (slip=%.5f, tilt=%.4f)" % [max_planted_foot_slip, max_planted_foot_tilt])
	_check(sit_hair_floated_up and hair_settled_rel < hair_peak_rel - 0.045,
			"Hair floats clearly upward on slam (peak=%.4f vs idle=%.4f) and falls back down (settled=%.4f)" % [hair_peak_rel, idle_hair_rel, hair_settled_rel])
	_check(rock_left_max > 0.04 and rock_right_min < -0.04 and rock_settled_abs < 0.008,
			"Seated hold rocks weight left (+%.3f) then right (%.3f) and settles back to center (%.4f)" % [rock_left_max, rock_right_min, rock_settled_abs])
	_check(rock_arms_clear_knees, "Arms stay clear of knees during seated weight rock")
	_check(push_hand_min_y >= -0.020 and push_hand_min_y <= 0.025 and push_hand_slip < 0.030,
			"Both palms plant flush on ground with low slip during push-off (min_y=%.4f, slip=%.4f)" % [push_hand_min_y, push_hand_slip])
	_check(push_hip_at_78 > push_hip_at_70 + 0.035,
			"Hips rise steadily off the ground while hands push off (%.3f -> %.3f)" % [push_hip_at_70, push_hip_at_78])
	_check(max_dust_hold > 0.90 and dust_at_95 < 0.25,
			"Dust envelope lingers thick during hold (%.2f) and slowly dissipates during rise (%.2f)" % [max_dust_hold, dust_at_95])
	_check(end_hip.distance_to(idle_hip) < 0.02 and end_foot_l.distance_to(idle_foot_l) < 0.005,
			"Animation finishes cleanly back at standing idle stance")
	_check(max_frame_hip_jump < 0.085 and max_frame_foot_jump < 0.035 and max_frame_hand_jump < 0.095,
			"All joints move continuously without teleports (max frame jumps: hip=%.4f foot=%.4f hand=%.4f)" % [
				max_frame_hip_jump, max_frame_foot_jump, max_frame_hand_jump])

	giant.free()


func _verify_walk_transition_and_pause_freeze() -> void:
	var giant := (load("res://scenes/giant.tscn") as PackedScene).instantiate() as CharacterBody3D
	var floor := StaticBody3D.new()
	var ground_shape := BoxShape3D.new()
	ground_shape.size = Vector3(30.0, 1.0, 30.0)
	var ground_collision := CollisionShape3D.new()
	ground_collision.shape = ground_shape
	floor.add_child(ground_collision)
	floor.position.y = -0.5
	root.add_child(floor)
	root.add_child(giant)
	giant.position.y = 0.02
	await process_frame
	giant.call("_set_skin", &"Kawaii")
	var skel: Skeleton3D = giant.get_node("Model/metarig/Skeleton3D")
	var idx_hip := skel.find_bone("spine")
	var idx_foot_l := skel.find_bone("foot.L")

	# Enter the sit animation with a shoe already airborne and locked onto a landing.
	var had_locked_foot := false
	for i in 105:
		await physics_frame
		giant.velocity = Vector3(0.0, -1.0, -7.0)
		giant.move_and_slide()
		giant.show_motion(7.0, -1.0, 1.0 / 60.0)
		if giant.heavy_step_preview().get("locked", false):
			had_locked_foot = true
			break
	var pre_hip := skel.get_bone_global_pose(idx_hip).origin
	var pre_foot := skel.get_bone_global_pose(idx_foot_l).origin
	giant.show_sit_crush(0.0, 1.0 / 60.0)
	_check(had_locked_foot and giant.heavy_step_preview().is_empty(),
			"Entering a sit cancels the pending walking footfall")
	var entry_hip_jump := skel.get_bone_global_pose(idx_hip).origin.distance_to(pre_hip)
	var entry_foot_jump := skel.get_bone_global_pose(idx_foot_l).origin.distance_to(pre_foot)
	_check(entry_hip_jump < 0.005 and entry_foot_jump < 0.005,
			"Entering sit-crush from walking blends smoothly with zero frame-0 snap (hip=%.5f foot=%.5f)" % [entry_hip_jump, entry_foot_jump])

	# Advance to impact and test pause freeze (delta = 0.0 must freeze hair & face springs).
	var pause_t := 120.0 / 288.0
	for i in 121:
		giant.show_sit_crush(float(i) / 288.0, 1.0 / 60.0)
	giant.show_sit_crush(pause_t, 0.0)
	var frozen_hair := _back_hair_tip_rel_head(giant, skel)
	var frozen_hip := skel.get_bone_global_pose(idx_hip).origin
	var frozen_eye: Vector2 = giant.get("_eye_gaze")
	for i in 15:
		giant.show_sit_crush(pause_t, 0.0)
	_check(is_equal_approx(_back_hair_tip_rel_head(giant, skel), frozen_hair)
			and skel.get_bone_global_pose(idx_hip).origin.is_equal_approx(frozen_hip)
			and (giant.get("_eye_gaze") as Vector2).is_equal_approx(frozen_eye),
			"Pause (delta=0) completely freezes sit-crush pose, hair springs, and eye gaze")

	# Finish sit-crush mid-pose and blend smoothly back into idle locomotion.
	var pre_exit_hip := skel.get_bone_global_pose(idx_hip).origin
	giant.finish_sit_crush()
	giant.show_motion(0.0, -1.0, 1.0 / 60.0)
	var exit_jump := skel.get_bone_global_pose(idx_hip).origin.distance_to(pre_exit_hip)
	_check(exit_jump < 0.08, "Exiting sit-crush back to show_motion blends smoothly without instant snap (jump=%.4f)" % exit_jump)

	giant.free()
	floor.free()


func _verify_all_three_skins() -> void:
	var specs := [
		[&"Kawaii", "spine", "shin.L", "foot.L", "hand.L"],
		[&"Hina", "Hips_108", "Left knee_102", "Left ankle_101", "Left wrist_75"],
		[&"Chibi Catgirl", "DEF-spine_013", "DEF-shin.L_091", "DEF-foot.L_093", "DEF-hand.L_0221"],
	]
	for spec in specs:
		var sname: StringName = spec[0]
		var giant := (load("res://scenes/giant.tscn") as PackedScene).instantiate() as CharacterBody3D
		root.add_child(giant)
		await process_frame
		giant.call("_set_skin", sname)
		giant.show_motion(0.0, -1.0, 0.0)
		var skel: Skeleton3D = giant._active_skin.skeleton if giant._active_skin != null else giant.get_node("Model/metarig/Skeleton3D")
		var model: Node3D = giant.get_node("Model")
		var hip_i := skel.find_bone(spec[1])
		var knee_i := skel.find_bone(spec[2])
		var foot_i := skel.find_bone(spec[3])
		var hand_i := skel.find_bone(spec[4])

		var idle_hip := model.to_local(skel.to_global(skel.get_bone_global_pose(hip_i).origin))
		var min_hip_y := idle_hip.y
		var min_hand_y := 999.0
		var max_knee_x := 0.0
		var total_frames := 144
		for f in total_frames + 1:
			var t := float(f) / float(total_frames)
			giant.show_sit_crush(t, 1.0 / 30.0)
			var hip_m := model.to_local(skel.to_global(skel.get_bone_global_pose(hip_i).origin))
			var knee_m := model.to_local(skel.to_global(skel.get_bone_global_pose(knee_i).origin))
			var hand_m := model.to_local(skel.to_global(skel.get_bone_global_pose(hand_i).origin))
			min_hip_y = minf(min_hip_y, hip_m.y)
			min_hand_y = minf(min_hand_y, hand_m.y)
			max_knee_x = maxf(max_knee_x, absf(knee_m.x))
		giant.finish_sit_crush()
		_check(idle_hip.y - min_hip_y > 0.65 and min_hip_y > 0.01,
				"%s drops deeply into sit without sinking pelvis underground (idle=%.3f min=%.3f)" % [sname, idle_hip.y, min_hip_y])
		_check(max_knee_x > 0.25 and min_hand_y < 0.25,
				"%s splays knees outward (max_x=%.3f) and reaches ground for push-off (min_hand_y=%.3f)" % [sname, max_knee_x, min_hand_y])
		giant.free()


func _verify_kawaii_sit_idle_biomechanics() -> void:
	var giant := (load("res://scenes/giant.tscn") as PackedScene).instantiate() as CharacterBody3D
	root.add_child(giant)
	await process_frame
	giant.call("_set_skin", &"Kawaii")
	giant.show_motion(0.0, -1.0, 0.0)

	var skel: Skeleton3D = giant.get_node("Model/metarig/Skeleton3D")
	var shorts: MeshInstance3D = skel.get_node("Jean shorts")
	var idx_hip := skel.find_bone("spine")
	var idx_chest := skel.find_bone("spine.003")
	var idx_head := skel.find_bone("Head")
	var idx_knee_l := skel.find_bone("shin.L")
	var idx_knee_r := skel.find_bone("shin.R")
	var idx_foot_l := skel.find_bone("foot.L")
	var idx_foot_r := skel.find_bone("foot.R")
	var idx_hand_l := skel.find_bone("hand.L")
	var idx_hand_r := skel.find_bone("hand.R")

	var dt := 1.0 / 60.0
	var res0: Dictionary = giant.show_sit_idle(0.0, false)
	_check(String(res0["phase"]) == "sit_idle", "show_sit_idle reports phase='sit_idle'")

	var foot_ref := skel.get_bone_global_pose(idx_foot_l).origin
	var max_foot_slip := 0.0
	var max_foot_tilt := 0.0
	var min_knee_ahead := INF
	var min_knee_outside_foot := INF
	var min_knee_span_extra := INF
	var max_hand_knee_dist := 0.0
	var min_hand_y := INF
	var shorts_ok := true
	var worst_shorts_y := 0.0

	var min_hip_x := INF
	var max_hip_x := -INF
	var min_chest_pitch := INF
	var max_chest_pitch := -INF
	var min_head_yaw := INF
	var max_head_yaw := -INF
	var min_head_pitch := INF
	var max_head_pitch := -INF

	for f in 360:
		var res: Dictionary = giant.show_sit_idle(dt, false)
		var hip := skel.get_bone_global_pose(idx_hip).origin
		var knee_l := skel.get_bone_global_pose(idx_knee_l).origin
		var knee_r := skel.get_bone_global_pose(idx_knee_r).origin
		var foot_l := skel.get_bone_global_pose(idx_foot_l).origin
		var foot_r := skel.get_bone_global_pose(idx_foot_r).origin
		var hand_l := skel.get_bone_global_pose(idx_hand_l).origin
		var hand_r := skel.get_bone_global_pose(idx_hand_r).origin
		var chest_fwd := skel.get_bone_global_pose(idx_chest).basis.orthonormalized() * Vector3.BACK
		var head_fwd := skel.get_bone_global_pose(idx_head).basis.orthonormalized() * Vector3.BACK

		max_foot_slip = maxf(max_foot_slip, foot_l.distance_to(foot_ref))
		max_foot_tilt = maxf(max_foot_tilt, maxf(absf(giant._left.last_pitch), absf(giant._left.last_roll)))
		min_knee_ahead = minf(min_knee_ahead, minf(knee_l.z - hip.z, knee_r.z - hip.z))
		min_knee_outside_foot = minf(min_knee_outside_foot, minf(knee_l.x - foot_l.x, foot_r.x - knee_r.x))
		min_knee_span_extra = minf(min_knee_span_extra, (knee_l.x - knee_r.x) - (foot_l.x - foot_r.x))
		max_hand_knee_dist = maxf(max_hand_knee_dist, maxf(hand_l.distance_to(knee_l), hand_r.distance_to(knee_r)))
		min_hand_y = minf(min_hand_y, minf(hand_l.y, hand_r.y))

		min_hip_x = minf(min_hip_x, hip.x)
		max_hip_x = maxf(max_hip_x, hip.x)
		var cp := atan2(chest_fwd.y, chest_fwd.z)
		min_chest_pitch = minf(min_chest_pitch, cp)
		max_chest_pitch = maxf(max_chest_pitch, cp)
		var hy := atan2(head_fwd.x, head_fwd.z)
		var hp := atan2(head_fwd.y, Vector2(head_fwd.x, head_fwd.z).length())
		min_head_yaw = minf(min_head_yaw, hy)
		max_head_yaw = maxf(max_head_yaw, hy)
		min_head_pitch = minf(min_head_pitch, hp)
		max_head_pitch = maxf(max_head_pitch, hp)

		if f % 60 == 0:
			var sy := _skinned_min_y(skel, shorts)
			if sy < -0.018 or sy > 0.006:
				shorts_ok = false
				worst_shorts_y = sy
		if f == 359:
			_check(float(res["time"]) > 5.9, "Sit-idle time advances smoothly over 6s (t=%.2fs)" % float(res["time"]))

	_check(shorts_ok, "Sit-idle keeps buttocks/shorts grounded cleanly (worst_min_y=%.4f)" % worst_shorts_y)
	_check(max_foot_slip < 0.001 and max_foot_tilt < 0.015 and giant._left.last_yaw > 0.50 and giant._right.last_yaw < -0.50,
			"Sit-idle locks flat outward-turned feet with zero slip (slip=%.5f, tilt=%.4f)" % [max_foot_slip, max_foot_tilt])
	_check(min_knee_outside_foot > 0.0 and min_knee_span_extra > 0.05 and min_knee_ahead > 0.05,
			"Sit-idle keeps knees splayed wider than ankles (min_dx=%.3f, span+%.3f) and ahead of hips (min_dz=%.3f)" % [
				min_knee_outside_foot, min_knee_span_extra, min_knee_ahead])
	_check(max_hand_knee_dist < 0.16 and min_hand_y > 0.18,
			"Sit-idle rests both hands naturally over knees above ground (max_dist=%.3f, min_hand_y=%.3f)" % [max_hand_knee_dist, min_hand_y])
	_check((max_hip_x - min_hip_x) > 0.009 and (max_chest_pitch - min_chest_pitch) > 0.025,
			"Sit-idle shows living lateral sway (%.4f) and chest breathing (%.4f rad)" % [max_hip_x - min_hip_x, max_chest_pitch - min_chest_pitch])
	_check((max_head_yaw - min_head_yaw) > 0.06 and (max_head_pitch - min_head_pitch) > 0.08,
			"Sit-idle shows calm look-around and downward glances (yaw=%.3f, pitch=%.3f rad)" % [max_head_yaw - min_head_yaw, max_head_pitch - min_head_pitch])

	# Verify delta=0.0 completely freezes sit-idle pose, timer, hair springs, and eye gaze.
	var frozen_res: Dictionary = giant.show_sit_idle(0.0, false)
	var frozen_time: float = frozen_res["time"]
	var frozen_hip := skel.get_bone_global_pose(idx_hip).origin
	var frozen_hair := _back_hair_tip_rel_head(giant, skel)
	var frozen_eye: Vector2 = giant.get("_eye_gaze")
	for i in 15:
		giant.show_sit_idle(0.0, false)
	var after_res: Dictionary = giant.show_sit_idle(0.0, false)
	_check(is_equal_approx(float(after_res["time"]), frozen_time)
			and skel.get_bone_global_pose(idx_hip).origin.is_equal_approx(frozen_hip)
			and is_equal_approx(_back_hair_tip_rel_head(giant, skel), frozen_hair)
			and (giant.get("_eye_gaze") as Vector2).is_equal_approx(frozen_eye),
			"Sit-idle pause (delta=0) completely freezes timer, pose, hair springs, and eye gaze")

	giant.free()


func _verify_sit_idle_transitions() -> void:
	var giant := (load("res://scenes/giant.tscn") as PackedScene).instantiate() as CharacterBody3D
	root.add_child(giant)
	await process_frame
	giant.call("_set_skin", &"Kawaii")
	giant.show_motion(0.0, -1.0, 0.0)

	var skel: Skeleton3D = giant.get_node("Model/metarig/Skeleton3D")
	var idx_hip := skel.find_bone("spine")
	var idx_knee_l := skel.find_bone("shin.L")
	var idx_foot_l := skel.find_bone("foot.L")
	var idx_hand_l := skel.find_bone("hand.L")
	var idle_hip := skel.get_bone_global_pose(idx_hip).origin

	var dt := 1.0 / 60.0
	var total_frames := int(round(giant.SIT_CRUSH_DURATION * 60.0))
	var split_frame := int(round(0.65 * float(total_frames)))

	# 1. Run sit-crush up to settled hold (t = 0.65).
	for f in split_frame + 1:
		var t := float(f) / float(total_frames)
		giant.show_sit_crush(t, dt)
	var pre_idle_hip := skel.get_bone_global_pose(idx_hip).origin
	var pre_idle_foot := skel.get_bone_global_pose(idx_foot_l).origin
	var pre_idle_hand := skel.get_bone_global_pose(idx_hand_l).origin

	# 2. Enter sit-idle smoothly (must glide hands onto knees with no frame-0 pop).
	giant.show_sit_idle(dt, true)
	var enter_hip_jump := skel.get_bone_global_pose(idx_hip).origin.distance_to(pre_idle_hip)
	var enter_foot_jump := skel.get_bone_global_pose(idx_foot_l).origin.distance_to(pre_idle_foot)
	var enter_hand_jump := skel.get_bone_global_pose(idx_hand_l).origin.distance_to(pre_idle_hand)
	_check(enter_hip_jump < 0.010 and enter_foot_jump < 0.005 and enter_hand_jump < 0.045,
			"Entering sit-idle from sit-crush blends smoothly (jumps: hip=%.4f foot=%.4f hand=%.4f)" % [
				enter_hip_jump, enter_foot_jump, enter_hand_jump])

	for i in 149:
		giant.show_sit_idle(dt, true)
	var settled_hand_knee := skel.get_bone_global_pose(idx_hand_l).origin.distance_to(skel.get_bone_global_pose(idx_knee_l).origin)
	_check(settled_hand_knee < 0.16, "Sit-idle hands settle cleanly onto knees after entry blend (dist=%.3f)" % settled_hand_knee)

	# 3. Resume stand-up directly from sit-idle (t = 0.65 .. 1.00): smooth handoff, zero re-impact, full rise!
	var pre_rise_hip := skel.get_bone_global_pose(idx_hip).origin
	var pre_rise_foot := skel.get_bone_global_pose(idx_foot_l).origin
	var pre_rise_hand := skel.get_bone_global_pose(idx_hand_l).origin
	var re_impact_count := 0
	var min_rise_hand_y := INF
	var rise_first_hip_jump := 0.0
	var rise_first_foot_jump := 0.0
	var rise_first_hand_jump := 0.0
	for f in range(split_frame + 1, total_frames + 1):
		var t := float(f) / float(total_frames)
		var res: Dictionary = giant.show_sit_crush(t, dt)
		if res["impact_just_hit"]:
			re_impact_count += 1
		var hip := skel.get_bone_global_pose(idx_hip).origin
		var foot := skel.get_bone_global_pose(idx_foot_l).origin
		var hand := skel.get_bone_global_pose(idx_hand_l).origin
		if f == split_frame + 1:
			rise_first_hip_jump = hip.distance_to(pre_rise_hip)
			rise_first_foot_jump = foot.distance_to(pre_rise_foot)
			rise_first_hand_jump = hand.distance_to(pre_rise_hand)
		min_rise_hand_y = minf(min_rise_hand_y, hand.y)
	var final_hip := skel.get_bone_global_pose(idx_hip).origin

	_check(re_impact_count == 0, "Resuming stand-up from sit-idle does not re-emit impact event")
	_check(rise_first_hip_jump < 0.015 and rise_first_foot_jump < 0.005 and rise_first_hand_jump < 0.050,
			"Resuming sit-crush stand-up from sit-idle blends smoothly (jumps: hip=%.4f foot=%.4f hand=%.4f)" % [
				rise_first_hip_jump, rise_first_foot_jump, rise_first_hand_jump])
	_check(min_rise_hand_y < 0.16 and final_hip.distance_to(idle_hip) < 0.025,
			"Resumed stand-up plants hands for push-off (min_hand_y=%.3f) and returns to standing idle" % min_rise_hand_y)

	# 4. Direct exit from sit-idle back to show_motion blends smoothly.
	giant.finish_sit_crush()
	for i in 30:
		giant.show_sit_idle(dt, false)
	var pre_exit_hip := skel.get_bone_global_pose(idx_hip).origin
	giant.finish_sit_idle()
	giant.show_motion(0.0, -1.0, dt)
	var exit_jump := skel.get_bone_global_pose(idx_hip).origin.distance_to(pre_exit_hip)
	_check(exit_jump < 0.08, "Exiting sit-idle directly to show_motion blends smoothly without instant snap (jump=%.4f)" % exit_jump)

	giant.free()


func _verify_all_three_skins_sit_idle() -> void:
	var specs := [
		[&"Kawaii", "spine", "shin.L", "hand.L"],
		[&"Hina", "Hips_108", "Left knee_102", "Left wrist_75"],
		[&"Chibi Catgirl", "DEF-spine_013", "DEF-shin.L_091", "DEF-hand.L_0221"],
	]
	for spec in specs:
		var sname: StringName = spec[0]
		var giant := (load("res://scenes/giant.tscn") as PackedScene).instantiate() as CharacterBody3D
		root.add_child(giant)
		await process_frame
		giant.call("_set_skin", sname)
		giant.show_motion(0.0, -1.0, 0.0)
		var skel: Skeleton3D = giant._active_skin.skeleton if giant._active_skin != null else giant.get_node("Model/metarig/Skeleton3D")
		var model: Node3D = giant.get_node("Model")
		var hip_i := skel.find_bone(spec[1])
		var knee_i := skel.find_bone(spec[2])
		var hand_i := skel.find_bone(spec[3])
		var idle_hip := model.to_local(skel.to_global(skel.get_bone_global_pose(hip_i).origin))

		var min_hip_y := INF
		var max_knee_x := 0.0
		var max_hand_knee := 0.0
		var min_hand_y := INF
		for f in 90:
			giant.show_sit_idle(1.0 / 45.0, false)
			var hip_m := model.to_local(skel.to_global(skel.get_bone_global_pose(hip_i).origin))
			var knee_m := model.to_local(skel.to_global(skel.get_bone_global_pose(knee_i).origin))
			var hand_m := model.to_local(skel.to_global(skel.get_bone_global_pose(hand_i).origin))
			min_hip_y = minf(min_hip_y, hip_m.y)
			max_knee_x = maxf(max_knee_x, absf(knee_m.x))
			max_hand_knee = maxf(max_hand_knee, hand_m.distance_to(knee_m))
			min_hand_y = minf(min_hand_y, hand_m.y)
		giant.finish_sit_idle()
		_check(idle_hip.y - min_hip_y > 0.65 and min_hip_y > 0.01,
				"%s sit-idle keeps pelvis seated flush above floor (idle=%.3f sit=%.3f)" % [sname, idle_hip.y, min_hip_y])
		_check(max_knee_x > 0.20 and max_hand_knee < 0.26 and min_hand_y > 0.12,
				"%s sit-idle keeps knees wide (%.3f) and hands resting on knees above ground (dist=%.3f, hand_y=%.3f)" % [
					sname, max_knee_x, max_hand_knee, min_hand_y])
		giant.free()


func _verify_preview_scene_end_to_end() -> void:
	var preview: Node3D = (load("res://tests/sit_crush_preview.tscn") as PackedScene).instantiate()
	root.add_child(preview)
	await process_frame
	preview.reset_preview(false)

	var st0: Dictionary = preview.get_preview_state()
	var targets_in_front := true
	for item in preview.get("_targets"):
		var orig: Vector3 = item["origin"]
		if orig.z >= -1.5:
			targets_in_front = false
	_check(String(st0["phase"]) == "turn" and absf(preview.giant.rotation.y) < 0.01 and targets_in_front
			and int(st0["flattened_targets"]) == 0 and int(st0["visible_dust_puffs"]) == 0 and not st0["impact_triggered"],
			"Preview starts facing -Z directly toward front targets before 180-deg in-place turn")

	var dt := 1.0 / 60.0
	var skel: Skeleton3D = preview.giant.get_node("Model/metarig/Skeleton3D")
	var idx_hip := skel.find_bone("spine")
	var saw_turn_steps := 0
	var turn_done_deg := 0.0
	var turn_done_seen := false
	var turn_to_sit_hip_jump := 0.0
	var prev_world_hip := skel.to_global(skel.get_bone_global_pose(idx_hip).origin)
	var saw_shake := false
	var saw_thick_dust := false
	var flattened_at_impact := 0
	var impact_center := Vector3.ZERO
	var dust_at_end := 1.0
	var max_frames := 650
	for f in max_frames:
		var st: Dictionary = preview.step_preview(dt)
		var ph: String = st["phase"]
		var cur_world_hip := skel.to_global(skel.get_bone_global_pose(idx_hip).origin)
		if ph == "turn":
			saw_turn_steps = maxi(saw_turn_steps, int(st["turn_steps"]))
		elif not turn_done_seen:
			turn_done_seen = true
			turn_done_deg = float(st["turn_yaw_deg"])
			turn_to_sit_hip_jump = cur_world_hip.distance_to(prev_world_hip)
		prev_world_hip = cur_world_hip

		var p: float = st["progress"]
		if p >= 0.375 and p <= 0.43 and float(st["shake_intensity"]) > 0.5:
			saw_shake = true
			flattened_at_impact = int(st["flattened_targets"])
			impact_center = st["impact_center"]
		if p >= 0.48 and p <= 0.62 and float(st["max_dust_alpha"]) > 0.45 and int(st["visible_dust_puffs"]) >= 30:
			saw_thick_dust = true
		if p >= 0.94:
			dust_at_end = minf(dust_at_end, float(st["max_dust_alpha"]))
		if p >= 0.995:
			break

	_check(turn_done_seen and saw_turn_steps >= 4 and turn_done_deg >= 174.0 and turn_to_sit_hip_jump < 0.25,
			"Preview runs live 180-deg standing pivot (%d steps, %.1f deg) and hands off smoothly to sit-crush (hip_jump=%.3fm)" % [
				saw_turn_steps, turn_done_deg, turn_to_sit_hip_jump])
	_check(saw_shake and impact_center.z < -2.0 and flattened_at_impact == int(st0["in_zone_targets"])
			and flattened_at_impact < int(st0["total_targets"]) and preview.IMPACT_RADIUS <= 5.0,
			"Preview sits down onto tight front target zone (r=%.1fm, z=%.2f), flattens all %d in-zone targets and spares %d outside targets" % [
				preview.IMPACT_RADIUS, impact_center.z, flattened_at_impact, int(st0["total_targets"]) - flattened_at_impact])
	_check(saw_thick_dust and dust_at_end < 0.12,
			"Preview dust ring lingers thick during sit hold and slowly dissipates during rise (end alpha=%.3f)" % dust_at_end)

	# Verify replay reset, skin switcher, camera presets, and walk -> 180 turn -> sit transition mode.
	preview.reset_preview(false)
	var st_reset: Dictionary = preview.get_preview_state()
	_check(String(st_reset["phase"]) == "turn" and absf(preview.giant.rotation.y) < 0.01
			and int(st_reset["flattened_targets"]) == 0 and int(st_reset["visible_dust_puffs"]) == 0,
			"Replay resets facing, turn phase, targets, and dust cleanly")

	preview.set_skin(&"Hina")
	preview.set_skin(&"Chibi Catgirl")
	preview.set_skin(&"Kawaii")
	for preset in 5:
		preview.set_camera_preset(preset)
	preview.start_walk_transition_test()
	var walk_saw_turn := false
	for f in 340:
		var stw: Dictionary = preview.step_preview(dt)
		if String(stw["phase"]) == "turn":
			walk_saw_turn = true
		if float(stw["progress"]) > 0.08:
			break
	var st_walk: Dictionary = preview.get_preview_state()
	_check(walk_saw_turn and float(st_walk["progress"]) > 0.05 and float(st_walk["turn_yaw_deg"]) >= 174.0 and String(st_walk["skin"]) == "Kawaii",
			"Preview walk -> 180-deg turn -> sit transition and skin/camera controls run cleanly")

	# Verify direct sit-idle preview mode (including skin switching in sit-idle).
	preview.start_sit_idle_preview(false)
	var st_idle0: Dictionary = preview.get_preview_state()
	for f in 90:
		preview.step_preview(dt)
	preview.set_skin(&"Hina")
	preview.set_skin(&"Chibi Catgirl")
	preview.set_skin(&"Kawaii")
	var st_idle1: Dictionary = preview.get_preview_state()
	_check(String(st_idle0["phase"]) == "sit_idle" and String(st_idle1["phase"]) == "sit_idle"
			and float(st_idle1["sit_idle_time"]) > 1.4
			and int(st_idle1["flattened_targets"]) == int(st0["in_zone_targets"])
			and int(st_idle1["visible_dust_puffs"]) >= 30,
			"Preview sit-idle mode loops seated idle with flattened in-zone targets and settled dust (t=%.2fs)" % float(st_idle1["sit_idle_time"]))

	# Verify full 180-deg turn -> sit-down -> sit-idle -> stand-up cycle mode.
	preview.start_sit_cycle_preview(false)
	var saw_cycle_turn := false
	var saw_cycle_drop := false
	var saw_cycle_idle := false
	var saw_cycle_rise := false
	var max_cycle_idle_t := 0.0
	var cycle_dust_end := 1.0
	for f in 860:
		var stc: Dictionary = preview.step_preview(dt)
		var ph: String = stc["phase"]
		if ph == "turn":
			saw_cycle_turn = true
		elif ph == "drop":
			saw_cycle_drop = true
		elif ph == "sit_idle":
			saw_cycle_idle = true
			max_cycle_idle_t = maxf(max_cycle_idle_t, float(stc["sit_idle_time"]))
		elif saw_cycle_idle and ph == "rise":
			saw_cycle_rise = true
			if float(stc["progress"]) >= 0.94:
				cycle_dust_end = minf(cycle_dust_end, float(stc["max_dust_alpha"]))
	_check(saw_cycle_turn and saw_cycle_drop and saw_cycle_idle and saw_cycle_rise and max_cycle_idle_t >= 3.1 and cycle_dust_end < 0.12,
			"Preview full cycle runs 180-turn -> drop -> sit-idle (%.2fs) -> rise with smooth dust clear (end=%.3f)" % [
				max_cycle_idle_t, cycle_dust_end])

	preview.queue_free()
	await process_frame
	await process_frame
