extends SceneTree
## Verifies the HarborAudio bus layout, loaded sound assets, persistent volume/mute
## settings, mobile font glyphs, and live playback triggers across Harbor modes and Bedroom.

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var audio := root.get_node_or_null("HarborAudio")
	if not _check(audio != null, "HarborAudio autoload initializes"):
		quit(1)
		return

	_check_buses_and_streams(audio)

	var loaded := change_scene_to_file("res://scenes/main.tscn")
	if not _check(loaded == OK, "main scene loads with audio active"):
		quit(1)
		return
	await scene_changed
	var game := current_scene
	var settings_path := "user://audio-playtest-%d-%d.cfg" % [OS.get_process_id(), Time.get_ticks_usec()]
	game.settings_path = settings_path
	await process_frame

	_check(audio.call("get_current_ambience") == &"harbor", "main menu activates coastal harbor ambience")

	await _check_audio_settings(game, audio, settings_path)
	await _check_ui_and_human_sfx(game, audio)
	await _check_giant_and_destruction_sfx(game, audio)
	await _check_growth_sfx(game, audio)
	await _check_bedroom_sfx(audio)

	if FileAccess.file_exists(settings_path):
		DirAccess.remove_absolute(settings_path)
	audio.call("apply_audio_settings", 0.85, 0.60, false)
	print("Audio: %d passed, %d failed" % [_checks - _failures, _failures])
	quit(1 if _failures else 0)


func _check_buses_and_streams(audio: Node) -> void:
	_check(AudioServer.get_bus_index(&"Master") == 0
			and AudioServer.get_bus_index(&"SFX") > 0
			and AudioServer.get_bus_index(&"Ambience") > 0
			and AudioServer.get_bus_index(&"UI") > 0,
			"audio bus layout defines Master, SFX, Ambience, and UI buses")
	var sfx_bus := AudioServer.get_bus_index(&"SFX")
	_check(AudioServer.get_bus_effect_count(sfx_bus) >= 1,
			"SFX bus includes a limiter to prevent multi-giant clipping")

	var ids: PackedStringArray = audio.call("stream_ids")
	var all_valid := ids.size() >= 35
	for id in ids:
		var stream: AudioStream = audio.call("get_stream", StringName(id))
		if stream == null or stream.get_length() <= 0.01:
			all_valid = false
			break
	_check(all_valid, "all %d SFX streams load cleanly with non-zero length" % ids.size())

	var amb_ids: PackedStringArray = audio.call("ambience_ids")
	var amb_valid := amb_ids.has("harbor") and amb_ids.has("bedroom")
	for id in amb_ids:
		var stream: AudioStream = audio.call("get_stream", StringName(id))
		if stream == null or stream.get_length() < 10.0:
			amb_valid = false
			break
	_check(amb_valid, "harbor and bedroom looping ambience OGG streams load cleanly")

	var bundled := load("res://assets/fonts/harbor-ui.otf") as Font
	var glyphs_ok := bundled != null
	if glyphs_ok:
		for ch in ["音", "效", "量", "环", "境", "静"]:
			if not bundled.has_char(ch.unicode_at(0)):
				glyphs_ok = false
				break
	_check(glyphs_ok, "bundled Android CJK font includes all new audio setting glyphs")


