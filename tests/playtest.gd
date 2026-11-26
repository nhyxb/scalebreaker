extends SceneTree
## Runs the installed game scene through its normal input and session entry points.

const MAP := "MapSlot/Round"
const PLAYERS := ["Human", "Giant"]
const FOOT_RADII := Vector2(0.71, 1.49)
const FOOT_OFFSET := Vector3(-1.39, 0.0, -7.05)
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
	_bedroom_skybox()
	await _human_controls()
	await _human_evacuates()
	await _human_vs_ai()
	await _speed_and_ignore_settings()
	await _ai_leads_a_sprinting_human()
	await _visibility_and_civilians()
	await _ai_demolition()
	await _walking_attack()
	await _finish_walking_step()
	await _giant_smooth_turn()
	await _giant_layered_turn()
	await _stomp_charge_pivot()
	await _giant_sandbox()
	await _queued_growth_and_touch_crush()
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
	_check(_game.get_screen() == "menu", "both modes returned to the title")
	if FileAccess.file_exists(settings_path):
		DirAccess.remove_absolute(settings_path)
	print("Gameplay: %d passed, %d failed" % [_checks - _failures, _failures])
	quit(1 if _failures else 0)


func _bedroom_skybox() -> void:
	var sky: Node = _game.get_node_or_null("Skybox")
	var sub: SubViewport = sky.get_node_or_null("BedroomViewport") if sky != null else null
	var rect: TextureRect = sky.get_node_or_null("BedroomBackdrop/BedroomPicture") if sky != null else null
	var bedroom: Node3D = sub.get_node_or_null("Bedroom") if sub != null else null
	_check(sky != null and sub != null and rect != null and bedroom != null,
			"bedroom skybox viewport, backdrop and shell initialize with the main scene")
	if bedroom == null:
		return
	var win := root.size
	var expected_min := int(round(win.x * 0.75))
	_check(rect.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR
			and sub.size.x >= mini(win.x, expected_min) and sub.msaa_3d == Viewport.MSAA_2X,
			"desktop skybox renders with linear filtering, high resolution ratio and 2x MSAA")
	var furniture := bedroom.get_node_or_null("Furniture")
	var required := [
		"Desk", "ChairDesk", "ComputerScreen", "ComputerKeyboard", "ComputerMouse",
		"LampRoundTable", "BooksDesk", "BearDesk", "PlantSmallDesk", "SpeakerLeft",
		"BedDouble", "Pillow", "PillowLong", "CabinetBedDrawer", "BookcaseOpen",
		"BookcaseClosedDoors", "RugRounded", "PottedPlant", "LampSquareCeiling",
		"Trashcan", "CoatRackStanding",
	]
	var all_present := furniture != null
	if all_present:
		for item: String in required:
			if furniture.get_node_or_null(item) == null:
				all_present = false
				break
	_check(all_present and _count_collisions_in(bedroom) == 0,
			"all Kenney furniture landmarks load into the bedroom with zero physics collisions")
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


func _count_collisions_in(node: Node) -> int:
	var total := 1 if node is CollisionObject3D else 0
	for child in node.get_children():
		total += _count_collisions_in(child)
	return total


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

	# Wait for a stomp that would hit the human, then sprint away from its warning.
	var away := Vector2.ZERO
	var passed_mid_street := false
	for frame in 1050:
		passed_mid_street = passed_mid_street or giant.position.z < 14.0
		var warning := current.get_node_or_null("Effects/StompWarning") as Node3D
		if warning != null and current.snapshot().stomp == "windup":
			var offset := human.global_position - warning.global_position
			var local := warning.to_local(human.global_position)
			if Vector2(local.x, local.z).length_squared() <= 1.0:
				away = Vector2(offset.x, offset.z)
				break
		_park_civilians(current)
		await physics_frame
	_check(passed_mid_street, "AI keeps chasing a nearby human down the central street")
	_check(away != Vector2.ZERO, "AI telegraphs a stomp that would hit the human")
	var dodge := "move_back" if away.x < 0.0 else "move_forward"
	if absf(away.y) > absf(away.x):
		dodge = "move_left" if away.y < 0.0 else "move_right"
	Input.action_press(dodge)
	Input.action_press("sprint")
	await _ticks(40)
	Input.action_release(dodge)
	Input.action_release("sprint")
	_check(current.snapshot().health == 3, "sprinting away from the warning center dodges the stomp")
	for frame in 1300:
		if current.snapshot().health < 3:
			break
		_park_civilians(current)
		await physics_frame
	_check(current.snapshot().health == 2, "one AI impact removes one life")
	for frame in 900:
		if _game.get_screen() == "lost":
			break
		_park_civilians(current)
		await physics_frame
	_check(_game.get_screen() == "lost" and current.snapshot().health == 0, "three impacts trigger defeat")
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
	_actor(1).position = Vector3(0.0, 0.02, 43.6)
	human.position = Vector3(-9.0, 0.02, 36.4)
	Input.action_press("move_forward")
	Input.action_press("sprint")
	var lead := 0.0
	var landing := Vector3.ZERO
	var stable_warning := true
	for frame in 85:
		if current.snapshot().stomp == "impact":
			break
		var warning := current.get_node_or_null("Effects/StompWarning") as Node3D
		if warning:
			if landing == Vector3.ZERO:
				landing = warning.global_position
				lead = landing.x - human.position.x
			else:
				stable_warning = stable_warning and warning.global_position.is_equal_approx(landing)
		_park_civilians(current)
		await physics_frame
	Input.action_release("move_forward")
	Input.action_release("sprint")
	_check(lead > 2.0 and stable_warning, "AI leads a sprinting human and locks the telegraph before landing")
	_check(current.snapshot().health == 2, "stomp intercepts the human who keeps sprinting along the predicted line")
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
	civilian.global_position = giant.global_position + FOOT_OFFSET
	_key(KEY_SPACE)
	# The civilian wanders, so keep it on the telegraphed shoe print until impact.
	for frame in 45:
		if current.snapshot().stomp == "impact":
			break
		civilian.global_position = giant.global_position + FOOT_OFFSET
		await physics_frame
	await _ticks(300)
	_check(initial_count == 6 and not is_instance_id_valid(civilian_id)
			and crowd.get_child_count() == initial_count - 1,
			"sandbox starts with six NPCs and leaves the crowd smaller until the slower spawn timer expires")
	await _ticks(300)
	_check(crowd.get_child_count() == initial_count, "the NPC replacement spawns within six to ten seconds")
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
	_check(count > 0 and nearest.get_node("BlockingBody").collision_layer == 0,
			"After losing its target the AI destroys the closest standing building")
	await _wait_growth(current, count)
	_check(count > 0 and _giant_has_scale(giant, pow(GROWTH_PER_BUILDING, count)),
			"AI grows once per demolished building")
	_game.show_menu()


