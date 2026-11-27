extends Node
## Synchronized day/dusk/night atmosphere controller for the unified single-world scene:
##   - Main `Atmosphere` (`BG_SKY` dynamic sky shader with daytime clouds, sunset glow &
##     twinkling stars visible directly through the bedroom's north window + unified AGX
##     exposure & ambient hemisphere),
##   - Layer 1 city `Sun` + `CityNightLights` (zero extra dynamic city lights),
##   - Layer 2 bedroom lights & props via `Skybox.apply_day_night()`.
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
var _sky_mat: ShaderMaterial
var _skybox: Node
var _auto_push_acc := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var parent := get_parent()
	if parent != null:
		_sun = parent.get_node_or_null("Sun") as DirectionalLight3D
		if _sun != null:
			_sun.light_cull_mask = 1
		var we := parent.get_node_or_null("Atmosphere") as WorldEnvironment
		if we != null:
			_env = we.environment
			if _env != null:
				_env.background_mode = Environment.BG_SKY
				_install_dynamic_sky()
		_skybox = parent.get_node_or_null("Skybox")
	_apply_now()


func _install_dynamic_sky() -> void:
	var sky_shader := Shader.new()
	sky_shader.code = """
shader_type sky;

uniform vec3 sky_top : source_color = vec3(0.19, 0.50, 0.90);
uniform vec3 sky_mid : source_color = vec3(0.48, 0.76, 0.97);
uniform vec3 sky_horizon : source_color = vec3(0.88, 0.93, 0.97);
uniform vec3 ground_color : source_color = vec3(0.74, 0.84, 0.93);
uniform vec3 sun_dir = vec3(0.22, 0.16, -0.96);
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.84);
uniform float sun_strength = 0.78;
uniform vec3 cloud_color : source_color = vec3(1.0, 0.995, 0.985);
uniform float cloud_opacity = 0.62;
uniform float star_strength = 0.0;
uniform float cloud_drift = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	v += 0.55 * vnoise(p);
	v += 0.30 * vnoise(p * 2.13 + vec2(3.7, 1.9));
	v += 0.15 * vnoise(p * 4.41 + vec2(8.2, 5.1));
	return v;
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	// Bias the effective sky horizon slightly downward (upper-floor bedroom viewpoint) so
	// looking straight through the north window always shows expansive sky, clouds, and stars.
	float y = dir.y + 0.16;
	vec3 col;
	if (y >= 0.0) {
		float t_mid = smoothstep(0.0, 0.22, y);
		float t_top = smoothstep(0.14, 0.70, y);
		col = mix(sky_horizon, sky_mid, t_mid);
		col = mix(col, sky_top, t_top);
	} else {
		col = mix(sky_horizon, ground_color, smoothstep(0.0, -0.35, y));
	}

	// Soft sun / sunset / moon halo visible through the north window.
	vec3 sdir = normalize(sun_dir);
	float sdot = max(dot(dir, sdir), 0.0);
	float halo = pow(sdot, 8.0) * 0.45 + pow(sdot, 54.0) * 0.68;
	float disc = smoothstep(0.9965, 0.9992, sdot) * 1.15;
	col += sun_color * (halo + disc) * sun_strength * smoothstep(-0.08, 0.06, y);

	// Airy sunlit / sunset clouds visible cleanly across the window panes.
	if (y > 0.02 && cloud_opacity > 0.01) {
		vec2 cp = dir.xz / (y + 0.20) * 0.72 + vec2(cloud_drift, cloud_drift * 0.35);
		float n = fbm(cp * vec2(1.10, 1.75));
		float mask = smoothstep(0.43, 0.70, n) * smoothstep(0.02, 0.16, y) * smoothstep(0.95, 0.38, y);
		vec3 lit_cloud = cloud_color + sun_color * pow(sdot, 4.0) * 0.24 * sun_strength;
		col = mix(col, lit_cloud, clamp(mask * cloud_opacity, 0.0, 0.88));
	}

	// Crisp twinkling starfield at dusk/night across all window panes.
	if (y > 0.02 && star_strength > 0.01) {
		vec2 sp = dir.xz / (y + 0.26) * 44.0;
		vec2 cell = floor(sp);
		vec2 f = fract(sp) - 0.5;
		float rnd = hash21(cell);
		if (rnd > 0.962) {
			vec2 off = vec2(hash21(cell + 17.3), hash21(cell + 53.7)) - 0.5;
			float d = length(f - off * 0.52);
			float star = smoothstep(0.20, 0.02, d) * smoothstep(0.02, 0.14, y);
			float twinkle = 0.72 + 0.28 * sin(rnd * 62.0 + cloud_drift * 14.0);
			col += vec3(0.90, 0.94, 1.0) * star * twinkle * star_strength * 1.45;
		}
	}

	COLOR = col;
}
"""
	_sky_mat = ShaderMaterial.new()
	_sky_mat.shader = sky_shader
	var sky := Sky.new()
	sky.sky_material = _sky_mat
	_env.sky = sky


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


func get_giant_shadow_strength() -> float:
	return CityNightLights.get_giant_shadow_strength()


func get_sky_shader_material() -> ShaderMaterial:
	return _sky_mat


