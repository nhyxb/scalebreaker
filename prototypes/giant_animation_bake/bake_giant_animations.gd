extends SceneTree
## Bakes the giant's procedural actions into a Godot AnimationLibrary that an
## AnimationPlayer can play directly (for previews, cutscenes or future wiring).
##
## Usage, from the project root:
##   XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --fixed-fps 60 \
##       --script res://prototypes/giant_animation_bake/bake_giant_animations.gd
##
## Output: res://prototypes/giant_animation_bake/giant_actions.res (AnimationLibrary "giant")
##   turn_180        standing 180 deg ship-like pivot on the spot (6 small steps)
##   sit_crush       sit-crush: look down -> stagger -> drop -> impact -> pack -> rise
##   sit_idle        seamless seated idle loop
##   turn_then_sit   the pivot immediately followed by the sit-crush
##
## How it works:
## - The poses come from the live procedural IK in scenes/giant_visual.gd, advanced at a
##   fixed 60 Hz with one physics-settled frame per sample (the body simply stands still,
##   so no awaits are needed).
## - Every skeleton bone records its local rotation; the spine also records its local
##   position (the only bone that translates while sitting).
## - Each track is thinned with a per-track Ramer-Douglas-Peucker pass (rotation error
##   <= ROT_TOLERANCE, position error <= POS_TOLERANCE), so replay stays visually
##   identical while the resource stays small.
## - Body yaw is folded into the "Model" node track. The clips therefore never touch the
##   CharacterBody3D transform: they are pure visuals and can be played on a body that
##   gameplay keeps driving.
## - Baked against the default Kawaii rig. Hina / Chibi Catgirl skins keep using the
##   procedural path, because their seated contact depth is calibrated per skin.

const GIANT_SCENE := "res://scenes/giant.tscn"
const OUTPUT_PATH := "res://prototypes/giant_animation_bake/giant_actions.res"
const MODEL_PATH := "Model"
const SKELETON_PATH := "Model/metarig/Skeleton3D"
const SPINE_BONE := "spine"

const DT := 1.0 / 60.0
const PRE_ROLL := 0.25          # neutral standing beat before the action starts
const SIT_OUTRO := 0.55         # blend back to plain standing idle after the rise
const IDLE_LOOP_SECONDS := 9.52 # two breathing cycles
const IDLE_SEAM_SECONDS := 0.60 # tail cross-faded into the head for a seamless loop
const TURN_TARGET_YAW := PI - 0.001
const TURN_TIMEOUT := 6.5
const ROT_TOLERANCE := 0.006    # rad (~0.34 deg)
const POS_TOLERANCE := 0.004    # m
const STATIC_EPSILON := 1e-5

var _giant: CharacterBody3D
var _skel: Skeleton3D
var _model: Node3D
var _bone_count := 0


class Capture:
	var rots: Array = []                  # frame -> Array[Quaternion] (one per bone)
	var poss: Array = []                  # frame -> Array[Vector3] (one per bone)
	var model: Array[Quaternion] = []
	var times: PackedFloat32Array = PackedFloat32Array()
	var markers: Array[Dictionary] = []
	var pre_roll := 0.0
	var action_start := 0.0


func _initialize() -> void:
	_bake.call_deferred()