func _walking_attack() -> void:
	_game.start_mode(true)
	var current := _round()
	var giant := _actor(1)
	var target: Node3D = current.get_node("District/Targets/DockPress3")
	var start := Vector3(-12.0, 0.03, 38.0)
	giant.position = start
	await _ticks(4)
	Input.action_press("move_forward")
	for frame in 74:
		if _has_strike_overlay(target):
			break
		await physics_frame
	Input.action_release("move_forward")
	_check(_has_strike_overlay(target) and current.snapshot().destroyed == 0,
			"walking heel strike cracks a building without a deliberate stomp")
	await _ticks(90)
	_check(target.has_node("IntactModel") and _giant_has_scale(giant, 1.0),
			"leaving the shoe planted does not deal another hit")

	giant.position = start
	await _ticks(4)
	Input.action_press("move_forward")
	for frame in 74:
		if current.snapshot().destroyed > 0:
			break
		await physics_frame
	Input.action_release("move_forward")
	_check(current.snapshot().destroyed == 1 and target.has_node("CollapseModel")
			and _giant_has_scale(giant, 1.0), "a second walking heel strike destroys the building and starts growth")
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
	giant.position = Vector3(0.0, 0.02, 43.0)
	await _ticks(4)
	var left_idle := giant.to_local(_ankle(giant, "L"))
	var right_idle := giant.to_local(_ankle(giant, "R"))
	Input.action_press("move_forward")
	await _ticks(25)
	var lifted := _ankle(giant, "R")
	var support := _ankle(giant, "L")
	var was_airborne: bool = giant.has_step_in_flight()
	Input.action_release("move_forward")
	for frame in 72:
		if not giant.has_step_in_flight():
			break
		await physics_frame
	var landed := _ankle(giant, "R")
	var support_at_landing := _ankle(giant, "L")
	_check(was_airborne and landed.z < lifted.z - 1.0 and landed.y < lifted.y - 0.6
			and absf(support_at_landing.z - support.z) < 0.4,
			"releasing movement completes the swinging step while leaving the support foot planted")
	await _ticks(3)
	var planted_before_settling := absf(_ankle(giant, "R").z - landed.z) < 0.4
	await _ticks(42)
	var left_final := giant.to_local(_ankle(giant, "L"))
	var right_final := giant.to_local(_ankle(giant, "R"))
	_check(planted_before_settling and left_final.distance_to(left_idle) < 0.25
			and right_final.distance_to(right_idle) < 0.25 and current.snapshot().stomp == "ready",
			"the feet plant before smoothly recovering the default idle stance")
	_game.show_menu()


