extends Node
## Global audio manager (Autoload: HarborAudio) for Scalebreaker & 微缩卧室.
## Provides pooled 2D/3D SFX playback with scale-aware spatial attenuation,
## per-sound rate limiting, voice stealing, pause-safe UI audio, seamless
## ambience crossfading, and persistent volume/mute routing.

const UI_POOL_SIZE := 6
const SFX_2D_POOL_SIZE := 12
const SFX_3D_POOL_SIZE := 24
const SHAKE_POOL_SIZE := 2
const TELEMETRY_LIMIT := 64

const STREAM_PATHS := {
	&"giant_footfall": [
		"res://assets/audio/giant_step_1.wav",
		"res://assets/audio/giant_step_2.wav",
	],
	&"giant_stomp": [
		"res://assets/audio/giant_stomp_1.wav",
		"res://assets/audio/giant_stomp_2.wav",
	],
	&"stomp_warn": ["res://assets/audio/stomp_warn.wav"],
	&"camera_shake_light": ["res://assets/audio/camera_shake_light.wav"],
	&"camera_shake_heavy": ["res://assets/audio/camera_shake_heavy.wav"],
	&"hand_whoosh": ["res://assets/audio/hand_whoosh.wav"],
	&"hand_grab": ["res://assets/audio/hand_grab.wav"],
	&"hand_punch": ["res://assets/audio/hand_punch.wav"],
	&"hand_crush": ["res://assets/audio/hand_crush.wav"],
	&"building_crack": ["res://assets/audio/building_crack.wav"],
	&"building_collapse": [
		"res://assets/audio/building_collapse_1.wav",
		"res://assets/audio/building_collapse_2.wav",
	],
	&"barrier_break": ["res://assets/audio/barrier_break.wav"],
	&"building_restore": ["res://assets/audio/building_restore.wav"],
	&"human_step": [
		"res://assets/audio/human_step_1.wav",
		"res://assets/audio/human_step_2.wav",
	],
	&"human_hurt": ["res://assets/audio/human_hurt.wav"],
	&"human_defeat": ["res://assets/audio/human_defeat.wav"],
	&"stamina_empty": ["res://assets/audio/stamina_empty.wav"],
	&"bedroom_step": [
		"res://assets/audio/bedroom_step_1.wav",
		"res://assets/audio/bedroom_step_2.wav",
	],
	&"bedroom_climb": ["res://assets/audio/bedroom_climb.wav"],
	&"bedroom_mantle": ["res://assets/audio/bedroom_mantle.wav"],
	&"coin_pickup": ["res://assets/audio/coin_pickup.wav"],
	&"coin_dwell_tick": ["res://assets/audio/coin_pickup.wav"],
	&"coin_drop": ["res://assets/audio/coin_drop.wav"],
	&"growth_surge": ["res://assets/audio/growth_surge.wav"],
	&"transform_giant": ["res://assets/audio/transform_giant.wav"],
	&"unlock_milestone": ["res://assets/audio/unlock_milestone.wav"],
	&"hit_confirm": ["res://assets/audio/hit_confirm.wav"],
	&"giant_hurt": ["res://assets/audio/giant_hurt.wav"],
	&"kill_confirm": ["res://assets/audio/kill_confirm.wav"],
	&"player_defeated": ["res://assets/audio/player_defeated.wav"],
	&"respawn": ["res://assets/audio/respawn.wav"],
	&"view_toggle": ["res://assets/audio/view_toggle.wav"],
	&"ui_hover": ["res://assets/audio/ui_hover.wav"],
	&"ui_click": ["res://assets/audio/ui_click.wav"],
	&"ui_back": ["res://assets/audio/ui_back.wav"],
	&"ui_error": ["res://assets/audio/ui_error.wav"],
	&"ui_pause": ["res://assets/audio/ui_pause.wav"],
	&"ui_resume": ["res://assets/audio/ui_resume.wav"],
	&"evac_victory": ["res://assets/audio/evac_victory.wav"],
	&"evac_lost": ["res://assets/audio/evac_lost.wav"],
}

