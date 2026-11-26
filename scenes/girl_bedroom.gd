extends Node3D

const MAIN_MENU := "res://scenes/main.tscn"
const TouchControls := preload("res://scenes/touch_controls.gd")

@export var setup_environment := true
@export var setup_lights := true
@export var setup_reflection_probe := true

@onready var _player: CharacterBody3D = $Player

var _touch_enabled := OS.has_feature("android")
var _touch: TouchControls
var _hud_root: Control


func _ready() -> void:
	_configure_imported_visuals()
	_configure_collisions()
	if setup_environment:
		_build_environment()
	if setup_lights:
		_build_lights()
	if setup_reflection_probe:
		_build_reflection_probe()
	_build_hud()
	var audio := get_node_or_null("/root/HarborAudio")
	if audio != null:
		audio.call("set_ambience", &"bedroom")
	if not _touch_enabled:
		var window := get_window()
		window.focus_entered.connect(_capture_mouse)
		window.focus_exited.connect(_release_mouse)
		if window.has_focus():
			_capture_mouse()


func _configure_imported_visuals() -> void:
	var visual := get_node_or_null("Visual")
	if visual == null:
		return

	# Let directional sunlight pass cleanly through the closed window glass while keeping specular reflections
	var glass := visual.find_child("Arch_ClosedWindowGlass", true, false) as MeshInstance3D
	if glass != null:
		glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if glass.mesh != null and glass.mesh.get_surface_count() > 0:
			var gmat := glass.mesh.surface_get_material(0)
			if gmat is StandardMaterial3D:
				var copy := gmat.duplicate() as StandardMaterial3D
				copy.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				copy.albedo_color = Color(0.88, 0.95, 0.98, 0.16)
				copy.roughness = 0.05
				copy.metallic = 0.05
				copy.metallic_specular = 0.9
				copy.cull_mode = BaseMaterial3D.CULL_DISABLED
				glass.set_surface_override_material(0, copy)

	# Ensure thin sheer curtains render cleanly from both sides
	var curtains := visual.find_child("Arch_Curtains", true, false) as MeshInstance3D
	if curtains != null and curtains.mesh != null:
		for s: int in range(curtains.mesh.get_surface_count()):
			var cmat := curtains.mesh.surface_get_material(s)
			if cmat is StandardMaterial3D and cmat.resource_name.contains("Sheer"):
				var copy := cmat.duplicate() as StandardMaterial3D
				copy.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				copy.cull_mode = BaseMaterial3D.CULL_DISABLED
				curtains.set_surface_override_material(s, copy)

	# Crisp mirror surface settings for ReflectionProbe
	for mname: String in ["Furn_VanityMirror", "Furn_FloorMirror"]:
		var mnode := visual.find_child(mname, true, false) as MeshInstance3D
		if mnode != null and mnode.mesh != null:
			for s: int in range(mnode.mesh.get_surface_count()):
				var mat := mnode.mesh.surface_get_material(s)
				if mat is StandardMaterial3D and mat.resource_name.contains("Mirror"):
					var copy := mat.duplicate() as StandardMaterial3D
					copy.metallic = 1.0
					copy.roughness = 0.02
					copy.albedo_color = Color("#f3f1ec")
					mnode.set_surface_override_material(s, copy)


func _configure_collisions() -> void:
	# The imported furniture boxes cover gaps that a centimeter-tall player can use.
	for body: StaticBody3D in $Visual.find_children("*", "StaticBody3D", true, false):
		if body.name not in [&"Col_Floor", &"Col_Ceiling"]:
			body.collision_layer = 0
			body.collision_mask = 0
	for visual: MeshInstance3D in $Visual.find_children("*", "MeshInstance3D", true, false):
		visual.create_trimesh_collision()


