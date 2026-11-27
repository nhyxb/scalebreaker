extends Node3D
## Standalone interactive preview & visual verification stage for the giant's
## sit-crush (坐压) animation. Not wired into production gameplay yet.

const GIANT_SCENE := preload("res://scenes/giant.tscn")
const HUMAN_MODEL := preload("res://assets/characters/human_kenney.glb")
const DUST_COLOR := Color("#ccb395")
const RING_COLOR := Color("#f5d7a3")
const ZONE_COLOR := Color("#f29d4b")
const IMPACT_RADIUS := 4.4
const TARGET_CENTER := Vector3(0.0, 0.0, -2.85)
const TURN_TARGET_YAW := PI - 0.001

const CAMERA_PRESETS := [
	{"name": "前侧 3/4", "yaw": 2.42, "pitch": -0.25, "dist": 43.0, "target": Vector3(0.0, 10.6, -1.2)},
	{"name": "正侧面", "yaw": 1.57, "pitch": -0.14, "dist": 41.0, "target": Vector3(0.0, 9.8, -1.2)},
	{"name": "初始前侧 3/4", "yaw": 0.66, "pitch": -0.26, "dist": 43.0, "target": Vector3(0.0, 10.6, -1.2)},
	{"name": "地面仰视", "yaw": 2.68, "pitch": 0.05, "dist": 22.0, "target": Vector3(0.0, 5.8, -1.4)},
	{"name": "坐姿/撑地特写", "yaw": 2.34, "pitch": -0.24, "dist": 24.0, "target": Vector3(0.0, 4.8, -1.4)},
]

var giant: CharacterBody3D
var _camera: Camera3D
var _orbit_yaw := 2.42
var _orbit_pitch := -0.25
var _orbit_dist := 43.0
var _orbit_target := Vector3(0.0, 10.6, -1.2)
var _dragging := false

var _playing := true
var _looping := true
var _speed_scale := 1.0
var _progress := 0.0
var _mode_walk_intro := false
var _walk_intro_time := 0.0
var _mode_turn_intro := true
var _turn_elapsed := 0.0
var _turn_steps_taken := 0
var _walk_outro_time := -1.0
var _mode_sit_idle_only := false
var _mode_sit_cycle := false
var _in_cycle_idle := false
var _sit_idle_elapsed := 0.0
var _cycle_dust_scale := 1.0
const CYCLE_IDLE_HOLD_SECONDS := 3.2
const CYCLE_IDLE_SPLIT_T := 0.65
var _last_phase := "prepare"
var _last_impact_center := Vector3.ZERO
var _impact_triggered := false
var _shake_intensity := 0.0
var _shake_time := 0.0

var _targets: Array[Dictionary] = []
var _dust_root: Node3D
var _dust_puffs: Array[Dictionary] = []
var _shock_ring: MeshInstance3D
var _zone_ring: MeshInstance3D
var _zone_disc: MeshInstance3D

# HUD controls
var _phase_label: Label
var _time_label: Label
var _skin_label: Label
var _slider: HSlider
var _updating_slider := false
var _play_button: Button
var _loop_button: Button
var _speed_button: Button


func _ready() -> void:
	_build_environment()
	_build_ground()
	_build_giant()
	_build_targets()
	_build_dust_vfx()
	_build_camera()
	_build_ui()
	reset_preview()


func _exit_tree() -> void:
	var audio := get_node_or_null("/root/HarborAudio")
	if audio != null:
		if audio.has_method("stop_camera_shake"):
			audio.call("stop_camera_shake")
		if audio.has_method("stop_gameplay_audio"):
			audio.call("stop_gameplay_audio")


func _build_environment() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.48, 0.68)
	sky_mat.sky_horizon_color = Color(0.76, 0.71, 0.64)
	sky_mat.ground_bottom_color = Color(0.24, 0.27, 0.30)
	sky_mat.ground_horizon_color = Color(0.56, 0.55, 0.52)
	sky.sky_material = sky_mat
	env.environment.sky = sky
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment.ambient_light_energy = 0.44
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-44.0, 34.0, 0.0)
	sun.light_color = Color(1.0, 0.94, 0.85)
	sun.light_energy = 0.96
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-22.0, -145.0, 0.0)
	fill.light_color = Color(0.76, 0.84, 0.96)
	fill.light_energy = 0.28
	add_child(fill)