const AMBIENCE_PATHS := {
	&"harbor": "res://assets/audio/ambience_harbor.ogg",
	&"bedroom": "res://assets/audio/ambience_bedroom.ogg",
}

const COOLDOWNS := {
	&"giant_stomp": 0.055,
	&"stomp_warn": 0.09,
	&"hand_whoosh": 0.08,
	&"hand_grab": 0.07,
	&"hand_punch": 0.06,
	&"hand_crush": 0.06,
	&"building_crack": 0.055,
	&"building_collapse": 0.075,
	&"barrier_break": 0.065,
	&"building_restore": 0.14,
	&"human_step": 0.06,
	&"bedroom_step": 0.08,
	&"bedroom_climb": 0.24,
	&"bedroom_mantle": 0.16,
	&"coin_pickup": 0.045,
	&"coin_dwell_tick": 0.14,
	&"coin_drop": 0.09,
	&"growth_surge": 0.22,
	&"hit_confirm": 0.04,
	&"giant_hurt": 0.06,
	&"ui_hover": 0.04,
	&"ui_click": 0.035,
	&"ui_back": 0.04,
}

var sfx_volume := 0.85
var ambience_volume := 0.60
var muted := false

var play_counts: Dictionary = {}
var last_events: Array[Dictionary] = []

var _streams: Dictionary = {}
var _ambience_streams: Dictionary = {}
var _variant_cursor: Dictionary = {}
var _last_played: Dictionary = {}
var _rng := RandomNumberGenerator.new()

var _ui_root: Node
var _gameplay_root: Node
var _ambience_root: Node
var _ui_pool: Array[AudioStreamPlayer] = []
var _sfx_2d_pool: Array[AudioStreamPlayer] = []
var _sfx_3d_pool: Array[AudioStreamPlayer3D] = []
var _shake_pool: Array[AudioStreamPlayer] = []
var _ambience_players: Array[AudioStreamPlayer] = []
var _ambience_active_idx := 0
var _current_ambience := &""
var _ambience_tween: Tween

var _ui_clock := 0.0
var _game_clock := 0.0
var _coin_streak := 0
var _last_coin_time := -10.0
var _last_shake_time := -10.0
var _last_shake_intensity := 0.0
var _was_paused := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	_load_streams()
	_build_pools()
	apply_audio_settings(sfx_volume, ambience_volume, muted)


func _exit_tree() -> void:
	if _ambience_tween and _ambience_tween.is_valid():
		_ambience_tween.kill()
	for p in _ambience_players:
		p.stop()
		p.stream = null
	for p in _ui_pool:
		p.stop()
		p.stream = null
	for p in _sfx_2d_pool:
		p.stop()
		p.stream = null
	for p3 in _sfx_3d_pool:
		p3.stop()
		p3.stream = null
	for ps in _shake_pool:
		ps.stop()
		ps.stream = null
	_streams.clear()
	_ambience_streams.clear()


func _process(delta: float) -> void:
	var dt := minf(delta, 0.1)
	_ui_clock += dt
	var paused := get_tree().paused
	if not paused:
		_game_clock += dt
	if paused != _was_paused:
		_was_paused = paused
		_sync_ambience_bus_gain()


func _load_streams() -> void:
	for id: StringName in STREAM_PATHS:
		var list: Array[AudioStream] = []
		for path: String in STREAM_PATHS[id]:
			var stream := load(path) as AudioStream
			if stream != null:
				list.append(stream)
		if not list.is_empty():
			_streams[id] = list
	for id: StringName in AMBIENCE_PATHS:
		var stream := load(AMBIENCE_PATHS[id]) as AudioStream
		if stream != null:
			if stream is AudioStreamOggVorbis:
				(stream as AudioStreamOggVorbis).loop = true
			_ambience_streams[id] = stream