func _build_environment() -> void:
	var we := WorldEnvironment.new()
	we.name = "BedroomWorldEnvironment"
	var env := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("#456f86")
	sky_mat.sky_horizon_color = Color("#f3ce9d")
	sky_mat.sky_curve = 0.14
	sky_mat.ground_horizon_color = Color("#8aa9b3")
	sky_mat.ground_bottom_color = Color("#344c56")
	sky_mat.sun_angle_max = 2.6
	sky_mat.sun_curve = 0.08
	sky.sky_material = sky_mat
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#c8dae0")
	env.ambient_light_energy = 0.24
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.05
	if RenderingServer.get_current_rendering_method() == "forward_plus":
		env.ssao_enabled = true
		env.ssao_radius = 0.65
		env.ssao_intensity = 1.55
		env.ssao_power = 1.35
		env.ssil_enabled = true
		env.ssil_radius = 2.8
		env.ssil_intensity = 0.75
		env.sdfgi_enabled = true
		env.sdfgi_use_occlusion = true
		env.sdfgi_bounce_feedback = 0.62
		env.sdfgi_energy = 0.85
		env.sdfgi_min_cell_size = 0.15
	env.glow_enabled = true
	env.glow_bloom = 0.10
	env.glow_intensity = 0.42
	env.glow_hdr_threshold = 1.15
	we.environment = env
	add_child(we)


func _build_lights() -> void:
	var rig := Node3D.new()
	rig.name = "BedroomLights"
	add_child(rig)

	# 1. Warm Breakwater afternoon sunlight streaming diagonally through the CLOSED North (-Z) window
	var sun := DirectionalLight3D.new()
	sun.name = "SunKey"
	sun.light_color = Color("#ffe0b4")
	sun.light_energy = 3.2
	sun.light_angular_distance = 2.4
	sun.shadow_enabled = true
	sun.shadow_bias = 0.018
	sun.shadow_normal_bias = 1.2
	sun.shadow_blur = 1.35
	sun.directional_shadow_max_distance = 32.0
	rig.add_child(sun)
	sun.look_at_from_position(Vector3(1.5, 2.85, -5.2), Vector3(-0.85, 0.15, 0.55), Vector3.UP)

	# 2. Cool coastal harbor sky bounce entering through the closed window panes
	var win_fill := OmniLight3D.new()
	win_fill.name = "WindowSkyBounce"
	win_fill.position = Vector3(0.35, 1.62, -1.80)
	win_fill.light_color = Color("#c2dff0")
	win_fill.light_energy = 1.05
	win_fill.omni_range = 6.5
	win_fill.omni_attenuation = 1.35
	win_fill.shadow_enabled = false
	rig.add_child(win_fill)

	# 3. Central ceiling scalloped pendant lamp (warm tungsten)
	var pendant := OmniLight3D.new()
	pendant.name = "PendantLight"
	pendant.position = Vector3(0.0, 2.08, 0.15)
	pendant.light_color = Color("#ffe1b4")
	pendant.light_energy = 0.92
	pendant.omni_range = 6.2
	pendant.omni_attenuation = 1.35
	pendant.shadow_enabled = true
	pendant.shadow_bias = 0.04
	pendant.light_size = 0.16
	rig.add_child(pendant)

	# 4. Bedside nightstand pleated lamp (cozy amber intimacy)
	var bedside := OmniLight3D.new()
	bedside.name = "BedsideLampLight"
	bedside.position = Vector3(-2.02, 0.90, 1.50)
	bedside.light_color = Color("#ffd18a")
	bedside.light_energy = 0.78
	bedside.omni_range = 3.2
	bedside.omni_attenuation = 1.65
	bedside.shadow_enabled = false
	rig.add_child(bedside)

	# 5. Brass gooseneck study desk lamp aimed at the open sketchbook
	var desk_lamp := SpotLight3D.new()
	desk_lamp.name = "DeskLampLight"
	desk_lamp.light_color = Color("#ffdca0")
	desk_lamp.light_energy = 1.25
	desk_lamp.spot_range = 2.4
	desk_lamp.spot_angle = 44.0
	desk_lamp.spot_angle_attenuation = 0.75
	desk_lamp.shadow_enabled = false
	rig.add_child(desk_lamp)
	desk_lamp.look_at_from_position(Vector3(-0.06, 1.01, -1.76), Vector3(0.26, 0.74, -1.65), Vector3.UP)

	# 6. Soft warm fairy-light glow over headboard gallery wall
	for i: int in range(2):
		var fairy := OmniLight3D.new()
		fairy.name = "FairyHalo_%d" % (i + 1)
		fairy.position = Vector3(-2.16, 2.20, 0.82 if i == 0 else -0.05)
		fairy.light_color = Color("#ffd085")
		fairy.light_energy = 0.24
		fairy.omni_range = 2.1
		fairy.omni_attenuation = 1.6
		fairy.shadow_enabled = false
		rig.add_child(fairy)


