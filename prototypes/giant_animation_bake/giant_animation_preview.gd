extends Node3D
## Standalone preview for the baked giant animation library
## (res://prototypes/giant_animation_bake/giant_actions.res, produced by tools/bake_giant_animations.gd).
##
## Unlike tests/sit_crush_preview.gd this scene never calls the procedural IK: every pose
## comes out of the AnimationPlayer, so it doubles as proof that the exported clips are
## self-sufficient.
##
## Run:
##   godot --path . res://prototypes/giant_animation_bake/giant_animation_preview.tscn
## Screenshot pass (writes res://build/tmp/shots/*.png):
##   godot --path . res://prototypes/giant_animation_bake/giant_animation_preview.tscn -- --shots

const GIANT_SCENE := preload("res://scenes/giant.tscn")
const LIBRARY := preload("res://prototypes/giant_animation_bake/giant_actions.res")
const CLIPS := [&"sit_crush", &"sit_idle", &"turn_180", &"turn_then_sit"]
const CLIP_TITLES := {
	&"sit_crush": "坐压 sit_crush",
	&"sit_idle": "坐姿待机 sit_idle",
	&"turn_180": "180° 原地转身 turn_180",
	&"turn_then_sit": "转身→坐压 turn_then_sit",
}
const IMPACT_CENTER := Vector3(0.0, 0.0, -2.85)
const IMPACT_RADIUS := 4.4
const CAMERA_PRESETS := [
	{"name": "前侧 3/4", "yaw": 2.52, "pitch": -0.26, "dist": 44.0},
	{"name": "正侧面", "yaw": 1.62, "pitch": -0.12, "dist": 41.0},
	{"name": "背面 3/4", "yaw": -0.62, "pitch": -0.28, "dist": 44.0},
	{"name": "地面仰视", "yaw": 2.72, "pitch": 0.02, "dist": 23.0},
]

var giant: CharacterBody3D
var player: AnimationPlayer
var current_clip: StringName = &"sit_crush"

var _camera: Camera3D
var _camera_index := 0
var _orbit_target := Vector3(0.0, 10.4, -1.2)
var _orbit_yaw := 2.52
var _orbit_pitch := -0.26
var _orbit_dist := 44.0
var _dragging := false
var _paused := false
var _speed := 1.0
var _scrubbing := false

var _title: Label
var _status: Label
var _markers: Label
var _slider: HSlider
var _play_button: Button
var _loop_button: Button


func _ready() -> void:
	_build_environment()
	_build_ground()
	_build_giant()
	_build_camera()
	_build_ui()
	select_clip(current_clip)
	player.play(&"giant/" + String(CLIP_TITLES.get(current_clip, current_clip)))
	player.seek(0.0, true)
	if "--shots" in OS.get_cmdline_user_args():
		_capture_shots.call_deferred()


# --- scene ----------------------------------------------------------------

func _build_environment() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.30, 0.46, 0.68)
	sky_mat.sky_horizon_color = Color(0.77, 0.72, 0.64)
	sky_mat.ground_bottom_color = Color(0.23, 0.26, 0.29)
	sky_mat.ground_horizon_color = Color(0.55, 0.54, 0.51)
	sky.sky_material = sky_mat
	env.environment.sky = sky
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment.ambient_light_energy = 0.46
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-44.0, 32.0, 0.0)
	sun.light_color = Color(1.0, 0.94, 0.85)
	sun.light_energy = 0.96
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 130.0
	add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20.0, -140.0, 0.0)
	fill.light_color = Color(0.75, 0.84, 0.97)
	fill.light_energy = 0.26
	add_child(fill)


