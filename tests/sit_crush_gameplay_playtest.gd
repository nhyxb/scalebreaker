extends SceneTree
## End-to-end sit-crush (坐压) gameplay checks: crowd trigger, size-scaled hold,
## idle sit at the growth cap, early stand-up, escape on sight, and the pinned
## damage-over-time a bigger giant inflicts.
##
## Run from the project root:
##   XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --fixed-fps 60 \
##       --script res://tests/sit_crush_gameplay_playtest.gd

const BASE_HEIGHT := 25.2
const OPEN_STREET := Vector3(0.0, 0.01, -34.0)
const FAR_AWAY := Vector3(0.0, 0.01, -760.0)

var _game: Node
var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	seed(20261125)
	_game = load("res://scenes/main.tscn").instantiate()
	_game.settings_path = "user://sit-playtest-%d.cfg" % OS.get_process_id()
	root.add_child(_game)
	await process_frame
	await _player_can_sit_anywhere()
	await _crush_triggers_on_small_crowd()
	await _ai_crush_wins_over_chase_and_footfall()
	await _crush_can_begin_after_a_footfall()
	await _crush_ignores_ignore_ratios()
	await _hold_time_scales_with_size()
	await _idle_sit_stands_when_someone_appears()
	await _idle_sit_times_out()
	await _player_stands_up_early()
	await _big_sit_pins_and_drains()
	_game.show_menu()
	DirAccess.remove_absolute(_game.settings_path)
	print("Sit-crush gameplay: %d passed, %d failed" % [_checks - _failures, _failures])
	quit(1 if _failures else 0)


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures += 1
		push_error("FAIL  " + description)


# --- harness ---------------------------------------------------------------

func _round() -> Node:
	return _game.get_node("MapSlot/Round")


func _body(index: int) -> CharacterBody3D:
	if index == 0:
		return _round().get_node("Giant")
	return _round().get_node("OtherGiants/Giant%d" % (index + 1))


func _actor(index: int) -> Dictionary:
	var actors: Array = _round().growth_actors()
	for actor in actors:
		if int(actor["index"]) == index:
			return actor
	return {}


func _start_sandbox(overrides: Dictionary) -> void:
	var options: Dictionary = _game.default_mode_settings(1)
	options.merge({"giant_count": 1, "npc_initial": 0, "npc_respawn": false}, true)
	options.merge(overrides, true)
	_game.save_mode_settings(_game.default_mode_settings(0), options, _game.default_mode_settings(2))
	_game.start_mode(true)
	await _ticks(2)


func _start_growth(overrides: Dictionary) -> void:
	var options: Dictionary = _game.default_mode_settings(2)
	options.merge({"giant_count": 1, "npc_initial": 0, "npc_respawn": false}, true)
	options.merge(overrides, true)
	_game.save_mode_settings(_game.default_mode_settings(0), _game.default_mode_settings(1), options)
	_game.start_growth()
	await _ticks(2)


func _ticks(count: int) -> void:
	for frame in count:
		await physics_frame


func _press(action: String, frames := 2) -> void:
	Input.action_press(action)
	await _ticks(frames)
	Input.action_release(action)
	await _ticks(1)


func _request_sit(attempts := 8) -> bool:
	for attempt in attempts:
		if String(_actor(0).get("sit", "")) != "":
			return true
		await _press("stand_up", 1)
		await _ticks(1)
	return String(_actor(0).get("sit", "")) != ""


func _crowd_nodes() -> Array:
	return _round().get_node("Civilians").get_children()


## Crowd in the rear landing zone, which is the only place a sit can reach.
func _hold_civilians_in_front(index: int, count := 2) -> void:
	var body := _body(index)
	var forward := Vector3(0.0, 0.0, 1.0).rotated(Vector3.UP, body.rotation.y)
	var side := forward.cross(Vector3.UP)
	var crowd := _crowd_nodes()
	for i in mini(crowd.size(), count):
		var offset := forward * 2.7 + side * (0.6 if i == 0 else -0.6)
		var npc := crowd[i] as CharacterBody3D
		npc.global_position = body.global_position + offset
		npc.velocity = Vector3.ZERO


