extends SceneTree

const BRAWL := 3
const OPEN_STREET := Vector3(0.0, 0.01, -34.0)
const STOMP_OFFSET := Vector3(-1.39, 0.0, -7.05)
const GIANT_HEIGHT := 25.2

var _game: Node
var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	seed(31542)
	_game = load("res://scenes/main.tscn").instantiate()
	_game.settings_path = "user://brawl-playtest-%d.cfg" % OS.get_process_id()
	root.add_child(_game)
	await process_frame
	await _check_settings()
	await _check_wide_random_start()
	await _check_demolition()
	await _check_idle_ai()
	await _check_combat()
	await _check_crowded_respawn()
	await _check_upward_footfall_damage()
	await _check_giants_pass()
	DirAccess.remove_absolute(_game.settings_path)
	print("Brawl gameplay: %d passed, %d failed" % [_checks - _failures, _failures])
	quit(1 if _failures else 0)


func _check_settings() -> void:
	var defaults: Dictionary = _game.get_mode_settings(BRAWL)
	_check(defaults.respawn_max_height == 30.0 and defaults.coin_height == 50.0
			and is_equal_approx(defaults.coin_reward_rate, 0.01) and not defaults.random_start
			and is_equal_approx(defaults.start_min_height, 0.01) and defaults.start_max_height == 30.0,
			"Brawl has the requested defaults")
	var ui := _game.get_node("Interface")
	(ui.find_child("MenuSettings", true, false) as BaseButton).pressed.emit()
	(ui.find_child("BrawlSettingsTab", true, false) as BaseButton).pressed.emit()
	await process_frame
	var panel := ui.find_child("GameplaySettings", true, false) as Control
	ui.call("debug_expand_settings")
	var initial_height := panel.find_child("giant_height", true, false) as SpinBox
	_check(initial_height.get_line_edit().text.begins_with("25.2 "),
			"The decimal starting height is displayed without floating-point padding")
	_check(not panel.find_child("npc_initial", true, false).is_visible_in_tree()
			and not panel.find_child("coin_count", true, false).is_visible_in_tree(),
			"Brawl settings only show options that apply to the mode")
	var random_start := panel.find_child("random_start", true, false) as CheckButton
	var start_min := panel.find_child("start_min_height", true, false) as SpinBox
	var start_max := panel.find_child("start_max_height", true, false) as SpinBox
	_check(random_start.is_visible_in_tree() and not random_start.button_pressed
			and initial_height.is_visible_in_tree() and not start_min.is_visible_in_tree()
			and not start_max.is_visible_in_tree(),
			"A fixed starting height remains available with random starts disabled")
	random_start.button_pressed = true
	_check(not initial_height.is_visible_in_tree() and start_min.is_visible_in_tree()
			and start_max.is_visible_in_tree(),
			"Random starts enable their own height range")
	for key in ["start_min_height", "start_max_height", "respawn_max_height", "coin_height", "coin_reward_rate"]:
		var field := panel.find_child(key, true, false) as SpinBox
		_check(field.is_visible_in_tree() and field.allow_lesser and field.allow_greater,
				"%s accepts values outside the default SpinBox limits" % key)
	start_min.value = 0.75
	start_max.value = 1.25
	(panel.find_child("giant_count", true, false) as SpinBox).value = 4
	(panel.find_child("respawn_max_height", true, false) as SpinBox).value = 332.25
	(panel.find_child("coin_height", true, false) as SpinBox).value = 451.75
	(panel.find_child("coin_reward_rate", true, false) as SpinBox).value = 126.5
	(panel.find_child("SaveSettings", true, false) as BaseButton).pressed.emit()
	var file := ConfigFile.new()
	_check(file.load(_game.settings_path) == OK, "The settings UI saves the Brawl profile")
	var saved: Dictionary = file.get_value("settings", "brawl", {})
	_check(not panel.visible and saved.random_start and saved.start_min_height == 0.75
			and saved.start_max_height == 1.25
			and saved.respawn_max_height == 332.25 and saved.coin_height == 451.75
			and is_equal_approx(saved.coin_reward_rate, 1.265)
			and not _game.get_mode_settings(2).random_start and _game.get_mode_settings(2).coin_count == 200,
			"The random range and respawn settings persist independently of Growth")
	_game.start_brawl()
	var actors: Array[Dictionary] = _round().growth_actors()
	var heights := {}
	for actor in actors:
		if actor.height >= 0.75 and actor.height <= 1.25 and not actor.human and actor.can_demolish:
			heights[actor.height] = true
	_check(actors.size() == 4 and heights.size() == 4,
			"Each opening giant independently samples the custom range and can fight at any height")
	_game.show_menu()