func _giant_smooth_turn() -> void:
	_game.start_mode(true)
	var current := _round()
	var giant := _actor(1)
	var model: Node3D = giant.get_node("Model")
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
	for frame in 40:
		await physics_frame
		var step := absf(angle_difference(prev_yaw, giant.rotation.y))
		if frame == 0:
			first_step = step
		max_step = maxf(max_step, step)
		prev_yaw = giant.rotation.y
	Input.action_release("move_right")
	_check(first_step < 0.025 and max_step < 0.065 and absf(angle_difference(start_yaw, giant.rotation.y)) > 1.1,
			"giant walking turns accelerate smoothly without snapping on frame one")

	# Stomping during a walking swing waits for the step to land and strictly stomps the current
	# body facing even when the camera is rotated 180 degrees behind and Back is held.
	var orbit: Node3D = current.get_node("Orbit")
	var facing_before_stomp := giant.rotation.y
	var behind := facing_before_stomp + PI
	_mouse(Vector2(-angle_difference(orbit.rotation.y, behind) / 0.0028, 0.0))
	await _ticks(2)
	var stepped_before_stomp: bool = giant.has_step_in_flight()
	Input.action_press("move_back")
	_key(KEY_SPACE)
	await _ticks(1)
	Input.action_release("move_back")
	_check(stepped_before_stomp and current.snapshot().stomp == "ready",
			"pressing stomp during a swing waits for the walking step to land")
	var warning_in_front := false
	var offset_at_impact := 99.0
	var yaw_change := 99.0
	for frame in 85:
		await physics_frame
		if current.snapshot().stomp == "windup":
			var warn := current.get_node_or_null("Effects/StompWarning") as Node3D
			if warn != null:
				var fwd := Vector3(-sin(facing_before_stomp), 0.0, -cos(facing_before_stomp))
				var to_warn := (warn.global_position - giant.global_position).slide(Vector3.UP)
				warning_in_front = to_warn.dot(fwd) > 4.0
				yaw_change = absf(angle_difference(facing_before_stomp, giant.rotation.y))
		if current.snapshot().stomp == "impact":
			offset_at_impact = absf(angle_difference(PI, model.rotation.y))
			break
	_check(warning_in_front and yaw_change < 0.08 and offset_at_impact < 0.02,
			"stomp ignores rear camera and reverse input, landing strictly in front of current body facing")
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

	# 1. Free camera orbit never rotates the giant or redirects attacks; holding Back + Stomp
	#    while facing North still stomps strictly North instead of spinning behind.
	_mouse(Vector2(-angle_difference(orbit.rotation.y, PI * 0.5) / 0.0028, 0.0))
	await _ticks(24)
	var yaw_after_side_look := absf(angle_difference(0.0, giant.rotation.y))
	_mouse(Vector2(-angle_difference(orbit.rotation.y, PI) / 0.0028, 0.0))
	await _ticks(24)
	var yaw_after_rear_look := absf(angle_difference(0.0, giant.rotation.y))
	var tel_look: Dictionary = giant.get_turn_telemetry()
	_check(yaw_after_side_look < 0.01 and yaw_after_rear_look < 0.01 and not bool(tel_look["standing_turning"]),
			"orbiting the camera around a standing giant leaves body facing untouched")

	# Reset camera north, hold Back + press Space simultaneously: must stomp North (current facing).
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(3)
	Input.action_press("move_back")
	_key(KEY_SPACE)
	await _ticks(4)
	Input.action_release("move_back")
	await _wait_windup(current, 0.20)
	var front_warn := current.get_node_or_null("Effects/StompWarning") as Node3D
	_check(front_warn != null and front_warn.global_position.z < giant.global_position.z - 4.0
			and absf(angle_difference(0.0, giant.rotation.y)) < 0.02,
			"holding Back while pressing stomp attacks forward along current facing rather than spinning behind")
	await _wait_ready(current)

	# 2. Hand attacks (grab_crush / punch) only hit targets in front of current body facing;
	#    to attack a building directly behind, the giant must turn around first.
	var dock3: Node3D = current.get_node("District/Targets/DockPress3")
	giant.position = dock3.position + Vector3(0.0, 0.03, -(float(dock3.footprint.z) * 0.5 + 5.0))
	giant.rotation = Vector3.ZERO
	_mouse(Vector2(-angle_difference(orbit.rotation.y, PI) / 0.0028, 0.0))
	await _ticks(6)
	current.tap_grab_crush()
	await _ticks(4)
	var rear_grab_empty: bool = current.snapshot().hand_action.is_empty()
	current.tap_punch()
	await _ticks(4)
	var rear_punch_empty: bool = current.snapshot().hand_action.is_empty()
	var facing_still_north := absf(angle_difference(0.0, giant.rotation.y)) < 0.02
	_check(rear_grab_empty and rear_punch_empty and facing_still_north,
			"hand attacks reject targets behind the giant even when the camera looks straight at them")

	# Now turn the body to face DockPress3 (south) and grab: facing the target is what unlocks
	# the hand attack, while the rear rejection above stays covered by the pivot tests.
	while current.snapshot().stomp != "ready":
		await physics_frame
	# Stand on the open street south of DockPress3 (the north side is filled by MarineWorks3's
	# lot) and face north into it, then grab.
	giant.rotation = Vector3.ZERO
	giant.position = dock3.position + Vector3(0.0, 0.03, float(dock3.footprint.z) * 0.5 + 5.0)
	await _ticks(12)
	current.tap_grab_crush()
	await _ticks(4)
	_check(current.snapshot().hand_action == "grab_crush",
			"turning to face the rear target first unlocks hand attacks on it")
	_game.restart()
	current = _round()
	giant = _actor(1)
	orbit = current.get_node("Orbit")
	giant.position = Vector3(0.0, 0.03, 36.0)
	giant.rotation = Vector3.ZERO
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(8)

	# 3. Standing 90-degree directional press (move_left) pivots in place with top-down cascade
	#    (Eye -> Head -> Chest -> Pelvis -> Feet) and zero-slip alternating small steps BEFORE walking.
	var start_yaw := giant.rotation.y
	var pivot_origin := giant.position
	var before_destroyed: int = current.snapshot().destroyed
	Input.action_press("move_left")

	var t_eye := -1.0
	var t_head := -1.0
	var t_chest := -1.0
	var t_pelvis := -1.0
	var t_foot := -1.0
	var best_ratio := 0.0
	var max_s_curve := 0.0
	var min_sh_counter := 0.0
	var max_in_weight := 0.0
	var max_slip := 0.0
	var max_steps := 0
	var heel_strikes := 0
	var max_pivot_disp := 0.0
	var transitioned_to_walk := false
	var prev_l_planted := true
	var prev_r_planted := true
	var prev_l_mode := -1
	var prev_r_mode := -1
	var prev_l_piv := Vector3.ZERO
	var prev_r_piv := Vector3.ZERO
	var saw_step_sides: Array[String] = []
	var prev_step_side := ""

	for frame in 150:
		await physics_frame
		var t_sec := float(frame + 1) / 60.0
		var tel: Dictionary = giant.get_turn_telemetry()
		var mode_s: String = tel["mode"]
		var in_pivot := bool(tel["standing_turning"]) or bool(tel["standing_step_active"])
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
		if t_foot < 0.0 and (not l_pl or not r_pl):
			t_foot = t_sec

		var head_rel := float(tel["head_rel_pelvis"])
		if in_pivot and absf(head_rel) > 0.25:
			var r := float(tel["chest_to_head_ratio"])
			if best_ratio == 0.0 or absf(r - 0.5) < absf(best_ratio - 0.5):
				best_ratio = r
		if in_pivot:
			max_s_curve = maxf(max_s_curve, float(tel["spine_s_curve"]))
			min_sh_counter = minf(min_sh_counter, float(tel["shoulder_counter_z"]))
			max_in_weight = maxf(max_in_weight, float(tel["pelvis_shift_x"]))
			max_steps = maxi(max_steps, int(tel["standing_step_count"]))
			max_pivot_disp = maxf(max_pivot_disp, Vector2(giant.position.x - pivot_origin.x, giant.position.z - pivot_origin.z).length())

			var step_side: String = tel["standing_step_side"]
			if bool(tel["standing_step_active"]) and step_side != prev_step_side:
				saw_step_sides.append(step_side)
				prev_step_side = step_side
			elif not bool(tel["standing_step_active"]):
				prev_step_side = ""

			if l_pl and prev_l_planted and l_mode == prev_l_mode and frame > 0:
				max_slip = maxf(max_slip, Vector2(l_piv.x - prev_l_piv.x, l_piv.z - prev_l_piv.z).length())
			if r_pl and prev_r_planted and r_mode == prev_r_mode and frame > 0:
				max_slip = maxf(max_slip, Vector2(r_piv.x - prev_r_piv.x, r_piv.z - prev_r_piv.z).length())
		elif mode_s.begins_with("walk_") and giant.position.x < pivot_origin.x - 1.5:
			transitioned_to_walk = true

		if l_pl and not prev_l_planted and float(tel["left_last_landing_pitch"]) <= -0.18:
			heel_strikes += 1
		if r_pl and not prev_r_planted and float(tel["right_last_landing_pitch"]) <= -0.18:
			heel_strikes += 1

		prev_l_planted = l_pl
		prev_r_planted = r_pl
		prev_l_mode = l_mode
		prev_r_mode = r_mode
		prev_l_piv = l_piv
		prev_r_piv = r_piv
	Input.action_release("move_left")

	var alternating := saw_step_sides.size() >= 2
	for idx in range(1, saw_step_sides.size()):
		if saw_step_sides[idx] == saw_step_sides[idx - 1]:
			alternating = false
	_check(t_eye > 0.0 and t_eye <= t_head and t_head < t_chest and t_chest < t_pelvis and t_pelvis < t_foot,
			"standing turn cascades strictly top-down from eyes and head through chest and pelvis to feet")
	_check(best_ratio >= 0.35 and best_ratio <= 0.68 and max_s_curve > 0.08 and min_sh_counter < -0.02,
			"standing turn rotates chest to roughly half of head with spine S-curve and shoulder counter-twist")
	_check(max_in_weight > 0.03 and alternating and max_steps >= 2 and heel_strikes >= 2 and max_slip < 0.02
			and max_pivot_disp < 0.15 and transitioned_to_walk and current.snapshot().destroyed == before_destroyed,
			"standing 90-degree directional input pivots in place with zero-slip alternating small steps before walking")

	# 4. Standing 180-degree Back input takes 4+ alternating ship-like small steps before walking,
	#    and releasing input mid-step lands cleanly with zero slip.
	giant.position = Vector3(0.0, 0.03, 36.0)
	giant.rotation = Vector3.ZERO
	_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(12)
	Input.action_press("move_back")
	var steps_180 := 0
	var slip_180 := 0.0
	var walked_south := false
	prev_l_planted = true
	prev_r_planted = true
	prev_l_mode = -1
	prev_r_mode = -1
	for frame in 210:
		await physics_frame
		var tel: Dictionary = giant.get_turn_telemetry()
		var in_pivot := bool(tel["standing_turning"]) or bool(tel["standing_step_active"])
		var l_pl: bool = tel["left_planted"]
		var r_pl: bool = tel["right_planted"]
		var l_mode: int = tel["left_pivot_mode"]
		var r_mode: int = tel["right_pivot_mode"]
		var l_piv: Vector3 = tel["left_heel_world"] if l_mode == 0 else tel["left_ball_world"]
		var r_piv: Vector3 = tel["right_heel_world"] if r_mode == 0 else tel["right_ball_world"]
		if in_pivot:
			steps_180 = maxi(steps_180, int(tel["standing_step_count"]))
			if l_pl and prev_l_planted and l_mode == prev_l_mode and frame > 0:
				slip_180 = maxf(slip_180, Vector2(l_piv.x - prev_l_piv.x, l_piv.z - prev_l_piv.z).length())
			if r_pl and prev_r_planted and r_mode == prev_r_mode and frame > 0:
				slip_180 = maxf(slip_180, Vector2(r_piv.x - prev_r_piv.x, r_piv.z - prev_r_piv.z).length())
		elif giant.position.z > 37.5:
			walked_south = true
		prev_l_planted = l_pl
		prev_r_planted = r_pl
		prev_l_mode = l_mode
		prev_r_mode = r_mode
		prev_l_piv = l_piv
		prev_r_piv = r_piv
	Input.action_release("move_back")
	_check(steps_180 >= 4 and slip_180 < 0.02 and walked_south,
			"standing 180-degree Back input pivots across multiple zero-slip small steps before walking south")

	# Early release mid-pivot finishes placing the airborne small step cleanly with zero slip.
	giant.position = Vector3(0.0, 0.03, 36.0)
	giant.rotation = Vector3.ZERO
	await _ticks(12)
	Input.action_press("move_left")
	await _ticks(28)
	Input.action_release("move_left")
	var release_slip := 0.0
	var settled_cleanly := false
	prev_l_planted = true
	prev_r_planted = true
	prev_l_mode = -1
	prev_r_mode = -1
	for frame in 45:
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
		if frame >= 30 and l_pl and r_pl and not bool(tel["standing_step_active"]):
			settled_cleanly = true
		prev_l_planted = l_pl
		prev_r_planted = r_pl
		prev_l_mode = l_mode
		prev_r_mode = r_mode
		prev_l_piv = l_piv
		prev_r_piv = r_piv
	_check(settled_cleanly and release_slip < 0.02 and giant.rotation.y > 0.25 and giant.rotation.y < 1.2,
			"releasing directional input mid-pivot finishes placing the step cleanly without slipping")

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