func _build_ground() -> void:
	var body := StaticBody3D.new()
	body.name = "Ground"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var col := CollisionShape3D.new()
	col.shape = WorldBoundaryShape3D.new()
	body.add_child(col)

	var plane := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(180.0, 180.0)
	plane.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.27, 0.29, 0.32)
	mat.roughness = 0.94
	plane.material_override = mat
	add_child(plane)

	# Seated footprint of the sit-crush clip, for scale and impact-placement checks.
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = IMPACT_RADIUS - 0.18
	torus.outer_radius = IMPACT_RADIUS
	torus.rings = 64
	torus.ring_segments = 8
	ring.mesh = torus
	ring.position = Vector3(IMPACT_CENTER.x, 0.03, IMPACT_CENTER.z)
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.albedo_color = Color(Color("#f29d4b"), 0.75)
	ring.material_override = ring_mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)

	# Reference props inside / outside the footprint.
	for spot in [Vector3(0.0, 0.0, -2.4), Vector3(1.6, 0.0, -3.2), Vector3(-1.5, 0.0, -2.9),
			Vector3(0.0, 0.0, -6.6)]:
		var box := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = Vector3(0.55, 0.42, 0.55)
		box.mesh = box_mesh
		box.position = spot + Vector3(0.0, 0.21, 0.0)
		var box_mat := StandardMaterial3D.new()
		box_mat.albedo_color = Color(0.62, 0.48, 0.32) if spot.z > -5.0 else Color(0.36, 0.42, 0.5)
		box.material_override = box_mat
		add_child(box)

	for offset in [-12.0, 0.0, 12.0]:
		var line := MeshInstance3D.new()
		var line_mesh := BoxMesh.new()
		line_mesh.size = Vector3(0.10, 0.012, 60.0)
		line.mesh = line_mesh
		line.position = Vector3(offset, 0.008, 0.0)
		var line_mat := StandardMaterial3D.new()
		line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		line_mat.albedo_color = Color(0.68, 0.70, 0.72, 0.32)
		line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		line.material_override = line_mat
		line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(line)


func _build_giant() -> void:
	giant = GIANT_SCENE.instantiate() as CharacterBody3D
	giant.name = "Giant"
	add_child(giant)
	giant.call("_set_skin", &"Kawaii")
	giant.velocity = Vector3(0.0, -2.0, 0.0)
	giant.move_and_slide()
	giant.global_position.y = 0.0

	player = AnimationPlayer.new()
	player.name = "BakedPlayer"
	giant.add_child(player)
	player.add_animation_library(&"giant", LIBRARY)
	player.animation_finished.connect(_on_animation_finished)


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 46.0
	_camera.near = 0.2
	_camera.far = 900.0
	add_child(_camera)
	_camera.current = true
	_update_camera()


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(18.0, 16.0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.08, 0.82)
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	layer.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	_title = Label.new()
	_title.add_theme_color_override("font_color", Color("#f6e6c8"))
	vbox.add_child(_title)

	_status = Label.new()
	_status.add_theme_color_override("font_color", Color("#c9d3de"))
	vbox.add_child(_status)

	_markers = Label.new()
	_markers.add_theme_color_override("font_color", Color("#9fb4c8"))
	vbox.add_child(_markers)

	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 8)
	vbox.add_child(controls)

	_play_button = Button.new()
	_play_button.text = "暂停 [Space]"
	_play_button.pressed.connect(toggle_play)
	controls.add_child(_play_button)

	_loop_button = Button.new()
	_loop_button.text = "循环:开 [L]"
	_loop_button.pressed.connect(toggle_loop)
	controls.add_child(_loop_button)

	for i in CLIPS.size():
		var button := Button.new()
		button.text = "%d %s" % [i + 1, String(CLIPS[i])]
		button.pressed.connect(select_clip.bind(CLIPS[i]))
		controls.add_child(button)

	var speed_button := Button.new()
	speed_button.text = "速度 1x [T]"
	speed_button.pressed.connect(_cycle_speed)
	controls.add_child(speed_button)

	_slider = HSlider.new()
	_slider.min_value = 0.0
	_slider.max_value = 1.0
	_slider.step = 0.001
	_slider.custom_minimum_size = Vector2(320.0, 18.0)
	_slider.value_changed.connect(_on_slider_changed)
	vbox.add_child(_slider)

	var hint := Label.new()
	hint.text = "左键拖动旋转视角 · 滚轮缩放 · 拖动进度条逐帧检查（动画完全来自 AnimationPlayer）"
	hint.add_theme_color_override("font_color", Color("#8b96a2"))
	vbox.add_child(hint)


# --- playback -------------------------------------------------------------

func select_clip(clip: StringName, start_time := 0.0) -> void:
	if not CLIP_TITLES.has(clip):
		return
	current_clip = clip
	var name := "giant/" + String(clip)
	player.play(name)
	player.seek(start_time, true)
	_slider.max_value = player.get_animation(name).get_length()
	_slider.set_value_no_signal(start_time)
	_title.text = "%s   %.2fs · %d 轨" % [
		CLIP_TITLES[clip], player.get_animation(name).get_length(),
		player.get_animation(name).get_track_count(),
	]
	var marker_names: PackedStringArray = player.get_animation(name).get_marker_names()
	var parts: Array[String] = []
	for marker in marker_names:
		parts.append("%s@%.2fs" % [marker, player.get_animation(name).get_marker_time(marker)])
	_markers.text = "标记：" + ("、".join(parts) if not parts.is_empty() else "无")