func _bake() -> void:
	seed(20261125)
	await _setup()

	var library := AnimationLibrary.new()
	var report: Array[String] = []

	var turn := _capture_turn()
	report.append(_add_clip(library, turn, &"turn_180", false, _turn_markers(turn)))
	var crush := _capture_sit_crush()
	report.append(_add_clip(library, crush, &"sit_crush", false, _sit_markers(crush)))
	var idle := _capture_sit_idle()
	report.append(_add_clip(library, idle, &"sit_idle", true, []))
	var combo := _capture_turn_then_sit()
	report.append(_add_clip(library, combo, &"turn_then_sit", false, _sit_markers(combo)))

	DirAccess.make_dir_recursive_absolute(OUTPUT_PATH.get_base_dir())
	var err := ResourceSaver.save(library, OUTPUT_PATH, ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		push_error("Failed to save %s: %s" % [OUTPUT_PATH, error_string(err)])
		quit(1)
		return

	var bytes := FileAccess.get_file_as_bytes(OUTPUT_PATH).size()
	print("")
	print("=== baked %s (%.1f KiB) ===" % [OUTPUT_PATH, bytes / 1024.0])
	for line in report:
		print(line)
	print("=== done ===")
	quit(0)


func _setup() -> void:
	var ground := StaticBody3D.new()
	ground.name = "BakeGround"
	ground.collision_layer = 1
	var shape := CollisionShape3D.new()
	shape.shape = WorldBoundaryShape3D.new()
	ground.add_child(shape)
	root.add_child(ground)

	_giant = (load(GIANT_SCENE) as PackedScene).instantiate() as CharacterBody3D
	root.add_child(_giant)
	await process_frame
	_giant.call("_set_skin", &"Kawaii")
	_skel = _giant.get_node(SKELETON_PATH) as Skeleton3D
	_model = _giant.get_node(MODEL_PATH) as Node3D
	_bone_count = _skel.get_bone_count()


# --- capture drivers -------------------------------------------------------

func _capture_turn() -> Capture:
	var cap := Capture.new()
	cap.pre_roll = PRE_ROLL
	_prepare(0.0)
	_advance_idle(cap, PRE_ROLL)
	var elapsed := 0.0
	while elapsed < TURN_TIMEOUT:
		_ground()
		var res: Dictionary = _giant.step_turn_in_place(TURN_TARGET_YAW, DT)
		elapsed += DT
		_record(cap)
		if bool(res["done"]):
			break
	_advance_idle(cap, 0.2)
	return cap


func _capture_sit_crush() -> Capture:
	var cap := Capture.new()
	cap.pre_roll = PRE_ROLL
	_prepare(0.0)
	_advance_idle(cap, PRE_ROLL)
	_advance_sit(cap)
	_advance_outro(cap, SIT_OUTRO)
	return cap


func _capture_sit_idle() -> Capture:
	var cap := Capture.new()
	_prepare(0.0)
	_ground()
	_giant.call("show_sit_idle", 0.0, false)
	_record(cap)
	var frames := int(round(IDLE_LOOP_SECONDS / DT))
	for i in range(1, frames + 1):
		_ground()
		_giant.show_sit_idle(DT, false)
		_record(cap)
	_seam_loop(cap, IDLE_SEAM_SECONDS)
	return cap


func _capture_turn_then_sit() -> Capture:
	var cap := Capture.new()
	cap.pre_roll = PRE_ROLL
	_prepare(0.0)
	_advance_idle(cap, PRE_ROLL)
	var elapsed := 0.0
	while elapsed < TURN_TIMEOUT:
		_ground()
		var res: Dictionary = _giant.step_turn_in_place(TURN_TARGET_YAW, DT)
		elapsed += DT
		_record(cap)
		if bool(res["done"]):
			break
	# Hand the settled pivot straight to the sit-crush, exactly like the preview scene.
	_advance_sit(cap)
	_advance_outro(cap, SIT_OUTRO)
	return cap


func _prepare(body_yaw: float) -> void:
	_giant.call("finish_sit_crush", true)
	_giant.call("finish_sit_idle", true)
	_giant.global_position = Vector3.ZERO
	_giant.rotation = Vector3(0.0, body_yaw, 0.0)
	_giant.velocity = Vector3.ZERO
	_giant.set("_breath", 0.0)
	_giant.set("_idle_look_time", 0.0)
	_giant.set("_visual_yaw_offset", 0.0)
	_giant.set("_prev_body_yaw", body_yaw)
	_giant.call("_reset_turn_tracks")
	_ground()
	_giant.show_motion(0.0, -1.0, 0.0)
	_ground()


func _advance_idle(cap: Capture, seconds: float) -> void:
	var frames := int(round(seconds / DT))
	for i in frames:
		_ground()
		_giant.show_motion(0.0, -1.0, DT)
		_record(cap)


func _advance_sit(cap: Capture) -> void:
	var duration: float = _giant.SIT_CRUSH_DURATION
	cap.action_start = cap.times.size() * DT
	_ground()
	_giant.show_sit_crush(0.0, 0.0)
	_record(cap)
	var frames := int(round(duration / DT))
	for i in range(1, frames + 1):
		_ground()
		_giant.show_sit_crush(float(i) / float(frames), DT)
		_record(cap)


func _advance_outro(cap: Capture, seconds: float) -> void:
	_giant.call("finish_sit_crush")
	var frames := int(round(seconds / DT))
	for i in frames:
		_ground()
		_giant.show_motion(0.0, -1.0, DT)
		_record(cap)


func _ground() -> void:
	_giant.velocity = Vector3(0.0, -2.0, 0.0)
	_giant.move_and_slide()
	_giant.global_position.y = 0.0


func _record(cap: Capture) -> void:
	var rots: Array[Quaternion] = []
	var poss: Array[Vector3] = []
	for i in _bone_count:
		rots.append(_skel.get_bone_pose_rotation(i))
		poss.append(_skel.get_bone_pose_position(i))
	cap.rots.append(rots)
	cap.poss.append(poss)
	cap.model.append(_model_world_quat())
	cap.times.append(cap.times.size() * DT)


func _model_world_quat() -> Quaternion:
	# Body yaw is folded into the Model node so the clip never moves the CharacterBody3D.
	var body := _giant.global_transform.basis.orthonormalized()
	var local := _model.transform.basis.orthonormalized()
	return (body * local).get_rotation_quaternion()


func _seam_loop(cap: Capture, seconds: float) -> void:
	# Cross-fade the tail into the head so time wrapping is perfectly seamless.
	var total := cap.times.size()
	var seam := mini(int(round(seconds / DT)), total - 2)
	if seam <= 1:
		return
	var first := total - seam
	for i in range(first, total):
		var u := float(i - first) / float(seam)
		var src := i - first
		for b in _bone_count:
			cap.rots[i][b] = (cap.rots[i][b] as Quaternion).slerp(cap.rots[src][b], u)
			cap.poss[i][b] = (cap.poss[i][b] as Vector3).lerp(cap.poss[src][b], u)
		cap.model[i] = cap.model[i].slerp(cap.model[src], u)
	# Land exactly on the first frame so LOOP_LINEAR wraps without a pop.
	cap.rots[total - 1] = cap.rots[0].duplicate()
	cap.poss[total - 1] = cap.poss[0].duplicate()
	cap.model[total - 1] = cap.model[0]


# --- animation building ----------------------------------------------------

func _add_clip(library: AnimationLibrary, cap: Capture, name: StringName,
		looping: bool, markers: Array) -> String:
	var anim := _build_animation(cap, name, looping, markers)
	var err := library.add_animation(name, anim)
	if err != OK:
		push_error("Failed to add animation %s: %s" % [name, error_string(err)])
	var keys := 0
	for t in anim.get_track_count():
		keys += anim.track_get_key_count(t)
	return "  %-14s %6.2f s  %3d tracks  %6d keys  %s%s" % [
		String(name), anim.get_length(), anim.get_track_count(), keys,
		"%d markers" % anim.get_marker_names().size(), "  (loop)" if looping else "",
	]


func _build_animation(cap: Capture, name: StringName, looping: bool,
		markers: Array) -> Animation:
	var anim := Animation.new()
	anim.resource_name = String(name)
	anim.set_step(DT)
	anim.set_length(cap.times[cap.times.size() - 1])
	anim.set_loop_mode(Animation.LOOP_LINEAR if looping else Animation.LOOP_NONE)

	var model_samples: Array[Quaternion] = cap.model.duplicate()
	var model_track := _rotation_track(anim, NodePath(MODEL_PATH), model_samples, looping)
	anim.track_set_enabled(model_track, true)

	var spine := _skel.find_bone(SPINE_BONE)
	for b in _bone_count:
		var bone_name := _skel.get_bone_name(b)
		var path := NodePath("%s:%s" % [SKELETON_PATH, bone_name])
		var samples: Array[Quaternion] = []
		for f in cap.rots.size():
			samples.append(cap.rots[f][b])
		_rotation_track(anim, path, samples, looping)
		if b == spine:
			var positions: Array[Vector3] = []
			for f in cap.poss.size():
				positions.append(cap.poss[f][b])
			if _max_spread(positions) > STATIC_EPSILON:
				_position_track(anim, path, positions, looping)

	for marker in markers:
		anim.add_marker(StringName(marker["name"]), float(marker["time"]))
		anim.set_marker_color(StringName(marker["name"]), marker["color"])

	anim.set_meta("baked_from", "scenes/giant_visual.gd procedural IK")
	anim.set_meta("bake_dt", DT)
	anim.set_meta("pre_roll", cap.pre_roll)
	anim.set_meta("base_skin", "Kawaii")
	return anim


func _rotation_track(anim: Animation, path: NodePath, samples: Array[Quaternion],
		looping: bool) -> int:
	var track := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(track, path)
	anim.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)
	anim.track_set_interpolation_loop_wrap(track, looping)
	_continuous(samples)
	var times := _clip_times(samples.size())
	var keep := _simplify(samples, ROT_TOLERANCE, true)
	for index in keep:
		anim.rotation_track_insert_key(track, times[index], samples[index])
	return track


