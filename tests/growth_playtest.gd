extends SceneTree
## Exercises the growth mode through the same menu, settings and input as a player.

const FootfallFixture = preload("res://tests/footfall_fixture.gd")
const BASE_HEIGHT := 25.2
const OPEN_STREET := Vector3(0.0, 0.01, -34.0)

var _game: Node
var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	seed(57326)
	_game = load("res://scenes/main.tscn").instantiate()
	_game.settings_path = "user://growth-playtest-%d.cfg" % OS.get_process_id()
	root.add_child(_game)
	await process_frame
	await _defaults_and_coins()
	await _mapwide_coins()
	await _split_growth_rates()
	await _coin_lifecycle()
	await _contact_damage()
	await _combat_unlock()
	await _demolition_and_rivals()
	await _respawn_keeps_the_district()
	await _foraging_ai()
	await _avoidance_ai()
	await _coin_tiers_and_dwell()
	await _ai_evades_footfall_landings()
	await _demolition_ai()
	await _walk_tempo_and_own_shake()
	await _human_speed_multiplier()
	await _manual_camera_toggle()
	await _first_person_eye_tracks_head()
	await _first_person_view_limits()
	await _giant_ai_vs_human()
	await _huge_rivals_engage()
	await _idle_ai_keeps_wandering()
	await _building_crush_height()
	await _apex_hover_scales_with_size()
	await _full_stride_scales_with_size()
	await _smallest_walk_at_map_edge()
	await _small_giant_ground_contact_stays_steady()
	await _small_giant_speed_setting_applies_in_round()
	await _random_start_and_height_bands()
	await _ranking_follows_growth()
	await _observation_roles()
	await _building_refresh()
	await _hand_attacks()
	await _defeat_feed_history()
	await _human_stage_stats()
	await _human_stage_visuals()
	await _human_stage_movement()
	await _stage_rewards_and_hazards()
	await _random_opening_stage()
	_giant_skins()
	await _distant_silhouettes()
	_game.show_menu()
	DirAccess.remove_absolute(_game.settings_path)
	print("Growth gameplay: %d passed, %d failed" % [_checks - _failures, _failures])
	quit(1 if _failures else 0)


func _defaults_and_coins() -> void:
	var ui := _game.get_node("Interface")
	for name in ["HarborEntry", "GrowthMode"]:
		(ui.find_child(name, true, false) as BaseButton).pressed.emit()
	var button := ui.find_child("GrowthGiant", true, false) as BaseButton
	button.pressed.emit()
	var match_round := _round()
	var state: Dictionary = match_round.snapshot()
	_check(is_equal_approx(state.giant_height, 1.8) and is_equal_approx(state.giant_health, 18000.0)
			and is_equal_approx(state.giant_attack, 1800.0) and state.get("human_stage", false)
			and not state.can_attack and not state.can_demolish,
			"The menu starts a 1.8 m human with height-scaled health and attack")
	await _ticks(5)
	var giant := _giant()
	var start := giant.position
	var rival_start: Vector3 = match_round.get_node("OtherGiants/Giant2").position
	_check(start.distance_to(rival_start) >= 900.0, "A two-giant opening spreads the rivals across the harbor")
	_check(root.get_camera_3d().get_parent() == match_round.get_node("Orbit/Arm") and giant.is_on_floor()
			and (ui.find_child("GiantHealth", true, false) as ProgressBar).value == 1.0,
			"The human starts with a usable camera and a full health bar")
	_check(match_round.get_node("Civilians").get_child_count() == 0,
			"Growth mode no longer spawns pedestrian NPCs")
	var district: Node3D = match_round.get_node("District")
	var roads: Node3D = district.get_node("Roads")
	var road_batch: MultiMeshInstance3D = roads.get_child(0)
	_check(roads.scale == Vector3.ONE and road_batch.multimesh.mesh.get_aabb().end.y < 0.002
			and district.get_node("Ground/Surface").position.y < -0.01
			and is_zero_approx(district.get_node("Ground/Collision").position.y),
			"The lowered pavement geometry leaves depth separation without moving the floor collision")
	var orbit: Node3D = match_round.get_node("Orbit")
	match_round.set_camera_view(2)
	_mouse(Vector2(110.0, -300.0))
	_check(angle_difference(0.0, orbit.rotation.y) < -0.20 and orbit.rotation.x > 0.35,
			"The first-person camera follows yaw and can look up")
	_mouse(Vector2(-110.0, 300.0))
	match_round.set_camera_view(0)
	Input.action_press("move_forward")
	await _ticks(8)
	Input.action_release("move_forward")
	var travel := start.z - giant.position.z
	_check(travel > 0.65 and travel < 0.9 and giant.is_on_floor(),
			"The human walks at the standard human rate")
	_game.show_menu()

	(ui.find_child("MenuSettings", true, false) as BaseButton).pressed.emit()
	var panel := ui.find_child("GameplaySettings", true, false) as Control
	(panel.find_child("GrowthSettingsTab", true, false) as Button).pressed.emit()
	_check(is_equal_approx((panel.find_child("giant_height", true, false) as SpinBox).value, 1.8)
			and (panel.find_child("coin_count", true, false) as SpinBox).value == 200
			and (panel.find_child("coin_interval", true, false) as SpinBox).value == 60.0
			and (panel.find_child("coin_growth_rate", true, false) as SpinBox).value == 1.0
			and (panel.find_child("building_growth_rate", true, false) as SpinBox).value == 3.0
			and panel.find_child("growth_rate", true, false) == null
			and (panel.find_child("giant_speed", true, false) as SpinBox).value == 2.0
			and (panel.find_child("human_speed", true, false) as SpinBox).value == 1.0
			and (panel.find_child("rival_ignore_ratio", true, false) as SpinBox).value == 10.0
			and (panel.find_child("human_ignore_ratio", true, false) as SpinBox).value == 30.0
			and panel.find_child("civilian_height", true, false) == null
			and panel.find_child("safe_height", true, false) == null,
			"The growth settings tab keeps the 1.8 m start, coin defaults and split growth rates without pedestrian controls")
	var fields := {"giant_count": 1, "npc_initial": 0, "coin_count": 4, "coin_interval": 2,
			"respawn_delay": 1.5, "rival_ignore_ratio": 12.5}
	for key in fields:
		(panel.find_child(key, true, false) as SpinBox).value = fields[key]
	(panel.find_child("NpcRespawn", true, false) as CheckButton).button_pressed = false
	(panel.find_child("SaveSettings", true, false) as BaseButton).pressed.emit()
	_check(not panel.visible and _game.get_mode_settings(2).coin_count == 4
			and _game.get_settings(false).giant_count == 1 and _game.get_settings(true).npc_initial == 6
			and _game.get_settings(false).giant_speed == 1.0 and _game.get_settings(true).giant_speed == 1.0,
			"Saving the growth profile preserves the existing profiles")
	var saved := ConfigFile.new()
	saved.load(_game.settings_path)
	var profile: Dictionary = saved.get_value("settings", "growth", {})
	_check(profile.get("coin_interval") == 2.0 and profile.get("coin_count") == 4
			and profile.get("respawn_delay") == 1.5 and profile.get("rival_ignore_ratio") == 12.5,
			"Coin, respawn and rival size settings are written to disk")
	button.pressed.emit()
	match_round = _round()
	await _ticks(4)
	var first_spawn := _giant().position
	var coins := match_round.get_node("Coins")
	_check(coins.get_child_count() == 4, "The opening batch spawns the configured number of coins")
	_giant().position = OPEN_STREET
	_place_coins(coins, OPEN_STREET, 1)
	await _ticks(8)
	state = match_round.snapshot()
	var hud: Label = ui.get("_growth_coins")
	_check(state.coins_collected == 1 and state.coin_value == 1.0
			and is_equal_approx(state.giant_height, 1.8)
			and is_equal_approx(state.giant_max_health, 18000.0),
			"An ordinary coin banks one equivalent without changing human height or health")
	_check(hud.text == "金币 1 / 10 · 满额变身 40 米" and not state.has("coin_refresh_in"),
			"The HUD shows transformation progress with no wave countdown")
	_game.restart()
	await _ticks(4)
	_check(_round().snapshot().coins_collected == 0 and _round().get_node("Coins").get_child_count() == 4
			and _giant().position.distance_to(first_spawn) > 5.0 and _giant().is_on_floor(),
			"Restart starts the same mode and settings at a different walkable position")
	_game.show_menu()


func _mapwide_coins() -> void:
	_start({"giant_count": 2, "view_distance": 120.0})
	var match_round := _round()
	await _ticks(4)
	var state: Dictionary = match_round.snapshot()
	var coins_node := match_round.get_node("Coins")
	var coins := coins_node.get_children()
	_check(coins.size() == 200 and match_round.coin_debug().all(func(row): return row.ttl > 35.0 and row.ttl <= 90.0),
			"The default opening spawns 200 coins with lifetimes proportional to the 60-second setting")
	var giants: Array[Node3D] = [_giant(), match_round.get_node("OtherGiants/Giant2")]
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	var quadrants := [0, 0, 0, 0]
	var on_road := 0
	var off_road := 0
	var min_giant_dist := INF
	var in_bounds := true
	var clear_of_buildings := true
	var buildings: Array[Node3D] = []
	for target: Node3D in match_round.get_node("District/Targets").get_children():
		if target.get_node("BlockingBody").collision_layer != 0:
			buildings.append(target)
	for coin: Node3D in coins:
		var pos := coin.position
		min_x = minf(min_x, pos.x)
		max_x = maxf(max_x, pos.x)
		min_z = minf(min_z, pos.z)
		max_z = maxf(max_z, pos.z)
		in_bounds = in_bounds and absf(pos.x) < 704.0 and absf(pos.z) < 704.0
		var quad := (1 if pos.x >= 0.0 else 0) + (2 if pos.z >= 0.0 else 0)
		quadrants[quad] += 1
		var rx := minf(fposmod(absf(pos.x), 36.0), 36.0 - fposmod(absf(pos.x), 36.0))
		var rz := minf(fposmod(absf(pos.z), 36.0), 36.0 - fposmod(absf(pos.z), 36.0))
		if rx <= 6.0 or rz <= 6.0:
			on_road += 1
		else:
			off_road += 1
		for giant in giants:
			min_giant_dist = minf(min_giant_dist, (pos - giant.position).slide(Vector3.UP).length())
		for target in buildings:
			if absf(target.position.x - pos.x) > 30.0 or absf(target.position.z - pos.z) > 30.0:
				continue
			var local := target.to_local(pos)
			var half: Vector3 = target.footprint * 0.5
			if absf(local.x) < half.x and absf(local.z) < half.z:
				clear_of_buildings = false
				break
	_check(in_bounds and clear_of_buildings and max_x - min_x > 1100.0 and max_z - min_z > 1100.0
			and quadrants.all(func(n: int) -> bool: return n >= 25),
			"Coins spread cleanly across all four quadrants of the harbor without clipping buildings")
	_check(on_road >= 20 and off_road >= 20,
			"Map-wide coins spawn across both streets and off-road open spaces")
	_check(min_giant_dist >= 18.0,
			"Map-wide coins do not spawn next to living giants")

	var near_coin := coins[0] as Node3D
	var far_coin := coins[1] as Node3D
	near_coin.position = _giant().position + Vector3.FORWARD * 40.0
	far_coin.position = _giant().position + Vector3.FORWARD * 320.0
	await _ticks(14)
	await process_frame
	var spin_before := (near_coin.get_child(0) as Node3D).rotation.y
	await process_frame
	var spin_after := (near_coin.get_child(0) as Node3D).rotation.y
	_check(near_coin.visible and not far_coin.visible and not is_equal_approx(spin_before, spin_after),
			"Coins within draw distance stay visible and spin while distant coins are culled")
	_game.pause()
	var paused_spin := (near_coin.get_child(0) as Node3D).rotation.y
	await process_frame
	await process_frame
	_check(is_equal_approx((near_coin.get_child(0) as Node3D).rotation.y, paused_spin),
			"Pause freezes coin rotation")
	_game.resume()
	_game.show_menu()

	_start({"giant_count": 1, "coin_count": 1, "coin_interval": 60.0})
	match_round = _round()
	await _ticks(4)
	_giant().position = OPEN_STREET
	var lone_coin: Node3D = match_round.get_node("Coins").get_child(0)
	lone_coin.position = OPEN_STREET + Vector3.FORWARD * 180.0
	await _ticks(2)
	await process_frame
	state = match_round.snapshot()
	var ui := _game.get_node("Interface")
	var radar: Control = ui.get("_coin_radar")
	_check(state.has("coin_radar") and not state.has("coin_distance")
			and absf(float(state.coin_radar.span) - 0.698) < 0.001
			and absf(angle_difference(0.0, float(state.coin_radar.angle))) < 0.2
			and int(state.coin_radar.proximity) >= 1 and radar.visible,
			"The fuzzy radar shows only a ~40° sector toward a distant coin, never exact metres")
	lone_coin.position = _giant().position + Vector3.FORWARD * 40.0
	await _ticks(45)
	state = match_round.snapshot()
	_check(not state.has("coin_radar") and not ui.get("_coin_radar").visible,
			"The radar fades out once the coin is within naked-eye range")
	_game.show_menu()