## The seated pelvis drops behind the body (yaw 0 faces -Z), so the crowd stands at +Z.
func _hold_crowd() -> void:
	_place(1, OPEN_STREET + Vector3(0.8, 0.0, 3.0))
	_place(2, OPEN_STREET + Vector3(-0.9, 0.0, 2.4))


func _place(index: int, position: Vector3) -> void:
	var body := _body(index)
	body.global_position = position
	body.velocity = Vector3.ZERO


func _wait_phase(index: int, phase: String, limit: int, keep_crowd := false) -> bool:
	for frame in limit:
		if keep_crowd:
			_hold_crowd()
		await physics_frame
		if String(_actor(index).get("sit", "")) == phase:
			return true
	return false


func _phase_frames(index: int, limit: int) -> Dictionary:
	var phases := {"drop": 0, "hold": 0, "rise": 0}
	for frame in limit:
		await physics_frame
		var sit := String(_actor(index).get("sit", ""))
		if sit == "":
			break
		phases[sit] = int(phases.get(sit, 0)) + 1
	return phases


# --- checks ----------------------------------------------------------------

func _player_can_sit_anywhere() -> void:
	await _start_growth({"giant_count": 1, "giant_height": BASE_HEIGHT})
	_place(0, OPEN_STREET)
	await _ticks(4)
	_check(String(_actor(0).get("sit", "")) == "",
			"The player giant does not sit on its own")
	var started := await _request_sit()
	_check(started, "A giant sits down on an empty street with nothing in range")
	_check(_round().get_node("Effects").find_child("SitWarning", true, false) != null,
			"A solo sit still shows where the giant will land")
	var reached_hold := await _wait_phase(0, "hold", 260)
	_check(reached_hold, "The solo sit reaches the seated hold")
	await _ticks(200)
	_check(String(_actor(0).get("sit", "")) == "hold",
			"The seated player does not stand up on its own")
	await _press("stand_up")
	var rose := false
	for frame in 140:
		await physics_frame
		var sit := String(_actor(0).get("sit", ""))
		if sit == "rise" or sit == "":
			rose = true
			break
	_check(rose, "The solo sit can be stood up early")


func _crush_triggers_on_small_crowd() -> void:
	await _start_growth({"giant_count": 3, "giant_height": BASE_HEIGHT})
	_place(0, OPEN_STREET)
	_round().debug_resize_giant(1, 1.0)
	_round().debug_resize_giant(2, 1.0)
	_hold_crowd()
	await _ticks(4)
	_check(String(_actor(0).get("sit", "")) == "",
			"The player giant waits for a sit request instead of dropping on its own")
	var started := await _request_sit()
	_check(started, "Two tiny targets inside the seated footprint start the sit-crush on request")
	_check(String(_actor(0).get("sit", "")) == "drop",
			"The giant drops straight down along its current facing instead of pivoting first")
	var effects := _round().get_node("Effects")
	var ring := effects.find_child("SitWarning", true, false) as Node3D
	_check(ring != null, "The sit-crush shows a yellow landing ring while it winds up")
	if ring != null and is_instance_valid(ring):
		var body := _body(0)
		var back := Vector3(0.0, 0.0, 1.0).rotated(Vector3.UP, body.rotation.y)
		var expected := body.global_position + back * (2.85 * BASE_HEIGHT / 25.2)
		_check(Vector2(ring.global_position.x - expected.x,
				ring.global_position.z - expected.z).length() < 1.5,
				"The landing ring sits where the pelvis will come down (behind the giant)")
	# The crowd stands behind the giant, exactly where the seated pelvis lands.
	var reached_hold := await _wait_phase(0, "hold", 700, true)
	_check(reached_hold, "The seated hold begins after the drop")
	var turned := absf(angle_difference(0.0, _body(0).rotation.y))
	_check(turned < 0.05, "Sitting keeps the current facing untouched (%.2f deg)" % rad_to_deg(turned))
	_check(effects.find_child("SitWarning", true, false) == null,
			"The landing ring clears once the giant is seated")
	var victim_health := float(_actor(1)["health"])
	_check(victim_health <= 0.001, "The seated impact crushes the small crowd (health %.2f)" % victim_health)
	await _ticks(240)
	_check(String(_actor(0).get("sit", "")) == "hold",
			"The player keeps sitting until asked to stand")
	await _press("stand_up")
	var phases := await _phase_frames(0, 300)
	_check(String(_actor(0).get("sit", "")) == "", "The giant stands back up when the player asks")
	_check(int(phases["rise"]) > 30, "The rise plays out before control returns (%d frames)" % int(phases["rise"]))


