extends SceneTree

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var loaded := change_scene_to_file("res://scenes/main.tscn")
	if not _expect(loaded == OK, "main scene loads"):
		quit(1)
		return
	await scene_changed
	var game := current_scene
	var harbor := _button(&"HarborEntry")
	var bedroom := _button(&"BedroomEntry")
	var human := _button(&"HumanMode")
	_expect(harbor.is_visible_in_tree() and bedroom.is_visible_in_tree()
		and not human.is_visible_in_tree() and not _button(&"BedroomPlay").is_visible_in_tree(),
		"first menu shows the two entries")
	harbor.pressed.emit()
	for mode in [&"HumanMode", &"SandboxMode", &"GrowthMode", &"BrawlMode"]:
		_expect(_button(mode).is_visible_in_tree(), "%s is available in the harbor submenu" % mode)
	_expect(not bedroom.is_visible_in_tree(), "bedroom entry belongs to the first menu")
	human.pressed.emit()
	_expect(game.get_screen() == "playing", "harbor submenu starts an existing mode")
	game.show_menu()
	_expect(human.is_visible_in_tree(), "leaving a harbor round reopens its submenu")
	_button(&"GrowthMode").pressed.emit()
	_expect(game.get_screen() == "menu" and _button(&"GrowthGiant").is_visible_in_tree()
		and _button(&"GrowthSpectator").is_visible_in_tree() and _button(&"GrowthHuman").is_visible_in_tree(),
		"Growth opens its own three-role menu")
	await _press_key(KEY_ESCAPE)
	_expect(human.is_visible_in_tree() and not _button(&"GrowthHuman").is_visible_in_tree(),
		"Escape from the growth menu returns to the harbor menu")
	await _press_key(KEY_ESCAPE)
	_expect(bedroom.is_visible_in_tree(), "Escape returns to the first menu")

	bedroom.pressed.emit()
	_expect(current_scene == game and _button(&"BedroomPlay").is_visible_in_tree()
		and not bedroom.is_visible_in_tree(), "bedroom opens a submenu without loading the room")
	_button(&"BedroomPlay").pressed.emit()
	await process_frame
	await process_frame
	var room := current_scene
	if _expect(room != null and room.scene_file_path == "res://scenes/GirlBedroom.tscn",
			"the submenu opens the imported scene"):
		await _check_bedroom(room)
		await _press_key(KEY_ESCAPE)
		await process_frame
		if _expect(_bedroom_menu_visible(), "Escape returns to the bedroom submenu"):
			await _press_key(KEY_ESCAPE)
			_expect(_button(&"BedroomEntry").is_visible_in_tree(),
				"Escape from the bedroom submenu returns to the first menu")
	await _check_touch_navigation()
	print("Mode menu: %d passed, %d failed" % [_checks - _failures, _failures])
	quit(1 if _failures else 0)


func _bedroom_menu_visible() -> bool:
	return current_scene != null and current_scene.scene_file_path == "res://scenes/main.tscn" \
		and _button(&"BedroomPlay").is_visible_in_tree() and not _button(&"BedroomEntry").is_visible_in_tree()


