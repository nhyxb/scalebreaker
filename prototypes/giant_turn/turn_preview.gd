extends Node3D
## Interactive 3D preview studio for inspecting the giant turning animation prototype.
## Launch directly with:
##   godot --path . res://prototypes/giant_turn/turn_preview.tscn
## Supports desktop keyboard/mouse AND responsive touchscreen controls for Android layout parity.

const ACTOR_SCENE := preload("res://prototypes/giant_turn/giant_turn_actor.tscn")
const FIXED_DT := 1.0 / 60.0

const SCENARIOS := [
	{"id": "stand_l90", "label": "1 站立左转 90°", "desc": "小碎步左转90°，眼→头→胸→胯→脚依次启动"},
	{"id": "stand_r90", "label": "2 站立右转 90°", "desc": "小碎步右转90°，重心压向右腿后迈左脚"},
	{"id": "stand_180", "label": "3 站立掉头 180°", "desc": "大船掉头：左右脚交替5-6小步，脚落地钉死"},
	{"id": "walk_gentle", "label": "4 行走轻转弯", "desc": "缓慢转弯：步幅不变，仅脚尖微偏与轻倾身"},
	{"id": "walk_sharp_l", "label": "5 行走左急转", "desc": "急弯：步子变短变快，外侧右脚迈长、内侧左脚迈短"},
	{"id": "walk_fast_r", "label": "6 高速右急转", "desc": "高速急右转：大幅向内压弯倾身、外臂张开内臂收紧"},
	{"id": "free", "label": "7 自由控制", "desc": "WASD/触屏摇杆控制方向与走停，测试任意变向"},
]

const CAM_PRESETS := [
	{"name": "3/4 正前全身", "yaw": 2.68, "pitch": -0.20, "dist": 38.0, "target_y": 12.4},
	{"name": "正面看眼头胸", "yaw": 3.06, "pitch": -0.08, "dist": 26.0, "target_y": 18.2},
	{"name": "脚部特写", "yaw": 2.48, "pitch": -0.26, "dist": 16.5, "target_y": 2.8},
	{"name": "高角俯视", "yaw": 2.55, "pitch": -0.78, "dist": 46.0, "target_y": 9.5},
	{"name": "后3/4 观察", "yaw": 0.52, "pitch": -0.22, "dist": 38.0, "target_y": 12.2},
]

const SKIN_NAMES: Array[StringName] = [&"Kawaii", &"Hina", &"Chibi Catgirl"]

var _actor: CharacterBody3D
var _camera: Camera3D
var _cam_pivot: Node3D
var _cam_preset_idx := 0
var _cam_yaw := 2.68
var _cam_pitch := -0.20
var _cam_dist := 38.0
var _cam_target_y := 12.4
var _cam_dragging := false
var _cam_drag_touch := -1

var _scenario_idx := 0
var _scenario_time := 0.0
var _skin_idx := 0
var _time_scale := 1.0
var _paused := false
var _show_gizmos := true
var _free_target_yaw := 0.0
var _free_walk_speed := 0.0
var _accum := 0.0

# 3D ground gizmos (target arrow, planted foot pivot rings, COM plumb-bob, footprint marks).
var _gizmo_root: Node3D
var _target_arrow: MeshInstance3D
var _l_pin_ring: MeshInstance3D
var _r_pin_ring: MeshInstance3D
var _com_dot: MeshInstance3D
var _footprint_marks: Array[MeshInstance3D] = []
var _prev_l_planted := true
var _prev_r_planted := true
var _prev_l_piv := Vector3.ZERO
var _prev_r_piv := Vector3.ZERO
var _prev_l_mode := -1
var _prev_r_mode := -1
var _max_observed_slip := 0.0

# HUD & touch UI.
var _telemetry_label: Label
var _status_label: Label
var _mode_btn: Button
var _pause_btn: Button
var _speed_btn: Button
var _skin_btn: Button
var _cam_btn: Button
var _gizmo_btn: Button
var _scenario_buttons: Array[Button] = []
var _joy_origin := Vector2.ZERO
var _joy_vec := Vector2.ZERO
var _joy_touch_idx := -1
var _joy_panel: Control
var _joy_knob: ColorRect