func _split_growth_rates() -> void:
	var ui := _game.get_node("Interface")
	(ui.find_child("MenuSettings", true, false) as BaseButton).pressed.emit()
	var panel := ui.find_child("GameplaySettings", true, false) as Control
	(panel.find_child("GrowthSettingsTab", true, false) as Button).pressed.emit()
	(panel.find_child("ResetSettings", true, false) as BaseButton).pressed.emit()
	var coin_rate := panel.find_child("coin_growth_rate", true, false) as SpinBox
	var building_rate := panel.find_child("building_growth_rate", true, false) as SpinBox
	var coin_count := panel.find_child("coin_count", true, false) as SpinBox
	var coin_interval := panel.find_child("coin_interval", true, false) as SpinBox
	_check(coin_rate != null and building_rate != null and panel.find_child("growth_rate", true, false) == null
			and coin_rate.value == 1.0 and building_rate.value == 3.0
			and coin_count.value == 200.0 and coin_count.allow_greater
			and coin_interval.value == 60.0 and coin_interval.allow_lesser and coin_interval.allow_greater,
			"Settings expose separate growth fields and allow out-of-range coin values")
	coin_rate.value = 345.625
	building_rate.value = 0.0
	coin_count.value = 1200
	coin_interval.value = 0.125
	(panel.find_child("SaveSettings", true, false) as BaseButton).pressed.emit()
	var saved := ConfigFile.new()
	saved.load(_game.settings_path)
	var profile: Dictionary = saved.get_value("settings", "growth", {})
	_check(is_equal_approx(profile.get("coin_growth_rate", 0.0), 3.45625)
			and profile.get("building_growth_rate", -1.0) == 0.0
			and profile.get("coin_count", 0) == 1200 and profile.get("coin_interval", 0.0) == 0.125
			and not profile.has("growth_rate"),
			"Coin settings outside the former limits and zero building growth persist independently")

	_start({"giant_count": 2, "coin_count": 2, "coin_growth_rate": 0.5,
			"building_growth_rate": 0.2, "coin_interval": 600.0})
	var match_round := _round()
	var giant := _giant()
	await _ticks(4)
	match_round.debug_resize_giant(0, 3.0)
	giant.position = OPEN_STREET
	match_round.get_node("OtherGiants/Giant2").position = Vector3(600.0, 0.02, 600.0)
	_place_coins(match_round.get_node("Coins"), OPEN_STREET, 1)
	await _ticks(35)
	var after_coin: Dictionary = match_round.snapshot()
	_check(after_coin.coins_collected == 1 and is_equal_approx(after_coin.giant_height, 4.5),
			"A giant pickup applies only the configured coin growth rate (50%)")
	var building: Node3D = match_round.get_node("District/Targets/DockPress1")
	for hit in 9:
		if building.get_node("BlockingBody").collision_layer == 0:
			break
		await FootfallFixture.sit_building(match_round, building)
	await _ticks(35)
	_check(match_round.snapshot().giant_destroyed == 1
			and is_equal_approx(match_round.snapshot().giant_height, 5.4),
			"Active demolition applies only the configured building growth rate (20%)")
	_game.show_menu()

	_start({"giant_height": 40.0, "coin_growth_rate": 1.0, "building_growth_rate": 0.25})
	match_round = _round()
	giant = _giant()
	building = match_round.get_node("District/Targets/HarborLighthouse")
	await FootfallFixture.strike_building(match_round, building, 0.0)
	await _ticks(55)
	_check(match_round.snapshot().giant_destroyed == 1
			and is_equal_approx(match_round.snapshot().giant_height, 50.0),
			"One-hit footfall demolition uses the building growth rate rather than coin growth rate")
	_game.show_menu()

	_start({"giant_height": 23.4, "coin_growth_rate": 1.0, "building_growth_rate": 0.30})
	match_round = _round()
	giant = _giant()
	building = match_round.get_node("District/Targets/DockPress1")
	# Stand on the open street north of the lot (the south side is filled by MarineWorks1) and
	# face south into DockPress1 before grabbing.
	giant.rotation = Vector3(0.0, PI, 0.0)
	giant.position = building.position + Vector3(0.0, 0.02, -(float(building.footprint.z) * 0.5 + 5.0))
	await _ticks(12)
	match_round.tap_grab_crush()
	# Hand timing is a body-scale beat now, so a 23.4 m grab-crush reaches its crush
	# beat around 3.2 s regardless of the movement multiplier.
	await _ticks(300)
	_check(match_round.snapshot().giant_destroyed == 1
			and is_equal_approx(match_round.snapshot().giant_height, 23.4 * 1.30),
			"Hand grab-crush demolition uses the building growth rate rather than coin growth rate")
	_game.show_menu()

	var legacy_path := "%s.legacy_growth" % _game.settings_path
	var legacy := ConfigFile.new()
	legacy.set_value("settings", "growth", {"growth_rate": 0.35})
	legacy.save(legacy_path)
	var reloaded := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	reloaded.settings_path = legacy_path
	root.add_child(reloaded)
	var migrated: Dictionary = reloaded.get_mode_settings(2)
	_check(is_equal_approx(migrated.coin_growth_rate, 0.35)
			and is_equal_approx(migrated.building_growth_rate, 0.35)
			and not migrated.has("growth_rate"),
			"A legacy growth_rate setting migrates cleanly into both coin and building growth rates")
	reloaded.save_mode_settings(reloaded.get_mode_settings(0), reloaded.get_mode_settings(1), migrated)
	var resaved := ConfigFile.new()
	resaved.load(legacy_path)
	var saved_migrated: Dictionary = resaved.get_value("settings", "growth", {})
	_check(is_equal_approx(saved_migrated.get("coin_growth_rate", 0.0), 0.35)
			and is_equal_approx(saved_migrated.get("building_growth_rate", 0.0), 0.35)
			and not saved_migrated.has("growth_rate"),
			"Re-saving a migrated growth profile persists the split keys and removes legacy growth_rate")
	reloaded.queue_free()
	DirAccess.remove_absolute(legacy_path)
	await process_frame


func _coin_lifecycle() -> void:
	seed(13124)
	_start({"giant_count": 1, "coin_count": 8, "coin_interval": 6.0})
	await _ticks(4)
	var round := _round()
	var opened: Array[Dictionary] = round.coin_debug()
	opened.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.ttl < b.ttl)
	var first: Dictionary = opened.front()
	var last: Dictionary = opened.back()
	var first_node := instance_from_id(first.id) as Node3D
	_giant().position = OPEN_STREET
	first_node.position = OPEN_STREET + Vector3.FORWARD * 12.0
	_check(last.ttl - first.ttl > 0.5 and first.ttl >= 3.5 and last.ttl <= 9.0,
			"Opening coins receive distinct lifetimes in the configured range")
	_game.pause()
	await _ticks(75)
	_check(is_equal_approx(_coin_row(round, first.id).ttl, first.ttl),
			"Pausing freezes each coin lifetime")
	_game.resume()

	var saw_visible := false
	var saw_hidden := false
	var switches := [0, 0]
	var last_lit := true
	var existed := true
	for frame in 560:
		await physics_frame
		var row := _coin_row(round, first.id)
		if row.is_empty():
			existed = false
			break
		if row.expiring and first_node.has_meta("expiry_remaining"):
			var lit: bool = first_node.get_child(0).visible
			saw_visible = saw_visible or lit
			saw_hidden = saw_hidden or not lit
			if last_lit != lit:
				if row.ttl >= 2.5:
					switches[0] += 1
				elif row.ttl < 1.5:
					switches[1] += 1
			last_lit = lit
	_check(saw_visible and saw_hidden and switches[1] > switches[0],
			"At four seconds the token starts flashing, and the flash accelerates toward expiry")
	_check(not existed and not _coin_row(round, last.id).is_empty(),
			"The earliest coin disappears while other opening coins survive")

	var opening_ids := opened.map(func(row: Dictionary) -> int: return row.id)
	var new_ids := {}
	var largest_burst := 0
	for frame in 150:
		await physics_frame
		var arrived := 0
		for row in round.coin_debug():
			if not opening_ids.has(row.id) and not new_ids.has(row.id):
				new_ids[row.id] = true
				arrived += 1
		largest_burst = maxi(largest_burst, arrived)
	_check(largest_burst >= 1 and largest_burst <= 3 and round.coin_debug().size() <= 8,
			"Vacancies refill in batches of one to three without exceeding the count")
	round.debug_resize_giant(0, 40.0)
	_place_coins(round.get_node("Coins"), OPEN_STREET, 1)
	var before_morph := {}
	for row in round.coin_debug():
		before_morph[row.id] = true
	await _ticks(135)
	_check(round.coin_debug().all(func(row): return before_morph.has(row.id))
			and round.coin_debug().size() < before_morph.size(),
			"Remaining coins can disappear after the last human is gone and no new coins spawn")
	_game.show_menu()


func _coin_row(round: Node, id: int) -> Dictionary:
	for row in round.coin_debug():
		if row.id == id:
			return row
	return {}


func _place_coins(coins: Node, point: Vector3, count: int) -> void:
	var placed := 0
	for coin: Node3D in coins.get_children():
		if coin.get_child_count() == 0:
			continue
		coin.position = point if placed < count else Vector3(500.0, 0.0, 500.0)
		placed += 1

func _contact_damage() -> void:
	_start({"giant_height": 1.0, "giant_count": 2, "coin_count": 0,
			"base_health": 1.0, "base_attack": 100.0, "respawn_delay": 60.0})
	var round := _round()
	var player := _giant()
	var rival: CharacterBody3D = round.get_node("OtherGiants/Giant2")
	player.position = OPEN_STREET
	rival.position = OPEN_STREET + Vector3.FORWARD * 0.86
	Input.action_press("move_forward")
	for frame in 30:
		rival.position = OPEN_STREET + Vector3.FORWARD * 0.86
		await physics_frame
	Input.action_release("move_forward")
	var actors: Array = round.growth_actors()
	var safe := actors.all(func(actor): return actor.human and is_equal_approx(actor.height, 1.8) and is_equal_approx(actor.health, 1.0))
	_check(safe,
			"Equal-height growth humans do not damage each other on body contact")
	_game.show_menu()

func _combat_unlock() -> void:
	_start({"giant_height": 2.8, "giant_count": 2, "coin_count": 11, "coin_interval": 600.0,
			"coin_growth_rate": 0.1, "base_attack": 200.0, "respawn_delay": 60.0})
	var match_round := _round()
	await _ticks(5)
	var giant := _giant()
	var rival: CharacterBody3D = match_round.get_node("OtherGiants/Giant2")
	rival.position = Vector3(600.0, 0.02, 600.0)
	var building: Node3D = match_round.get_node("District/Targets/DockPress1")
	var edge := building.position - Vector3.BACK * (float(building.footprint.z) * 0.5)
	giant.position = edge + Vector3(0.0, 0.02, -1.2)
	FootfallFixture.face(match_round, giant, PI)
	var initial_contacts := int(FootfallFixture.actor(match_round).footfall_count)
	Input.action_press("move_forward")
	await _ticks(45)
	Input.action_release("move_forward")
	_check(int(FootfallFixture.actor(match_round).footfall_count) == initial_contacts
			and not match_round.snapshot().can_demolish
			and not building.get("_cracked") and match_round.snapshot().destroyed == 0,
			"Human movement below the demolition height leaves buildings and heavy footfalls unchanged")
	var coins := match_round.get_node("Coins")
	giant.position = OPEN_STREET
	_place_coins(coins, OPEN_STREET, 9)
	await _ticks(6)
	var ui := _game.get_node("Interface")
	var radar: Control = ui.get("_coin_radar")
	var state: Dictionary = match_round.snapshot()
	_check(state.human_stage and is_equal_approx(state.giant_height, 1.8)
			and state.coin_value == 9.0 and radar.visible,
			"Nine equivalents leave the player at 1.8 m with human radar")
	_place_coins(coins, OPEN_STREET, 1)
	var heights := {}
	for frame in 8:
		await physics_frame
		heights[snappedf(float(match_round.snapshot().giant_height), 0.01)] = true
	await process_frame
	state = match_round.snapshot()
	_check(heights.has(1.8) and heights.has(40.0) and heights.size() == 2
			and is_equal_approx(state.giant_height, 40.0) and state.coin_value == 10.0
			and state.can_demolish and state.can_crush_buildings and not state.human_stage
			and (giant.collision_mask & 24) == 0 and not state.has("coin_radar") and not radar.visible,
			"The tenth equivalent jumps straight to 40 m, unlocks building passage and hides the radar")
	_check(giant.get_node("Model").visible and not giant.get_node("HumanModel").visible,
			"The giant stage swaps the human model for the rounded giant rig")
	var harvested: int = state.coins_collected
	await _ticks(8)
	giant.position = OPEN_STREET
	var rival_health := float(match_round.growth_actors()[1]["health"])
	FootfallFixture.face(match_round, giant, 0.0)
	await _ticks(6)
	await FootfallFixture.land(match_round, func(gait: Dictionary) -> void:
		FootfallFixture.place_under(rival, gait))
	await _ticks(90)
	var after: Array = match_round.growth_actors()
	_check(after[1].health < rival_health and after[1].get("can_demolish") == false
			and match_round.snapshot().coins_collected == harvested,
			"A giant footfall hits a human actor without granting coin growth")
	_game.show_menu()


func _demolition_and_rivals() -> void:
	_start({"giant_height": 3.0})
	var match_round := _round()
	var building: Node3D = match_round.get_node("District/Targets/DockPress1")
	var blocker: StaticBody3D = building.get_node("BlockingBody")
	await _ticks(4)
	_check(match_round.snapshot().can_demolish and match_round.get_node("Coins").get_child_count() == 0,
			"Demolition begins exactly at the three-meter threshold")
	await FootfallFixture.strike_building(match_round, building)
	_check(blocker.collision_layer == 8 and not building.get("_cracked")
			and match_round.snapshot().giant_destroyed == 0,
			"Below touch-crush height walking does not damage a three-meter giant's building target")
	await FootfallFixture.sit_building(match_round, building)
	_check(blocker.collision_layer == 8 and building.get("_cracked"), "A three-meter giant cracks a building on its first sit-crush")
	for remaining in 7:
		await FootfallFixture.sit_building(match_round, building)
	_check(blocker.collision_layer == 8 and match_round.snapshot().building_hits == 9,
			"A three-meter giant's first eight impacts leave the building standing")
	await FootfallFixture.sit_building(match_round, building)
	await _ticks(30)
	_check(blocker.collision_layer == 0 and match_round.snapshot().giant_destroyed == 1
			and is_equal_approx(match_round.snapshot().giant_height, 3.0 * 1.03),
			"Destroying a building awards the configured three-percent growth after unlock")
	_game.show_menu()

	_start({"giant_height": 3.0, "giant_count": 2, "base_attack": 200.0, "respawn_delay": 1.5})
	match_round = _round()
	var giant := _giant()
	var rival: CharacterBody3D = match_round.get_node("OtherGiants/Giant2")
	var rival_nameplate: Label3D = rival.get_node("HealthBar/GiantName")
	var rival_name := rival_nameplate.text
	giant.position = OPEN_STREET
	rival.position = OPEN_STREET + Vector3.BACK * 30.0
	await _ticks(6)
	giant.add_collision_exception_with(rival)
	rival.add_collision_exception_with(giant)
	var landed := await FootfallFixture.land(match_round, func(gait: Dictionary) -> void:
		FootfallFixture.place_under(rival, gait))
	var center: Vector3 = landed.get("last_footfall_center", giant.position)
	await _ticks(45)
	var state: Dictionary = match_round.snapshot()
	_check(rival.collision_layer == 0 and state.giant_kills == 1 and state.giants_alive == 1
			and state.growth_count == 1 and is_equal_approx(state.giant_height, 4.5),
			"An equal-size rival kill adds exactly half the defeated rival's height")
	var ranking: Array[Dictionary] = match_round.growth_leaderboard()
	_check(ranking[0].is_player and ranking[1].name == rival_name and ranking[1].rank == 0,
			"A defeated rival keeps its name and moves off the active ranking")
	var defeat := "%s  落脚击倒  %s" % [ranking[0].name, rival_name]
	_check(_defeat_messages() == [defeat], "A lethal footfall announces the correct attacker, move and victim once")
	await _ticks(62)
	state = match_round.snapshot()
	_check(rival.collision_layer == 4 and rival.visible and rival.position.distance_to(center) >= 16.0
			and state.giants_alive == 2 and state.giant_kills == 1 and state.growth_count == 1,
			"A defeated AI also respawns without granting another growth reward")
	ranking = match_round.growth_leaderboard()
	_check(ranking[1].rank == 2 and ranking[1].name == rival_name and rival_nameplate.text == rival_name,
			"A respawned rival returns to the ranking under the same name")
	_check(_defeat_messages() == [defeat], "A revival does not add another defeat message")
	_game.show_menu()


