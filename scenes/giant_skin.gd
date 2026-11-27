@abstract
extends Node3D
## Drives an alternate model from the procedural giant pose in skeleton space.

class BoneLink:
	var target: int
	var driver: int
	var parent: int
	var rotation_offset: Quaternion

class LegLink:
	var thigh: int
	var shin: int
	var foot: int

var skeleton: Skeleton3D
var head_bone: StringName
var head_parts: Array[MeshInstance3D] = []
var body_meshes: Dictionary[MeshInstance3D, ArrayMesh] = {}
var meshes: Array[MeshInstance3D] = []

var _driver: Skeleton3D
var _links: Array[BoneLink] = []
var _legs: Dictionary[int, LegLink] = {}
var _driver_basis: Quaternion
var _pelvis_movement: Basis
var _hip_rest: Vector3
var _driver_hip_rest: Vector3
var _pelvis_height_ratio := 1.0


@abstract func configure(driver: Skeleton3D) -> void


func _load_model(asset: PackedScene) -> void:
	var model := asset.instantiate()
	skeleton = model.find_child("Skeleton3D", true, false) as Skeleton3D
	var rig_transform := skeleton.transform
	var ancestor := skeleton.get_parent() as Node3D
	while ancestor != null:
		rig_transform = ancestor.transform * rig_transform
		ancestor = ancestor.get_parent() as Node3D
	skeleton.owner = null
	for child in skeleton.find_children("*", "", true, false):
		child.owner = null
	skeleton.get_parent().remove_child(skeleton)
	skeleton.transform = rig_transform
	add_child(skeleton)
	model.free()
	for child in skeleton.get_children():
		if child is MeshInstance3D:
			meshes.append(child)


func _configure_visibility(head: StringName, heads: Array[StringName], bodies: Array[StringName]) -> void:
	head_bone = head
	for mesh in meshes:
		if mesh.name in heads:
			head_parts.append(mesh)
		elif mesh.name in bodies:
			body_meshes[mesh] = mesh.mesh


func _configure_pose(driver: Skeleton3D, mapping: Dictionary, alignments: Dictionary,
		yaw_alignments: Dictionary = {}) -> void:
	_driver = driver
	var driver_to_target := skeleton.global_transform.affine_inverse() * driver.global_transform
	_driver_basis = driver_to_target.basis.orthonormalized().get_rotation_quaternion()
	var up := (_driver_basis * Vector3.UP).normalized()
	var horizontal_offsets := {}
	var target_by_driver := {}
	for target_name: String in yaw_alignments:
		var next_name: String = yaw_alignments[target_name]
		var target_bone := skeleton.find_bone(target_name)
		var next_target := skeleton.find_bone(next_name)
		var source_bone := driver.find_bone(mapping[target_name])
		var next_driver := driver.find_bone(mapping[next_name])
		var target_dir := skeleton.get_bone_global_rest(next_target).origin - skeleton.get_bone_global_rest(target_bone).origin
		var source_dir := driver.get_bone_global_rest(next_driver).origin - driver.get_bone_global_rest(source_bone).origin
		var driver_dir := _driver_basis * source_dir
		var target_flat := target_dir - up * target_dir.dot(up)
		var driver_flat := driver_dir - up * driver_dir.dot(up)
		if target_flat.length_squared() > 1e-6 and driver_flat.length_squared() > 1e-6:
			target_flat = target_flat.normalized()
			driver_flat = driver_flat.normalized()
			var yaw := Quaternion(up, atan2(up.dot(target_flat.cross(driver_flat)), target_flat.dot(driver_flat)))
			horizontal_offsets[target_name] = yaw
			horizontal_offsets[next_name] = yaw
	for bone in skeleton.get_bone_count():
		var target_name := skeleton.get_bone_name(bone)
		if not mapping.has(target_name):
			continue
		var source := driver.find_bone(mapping[target_name])
		target_by_driver[mapping[target_name]] = bone
		var source_rest := driver.get_bone_global_rest(source)
		var target_rest := skeleton.get_bone_global_rest(bone)
		var source_rotation := _driver_basis * source_rest.basis.orthonormalized().get_rotation_quaternion()
		var aligned_rotation := target_rest.basis.orthonormalized().get_rotation_quaternion()
		if horizontal_offsets.has(target_name):
			aligned_rotation = horizontal_offsets[target_name] * aligned_rotation
		elif alignments.has(target_name):
			var next_name: String = alignments[target_name]
			var next_target := skeleton.find_bone(next_name)
			var next_driver := driver.find_bone(mapping[next_name])
			var target_direction := skeleton.get_bone_global_rest(next_target).origin - target_rest.origin
			var source_direction := driver.get_bone_global_rest(next_driver).origin - source_rest.origin
			var driver_direction := _driver_basis * source_direction.normalized()
			aligned_rotation = Quaternion(target_direction.normalized(), driver_direction) * aligned_rotation
		var link := BoneLink.new()
		link.target = bone
		link.driver = source
		link.parent = skeleton.get_bone_parent(bone)
		link.rotation_offset = source_rotation.inverse() * aligned_rotation
		_links.append(link)

	for side in ["L", "R"]:
		var leg := LegLink.new()
		leg.thigh = target_by_driver["thigh." + side]
		leg.shin = target_by_driver["shin." + side]
		leg.foot = target_by_driver["foot." + side]
		_legs[driver.find_bone("foot." + side)] = leg

	var pelvis := _links[0]
	_hip_rest = skeleton.get_bone_rest(pelvis.target).origin
	_driver_hip_rest = driver.get_bone_global_rest(pelvis.driver).origin
	_pelvis_movement = driver_to_target.basis
	if pelvis.parent >= 0:
		_pelvis_movement = skeleton.get_bone_global_rest(pelvis.parent).basis.inverse() * _pelvis_movement
	var model_root := get_parent() as Node3D
	if model_root != null:
		var target_hip := model_root.to_local(skeleton.global_transform * skeleton.get_bone_global_rest(pelvis.target).origin)
		var driver_hip := model_root.to_local(driver.global_transform * _driver_hip_rest)
		if driver_hip.y > 0.001 and target_hip.y > 0.001:
			_pelvis_height_ratio = clampf(target_hip.y / driver_hip.y, 0.75, 1.25)


