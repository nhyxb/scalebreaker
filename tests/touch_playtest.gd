extends SceneTree
## Exercises the Android HUD and native gameplay bridge with synthetic touch events.

var _game: Node
var _view: CanvasLayer
var _controls: Control
var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	seed(61122)
	_game = load("res://scenes/main.tscn").instantiate()
	_game.settings_path = "user://touch-playtest-%d.cfg" % OS.get_process_id()
	_view = _game.get_node("Interface")
	_view.set("_touch_enabled", true)
	root.add_child(_game)
	await process_frame
	_controls = _view.get("_touch")
	_check(_game.get_screen() == "menu" and not _controls.visible, "main menu uses regular GUI input")
	var settings: BaseButton = _view.find_child("MenuSettings", true, false)
	settings.pressed.emit()
	var panel: Control = _view.find_child("GameplaySettings", true, false)
	var scroll: ScrollContainer = _view.get("_settings_scroll")
	var growth_tab: Button = panel.find_child("GrowthSettingsTab", true, false)
	growth_tab.pressed.emit()
	await process_frame
	_check(panel.visible and scroll.get_v_scroll_bar().max_value > scroll.size.y, "growth options fit a scrollable settings card")
	var map_size := panel.find_child("map_side", true, false) as SpinBox
	var line := map_size.get_line_edit()
	_check(map_size.is_visible_in_tree() and map_size.size.y >= 50.0
			and map_size.allow_lesser and map_size.allow_greater
			and line.virtual_keyboard_type == LineEdit.KEYBOARD_TYPE_NUMBER
			and _view.get("_font_regular").has_char("图".unicode_at(0)),
			"Map size has unrestricted touch input, a numeric keyboard and bundled Chinese glyphs")
	(panel.find_child("SettingsPageGraphics", true, false) as BaseButton).pressed.emit()
	await process_frame
	var own_shake := panel.find_child("own_camera_shake", true, false) as CheckButton
	_check(own_shake.is_visible_in_tree() and own_shake.button_pressed
			and own_shake.get_parent().size.y >= 52.0,
			"The graphics page keeps a touch-sized own-shake switch")
	(panel.find_child("SettingsPageGameplay", true, false) as BaseButton).pressed.emit()
	await process_frame
	_check((panel.find_child("coin_count", true, false) as SpinBox).value == 200.0
			and (panel.find_child("coin_interval", true, false) as SpinBox).value == 60.0
			and (panel.find_child("coin_growth_rate", true, false) as SpinBox).value == 10.0
			and (panel.find_child("building_growth_rate", true, false) as SpinBox).value == 10.0,
			"touch growth settings expose the map-wide coin defaults and split growth rates")
	_game.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	_check(not panel.visible and _game.get_screen() == "menu", "Back dismisses settings first")

	await _test_human()
	await _test_giant(false)
	await _test_giant(true)
	await _test_growth_ranking()
	await _test_observation()
	await _test_hand_buttons()
	await _test_observer_defeat_feed()
	_game.show_menu()
	_check(not _controls.visible, "returning to the menu hides gameplay controls")
	DirAccess.remove_absolute(_game.settings_path)
	print("Touch: %d passed, %d failed" % [_checks - _failures, _failures])
	quit(1 if _failures else 0)