func _build_ground() -> void:
	var body := StaticBody3D.new()
	body.name = "Ground"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)

	var col := CollisionShape3D.new()
	var shape := WorldBoundaryShape3D.new()
	col.shape = shape
	body.add_child(col)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(180.0, 180.0)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.27, 0.29, 0.32)
	gmat.roughness = 0.94
	ground.material_override = gmat
	add_child(ground)

	# Subtle harbor lane lines for clean scale & motion readability.
	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.albedo_color = Color(0.68, 0.70, 0.72, 0.35)
	line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	for offset in [-24.0, -12.0, 0.0, 12.0, 24.0]:
		var line_x := MeshInstance3D.new()
		var bx := BoxMesh.new()
		bx.size = Vector3(60.0, 0.012, 0.14)
		line_x.mesh = bx
		line_x.position = Vector3(0.0, 0.008, offset)
		line_x.material_override = line_mat
		line_x.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(line_x)

		var line_z := MeshInstance3D.new()
		var bz := BoxMesh.new()
		bz.size = Vector3(0.14, 0.012, 60.0)
		line_z.mesh = bz
		line_z.position = Vector3(offset, 0.008, 0.0)
		line_z.material_override = line_mat
		line_z.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(line_z)

	# Wide area-clear indicator zone underneath the giant's sit-crush landing patch.
	_zone_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = IMPACT_RADIUS - 0.18
	torus.outer_radius = IMPACT_RADIUS
	torus.rings = 64
	torus.ring_segments = 8
	_zone_ring.mesh = torus
	_zone_ring.position = Vector3(TARGET_CENTER.x, 0.025, TARGET_CENTER.z)
	var zmat := StandardMaterial3D.new()
	zmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	zmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	zmat.albedo_color = Color(ZONE_COLOR, 0.68)
	_zone_ring.material_override = zmat
	_zone_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_zone_ring)

	_zone_disc = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = IMPACT_RADIUS
	disc.bottom_radius = IMPACT_RADIUS
	disc.height = 0.016
	disc.radial_segments = 64
	_zone_disc.mesh = disc
	_zone_disc.position = Vector3(TARGET_CENTER.x, 0.016, TARGET_CENTER.z)
	var dmat := StandardMaterial3D.new()
	dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dmat.albedo_color = Color(ZONE_COLOR, 0.14)
	_zone_disc.material_override = dmat
	_zone_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_zone_disc)


func _build_giant() -> void:
	giant = GIANT_SCENE.instantiate() as CharacterBody3D
	add_child(giant)
	giant.call("_set_skin", &"Kawaii")
	_ground_giant()
	giant.show_motion(0.0, -1.0, 0.0)


func _ground_giant() -> void:
	if giant == null:
		return
	giant.velocity = Vector3(0.0, -2.0, 0.0)
	giant.move_and_slide()
	giant.position.y = 0.0


func _build_targets() -> void:
	var targets_root := Node3D.new()
	targets_root.name = "TestTargets"
	add_child(targets_root)

	# 6 humans inside the tight seated footprint (r <= 4.4m) + 2 outside reference humans (r ~ 5.5m)
	# so the tight seated impact boundary is immediately verifiable.
	var human_spots: Array[Vector3] = [
		Vector3(0.0, 0.0, -2.9),
		Vector3(-1.6, 0.0, -2.4),
		Vector3(1.7, 0.0, -2.5),
		Vector3(-0.9, 0.0, -4.4),
		Vector3(1.1, 0.0, -4.2),
		Vector3(0.1, 0.0, -5.2),
		Vector3(-4.4, 0.0, -6.2),
		Vector3(4.6, 0.0, -5.9),
	]
	for i in human_spots.size():
		var holder := Node3D.new()
		holder.name = "TargetHuman%d" % (i + 1)
		holder.position = human_spots[i]
		var away := (human_spots[i] - TARGET_CENTER)
		if away.length_squared() < 0.01:
			away = Vector3(0.3, 0.0, -1.0)
		away = away.normalized()
		holder.rotation.y = atan2(away.x, away.z)
		var model := HUMAN_MODEL.instantiate() as Node3D
		model.scale = Vector3.ONE * 1.0
		holder.add_child(model)
		targets_root.add_child(holder)
		var anim := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if anim != null and anim.has_animation(&"idle"):
			anim.get_animation(&"idle").loop_mode = Animation.LOOP_LINEAR
			anim.play(&"idle")
		_targets.append({
			"node": holder,
			"anim": anim,
			"origin": human_spots[i],
			"flee_dir": away,
			"is_human": true,
			"flattened": false,
			"flatten_t": 0.0,
		})

	# Small harbor props inside the tight seated footprint that flatten under her weight.
	var crate_specs := [
		{"pos": Vector3(-2.4, 0.0, -2.3), "size": Vector3(1.8, 1.5, 1.8), "color": Color("#b97843")},
		{"pos": Vector3(2.5, 0.0, -2.4), "size": Vector3(1.9, 1.4, 1.6), "color": Color("#4f738a")},
		{"pos": Vector3(-1.8, 0.0, -5.2), "size": Vector3(1.7, 1.3, 1.7), "color": Color("#995843")},
		{"pos": Vector3(2.0, 0.0, -5.0), "size": Vector3(1.8, 1.4, 1.5), "color": Color("#5d7d59")},
	]
	for i in crate_specs.size():
		var spec: Dictionary = crate_specs[i]
		var holder := Node3D.new()
		holder.name = "TargetCrate%d" % (i + 1)
		holder.position = spec["pos"]
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = spec["size"]
		mi.mesh = box
		mi.position.y = (spec["size"] as Vector3).y * 0.5
		var mat := StandardMaterial3D.new()
		mat.albedo_color = spec["color"]
		mat.roughness = 0.82
		mi.material_override = mat
		holder.add_child(mi)
		targets_root.add_child(holder)
		_targets.append({
			"node": holder,
			"anim": null,
			"origin": spec["pos"],
			"flee_dir": Vector3.ZERO,
			"is_human": false,
			"flattened": false,
			"flatten_t": 0.0,
		})