func _build_pools() -> void:
	_ui_root = Node.new()
	_ui_root.name = "UiAudio"
	_ui_root.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_ui_root)
	for i in UI_POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = &"UI"
		_ui_root.add_child(player)
		_ui_pool.append(player)

	_gameplay_root = Node.new()
	_gameplay_root.name = "GameplayAudio"
	_gameplay_root.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(_gameplay_root)
	for i in SFX_2D_POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = &"SFX"
		_gameplay_root.add_child(player)
		_sfx_2d_pool.append(player)
	for i in SFX_3D_POOL_SIZE:
		var player3d := AudioStreamPlayer3D.new()
		player3d.bus = &"SFX"
		player3d.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		player3d.attenuation_filter_cutoff_hz = 4600.0
		player3d.attenuation_filter_db = -14.0
		player3d.max_db = 4.0
		_gameplay_root.add_child(player3d)
		_sfx_3d_pool.append(player3d)
	for i in SHAKE_POOL_SIZE:
		var shaker := AudioStreamPlayer.new()
		shaker.bus = &"SFX"
		_gameplay_root.add_child(shaker)
		_shake_pool.append(shaker)

	_ambience_root = Node.new()
	_ambience_root.name = "AmbienceAudio"
	_ambience_root.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_ambience_root)
	for i in 2:
		var amb := AudioStreamPlayer.new()
		amb.bus = &"Ambience"
		amb.volume_db = -60.0
		_ambience_root.add_child(amb)
		_ambience_players.append(amb)


func apply_audio_settings(new_sfx_volume: float, new_ambience_volume: float, new_muted: bool) -> void:
	if not is_finite(new_sfx_volume) or not is_finite(new_ambience_volume):
		return
	sfx_volume = maxf(new_sfx_volume, 0.0)
	ambience_volume = maxf(new_ambience_volume, 0.0)
	muted = new_muted

	var master_idx := AudioServer.get_bus_index(&"Master")
	if master_idx >= 0:
		AudioServer.set_bus_mute(master_idx, muted)

	for bus_name: StringName in [&"SFX", &"UI"]:
		var idx := AudioServer.get_bus_index(bus_name)
		if idx >= 0:
			var silent := sfx_volume == 0.0
			AudioServer.set_bus_mute(idx, silent)
			if not silent:
				AudioServer.set_bus_volume_db(idx, linear_to_db(sfx_volume))

	_sync_ambience_bus_gain()


func _sync_ambience_bus_gain() -> void:
	var amb_idx := AudioServer.get_bus_index(&"Ambience")
	if amb_idx < 0:
		return
	var silent := ambience_volume == 0.0
	AudioServer.set_bus_mute(amb_idx, silent)
	if not silent:
		var pause_duck := -6.0 if _was_paused else 0.0
		AudioServer.set_bus_volume_db(amb_idx, linear_to_db(ambience_volume) + pause_duck)


func set_ambience(kind: StringName) -> void:
	if kind == _current_ambience:
		if kind != &"" and not _ambience_players[_ambience_active_idx].playing:
			_ambience_players[_ambience_active_idx].play()
		return
	_current_ambience = kind
	if _ambience_tween and _ambience_tween.is_valid():
		_ambience_tween.kill()

	var outgoing := _ambience_players[_ambience_active_idx]
	var next_idx := 1 - _ambience_active_idx
	var incoming := _ambience_players[next_idx]
	_ambience_active_idx = next_idx

	_ambience_tween = create_tween().set_parallel(true).set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	if outgoing.playing:
		_ambience_tween.tween_property(outgoing, "volume_db", -42.0, 0.75)
		_ambience_tween.tween_callback(outgoing.stop).set_delay(0.76)

	if kind != &"" and _ambience_streams.has(kind):
		incoming.stream = _ambience_streams[kind]
		incoming.volume_db = -36.0
		incoming.play()
		var target_db := -5.5 if kind == &"harbor" else -7.0
		_ambience_tween.tween_property(incoming, "volume_db", target_db, 0.85)
		_record_event(StringName("ambience_" + String(kind)), Vector3.ZERO, target_db, 1.0, false)
	else:
		incoming.stop()