func _weights_for_phase(p: float) -> Vector3:
	# Smooth periodic 24h weights:
	#   0.28..0.64 -> full day
	#   0.64..0.76 -> day -> dusk, 0.76..0.88 -> dusk -> night
	#   0.88..1.00 & 0.00..0.14 -> full night
	#   0.14..0.21 -> night -> warm dawn (reuses dusk golden palette), 0.21..0.28 -> dawn -> day
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

	# 1. Layer 1 main-world city Sun (crisp warm daylight -> low golden dusk -> cool moonlight).
	if _sun != null:
		_sun.light_cull_mask = 1
		var rot_day := Vector3(-42.0, -36.0, 0.0)
		var rot_dusk := Vector3(-15.0, -70.0, 0.0)
		var rot_night := Vector3(-34.0, 32.0, 0.0)
		_sun.rotation_degrees = rot_day * d + rot_dusk * u + rot_night * n
		_sun.light_color = Color(1.0, 0.94, 0.85) * d \
				+ Color(1.0, 0.56, 0.28) * u \
				+ Color(0.56, 0.70, 0.98) * n
		_sun.light_energy = 0.98 * d + 0.92 * u + 0.44 * n
		_sun.shadow_opacity = 0.68 * d + 0.76 * u + 0.52 * n

	# 2. Unified dynamic sky shader (visible directly through the bedroom's north window)
	#    plus main WorldEnvironment ambient & fog tint (never touches fog density).
	if _sky_mat != null:
		var top_col := Color(0.19, 0.50, 0.90) * d + Color(0.18, 0.21, 0.44) * u + Color(0.025, 0.045, 0.13) * n
		var mid_col := Color(0.48, 0.76, 0.97) * d + Color(0.86, 0.44, 0.38) * u + Color(0.055, 0.095, 0.22) * n
		var hor_col := Color(0.88, 0.93, 0.97) * d + Color(1.00, 0.58, 0.24) * u + Color(0.10, 0.15, 0.29) * n
		var gnd_col := Color(0.74, 0.84, 0.93) * d + Color(0.68, 0.42, 0.32) * u + Color(0.05, 0.08, 0.17) * n
		var sdir := (Vector3(0.22, 0.16, -0.96) * d + Vector3(0.24, 0.04, -0.97) * u + Vector3(-0.20, 0.14, -0.97) * n).normalized()
		var scol := Color(1.0, 0.96, 0.84) * d + Color(1.0, 0.62, 0.26) * u + Color(0.76, 0.86, 1.0) * n
		var sstr := 0.78 * d + 1.15 * u + 0.52 * n
		var ccol := Color(1.0, 0.995, 0.985) * d + Color(1.0, 0.76, 0.58) * u + Color(0.22, 0.30, 0.48) * n
		var cop := 0.62 * d + 0.60 * u + 0.18 * n
		var stars := 0.0 * d + 0.16 * u + 1.0 * n
		_sky_mat.set_shader_parameter(&"sky_top", top_col)
		_sky_mat.set_shader_parameter(&"sky_mid", mid_col)
		_sky_mat.set_shader_parameter(&"sky_horizon", hor_col)
		_sky_mat.set_shader_parameter(&"ground_color", gnd_col)
		_sky_mat.set_shader_parameter(&"sun_dir", sdir)
		_sky_mat.set_shader_parameter(&"sun_color", scol)
		_sky_mat.set_shader_parameter(&"sun_strength", sstr)
		_sky_mat.set_shader_parameter(&"cloud_color", ccol)
		_sky_mat.set_shader_parameter(&"cloud_opacity", cop)
		_sky_mat.set_shader_parameter(&"star_strength", stars)
		_sky_mat.set_shader_parameter(&"cloud_drift", _cycle_time * 0.02)

	if _env != null:
		_env.background_mode = Environment.BG_SKY
		_env.ambient_light_color = Color(0.80, 0.84, 0.91) * d \
				+ Color(0.76, 0.56, 0.60) * u \
				+ Color(0.24, 0.34, 0.58) * n
		_env.ambient_light_sky_contribution = 0.44 * d + 0.52 * u + 0.42 * n
		_env.ambient_light_energy = 0.42 * d + 0.38 * u + 0.54 * n
		_env.fog_light_color = Color(0.86, 0.88, 0.90) * d \
				+ Color(0.88, 0.56, 0.38) * u \
				+ Color(0.10, 0.15, 0.28) * n
		_env.fog_light_energy = 0.95 * d + 0.85 * u + 0.45 * n
		_env.tonemap_exposure = 0.96 * d + 0.98 * u + 1.04 * n

	# 3. City-wide window & streetlamp emissive glow (zero extra dynamic lights).
	var night_glow := clampf(u * 0.38 + n * 1.0, 0.0, 1.0)
	CityNightLights.set_night_glow(night_glow)

	# 3b. Ultra-giant looming shadow over the southern harbour (strongest in day/dusk,
	#     gently softened at night so city window lights stay crisp and un-dimmed).
	var yumeka_present: bool = _skybox != null and _skybox.has_method(&"is_yumeka_mounted") \
			and bool(_skybox.call(&"is_yumeka_mounted"))
	var shadow_strength := (0.66 * d + 0.70 * u + 0.26 * n) if yumeka_present else 0.0
	var shadow_tint := Color(0.41, 0.51, 0.68) * d \
			+ Color(0.38, 0.34, 0.58) * u \
			+ Color(0.56, 0.60, 0.76) * n
	CityNightLights.set_giant_shadow(shadow_strength, shadow_tint)

	# 4. Layer 2 bedroom lights & props synchronization (window sun, warm night desk lamp, monitor).
	if _skybox != null and _skybox.has_method(&"apply_day_night"):
		_skybox.call(&"apply_day_night", d, u, n, _cycle_time)
