extends RefCounted
## Zero-extra-light, zero-extra-draw-call night illumination for the 1,586 harbour buildings
## and batched streetlamps.
##
## Works by inspecting each Kenney kit's shared `colormap.png` palette at runtime to build a
## nearest-filtered window/lens emission mask (guaranteeing zero wall/roof bleed), and sharing
## lightweight GL-Compatibility spatial ShaderMaterials across all batched Near/Far building
## MultiMeshes, the 12 core hero buildings, and the two streetlamp MultiMeshes.

const NEAR_GLASS_SWATCHES := {
	"commercial": Vector2i(5, 1),
	"industrial": Vector2i(4, 3),
	"suburban": Vector2i(5, 1),
}
const LAMP_LENS_SWATCH := Vector2i(4, 2)
const MASK_SIZE := 128

## Shared GLSL world-space looming shadow cast over the southern harbour by the
## seated ultra-giant Yumeka leaning over the desktop sandbox (+Z side). Darkens
## ALBEDO only so night window/streetlamp EMISSION stays 100% crisp.
const _GIANT_SHADOW_UNIFORMS := """
uniform vec4 giant_shadow_params = vec4(0.0, 0.0, 709.0, 0.0);
uniform vec3 giant_shadow_tint : source_color = vec3(0.41, 0.51, 0.68);
"""

const _GIANT_SHADOW_FN := """
vec3 apply_giant_shadow(vec3 albedo, vec3 world_pos, vec4 params, vec3 tint) {
	if (params.x <= 0.001) {
		return albedo;
	}
	float inv_half = 1.0 / max(params.z, 1.0);
	vec2 u = world_pos.xz * inv_half;
	float pulse = params.y;
	// Broad torso/shoulders canopy over the southern waterfront (+Z)
	vec2 d_torso = (u - vec2(0.0, 1.04 + pulse * 0.025)) / vec2(0.98, 0.72);
	float m_torso = exp(-dot(d_torso, d_torso) * 1.35);
	// Looming head & hair overhang reaching into south-central downtown
	vec2 d_head = (u - vec2(0.0, 0.44 + pulse * 0.035)) / vec2(0.56, 0.54);
	float m_head = exp(-dot(d_head, d_head) * 1.45);
	// Soft forearm/sleeve shadows flanking the east & west southern desk edges
	vec2 d_al = (u - vec2(-0.92, 0.46 + pulse * 0.018)) / vec2(0.36, 0.56);
	vec2 d_ar = (u - vec2( 0.92, 0.46 + pulse * 0.018)) / vec2(0.36, 0.56);
	float m_arms = max(exp(-dot(d_al, d_al) * 1.55), exp(-dot(d_ar, d_ar) * 1.55)) * 0.72;
	float cov = clamp(1.0 - (1.0 - m_torso * 0.92) * (1.0 - m_head * 0.94) * (1.0 - m_arms), 0.0, 1.0);
	// Tall skyscraper crowns keep slightly more sky bounce than deep street canyons
	float h_fade = 1.0 - clamp((world_pos.y - 24.0) / 160.0, 0.0, 0.22);
	float shade = clamp(cov * params.x * (1.0 + 0.05 * pulse) * h_fade, 0.0, 0.85);
	return albedo * mix(vec3(1.0), tint, shade);
}
"""

static var _night_glow := 0.0
static var _giant_shadow_strength := 0.0
static var _giant_shadow_pulse := 0.0
static var _giant_shadow_half_extent := 709.0
static var _giant_shadow_tint := Color(0.41, 0.51, 0.68)

static var _near_shader: Shader
static var _far_tex_shader: Shader
static var _far_box_shader: Shader
static var _lamp_shader: Shader
static var _surface_shaders: Dictionary = {} # key -> Shader
static var _near_mats: Dictionary = {}   # kit -> ShaderMaterial
static var _far_tex_mat: ShaderMaterial
static var _far_box_mat: ShaderMaterial
static var _lamp_mat: ShaderMaterial
static var _surface_mats: Dictionary = {} # cache key -> ShaderMaterial
static var _masks: Dictionary = {}       # key -> ImageTexture