func get_current_ambience() -> StringName:
	return _current_ambience


func stop_gameplay_sfx() -> void:
	for p in _sfx_2d_pool:
		p.stop()
	for p3 in _sfx_3d_pool:
		p3.stop()
	stop_camera_shake()
	_coin_streak = 0


func stop_camera_shake() -> void:
	for ps in _shake_pool:
		ps.stop()
	_last_shake_intensity = 0.0


# ---------------------------------------------------------------------------
# Low-level Playback Primitives
# ---------------------------------------------------------------------------

func play_ui(id: StringName, volume_db: float = 0.0, pitch: float = 1.0, jitter: float = 0.02) -> bool:
	var stream := _pick_stream(id)
	if stream == null or not _pass_cooldown(id, _ui_clock):
		return false
	var player := _claim_2d(_ui_pool)
	var final_pitch := clampf(pitch * _rng.randf_range(1.0 - jitter, 1.0 + jitter), 0.35, 2.5)
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = final_pitch
	player.play()
	_record_event(id, Vector3.ZERO, volume_db, final_pitch, false)
	return true


func play_2d(id: StringName, volume_db: float = 0.0, pitch: float = 1.0, jitter: float = 0.04) -> bool:
	var stream := _pick_stream(id)
	if stream == null or not _pass_cooldown(id, _game_clock):
		return false
	var player := _claim_2d(_sfx_2d_pool)
	var final_pitch := clampf(pitch * _rng.randf_range(1.0 - jitter, 1.0 + jitter), 0.35, 2.5)
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = final_pitch
	player.play()
	_record_event(id, Vector3.ZERO, volume_db, final_pitch, false)
	return true


func play_3d(id: StringName, position: Vector3, volume_db: float = 0.0, pitch: float = 1.0,
		unit_size: float = 14.0, max_distance: float = 160.0, jitter: float = 0.05) -> bool:
	var stream := _pick_stream(id)
	if stream == null:
		return false
	var camera := _active_camera()
	var dist := 0.0
	if camera != null:
		dist = camera.global_position.distance_to(position)
		if dist > max_distance:
			return false
	if not _pass_cooldown(id, _game_clock):
		return false
	var player := _claim_3d(position, dist, camera)
	if player == null:
		return false
	var final_pitch := clampf(pitch * _rng.randf_range(1.0 - jitter, 1.0 + jitter), 0.38, 2.4)
	player.stream = stream
	player.global_position = position
	player.volume_db = volume_db
	player.pitch_scale = final_pitch
	player.unit_size = maxf(unit_size, 0.01)
	player.max_distance = maxf(max_distance, 0.1)
	player.play()
	_record_event(id, position, volume_db, final_pitch, true)
	return true


# ---------------------------------------------------------------------------
# High-Level Domain Sound Helpers
# ---------------------------------------------------------------------------

func _giant_pitch_for_height(height: float) -> float:
	# 25.2m reference -> 1.0; 3m -> ~1.55; 200m -> ~0.56; 500m -> ~0.46
	return clampf(pow(25.2 / maxf(height, 0.35), 0.28), 0.45, 1.85)


func play_giant_footfall(position: Vector3, height: float, is_player: bool = false) -> bool:
	var pitch := _giant_pitch_for_height(height) * 0.86
	var size_boost := clampf(log(maxf(height, 0.5) / 25.2) * 2.4, -10.0, 3.5)
	var volume := -2.5 + size_boost + (1.5 if is_player else 0.0)
	var unit_size := clampf(height * 1.3, 3.0, 240.0)
	var max_distance := clampf(height * 8.5, 28.0, 1400.0)
	return play_3d(&"giant_footfall", position, volume, pitch, unit_size, max_distance, 0.05)