func _build_dust_vfx() -> void:
	_dust_root = Node3D.new()
	_dust_root.name = "SitCrushDustVFX"
	_dust_root.position = TARGET_CENTER
	add_child(_dust_root)

	# Crisp expanding shockwave ring right on impact.
	_shock_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.84
	torus.outer_radius = 1.0
	torus.rings = 64
	torus.ring_segments = 8
	_shock_ring.mesh = torus
	_shock_ring.position.y = 0.16
	_shock_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var rmat := StandardMaterial3D.new()
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rmat.albedo_color = Color(RING_COLOR, 0.0)
	_shock_ring.material_override = rmat
	_shock_ring.visible = false
	_dust_root.add_child(_shock_ring)

	# 36 soft radial-feathered billboard dust clouds forming a full 360-degree ground collar that blasts
	# outward on impact, lingers thick through sit & rock, then slowly thins out and clears as she stands up!
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261125
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.42, 0.78, 1.0])
	grad.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.92),
		Color(0.96, 0.94, 0.90, 0.62),
		Color(0.90, 0.87, 0.82, 0.18),
		Color(0.88, 0.85, 0.80, 0.0),
	])
	var dust_tex := GradientTexture2D.new()
	dust_tex.gradient = grad
	dust_tex.fill = GradientTexture2D.FILL_RADIAL
	dust_tex.fill_from = Vector2(0.5, 0.5)
	dust_tex.fill_to = Vector2(0.5, 0.0)
	dust_tex.width = 64
	dust_tex.height = 64

	var puff_mesh := QuadMesh.new()
	puff_mesh.size = Vector2(2.2, 1.8)
	for i in 36:
		var angle := (float(i) / 36.0) * TAU + rng.randf_range(-0.07, 0.07)
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		var mi := MeshInstance3D.new()
		mi.mesh = puff_mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var pmat := StandardMaterial3D.new()
		pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		pmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		pmat.billboard_keep_scale = true
		pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		pmat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		pmat.albedo_texture = dust_tex
		pmat.albedo_color = Color(DUST_COLOR.lerp(Color("#dfd1bc"), rng.randf_range(0.0, 0.35)), 0.0)
		mi.material_override = pmat
		mi.visible = false
		_dust_root.add_child(mi)
		_dust_puffs.append({
			"mesh": mi,
			"mat": pmat,
			"dir": dir,
			"inner_r": rng.randf_range(1.4, 2.6),
			"outer_r": rng.randf_range(4.4, 6.8),
			"base_scale": rng.randf_range(1.4, 2.2),
			"peak_scale": rng.randf_range(2.8, 4.4),
			"lift_h": rng.randf_range(1.0, 2.4),
			"peak_alpha": rng.randf_range(0.52, 0.72),
			"drift_phase": rng.randf_range(0.0, TAU),
		})


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 44.0
	_camera.near = 0.1
	_camera.far = 400.0
	add_child(_camera)
	_camera.current = true
	_update_camera_transform()


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "PreviewHUD"
	add_child(layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(16, 16)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.10, 0.12, 0.84)
	style.border_color = Color(0.95, 0.62, 0.30, 0.72)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	layer.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(360, 0)
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "巨人动作测试预览 · 坐压 / 坐姿待机（未接入正式玩法）"
	title.add_theme_color_override("font_color", Color("#f6ede0"))
	vbox.add_child(title)

	var info_row := HBoxContainer.new()
	info_row.add_theme_constant_override("separation", 12)
	vbox.add_child(info_row)

	_phase_label = Label.new()
	_phase_label.text = "阶段：准备下蹲"
	_phase_label.add_theme_color_override("font_color", Color("#ffa64c"))
	info_row.add_child(_phase_label)

	_time_label = Label.new()
	_time_label.text = "0.00s / 4.80s (0%)"
	_time_label.add_theme_color_override("font_color", Color("#d4dbe2"))
	info_row.add_child(_time_label)

	_skin_label = Label.new()
	_skin_label.text = "外观：Kawaii"
	_skin_label.add_theme_color_override("font_color", Color("#8ad7c6"))
	vbox.add_child(_skin_label)

	_slider = HSlider.new()
	_slider.min_value = 0.0
	_slider.max_value = 1.0
	_slider.step = 0.001
	_slider.value_changed.connect(_on_slider_changed)
	vbox.add_child(_slider)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	vbox.add_child(btn_row)

	_play_button = Button.new()
	_play_button.text = "暂停 [Space]"
	_play_button.pressed.connect(toggle_play)
	btn_row.add_child(_play_button)

	var replay_btn := Button.new()
	replay_btn.text = "重播 [R]"
	replay_btn.pressed.connect(func() -> void: reset_preview())
	btn_row.add_child(replay_btn)

	_loop_button = Button.new()
	_loop_button.text = "循环:开 [L]"
	_loop_button.pressed.connect(toggle_loop)
	btn_row.add_child(_loop_button)

	_speed_button = Button.new()
	_speed_button.text = "1.0x [T]"
	_speed_button.pressed.connect(cycle_speed)
	btn_row.add_child(_speed_button)

	var skin_row := HBoxContainer.new()
	skin_row.add_theme_constant_override("separation", 6)
	vbox.add_child(skin_row)
	for entry in [[&"Kawaii", "1:Kawaii"], [&"Hina", "2:Hina"], [&"Chibi Catgirl", "3:Catgirl"], [&"Snow Fox", "4:SnowFox"]]:
		var b := Button.new()
		b.text = entry[1]
		var sname: StringName = entry[0]
		b.pressed.connect(func() -> void: set_skin(sname))
		skin_row.add_child(b)

	var walk_btn := Button.new()
	walk_btn.text = "行走→转身→坐压 [W]"
	walk_btn.pressed.connect(start_walk_transition_test)
	skin_row.add_child(walk_btn)

	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 6)
	vbox.add_child(mode_row)

	var idle_btn := Button.new()
	idle_btn.text = "坐姿待机 [I]"
	idle_btn.pressed.connect(func() -> void: start_sit_idle_preview())
	mode_row.add_child(idle_btn)

	var cycle_btn := Button.new()
	cycle_btn.text = "转身→坐下→待机→起身 [C]"
	cycle_btn.pressed.connect(func() -> void: start_sit_cycle_preview())
	mode_row.add_child(cycle_btn)

	var cam_row := HBoxContainer.new()
	cam_row.add_theme_constant_override("separation", 4)
	vbox.add_child(cam_row)
	for i in CAMERA_PRESETS.size():
		var b := Button.new()
		b.text = CAMERA_PRESETS[i]["name"]
		var idx := i
		b.pressed.connect(func() -> void: set_camera_preset(idx))
		cam_row.add_child(b)

	var hint := Label.new()
	hint.text = "左键拖动旋转视角 · 滚轮缩放 · 拖动进度条逐帧检查"
	hint.add_theme_color_override("font_color", Color("#9ba5b0"))
	vbox.add_child(hint)