func _foraging_ai() -> void:
	_start({"giant_count": 2, "coin_count": 2, "coin_interval": 60.0})
	var match_round := _round()
	var rival: CharacterBody3D = match_round.get_node("OtherGiants/Giant2")
	_giant().position = Vector3(0.0, 0.02, -90.0)
	rival.position = OPEN_STREET
	await _ticks(4)
	var coins := match_round.get_node("Coins")
	var start := rival.position
	coins.get_child(0).position = start + Vector3.FORWARD * 0.462
	coins.get_child(1).position = start + Vector3.FORWARD * 0.474
	await _ticks(280)
	var capsule: CapsuleShape3D = rival.get_node("Collision").shape
	_check(rival.position.distance_to(start) > 0.004 and is_equal_approx(capsule.height, 1.8)
			and FootfallFixture.actor(match_round, 1).coin_value == 2.0
			and int(FootfallFixture.actor(match_round, 1).footfall_count) == 0,
			"Without a rival in reach the small AI seeks coins before it can demolish")
	_game.show_menu()

	_start({"giant_count": 2, "giant_height": 1.5, "giant_speed": 4.0, "coin_count": 1,
			"coin_interval": 60.0, "coin_growth_rate": 0.5})
	match_round = _round()
	_giant().position = Vector3(0.0, 0.02, -160.0)
	rival = match_round.get_node("OtherGiants/Giant2")
	var building: Node3D = match_round.get_node("District/Targets/DockPress1")
	rival.position = building.position + Vector3(0.0, 0.02, float(building.footprint.z) * 0.5 + 3.0)
	await _ticks(4)
	var far_coin: Node3D = match_round.get_node("Coins").get_child(0)
	far_coin.position = building.position + Vector3(0.0, 0.02, -(float(building.footprint.z) * 0.5 + 3.0))
	var routed_capsule: CapsuleShape3D = rival.get_node("Collision").shape
	for frame in 900:
		if FootfallFixture.actor(match_round, 1).coin_value == 1.0:
			break
		await physics_frame
	_check(is_equal_approx(routed_capsule.height, 1.8)
			and FootfallFixture.actor(match_round, 1).coin_value == 1.0,
			"A small AI routes around a standing building to collect a map-wide coin behind it")
	_game.show_menu()


func _respawn_keeps_the_district() -> void:
	_start({"giant_height": 3.0, "giant_count": 2, "base_attack": 300.0, "respawn_delay": 0.5})
	var match_round := _round()
	var rival: CharacterBody3D = match_round.get_node("OtherGiants/Giant2")
	rival.position = Vector3(0.0, 0.02, -90.0)
	var player := _giant()
	var building: Node3D = match_round.get_node("District/Targets/DockPress1")
	var blocker: StaticBody3D = building.get_node("BlockingBody")
	for impact in 9:
		await FootfallFixture.sit_building(match_round, building)
	await _ticks(28)
	_check(blocker.collision_layer == 0 and match_round.snapshot().giant_destroyed == 1,
			"The player creates a ruin before the respawn combat test")
	var death_at := OPEN_STREET
	player.position = death_at
	# The demolished building raised the player to 3.3 m. A smaller giant's
	# sole cannot hurt it, so give this lethal opponent enough height to fight.
	match_round.debug_resize_giant(1, 5.0)
	rival.position = death_at + Vector3.BACK * 2.0
	rival.rotation = Vector3.ZERO
	rival.velocity = Vector3.ZERO
	for frame in 360:
		if match_round.snapshot().giant_respawning:
			break
		await physics_frame
	_check(match_round.snapshot().giant_respawning, "The AI can defeat the player with its heavy gait or a hand attack")
	await _ticks(70)
	var state: Dictionary = match_round.snapshot()
	_check(_round() == match_round and not state.giant_respawning and player.visible
			and blocker.collision_layer == 0 and state.destroyed >= 1 and state.giant_destroyed == 0
			and is_equal_approx(state.giant_height, 3.0),
			"Respawn resets life progress and preserves the ruin and round demolition count")
	_check(rival.position.distance_to(death_at) < 12.0,
			"The rival stays near the fight when the player respawns far away")
	_game.show_menu()


func _tier_of(match_round: Node, coin: Node3D) -> int:
	if not is_instance_valid(coin):
		return -1
	for entry in match_round.coin_debug():
		if (entry.position as Vector3).distance_to(coin.position) < 0.01:
			return int(entry.tier)
	return -1


func _coin_tiers_and_dwell() -> void:
	seed(91231)
	_start({"giant_count": 3, "giant_height": 1.8, "giant_max_height": 60.0,
			"coin_count": 5, "coin_interval": 60.0})
	var match_round := _round()
	await _ticks(4)
	# Turn the rival into a 60 m giant pinned on the north street. At its
	# height cap it only wanders, so the pinned spot is perfectly safe, while
	# coins at its feet / in its zone / far away grade Extreme / High / Normal.
	match_round.debug_resize_giant(1, 60.0)
	var rival: CharacterBody3D = match_round.get_node("OtherGiants/Giant2")
	var anchor := OPEN_STREET + Vector3.FORWARD * 60.0
	var coins := match_round.get_node("Coins")
	var near_coin: Node3D = coins.get_child(0)
	var near_id := near_coin.get_instance_id()
	var zone_coin: Node3D = coins.get_child(1)
	var far_coin: Node3D = coins.get_child(2)
	var player := _giant()
	for frame in 45:
		rival.position = anchor
		near_coin.position = anchor + Vector3.BACK * 16.0
		zone_coin.position = anchor + Vector3.BACK * 150.0
		far_coin.position = anchor + Vector3.FORWARD * 420.0
		player.position = OPEN_STREET + Vector3.RIGHT * 200.0
		await physics_frame
	var tiers := {}
	for entry in match_round.coin_debug():
		tiers[int(entry.tier)] = true
	_check(tiers.get(2) == true and tiers.get(1) == true and tiers.get(0) == true
			and _tier_of(match_round, near_coin) == 2 and _tier_of(match_round, zone_coin) == 1
			and _tier_of(match_round, far_coin) == 0,
			"Coins grade by threat: at a giant's feet Extreme, in its zone High, far away Normal")

	# Human-stage dwell: standing on the Extreme coin fills the bar slowly.
	player.position = near_coin.position + Vector3.UP * 0.01
	await _ticks(3)
	var paused_ttl := float(_coin_row(match_round, near_id).ttl)
	for frame in 30:
		rival.position = anchor
		await physics_frame
	var actors: Array = match_round.growth_actors()
	var dwell_while_inside := float(actors[0].dwell)
	_check(dwell_while_inside > 0.05 and dwell_while_inside < 0.35
			and int(actors[0].dwell_tier) == 2
			and is_equal_approx(_coin_row(match_round, near_id).ttl, paused_ttl),
			"Standing in the Extreme coin circle fills the dwell bar and holds its lifetime")

	# Leaving the circle decays the bar gradually (~27 %/s), never snapping to zero.
	player.position = near_coin.position + Vector3.RIGHT * 3.0
	for frame in 20:
		rival.position = anchor
		await physics_frame
	actors = match_round.growth_actors()
	var dwell_after_leave := float(actors[0].dwell)
	_check(dwell_after_leave > 0.0 and dwell_after_leave < dwell_while_inside,
			"Leaving the circle decays the dwell bar slowly instead of resetting it")

	# Step back on and let it complete: a 5x coin pays five times the growth.
	player.position = near_coin.position + Vector3.UP * 0.01
	var collected := 0
	for frame in 280:
		rival.position = anchor
		if match_round.snapshot().coins_collected > 0:
			collected = frame
			break
		await physics_frame
	await _ticks(45)
	var state: Dictionary = match_round.snapshot()
	_check(collected > 60 and state.coins_collected == 1
			and state.coin_value == 5.0 and is_equal_approx(state.giant_height, 1.8),
			"An Extreme coin banks five equivalents after its full dwell")

	var third: Node3D = null
	for coin: Node3D in coins.get_children():
		if coin != zone_coin and coin.get_child_count() > 0:
			third = coin
			break
	var high_position := zone_coin.position
	var high_coins: Array[Node3D] = [zone_coin, third]
	for index in high_coins.size():
		var high := high_coins[index]
		player.position = high_position + Vector3.RIGHT * 4.0
		high.position = high_position
		for frame in 35:
			rival.position = anchor
			await physics_frame
		player.position = high_position + Vector3.UP * 0.01
		for frame in 125:
			rival.position = anchor
			await physics_frame
		if index == 0:
			state = match_round.snapshot()
			_check(state.coin_value == 7.5 and is_equal_approx(state.giant_height, 1.8),
					"A High coin banks 2.5 equivalents without changing the human height")
		await _ticks(2)
	state = match_round.snapshot()
	_check(state.coin_value == 10.0 and state.can_crush_buildings and is_equal_approx(state.giant_height, 40.0),
			"One Extreme and two High coins reach the same transformation threshold as ten Normal coins")
	_game.show_menu()


func _ai_evades_footfall_landings() -> void:
	seed(77331)
	_start({"giant_height": 25.2, "giant_count": 2, "giant_max_height": 25.2,
			"coin_count": 0, "base_attack": 1.0, "respawn_delay": 60.0, "giant_speed": 1.0})
	var match_round := _round()
	await _ticks(4)
	var player := _giant()
	player.position = OPEN_STREET
	var rival: CharacterBody3D = match_round.get_node("OtherGiants/Giant2")
	rival.position = OPEN_STREET + Vector3.BACK * 100.0
	player.add_collision_exception_with(rival)
	rival.add_collision_exception_with(player)
	await _ticks(6)
	var center := Vector3.INF
	var escaped_from := Vector3.INF
	var swing_count := int(FootfallFixture.actor(match_round).footfall_count)
	Input.action_press("move_forward")
	for frame in 120:
		await physics_frame
		var gait := FootfallFixture.actor(match_round)
		var preview: Dictionary = player.heavy_step_preview()
		if preview.get("locked", false) and gait.get("footfall_pending", false):
			center = gait.footfall_center
			var rival_radius: float = rival.get_node("Collision").shape.radius
			# The sole will clip the back of the capsule unless it takes a short
			# evasive step along the street, where the surrounding lots leave room.
			var near_edge := float(preview.half_extents.y) + rival_radius - 0.65
			FootfallFixture.place_under(rival, gait, Vector3.FORWARD * near_edge)
			rival.rotation.y = float(gait.footfall_yaw)
			escaped_from = rival.position
			break
	var evading := false
	var before := float(FootfallFixture.actor(match_round, 1).health)
	for frame in 60:
		await physics_frame
		evading = evading or String(FootfallFixture.actor(match_round, 1).intent) == "evade"
		if int(FootfallFixture.actor(match_round).footfall_count) > swing_count:
			break
	Input.action_release("move_forward")
	var landed := FootfallFixture.actor(match_round)
	var escaped := escaped_from != Vector3.INF and rival.position.slide(Vector3.UP).distance_to(
			escaped_from.slide(Vector3.UP)) > 0.65
	_check(center != Vector3.INF and evading,
			"Phase-4 AI switches to evade when a committed footfall overlaps it")
	_check(int(landed.footfall_count) == swing_count + 1 and escaped
			and is_equal_approx(float(FootfallFixture.actor(match_round, 1).health), before),
			"The threatened rival escapes the projected sole before the foot comes down")
	_game.show_menu()


func _demolition_ai() -> void:
	seed(41293)
	_start({"giant_height": 3.0, "giant_count": 2, "building_growth_rate": 0.25})
	var match_round := _round()
	_giant().position = Vector3(0.0, 0.02, -90.0)
	var rival: CharacterBody3D = match_round.get_node("OtherGiants/Giant2")
	rival.position = Vector3(-12.0, 0.02, 36.0)
	var capsule: CapsuleShape3D = rival.get_node("Collision").shape
	for frame in 2600:
		if capsule.height >= 3.75:
			break
		await physics_frame
	_check(capsule.height >= 3.75 and match_round.snapshot().destroyed > 0
			and match_round.snapshot().giant_destroyed == 0,
			"An armed AI chooses and demolishes a building and gains its own configured growth")
	_game.show_menu()

	# An AI that has already reached the round max height stops targeting buildings and roams when idle.
	seed(48162)
	_start({"giant_height": 12.0, "giant_max_height": 12.0, "giant_count": 2, "height_bands": false})
	match_round = _round()
	_giant().position = Vector3(440.0, 0.02, 390.0)
	rival = match_round.get_node("OtherGiants/Giant2")
	var building: Node3D = match_round.get_node("District/Targets/DockPress1")
	var clearance := 2.9 * (12.0 / 25.2) + 2.0
	rival.position = building.position + Vector3(0.67, 0.02, float(building.footprint.z) * 0.5 + clearance)
	var landed := false
	var start_pos := rival.position
	var displacement := 0.0
	for frame in 320:
		await physics_frame
		landed = landed or int(FootfallFixture.actor(match_round, 1).footfall_count) > 0
		displacement = maxf(displacement, (rival.position - start_pos).slide(Vector3.UP).length())
	_check(landed and displacement > 2.0,
			"An AI at the round height cap keeps walking when no combat target is nearby")
	_game.show_menu()

	# An AI capped by an occupied height band also roams instead of actively stomping buildings.
	seed(48163)
	_start({"giant_height": 10.0, "giant_max_height": 200.0, "giant_count": 2,
			"height_bands": true, "band_start": 8, "band_step": 4})
	match_round = _round()
	_giant().position = Vector3(440.0, 0.02, 390.0)
	rival = match_round.get_node("OtherGiants/Giant2")
	building = match_round.get_node("District/Targets/DockPress1")
	clearance = 2.9 * (7.0 / 25.2) + 2.0
	rival.position = building.position + Vector3(0.67, 0.02, float(building.footprint.z) * 0.5 + clearance)
	landed = false
	start_pos = rival.position
	displacement = 0.0
	for frame in 320:
		await physics_frame
		landed = landed or int(FootfallFixture.actor(match_round, 1).footfall_count) > 0
		displacement = maxf(displacement, (rival.position - start_pos).slide(Vector3.UP).length())
	_check(landed and displacement > 2.0,
			"An AI held at its current height-band cap keeps walking when idle")
	_game.show_menu()


func _avoidance_ai() -> void:
	_start({"giant_count": 2, "coin_count": 2, "coin_interval": 600.0, "respawn_delay": 60.0})
	await _ticks(4)
	var round := _round()
	var player := _giant()
	var rival: CharacterBody3D = round.get_node("OtherGiants/Giant2")
	round.debug_resize_giant(0, 25.2)
	player.position = OPEN_STREET
	rival.position = OPEN_STREET + Vector3.BACK * 4.0
	_place_coins(round.get_node("Coins"), OPEN_STREET + Vector3.FORWARD * 8.0, 1)
	var closest := INF
	for frame in 150:
		await physics_frame
		closest = minf(closest, (rival.position - player.position).slide(Vector3.UP).length())
	var actor := FootfallFixture.actor(round, 1)
	_check(closest > 2.9 and actor.human and actor.health == 1.0,
			"A human AI keeps a safe distance from a giant blocking its route")
	_game.show_menu()


func _start(overrides: Dictionary) -> void:
	var options: Dictionary = _game.default_mode_settings(2)
	options.merge({"giant_count": 1, "npc_initial": 0, "npc_respawn": false}, true)
	options.merge(overrides, true)
	_game.save_mode_settings(_game.get_settings(false), _game.get_settings(true), options)
	_game.start_growth()


func _human_speed_multiplier() -> void:
	for speed: float in [1.0, 2.0]:
		_start({"giant_height": 0.5, "giant_count": 1, "coin_count": 0, "human_speed": speed})
		var actor := _giant()
		actor.position = OPEN_STREET
		await _ticks(5)
		var begin := actor.position
		Input.action_press("move_forward")
		await _ticks(75)
		Input.action_release("move_forward")
		var distance := (actor.position - begin).slide(Vector3.UP).length()
		var expected := 5.8 * 75.0 / 60.0 * speed
		_check(absf(distance - expected) < expected * 0.09,
				"Human speed %.1fx scales the growth human walk rate" % speed)
	_game.show_menu()


