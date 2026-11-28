extends RefCounted
## Reads self-contained VRM 0.x / 1.0 glTF binaries in the exported game.

const MAX_FILE_BYTES := 96 * 1024 * 1024
const NAMED_SKIN_BINDS := 16 # GLTFDocument::IMPORT_USE_NAMED_SKIN_BINDS
const REQUIRED_BONES := [
	"hips", "spine", "head",
	"leftUpperArm", "leftLowerArm", "leftHand", "rightUpperArm", "rightLowerArm", "rightHand",
	"leftUpperLeg", "leftLowerLeg", "leftFoot", "rightUpperLeg", "rightLowerLeg", "rightFoot",
]


class Avatar:
	var scene: PackedScene
	var display_name := ""
	var rig_path: NodePath
	var bones: Dictionary[String, StringName] = {}
	var first_person: Dictionary[StringName, String] = {}
	var legacy := false
	var error := ""


static func read(path: String) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var length := file.get_length()
	if length < 20 or length > MAX_FILE_BYTES:
		return PackedByteArray()
	return file.get_buffer(length)


static func decode(bytes: PackedByteArray) -> Avatar:
	if bytes.size() < 20 or bytes.size() > MAX_FILE_BYTES or bytes.decode_u32(0) != 0x46546C67 \
			or bytes.decode_u32(4) != 2 or bytes.decode_u32(8) != bytes.size() \
			or bytes.decode_u32(16) != 0x4E4F534A:
		return _failed("文件不是有效的 VRM 模型。")
	var json_length := bytes.decode_u32(12)
	if json_length <= 0 or json_length > bytes.size() - 20:
		return _failed("VRM 文件头已损坏。")
	var parsed: Variant = JSON.parse_string(bytes.slice(20, 20 + json_length).get_string_from_utf8())
	if not parsed is Dictionary:
		return _failed("VRM 模型信息无法读取。")
	var gltf: Dictionary = parsed
	var extensions := _object(gltf.get("extensions"))
	var vrm := _object(extensions.get("VRMC_vrm"))
	var legacy := vrm.is_empty()
	if legacy:
		vrm = _object(extensions.get("VRM"))
	elif String(vrm.get("specVersion", "")) != "1.0":
		return _failed("当前支持 VRM 0.x 和 1.0。")
	if vrm.is_empty():
		return _failed("文件缺少 VRM 人形骨骼信息。")
	for section in ["buffers", "images"]:
		for item in _list(gltf.get(section)):
			var uri := str(_object(item).get("uri", ""))
			if not uri.is_empty() and not uri.begins_with("data:"):
				return _failed("请使用内嵌贴图和网格的 VRM 文件。")

	var bone_indices := _bone_indices(vrm, legacy)
	var node_count := _list(gltf.get("nodes")).size()
	for required: String in REQUIRED_BONES:
		var index: int = bone_indices.get(required, -1)
		if index < 0 or index >= node_count:
			return _failed("模型缺少必要的人形骨骼（%s）。" % required)

	var document := GLTFDocument.new()
	var state := GLTFState.new()
	state.create_animations = false
	if document.append_from_buffer(bytes, "", state, NAMED_SKIN_BINDS) != OK:
		return _failed("Godot 无法读取该模型的网格或贴图。")
	_mark_mtoon(state, gltf, vrm, legacy)
	var model := document.generate_scene(state) as Node3D
	if model == null:
		return _failed("VRM 模型没有可用的场景。")
	var avatar := _describe_model(model, state.get_nodes(), bone_indices)
	if avatar.error.is_empty():
		var meta := _object(vrm.get("meta"))
		avatar.display_name = str(meta.get("title" if legacy else "name", "")).strip_edges()
		avatar.legacy = legacy
		avatar.first_person = _visibility(vrm, state.get_nodes(), legacy)
	model.free()
	return avatar