func reset_preview(autoplay := true, with_turn := true) -> void:
	_mode_walk_intro = false
	_walk_intro_time = 0.0
	_mode_turn_intro = with_turn
	_turn_elapsed = 0.0
	_turn_steps_taken = 0
	_walk_outro_time = -1.0
	_mode_sit_idle_only = false
	_mode_sit_cycle = false
	_in_cycle_idle = false
	_sit_idle_elapsed = 0.0
	_cycle_dust_scale = 1.0
	_progress = 0.0
	_impact_triggered = false
	_shake_intensity = 0.0
	_shake_time = 0.0
	_playing = autoplay
	if _play_button != null:
		_play_button.text = "暂停 [Space]" if _playing else "播放 [Space]"
	giant.finish_sit_crush(true)
	giant.finish_sit_idle(true)
	giant.position = Vector3.ZERO
	giant.rotation = Vector3.ZERO if with_turn else Vector3(0.0, TURN_TARGET_YAW, 0.0)
	_ground_giant()
	giant.call("_reset_turn_tracks")
	giant.show_motion(0.0, -1.0, 0.0)
	_reset_targets()
	_update_vfx(0.0, 0.0, TARGET_CENTER)
	if with_turn:
		_last_phase = "turn"
		_last_impact_center = TARGET_CENTER
		_update_camera_transform()
		_update_hud_turn()
	else:
		_apply_sit_frame(0.0, 0.0)


func start_walk_transition_test() -> void:
	reset_preview(true, true)
	_mode_walk_intro = true
	_walk_intro_time = 0.0
	_walk_outro_time = -1.0
	giant.position = Vector3(0.0, 0.0, 6.0)
	giant.rotation = Vector3.ZERO
	_ground_giant()
	giant.call("_reset_turn_tracks")


func start_sit_idle_preview(autoplay := true) -> void:
	reset_preview(autoplay, false)
	_mode_sit_idle_only = true
	_progress = CYCLE_IDLE_SPLIT_T
	_impact_triggered = true
	_sit_idle_elapsed = 0.0
	var res: Dictionary = giant.show_sit_idle(0.0, false)
	_last_phase = "sit_idle"
	_last_impact_center = res["pelvis_world"]
	_flatten_targets_in_zone(_last_impact_center)
	_update_targets(CYCLE_IDLE_SPLIT_T, 0.0)
	_update_vfx(CYCLE_IDLE_SPLIT_T, 0.35, _last_impact_center)
	_update_camera_transform()
	_update_hud_sit_idle()


func start_sit_cycle_preview(autoplay := true) -> void:
	reset_preview(autoplay, true)
	_mode_sit_cycle = true
	_in_cycle_idle = false
	_sit_idle_elapsed = 0.0


func toggle_play() -> void:
	_playing = not _playing
	if _play_button != null:
		_play_button.text = "暂停 [Space]" if _playing else "播放 [Space]"