func _ai_crush_wins_over_chase_and_footfall() -> void:
	# 常规追击:AI-1 追着前方 40 m 的 25 m 对手,同时脚边站着两个 1 m 的小目标。
	# 期望：群体坐压优先触发，小目标在落座时一起受击。
	await _start_growth({"giant_count": 5, "giant_height": BASE_HEIGHT})
	_place(0, FAR_AWAY)
	_place(1, OPEN_STREET)
	_place(2, OPEN_STREET + Vector3(0.0, 0.0, -40.0))
	_round().debug_resize_giant(2, BASE_HEIGHT)
	_round().debug_resize_giant(3, 1.0)
	_round().debug_resize_giant(4, 1.0)
	await _ticks(4)
	var crowd_at_feet: Array[int] = [3, 4]
	var started := false
	var chased_before_sit := false
	for frame in 180:
		_pin_crowd_at_feet()
		if int(_actor(1).get("chase", 0)) != 0:
			chased_before_sit = true
		await physics_frame
		if String(_actor(1).get("sit", "")) != "":
			started = true
			break
	_check(started, "A chasing AI drops into a sit-crush on a two-target crowd by itself")
	_check(chased_before_sit,
			"The sit starts while the AI is still pursuing an ordinary chase target")
	var alive := 0
	for index in crowd_at_feet:
		if float(_actor(index).get("health", 0.0)) > 0.0:
			alive += 1
	_check(alive == 2,
			"The crowd sit starts before either small target is struck (both alive: %d)" % alive)
	# 落座伤害在 drop 段末结算,期间必须把人留在落区里。
	var reached_hold := false
	for frame in 700:
		_pin_crowd_at_feet()
		await physics_frame
		if String(_actor(1).get("sit", "")) == "hold":
			reached_hold = true
			break
	_check(reached_hold, "The chase-triggered crowd sit reaches the seated hold")
	for index in crowd_at_feet:
		_check(float(_actor(index).get("health", 0.0)) <= 0.001,
				"The crowd sit crushes small target #%d with the seated impact" % index)


func _pin_crowd_at_feet() -> void:
	# 两个 1 m 小目标固定在 AI-1 身体后方 2.4 m：坐压的骨盆只会落在背后。
	var body := _body(1)
	var back := Vector3(0.0, 0.0, 1.0).rotated(Vector3.UP, body.rotation.y)
	var side := back.cross(Vector3.UP)
	var anchor: Vector3 = body.global_position
	for pair in [[3, 0.7], [4, -0.7]]:
		var npc := _body(pair[0])
		npc.global_position = anchor + back * 2.4 + side * float(pair[1])
		npc.velocity = Vector3.ZERO


func _crush_can_begin_after_a_footfall() -> void:
	await _start_growth({"giant_count": 5, "giant_height": BASE_HEIGHT})
	_place(0, FAR_AWAY)
	_place(1, OPEN_STREET)
	_place(2, OPEN_STREET + Vector3(0.0, 0.0, -40.0))
	_place(3, OPEN_STREET + Vector3(40.0, 0.0, 0.0))
	_place(4, OPEN_STREET + Vector3(-40.0, 0.0, 0.0))
	_round().debug_resize_giant(2, BASE_HEIGHT)
	_round().debug_resize_giant(3, 1.0)
	_round().debug_resize_giant(4, 1.0)
	await _ticks(4)
	var landed := false
	for frame in 240:
		await physics_frame
		if int(_actor(1).get("footfall_count", 0)) > 0:
			landed = true
			break
	_check(landed, "A chasing giant completes a heavy footfall before the crowd approaches")
	var frames_to_sit := -1
	for frame in 16:
		var giant := _body(1)
		var back := Vector3(0.0, 0.0, 1.0).rotated(Vector3.UP, giant.rotation.y)
		for index in [3, 4]:
			var civilian := _body(index)
			var lateral := 0.8 if index == 3 else -0.8
			civilian.global_position = giant.global_position + back * 2.4 + giant.global_basis.x * lateral
			civilian.velocity = Vector3.ZERO
		await physics_frame
		if not String(_actor(1).get("sit", "")).is_empty():
			frames_to_sit = frame + 1
			break
	_check(frames_to_sit > 0 and frames_to_sit <= 16,
			"A qualifying crowd opens a sit directly after a footfall (%d frames)" % frames_to_sit)
	_check(float(_actor(3).get("health", 0.0)) > 0.0 and float(_actor(4).get("health", 0.0)) > 0.0,
			"The crowd sit starts while both small targets are alive")


