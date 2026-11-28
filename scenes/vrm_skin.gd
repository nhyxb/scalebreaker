extends "res://scenes/giant_skin.gd"
## Retargets VRM humanoid slots onto the Kawaii driver and fits the model to its height.

const Loader := preload("res://scenes/vrm_loader.gd")
const DRIVER_HEIGHT := 1.7047
const TORSO := {
	"hips": "spine", "spine": "spine.001", "chest": "spine.002", "upperChest": "spine.003",
	"neck": "Neck", "head": "Head",
}
const LIMBS := {
	"Shoulder": "shoulder", "UpperArm": "upper_arm", "LowerArm": "forearm", "Hand": "hand",
	"UpperLeg": "thigh", "LowerLeg": "shin", "Foot": "foot", "Toes": "toe",
}
const FINGERS := {
	"Index": "f_index", "Middle": "f_middle", "Ring": "f_ring", "Little": "f_pinky", "Thumb": "thumb",
}


class Sole:
	var offset: Vector2
	var half_extents: Vector2
	var outline: Array[Vector2] = []
	var bone_center: Vector3


var avatar: Loader.Avatar
var soles: Array[Sole] = []
var _first_person_only: Array[MeshInstance3D] = []
var _first_person_bodies: Dictionary[MeshInstance3D, ArrayMesh] = {}


func configure(driver: Skeleton3D) -> void:
	var model := avatar.scene.instantiate() as Node3D
	add_child(model)
	skeleton = model.get_node(avatar.rig_path) as Skeleton3D
	for mesh in model.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh != null:
			meshes.append(mesh)
	if avatar.legacy:
		rotation.y = PI # VRM 0.x faces -Z, VRM 1.0 and the driver face +Z.
	_fit_height()
	_retarget(driver, avatar.bones, avatar.legacy)
	_configure_avatar_visibility(avatar.first_person)
	_shade_vrm_materials()
	follow_pose()
	_measure_soles(avatar.bones)


func _fit_height() -> void:
	var world_to_skin := global_transform.affine_inverse()
	var bottom := INF
	var top := -INF
	for mesh in meshes:
		var bounds: AABB = (world_to_skin * mesh.global_transform) * mesh.get_aabb()
		bottom = minf(bottom, bounds.position.y)
		top = maxf(top, bounds.end.y)
	if is_finite(bottom) and is_finite(top) and top - bottom > 0.001:
		var fit := DRIVER_HEIGHT / (top - bottom)
		scale = Vector3.ONE * fit
		position.y = -bottom * fit


func _retarget(driver: Skeleton3D, bones: Dictionary, legacy := false) -> void:
	var driver_slots := TORSO.duplicate()
	var chains := [["hips", "spine", "chest", "upperChest", "neck", "head"]]
	var yaw_slots := {}
	for side in ["left", "right"]:
		var suffix := ".L" if side == "left" else ".R"
		for limb: String in LIMBS:
			driver_slots[side + limb] = LIMBS[limb] + suffix
		chains.append([side + "Shoulder", side + "UpperArm", side + "LowerArm", side + "Hand"])
		chains.append([side + "UpperLeg", side + "LowerLeg", side + "Foot"])
		if bones.has(side + "Toes") and skeleton.find_bone(bones[side + "Toes"]) >= 0:
			yaw_slots[bones[side + "Foot"]] = bones[side + "Toes"]
		for digit: String in FINGERS:
			var segments := ["Proximal", "Intermediate", "Distal"]
			if digit == "Thumb" and not legacy:
				segments = ["Metacarpal", "Proximal", "Distal"]
			for index in segments.size():
				driver_slots[side + digit + segments[index]] = "%s.%02d%s" % [FINGERS[digit], index + 1, suffix]

	var mapping := {}
	for slot: String in driver_slots:
		if bones.has(slot) and skeleton.find_bone(bones[slot]) >= 0 and driver.find_bone(driver_slots[slot]) >= 0:
			mapping[String(bones[slot])] = driver_slots[slot]
	var alignments := {}
	for chain: Array in chains:
		var previous := ""
		for slot: String in chain:
			var bone := String(bones.get(slot, ""))
			if not mapping.has(bone):
				continue
			if not previous.is_empty():
				alignments[previous] = bone
			previous = bone
	_configure_pose(driver, mapping, alignments, yaw_slots)