func toggle_loop() -> void:
	_looping = not _looping
	if _loop_button != null:
		_loop_button.text = ("循环:开 [L]" if _looping else "循环:关 [L]")


func cycle_speed() -> void:
	if is_equal_approx(_speed_scale, 1.0):
		_speed_scale = 0.5
	elif is_equal_approx(_speed_scale, 0.5):
		_speed_scale = 0.25
	else:
		_speed_scale = 1.0
	if _speed_button != null:
		_speed_button.text = "%.2gx [T]" % _speed_scale


func set_skin(sname: StringName) -> void:
	giant.call("_set_skin", sname)
	if _skin_label != null:
		_skin_label.text = "外观：%s" % String(sname)
	if _mode_sit_idle_only or _in_cycle_idle:
		giant.show_sit_idle(0.0, false)
	elif _mode_turn_intro or _mode_walk_intro or _walk_outro_time >= 0.0:
		giant.show_motion(0.0, -1.0, 0.0)
	else:
		_apply_sit_frame(_progress, 0.0)


func set_camera_preset(index: int) -> void:
	var preset: Dictionary = CAMERA_PRESETS[clampi(index, 0, CAMERA_PRESETS.size() - 1)]
	_orbit_yaw = preset["yaw"]
	_orbit_pitch = preset["pitch"]
	_orbit_dist = preset["dist"]
	_orbit_target = preset["target"]
	_update_camera_transform()


func set_progress(t: float) -> void:
	var was_before_sit := _mode_turn_intro or _mode_walk_intro
	_mode_walk_intro = false
	_mode_turn_intro = false
	_mode_sit_idle_only = false
	_in_cycle_idle = false
	_walk_outro_time = -1.0
	if was_before_sit:
		giant.position = Vector3.ZERO
		giant.rotation = Vector3(0.0, TURN_TARGET_YAW, 0.0)
		_ground_giant()
		giant.call("_reset_turn_tracks")
	_progress = clampf(t, 0.0, 1.0)
	if _progress < giant.SIT_CRUSH_IMPACT_TIME:
		_impact_triggered = false
		_shake_intensity = 0.0
		_reset_targets()
	_apply_sit_frame(_progress, 0.0)


func step_preview(delta: float) -> Dictionary:
	var dt := clampf(delta, 0.0, 0.05) * _speed_scale
	if _mode_sit_idle_only:
		_sit_idle_elapsed += dt
		var res: Dictionary = giant.show_sit_idle(dt, false)
		_last_phase = "sit_idle"
		_last_impact_center = res["pelvis_world"]
		_update_vfx(CYCLE_IDLE_SPLIT_T, 0.32, _last_impact_center)
		_update_camera_transform()
		_update_hud_sit_idle()
		return get_preview_state()

	if _mode_walk_intro:
		_walk_intro_time += dt
		var speed := 7.0
		giant.position.z = maxf(0.0, 6.0 - _walk_intro_time * speed)
		_ground_giant()
		giant.show_motion(speed, -1.0, dt)
		_last_phase = "walk"
		if _walk_intro_time >= 0.85:
			_mode_walk_intro = false
			giant.position = Vector3.ZERO
			_ground_giant()
			_mode_turn_intro = true
			_turn_elapsed = 0.0
			_turn_steps_taken = 0
			_progress = 0.0
			_impact_triggered = false
		_update_camera_transform()
		return get_preview_state()

	if _mode_turn_intro:
		_turn_elapsed += dt
		_ground_giant()
		var tres: Dictionary = giant.step_turn_in_place(TURN_TARGET_YAW, dt)
		_turn_steps_taken = maxi(_turn_steps_taken, int(tres["step_count"]))
		_last_phase = "turn"
		_last_impact_center = TARGET_CENTER
		_update_vfx(0.0, 0.0, TARGET_CENTER)
		if _zone_ring != null:
			var pulse := 0.5 + 0.5 * sin(_turn_elapsed * 4.2)
			(_zone_ring.material_override as StandardMaterial3D).albedo_color.a = 0.42 + 0.34 * pulse
			(_zone_disc.material_override as StandardMaterial3D).albedo_color.a = 0.10 + 0.10 * pulse
		_update_camera_transform()
		_update_hud_turn()
		if tres["done"] or _turn_elapsed >= 6.5:
			_mode_turn_intro = false
			_progress = 0.0
			_impact_triggered = false
		return get_preview_state()

	if _walk_outro_time >= 0.0:
		_walk_outro_time += dt
		giant.show_motion(0.0, -1.0, dt)
		if _walk_outro_time >= 0.55:
			if _looping:
				if _mode_sit_cycle:
					start_sit_cycle_preview(true)
				else:
					reset_preview(true)
			else:
				_walk_outro_time = -1.0
				_playing = false
		_update_camera_transform()
		return get_preview_state()

	if _in_cycle_idle:
		_sit_idle_elapsed += dt
		var res: Dictionary = giant.show_sit_idle(dt, true)
		_last_phase = "sit_idle"
		_last_impact_center = res["pelvis_world"]
		var hold_dust := lerpf(1.0, 0.58, clampf(_sit_idle_elapsed / CYCLE_IDLE_HOLD_SECONDS, 0.0, 1.0))
		_cycle_dust_scale = hold_dust
		_update_vfx(CYCLE_IDLE_SPLIT_T, hold_dust, _last_impact_center)
		_update_camera_transform()
		_update_hud_sit_idle()
		if _sit_idle_elapsed >= CYCLE_IDLE_HOLD_SECONDS:
			_in_cycle_idle = false
			_progress = CYCLE_IDLE_SPLIT_T
		return get_preview_state()

	var prev_progress := _progress
	_progress += dt / giant.SIT_CRUSH_DURATION
	if _mode_sit_cycle and prev_progress < CYCLE_IDLE_SPLIT_T and _progress >= CYCLE_IDLE_SPLIT_T:
		_progress = CYCLE_IDLE_SPLIT_T
		_apply_sit_frame(_progress, dt)
		_in_cycle_idle = true
		_sit_idle_elapsed = 0.0
		return get_preview_state()

	if _progress >= 1.0:
		_progress = 1.0
		_apply_sit_frame(_progress, dt)
		giant.finish_sit_crush()
		_walk_outro_time = 0.0
		return get_preview_state()

	_apply_sit_frame(_progress, dt)
	return get_preview_state()