func _crush_ignores_ignore_ratios() -> void:
	# 坐压人数统计不看 rival_ignore_ratio / human_ignore_ratio:即使 AI 完全
	# 不想追击这些小目标(倍率门槛极低),它们也必须算进坐压人数。
	await _start_growth({"giant_count": 5, "giant_height": BASE_HEIGHT,
			"rival_ignore_ratio": 1.01, "human_ignore_ratio": 1.01, "base_attack": 1.0})
	_place(0, FAR_AWAY)
	_place(1, OPEN_STREET)
	_place(2, FAR_AWAY + Vector3(50.0, 0.0, 0.0))
	_place(3, OPEN_STREET + Vector3(40.0, 0.0, 0.0))
	_place(4, OPEN_STREET + Vector3(-40.0, 0.0, 0.0))
	_round().debug_resize_giant(2, BASE_HEIGHT)
	_round().debug_resize_giant(3, 1.0)
	_round().debug_resize_giant(4, 1.0)
	await _ticks(4)
	var started := false
	for frame in 180:
		var back: Vector3 = Vector3(0.0, 0.0, 1.0).rotated(Vector3.UP, _body(1).rotation.y)
		var side: Vector3 = back.cross(Vector3.UP)
		var anchor: Vector3 = _body(1).global_position
		# Keep both bodies in the rear landing zone and clear of either shoe's lane.
		for pair in [[3, 3.25], [4, -3.25]]:
			var npc := _body(pair[0])
			npc.global_position = anchor + back * 3.1 + side * float(pair[1])
			npc.velocity = Vector3.ZERO
		await physics_frame
		if String(_actor(1).get("sit", "")) != "":
			started = true
			break
	_check(started,
			"Bodies past the ignore ratios still count toward the sit crowd")


func _hold_time_scales_with_size() -> void:
	var holds: Array[int] = []
	for height: float in [BASE_HEIGHT, 100.0]:
		await _start_sandbox({
			"giant_count": 2, "npc_initial": 2, "npc_respawn": false,
			"giant_height": BASE_HEIGHT, "giant_max_height": 500.0,
		})
		_place(0, FAR_AWAY)
		_round().debug_resize_giant(1, height)
		await _ticks(5)
		var started := false
		for frame in 600:
			_hold_civilians_in_front(1)
			await physics_frame
			if String(_actor(1).get("sit", "")) != "":
				started = true
				break
		_check(started, "An AI giant at %.0f m starts a sit-crush on the crowd" % height)
		var phases := await _phase_frames(1, 900)
		holds.append(int(phases["hold"]))
	_check(holds.size() == 2 and holds[1] > holds[0] + 40,
			"A 100 m AI giant stays seated much longer than a 25.2 m one (%d vs %d frames)" % [
				holds[holds.size() - 1], holds[0]])


