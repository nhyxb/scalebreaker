extends SceneTree
## Runs the installed game scene through its normal input and session entry points.

const MAP := "MapSlot/Round"
const PLAYERS := ["Human", "Giant"]
const FootfallFixture = preload("res://tests/footfall_fixture.gd")
const DistrictBatches = preload("res://scenes/district_batches.gd")
const GROWTH_PER_BUILDING := 1.10
const CORE_SPAWN := Vector3(0.0, 0.02, -34.0)
const BUILDING_LAYER := 8
const CORE_BUILDINGS := [
	&"DockPress1", &"Tidewater1", &"MarineWorks1",
	&"DockPress2", &"Tidewater2", &"MarineWorks2",
	&"DockPress3", &"Tidewater3", &"MarineWorks3",
	&"DockPress4", &"Tidewater4", &"MarineWorks4",
]

var _game: Node
var _failures := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	seed(20261122)
	_game = load("res://scenes/main.tscn").instantiate()
	var settings_path := "user://playtest-options-%d-%d.cfg" % [OS.get_process_id(), Time.get_ticks_usec()]
	_game.settings_path = settings_path
	root.add_child(_game)
	await process_frame
	_check(_game.get_screen() == "menu", "main menu opens")
	await _bedroom_skybox()
	await _day_night_and_settings()
	await _human_controls()
	await _human_evacuates()
	await _human_vs_ai()
	await _speed_and_ignore_settings()
	await _ai_leads_a_sprinting_human()
	await _visibility_and_civilians()
	await _civilian_three_states()
	await _ai_demolition()
	await _walking_attack()
	await _finish_walking_step()
	await _giant_smooth_turn()
	await _giant_layered_turn()
	await _blocked_walk_pivot()
	await _giant_sandbox()
	await _queued_growth_and_footfalls()
	await _expanded_harbor()
	await _human_walks_rubble()
	await _camera_shake()
	await _settings_modes()
	await _open_numeric_settings()
	await _multiple_giants()
	await _ai_smooth_turning()
	await _map_size_settings()
	await _smallest_map()
	await _own_camera_shake_toggle()
	await _desk_hazards_finger_poke()
	await _tall_own_camera_shake()
	await _palm_sandbox_layout()
	_check(_game.get_screen() == "menu", "both modes returned to the title")
	if FileAccess.file_exists(settings_path):
		DirAccess.remove_absolute(settings_path)
	print("Gameplay: %d passed, %d failed" % [_checks - _failures, _failures])
	quit(1 if _failures else 0)


func _bedroom_skybox() -> void:
	var sky: Node = _game.get_node_or_null("Skybox")
	var bedroom: Node3D = sky.get_node_or_null("Bedroom") if sky != null else null
	var sub: Node = sky.get_node_or_null("BedroomViewport") if sky != null else null
	var backdrop: Node = sky.get_node_or_null("BedroomBackdrop") if sky != null else null
	var sun: DirectionalLight3D = _game.get_node_or_null("Sun") as DirectionalLight3D
	var overview: Camera3D = _game.get_node_or_null("Overview") as Camera3D
	var atmo: WorldEnvironment = _game.get_node_or_null("Atmosphere") as WorldEnvironment
	_check(sky != null and bedroom != null and sub == null and backdrop == null,
			"single-world bedroom mounts directly under Skybox with SubViewport and 2D backdrop removed")
	if bedroom == null:
		return
	var anchor_world_err: float = (bedroom.sandbox_anchor as Node3D).global_position.length() if bedroom.sandbox_anchor != null else 999.0
	_check(bedroom.scale.is_equal_approx(Vector3.ONE * 6666.67)
			and anchor_world_err < 0.05
			and overview != null and overview.far >= 45000.0 and (overview.cull_mask & 3) == 3,
			"single-world bedroom scales 6666.67x with sandbox_anchor at (0,0,0) and Overview far >= 45000")
	# Layer 1 (city) / Layer 2 (bedroom + Yumeka) lighting & visibility isolation.
	var win_sun: DirectionalLight3D = bedroom.call("get_window_sun") if bedroom.has_method(&"get_window_sun") else null
	var bounce: DirectionalLight3D = bedroom.call("get_interior_bounce") if bedroom.has_method(&"get_interior_bounce") else null
	var ceil_l: OmniLight3D = bedroom.call("get_ceiling_fill") if bedroom.has_method(&"get_ceiling_fill") else null
	var desk_l: OmniLight3D = bedroom.call("get_desk_lamp_light") if bedroom.has_method(&"get_desk_lamp_light") else null
	var all_bedroom_layer2 := _count_non_layer_in(bedroom, 2) == 0
	var lights_isolated := sun != null and sun.light_cull_mask == 1 \
			and win_sun != null and win_sun.light_cull_mask == 2 \
			and win_sun.directional_shadow_max_distance >= 35000.0 \
			and bounce != null and bounce.light_cull_mask == 2 \
			and ceil_l != null and ceil_l.light_cull_mask == 2 \
			and desk_l != null and desk_l.light_cull_mask == 2 \
			and desk_l.omni_range >= 25000.0
	_check(all_bedroom_layer2 and lights_isolated,
			"city Sun isolates to Layer 1 while Bedroom/Yumeka meshes and calibrated lights isolate to Layer 2")
	var furniture := bedroom.get_node_or_null("Furniture")
	var required := [
		"Desk", "ChairDesk", "ComputerScreen", "ComputerKeyboard", "ComputerMouse",
		"LampRoundTable", "BooksDesk", "PlantSmallDesk", "SpeakerLeft", "SpeakerRight",
		"BedDouble", "Pillow", "PillowLong", "CabinetBedDrawer", "BookcaseOpen",
		"BookcaseClosedDoors", "RugRounded", "PottedPlant", "LampSquareCeiling",
		"Trashcan", "CoatRackStanding",
	]
	var all_present := furniture != null and furniture.get_node_or_null("BearDesk") == null
	if all_present:
		for item: String in required:
			if furniture.get_node_or_null(item) == null:
				all_present = false
				break
	var district := _game.get_node_or_null("MapSlot/District")
	var diorama_ok := district != null and district.get_node_or_null("Water") == null \
			and district.get_node_or_null("SandboxFrame") != null
	_check(all_present and diorama_ok and _count_collisions_in(bedroom) == 0,
			"all Kenney furniture landmarks load without BearDesk/Water, with SandboxFrame and zero collisions")
	# Soft interior decor + unified main-world BG_SKY dynamic sky + real desktop monitor display.
	var decor := bedroom.get_node_or_null("Decor")
	var monitor_disp := furniture.get_node_or_null("ComputerScreen/MonitorDisplay") as MeshInstance3D if furniture != null else null
	var monitor_mat := monitor_disp.material_override as StandardMaterial3D if monitor_disp != null else null
	var main_env: Environment = atmo.environment if atmo != null else null
	var decor_ok := decor != null \
			and decor.get_node_or_null("Curtains/CurtainLeft") != null \
			and decor.get_node_or_null("Curtains/CurtainRight") != null \
			and decor.get_node_or_null("Curtains/CurtainRod") != null \
			and decor.get_node_or_null("CorkBoard") != null \
			and decor.get_node_or_null("WallShelfSouth") != null \
			and decor.get_node_or_null("ArtSouthHarbor") != null \
			and decor.get_node_or_null("ArtWestMisty") != null \
			and decor.get_node_or_null("ArtEastLandscape") != null \
			and decor.get_node_or_null("DeskMat") != null \
			and decor.get_node_or_null("DeskMug") != null
	_check(decor_ok and monitor_mat != null and monitor_mat.albedo_texture != null and monitor_mat.emission_enabled
			and bedroom.get_node_or_null("BedroomEnvironment") == null
			and main_env != null and main_env.background_mode == Environment.BG_SKY
			and main_env.sky != null and main_env.sky.sky_material is ShaderMaterial,
			"unified BG_SKY dynamic sky and bedroom decor (curtains, art, corkboard, shelf, desk accents, monitor) load cleanly")
	var sandbox_anchor: Node3D = bedroom.sandbox_anchor
	var ug_anchor: Node3D = bedroom.ultra_giant_anchor
	var to_sandbox := Vector3.ZERO
	var ug_fwd := Vector3.ZERO
	if sandbox_anchor != null and ug_anchor != null:
		var flat_target := Vector3(sandbox_anchor.global_position.x,
				ug_anchor.global_position.y, sandbox_anchor.global_position.z)
		to_sandbox = (flat_target - ug_anchor.global_position).normalized()
		ug_fwd = (-ug_anchor.global_transform.basis.z).normalized()
	_check(sandbox_anchor != null and ug_anchor != null and sky.ultra_giant_anchor == ug_anchor
			and is_equal_approx(sandbox_anchor.position.x, 0.0)
			and is_equal_approx(sandbox_anchor.position.z, 0.0)
			and bedroom.ultra_giant_seat_y > 0.40 and bedroom.ultra_giant_seat_y < 0.52
			and is_equal_approx(ug_anchor.position.y, bedroom.ultra_giant_seat_y)
			and ug_fwd.dot(to_sandbox) > 0.99,
			"ultra_giant_anchor sits above the swivel chair seat cushion facing sandbox_anchor")
	# Phase 3A: the seated Yumeka mounts on the chair when her licensed GLB is
	# present locally, and the mount quietly disappears on fresh public clones.
	var yumeka: Node = ug_anchor.get_node_or_null("Yumeka") if ug_anchor != null else null
	if ResourceLoader.exists("res://assets/characters/yumeka/Yumeka_seated.glb", "PackedScene"):
		_check(yumeka != null and yumeka.debug_is_mounted()
				and yumeka.has_node("Model")
				and _count_collisions_in(yumeka) == 0,
				"seated Yumeka mounts under the anchor with zero colliders")
		if yumeka != null and yumeka.debug_is_mounted():
			# Hard seated-pose assertions: the exporter sends the forward-leaning
			# elbow-prop pose as a 1-frame SeatedPose animation; guard against any
			# regression to T-pose, high upright eyes, sandbox-clipping hands, or
			# desk-clipping thighs.
			var hm_l: Vector3 = yumeka.debug_bone_pos("Hand_L")
			var hm_r: Vector3 = yumeka.debug_bone_pos("Hand_R")
			var eye_l_pos: Vector3 = yumeka.debug_bone_pos("Eye_L")
			var knee_l: Vector3 = yumeka.debug_bone_pos("LowerLeg_L")
			var knee_r: Vector3 = yumeka.debug_bone_pos("LowerLeg_R")
			var ft_l: Vector3 = yumeka.debug_bone_pos("Foot_L")
			var ft_r: Vector3 = yumeka.debug_bone_pos("Foot_R")
			_check(hm_l.y < eye_l_pos.y - 0.15 and hm_r.y < eye_l_pos.y - 0.15
					and hm_l.y > 0.74 and hm_l.y < 0.88 and hm_r.y > 0.74 and hm_r.y < 0.88
					and absf(hm_l.x) > 0.12 and absf(hm_r.x) > 0.12
					and knee_l.y < 0.68 and knee_r.y < 0.68
					and ft_l.y < 0.25 and ft_r.y < 0.25
					and ft_l.z < 0.35 and ft_r.z < 0.35
					and eye_l_pos.y >= 0.95 and eye_l_pos.y <= 1.08,
					"SeatedPose lands in Godot: leaning eye height 0.95-1.08 m, hands on desk outside sandbox, knees under desk, feet tucked forward-low")
			_check(yumeka.get_morph("eye_nagomi_1") > 0.2
					and yumeka.get_morph("mouth_smile_1") > 0.1
					and yumeka.get_morph("eye_close") < 0.01,
					"Yumeka idles with soft eyes and a faint closed-lids rest")
			# Blink: force one and observe the close crossing inside its window.
			yumeka.debug_force_blink()
			var saw_blink := false
			for frame in 40:
				await physics_frame
				if yumeka.debug_eye_close() > 0.5:
					saw_blink = true
					break
			for frame in 90:
				await physics_frame
				if yumeka.debug_eye_close() < 0.01:
					break
			_check(saw_blink and yumeka.debug_eye_close() < 0.01,
					"forced blink closes and reopens the eyelids morph")
			# Gaze: both head/neck and Eye_L/Eye_R bones smoothly track main-world override
			# targets left/right and stay clamped within anatomical limits.
			yumeka.debug_set_gaze_override(Vector3(-4000.0, 600.0, 0.0))
			var yaw_left := 0.0
			var eye_left := 0.0
			for frame in 120:
				await physics_frame
				yaw_left = yumeka.debug_head_swing().x
				eye_left = yumeka.debug_eye_swing().x
				if absf(yaw_left) > 5.0 and absf(eye_left) > 4.0:
					break
			yumeka.debug_set_gaze_override(Vector3(4000.0, 600.0, 0.0))
			var yaw_right := 0.0
			var eye_right := 0.0
			for frame in 120:
				await physics_frame
				yaw_right = yumeka.debug_head_swing().x
				eye_right = yumeka.debug_eye_swing().x
				if yaw_right * yaw_left < 0.0 and absf(yaw_right) > 5.0 \
						and eye_right * eye_left < 0.0 and absf(eye_right) > 4.0:
					break
			var swing: Vector2 = yumeka.debug_head_swing()
			var eye_swing: Vector2 = yumeka.debug_eye_swing()
			yumeka.debug_set_gaze_override(Vector3.ZERO)
			_check(yaw_left * yaw_right < 0.0
					and absf(swing.x) <= 15.5 and absf(swing.y) <= 10.5,
					"gaze overrides swing the head both ways within yaw/pitch limits")
			_check(yumeka.debug_eye_bones_ready()
					and eye_left * eye_right < 0.0
					and absf(eye_left) > 3.0 and absf(eye_right) > 3.0
					and absf(eye_swing.x) <= 14.5 and absf(eye_swing.y) <= 10.5,
					"Eye_L and Eye_R bones track left/right gaze targets smoothly within anatomical clamp")
			var anim_t0: float = yumeka.debug_anim_time()
			for frame in 90:
				await physics_frame
			_check(yumeka.debug_sky_wired()
					and yumeka.debug_anim_time() - anim_t0 > 0.12,
					"Yumeka breathing/blink ticks run continuously in the single 3D world")
	else:
		_check(yumeka == null,
				"missing licensed Yumeka asset skips the mount silently")


func _count_non_layer_in(node: Node, expected_layer: int) -> int:
	var bad := 1 if (node is VisualInstance3D and (node as VisualInstance3D).layers != expected_layer) else 0
	for child in node.get_children():
		bad += _count_non_layer_in(child, expected_layer)
	return bad


func _count_collisions_in(node: Node) -> int:
	var total := 1 if node is CollisionObject3D else 0
	for child in node.get_children():
		total += _count_collisions_in(child)
	return total


func _count_city_dynamic_lights(node: Node) -> int:
	var total := 1 if (node is OmniLight3D or node is SpotLight3D) else 0
	for child in node.get_children():
		total += _count_city_dynamic_lights(child)
	return total