func get_preview_state() -> Dictionary:
	var flattened_count := 0
	var in_zone_count := 0
	for item in _targets:
		var orig: Vector3 = item["origin"]
		if Vector2(orig.x - TARGET_CENTER.x, orig.z - TARGET_CENTER.z).length() <= IMPACT_RADIUS:
			in_zone_count += 1
		if item["flattened"]:
			flattened_count += 1
	var visible_puffs := 0
	var max_puff_alpha := 0.0
	for p in _dust_puffs:
		var m: MeshInstance3D = p["mesh"]
		var mat: StandardMaterial3D = p["mat"]
		if m.visible and mat.albedo_color.a > 0.01:
			visible_puffs += 1
			max_puff_alpha = maxf(max_puff_alpha, mat.albedo_color.a)
	var turned_deg := rad_to_deg(absf(angle_difference(0.0, giant.rotation.y)))
	return {
		"progress": _progress,
		"phase": _last_phase,
		"turning": _mode_turn_intro,
		"turn_yaw_deg": turned_deg,
		"turn_steps": _turn_steps_taken,
		"sit_idle_time": _sit_idle_elapsed,
		"impact_triggered": _impact_triggered,
		"impact_center": _last_impact_center,
		"shake_intensity": _shake_intensity,
		"flattened_targets": flattened_count,
		"in_zone_targets": in_zone_count,
		"total_targets": _targets.size(),
		"visible_dust_puffs": visible_puffs,
		"max_dust_alpha": max_puff_alpha,
		"skin": String(giant.skin_name),
	}


func _physics_process(delta: float) -> void:
	if _playing:
		step_preview(delta)
	elif _shake_intensity > 0.001:
		_shake_intensity = maxf(0.0, _shake_intensity - delta * 2.5)
		_update_camera_transform()


func _apply_sit_frame(t: float, dt: float) -> void:
	var res: Dictionary = giant.show_sit_crush(t, dt)
	_last_phase = res["phase"]
	_last_impact_center = res["pelvis_world"]
	var dust_alpha: float = res["dust_alpha"]
	if _mode_sit_cycle and t >= CYCLE_IDLE_SPLIT_T:
		dust_alpha *= _cycle_dust_scale

	if res["impact_just_hit"] or (t >= giant.SIT_CRUSH_IMPACT_TIME and not _impact_triggered):
		_impact_triggered = true
		_shake_intensity = 1.0
		_shake_time = 0.0
		_play_impact_audio(_last_impact_center)
		_flatten_targets_in_zone(_last_impact_center)

	if dt > 0.0 and _shake_intensity > 0.0:
		_shake_time += dt
		_shake_intensity = maxf(0.0, _shake_intensity - dt * 1.55)

	_update_targets(t, dt)
	_update_vfx(t, dust_alpha, _last_impact_center)
	_update_camera_transform()
	_update_hud(t)


func _reset_targets() -> void:
	for item in _targets:
		var n: Node3D = item["node"]
		n.position = item["origin"]
		n.scale = Vector3.ONE
		item["flattened"] = false
		item["flatten_t"] = 0.0
		var anim: AnimationPlayer = item["anim"]
		if anim != null and anim.has_animation(&"idle"):
			anim.play(&"idle")
			anim.speed_scale = 1.0


func _flatten_targets_in_zone(center: Vector3) -> void:
	for item in _targets:
		var n: Node3D = item["node"]
		var d := Vector2(n.position.x - center.x, n.position.z - center.z).length()
		if d <= IMPACT_RADIUS:
			item["flattened"] = true
			var anim: AnimationPlayer = item["anim"]
			if anim != null:
				anim.stop()