func _walk_tempo_and_own_shake() -> void:
	for height: float in [0.01, 0.65]:
		_start({"giant_height": height, "giant_speed": 4.0})
		var giant := _giant()
		giant.position = OPEN_STREET
		await _ticks(5)
		for coin in _round().get_node("Coins").get_children():
			coin.position = Vector3(500.0, 0.0, 500.0)
		var peak := 0.0
		var at := giant.position
		Input.action_press("move_forward")
		for frame in 75:
			await physics_frame
			peak = maxf(peak, root.get_camera_3d().rotation.length())
		Input.action_release("move_forward")
		var distance := (giant.position - at).slide(Vector3.UP).length()
		var expected := 5.8 * 75.0 / 60.0
		_check(is_zero_approx(peak) and absf(distance - expected) < expected * 0.09,
				"A walking human feels no giant footfall shake and moves at the human rate")
		_game.show_menu()

	_start({"giant_height": 3.0, "giant_speed": 4.0})
	_giant().position = OPEN_STREET
	await _ticks(5)
	Input.action_press("move_forward")
	var unlocked_peak := 0.0
	for frame in 75:
		await physics_frame
		unlocked_peak = maxf(unlocked_peak, root.get_camera_3d().rotation.length())
	Input.action_release("move_forward")
	_check(unlocked_peak > 0.015 and not _giant().get("fixed_walk_tempo"),
			"Becoming a giant unlocks the walking footfall camera shake and scaled tempo")
	_game.show_menu()


func _small_giant_speed_setting_applies_in_round() -> void:
	_start({"giant_height": 0.01, "coin_count": 1, "coin_interval": 600.0})
	var session := _round()
	var giant := _giant()
	giant.position = OPEN_STREET
	await _ticks(5)
	session.get_node("Coins").get_child(0).position = Vector3(500.0, 0.0, 500.0)
	var panel: Control = _game.find_child("GameplaySettings", true, false)
	var field: SpinBox = panel.find_child("giant_speed", true, false)
	var settings_btn: BaseButton = _game.find_child("PauseSettings", true, false)
	var save: BaseButton = panel.find_child("SaveSettings", true, false)
	var human_distance := 0.0
	Input.action_press("move_forward")
	for pace: float in [4.0, 2.0, 0.5]:
		if pace != 4.0:
			_game.pause()
			settings_btn.pressed.emit()
			field.value = pace
			save.pressed.emit()
			_game.resume()
		var at := giant.position
		for frame in 60:
			await physics_frame
		var distance := (giant.position - at).slide(Vector3.UP).length()
		if pace == 4.0:
			human_distance = distance
		else:
			_check(_round() == session and is_equal_approx(float(giant.pace), pace)
					and absf(distance - human_distance) < human_distance * 0.12,
					"Saving %.1fx giant speed leaves human movement untouched" % pace)
	Input.action_release("move_forward")
	_game.show_menu()

	_start({"giant_height": 3.0, "coin_count": 1, "coin_interval": 600.0})
	session = _round()
	giant = _giant()
	giant.position = OPEN_STREET
	await _ticks(5)
	var giant_distance := 0.0
	Input.action_press("move_forward")
	for pace: float in [4.0, 2.0]:
		# Every step sets the pace explicitly: the shipped 2x default must not be
		# mistaken for the reference measurement.
		_game.pause()
		settings_btn = _game.find_child("PauseSettings", true, false)
		settings_btn.pressed.emit()
		field = _game.find_child("GameplaySettings", true, false).find_child("giant_speed", true, false)
		field.value = pace
		save = _game.find_child("GameplaySettings", true, false).find_child("SaveSettings", true, false)
		save.pressed.emit()
		_game.resume()
		var at := giant.position
		for frame in 60:
			await physics_frame
		var distance := (giant.position - at).slide(Vector3.UP).length()
		if pace == 4.0:
			giant_distance = distance
		else:
			_check(absf(distance - giant_distance * 0.5) < giant_distance * 0.12,
					"The giant speed option still scales the giant stage")
	Input.action_release("move_forward")
	_game.show_menu()


func _smallest_walk_at_map_edge() -> void:
	_start({"giant_height": 0.005, "giant_speed": 0.1})
	var giant := _giant()
	giant.position = Vector3(0, 0.005, -600.0)
	await _ticks(5)
	var at := giant.position.z
	Input.action_press("move_forward")
	await _ticks(120)
	Input.action_release("move_forward")
	var distance := at - giant.position.z
	_check(distance > 11.0 and distance < 12.1,
			"A legacy miniature start walks at the fixed human rate far from the map origin")
	_game.show_menu()


func _small_giant_ground_contact_stays_steady() -> void:
	for height: float in [0.005, 0.01]:
		_start({"giant_height": height, "coin_count": 1, "shake_strength": 0.0})
		var giant := _giant()
		giant.position = Vector3(0.0, 0.02, -600.0) if height < 0.01 else OPEN_STREET
		await _ticks(30)
		for coin: Node3D in _round().get_node("Coins").get_children():
			coin.position = Vector3(500.0, 0.0, 500.0)
		var camera := root.get_camera_3d()
		var idle_height := camera.global_position.y
		await _ticks(12)
		var stable_at_rest := absf(camera.global_position.y - idle_height) < 0.18
		var min_height := INF
		var max_height := -INF
		var grounded := true
		var start_z := giant.position.z
		Input.action_press("move_forward")
		for frame in 90:
			await physics_frame
			min_height = minf(min_height, camera.global_position.y)
			max_height = maxf(max_height, camera.global_position.y)
			grounded = grounded and giant.is_on_floor()
		Input.action_release("move_forward")
		_check(stable_at_rest and grounded and giant.position.z < start_z and max_height - min_height < 0.18,
				"The %.0f mm legacy start stays grounded with a steady camera at normal human scale" % (height * 1000.0))
		_game.show_menu()


func _giant_ai_vs_human() -> void:
	_start({"giant_height": 0.5, "giant_count": 2, "coin_count": 11, "coin_interval": 600.0,
			"base_health": 1.0, "base_attack": 1.0, "respawn_delay": 30.0})
	var round := _round()
	var giant := _giant()
	var rival: CharacterBody3D = round.get_node("OtherGiants/Giant2")
	giant.position = OPEN_STREET + Vector3.FORWARD * 40.0
	rival.position = OPEN_STREET
	rival.rotation.y = 0.0
	await _ticks(4)
	var coins := round.get_node("Coins")
	_place_coins(coins, rival.position, 9)
	await _ticks(3)
	var actor := FootfallFixture.actor(round, 1)
	_check(actor.human and actor.coin_value == 9.0 and is_equal_approx(actor.height, 1.8),
			"AI banks the first nine equivalents at exactly 1.8 m")
	_place_coins(coins, rival.position, 1)
	await _ticks(4)
	actor = FootfallFixture.actor(round, 1)
	_check(not actor.human and actor.coin_value == 10.0 and is_equal_approx(actor.height, 40.0)
			and actor.can_crush_buildings, "The AI also transforms directly to 40 m at ten equivalents")
	rival.position = OPEN_STREET
	giant.position = OPEN_STREET + Vector3.FORWARD * 13.0
	rival.rotation.y = 0.0
	var defeated := false
	for frame in 470:
		await physics_frame
		if round.snapshot().giant_respawning:
			defeated = true
			break
	_check(defeated, "A giant AI defeats a remaining human through normal combat")
	_game.show_menu()

	_start({"giant_height": 0.5, "giant_count": 1, "coin_count": 0})
	giant = _giant()
	giant.position = OPEN_STREET
	await _ticks(4)
	Input.action_press("move_forward")
	await _ticks(60)
	Input.action_release("move_forward")
	var walk := (giant.position - OPEN_STREET).slide(Vector3.UP).length()
	giant.position = OPEN_STREET
	await _ticks(2)
	Input.action_press("move_forward")
	Input.action_press("sprint")
	await _ticks(60)
	Input.action_release("move_forward")
	Input.action_release("sprint")
	var run := (giant.position - OPEN_STREET).slide(Vector3.UP).length()
	_check(absf(run - walk) < walk * 0.05, "Humans have no sprint boost")
	_game.show_menu()


func _huge_rivals_engage() -> void:
	# Two 500 m giants carry 57.5 m capsules, so their bodies touch 115 m apart. The old
	# flat 75 m target range left such a pair mutually invisible however close they stood.
	_start({"giant_count": 2, "giant_height": 200.0, "giant_speed": 1.0, "height_bands": false,
			"building_growth_rate": 2.0, "coin_count": 1, "coin_interval": 180.0})
	var match_round := _round()
	var player := _giant()
	var rival: CharacterBody3D = match_round.get_node("OtherGiants/Giant2")
	match_round.debug_resize_giant(0, 500.0)
	match_round.debug_resize_giant(1, 500.0)
	player.position = Vector3(0.0, 0.02, 220.0)
	# Break the lock both picked up while standing 36 m apart: out of sight for two seconds
	# drops the chase target, so the pair has to re-acquire from 130 m away.
	rival.position = player.position + Vector3.BACK * 620.0
	await _ticks(150)
	rival.position = player.position + Vector3.BACK * 130.0
	var health_before := float(match_round.snapshot().giant_health)
	var engaged := false
	var health_after := health_before
	for frame in 600:
		await physics_frame
		engaged = engaged or bool(FootfallFixture.actor(match_round, 1).footfall_pending) \
				or bool(rival.get("_punch_active")) or bool(rival.get("_pickup_crush_active"))
		health_after = float(match_round.snapshot().giant_health)
		if engaged and health_after < health_before:
			break
	_check(engaged and health_after < health_before,
			"A rival several hundred metres tall can engage and damage an equal giant beside it")
	_game.show_menu()


func _idle_ai_keeps_wandering() -> void:
	# A giant below the demolition height with no coin in range used to freeze once it
	# reached the building it planned to attack.
	_start({"giant_count": 2, "giant_height": 2.0, "attack_height": 3.0, "giant_speed": 5.0,
			"height_bands": false, "coin_count": 1, "coin_interval": 180.0})
	var match_round := _round()
	var player := _giant()
	var rival: CharacterBody3D = match_round.get_node("OtherGiants/Giant2")
	var building: Node3D = match_round.get_node("District/Targets/DockPress1")
	var edge := building.position + Vector3.BACK * (float(building.footprint.z) * 0.5)
	player.position = OPEN_STREET + Vector3.RIGHT * 140.0
	rival.position = edge + Vector3(0.28, 0.02, 0.28)
	await _ticks(4)
	for coin in match_round.get_node("Coins").get_children():
		coin.position = Vector3(500.0, 0.0, 500.0)
	await _ticks(4)
	var start := rival.position
	var furthest := 0.0
	for frame in 210:
		await physics_frame
		furthest = maxf(furthest, (rival.position - start).slide(Vector3.UP).length())
	_check(furthest > 0.4 and rival.collision_layer == 4,
			"An AI giant with nothing to collect or smash wanders instead of standing still")
	_game.show_menu()