func play_giant_impact(position: Vector3, height: float, is_player: bool = false) -> bool:
	var pitch := _giant_pitch_for_height(height)
	var size_boost := clampf(log(maxf(height, 1.0) / 25.2) * 1.6, -4.5, 3.5)
	var volume := 0.5 + size_boost + (1.5 if is_player else 0.0)
	var unit_size := clampf(height * 1.5, 10.0, 240.0)
	var max_distance := clampf(height * 9.5, 75.0, 1400.0)
	return play_3d(&"giant_stomp", position, volume, pitch, unit_size, max_distance, 0.06)


func play_desk_hazard_warn(position: Vector3) -> bool:
	# Low-frequency sky-filling rumble + deep warning tone for ultra-giant desk hazards.
	var played_rumble := play_2d(&"camera_shake_heavy", -6.0, 0.46, 0.03)
	var played_warn := play_3d(&"stomp_warn", position, -2.5, 0.46, 260.0, 2400.0, 0.03)
	return played_rumble or played_warn


func play_desk_hazard_whoosh(position: Vector3) -> bool:
	return play_3d(&"hand_whoosh", position, -1.5, 0.44, 240.0, 2200.0, 0.04)


func play_desk_hazard_impact(position: Vector3) -> bool:
	var played_stomp := play_3d(&"giant_stomp", position, 1.5, 0.40, 320.0, 2600.0, 0.04)
	var played_crush := play_3d(&"hand_crush", position, -1.0, 0.44, 280.0, 2400.0, 0.04)
	return played_stomp or played_crush


func play_camera_shake(intensity: float, source_height: float = 25.2) -> bool:
	if intensity <= 0.005:
		return false
	var elapsed := _game_clock - _last_shake_time
	if elapsed < 0.14 and intensity <= _last_shake_intensity * 1.45:
		return false
	var heavy := intensity >= 0.55
	var stream := _pick_stream(&"camera_shake_heavy" if heavy else &"camera_shake_light")
	if stream == null:
		return false
	var player := _claim_2d(_shake_pool)
	var norm := clampf(intensity / 1.15, 0.0, 1.4)
	var vol_db := lerpf(-18.0, -1.5, clampf(pow(norm, 0.55), 0.0, 1.0))
	var base_pitch := clampf(pow(25.2 / maxf(source_height, 1.0), 0.22), 0.65, 1.35)
	if heavy:
		base_pitch *= 0.94
	var final_pitch := clampf(base_pitch * _rng.randf_range(0.96, 1.04), 0.55, 1.45)
	player.stream = stream
	player.volume_db = vol_db
	player.pitch_scale = final_pitch
	player.play()
	_last_shake_time = _game_clock
	_last_shake_intensity = intensity
	_record_event(&"camera_shake", Vector3.ZERO, vol_db, final_pitch, false)
	return true


func play_hand_action(kind: StringName, position: Vector3, height: float) -> bool:
	var id: StringName
	var base_db := -1.5
	var dist_mult := 7.0
	match kind:
		&"whoosh":
			id = &"hand_whoosh"
			base_db = -4.0
			dist_mult = 5.5
		&"grab":
			id = &"hand_grab"
			base_db = -2.5
			dist_mult = 6.0
		&"punch":
			id = &"hand_punch"
			base_db = 0.0
			dist_mult = 8.5
		&"crush":
			id = &"hand_crush"
			base_db = 0.5
			dist_mult = 8.5
		_:
			return false
	var pitch := _giant_pitch_for_height(height)
	var unit_sz := clampf(height * 1.15, 8.0, 180.0)
	var max_dist := clampf(height * dist_mult, 60.0, 1100.0)
	return play_3d(id, position, base_db, pitch, unit_sz, max_dist, 0.06)