func _update_targets(t: float, dt: float) -> void:
	# Tiny targets notice her squatting and scramble slightly outward — telegraphing that she's
	# about to sit, yet too fast on the drop for those inside the tight footprint to escape!
	for item in _targets:
		var n: Node3D = item["node"]
		if item["flattened"]:
			var ft: float = clampf(inverse_lerp(giant.SIT_CRUSH_IMPACT_TIME, giant.SIT_CRUSH_IMPACT_TIME + 0.032, t), 0.0, 1.0)
			if dt <= 0.0:
				ft = 1.0 if t >= giant.SIT_CRUSH_IMPACT_TIME else 0.0
			item["flatten_t"] = ft
			var squash := smoothstep(0.0, 1.0, ft)
			# Extra slight packing press during seated left-right rock!
			var pack := 0.015 * smoothstep(0.45, 0.62, t)
			n.scale = Vector3(
				lerpf(1.0, 1.58, squash),
				maxf(0.045, lerpf(1.0, 0.065, squash) - pack),
				lerpf(1.0, 1.58, squash)
			)
		elif item["is_human"]:
			var flee_u := smoothstep(0.14, giant.SIT_CRUSH_IMPACT_TIME, t)
			var origin: Vector3 = item["origin"]
			var dir: Vector3 = item["flee_dir"]
			n.position = origin + dir * (1.0 * flee_u)
			n.scale = Vector3.ONE
			var anim: AnimationPlayer = item["anim"]
			if anim != null:
				if t >= 0.14 and t < giant.SIT_CRUSH_IMPACT_TIME and anim.has_animation(&"walk"):
					if anim.current_animation != &"walk":
						anim.play(&"walk")
					anim.speed_scale = 2.0
				elif anim.has_animation(&"idle") and anim.current_animation != &"idle":
					anim.play(&"idle")
					anim.speed_scale = 1.0


func _update_vfx(t: float, dust_alpha: float, center: Vector3) -> void:
	# Zone indicator pulses gently during preparation & drop, fades after impact.
	var warn_alpha := smoothstep(0.02, 0.16, t) * (1.0 - smoothstep(giant.SIT_CRUSH_IMPACT_TIME, giant.SIT_CRUSH_IMPACT_TIME + 0.08, t))
	if _zone_ring != null:
		(_zone_ring.material_override as StandardMaterial3D).albedo_color.a = 0.25 + 0.68 * warn_alpha
		(_zone_disc.material_override as StandardMaterial3D).albedo_color.a = 0.06 + 0.22 * warn_alpha

	_dust_root.position = Vector3(center.x, 0.0, center.z)
	if t < giant.SIT_CRUSH_IMPACT_TIME:
		_shock_ring.visible = false
		for p in _dust_puffs:
			(p["mesh"] as MeshInstance3D).visible = false
			(p["mat"] as StandardMaterial3D).albedo_color.a = 0.0
		return

	# Outward shockwave ring right at impact ("灰往外一圈").
	var wave_u := clampf(inverse_lerp(giant.SIT_CRUSH_IMPACT_TIME, giant.SIT_CRUSH_IMPACT_TIME + 0.12, t), 0.0, 1.0)
	_shock_ring.visible = wave_u < 1.0
	if _shock_ring.visible:
		var r := lerpf(1.4, IMPACT_RADIUS * 1.65, 1.0 - pow(1.0 - wave_u, 2.2))
		_shock_ring.scale = Vector3(r, 1.0, r)
		(_shock_ring.material_override as StandardMaterial3D).albedo_color.a = (1.0 - wave_u) * 0.92

	# 360-degree billowing dust collar: blasts outward fast on impact, lingers thick through sit & rock,
	# then slowly rises and clears away as she stands up ("灰尘这时候才慢慢散开")!
	var expand_u := clampf(inverse_lerp(giant.SIT_CRUSH_IMPACT_TIME, giant.SIT_CRUSH_IMPACT_TIME + 0.13, t), 0.0, 1.0)
	var expand_ease := 1.0 - pow(1.0 - expand_u, 2.6)
	var slow_drift := smoothstep(giant.SIT_CRUSH_IMPACT_TIME + 0.10, 1.0, t)
	var rise_clear := smoothstep(giant.SIT_CRUSH_RISE_START, 1.0, t)
	for p in _dust_puffs:
		var mi: MeshInstance3D = p["mesh"]
		var mat: StandardMaterial3D = p["mat"]
		var alpha: float = p["peak_alpha"] * dust_alpha
		mi.visible = alpha > 0.008
		mat.albedo_color.a = alpha
		if not mi.visible:
			continue
		var dir: Vector3 = p["dir"]
		var r := lerpf(float(p["inner_r"]), float(p["outer_r"]), expand_ease) + slow_drift * 1.6
		var h := lerpf(0.55, float(p["lift_h"]), expand_ease) + rise_clear * 1.8 + sin(t * 14.0 + float(p["drift_phase"])) * 0.14
		var sc := lerpf(float(p["base_scale"]), float(p["peak_scale"]), expand_ease) * (1.0 + rise_clear * 0.45)
		mi.position = dir * r + Vector3.UP * h
		mi.scale = Vector3(sc * 1.15, sc * 0.68, sc * 1.15)


