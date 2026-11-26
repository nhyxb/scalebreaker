extends Node
## Synchronized day/dusk/night atmosphere controller for both the main harbour scene
## (`Sun`, `Atmosphere`, `CityNightLights`) and the desktop bedroom skybox (`Skybox`).
##
## Modes:
##   "auto"  - continuous 24h cycle (paused when the game tree is paused)
##   "day"   - crisp warm miniature daylight (default)
##   "dusk"  - low golden-orange sunset with long shadows and early warm lights
##   "night" - cool moonlight harbour + glowing city windows/streetlamps + warm bedroom desk lamp
##
## Pressing F7 cycles day -> dusk -> night -> day immediately for live preview & captures.

const CityNightLights := preload("res://scenes/city_night_lights.gd")

const CYCLE_SECONDS := 180.0
const PHASE_DAY := 0.48
const PHASE_DUSK := 0.76
const PHASE_NIGHT := 0.96
const PREVIEW_CYCLE := ["day", "dusk", "night"]

var _mode := "day"
var _phase := PHASE_DAY
var _cycle_time := 0.0
var _weights := Vector3(1.0, 0.0, 0.0) # (day, dusk, night)
var _sun: DirectionalLight3D
var _env: Environment
var _sky_mat: ProceduralSkyMaterial
var _skybox: Node
var _auto_push_acc := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var parent := get_parent()
	if parent != null:
		_sun = parent.get_node_or_null("Sun") as DirectionalLight3D
		var we := parent.get_node_or_null("Atmosphere") as WorldEnvironment
		if we != null:
			_env = we.environment
			if _env != null and _env.sky != null:
				_sky_mat = _env.sky.sky_material as ProceduralSkyMaterial
		_skybox = parent.get_node_or_null("Skybox")
	_apply_now()


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	var is_f7 := (key.keycode == KEY_F7 or key.physical_keycode == KEY_F7)
	if key.pressed and not key.echo and is_f7 \
			and not key.ctrl_pressed and not key.alt_pressed and not key.meta_pressed:
		cycle_preview_mode()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _mode != "auto":
		return
	if get_tree().paused:
		return
	_cycle_time += delta
	_phase = fposmod(_phase + delta / CYCLE_SECONDS, 1.0)
	_auto_push_acc += delta
	# Smooth 20 Hz lighting updates in auto cycle keep CPU/SubViewport overhead tiny.
	if _auto_push_acc >= 0.05:
		_auto_push_acc = 0.0
		_apply_now()


func set_mode(next_mode: String) -> void:
	var clean := next_mode.strip_edges().to_lower()
	if clean not in ["auto", "day", "dusk", "night"]:
		clean = "day"
	_mode = clean
	match _mode:
		"day":
			_phase = PHASE_DAY
		"dusk":
			_phase = PHASE_DUSK
		"night":
			_phase = PHASE_NIGHT
	_apply_now()


func get_mode() -> String:
	return _mode


func cycle_preview_mode() -> String:
	var idx := PREVIEW_CYCLE.find(_mode)
	var next_mode: String = PREVIEW_CYCLE[(idx + 1) % PREVIEW_CYCLE.size()] if idx >= 0 else "dusk"
	set_mode(next_mode)
	return next_mode


func set_phase(normalized_phase: float) -> void:
	_phase = fposmod(normalized_phase, 1.0)
	_apply_now()


func get_phase() -> float:
	return _phase


func get_weights() -> Vector3:
	return _weights


func get_night_glow() -> float:
	return CityNightLights.get_night_glow()