func _shade_vrm_materials(tint := Callable(), diffuse := BaseMaterial3D.DIFFUSE_BURLEY,
		convert_all := false, shared: Dictionary = {}) -> void:
	for mesh in meshes:
		var source := mesh.mesh as ArrayMesh
		if source == null:
			continue
		var shaded: ArrayMesh = shared.get(source)
		if shaded == null:
			for surface in source.get_surface_count():
				var material := source.surface_get_material(surface) as StandardMaterial3D
				if material == null:
					continue
				var is_toon := material.has_meta(&"vrm_mtoon") or material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED
				if not convert_all and not is_toon:
					continue
				if shaded == null:
					shaded = source.duplicate() as ArrayMesh
				shaded.surface_set_material(surface, matte_material(material, tint, diffuse))
			if shaded != null:
				shared[source] = shaded
		if shaded != null:
			mesh.mesh = shaded
			if body_meshes.has(mesh):
				body_meshes[mesh] = shaded


func _configure_avatar_visibility(annotations: Dictionary) -> void:
	head_bone = avatar.bones["head"]
	var head := skeleton.find_bone(head_bone)
	for mesh in meshes:
		match annotations.get(mesh.name, "auto"):
			"both":
				continue
			"thirdpersononly":
				head_parts.append(mesh)
			"firstpersononly":
				_first_person_only.append(mesh)
				mesh.hide()
			_:
				var attachment := _bone_attachment(mesh)
				if attachment != null and _under_bone(attachment.get_bone_idx(), head):
					head_parts.append(mesh)
				elif mesh.skin != null and mesh.get_node_or_null(mesh.skeleton) == skeleton and mesh.mesh is ArrayMesh:
					body_meshes[mesh] = mesh.mesh


func _bone_attachment(node: Node3D) -> BoneAttachment3D:
	var parent := node.get_parent()
	while parent != null and parent != self:
		if parent is BoneAttachment3D and parent.get_parent() == skeleton:
			return parent
		parent = parent.get_parent()
	return null


func set_first_person(enabled: bool) -> void:
	var head := skeleton.find_bone(head_bone)
	for body in body_meshes:
		if enabled and not _first_person_bodies.has(body):
			var cropped := _crop_head(body.skin, body_meshes[body], head)
			if cropped == null:
				head_parts.append(body)
			_first_person_bodies[body] = cropped
		# Keep fully head-bound meshes intact for their shadows.
		if _first_person_bodies.get(body) != null:
			body.mesh = _first_person_bodies[body] if enabled else body_meshes[body]
	for part in head_parts:
		part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if enabled \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for part in _first_person_only:
		part.visible = enabled


func _under_bone(bone: int, ancestor: int) -> bool:
	while bone >= 0:
		if bone == ancestor:
			return true
		bone = skeleton.get_bone_parent(bone)
	return false


func _bind_bone(skin: Skin, bind: int) -> int:
	var named := skin.get_bind_name(bind)
	return skeleton.find_bone(named) if not named.is_empty() else skin.get_bind_bone(bind)


func _crop_head(skin: Skin, source: ArrayMesh, head: int) -> ArrayMesh:
	var hidden_binds := PackedByteArray()
	hidden_binds.resize(skin.get_bind_count())
	for bind in hidden_binds.size():
		hidden_binds[bind] = int(_under_bone(_bind_bone(skin, bind), head))
	var result := ArrayMesh.new()
	result.blend_shape_mode = source.blend_shape_mode
	for shape in source.get_blend_shape_count():
		result.add_blend_shape(source.get_blend_shape_name(shape))

	for surface in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface)
		if arrays[Mesh.ARRAY_BONES] != null and source.surface_get_primitive_type(surface) == Mesh.PRIMITIVE_TRIANGLES:
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var binds: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			var head_vertices := PackedByteArray()
			head_vertices.resize(vertices.size())
			var influences := binds.size() / vertices.size()
			for vertex in vertices.size():
				var weight := 0.0
				for slot in influences:
					var index := vertex * influences + slot
					if hidden_binds[binds[index]]:
						weight += weights[index]
				head_vertices[vertex] = int(weight >= 0.5)

			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var count := vertices.size() if indices.is_empty() else indices.size()
			var kept := PackedInt32Array()
			for i in range(0, count - 2, 3):
				var a := i if indices.is_empty() else indices[i]
				var b := i + 1 if indices.is_empty() else indices[i + 1]
				var c := i + 2 if indices.is_empty() else indices[i + 2]
				if not (head_vertices[a] or head_vertices[b] or head_vertices[c]):
					kept.append(a)
					kept.append(b)
					kept.append(c)
			if kept.is_empty():
				continue
			arrays[Mesh.ARRAY_INDEX] = kept
		var flags := source.surface_get_format(surface) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		result.add_surface_from_arrays(source.surface_get_primitive_type(surface), arrays,
				source.surface_get_blend_shape_arrays(surface), {}, flags)
		result.surface_set_material(result.get_surface_count() - 1, source.surface_get_material(surface))
	return result if result.get_surface_count() > 0 else null