const ANIME_ROUGHNESS := 0.89
const ANIME_SPECULAR := 0.16
const ANIME_DEFAULT_TINT := Color(0.88, 0.88, 0.90)
const ANIME_EYE_TINT := Color(0.95, 0.95, 0.96)
const ANIME_OUTLINE_TINT := Color(0.75, 0.75, 0.75)


## Converts imported KHR_materials_unlit / overly hot character materials to soft matte PBR
## (roughness ~0.89, specular ~0.16, gently tempered whites) so faces and white outfits read
## cleanly under AGX sunlight and respond naturally to dusk and night lighting.
static func shade_anime_materials(target_meshes: Array[MeshInstance3D],
		tint_fn: Callable = Callable(),
		diffuse_mode := BaseMaterial3D.DIFFUSE_BURLEY,
		roughness := ANIME_ROUGHNESS,
		specular := ANIME_SPECULAR) -> void:
	for mesh in target_meshes:
		if mesh == null or mesh.mesh == null:
			continue
		for surface in mesh.mesh.get_surface_count():
			var mat := mesh.mesh.surface_get_material(surface) as StandardMaterial3D
			if mat == null:
				continue
			var shaded := mat.duplicate() as StandardMaterial3D
			shaded.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			shaded.diffuse_mode = diffuse_mode
			shaded.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
			shaded.roughness = roughness
			shaded.metallic = 0.0
			shaded.metallic_specular = specular
			shaded.emission_enabled = false
			var tint: Color = tint_fn.call(shaded.resource_name) if tint_fn.is_valid() \
					else default_anime_tint(shaded.resource_name)
			shaded.albedo_color = Color(
				shaded.albedo_color.r * tint.r,
				shaded.albedo_color.g * tint.g,
				shaded.albedo_color.b * tint.b,
				shaded.albedo_color.a,
			)
			mesh.set_surface_override_material(surface, shaded)


static func default_anime_tint(material_name: String) -> Color:
	var upper := material_name.to_upper()
	if upper.contains("_EYE") or upper == "EYES":
		return ANIME_EYE_TINT
	if upper.contains("OUTLINE"):
		return ANIME_OUTLINE_TINT
	return ANIME_DEFAULT_TINT


func pelvis_height_ratio() -> float:
	return _pelvis_height_ratio


## Optional hook for skins that animate their own hair/tail chains from the giant's
## two-layer springs. Default skins ignore it; giant_visual only calls it up close.
func apply_secondary_motion(_sway: Vector2, _tip_sway: Vector2, _bounce: float,
		_tip_bounce: float, _rot_lag: float, _tip_rot: float, _head_down_tilt: float,
		_dt: float) -> void:
	pass