static func set_night_glow(level: float) -> void:
	_night_glow = clampf(level, 0.0, 1.0)
	for mat: ShaderMaterial in _near_mats.values():
		mat.set_shader_parameter(&"night_glow", _night_glow)
	if _far_tex_mat != null:
		_far_tex_mat.set_shader_parameter(&"night_glow", _night_glow)
	if _far_box_mat != null:
		_far_box_mat.set_shader_parameter(&"night_glow", _night_glow)
	if _lamp_mat != null:
		_lamp_mat.set_shader_parameter(&"night_glow", _night_glow)


static func get_night_glow() -> float:
	return _night_glow


static func set_giant_shadow(strength: float, tint: Color) -> void:
	_giant_shadow_strength = clampf(strength, 0.0, 1.0)
	_giant_shadow_tint = tint
	_push_giant_shadow_uniforms()


static func set_giant_shadow_pulse(breath_lift: float) -> void:
	_giant_shadow_pulse = clampf(breath_lift, -1.0, 1.0)
	_push_giant_shadow_uniforms()


static func set_giant_shadow_half_extent(half_extent: float) -> void:
	_giant_shadow_half_extent = maxf(half_extent, 1.0)
	_push_giant_shadow_uniforms()


static func get_giant_shadow_strength() -> float:
	return _giant_shadow_strength


static func get_giant_shadow_pulse() -> float:
	return _giant_shadow_pulse


static func _giant_shadow_vec() -> Vector4:
	return Vector4(_giant_shadow_strength, _giant_shadow_pulse, _giant_shadow_half_extent, 0.0)