func _stomp_charge_pivot() -> void:
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
	# Charge a stomp into the wall and keep holding forward during the charge (the walk presses
	# into the wall), then mid-cooldown swing the view -Z behind and keep forward held.
	_key(KEY_SPACE)
	await _wait_windup(current, 0.25)
	Input.action_press("move_forward")
	for frame in 240:
		if current.snapshot().stomp == "cooldown":
			break
		await physics_frame
	await _ticks(20)
	_mouse(Vector2(-angle_difference(orbit.rotation.y, PI) / 0.0028, 0.0))
	var start_z := giant.global_position.z
	var standing_pivot := false
	var turned := false
	var left := false
	for frame in 1500:
		await physics_frame
		standing_pivot = standing_pivot or bool(giant.get_turn_telemetry()["standing_turning"])
		if absf(angle_difference(giant.rotation.y, PI)) < 0.5:
			turned = true
		if giant.global_position.z - start_z > 15.0:
			left = true
			break
	Input.action_release("move_forward")
	_check(standing_pivot and turned and left,
			"a giant charging at a wall while holding forward pivots in place and leaves the wall")
	_game.show_menu()


func _giant_sandbox() -> void:
	_game.start_mode(true)
	var current := _round()
	var giant := _actor(1)
	await _ticks(4)
	_check(current.get_node_or_null("Human") == null and current.get_node("Civilians").get_child_count() > 0,
			"giant mode spawns the giant and civilian NPCs")
	_check(root.get_camera_3d() == current.get_node("Orbit/Arm/Camera"), "giant camera activates")

	await _check_giant_walk(giant)
	_check(_roadblock_count(current) == 0, "sandbox maps no longer contain roadblocks")

	# Keep the stomp telegraph, pause and foot-placement checks on open road now that
	# roadblocks are gone. Building damage is exercised by the core loop below.
	giant.position = Vector3(0.0, 0.03, 32.0)
	giant.rotation = Vector3.ZERO
	var street_orbit: Node3D = current.get_node("Orbit")
	_mouse(Vector2(-angle_difference(street_orbit.rotation.y, 0.0) / 0.0028, 0.0))
	await _ticks(4)
	await _wait_ready(current)
	_key(KEY_SPACE)
	await _wait_windup(current, 0.25)
	_check(current.snapshot().stomp == "windup" and current.has_node("Effects/StompWarning"),
			"Space starts a visible warning before damage")
	_key(KEY_ESCAPE)
	var before_pause := giant.position
	var paused_foot := _ankle(giant, "L")
	await _ticks(55)
	_check(current.snapshot().stomp == "windup" and giant.position == before_pause,
			"pause freezes an in-progress stomp")
	_check(_ankle(giant, "L").is_equal_approx(paused_foot), "pause freezes the skeletal pose")
	_key(KEY_ESCAPE)
	await _ticks(12)
	var warning: Node3D = current.get_node("Effects/StompWarning")
	var center := warning.global_position
	_check(Vector2(warning.scale.x, warning.scale.z).is_equal_approx(FOOT_RADII),
			"initial warning is the width and length of the left shoe")
	var support := _ankle(giant, "R")
	_check(_ankle(giant, "L").y > support.y + 3.8 and absf(support.y - 1.86) < 0.22,
			"windup lifts the striking foot while the support foot stays grounded")
	for frame in 35:
		if current.snapshot().stomp == "impact":
			break
		await physics_frame
	var contact := _left_sole(giant)
	_check(absf(contact.y) < 0.2 and Vector2(contact.x - center.x, contact.z - center.z).length() < 0.15,
			"striking sole lands at the advertised impact center")
	await _wait_ready(current)
	_check(absf(_ankle(giant, "L").z - _ankle(giant, "R").z) < 0.24,
			"recovery returns the striking foot to the idle stance")

	# Place the actor on the street-facing side of each core building to exercise
	# actual impact detection against all footprints in the central harbor.
	var targets: Node = current.get_node("District/Targets")
	for building_name: StringName in CORE_BUILDINGS:
		var target: Node3D = targets.get_node(NodePath(building_name))
		var building_blocker: StaticBody3D = target.get_node("BlockingBody")
		if building_blocker.collision_layer == 0:
			continue
		var from_south: bool = is_equal_approx(target.position.z, -12.5) or is_equal_approx(target.position.z, 23.65)
		var before_count: int = current.snapshot().destroyed
		await _wait_growth(current, before_count)
		var factor := pow(GROWTH_PER_BUILDING, before_count)
		var gap := -FOOT_OFFSET.z * factor
		if target.name == &"Tidewater1":
			# The shoe center lands beyond the original longitudinal radius.
			gap += lerpf(FOOT_RADII.y, FOOT_RADII.y * factor, 0.5)
		giant.position = target.position + Vector3(0, 0.03, (1 if from_south else -1) * (target.footprint.z * 0.5 + gap))
		var orbit: Node3D = current.get_node("Orbit")
		var yaw := 0.0 if from_south else PI
		giant.rotation = Vector3(0.0, yaw, 0.0)
		_mouse(Vector2(-angle_difference(orbit.rotation.y, yaw) / 0.0028, 0.0))
		await _ticks(3)
		if before_count == 3:
			_check(not _has_strike_overlay(target), "the first building after the unlock starts undamaged")
		if before_count == 5:
			# Before the sixth building falls, walking straight into it still blocks the giant.
			giant.position = Vector3(target.position.x, 0.03, target.position.z + target.footprint.z * 0.5 + 2.9 * factor + 2.2)
			_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
			await _ticks(40)
			Input.action_press("move_forward")
			var blocked_speed := 99.0
			for f in 35:
				await physics_frame
				if f > 8:
					blocked_speed = minf(blocked_speed, Vector2(giant.get_real_velocity().x, giant.get_real_velocity().z).length())
			Input.action_release("move_forward")
			_check(building_blocker.collision_layer == BUILDING_LAYER and blocked_speed < 0.5,
					"touching the sixth building before unlocking still stops the giant")
			giant.position = target.position + Vector3(0, 0.03, (1 if from_south else -1) * (target.footprint.z * 0.5 + gap))
			await _ticks(4)
		if before_count >= 6 and target.name == &"DockPress3":
			# After six destroyed buildings, simply walking into an intact building crushes it without stalling.
			giant.position = Vector3(target.position.x, 0.03, target.position.z + target.footprint.z * 0.5 + 2.9 * factor + 3.5)
			giant.rotation = Vector3.ZERO
			_mouse(Vector2(-angle_difference(orbit.rotation.y, 0.0) / 0.0028, 0.0))
			await _ticks(40)
			Input.action_press("move_forward")
			var crushed_on_touch := false
			var min_crush_speed := 99.0
			for f in 95:
				await physics_frame
				var spd := Vector2(giant.get_real_velocity().x, giant.get_real_velocity().z).length()
				if f >= 2:
					min_crush_speed = minf(min_crush_speed, spd)
				if not crushed_on_touch and building_blocker.collision_layer == 0:
					crushed_on_touch = true
			Input.action_release("move_forward")
			var expected_destroyed := before_count + 1
			_check(crushed_on_touch and target.has_node("CollapseModel") and current.snapshot().destroyed == expected_destroyed,
					"after six buildings, touching a building immediately destroys it without stomping")
			_check(min_crush_speed > 6.85 and giant.position.z < target.position.z + target.footprint.z * 0.5,
					"crushing through a building keeps full walking speed without stalling")
			await _wait_growth(current, expected_destroyed)
			_check(_giant_has_scale(giant, pow(GROWTH_PER_BUILDING, expected_destroyed)),
					"touch-crushing a building still triggers the ten percent growth")
			continue
		var attacks := 2 if before_count < 3 else 1
		for hit in attacks:
			if building_blocker.collision_layer == 0:
				break
			await _stomp(current)
			if target.name == &"DockPress1" and hit == 0:
				_check(building_blocker.collision_layer == BUILDING_LAYER and target.has_node("IntactModel")
						and not target.has_node("CollapseModel") and _giant_has_scale(giant, 1.0),
						"first building hit keeps the intact model, collision and giant size")
			if before_count == 2 and hit == 0:
				_check(building_blocker.collision_layer == BUILDING_LAYER and current.snapshot().destroyed == 2,
						"the third building still takes two attacks")
		if before_count == 2:
			_check(current.snapshot().destroyed == 3 and building_blocker.collision_layer == 0,
					"destroying the third building reaches the unlock threshold")
		if before_count == 3:
			_check(current.snapshot().destroyed == 4 and building_blocker.collision_layer == 0,
					"the first attack after the unlock destroys an undamaged building")
		if target.name == &"DockPress1":
			_check(_giant_has_scale(giant, GROWTH_PER_BUILDING), "one destroyed building grows the model and capsule by ten percent")
			await _check_collapse_pause(target, building_blocker)
		if target.name == &"Tidewater1":
			_check(building_blocker.collision_layer == 0, "grown stomp reaches a building beyond the original attack range")
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
	_check(await _walk_rubble(giant, tower, 2.5), "giant walks up and over the tower rubble")
	await _wait_ready(current)
	# Aim at the tower from the side facing the district center by steering the body there
	# naturally (swing the view, hold the direction until the body converges) instead of
	# hard-setting the rotation — the in-place turn owns that transition now that charging
	# no longer cancels it.
	var orbit: Node3D = current.get_node("Orbit")
	var yaw := orbit.rotation.y + PI
	_mouse(Vector2(-angle_difference(orbit.rotation.y, yaw) / 0.0028, 0.0))
	Input.action_press("move_forward")
	for frame in 420:
		await physics_frame
		if absf(angle_difference(yaw, giant.rotation.y)) < 0.05:
			break
	Input.action_release("move_forward")
	await _ticks(2)
	_check(absf(angle_difference(yaw, giant.rotation.y)) < 0.08,
			"holding the view-facing direction turns the body onto the view yaw")
	giant.global_position = tower.to_global(Vector3.UP * 0.04 + FOOT_OFFSET * final_scale)
	await _ticks(4)
	_key(KEY_SPACE)
	await _wait_windup(current)
	var elevated_warning := current.get_node_or_null("Effects/StompWarning") as Node3D
	_check(elevated_warning != null and elevated_warning.global_position.y > 0.7,
			"stomp warning moves up to the rubble surface")
	_check(elevated_warning != null and Vector2(elevated_warning.scale.x, elevated_warning.scale.z)
			.is_equal_approx(FOOT_RADII * final_scale), "the shoe print grows in both directions")

	# Start another collapse and restart before the animation has time to finish.
	_game.restart()
	var replacement := _round()
	var fresh_giant := _actor(1)
	fresh_giant.position = Vector3(-12.0, 0.03, 30.5)
	await _ticks(4)
	Input.action_press("move_forward")
	await _ticks(18)
	Input.action_release("move_forward")
	_check(replacement.snapshot().destroyed == 0 and replacement.has_node("District/Targets/DockPress3/IntactModel"),
			"restarting removes the touch-crush upgrade")
	fresh_giant.position = Vector3(-12.0, 0.03, 30.5)
	await _ticks(4)
	await _stomp(replacement)
	_check(replacement.snapshot().destroyed == 0 and replacement.has_node("District/Targets/DockPress3/IntactModel"),
			"restarting removes the one-hit building upgrade")
	await _stomp(replacement)
	_check(replacement.has_node("District/Targets/DockPress3/CollapseModel"),
			"a new round can play the same source clip again")
	_game.pause()
	_game.restart()
	await _ticks(4)
	_check(_initial_state(_round()) and _actor(1).position.z == 32.0, "restart restores all buildings, cooldown and count")
	_check(_round().has_node("District/Targets/DockPress3/IntactModel")
			and not _round().has_node("District/Targets/DockPress3/CollapseModel")
			and not _round().has_node("District/Targets/DockPress3/RuinBody"), "restart discards collapse and rubble collision")
	_game.restart()
	await _ticks(4)
	_check(_initial_state(_round()), "consecutive giant restart also resets the round")
	_game.pause()
	_game.show_menu()
	_check(not paused and _game.get_screen() == "menu", "return to title releases pause")