func _weights_for_phase(p: float) -> Vector3:
	# Smooth periodic 24h weights:
	#   0.26..0.64 -> full day
	#   0.64..0.76 -> day -> dusk, 0.76..0.88 -> dusk -> night
	#   0.88..1.00 & 0.00..0.14 -> full night
	#   0.14..0.20 -> night -> warm dawn (reuses dusk golden palette), 0.20..0.28 -> dawn -> day
	var x := fposmod(p, 1.0)
	var d := 0.0
	var u := 0.0
	var n := 0.0
	if x >= 0.28 and x <= 0.64:
		d = 1.0
	elif x > 0.64 and x < 0.76:
		var t := smoothstep(0.64, 0.76, x)
		d = 1.0 - t
		u = t
	elif x >= 0.76 and x < 0.88:
		var t := smoothstep(0.76, 0.88, x)
		u = 1.0 - t
		n = t
	elif x >= 0.88 or x <= 0.14:
		n = 1.0
	elif x > 0.14 and x < 0.21:
		var t := smoothstep(0.14, 0.21, x)
		n = 1.0 - t
		u = t
	else:
		var t := smoothstep(0.21, 0.28, x)
		u = 1.0 - t
		d = t
	return Vector3(d, u, n)


func _apply_now() -> void:
	match _mode:
		"day":
			_weights = Vector3(1.0, 0.0, 0.0)
		"dusk":
			_weights = Vector3(0.0, 1.0, 0.0)
		"night":
			_weights = Vector3(0.0, 0.0, 1.0)
		_:
			_weights = _weights_for_phase(_phase)

	var d := _weights.x
	var u := _weights.y
	var n := _weights.z

	# 1. Main world directional Sun (crisp warm daylight -> low golden dusk -> cool moonlight).
	if _sun != null:
		var rot_day := Vector3(-42.0, -36.0, 0.0)
		var rot_dusk := Vector3(-15.0, -70.0, 0.0)
		var rot_night := Vector3(-34.0, 32.0, 0.0)
		_sun.rotation_degrees = rot_day * d + rot_dusk * u + rot_night * n
		_sun.light_color = Color(1.0, 0.94, 0.85) * d \
				+ Color(1.0, 0.56, 0.28) * u \
				+ Color(0.60, 0.72, 0.96) * n
		_sun.light_energy = 0.98 * d + 0.92 * u + 0.46 * n
		_sun.shadow_opacity = 0.68 * d + 0.76 * u + 0.52 * n

	# 2. Main world Environment ambient, sky hemisphere & fog tint (never touch BG_CANVAS or fog density).
	if _sky_mat != null:
		_sky_mat.sky_top_color = Color(0.40, 0.65, 0.92) * d \
				+ Color(0.32, 0.34, 0.56) * u \
				+ Color(0.16, 0.21, 0.36) * n
		_sky_mat.sky_horizon_color = Color(0.86, 0.89, 0.92) * d \
				+ Color(0.95, 0.56, 0.34) * u \
				+ Color(0.38, 0.36, 0.46) * n
		_sky_mat.ground_bottom_color = Color(0.46, 0.44, 0.40) * d \
				+ Color(0.28, 0.22, 0.24) * u \
				+ Color(0.36, 0.30, 0.28) * n
		_sky_mat.ground_horizon_color = Color(0.76, 0.74, 0.69) * d \
				+ Color(0.68, 0.42, 0.30) * u \
				+ Color(0.38, 0.33, 0.36) * n

	if _env != null:
		_env.ambient_light_color = Color(0.66, 0.78, 0.94) * d \
				+ Color(0.70, 0.52, 0.62) * u \
				+ Color(0.50, 0.48, 0.58) * n
		_env.ambient_light_energy = 0.44 * d + 0.40 * u + 0.78 * n
		_env.fog_light_color = Color(0.86, 0.88, 0.90) * d \
				+ Color(0.88, 0.56, 0.38) * u \
				+ Color(0.10, 0.15, 0.28) * n
		_env.fog_light_energy = 0.95 * d + 0.85 * u + 0.45 * n
		_env.tonemap_exposure = 0.96 * d + 0.98 * u + 1.06 * n

	# 3. City-wide window & streetlamp emissive glow (zero extra dynamic lights).
	var night_glow := clampf(u * 0.38 + n * 1.0, 0.0, 1.0)
	CityNightLights.set_night_glow(night_glow)

	# 4. Bedroom skybox synchronization (north window sky, sunset sun, auto warm desk lamp).
	if _skybox != null and _skybox.has_method(&"apply_day_night"):
		_skybox.call(&"apply_day_night", d, u, n, _cycle_time)
