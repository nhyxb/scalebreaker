extends Node3D
## Seated Yumeka: the licensed anime avatar (assets/characters/yumeka/,
## gitignored) perched on the skybox bedroom's swivel chair, gazing down at the
## harbour diorama. Mounted by skybox_bedroom.gd onto `ultra_giant_anchor`; if
## the GLB asset is absent (fresh public-repo clone) this node either never
## spawns or stays inert, and the game runs exactly as before.
##
## Life on a budget: breathing, blinking and the player-tracking gaze animate at
## a low ANIM_HZ tick, and every tick calls `harbor_skybox.gd::mark_dirty()` so
## the change-driven bedroom viewport re-renders exactly one frame - camera
## motion still refreshes every frame on its own, and a static camera never
## renders more than the animation needs.

const GLB_PATH := "res://assets/characters/yumeka/Yumeka_seated.glb"
const CityNightLights := preload("res://scenes/city_night_lights.gd")
const SKY_SCALE := 1.0 / 6666.67
## Main-world y == 0 (city ground) maps to this bedroom height (desk + 32 m of
## diorama base, matching `skybox_bedroom.gd::sandbox_anchor`).
const SANDBOX_ANCHOR_Y := 0.7548
const DIORAMA_CENTRE := Vector3(0.0, SANDBOX_ANCHOR_Y, 0.0)

## Animation tick: every morph/bone update runs at this rate, not per frame.
const ANIM_HZ := 18.0
const BREATH_PERIOD := 4.2
## Breathing amplitudes (radians, applied over the baked rest pose).
const BREATH_CHEST_RAD := 0.011
const BREATH_SPINE_RAD := 0.006
const BLINK_MIN_GAP := 3.0
const BLINK_MAX_GAP := 6.0
const BLINK_CLOSE_TIME := 0.07
const BLINK_OPEN_TIME := 0.14
## Comfort limits around the baked seated rest orientation (degrees).
const GAZE_YAW_LIMIT := 15.0
const GAZE_PITCH_LIMIT := 10.0
## Anatomical eyeball rotation limits inside the sockets (degrees): tracks the
## player crisply without sclera clipping or rolling back.
const EYE_YAW_LIMIT := 14.0
const EYE_PITCH_LIMIT := 10.0
## Soft anime matte (gl_compatibility + AGX friendly).
const MATTE_ROUGHNESS := 0.88
const MATTE_SPECULAR := 0.16
const SCISSOR_THRESHOLD := 0.42

var _model: Node3D
var _skeleton: Skeleton3D
var _sky: Node
var _morph_carriers := {}          # morph name -> MeshInstance3D carrying it
var _head_idx := -1
var _neck_idx := -1
var _chest_idx := -1
var _spine_idx := -1
var _eye_l_idx := -1
var _eye_r_idx := -1
## Baked (animated) seated transforms per animated bone: breathing and gaze
## compose parent-to-child over these, never over the armature's raw T-pose rest.
var _posed_bases := {}
var _local_bases := {}             # child bone idx -> local transform relative to parent in SeatedPose
var _rest_eye_mid_local := Vector3.ZERO