func _check_audio_settings(game: Node, audio: Node, settings_path: String) -> void:
	var defaults: Dictionary = game.call("default_audio_settings")
	_check(is_equal_approx(float(defaults.sfx_volume), 0.85)
			and is_equal_approx(float(defaults.ambience_volume), 0.60)
			and not bool(defaults.audio_muted),
			"default audio settings use 85% SFX, 60% ambience, unmuted")

	var ui := game.get_node("Interface")
	(ui.find_child("MenuSettings", true, false) as BaseButton).pressed.emit()
	await process_frame
	var panel := ui.find_child("GameplaySettings", true, false) as Control
	var sfx_spin := panel.find_child("sfx_volume", true, false) as SpinBox
	var amb_spin := panel.find_child("ambience_volume", true, false) as SpinBox
	var mute_btn := panel.find_child("AudioMuted", true, false) as CheckButton
	var save_btn := panel.find_child("SaveSettings", true, false) as BaseButton
	(panel.find_child("SettingsPageGraphics", true, false) as BaseButton).pressed.emit()
	await process_frame
	var sfx_bus := AudioServer.get_bus_index(&"SFX")
	var ui_bus := AudioServer.get_bus_index(&"UI")
	var amb_bus := AudioServer.get_bus_index(&"Ambience")

	_check(sfx_spin.is_visible_in_tree() and amb_spin.is_visible_in_tree() and mute_btn.is_visible_in_tree(),
			"settings panel exposes SFX volume, ambience volume, and mute toggle")

	audio.call("reset_telemetry")
	amb_spin.value = -1.0
	save_btn.pressed.emit()
	_check(panel.visible and game.call("invalid_setting") == "ambience_volume"
			and int(audio.call("count_played", &"ui_error")) >= 1,
			"negative gain keeps settings open, flags the volume field, and plays ui_error")

	sfx_spin.value = 150.0
	amb_spin.value = 225.0
	_check(absf(db_to_linear(AudioServer.get_bus_volume_db(sfx_bus)) - 1.5) < 0.001
			and absf(db_to_linear(AudioServer.get_bus_volume_db(ui_bus)) - 1.5) < 0.001
			and absf(db_to_linear(AudioServer.get_bus_volume_db(amb_bus)) - 2.25) < 0.001,
			"audio settings preview gain above 100% on all configured buses")
	mute_btn.button_pressed = true
	save_btn.pressed.emit()
	_check(not panel.visible, "audio settings above 100% save and close the panel")

	_check(AudioServer.is_bus_mute(0)
			and absf(db_to_linear(AudioServer.get_bus_volume_db(sfx_bus)) - 1.50) < 0.001
			and absf(db_to_linear(AudioServer.get_bus_volume_db(amb_bus)) - 2.25) < 0.001,
			"saved volume and mute values apply immediately to AudioServer buses")

	# Reload from disk
	var reloaded := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	reloaded.settings_path = settings_path
	root.add_child(reloaded)
	await process_frame
	var loaded_audio: Dictionary = reloaded.call("get_audio_settings")
	_check(is_equal_approx(float(loaded_audio.sfx_volume), 1.5)
			and is_equal_approx(float(loaded_audio.ambience_volume), 2.25)
			and bool(loaded_audio.audio_muted),
			"audio settings persist across restarts in gameplay.cfg")
	reloaded.queue_free()
	await process_frame

	# Legacy config without [audio] section falls back cleanly
	var legacy_path := "%s.legacy" % settings_path
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "human", {"giant_height": 30.0})
	cfg.save(legacy_path)
	var legacy_game := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	legacy_game.settings_path = legacy_path
	root.add_child(legacy_game)
	await process_frame
	var fallback: Dictionary = legacy_game.call("get_audio_settings")
	_check(is_equal_approx(float(fallback.sfx_volume), 0.85)
			and is_equal_approx(float(fallback.ambience_volume), 0.60)
			and not bool(fallback.audio_muted),
			"legacy config without audio section receives default audio settings")
	legacy_game.queue_free()
	DirAccess.remove_absolute(legacy_path)
	await process_frame

	# Unmute for remaining gameplay checks
	game.call("save_audio_settings", game.call("default_audio_settings"))


func _check_ui_and_human_sfx(game: Node, audio: Node) -> void:
	audio.call("reset_telemetry")
	var ui := game.get_node("Interface")
	(ui.find_child("HarborEntry", true, false) as BaseButton).pressed.emit()
	_check(int(audio.call("count_played", &"ui_click")) >= 1, "menu navigation plays ui_click")

	game.call("start_mode", false)
	await _ticks(4)
	var current := game.get_node("MapSlot/Round")
	var human: CharacterBody3D = current.get_node("Human")
	human.position = Vector3(0.0, 0.02, -34.0)
	audio.call("reset_telemetry")

	# Walk/sprint triggers human footsteps
	Input.action_press("move_forward")
	Input.action_press("sprint")
	await _ticks(50)
	Input.action_release("move_forward")
	Input.action_release("sprint")
	_check(int(audio.call("count_played", &"human_step")) >= 1,
			"sprinting human plays synced human_step footsteps")

	# Pause & resume play UI sounds
	game.call("pause")
	await process_frame
	_check(int(audio.call("count_played", &"ui_pause")) >= 1, "pausing plays ui_pause")
	game.call("resume")
	await process_frame
	_check(int(audio.call("count_played", &"ui_resume")) >= 1, "resuming plays ui_resume")

	# Reaching exit plays evac_victory
	var exit_pos: Vector3 = current.get_node("District/Evacuation").global_position
	human.global_position = Vector3(exit_pos.x, 0.05, exit_pos.z)
	await _ticks(4)
	await process_frame
	_check(game.get_screen() == "evacuated" and int(audio.call("count_played", &"evac_victory")) >= 1,
			"successful evacuation plays evac_victory")