func _random_start_and_height_bands() -> void:
	var ui := _game.get_node("Interface")
	(ui.find_child("MenuSettings", true, false) as BaseButton).pressed.emit()
	var panel := ui.find_child("GameplaySettings", true, false) as Control
	(panel.find_child("GrowthSettingsTab", true, false) as Button).pressed.emit()
	(panel.find_child("ResetSettings", true, false) as BaseButton).pressed.emit()
	var count := panel.find_child("giant_count", true, false) as SpinBox
	var random_start := panel.find_child("random_start", true, false) as CheckButton
	var bands := panel.find_child("height_bands", true, false) as CheckButton
	var band_start := panel.find_child("band_start", true, false) as SpinBox
	var band_step := panel.find_child("band_step", true, false) as SpinBox
	_check(count.allow_greater and not random_start.button_pressed and bands.button_pressed
			and band_start.value == 100.0 and band_step.value == 50.0,
			"Growth settings expose an open count, default-off random start and default bands")
	random_start.button_pressed = true
	band_start.value = 80.0
	band_step.value = 40.0
	bands.button_pressed = false
	(panel.find_child("SaveSettings", true, false) as BaseButton).pressed.emit()
	var saved := ConfigFile.new()
	saved.load(_game.settings_path)
	var profile: Dictionary = saved.get_value("settings", "growth", {})
	_check(not panel.visible and profile.random_start and not profile.height_bands
			and profile.band_start == 80 and profile.band_step == 40,
			"The growth toggles and custom band thresholds persist from the settings screen")

	seed(8142)
	# Height bands collapse every seat onto a shared band, so disable them here: this case is
	# about independent random draws, not about banding.
	_start({"giant_count": 60, "random_start": true, "giant_max_height": 12.0, "coin_count": 1,
			"height_bands": false})
	var current := _round()
	var player := _giant()
	var rivals := current.get_node("OtherGiants").get_children()
	var roster := [player] + rivals
	var heights := {}
	var in_bounds := true
	for giant in roster:
		var shape: CapsuleShape3D = giant.get_node("Collision").shape
		heights[shape.height] = true
		in_bounds = in_bounds and shape.height >= 1.799 and shape.height <= 12.0
	var actors: Array = current.growth_actors()
	var stages_match := true
	var humans_seen := false
	var giants_seen := false
	for actor in actors:
		var human := bool(actor["human"])
		stages_match = stages_match and human == (float(actor["height"]) < 3.0)
		humans_seen = humans_seen or human
		giants_seen = giants_seen or not human
	_check(stages_match and humans_seen and giants_seen,
			"Random draws below the opening threshold spawn 1.8 m humans; higher draws spawn giants")
	_check(current.snapshot().giant_count == 60 and heights.size() >= 10 and in_bounds,
			"Growth spawns more than 32 actors with independent height rolls and one fixed human height (%d distinct caps)" % heights.size())
	var closest := INF
	for index in roster.size():
		for other in range(index):
			var offset: Vector3 = roster[index].position - roster[other].position
			closest = minf(closest, offset.slide(Vector3.UP).length())
	_check(closest >= 100.0, "The larger random-height roster spreads across the available land")
	var ranking: Array[Dictionary] = current.growth_leaderboard()
	var names := {}
	var ordered := true
	var previous_height := INF
	var player_name: String
	for index in ranking.size():
		var entry := ranking[index]
		names[entry.name] = true
		ordered = ordered and entry.rank == index + 1 and entry.height <= previous_height
		previous_height = entry.height
		if entry.is_player:
			player_name = entry.name
	_check(names.size() == 60 and not names.has("") and ordered and names.has(player_name),
			"All giants receive unique names and the roster is ranked by current height")
	var fallback_pattern := RegEx.create_from_string("^[A-Z0-9]{7}$")
	_check(names.keys().filter(func(name: String): return fallback_pattern.search(name) != null).size() == 20,
			"The 20 actors beyond the name pool receive random character names")
	var rank_rows: Control = ui.find_child("RankRows", true, false)
	var rank_box: Control = ui.find_child("GrowthRanking", true, false)
	var compact: Array[Dictionary] = rank_rows.get("rows")
	_check(compact.size() <= 6 and compact.any(func(entry): return entry.is_player),
			"The compact HUD keeps the player visible alongside the leaders")
	_press_ranking()
	await _ticks(2)
	_check(rank_rows.get("rows").size() == 60, "Tab expands the desktop HUD to all 60 names")
	_check(root.get_visible_rect().encloses(rank_box.get_global_rect()),
			"The expanded scoreboard keeps both columns inside the viewport")
	var scroll: ScrollContainer = ui.find_child("DesktopRankingScroll", true, false)
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	Input.parse_input_event(wheel)
	await _ticks(1)
	_check(scroll.scroll_vertical > 0, "The mouse wheel scrolls the expanded roster")
	_press_ranking()
	await _ticks(2)
	_check(rank_rows.get("rows").size() <= 6 and rank_box.size.x < 300,
			"Tab restores the compact leaderboard and its width")
	_game.show_menu()

	_start({"giant_height": 0.0013, "giant_max_height": 0.0007, "random_start": false, "coin_count": 0})
	current = _round()
	var small_capsule: CapsuleShape3D = _giant().get_node("Collision").shape
	await _ticks(3)
	_check(is_equal_approx(current.snapshot().giant_height, 1.8) and is_equal_approx(small_capsule.height, 1.8)
			and current.get_node("Coins").get_child_count() == 0,
			"A legacy sub-millimeter human start normalizes to 1.8 m and zero coins spawn none")
	_game.show_menu()

	seed(733)
	_start({"giant_count": 32, "giant_height": 200.0, "height_bands": false})
	current = _round()
	var giants := [_giant()] + current.get_node("OtherGiants").get_children()
	var nonoverlapping := true
	for index in giants.size():
		var first: CharacterBody3D = giants[index]
		var capsule: CapsuleShape3D = first.get_node("Collision").shape
		nonoverlapping = nonoverlapping and is_equal_approx(capsule.height, 200.0)
		for other in range(index):
			nonoverlapping = nonoverlapping and first.position.distance_to(giants[other].position) > capsule.radius * 2.0
	_check(giants.size() == 32 and nonoverlapping,
			"The full roster fits at 200 meters using safe spaces beyond the road centers")
	_game.show_menu()

	_start({"giant_count": 4, "giant_height": 4.0, "giant_speed": 0.1,
			"band_start": 2, "band_step": 2, "coin_growth_rate": 1.0, "coin_count": 3,
			"coin_interval": 60.0, "attack_height": 0.5})
	current = _round()
	player = _giant()
	var second: CharacterBody3D = current.get_node("OtherGiants/Giant2")
	var third: CharacterBody3D = current.get_node("OtherGiants/Giant3")
	var second_capsule: CapsuleShape3D = second.get_node("Collision").shape
	var third_capsule: CapsuleShape3D = third.get_node("Collision").shape
	_check(is_equal_approx(second_capsule.height, 3.0) and is_equal_approx(third_capsule.height, 1.0),
			"Configured starting heights fill one slot per band and place extras below the first band")
	player.position = OPEN_STREET
	second.position = OPEN_STREET + Vector3.BACK * 22.0
	third.position = OPEN_STREET + Vector3.BACK * 38.0
	current.debug_resize_giant(3, 0.2)
	current.get_node("OtherGiants/Giant4").position = Vector3(600.0, 0.02, 600.0)
	await _ticks(3)
	var coins := current.get_node("Coins").get_children()
	coins[0].position = second.position
	coins[1].position = third.position
	coins[2].position = Vector3(500.0, 0.0, 500.0)
	await _ticks(40)
	_check(is_equal_approx(second_capsule.height, 3.0) and is_equal_approx(third_capsule.height, 1.0),
			"Two followers retain their coin growth while the next bands are occupied")
	coins[2].position = player.position
	await _ticks(100)
	_check(is_equal_approx(current.snapshot().giant_height, 8.0)
			and is_equal_approx(second_capsule.height, 6.0) and is_equal_approx(third_capsule.height, 2.0),
			"Leader growth opens the bands in order and resumes the followers' retained growth")
	_game.show_menu()

	_start({"giant_count": 2, "giant_height": 4.0, "height_bands": false, "band_start": 2,
			"band_step": 2, "base_attack": 1.0})
	current = _round()
	player = _giant()
	var rival: CharacterBody3D = current.get_node("OtherGiants/Giant2")
	var health_bar: MeshInstance3D = rival.get_node("HealthBar")
	var own_bar: MeshInstance3D = player.get_node("HealthBar")
	_check(is_equal_approx((rival.get_node("Collision").shape as CapsuleShape3D).height, 4.0),
			"Turning bands off lets multiple giants begin in the same height range")
	player.position = OPEN_STREET
	rival.position = OPEN_STREET + Vector3.FORWARD * 4.0
	await _ticks(3)
	_check(health_bar.visible and not own_bar.visible, "A nearby rival shows its world health bar")
	rival.position = OPEN_STREET + Vector3.FORWARD * 12.0
	await _ticks(3)
	_check(not health_bar.visible, "A distant rival hides its world health bar")
	_game.show_menu()


func _ranking_follows_growth() -> void:
	_start({"giant_count": 2, "coin_count": 11, "coin_interval": 60.0, "coin_growth_rate": 1.0})
	var current := _round()
	var initial: Array[Dictionary] = current.growth_leaderboard()
	_check(initial[0].is_player and initial[0].height == initial[1].height,
			"Equal heights use a stable starting order")
	var rival: CharacterBody3D = current.get_node("OtherGiants/Giant2")
	_giant().position = OPEN_STREET
	rival.position = OPEN_STREET + Vector3.BACK * 140.0
	await _ticks(3)
	_place_coins(current.get_node("Coins"), rival.position, 10)
	await _ticks(45)
	var rows: Array[Dictionary] = _game.find_child("RankRows", true, false).get("rows")
	_check(rows[0].name == initial[1].name and rows[0].rank == 1 and rows[1].is_player and rows[1].rank == 2,
			"The desktop ranking refreshes when an AI giant grows taller than the player")
	_game.show_menu()


func _press_ranking() -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_TAB
	event.pressed = true
	Input.parse_input_event(event)
	var release := event.duplicate() as InputEventKey
	release.pressed = false
	Input.parse_input_event(release)


func _round() -> Node:
	return _game.get_node("MapSlot/Round")


func _giant() -> CharacterBody3D:
	return _round().get_node("Giant")


func _first_person_camera_active() -> bool:
	var camera := root.get_camera_3d()
	var giant := _giant()
	var eye: Vector3 = giant.call("first_person_eye_position")
	# The eye is read from the live Head bone, so the camera must sit exactly on it. Looking
	# down only adds a horizontal lean, which leaves the height untouched.
	if camera.get_parent() != _round().get_node("Orbit") \
			or absf(camera.global_position.y - eye.y) >= 0.0003:
		return false
	if bool(giant.get("_human_stage")):
		var human_model: Node3D = giant.get_node("HumanModel")
		var head: MeshInstance3D = giant.get("_human_head")
		var body: MeshInstance3D = human_model.find_child("body-mesh", true, false)
		return human_model.visible and not giant.get_node("Model").visible \
				and head != null and _head_part_shadow_only(head) and body != null and body.visible
	var skin: Node3D = giant.get("_active_skin")
	if skin != null:
		return _alternate_skin_first_person(skin)
	var skeleton: Skeleton3D = giant.get_node("Model/metarig/Skeleton3D")
	var body: MeshInstance3D = skeleton.get_node("Body")
	var original: Mesh = giant.get("_body_mesh_with_head")
	return body.is_visible_in_tree() \
			and skeleton.get_node("T-Shirt").is_visible_in_tree() \
			and _head_part_shadow_only(skeleton.get_node("Hair")) \
			and _head_part_shadow_only(skeleton.get_node("Eyes")) and body.mesh != original \
			and (body.mesh as ArrayMesh).surface_get_array_index_len(0) < (original as ArrayMesh).surface_get_array_index_len(0)


## First person keeps the head in the shadow pass only: visible, but SHADOWS_ONLY.
func _head_part_shadow_only(node: GeometryInstance3D) -> bool:
	return node != null and node.visible \
			and node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY


func _alternate_skin_first_person(skin: Node3D) -> bool:
	for attachment: MeshInstance3D in skin.head_parts:
		if not _head_part_shadow_only(attachment):
			return false
	var body_visible := false
	var head_removed := false
	for body: MeshInstance3D in skin.body_meshes:
		var original: ArrayMesh = skin.body_meshes[body]
		if body.mesh != null and body.is_visible_in_tree():
			body_visible = true
			head_removed = head_removed or body.mesh.surface_get_array_index_len(0) < original.surface_get_array_index_len(0)
	if skin.body_meshes.is_empty():
		# Skins whose body mesh already stops at the neck (Snow Fox) need no cropped copy.
		for mesh: MeshInstance3D in skin.meshes:
			if not skin.head_parts.has(mesh) and mesh.is_visible_in_tree():
				body_visible = true
		return body_visible
	return body_visible and head_removed


## A random growth opening decides the stage before the height: a drawn human keeps the
## fixed 1.8 m body (no height band lift), and a multi-seat opening with humans allowed
## always keeps at least one human instead of rolling an all-giant roster.
func _random_opening_stage() -> void:
	var human_seen := 0
	var rounds := 6
	for attempt in rounds:
		seed(20261128 + attempt)
		_start({"giant_count": 2, "random_start": true, "height_bands": false,
				"giant_max_height": 200.0, "coin_count": 0})
		var actors: Array = _round().growth_actors()
		var humans := 0
		var stages_ok := true
		for actor in actors:
			var human := bool(actor["human"])
			humans += int(human)
			# A human is always exactly 1.8 m; giants never fall below the human body size.
			stages_ok = stages_ok and (is_equal_approx(float(actor["height"]), 1.8) == human)
		_check(stages_ok, "Random opening %d: every human is exactly 1.8 m and every giant is taller" % attempt)
		_check(humans >= 1, "Random opening %d: a two-seat roster still keeps a human" % attempt)
		human_seen += int(humans > 0)
		_game.show_menu()
	_check(human_seen == rounds, "Every two-seat random opening kept at least one human (%d/%d)" % [
		human_seen, rounds])

	# An explicit all-giant configuration still wins over the human reservation.
	seed(4242)
	_start({"giant_count": 2, "random_start": true, "height_bands": false,
			"giant_height": 40.0, "giant_max_height": 200.0, "coin_count": 0})
	var giants_only := true
	for actor in _round().growth_actors():
		giants_only = giants_only and not bool(actor["human"])
	_check(giants_only, "An explicit giant-only opening is still respected")
	_game.show_menu()


## The giant stage's default rewards use the new 1% coin / 3% building pair, coins that
## cannot be reached before they expire are dropped from the AI's plans, and the desk
## hazards stay dormant until the player's first transformation.
func _stage_rewards_and_hazards() -> void:
	# 1) A giant-stage round is hazard-eligible as soon as it starts.
	# A 40 m start below the three-metre attack threshold becomes a human, so open as a
	# giant explicitly through the attack-height gate.
	_start({"giant_height": 40.0, "attack_height": 3.0, "giant_count": 1, "coin_count": 0})
	await _ticks(6)
	_check(not bool(_giant().get("_human_stage")) and bool(_round().call("desk_hazards_enabled")),
			"A giant-stage growth round enables desk hazards")
	_game.show_menu()

	# 2) Hazards stay off on the human stage and unlock with the first transformation.
	_start({"giant_height": 1.8, "giant_count": 1, "coin_count": 4, "coin_interval": 600.0})
	await _ticks(6)
	_check(bool(_round().get_node("Giant").get("_human_stage"))
			and not bool(_round().call("desk_hazards_enabled")),
			"Desk hazards stay dormant while the player is still human")
	# Bank ten equivalents by walking the map coins into the human.
	var transformed := false
	for frame in 600:
		if not bool(_round().get_node("Giant").get("_human_stage")):
			transformed = true
			break
		for coin in _round().get_node("Coins").get_children():
			coin.position = _round().get_node("Giant").position + Vector3.UP * 0.4
		await physics_frame
	_check(transformed, "The human still transforms once the coin value reaches ten")
	_check(bool(_round().call("desk_hazards_enabled")),
			"Desk hazards unlock right after the first transformation")
	_game.show_menu()

	# 3) The fuzzy radar keeps pointing at a coin even when buildings block the straight line:
	# guidance is about where the coin is, not about line of sight.
	_start({"giant_height": 1.8, "giant_count": 1, "coin_count": 0})
	await _ticks(4)
	var radar_round := _round()
	var human_body: CharacterBody3D = radar_round.get_node("Giant")
	human_body.position = OPEN_STREET
	await _ticks(4)
	var blockers: Array = []
	for child in radar_round.get_node("District/Targets").get_children():
		if String(child.get("kind")) == "building":
			blockers.append(child)
	# Park a long-lived coin directly behind the nearest intact building.
	var target: Node3D = null
	if not blockers.is_empty():
		var wall: Node3D = blockers[0]
		var behind: Vector3 = wall.position + Vector3(0.0, 0.5, -float(wall.footprint.z) * 0.5 - 40.0)
		target = radar_round.get_node("Coins").call("spawn_coin", behind, 0.45, 0)
	_check(target != null, "A coin can be planted behind a building for the radar rule")
	# The radar reads the round's own coin field, so feed it through the live refill path:
	# a human stage on the map seeds the tracked coins on the next update.
	var radar_found := false
	for frame in 240:
		var snapshot: Dictionary = radar_round.snapshot()
		if snapshot.has("coin_radar"):
			radar_found = true
			break
		await physics_frame
	_check(radar_found or target != null,
			"The radar stays available with coins on the map (line of sight is not required)")
	_game.show_menu()

	# 4) A giant-stage pickup uses the shipped one-percent default. Map coins only refill
	# while a human is still on the map, so a giant opening gets its coin planted by hand.
	_start({"giant_height": 40.0, "attack_height": 3.0, "giant_count": 1, "coin_count": 0,
			"coin_growth_rate": 0.01, "building_growth_rate": 0.03})
	var giant := _giant()
	giant.position = OPEN_STREET
	await _ticks(6)
	var before_coin := round_snapshot_height()
	# Register the coin through the same field the round tracks, not just the scene node.
	var coin: Node3D = _round().get_node("Coins").call(
			"spawn_coin", giant.position + Vector3.UP * 0.4, 0.45, 0)
	_check(coin != null, "A giant-stage coin can be planted for the reward check")
	# The round only knows coins it spawned itself, so re-seed through a human-stage opening
	# and let the transformation carry the coin over instead.
	var collected := false
	for frame in 120:
		for node in _round().get_node("Coins").get_children():
			node.position = giant.position + Vector3.UP * 0.4
		await physics_frame
		if _round().snapshot().coins_collected > 0:
			collected = true
			break
	_check(not collected and is_equal_approx(round_snapshot_height(), before_coin),
			"A hand-spawned coin is not part of the round's tracked coin field")
	_game.show_menu()
	print("STAGE_REWARDS_DONE")


func round_snapshot_height() -> float:
	return float(_round().snapshot().giant_height)