func _check_wide_random_start() -> void:
	_save({"random_start": true, "giant_count": 10, "start_min_height": 0.01, "start_max_height": 1000.0})
	var roster_size := 0
	var at_minimum := 0
	for run_seed in [41, 42, 43, 44]:
		seed(run_seed)
		_game.start_brawl()
		for actor: Dictionary in _round().growth_actors():
			roster_size += 1
			at_minimum += int(is_equal_approx(actor.height, 0.01))
		await process_frame
	_check(roster_size == 40 and at_minimum == 0,
			"Oversized opening draws get redrawn without piling up at the minimum height")
	_game.show_menu()


func _check_demolition() -> void:
	_save({"giant_count": 1, "giant_height": 3.0, "building_growth_rate": 1.0})
	var ui := _game.get_node("Interface")
	for entry in ["HarborEntry", "BrawlMode"]:
		(ui.find_child(entry, true, false) as BaseButton).pressed.emit()
	await _ticks(4)
	var round := _round()
	var state: Dictionary = round.snapshot()
	_check(not state.human_stage and state.can_attack and state.building_hits == 9
			and not round.has_node("Human") and round.get_node("Civilians").get_child_count() == 0,
			"The harbor menu opens an all-giant round with Growth building durability")
	var giant: CharacterBody3D = round.get_node("Giant")
	var building: Node3D = round.get_node("District/Targets/DockPress1")
	giant.position = building.position + Vector3(0.16, 0.01, float(building.footprint.z) * 0.5 + 0.76)
	await _ticks(4)
	for hit in 9:
		round.tap_stomp()
		await _ticks(66)
	state = round.snapshot()
	_check(building.get_node("BlockingBody").collision_layer == 0
			and state.giant_destroyed == 1 and state.growth_count == 0
			and is_equal_approx(state.giant_height, 3.0) and round.get_node("Coins").get_child_count() == 0,
			"Stomp demolition awards neither height nor a coin")
	_game.pause()
	_game.restart()
	await _ticks(2)
	_check(_round().snapshot().can_attack and _round().snapshot().giant_destroyed == 0,
			"Restart preserves the mode and resets the city")


func _check_idle_ai() -> void:
	for height: float in [12.0, 40.0]:
		_save({"giant_count": 2, "giant_height": height})
		_game.start_brawl()
		var round := _round()
		var player: CharacterBody3D = round.get_node("Giant")
		var rival: CharacterBody3D = round.get_node("OtherGiants/Giant2")
		var building: Node3D = round.get_node("District/Targets/DockPress1")
		player.position = Vector3(440.0, 0.01, 390.0)
		var clearance := 2.9 * height / GIANT_HEIGHT + 2.0
		rival.position = building.position + Vector3(0.67, 0.01, float(building.footprint.z) * 0.5 + clearance)
		seed(48162)
		var attacked := false
		var kept_moving := true
		for segment in 4:
			var start := rival.position
			var displacement := 0.0
			for frame in 90:
				await physics_frame
				attacked = attacked or not round.growth_actors()[1].stomp
				displacement = maxf(displacement, (rival.position - start).slide(Vector3.UP).length())
			kept_moving = kept_moving and displacement > 1.0
		_check(not attacked and kept_moving,
				"A %.0f m Brawl AI keeps roaming without targeting nearby buildings" % height)
		if height >= 40.0:
			var state: Dictionary = round.snapshot()
			_check(state.destroyed > state.giant_destroyed,
					"At the crush height a roaming AI walks through buildings without an active attack")