func _day_night_and_settings() -> void:
	const CityNightLights := preload("res://scenes/city_night_lights.gd")
	var dn: Node = _game.get_node_or_null("DayNight")
	var sun: DirectionalLight3D = _game.get_node_or_null("Sun") as DirectionalLight3D
	var atmo: WorldEnvironment = _game.get_node_or_null("Atmosphere") as WorldEnvironment
	var bedroom: Node3D = _game.get_node_or_null("Skybox/Bedroom") as Node3D
	var desk_lamp: OmniLight3D = bedroom.call("get_desk_lamp_light") if bedroom != null else null
	_check(dn != null and sun != null and atmo != null and atmo.environment != null
			and atmo.environment.tonemap_mode == Environment.TONE_MAPPER_AGX
			and atmo.environment.background_mode == Environment.BG_SKY
			and desk_lamp != null,
			"DayNight controller, unified AGX BG_SKY environment, and bedroom DeskLampLight initialize")
	if dn == null or sun == null or desk_lamp == null:
		return

	# Default time_of_day setting is "day" in all 4 modes; invalid values are rejected.
	var all_default_day := true
	for mode in 4:
		if String(_game.default_mode_settings(mode).get("time_of_day", "")) != "day":
			all_default_day = false
	var bad_opts: Dictionary = _game.default_mode_settings(0)
	bad_opts["time_of_day"] = "midnight"
	var rejected: bool = not _game.save_all_mode_settings(
			bad_opts, _game.default_mode_settings(1),
			_game.default_mode_settings(2), _game.default_mode_settings(3))
	_check(all_default_day and rejected and String(_game.invalid_setting()) == "time_of_day",
			"time_of_day defaults to day across modes and rejects unknown values")

	# Graphics settings UI exposes time_of_day with 4 choices and persists across reloads.
	var ui := _game.get_node("Interface")
	(ui.find_child("MenuSettings", true, false) as BaseButton).pressed.emit()
	await process_frame
	var panel: Control = ui.find_child("GameplaySettings", true, false)
	(panel.find_child("SettingsPageGraphics", true, false) as BaseButton).pressed.emit()
	await process_frame
	var selector := panel.find_child("time_of_day", true, false) as OptionButton
	_check(selector != null and selector.item_count == 4 and selector.is_visible_in_tree(),
			"Graphics settings expose the 4-choice time_of_day OptionButton")
	if selector != null:
		# Pick "night" (index 3), save, and verify config + fresh HarborGame reload.
		selector.select(3)
		selector.item_selected.emit(3)
		await process_frame
		(panel.find_child("SaveSettings", true, false) as BaseButton).pressed.emit()
		await process_frame
		var cfg := ConfigFile.new()
		var loaded_ok := cfg.load(_game.settings_path) == OK
		var human_saved: Dictionary = cfg.get_value("settings", "human", {})
		var brawl_saved: Dictionary = cfg.get_value("settings", "brawl", {})
		var reloaded: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
		reloaded.settings_path = _game.settings_path
		root.add_child(reloaded)
		await process_frame
		var reloaded_val := String(reloaded.get_mode_settings(1).get("time_of_day", ""))
		reloaded.queue_free()
		await process_frame
		_check(loaded_ok and String(human_saved.get("time_of_day", "")) == "night"
				and String(brawl_saved.get("time_of_day", "")) == "night"
				and reloaded_val == "night"
				and String(dn.call("get_mode")) == "night",
				"time_of_day persists to gameplay.cfg across all modes and restores on reload")

	# Verify day / dusk / night transitions, unified BG_SKY clouds/stars, F7 shortcut,
	# giant looming shadow linkage, Layer 2 FP16-safe desk lamp energy, and zero city dynamic lights.
	var sky: Node = _game.get_node_or_null("Skybox")
	var sky_mat: ShaderMaterial = dn.call("get_sky_shader_material") if dn.has_method(&"get_sky_shader_material") else null
	var yumeka_present: bool = sky != null and sky.has_method(&"is_yumeka_mounted") and bool(sky.call(&"is_yumeka_mounted"))
	dn.call("set_mode", "day")
	await process_frame
	var sh_day: float = float(dn.call("get_giant_shadow_strength"))
	var clouds_day: float = float(sky_mat.get_shader_parameter(&"cloud_opacity")) if sky_mat != null else -1.0
	var stars_day: float = float(sky_mat.get_shader_parameter(&"star_strength")) if sky_mat != null else -1.0
	var day_ok: bool = is_zero_approx(float(dn.call("get_night_glow"))) \
			and not desk_lamp.visible and sun.light_energy > 0.85
	dn.call("set_mode", "dusk")
	await process_frame
	var sh_dusk: float = float(dn.call("get_giant_shadow_strength"))
	var dusk_glow: float = float(dn.call("get_night_glow"))
	var dusk_ok: bool = dusk_glow > 0.25 and dusk_glow < 0.65 \
			and desk_lamp.visible and sun.light_color.r > sun.light_color.b + 0.35
	dn.call("set_mode", "night")
	await process_frame
	var sh_night: float = float(dn.call("get_giant_shadow_strength"))
	var stars_night: float = float(sky_mat.get_shader_parameter(&"star_strength")) if sky_mat != null else -1.0
	var night_ok: bool = float(dn.call("get_night_glow")) > 0.95 \
			and desk_lamp.visible and desk_lamp.light_energy > 100.0 and desk_lamp.light_energy * PI < 20000.0 \
			and desk_lamp.light_cull_mask == 2 \
			and sun.light_color.b > sun.light_color.r + 0.25
	_check(day_ok and dusk_ok and night_ok,
			"day, dusk, and night presets synchronize Sun, city night glow, and FP16-safe Layer 2 DeskLampLight")
	var shadow_ok := (sh_day > 0.50 and sh_dusk > 0.50 and sh_night > 0.05 and sh_night < sh_day * 0.6) \
			if yumeka_present else is_zero_approx(sh_day)
	_check(sky_mat != null and clouds_day > 0.4 and stars_day < 0.05 and stars_night > 0.9
			and shadow_ok,
			"unified dynamic sky shader (clouds/stars) and city-wide giant looming shadow scale cleanly with day/dusk/night")

	# F7 debug shortcut cycles day -> dusk -> night -> day cleanly.
	dn.call("set_mode", "day")
	_key(KEY_F7)
	await process_frame
	var after_f7_1 := String(dn.call("get_mode"))
	_key(KEY_F7)
	await process_frame
	var after_f7_2 := String(dn.call("get_mode"))
	_key(KEY_F7)
	await process_frame
	var after_f7_3 := String(dn.call("get_mode"))
	_check(after_f7_1 == "dusk" and after_f7_2 == "night" and after_f7_3 == "day",
			"F7 cycles day -> dusk -> night -> day in-place without errors")

	# Verify auto cycle advances smoothly when unpaused, window emission mask stays strictly
	# confined to the single glass swatch (~1/32 = 3.125%), and city has zero dynamic lights.
	dn.call("set_mode", "auto")
	var p0: float = float(dn.call("get_phase"))
	await _ticks(12)
	var p1: float = float(dn.call("get_phase"))
	var district := _game.get_node_or_null("MapSlot/District")
	var comm_cov: float = CityNightLights.debug_mask_coverage("commercial")
	var lamp_cov: float = CityNightLights.debug_mask_coverage("roads_lamp")
	_check(p1 != p0 and district != null and _count_city_dynamic_lights(district) == 0
			and comm_cov > 0.01 and comm_cov < 0.05
			and lamp_cov > 0.01 and lamp_cov < 0.05,
			"auto day-night advances, window/lamp masks cover only target swatches, and zero city dynamic lights exist")

	# Restore default daytime setting cleanly before gameplay tests.
	_game.save_all_mode_settings(
			_game.default_mode_settings(0), _game.default_mode_settings(1),
			_game.default_mode_settings(2), _game.default_mode_settings(3))
	await process_frame


func _human_controls() -> void:
	_game.start_mode(false)
	var current := _round()
	var human := _actor(0)
	var orbit: Node3D = current.get_node("Orbit")
	var original_spawn := human.position
	human.position = CORE_SPAWN
	await _ticks(4)
	_check(root.get_camera_3d() == current.get_node("Orbit/Arm/Camera"), "human camera activates")
	var begin := human.position
	Input.action_press("move_forward")
	Input.action_press("sprint")
	await _ticks(47)
	var low: float = current.snapshot().stamina
	_check(human.position.x - begin.x > 7.0, "camera-relative input makes the human sprint east")
	_check(low < 0.85 and low > 0.7, "moving while holding Shift consumes stamina")
	_key(KEY_ESCAPE)
	await process_frame
	_check(_game.get_screen() == "paused" and paused, "Escape pauses the game tree")
	var stopped := human.position
	var paused_view := orbit.rotation
	_set_key_state(KEY_RIGHT, true)
	await _ticks(45)
	_set_key_state(KEY_RIGHT, false)
	_check(is_equal_approx(current.snapshot().stamina, low) and human.position == stopped,
			"pause freezes movement and stamina")
	_check(orbit.rotation.is_equal_approx(paused_view), "Arrow keys leave the view frozen while paused")
	_key(KEY_ESCAPE)
	await _ticks(3)
	_check(_game.get_screen() == "playing" and not paused, "Escape resumes play")
	Input.action_release("move_forward")
	Input.action_release("sprint")
	await _ticks(51)
	_check(current.snapshot().stamina > low + 0.15, "releasing Shift replenishes stamina")
	var yaw := orbit.rotation.y
	_mouse(Vector2(150, -80))
	await _ticks(2)
	_check(absf(angle_difference(yaw, orbit.rotation.y)) > 0.35 and orbit.rotation.x > -0.1,
			"mouse movement orbits horizontally and vertically")
	var before_arrows := orbit.rotation
	_set_key_state(KEY_RIGHT, true)
	_set_key_state(KEY_UP, true)
	await _ticks(12)
	_set_key_state(KEY_RIGHT, false)
	_set_key_state(KEY_UP, false)
	var turned := orbit.rotation
	_check(angle_difference(before_arrows.y, turned.y) < -0.15 and turned.x > before_arrows.x + 0.15,
			"Holding Right and Up turns and raises the camera together")
	await _ticks(8)
	_check(orbit.rotation.is_equal_approx(turned), "Releasing the arrows stops the camera")
	_set_key_state(KEY_LEFT, true)
	_set_key_state(KEY_DOWN, true)
	await _ticks(12)
	_set_key_state(KEY_LEFT, false)
	_set_key_state(KEY_DOWN, false)
	_check(angle_difference(turned.y, orbit.rotation.y) > 0.15 and orbit.rotation.x < turned.x - 0.15,
			"Holding Left and Down turns and lowers the camera together")
	var camera := current.get_node("Orbit/Arm/Camera") as Camera3D
	current.look(Vector2(0.0, -600.0))
	await _ticks(3)
	_check((-camera.global_basis.z).y > 0.95 and camera.global_position.y >= human.global_position.y + 0.15,
			"A human can look almost vertically up while the camera stays above the street")
	_game.pause()
	_game.restart()
	await _ticks(4)
	_check(_round() != current and _initial_state(_round()), "restart creates a fresh human session")
	var first_restart_spawn := _actor(0).position
	_game.restart()
	await _ticks(4)
	var latest_spawn := _actor(0).position
	_check(_initial_state(_round()) and latest_spawn.distance_to(first_restart_spawn) > 5.0
			and latest_spawn.distance_to(original_spawn) > 5.0 and _actor(0).is_on_floor(),
			"consecutive restarts choose different walkable human spawns and reset stats")
	_game.show_menu()
	_check(_game.get_screen() == "menu" and not paused, "human mode returns to main menu")


func _human_evacuates() -> void:
	_game.start_mode(false)
	var human := _actor(0)
	human.position = CORE_SPAWN
	# Follow the northern road, take the east verge, then approach the
	# south-east evacuation beacon.
	await _walk_axis(human, "move_forward", Vector3.RIGHT, 42.3, 550)
	await _walk_axis(human, "move_right", Vector3.BACK, 34.0, 875)
	await _walk_axis(human, "move_back", Vector3.LEFT, -35.0, 120)
	await _ticks(3)
	_check(_game.get_screen() == "evacuated", "human reaches the beacon through the playable streets")
	_game.restart()
	await _ticks(4)
	_check(_game.get_screen() == "playing" and _initial_state(_round()), "evacuation screen can restart")
	_game.show_menu()


func _human_vs_ai() -> void:
	_game.start_mode(false)
	var current := _round()
	var giant := _actor(1)
	var human := _actor(0)
	giant.position = Vector3(0.0, 0.02, 23.0)
	human.position = Vector3(0.0, 0.02, 5.0)
	_park_civilians(current)
	_check(_roadblock_count(current) == 0, "the harbor map generates no roadblocks")

	# The AI must approach with its normal gait. Sprint away from a committed landing,
	# then hold the human at subsequent previews so each touchdown can be counted.
	var preview: Dictionary = {}
	var approached := false
	for frame in 420:
		approached = approached or giant.position.z < 14.0
		var gait := FootfallFixture.actor(current)
		if gait.get("footfall_pending", false) and approached:
			preview = gait
			break
		_park_civilians(current)
		await physics_frame
	_check(approached and current.snapshot().ai_target_id == human.get_instance_id(),
			"AI keeps chasing a nearby human down the central street")
	_check(not preview.is_empty(), "The pursuit produces a committed footfall")
	if not preview.is_empty():
		FootfallFixture.place_under(human, preview)
		Input.action_press("sprint")
		Input.action_press("move_forward")
		await _ticks(32)
		Input.action_release("move_forward")
		Input.action_release("sprint")
	_check(current.snapshot().health == 3, "Sprinting clear of the predicted sole avoids the contact")
	var one_hit := false
	for frame in 900:
		var gait := FootfallFixture.actor(current)
		if gait.get("footfall_pending", false):
			FootfallFixture.place_under(human, gait)
		_park_civilians(current)
		await physics_frame
		one_hit = one_hit or current.snapshot().health == 2
		if _game.get_screen() == "lost":
			break
	_check(one_hit, "One AI sole impact removes one life")
	_check(_game.get_screen() == "lost" and current.snapshot().health == 0, "Three AI hits trigger defeat")
	_game.restart()
	await _ticks(4)
	_check(_initial_state(_round()), "human restart restores health and a clear street")
	_game.show_menu()


func _speed_and_ignore_settings() -> void:
	var defaults: Dictionary = _game.default_settings()
	_check(is_equal_approx(defaults.human_speed, 1.0)
			and is_equal_approx(defaults.rival_ignore_ratio, 10.0)
			and is_equal_approx(defaults.human_ignore_ratio, 30.0),
			"Human speed and the two ignore ratios have independent defaults")
	var human_options: Dictionary = _game.default_mode_settings(0)
	human_options.giant_count = 1
	human_options.npc_initial = 0
	human_options.npc_respawn = false
	human_options.human_speed = 1.0
	human_options.rival_ignore_ratio = 10.0
	human_options.human_ignore_ratio = 2.0
	var sandbox: Dictionary = _game.default_mode_settings(1)
	sandbox.giant_count = 1
	sandbox.npc_initial = 0
	sandbox.npc_respawn = false
	var growth: Dictionary = _game.default_mode_settings(2)
	growth.coin_count = 0
	var brawl: Dictionary = _game.default_mode_settings(3)
	_check(_game.save_all_mode_settings(human_options, sandbox, growth, brawl),
			"Human speed and both ignore ratios save")
	var saved: Dictionary = _game.get_mode_settings(0)
	_check(is_equal_approx(saved.human_speed, 1.0)
			and is_equal_approx(saved.rival_ignore_ratio, 10.0)
			and is_equal_approx(saved.human_ignore_ratio, 2.0),
			"Both ignore ratios round-trip independently from human speed")
	sandbox.human_speed = 0.5
	sandbox.rival_ignore_ratio = 20.0
	sandbox.human_ignore_ratio = 12.0
	_check(_game.save_all_mode_settings(human_options, sandbox, growth, brawl),
			"Sandbox speed and ratio overrides save")
	var sandbox_saved: Dictionary = _game.get_mode_settings(1)
	_check(is_equal_approx(sandbox_saved.human_speed, 0.5)
			and is_equal_approx(sandbox_saved.rival_ignore_ratio, 20.0)
			and is_equal_approx(sandbox_saved.human_ignore_ratio, 12.0),
			"Each mode keeps its own human speed and ignore ratios")

	# A 25.2 m giant sees a 1.8 m human as about 14x. Ratio 2 ignores; ratio 30 chases.
	_game.start_mode(false)
	var current := _round()
	var giant := _actor(1)
	var human := _actor(0)
	giant.position = Vector3(0.0, 0.02, 23.0)
	human.position = Vector3(0.0, 0.02, 5.0)
	_park_civilians(current)
	await _ticks(90)
	_check(current.snapshot().ai_target_id == 0 and current.snapshot().health == 3,
			"A giant ignores a human below the configured height ratio")
	human_options.human_ignore_ratio = 30.0
	_check(_game.save_all_mode_settings(human_options, sandbox, growth, brawl),
			"Raising the human ignore ratio saves")
	_game.start_mode(false)
	current = _round()
	giant = _actor(1)
	human = _actor(0)
	giant.position = Vector3(0.0, 0.02, 23.0)
	human.position = Vector3(0.0, 0.02, 5.0)
	_park_civilians(current)
	var targeted := false
	for frame in 240:
		if current.snapshot().ai_target_id == human.get_instance_id():
			targeted = true
			break
		_park_civilians(current)
		await physics_frame
	_check(targeted, "Raising the ratio makes the giant chase the human again")

	# The same walk over the same number of frames should cover twice the ground at 2x.
	human_options.human_speed = 1.0
	_game.save_all_mode_settings(human_options, sandbox, growth, brawl)
	_game.start_mode(false)
	human = _actor(0)
	human.position = CORE_SPAWN
	await _ticks(4)
	Input.action_press("move_forward")
	await _ticks(40)
	Input.action_release("move_forward")
	var normal_walk := (human.position - CORE_SPAWN).slide(Vector3.UP).length()
	human_options.human_speed = 2.0
	_game.save_all_mode_settings(human_options, sandbox, growth, brawl)
	_game.start_mode(false)
	human = _actor(0)
	human.position = CORE_SPAWN
	await _ticks(4)
	Input.action_press("move_forward")
	await _ticks(40)
	Input.action_release("move_forward")
	var fast_walk := (human.position - CORE_SPAWN).slide(Vector3.UP).length()
	_check(fast_walk > normal_walk * 1.6 and fast_walk < normal_walk * 2.4,
			"Human speed multiplies the walking rate")

	# Older saves lack the two new keys; they keep the old 1.0x and 30x defaults.
	var legacy: Dictionary = _game.get_mode_settings(0)
	legacy.erase("human_speed")
	legacy.erase("human_ignore_ratio")
	_game.save_all_mode_settings(legacy, sandbox, growth, brawl)
	var migrated: Dictionary = _game.get_mode_settings(0)
	_check(is_equal_approx(migrated.human_speed, 1.0)
			and is_equal_approx(migrated.human_ignore_ratio, 30.0),
			"Older saves default the new human speed and ignore ratio")
	_game.save_all_mode_settings(
			_game.default_mode_settings(0), _game.default_mode_settings(1),
			_game.default_mode_settings(2), _game.default_mode_settings(3))
	_game.show_menu()


func _park_civilians(current: Node, except: CharacterBody3D = null) -> void:
	for civilian: CharacterBody3D in current.get_node("Civilians").get_children():
		if civilian != except:
			civilian.position = Vector3(612.0, 0.03, 612.0)


func _roadblock_count(current: Node) -> int:
	var count := 0
	for target: Node3D in current.get_node("District/Targets").get_children():
		if target.get("kind") == "barrier":
			count += 1
	return count


func _ai_leads_a_sprinting_human() -> void:
	_game.start_mode(false)
	var current := _round()
	var human := _actor(0)
	var giant := _actor(1)
	giant.position = Vector3(0.0, 0.02, 64.0)
	human.position = Vector3(-3.0, 0.02, 45.0)
	Input.action_press("move_forward")
	Input.action_press("sprint")
	var landing := Vector3.INF
	var first_velocity := Vector3.ZERO
	var stable := true
	var before := int(FootfallFixture.actor(current).footfall_count)
	var pursued := false
	for frame in 175:
		var gait := FootfallFixture.actor(current)
		var preview: Dictionary = giant.heavy_step_preview()
		if gait.get("footfall_pending", false) and preview.get("locked", false):
			var projected: Vector3 = gait.footfall_center
			if landing == Vector3.INF:
				landing = projected
				first_velocity = human.get_real_velocity()
			else:
				stable = stable and projected.slide(Vector3.UP).distance_to(landing.slide(Vector3.UP)) < 0.04
		if int(gait.footfall_count) > before and landing != Vector3.INF:
			var actual: Vector3 = gait.last_footfall_center
			stable = stable and actual.slide(Vector3.UP).distance_to(landing.slide(Vector3.UP)) < 0.04
			break
		pursued = pursued or current.snapshot().ai_target_id == human.get_instance_id()
		_park_civilians(current)
		await physics_frame
	Input.action_release("move_forward")
	Input.action_release("sprint")
	_check(pursued and first_velocity.slide(Vector3.UP).length() > 3.0 and stable
			and int(FootfallFixture.actor(current).footfall_count) > 0,
			"AI pursues a sprinting human and keeps the projected sole fixed through touchdown")
	_game.show_menu()