func _build_reflection_probe() -> void:
	var probe := ReflectionProbe.new()
	probe.name = "BedroomReflectionProbe"
	probe.position = Vector3(0.0, 1.45, 0.0)
	probe.size = Vector3(5.0, 3.1, 4.4)
	probe.interior = true
	probe.box_projection = true
	probe.enable_shadows = true
	probe.intensity = 0.95
	probe.ambient_mode = ReflectionProbe.AMBIENT_COLOR
	probe.ambient_color = Color("#d8cfc4")
	probe.ambient_color_energy = 0.22
	add_child(probe)


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	match what:
		NOTIFICATION_WM_GO_BACK_REQUEST:
			_return_to_menu.call_deferred()
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT:
			if _touch != null:
				_touch.clear_input()
		NOTIFICATION_APPLICATION_RESUMED:
			if _touch_enabled:
				_fit_hud_to_safe_area.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause_game"):
		get_viewport().set_input_as_handled()
		_return_to_menu()
	elif not _touch_enabled and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and event is InputEventMouseMotion \
			and event.device != InputEvent.DEVICE_ID_EMULATION:
		_player.look(event.screen_relative)


func _capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _exit_tree() -> void:
	if not _touch_enabled:
		_release_mouse()


func _return_to_menu() -> void:
	if not is_inside_tree():
		return
	var audio := get_node_or_null("/root/HarborAudio")
	if audio != null:
		audio.call("play_ui", &"ui_back")
		audio.call("stop_gameplay_sfx")
	var menu_scene := load(MAIN_MENU) as PackedScene
	if menu_scene == null:
		push_error("Unable to load the bedroom menu")
		return
	var menu := menu_scene.instantiate()
	menu.get_node("Interface").prepare_bedroom_menu()
	var result := get_tree().change_scene_to_node(menu)
	if result != OK:
		menu.free()
		push_error("Unable to return to the bedroom menu: %s" % error_string(result))


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "BedroomHUD"
	add_child(layer)
	_hud_root = Control.new()
	_hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_hud_root)
	_hud_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if _touch_enabled:
		var font := FontVariation.new()
		font.base_font = preload("res://assets/fonts/harbor-ui.otf")
		font.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 500}
		var theme := Theme.new()
		theme.default_font = font
		_hud_root.theme = theme
		_touch = TouchControls.new()
		_touch.name = "TouchControls"
		_touch.bedroom_controls = true
		_touch.label_font = font
		_touch.leave_requested.connect(_return_to_menu, CONNECT_DEFERRED)
		_hud_root.add_child(_touch)
		_touch.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_touch.present("playing", 0, _player, true, false)
		get_viewport().size_changed.connect(_fit_hud_to_safe_area)
		_fit_hud_to_safe_area()

	var card := PanelContainer.new()
	card.position = Vector2(24, 18)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#19272eea")
	style.border_color = Color("#627477")
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 9
	style.content_margin_bottom = 9
	card.add_theme_stylebox_override("panel", style)
	_hud_root.add_child(card)
	var label := Label.new()
	label.text = "身高 1 厘米"
	if not _touch_enabled:
		label.text += "   ·   WASD 移动   ·   鼠标或方向键环视   ·   按住空格攀爬   ·   Esc 返回"
	label.add_theme_font_size_override("font_size", 22 if _touch_enabled else 17)
	label.add_theme_color_override("font_color", Color("#ecf1ed"))
	card.add_child(label)


func _fit_hud_to_safe_area() -> void:
	var viewport := get_viewport()
	var area := viewport.get_visible_rect()
	var from_screen := viewport.get_screen_transform().affine_inverse()
	var safe := area.intersection(from_screen * Rect2(DisplayServer.get_display_safe_area()))
	if not safe.has_area():
		safe = area
	_hud_root.offset_left = safe.position.x - area.position.x
	_hud_root.offset_top = safe.position.y - area.position.y
	_hud_root.offset_right = safe.end.x - area.end.x
	_hud_root.offset_bottom = safe.end.y - area.end.y