static func _apply_shadow_params(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter(&"giant_shadow_params", _giant_shadow_vec())
	mat.set_shader_parameter(&"giant_shadow_tint", _giant_shadow_tint)


static func _push_giant_shadow_uniforms() -> void:
	var params := _giant_shadow_vec()
	for mat: ShaderMaterial in _near_mats.values():
		mat.set_shader_parameter(&"giant_shadow_params", params)
		mat.set_shader_parameter(&"giant_shadow_tint", _giant_shadow_tint)
	if _far_tex_mat != null:
		_far_tex_mat.set_shader_parameter(&"giant_shadow_params", params)
		_far_tex_mat.set_shader_parameter(&"giant_shadow_tint", _giant_shadow_tint)
	if _far_box_mat != null:
		_far_box_mat.set_shader_parameter(&"giant_shadow_params", params)
		_far_box_mat.set_shader_parameter(&"giant_shadow_tint", _giant_shadow_tint)
	if _lamp_mat != null:
		_lamp_mat.set_shader_parameter(&"giant_shadow_params", params)
		_lamp_mat.set_shader_parameter(&"giant_shadow_tint", _giant_shadow_tint)
	for mat: ShaderMaterial in _surface_mats.values():
		mat.set_shader_parameter(&"giant_shadow_params", params)
		mat.set_shader_parameter(&"giant_shadow_tint", _giant_shadow_tint)


## Wraps a static ground/road/lot/tree/frame StandardMaterial3D in a cached GL-Compatibility
## ShaderMaterial that preserves its albedo/normal/roughness/metallic/detail grain while
## receiving Yumeka's zero-draw-call, zero-Z-fighting world-space looming shadow.
static func shadowed_surface_material(source: Material, detail_tex: Texture2D = null) -> Material:
	var std := source as StandardMaterial3D
	if std == null:
		return source
	var key := "%d|%d" % [std.get_instance_id(), detail_tex.get_instance_id() if detail_tex != null else 0]
	if _surface_mats.has(key):
		return _surface_mats[key]
	var has_tex := std.albedo_texture != null
	var has_nrm := std.normal_enabled and std.normal_texture != null
	var has_detail := detail_tex != null
	var cull_disabled := (std.cull_mode == BaseMaterial3D.CULL_DISABLED)
	var mat := ShaderMaterial.new()
	mat.shader = _get_surface_shader(has_tex, has_nrm, has_detail, cull_disabled)
	mat.set_shader_parameter(&"albedo_col", std.albedo_color)
	mat.set_shader_parameter(&"roughness_val", std.roughness)
	mat.set_shader_parameter(&"metallic_val", std.metallic)
	if has_tex:
		mat.set_shader_parameter(&"albedo_tex", std.albedo_texture)
	if has_nrm:
		mat.set_shader_parameter(&"normal_tex", std.normal_texture)
		mat.set_shader_parameter(&"normal_scale", std.normal_scale)
	if has_detail:
		mat.set_shader_parameter(&"detail_tex", detail_tex)
	_apply_shadow_params(mat)
	_surface_mats[key] = mat
	return mat


static func _get_surface_shader(has_tex: bool, has_nrm: bool, has_detail: bool, cull_disabled: bool) -> Shader:
	var key := "%d_%d_%d_%d" % [int(has_tex), int(has_nrm), int(has_detail), int(cull_disabled)]
	if _surface_shaders.has(key):
		return _surface_shaders[key]
	var sh := Shader.new()
	var render_line := "render_mode cull_disabled;\n" if cull_disabled else ""
	var decls := ""
	if has_tex:
		decls += "uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;\n"
	if has_nrm:
		decls += "uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;\n"
		decls += "uniform float normal_scale = 1.0;\n"
	if has_detail:
		decls += "uniform sampler2D detail_tex : source_color, filter_linear_mipmap, repeat_enable;\n"
	var tex_line := "	col *= texture(albedo_tex, UV).rgb;\n" if has_tex else ""
	var detail_line := ""
	if has_detail:
		detail_line = "	col *= texture(detail_tex, v_world_pos.xz * 5.0).rgb;\n"
	var nrm_line := ""
	if has_nrm:
		nrm_line = "	NORMAL_MAP = texture(normal_tex, UV).rgb;\n\tNORMAL_MAP_DEPTH = normal_scale;\n"
	sh.code = """
shader_type spatial;
%suniform vec4 albedo_col : source_color = vec4(1.0);
uniform float roughness_val = 0.92;
uniform float metallic_val = 0.0;
%s%s
varying vec3 v_world_pos;
%s
void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 col = albedo_col.rgb;
%s%s	ALBEDO = apply_giant_shadow(col, v_world_pos, giant_shadow_params, giant_shadow_tint);
	ROUGHNESS = roughness_val;
	METALLIC = metallic_val;
	SPECULAR = 0.22;
%s}
""" % [render_line, decls, _GIANT_SHADOW_UNIFORMS, _GIANT_SHADOW_FN, tex_line, detail_line, nrm_line]
	_surface_shaders[key] = sh
	return sh


## Returns a shared night-aware ShaderMaterial for a Kenney kit building material
## (commercial / industrial / suburban), or null if `source` is not a kit colormap material.
static func near_building_material(source: Material) -> Material:
	var std := source as StandardMaterial3D
	if std == null or std.albedo_texture == null:
		return null
	var kit := _detect_building_kit(std.albedo_texture.resource_path)
	if kit == "":
		return null
	if _near_mats.has(kit):
		return _near_mats[kit]
	var mask := _build_colormap_mask(kit, std.albedo_texture, NEAR_GLASS_SWATCHES[kit], false)
	var mat := ShaderMaterial.new()
	mat.shader = _get_near_shader()
	mat.set_shader_parameter(&"albedo_tex", std.albedo_texture)
	mat.set_shader_parameter(&"window_mask", mask)
	mat.set_shader_parameter(&"night_glow", _night_glow)
	mat.set_shader_parameter(&"emission_strength", 2.85 if kit != "industrial" else 2.35)
	mat.set_shader_parameter(&"roughness_val", 0.86)
	_apply_shadow_params(mat)
	_near_mats[kit] = mat
	return mat


## Returns a shared night-aware ShaderMaterial for the 4 low-detail commercial far proxies.
static func far_textured_material(source: Material) -> Material:
	var std := source as StandardMaterial3D
	if std == null or std.albedo_texture == null:
		return null
	if _far_tex_mat == null:
		_far_tex_mat = ShaderMaterial.new()
		_far_tex_mat.shader = _get_far_shader(true)
		_far_tex_mat.set_shader_parameter(&"albedo_tex", std.albedo_texture)
		_far_tex_mat.set_shader_parameter(&"night_glow", _night_glow)
		_far_tex_mat.set_shader_parameter(&"emission_strength", 1.95)
		_apply_shadow_params(_far_tex_mat)
	return _far_tex_mat


## Returns a shared night-aware ShaderMaterial for the untextured box far proxy.
static func far_box_material() -> Material:
	if _far_box_mat == null:
		_far_box_mat = ShaderMaterial.new()
		_far_box_mat.shader = _get_far_shader(false)
		_far_box_mat.set_shader_parameter(&"night_glow", _night_glow)
		_far_box_mat.set_shader_parameter(&"emission_strength", 1.75)
		_apply_shadow_params(_far_box_mat)
	return _far_box_mat


## Returns a shared ShaderMaterial exclusively for batched streetlamps so only the bulb
## lens swatch (cell 4,2) lights up warm amber at dusk/night while poles stay matte grey.
static func streetlamp_material(source: Material) -> Material:
	var std := source as StandardMaterial3D
	if std == null or std.albedo_texture == null:
		return source
	if _lamp_mat == null:
		var mask := _build_colormap_mask("roads_lamp", std.albedo_texture, LAMP_LENS_SWATCH, true)
		_lamp_mat = ShaderMaterial.new()
		_lamp_mat.shader = _get_lamp_shader()
		_lamp_mat.set_shader_parameter(&"albedo_tex", std.albedo_texture)
		_lamp_mat.set_shader_parameter(&"lens_mask", mask)
		_lamp_mat.set_shader_parameter(&"night_glow", _night_glow)
		_lamp_mat.set_shader_parameter(&"emission_strength", 4.6)
		_apply_shadow_params(_lamp_mat)
	return _lamp_mat


static func debug_mask_coverage(kit: String) -> float:
	if not _masks.has(kit):
		return 0.0
	var tex: ImageTexture = _masks[kit]
	var img := tex.get_image()
	if img == null:
		return 0.0
	var lit := 0
	var total := img.get_width() * img.get_height()
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).r > 0.5:
				lit += 1
	return float(lit) / maxf(float(total), 1.0)