func _check_touch_navigation() -> void:
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	root.size = Vector2i(1920, 864)
	var menu := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	var interface := menu.get_node("Interface")
	interface.set("_touch_enabled", true)
	if not _expect(change_scene_to_node(menu) == OK, "main menu opens in the mobile layout"):
		menu.free()
		return
	await scene_changed
	await create_timer(0.45).timeout
	await _tap(_button(&"HarborEntry"))
	var safe: Rect2 = interface.get("_root").get_global_rect()
	var brawl := _button(&"BrawlMode")
	_expect(brawl.is_visible_in_tree() and safe.encloses(brawl.get_global_rect()),
			"The mobile Brawl entry fits the safe area")
	await _tap(brawl)
	var controls: Control = interface.get("_touch")
	var ranking: Rect2 = controls.call("_ranking_rect")
	_finger(controls, 0, ranking.get_center(), true)
	_finger(controls, 0, ranking.get_center(), false)
	var leaderboard := interface.find_child("TouchRanking", true, false) as Control
	_expect(menu.get_screen() == "playing" and controls.get("_allow_giant") and not controls.get("_allow_sprint") and leaderboard.visible,
			"A touch opens Brawl with giant actions and the mobile leaderboard")
	menu.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	_expect(not leaderboard.visible and controls.visible, "Android Back closes the Brawl leaderboard")
	menu.show_menu()
	await _tap(_button(&"GrowthMode"))
	for entry in [&"GrowthGiant", &"GrowthSpectator", &"GrowthHuman", &"GrowthBack"]:
		var button := _button(entry)
		_expect(button.is_visible_in_tree() and safe.encloses(button.get_global_rect()),
			"The mobile growth entry %s fits the safe area" % entry)
	await _tap(_button(&"GrowthBack"))
	_expect(_button(&"GrowthMode").is_visible_in_tree(), "Growth Back returns to the harbor submenu")
	await _tap(_button(&"HarborBack"))
	await _tap(_button(&"BedroomEntry"))
	var enter := _button(&"BedroomPlay")
	var back := _button(&"BedroomMenuBack")
	if not _expect(_bedroom_menu_visible() and safe.encloses(enter.get_global_rect())
			and safe.encloses(back.get_global_rect()), "a touch opens bedroom options inside the safe area"):
		return
	await _tap(back)
	_expect(_button(&"BedroomEntry").is_visible_in_tree(), "a touch on Back exits the bedroom submenu")

	await _tap(_button(&"BedroomEntry"))
	menu.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	_expect(_button(&"BedroomEntry").is_visible_in_tree(), "Android Back exits the bedroom submenu")
	await _tap(_button(&"BedroomEntry"))
	await _tap(enter)
	if _expect(current_scene != null and current_scene.scene_file_path == "res://scenes/GirlBedroom.tscn",
			"a touch on Enter opens the room"):
		current_scene.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
		await process_frame
		await process_frame
		_expect(_bedroom_menu_visible(), "Android Back from the room opens the bedroom submenu")
	await _check_bedroom_touch()


func _tap(button: BaseButton) -> void:
	var at := root.get_final_transform() * button.get_global_rect().get_center()
	for pressed in [true, false]:
		var event := InputEventScreenTouch.new()
		event.position = at
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	await process_frame
	await process_frame


func _check_bedroom(room: Node3D) -> void:
	var visual := room.get_node("Visual")
	var meshes := visual.find_children("*", "MeshInstance3D", true, false)
	_expect(meshes.size() == 13, "the playable bedroom retains all 13 room meshes")
	var shell := visual.find_child("Arch_Shell_Opaque", true, false) as MeshInstance3D
	var floor_material := shell.mesh.surface_get_material(0) as StandardMaterial3D
	_expect(floor_material.albedo_texture != null and floor_material.normal_texture != null
		and floor_material.roughness_texture != null, "import resolves embedded PBR textures")
	var player := room.get_node("Player") as CharacterBody3D
	var model := player.get_node("Model") as Node3D
	var capsule: CapsuleShape3D = player.get_node("Collision").shape
	var model_top := 0.0
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		model_top = maxf(model_top, (mesh.global_transform * mesh.get_aabb()).end.y)
	_expect(player.scene_file_path == "res://scenes/human.tscn" and is_equal_approx(capsule.height, 0.01)
		and absf(model_top - player.global_position.y - 0.01) < 0.0001,
		"the reused harbor human model and capsule are both one centimeter tall")
	await _ticks(25)
	var camera := root.get_camera_3d()
	var orbit := player.get_node("Orbit") as Node3D
	_expect(camera == player.get_node("Orbit/SpringArm3D/Camera3D") and player.is_on_floor()
		and camera.global_position.distance_to(player.global_position) < 0.04,
		"the close third-person camera follows the grounded player on entry")
	var before_walk := player.position
	_send_key(KEY_W, true)
	await _ticks(12)
	_expect(player.position.x < before_walk.x - 0.01, "forward movement controls the miniature human")
	_send_key(KEY_SPACE, true)
	await _ticks(75)
	var animation := player.get_node("Model/AnimationPlayer") as AnimationPlayer
	_expect(player.position.y > 0.045 and animation.current_animation == &"bedroom/climb",
		"holding Space climbs the real bedside table leg and plays the climbing animation")
	_send_key(KEY_SPACE, false)
	_send_key(KEY_W, false)
	await _ticks(45)
	_expect(player.is_on_floor() and player.position.y < 0.002, "releasing Space drops the player to the floor")

	orbit.rotation.y = 0.0
	player.position = Vector3(2.354, 0.001, 0.59)
	player.velocity = Vector3.ZERO
	await _ticks(4)
	Input.action_press("move_right")
	Input.action_press("climb")
	await _ticks(365)
	Input.action_release("move_right")
	Input.action_release("climb")
	_expect(player.position.y > 0.30 and player.position.x < 2.4,
		"the character climbs the bedroom wall past its protruding trim")
	await _check_ledge(room, player)
	var arm: SpringArm3D = orbit.get_node("SpringArm3D")
	var before_arrows := Vector2(orbit.rotation.y, arm.rotation.x)
	_send_key(KEY_LEFT, true)
	_send_key(KEY_UP, true)
	Input.flush_buffered_events()
	await _ticks(16)
	_send_key(KEY_LEFT, false)
	_send_key(KEY_UP, false)
	Input.flush_buffered_events()
	var turned := Vector2(orbit.rotation.y, arm.rotation.x)
	_expect(angle_difference(before_arrows.x, turned.x) > 0.2 and turned.y > before_arrows.y + 0.2,
		"the bedroom camera turns and looks up while the arrow keys are held")
	await _ticks(8)
	_expect(Vector2(orbit.rotation.y, arm.rotation.x).is_equal_approx(turned),
		"the bedroom camera stops when the arrow keys are released")