func _visibility_and_civilians() -> void:
	_game.start_mode(false)
	var current := _round()
	var giant := _actor(1)
	var human := _actor(0)
	var crowd := current.get_node("Civilians")
	_park_civilians(current)
	var near_npc := crowd.get_child(0) as CharacterBody3D
	near_npc.position = Vector3(14.0, 0.02, 32.0)
	human.position = Vector3(-22.0, 0.02, 32.0)
	var wall := StaticBody3D.new()
	wall.collision_layer = BUILDING_LAYER
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 32.0, 60.0)
	var shape := CollisionShape3D.new()
	shape.shape = box
	wall.position = Vector3(7.0, 16.0, 32.0)
	wall.add_child(shape)
	current.add_child(wall)
	await _ticks(4)
	_check(current.snapshot().ai_target_id == human.get_instance_id(),
			"AI skips a nearer occluded civilian and chases the nearest visible human")
	wall.collision_layer = 0
	await _ticks(3)
	_check(current.snapshot().ai_target_id == near_npc.get_instance_id(),
			"AI switches to the closer civilian when the sightline opens")
	wall.collision_layer = BUILDING_LAYER
	human.position = Vector3(-600.0, 0.02, -600.0)
	for frame in 118:
		near_npc.position = Vector3(14.0, 0.02, 32.0)
		giant.position = Vector3(0.0, 0.02, 32.0)
		_park_civilians(current, near_npc)
		await physics_frame
	_check(current.snapshot().ai_target_id == near_npc.get_instance_id(),
			"AI continues tracking an already targeted civilian just before two seconds of occlusion")
	for frame in 5:
		near_npc.position = Vector3(14.0, 0.02, 32.0)
		_park_civilians(current, near_npc)
		await physics_frame
	_check(current.snapshot().ai_target_id == 0,
			"AI drops a civilian after two seconds of continuous occlusion")
	wall.collision_layer = 0
	await _ticks(3)
	_check(current.snapshot().ai_target_id == near_npc.get_instance_id(),
			"AI can acquire a civilian again when the obstruction clears")

	_game.start_mode(true)
	current = _round()
	giant = _actor(1)
	crowd = current.get_node("Civilians")
	var initial_count := crowd.get_child_count()
	var civilian := crowd.get_child(0) as CharacterBody3D
	var civilian_id := civilian.get_instance_id()
	_park_civilians(current, civilian)
	await FootfallFixture.land(current, func(gait: Dictionary) -> void:
		FootfallFixture.place_under(civilian, gait))
	await _ticks(300)
	_check(initial_count == 6 and not is_instance_id_valid(civilian_id)
			and crowd.get_child_count() == initial_count - 1,
			"sandbox starts with six NPCs and leaves the crowd smaller until the slower spawn timer expires")
	await _ticks(300)
	_check(crowd.get_child_count() == initial_count, "the NPC replacement spawns within six to ten seconds")
	_game.show_menu()


func _civilian_three_states() -> void:
	_game.start_mode(true)
	var current := _round()
	await _ticks(6)
	var giant := current.get_node("Giant") as CharacterBody3D
	var crowd := current.get_node("Civilians")
	_park_civilians(current)
	var npc := crowd.get_child(0) as CharacterBody3D
	var ui := _game.get_node("Interface")
	_check(not ui.get("_coin_radar").visible,
			"The fuzzy coin radar stays hidden outside growth mode")
	# Parked far from the giant, the spawn panic ebbs and the pedestrian
	# settles back into its calm daily stroll.
	giant.position = Vector3(0.0, 0.02, -600.0)
	var settled := false
	for frame in 900:
		await physics_frame
		if String(current.civilian_debug()[0].state) == "calm":
			settled = true
			break
	_check(settled, "An unthreatened pedestrian settles back into the calm state")

	# A nearby giant breaks the stroll into a panic sprint away from the threat.
	npc.position = Vector3(0.0, 0.02, 65.0)
	giant.position = Vector3(0.0, 0.02, 110.0)
	var start := npc.position
	var fled := false
	var panicked := false
	var state := ""
	for frame in 72:
		await physics_frame
		state = String(current.civilian_debug()[0].state)
		if state == "panic":
			panicked = true
		if npc.position.distance_to(start) > 4.0:
			fled = true
	_check(panicked and fled,
			"Sensing a giant switches the pedestrian to a panic sprint away from it")

	# With the threat far away the panic ebbs into sheltering and then calm.
	giant.position = Vector3(0.0, 0.02, -600.0)
	var saw_cover := false
	var calm := false
	for frame in 900:
		await physics_frame
		state = String(current.civilian_debug()[0].state)
		saw_cover = saw_cover or state == "cover"
		if state == "calm":
			calm = true
			break
	_check(saw_cover and calm,
			"After the threat passes the pedestrian shelters and then calms back down")
	_game.show_menu()


func _ai_demolition() -> void:
	_game.start_mode(false)
	var current := _round()
	var human := _actor(0)
	var giant := _actor(1)
	human.position = Vector3(0.0, 0.03, 100.0)
	_park_civilians(current)
	await _ticks(5)
	_check(current.snapshot().ai_target_id == human.get_instance_id() and current.snapshot().destroyed == 0,
			"AI pursues a visible human even with buildings closer than the target")
	human.position = Vector3(-600.0, 0.03, -600.0)
	for frame in 121:
		giant.position = Vector3(0.0, 0.02, 32.0)
		_park_civilians(current)
		await physics_frame
	var nearest: Node3D
	var distance := INF
	for target: Node3D in current.get_node("District/Targets").get_children():
		if target.kind != "building":
			continue
		var local := target.to_local(giant.position)
		var half: Vector3 = target.footprint * 0.5
		var distance_to_wall := Vector2(maxf(absf(local.x) - half.x, 0.0),
				maxf(absf(local.z) - half.z, 0.0)).length_squared()
		if distance_to_wall < distance:
			nearest = target
			distance = distance_to_wall
	for frame in 720:
		_park_civilians(current)
		if current.snapshot().destroyed > 0:
			break
		await physics_frame
	var count: int = current.snapshot().destroyed
	# A destructive personality may swap the flat nearest block for the tall
	# landmark right next to it (挑高楼倾向); either way the pick must come
	# from the nearest cluster of standing buildings.
	var ruined_distance := INF
	for target: Node3D in current.get_node("District/Targets").get_children():
		if target.kind != "building":
			continue
		if target.get_node("BlockingBody").collision_layer != 0:
			continue
		var local := target.to_local(giant.position)
		var half: Vector3 = target.footprint * 0.5
		var wall := Vector2(maxf(absf(local.x) - half.x, 0.0),
				maxf(absf(local.z) - half.z, 0.0)).length()
		ruined_distance = minf(ruined_distance, wall)
	_check(count > 0 and ruined_distance <= sqrt(distance) + 7.0,
			"After losing its target the AI destroys a building from the nearest cluster")
	await _wait_growth(current, count)
	_check(count > 0 and _giant_has_scale(giant, pow(GROWTH_PER_BUILDING, count)),
			"AI grows once per demolished building")
	_game.show_menu()


func _walking_attack() -> void:
	_game.start_mode(true)
	var current := _round()
	var giant := _actor(1)
	var target: Node3D = current.get_node("District/Targets/DockPress3")
	giant.call("_set_skin", &"Kawaii")
	FootfallFixture.face(current, giant, 0.0)
	giant.position = target.position + Vector3(0.0, 0.02, float(target.footprint.z) * 0.5 + 4.0)
	await _ticks(6)
	Input.action_press("move_forward")
	for frame in 120:
		await physics_frame
		if current.snapshot().destroyed > 0:
			break
	Input.action_release("move_forward")
	_check(current.snapshot().can_crush_buildings
			and (giant.collision_mask & 24) == 0 and current.snapshot().destroyed == 1
			and target.get_node("BlockingBody").collision_layer == 0,
			"Sandbox walking can immediately pass through and demolish an intact building")
	await _ticks(14)
	var model: Node3D = giant.get_node("Model")
	var arm: SpringArm3D = current.get_node("Orbit/Arm")
	var mid_scale := model.scale.x / 14.8
	_check(mid_scale > 1.01 and mid_scale < GROWTH_PER_BUILDING - 0.01
			and _giant_has_scale(giant, mid_scale)
			and is_equal_approx(arm.spring_length, 25.2 * mid_scale * 1.30),
			"model, collision and camera grow together through intermediate sizes")
	_game.pause()
	await _ticks(50)
	_check(_giant_has_scale(giant, mid_scale), "pause freezes the growth animation")
	_game.resume()
	await _ticks(40)
	_check(_giant_has_scale(giant, GROWTH_PER_BUILDING), "growth finishes at the full ten percent after resuming")
	_game.show_menu()


func _finish_walking_step() -> void:
	_game.start_mode(true)
	var current := _round()
	var giant := _actor(1)
	giant.position = Vector3(0.0, 0.02, 77.0)
	await _ticks(6)
	var before := int(FootfallFixture.actor(current).footfall_count)
	var planned: Dictionary = {}
	var peak_lift := 0.0
	var max_support_slip := 0.0
	var min_swing_pitch := 9.0
	var max_swing_pitch := -9.0
	var support_start := Vector3.INF
	var airborne := ""
	var support := ""
	Input.action_press("move_forward")
	for frame in 90:
		await physics_frame
		var tel_w: Dictionary = giant.get_turn_telemetry()
		min_swing_pitch = minf(min_swing_pitch, minf(float(tel_w["left_foot_pitch"]), float(tel_w["right_foot_pitch"])))
		max_swing_pitch = maxf(max_swing_pitch, maxf(float(tel_w["left_foot_pitch"]), float(tel_w["right_foot_pitch"])))
		var gait := FootfallFixture.actor(current)
		if not gait.get("footfall_pending", false):
			continue
		if airborne.is_empty():
			airborne = "L" if gait.footfall_left else "R"
			support = "R" if gait.footfall_left else "L"
			support_start = _ankle(giant, support)
		peak_lift = maxf(peak_lift, _ankle(giant, airborne).y - _ankle(giant, support).y)
		max_support_slip = maxf(max_support_slip, (_ankle(giant, support) - support_start).slide(Vector3.UP).length())
		if peak_lift > 2.0 and giant.heavy_step_preview().get("locked", false):
			planned = gait
			break
	Input.action_release("move_forward")
	for frame in 130:
		if int(FootfallFixture.actor(current).footfall_count) > before:
			break
		await physics_frame
	var landed := FootfallFixture.actor(current)
	var target: Vector3 = planned.get("footfall_center", Vector3.INF)
	var actual: Vector3 = landed.get("last_footfall_center", Vector3.INF)
	_check(peak_lift > 2.0 and max_support_slip < 0.06 and target != Vector3.INF,
			"The loaded support shoe remains fixed in world space during a high swing")
	_check(min_swing_pitch >= -0.02 and max_swing_pitch <= 0.02,
			"Walking heavy-step lift keeps the shoe level without pitching the toe upward (min=%.3f max=%.3f)" % [min_swing_pitch, max_swing_pitch])
	_check(int(landed.footfall_count) == before + 1
			and target.slide(Vector3.UP).distance_to(actual.slide(Vector3.UP)) < 0.1,
			"Releasing movement finishes the committed touchdown on its projected mark")
	await _ticks(65)
	var settled := FootfallFixture.actor(current)
	var count := int(settled.footfall_count)
	var has_only_distinct_plants: bool = count == before + 1 or (count == before + 2
			and settled.last_footfall_left != landed.last_footfall_left)
	await _ticks(90)
	_check(has_only_distinct_plants and FootfallFixture.actor(current).footfall_count == count,
			"Only the moving trail shoe may add a settling mark, and stationary shoes stay quiet")
	_game.show_menu()


func _giant_smooth_turn() -> void:
	_game.start_mode(true)
	var current := _round()
	var giant := _actor(1)
	await _ticks(4)

	# Once already walking, a 90-degree walking turn accelerates gently rather than snapping on frame 1.
	Input.action_press("move_forward")
	await _ticks(12)
	Input.action_release("move_forward")
	var start_yaw := giant.rotation.y
	var prev_yaw := start_yaw
	var first_step := 0.0
	var max_step := 0.0
	Input.action_press("move_right")
	for frame in 90:
		await physics_frame
		var step := absf(angle_difference(prev_yaw, giant.rotation.y))
		if frame == 0:
			first_step = step
		max_step = maxf(max_step, step)
		prev_yaw = giant.rotation.y
	Input.action_release("move_right")
	_check(first_step < 0.025 and max_step < 0.025 and absf(angle_difference(start_yaw, giant.rotation.y)) > 1.1,
			"giant walking turns accelerate smoothly without snapping on frame one")

	_check(not InputMap.has_action("stomp") and not current.has_method("tap_stomp"),
			"The round and Input Map both omit the old manual attack")
	_game.show_menu()


