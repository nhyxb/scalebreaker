extends SceneTree
## Runtime importer, picker-to-round workflow, and the built-in Snow Fox regression.

const Loader := preload("res://scenes/vrm_loader.gd")
const Library := preload("res://scenes/vrm_library.gd")
const MAIN := preload("res://scenes/main.tscn")
const GIANT := preload("res://scenes/giant.tscn")

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# A unique App data directory is used by the test command, so test imports are disposable.
	if not OS.get_environment("XDG_DATA_HOME").contains("vrm-test"):
		push_error("Use an isolated XDG_DATA_HOME containing vrm-test for the VRM playtest.")
		quit(2)
		return
	var args := OS.get_cmdline_user_args()
	var source := args[0] if not args.is_empty() else "res://assets/characters/snow_fox.glb"
	var bytes := Loader.read(source)
	var avatar := Loader.decode(bytes)
	_check(avatar.error.is_empty(), "VRM 1.0 loads via FileAccess and GLTFDocument: " + avatar.error)
	if avatar.scene == null:
		quit(1)
		return
	_check(not Loader.decode(bytes.slice(0, 32)).error.is_empty(), "Truncated GLB is rejected")
	var legacy := Loader.decode(_legacy_fixture(bytes))
	_check(legacy.error.is_empty() and legacy.legacy and legacy.bones.get("hips") == &"CustomPelvis",
			"VRM 0.x uses humanoid metadata with arbitrary joint names: " + legacy.error)
	_check(legacy.first_person.get(&"Face") == "thirdpersononly", "Legacy first-person mesh annotation is read")
	_check_pose(avatar, legacy)

	var sample := "user://Runtime Fox.vrm"
	_write(sample, bytes)
	var bad := "user://Broken.vrm"
	_write(bad, bytes.slice(0, 32))
	var game := MAIN.instantiate()
	root.add_child(game)
	current_scene = game
	await process_frame
	var view := game.get_node("Interface")
	var open := view.find_child("MenuSkins", true, false) as BaseButton
	open.pressed.emit()
	var panel := view.find_child("SkinManager", true, false) as Control
	_check(panel.visible, "Main menu opens the skin manager")
	var picker := view.get_node("VrmFilePicker") as FileDialog
	picker.file_selected.emit(bad)
	for i in 4:
		await process_frame
	_check(Library.files().is_empty() and Library.selected().is_empty(),
			"Invalid imports leave the library and player selection unchanged")
	picker.file_selected.emit(sample)
	for i in 4:
		await process_frame
	var selected := Library.selected()
	_check(selected == "Runtime Fox.vrm" and selected in Library.files()
			and not FileAccess.file_exists(Library.DIRECTORY.path_join(selected) + ".import"),
			"Picker copies and selects the raw VRM in user://")
	_check(view.handle_back() and not panel.visible, "Back closes the manager")
	game.start_mode(true)
	var giant := game.get_node("MapSlot").get_child(0).get_node("Giant")
	_check(giant.skin_name == &"Custom VRM", "New player giant uses the saved VRM")
	game.restart()
	giant = game.get_node("MapSlot").get_child(0).get_node("Giant")
	_check(giant.skin_name == &"Custom VRM", "Restart uses the saved VRM again")
	game.show_menu()
	game.start_mode(false)
	giant = game.get_node("MapSlot").get_child(0).get_node("Giant")
	_check(giant.skin_name != &"Custom VRM", "The evacuation AI uses an internal skin")
	game.show_menu()
	open.pressed.emit()
	var random := panel.find_child("RandomSkin", true, false) as Button
	random.button_pressed = true
	random.pressed.emit()
	(panel.find_child("UseVrm", true, false) as BaseButton).pressed.emit()
	_check(Library.selected().is_empty() and Library.active_avatar() == null, "Player can switch back to random skins")
	var imported := panel.find_child("ImportedSkin", true, false) as Button
	imported.button_pressed = true
	imported.pressed.emit()
	(panel.find_child("UseVrm", true, false) as BaseButton).pressed.emit()
	_check(Library.selected() == selected and Library.active_avatar() != null, "Player can reselect a saved file")
	(panel.find_child("RemoveVrm", true, false) as BaseButton).pressed.emit()
	(view.get("_skin_confirm") as ConfirmationDialog).confirmed.emit()
	_check(Library.files().is_empty() and Library.selected().is_empty(), "Deleting the active VRM restores random skins")
	game.queue_free()
	await process_frame
	quit(0 if _failures == 0 else 1)


