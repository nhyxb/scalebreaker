extends RefCounted
## Stores source files and the player preference in Godot's app-private data directory.

const Loader := preload("res://scenes/vrm_loader.gd")
const DIRECTORY := "user://vrm_skins"
const PREFERENCE := "user://vrm_skin.cfg"

static var _cached_name := ""
static var _cached_avatar: Loader.Avatar


static func open_directory() -> Error:
	return DirAccess.make_dir_recursive_absolute(DIRECTORY)


static func files() -> PackedStringArray:
	var names := PackedStringArray()
	for file in DirAccess.get_files_at(DIRECTORY):
		if _valid_name(file):
			names.append(file)
	return names


static func selected() -> String:
	var config := ConfigFile.new()
	if config.load(PREFERENCE) != OK:
		return ""
	var file: Variant = config.get_value("player", "skin", "")
	return file if file is String and _valid_name(file) else ""


static func active_avatar() -> Loader.Avatar:
	var file := selected()
	if not _valid_name(file) or not FileAccess.file_exists(DIRECTORY.path_join(file)):
		return null
	if _cached_name != file:
		var avatar := Loader.decode(Loader.read(DIRECTORY.path_join(file)))
		if not avatar.error.is_empty():
			return null
		_cached_name = file
		_cached_avatar = avatar
	return _cached_avatar


static func import_file(path: String) -> String:
	var bytes := Loader.read(path)
	if bytes.is_empty():
		return "无法读取文件，或文件超过 96 MiB。"
	var avatar := Loader.decode(bytes)
	if not avatar.error.is_empty():
		return avatar.error
	if open_directory() != OK:
		return "无法创建 VRM 皮肤目录。"

	var stem := path.get_file().get_basename() if path.get_extension().to_lower() == "vrm" else avatar.display_name
	stem = stem.validate_filename().strip_edges().left(60)
	if stem.is_empty() or stem.begins_with("."):
		stem = "VRM 模型"
	var file := stem + ".vrm"
	var suffix := 2
	while FileAccess.file_exists(DIRECTORY.path_join(file)):
		file = "%s (%d).vrm" % [stem, suffix]
		suffix += 1

	var target := DIRECTORY.path_join(file)
	var temporary := target + ".part"
	var output := FileAccess.open(temporary, FileAccess.WRITE)
	if output == null:
		return "无法将 VRM 保存到游戏目录。"
	var written := output.store_buffer(bytes)
	output.close()
	if not written or DirAccess.rename_absolute(temporary, target) != OK:
		DirAccess.remove_absolute(temporary)
		return "无法将 VRM 保存到游戏目录。"
	if _save_selection(file) != OK:
		return "模型已导入，保存选用项失败，请重新选用。"
	_cached_name = file
	_cached_avatar = avatar
	return ""


static func choose(file: String) -> String:
	if file.is_empty():
		if _save_selection("") != OK:
			return "无法保存选用项。"
		_cached_name = ""
		_cached_avatar = null
		return ""
	if not _valid_name(file):
		return "找不到该 VRM 文件。"
	var avatar := _cached_avatar if _cached_name == file else Loader.decode(Loader.read(DIRECTORY.path_join(file)))
	if not avatar.error.is_empty():
		return avatar.error
	if _save_selection(file) != OK:
		return "无法保存选用项。"
	_cached_name = file
	_cached_avatar = avatar
	return ""


static func remove(file: String) -> String:
	if not _valid_name(file) or DirAccess.remove_absolute(DIRECTORY.path_join(file)) != OK:
		return "无法删除该 VRM 文件。"
	if _cached_name == file:
		_cached_name = ""
		_cached_avatar = null
	if selected() == file and _save_selection("") != OK:
		return "模型已删除。下局将使用随机内置皮肤。"
	return ""


static func _save_selection(file: String) -> Error:
	var config := ConfigFile.new()
	config.set_value("player", "skin", file)
	var temporary := PREFERENCE + ".part"
	var error := config.save(temporary)
	if error == OK:
		error = DirAccess.rename_absolute(temporary, PREFERENCE)
	if error != OK:
		DirAccess.remove_absolute(temporary)
	return error


static func _valid_name(file: String) -> bool:
	return not file.begins_with(".") and file.get_extension().to_lower() == "vrm" \
			and file == file.get_file() and file == file.validate_filename()