func _giant_layered_turn() -> void:
	_game.start_mode(true)
	var current := _round()
	var giant := _actor(1)
	var orbit: Node3D = current.get_node("Orbit")
	giant.position = Vector3(0.0, 0.03, 36.0)
	giant.rotation = Vector3.ZERO
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(8)

	# 1. Free camera orbit leaves the standing giant facing north.
	_mouse(Vector2(-angle_difference(orbit.rotation.y, PI * 0.5) / 0.0028, 0.0))
	await _ticks(24)
	var yaw_after_side_look := absf(angle_difference(0.0, giant.rotation.y))
	_mouse(Vector2(-angle_difference(orbit.rotation.y, PI) / 0.0028, 0.0))
	await _ticks(24)
	var yaw_after_rear_look := absf(angle_difference(0.0, giant.rotation.y))
	var tel_look: Dictionary = giant.get_turn_telemetry()
	_check(yaw_after_side_look < 0.01 and yaw_after_rear_look < 0.01 and not bool(tel_look["standing_turning"]),
			"orbiting the camera around a standing giant leaves body facing untouched")

	# 2. Hand attacks (grab_crush / punch) only hit targets in front of current body facing;
	#    to attack a building directly behind, the giant must turn around first.
	_park_civilians(current)
	var dock3: Node3D = current.get_node("District/Targets/DockPress3")
	giant.position = dock3.position + Vector3(0.0, 0.03, float(dock3.footprint.z) * 0.5 + 5.0)
	giant.rotation = Vector3(0.0, PI, 0.0)
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(6)
	current.tap_grab_crush()
	await _ticks(4)
	var rear_grab_empty: bool = current.snapshot().hand_action.is_empty()
	current.tap_punch()
	await _ticks(4)
	var rear_punch_empty: bool = current.snapshot().hand_action.is_empty()
	var facing_still_south := absf(angle_difference(PI, giant.rotation.y)) < 0.02
	_check(rear_grab_empty and rear_punch_empty and facing_still_south,
			"hand attacks reject targets behind the giant even when the camera looks straight at them")

	# Face north into the same building without changing position.
	giant.rotation = Vector3.ZERO
	await _ticks(12)
	current.tap_grab_crush()
	await _ticks(4)
	_check(current.snapshot().hand_action == "grab_crush",
			"turning to face the rear target first unlocks hand attacks on it")
	_game.restart()
	current = _round()
	giant = _actor(1)
	orbit = current.get_node("Orbit")
	giant.position = Vector3(0.0, 0.03, -675.0)
	giant.rotation = Vector3.ZERO
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(8)

	# 3. Standing 90-degree directional press (move_left) immediately launches forward into a natural
	#    car-like curved arc (no zero-velocity tank-turn lock or stationary stepping), keeping the
	#    top-down gaze cascade, zero support slip, and bounded ~30-45 deg turn per step.
	var start_yaw := giant.rotation.y
	var pivot_origin := giant.position
	var before_destroyed: int = current.snapshot().destroyed
	var fc_arc0 := int(FootfallFixture.actor(current).footfall_count)
	Input.action_press("move_left")

	var t_eye := -1.0
	var t_head := -1.0
	var t_chest := -1.0
	var t_pelvis := -1.0
	var best_ratio := 0.0
	var max_s_curve := 0.0
	var min_sh_counter := 0.0
	var max_slip := 0.0
	var max_yaw_rate := 0.0
	var max_step_dyaw := 0.0
	var disp_early := 0.0
	var saw_stationary_turn := false
	var saw_walk_curve := false
	var prev_yaw := start_yaw
	var step_start_yaw := start_yaw
	var prev_fc := fc_arc0
	var prev_l_planted := true
	var prev_r_planted := true
	var prev_l_mode := -1
	var prev_r_mode := -1
	var prev_l_piv := Vector3.ZERO
	var prev_r_piv := Vector3.ZERO

	for frame in 150:
		await physics_frame
		var t_sec := float(frame + 1) / 60.0
		var tel: Dictionary = giant.get_turn_telemetry()
		var mode_s: String = tel["mode"]
		var dyaw_rate := absf(angle_difference(prev_yaw, giant.rotation.y)) * 60.0
		max_yaw_rate = maxf(max_yaw_rate, dyaw_rate)
		prev_yaw = giant.rotation.y

		if bool(tel["standing_turning"]) or bool(tel["standing_step_active"]):
			saw_stationary_turn = true
		if mode_s == "walk_sharp_turn" or mode_s == "walk_gentle_turn":
			saw_walk_curve = true

		var fc_now := int(FootfallFixture.actor(current).footfall_count)
		if fc_now > prev_fc:
			max_step_dyaw = maxf(max_step_dyaw, absf(angle_difference(step_start_yaw, giant.rotation.y)))
			step_start_yaw = giant.rotation.y
			prev_fc = fc_now

		var eye_d := absf(angle_difference(start_yaw, float(tel["eye_world_yaw"])))
		var head_d := absf(angle_difference(start_yaw, float(tel["head_world_yaw"])))
		var chest_d := absf(angle_difference(start_yaw, float(tel["chest_world_yaw"])))
		var pelvis_d := absf(angle_difference(start_yaw, float(tel["pelvis_world_yaw"])))
		var l_pl: bool = tel["left_planted"]
		var r_pl: bool = tel["right_planted"]
		var l_mode: int = tel["left_pivot_mode"]
		var r_mode: int = tel["right_pivot_mode"]
		var l_piv: Vector3 = tel["left_heel_world"] if l_mode == 0 else tel["left_ball_world"]
		var r_piv: Vector3 = tel["right_heel_world"] if r_mode == 0 else tel["right_ball_world"]

		if t_eye < 0.0 and eye_d >= 0.08:
			t_eye = t_sec
		if t_head < 0.0 and head_d >= 0.08:
			t_head = t_sec
		if t_chest < 0.0 and chest_d >= 0.06:
			t_chest = t_sec
		if t_pelvis < 0.0 and pelvis_d >= 0.06:
			t_pelvis = t_sec
		if frame == 11:
			disp_early = Vector2(giant.position.x - pivot_origin.x, giant.position.z - pivot_origin.z).length()

		var head_rel := float(tel["head_rel_pelvis"])
		if absf(head_rel) > 0.25:
			var r := float(tel["chest_to_head_ratio"])
			if best_ratio == 0.0 or absf(r - 0.5) < absf(best_ratio - 0.5):
				best_ratio = r
		max_s_curve = maxf(max_s_curve, float(tel["spine_s_curve"]))
		min_sh_counter = minf(min_sh_counter, float(tel["shoulder_counter_z"]))

		if l_pl and prev_l_planted and l_mode == prev_l_mode and frame > 0:
			max_slip = maxf(max_slip, Vector2(l_piv.x - prev_l_piv.x, l_piv.z - prev_l_piv.z).length())
		if r_pl and prev_r_planted and r_mode == prev_r_mode and frame > 0:
			max_slip = maxf(max_slip, Vector2(r_piv.x - prev_r_piv.x, r_piv.z - prev_r_piv.z).length())

		prev_l_planted = l_pl
		prev_r_planted = r_pl
		prev_l_mode = l_mode
		prev_r_mode = r_mode
		prev_l_piv = l_piv
		prev_r_piv = r_piv
	Input.action_release("move_left")

	var arc_err90 := absf(angle_difference(giant.rotation.y, PI * 0.5))
	_check(t_eye > 0.0 and t_eye <= t_head and t_head < t_chest and t_chest <= t_pelvis,
			"standing curve turn cascades top-down from eyes and head through chest to pelvis")
	_check(best_ratio >= 0.35 and best_ratio <= 0.68 and max_s_curve > 0.05 and min_sh_counter < -0.02,
			"standing curve turn rotates chest cleanly relative to head with natural spine S-curve")
	_check(not saw_stationary_turn and saw_walk_curve and disp_early > 0.50 and arc_err90 < 0.08
			and max_yaw_rate <= 1.05 and rad_to_deg(max_step_dyaw) <= 46.0 and max_slip < 0.02
			and current.snapshot().destroyed == before_destroyed,
			"standing 90-degree directional press enters a zero-slip curved arc immediately without stationary tank spinning")

	# Diagonal backward input (S+D) turns smoothly around along a curved arc instead of backpedaling.
	giant.position = Vector3(0.0, 0.03, 36.0)
	giant.rotation = Vector3.ZERO
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(12)
	Input.action_press("move_back")
	Input.action_press("move_right")
	var diag_saw_backpedal := false
	var diag_disp_12 := 0.0
	for frame in 50:
		await physics_frame
		if bool(giant.get_turn_telemetry().get("walk_backward", false)):
			diag_saw_backpedal = true
		if frame == 11:
			diag_disp_12 = Vector2(giant.position.x, giant.position.z - 36.0).length()
	Input.action_release("move_back")
	Input.action_release("move_right")
	_check(not diag_saw_backpedal and diag_disp_12 > 0.40 and giant.rotation.y < -0.25,
			"Diagonal backward input curves into a turnaround arc immediately instead of backpedaling or spinning in place")

	# 4. Pressing Back (S) keeps the body facing the camera direction and plays a natural
	#    backward walk without spinning 180 degrees or twisting the pelvis/legs.
	giant.position = Vector3(0.0, 0.03, 36.0)
	giant.rotation = Vector3.ZERO
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(12)
	var back_fc_before := int(FootfallFixture.actor(current).footfall_count)
	Input.action_press("move_back")
	var back_max_yaw_err := 0.0
	var back_saw_pivot := false
	var back_mode_active := false
	var back_max_roll := 0.0
	var back_legs_clean := true
	for frame in 95:
		await physics_frame
		var tel: Dictionary = giant.get_turn_telemetry()
		back_max_yaw_err = maxf(back_max_yaw_err, absf(angle_difference(0.0, giant.rotation.y)))
		back_saw_pivot = back_saw_pivot or bool(tel["standing_turning"]) or bool(tel["standing_step_active"])
		back_mode_active = back_mode_active or bool(tel.get("walk_backward", false))
		back_max_roll = maxf(back_max_roll, absf(float(tel.get("pelvis_roll_rad", 0.0))))
		back_legs_clean = back_legs_clean and float(tel.get("left_ankle_local_x", 0.1)) > 0.035 \
				and float(tel.get("right_ankle_local_x", -0.1)) < -0.035
	Input.action_release("move_back")
	var back_dist := giant.position.z - 36.0
	var back_fc_after := int(FootfallFixture.actor(current).footfall_count)
	_check(back_mode_active and not back_saw_pivot and back_max_yaw_err < 0.08
			and back_dist > 4.0 and back_dist < 9.5 and back_fc_after > back_fc_before
			and back_max_roll < 0.14 and back_legs_clean,
			"Pressing Back walks backward smoothly without a 180-degree turnaround or torso twist")

	# Early release mid-curve finishes placing the airborne step cleanly with zero slip
	# and stops emitting steps once grounded travel reaches zero.
	giant.position = Vector3(0.0, 0.03, 36.0)
	giant.rotation = Vector3.ZERO
	await _ticks(12)
	Input.action_press("move_left")
	await _ticks(28)
	Input.action_release("move_left")
	var release_slip := 0.0
	var settled_cleanly := false
	var fc_after_settle := -1
	var extra_fc_at_rest := 0
	prev_l_planted = true
	prev_r_planted = true
	prev_l_mode = -1
	prev_r_mode = -1
	for frame in 90:
		await physics_frame
		var tel: Dictionary = giant.get_turn_telemetry()
		var l_pl: bool = tel["left_planted"]
		var r_pl: bool = tel["right_planted"]
		var l_mode: int = tel["left_pivot_mode"]
		var r_mode: int = tel["right_pivot_mode"]
		var l_piv: Vector3 = tel["left_heel_world"] if l_mode == 0 else tel["left_ball_world"]
		var r_piv: Vector3 = tel["right_heel_world"] if r_mode == 0 else tel["right_ball_world"]
		if l_pl and prev_l_planted and l_mode == prev_l_mode and frame > 0:
			release_slip = maxf(release_slip, Vector2(l_piv.x - prev_l_piv.x, l_piv.z - prev_l_piv.z).length())
		if r_pl and prev_r_planted and r_mode == prev_r_mode and frame > 0:
			release_slip = maxf(release_slip, Vector2(r_piv.x - prev_r_piv.x, r_piv.z - prev_r_piv.z).length())
		if frame >= 50 and l_pl and r_pl and not bool(tel["standing_step_active"]) and tel["mode"] == "idle":
			if fc_after_settle < 0:
				fc_after_settle = int(FootfallFixture.actor(current).footfall_count)
			settled_cleanly = true
		if fc_after_settle >= 0 and int(FootfallFixture.actor(current).footfall_count) > fc_after_settle:
			extra_fc_at_rest += 1
		prev_l_planted = l_pl
		prev_r_planted = r_pl
		prev_l_mode = l_mode
		prev_r_mode = r_mode
		prev_l_piv = l_piv
		prev_r_piv = r_piv
	_check(settled_cleanly and release_slip < 0.02 and extra_fc_at_rest == 0 and giant.rotation.y > 0.18 and giant.rotation.y < 1.10,
			"releasing directional input mid-arc settles cleanly with zero slip and zero stationary steps")

	# 5. Walking gentle curve vs sharp left/right turns on open central intersection.
	giant.position = Vector3(0.0, 0.03, 0.0)
	giant.rotation = Vector3.ZERO
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(6)
	Input.action_press("move_forward")
	var gentle_min_stride := 9.0
	var gentle_max_lean := 0.0
	for frame in 65:
		_mouse(Vector2(-1.2, 0.0))
		await physics_frame
		if frame > 15:
			var tel: Dictionary = giant.get_turn_telemetry()
			gentle_min_stride = minf(gentle_min_stride, float(tel["turn_stride_mult"]))
			gentle_max_lean = maxf(gentle_max_lean, absf(rad_to_deg(float(tel["inward_lean_rad"]))))
	Input.action_release("move_forward")

	# Sharp left turn while already walking, then sharp right turn while already walking.
	giant.position = Vector3(0.0, 0.03, 0.0)
	giant.rotation = Vector3.ZERO
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(6)
	Input.action_press("move_forward")
	await _ticks(14)
	Input.action_release("move_forward")
	Input.action_press("move_left")
	var left_peak_lean := 0.0
	var left_min_stride := 9.0
	var left_max_cadence := 0.0
	var left_asym_arms := false
	for frame in 60:
		await physics_frame
		if frame > 8:
			var tel: Dictionary = giant.get_turn_telemetry()
			left_peak_lean = maxf(left_peak_lean, rad_to_deg(float(tel["inward_lean_rad"])))
			left_min_stride = minf(left_min_stride, float(tel["turn_stride_mult"]))
			left_max_cadence = maxf(left_max_cadence, float(tel["turn_cadence_mult"]))
			if float(tel["right_arm_open"]) > float(tel["left_arm_open"]) + 0.08 \
					and float(tel["right_arm_amp"]) > float(tel["left_arm_amp"]) + 0.15:
				left_asym_arms = true
	Input.action_release("move_left")

	giant.position = Vector3(0.0, 0.03, 0.0)
	giant.rotation = Vector3.ZERO
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(6)
	Input.action_press("move_forward")
	await _ticks(14)
	Input.action_release("move_forward")
	Input.action_press("move_right")
	var right_peak_lean := 0.0
	var right_asym_arms := false
	for frame in 60:
		await physics_frame
		if frame > 8:
			var tel: Dictionary = giant.get_turn_telemetry()
			right_peak_lean = minf(right_peak_lean, rad_to_deg(float(tel["inward_lean_rad"])))
			if float(tel["left_arm_open"]) > float(tel["right_arm_open"]) + 0.08 \
					and float(tel["left_arm_amp"]) > float(tel["right_arm_amp"]) + 0.15:
				right_asym_arms = true
	Input.action_release("move_right")

	_check(gentle_min_stride > 0.92 and gentle_max_lean < 8.0
			and left_peak_lean > gentle_max_lean + 3.0 and right_peak_lean < -5.0,
			"walking leans inward on both left and right turns and scales lean above gentle curves")
	_check(left_min_stride < 0.72 and left_max_cadence > 1.25 and left_asym_arms and right_asym_arms,
			"sharp walking turns shorten and quicken stride while opening the outside arm and tucking the inside arm")
	_game.show_menu()


func _blocked_walk_pivot() -> void:
	_game.start_mode(true)
	var current := _round()
	var giant := _actor(1)
	var orbit: Node3D = current.get_node("Orbit")
	# Hug the north boundary wall with the capsule already touching it, facing straight into it.
	giant.position = Vector3(0.0, 0.03, -current.get_node("District").play_edge + 3.1)
	giant.rotation = Vector3.ZERO
	await _ticks(8)
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(2)
	Input.action_press("move_forward")
	await _ticks(35)
	var before_turn := int(FootfallFixture.actor(current).footfall_count)
	await _ticks(30)
	_check(int(FootfallFixture.actor(current).footfall_count) == before_turn,
			"Steering into a blocked wall does not repeatedly strike it while stationary")
	_mouse(Vector2(-angle_difference(orbit.rotation.y, PI) / 0.0028, 0.0))
	var start_z := giant.global_position.z
	var blocked_stationary_step := false
	var turned := false
	var left := false
	for frame in 1500:
		await physics_frame
		var blk_tel: Dictionary = giant.get_turn_telemetry()
		if bool(blk_tel["standing_turning"]) or bool(blk_tel["standing_step_active"]):
			blocked_stationary_step = true
		if absf(angle_difference(giant.rotation.y, PI)) < 0.5:
			turned = true
		if giant.global_position.z - start_z > 15.0:
			left = true
			break
	Input.action_release("move_forward")
	_check(not blocked_stationary_step and turned and left,
			"A blocked giant holding forward away from a wall turns smoothly without stationary stepping and leaves the wall")

	# Diagonal/straight push into wall keeps pelvis upright and legs separated without IK twist.
	giant.position = Vector3(0.0, 0.03, -current.get_node("District").play_edge + 3.1)
	giant.rotation = Vector3.ZERO
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(8)
	Input.action_press("move_forward")
	Input.action_press("move_left")
	var wall_max_roll := 0.0
	var wall_max_lean := 0.0
	var wall_legs_safe := true
	var wall_blocked_seen := false
	for frame in 45:
		await physics_frame
		var tel: Dictionary = giant.get_turn_telemetry()
		if frame >= 15:
			wall_max_roll = maxf(wall_max_roll, absf(float(tel.get("pelvis_roll_rad", 0.0))))
			wall_max_lean = maxf(wall_max_lean, absf(float(tel.get("inward_lean_rad", 0.0))))
		wall_legs_safe = wall_legs_safe and float(tel.get("left_ankle_local_x", 0.1)) >= 0.035 \
				and float(tel.get("right_ankle_local_x", -0.1)) <= -0.035
		wall_blocked_seen = wall_blocked_seen or float(tel.get("blocked_weight", 0.0)) > 0.35
	Input.action_release("move_forward")
	Input.action_release("move_left")
	_check(wall_blocked_seen and wall_max_roll < 0.12 and wall_max_lean < 0.05 and wall_legs_safe,
			"Pushing obliquely into a wall decays lean/roll and prevents twisted support IK")

	# Rapid alternating low-speed/stationary turning never spams heavy stomp footfalls or overlapping prints.
	giant.position = Vector3(0.0, 0.03, 0.0)
	giant.rotation = Vector3.ZERO
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(8)
	var fc_pre_spin := int(FootfallFixture.actor(current).footfall_count)
	var spin_saw_st := false
	for cycle_idx in 4:
		var key := "move_left" if cycle_idx % 2 == 0 else "move_right"
		Input.action_press(key)
		for _sub in 14:
			await physics_frame
			var st_tel: Dictionary = giant.get_turn_telemetry()
			if bool(st_tel["standing_turning"]) or bool(st_tel["standing_step_active"]):
				spin_saw_st = true
		Input.action_release(key)
	var weave_fc := int(FootfallFixture.actor(current).footfall_count) - fc_pre_spin
	_check(not spin_saw_st and weave_fc <= 1,
			"Sharp alternating turning transitions smoothly along an arc without spamming heavy stomp footprints")

	# Holding a directional key far from current facing turns briskly without off-axis small-step spam.
	giant.position = Vector3(0.0, 0.03, 0.0)
	giant.rotation = Vector3(0.0, PI * 0.25, 0.0)
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(6)
	Input.action_press("move_forward")
	Input.action_press("move_left")
	await _ticks(12)
	Input.action_release("move_forward")
	Input.action_release("move_left")
	var fc_pre_offaxis := int(FootfallFixture.actor(current).footfall_count)
	Input.action_press("move_right")
	var offaxis_saw_st := false
	for _off_f in 210:
		await physics_frame
		var otel: Dictionary = giant.get_turn_telemetry()
		if bool(otel["standing_turning"]) or bool(otel["standing_step_active"]):
			offaxis_saw_st = true
	Input.action_release("move_right")
	var offaxis_err := absf(angle_difference(giant.rotation.y, -PI * 0.5))
	var offaxis_fc := int(FootfallFixture.actor(current).footfall_count) - fc_pre_offaxis
	_check(not offaxis_saw_st and offaxis_err < 0.25 and offaxis_fc >= 2 and offaxis_fc <= 5,
			"Holding an off-heading directional key turns along a curved arc in full strides without small-step spam")

	# Pure stationary micro-turning with zero horizontal movement never emits footsteps.
	giant.position = Vector3(0.0, 0.03, 0.0)
	giant.rotation = Vector3.ZERO
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(60)
	current.set_camera_view(2)
	await _ticks(6)
	var fp_idle_fc := int(FootfallFixture.actor(current).footfall_count)
	var fp_idle_st := false
	_set_key_state(KEY_LEFT, true)
	for _fp_f in 60:
		await physics_frame
		var ftel: Dictionary = giant.get_turn_telemetry()
		if bool(ftel["standing_turning"]) or bool(ftel["standing_step_active"]):
			fp_idle_st = true
	_set_key_state(KEY_LEFT, false)
	current.set_camera_view(0)
	_check(not fp_idle_st and int(FootfallFixture.actor(current).footfall_count) == fp_idle_fc,
			"Turning the body without horizontal displacement never plays stationary stepping")

	# Spinning the camera rapidly while walking forward obeys car-like turn limits,
	# keeps planted support feet pinned without slip, and prevents leg crossing.
	giant.position = Vector3(0.0, 0.03, 0.0)
	giant.rotation = Vector3.ZERO
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(6)
	Input.action_press("move_forward")
	var spin_legs_clean := true
	var spin_support_slip := 0.0
	var spin_max_rate := 0.0
	var sp_prev_yaw := giant.rotation.y
	var sp_prev_l_pl := false
	var sp_prev_r_pl := false
	var sp_prev_l_mode := -1
	var sp_prev_r_mode := -1
	var sp_prev_l_piv := Vector3.ZERO
	var sp_prev_r_piv := Vector3.ZERO
	for s_frame in 95:
		_mouse(Vector2(-10.0 if s_frame >= 20 else -5.0, 0.0))
		await physics_frame
		spin_max_rate = maxf(spin_max_rate, absf(angle_difference(sp_prev_yaw, giant.rotation.y)) * 60.0)
		sp_prev_yaw = giant.rotation.y
		var tel: Dictionary = giant.get_turn_telemetry()
		var lx := float(tel.get("left_ankle_local_x", 0.0))
		var rx := float(tel.get("right_ankle_local_x", 0.0))
		if lx < 0.038 or rx > -0.038:
			spin_legs_clean = false
		var l_pl := bool(tel["left_planted"])
		var r_pl := bool(tel["right_planted"])
		var l_mode := int(tel["left_pivot_mode"])
		var r_mode := int(tel["right_pivot_mode"])
		var l_piv: Vector3 = tel["left_heel_world"] if l_mode == 0 else tel["left_ball_world"]
		var r_piv: Vector3 = tel["right_heel_world"] if r_mode == 0 else tel["right_ball_world"]
		if s_frame > 4:
			if l_pl and sp_prev_l_pl and l_mode == sp_prev_l_mode:
				spin_support_slip = maxf(spin_support_slip, Vector2(l_piv.x - sp_prev_l_piv.x, l_piv.z - sp_prev_l_piv.z).length())
			if r_pl and sp_prev_r_pl and r_mode == sp_prev_r_mode:
				spin_support_slip = maxf(spin_support_slip, Vector2(r_piv.x - sp_prev_r_piv.x, r_piv.z - sp_prev_r_piv.z).length())
		sp_prev_l_pl = l_pl
		sp_prev_r_pl = r_pl
		sp_prev_l_mode = l_mode
		sp_prev_r_mode = r_mode
		sp_prev_l_piv = l_piv
		sp_prev_r_piv = r_piv
	Input.action_release("move_forward")
	_check(spin_legs_clean and spin_support_slip < 0.015 and spin_max_rate <= 1.05
			and absf(angle_difference(0.0, giant.rotation.y)) > 0.90,
			"Rapid camera turning while walking follows a bounded car-like arc with zero slip and no leg crossing")
	_game.show_menu()