func _position_track(anim: Animation, path: NodePath, samples: Array[Vector3],
		looping: bool) -> int:
	var track := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(track, path)
	anim.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)
	anim.track_set_interpolation_loop_wrap(track, looping)
	var times := _clip_times(samples.size())
	var keep := _simplify(samples, POS_TOLERANCE, false)
	for index in keep:
		anim.position_track_insert_key(track, times[index], samples[index])
	return track


func _clip_times(count: int) -> PackedFloat32Array:
	var times := PackedFloat32Array()
	times.resize(count)
	for i in count:
		times[i] = i * DT
	return times


func _continuous(samples: Array[Quaternion]) -> void:
	# Keep neighbouring quaternions on the same hemisphere so linear slerp never flips.
	for i in range(1, samples.size()):
		if samples[i - 1].dot(samples[i]) < 0.0:
			samples[i] = Quaternion(-samples[i].x, -samples[i].y, -samples[i].z, -samples[i].w)


func _max_spread(samples: Array[Vector3]) -> float:
	var spread := 0.0
	for i in range(1, samples.size()):
		spread = maxf(spread, samples[0].distance_to(samples[i]))
	return spread


func _simplify(samples: Array, tolerance: float, is_rotation: bool) -> PackedInt32Array:
	var count := samples.size()
	var keep := PackedByteArray()
	keep.resize(count)
	keep[0] = 1
	keep[count - 1] = 1
	if count > 2:
		var stack: Array[Vector2i] = [Vector2i(0, count - 1)]
		while not stack.is_empty():
			var span: Vector2i = stack.pop_back()
			var first := span.x
			var last := span.y
			if last - first < 2:
				continue
			var worst := -1.0
			var worst_index := -1
			var span_len := float(last - first)
			for i in range(first + 1, last):
				var u := float(i - first) / span_len
				var err := _deviation(samples[first], samples[i], samples[last], u, is_rotation)
				if err > worst:
					worst = err
					worst_index = i
			if worst_index >= 0 and worst > tolerance:
				keep[worst_index] = 1
				stack.push_back(Vector2i(first, worst_index))
				stack.push_back(Vector2i(worst_index, last))
	var result := PackedInt32Array()
	for i in count:
		if keep[i] == 1:
			result.append(i)
	return result


