@abstract
extends Node3D
## Drives an alternate model from the procedural giant pose in skeleton space.

class BoneLink:
	var target: int
	var driver: int
	var parent: int
	var rotation_offset: Quaternion

var skeleton: Skeleton3D
var head_bone: StringName
var head_parts: Array[MeshInstance3D] = []
var body_meshes: Dictionary[MeshInstance3D, ArrayMesh] = {}
var meshes: Array[MeshInstance3D] = []

var _driver: Skeleton3D
var _links: Array[BoneLink] = []
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