func _idle_sit_stands_when_someone_appears() -> void:
	await _start_sandbox({
		"giant_count": 2, "giant_height": BASE_HEIGHT, "giant_max_height": BASE_HEIGHT,
		"sit_idle_chance": 1.0, "sit_idle_timeout": 30.0,
	})
	_place(0, FAR_AWAY)
	_place(1, OPEN_STREET)
	var sat := await _wait_phase(1, "hold", 660)
	_check(sat, "A maxed-out AI giant with an empty horizon sits down to idle")
	_check(bool(_actor(1).get("sit_idle", false)), "The idle sit is flagged separately from a sit-crush")
	_place(0, OPEN_STREET + Vector3(0.0, 0.0, -60.0))
	var stood := false
	for frame in 120:
		await physics_frame
		var sit := String(_actor(1).get("sit", ""))
		if sit == "rise" or sit == "":
			stood = true
			break
	_check(stood, "A target appearing in sight range gets the idle giant back on its feet")


func _idle_sit_times_out() -> void:
	await _start_sandbox({
		"giant_count": 2, "giant_height": BASE_HEIGHT, "giant_max_height": BASE_HEIGHT,
		"sit_idle_chance": 1.0, "sit_idle_timeout": 1.5,
	})
	_place(0, FAR_AWAY)
	_place(1, OPEN_STREET)
	var hold_frames := 0
	var saw_hold := false
	for frame in 620:
		await physics_frame
		var sit := String(_actor(1).get("sit", ""))
		if sit == "hold":
			saw_hold = true
			hold_frames += 1
		elif saw_hold:
			break
	_check(saw_hold, "The idle sit starts without any target around")
	_check(hold_frames > 40 and hold_frames < 150,
			"The idle sit honours the configured 1.5 s timeout (%d frames)" % hold_frames)


func _player_stands_up_early() -> void:
	await _start_growth({"giant_count": 3, "giant_height": BASE_HEIGHT})
	_place(0, OPEN_STREET)
	_round().debug_resize_giant(1, 1.0)
	_round().debug_resize_giant(2, 1.0)
	_hold_crowd()
	await _ticks(4)
	var started := await _request_sit()
	_check(started, "The player's giant sits down on request")
	var reached_hold := await _wait_phase(0, "hold", 700, true)
	_check(reached_hold, "The player's giant reaches the seated hold before standing up")
	await _press("stand_up")
	var rose := false
	for frame in 60:
		await physics_frame
		var sit := String(_actor(0).get("sit", ""))
		if sit == "rise" or sit == "":
			rose = true
			break
	_check(rose, "Pressing the stand-up key lifts the player off the ground early")


func _big_sit_pins_and_drains() -> void:
	await _start_sandbox({
		"giant_count": 2, "giant_height": BASE_HEIGHT, "giant_max_height": 500.0,
		"sit_crush_targets": 1, "sit_pin_ratio": 5.0, "sit_idle_chance": 0.0,
	})
	_place(0, OPEN_STREET)
	_round().debug_resize_giant(0, 125.0)
	_round().debug_resize_giant(1, 20.0)
	_place(1, OPEN_STREET + Vector3(0.0, 0.0, -8.0))
	await _ticks(3)
	var started := await _request_sit()
	_check(started, "The big giant sits down on the smaller one")
	var pinned := false
	var pinned_at := Vector3.ZERO
	for frame in 700:
		if not pinned:
			_place(1, OPEN_STREET + Vector3(0.0, 0.0, -8.0))
		await physics_frame
		if bool(_actor(1).get("pinned", false)):
			pinned = true
			pinned_at = _body(1).global_position
			break
	_check(pinned, "A giant crushed by a 6x bigger sit is pinned in place")
	var start_health := float(_actor(1)["health"])
	await _ticks(66)
	var drained := start_health - float(_actor(1)["health"])
	_check(drained > 0.15, "The pinned giant keeps losing a fifth of the attack twice a second (%.2f)" % drained)
	_check(_body(1).global_position.distance_to(pinned_at) < 0.6,
			"The pinned giant cannot move while sat on")
	# The pinned body belongs to the attacker's sit, so it must not start a second sit
	# state machine on top of the pin (`sit_ready` mirrors the same guard).
	await _ticks(8)
	_check(String(_actor(1).get("sit", "")) == "",
			"A pinned giant does not start a sit of its own")
	await _press("stand_up")
	var released := false
	for frame in 300:
		await physics_frame
		if not bool(_actor(1).get("pinned", false)):
			released = true
			break
	_check(released, "Standing up releases the pinned giant")