func _deviation(a: Variant, sample: Variant, b: Variant, u: float,
		is_rotation: bool) -> float:
	if is_rotation:
		var guess := (a as Quaternion).slerp(b as Quaternion, u)
		return absf(guess.angle_to(sample as Quaternion))
	return (a as Vector3).lerp(b as Vector3, u).distance_to(sample as Vector3)


# --- clip metadata ---------------------------------------------------------

func _action_markers(offset: float) -> Array:
	var duration: float = _giant.SIT_CRUSH_DURATION
	return [
		{"name": "action_start", "time": offset, "color": Color(0.55, 0.85, 1.0)},
		{"name": "drop_start", "time": offset + _giant.SIT_CRUSH_DROP_START * duration,
			"color": Color(1.0, 0.82, 0.35)},
		{"name": "impact", "time": offset + _giant.SIT_CRUSH_IMPACT_TIME * duration,
			"color": Color(1.0, 0.35, 0.25)},
		{"name": "rock_start", "time": offset + _giant.SIT_CRUSH_ROCK_START * duration,
			"color": Color(0.9, 0.6, 0.9)},
		{"name": "rise_start", "time": offset + _giant.SIT_CRUSH_RISE_START * duration,
			"color": Color(0.45, 0.95, 0.7)},
		{"name": "seated_end", "time": offset + duration, "color": Color(0.7, 0.7, 0.85)},
	]


func _sit_markers(cap: Capture) -> Array:
	return _action_markers(cap.action_start)


func _turn_markers(cap: Capture) -> Array:
	var duration := cap.times[cap.times.size() - 1] - 0.2
	return [
		{"name": "action_start", "time": cap.pre_roll, "color": Color(0.55, 0.85, 1.0)},
		{"name": "pivot_end", "time": maxf(cap.pre_roll, duration), "color": Color(0.45, 0.95, 0.7)},
	]