func _play_impact_audio(at: Vector3) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var audio := get_node_or_null("/root/HarborAudio")
	if audio == null:
		return
	if audio.has_method("play_giant_impact"):
		audio.call("play_giant_impact", at, 25.2)
	if audio.has_method("play_camera_shake"):
		audio.call("play_camera_shake", 0.92, 25.2)


func _update_camera_transform() -> void:
	if _camera == null:
		return
	var offset := Vector3(
		sin(_orbit_yaw) * cos(_orbit_pitch),
		-sin(_orbit_pitch),
		-cos(_orbit_yaw) * cos(_orbit_pitch)
	) * _orbit_dist
	var shake := Vector3.ZERO
	if _shake_intensity > 0.001:
		var amp := _shake_intensity * _shake_intensity * 1.15
		shake = Vector3(
			sin(_shake_time * 52.0) * 0.45,
			cos(_shake_time * 68.0) * 0.85,
			sin(_shake_time * 43.0 + 1.2) * 0.35
		) * amp
	var cam_pos := _orbit_target + offset + shake
	cam_pos.y = maxf(cam_pos.y, 0.8)
	_camera.look_at_from_position(cam_pos, _orbit_target + shake * 0.35, Vector3.UP)


func _update_hud_turn() -> void:
	if _phase_label == null:
		return
	var turned_deg := int(round(rad_to_deg(absf(angle_difference(0.0, giant.rotation.y)))))
	_phase_label.text = "阶段：原地 180° 转身（背对前方目标 · 第 %d 步）" % maxi(_turn_steps_taken, 1)
	_time_label.text = "已转 %d° / 180° (%.2fs)" % [turned_deg, _turn_elapsed]
	_updating_slider = true
	_slider.value = 0.0
	_updating_slider = false


func _update_hud_sit_idle() -> void:
	if _phase_label == null:
		return
	if _mode_sit_idle_only:
		_phase_label.text = "阶段：坐姿待机（呼吸/搭膝/环视/微晃）"
		_time_label.text = "坐姿待机 %.2fs（循环）" % _sit_idle_elapsed
	else:
		_phase_label.text = "阶段：坐姿待机（坐下后停留）"
		_time_label.text = "停留 %.2fs / %.2fs" % [_sit_idle_elapsed, CYCLE_IDLE_HOLD_SECONDS]
	_updating_slider = true
	_slider.value = CYCLE_IDLE_SPLIT_T
	_updating_slider = false


func _update_hud(t: float) -> void:
	if _phase_label == null:
		return
	var phase_cn := "准备下蹲（看目标/站稳/张臂）"
	if t >= giant.SIT_CRUSH_RISE_START:
		phase_cn = "撑地起身（手撑地/腿蹬起/灰散开）"
	elif t >= giant.SIT_CRUSH_ROCK_START:
		phase_cn = "坐压晃动（左右压实/稳住）"
	elif t >= giant.SIT_CRUSH_IMPACT_TIME:
		phase_cn = "重压落定（震地/灰圈/发丝回落）"
	elif t >= giant.SIT_CRUSH_DROP_START:
		phase_cn = "高速下落（胯下沉/发丝飘起）"
	_phase_label.text = "阶段：%s" % phase_cn
	_time_label.text = "%.2fs / %.2fs (%d%%)" % [t * giant.SIT_CRUSH_DURATION, giant.SIT_CRUSH_DURATION, int(round(t * 100.0))]
	_updating_slider = true
	_slider.value = t
	_updating_slider = false


func _on_slider_changed(val: float) -> void:
	if _updating_slider:
		return
	_playing = false
	if _play_button != null:
		_play_button.text = "播放 [Space]"
	set_progress(val)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_orbit_dist = maxf(10.0, _orbit_dist - 2.5)
			_update_camera_transform()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_orbit_dist = minf(75.0, _orbit_dist + 2.5)
			_update_camera_transform()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_orbit_yaw -= mm.relative.x * 0.008
		_orbit_pitch = clampf(_orbit_pitch - mm.relative.y * 0.006, -1.25, 0.25)
		_update_camera_transform()
	elif event is InputEventKey and event.pressed and not event.echo:
		var k := (event as InputEventKey).physical_keycode
		match k:
			KEY_SPACE:
				toggle_play()
			KEY_R:
				reset_preview(true)
			KEY_L:
				toggle_loop()
			KEY_T:
				cycle_speed()
			KEY_W:
				start_walk_transition_test()
			KEY_I:
				start_sit_idle_preview(true)
			KEY_C:
				start_sit_cycle_preview(true)
			KEY_1:
				set_skin(&"Kawaii")
			KEY_2:
				set_skin(&"Hina")
			KEY_3:
				set_skin(&"Chibi Catgirl")
			KEY_4:
				set_skin(&"Snow Fox")
			KEY_F1:
				set_camera_preset(0)
			KEY_F2:
				set_camera_preset(1)
			KEY_F3:
				set_camera_preset(2)
			KEY_F4:
				set_camera_preset(3)
			KEY_F5:
				set_camera_preset(4)