static func _describe_model(model: Node3D, nodes: Array[GLTFNode], indices: Dictionary) -> Avatar:
	var hips_index: int = indices["hips"]
	var rig_index := nodes[hips_index].skeleton
	if rig_index < 0:
		return _failed("VRM 的人形骨骼未绑定到网格。")
	var bones: Dictionary[String, StringName] = {}
	for slot: String in indices:
		var index: int = indices[slot]
		if index >= 0 and index < nodes.size() and nodes[index].skeleton == rig_index:
			bones[slot] = StringName(nodes[index].resource_name)
	for slot: String in REQUIRED_BONES:
		if not bones.has(slot):
			return _failed("VRM 的必要骨骼必须属于同一个人形骨架。")

	var meshes := model.find_children("*", "MeshInstance3D", true, false)
	for node in meshes:
		var mesh := node as MeshInstance3D
		if mesh.skin == null:
			continue
		var rig := mesh.get_node_or_null(mesh.skeleton) as Skeleton3D
		if rig == null or rig.find_bone(bones["hips"]) < 0:
			continue
		var hips := rig.find_bone(bones["hips"])
		var used := {hips: true}
		for slot: String in REQUIRED_BONES:
			if slot == "hips":
				continue
			var bone := rig.find_bone(bones[slot])
			if bone < 0 or used.has(bone) or not _descends_from(rig, bone, hips):
				return _failed("VRM 的人形骨骼绑定不完整。")
			used[bone] = true
		var avatar := Avatar.new()
		avatar.rig_path = model.get_path_to(rig)
		avatar.bones = bones
		avatar.scene = PackedScene.new()
		if avatar.scene.pack(model) != OK:
			return _failed("VRM 模型无法实例化。")
		return avatar
	return _failed("VRM 没有可用的人形蒙皮网格。")


static func _descends_from(rig: Skeleton3D, bone: int, ancestor: int) -> bool:
	while bone >= 0:
		if bone == ancestor:
			return true
		bone = rig.get_bone_parent(bone)
	return false


static func _mark_mtoon(state: GLTFState, gltf: Dictionary, vrm: Dictionary, legacy: bool) -> void:
	var materials := state.get_materials()
	var definitions := _list(vrm.get("materialProperties") if legacy else gltf.get("materials"))
	for index in mini(materials.size(), definitions.size()):
		var material := materials[index]
		var definition := _object(definitions[index])
		var toon: bool = definition.get("shader") == "VRM/MToon" if legacy \
				else _object(definition.get("extensions")).has("VRMC_materials_mtoon")
		if material != null and toon:
			material.set_meta(&"vrm_mtoon", true)


static func _bone_indices(vrm: Dictionary, legacy: bool) -> Dictionary:
	var humanoid := _object(vrm.get("humanoid"))
	var indices := {}
	if legacy:
		for entry in _list(humanoid.get("humanBones")):
			var bone := _object(entry)
			indices[str(bone.get("bone", ""))] = _node_index(bone.get("node"))
	else:
		var human_bones := _object(humanoid.get("humanBones"))
		for slot: String in human_bones:
			indices[slot] = _node_index(_object(human_bones[slot]).get("node"))
	return indices


static func _visibility(vrm: Dictionary, nodes: Array[GLTFNode], legacy: bool) -> Dictionary[StringName, String]:
	var result: Dictionary[StringName, String] = {}
	var first_person := _object(vrm.get("firstPerson"))
	for entry in _list(first_person.get("meshAnnotations")):
		var annotation := _object(entry)
		if legacy:
			var mesh_index := _node_index(annotation.get("mesh"))
			if mesh_index >= 0:
				for node in nodes:
					if node.mesh == mesh_index:
						result[StringName(node.resource_name)] = str(annotation.get("firstPersonFlag", "Auto")).to_lower()
		else:
			var node_index := _node_index(annotation.get("node"))
			if node_index >= 0 and node_index < nodes.size() and nodes[node_index].mesh >= 0:
				result[StringName(nodes[node_index].resource_name)] = str(annotation.get("type", "auto")).to_lower()
	return result


static func _node_index(value: Variant) -> int:
	if (value is float or value is int) and value >= 0 and value <= 0x7fffffff and value == floorf(value):
		return int(value)
	return -1


static func _object(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


static func _list(value: Variant) -> Array:
	return value if value is Array else []


static func _failed(message: String) -> Avatar:
	var avatar := Avatar.new()
	avatar.error = message
	return avatar
