extends Node3D
## 1:1 soft Japanese cream & light natural-wood bedroom mounted directly into the
## main 3D world by `scenes/harbor_skybox.gd` at the active tabletop scale (Vulkan
## mobile, 32-bit Reversed-Z). Uses real Kenney Furniture Kit GLB assets
## (assets/kenney/furniture/, visual-only, zero physics collision), an airtight CSG room
## shell with baseboards and a recessed sunlit two-pane window framed by sheer curtains,
## procedural wall art / corkboard / floating shelf / live desktop monitor texture, a
## desktop harbour sandbox, Layer 2 isolated
## interior lighting (window sun + interior bounce + ceiling fill + automatic warm night
## desk lamp), and an exported `ultra_giant_anchor` above the swivel chair cushion where
## the seated anime Yumeka mounts.

const FLOOR_WOOD_DIFF := "res://assets/textures/polyhaven/floor_wood_diff.jpg"
const FURNITURE_DIR := "res://assets/kenney/furniture/"
const YUMEKA_GLB := "res://assets/characters/yumeka/Yumeka_seated.glb"
const YumekaSeated := preload("res://scenes/yumeka_ultra_giant.gd")
## 1 m of harbour ↔ 0.15 mm of bedroom (1:6667). Kept in one place with `harbor_skybox.gd`.
const BEDROOM_SCALE := 6666.67
const SKY_SCALE := 1.0 / BEDROOM_SCALE
## Visual & light isolation layer for Bedroom + Yumeka (Layer 1 = city, Layer 2 = bedroom).
const BEDROOM_LAYER := 2
## Inner tray side for the default 1418 m harbour, in metres.
const SANDBOX_SIDE := 0.2127
## Matches `district_expansion.gd::_build_sandbox_frame()` default base depth (32 m -> 4.8 mm)
## so the main-world pale-wood diorama tray sits dead flush on `DESK_TOP` with zero parallax.
const SANDBOX_BASE_THICKNESS := 32.0 * SKY_SCALE

## Room shell in metres: north wall sits just behind the desk (z = ROOM_Z_MIN) so the sunlit
## window and desktop props frame the harbour skyline naturally from low city elevations.
const ROOM := Vector3(4.6, 2.6, 3.8)
const ROOM_Z_MIN := -0.54
const ROOM_Z_MAX := ROOM_Z_MIN + ROOM.z
const ROOM_Z_CENTER := (ROOM_Z_MIN + ROOM_Z_MAX) * 0.5
const WALL := 0.14
const DESK_TOP := 0.75
const DESK_MAT_THICKNESS := 0.0024

## Two-pane north window centred behind the desk.
const WIN_CENTER_X := -0.05
const WIN_WIDTH := 1.84
const WIN_SILL_Y := 0.94
const WIN_HEIGHT := 1.28
const DESK_LAMP_POSITION := Vector3(0.42, DESK_TOP + 0.34, -0.10)

## Uniform scale for chairDesk.glb (seat cushion top raw Y = 0.2335 -> 0.4553 m real metric).
const CHAIR_SCALE := 1.95
const CHAIR_RAW_SEAT_TOP_Y := 0.2335
const CHAIR_RAW_SEAT_CENTER_Z_OFFSET := 0.047

var _mat_wall: StandardMaterial3D
var _mat_ceiling: StandardMaterial3D
var _mat_floor: Material
var _mat_wood_trim: StandardMaterial3D
var _mat_sash: StandardMaterial3D
var _mat_door: StandardMaterial3D
var _mat_metal: StandardMaterial3D
var _window_glass_mat: StandardMaterial3D
var _desk_lamp_shade_mat: StandardMaterial3D
var _ceiling_lamp_shade_mat: StandardMaterial3D
var _monitor_mat: StandardMaterial3D
var _curtain_mat: StandardMaterial3D

var _window_sun: DirectionalLight3D
var _interior_bounce: DirectionalLight3D
var _ceiling_fill: OmniLight3D
var _desk_lamp_light: OmniLight3D
var _lights: Node3D
var _render_scale := BEDROOM_SCALE
var _light_weights := Vector3(1.0, 0.0, 0.0)
var _sandbox_shadow: MeshInstance3D
var _desk_half_depth := 0.0

var sandbox_anchor: Node3D
## Anchor perched directly above the chairDesk.glb cushion, facing `sandbox_anchor`, for
## attaching the seated ultra-giant Yumeka model.
@export var ultra_giant_anchor: Node3D
var ultra_giant_seat_y := 0.0


func _ready() -> void:
	_build_materials()
	_build_shell()
	_build_sandbox()
	_build_furniture()
	_build_decor()
	_build_lights()
	_apply_visual_layer(self, BEDROOM_LAYER)
	apply_day_night(1.0, 0.0, 0.0, 0.0)


func _is_mobile_platform() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")


func _apply_visual_layer(node: Node, mask: int) -> void:
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = mask
	for child in node.get_children():
		_apply_visual_layer(child, mask)


func set_shadows_enabled(enabled: bool) -> void:
	if _window_sun != null:
		_window_sun.shadow_enabled = enabled


func get_desk_lamp_light() -> OmniLight3D:
	return _desk_lamp_light


func get_window_sun() -> DirectionalLight3D:
	return _window_sun


func get_interior_bounce() -> DirectionalLight3D:
	return _interior_bounce


func get_ceiling_fill() -> OmniLight3D:
	return _ceiling_fill


func _build_materials() -> void:
	# Soft Japanese cream-white matte plaster (clean low-saturation finish, zero gritty banding).
	_mat_wall = _matte(Color(0.945, 0.916, 0.862), 0.92)
	_mat_ceiling = _matte(Color(0.972, 0.956, 0.922), 0.95)
	_mat_floor = _light_oak_floor_material()
	# Pale natural birch/oak wood matching Kenney furniture wood tone.
	_mat_wood_trim = _matte(Color(0.865, 0.768, 0.632), 0.74)
	_mat_sash = _matte(Color(0.955, 0.938, 0.902), 0.68)
	_mat_door = _matte(Color(0.928, 0.892, 0.835), 0.76)
	_mat_metal = _matte(Color(0.74, 0.75, 0.76), 0.35, 0.45)