func _test_human() -> void:
	_game.start_mode(false)
	await _ticks(4)
	var current := _round()
	var human: CharacterBody3D = current.get_node("Human")
	var orbit: Node3D = current.get_node("Orbit")
	human.position = Vector3(0.0, 0.03, -34.0)
	var start := human.position
	var yaw := orbit.rotation.y
	var move := Vector2(112, _controls.size.y - 104)
	var look := Vector2(_controls.size.x * 0.67, _controls.size.y * 0.48)
	var sprint := _button("_action_rect")
	_finger(3, move, true)
	_drag(3, move + Vector2(0, -60), Vector2(0, -60))
	_finger(8, look, true)
	_drag(8, look + Vector2(60, 0), Vector2(60, 0))
	_finger(12, sprint, true)
	await _ticks(40)
	var low: float = current.snapshot().stamina
	_check(start.distance_to(human.position) > 4.0 and absf(orbit.rotation.y - yaw) > 0.1
		and low < 0.9, "three fingers move, aim and sprint concurrently")
	_finger(12, sprint, false, true)
	await _ticks(40)
	_check(current.snapshot().stamina > low, "canceling the sprint finger restores stamina")
	_finger(3, move, false, true)
	await _ticks(3)
	var stopped := human.position
	await _ticks(16)
	_check(human.position.distance_to(stopped) < 0.05, "canceling the joystick stops movement")

	_finger(3, move, true)
	_drag(3, move + Vector2(0, -60), Vector2(0, -60))
	_finger(12, sprint, true)
	_game.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	_game.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	_check(_game.get_screen() == "paused" and paused and not _controls.visible, "backgrounding pauses until the player resumes")
	_game.resume()
	var resumed := human.position
	await _ticks(12)
	_check(human.position.distance_to(resumed) < 0.05, "old held fingers remain cleared after resume")
	_game.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	_check(_game.get_screen() == "paused", "Android Back pauses an active round")
	var previous_id := current.get_instance_id()
	_game.restart()
	await _ticks(4)
	_check(_round().get_instance_id() != previous_id and _game.get_screen() == "playing" and not paused
		and _controls.visible, "restarting binds the HUD to a fresh round")


func _test_giant(growth: bool) -> void:
	if growth:
		_game.start_growth()
	else:
		_game.start_mode(true)
	await _ticks(4)
	var current := _round()
	var camera := root.get_camera_3d()
	var parent := camera.get_parent()
	var view_button := _button("_view_rect")
	# The touch button cycles the same three modes as V: third person -> foot follow -> first.
	current.set_camera_view(0)
	await _ticks(2)
	_tap(2, view_button)
	await _ticks(2)
	var foot_mode: int = current.camera_view_mode()
	_tap(2, view_button)
	await _ticks(2)
	_check(foot_mode == 1 and current.camera_view_mode() == 2
			and camera.get_parent() == current.get_node("Orbit"),
			"touch cycles the giant view to foot follow then first person in mode %d" % int(growth))
	var giant := current.get_node("Giant") as CharacterBody3D
	giant.position = Vector3(0.0, 0.03, -34.0)
	await _ticks(5)
	var initial_position := giant.position
	var before_count := int(current.growth_actors()[0].footfall_count)
	var starting_yaw: float = current.get_node("Orbit").rotation.y
	var move := Vector2(112, _controls.size.y - 104)
	var look := Vector2(_controls.size.x * 0.67, _controls.size.y * 0.48)
	_finger(6, move, true)
	_drag(6, move + Vector2(0, -60), Vector2(0, -60))
	_finger(8, look, true)
	_drag(8, look + Vector2(32, 0), Vector2(32, 0))
	await _ticks(110)
	var took_step: bool = int(current.growth_actors()[0].footfall_count) > before_count
	var moved := giant.position.distance_to(initial_position) > 0.01
	var looked: bool = absf(angle_difference(starting_yaw, current.get_node("Orbit").rotation.y)) > 0.02
	_check(not _controls.get("_allow_sprint") and _controls.get("_action_id") == -1
			and not InputMap.has_action("stomp"), "The giant touch layout has no manual stomp")
	if growth:
		_check(moved and looked and not took_step,
				"The growth human moves and looks with two fingers without creating heavy footfalls")
	else:
		_check(moved and looked and took_step,
				"The giant touch joystick walks and lands heavy footsteps while looking")
	_tap(14, _button("_pause_rect"))
	_check(_game.get_screen() == "paused", "pause button works with other fingers held")