func follow_pose(pelvis_scale := 1.0) -> void:
	var pelvis := _links[0]
	var travel := (_driver.get_bone_global_pose(pelvis.driver).origin - _driver_hip_rest) * pelvis_scale
	skeleton.set_bone_pose_position(pelvis.target, _hip_rest + _pelvis_movement * travel)
	for link in _links:
		var source := _driver.get_bone_global_pose(link.driver).basis.orthonormalized().get_rotation_quaternion()
		var desired := _driver_basis * source * link.rotation_offset
		if link.parent >= 0:
			var parent := skeleton.get_bone_global_pose(link.parent).basis.orthonormalized().get_rotation_quaternion()
			desired = parent.inverse() * desired
		skeleton.set_bone_pose_rotation(link.target, desired)


## Rotation-only retargeting places differently proportioned ankles at different points.
## Keep the live shoe on the driver's sole anchor with a second two-bone solve.
func pin_soles(left_foot: int, left_center: Vector3, left_world: Vector3,
		right_foot: int, right_center: Vector3, right_world: Vector3) -> void:
	var up := _driver_basis * Vector3.UP
	var left_leg := _legs[left_foot]
	var right_leg := _legs[right_foot]
	var left_ankle := skeleton.to_local(left_world) - skeleton.get_bone_global_pose(left_leg.foot).basis * left_center
	var right_ankle := skeleton.to_local(right_world) - skeleton.get_bone_global_pose(right_leg.foot).basis * right_center
	var drop := maxf(_pelvis_drop(left_leg, left_ankle, up), _pelvis_drop(right_leg, right_ankle, up))
	if drop > 0.000001:
		var pelvis := _links[0]
		var displacement := -up * drop
		if pelvis.parent >= 0:
			displacement = skeleton.get_bone_global_pose(pelvis.parent).basis.inverse() * displacement
		skeleton.set_bone_pose_position(pelvis.target, skeleton.get_bone_pose_position(pelvis.target) + displacement)
	_pin_ankle(left_leg, left_ankle)
	_pin_ankle(right_leg, right_ankle)


func _pelvis_drop(leg: LegLink, ankle: Vector3, up: Vector3) -> float:
	var hip := skeleton.get_bone_global_pose(leg.thigh).origin
	var knee := skeleton.get_bone_global_pose(leg.shin).origin
	var original_ankle := skeleton.get_bone_global_pose(leg.foot).origin
	var reach := hip.distance_to(knee) + knee.distance_to(original_ankle) - 0.002
	var offset := ankle - hip
	var vertical_room := sqrt(maxf(reach * reach - offset.slide(up).length_squared(), 0.0))
	return maxf(-offset.dot(up) - vertical_room, 0.0)


func _pin_ankle(leg: LegLink, ankle: Vector3) -> void:
	var thigh := skeleton.get_bone_global_pose(leg.thigh)
	var shin := skeleton.get_bone_global_pose(leg.shin)
	var foot := skeleton.get_bone_global_pose(leg.foot)
	var original_thigh := shin.origin - thigh.origin
	var original_shin := foot.origin - shin.origin
	var upper_len := original_thigh.length()
	var lower_len := original_shin.length()
	var offset := ankle - thigh.origin
	var reach := clampf(offset.length(), absf(upper_len - lower_len) + 0.001, upper_len + lower_len - 0.001)
	var axis := offset.normalized()
	var pole := original_thigh.slide(axis).normalized()
	if pole.is_zero_approx():
		pole = (_driver_basis * Vector3.BACK).slide(axis).normalized()
	var along := (reach * reach + upper_len * upper_len - lower_len * lower_len) / (2.0 * reach)
	var knee := axis * along + pole * sqrt(maxf(upper_len * upper_len - along * along, 0.0))
	var thigh_rot := Quaternion(original_thigh.normalized(), knee.normalized()) * thigh.basis.orthonormalized().get_rotation_quaternion()
	var shin_rot := Quaternion(original_shin.normalized(), (axis * reach - knee).normalized()) * shin.basis.orthonormalized().get_rotation_quaternion()
	_set_world_bone_rotation(leg.thigh, thigh_rot)
	_set_world_bone_rotation(leg.shin, shin_rot)
	_set_world_bone_rotation(leg.foot, foot.basis.orthonormalized().get_rotation_quaternion())


func _set_world_bone_rotation(bone: int, rotation: Quaternion) -> void:
	var parent := skeleton.get_bone_parent(bone)
	var parent_rot := skeleton.get_bone_global_pose(parent).basis.orthonormalized().get_rotation_quaternion()
	skeleton.set_bone_pose_rotation(bone, parent_rot.inverse() * rotation)