static func _detect_building_kit(path: String) -> String:
	var lower := path.to_lower()
	for kit: String in NEAR_GLASS_SWATCHES:
		if lower.contains("/kenney/" + kit + "/") or lower.contains(kit + "/textures/colormap"):
			return kit
	return ""


## Runtime pixel analysis of Kenney's 8x4 colormap palette: builds a crisp 128x128 binary
## emission mask where ONLY the verified glass (or streetlamp lens) pixels equal 1.0.
static func _build_colormap_mask(cache_key: String, tex: Texture2D, target_cell: Vector2i,
		is_lamp_lens: bool) -> ImageTexture:
	if _masks.has(cache_key):
		return _masks[cache_key]
	var mask_img := Image.create(MASK_SIZE, MASK_SIZE, false, Image.FORMAT_L8)
	var src_img: Image = tex.get_image()
	if src_img != null and src_img.is_compressed():
		src_img = src_img.duplicate() as Image
		src_img.decompress()
	var cell_w := MASK_SIZE / 8
	var cell_h := MASK_SIZE / 4
	var x0 := target_cell.x * cell_w
	var x1 := x0 + cell_w
	var y0 := target_cell.y * cell_h
	var y1 := y0 + cell_h
	var src_w := src_img.get_width() if src_img != null else 0
	var src_h := src_img.get_height() if src_img != null else 0
	for y in MASK_SIZE:
		for x in MASK_SIZE:
			var inside := (x >= x0 and x < x1 and y >= y0 and y < y1)
			var lit := false
			if inside:
				if src_img != null and src_w > 0 and src_h > 0:
					var sx := mini(src_w - 1, int((float(x) + 0.5) / float(MASK_SIZE) * float(src_w)))
					var sy := mini(src_h - 1, int((float(y) + 0.5) / float(MASK_SIZE) * float(src_h)))
					var c := src_img.get_pixel(sx, sy)
					if is_lamp_lens:
						# White/bright lens swatch in roads colormap.
						lit = c.r > 0.72 and c.g > 0.72 and c.b > 0.78
					else:
						# Sky-blue glass swatch in commercial/industrial/suburban colormaps.
						lit = c.b > 0.70 and (c.b - c.r) > 0.08 and c.g > 0.52
				else:
					lit = true
			mask_img.set_pixel(x, y, Color.WHITE if lit else Color.BLACK)
	var out := ImageTexture.create_from_image(mask_img)
	_masks[cache_key] = out
	return out