func play_building_event(kind: StringName, position: Vector3, footprint_height: float = 12.0) -> bool:
	var scale_pitch := clampf(pow(14.0 / maxf(footprint_height, 3.0), 0.18), 0.72, 1.25)
	match kind:
		&"crack":
			return play_3d(&"building_crack", position, -2.5, scale_pitch, 18.0, 210.0, 0.07)
		&"collapse":
			return play_3d(&"building_collapse", position, -0.5, scale_pitch, 28.0, 360.0, 0.07)
		&"barrier_break":
			return play_3d(&"barrier_break", position, -2.0, 1.0, 16.0, 160.0, 0.08)
		&"restore":
			return play_3d(&"building_restore", position, -7.5, scale_pitch, 14.0, 120.0, 0.04)
	return false


func play_human_step(position: Vector3, sprinting: bool, height: float = 1.8, is_player: bool = false) -> bool:
	var pitch := clampf(pow(1.8 / maxf(height, 0.01), 0.14), 0.80, 1.55)
	if sprinting:
		pitch *= 1.12
	var vol := (-8.5 if sprinting else -12.0) if is_player else -14.5
	if is_player:
		return play_2d(&"human_step", vol, pitch, 0.07)
	var unit_sz := clampf(height * 2.4, 0.25, 8.0)
	var max_dist := clampf(height * 14.0, 3.0, 34.0)
	return play_3d(&"human_step", position, vol, pitch, unit_sz, max_dist, 0.07)


func play_bedroom_step() -> bool:
	return play_2d(&"bedroom_step", -10.0, 1.08, 0.08)


func play_bedroom_climb() -> bool:
	return play_2d(&"bedroom_climb", -10.5, 1.0, 0.09)


func play_bedroom_mantle() -> bool:
	return play_2d(&"bedroom_mantle", -7.5, 1.04, 0.05)


func play_coin_pickup(is_player: bool, position: Vector3 = Vector3.ZERO) -> bool:
	if is_player:
		if _game_clock - _last_coin_time <= 1.65:
			_coin_streak = mini(_coin_streak + 1, 8)
		else:
			_coin_streak = 0
		_last_coin_time = _game_clock
		var pitch := 1.0 + float(_coin_streak) * 0.04
		return play_2d(&"coin_pickup", -3.5, pitch, 0.02)
	return play_3d(&"coin_pickup", position, -12.0, 0.96, 6.0, 48.0, 0.04)


## Rising tick while the player's dwell bar fills on a risk-tiered coin.
## Pitch climbs with the collection progress so the last second feels earned.
func play_coin_dwell_tick(progress: float) -> bool:
	var pitch := 0.82 + clampf(progress, 0.0, 1.0) * 0.55
	return play_2d(&"coin_dwell_tick", -15.0, pitch, 0.06)


func play_coin_drop(position: Vector3, height: float = 50.0) -> bool:
	var pitch := clampf(pow(50.0 / maxf(height, 10.0), 0.15), 0.72, 1.25)
	return play_3d(&"coin_drop", position, -2.0, pitch, clampf(height * 0.8, 16.0, 120.0), clampf(height * 4.5, 120.0, 650.0), 0.05)


func play_growth_surge() -> bool:
	return play_2d(&"growth_surge", -6.5, 1.0, 0.04)


func play_transform_giant() -> bool:
	return play_2d(&"transform_giant", -1.5, 1.0, 0.01)


func play_unlock_milestone() -> bool:
	return play_2d(&"unlock_milestone", -3.0, 1.0, 0.01)


func play_combat_hit(is_player_attacker: bool, is_player_victim: bool,
		victim_pos: Vector3, victim_height: float) -> bool:
	var played := false
	if is_player_attacker:
		played = play_2d(&"hit_confirm", -2.5, 1.0, 0.05) or played
	if is_player_victim:
		var pitch := _giant_pitch_for_height(victim_height)
		played = play_2d(&"giant_hurt", -1.5, pitch, 0.04) or played
	else:
		var pitch := _giant_pitch_for_height(victim_height)
		var unit_sz := clampf(victim_height * 1.1, 8.0, 140.0)
		var max_dist := clampf(victim_height * 6.5, 55.0, 700.0)
		played = play_3d(&"giant_hurt", victim_pos, -3.5, pitch, unit_sz, max_dist, 0.06) or played
	return played