func _check_giant_and_destruction_sfx(game: Node, audio: Node) -> void:
	var opts: Dictionary = game.call("default_mode_settings", 1)
	opts.merge({"giant_count": 1, "npc_initial": 0, "npc_respawn": false}, true)
	game.call("save_settings", game.call("get_settings", false), opts)
	game.call("start_mode", true)
	await _ticks(4)
	var current := game.get_node("MapSlot/Round")
	var giant: CharacterBody3D = current.get_node("Giant")
	audio.call("reset_telemetry")

	# Toggle view plays view_toggle
	current.call("toggle_view")
	_check(int(audio.call("count_played", &"view_toggle")) >= 1, "toggling camera view plays view_toggle")
	current.call("toggle_view")

	# Walk triggers giant_step and camera_shake
	Input.action_press("move_forward")
	await _ticks(75)
	Input.action_release("move_forward")
	await _ticks(35)
	_check(int(audio.call("count_played", &"giant_step")) >= 1, "giant walking triggers spatial giant_step")
	_check(int(audio.call("count_played", &"camera_shake")) >= 1,
			"giant walking with shake enabled triggers deep seismic camera_shake")

	# Stomp near a building triggers stomp_warn, giant_stomp, camera_shake, building_crack, and building_collapse
	var target: Node3D = current.get_node("District/Targets/DockPress1")
	giant.position = target.position + Vector3.BACK * (target.footprint.z * 0.5 + 7.05)
	giant.rotation = Vector3.ZERO
	await _ticks(4)
	audio.call("reset_telemetry")
	for strike in 2:
		current.call("tap_stomp")
		for _f in 120:
			await physics_frame
			if current.snapshot().stomp == "ready":
				break
		await _ticks(4)
	_check(int(audio.call("count_played", &"stomp_warn")) >= 1
			and int(audio.call("count_played", &"giant_stomp")) >= 2,
			"stomping plays stomp_warn telegraph and giant_stomp impacts")
	_check(int(audio.call("count_played", &"camera_shake")) >= 2,
			"stomping triggers seismic camera_shake synced to screen tremor")
	_check(int(audio.call("count_played", &"building_crack")) >= 1
			and int(audio.call("count_played", &"building_collapse")) >= 1,
			"damaging and demolishing a building plays building_crack and building_collapse")

	# Setting shake_strength = 0 disables camera_shake audio cleanly
	opts.merge({"shake_strength": 0.0}, true)
	game.call("save_settings", game.call("get_settings", false), opts)
	await _ticks(4)
	audio.call("reset_telemetry")
	current.call("tap_stomp")
	for _f in 120:
		await physics_frame
		if current.snapshot().stomp == "ready":
			break
	await _ticks(4)
	_check(int(audio.call("count_played", &"camera_shake")) == 0,
			"setting shake_strength to 0 silences camera_shake")

	# Disabling own_camera_shake prevents self-stomps from firing camera_shake
	opts.merge({"shake_strength": 1.0, "own_camera_shake": false}, true)
	game.call("save_settings", game.call("get_settings", false), opts)
	await _ticks(4)
	audio.call("reset_telemetry")
	current.call("tap_stomp")
	for _f in 120:
		await physics_frame
		if current.snapshot().stomp == "ready":
			break
	await _ticks(4)
	_check(int(audio.call("count_played", &"camera_shake")) == 0,
			"disabling own_camera_shake silences self-caused camera_shake")
	opts.merge({"own_camera_shake": true}, true)
	game.call("save_settings", game.call("get_settings", false), opts)


func _check_growth_sfx(game: Node, audio: Node) -> void:
	var growth: Dictionary = game.call("default_mode_settings", 2)
	growth.merge({
		"giant_count": 2, "giant_height": 2.8, "attack_height": 3.0,
		"coin_count": 40, "coin_growth_rate": 0.25, "random_start": false,
	}, true)
	game.call("save_mode_settings", game.call("get_settings", false), game.call("get_settings", true), growth)
	game.call("start_growth")
	await _ticks(6)
	var current := game.get_node("MapSlot/Round")
	var giant: CharacterBody3D = current.get_node("Giant")
	var coins := current.get_node("Coins")
	audio.call("reset_telemetry")

	if coins.get_child_count() > 0:
		var coin := coins.get_child(0) as Node3D
		giant.global_position = coin.global_position
		await _ticks(25)
	_check(int(audio.call("count_played", &"coin_pickup")) >= 1,
			"collecting a coin in Growth mode plays coin_pickup")
	_check(int(audio.call("count_played", &"transform_giant")) >= 1,
			"growing across attack_height plays transform_giant")


func _check_bedroom_sfx(audio: Node) -> void:
	audio.call("reset_telemetry")
	var ok := change_scene_to_file("res://scenes/GirlBedroom.tscn")
	if not _check(ok == OK, "GirlBedroom scene opens cleanly"):
		return
	await scene_changed
	await _ticks(12)
	_check(audio.call("get_current_ambience") == &"bedroom",
			"entering GirlBedroom crossfades to bedroom ambience")

	Input.action_press("move_back")
	await _ticks(55)
	Input.action_release("move_back")
	_check(int(audio.call("count_played", &"bedroom_step")) >= 1,
			"walking in GirlBedroom plays bedroom_step footsteps")

	Input.action_press("move_forward")
	await _ticks(65)
	Input.action_press("climb")
	await _ticks(55)
	Input.action_release("climb")
	Input.action_release("move_forward")
	_check(int(audio.call("count_played", &"bedroom_climb")) >= 1,
			"climbing furniture in GirlBedroom plays bedroom_climb")

	current_scene.call("_return_to_menu")
	await process_frame
	await process_frame
	_check(int(audio.call("count_played", &"ui_back")) >= 1
			and audio.call("get_current_ambience") == &"harbor",
			"leaving GirlBedroom plays ui_back and restores harbor ambience")


func _ticks(count: int) -> void:
	for _i in count:
		await physics_frame


func _check(condition: bool, description: String) -> bool:
	_checks += 1
	if condition:
		print("PASS  ", description)
		return true
	_failures += 1
	push_error(description)
	return false