func _giant_sandbox() -> void:
	_game.start_mode(true)
	var current := _round()
	var haz := current.get_node_or_null("DeskHazards")
	if haz != null:
		haz.set("_next_auto_in", 9999.0)
	var giant := _actor(1)
	await _ticks(4)
	_check(current.get_node_or_null("Human") == null and current.get_node("Civilians").get_child_count() > 0,
			"giant mode spawns the giant and civilian NPCs")
	_check(root.get_camera_3d() == current.get_node("Orbit/Arm/Camera"), "giant camera activates")

	await _check_giant_walk(giant)
	_check(_roadblock_count(current) == 0, "sandbox maps no longer contain roadblocks")

	giant.position = Vector3(0.0, 0.03, 77.0)
	FootfallFixture.face(current, giant, 0.0)
	await _ticks(5)
	var initial := int(FootfallFixture.actor(current).footfall_count)
	_key(KEY_SPACE)
	await _ticks(20)
	_check(int(FootfallFixture.actor(current).footfall_count) == initial,
			"Space alone creates no footfall in the giant sandbox")
	var pending := {}
	Input.action_press("move_forward")
	for frame in 125:
		await physics_frame
		pending = FootfallFixture.actor(current)
		if pending.footfall_pending and giant.heavy_step_preview().get("locked", false):
			break
	Input.action_release("move_forward")
	_key(KEY_ESCAPE)
	var before_pause := giant.position
	var paused_foot := _ankle(giant, "L")
	await _ticks(55)
	_check(pending.get("footfall_pending", false) and FootfallFixture.actor(current).footfall_pending
			and giant.position.is_equal_approx(before_pause),
			"Pause freezes an in-flight heavy foot and its actor")
	_check(_ankle(giant, "L").is_equal_approx(paused_foot), "pause freezes the skeletal pose")
	_key(KEY_ESCAPE)
	for frame in 110:
		await physics_frame
		if int(FootfallFixture.actor(current).footfall_count) > initial:
			break
	var effects := current.get_node("Effects")
	var first_contact := FootfallFixture.actor(current)
	_check(int(first_contact.footfall_count) == initial + 1
			and first_contact.get("last_footfall_left") == pending.get("footfall_left"),
			"Resuming completes that airborne shoe's footfall exactly once")
	# Verify alternating feet while one continuous walking input remains held.
	await _ticks(65)
	var continuous := int(FootfallFixture.actor(current).footfall_count)
	var contacts: Array[Dictionary] = []
	Input.action_press("move_forward")
	for frame in 170:
		await physics_frame
		var gait := FootfallFixture.actor(current)
		if int(gait.footfall_count) > continuous + contacts.size():
			contacts.append(gait)
			if contacts.size() == 2:
				break
	Input.action_release("move_forward")
	var prints: Array = effects.footprint_debug()
	var matching_count := 0
	for contact in contacts:
		var matching := prints.any(func(imprint: Dictionary) -> bool:
			var at: Vector3 = imprint.position
			return (at.is_equal_approx(contact.last_footfall_center)
					and imprint.left == contact.last_footfall_left
					and imprint.half_extents == contact.last_footfall_half_extents))
		if matching:
			matching_count += 1
	_check(contacts.size() == 2 and matching_count == 2
			and contacts[0].last_footfall_left != contacts[1].last_footfall_left,
			"Successive heavy landings alternate sides and leave matching sole impressions")
	await _check_footprint_pool(effects)

	# Place the actor on the street-facing side of each core building to exercise
	# actual impact detection against all footprints in the central harbor.
	giant.call("_set_skin", &"Kawaii")
	var targets: Node = current.get_node("District/Targets")
	for building_name: StringName in CORE_BUILDINGS:
		var target: Node3D = targets.get_node(NodePath(building_name))
		var building_blocker: StaticBody3D = target.get_node("BlockingBody")
		if building_blocker.collision_layer == 0:
			continue
		var from_south: bool = is_equal_approx(target.position.z, -12.5) or is_equal_approx(target.position.z, 23.65)
		var before_count: int = current.snapshot().destroyed
		await _wait_growth(current, before_count)
		var yaw := 0.0 if from_south else PI
		await FootfallFixture.strike_building(current, target, yaw)
		_check(building_blocker.collision_layer == 0 and current.snapshot().destroyed > before_count,
				"An intact building collapses on the first walking approach")
		if target.name == &"DockPress1":
			await _check_collapse_pause(target, building_blocker)
			await _wait_growth(current, 1)
			_check(_giant_has_scale(giant, GROWTH_PER_BUILDING), "one destroyed building grows the model and capsule by ten percent")

	_check(current.snapshot().destroyed == 12, "giant can destroy all 12 buildings")
	await _wait_growth(current, 12)
	var final_scale := pow(GROWTH_PER_BUILDING, 12)
	_check(_giant_has_scale(giant, final_scale), "giant growth compounds across all twelve buildings")
	_check(_game.get_screen() == "playing", "sandbox remains playable after all buildings are destroyed")
	var vanished := giant.position
	Input.action_press("move_forward")
	await _ticks(28)
	Input.action_release("move_forward")
	_check(giant.position.distance_to(vanished) > 2.0, "sandbox still accepts movement after all buildings fall")
	await _ticks(425)
	var all_settled := true
	for building_name: StringName in CORE_BUILDINGS:
		var target: Node3D = targets.get_node(NodePath(building_name))
		all_settled = all_settled and target.has_node("RuinBody")
		all_settled = all_settled and target.has_node("RuinModel") and not target.has_node("CollapseModel")
	_check(all_settled, "all three building variants settle with static rubble collision")
	var tower := targets.get_node("Tidewater4") as Node3D
	giant.global_position = tower.global_position + Vector3.UP * 0.02
	await _ticks(12)
	_check(giant.global_position.y < 0.2 and (giant.collision_mask & 16) == 0,
			"The giant can stand inside tower rubble at ground level")
	# Growing scales both dimensions of the live sole.
	giant.position = Vector3(0.0, 0.03, -110.0)
	FootfallFixture.face(current, giant, 0.0)
	await _ticks(12)
	var grown := await FootfallFixture.land(current)
	var original_sole: Vector2 = first_contact.get("last_footfall_half_extents", Vector2.ZERO)
	var grown_sole: Vector2 = grown.get("last_footfall_half_extents", Vector2.ZERO)
	_check(original_sole.x > 0.0 and original_sole.y > 0.0
			and grown_sole.x > original_sole.x * 2.0 and grown_sole.y > original_sole.y * 2.0,
			"Growth scales shoe length and width together")

	# Start another collapse and restart before the animation has time to finish.
	_game.restart()
	var replacement := _round()
	var fresh_target: Node3D = replacement.get_node("District/Targets/DockPress3")
	_check(replacement.snapshot().destroyed == 0 and fresh_target.has_node("IntactModel")
			and replacement.snapshot().can_crush_buildings,
			"Restart restores the buildings and keeps Sandbox building passage enabled")
	await FootfallFixture.strike_building(replacement, fresh_target, 0.0)
	_check(fresh_target.has_node("CollapseModel"),
			"a new round can play the same source clip again")
	_game.pause()
	_game.restart()
	await _ticks(4)
	_check(_initial_state(_round()) and _actor(1).position.z == 32.0, "restart restores all buildings and footfall counts")
	_check(_round().has_node("District/Targets/DockPress3/IntactModel")
			and not _round().has_node("District/Targets/DockPress3/CollapseModel")
			and not _round().has_node("District/Targets/DockPress3/RuinBody"), "restart discards collapse and rubble collision")
	_game.restart()
	await _ticks(4)
	_check(_initial_state(_round()), "consecutive giant restart also resets the round")
	_game.pause()
	_game.show_menu()
	_check(not paused and _game.get_screen() == "menu", "return to title releases pause")


func _queued_growth_and_footfalls() -> void:
	var current := (load("res://scenes/round.tscn") as PackedScene).instantiate()
	current.configure(true)
	var targets := current.get_node("District/Targets")
	var sites := [Vector3(0.0, 0.02, -693.0), Vector3(36.0, 0.02, -693.0),
			Vector3(72.0, 0.02, -693.0), Vector3(108.0, 0.02, -693.0)]
	var fixtures: Array[Node3D] = []
	for stage in sites.size():
		for i in [3, 3, 2, 1][stage]:
			fixtures.append(_test_building(targets, sites[stage], "fixture"))
	var cap_site := Vector3(672.0, 0.02, -693.0)
	for i in 27:
		_test_building(targets, cap_site)
	var over_cap := _test_building(targets, Vector3(-250.0, 0.02, -670.0))
	root.add_child(current)
	var giant := current.get_node("Giant") as CharacterBody3D
	await FootfallFixture.sit_building(current, fixtures[0], 0.0)
	await FootfallFixture.sit_building(current, fixtures[0], 0.0, -1.0, false)
	_check(current.snapshot().destroyed == 3 and current.snapshot().growth_count == 0,
			"three buildings destroyed in one impact queue separate growth steps")
	var first_start := -1
	var second_start := -1
	for frame in 150:
		var factor: float = current.snapshot().giant_scale
		if first_start < 0 and factor > 1.0001:
			first_start = frame
		if factor > GROWTH_PER_BUILDING + 0.0001:
			second_start = frame
			break
		await physics_frame
	_check(first_start >= 0 and second_start - first_start >= 60
			and current.snapshot().growth_count == 1,
			"queued ten-percent growth steps start at least one second apart")
	await _wait_growth(current, 3)
	_check(_giant_has_scale(giant, pow(GROWTH_PER_BUILDING, 3)),
			"The independent growth queue preserves every compounding increase")
	await FootfallFixture.sit_building(current, fixtures[3], 0.0)
	await _wait_growth(current, 6)
	await FootfallFixture.strike_building(current, fixtures[6], 0.0)
	await _wait_growth(current, 8)
	_check(current.snapshot().destroyed == 8 and fixtures[7].has_node("RuinBody"),
			"The eighth growth unlocks after the queue reaches eight")

	await FootfallFixture.strike_building(current, fixtures[8], 0.0)
	_check(current.snapshot().destroyed == 9 and fixtures[8].has_node("RuinBody")
			and not fixtures[8].get_node("BlockingBody").collision_layer,
			"The giant still crushes a building on a single heavy contact after the eighth growth")

	var cap_target := _find_target_at(targets, cap_site)
	await FootfallFixture.strike_building(current, cap_target, 0.0)
	await _wait_growth(current, 32, 2100)
	var capsule := (giant.get_node("Collision") as CollisionShape3D).shape as CapsuleShape3D
	var max_scale := 500.0 / 25.2
	_check(capsule.height == 500.0 and current.snapshot().giant_height == 500.0
			and current.snapshot().giant_at_max_height
			and _giant_has_scale(giant, max_scale), "the giant model and capsule stop at 500 meters")
	# The 500 m capsule spans several blocks. Clear the approach of incidental
	# blockers while keeping the test facade solid and its damage rules intact.
	for target: Node3D in targets.get_children():
		if target != over_cap and target.position.distance_to(over_cap.position) < 180.0:
			var blocker := target.get_node_or_null("BlockingBody") as StaticBody3D
			if blocker != null:
				giant.add_collision_exception_with(blocker)
	var cap_landing := await FootfallFixture.strike_building(current, over_cap, 0.0, -1.0, 3.0, -1.0)
	await _ticks(65)
	_check(not cap_landing.is_empty() and over_cap.get_node("BlockingBody").collision_layer == 0
			and current.snapshot().growth_count == 32 and current.snapshot().giant_height == 500.0,
			"the giant can still demolish buildings after reaching maximum height")
	var orbit := current.get_node("Orbit") as Node3D
	var camera := current.get_node("Orbit/Arm/Camera") as Camera3D
	var arm := current.get_node("Orbit/Arm") as SpringArm3D
	var tall := float(current.snapshot().giant_height)
	_check(camera.far >= 2500.0 and arm.spring_length > tall * 1.1
			and orbit.global_position.y - giant.global_position.y > tall * 0.40
			and camera.near >= 0.09,
			"a 500 m giant places the third-person camera outside its body with a map-scaled far plane")
	current.queue_free()
	await process_frame


func _find_target_at(targets: Node, at: Vector3) -> Node3D:
	for target: Node3D in targets.get_children():
		if target.position.is_equal_approx(at):
			return target
	return null


func _check_footprint_pool(effects: Node) -> void:
	# Exercise pool saturation without waiting for more than 72 actual animated strides.
	for index in 90:
		effects.footfall_effect(Vector3(180.0 + index * 2.0, 0.0, -130.0),
				0.4, Vector2(0.5, 1.0), index % 2 == 0, 12.0, false)
	var prints: Array = effects.footprint_debug()
	var newest := prints.any(func(imprint: Dictionary) -> bool:
		return is_equal_approx(float(imprint.position.x), 358.0))
	_check(prints.size() == 72 and newest and effects.get_node("Footprints").get_child_count() == 72,
			"The footprint pool reuses its oldest slot at capacity")
	await _ticks(620)
	prints = effects.footprint_debug()
	_check(prints.any(func(imprint: Dictionary) -> bool:
		return imprint.position.z == -130.0 and float(imprint.opacity) < 0.75),
			"Older impressions visibly fade before their pool slots expire")
	await _ticks(150)
	var synthetic_remains: bool = effects.footprint_debug().any(func(imprint: Dictionary) -> bool:
		return imprint.position.z == -130.0)
	_check(not synthetic_remains and effects.get_node("Footprints").get_child_count() == 72,
			"Expired impressions become reusable without growing the pool")


func _test_building(parent: Node, at: Vector3, style := "") -> Node3D:
	var target := Node3D.new()
	target.set_script(preload("res://scenes/damageable.gd"))
	target.kind = "building"
	target.procedural_style = style
	target.footprint = Vector3(3.0, 5.0, 3.0)
	target.position = at
	parent.add_child(target)
	return target


func _expanded_harbor() -> void:
	_game.start_mode(true)
	var current := _round()
	var giant := _actor(1)
	var district := current.get_node("District")
	await _ticks(4)

	var ground: MeshInstance3D = district.get_node("Ground/Surface")
	var gsize: Vector3 = (ground.mesh as BoxMesh).size
	_check(gsize.x * gsize.z >= 448.0 * 448.0 * 10.0, "district land area expands to ten times the previous harbor")
	_check(district.get_node("Boundary/East").position.x >= 700.0, "play boundary opens out to the expanded harbor")

	var targets := district.get_node("Targets")
	var styles := {}
	var total_buildings := 0
	for t in targets.get_children():
		if t.kind == "building":
			total_buildings += 1
			var tag: String = t.procedural_style if t.procedural_style != "" else "breakwater_glb"
			styles[tag] = styles.get(tag, 0) + 1
	_check(total_buildings >= 1000 and current.snapshot().total_buildings == total_buildings,
			"expanded harbor populates over 1000 destructible buildings and reports the live total")
	_check(styles.size() >= 5 and district.has_node("Scenery") and district.get_node("Scenery").get_child_count() > 20,
			"expanded harbor mixes multiple building styles, landmarks, parks, cranes and ships")
	var cheap := true
	for name in [&"DockPress3", &"Tidewater3", &"MarineWorks3"]:
		var model := targets.get_node("%s/IntactModel" % name) as Node3D
		var tris := _model_tris(model)
		cheap = cheap and model.has_node("KitModel") and tris > 0 and tris <= 4000
	_check(cheap, "the three historic blocks now use the low-face Kenney kit models")
	_check(district.get_node("Lots").get_child_count() < 500,
			"district lot pads are batched into fewer render nodes")
	var batches := district.get_node("BuildingBatches")
	var ruins := batches.get_node("Ruins") as MultiMeshInstance3D
	_check(DistrictBatches.HIDDEN_TRANSFORM.basis.get_scale() == Vector3.ZERO
			and ruins.multimesh.instance_count == 0,
			"hidden building slots collapse to zero scale and an empty ruin layer has no instance")
	batches.update_for_camera(Vector3(gsize.x, 0.0, gsize.z))
	var detail_layers := batches.find_children("Near_*", "MultiMeshInstance3D", false, false)
	_check(not detail_layers.is_empty() and detail_layers.all(
			func(layer: MultiMeshInstance3D) -> bool: return layer.multimesh.instance_count == 0),
			"detail layers have no placeholder instances when the camera moves out of range")
	batches.update_for_camera(root.get_camera_3d().global_position)
	_check(batches.stats().near_live > 0, "detail layers refill when the camera returns")
	# Every building is visible across the whole map now, so a far demolition still updates
	# collision and the ruin layer but skips the hand-built collapse model nobody can see.
	var far_target: Node3D = null
	for candidate: Node3D in targets.get_children():
		if candidate.get("batched") and candidate.position.length() > 520.0:
			far_target = candidate
			break
	_check(far_target != null, "the expanded harbor batches buildings out to the far edge")
	if far_target != null:
		far_target.strike(true)
		_check(far_target.has_node("RuinBody") and not far_target.has_node("CollapseModel")
				and not far_target.has_node("CollapseDust"),
				"far batched demolition updates collision without building a collapse model")
	var radar := targets.get_node("HarborRadarTower") as Node3D
	radar.strike(true)
	_check(radar.has_node("RuinBody"), "a landmark demolition still settles into rubble collision")

	# Traverse far beyond the original +/-48m limits and destroy the coastal lighthouse landmark.
	var lighthouse := targets.get_node("HarborLighthouse") as Node3D
	var lh_blocker: StaticBody3D = lighthouse.get_node("BlockingBody")
	_check(lighthouse.visible and lh_blocker.collision_layer == BUILDING_LAYER,
			"far buildings stay visible while their collision stays active")
	giant.position = lighthouse.position + Vector3(0.0, 0.03, lighthouse.footprint.z * 0.5 + 7.05)
	giant.rotation = Vector3.ZERO
	var orbit: Node3D = current.get_node("Orbit")
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(16)
	_check(giant.position.x > 690.0 and giant.position.z < -680.0 and lighthouse.visible,
			"new outer districts are walkable and become visible when approached")
	await FootfallFixture.sit_building(current, lighthouse, 0.0)
	await FootfallFixture.sit_building(current, lighthouse, 0.0, -1.0, false)
	_check(lh_blocker.collision_layer == 0 and lighthouse.has_node("CollapseModel") and lighthouse.has_node("RuinBody")
			and current.snapshot().destroyed == 1,
			"outer procedural landmark collapses and counts toward demolition")
	await _ticks(175)
	_check(lighthouse.has_node("RuinModel") and lighthouse.has_node("RuinBody") and not lighthouse.has_node("CollapseModel"),
			"procedural landmark settles into walkable rubble with static collision")
	giant.position = radar.position + Vector3(0.0, 0.03, 16.0)
	await _ticks(16)
	_check(radar.visible and radar.has_node("RuinModel"),
			"approaching an offscreen demolition reveals its final ruin")
	_game.restart()
	await _ticks(4)
	_check(_round().has_node("District/Targets/HarborLighthouse/IntactModel") and _round().snapshot().destroyed == 0,
			"restart restores outer expanded landmarks as well as the core district")
	_game.show_menu()