static func _get_near_shader() -> Shader:
	if _near_shader != null:
		return _near_shader
	_near_shader = Shader.new()
	_near_shader.code = """
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform sampler2D window_mask : filter_nearest;
uniform float night_glow = 0.0;
uniform float emission_strength = 2.15;
uniform float roughness_val = 0.86;
%s
varying vec3 v_world_pos;
varying vec3 v_world_nrm;
%s
float hash31(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.x + p.y) * p.z);
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec4 tex_col = texture(albedo_tex, UV);
	vec3 base_albedo = tex_col.rgb * COLOR.rgb;
	float mask = texture(window_mask, UV).r;
	ROUGHNESS = mix(roughness_val, 0.24, mask);
	METALLIC = 0.0;
	SPECULAR = mix(0.22, 0.45, mask);

	if (night_glow > 0.001 && mask > 0.5) {
		vec3 cell_size = vec3(3.1, 3.2, 3.1);
		vec3 cell = floor(v_world_pos / cell_size);
		vec3 f = fract(v_world_pos / cell_size);
		float h = hash31(cell);

		// Subtle architectural mullions on vertical curtain-wall windows (slim borders keep
		// small Kenney window panes evenly bright).
		float is_vertical = step(abs(v_world_nrm.y), 0.35);
		float horiz = abs(v_world_nrm.x) > 0.5 ? f.z : f.x;
		float pane_v = step(0.06, f.y) * step(f.y, 0.94);
		float pane_h = step(0.05, horiz) * step(horiz, 0.95);
		float pane = mix(0.88, pane_h * pane_v, is_vertical);

		vec3 glow_col;
		float lit = 1.0;
		if (h < 0.54) {
			glow_col = vec3(1.00, 0.76, 0.34); // Warm golden tungsten
		} else if (h < 0.78) {
			glow_col = vec3(1.00, 0.89, 0.62); // Soft warm cream-white
		} else if (h < 0.92) {
			glow_col = vec3(0.66, 0.86, 1.00); // Cool pale-blue office glow
		} else {
			glow_col = vec3(0.18, 0.26, 0.40); // Dim unlit glass
			lit = 0.14;
		}
		float intact = smoothstep(0.45, 0.90, COLOR.r);
		EMISSION = glow_col * (lit * pane * night_glow * emission_strength * mix(0.35, 1.0, intact));
		base_albedo = mix(base_albedo, base_albedo * 0.22, night_glow * (1.0 - lit * 0.65));
	}
	ALBEDO = apply_giant_shadow(base_albedo, v_world_pos, giant_shadow_params, giant_shadow_tint);
}
""" % [_GIANT_SHADOW_UNIFORMS, _GIANT_SHADOW_FN]
	return _near_shader