func _test_growth_ranking() -> void:
	var growth: Dictionary = _game.default_mode_settings(2)
	growth.merge({"giant_count": 32, "coin_count": 1, "npc_initial": 0, "npc_respawn": false}, true)
	_game.save_mode_settings(_game.get_mode_settings(0), _game.get_mode_settings(1), growth)
	_game.start_growth()
	await _ticks(3)
	var layer: Control = _view.find_child("TouchRanking", true, false)
	var board: Control = layer.find_child("GrowthRanking", true, false)
	var table: Control = layer.find_child("RankRows", true, false)
	var scroll: ScrollContainer = layer.find_child("RankingScroll", true, false)
	var personal: Label = layer.find_child("PersonalRank", true, false)
	var close: Button = layer.find_child("CloseRanking", true, false)
	var chart := _button("_ranking_rect")
	var view_rect: Rect2 = _controls.call("_view_rect")
	var action_rect: Rect2 = _controls.call("_action_rect")
	var chart_rect: Rect2 = _controls.call("_ranking_rect")
	var compass: Control = _view.get("_evac_panel")
	var chart_in_canvas := Rect2(_controls.get_global_transform_with_canvas() * chart_rect.position, chart_rect.size)
	_check(not layer.visible and _controls.get("_player_rank") > 0
			and not chart_rect.intersects(view_rect) and not chart_rect.intersects(action_rect)
			and not chart_in_canvas.intersects(compass.get_global_rect()),
			"The mobile HUD shows the player's rank in a separate touch target")
	_finger(11, chart, true)
	_finger(11, chart, false, true)
	_check(not layer.visible, "Canceling a ranking tap leaves the panel closed")

	var move := Vector2(110, _controls.size.y - 104)
	_finger(9, move, true)
	_drag(9, move + Vector2(0, -60), Vector2(0, -60))
	_tap(11, chart)
	await _ticks(3)
	_check(layer.visible and not _controls.visible and _controls.get("_move_id") == -1
			and _game.get_screen() == "playing", "Touch opens the ranking and releases the gameplay fingers")
	_check(_view.get("_root").get_global_rect().encloses(board.get_global_rect())
			and table.get("rows").size() == 32 and personal.text.contains("名"),
			"The anchored mobile list fits the safe area and contains all 32 ranks")
	var list_start := scroll.get_global_rect().get_center()
	var touch_transform := _controls.get_global_transform_with_canvas().affine_inverse()
	var from := touch_transform * (list_start + Vector2(0, 100))
	_finger(4, from, true)
	for step in range(1, 7):
		_drag(4, from - Vector2(0, 35 * step), Vector2(0, -35))
		await process_frame
	_finger(4, from - Vector2(0, 210), false)
	_check(scroll.scroll_vertical > 80, "Swiping on the ranking scrolls the roster")
	var from_bottom := touch_transform * Vector2(list_start.x, scroll.get_global_rect().end.y - 16.0)
	var to_top := touch_transform * Vector2(list_start.x, scroll.get_global_rect().position.y + 16.0)
	for swipe in 3:
		_finger(4, from_bottom, true)
		_drag(4, to_top, to_top - from_bottom)
		_finger(4, to_top, false)
	var last_offset := scroll.get_v_scroll_bar().max_value - scroll.get_v_scroll_bar().page
	_check(scroll.scroll_vertical >= last_offset - 1 and personal.is_visible_in_tree(),
			"Swiping can reach the last rank while the player's rank stays visible")
	_finger(9, move, false)
	_game.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	_check(not layer.visible and _controls.visible and _game.get_screen() == "playing",
			"Android Back closes the ranking before pausing the game")

	_tap(11, chart)
	await _ticks(3)
	_check(layer.visible and scroll.scroll_vertical == 0, "Opening the ranking resets the scroll to the leaders")
	_tap(4, touch_transform * close.get_global_rect().get_center())
	await _ticks(2)
	_check(not layer.visible and _controls.visible, "The touch close button restores the gameplay controls")
	_tap(11, chart)
	_game.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	_check(not layer.visible and not _controls.visible and _game.get_screen() == "paused",
			"Backgrounding closes the ranking and goes to the pause screen")


func _test_observation() -> void:
	_game.save_mode_settings(_game.get_settings(false), _game.get_settings(true), _game.default_mode_settings(2))
	_game.start_growth_spectator()
	await _ticks(3)
	var camera := root.get_camera_3d()
	var start := camera.global_position
	var move := Vector2(110, _controls.size.y - 104)
	var look := _button("_action_rect")
	_finger(3, look, true)
	_drag(3, look - Vector2(0, 200), Vector2(0, -200))
	_finger(8, move, true)
	_drag(8, move - Vector2(0, 58), Vector2(0, -58))
	await _ticks(15)
	_check(camera.global_position.y > start.y + 0.03 and _controls.get("_action_id") == -1,
			"The spectator can swipe in the lower action area and fly upward with the joystick")
	_finger(3, look, false)
	_finger(8, move, false)
	_tap(11, _button("_ranking_rect"))
	var layer: Control = _view.find_child("TouchRanking", true, false)
	var personal: Label = layer.find_child("PersonalRank", true, false)
	_check(layer.visible and not personal.visible, "Spectators can browse the live ranking without a personal rank")
	_game.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	_check(_controls.visible and not layer.visible, "Android Back closes the spectator ranking")

	_game.start_growth_human()
	await _ticks(3)
	_finger(3, look, true)
	_check(_controls.get("_action_id") == 3 and not _controls.get("_allow_giant"),
			"Human observation offers touch sprint and hides the giant controls")
	_finger(3, look, false)