func _check_pose(avatar: Loader.Avatar, legacy: Loader.Avatar) -> void:
	var giant := GIANT.instantiate()
	root.add_child(giant)
	for skin_name: StringName in [&"Snow Fox", &"Custom VRM"]:
		giant._set_skin(skin_name, avatar if skin_name == &"Custom VRM" else null)
		giant.show_motion(0.0, -1.0, 0.0)
		var skin: Node3D = giant._active_skin
		_check(absf(skin.scale.y * 1.45281 - 1.7047) < 0.002, "%s fits the driver height" % skin_name)
		_check(skin.soles.size() == 2 and skin.soles[0] != null and skin.soles[1] != null
				and skin.soles[0].outline.size() >= 8 and skin.soles[1].outline.size() >= 8,
				"%s builds both convex shoe outlines" % skin_name)
		var body := skin.skeleton.find_child("Body", true, false) as MeshInstance3D
		var full := body.mesh
		var shoe := _shoe_material(full)
		_check(shoe != null and shoe.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL
				and not shoe.emission_enabled and shoe.roughness > 0.8,
				"%s tempers the shoe material" % skin_name)
		giant.set_first_person(true)
		var head := skin.skeleton.find_child("Hair", true, false) as MeshInstance3D
		_check(body.mesh != full and _shoe_material(body.mesh) == shoe
				and head.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY,
				"%s crops head geometry while leaving the visible shoes and head shadows" % skin_name)
		giant.set_first_person(false)
		_check(body.mesh == full and head.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
				"%s restores the complete third-person mesh" % skin_name)
	if legacy.scene != null:
		giant._set_skin(&"Kawaii")
		giant._set_skin(&"Custom VRM", legacy)
		var skin: Node3D = giant._active_skin
		var rig: Skeleton3D = skin.skeleton
		var toe := rig.find_bone(legacy.bones["leftToes"])
		var foot := rig.find_bone(legacy.bones["leftFoot"])
		var direction := rig.to_global(rig.get_bone_global_pose(toe).origin) \
				- rig.to_global(rig.get_bone_global_pose(foot).origin)
		_check(direction.z < 0.0, "VRM 0.x faces gameplay forward")
	giant.free()


func _shoe_material(mesh: Mesh) -> StandardMaterial3D:
	for index in mesh.get_surface_count():
		var material := mesh.surface_get_material(index) as StandardMaterial3D
		if material != null and material.resource_name.contains("Shoes"):
			return material
	return null


func _legacy_fixture(bytes: PackedByteArray) -> PackedByteArray:
	var json_end := 20 + bytes.decode_u32(12)
	var gltf: Dictionary = JSON.parse_string(bytes.slice(20, json_end).get_string_from_utf8())
	var vrm: Dictionary = gltf.extensions["VRMC_vrm"]
	var bones := []
	for slot: String in vrm.humanoid.humanBones:
		var index: int = vrm.humanoid.humanBones[slot].node
		bones.append({"bone": slot, "node": index})
		if slot == "hips":
			gltf.nodes[index].name = "CustomPelvis"
	# Turn the source from VRM 1.0 +Z to VRM 0.x -Z.
	gltf.nodes.append({"name": "LegacyOrientation", "rotation": [0, 1, 0, 0], "children": gltf.scenes[0].nodes})
	gltf.scenes[0].nodes = [gltf.nodes.size() - 1]
	gltf.extensions = {"VRM": {"specVersion": "0.0", "meta": {"title": "Legacy Fox"},
		"humanoid": {"humanBones": bones},
		"firstPerson": {"meshAnnotations": [{"mesh": 0, "firstPersonFlag": "ThirdPersonOnly"}]}}}
	gltf.extensionsUsed = ["KHR_texture_transform", "KHR_materials_unlit", "VRM"]
	var json := JSON.stringify(gltf).to_utf8_buffer()
	while json.size() % 4 != 0:
		json.append(32)
	var result := bytes.slice(0, 20)
	result.append_array(json)
	result.append_array(bytes.slice(json_end))
	result.encode_u32(8, result.size())
	result.encode_u32(12, json.size())
	return result


func _write(path: String, bytes: PackedByteArray) -> void:
	var output := FileAccess.open(path, FileAccess.WRITE)
	output.store_buffer(bytes)
	output.close()


func _check(condition: bool, summary: String) -> void:
	if condition:
		print("PASS ", summary)
	else:
		_failures += 1
		printerr("FAIL ", summary)