func _matte(color: Color, roughness: float, metallic := 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mat.metallic = metallic
	mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	return mat


func _light_oak_floor_material() -> Material:
	var diff := load(FLOOR_WOOD_DIFF) as Texture2D
	if diff == null:
		return _matte(Color(0.86, 0.77, 0.63), 0.74)
	# Lift the walnut plank texture into a soft pale Japanese oak floor while preserving subtle
	# plank lines (compatible with GL Compatibility on desktop & mobile).
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
uniform sampler2D wood_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec2 uv_scale = vec2(3.6, 3.6);
uniform vec3 pale_base = vec3(0.78, 0.67, 0.53);
void fragment() {
	vec3 raw = texture(wood_tex, UV * uv_scale).rgb;
	float luma = dot(raw, vec3(0.299, 0.587, 0.114));
	float s_luma = pow(max(luma, 0.0001), 0.4545);
	float grain = clamp((s_luma - 0.43) * 1.25, -0.20, 0.20);
	ALBEDO = clamp(pale_base + vec3(grain * 0.65, grain * 0.58, grain * 0.48), vec3(0.42), vec3(0.90));
	ROUGHNESS = 0.74;
	METALLIC = 0.0;
	SPECULAR = 0.22;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter(&"wood_tex", diff)
	return mat


func _box(parent: Node, size: Vector3, pos: Vector3, mat: Material,
		op := CSGBox3D.OPERATION_UNION) -> CSGBox3D:
	var node := CSGBox3D.new()
	node.size = size
	node.position = pos
	node.operation = op
	node.material = mat
	parent.add_child(node)
	return node


func _build_shell() -> void:
	var shell := CSGCombiner3D.new()
	shell.name = "Shell"
	# Cast room/window-frame shadows on desktop so sunlight enters cleanly through the window.
	shell.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if _is_mobile_platform()
		else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	)
	add_child(shell)

	var half_x := ROOM.x * 0.5
	var win_left := WIN_CENTER_X - WIN_WIDTH * 0.5
	var win_right := WIN_CENTER_X + WIN_WIDTH * 0.5
	var win_top := WIN_SILL_Y + WIN_HEIGHT
	var win_mid_y := WIN_SILL_Y + WIN_HEIGHT * 0.5

	# Floor (top at y = 0) & ceiling (bottom at y = ROOM.y): extended past all wall faces so
	# grazing low-elevation angles can never leak background sky through floor/wall corners.
	_box(shell, Vector3(ROOM.x + WALL * 2.0, 0.10, ROOM.z + WALL * 2.0),
		Vector3(0.0, -0.05, ROOM_Z_CENTER), _mat_floor)
	_box(shell, Vector3(ROOM.x + WALL * 2.0, 0.10, ROOM.z + WALL * 2.0),
		Vector3(0.0, ROOM.y + 0.05, ROOM_Z_CENTER), _mat_ceiling)

	# North wall (-Z) assembled from 4 overlapping slabs around the exact window opening
	# (avoids CSG subtraction offset traps and guarantees zero corner cracks).
	var wall_h := ROOM.y + 0.08
	var wall_y := ROOM.y * 0.5
	var north_z := ROOM_Z_MIN - WALL * 0.5
	var left_w := win_left - (-half_x - WALL)
	_box(shell, Vector3(left_w, wall_h, WALL),
		Vector3(-half_x - WALL + left_w * 0.5, wall_y, north_z), _mat_wall)
	var right_w := (half_x + WALL) - win_right
	_box(shell, Vector3(right_w, wall_h, WALL),
		Vector3(win_right + right_w * 0.5, wall_y, north_z), _mat_wall)
	var spandrel_h := WIN_SILL_Y + 0.04
	_box(shell, Vector3(WIN_WIDTH + 0.04, spandrel_h, WALL),
		Vector3(WIN_CENTER_X, spandrel_h * 0.5 - 0.04, north_z), _mat_wall)
	var lintel_h := (ROOM.y + 0.04) - win_top
	_box(shell, Vector3(WIN_WIDTH + 0.04, lintel_h, WALL),
		Vector3(WIN_CENTER_X, win_top + lintel_h * 0.5, north_z), _mat_wall)

	# South, West, East walls (overlapping into floor, ceiling, and north/south corners).
	_box(shell, Vector3(ROOM.x + WALL * 2.0, wall_h, WALL),
		Vector3(0.0, wall_y, ROOM_Z_MAX + WALL * 0.5), _mat_wall)
	_box(shell, Vector3(WALL, wall_h, ROOM.z + WALL * 2.0),
		Vector3(-half_x - WALL * 0.5, wall_y, ROOM_Z_CENTER), _mat_wall)
	_box(shell, Vector3(WALL, wall_h, ROOM.z + WALL * 2.0),
		Vector3(half_x + WALL * 0.5, wall_y, ROOM_Z_CENTER), _mat_wall)

	# Recessed 3D pale-wood window frame (overlaps 1.5 cm into wall edges for zero seams).
	var frame_t := 0.055
	var frame_d := WALL + 0.036
	var frame_z := north_z + 0.012
	var ov := 0.015
	_box(shell, Vector3(WIN_WIDTH + frame_t * 2.0 - ov * 2.0, frame_t, frame_d),
		Vector3(WIN_CENTER_X, win_top + frame_t * 0.5 - ov, frame_z), _mat_wood_trim)
	_box(shell, Vector3(WIN_WIDTH + frame_t * 2.0 - ov * 2.0, frame_t, frame_d),
		Vector3(WIN_CENTER_X, WIN_SILL_Y - frame_t * 0.5 + ov, frame_z), _mat_wood_trim)
	_box(shell, Vector3(frame_t, WIN_HEIGHT - ov * 2.0 + 0.004, frame_d),
		Vector3(win_left - frame_t * 0.5 + ov, win_mid_y, frame_z), _mat_wood_trim)
	_box(shell, Vector3(frame_t, WIN_HEIGHT - ov * 2.0 + 0.004, frame_d),
		Vector3(win_right + frame_t * 0.5 - ov, win_mid_y, frame_z), _mat_wood_trim)
	# Projecting interior window sill
	_box(shell, Vector3(WIN_WIDTH + frame_t * 2.0 + 0.08, 0.036, 0.09),
		Vector3(WIN_CENTER_X, WIN_SILL_Y - 0.004, ROOM_Z_MIN + 0.032), _mat_wood_trim)
	# Inner cream sash border + centre mullion + subtle upper transom bar (clean two-pane look)
	var sash_z := north_z + 0.005
	var sash_d := 0.042
	var sash_w := 0.032
	_box(shell, Vector3(sash_w, WIN_HEIGHT, sash_d),
		Vector3(WIN_CENTER_X, win_mid_y, sash_z), _mat_sash)
	_box(shell, Vector3(WIN_WIDTH, 0.026, sash_d),
		Vector3(WIN_CENTER_X, WIN_SILL_Y + WIN_HEIGHT * 0.72, sash_z), _mat_sash)
	_box(shell, Vector3(sash_w * 0.85, WIN_HEIGHT, sash_d),
		Vector3(win_left + sash_w * 0.5, win_mid_y, sash_z), _mat_sash)
	_box(shell, Vector3(sash_w * 0.85, WIN_HEIGHT, sash_d),
		Vector3(win_right - sash_w * 0.5, win_mid_y, sash_z), _mat_sash)
	_box(shell, Vector3(WIN_WIDTH, sash_w * 0.85, sash_d),
		Vector3(WIN_CENTER_X, win_top - sash_w * 0.5, sash_z), _mat_sash)
	_box(shell, Vector3(WIN_WIDTH, sash_w * 0.85, sash_d),
		Vector3(WIN_CENTER_X, WIN_SILL_Y + sash_w * 0.5, sash_z), _mat_sash)

	# Window glass (separate MeshInstance3D outside combiner so alpha doesn't split CSG).
	var glass := MeshInstance3D.new()
	glass.name = "WindowGlass"
	var glass_mesh := BoxMesh.new()
	glass_mesh.size = Vector3(WIN_WIDTH - 0.04, WIN_HEIGHT - 0.04, 0.008)
	glass.mesh = glass_mesh
	glass.position = Vector3(WIN_CENTER_X, win_mid_y, north_z)
	_window_glass_mat = StandardMaterial3D.new()
	_window_glass_mat.albedo_color = Color(0.92, 0.96, 1.0, 0.11)
	_window_glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_window_glass_mat.roughness = 0.06
	_window_glass_mat.metallic = 0.05
	_window_glass_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	glass.material_override = _window_glass_mat
	glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(glass)

	# Minimalist pale-wood baseboards sealing every wall/floor corner cleanly.
	var base_h := 0.08
	var base_t := 0.022
	var base_y := base_h * 0.5 - 0.005
	_box(shell, Vector3(ROOM.x + 0.02, base_h, base_t),
		Vector3(0.0, base_y, ROOM_Z_MIN + base_t * 0.5 - 0.004), _mat_wood_trim)
	_box(shell, Vector3(ROOM.x + 0.02, base_h, base_t),
		Vector3(0.0, base_y, ROOM_Z_MAX - base_t * 0.5 + 0.004), _mat_wood_trim)
	_box(shell, Vector3(base_t, base_h, ROOM.z + 0.02),
		Vector3(-half_x + base_t * 0.5 - 0.004, base_y, ROOM_Z_CENTER), _mat_wood_trim)
	var door_z := 1.78
	var door_w := 0.84
	var door_h := 2.02
	var door_z0 := door_z - door_w * 0.5
	var door_z1 := door_z + door_w * 0.5
	var east_n_len := door_z0 - ROOM_Z_MIN
	_box(shell, Vector3(base_t, base_h, east_n_len),
		Vector3(half_x - base_t * 0.5 + 0.004, base_y, ROOM_Z_MIN + east_n_len * 0.5), _mat_wood_trim)
	var east_s_len := ROOM_Z_MAX - door_z1
	_box(shell, Vector3(base_t, base_h, east_s_len),
		Vector3(half_x - base_t * 0.5 + 0.004, base_y, door_z1 + east_s_len * 0.5), _mat_wood_trim)

	# East wall cream bedroom door with pale-wood casing and handle.
	var trim := 0.055
	_box(shell, Vector3(0.022, door_h, door_w),
		Vector3(half_x - 0.009, door_h * 0.5, door_z), _mat_door)
	_box(shell, Vector3(0.032, door_h + trim, trim),
		Vector3(half_x - 0.012, (door_h + trim) * 0.5, door_z0 - trim * 0.5), _mat_wood_trim)
	_box(shell, Vector3(0.032, door_h + trim, trim),
		Vector3(half_x - 0.012, (door_h + trim) * 0.5, door_z1 + trim * 0.5), _mat_wood_trim)
	_box(shell, Vector3(0.032, trim, door_w + trim * 2.0),
		Vector3(half_x - 0.012, door_h + trim * 0.5, door_z), _mat_wood_trim)
	_box(shell, Vector3(0.045, 0.025, 0.11),
		Vector3(half_x - 0.035, 0.96, door_z - door_w * 0.36), _mat_metal)

	# Carve shallow 10 cm recesses (667 m in single-world scale, leaving 4 cm airtight outer
	# wall backing) behind every wall painting & corkboard so far walls at 15-22 km never
	# Z-fight with thin wall decor even on 24-bit mobile depth buffers at near = 0.05 m.
	var recess_d := 0.10
	# South wall art recesses
	_box(shell, Vector3(0.77, 0.51, recess_d),
		Vector3(-0.82, 1.66, ROOM_Z_MAX + recess_d * 0.5 - 0.010), _mat_wall, CSGBox3D.OPERATION_SUBTRACTION)
	_box(shell, Vector3(0.43, 0.57, recess_d),
		Vector3(1.66, 1.66, ROOM_Z_MAX + recess_d * 0.5 - 0.010), _mat_wall, CSGBox3D.OPERATION_SUBTRACTION)
	# West wall art recesses
	_box(shell, Vector3(recess_d, 0.55, 0.41),
		Vector3(-half_x - recess_d * 0.5 + 0.010, 1.54, 0.54), _mat_wall, CSGBox3D.OPERATION_SUBTRACTION)
	_box(shell, Vector3(recess_d, 0.45, 0.57),
		Vector3(-half_x - recess_d * 0.5 + 0.010, 1.62, 1.48), _mat_wall, CSGBox3D.OPERATION_SUBTRACTION)
	_box(shell, Vector3(recess_d, 0.45, 0.57),
		Vector3(-half_x - recess_d * 0.5 + 0.010, 1.62, 2.26), _mat_wall, CSGBox3D.OPERATION_SUBTRACTION)
	# East wall art recess
	_box(shell, Vector3(recess_d, 0.39, 0.63),
		Vector3(half_x + recess_d * 0.5 - 0.010, 2.02, 0.58), _mat_wall, CSGBox3D.OPERATION_SUBTRACTION)
	# North-west corkboard recess
	_box(shell, Vector3(0.61, 0.45, recess_d),
		Vector3(-1.62, 1.54, ROOM_Z_MIN - recess_d * 0.5 + 0.010), _mat_wall, CSGBox3D.OPERATION_SUBTRACTION)


func _build_sandbox() -> void:
	var sandbox := Node3D.new()
	sandbox.name = "Sandbox"
	add_child(sandbox)
	var shadow_pad := MeshInstance3D.new()
	shadow_pad.name = "SandboxContactShadow"
	var quad := PlaneMesh.new()
	quad.size = Vector2(SANDBOX_SIDE + 0.036, SANDBOX_SIDE + 0.036)
	shadow_pad.mesh = quad
	shadow_pad.position = Vector3(0.0, DESK_TOP + 0.0005, 0.0)
	shadow_pad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled;
void fragment() {
	vec2 d = abs(UV - vec2(0.5)) * 2.0;
	float edge = max(d.x, d.y);
	float alpha = (1.0 - smoothstep(0.74, 1.0, edge)) * 0.42;
	ALBEDO = vec3(0.16, 0.11, 0.07);
	ALPHA = alpha;
}
"""
	var smat := ShaderMaterial.new()
	smat.shader = sh
	shadow_pad.material_override = smat
	sandbox.add_child(shadow_pad)
	_sandbox_shadow = shadow_pad
	sandbox_anchor = Node3D.new()
	sandbox_anchor.name = "SandboxAnchor"
	sandbox_anchor.position = Vector3(0.0, DESK_TOP + SANDBOX_BASE_THICKNESS, 0.0)
	sandbox.add_child(sandbox_anchor)


func configure_tray(room_scale: float, side: float, base_depth: float, offset: float) -> void:
	var shadow_side := side / room_scale + 0.036
	var desk_offset := minf(offset, maxf(0.0, _desk_half_depth - shadow_side * 0.5))
	sandbox_anchor.position = Vector3(0.0, DESK_TOP + base_depth / room_scale, desk_offset)
	_sandbox_shadow.position.z = desk_offset
	(_sandbox_shadow.mesh as PlaneMesh).size = Vector2.ONE * shadow_side
	if is_equal_approx(_render_scale, room_scale):
		return
	_render_scale = room_scale
	_lights.scale = Vector3.ONE / _render_scale
	_window_sun.directional_shadow_max_distance = 6.0 * _render_scale
	_desk_lamp_light.position = DESK_LAMP_POSITION * _render_scale
	_desk_lamp_light.omni_range = 4.4 * _render_scale
	apply_day_night(_light_weights.x, _light_weights.y, _light_weights.z)


func _build_furniture() -> void:
	var furniture := Node3D.new()
	furniture.name = "Furniture"
	add_child(furniture)

	var mat_wood_soft := {"wood": {"color": Color(0.84, 0.70, 0.55), "roughness": 0.78}}
	var mat_chair := {
		"carpet": {"color": Color(0.76, 0.65, 0.57), "roughness": 0.88},
		"metalMedium": {"color": Color(0.58, 0.61, 0.64), "roughness": 0.45, "metallic": 0.25},
	}
	var mat_bed := {
		"carpet": {"color": Color(0.82, 0.67, 0.61), "roughness": 0.90},
		"carpetWhite": {"color": Color(0.92, 0.89, 0.85), "roughness": 0.90},
		"wood": {"color": Color(0.84, 0.70, 0.55), "roughness": 0.78},
	}
	var mat_pillow_sage := {"carpet": {"color": Color(0.76, 0.80, 0.73), "roughness": 0.92}}
	var mat_pillow_rose := {"carpet": {"color": Color(0.85, 0.72, 0.67), "roughness": 0.92}}
	var mat_rug := {
		"carpet": {"color": Color(0.83, 0.76, 0.67), "roughness": 0.94},
		"carpetDarker": {"color": Color(0.74, 0.66, 0.56), "roughness": 0.94},
	}
	var mat_lamp := {
		"lamp": {
			"color": Color(0.98, 0.94, 0.84),
			"roughness": 0.76,
			"emission": Color(1.0, 0.82, 0.46),
			"emission_energy": 0.14,
		},
		"metal": {"color": Color(0.86, 0.84, 0.80), "roughness": 0.45},
	}
	var mat_screen := {
		"metalDark": {"color": Color(0.28, 0.30, 0.34), "roughness": 0.52},
		"metal": {"color": Color(0.14, 0.17, 0.22), "roughness": 0.24},
	}
	var mat_periph := {
		"metalDark": {"color": Color(0.42, 0.44, 0.47), "roughness": 0.62},
		"metalMedium": {"color": Color(0.78, 0.78, 0.76), "roughness": 0.65},
	}

	var cast_major := not _is_mobile_platform()

	# --- 1. Study desk & swivel chair ---
	var desk_probe := _load_bounds("desk")
	var desk_scale := DESK_TOP / maxf(desk_probe.size.y, 0.001)
	_desk_half_depth = desk_probe.size.z * desk_scale * 0.5
	_place_glb(furniture, "Desk", "desk", Vector3(0.0, 0.0, 0.0),
		Vector3(desk_scale * 1.14, desk_scale, desk_scale), 0.0, false, mat_wood_soft, cast_major)

	var chair_pos := Vector3(0.0, 0.0, 0.60)
	_place_glb(furniture, "ChairDesk", "chairDesk", chair_pos,
		Vector3.ONE * CHAIR_SCALE, PI, false, mat_chair, cast_major)

	ultra_giant_seat_y = CHAIR_RAW_SEAT_TOP_Y * CHAIR_SCALE
	ultra_giant_anchor = Node3D.new()
	ultra_giant_anchor.name = "UltraGiantAnchor"
	ultra_giant_anchor.position = Vector3(
		chair_pos.x,
		ultra_giant_seat_y,
		chair_pos.z - CHAIR_RAW_SEAT_CENTER_Z_OFFSET * CHAIR_SCALE,
	)
	ultra_giant_anchor.set_meta(&"seat_y", ultra_giant_seat_y)
	ultra_giant_anchor.set_meta(&"faces", &"SandboxAnchor")
	# Use local Transform3D.looking_at so the horizontal orientation stays invariant
	# under the bedroom's scale and offset. Both tray layouts use the desk centreline.
	ultra_giant_anchor.transform = Transform3D(Basis.IDENTITY, ultra_giant_anchor.position).looking_at(
		Vector3(sandbox_anchor.position.x, ultra_giant_seat_y, sandbox_anchor.position.z),
		Vector3.UP,
	)
	add_child(ultra_giant_anchor)

	if ResourceLoader.exists(YUMEKA_GLB, "PackedScene"):
		var seated: Node3D = YumekaSeated.new()
		seated.name = "Yumeka"
		ultra_giant_anchor.add_child(seated)

	# --- 2. Desktop landmarks pulled 15-26 cm clear of the 21.27 cm sandbox ---
	var monitor := _place_glb(furniture, "ComputerScreen", "computerScreen",
		Vector3(-0.46, DESK_TOP, -0.26), Vector3.ONE * 0.98, deg_to_rad(20.0), false, mat_screen, cast_major)
	_attach_monitor_display(monitor)
	# Keyboard and mouse rest cleanly on top of the 2.4 mm felt desk mat, clear of Yumeka's left hand.
	_place_glb(furniture, "ComputerKeyboard", "computerKeyboard",
		Vector3(-0.52, DESK_TOP + DESK_MAT_THICKNESS, -0.02), Vector3.ONE * 1.12, deg_to_rad(18.0), false, mat_periph, false)
	_place_glb(furniture, "ComputerMouse", "computerMouse",
		Vector3(-0.42, DESK_TOP + DESK_MAT_THICKNESS, 0.17), Vector3.ONE * 1.10, deg_to_rad(16.0), false, mat_periph, false)
	_place_glb(furniture, "PlantSmallDesk", "plantSmall1",
		Vector3(-0.70, DESK_TOP, 0.23), Vector3.ONE * 1.45, deg_to_rad(15.0), false, mat_wood_soft, false)
	_place_glb(furniture, "SpeakerLeft", "speakerSmall",
		Vector3(-0.74, DESK_TOP, -0.15), Vector3.ONE * 0.76, deg_to_rad(32.0), false, mat_wood_soft, false)

	var desk_lamp := _place_glb(furniture, "LampRoundTable", "lampRoundTable",
		Vector3(0.48, DESK_TOP, -0.25), Vector3.ONE * 1.20, deg_to_rad(-20.0), false, mat_lamp, cast_major)
	_desk_lamp_shade_mat = _find_surface_material(desk_lamp, "lamp")
	_place_glb(furniture, "BooksDesk", "books",
		Vector3(0.55, DESK_TOP, 0.05), Vector3.ONE * 1.55, deg_to_rad(-22.0), false, mat_wood_soft, false)
	_place_glb(furniture, "SpeakerRight", "speakerSmall",
		Vector3(0.74, DESK_TOP, -0.15), Vector3.ONE * 0.76, deg_to_rad(-32.0), false, mat_wood_soft, false)

	# --- 3. Large bedroom background furniture ---
	_place_glb(furniture, "PottedPlant", "pottedPlant",
		Vector3(-1.88, 0.0, -0.18), Vector3.ONE * 1.85, deg_to_rad(25.0), false, mat_wood_soft, cast_major)
	var nightstand := _place_glb(furniture, "CabinetBedDrawer", "cabinetBedDrawer",
		Vector3(-2.02, 0.0, 0.62), Vector3.ONE * 1.95, PI * 0.5, false, mat_wood_soft, cast_major)
	var ns_top := 0.2632 * 1.95
	_place_glb(furniture, "PlantSmallNightstand", "plantSmall1",
		Vector3(nightstand.position.x + 0.02, ns_top, nightstand.position.z - 0.06),
		Vector3.ONE * 1.40, deg_to_rad(45.0), false, mat_wood_soft, false)

	const BED_SCALE := 1.82
	var bed_mattress_y := 0.23 * BED_SCALE
	_place_glb(furniture, "BedDouble", "bedDouble",
		Vector3(-1.24, 0.0, 2.02), Vector3.ONE * BED_SCALE, PI * 0.5, false, mat_bed, cast_major)
	var pillow_a := _place_glb(furniture, "Pillow", "pillow",
		Vector3(-1.80, bed_mattress_y, 1.66), Vector3.ONE * 1.45, deg_to_rad(82.0), false, mat_pillow_sage, false)
	pillow_a.rotation.x = deg_to_rad(-22.0)
	var pillow_b := _place_glb(furniture, "PillowLong", "pillowLong",
		Vector3(-1.74, bed_mattress_y, 2.28), Vector3.ONE * 1.40, deg_to_rad(96.0), false, mat_pillow_rose, false)
	pillow_b.rotation.x = deg_to_rad(-20.0)

	_place_glb(furniture, "RugRounded", "rugRounded",
		Vector3(0.38, 0.002, 1.55), Vector3.ONE * 1.45, PI * 0.5, false, mat_rug, false)

	_place_glb(furniture, "BookcaseOpen", "bookcaseOpen",
		Vector3(1.50, 0.0, -0.26), Vector3.ONE * 1.95, 0.0, false, mat_wood_soft, cast_major)
	_place_glb(furniture, "BooksShelfMid", "books",
		Vector3(1.56, 0.37 * 1.95, -0.24), Vector3.ONE * 1.50, deg_to_rad(-8.0), false, mat_wood_soft, false)
	_place_glb(furniture, "BooksShelfUpper", "books",
		Vector3(1.36, 0.61 * 1.95, -0.24), Vector3.ONE * 1.55, deg_to_rad(6.0), false, mat_wood_soft, false)
	_place_glb(furniture, "PlantShelfUpper", "plantSmall1",
		Vector3(1.68, 0.61 * 1.95, -0.24), Vector3.ONE * 1.35, deg_to_rad(-18.0), false, mat_wood_soft, false)
	_place_glb(furniture, "BookcaseClosedDoors", "bookcaseClosedDoors",
		Vector3(2.02, 0.0, 0.58), Vector3.ONE * 1.95, -PI * 0.5, false, mat_wood_soft, cast_major)
	_place_glb(furniture, "Trashcan", "trashcan",
		Vector3(1.02, 0.0, 0.16), Vector3.ONE * 0.90, deg_to_rad(-18.0), false, mat_periph, cast_major)
	_place_glb(furniture, "CoatRackStanding", "coatRackStanding",
		Vector3(1.86, 0.0, 2.78), Vector3.ONE * 2.05, deg_to_rad(-30.0), false, mat_wood_soft, cast_major)

	var ceiling_lamp := _place_glb(furniture, "LampSquareCeiling", "lampSquareCeiling",
		Vector3(0.0, ROOM.y, 1.20), Vector3.ONE * 2.10, 0.0, true, mat_lamp, cast_major)
	_ceiling_lamp_shade_mat = _find_surface_material(ceiling_lamp, "lamp")


# ---------------------------------------------------------------------------
# Soft Interior Decor (Visual-Only, Zero Collision, Lightweight Draw Budget)
# ---------------------------------------------------------------------------

func _build_decor() -> void:
	var decor := Node3D.new()
	decor.name = "Decor"
	add_child(decor)
	_build_curtains(decor)
	_build_wall_art(decor)
	_build_corkboard(decor)
	_build_wall_shelf(decor)
	_build_desk_details(decor)


func _build_curtains(parent: Node3D) -> void:
	var group := Node3D.new()
	group.name = "Curtains"
	parent.add_child(group)

	var win_left := WIN_CENTER_X - WIN_WIDTH * 0.5
	var win_right := WIN_CENTER_X + WIN_WIDTH * 0.5
	var win_top := WIN_SILL_Y + WIN_HEIGHT
	var rod_y := win_top + 0.095
	var rod_z := ROOM_Z_MIN + 0.088
	var rod_x0 := win_left - 0.22
	var rod_x1 := win_right + 0.22
	var rod_len := rod_x1 - rod_x0

	# Natural birch curtain rod + spherical end finials + 3 wall brackets.
	var rod := MeshInstance3D.new()
	rod.name = "CurtainRod"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.013
	cyl.bottom_radius = 0.013
	cyl.height = rod_len
	cyl.radial_segments = 12
	rod.mesh = cyl
	rod.position = Vector3((rod_x0 + rod_x1) * 0.5, rod_y, rod_z)
	rod.rotation.z = PI * 0.5
	rod.material_override = _mat_wood_trim
	rod.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	group.add_child(rod)

	var finial_mesh := SphereMesh.new()
	finial_mesh.radius = 0.023
	finial_mesh.height = 0.046
	finial_mesh.radial_segments = 10
	finial_mesh.rings = 6
	for side_idx in 2:
		var fin := MeshInstance3D.new()
		fin.mesh = finial_mesh
		fin.position = Vector3(rod_x0 - 0.012 if side_idx == 0 else rod_x1 + 0.012, rod_y, rod_z)
		fin.material_override = _mat_wood_trim
		fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		group.add_child(fin)

	var bracket_mesh := BoxMesh.new()
	bracket_mesh.size = Vector3(0.018, 0.028, 0.094)
	for bx in [rod_x0 + 0.14, WIN_CENTER_X, rod_x1 - 0.14]:
		var br := MeshInstance3D.new()
		br.mesh = bracket_mesh
		br.position = Vector3(bx, rod_y, ROOM_Z_MIN + 0.045)
		br.material_override = _mat_wood_trim
		br.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		group.add_child(br)

	# Translucent warm cream / soft apricot sheer curtain material with wrap shading so
	# close desk-lamp light wraps softly across fabric folds instead of harsh dark bands.
	_curtain_mat = StandardMaterial3D.new()
	_curtain_mat.albedo_color = Color(0.985, 0.942, 0.898, 0.84)
	_curtain_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_curtain_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT_WRAP
	_curtain_mat.roughness = 0.92
	_curtain_mat.metallic = 0.0
	_curtain_mat.metallic_specular = 0.08
	_curtain_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Left & right pleated sheer panels frame the outer ~22 cm of the window while keeping
	# the central ~1.38 m completely open for sunlight and city-to-sky sightlines.
	var tie_mat := _matte(Color(0.84, 0.74, 0.64), 0.88)
	var left_panel := _make_pleated_curtain(-1.14, -0.74, true, rod_y - 0.015, 0.80, rod_z + 0.004)
	left_panel.name = "CurtainLeft"
	left_panel.material_override = _curtain_mat
	group.add_child(left_panel)

	var right_panel := _make_pleated_curtain(0.64, 1.04, false, rod_y - 0.015, 0.80, rod_z + 0.004)
	right_panel.name = "CurtainRight"
	right_panel.material_override = _curtain_mat
	group.add_child(right_panel)

	# Fabric tiebacks cinching each curtain snugly at y = 1.38 m.
	for i in 2:
		var is_left := (i == 0)
		var tie := MeshInstance3D.new()
		tie.name = "CurtainTieLeft" if is_left else "CurtainTieRight"
		var tmesh := BoxMesh.new()
		tmesh.size = Vector3(0.215, 0.028, 0.044)
		tie.mesh = tmesh
		tie.position = Vector3(-1.032 if is_left else 0.932, 1.38, rod_z + 0.008)
		tie.rotation.z = deg_to_rad(5.0 if is_left else -5.0)
		tie.material_override = tie_mat
		tie.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		group.add_child(tie)


func _make_pleated_curtain(x_min: float, x_max: float, cinch_left: bool,
		y_top: float, y_bot: float, z_mid: float) -> MeshInstance3D:
	var cols := 18
	var rows := 14
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pts: Array[Array] = []
	for r in rows + 1:
		var v := float(r) / float(rows)  # 0 = top, 1 = bottom
		var y := lerpf(y_top, y_bot, v)
		# Smooth hourglass cinch around v = 0.61 (y ≈ 1.38 m) pulling toward outer wall edge.
		var cinch := exp(-pow((v - 0.61) / 0.22, 2.0))
		var row_pts: Array[Vector3] = []
		for c in cols + 1:
			var u := float(c) / float(cols)
			var base_x := lerpf(x_min, x_max, u)
			var x := base_x
			if cinch_left:
				x = lerpf(base_x, x_min + (base_x - x_min) * 0.56, cinch)
			else:
				x = lerpf(base_x, x_max - (x_max - base_x) * 0.56, cinch)
			# Gentle fabric drape folds (soft wave prevents grazing dark stripes near lamp).
			var pleat_amp := lerpf(0.015, 0.010, cinch * 0.7) * (0.85 + 0.18 * v)
			var z := z_mid + sin(u * TAU * 3.0) * pleat_amp + cinch * 0.006
			row_pts.append(Vector3(x, y, z))
		pts.append(row_pts)
	for r in rows:
		for c in cols:
			var p00: Vector3 = pts[r][c]
			var p10: Vector3 = pts[r][c + 1]
			var p01: Vector3 = pts[r + 1][c]
			var p11: Vector3 = pts[r + 1][c + 1]
			var u0 := float(c) / float(cols)
			var u1 := float(c + 1) / float(cols)
			var v0 := float(r) / float(rows)
			var v1 := float(r + 1) / float(rows)
			st.set_uv(Vector2(u0, v0)); st.add_vertex(p00)
			st.set_uv(Vector2(u1, v0)); st.add_vertex(p10)
			st.set_uv(Vector2(u1, v1)); st.add_vertex(p11)
			st.set_uv(Vector2(u0, v0)); st.add_vertex(p00)
			st.set_uv(Vector2(u1, v1)); st.add_vertex(p11)
			st.set_uv(Vector2(u0, v1)); st.add_vertex(p01)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _build_wall_art(parent: Node3D) -> void:
	var half_x := ROOM.x * 0.5
	# South wall behind Yumeka (prominent when looking south/upward from the city).
	_add_framed_art(parent, "ArtSouthHarbor",
		Vector3(-0.82, 1.66, ROOM_Z_MAX - 0.014), PI, Vector2(0.76, 0.50),
		_make_art_texture("coastal_sunset"))
	_add_framed_art(parent, "ArtSouthBotanical",
		Vector3(1.66, 1.66, ROOM_Z_MAX - 0.014), PI, Vector2(0.42, 0.56),
		_make_art_texture("botanical_sprig"))
	# West wall above nightstand & double bed (fills the wall cleanly with zero blank gaps).
	_add_framed_art(parent, "ArtWestNightstand",
		Vector3(-half_x + 0.014, 1.54, 0.54), PI * 0.5, Vector2(0.40, 0.54),
		_make_art_texture("botanical_sprig"))
	_add_framed_art(parent, "ArtWestMisty",
		Vector3(-half_x + 0.014, 1.62, 1.48), PI * 0.5, Vector2(0.56, 0.44),
		_make_art_texture("misty_harbor"))
	_add_framed_art(parent, "ArtWestMoon",
		Vector3(-half_x + 0.014, 1.62, 2.26), PI * 0.5, Vector2(0.56, 0.44),
		_make_art_texture("warm_moon"))
	# East wall above closed bookcase (fits cleanly between y = 1.66 bookcase top & ceiling).
	_add_framed_art(parent, "ArtEastLandscape",
		Vector3(half_x - 0.014, 2.02, 0.58), -PI * 0.5, Vector2(0.62, 0.38),
		_make_art_texture("coastal_sunset"))


func _add_framed_art(parent: Node3D, node_name: String, pos: Vector3, rot_y: float,
		outer_size: Vector2, tex: ImageTexture) -> void:
	var root := Node3D.new()
	root.name = node_name
	root.position = pos
	root.rotation.y = rot_y
	parent.add_child(root)

	var w := outer_size.x
	var h := outer_size.y
	var border := 0.022
	var depth := 0.024
	# Four pale-oak frame bars.
	for spec in [
		[Vector3(w, border, depth), Vector3(0.0, h * 0.5 - border * 0.5, 0.0)],
		[Vector3(w, border, depth), Vector3(0.0, -h * 0.5 + border * 0.5, 0.0)],
		[Vector3(border, h - border * 2.0, depth), Vector3(-w * 0.5 + border * 0.5, 0.0, 0.0)],
		[Vector3(border, h - border * 2.0, depth), Vector3(w * 0.5 - border * 0.5, 0.0, 0.0)],
	]:
		var bar := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = spec[0]
		bar.mesh = bm
		bar.position = spec[1]
		bar.material_override = _mat_wood_trim
		bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(bar)

	# Single non-overlapping mat + illustration quad (avoids coplanar backing/art Z-fighting
	# at 22 km distance on 24-bit mobile depth buffers while preserving the cream mat border).
	var art := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(maxf(w - border * 1.9, 0.08), maxf(h - border * 1.9, 0.08))
	art.mesh = qm
	art.position = Vector3(0.0, 0.0, 0.002)
	var art_mat := StandardMaterial3D.new()
	art_mat.albedo_texture = _add_mat_border_to_texture(tex)
	art_mat.roughness = 0.86
	art_mat.metallic = 0.0
	art_mat.metallic_specular = 0.14
	art.material_override = art_mat
	art.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(art)


func _add_mat_border_to_texture(inner_tex: ImageTexture) -> ImageTexture:
	var src := inner_tex.get_image()
	if src == null:
		return inner_tex
	var pad := 12
	var w := src.get_width() + pad * 2
	var h := src.get_height() + pad * 2
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	out.fill(Color(0.965, 0.952, 0.925))
	out.blit_rect(src, Rect2i(0, 0, src.get_width(), src.get_height()), Vector2i(pad, pad))
	return ImageTexture.create_from_image(out)


func _build_corkboard(parent: Node3D) -> void:
	# North-west wall beside the window: warm cork memo board with pastel sticky notes.
	var root := Node3D.new()
	root.name = "CorkBoard"
	root.position = Vector3(-1.62, 1.54, ROOM_Z_MIN + 0.014)
	parent.add_child(root)

	var w := 0.60
	var h := 0.44
	var border := 0.022
	var depth := 0.022
	for spec in [
		[Vector3(w, border, depth), Vector3(0.0, h * 0.5 - border * 0.5, 0.0)],
		[Vector3(w, border, depth), Vector3(0.0, -h * 0.5 + border * 0.5, 0.0)],
		[Vector3(border, h - border * 2.0, depth), Vector3(-w * 0.5 + border * 0.5, 0.0, 0.0)],
		[Vector3(border, h - border * 2.0, depth), Vector3(w * 0.5 - border * 0.5, 0.0, 0.0)],
	]:
		var bar := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = spec[0]
		bar.mesh = bm
		bar.position = spec[1]
		bar.material_override = _mat_wood_trim
		bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(bar)

	var board := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(w - border * 2.0, h - border * 2.0)
	board.mesh = qm
	board.position = Vector3(0.0, 0.0, 0.002)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_texture = _make_cork_texture()
	bmat.roughness = 0.92
	bmat.metallic_specular = 0.10
	board.material_override = bmat
	board.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(board)


func _build_wall_shelf(parent: Node3D) -> void:
	# Minimalist pale-wood floating wall shelf on the South wall behind Yumeka.
	var root := Node3D.new()
	root.name = "WallShelfSouth"
	root.position = Vector3(0.58, 1.48, ROOM_Z_MAX - 0.092)
	root.rotation.y = PI
	parent.add_child(root)

	var shelf_w := 0.86
	var shelf_t := 0.026
	var shelf_d := 0.165
	var plank := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(shelf_w, shelf_t, shelf_d)
	plank.mesh = pm
	plank.material_override = _mat_wood_trim
	plank.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(plank)

	for bx in [-0.28, 0.28]:
		var br := MeshInstance3D.new()
		var brm := BoxMesh.new()
		brm.size = Vector3(0.022, 0.085, 0.12)
		br.mesh = brm
		br.position = Vector3(bx, -0.055, -0.015)
		br.material_override = _mat_wood_trim
		br.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(br)

	var top_y := shelf_t * 0.5
	# Small pastel books on the left half of the shelf.
	var book_specs := [
		[Vector3(-0.32, 0.082, 0.0), Vector3(0.028, 0.164, 0.12), 0.0, Color(0.84, 0.67, 0.63)],
		[Vector3(-0.286, 0.074, 0.0), Vector3(0.024, 0.148, 0.115), 0.0, Color(0.70, 0.78, 0.84)],
		[Vector3(-0.254, 0.086, 0.0), Vector3(0.026, 0.172, 0.122), 0.0, Color(0.92, 0.87, 0.74)],
		[Vector3(-0.205, 0.072, 0.0), Vector3(0.024, 0.148, 0.115), deg_to_rad(-16.0), Color(0.75, 0.82, 0.74)],
	]
	for b in book_specs:
		var book := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = b[1]
		book.mesh = bm
		book.position = Vector3(b[0].x, top_y + b[0].y, b[0].z)
		book.rotation.z = b[2]
		book.material_override = _matte(b[3], 0.86)
		book.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(book)

	# Small cream ceramic succulent pot in the center.
	var pot := MeshInstance3D.new()
	var pot_mesh := CylinderMesh.new()
	pot_mesh.top_radius = 0.044
	pot_mesh.bottom_radius = 0.036
	pot_mesh.height = 0.074
	pot_mesh.radial_segments = 10
	pot.mesh = pot_mesh
	pot.position = Vector3(0.04, top_y + 0.037, 0.01)
	pot.material_override = _matte(Color(0.94, 0.91, 0.86), 0.78)
	pot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(pot)

	var plant_ball := MeshInstance3D.new()
	var sp := SphereMesh.new()
	sp.radius = 0.042
	sp.height = 0.064
	sp.radial_segments = 10
	sp.rings = 6
	plant_ball.mesh = sp
	plant_ball.position = Vector3(0.04, top_y + 0.084, 0.01)
	plant_ball.material_override = _matte(Color(0.48, 0.64, 0.46), 0.88)
	plant_ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(plant_ball)

	# Small leaning mini-photo frame on the right half of the shelf (non-overlapping border).
	var mini := Node3D.new()
	mini.position = Vector3(0.26, top_y + 0.081, -0.01)
	mini.rotation = Vector3(deg_to_rad(-11.0), deg_to_rad(-12.0), 0.0)
	root.add_child(mini)
	for bar_spec in [
		[Vector3(0.135, 0.015, 0.012), Vector3(0.0, 0.075, 0.0)],
		[Vector3(0.135, 0.015, 0.012), Vector3(0.0, -0.075, 0.0)],
		[Vector3(0.015, 0.135, 0.012), Vector3(-0.06, 0.0, 0.0)],
		[Vector3(0.015, 0.135, 0.012), Vector3(0.06, 0.0, 0.0)],
	]:
		var mb := MeshInstance3D.new()
		var mbm := BoxMesh.new()
		mbm.size = bar_spec[0]
		mb.mesh = mbm
		mb.position = bar_spec[1]
		mb.material_override = _mat_wood_trim
		mb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mini.add_child(mb)

	var mini_pic := MeshInstance3D.new()
	var mq := QuadMesh.new()
	mq.size = Vector2(0.105, 0.135)
	mini_pic.mesh = mq
	mini_pic.position = Vector3(0.0, 0.0, 0.002)
	var mmat := StandardMaterial3D.new()
	mmat.albedo_texture = _make_art_texture("misty_harbor")
	mmat.roughness = 0.84
	mini_pic.material_override = mmat
	mini_pic.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mini.add_child(mini_pic)


func _build_desk_details(parent: Node3D) -> void:
	# Soft pale-oatmeal felt desk mat tucked cleanly under keyboard & mouse,
	# keeping >= 5 cm clearance from the 21.27 cm sandbox and clear of Yumeka's hands.
	var mat_node := MeshInstance3D.new()
	mat_node.name = "DeskMat"
	var mat_mesh := BoxMesh.new()
	mat_mesh.size = Vector3(0.48, DESK_MAT_THICKNESS, 0.25)
	mat_node.mesh = mat_mesh
	mat_node.position = Vector3(-0.48, DESK_TOP + DESK_MAT_THICKNESS * 0.5, 0.06)
	mat_node.rotation.y = deg_to_rad(17.0)
	var desk_mat_m := StandardMaterial3D.new()
	desk_mat_m.albedo_texture = _make_desk_mat_texture()
	desk_mat_m.roughness = 0.94
	desk_mat_m.metallic = 0.0
	desk_mat_m.metallic_specular = 0.08
	mat_node.material_override = desk_mat_m
	mat_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mat_node)

	# Small pastel ceramic mug on a thin pale-oak coaster (far right desk corner,
	# clear of BooksDesk, sandbox, and Yumeka's seated right hand).
	var mug_root := Node3D.new()
	mug_root.name = "DeskMug"
	mug_root.position = Vector3(0.62, DESK_TOP, 0.24)
	mug_root.rotation.y = deg_to_rad(-35.0)
	parent.add_child(mug_root)

	var coaster := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.048
	cm.bottom_radius = 0.048
	cm.height = 0.005
	cm.radial_segments = 14
	coaster.mesh = cm
	coaster.position = Vector3(0.0, 0.0025, 0.0)
	coaster.material_override = _mat_wood_trim
	coaster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mug_root.add_child(coaster)

	var mug_body := MeshInstance3D.new()
	var mm := CylinderMesh.new()
	mm.top_radius = 0.036
	mm.bottom_radius = 0.033
	mm.height = 0.082
	mm.radial_segments = 14
	mug_body.mesh = mm
	mug_body.position = Vector3(0.0, 0.005 + 0.041, 0.0)
	var ceramic := _matte(Color(0.95, 0.89, 0.85), 0.42)
	mug_body.material_override = ceramic
	mug_body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mug_root.add_child(mug_body)

	var tea := MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = 0.031
	tm.bottom_radius = 0.031
	tm.height = 0.003
	tm.radial_segments = 12
	tea.mesh = tm
	tea.position = Vector3(0.0, 0.005 + 0.0815, 0.0)
	tea.material_override = _matte(Color(0.46, 0.31, 0.20), 0.22)
	tea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mug_root.add_child(tea)

	var handle := MeshInstance3D.new()
	var hm := TorusMesh.new()
	hm.inner_radius = 0.015
	hm.outer_radius = 0.023
	hm.rings = 10
	hm.ring_segments = 8
	handle.mesh = hm
	handle.position = Vector3(0.036, 0.005 + 0.044, 0.0)
	handle.rotation.x = PI * 0.5
	handle.material_override = ceramic
	handle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mug_root.add_child(handle)


func _attach_monitor_display(monitor_pivot: Node3D) -> void:
	# Aligned to the exact tilted screen plane measured from computerScreen.glb prim=1
	# (normal (0, 0.139, 0.990), centered at (0, 0.1713, 0) in pivot local coordinates).
	var screen := MeshInstance3D.new()
	screen.name = "MonitorDisplay"
	var quad := QuadMesh.new()
	quad.size = Vector2(0.372, 0.225)
	screen.mesh = quad
	var normal := Vector3(0.0, 0.139, 0.990).normalized()
	screen.position = Vector3(0.0, 0.1713, -0.0001) + normal * 0.0045
	screen.rotation.x = -atan2(0.139, 0.990)
	var tex := _make_monitor_texture()
	_monitor_mat = StandardMaterial3D.new()
	_monitor_mat.albedo_texture = tex
	_monitor_mat.roughness = 0.22
	_monitor_mat.metallic = 0.0
	_monitor_mat.metallic_specular = 0.25
	_monitor_mat.emission_enabled = true
	_monitor_mat.emission_texture = tex
	_monitor_mat.emission_energy_multiplier = 0.38
	screen.material_override = _monitor_mat
	screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	monitor_pivot.add_child(screen)


# ---------------------------------------------------------------------------
# Procedural Crisp Mini-Textures (Zero External Downloads)
# ---------------------------------------------------------------------------

func _make_monitor_texture() -> ImageTexture:
	var w := 256
	var h := 154
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	# 1. Soft pastel anime twilight-harbor desktop wallpaper.
	for y in h:
		var vy := float(y) / float(h)
		for x in w:
			var vx := float(x) / float(w)
			var col: Color
			if vy < 0.62:
				var t := vy / 0.62
				var c_top := Color(0.30, 0.49, 0.78)
				var c_mid := Color(0.68, 0.76, 0.91)
				var c_hor := Color(0.98, 0.82, 0.72)
				col = c_top.lerp(c_mid, clampf(t * 1.4, 0.0, 1.0)).lerp(c_hor, clampf((t - 0.45) / 0.55, 0.0, 1.0))
				# Soft pastel clouds
				var cloud := sin(vx * 9.0 + 0.7) * cos(vy * 14.0) + 0.5 * sin(vx * 18.0 - 1.2)
				if vy > 0.16 and vy < 0.48 and cloud > 0.45:
					var cw := smoothstep(0.45, 1.1, cloud) * (1.0 - absf(vy - 0.32) / 0.18)
					col = col.lerp(Color(1.0, 0.96, 0.92), clampf(cw * 0.62, 0.0, 0.65))
				# Warm sun orb on horizon
				var sd := Vector2((vx - 0.68) * 1.65, vy - 0.54).length()
				if sd < 0.16:
					col = col.lerp(Color(1.0, 0.93, 0.76), smoothstep(0.16, 0.03, sd) * 0.85)
			else:
				# Calm shimmering bay water
				var wt := (vy - 0.62) / 0.38
				col = Color(0.45, 0.57, 0.74).lerp(Color(0.24, 0.33, 0.50), wt)
				var shimmer := exp(-pow((vx - 0.68) / (0.04 + wt * 0.10), 2.0)) * (0.45 + 0.55 * sin(vy * 95.0))
				col = col.lerp(Color(1.0, 0.86, 0.66), clampf(shimmer * 0.55, 0.0, 0.6))
			# Distant soft blue mountain silhouette along horizon
			var ridge := 0.62 - 0.08 * exp(-pow((vx - 0.24) / 0.20, 2.0)) - 0.055 * exp(-pow((vx - 0.82) / 0.24, 2.0))
			if vy >= ridge and vy < 0.63:
				col = Color(0.32, 0.40, 0.58)
			img.set_pixel(x, y, col)

	# 2. Left desktop app icons.
	var icon_colors := [Color(0.95, 0.62, 0.58), Color(0.56, 0.80, 0.94), Color(0.98, 0.84, 0.48), Color(0.60, 0.85, 0.68)]
	for i in icon_colors.size():
		_fill_rect(img, 10, 12 + i * 22, 12, 12, icon_colors[i])
		_fill_rect(img, 11, 26 + i * 22, 10, 2, Color(0.94, 0.95, 0.98, 0.85))

	# 3. Cozy floating music/study player window (left-mid).
	_fill_rect(img, 36, 26, 86, 62, Color(0.97, 0.96, 0.94))
	_fill_rect(img, 36, 26, 86, 11, Color(0.86, 0.89, 0.94))
	_fill_rect(img, 40, 29, 4, 4, Color(0.94, 0.48, 0.46))
	_fill_rect(img, 47, 29, 4, 4, Color(0.95, 0.78, 0.36))
	_fill_rect(img, 54, 29, 4, 4, Color(0.45, 0.80, 0.54))
	# Album square + track lines + progress bar.
	_fill_rect(img, 42, 42, 26, 26, Color(0.95, 0.72, 0.64))
	_fill_rect(img, 46, 48, 18, 10, Color(0.54, 0.70, 0.88))
	_fill_rect(img, 74, 45, 38, 4, Color(0.34, 0.38, 0.46))
	_fill_rect(img, 74, 53, 28, 3, Color(0.58, 0.62, 0.68))
	_fill_rect(img, 42, 74, 72, 4, Color(0.84, 0.86, 0.90))
	_fill_rect(img, 42, 74, 44, 4, Color(0.42, 0.68, 0.92))

	# 4. Right desktop notes / harbor mini-chart window.
	_fill_rect(img, 134, 18, 106, 92, Color(0.98, 0.97, 0.95))
	_fill_rect(img, 134, 18, 106, 11, Color(0.26, 0.32, 0.44))
	_fill_rect(img, 139, 21, 4, 4, Color(0.94, 0.48, 0.46))
	_fill_rect(img, 146, 21, 4, 4, Color(0.95, 0.78, 0.36))
	_fill_rect(img, 153, 21, 4, 4, Color(0.45, 0.80, 0.54))
	# Mini harbor map diagram inside right window.
	_fill_rect(img, 142, 35, 90, 38, Color(0.76, 0.86, 0.94))
	_fill_rect(img, 154, 42, 66, 24, Color(0.86, 0.84, 0.78))
	_fill_rect(img, 184, 42, 5, 24, Color(0.56, 0.60, 0.66))
	_fill_rect(img, 154, 52, 66, 4, Color(0.56, 0.60, 0.66))
	_fill_rect(img, 162, 45, 14, 5, Color(0.84, 0.55, 0.46))
	_fill_rect(img, 196, 58, 16, 6, Color(0.52, 0.72, 0.58))
	# Note text lines below map.
	_fill_rect(img, 142, 80, 74, 3, Color(0.38, 0.42, 0.48))
	_fill_rect(img, 142, 88, 60, 3, Color(0.56, 0.60, 0.66))
	_fill_rect(img, 142, 96, 82, 3, Color(0.56, 0.60, 0.66))

	# 5. Sleek frosted dark taskbar at bottom.
	_fill_rect(img, 0, h - 16, w, 16, Color(0.14, 0.17, 0.24))
	_fill_rect(img, 0, h - 16, w, 1, Color(0.36, 0.44, 0.58))
	_fill_rect(img, 8, h - 12, 9, 8, Color(0.42, 0.74, 0.98))
	var bar_icons := [Color(0.95, 0.68, 0.42), Color(0.94, 0.52, 0.62), Color(0.52, 0.84, 0.66), Color(0.72, 0.64, 0.94)]
	for i in bar_icons.size():
		_fill_rect(img, 96 + i * 16, h - 12, 10, 8, bar_icons[i])
	# Clock/status pills on right.
	_fill_rect(img, w - 34, h - 11, 24, 6, Color(0.78, 0.84, 0.92))
	return ImageTexture.create_from_image(img)


func _make_art_texture(theme: String) -> ImageTexture:
	var w := 144
	var h := 104
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	match theme:
		"coastal_sunset":
			for y in h:
				var vy := float(y) / float(h)
				for x in w:
					var vx := float(x) / float(w)
					var col: Color
					if vy < 0.60:
						var t := vy / 0.60
						col = Color(0.44, 0.58, 0.80).lerp(Color(0.94, 0.72, 0.64), clampf(t * 1.1, 0.0, 1.0))
						col = col.lerp(Color(0.99, 0.87, 0.70), clampf((t - 0.55) / 0.45, 0.0, 1.0))
						var sun_d := Vector2((vx - 0.66) * 1.38, vy - 0.49).length()
						if sun_d < 0.14:
							col = col.lerp(Color(1.0, 0.96, 0.85), smoothstep(0.14, 0.04, sun_d))
					else:
						var wt := (vy - 0.60) / 0.40
						col = Color(0.72, 0.68, 0.76).lerp(Color(0.42, 0.52, 0.68), wt)
						var glow := exp(-pow((vx - 0.66) / (0.05 + wt * 0.11), 2.0))
						col = col.lerp(Color(0.99, 0.86, 0.66), glow * 0.65)
					# Distant headland + tiny lighthouse
					var hill1 := 0.61 - 0.14 * exp(-pow((vx - 0.22) / 0.22, 2.0))
					var hill2 := 0.62 - 0.09 * exp(-pow((vx - 0.84) / 0.19, 2.0))
					if vy >= hill1 and vy < 0.64:
						col = Color(0.36, 0.42, 0.56)
					if vy >= hill2 and vy < 0.64:
						col = Color(0.46, 0.48, 0.60)
					if vx > 0.205 and vx < 0.232 and vy > 0.35 and vy < 0.49:
						col = Color(0.96, 0.93, 0.88)
					img.set_pixel(x, y, col)
		"botanical_sprig":
			for y in h:
				var vy := float(y) / float(h)
				for x in w:
					var vx := float(x) / float(w)
					var bg := Color(0.965, 0.945, 0.905).lerp(Color(0.935, 0.905, 0.855), vy * 0.6)
					# Soft terracotta sun circle in upper background
					var cd := Vector2((vx - 0.58) * 1.2, vy - 0.36).length()
					if cd < 0.22:
						bg = bg.lerp(Color(0.92, 0.78, 0.68), smoothstep(0.22, 0.19, cd) * 0.55)
					# Curved stem
					var stem_x := 0.46 + 0.11 * sin((vy - 0.15) * 3.8)
					if vy > 0.16 and vy < 0.90 and absf(vx - stem_x) < 0.011:
						bg = Color(0.39, 0.48, 0.38)
					img.set_pixel(x, y, bg)
			# Paired sage-green leaves along the stem
			var leaves := [
				[0.41, 0.74, -0.55], [0.56, 0.70, 0.50],
				[0.44, 0.56, -0.60], [0.59, 0.52, 0.55],
				[0.43, 0.39, -0.50], [0.57, 0.35, 0.48],
				[0.48, 0.22, -0.10],
			]
			for lf in leaves:
				var cx: float = lf[0] * w
				var cy: float = lf[1] * h
				var ang: float = lf[2]
				var ca := cos(ang)
				var sa := sin(ang)
				for py in range(maxi(0, int(cy) - 18), mini(h, int(cy) + 18)):
					for px in range(maxi(0, int(cx) - 18), mini(w, int(cx) + 18)):
						var dx := float(px) - cx
						var dy := float(py) - cy
						var rx := dx * ca + dy * sa
						var ry := -dx * sa + dy * ca
						var d := (rx * rx) / 144.0 + (ry * ry) / 42.0
						if d < 1.0:
							var leaf_c := Color(0.46, 0.60, 0.48).lerp(Color(0.62, 0.74, 0.60), clampf(0.5 + ry / 14.0, 0.0, 1.0))
							img.set_pixel(px, py, leaf_c)
		"misty_harbor":
			for y in h:
				var vy := float(y) / float(h)
				for x in w:
					var vx := float(x) / float(w)
					var col: Color
					if vy < 0.58:
						col = Color(0.58, 0.76, 0.90).lerp(Color(0.92, 0.94, 0.95), vy / 0.58)
					else:
						col = Color(0.70, 0.83, 0.88).lerp(Color(0.48, 0.65, 0.76), (vy - 0.58) / 0.42)
					var m1 := 0.58 - 0.16 * exp(-pow((vx - 0.32) / 0.24, 2.0)) - 0.12 * exp(-pow((vx - 0.76) / 0.26, 2.0))
					var m2 := 0.60 - 0.10 * exp(-pow((vx - 0.56) / 0.22, 2.0))
					if vy >= m1 and vy < 0.61:
						col = Color(0.55, 0.68, 0.74)
					if vy >= m2 and vy < 0.61:
						col = Color(0.42, 0.56, 0.62)
					img.set_pixel(x, y, col)
			# Two minimalist white sailboats on the bay
			for bx in [48, 96]:
				for dy in range(0, 14):
					var span := int(float(dy) * 0.55)
					for dx in range(0, span + 1):
						img.set_pixel(clampi(bx + dx, 0, w - 1), clampi(62 + dy, 0, h - 1), Color(0.98, 0.97, 0.94))
				_fill_rect(img, bx - 3, 76, 14, 3, Color(0.76, 0.44, 0.36))
		_:
			# "warm_moon": pastel dusk twilight with glowing crescent/full moon and cozy hill town
			for y in h:
				var vy := float(y) / float(h)
				for x in w:
					var vx := float(x) / float(w)
					var col := Color(0.24, 0.30, 0.52).lerp(Color(0.76, 0.56, 0.62), clampf(vy * 1.15, 0.0, 1.0))
					col = col.lerp(Color(0.95, 0.78, 0.64), clampf((vy - 0.52) / 0.36, 0.0, 1.0))
					var md := Vector2((vx - 0.70) * 1.38, vy - 0.30).length()
					if md < 0.11:
						col = col.lerp(Color(1.0, 0.96, 0.82), smoothstep(0.11, 0.075, md))
					var hill := 0.74 - 0.12 * exp(-pow((vx - 0.28) / 0.30, 2.0)) - 0.08 * exp(-pow((vx - 0.80) / 0.26, 2.0))
					if vy >= hill:
						col = Color(0.24, 0.26, 0.38)
					img.set_pixel(x, y, col)
			# Tiny glowing town lights along the ridge
			for pt in [[32, 74], [38, 72], [44, 75], [52, 78], [108, 74], [115, 76]]:
				_fill_rect(img, pt[0], pt[1], 3, 3, Color(1.0, 0.88, 0.56))
	return ImageTexture.create_from_image(img)


func _make_cork_texture() -> ImageTexture:
	var w := 160
	var h := 112
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261126
	for y in h:
		for x in w:
			var n := rng.randf_range(-0.045, 0.045)
			var speck := -0.05 if rng.randf() < 0.08 else 0.0
			var c := Color(0.76 + n + speck, 0.60 + n * 0.85 + speck, 0.44 + n * 0.7 + speck)
			img.set_pixel(x, y, c)
	# Pinned pastel sticky notes & mini postcard with subtle drop shadow + pushpin.
	var notes := [
		[14, 14, 34, 34, Color(0.98, 0.93, 0.68), Color(0.86, 0.38, 0.36)],
		[58, 12, 42, 30, Color(0.95, 0.96, 0.97), Color(0.36, 0.62, 0.86)],
		[110, 16, 36, 36, Color(0.96, 0.82, 0.84), Color(0.92, 0.72, 0.30)],
		[22, 58, 46, 38, Color(0.84, 0.93, 0.86), Color(0.38, 0.68, 0.52)],
		[82, 54, 52, 42, Color(0.97, 0.95, 0.90), Color(0.86, 0.38, 0.36)],
	]
	for n in notes:
		var nx: int = n[0]; var ny: int = n[1]; var nw: int = n[2]; var nh: int = n[3]
		_fill_rect(img, nx + 2, ny + 2, nw, nh, Color(0.42, 0.32, 0.22))
		_fill_rect(img, nx, ny, nw, nh, n[4])
		# Tiny note lines
		for li in 3:
			_fill_rect(img, nx + 5, ny + 10 + li * 7, nw - 12 - (li % 2) * 6, 2, Color(0.46, 0.44, 0.42))
		# Pushpin at top center
		_fill_rect(img, nx + nw / 2 - 2, ny + 2, 4, 4, n[5])
	# Mini sky-blue photo accent inside the second card
	_fill_rect(img, 62, 18, 34, 16, Color(0.60, 0.78, 0.92))
	_fill_rect(img, 62, 28, 34, 6, Color(0.42, 0.56, 0.64))
	return ImageTexture.create_from_image(img)


func _make_desk_mat_texture() -> ImageTexture:
	var w := 128
	var h := 64
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4042
	for y in h:
		for x in w:
			var edge := (x == 3 or x == w - 4 or y == 3 or y == h - 4)
			var stitch := edge and ((x + y) % 4 < 2)
			var n := rng.randf_range(-0.018, 0.018)
			var c := Color(0.86 + n, 0.82 + n, 0.76 + n)
			if stitch:
				c = Color(0.75, 0.69, 0.62)
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)


func _fill_rect(img: Image, x0: int, y0: int, rw: int, rh: int, col: Color) -> void:
	var x1 := mini(img.get_width(), x0 + rw)
	var y1 := mini(img.get_height(), y0 + rh)
	for y in range(maxi(0, y0), y1):
		for x in range(maxi(0, x0), x1):
			img.set_pixel(x, y, col)


# ---------------------------------------------------------------------------
# Furniture Placement Helpers
# ---------------------------------------------------------------------------

func _load_bounds(stem: String) -> AABB:
	var packed := load(FURNITURE_DIR + stem + ".glb") as PackedScene
	if packed == null:
		return AABB(Vector3.ZERO, Vector3.ONE)
	var temp := packed.instantiate()
	var bounds := _subtree_aabb(temp, Transform3D.IDENTITY)
	temp.free()
	return bounds


func _place_glb(parent: Node, node_name: String, stem: String, world_pos: Vector3,
		scale_vec: Vector3, rot_y: float, align_top := false,
		material_overrides := {}, cast_shadow := false) -> Node3D:
	var pivot := Node3D.new()
	pivot.name = node_name
	pivot.position = world_pos
	pivot.rotation.y = rot_y
	pivot.scale = scale_vec
	parent.add_child(pivot)
	var packed := load(FURNITURE_DIR + stem + ".glb") as PackedScene
	if packed == null:
		push_warning("Missing bedroom furniture asset: %s%s.glb" % [FURNITURE_DIR, stem])
		return pivot
	var inst := packed.instantiate()
	_prepare_visual_subtree(inst, material_overrides, cast_shadow)
	var bounds := _subtree_aabb(inst, Transform3D.IDENTITY)
	if bounds.size != Vector3.ZERO:
		var center := bounds.position + bounds.size * 0.5
		var anchor_y := (bounds.position.y + bounds.size.y) if align_top else bounds.position.y
		inst.position = Vector3(-center.x, -anchor_y, -center.z)
	pivot.add_child(inst)
	return pivot


func _find_surface_material(root: Node, res_name: String) -> StandardMaterial3D:
	if root is MeshInstance3D:
		var mi := root as MeshInstance3D
		if mi.mesh != null:
			for surf in mi.mesh.get_surface_count():
				var m := mi.get_active_material(surf) as StandardMaterial3D
				if m != null and m.resource_name == res_name:
					return m
	for child in root.get_children():
		var found := _find_surface_material(child, res_name)
		if found != null:
			return found
	return null


func _prepare_visual_subtree(node: Node, material_overrides: Dictionary, cast_shadow: bool) -> void:
	for child in node.get_children():
		if child is CollisionObject3D:
			node.remove_child(child)
			child.free()
			continue
		_prepare_visual_subtree(child, material_overrides, cast_shadow)
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		mi.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			if cast_shadow
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)
		if mi.mesh == null:
			return
		for surf_idx in mi.mesh.get_surface_count():
			var base_mat := mi.get_active_material(surf_idx)
			if not (base_mat is StandardMaterial3D):
				continue
			var src := base_mat as StandardMaterial3D
			var rule: Variant = material_overrides.get(src.resource_name, null)
			if rule == null:
				continue
			var dup := src.duplicate() as StandardMaterial3D
			if rule.has("color"):
				dup.albedo_color = rule["color"]
			if rule.has("roughness"):
				dup.roughness = float(rule["roughness"])
			if rule.has("metallic"):
				dup.metallic = float(rule["metallic"])
			if rule.has("emission"):
				dup.emission_enabled = true
				dup.emission = rule["emission"]
				dup.emission_energy_multiplier = float(rule.get("emission_energy", 0.4))
			mi.set_surface_override_material(surf_idx, dup)


func _subtree_aabb(node: Node, parent_xf: Transform3D) -> AABB:
	var xf := parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	var merged := AABB()
	var has_any := false
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			var local_box := mi.mesh.get_aabb()
			merged = _transform_aabb(xf, local_box)
			has_any = true
	for child in node.get_children():
		var sub := _subtree_aabb(child, xf)
		if sub.size != Vector3.ZERO:
			merged = sub if not has_any else merged.merge(sub)
			has_any = true
	return merged if has_any else AABB()


func _transform_aabb(xf: Transform3D, box: AABB) -> AABB:
	var p := box.position
	var s := box.size
	var corners := [
		Vector3(p.x, p.y, p.z),
		Vector3(p.x + s.x, p.y, p.z),
		Vector3(p.x, p.y + s.y, p.z),
		Vector3(p.x + s.x, p.y + s.y, p.z),
		Vector3(p.x, p.y, p.z + s.z),
		Vector3(p.x + s.x, p.y, p.z + s.z),
		Vector3(p.x, p.y + s.y, p.z + s.z),
		Vector3(p.x + s.x, p.y + s.y, p.z + s.z),
	]
	var lo: Vector3 = xf * corners[0]
	var hi: Vector3 = lo
	for i in range(1, corners.size()):
		var pt: Vector3 = xf * corners[i]
		lo = Vector3(minf(lo.x, pt.x), minf(lo.y, pt.y), minf(lo.z, pt.z))
		hi = Vector3(maxf(hi.x, pt.x), maxf(hi.y, pt.y), maxf(hi.z, pt.z))
	return AABB(lo, hi - lo)


# ---------------------------------------------------------------------------
# Layer 2 Isolated Lights & Day/Dusk/Night Linkage
# ---------------------------------------------------------------------------

func _build_lights() -> void:
	# Counter-scale the Lights pivot so the lights keep unit global scale and use
	# main-world metres for positions and ranges.
	var lights := Node3D.new()
	lights.name = "Lights"
	lights.scale = Vector3.ONE * SKY_SCALE
	add_child(lights)
	_lights = lights

	# Primary window directional light (sunlight -> golden dusk -> cool moonlight).
	_window_sun = DirectionalLight3D.new()
	_window_sun.name = "WindowSun"
	_window_sun.light_cull_mask = BEDROOM_LAYER
	_window_sun.light_color = Color(1.0, 0.93, 0.82)
	_window_sun.light_energy = 0.72
	_window_sun.shadow_enabled = not _is_mobile_platform()
	_window_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	_window_sun.directional_shadow_split_1 = 0.22
	_window_sun.directional_shadow_max_distance = 6.0 * BEDROOM_SCALE
	_window_sun.shadow_bias = 0.03
	_window_sun.shadow_normal_bias = 1.6
	_window_sun.shadow_blur = 2.0
	_window_sun.shadow_opacity = 0.54
	_window_sun.transform = Transform3D(
		Basis.IDENTITY, Vector3(1.3, 3.1, -3.8) * BEDROOM_SCALE
	).looking_at(Vector3(-0.35, 0.55, 1.0) * BEDROOM_SCALE, Vector3.UP)
	lights.add_child(_window_sun)

	# Soft interior bounce fill.
	_interior_bounce = DirectionalLight3D.new()
	_interior_bounce.name = "InteriorBounce"
	_interior_bounce.light_cull_mask = BEDROOM_LAYER
	_interior_bounce.light_color = Color(0.96, 0.92, 0.86)
	_interior_bounce.light_energy = 0.20
	_interior_bounce.shadow_enabled = false
	_interior_bounce.transform = Transform3D(
		Basis.IDENTITY, Vector3(-0.8, 2.2, 3.0) * BEDROOM_SCALE
	).looking_at(Vector3(0.2, 1.0, -0.5) * BEDROOM_SCALE, Vector3.UP)
	lights.add_child(_interior_bounce)

	# Subtle warm fill near the ceiling pendant (repurposed at night as short-range monitor bounce).
	_ceiling_fill = OmniLight3D.new()
	_ceiling_fill.name = "CeilingFill"
	_ceiling_fill.light_cull_mask = BEDROOM_LAYER
	_ceiling_fill.position = Vector3(0.0, ROOM.y - 0.52, 1.20) * BEDROOM_SCALE
	_ceiling_fill.light_color = Color(1.0, 0.92, 0.80)
	_ceiling_fill.light_energy = 0.14
	_ceiling_fill.omni_range = 6.5 * BEDROOM_SCALE
	_ceiling_fill.shadow_enabled = false
	lights.add_child(_ceiling_fill)

	# Single warm table lamp OmniLight3D inside LampRoundTable: automatically switches on
	# at dusk/night to softly illuminate Layer 2 Yumeka and the desk without ever yellowing
	# the Layer 1 city below. Uses omni_attenuation = 0.75 so scaled light_energy (~1118)
	# stays 18x below Vulkan Forward Mobile's FP16 light-UBO ceiling (65,504).
	_desk_lamp_light = OmniLight3D.new()
	_desk_lamp_light.name = "DeskLampLight"
	_desk_lamp_light.light_cull_mask = BEDROOM_LAYER
	_desk_lamp_light.position = DESK_LAMP_POSITION * BEDROOM_SCALE
	_desk_lamp_light.light_color = Color(1.0, 0.76, 0.44)
	_desk_lamp_light.light_energy = 0.0
	_desk_lamp_light.omni_range = 4.4 * BEDROOM_SCALE
	_desk_lamp_light.omni_attenuation = 0.75
	_desk_lamp_light.shadow_enabled = false
	_desk_lamp_light.visible = false
	lights.add_child(_desk_lamp_light)


func apply_day_night(day_w: float, dusk_w: float, night_w: float, _cycle_time: float = 0.0) -> void:
	_light_weights = Vector3(day_w, dusk_w, night_w)
	var sum := maxf(day_w + dusk_w + night_w, 0.0001)
	var d := day_w / sum
	var u := dusk_w / sum
	var n := night_w / sum
	var scale_ratio := _render_scale / BEDROOM_SCALE

	if _window_sun != null:
		_window_sun.light_cull_mask = BEDROOM_LAYER
		_window_sun.light_color = Color(1.0, 0.93, 0.82) * d + Color(1.0, 0.56, 0.28) * u + Color(0.46, 0.62, 0.94) * n
		_window_sun.light_energy = 0.86 * d + 0.84 * u + 0.14 * n
		# Keep night moonlight shadow very soft so bangs/window frame never cut a hard dark line across Yumeka's eyes.
		_window_sun.shadow_opacity = 0.54 * d + 0.62 * u + 0.12 * n
		# Dusk sun slants low through the north window across Yumeka's side face and sandbox.
		var from_p := (Vector3(1.3, 3.1, -3.8) * d + Vector3(1.8, 2.45, -3.2) * u + Vector3(-0.3, 2.8, -3.6) * n) * _render_scale
		var to_p := (Vector3(-0.35, 0.55, 1.0) * d + Vector3(-0.15, 0.90, 0.65) * u + Vector3(0.05, 0.75, 0.85) * n) * _render_scale
		_window_sun.transform = Transform3D(Basis.IDENTITY, from_p).looking_at(to_p, Vector3.UP)

	if _interior_bounce != null:
		_interior_bounce.light_cull_mask = BEDROOM_LAYER
		# Keep global interior bounce gentle at night so far bedroom walls retain deep midnight-blue depth.
		_interior_bounce.light_color = Color(0.98, 0.93, 0.86) * d + Color(0.92, 0.64, 0.54) * u + Color(0.32, 0.40, 0.62) * n
		_interior_bounce.light_energy = 0.28 * d + 0.18 * u + 0.08 * n
		_interior_bounce.transform = Transform3D(
			Basis.IDENTITY, Vector3(-0.8, 2.2, 3.0) * _render_scale
		).looking_at(Vector3(0.2, 1.0, -0.5) * _render_scale, Vector3.UP)

	# Godot 4.7 Vulkan Forward Mobile applies `pow(distance, -omni_attenuation)` and packs
	# `linear_color * light_energy * PI` into FP16 (max 65,504). Keeping omni_attenuation
	# in [0.50, 0.75] lets calibrated energy (~16..1,118) deliver the exact 1:1 bedroom
	# radiance at 4 km distance while staying 18x-60x below the FP16 overflow ceiling.
	if _ceiling_fill != null:
		_ceiling_fill.light_cull_mask = BEDROOM_LAYER
		var ceil_pos := Vector3(0.0, ROOM.y - 0.52, 1.20) * _render_scale
		var desk_fill_pos := Vector3(-0.38, DESK_TOP + 0.38, -0.06) * _render_scale
		var ceil_atten := lerpf(0.50, 0.75, n)
		_ceiling_fill.position = ceil_pos.lerp(desk_fill_pos, n)
		_ceiling_fill.omni_range = lerpf(6.5, 2.0, n) * _render_scale
		_ceiling_fill.omni_attenuation = ceil_atten
		_ceiling_fill.light_color = Color(1.0, 0.92, 0.80) * d + Color(1.0, 0.76, 0.56) * u + Color(0.88, 0.86, 0.98) * n
		_ceiling_fill.light_energy = (16.0 * d + 12.0 * u + 320.0 * n) * pow(scale_ratio, ceil_atten)

	# Warm table lamp lights up automatically through dusk into night (Layer 2 ONLY).
	# At d = 4,323 m & omni_attenuation = 0.75, energy 1,118 delivers exact ~2.10 warm
	# tungsten irradiance on Yumeka's right cheek (R_ubo = 3,512 << 65,504, zero overflow).
	var lamp_energy := (420.0 * u + 1118.0 * n) * pow(scale_ratio, 0.75)
	if _desk_lamp_light != null:
		_desk_lamp_light.light_cull_mask = BEDROOM_LAYER
		_desk_lamp_light.omni_attenuation = 0.75
		_desk_lamp_light.light_energy = lamp_energy
		_desk_lamp_light.visible = lamp_energy > 0.01
	if _desk_lamp_shade_mat != null:
		_desk_lamp_shade_mat.emission = Color(1.0, 0.86, 0.58) * d + Color(1.0, 0.74, 0.36) * u + Color(1.0, 0.72, 0.32) * n
		_desk_lamp_shade_mat.emission_energy_multiplier = 0.10 * d + 0.95 * u + 1.75 * n
	if _curtain_mat != null:
		# Subtle warm inner bounce keeps sheer curtains luminous instead of turning muddy at night.
		_curtain_mat.emission_enabled = (u + n) > 0.05
		_curtain_mat.emission = Color(1.0, 0.76, 0.52) * u + Color(0.95, 0.74, 0.46) * n
		_curtain_mat.emission_energy_multiplier = 0.08 * u + 0.10 * n
	if _ceiling_lamp_shade_mat != null:
		_ceiling_lamp_shade_mat.emission_energy_multiplier = 0.22 * d + 0.16 * u + 0.04 * n
	if _monitor_mat != null:
		_monitor_mat.emission_energy_multiplier = 0.38 * d + 0.62 * u + 0.94 * n
	if _window_glass_mat != null:
		_window_glass_mat.albedo_color = Color(0.92, 0.96, 1.0, 0.11) * d \
				+ Color(1.0, 0.82, 0.66, 0.13) * u + Color(0.18, 0.26, 0.46, 0.18) * n