static func _get_far_shader(textured: bool) -> Shader:
	if textured and _far_tex_shader != null:
		return _far_tex_shader
	if not textured and _far_box_shader != null:
		return _far_box_shader
	var shader := Shader.new()
	var albedo_decl := "uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;\n" if textured else ""
	var albedo_expr := "texture(albedo_tex, UV).rgb * COLOR.rgb" if textured else "COLOR.rgb"
	shader.code = """
shader_type spatial;
render_mode cull_disabled;

%suniform float night_glow = 0.0;
uniform float emission_strength = 1.9;
%s
varying vec3 v_world_pos;
varying vec3 v_world_nrm;
%s
float hash31(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.x + p.y) * p.z);
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	ALBEDO = apply_giant_shadow(%s, v_world_pos, giant_shadow_params, giant_shadow_tint);
	ROUGHNESS = 0.90;
	METALLIC = 0.0;
	SPECULAR = 0.18;

	// Strictly vertical exterior walls above street floor: crisp procedural window grid
	// so distant skyline blocks match near kit buildings with zero roof/wall wash.
	if (night_glow > 0.001 && abs(v_world_nrm.y) < 0.22 && v_world_pos.y > 2.2) {
		float horiz_coord = abs(v_world_nrm.x) > 0.5 ? v_world_pos.z : v_world_pos.x;
		vec2 cell_sz = vec2(3.4, 3.6);
		vec2 gp = vec2(horiz_coord, v_world_pos.y) / cell_sz;
		vec2 gf = fract(gp);
		float win_x = step(0.24, gf.x) * step(gf.x, 0.76);
		float win_y = step(0.28, gf.y) * step(gf.y, 0.74);
		float aperture = win_x * win_y;
		if (aperture > 0.5) {
			vec3 cell_id = floor(v_world_pos / vec3(3.4, 3.6, 3.4));
			float h = hash31(cell_id);
			vec3 glow_col = vec3(0.0);
			float lit = 0.0;
			if (h < 0.42) {
				glow_col = vec3(1.00, 0.77, 0.38);
				lit = 1.0;
			} else if (h < 0.62) {
				glow_col = vec3(1.00, 0.90, 0.68);
				lit = 0.92;
			} else if (h < 0.75) {
				glow_col = vec3(0.68, 0.86, 1.00);
				lit = 0.85;
			}
			EMISSION = glow_col * (lit * night_glow * emission_strength);
		}
	}
}
""" % [albedo_decl, _GIANT_SHADOW_UNIFORMS, _GIANT_SHADOW_FN, albedo_expr]
	if textured:
		_far_tex_shader = shader
	else:
		_far_box_shader = shader
	return shader


static func _get_lamp_shader() -> Shader:
	if _lamp_shader != null:
		return _lamp_shader
	_lamp_shader = Shader.new()
	_lamp_shader.code = """
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform sampler2D lens_mask : filter_nearest;
uniform float night_glow = 0.0;
uniform float emission_strength = 3.6;
%s
varying vec3 v_world_pos;
%s
void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 col = texture(albedo_tex, UV).rgb;
	float mask = texture(lens_mask, UV).r;
	ALBEDO = apply_giant_shadow(col, v_world_pos, giant_shadow_params, giant_shadow_tint);
	ROUGHNESS = mix(0.62, 0.18, mask);
	METALLIC = mix(0.20, 0.0, mask);
	SPECULAR = 0.25;
	if (night_glow > 0.001 && mask > 0.5) {
		EMISSION = vec3(1.00, 0.80, 0.42) * (night_glow * emission_strength);
	}
}
""" % [_GIANT_SHADOW_UNIFORMS, _GIANT_SHADOW_FN]
	return _lamp_shader