func _ready() -> void:
	_build_environment()
	_build_ground()
	_build_actor()
	_build_camera()
	_build_gizmos()
	_build_ui()
	_select_scenario(0)


func _build_environment() -> void:
	var env := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.24, 0.44, 0.72)
	sky_mat.sky_horizon_color = Color(0.76, 0.80, 0.84)
	sky_mat.ground_bottom_color = Color(0.18, 0.20, 0.24)
	sky_mat.ground_horizon_color = Color(0.55, 0.58, 0.62)
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.65
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, 36.0, 0.0)
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.directional_shadow_max_distance = 180.0
	add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-22.0, -140.0, 0.0)
	fill.light_energy = 0.35
	fill.light_color = Color(0.78, 0.88, 1.0)
	add_child(fill)


func _build_ground() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(600.0, 2.0, 600.0)
	col.shape = box
	col.position = Vector3(0.0, -1.0, 0.0)
	floor_body.add_child(col)
	add_child(floor_body)

	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(520.0, 520.0)
	floor_mesh.mesh = plane

	# High-contrast procedural 2m / 10m grid texture so zero-slip pivoting is visually unmistakable!
	var img := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	for y in 256:
		for x in 256:
			var tile := ((x / 64) + (y / 64)) % 2
			var c := Color(0.30, 0.33, 0.37) if tile == 0 else Color(0.25, 0.28, 0.32)
			if x < 3 or y < 3:
				c = Color(0.55, 0.60, 0.66)
			elif (x % 64) < 2 or (y % 64) < 2:
				c = Color(0.39, 0.43, 0.48)
			img.set_pixel(x, y, c)
	var tex := ImageTexture.create_from_image(img)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.uv1_scale = Vector3(65.0, 65.0, 1.0)
	mat.roughness = 0.88
	floor_mesh.material_override = mat
	add_child(floor_mesh)

	# Compass protractor ring around origin (30 deg ticks, 90 deg cardinal spokes).
	var ring_root := Node3D.new()
	ring_root.position.y = 0.04
	add_child(ring_root)
	for deg in range(0, 360, 30):
		var major := (deg % 90) == 0
		var tick := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.28 if major else 0.14, 0.02, 5.2 if major else 2.2)
		tick.mesh = bm
		var tmat := StandardMaterial3D.new()
		tmat.albedo_color = Color(0.95, 0.72, 0.25) if major else Color(0.62, 0.68, 0.75)
		tmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		tick.material_override = tmat
		var rad := deg_to_rad(float(deg))
		var r := 8.5 if major else 7.2
		tick.position = Vector3(-sin(rad) * r, 0.0, -cos(rad) * r)
		tick.rotation.y = rad
		ring_root.add_child(tick)


func _build_actor() -> void:
	_actor = ACTOR_SCENE.instantiate() as CharacterBody3D
	add_child(_actor)
	_actor.set_skin_by_name(SKIN_NAMES[_skin_idx])
	_actor.reset_turn_state(Vector3.ZERO, 0.0)


func _build_camera() -> void:
	_cam_pivot = Node3D.new()
	add_child(_cam_pivot)
	_camera = Camera3D.new()
	_camera.fov = 52.0
	_camera.near = 0.1
	_camera.far = 600.0
	_cam_pivot.add_child(_camera)
	_update_camera_transform()


func _build_gizmos() -> void:
	_gizmo_root = Node3D.new()
	add_child(_gizmo_root)

	_target_arrow = _make_flat_box(Vector3(0.55, 0.04, 7.5), Color(0.18, 0.90, 0.56))
	_gizmo_root.add_child(_target_arrow)

	_l_pin_ring = _make_cylinder_marker(1.05, Color(0.25, 0.76, 1.0, 0.85))
	_r_pin_ring = _make_cylinder_marker(1.05, Color(1.0, 0.56, 0.20, 0.85))
	_com_dot = _make_cylinder_marker(0.52, Color(0.98, 0.92, 0.28, 0.95))
	_gizmo_root.add_child(_l_pin_ring)
	_gizmo_root.add_child(_r_pin_ring)
	_gizmo_root.add_child(_com_dot)