func _measure_soles(bones: Dictionary) -> void:
	var feet := PackedInt32Array([skeleton.find_bone(bones["leftFoot"]), skeleton.find_bone(bones["rightFoot"])])
	var points: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array()]
	for mesh in meshes:
		if mesh.skin == null or mesh.get_node_or_null(mesh.skeleton) != skeleton:
			continue
		_collect_foot_vertices(mesh, feet, points)

	var world_to_forward := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO) * get_parent_node_3d().global_transform.affine_inverse()
	var rig_to_forward := world_to_forward * skeleton.global_transform
	for side in feet.size():
		var ankle := rig_to_forward * skeleton.get_bone_global_pose(feet[side])
		var toe := skeleton.find_bone(bones.get("leftToes" if side == 0 else "rightToes", &""))
		var heading := Vector3.FORWARD
		if toe >= 0:
			var toe_position := rig_to_forward * skeleton.get_bone_global_pose(toe).origin
			var toe_heading := (toe_position - ankle.origin).slide(Vector3.UP).normalized()
			if not toe_heading.is_zero_approx():
				heading = toe_heading
		var axes := Basis(Vector3.UP, atan2(-heading.x, -heading.z))
		soles.append(_measure_sole(points[side], rig_to_forward, ankle, axes))


func _collect_foot_vertices(mesh: MeshInstance3D, feet: PackedInt32Array,
		points: Array[PackedVector3Array]) -> void:
	var transforms: Array[Transform3D] = []
	var sides := PackedInt32Array()
	for bind in mesh.skin.get_bind_count():
		var bone := _bind_bone(mesh.skin, bind)
		transforms.append(skeleton.get_bone_global_pose(bone) * mesh.skin.get_bind_pose(bind) if bone >= 0 else Transform3D.IDENTITY)
		var side := -1
		if _under_bone(bone, feet[0]):
			side = 0
		elif _under_bone(bone, feet[1]):
			side = 1
		sides.append(side)

	for surface in mesh.mesh.get_surface_count():
		var arrays := mesh.mesh.surface_get_arrays(surface)
		if arrays[Mesh.ARRAY_BONES] == null:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var influences := joints.size() / vertices.size()
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var seen := PackedByteArray()
		seen.resize(vertices.size())
		var count := vertices.size() if indices.is_empty() else indices.size()
		for i in count:
			var vertex := i if indices.is_empty() else indices[i]
			if seen[vertex]:
				continue
			seen[vertex] = 1
			var foot_weight := Vector2.ZERO
			var start := vertex * influences
			for weight_index in range(start, start + influences):
				var side := sides[joints[weight_index]]
				if side >= 0:
					foot_weight[side] += weights[weight_index]
			if maxf(foot_weight.x, foot_weight.y) < 0.45:
				continue
			var point := Vector3.ZERO
			for weight_index in range(start, start + influences):
				point += (transforms[joints[weight_index]] * vertices[vertex]) * weights[weight_index]
			var side := 0 if foot_weight.x > foot_weight.y else 1
			points[side].append(point)


static func _measure_sole(points: PackedVector3Array, rig_to_forward: Transform3D,
		ankle: Transform3D, axes: Basis) -> Sole:
	var low := INF
	var local_points := PackedVector3Array()
	var forward_to_shoe := axes.inverse()
	for point in points:
		var relative := forward_to_shoe * (rig_to_forward * point - ankle.origin)
		local_points.append(relative)
		low = minf(low, relative.y)
	var bottom := PackedVector2Array()
	for point in local_points:
		if point.y < low + 0.02:
			bottom.append(Vector2(point.x, point.z))
	var hull := Geometry2D.convex_hull(bottom) if bottom.size() >= 3 else PackedVector2Array()
	if hull.size() < 4:
		return null
	var bounds := Rect2(hull[0], Vector2.ZERO)
	for point in hull:
		bounds = bounds.expand(point)
	var sole := Sole.new()
	sole.offset = bounds.get_center()
	sole.half_extents = bounds.size * 0.5
	if minf(sole.half_extents.x, sole.half_extents.y) < 0.002:
		return null
	var center := Vector3(sole.offset.x, low, sole.offset.y)
	sole.bone_center = ankle.affine_inverse() * (ankle.origin + axes * center)
	# Geometry2D repeats the start vertex at the end. The footprint API closes the polygon itself.
	for i in hull.size() - 1:
		sole.outline.append((hull[i] - sole.offset) / sole.half_extents)
	return sole