func _queued_growth_and_touch_crush() -> void:
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
	var over_cap := _test_building(targets, Vector3(-672.0, 0.02, -693.0))
	root.add_child(current)
	var giant := current.get_node("Giant") as CharacterBody3D
	giant.position = sites[0] - FOOT_OFFSET
	await _ticks(3)
	await _stomp(current)
	await _wait_ready(current)
	_key(KEY_SPACE)
	for frame in 45:
		if current.snapshot().stomp == "impact":
			break
		await physics_frame
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
			"the cooldown preserves every queued compounding increase")
	giant.position = sites[1] - FOOT_OFFSET * pow(GROWTH_PER_BUILDING, 3)
	await _stomp(current)
	await _wait_growth(current, 6)
	giant.position = sites[2] + Vector3.BACK * 3.0
	await _wait_growth(current, 8)
	_check(current.snapshot().destroyed == 8 and fixtures[7].has_node("RuinBody"),
			"the eighth growth unlocks after the queue reaches eight")

	giant.position = sites[3] + Vector3.BACK * (2.9 * pow(GROWTH_PER_BUILDING, 8) + 4.0)
	await _wait_ready(current)
	await _ticks(3)
	Input.action_press("move_forward")
	var min_speed := INF
	for frame in 52:
		await physics_frame
		if frame >= 2:
			min_speed = minf(min_speed, Vector2(giant.get_real_velocity().x, giant.get_real_velocity().z).length())
	Input.action_release("move_forward")
	_check(current.snapshot().destroyed == 9 and fixtures[8].has_node("RuinBody")
			and not fixtures[8].get_node("BlockingBody").collision_layer and min_speed > 6.85,
			"the giant still crushes a building at full speed after the eighth growth")

	giant.position = cap_site + Vector3.BACK * 3.0
	await _wait_growth(current, 32, 1700)
	var capsule := (giant.get_node("Collision") as CollisionShape3D).shape as CapsuleShape3D
	var max_scale := 500.0 / 25.2
	_check(capsule.height == 500.0 and current.snapshot().giant_height == 500.0
			and current.snapshot().giant_at_max_height
			and _giant_has_scale(giant, max_scale), "the giant model and capsule stop at 500 meters")
	giant.position = over_cap.position + Vector3.BACK * 3.0
	await _ticks(125)
	_check(over_cap.get_node("BlockingBody").collision_layer == 0
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
	await _check_large_stomp_timing(current, max_scale)
	current.queue_free()
	await process_frame


func _check_large_stomp_timing(current: Node, scale_factor: float) -> void:
	await _wait_ready(current)
	var giant := current.get_node("Giant") as CharacterBody3D
	var ankle_start := _ankle(giant, "L").y
	_key(KEY_SPACE)
	var frames := {"windup": 0, "impact": 0, "cooldown": 0}
	var lifted_with_warning := false
	for frame in 350:
		await physics_frame
		var data: Dictionary = current.snapshot()
		if data.stomp == "ready":
			if frames.windup > 0:
				break
			continue
		frames[data.stomp] += 1
		if data.stomp == "windup" and data.stomp_progress > 0.5 and data.stomp_progress < 0.6:
			var warning := current.get_node_or_null("Effects/StompWarning") as Node3D
			var raised := _ankle(giant, "L").y - ankle_start > scale_factor
			lifted_with_warning = lifted_with_warning or (warning != null and warning.visible and raised)
	_check(lifted_with_warning and absf(frames.windup - 60.0 * 0.52 * sqrt(scale_factor)) <= 2.0
			and absf(frames.impact - 60.0 * 0.48 * sqrt(scale_factor)) <= 2.0,
			"giant size stretches the telegraph, landing and recovery animation together")
	_check(absf(frames.cooldown - 60.0 * 0.72) <= 2.0, "stomp cooldown stays the same at maximum size")


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
	await _stomp(current)
	await _stomp(current)
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
			"second hit immediately enables rubble collision while the low-poly building collapses")
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
	await _ticks(70)
	_check(absf(camera.v_offset) < 0.01, "the footstep shake settles once the giant stops")
	_key(KEY_SPACE)
	var stomp_peak := 0.0
	for frame in 55:
		await physics_frame
		stomp_peak = maxf(stomp_peak, absf(camera.v_offset))
	_check(stomp_peak > step_peak * 1.5, "a deliberate stomp shakes the camera more than walking")
	_game.show_menu()


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
	current.tap_stomp()
	for frame in 75:
		await physics_frame
		if absf(camera.v_offset) > 0.08:
			break
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
	current.tap_stomp()
	for frame in 70:
		await physics_frame
		own_peak = maxf(own_peak, absf(camera.v_offset))
	_check(own_peak < 0.003, "Own footfalls and stomps stop shaking the camera while the switch is off")

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
	_check(current.has_node("Effects/StompWarning") and current.has_node("Effects/StompWarning2"),
			"both AI giants can telegraph stomps at the same time")
	await _ticks(32)
	_check(current.snapshot().health == 1
			and not current.has_node("Effects/StompWarning") and not current.has_node("Effects/StompWarning2"),
			"both AI stomps hit independently and clear their own warnings")

	_game.start_mode(true)
	current = _round()
	first = _actor(1)
	second = current.get_node("OtherGiants/Giant2") as CharacterBody3D
	second.position = Vector3(0.0, 0.02, -684.0)
	var second_start := second.position
	var target := current.get_node("District/Targets/DockPress1") as Node3D
	first.position = target.position + Vector3.BACK * (target.footprint.z * 0.5 - FOOT_OFFSET.z)
	await _ticks(4)
	await _stomp(current)
	await _stomp(current)
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
	var early_stomp := false
	var saw_standing_pivot := false
	var max_yaw_step := 0.0
	var warned_frame := -1
	for i in range(180):
		await _ticks(1)
		var step := absf(angle_difference(prev_yaw, giant.rotation.y))
		prev_yaw = giant.rotation.y
		if current.has_node("Effects/StompWarning"):
			warned_frame = i
			if i < 12:
				early_stomp = true
			break
		max_yaw_step = maxf(max_yaw_step, step)
		var diag: Dictionary = giant.get_turn_telemetry()
		if diag.get("mode", "") == "standing_turn":
			saw_standing_pivot = true
	_check(not early_stomp,
			"an AI giant facing away does not snap-stomp a target behind her")
	_check(saw_standing_pivot and warned_frame >= 12,
			"an AI giant pivots with standing small steps before stomping behind her (warned=%d)" % warned_frame)
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
	if data.health != 3 or data.stamina != 1.0 or data.destroyed != 0 or data.stomp != "ready":
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


func _stomp(current: Node) -> void:
	await _wait_ready(current)
	_key(KEY_SPACE)
	for frame in 180:
		if current.snapshot().stomp == "impact":
			await _ticks(42)
			return
		await physics_frame
	_check(false, "stomp reaches impact")


func _wait_growth(current: Node, count: int, limit := 180) -> void:
	for frame in limit:
		if current.snapshot().growth_count >= count:
			return
		await physics_frame
	_check(false, "queued growth completes")


func _wait_windup(current: Node, progress := 0.0) -> void:
	for frame in 180:
		var state: Dictionary = current.snapshot()
		if state.stomp == "windup" and state.stomp_progress >= progress:
			return
		await physics_frame
	_check(false, "stomp windup starts after any walking step lands")


func _wait_ready(current: Node) -> void:
	for frame in 350:
		if current.snapshot().stomp == "ready":
			return
		await physics_frame
	_check(false, "stomp cooldown finishes")


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