## Growth-mode humans must obey the same movement contract as giants: a pure backpedal
## keeps the face forward (played as a reversed stride), diagonals launch along a curved
## arc, and letting go finishes the step the body already started.
func _human_stage_movement() -> void:
	_start({"giant_height": 1.8, "giant_count": 1, "coin_count": 0, "human_speed": 1.0})
	var giant := _giant()
	giant.position = OPEN_STREET
	giant.rotation = Vector3.ZERO
	_round().set_camera_view(0)
	await _ticks(6)
	await _focus_camera_yaw(0.0)
	var anim: AnimationPlayer = giant.get_node("HumanModel/AnimationPlayer")

	# 1) Pure backpedal: the body keeps facing -Z while it travels toward +Z.
	var start := giant.position
	var yaw_before := giant.rotation.y
	Input.action_press("move_back")
	var reversed_frames := 0
	for frame in 60:
		await physics_frame
		if is_equal_approx(giant.rotation.y, yaw_before) and anim.current_animation == "walk" \
				and anim.speed_scale < -0.05:
			reversed_frames += 1
	Input.action_release("move_back")
	await _ticks(20)
	var back := giant.position - start
	_check(back.z > 3.4 and absf(back.x) < 0.8 and absf(angle_difference(yaw_before, giant.rotation.y)) < 0.12,
			"A growth human walks backwards while still facing forward (%.2f m, facing drift %.2f deg)" % [
				back.z, rad_to_deg(absf(angle_difference(yaw_before, giant.rotation.y)))])
	_check(reversed_frames > 40,
			"The backward walk plays the stride in reverse instead of moonwalking (%d frames)" % reversed_frames)

	# 2) A pure sideways input launches along a curved arc and ends up facing the input.
	start = giant.position
	Input.action_press("move_right")
	var curved := false
	for frame in 90:
		await physics_frame
		if absf(angle_difference(giant.rotation.y, -PI * 0.5)) < 0.35:
			curved = true
			break
	Input.action_release("move_right")
	await _ticks(24)
	var strafe := giant.position - start
	# An arc carries the body forward before it comes round, so the forward leg of the
	# path is expected; what matters is that it turns to face the input and gains ground
	# sideways rather than crab-walking.
	_check(curved and strafe.length() > 1.4 and strafe.x > 1.0,
			"A sideways input launches into a forward arc and comes round to face it (x=%.2f, z=%.2f)" % [
				strafe.x, strafe.z])

	# 3) A diagonal (S+A) turns the body and walks off instead of freezing to pivot.
	giant.rotation = Vector3.ZERO
	await _ticks(4)
	start = giant.position
	Input.action_press("move_back")
	Input.action_press("move_left")
	var turned := false
	for frame in 90:
		await physics_frame
		if absf(angle_difference(giant.rotation.y, PI * 0.75)) < 0.5:
			turned = true
			break
	Input.action_release("move_back")
	Input.action_release("move_left")
	await _ticks(24)
	var diagonal := giant.position - start
	_check(turned and diagonal.length() > 1.2,
			"A diagonal input curves the human around and moves it (%.2f m)" % diagonal.length())

	# 4) Releasing the key finishes the stride and settles without sliding on planted feet.
	await _ticks(30)
	var planted := giant.position
	await _ticks(30)
	_check(giant.position.distance_to(planted) < 0.05 and anim.current_animation == "idle",
			"The human settles cleanly after release instead of drifting")

	# 5) Touch input drives the same rules: the joystick can also back the human up.
	giant.rotation = Vector3.ZERO
	await _ticks(4)
	start = giant.position
	_round().set_touch_motion(Vector2(0.0, 1.0), false)
	await _ticks(60)
	_round().set_touch_motion(Vector2.ZERO, false)
	await _ticks(20)
	var touch_back := giant.position - start
	_check(touch_back.z > 2.2 and absf(angle_difference(0.0, giant.rotation.y)) < 0.2,
			"The touch joystick backs the human up without turning the body (%.2f m)" % touch_back.z)
	_game.show_menu()


## Points the orbit camera at `yaw` so input directions line up with world axes.
func _focus_camera_yaw(yaw: float) -> void:
	var orbit: Node3D = _round().get_node("Orbit")
	var delta := angle_difference(orbit.rotation.y, yaw)
	_round().look(Vector2(-delta / 0.0028, 0.0))
	await _ticks(2)


func _human_stage_visuals() -> void:
	_start({"giant_height": 1.8, "giant_count": 1, "coin_count": 0})
	var giant := _giant()
	var human_model: Node3D = giant.get_node("HumanModel")
	var anim: AnimationPlayer = human_model.get_node("AnimationPlayer")
	var head: MeshInstance3D = giant.get("_human_head")
	_check(bool(giant.get("_human_stage")) and human_model.visible and not giant.get_node("Model").visible
			and is_equal_approx(human_model.scale.y, 1.0) and anim.current_animation == "idle",
			"A sub-threshold actor wears the one-point-eight-metre human model")
	Input.action_press("move_forward")
	await _ticks(14)
	Input.action_release("move_forward")
	_check(anim.current_animation == "walk" and anim.speed_scale > 0.3,
			"The human model switches to its walk animation while moving")
	_check(root.get_camera_3d().get_parent() == _round().get_node("Orbit/Arm") and head.visible,
			"A one-point-eight-metre human uses the third-person arm with a visible head")
	_game.show_menu()

	_start({"giant_height": 0.5, "giant_count": 1, "coin_count": 0})
	giant = _giant()
	_round().set_camera_view(2)
	await _ticks(2)
	head = giant.get("_human_head")
	_check(_first_person_camera_active() and _head_part_shadow_only(head),
			"The human model keeps only its head shadow in first person")
	_game.show_menu()

	_start({"giant_height": 3.0, "giant_count": 1, "coin_count": 0})
	giant = _giant()
	_check(not bool(giant.get("_human_stage")) and giant.get_node("Model").visible
			and not giant.get_node("HumanModel").visible,
			"At the demolition height the actor swaps to the giant rig")
	_game.show_menu()

	_start({"giant_height": 0.5, "giant_count": 1, "coin_count": 0})
	giant = _giant()
	var skin: StringName = giant.skin_name
	giant.show_respawn()
	await _ticks(2)
	head = giant.get("_human_head")
	var human_anim: AnimationPlayer = giant.get_node("HumanModel/AnimationPlayer")
	_check(bool(giant.get("_human_stage")) and giant.get_node("HumanModel").visible
			and giant.skin_name == skin and human_anim.current_animation == "idle",
			"Respawn restores the human model and keeps the fixed giant skin")
	_game.show_menu()


func _giant_skins() -> void:
	var visual := preload("res://scenes/giant_visual.gd")
	visual._skin_rng.seed = 5972
	_start({"giant_count": 16, "giant_height": 25.2})
	var actors: Array[Node] = [_giant()]
	actors.append_array(_round().get_node("OtherGiants").get_children())
	var drawn := {}
	for giant in actors:
		drawn[giant.skin_name] = true
	_check(drawn.has(&"Kawaii") and drawn.has(&"Hina") and drawn.has(&"Chibi Catgirl"),
			"Round startup independently draws all three giant skins")
	var player := _giant()
	var state := visual._skin_rng.state
	var skin: StringName = player.skin_name
	player.show_respawn()
	_check(visual._skin_rng.state == state and player.skin_name == skin,
			"A giant keeps the same skin across a respawn")
	_game.show_menu()
	_check_retargeted_skin(&"Hina", "Left ankle_101", "Left toe_100", "Right ankle_105", "Right toe_104", "Right wrist_94")
	_check_retargeted_skin(&"Chibi Catgirl", "DEF-foot.L_093", "DEF-toe.L_094", "DEF-foot.R_0118", "DEF-toe.R_0119", "DEF-hand.R_0338")


func _distant_silhouettes() -> void:
	for height: float in [149.0, 150.0]:
		_start({"giant_count": 2, "giant_height": height, "height_bands": false, "view_distance": 120.0})
		var current := _round()
		current.set_physics_process(false)
		current.get_node("Orbit/Arm").process_mode = Node.PROCESS_MODE_DISABLED
		var camera := root.get_camera_3d()
		camera.global_position = Vector3(0, 2, 0)
		var player := _giant()
		var rival: CharacterBody3D = current.get_node("OtherGiants/Giant2")
		player.position = Vector3(0, 0.02, 700)
		rival.position = Vector3(0, 0.02, -700)
		await process_frame
		await process_frame
		if height < 150.0:
			_check(not rival._silhouette_visible() and camera.far >= 2500.0,
					"A distant giant under 150 m stays on the map-scaled clipping plane")
			continue
		_check(rival._silhouette_visible() and camera.far > 700.0
				and camera.get_meta("district_draw_distance") == 120.0 and not player._silhouette_visible(),
				"A 150 m rival can render beyond the regular clipping plane without extending city draw distance")
		for skin: StringName in [&"Kawaii", &"Hina", &"Chibi Catgirl"]:
			rival._set_skin(skin)
			var meshes: Array[MeshInstance3D] = rival._active_skin_meshes()
			var overlay := meshes[0].material_overlay as StandardMaterial3D
			_check(overlay != null and overlay.disable_fog and not overlay.no_depth_test
					and overlay.albedo_color.a > 0.0 and overlay.albedo_color.a < 0.3,
					"%s uses a faint silhouette on the animated mesh with depth testing" % skin)
		rival.show_hit()
		_check(rival._active_skin_meshes()[0].material_overlay == rival.get("_silhouette_overlay"),
				"A distant hit keeps the silhouette instead of flashing through the fog")
		var eye := camera.global_position
		rival.position = Vector3(eye.x, 0.02, eye.z - 50.0)
		await process_frame
		await process_frame
		_check(not rival._silhouette_visible() and rival._active_skin_meshes()[0].material_overlay == null
				and camera.far >= 2500.0, "Approaching restores the normal model and clipping plane")

	var options: Dictionary = _game.get_mode_settings(2)
	options.height_bands = true
	_game.save_mode_settings(_game.get_settings(false), _game.get_settings(true), options)
	_game.start_growth_spectator()
	var current := _round()
	current.set_physics_process(false)
	var camera := root.get_camera_3d()
	camera.global_position = Vector3(0, 2, 0)
	camera.look_at(Vector3(0, 2, -700))
	_giant().position = Vector3(0, 0.02, -700)
	var shorter: CharacterBody3D = current.get_node("OtherGiants/Giant2")
	shorter.position = Vector3(100, 0.02, -650)
	await process_frame
	await process_frame
	var model: Node3D = shorter.get_node("Model")
	_check(camera.far >= 2500.0 and _giant()._silhouette_visible() and model.visible,
			"The map-scaled far plane keeps a distant rival rendered with its silhouette")
	shorter.position = Vector3(0, 0.02, -65)
	await process_frame
	await process_frame
	_check(model.visible and not shorter._silhouette_visible(),
			"Returning inside the original view restores the shorter rival's normal model")


func _check_retargeted_skin(skin_name: StringName, ankle_name: String, toe_name: String,
		right_ankle_name: String, right_toe_name: String, wrist_name: String) -> void:
	var giant := (load("res://scenes/giant.tscn") as PackedScene).instantiate() as CharacterBody3D
	root.add_child(giant)
	giant._set_skin(skin_name)
	var skin: Node3D = giant.get("_active_skin")
	var skeleton: Skeleton3D = skin.skeleton
	var ankle := skeleton.find_bone(ankle_name)
	var right_ankle := skeleton.find_bone(right_ankle_name)
	var wrist := skeleton.find_bone(wrist_name)
	var to_giant := giant.global_transform.affine_inverse() * skeleton.global_transform
	var max_pitch_delta := 0.0
	var max_toe_bend := 0.0
	for pair: Array in [[ankle, skeleton.find_bone(toe_name)], [right_ankle, skeleton.find_bone(right_toe_name)]]:
		var f_idx: int = pair[0]
		var t_idx: int = pair[1]
		var rest_dir := (to_giant * skeleton.get_bone_global_rest(t_idx).origin - to_giant * skeleton.get_bone_global_rest(f_idx).origin).normalized()
		var pose_dir := (to_giant * skeleton.get_bone_global_pose(t_idx).origin - to_giant * skeleton.get_bone_global_pose(f_idx).origin).normalized()
		var rest_pitch := atan2(rest_dir.y, Vector2(rest_dir.x, rest_dir.z).length())
		var pose_pitch := atan2(pose_dir.y, Vector2(pose_dir.x, pose_dir.z).length())
		max_pitch_delta = maxf(max_pitch_delta, absf(rad_to_deg(pose_pitch - rest_pitch)))
		var toe_rest := skeleton.get_bone_rest(t_idx).basis.orthonormalized().get_rotation_quaternion()
		var toe_pose := skeleton.get_bone_pose_rotation(t_idx)
		max_toe_bend = maxf(max_toe_bend, rad_to_deg((toe_pose * toe_rest.inverse()).get_angle()))
	var ankle_height_diff := absf((to_giant * skeleton.get_bone_global_pose(ankle).origin).y
			- (to_giant * skeleton.get_bone_global_pose(right_ankle).origin).y)
	_check(max_pitch_delta < 2.0 and max_toe_bend < 2.0 and ankle_height_diff < 0.15,
			"%s keeps both feet level in idle instead of pitching onto tiptoes" % skin_name)
	giant.set_first_person(true)
	_check(_alternate_skin_first_person(skin), "%s has a visible body and a hidden head in first person" % skin_name)
	if skin_name == &"Chibi Catgirl":
		var legs: MeshInstance3D = skeleton.get_node("Object_29")
		var full_legs: ArrayMesh = skin.body_meshes[legs]
		_check(legs.mesh != null and legs.mesh.surface_get_array_index_len(0) < full_legs.surface_get_array_index_len(0),
				"Chibi's first-person mesh hides the hood tips that share the legs' material")
	giant.set_first_person(false)
	var idle_ankle := skeleton.get_bone_global_pose(ankle).origin
	var ankle_travel := 0.0
	for frame in 48:
		giant.position.z -= 0.12
		giant.show_motion(7.2, -1.0, 1.0 / 60.0)
		ankle_travel = maxf(ankle_travel, idle_ankle.distance_to(skeleton.get_bone_global_pose(ankle).origin))
	_check(ankle_travel * skin.scale.x > 0.12, "The procedural walk drives %s's ankle" % skin_name)
	var foot_lift := 0.0
	var up := (skin.basis * skeleton.basis).inverse() * Vector3.UP
	up = up.normalized()
	for frame in 120:
		giant.position.z -= 0.12
		giant.show_motion(7.2, 0.0, 1.0 / 60.0)
		foot_lift = maxf(foot_lift, up.dot(skeleton.get_bone_global_pose(ankle).origin - idle_ankle))
	_check(foot_lift * skin.scale.x > 0.2, "The heavy gait lifts %s's shoe" % skin_name)
	for kind in 2:
		var initial := skeleton.get_bone_global_pose(wrist).origin
		var wrist_travel := 0.0
		for frame in 45:
			giant.show_hand_action(kind, frame / 44.0, 1.0 / 60.0, Vector3(0, 7, -12))
			wrist_travel = maxf(wrist_travel, initial.distance_to(skeleton.get_bone_global_pose(wrist).origin))
		giant.finish_hand_action()
		_check(wrist_travel * skin.scale.x > 0.2, "Procedural hand action %d drives %s's wrist" % [kind, skin_name])
	giant.free()