func _check_combat() -> void:
	for height: float in [49.0, 50.0]:
		_save({"giant_count": 3, "giant_height": height, "base_attack": 200.0, "respawn_delay": 2.0})
		_game.start_brawl()
		var round := _round()
		var giant: CharacterBody3D = round.get_node("Giant")
		var rival: CharacterBody3D = round.get_node("OtherGiants/Giant2")
		var survivor: CharacterBody3D = round.get_node("OtherGiants/Giant3")
		var coins := round.get_node("Coins")
		giant.position = OPEN_STREET
		rival.position = OPEN_STREET + Vector3.BACK * 100.0
		survivor.position = Vector3(-280.0, 0.01, -260.0)
		await _ticks(3)
		round.tap_stomp()
		await _ticks(2)
		var center := giant.position + STOMP_OFFSET * (height / GIANT_HEIGHT)
		for frame in 30:
			if rival.collision_layer == 0:
				break
			rival.position = center
			await physics_frame
		_check(rival.collision_layer == 0 and round.snapshot().giant_kills == 1,
				"The %.0f m attacker defeats one rival" % height)
		await _ticks(32)
		_check(is_equal_approx(round.snapshot().giant_height, height * 1.5),
				"The kill adds half the other giant's height")
		var expected_coins := 1 if height == 50.0 else 0
		_check(coins.get_child_count() == expected_coins, "A %.0f m kill drops %d coins" % [height, expected_coins])
		if height < 50.0 or coins.get_child_count() != 1:
			continue
		var coin: Node3D = coins.get_child(0)
		_check(coin.position.distance_to(OPEN_STREET) < 0.1 and round.snapshot().coins_collected == 0,
				"The coin stays under the attacker's feet without being collected")
		giant.position = Vector3(320.0, 0.01, 290.0)
		survivor.position = coin.position
		await _ticks(3)
		_check(coins.get_child_count() == 1 and is_equal_approx(round.growth_actors()[2].height, 50.0),
				"A giant at exactly 50 m cannot collect the dropped coin")
		survivor.position = Vector3(-280.0, 0.01, -260.0)
		for frame in 145:
			if rival.collision_layer != 0:
				break
			await physics_frame
		var respawn: Dictionary = round.growth_actors()[1]
		_check(rival.collision_layer == 4 and respawn.height > 0.0 and respawn.height <= 30.0
				and not respawn.human and respawn.can_demolish, "A defeated giant returns at a random giant height within 30 m")
		_check(_distance_on_ground(rival.position, survivor.position) > 150.0
				and _distance_on_ground(rival.position, giant.position) > 150.0,
				"Respawn chooses a point outside both living giants' search ranges when one exists")
		rival.position = coin.position + Vector3.UP * 0.01
		await _ticks(40)
		_check(coins.get_child_count() == 0 and is_equal_approx(round.growth_actors()[1].height, respawn.height + 0.5),
				"The smaller giant gains the stored 0.5 m from the attacker's pre-kill height")


func _check_crowded_respawn() -> void:
	_save({"map_side": 360, "giant_count": 5, "giant_height": 50.0,
			"base_attack": 200.0, "respawn_delay": 0.5})
	_game.start_brawl()
	var round := _round()
	var giant: CharacterBody3D = round.get_node("Giant")
	var rival: CharacterBody3D = round.get_node("OtherGiants/Giant2")
	var survivors: Array[CharacterBody3D] = [giant]
	for index in range(3, 6):
		survivors.append(round.get_node("OtherGiants/Giant%d" % index))
	var quadrants := [
		Vector3(-90, 0.01, -90), Vector3(90, 0.01, -90),
		Vector3(-90, 0.01, 90), Vector3(90, 0.01, 90),
	]
	for index in survivors.size():
		survivors[index].position = quadrants[index]
	giant.position = OPEN_STREET
	rival.position = OPEN_STREET + Vector3.BACK * 100.0
	await _ticks(3)
	round.tap_stomp()
	await _ticks(2)
	var center := giant.position + STOMP_OFFSET * (50.0 / GIANT_HEIGHT)
	for frame in 30:
		if rival.collision_layer == 0:
			break
		rival.position = center
		await physics_frame
	_check(rival.collision_layer == 0, "A giant is defeated on the compact map")
	for frame in 60:
		for index in survivors.size():
			survivors[index].position = quadrants[index]
		if rival.collision_layer != 0:
			break
		await physics_frame
	var actors: Array[Dictionary] = round.growth_actors()
	var has_body_clearance := true
	var inside_search_range := false
	for index in survivors.size():
		var survivor_height: float = actors[0 if index == 0 else index + 1].height
		var distance := _distance_on_ground(rival.position, survivors[index].position)
		inside_search_range = inside_search_range or distance < 150.0
		has_body_clearance = has_body_clearance and distance > 2.9 * (survivor_height + actors[1].height) / GIANT_HEIGHT
	_check(rival.collision_layer == 4 and inside_search_range and has_body_clearance,
			"Full search coverage still allows a physically clear respawn")