## Triangles under a model subtree, so tests can bound a kit building's cost.
func _model_tris(model: Node) -> int:
	var total := 0
	if model == null:
		return total
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := (child as MeshInstance3D).mesh
		if mesh == null:
			continue
		for surface in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface)
			var index = arrays[Mesh.ARRAY_INDEX]
			total += (index.size() if index != null else arrays[Mesh.ARRAY_VERTEX].size()) / 3
	return total


func _check_collapse_pause(building: Node, blocker: StaticBody3D) -> void:
	var model := building.get_node_or_null("CollapseModel") as Node3D
	if model == null:
		_check(false, "a visible historic building plays its low-poly collapse")
		return
	var tris := _model_tris(model)
	_check(tris > 0 and tris <= 4000 and model.position.y < 0.0
			and not building.has_node("IntactModel") and building.has_node("RuinBody")
			and blocker.collision_layer == 0,
			"demolition immediately enables rubble collision for other actors while the low-poly building collapses")
	_game.pause()
	var paused_at := model.transform
	await _ticks(45)
	_check(model.transform.is_equal_approx(paused_at), "pause freezes collapse playback")
	_game.resume()
	await _ticks(30)
	_check(model.position.y < paused_at.origin.y - 0.1, "low-poly collapse continues after resuming")
	var frames := 0
	while frames < 220 and not building.has_node("RuinModel"):
		await physics_frame
		frames += 1
	var ruins := building.get_node_or_null("RuinModel") as Node3D
	_check(ruins != null and frames < 220 and not building.has_node("CollapseModel"),
			"collapse settles into a static low-poly ruin")
	var rubble_mesh := (ruins.get_child(0) as MeshInstance3D).mesh as ArrayMesh if ruins else null
	_check(rubble_mesh != null and rubble_mesh.get_surface_count() == 1,
			"historic rubble renders with one surface over the original collision heightmap")


func _human_walks_rubble() -> void:
	_game.start_mode(false)
	var building := _round().get_node("District/Targets/DockPress1") as Node3D
	var human := _actor(0)
	human.global_position = building.global_position + Vector3(0.0, 0.04, 8.0)
	await _ticks(14)
	human.global_position = building.global_position + Vector3.UP * 0.04
	building.strike(true)
	await _ticks(4)
	_check(building.has_node("CollapseModel") and human.is_on_floor() and human.global_position.y > 1.0,
			"rubble lifts a character already inside the lot onto the new surface")
	_check(await _walk_rubble(human, building, 1.0), "human walks up and over the brick rubble")
	_game.show_menu()


func _camera_shake() -> void:
	_game.start_mode(true)
	var current := _round()
	var giant := _actor(1)
	var camera := current.get_node("Orbit/Arm/Camera") as Camera3D
	giant.position = Vector3(0.0, 0.02, 76.0)
	await _ticks(8)
	Input.action_press("move_forward")
	var step_peak := 0.0
	for frame in 70:
		await physics_frame
		step_peak = maxf(step_peak, absf(camera.v_offset))
	Input.action_release("move_forward")
	_check(step_peak > 0.05 and current.snapshot().destroyed == 0,
			"a regular footstep on clear ground shakes the camera")
	await _ticks(140)
	_check(absf(camera.v_offset) < 0.01, "the footstep shake settles once the giant stops")
	_game.show_menu()


func _tall_own_camera_shake() -> void:
	var options: Dictionary = _game.default_mode_settings(1)
	options.merge({"giant_height": 500.0, "giant_max_height": 500.0, "npc_initial": 0,
			"npc_respawn": false, "desk_hazards": false}, true)
	_game.save_settings(_game.get_settings(false), options)
	for view: int in [0, 1, 2]:
		_game.start_mode(true)
		var current := _round()
		var giant := _actor(1)
		FootfallFixture.face(current, giant, 0.0)
		giant.position = Vector3(0.0, 0.02, 410.0)
		current.set_camera_view(view)
		await _ticks(8)
		var landed := await FootfallFixture.land(current, Callable(), 600)
		var camera := root.get_camera_3d()
		var distance := camera.global_position.distance_to(landed.get("last_footfall_center", Vector3.INF))
		var shake := absf(camera.rotation.x) if view == 2 else absf(camera.v_offset) / camera.position.z
		# The full-body camera has to prove self feedback beyond the external falloff.
		_check(not landed.is_empty() and is_equal_approx(current.snapshot().giant_height, 500.0)
				and (view != 0 or distance > 585.2) and shake > 0.005,
				"500 m giant feels its own step in view %d (%.1f m, %.4f)"
				% [view, distance, shake])
		_game.show_menu()


func _palm_sandbox_layout() -> void:
	var sky := _game.get_node("Skybox")
	var bedroom := sky.get_bedroom() as Node3D
	var anchor: Node3D = bedroom.sandbox_anchor
	var original_scale := bedroom.scale.x
	var preview := _game.get_node("MapSlot/District")
	var original_side := float(preview.map_side)
	var original_targets := preview.get_node("Targets").get_child_count()
	var options: Dictionary = _game.default_mode_settings(1)
	options.merge({"npc_initial": 0, "npc_respawn": false, "desk_hazards": false}, true)
	_game.save_settings(_game.get_settings(false), options)
	_game.start_mode(true)
	await _ticks(4)
	var current := _round()
	var district := current.get_node("District")
	var frame := district.get_node("SandboxFrame") as MeshInstance3D
	var tray := bedroom._transform_aabb(
			bedroom.global_transform.affine_inverse() * frame.global_transform, frame.get_aabb()) as AABB
	var desk := bedroom._subtree_aabb(
			bedroom.get_node("Furniture/Desk"), Transform3D.IDENTITY) as AABB
	_check(is_equal_approx(float(district.map_side) / bedroom.scale.x, 0.10)
			and is_equal_approx(float(district.map_side), original_side)
			and district.get_node("Targets").get_child_count() == original_targets,
			"palm sandbox fits the existing harbour and every building into a 10 cm inner tray")
	_check(anchor.global_position.length() < 0.05
			and is_equal_approx(tray.position.y, desk.end.y)
			and tray.end.z < desk.end.z and tray.get_center().z >= 0.29
			and Vector3.ONE.is_equal_approx(bedroom.get_desk_lamp_light().global_basis.get_scale()),
			"palm tray moves toward the seated giant and sits flush within the desk with unit-scale lights")

	var giant := _actor(1)
	var camera := root.get_camera_3d()
	var observer: Node = sky.get_yumeka()
	var face_visible := true
	for height: float in [25.2, 500.0]:
		current.debug_resize_giant(0, height)
		for x: float in [-640.0, 0.0, 640.0]:
			for z: float in [-640.0, 0.0, 640.0]:
				giant.position = Vector3(x, 0.02, z)
				await physics_frame
				current.look(Vector2(0.0, -1200.0))
				if observer != null and observer.debug_is_mounted():
					var face: Vector3 = (observer.debug_bone_world_pos("Eye_L")
							+ observer.debug_bone_world_pos("Eye_R")) * 0.5
					face_visible = face_visible and camera.is_position_in_frustum(face)
	if observer != null and observer.debug_is_mounted():
		_check(face_visible, "looking straight up frames the seated giant from the centre and outer districts")

	current.zoom_by(100.0)
	await _ticks(60)
	_check(-camera.global_basis.z.y > 0.99 and camera.global_position.y > 1.0
			and camera.position.z > 1800.0,
			"at maximum zoom the full-body camera still looks overhead from above the street")
	_game.show_menu()
	_check(is_equal_approx(bedroom.scale.x, original_scale) and is_zero_approx(anchor.position.z),
			"the menu restores its tabletop layout after the palm sandbox")


func _own_camera_shake_toggle() -> void:
	var options: Dictionary = _game.default_mode_settings(1)
	options.merge({"giant_count": 2, "npc_initial": 0, "npc_respawn": false}, true)
	_game.save_settings(_game.get_settings(false), options)
	_game.start_mode(true)
	var current := _round()
	var giant := _actor(1)
	var rival: CharacterBody3D = current.get_node("OtherGiants/Giant2")
	var camera: Camera3D = root.get_camera_3d()
	giant.position = Vector3(0.0, 0.02, 76.0)
	rival.position = Vector3(460.0, 0.02, -460.0)
	await _ticks(8)
	Input.action_press("move_forward")
	for frame in 100:
		await physics_frame
		if absf(camera.v_offset) > 0.08:
			break
	Input.action_release("move_forward")
	var had_own_shake := absf(camera.v_offset) > 0.08
	_game.pause()
	var ui := _game.get_node("Interface")
	(ui.find_child("PauseSettings", true, false) as BaseButton).pressed.emit()
	(ui.find_child("SettingsPageGraphics", true, false) as BaseButton).pressed.emit()
	var toggle := ui.find_child("own_camera_shake", true, false) as CheckButton
	_check(toggle.is_visible_in_tree() and toggle.button_pressed and had_own_shake,
			"Own camera shake is enabled by default on the graphics page")
	toggle.button_pressed = false
	(ui.find_child("SaveSettings", true, false) as BaseButton).pressed.emit()
	var config := ConfigFile.new()
	var saved := config.load(_game.settings_path) == OK
	var sandbox: Dictionary = config.get_value("settings", "giant", {})
	_check(saved and sandbox.get("own_camera_shake", true) == false
			and not _game.get_mode_settings(2).own_camera_shake and not _game.get_settings(false).own_camera_shake
			and is_zero_approx(camera.v_offset),
			"Saving turns off own shake immediately and applies to every mode profile")
	_game.resume()
	await _ticks(90)
	Input.action_press("move_forward")
	var own_peak := 0.0
	for frame in 64:
		await physics_frame
		own_peak = maxf(own_peak, absf(camera.v_offset))
	Input.action_release("move_forward")
	await _ticks(70)
	_check(own_peak < 0.003, "Own footfalls stop shaking the camera while the switch is off")

	giant.position = Vector3(0.0, 0.02, -2.0)
	rival.position = Vector3(0.0, 0.02, -24.0)
	var nearby_peak := 0.0
	for frame in 180:
		await physics_frame
		nearby_peak = maxf(nearby_peak, absf(camera.v_offset))
	_check(nearby_peak > 0.015, "Other giants still shake the camera while own shake is off")
	_game.show_menu()


func _settings_modes() -> void:
	var ui := _game.get_node("Interface")
	var panel := ui.find_child("GameplaySettings", true, false) as Control
	(ui.find_child("MenuSettings", true, false) as BaseButton).pressed.emit()
	_check(panel.visible, "the title menu opens the gameplay settings")
	var speed := panel.find_child("giant_speed", true, false) as SpinBox
	var height := panel.find_child("giant_height", true, false) as SpinBox
	var max_height := panel.find_child("giant_max_height", true, false) as SpinBox
	var giant_count := panel.find_child("giant_count", true, false) as SpinBox
	var initial := panel.find_child("npc_initial", true, false) as SpinBox
	var respawn := panel.find_child("NpcRespawn", true, false) as CheckButton
	var interval := panel.find_child("npc_interval", true, false) as SpinBox
	var draw_distance := panel.find_child("view_distance", true, false) as SpinBox
	var shake := panel.find_child("shake_strength", true, false) as SpinBox
	var save := panel.find_child("SaveSettings", true, false) as BaseButton
	var giant_tab := panel.find_child("GiantSettingsTab", true, false) as Button
	var human_tab := panel.find_child("HumanSettingsTab", true, false) as Button
	_check(is_equal_approx(speed.value, 1.0) and is_equal_approx(height.value, 25.2)
			and max_height.value == 500 and giant_count.value == 1
			and initial.value == 6 and interval.value == 8 and draw_distance.value == 300,
			"settings controls show the current defaults")
	_check([speed, height, max_height, giant_count, initial, interval, draw_distance, shake].all(
			func(field: SpinBox): return field.allow_lesser and field.allow_greater),
			"gameplay settings accept typed numbers outside the arrow range")
	max_height.value = 20
	_check(is_equal_approx(height.value, 25.2), "editing the growth cap leaves initial height untouched")
	max_height.value = 68
	speed.value = 1.5
	height.value = 45
	initial.value = 3
	interval.value = 2
	respawn.button_pressed = false
	draw_distance.value = 430
	shake.value = 0
	_check(not interval.is_visible_in_tree(), "the spawn interval control is hidden when NPC spawning is off")
	giant_tab.button_pressed = true
	giant_tab.pressed.emit()
	speed.value = 2.0
	height.value = 45
	initial.value = 0
	interval.value = 2
	save.pressed.emit()
	_check(not panel.visible and _game.get_settings(false).npc_initial == 3
			and _game.get_settings(true).npc_initial == 0,
			"the two mode profiles are saved independently")

	_game.start_mode(false)
	var current := _round()
	var camera := current.get_node("Orbit/Arm/Camera") as Camera3D
	var crowd := current.get_node("Civilians")
	await _ticks(160)
	_check(is_equal_approx(current.snapshot().giant_height, 45.0) and crowd.get_child_count() == 3
			and is_equal_approx(float(_actor(1).pace), 1.5) and camera.far >= 2500.0,
			"human mode applies speed, initial height, visibility and a disabled spawn timer")
	var env: Environment = (_game.get_node("Atmosphere") as WorldEnvironment).environment
	_check(env.fog_enabled and env.fog_mode == Environment.FOG_MODE_DEPTH
			and env.fog_depth_begin > 400.0 and env.fog_depth_begin < env.fog_depth_end
			and env.fog_depth_end > 700.0,
			"depth fog sits at the island rim so every district stays readable")
	_key(KEY_ESCAPE)
	(ui.find_child("PauseSettings", true, false) as BaseButton).pressed.emit()
	_check(panel.visible and human_tab.button_pressed and paused,
			"the pause settings open on the current mode while the game stays paused")
	respawn.button_pressed = true
	height.value = 60
	max_height.value = 80
	giant_count.value = 2
	initial.value = 4
	draw_distance.value = 260
	save.pressed.emit()
	_check(paused and not panel.visible
			and is_equal_approx(float(camera.get_meta("district_draw_distance")), 260.0)
			and env.fog_depth_begin < 140.0 and env.fog_depth_end < 260.0 and env.fog_depth_end > 220.0
			and is_equal_approx(current.snapshot().giant_height, 45.0) and crowd.get_child_count() == 3
			and current.snapshot().giant_max_height == 68 and current.snapshot().giant_count == 1,
			"visibility and boundary fog update immediately while starting height and population wait for restart")
	_game.resume()
	await _ticks(165)
	_check(crowd.get_child_count() >= 4, "reenabling NPC spawning takes effect in the current round")
	_game.restart()
	_check(is_equal_approx(_round().snapshot().giant_height, 60.0)
			and _round().get_node("Civilians").get_child_count() == 4
			and _round().snapshot().giant_max_height == 80 and _round().snapshot().giant_count == 2,
			"restarting applies the new giant height, cap, count and NPC population")

	_game.start_mode(true)
	current = _round()
	var giant := _actor(1)
	giant.position = Vector3(0.0, 0.02, 74.0)
	crowd = current.get_node("Civilians")
	camera = current.get_node("Orbit/Arm/Camera")
	_check(crowd.get_child_count() == 0 and is_equal_approx(current.snapshot().giant_height, 45.0)
			and is_equal_approx(float(camera.get_meta("district_draw_distance")), 260.0),
			"giant mode keeps its own gameplay profile but shares display settings")
	await _ticks(5)
	var first_z := giant.position.z
	Input.action_press("move_forward")
	await _ticks(12)
	Input.action_release("move_forward")
	_check(first_z - giant.position.z > 2.5, "the speed multiplier increases sandbox movement speed")
	await _ticks(150)
	_check(crowd.get_child_count() > 0, "a sandbox set to zero starting NPCs can still spawn new ones")
	_key(KEY_ESCAPE)
	(ui.find_child("PauseSettings", true, false) as BaseButton).pressed.emit()
	_check(panel.visible and giant_tab.button_pressed, "sandbox pause preselects the giant profile")
	_key(KEY_ESCAPE)
	_check(not panel.visible and paused, "Escape closes settings back to pause")
	_game.show_menu()
	_check(env.fog_depth_end > 400.0 and env.fog_depth_end < 470.0,
			"returning to the title menu restores the overview fog distance")

	var reloaded := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	reloaded.settings_path = _game.settings_path
	root.add_child(reloaded)
	_check(reloaded.get_settings(false).npc_initial == 4 and reloaded.get_settings(true).giant_speed == 2.0,
			"both settings profiles reload from disk")
	_check(reloaded.get_settings(false).giant_count == 2 and reloaded.get_settings(false).giant_max_height == 80
			and reloaded.get_settings(true).giant_count == 1 and reloaded.get_settings(true).giant_max_height == 500,
			"the two profiles persist the giant counts and growth caps separately")
	reloaded.queue_free()
	await process_frame

	var legacy_path := "%s.legacy" % _game.settings_path
	var legacy := ConfigFile.new()
	legacy.set_value("settings", "human", {"giant_height": 125.0, "giant_speed": 2.2, "npc_initial": 7})
	legacy.save(legacy_path)
	reloaded = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	reloaded.settings_path = legacy_path
	root.add_child(reloaded)
	var old_options: Dictionary = reloaded.get_settings(false)
	_check(old_options.giant_height == 125 and is_equal_approx(old_options.giant_speed, 2.2)
			and old_options.npc_initial == 7 and old_options.giant_count == 1 and old_options.giant_max_height == 500
			and old_options.map_side == 1418,
			"old settings retain saved values and receive defaults for newly added options")
	reloaded.queue_free()
	DirAccess.remove_absolute(legacy_path)
	await process_frame