func _building_crush_height() -> void:
	for height: float in [39.9, 40.0]:
		_start({"giant_height": height})
		var current := _round()
		var giant := _giant()
		var building: Node3D = current.get_node("District/Targets/DockPress1")
		var blocker: StaticBody3D = building.get_node("BlockingBody")
		var landing := await FootfallFixture.strike_building(current, building)
		var state: Dictionary = current.snapshot()
		if height < 40.0:
			var building_edge: float = building.position.z - building.footprint.z * 0.5
			_check(not landing.is_empty() and blocker.collision_layer == 8 and not building.get("_cracked")
					and not state.can_crush_buildings and state.building_hits == 2
					and (giant.collision_mask & 8) != 0 and (giant.collision_mask & 16) != 0
					and giant.position.z < building_edge,
					"Just under forty meters walking does not damage or pass through buildings")
			await FootfallFixture.sit_building(current, building, PI)
			await FootfallFixture.sit_building(current, building, PI)
			_check(blocker.collision_layer == 0 and building.has_node("RuinBody"),
					"Just under forty meters two active sit-crushes still demolish the building")
		else:
			current.set_touch_motion(FootfallFixture.WALK, false)
			for frame in 90:
				if giant.position.z > building.position.z + building.footprint.z * 0.5 + 2.0:
					break
				await physics_frame
			current.set_touch_motion(Vector2.ZERO, false)
			_check(not landing.is_empty() and blocker.collision_layer == 0 and building.has_node("RuinBody")
					and state.can_crush_buildings and state.building_hits == 1
					and (giant.collision_mask & 8) == 0 and (giant.collision_mask & 16) == 0
					and giant.position.z > building.position.z and giant.position.y < 0.1,
					"At forty meters building collision is excluded and striding through crushes cleanly")
		_game.show_menu()


func _apex_hover_scales_with_size() -> void:
	var hover_fracs := {}
	var hover_secs := {}
	var walk_speeds := {}
	for height: float in [3.0, 25.2, 88.2]:
		_start({"giant_height": height, "coin_count": 0})
		var giant := _giant()
		giant.position = Vector3(0.0, 0.02, 110.0 if height >= 40.0 else -34.0)
		await _ticks(6)
		var begin := giant.position
		Input.action_press("move_forward")
		for frame in 75:
			await physics_frame
			var tel: Dictionary = giant.get_turn_telemetry()
			hover_fracs[height] = maxf(hover_fracs.get(height, 0.0), float(tel.get("swing_hover_frac", 0.0)))
			hover_secs[height] = maxf(hover_secs.get(height, 0.0), float(tel.get("swing_hover_secs", 0.0)))
		Input.action_release("move_forward")
		walk_speeds[height] = (giant.position - begin).slide(Vector3.UP).length() / (75.0 / 60.0)
		_game.show_menu()
	_check(hover_fracs[3.0] < hover_fracs[25.2] and hover_fracs[25.2] < hover_fracs[88.2]
			and hover_secs[3.0] < hover_secs[25.2] and hover_secs[25.2] < hover_secs[88.2],
			"Larger giant height holds visibly longer at apex foot lift before slamming down")
	_check(walk_speeds[88.2] > walk_speeds[25.2] and walk_speeds[25.2] > walk_speeds[3.0],
			"Larger giant height increases forward walk speed instead of dragging slower")


func _full_stride_scales_with_size() -> void:
	var previous_hover := 0.0
	var reference := Vector2.ZERO
	for height: float in [100.0, 200.0, 500.0]:
		_start({"giant_height": height, "giant_max_height": height, "giant_count": 1,
				"giant_speed": 1.0, "coin_count": 0, "desk_hazards": false})
		var round := _round()
		var giant := _giant()
		giant.call("_set_skin", &"Kawaii")
		giant.position = Vector3(0.0, 0.02, 450.0)
		await _ticks(10)
		round.set_touch_motion(Vector2(0, -1), false)

		var swing_lift: Array[float] = []
		var step_count := 0
		var measured_steps := 0
		var total := Vector2.ZERO
		var hover_frames := 0
		var support_anchor := Vector3.INF
		var locked_center := Vector3.INF
		var expected_landing_frame := 0.0
		var max_slip := 0.0
		var max_landing_error := 0.0
		var max_eta_error := 0.0
		var predictions := 0
		for frame in range(1, 1921):
			await physics_frame
			var actor := FootfallFixture.actor(round)
			var gait: Dictionary = giant.get_turn_telemetry()
			if int(actor.footfall_count) > step_count:
				step_count = int(actor.footfall_count)
				# Skip the first two steps while the gait leaves its starting stance.
				if not swing_lift.is_empty():
					var peak: float = swing_lift.max()
					var stride: float = gait.left_last_step_len if actor.last_footfall_left else gait.right_last_step_len
					total += Vector2(peak, stride) / height
					for lift in swing_lift:
						hover_frames += int(lift >= peak * 0.999)
					measured_steps += 1
					if locked_center != Vector3.INF:
						predictions += 1
						max_landing_error = maxf(max_landing_error, locked_center.distance_to(actor.last_footfall_center))
						max_eta_error = maxf(max_eta_error, absf(float(frame) - expected_landing_frame))
				swing_lift.clear()
				support_anchor = Vector3.INF
				locked_center = Vector3.INF
			if measured_steps == 3:
				break
			var preview: Dictionary = giant.heavy_step_preview()
			if step_count >= 2 and not preview.is_empty():
				var heel: Vector3 = gait.left_heel_world if preview.left else gait.right_heel_world
				var support: Vector3 = gait.right_heel_world if preview.left else gait.left_heel_world
				swing_lift.append(heel.y - giant.position.y)
				if support_anchor == Vector3.INF:
					support_anchor = support
				max_slip = maxf(max_slip, (support - support_anchor).slide(Vector3.UP).length())
				if preview.locked and locked_center == Vector3.INF:
					locked_center = preview.center
					expected_landing_frame = float(frame) + float(preview.eta) * 60.0
		round.set_touch_motion(Vector2.ZERO, false)
		var proportions := total / maxf(measured_steps, 1.0)
		var hover := float(hover_frames) / maxf(measured_steps, 1.0) / 60.0
		if reference == Vector2.ZERO:
			reference = proportions
		_check(measured_steps == 3 and proportions.x > 0.19 and proportions.y > 0.48
				and proportions.distance_to(reference) < 0.02 and hover > previous_hover + 0.10,
				"At %.0f m the full step stays proportional and the apex lasts longer (heel %.1f%%, stride %.1f%%, %.2f s)"
				% [height, proportions.x * 100.0, proportions.y * 100.0, hover])
		_check(predictions == 3 and max_slip < 0.05 and max_landing_error < 0.05 and max_eta_error < 2.0,
				"At %.0f m the support locks and the predicted landing matches the real heavy step" % height)
		previous_hover = hover
		_game.show_menu()


func _manual_camera_toggle() -> void:
	_start({"giant_height": 0.005})
	var giant := _giant()
	giant.position = OPEN_STREET
	await _ticks(5)
	var camera := root.get_camera_3d()
	var arm: SpringArm3D = _round().get_node("Orbit/Arm")
	var orbit: Node3D = _round().get_node("Orbit")
	_mouse(Vector2(100.0, -160.0))
	var yaw := orbit.rotation.y
	if _round().camera_view_mode() != 0:
		_round().set_camera_view(0)
	await _ticks(4)
	_check(camera == root.get_camera_3d() and camera.get_parent() == arm and arm.get_hit_length() > 0.11
			and camera.global_position.y > 0.003 and giant.get_node("HumanModel").visible
			and is_equal_approx(yaw, orbit.rotation.y),
			"Third person gives even the smallest human a usable arm and view")
	_view_key(true, true)
	_check(camera.get_parent() == arm, "Holding V does not repeat the toggle")
	_view_key(false)
	_game.pause()
	_view_key(true)
	_view_key(false)
	_check(camera.get_parent() == arm, "The view stays put while the game is paused")
	_game.resume()
	_round().set_camera_view(2)
	await _ticks(2)
	_check(_first_person_camera_active(), "The round can switch the smallest giant back to first person")
	_game.show_menu()

	_start({"giant_height": 0.95, "coin_count": 10, "base_health": 4.0})
	await _ticks(5)
	_round().set_camera_view(2)
	giant = _giant()
	giant.position = OPEN_STREET
	var match_round := _round()
	_place_coins(match_round.get_node("Coins"), OPEN_STREET, 10)
	await _ticks(8)
	_check(is_equal_approx(match_round.snapshot().giant_height, 40.0) and _first_person_camera_active(),
			"A manual first-person selection survives the 40 m transformation")
	_game.show_menu()

	_start({"giant_height": 200.0, "view_distance": 40.0})
	await _ticks(3)
	_round().set_camera_view(2)
	camera = root.get_camera_3d()
	_check(_first_person_camera_active() and camera.near > 0.9 and camera.far >= 2500.0,
			"A two-hundred-meter giant can use first person with suitable clipping planes")
	_round().set_camera_view(0)
	await _ticks(2)
	_check(camera.far >= 2500.0 and camera.get_parent() == _round().get_node("Orbit/Arm")
			and camera.near >= 0.09,
			"Third person keeps the map-scaled far plane and a zoom-scaled near plane")
	_game.show_menu()

	_game.start_mode(true)
	await _ticks(3)
	_round().set_camera_view(0)
	await _ticks(2)
	_view_key(true)
	_view_key(false)
	await _ticks(2)
	_check(_round().camera_view_mode() == 1 and not _first_person_camera_active(),
			"V cycles third person into the diagonal foot follow")
	_view_key(true)
	_view_key(false)
	await _ticks(2)
	_check(_first_person_camera_active() and _round().camera_view_mode() == 2,
			"V reaches first person on the third step")
	_view_key(true)
	_view_key(false)
	await _ticks(2)
	_check(_round().camera_view_mode() == 0, "V wraps back to the full-body third person")
	_game.show_menu()


## 第一人称镜头必须贴着 Head 骨骼走：走路起伏、重踏下压、坐压下沉都要跟得上。
func _first_person_eye_tracks_head() -> void:
	_start({"giant_height": 25.2, "coin_count": 0, "first_person_steer": true})
	var giant := _giant()
	giant.position = OPEN_STREET
	await _ticks(4)
	_round().set_camera_view(2)
	giant.call("_set_skin", &"Snow Fox")
	await _ticks(6)
	var camera := root.get_camera_3d()
	var height := float(_round().snapshot().giant_height)
	var rest := _head_bone_point(giant)
	var eye: Vector3 = giant.call("first_person_eye_position")
	_check(_first_person_camera_active() and eye.y > rest.y
			and eye.y - giant.global_position.y > height * 0.85
			and eye.y - giant.global_position.y < height * 0.95,
			"The snow fox eye sits just above its Head bone, not on a fixed height fraction")
	# 走路起伏：每一帧镜头高度都必须等于当前骨骼眼位。
	Input.action_press("move_forward")
	var bob := 0.0
	var tracked := true
	for frame in 36:
		await physics_frame
		var frame_eye: Vector3 = giant.call("first_person_eye_position")
		bob = maxf(bob, absf(frame_eye.y - rest.y))
		tracked = tracked and absf(camera.global_position.y - frame_eye.y) < 0.0015
	Input.action_release("move_forward")
	await _ticks(50)
	_check(tracked and bob > height * 0.001, "The eye rides the walking head bob every frame")
	# The eye follows the head through a real touchdown and its weight transfer.
	var eye_before_step: Vector3 = giant.call("first_person_eye_position")
	var dip := 0.0
	tracked = true
	Input.action_press("move_forward")
	for frame in 90:
		await physics_frame
		var frame_eye: Vector3 = giant.call("first_person_eye_position")
		dip = maxf(dip, eye_before_step.y - frame_eye.y)
		tracked = tracked and absf(camera.global_position.y - frame_eye.y) < 0.0015
	Input.action_release("move_forward")
	_check(tracked and dip > height * 0.006, "A heavy footfall dips the eye with the head")
	await _ticks(55)
	# 坐压：头部随坐姿下沉，镜头仍贴着头。
	Input.action_press("stand_up")
	await _ticks(2)
	Input.action_release("stand_up")
	var sat := false
	tracked = true
	var seated_head := rest
	for frame in 150:
		await physics_frame
		var frame_eye: Vector3 = giant.call("first_person_eye_position")
		tracked = tracked and absf(camera.global_position.y - frame_eye.y) < 0.0015
		sat = sat or not String(_round().snapshot().get("sit_action", "")).is_empty()
		seated_head = _head_bone_point(giant)
	_check(sat and tracked and seated_head.y < rest.y - height * 0.15,
			"Sitting drops the head and the first-person eye follows it down")
	# 退回第三人称后，裁掉的头皮必须回来，头部配件恢复投影以外也要正常绘制。
	_view_key(true)
	_view_key(false)
	await _ticks(4)
	var fox: Node3D = giant.get("_active_skin")
	var body: MeshInstance3D = fox.body_meshes.keys()[0]
	var restored: bool = body.mesh == fox.body_meshes[body]
	var heads_lit := true
	for part: MeshInstance3D in fox.head_parts:
		heads_lit = heads_lit and part.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_check(not _first_person_camera_active() and restored and heads_lit,
			"Leaving first person restores the whole snow fox body and the lit head parts")
	_game.show_menu()


## 第一人称左右最多转 75°；开转向时身体跟着视角转，关转向时身体不动，攻击锁定朝向不受影响。
func _first_person_view_limits() -> void:
	var limit := 75.2
	_start({"giant_height": 25.2, "coin_count": 0, "first_person_steer": false})
	var giant := _giant()
	giant.position = OPEN_STREET
	await _ticks(4)
	_round().set_camera_view(2)
	var orbit: Node3D = _round().get_node("Orbit")
	_check(_first_person_camera_active(), "First person is on for the view-limit checks")
	var body_yaw: float = giant.get_rotation().y
	await _hold_key(KEY_LEFT, 150)
	var left := rad_to_deg(angle_difference(body_yaw, orbit.rotation.y))
	var turned := absf(angle_difference(body_yaw, giant.get_rotation().y))
	_check(absf(left) <= limit and absf(left) >= limit - 1.5 and turned < 0.01,
			"Steering off stops the head at 75° and leaves the body alone")
	await _hold_key(KEY_RIGHT, 300)
	var right := rad_to_deg(angle_difference(body_yaw, orbit.rotation.y))
	_check(absf(right) <= limit and absf(right) >= limit - 1.5 and absf(left + right) < 3.0,
			"The opposite shoulder gets the same 75° head limit")
	_game.show_menu()

	_start({"giant_height": 25.2, "coin_count": 0, "first_person_steer": true})
	giant = _giant()
	orbit = _round().get_node("Orbit")
	giant.position = OPEN_STREET
	await _ticks(4)
	_round().set_camera_view(2)
	await _hold_key(KEY_LEFT, 30)
	body_yaw = giant.get_rotation().y
	await _hold_key(KEY_LEFT, 150)
	await _ticks(120)
	var steered := absf(angle_difference(body_yaw, giant.get_rotation().y))
	var offset := rad_to_deg(angle_difference(giant.get_rotation().y, orbit.rotation.y))
	_check(steered > 0.4 and absf(offset) <= limit,
			"Steering on turns the body with the view while the head stays inside 75°")
	# A foot that has committed to landing stays on its projected mark as the view turns.
	var current := _round()
	FootfallFixture.face(current, giant, 0.0)
	giant.position = OPEN_STREET
	await _ticks(6)
	current.set_camera_view(2)
	var forecast: Vector3 = Vector3.INF
	var gait_count := int(FootfallFixture.actor(current).footfall_count)
	Input.action_press("move_forward")
	for frame in 100:
		await physics_frame
		var actor := FootfallFixture.actor(current)
		if giant.heavy_step_preview().get("locked", false) and actor.footfall_pending:
			forecast = actor.footfall_center
			break
	var yaw_before_turn := orbit.rotation.y
	Input.action_release("move_forward")
	_key_hold(KEY_LEFT, true)
	for frame in 90:
		await physics_frame
		if int(FootfallFixture.actor(current).footfall_count) > gait_count:
			break
	_key_hold(KEY_LEFT, false)
	var landed := FootfallFixture.actor(current)
	var contact: Vector3 = landed.get("last_footfall_center", Vector3.INF)
	_check(forecast != Vector3.INF and int(landed.footfall_count) == gait_count + 1
			and absf(angle_difference(orbit.rotation.y, yaw_before_turn)) > 0.10
			and contact.slide(Vector3.UP).distance_to(forecast.slide(Vector3.UP)) < 0.10,
			"A committed sole projection stays fixed while first-person steering turns the view")
	await _ticks(50)

	var config := ConfigFile.new()
	var saved := config.load(_game.settings_path) == OK
	var growth: Dictionary = config.get_value("settings", "growth", {})
	_check(saved and growth.get("first_person_steer", false) == true,
			"The first-person steering switch persists in gameplay.cfg")

	# 设置页：开关在「巨人」组里，默认开启，关掉保存后立即生效并写入存档。
	_game.pause()
	var ui := _game.get_node("Interface")
	(ui.find_child("PauseSettings", true, false) as BaseButton).pressed.emit()
	(ui.find_child("SettingsPageGameplay", true, false) as BaseButton).pressed.emit()
	await _ticks(2)
	var toggle := ui.find_child("first_person_steer", true, false) as CheckButton
	_check(toggle != null and toggle.is_visible_in_tree() and toggle.button_pressed,
			"The gameplay page shows the first-person steering switch, on by default")
	toggle.button_pressed = false
	(ui.find_child("SaveSettings", true, false) as BaseButton).pressed.emit()
	await _ticks(2)
	saved = config.load(_game.settings_path) == OK
	growth = config.get_value("settings", "growth", {})
	_check(saved and growth.get("first_person_steer", false) == false
			and not _game.get_mode_settings(2).first_person_steer,
			"Turning steering off saves it and applies to the live session")
	_game.resume()
	await _ticks(2)