func play_defeat(is_player_attacker: bool, is_player_victim: bool,
		victim_pos: Vector3, victim_height: float) -> bool:
	if is_player_victim:
		return play_2d(&"player_defeated", -1.0, 1.0, 0.02)
	if is_player_attacker:
		return play_2d(&"kill_confirm", -2.0, 1.0, 0.03)
	var pitch := _giant_pitch_for_height(victim_height)
	return play_3d(&"giant_hurt", victim_pos, -4.0, pitch * 0.82, clampf(victim_height * 1.2, 10.0, 160.0), clampf(victim_height * 7.0, 65.0, 800.0), 0.04)


# ---------------------------------------------------------------------------
# Inspection / Test Helpers
# ---------------------------------------------------------------------------

func reset_telemetry() -> void:
	play_counts.clear()
	last_events.clear()
	_last_played.clear()
	_coin_streak = 0
	_last_coin_time = -10.0
	_last_shake_time = -10.0
	_last_shake_intensity = 0.0


func stream_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for id: StringName in _streams:
		ids.append(String(id))
	return ids


func ambience_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for id: StringName in _ambience_streams:
		ids.append(String(id))
	return ids


func get_stream(id: StringName) -> AudioStream:
	if _streams.has(id):
		return _streams[id][0]
	if _ambience_streams.has(id):
		return _ambience_streams[id]
	return null


func count_played(id: StringName) -> int:
	return int(play_counts.get(id, 0))


# ---------------------------------------------------------------------------
# Internal Helpers
# ---------------------------------------------------------------------------

func _pick_stream(id: StringName) -> AudioStream:
	if not _streams.has(id):
		return null
	var list: Array = _streams[id]
	if list.size() == 1:
		return list[0]
	var cursor := int(_variant_cursor.get(id, 0))
	_variant_cursor[id] = (cursor + 1) % list.size()
	return list[cursor]


func _pass_cooldown(id: StringName, clock: float) -> bool:
	var min_gap := float(COOLDOWNS.get(id, 0.0))
	if min_gap <= 0.0:
		return true
	var prev := float(_last_played.get(id, -1000.0))
	if clock - prev < min_gap:
		return false
	_last_played[id] = clock
	return true


func _claim_2d(pool: Array[AudioStreamPlayer]) -> AudioStreamPlayer:
	for p in pool:
		if not p.playing:
			return p
	var oldest := pool[0]
	var best_pos := -1.0
	for p in pool:
		var pos := p.get_playback_position()
		if pos > best_pos:
			best_pos = pos
			oldest = p
	return oldest


func _claim_3d(position: Vector3, new_dist: float, camera: Camera3D) -> AudioStreamPlayer3D:
	for p in _sfx_3d_pool:
		if not p.playing:
			return p
	# Steal the farthest active 3D voice if the new sound is closer (or oldest if no camera).
	var candidate: AudioStreamPlayer3D = null
	var worst_dist := new_dist
	if camera == null:
		return _sfx_3d_pool[0]
	var cam_pos := camera.global_position
	for p in _sfx_3d_pool:
		var d := cam_pos.distance_to(p.global_position)
		if d > worst_dist:
			worst_dist = d
			candidate = p
	return candidate


func _active_camera() -> Camera3D:
	var vp := get_viewport()
	return vp.get_camera_3d() if vp != null else null


func _record_event(id: StringName, position: Vector3, volume_db: float, pitch: float, spatial: bool) -> void:
	play_counts[id] = int(play_counts.get(id, 0)) + 1
	last_events.append({
		"id": id,
		"position": position,
		"volume_db": volume_db,
		"pitch": pitch,
		"spatial": spatial,
	})
	if last_events.size() > TELEMETRY_LIMIT:
		last_events.pop_front()