func _map_size_settings() -> void:
	var ui := _game.get_node("Interface")
	var opener := ui.find_child("MenuSettings", true, false) as BaseButton
	opener.pressed.emit()
	var panel := ui.find_child("GameplaySettings", true, false) as Control
	var side := panel.find_child("map_side", true, false) as SpinBox
	var save := panel.find_child("SaveSettings", true, false) as BaseButton
	_check(side.is_visible_in_tree() and side.value == 1418, "Map settings show the default 1,418 m side")
	side.value = 0
	save.pressed.emit()
	_check(panel.visible and _game.invalid_setting() == "map_side", "A zero map side keeps the settings panel open")
	var sizes := [24, 72, 1900, 541]
	var tabs := ["HumanSettingsTab", "GiantSettingsTab", "GrowthSettingsTab", "BrawlSettingsTab"]
	for mode in tabs.size():
		(panel.find_child(tabs[mode], true, false) as BaseButton).pressed.emit()
		side.value = sizes[mode]
	save.pressed.emit()
	_check(not panel.visible, "The four map sizes save through their mode tabs")
	var reloaded: Node = load("res://scenes/main.tscn").instantiate()
	reloaded.settings_path = _game.settings_path
	root.add_child(reloaded)
	var all_profiles_reload := true
	for mode in sizes.size():
		all_profiles_reload = all_profiles_reload and reloaded.get_mode_settings(mode).map_side == sizes[mode]
	reloaded.queue_free()
	await process_frame
	_check(all_profiles_reload, "All four custom map sizes reload from disk independently")

	var counts: Array[int] = []
	var starts: Array[Callable] = [
		_game.start_mode.bind(false), _game.start_mode.bind(true),
		_game.start_growth, _game.start_brawl,
	]
	for mode in starts.size():
		starts[mode].call()
		var current := _round()
		var district := current.get_node("District")
		var extent: float = 7.8 if mode == 0 else sizes[mode] * 0.5 - 5.0
		counts.append(district.get_node("Targets").get_child_count())
		var inside := true
		var road_extent := 0.0
		for point: Vector3 in district.spawn_points:
			var distance := maxf(absf(point.x), absf(point.z))
			inside = inside and distance < extent
			road_extent = maxf(road_extent, distance)
		var ground: BoxShape3D = district.get_node("Ground/Collision").shape
		var land: BoxMesh = district.get_node("Ground/Surface").mesh
		var east: CollisionShape3D = district.get_node("Boundary/East")
		var north: CollisionShape3D = district.get_node("Boundary/North")
		_check(land.size.x == sizes[mode] and land.size.z == sizes[mode]
				and ground.size == land.size
				and is_equal_approx(east.position.x - east.shape.size.z * 0.5, extent)
				and is_equal_approx(-north.position.z - north.shape.size.z * 0.5, extent)
				and inside and road_extent > extent - 60.0,
				"Mode %d generates a %d m map with matching ground, walls and spawn roads" % [mode, sizes[mode]])
		await _ticks(3)
		var space := root.world_3d.direct_space_state
		var wall_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
				Vector3(extent - 1, 4, 0), Vector3(extent + 3, 4, 0), 2))
		var inside_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
				Vector3(extent + 2, 3, 0), Vector3(extent + 2, -3, 0), 1))
		var outside_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
				Vector3(extent + 6, 3, 0), Vector3(extent + 6, -3, 0), 1))
		_check(not wall_hit.is_empty() and not inside_hit.is_empty() and outside_hit.is_empty(),
				"Mode %d collides with the wall and terrain at the configured edge" % mode)
	_check(counts[0] < counts[1] and counts[1] < counts[3] and counts[3] < counts[2],
			"Changing map size regenerates the number of city blocks")
	_game.pause()
	(ui.find_child("PauseSettings", true, false) as BaseButton).pressed.emit()
	side.value = 631
	save.pressed.emit()
	_check(_round().get_node("District").map_side == 541,
			"Saving in pause keeps the current map size until restart")
	_game.restart()
	_check(_round().get_node("District/Ground/Collision").shape.size.x == 631,
			"Restart builds the current mode with its new map size")
	_game.show_menu()
	_check(_game.get_node("MapSlot/District/Ground/Surface").mesh.size.x == 1418,
			"Resizing the gameplay map preserves the shared terrain used by the menu")
	await process_frame


func _smallest_map() -> void:
	var options: Array[Dictionary] = []
	for mode in 4:
		var profile: Dictionary = _game.default_mode_settings(mode)
		profile.map_side = 48
		options.append(profile)
	options[1].giant_count = 2
	_game.save_all_mode_settings(options[0], options[1], options[2], options[3])
	var starts: Array[Callable] = [
		_game.start_mode.bind(false), _game.start_mode.bind(true),
		_game.start_growth, _game.start_brawl,
	]
	for mode in starts.size():
		starts[mode].call()
		await _ticks(4)
		var current := _round()
		var district := current.get_node("District")
		var player: CharacterBody3D = current.get_node("Human" if mode == 0 else "Giant")
		var targets := district.get_node("Targets")
		var inside := player.position.abs().x < 19.0 and player.position.abs().z < 19.0
		for target: Node3D in targets.get_children():
			var reach := Vector2(target.footprint.x, target.footprint.z) * 0.5
			inside = inside and absf(target.position.x) + reach.x < 19.0
			inside = inside and absf(target.position.z) + reach.y < 19.0
		var giant_count: int = current.snapshot().giant_count
		_check(_game.get_screen() == "playing" and player.is_on_floor() and inside
				and targets.get_child_count() == 4 and giant_count == (1 if mode == 0 else 2),
				"Mode %d starts at %s with %d giants and %d buildings on a 48 m map" %
				[mode, player.position, giant_count, targets.get_child_count()])
		if mode == 0:
			var exit: Marker3D = district.get_node("Evacuation")
			_check(exit.position == Vector3(15, 0, 0) and current.snapshot().exit_distance > 2.7,
					"Compact Evacuation starts away from the accessible east-street exit")
			player.position = exit.position + Vector3(-4.0, 0.02, 0)
			await _walk_axis(player, "move_forward", Vector3.RIGHT, 13.0, 50)
			await _ticks(3)
			_check(_game.get_screen() == "evacuated", "The player can reach the exit and finish a 48 m round")
		if mode == 2:
			_check(current.get_node("Coins").get_child_count() > 0, "Growth still places coins on the compact map")
	options[2].map_side = 1
	_check(_game.save_all_mode_settings(options[0], options[1], options[2], options[3]),
			"A one-metre side saves as a valid positive integer")
	_game.start_growth()
	await _ticks(4)
	var tiny := _round().get_node("District")
	var tiny_player := _round().get_node("Giant") as CharacterBody3D
	_check(tiny.get_node("Ground/Collision").shape.size.x == 1.0 and tiny.play_edge > 0.0
			and tiny.get_node("Targets").get_child_count() == 0
			and tiny.get_node("Lots").get_child_count() == 0 and tiny_player.is_on_floor(),
			"The one-metre map has valid ground and walls and omits tiles and buildings that cannot fit")
	_game.show_menu()
	await process_frame


func _open_numeric_settings() -> void:
	var ui := _game.get_node("Interface")
	(ui.find_child("MenuSettings", true, false) as BaseButton).pressed.emit()
	var panel := ui.find_child("GameplaySettings", true, false) as Control
	(panel.find_child("GiantSettingsTab", true, false) as BaseButton).pressed.emit()
	var save := panel.find_child("SaveSettings", true, false) as BaseButton
	var speed := panel.find_child("giant_speed", true, false) as SpinBox
	speed.value = -1.0
	save.pressed.emit()
	_check(panel.visible and _game.invalid_setting() == "giant_speed", "an invalid speed identifies the field and keeps settings open")
	var entries := {
		"giant_speed": "0.025", "giant_height": "240.125", "giant_max_height": "2200.5",
		"giant_count": "12", "npc_initial": "110", "npc_interval": "0.125",
		"view_distance": "1750.25", "shake_strength": "450.5",
	}
	for key in entries:
		var field := panel.find_child(key, true, false) as SpinBox
		field.get_line_edit().text = entries[key]
		field.apply()
	save.pressed.emit()
	var reloaded := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	reloaded.settings_path = _game.settings_path
	root.add_child(reloaded)
	var settings: Dictionary = reloaded.get_settings(true)
	_check(not panel.visible and is_equal_approx(settings.giant_speed, 0.025)
			and is_equal_approx(settings.giant_height, 240.125) and settings.giant_max_height == 2200.5
			and settings.giant_count == 12 and settings.npc_initial == 110 and settings.npc_interval == 0.125
			and settings.view_distance == 1750.25 and is_equal_approx(settings.shake_strength, 4.505),
			"typed values outside the former limits survive a save and reload without rounding")
	reloaded.queue_free()
	await process_frame

	var options: Dictionary = _game.default_mode_settings(1)
	options.merge({"giant_height": 240.125, "giant_max_height": 150.0, "npc_initial": 0}, true)
	_game.save_settings(_game.get_settings(false), options)
	_game.start_mode(true)
	var giant := _actor(1)
	var capsule: CapsuleShape3D = giant.get_node("Collision").shape
	_check(is_equal_approx(_round().snapshot().giant_height, 240.125) and is_equal_approx(capsule.height, 240.125)
			and _round().snapshot().giant_max_height == 150.0,
			"a starting height above the chosen growth cap still controls the model and collision")
	_game.show_menu()


func _multiple_giants() -> void:
	var options: Dictionary = _game.default_settings()
	options.giant_count = 2
	options.giant_max_height = 26.5
	options.npc_initial = 0
	options.npc_respawn = false
	_game.save_settings(options, options)
	_game.start_mode(false)
	var current := _round()
	var first := _actor(1)
	var second := current.get_node("OtherGiants/Giant2") as CharacterBody3D
	var human := _actor(0)
	human.position = Vector3(0.0, 0.02, -684.0)
	first.position = human.position + Vector3.BACK * 7.18
	first.rotation = Vector3.ZERO
	second.position = human.position + Vector3.RIGHT * 7.18
	second.rotation = Vector3(0.0, PI * 0.5, 0.0)
	await _ticks(4)
	var both_started := false
	var first_landed := false
	var second_landed := false
	for frame in 150:
		var one := FootfallFixture.actor(current)
		var two := FootfallFixture.actor(current, 1)
		both_started = both_started or (one.footfall_pending and two.footfall_pending)
		first_landed = first_landed or int(one.footfall_count) > 0
		second_landed = second_landed or int(two.footfall_count) > 0
		if first_landed and second_landed:
			break
		await physics_frame
	_check(both_started, "Both AI giants independently commit to their heavy swing")
	_check(first_landed and second_landed, "Both AI giants register their own physical landing")

	_game.start_mode(true)
	current = _round()
	first = _actor(1)
	second = current.get_node("OtherGiants/Giant2") as CharacterBody3D
	second.position = Vector3(0.0, 0.02, -684.0)
	var second_start := second.position
	var target := current.get_node("District/Targets/Tidewater1") as Node3D
	await FootfallFixture.punch_building(current, target)
	if target.get_node("BlockingBody").collision_layer != 0:
		await FootfallFixture.punch_building(current, target)
	await _wait_growth(current, 1)
	var data: Dictionary = current.snapshot()
	_check(data.giant_destroyed == 1 and data.giant_at_max_height
			and is_equal_approx(data.giant_height, 26.5) and _giant_has_scale(first, 26.5 / 25.2),
			"the sandbox giant grows to its custom cap with matching model and collision")
	_check(_giant_has_scale(second, 1.0) and second.position.distance_to(second_start) > 1.0,
			"the other sandbox giant moves on its own and does not share the player's growth")

	options.merge({"giant_count": 8, "giant_height": 200.0, "giant_max_height": 2000.0,
			"npc_initial": 100, "view_distance": 1600.0}, true)
	_game.save_settings(options, options)
	_game.restart()
	current = _round()
	var giants: Array[Node] = current.get_node("OtherGiants").get_children()
	giants.push_front(_actor(1))
	var separated := true
	for i in giants.size():
		for j in range(i + 1, giants.size()):
			separated = separated and giants[i].position.distance_to(giants[j].position) > 2 * 2.9 * 200.0 / 25.2
	_check(giants.size() == 8 and separated and giants.all(func(giant: CharacterBody3D) -> bool:
		return _giant_has_scale(giant, 200.0 / 25.2)
	), "eight maximum-height starting giants spawn apart with their own capsules")
	_check(current.get_node("Civilians").get_child_count() == 100
			and current.snapshot().giant_max_height == 2000
			and is_equal_approx(float(current.get_node("Orbit/Arm/Camera").get_meta(
			"district_draw_distance")), 1600.0),
			"the larger NPC count, growth cap and draw distance apply to a real round")

	options.merge({"giant_count": 1, "giant_height": 9.0, "giant_max_height": 1.0,
			"npc_initial": 0, "view_distance": 40.0, "giant_speed": 0.1}, true)
	_game.save_settings(options, options)
	_game.restart()
	current = _round()
	_check(is_equal_approx(current.snapshot().giant_height, 9.0) and current.snapshot().giant_at_max_height
			and _giant_has_scale(_actor(1), 9.0 / 25.2)
			and is_equal_approx(float(current.get_node("Orbit/Arm/Camera").get_meta(
			"district_draw_distance")), 40.0),
			"the configured cap blocks further growth while a larger starting capsule keeps its height")
	_game.show_menu()


func _ai_smooth_turning() -> void:
	var options: Dictionary = _game.default_settings()
	options.giant_count = 1
	options.npc_initial = 0
	options.npc_respawn = false
	options.giant_speed = 4.0
	_game.save_settings(options, options)
	_game.start_mode(false)
	var current := _round()
	var giant := _actor(1)
	var human := _actor(0)
	human.position = Vector3(0.0, 0.02, -684.0)
	giant.position = human.position + Vector3.BACK * 7.18
	giant.rotation = Vector3(0.0, PI, 0.0)
	await _ticks(1)
	var prev_yaw := giant.rotation.y
	var early_rear_strike := false
	var saw_standing_pivot := false
	var max_yaw_step := 0.0
	var start_health: float = float(current.snapshot().health)
	for i in range(180):
		await _ticks(1)
		var step := absf(angle_difference(prev_yaw, giant.rotation.y))
		prev_yaw = giant.rotation.y
		max_yaw_step = maxf(max_yaw_step, step)
		if i < 20 and float(current.snapshot().health) < start_health:
			early_rear_strike = true
		var diag: Dictionary = giant.get_turn_telemetry()
		if diag.get("mode", "") == "standing_turn":
			saw_standing_pivot = true
	_check(not early_rear_strike,
			"an AI giant facing away does not strike a human behind her while arcing around")
	_check(not saw_standing_pivot and absf(angle_difference(PI, giant.rotation.y)) > 0.6,
			"an AI giant arcs forward cleanly toward a target behind her without stationary tank turning")
	_check(max_yaw_step < 0.14,
			"4x speed AI turning stays bounded per frame without whip-snapping (max=%.3f)" % max_yaw_step)
	_game.show_menu()


func _walk_rubble(actor: CharacterBody3D, building: Node3D, crest: float) -> bool:
	var orbit: Node3D = _round().get_node("Orbit")
	var direction := -building.global_basis.z
	var yaw := atan2(-direction.x, -direction.z)
	_mouse(Vector2(-angle_difference(orbit.rotation.y, yaw) / 0.0028, 0.0))
	actor.rotation = Vector3(0.0, yaw, 0.0)
	actor.global_position = building.to_global(Vector3(0.0, 0.04, 10.5))
	await _ticks(5)
	var climbed := false
	Input.action_press("move_forward")
	for frame in 170:
		climbed = climbed or (actor.is_on_floor() and actor.global_position.y > crest)
		if building.to_local(actor.global_position).z < -1.4:
			break
		await physics_frame
	Input.action_release("move_forward")
	return climbed and building.to_local(actor.global_position).z < -1.4


func _check_giant_walk(giant: CharacterBody3D) -> void:
	var left_swing := false
	var right_swing := false
	var planted_frames := 0
	var previous := _ankle(giant, "L")
	Input.action_press("move_forward")
	for frame in 120:
		await physics_frame
		var left := _ankle(giant, "L")
		var right := _ankle(giant, "R")
		left_swing = left_swing or left.y > right.y + 1.1
		right_swing = right_swing or right.y > left.y + 1.1
		if frame > 18 and left.y < 1.92 and previous.y < 1.92 and left.distance_to(previous) < 0.04:
			planted_frames += 1
		previous = left
	Input.action_release("move_forward")
	_check(left_swing and right_swing, "walking lifts each leg in turn")
	_check(planted_frames > 18, "the support foot stays in place during the walking cycle")