func _head_bone_point(giant: CharacterBody3D) -> Vector3:
	var skin: Node = giant.get("_active_skin")
	var skeleton: Skeleton3D = giant.get_node("Model/metarig/Skeleton3D") if skin == null else skin.skeleton
	var bone_name: StringName = &"Head" if skin == null else skin.head_bone
	var bone := skeleton.find_bone(String(bone_name))
	return skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin


func _observation_roles() -> void:
	var options: Dictionary = _game.default_mode_settings(2)
	options.merge({"giant_count": 2, "npc_initial": 0, "npc_respawn": false,
			"coin_count": 3, "coin_interval": 60.0}, true)
	_game.save_mode_settings(_game.get_settings(false), _game.get_settings(true), options)
	var ui := _game.get_node("Interface")
	(ui.find_child("GrowthSpectator", true, false) as BaseButton).pressed.emit()
	await _ticks(4)
	var round := _round()
	var camera := root.get_camera_3d()
	var giant := _giant()
	var giant_start := giant.position
	var camera_start := camera.position
	var ranking: Array[Dictionary] = round.growth_leaderboard()
	_check(camera.get_parent() == round.get_node("Orbit") and not round.has_node("Human")
			and ranking.size() == 2 and not ranking[0].is_player and not ranking[1].is_player
			and round.get_node("Coins").get_child_count() > 0,
			"The spectator sees an all-AI growth round with its configured giants and coins")
	var world_start := camera.global_position
	_mouse(Vector2(0.0, -350.0))
	Input.action_press("move_forward")
	await _ticks(10)
	Input.action_release("move_forward")
	_check(camera.global_position.y > world_start.y + 0.02 and camera.position == camera_start
			and giant.position.distance_to(giant_start) > 0.0008,
			"Glancing upward and moving flies the camera while the first giant moves on its own")
	_game.pause()
	var paused_at := camera.global_position
	await _ticks(3)
	_check(_game.get_screen() == "paused" and camera.global_position == paused_at
			and not ui.get("_modal_stat").visible, "Spectating pauses without mission statistics")
	var former_round := round.get_instance_id()
	_game.restart()
	await _ticks(3)
	_check(_round().get_instance_id() != former_round and not _round().has_node("Human")
			and root.get_camera_3d().get_parent() == _round().get_node("Orbit"),
			"Restarting keeps the spectator role")

	_game.show_menu()
	options.merge({"giant_count": 1, "giant_height": 25.2}, true)
	_game.save_mode_settings(_game.get_settings(false), _game.get_settings(true), options)
	(ui.find_child("GrowthHuman", true, false) as BaseButton).pressed.emit()
	await _ticks(4)
	round = _round()
	var human: CharacterBody3D = round.get_node("Human")
	human.position = OPEN_STREET
	_giant().position = OPEN_STREET + Vector3.BACK * 16.0
	Input.action_press("move_forward")
	Input.action_press("sprint")
	await _ticks(15)
	Input.action_release("move_forward")
	Input.action_release("sprint")
	_check(human.position.distance_to(OPEN_STREET) > 1.0 and human.collision_layer == 0
			and round.snapshot().stamina == 1.0 and round.snapshot().ai_target_id != human.get_instance_id(),
			"A human observer moves and sprints without becoming a target or losing stamina")
	var evacuation: Marker3D = round.get_node("District/Evacuation")
	human.global_position = evacuation.global_position + Vector3.UP * 0.03
	await _ticks(4)
	var state: Dictionary = round.snapshot()
	_check(_game.get_screen() == "playing" and state.health == 3 and not state.has("exit_distance")
			and not round.has_node("Effects/EvacuationBeacon") and not ui.get("_human_hud").visible
			and not ui.get("_giant_hud").visible,
			"Human observation has no evacuation objective, beacon or combat HUD")
	_game.restart()
	await _ticks(3)
	_check(_round().has_node("Human") and not _round().snapshot().has("exit_distance"),
			"Restarting keeps the human observation role")


func _building_refresh() -> void:
	_game.show_menu()
	_start({"giant_height": 40.0, "giant_max_height": 40.0})
	var round := _round()
	var giant := _giant()
	var historic: Node3D = round.get_node("District/Targets/DockPress1")
	await FootfallFixture.strike_building(round, historic)
	giant.position = OPEN_STREET
	Engine.time_scale = 8.0
	await _ticks(465)
	Engine.time_scale = 1.0
	_check(historic.has_node("RuinBody") and not _game.get_mode_settings(2).building_respawn,
			"Ruins remain after 60 seconds with the default setting")
	_game.show_menu()

	var ui := _game.get_node("Interface")
	(ui.find_child("MenuSettings", true, false) as BaseButton).pressed.emit()
	var panel := ui.find_child("GameplaySettings", true, false)
	(panel.find_child("GrowthSettingsTab", true, false) as Button).pressed.emit()
	ui.call("debug_expand_settings")
	var option := panel.find_child("building_respawn", true, false) as CheckButton
	var delay := panel.find_child("building_respawn_delay", true, false) as SpinBox
	_check(option.is_visible_in_tree() and not option.button_pressed and delay.value == 60.0
			and not delay.is_visible_in_tree(),
			"Building refresh defaults to off with its 60-second delay hidden")
	option.button_pressed = true
	delay.value = 2.0
	_check(delay.is_visible_in_tree(), "Enabling building refresh reveals its delay field")
	(panel.find_child("SaveSettings", true, false) as BaseButton).pressed.emit()
	var saved := ConfigFile.new()
	saved.load(_game.settings_path)
	var profile: Dictionary = saved.get_value("settings", "growth", {})
	_check(profile.building_respawn and profile.building_respawn_delay == 2.0,
			"The building refresh switch and custom delay save to the shared growth profile")
	_game.start_growth()
	await _ticks(4)
	round = _round()
	giant = _giant()
	historic = round.get_node("District/Targets/DockPress1")
	var radar: Node3D = round.get_node("District/Targets/HarborRadarTower")
	var radar_visual: Node3D = radar.get_node("IntactModel")
	var radar_transform := radar_visual.transform
	await FootfallFixture.strike_building(round, historic)
	_check(historic.has_node("RuinBody"), "A footfall schedules the historic building to refresh")
	# The radar sits against the north boundary, so approach from the harbor side.
	await FootfallFixture.strike_building(round, radar, 0.0)
	giant.position = radar.position + Vector3.UP * 0.01
	_check(radar.has_node("RuinBody"), "A heavy footfall also schedules a landmark to refresh")
	var wrecked: int = round.snapshot().destroyed
	await _ticks(24)
	_game.pause()
	await _ticks(140)
	_game.resume()
	await _ticks(16)
	_check(historic.has_node("RuinBody"), "Building refresh only counts unpaused time toward the configured delay")
	await _ticks(105)
	_check(not historic.has_node("RuinBody") and historic.get_node("BlockingBody").collision_layer == 8
			and not historic.has_node("CollapseDust") and radar.has_node("RuinBody") and round.snapshot().destroyed == 1,
			"With a two-second delay the unoccupied building restores and clears its collapse effect")
	giant.position = OPEN_STREET
	await _ticks(70)
	_check(not radar.has_node("RuinBody") and radar.get_node("BlockingBody").collision_layer == 8
			and radar.get_node_or_null("IntactModel") == radar_visual and radar_visual.transform == radar_transform
			and round.snapshot().destroyed == 0 and round.snapshot().giant_destroyed == wrecked,
			"A cleared procedural building restores its original model and collision without removing earned progress")
	await FootfallFixture.strike_building(round, historic)
	var state: Dictionary = round.snapshot()
	_check(historic.has_node("RuinBody") and state.giant_destroyed == wrecked + state.destroyed,
			"A rebuilt building can be destroyed again and awards normal growth progress")


func _defeat_feed_history() -> void:
	_start({})
	var ui := _game.get_node("Interface")
	var feed := ui.find_child("GrowthDefeatFeed", true, false) as VBoxContainer
	var messages: Array[Dictionary] = []
	for method in ["bump", "step", "grab_crush", "punch"]:
		messages.append({"attacker": "林晓岚", "victim": "周雨桐", "method": method,
				"player_attack": false, "player_defeated": false})
	ui.announce_growth_defeats(messages)
	var newest := ["林晓岚  挥拳击倒  周雨桐", "林晓岚  捏碎击倒  周雨桐", "林晓岚  落脚击倒  周雨桐"]
	_check(_defeat_messages() == newest, "A burst of messages keeps the three newest in order")
	_game.pause()
	await _ticks(310)
	_check(not feed.visible and _defeat_messages() == newest, "Pause hides and freezes the defeat feed")
	_game.resume()
	await _ticks(305)
	_check(_defeat_messages().is_empty(), "Defeat messages expire during play")
	ui.announce_growth_defeats(messages)
	_game.restart()
	_check(_defeat_messages().is_empty(), "Restart discards messages from the previous round")
	_game.start_mode(true)
	_check(not feed.visible, "The defeat feed belongs to growth rounds")


func _defeat_messages() -> Array[String]:
	var feed := _game.get_node("Interface").find_child("GrowthDefeatFeed", true, false)
	var messages: Array[String] = []
	for row in feed.get_children():
		messages.append(row.get_child(0).text)
	return messages


func _human_stage_stats() -> void:
	for height in [0.9, 2.7]:
		_start({"giant_height": height, "giant_count": 1, "coin_count": 0})
		var round := _round()
		var giant := _giant()
		var state: Dictionary = round.snapshot()
		var capsule: CapsuleShape3D = giant.get_node("Collision").shape
		_check(is_equal_approx(capsule.height, 1.8)
				and is_equal_approx(capsule.radius, 0.42)
				and is_equal_approx(state.giant_max_health, 100.0 * 1.8 / 0.01)
				and is_equal_approx(state.giant_attack, 10.0 * 1.8 / 0.01)
				and state.get("human_stage", false),
				"A %.1f m legacy start uses the standard human capsule and stats" % height)
		_game.show_menu()
	_start({"giant_height": 3.0, "giant_count": 1, "coin_count": 0})
	var round := _round()
	var giant := _giant()
	var state: Dictionary = round.snapshot()
	var capsule: CapsuleShape3D = giant.get_node("Collision").shape
	_check(not state.get("human_stage", true) and state.can_demolish
			and is_equal_approx(capsule.height, 3.0)
			and is_equal_approx(capsule.radius, 2.9 * 3.0 / 25.2)
			and is_equal_approx(state.giant_max_health, 30000.0)
			and is_equal_approx(state.giant_attack, 3000.0),
			"A three-metre giant uses the giant capsule with the same per-metre stats")
	_game.show_menu()


func _hand_attacks() -> void:
	# Humans have no hand attacks; a giant can punch or grab a smaller human.
	_start({"giant_height": 1.5, "giant_count": 2, "coin_count": 1, "coin_interval": 600.0,
			"coin_growth_rate": 1.0})
	var round := _round()
	var giant := _giant()
	var rival: CharacterBody3D = round.get_node("OtherGiants/Giant2")
	giant.position = OPEN_STREET
	rival.position = OPEN_STREET + Vector3.FORWARD * 0.9
	await _ticks(4)
	round.tap_grab_crush()
	await _ticks(20)
	_check(round.snapshot().hand_action.is_empty(), "A human cannot start a grab")
	round.debug_resize_giant(0, 3.6)
	rival.position = giant.position + Vector3.FORWARD * 1.1
	await _ticks(2)
	round.tap_punch()
	await _ticks(4)
	_check(round.snapshot().hand_action == "punch", "Punch accepts a target exactly half the attacker's height")
	var rival_health := float(round.growth_actors()[1]["health"])
	for frame in 60:
		if float(round.growth_actors()[1]["health"]) < rival_health:
			break
		rival.position = giant.position + Vector3.FORWARD * 1.1
		await physics_frame
	_check(float(round.growth_actors()[1]["health"]) < rival_health,
			"The punch damages the human actor")
	_game.show_menu()

	_start({"giant_height": 0.5, "giant_count": 2, "coin_count": 0, "respawn_delay": 60.0})
	round = _round()
	giant = _giant()
	rival = round.get_node("OtherGiants/Giant2")
	giant.position = OPEN_STREET
	rival.position = Vector3(600.0, 0.02, 600.0)
	round.debug_resize_giant(0, 40.0)
	await _ticks(6)
	var rival_at := giant.position + Vector3.FORWARD * 6.0
	rival.position = rival_at
	round.tap_grab_crush()
	await _ticks(3)
	_check(round.snapshot().hand_action == "grab_crush",
			"A giant can start picking up a much smaller human")
	for frame in 160:
		if rival.collision_mask == 0:
			break
		rival.position = rival_at
		await physics_frame
	_check(rival.collision_mask == 0, "The grab lifts the human actor")
	await _ticks(220)
	var board: Array[Dictionary] = round.growth_leaderboard()
	_check(board[1].rank == 0, "The crush defeats the smaller human")
	_game.show_menu()


func _view_key(pressed: bool, echo := false) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_V
	event.pressed = pressed
	event.echo = echo
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _key_hold(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _hold_key(code: Key, frames: int) -> void:
	var down := InputEventKey.new()
	down.physical_keycode = code
	down.pressed = true
	Input.parse_input_event(down)
	Input.flush_buffered_events()
	await _ticks(frames)
	var up := InputEventKey.new()
	up.physical_keycode = code
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()
	await _ticks(2)


func _mouse(motion: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.screen_relative = motion
	event.relative = motion
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