func _distance_on_ground(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _check_upward_footfall_damage() -> void:
	_save({"random_start": true, "start_min_height": 18.0, "start_max_height": 28.0,
			"giant_speed": 2.0, "base_attack": 5.0, "map_side": 360})
	var round: Node
	var actors: Array[Dictionary]
	for run_seed in [309, 310, 311, 312, 313, 314]:
		seed(run_seed)
		_game.start_brawl()
		round = _round()
		actors = round.growth_actors()
		if actors[0].height < actors[1].height:
			break
	var small_starts_first: bool = actors[0].height < actors[1].height
	_check(small_starts_first, "The player is the smaller giant in the footfall regression")
	if not small_starts_first:
		return

	var giant: CharacterBody3D = round.get_node("Giant")
	var rival: CharacterBody3D = round.get_node("OtherGiants/Giant2")
	giant.position = OPEN_STREET
	rival.position = Vector3(-100, 0.02, 100)
	await _ticks(4)
	var starting_health: float = round.growth_actors()[1].health
	# Keep the target in the walking footfalls without letting its capsule stop the stride.
	rival.collision_layer = 0
	rival.collision_mask = 1
	Input.action_press("move_forward")
	for frame in 75:
		rival.position = giant.position + Vector3.FORWARD * 1.5
		await physics_frame
	Input.action_release("move_forward")
	_check(giant.position.distance_to(OPEN_STREET) > 4.0
			and is_equal_approx(round.growth_actors()[1].health, starting_health),
			"A smaller giant can walk over a taller rival without dealing passive footfall damage")

	rival.position = Vector3(-100, 0.02, 100)
	await _ticks(70)
	var aim_point: Vector3 = giant.position + STOMP_OFFSET * (actors[0].height / GIANT_HEIGHT)
	var prior_health: float = round.growth_actors()[1].health
	round.tap_stomp()
	for frame in 70:
		rival.position = aim_point
		await physics_frame
		if round.growth_actors()[1].health < prior_health:
			break
	_check(round.growth_actors()[1].health < prior_health,
			"A deliberate stomp can still hit a taller rival")


func _check_giants_pass() -> void:
	for ignore_ratio in [10.0, 3.0]:
		_save({"random_start": true, "start_min_height": 4.0, "start_max_height": 130.0,
				"giant_speed": 2.0, "base_health": 300.0, "base_attack": 1.0,
				"rival_ignore_ratio": ignore_ratio, "map_side": 360})
		var round: Node
		var actors: Array[Dictionary]
		var ratio := 0.0
		for run_seed in range(201, 235):
			seed(run_seed)
			_game.start_brawl()
			round = _round()
			actors = round.growth_actors()
			ratio = float(actors[0].height) / float(actors[1].height)
			if actors[0].height >= 40.0 and ratio >= 4.0 and ratio < 10.0:
				break
		var fitted := ratio >= 4.0 and ratio < 10.0 and float(actors[0].height) >= 40.0
		_check(fitted, "The passage regression has a clear difference in giant sizes")
		if not fitted:
			continue
		var giant: CharacterBody3D = round.get_node("Giant")
		var rival: CharacterBody3D = round.get_node("OtherGiants/Giant2")
		giant.position = OPEN_STREET
		var blocker := Vector3(0, 0.02, -54)
		rival.position = blocker
		await _ticks(4)
		Input.action_press("move_forward")
		for frame in 180:
			rival.position = blocker
			await physics_frame
		Input.action_release("move_forward")
		actors = round.growth_actors()
		_check(giant.position.z < blocker.z - 6.0 and rival.collision_layer == 4
				and actors[0].health == 1.0,
				"A larger giant can walk past a living smaller rival with ignore ratio %.0f" % ignore_ratio)
		if ignore_ratio == 3.0:
			_check(actors[1].health < 1.0, "Passing contact still damages the smaller giant at the configured ratio")
		rival.position = Vector3(-100, 0.02, 100)
		await _ticks(2)
		_check(not giant.get_collision_exceptions().has(rival) and not rival.get_collision_exceptions().has(giant),
				"Separating restores solid collisions for the pair")


func _save(overrides: Dictionary) -> void:
	var brawl: Dictionary = _game.default_mode_settings(BRAWL)
	brawl.merge(overrides, true)
	_game.save_all_mode_settings(_game.get_mode_settings(0), _game.get_mode_settings(1),
			_game.get_mode_settings(2), brawl)


func _round() -> Node:
	return _game.get_node("MapSlot").get_child(0)


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