func _make_flat_box(sz: Vector3, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = sz
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = m
	return mi


func _make_cylinder_marker(radius: float, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = 0.06
	cm.radial_segments = 24
	mi.mesh = cm
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = m
	return mi


func _drop_footprint(world_pos: Vector3, yaw: float, is_left: bool) -> void:
	if not _show_gizmos:
		return
	var mark := _make_flat_box(Vector3(1.15, 0.03, 2.35), Color(0.22, 0.72, 1.0, 0.45) if is_left else Color(1.0, 0.52, 0.18, 0.45))
	(mark.material_override as StandardMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mark.position = Vector3(world_pos.x, 0.05, world_pos.z)
	mark.rotation.y = yaw
	_gizmo_root.add_child(mark)
	_footprint_marks.append(mark)
	if _footprint_marks.size() > 16:
		var old: MeshInstance3D = _footprint_marks.pop_front()
		old.queue_free()


func _clear_footprints() -> void:
	for m in _footprint_marks:
		if is_instance_valid(m):
			m.queue_free()
	_footprint_marks.clear()


func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	# Top-left compact telemetry panel.
	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	panel.custom_minimum_size = Vector2(360, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.09, 0.12, 0.80)
	style.set_border_width_all(1)
	style.border_color = Color(0.32, 0.40, 0.48, 0.7)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	canvas.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "巨人转身动作原型预览（未接入正式玩法）"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(0.98, 0.82, 0.36))
	vbox.add_child(title)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status_label)

	_telemetry_label = Label.new()
	_telemetry_label.add_theme_font_size_override("font_size", 12)
	_telemetry_label.add_theme_color_override("font_color", Color(0.86, 0.92, 0.96))
	vbox.add_child(_telemetry_label)

	# Top-right scrollable scenario & tool panel (touch-sized >= 34px height, adapts cleanly to desktop & Android landscape/portrait).
	var right_scroll := ScrollContainer.new()
	right_scroll.anchor_left = 1.0
	right_scroll.anchor_right = 1.0
	right_scroll.anchor_top = 0.0
	right_scroll.anchor_bottom = 1.0
	right_scroll.offset_left = -236
	right_scroll.offset_right = -10
	right_scroll.offset_top = 12
	right_scroll.offset_bottom = -66
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	canvas.add_child(right_scroll)

	var right_box := VBoxContainer.new()
	right_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_box.add_theme_constant_override("separation", 5)
	right_scroll.add_child(right_box)

	for i in SCENARIOS.size():
		var btn := Button.new()
		btn.text = SCENARIOS[i]["label"]
		btn.custom_minimum_size = Vector2(210, 34)
		btn.pressed.connect(_select_scenario.bind(i))
		right_box.add_child(btn)
		_scenario_buttons.append(btn)

	var sep := HSeparator.new()
	right_box.add_child(sep)

	_mode_btn = _make_btn("模式：新版分层转身", _toggle_layered_mode)
	_skin_btn = _make_btn("皮肤：Kawaii", _cycle_skin)
	_cam_btn = _make_btn("视角：3/4 正前全身", _cycle_camera)
	_speed_btn = _make_btn("倍速：1.0x", _cycle_speed)
	_pause_btn = _make_btn("暂停 / 继续", _toggle_pause)
	_gizmo_btn = _make_btn("地面标尺：开", _toggle_gizmos)
	var replay_btn := _make_btn("重播当前动作 (R)", func() -> void: _select_scenario(_scenario_idx))
	for b in [_mode_btn, _skin_btn, _cam_btn, _speed_btn, _pause_btn, _gizmo_btn, replay_btn]:
		right_box.add_child(b)

	# Bottom touch controls (virtual joystick on bottom-left, quick turn/walk buttons on bottom-right).
	_joy_panel = Panel.new()
	_joy_panel.anchor_top = 1.0
	_joy_panel.anchor_bottom = 1.0
	_joy_panel.offset_left = 20
	_joy_panel.offset_right = 152
	_joy_panel.offset_top = -152
	_joy_panel.offset_bottom = -20
	var jstyle := StyleBoxFlat.new()
	jstyle.bg_color = Color(0.10, 0.14, 0.19, 0.55)
	jstyle.set_border_width_all(2)
	jstyle.border_color = Color(0.55, 0.68, 0.80, 0.65)
	jstyle.set_corner_radius_all(66)
	_joy_panel.add_theme_stylebox_override("panel", jstyle)
	canvas.add_child(_joy_panel)

	_joy_knob = ColorRect.new()
	_joy_knob.color = Color(0.95, 0.80, 0.35, 0.85)
	_joy_knob.size = Vector2(36, 36)
	_joy_knob.position = Vector2(48, 48)
	_joy_panel.add_child(_joy_knob)

	var touch_actions := HBoxContainer.new()
	touch_actions.anchor_left = 0.5
	touch_actions.anchor_right = 0.5
	touch_actions.anchor_top = 1.0
	touch_actions.anchor_bottom = 1.0
	touch_actions.offset_left = -195
	touch_actions.offset_right = 195
	touch_actions.offset_top = -54
	touch_actions.offset_bottom = -14
	touch_actions.add_theme_constant_override("separation", 8)
	canvas.add_child(touch_actions)

	touch_actions.add_child(_make_btn("← 左转90°", func() -> void: _nudge_free_turn(PI * 0.5), 92))
	touch_actions.add_child(_make_btn("180° 掉头", func() -> void: _nudge_free_turn(PI - 0.01), 96))
	touch_actions.add_child(_make_btn("右转90° →", func() -> void: _nudge_free_turn(-PI * 0.5), 92))
	touch_actions.add_child(_make_btn("走 / 停", _toggle_free_walk, 84))


func _make_btn(text: String, cb: Callable, min_w := 210) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(min_w, 34)
	btn.pressed.connect(cb)
	return btn


func _nudge_free_turn(delta_yaw: float) -> void:
	if SCENARIOS[_scenario_idx]["id"] != "free":
		_select_scenario(SCENARIOS.size() - 1)
	_free_target_yaw = wrapf(_free_target_yaw + delta_yaw, -PI, PI)


func _toggle_free_walk() -> void:
	if SCENARIOS[_scenario_idx]["id"] != "free":
		_select_scenario(SCENARIOS.size() - 1)
	_free_walk_speed = 0.0 if _free_walk_speed > 0.1 else 7.0


func _toggle_layered_mode() -> void:
	_actor.use_layered_turn = not _actor.use_layered_turn
	_mode_btn.text = "模式：新版分层转身" if _actor.use_layered_turn else "模式：旧版僵硬直转"
	_select_scenario(_scenario_idx)


func _cycle_skin() -> void:
	_skin_idx = (_skin_idx + 1) % SKIN_NAMES.size()
	_actor.set_skin_by_name(SKIN_NAMES[_skin_idx])
	_skin_btn.text = "皮肤：" + String(SKIN_NAMES[_skin_idx])


func _cycle_camera() -> void:
	_cam_preset_idx = (_cam_preset_idx + 1) % CAM_PRESETS.size()
	var p: Dictionary = CAM_PRESETS[_cam_preset_idx]
	_cam_yaw = p["yaw"]
	_cam_pitch = p["pitch"]
	_cam_dist = p["dist"]
	_cam_target_y = p["target_y"]
	_cam_btn.text = "视角：" + String(p["name"])


func _cycle_speed() -> void:
	if is_equal_approx(_time_scale, 1.0):
		_time_scale = 0.5
	elif is_equal_approx(_time_scale, 0.5):
		_time_scale = 0.25
	else:
		_time_scale = 1.0
	_speed_btn.text = "倍速：%.2gx" % _time_scale


func _toggle_pause() -> void:
	_paused = not _paused
	_pause_btn.text = "继续 (Space)" if _paused else "暂停 (Space)"


func _toggle_gizmos() -> void:
	_show_gizmos = not _show_gizmos
	_gizmo_root.visible = _show_gizmos
	_gizmo_btn.text = "地面标尺：开" if _show_gizmos else "地面标尺：关"


func _select_scenario(idx: int) -> void:
	_scenario_idx = clampi(idx, 0, SCENARIOS.size() - 1)
	_scenario_time = 0.0
	_max_observed_slip = 0.0
	_free_target_yaw = 0.0
	_free_walk_speed = 0.0
	_clear_footprints()
	_actor.reset_turn_state(Vector3.ZERO, 0.0)
	_prev_l_planted = true
	_prev_r_planted = true
	_prev_l_mode = -1
	_prev_r_mode = -1
	_status_label.text = "%s\n%s" % [SCENARIOS[_scenario_idx]["label"], SCENARIOS[_scenario_idx]["desc"]]
	for i in _scenario_buttons.size():
		_scenario_buttons[i].disabled = (i == _scenario_idx)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var kc: Key = event.keycode
		if kc >= KEY_1 and kc <= KEY_7:
			_select_scenario(int(kc - KEY_1))
		elif kc == KEY_R:
			_select_scenario(_scenario_idx)
		elif kc == KEY_TAB:
			_toggle_layered_mode()
		elif kc == KEY_K:
			_cycle_skin()
		elif kc == KEY_C:
			_cycle_camera()
		elif kc == KEY_SPACE:
			_toggle_pause()
		elif kc == KEY_PERIOD and _paused:
			_step_simulation(FIXED_DT)
		elif kc == KEY_G:
			_toggle_gizmos()
		elif kc == KEY_BRACKETLEFT:
			_time_scale = maxf(0.25, _time_scale * 0.5)
			_speed_btn.text = "倍速：%.2gx" % _time_scale
		elif kc == KEY_BRACKETRIGHT:
			_time_scale = minf(1.0, _time_scale * 2.0)
			_speed_btn.text = "倍速：%.2gx" % _time_scale
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			_cam_dragging = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_cam_dist = clampf(_cam_dist * 0.90, 10.0, 95.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_cam_dist = clampf(_cam_dist * 1.12, 10.0, 95.0)
	elif event is InputEventMouseMotion and _cam_dragging:
		var mm := event as InputEventMouseMotion
		_cam_yaw -= mm.relative.x * 0.006
		_cam_pitch = clampf(_cam_pitch - mm.relative.y * 0.005, -1.30, 0.15)
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		var joy_rect := _joy_panel.get_global_rect()
		if st.pressed:
			if joy_rect.has_point(st.position) and _joy_touch_idx < 0:
				_joy_touch_idx = st.index
				_joy_origin = joy_rect.get_center()
				_update_joystick(st.position)
			elif _cam_drag_touch < 0:
				_cam_drag_touch = st.index
		else:
			if st.index == _joy_touch_idx:
				_joy_touch_idx = -1
				_joy_vec = Vector2.ZERO
				_joy_knob.position = Vector2(48, 48)
			elif st.index == _cam_drag_touch:
				_cam_drag_touch = -1
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		if sd.index == _joy_touch_idx:
			_update_joystick(sd.position)
		elif sd.index == _cam_drag_touch:
			_cam_yaw -= sd.relative.x * 0.006
			_cam_pitch = clampf(_cam_pitch - sd.relative.y * 0.005, -1.30, 0.15)


func _update_joystick(pos: Vector2) -> void:
	var delta := pos - _joy_origin
	var radius := 48.0
	if delta.length() > radius:
		delta = delta.normalized() * radius
	_joy_vec = delta / radius
	_joy_knob.position = Vector2(48, 48) + delta
	if SCENARIOS[_scenario_idx]["id"] != "free" and _joy_vec.length() > 0.25:
		_select_scenario(SCENARIOS.size() - 1)


func _process(delta: float) -> void:
	if not _paused:
		_accum += minf(delta, 0.05) * _time_scale
		while _accum >= FIXED_DT:
			_step_simulation(FIXED_DT)
			_accum -= FIXED_DT
	_update_camera_transform()
	_update_gizmos_and_hud()


func _step_simulation(dt: float) -> void:
	_scenario_time += dt
	var sid: String = SCENARIOS[_scenario_idx]["id"]
	var target_yaw := 0.0
	var speed := 0.0

	match sid:
		"stand_l90":
			target_yaw = PI * 0.5 if _scenario_time >= 0.35 else 0.0
			if _scenario_time > 4.2:
				_select_scenario(_scenario_idx)
				return
		"stand_r90":
			target_yaw = -PI * 0.5 if _scenario_time >= 0.35 else 0.0
			if _scenario_time > 4.2:
				_select_scenario(_scenario_idx)
				return
		"stand_180":
			target_yaw = (PI - 0.01) if _scenario_time >= 0.35 else 0.0
			if _scenario_time > 5.4:
				_select_scenario(_scenario_idx)
				return
		"walk_gentle":
			speed = 7.0
			target_yaw = maxf(_scenario_time - 0.5, 0.0) * 0.30
			if _scenario_time > 9.0:
				_select_scenario(_scenario_idx)
				return
		"walk_sharp_l":
			speed = 7.0
			if _scenario_time < 0.7:
				target_yaw = 0.0
			elif _scenario_time < 4.5:
				target_yaw = deg_to_rad(135.0)
			else:
				_select_scenario(_scenario_idx)
				return
		"walk_fast_r":
			speed = 13.0
			if _scenario_time < 0.6:
				target_yaw = 0.0
			elif _scenario_time < 4.2:
				target_yaw = deg_to_rad(-135.0)
			else:
				_select_scenario(_scenario_idx)
				return
		"free":
			var inp := Vector2.ZERO
			if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
				inp.y -= 1.0
			if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
				inp.y += 1.0
			if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
				inp.x -= 1.0
			if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
				inp.x += 1.0
			if _joy_vec.length() > 0.18:
				inp = _joy_vec
			if inp.length() > 0.15:
				var world_dir := Vector3(inp.x, 0.0, inp.y).rotated(Vector3.UP, _cam_yaw).normalized()
				_free_target_yaw = atan2(-world_dir.x, -world_dir.z)
				var sprint := Input.is_key_pressed(KEY_SHIFT)
				speed = (12.5 if sprint else 7.0) * clampf(inp.length(), 0.0, 1.0)
			else:
				speed = _free_walk_speed
			target_yaw = _free_target_yaw

	_actor.step_turn_demo(target_yaw, speed, dt)

	# Track slip and drop footprints on touchdowns.
	var tel: Dictionary = _actor.get_turn_telemetry()
	var l_pl: bool = tel["left_planted"]
	var r_pl: bool = tel["right_planted"]
	var l_mode: int = tel["left_pivot_mode"]
	var r_mode: int = tel["right_pivot_mode"]
	var l_piv: Vector3 = tel["left_heel_world"] if l_mode == 0 else tel["left_ball_world"]
	var r_piv: Vector3 = tel["right_heel_world"] if r_mode == 0 else tel["right_ball_world"]
	if l_pl and _prev_l_planted and l_mode == _prev_l_mode:
		_max_observed_slip = maxf(_max_observed_slip, Vector2(l_piv.x - _prev_l_piv.x, l_piv.z - _prev_l_piv.z).length())
	if r_pl and _prev_r_planted and r_mode == _prev_r_mode:
		_max_observed_slip = maxf(_max_observed_slip, Vector2(r_piv.x - _prev_r_piv.x, r_piv.z - _prev_r_piv.z).length())
	if l_pl and not _prev_l_planted:
		_drop_footprint(tel["left_ankle_world"], tel["left_foot_world_yaw"], true)
	if r_pl and not _prev_r_planted:
		_drop_footprint(tel["right_ankle_world"], tel["right_foot_world_yaw"], false)
	_prev_l_planted = l_pl
	_prev_r_planted = r_pl
	_prev_l_mode = l_mode
	_prev_r_mode = r_mode
	_prev_l_piv = l_piv
	_prev_r_piv = r_piv


func _update_camera_transform() -> void:
	var focus := _actor.global_position + Vector3(0.0, _cam_target_y, 0.0)
	_cam_pivot.global_position = focus
	var offset := Vector3(0.0, 0.0, _cam_dist).rotated(Vector3.RIGHT, _cam_pitch).rotated(Vector3.UP, _cam_yaw)
	_camera.global_position = focus + offset
	_camera.look_at(focus, Vector3.UP)


func _update_gizmos_and_hud() -> void:
	var tel: Dictionary = _actor.get_turn_telemetry()
	if _show_gizmos:
		var t_yaw: float = tel["target_yaw"]
		var fwd := Vector3(-sin(t_yaw), 0.0, -cos(t_yaw))
		_target_arrow.global_position = Vector3(_actor.global_position.x, 0.08, _actor.global_position.z) + fwd * 6.5
		_target_arrow.rotation = Vector3(0.0, t_yaw, 0.0)

		var l_piv: Vector3 = tel["left_heel_world"] if int(tel["left_pivot_mode"]) == 0 else tel["left_ball_world"]
		var r_piv: Vector3 = tel["right_heel_world"] if int(tel["right_pivot_mode"]) == 0 else tel["right_ball_world"]
		_l_pin_ring.visible = bool(tel["left_planted"])
		_r_pin_ring.visible = bool(tel["right_planted"])
		_l_pin_ring.global_position = Vector3(l_piv.x, 0.07, l_piv.z)
		_r_pin_ring.global_position = Vector3(r_piv.x, 0.07, r_piv.z)

		var hip_w: Vector3 = _actor.to_global((_actor.get_node("Model/metarig/Skeleton3D") as Skeleton3D).get_bone_global_pose(0).origin * 14.8 * Vector3(-1, 1, -1))
		var skel: Skeleton3D = _actor.get_node("Model/metarig/Skeleton3D")
		var com_w := skel.to_global(skel.get_bone_global_pose(0).origin)
		_com_dot.global_position = Vector3(com_w.x, 0.09, com_w.z)
		var _unused := hip_w

	var eye_deg := rad_to_deg(tel["bone_eye_world_yaw"])
	var head_deg := rad_to_deg(tel["bone_head_world_yaw"])
	var chest_deg := rad_to_deg(tel["bone_chest_world_yaw"])
	var pelvis_deg := rad_to_deg(tel["pelvis_world_yaw"])
	var feet_deg := rad_to_deg(tel["feet_mean_world_yaw"])
	var target_deg := rad_to_deg(tel["target_yaw"])

	_telemetry_label.text = (
		"状态: %s | 步数: %d | 支撑滑移: %.4f m\n" +
		"目标: %+5.1f°\n" +
		"眼:   %+5.1f°  头: %+5.1f°  胸: %+5.1f°\n" +
		"胯:   %+5.1f°  脚: %+5.1f°  (胸/头=%.2f)\n" +
		"倾身: %+5.1f° | 重心偏X: %+.3f | 膝屈: L %.0f° / R %.0f°\n" +
		"左脚: %s (pitch %+.1f°) | 右脚: %s (pitch %+.1f°)\n" +
		"步幅倍率: %.2f | 外臂张度 L:%+.2f R:%+.2f"
	) % [
		String(tel["mode"]), int(tel["standing_step_count"]), _max_observed_slip,
		target_deg,
		eye_deg, head_deg, chest_deg,
		pelvis_deg, feet_deg, float(tel["chest_to_head_ratio"]),
		rad_to_deg(float(tel["actual_torso_lean_rad"])), float(tel["pelvis_shift_x"]),
		float(tel["left_knee_bend_deg"]), float(tel["right_knee_bend_deg"]),
		("钉地-" + ("跟" if int(tel["left_pivot_mode"]) == 0 else "掌")) if bool(tel["left_planted"]) else "抬脚迈步",
		rad_to_deg(float(tel["left_foot_pitch"])),
		("钉地-" + ("跟" if int(tel["right_pivot_mode"]) == 0 else "掌")) if bool(tel["right_planted"]) else "抬脚迈步",
		rad_to_deg(float(tel["right_foot_pitch"])),
		float(tel["turn_stride_mult"]), float(tel["left_arm_open"]), float(tel["right_arm_open"]),
	]