var _anim_acc := 0.0
var _time := 0.0
var _breath_lift := 0.0            # [-1, +1] sine shared with main-world looming shadow
var _blink_state := 0.0            # 0 = open, 1 = closed (animated weight)
var _blink_timer := 2.2            # seconds until the next blink
var _blink_anim := -1.0            # < 0: idle; else seconds into the blink
var _gaze_yaw := 0.0               # smoothed head+neck degrees around the baked rest
var _gaze_pitch := 0.0             # positive = lower the gaze further
var _eye_yaw := 0.0                # smoothed Eye_L/Eye_R degrees in current head space
var _eye_pitch := 0.0              # positive = lower irises toward diorama
var _gaze_swing := Vector2.ZERO    # neutral (diorama) gaze angle (degrees), subtracted
var _gaze_override: Vector3        # world-space debug/test target (0,0,0 = off)
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
	# The GLB's real pose ships as a 1-frame `SeatedPose` action (Apply-Pose-as-
	# Rest breaks glTF skinning against shape keys, so the exporter keeps the
	# T-pose rest + this animation). Land it FIRST so every runtime base below
	# reads the seated skeleton, then freeze the player so ticks own the bones.
	_land_seated_pose()
	_cache_posed_bases()
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
	# Soft anime matte: kill any emission (AGX blowout guard, unlike the old
	# snow_fox whites), flatten PBR reflections, and give the alpha eyelash /
	# fringe / wing cards a depth-safe scissor instead of sorted blending.
	if _model == null:
		return
	_walk(_model, func(node: Node) -> void:
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			return
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
	# The bedroom renders in a SubViewport whose parent is the Skybox node
	# (harbor_skybox.gd); that is the mark_dirty() owner.
	var vp := get_viewport()
	if vp != null and vp.get_parent() != null:
		var parent := vp.get_parent()
		if parent.has_method(&"mark_dirty"):
			_sky = parent


func _land_seated_pose() -> void:
	# NB: GDScript lambdas capture locals BY VALUE, so collect through an array
	# (assigning a local from inside the lambda would silently go nowhere).
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
	for idx in [_spine_idx, _chest_idx, _neck_idx, _head_idx, _eye_l_idx, _eye_r_idx]:
		if idx >= 0:
			_posed_bases[idx] = _skeleton.get_bone_global_pose(idx)
	# Cache parent-relative transforms from SeatedPose so parent-to-child twists
	# (Spine -> Chest -> Neck -> Head -> Eye_L/Eye_R) compose seamlessly without drift.
	var pairs := [
		[_chest_idx, _spine_idx],
		[_neck_idx, _chest_idx],
		[_head_idx, _neck_idx],
		[_eye_l_idx, _head_idx],
		[_eye_r_idx, _head_idx],
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


func _cache_neutral_gaze() -> void:
	# The baked pose already faces the diorama; store that resting swing so the
	# runtime gaze drifts AROUND it instead of re-deriving it every frame.
	_gaze_swing = _swing_to(DIORAMA_CENTRE)


func _set_idle_face() -> void:
	# Warming rest: tiny smile, relaxed lids, faint downward look - she reads as
	# gently watching the tiny harbour from above.
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
# Low-frequency animation loop
# --------------------------------------------------------------------------- #

func _process(delta: float) -> void:
	if _model == null:
		return
	_anim_acc += delta
	var tick := 1.0 / ANIM_HZ
	if _anim_acc < tick:
		return
	var dt := _anim_acc
	_anim_acc = 0.0
	_time += dt

	_drive_breathing()
	_drive_blink(dt)
	_drive_gaze(dt)
	if _sky != null:
		_sky.mark_dirty()


func _drive_breathing() -> void:
	# One slow sine per ~4.2 s: spine leads slightly, chest follows cleanly as a
	# child of spine so upper-body & eyes ride the breathing cycle naturally.
	var phase := fposmod(_time / BREATH_PERIOD, 1.0) * TAU
	_breath_lift = sin(phase)
	# Negative rotation about +X tips the torso gently back up on the inhale.
	_twist_bone_from_base(_spine_idx, _posed_bases.get(_spine_idx, Transform3D.IDENTITY),
			Vector3.RIGHT, -_breath_lift * BREATH_SPINE_RAD)
	if _chest_idx >= 0:
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
	# The unused Human node is freed whenever the player is a giant (round.rs),
	# so its presence alone identifies the human player; otherwise the player
	# rides the Giant node.
	for scene_root in get_tree().root.get_children():
		var round := (scene_root as Node).get_node_or_null("MapSlot/Round")
		if round == null:
			continue
		var human := round.get_node_or_null("Human")
		if human != null:
			return human as Node3D
		return round.get_node_or_null("Giant") as Node3D
	return null


func _drive_gaze(dt: float) -> void:
	if _head_idx < 0:
		return
	var world_target: Vector3 = _gaze_override
	if world_target == Vector3.ZERO:
		var actor := _main_world_player()
		if actor != null:
			world_target = Vector3(
				actor.global_position.x * SKY_SCALE,
				SANDBOX_ANCHOR_Y + actor.global_position.y * SKY_SCALE,
				actor.global_position.z * SKY_SCALE,
			)
		else:
			world_target = DIORAMA_CENTRE

	# 1. Gentle neck + head turn toward the player (parent-to-child over the
	#    breathing chest pose), keeping soft inertia and +/-15° yaw / +/-10° pitch bounds.
	var swing := _swing_to(world_target)
	var delta_yaw := swing.x - _gaze_swing.x
	var delta_pitch := swing.y - _gaze_swing.y
	# Head carries ~68% of the total required turn (up to its comfort limits);
	# the eyeballs take over the exact residual so irises stay locked dead-on.
	var desired_yaw := clampf(delta_yaw * 0.68, -GAZE_YAW_LIMIT, GAZE_YAW_LIMIT)
	var desired_pitch := clampf(delta_pitch * 0.60, -GAZE_PITCH_LIMIT, GAZE_PITCH_LIMIT)
	var head_smooth := 1.0 - exp(-dt * 4.2)
	_gaze_yaw = lerpf(_gaze_yaw, desired_yaw, head_smooth)
	_gaze_pitch = lerpf(_gaze_pitch, desired_pitch, head_smooth)

	if _neck_idx >= 0:
		var neck_base := _composed_base(_neck_idx, _chest_idx)
		_twist_bone_from_base(_neck_idx, neck_base,
				Vector3.UP, deg_to_rad(_gaze_yaw) * 0.35,
				Vector3.RIGHT, deg_to_rad(_gaze_pitch) * 0.35)
	var head_base := _composed_base(_head_idx, _neck_idx)
	_twist_bone_from_base(_head_idx, head_base,
			Vector3.UP, deg_to_rad(_gaze_yaw) * 0.65,
			Vector3.RIGHT, deg_to_rad(_gaze_pitch) * 0.65)

	# 2. Precision Eye_L / Eye_R eyeball lock in the CURRENT posed head frame:
	#    irises track the exact residual angle to the player smoothly & quickly
	#    within strict anatomical bounds (+/-14° horizontal, +/-10° vertical).
	_drive_eyes(world_target, dt)


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
	# Transform direction into the resting eye socket basis (+Z optical forward,
	# +X her left, +Y up) so angles are purely relative to the current head pose.
	var dir_eye := eye_l_base.basis.inverse() * dir_skel
	var horiz := Vector2(dir_eye.x, dir_eye.z).length()
	var desired_eye_yaw := clampf(rad_to_deg(atan2(dir_eye.x, maxf(dir_eye.z, 1e-4))),
			-EYE_YAW_LIMIT, EYE_YAW_LIMIT)
	var desired_eye_pitch := clampf(rad_to_deg(atan2(-dir_eye.y, maxf(horiz, 1e-4))),
			-EYE_PITCH_LIMIT, EYE_PITCH_LIMIT)
	var eye_smooth := 1.0 - exp(-dt * 11.0)
	_eye_yaw = lerpf(_eye_yaw, desired_eye_yaw, eye_smooth)
	_eye_pitch = lerpf(_eye_pitch, desired_eye_pitch, eye_smooth)

	# Conjugate gaze (identical yaw/pitch on both eyes) keeps anime iris symmetry
	# cleanly locked onto the player without cross-eye distortion at close edges.
	var eye_rot := Basis(Vector3.UP, deg_to_rad(_eye_yaw)) \
			* Basis(Vector3.RIGHT, deg_to_rad(_eye_pitch))
	_skeleton.set_bone_global_pose(_eye_l_idx,
			Transform3D(eye_l_base.basis * eye_rot, eye_l_base.origin))
	_skeleton.set_bone_global_pose(_eye_r_idx,
			Transform3D(eye_r_base.basis * eye_rot, eye_r_base.origin))

	# Gently couple upper-lid droop (eyelids only, zero iris shift) with downward gaze.
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
	# Yaw/pitch (degrees) of the target relative to the skeleton's baked facing
	# (+Z local forward after the mount flip), measured from the resting eye midpoint.
	var eye_pos := _skeleton.global_transform * _rest_eye_mid_local
	var dir := world_target - eye_pos
	if dir.length_squared() < 1e-8:
		dir = Vector3(0.0, -0.1, -1.0)
	var dir_local := _skeleton.global_transform.affine_inverse().basis * dir
	var yaw := rad_to_deg(atan2(dir_local.x, maxf(dir_local.z, 1e-4)))
	var pitch := rad_to_deg(atan2(-dir_local.y, Vector2(dir_local.x, dir_local.z).length()))
	return Vector2(yaw, pitch)


func _twist_bone_from_base(bone_idx: int, base: Transform3D, axis_a: Vector3, angle_a: float,
		axis_b := Vector3.ZERO, angle_b := 0.0) -> void:
	# Rotates the bone about skeleton-space axes through its current pivot,
	# stacked over `base` (parent-composed SeatedPose).
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
# Debug / test hooks
# --------------------------------------------------------------------------- #

func debug_eye_close() -> float:
	return _blink_state


func debug_bone_pos(bone: String) -> Vector3:
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
	return _sky != null and _sky.has_method(&"mark_dirty")


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


func debug_set_gaze_override(world_pos_or_null: Vector3) -> void:
	_gaze_override = world_pos_or_null


func debug_is_mounted() -> bool:
	return _model != null and _skeleton != null and _head_idx >= 0