func _check_ledge(room: Node, player: CharacterBody3D) -> void:
	var box := StaticBody3D.new()
	box.position = Vector3(0.0, 0.02, 0.4)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.08, 0.04, 0.05)
	collision.shape = shape
	box.add_child(collision)
	room.add_child(box)
	player.position = Vector3(0.0, 0.001, 0.435)
	player.velocity = Vector3.ZERO
	await _ticks(3)
	Input.action_press("move_forward")
	await _ticks(6)
	Input.action_release("move_forward")
	Input.action_press("climb")
	await _ticks(75)
	Input.action_release("climb")
	_expect(player.is_on_floor() and absf(player.position.y - 0.04) < 0.001
		and player.position.z < 0.425, "a clear ledge can be climbed onto")
	box.queue_free()


func _check_bedroom_touch() -> void:
	var room := (load("res://scenes/GirlBedroom.tscn") as PackedScene).instantiate()
	room.set("_touch_enabled", true)
	if not _expect(change_scene_to_node(room) == OK, "the bedroom opens with the mobile controls"):
		room.free()
		return
	await scene_changed
	await _ticks(20)
	var touch := room.find_child("TouchControls", true, false) as Control
	var player := room.get_node("Player") as CharacterBody3D
	var orbit := player.get_node("Orbit") as Node3D
	var move := Vector2(112, touch.size.y - 104)
	var look := Vector2(touch.size.x * 0.72, touch.size.y * 0.38)
	var climb: Vector2 = touch.call("_action_rect").get_center()
	_finger(touch, 1, move, true)
	_drag(touch, 1, move - Vector2(0, 60), Vector2(0, -60))
	_finger(touch, 2, climb, true)
	await _ticks(85)
	var yaw := orbit.rotation.y
	_finger(touch, 3, look, true)
	_drag(touch, 3, look + Vector2(24, 0), Vector2(24, 0))
	_expect(player.position.y > 0.045 and absf(orbit.rotation.y - yaw) > 0.06,
		"touch can move, climb and look with independent fingers")
	_finger(touch, 2, climb, false)
	_finger(touch, 1, move, false)
	_finger(touch, 3, look, false)
	await _ticks(45)
	_expect(player.is_on_floor(), "releasing the climb touch drops the player")
	var back: Vector2 = touch.call("_pause_rect").get_center()
	_finger(touch, 4, back, true)
	_finger(touch, 4, back, false)
	await process_frame
	await process_frame
	_expect(_bedroom_menu_visible(), "the touch return button opens the bedroom submenu")


func _finger(control: Control, id: int, at: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = id
	event.position = control.get_global_transform_with_canvas() * at
	event.pressed = pressed
	root.push_input(event, true)


func _drag(control: Control, id: int, at: Vector2, relative: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = id
	event.position = control.get_global_transform_with_canvas() * at
	event.relative = relative
	root.push_input(event, true)


func _ticks(count: int) -> void:
	for frame in count:
		await physics_frame


func _button(node_name: StringName) -> BaseButton:
	return current_scene.find_child(node_name, true, false) as BaseButton


func _press_key(key: Key) -> void:
	_send_key(key, true)
	await process_frame
	_send_key(key, false)
	await process_frame


func _send_key(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)


func _expect(condition: bool, description: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)
	return condition