func _desk_hazards_finger_poke() -> void:
	# 1. Setting defaults, mode-scoped UI visibility, and gameplay.cfg persistence.
	var def_ok := true
	for mode in [1, 2, 3]:
		if not bool(_game.default_mode_settings(mode).get("desk_hazards", false)):
			def_ok = false
	var human_opts: Dictionary = _game.default_mode_settings(0)
	var human_omits := not human_opts.has("desk_hazards")
	_check(def_ok and human_omits,
			"desk_hazards defaults true in Sandbox/Growth/Brawl and is excluded from Human Evacuation")

	var ui := _game.get_node("Interface")
	(ui.find_child("MenuSettings", true, false) as BaseButton).pressed.emit()
	await process_frame
	var panel: Control = ui.find_child("GameplaySettings", true, false)
	(panel.find_child("SettingsPageGameplay", true, false) as BaseButton).pressed.emit()
	await process_frame
	var toggle := panel.find_child("desk_hazards", true, false) as CheckButton
	(panel.find_child("HumanSettingsTab", true, false) as BaseButton).pressed.emit()
	await process_frame
	var hidden_in_human := toggle != null and not toggle.is_visible_in_tree()
	(panel.find_child("GiantSettingsTab", true, false) as BaseButton).pressed.emit()
	await process_frame
	var visible_in_sandbox := toggle != null and toggle.is_visible_in_tree() and toggle.button_pressed
	(panel.find_child("GrowthSettingsTab", true, false) as BaseButton).pressed.emit()
	await process_frame
	var visible_in_growth := toggle != null and toggle.is_visible_in_tree() and toggle.button_pressed
	(panel.find_child("BrawlSettingsTab", true, false) as BaseButton).pressed.emit()
	await process_frame
	var visible_in_brawl := toggle != null and toggle.is_visible_in_tree() and toggle.button_pressed
	_check(hidden_in_human and visible_in_sandbox and visible_in_growth and visible_in_brawl,
			"Gameplay settings expose desk_hazards toggle in Sandbox/Growth/Brawl and hide it in Human Evacuation")

	# Toggle OFF for Sandbox, save, verify gameplay.cfg & fresh HarborGame reload.
	(panel.find_child("GiantSettingsTab", true, false) as BaseButton).pressed.emit()
	await process_frame
	toggle.button_pressed = false
	await process_frame
	(panel.find_child("SaveSettings", true, false) as BaseButton).pressed.emit()
	await process_frame
	var cfg := ConfigFile.new()
	var cfg_ok := cfg.load(_game.settings_path) == OK
	var saved_giant: Dictionary = cfg.get_value("settings", "giant", {})
	var saved_growth: Dictionary = cfg.get_value("settings", "growth", {})
	var reloaded: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	reloaded.settings_path = _game.settings_path
	root.add_child(reloaded)
	await process_frame
	var reloaded_giant_off := not bool(reloaded.get_mode_settings(1).get("desk_hazards", true))
	var reloaded_growth_on := bool(reloaded.get_mode_settings(2).get("desk_hazards", false))
	reloaded.queue_free()
	await process_frame
	_check(cfg_ok and saved_giant.get("desk_hazards", true) == false
			and saved_growth.get("desk_hazards", false) == true
			and reloaded_giant_off and reloaded_growth_on,
			"desk_hazards persists per-mode to gameplay.cfg and restores cleanly on reload")

	# 2. Human Evacuation mode never triggers desk hazards even on F8.
	_game.start_mode(false)
	await _ticks(4)
	var human_round := _round()
	var human_haz := human_round.get_node_or_null("DeskHazards")
	_key(KEY_F8)
	await _ticks(3)
	_check(human_haz != null and not bool(human_round.desk_hazards_enabled())
			and not bool(human_haz.debug_state().active),
			"Human Evacuation mode never enables or triggers desk hazards on F8")

	# 3. Sandbox with desk_hazards = false ignores F8; enabling live allows F8 (blocked while paused).
	_game.start_mode(true)
	await _ticks(4)
	var sb_round := _round()
	var sb_haz := sb_round.get_node_or_null("DeskHazards")
	_key(KEY_F8)
	await _ticks(3)
	var blocked_when_off := sb_haz != null and not bool(sb_round.desk_hazards_enabled()) \
			and not bool(sb_haz.debug_state().active)
	# Re-enable live across all modes, then test pause guard on F8.
	var growth_opts: Dictionary = _game.default_mode_settings(2)
	growth_opts["giant_height"] = 25.2
	growth_opts["giant_count"] = 2
	growth_opts["coin_count"] = 0
	growth_opts["desk_hazards"] = true
	_game.save_all_mode_settings(
			_game.default_mode_settings(0), _game.default_mode_settings(1),
			growth_opts, _game.default_mode_settings(3))
	await _ticks(2)
	_key(KEY_ESCAPE)
	await process_frame
	_key(KEY_F8)
	await process_frame
	var blocked_when_paused := paused and not bool(sb_haz.debug_state().active)
	_key(KEY_ESCAPE)
	await _ticks(2)
	_check(blocked_when_off and blocked_when_paused,
			"desk_hazards toggle OFF and pause state both block F8 finger_poke triggers")

	# 4. Growth mode F8 trigger: zero-teleport 5-phase IK arm, smooth gesture blend, AI evasion,
	#    unattackable foreground arm, touchdown destruction, smooth desk return & background restore.
	_game.start_growth()
	await _ticks(6)
	var round := _round()
	var hazards := round.get_node_or_null("DeskHazards")
	var sky: Node = _game.get_node_or_null("Skybox")
	var yumeka: Node = sky.call("get_yumeka") if sky != null and sky.has_method(&"get_yumeka") else null
	var giants_before: int = round.snapshot().giant_count
	var destroyed_before: int = round.snapshot().destroyed

	_key(KEY_F8)
	var s_start: Dictionary = hazards.debug_state()
	var rest_hand_start: Vector3 = s_start.rest_hand_pos
	var start_wrist_err: float = (s_start.wrist_pos as Vector3).distance_to(rest_hand_start)
	var hand_has_no_colliders := _count_collisions_in(hazards) == 0
	var giants_unchanged := int(round.snapshot().giant_count) == giants_before
	var bedroom_scale: float = _game.get_node("Skybox/Bedroom").scale.x
	var arm_l1 := float(s_start.arm_l1) / bedroom_scale
	var arm_l2 := float(s_start.arm_l2) / bedroom_scale
	var rig_ok := bool(s_start.using_placeholder) or (bool(s_start.using_real_yumeka)
			and not bool(s_start.placeholder_visible)
			and bool(s_start.has_skeleton) and int(s_start.bone_count) > 100
			and arm_l1 > 0.135 and arm_l1 < 0.195
			and arm_l2 > 0.142 and arm_l2 < 0.21)
	_check(bool(s_start.active) and String(s_start.phase) == "raise"
			and String(s_start.hazard) == "finger_poke"
			and bool(s_start.hand_visible) and bool(s_start.warning_visible)
			and bool(s_start.shadow_visible)
			and int(round.hazard_warning_count()) == 1
			and start_wrist_err < 15.0 and float(s_start.gesture_weight) < 0.05
			and rig_ok,
			"F8 starts finger_poke in RAISE on Yumeka's real full Skeleton3D from desk rest_pos (zero teleport, no detached relay)")
	_check(hand_has_no_colliders and giants_unchanged,
			"desk hazard arm carries zero colliders and never registers into giants/rivals (strictly unattackable)")

	# Place the rival AI inside the 110 m warning circle; during RAISE verify smooth elbow lift,
	# natural elbow bend, smooth gesture interpolation (0 -> 1) and immediate Phase 4 AI evasion.
	var rival: CharacterBody3D = round.get_node("OtherGiants").get_child(0) as CharacterBody3D
	var target: Vector3 = s_start.target
	rival.global_position = Vector3(target.x + 28.0, 0.05, target.z)
	var ai_evaded := false
	var saw_raise_mid_blend := false
	var saw_raise_elbow_bend := false
	for f in 24:
		await physics_frame
		var actors: Array = round.growth_actors()
		if actors.size() > 1 and String(actors[1].intent) == "evade":
			ai_evaded = true
		var st_r: Dictionary = hazards.debug_state()
		if String(st_r.phase) == "raise":
			var g_now: float = float(st_r.gesture_weight)
			var bend_now: float = float(st_r.elbow_bend_deg)
			if g_now > 0.15 and g_now < 0.88:
				saw_raise_mid_blend = true
			if bend_now > 25.0 and bend_now < 115.0 and (st_r.elbow_pos as Vector3).y > (s_start.elbow_pos as Vector3).y + 150.0:
				saw_raise_elbow_bend = true
	_check(saw_raise_mid_blend and saw_raise_elbow_bend,
			"RAISE lifts elbow naturally with smooth bend and continuous finger gesture blend (0 -> 1)")
	_check(ai_evaded, "Phase 4 AI inside the desk hazard warning circle immediately switches to evade")

	# Verify Yumeka's REAL full-body skeleton drives the arm directly (no collapsed UpperArm_R,
	# no placeholder arm shown, real Hand_R tracks IK wrist target with subtle Chest/Shoulder lean).
	if yumeka != null and bool(yumeka.call("debug_is_mounted")):
		await _ticks(4)
		var ik_st: Dictionary = yumeka.call("debug_right_arm_ik_state")
		var ua_world: Vector3 = yumeka.call("debug_bone_world_pos", "UpperArm_R")
		var ua_room: Vector3 = yumeka.call("debug_bone_pos", "UpperArm_R")
		var elbow_world: Vector3 = yumeka.call("debug_bone_world_pos", "LowerArm_R")
		var hand_world: Vector3 = yumeka.call("debug_bone_world_pos", "Hand_R")
		var st_now: Dictionary = hazards.debug_state()
		_check(bool(ik_st.active) and float(ik_st.lean) > 0.05
				and not bool(st_now.placeholder_visible)
				and ua_room.z > 0.30 and ua_room.y > 0.83
				and is_equal_approx(ua_world.distance_to(elbow_world), float(ik_st.arm_l1_world) * float(ik_st.ik_stretch))
				and is_equal_approx(elbow_world.distance_to(hand_world), float(ik_st.arm_l2_world) * float(ik_st.ik_stretch))
				and hand_world.distance_to(st_now.wrist_pos as Vector3) < 10.0,
				"Yumeka's real Skeleton3D drives UpperArm_R -> LowerArm_R -> Hand_R directly with subtle lean (zero relay collapse)")

	# Advance through WINDUP (1.75 s) to touchdown (HOLD) and verify impact resolution & fingertip accuracy.
	var saw_windup := false
	var hit_hold := false
	for _f in 180:
		var st: Dictionary = hazards.debug_state()
		if String(st.phase) == "windup":
			saw_windup = true
			if float(st.phase_time) >= 1.60:
				rival.global_position = Vector3(target.x + 12.0, 0.05, target.z)
		await physics_frame
		if String(hazards.debug_state().phase) == "hold":
			hit_hold = true
			break
	var s_hold: Dictionary = hazards.debug_state()
	var impact_info: Dictionary = s_hold.last_impact
	var tip_err: float = (s_hold.fingertip_pos as Vector3).distance_to(target)
	var curled_clear := true
	if yumeka != null and bool(yumeka.call("debug_is_mounted")):
		for bn in ["MiddleDistal_R", "RingDistal_R", "LittleDistal_R", "ThumbDistal_R"]:
			if (yumeka.call("debug_bone_world_pos", bn) as Vector3).y < 100.0:
				curled_clear = false
	_check(saw_windup and hit_hold and int(round.hazard_warning_count()) == 0
			and not bool(s_hold.warning_visible) and bool(s_hold.hand_visible)
			and tip_err < 25.0 and curled_clear
			and int(impact_info.get("buildings_destroyed", 0)) > 0
			and int(round.snapshot().destroyed) > destroyed_before
			and int(impact_info.get("giants_hit", 0)) >= 1
			and int(impact_info.get("giants_defeated", 0)) >= 1,
			"finger_poke touchdown lands real fingertip on target with curled fingers clear, destroys buildings and crushes units")

	# Advance through HOLD (0.5 s) -> RETRACT (0.65 s) -> RETURN (0.75 s) and verify smooth landing back at rest_pos.
	var saw_retract := false
	var saw_return := false
	var last_return_wrist := Vector3.INF
	var last_return_rest := Vector3.ZERO
	var last_return_gesture := 1.0
	var returned_idle := false
	for _f in 180:
		await physics_frame
		var st_p: Dictionary = hazards.debug_state()
		if String(st_p.phase) == "retract":
			saw_retract = true
		elif String(st_p.phase) == "return":
			saw_return = true
			last_return_wrist = st_p.wrist_pos
			last_return_rest = st_p.rest_hand_pos
			last_return_gesture = float(st_p.gesture_weight)
		elif not bool(st_p.active):
			returned_idle = true
			break
	var s_idle: Dictionary = hazards.debug_state()
	_check(saw_retract and saw_return and returned_idle and String(s_idle.phase) == "idle"
			and last_return_wrist.distance_to(last_return_rest) < 40.0
			and last_return_gesture < 0.15
			and not bool(s_idle.hand_visible) and not bool(s_idle.warning_visible)
			and not bool(s_idle.shadow_visible) and int(round.hazard_warning_count()) == 0,
			"arm glides back to desk rest_pos (gesture -> 0.0) in RETURN and resets cleanly to idle")

	if yumeka != null and bool(yumeka.call("debug_is_mounted")):
		await _ticks(6)
		var ik_done: Dictionary = yumeka.call("debug_right_arm_ik_state")
		var hand_rest_room: Vector3 = yumeka.call("debug_bone_pos", "Hand_R")
		_check(not bool(ik_done.active) and is_zero_approx(float(ik_done.lean))
				and hand_rest_room.y > 0.74 and hand_rest_room.y < 0.88
				and hand_rest_room.x > 0.12,
				"Yumeka real right arm restores seamlessly to SeatedPose desk rest after RETURN")

	# 5. Missing Yumeka_seated.glb graceful placeholder fallback runs the identical 5-phase zero-teleport curve.
	hazards.debug_force_placeholder(true)
	var ph_started: bool = bool(hazards.trigger_finger_poke(Vector3(0.0, 0.0, 0.0)))
	var s_ph: Dictionary = hazards.debug_state()
	var ph_meshes: Array = hazards.find_children("*", "MeshInstance3D", true, false)
	var ph_phases := {}
	for _f in 290:
		var st_ph: Dictionary = hazards.debug_state()
		ph_phases[String(st_ph.phase)] = true
		if not bool(st_ph.active):
			break
		await physics_frame
	_check(ph_started and bool(s_ph.active) and bool(s_ph.using_placeholder)
			and bool(s_ph.placeholder_visible)
			and String(s_ph.phase) == "raise"
			and (s_ph.wrist_pos as Vector3).distance_to(s_ph.rest_hand_pos as Vector3) < 15.0
			and bool(s_ph.hand_visible) and ph_meshes.size() >= 6
			and _count_collisions_in(hazards) == 0
			and ph_phases.has("raise") and ph_phases.has("windup") and ph_phases.has("hold")
			and ph_phases.has("retract") and ph_phases.has("return") and ph_phases.has("idle"),
			"missing Yumeka_seated.glb placeholder runs full 5-phase zero-teleport curve with zero colliders")

	# Leaving round mid-hazard cleans up cleanly back to title & releases Yumeka IK.
	hazards.debug_force_placeholder(false)
	hazards.trigger_finger_poke(Vector3(0.0, 0.0, 0.0))
	await _ticks(4)
	_game.save_all_mode_settings(
			_game.default_mode_settings(0), _game.default_mode_settings(1),
			_game.default_mode_settings(2), _game.default_mode_settings(3))
	_game.show_menu()
	await _ticks(4)
	if yumeka != null and bool(yumeka.call("debug_is_mounted")):
		_check(not bool(yumeka.call("debug_right_arm_ik_state").active),
				"returning to title mid-hazard immediately releases Yumeka real-skeleton right-arm IK")


func _ankle(giant: CharacterBody3D, side: String) -> Vector3:
	var rig: Skeleton3D = giant.get_node("Model/metarig/Skeleton3D")
	return rig.to_global(rig.get_bone_global_pose(rig.find_bone("foot." + side)).origin)


func _left_sole(giant: CharacterBody3D) -> Vector3:
	var rig: Skeleton3D = giant.get_node("Model/metarig/Skeleton3D")
	var foot := rig.find_bone("foot.L")
	var rest_center := rig.get_bone_global_rest(foot).affine_inverse() * Vector3(0.06208, 0.0, 0.02071)
	return rig.to_global(rig.get_bone_global_pose(foot) * rest_center)


func _has_strike_overlay(target: Node) -> bool:
	for mesh: MeshInstance3D in target.find_children("*", "MeshInstance3D", true, false):
		if mesh.material_overlay != null:
			return true
	return false


func _round() -> Node:
	return _game.get_node(MAP)


func _actor(index: int) -> CharacterBody3D:
	return _round().get_node(PLAYERS[index])


func _initial_state(current: Node) -> bool:
	var data: Dictionary = current.snapshot()
	if data.health != 3 or data.stamina != 1.0 or data.destroyed != 0 or int(FootfallFixture.actor(current).footfall_count) != 0:
		return false
	for target in current.get_node("District/Targets").get_children():
		if target.get_node("BlockingBody").collision_layer != (BUILDING_LAYER if target.kind == "building" else 2):
			return false
	return _giant_has_scale(current.get_node("Giant"), 1.0)


func _giant_has_scale(giant: CharacterBody3D, factor: float) -> bool:
	var model: Node3D = giant.get_node("Model")
	var collision: CollisionShape3D = giant.get_node("Collision")
	var capsule := collision.shape as CapsuleShape3D
	return model.scale.is_equal_approx(Vector3.ONE * (14.8 * factor)) \
			and is_equal_approx(capsule.radius, 2.9 * factor) \
			and is_equal_approx(capsule.height, 25.2 * factor) \
			and is_equal_approx(collision.position.y, capsule.height * 0.5)


func _walk_axis(actor: CharacterBody3D, action: StringName, direction: Vector3, coordinate: float, limit: int) -> void:
	Input.action_press(action)
	for frame in limit:
		if actor.position.dot(direction) >= coordinate or _game.get_screen() != "playing":
			break
		await physics_frame
	Input.action_release(action)
	await _ticks(2)


func _wait_growth(current: Node, count: int, limit := 180) -> void:
	for frame in limit:
		if current.snapshot().growth_count >= count:
			return
		await physics_frame
	_check(false, "queued growth completes")


func _mouse(motion: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.screen_relative = motion
	event.relative = motion
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _key(code: Key) -> void:
	_set_key_state(code, true)
	_set_key_state(code, false)


func _set_key_state(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _ticks(count: int) -> void:
	for frame in count:
		await physics_frame


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures += 1
		push_error(description)