func _test_hand_buttons() -> void:
	var growth: Dictionary = _game.default_mode_settings(2)
	growth.merge({"giant_count": 1, "giant_height": 23.4, "npc_initial": 0, "npc_respawn": false}, true)
	_game.save_mode_settings(_game.get_mode_settings(0), _game.get_mode_settings(1), growth)
	for index in 2:
		_game.start_growth()
		var current := _round()
		var giant: CharacterBody3D = current.get_node("Giant")
		var building: Node3D = current.get_node("District/Targets/DockPress1" if index == 0 else "District/Targets/Tidewater1")
		# The core lots sit against MarineWorks1 to the south, so the giant stands on the open
		# street north of the row and faces it.
		giant.rotation = Vector3(0.0, PI, 0.0)
		giant.position = building.position + Vector3(0.0, 0.02, -(building.footprint.z * 0.5 + 5.0))
		await _ticks(12)
		var rect: Rect2 = _controls.call("_hand_rect", index)
		_finger(7, rect.get_center(), true)
		_finger(7, rect.get_center(), false, true)
		await _ticks(2)
		_check(current.snapshot().hand_action.is_empty(), "Canceling hand attack %d does not fire it" % index)
		_tap(7, rect.get_center())
		await _ticks(2)
		_check(current.snapshot().hand_action == ("grab_crush" if index == 0 else "punch"),
				"The dedicated touch button triggers hand attack %d" % index)


func _test_observer_defeat_feed() -> void:
	var growth: Dictionary = _game.default_mode_settings(2)
	growth.merge({"giant_count": 2, "giant_height": 23.4, "npc_initial": 0, "npc_respawn": false}, true)
	_game.save_mode_settings(_game.get_mode_settings(0), _game.get_mode_settings(1), growth)
	for spectator in [true, false]:
		if spectator:
			_game.start_growth_spectator()
		else:
			_game.start_growth_human()
		var current := _round()
		var messages: Array[Dictionary] = [{
				"attacker": "林晓岚", "victim": "周雨桐", "method": "step",
				"player_attack": false, "player_defeated": false}]
		_view.announce_growth_defeats(messages)
		await _ticks(3)
		var feed := _view.find_child("GrowthDefeatFeed", true, false) as VBoxContainer
		var safe: Rect2 = _view.get("_root").get_global_rect()
		var pause_button: Rect2 = _controls.call("_pause_rect")
		var pause_bottom := (_controls.get_global_transform_with_canvas() * pause_button.end).y
		_check(feed.visible and feed.get_child_count() == 1 and safe.encloses(feed.get_global_rect())
				and feed.get_global_rect().position.y > pause_bottom,
				"Touch observer role %d gets the live feed below Pause and inside the safe area" % int(spectator))


func _button(method: String) -> Vector2:
	var rect: Rect2 = _controls.call(method)
	return rect.get_center()


func _tap(id: int, at: Vector2) -> void:
	_finger(id, at, true)
	_finger(id, at, false)


func _finger(id: int, at: Vector2, down: bool, canceled := false) -> void:
	var event := InputEventScreenTouch.new()
	event.index = id
	event.position = _controls.get_global_transform_with_canvas() * at
	event.pressed = down
	event.canceled = canceled
	root.push_input(event, true)


func _drag(id: int, at: Vector2, relative: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = id
	event.position = _controls.get_global_transform_with_canvas() * at
	event.relative = relative
	root.push_input(event, true)


func _round() -> Node:
	return _game.get_node("MapSlot/Round")


func _ticks(count: int) -> void:
	for frame in count:
		await physics_frame


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS ", description)
	else:
		_failures += 1
		push_error("FAIL " + description)