func toggle_play() -> void:
	_paused = not _paused
	player.paused = _paused
	_play_button.text = "继续 [Space]" if _paused else "暂停 [Space]"


func toggle_loop() -> void:
	var name := "giant/" + String(current_clip)
	var anim := player.get_animation(name)
	anim.loop_mode = Animation.LOOP_NONE if anim.loop_mode == Animation.LOOP_LINEAR else Animation.LOOP_LINEAR
	_loop_button.text = "循环:开 [L]" if anim.loop_mode == Animation.LOOP_LINEAR else "循环:关 [L]"


func _cycle_speed() -> void:
	if is_equal_approx(_speed, 1.0):
		_speed = 0.5
	elif is_equal_approx(_speed, 0.5):
		_speed = 0.25
	else:
		_speed = 1.0
	player.speed_scale = _speed


func _on_slider_changed(value: float) -> void:
	if _scrubbing:
		return
	player.seek(value, true)


func _on_animation_finished(_name: StringName) -> void:
	_status.text = "播放完毕（按 R 重播）"


func _process(delta: float) -> void:
	if not _paused and player != null:
		var name := "giant/" + String(current_clip)
		var length := player.get_animation(name).get_length()
		if player.current_animation_position >= length and player.get_animation(name).loop_mode == Animation.LOOP_NONE:
			player.seek(length, true)
	if player != null:
		_slider.set_value_no_signal(player.current_animation_position)
		_status.text = "t = %.2f s   %s   %s" % [
			player.current_animation_position,
			"暂停" if _paused else "播放中",
			CLIP_TITLES.get(current_clip, current_clip),
		]
	_update_camera()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_SPACE:
				toggle_play()
			KEY_L:
				toggle_loop()
			KEY_R:
				select_clip(current_clip)
			KEY_T:
				_cycle_speed()
			KEY_C:
				_camera_index = (_camera_index + 1) % CAMERA_PRESETS.size()
				var preset: Dictionary = CAMERA_PRESETS[_camera_index]
				_orbit_yaw = preset["yaw"]
				_orbit_pitch = preset["pitch"]
				_orbit_dist = preset["dist"]
			KEY_1, KEY_2, KEY_3, KEY_4:
				select_clip(CLIPS[event.keycode - KEY_1])
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_orbit_dist = maxf(12.0, _orbit_dist - 3.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_orbit_dist = minf(120.0, _orbit_dist + 3.0)
	elif event is InputEventMouseMotion and _dragging:
		_orbit_yaw -= event.relative.x * 0.006
		_orbit_pitch = clampf(_orbit_pitch - event.relative.y * 0.005, -0.9, 0.6)


func _update_camera() -> void:
	if _camera == null:
		return
	var offset := Vector3(sin(_orbit_yaw), 0.0, cos(_orbit_yaw)) * _orbit_dist
	offset.y = -_orbit_pitch * _orbit_dist
	_camera.global_position = _orbit_target + offset
	_camera.look_at(_orbit_target, Vector3.UP)


# --- screenshot pass ------------------------------------------------------

func _capture_shots() -> void:
	DirAccess.make_dir_recursive_absolute("res://build/tmp/shots")
	_paused = true
	player.paused = true
	var plan := [
		{"clip": &"turn_180", "time": 0.30},
		{"clip": &"turn_180", "time": 2.10},
		{"clip": &"turn_180", "time": 3.95},
		{"clip": &"sit_crush", "time": 1.20},
		{"clip": &"sit_crush", "time": 2.05},
		{"clip": &"sit_crush", "time": 3.10},
		{"clip": &"sit_crush", "time": 4.60},
		{"clip": &"sit_idle", "time": 3.00},
		{"clip": &"turn_then_sit", "time": 4.30},
	]
	for i in plan.size():
		select_clip(plan[i]["clip"], plan[i]["time"])
		for frame in 3:
			await get_tree().process_frame
		var image := get_viewport().get_texture().get_image()
		var path := "res://build/tmp/shots/%02d_%s_%.2f.png" % [i, String(plan[i]["clip"]), plan[i]["time"]]
		image.save_png(path)
		print("saved ", path)
	get_tree().quit()
