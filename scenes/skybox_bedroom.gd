extends Node3D
## 1:1 soft Japanese cream & light natural-wood bedroom rendered inside the harbour skybox
## SubViewport (scenes/harbor_skybox.gd). Uses real Kenney Furniture Kit GLB assets
## (assets/kenney/furniture/, visual-only, zero physics collision), an airtight CSG room
## shell with baseboards and a recessed sunlit two-pane window, a 21.27 cm desktop harbour
## sandbox centred at (0, DESK_TOP, 0), and an exported `ultra_giant_anchor` above the swivel
## chair cushion ready for Phase 3 seated anime Yumeka.

const FLOOR_WOOD_DIFF := "res://assets/textures/polyhaven/floor_wood_diff.jpg"
const FURNITURE_DIR := "res://assets/kenney/furniture/"
## 1 m of harbour ↔ 0.15 mm of bedroom (1:6667). Kept in one place with the skybox sync.
const SKY_SCALE := 1.0 / 6666.67
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

## Two-pane north window centred behind the desk.
const WIN_CENTER_X := -0.05
const WIN_WIDTH := 1.84
const WIN_SILL_Y := 0.94
const WIN_HEIGHT := 1.28

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
var _window_sun: DirectionalLight3D

var sandbox_anchor: Node3D
## Anchor perched directly above the chairDesk.glb cushion, facing `sandbox_anchor`, for
## attaching the Phase 3 seated ultra-giant Yumeka model.
@export var ultra_giant_anchor: Node3D
var ultra_giant_seat_y := 0.0


func _ready() -> void:
	_build_materials()
	_build_shell()
	_build_sandbox()
	_build_furniture()
	_build_lights()
	_build_environment()


func _is_mobile_platform() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")


func set_shadows_enabled(enabled: bool) -> void:
	if _window_sun != null:
		_window_sun.shadow_enabled = enabled


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
	# Top & bottom outer frame (flush corners with jambs)
	_box(shell, Vector3(WIN_WIDTH + frame_t * 2.0 - ov * 2.0, frame_t, frame_d),
		Vector3(WIN_CENTER_X, win_top + frame_t * 0.5 - ov, frame_z), _mat_wood_trim)
	_box(shell, Vector3(WIN_WIDTH + frame_t * 2.0 - ov * 2.0, frame_t, frame_d),
		Vector3(WIN_CENTER_X, WIN_SILL_Y - frame_t * 0.5 + ov, frame_z), _mat_wood_trim)
	# Left & right outer jambs (exact span between top and bottom frame bars)
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
	var glass_mat := StandardMaterial3D.new()
	glass_mat.albedo_color = Color(0.92, 0.96, 1.0, 0.14)
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass_mat.roughness = 0.06
	glass_mat.metallic = 0.05
	glass_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	glass.material_override = glass_mat
	glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(glass)

	# Minimalist pale-wood baseboards (踢脚线) sealing every wall/floor corner cleanly.
	var base_h := 0.08
	var base_t := 0.022
	var base_y := base_h * 0.5 - 0.005  # embedded 5 mm into floor
	# North & South baseboards
	_box(shell, Vector3(ROOM.x + 0.02, base_h, base_t),
		Vector3(0.0, base_y, ROOM_Z_MIN + base_t * 0.5 - 0.004), _mat_wood_trim)
	_box(shell, Vector3(ROOM.x + 0.02, base_h, base_t),
		Vector3(0.0, base_y, ROOM_Z_MAX - base_t * 0.5 + 0.004), _mat_wood_trim)
	# West baseboard
	_box(shell, Vector3(base_t, base_h, ROOM.z + 0.02),
		Vector3(-half_x + base_t * 0.5 - 0.004, base_y, ROOM_Z_CENTER), _mat_wood_trim)
	# East baseboard split around the bedroom door
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


func _build_sandbox() -> void:
	var sandbox := Node3D.new()
	sandbox.name = "Sandbox"
	add_child(sandbox)
	# The wooden diorama frame is rendered in the main world (`District/SandboxFrame`) so the
	# city edge and tray frame share depth and never duplicate or Z-fight. Here we only place a
	# soft desk contact shadow underneath the 22.6 cm outer wood tray and align `sandbox_anchor`
	# to `DESK_TOP + SANDBOX_BASE_THICKNESS` so the tray base rests dead flush on the desk.
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
	# The anchor the skybox camera extrapolates from: port origin (0,0,0) lands here, matching
	# `District/SandboxFrame` bottom (-32 m * SKY_SCALE = -4.8 mm) exactly onto DESK_TOP.
	sandbox_anchor = Node3D.new()
	sandbox_anchor.name = "SandboxAnchor"
	sandbox_anchor.position = Vector3(0.0, DESK_TOP + SANDBOX_BASE_THICKNESS, 0.0)
	sandbox.add_child(sandbox_anchor)


func _build_furniture() -> void:
	var furniture := Node3D.new()
	furniture.name = "Furniture"
	add_child(furniture)

	# Soft Japanese cream / milk-tea / dusty-rose material harmonies for Kenney's saturated
	# coral `carpet` surfaces, keeping natural warm wood rich under direct sunlight.
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
			"color": Color(1.0, 0.95, 0.82),
			"roughness": 0.72,
			"emission": Color(1.0, 0.93, 0.75),
			"emission_energy": 0.48,
		},
		"metal": {"color": Color(0.86, 0.84, 0.80), "roughness": 0.45},
	}
	var mat_screen := {
		"metalDark": {"color": Color(0.32, 0.34, 0.37), "roughness": 0.55},
		"metal": {
			"color": Color(0.82, 0.89, 0.94),
			"roughness": 0.25,
			"emission": Color(0.76, 0.86, 0.95),
			"emission_energy": 0.22,
		},
	}
	var mat_periph := {
		"metalDark": {"color": Color(0.42, 0.44, 0.47), "roughness": 0.62},
		"metalMedium": {"color": Color(0.78, 0.78, 0.76), "roughness": 0.65},
	}

	var cast_major := not _is_mobile_platform()

	# --- 1. Study desk & swivel chair ---
	# Scale desk to exact DESK_TOP (0.75 m) and spacious 1.63 m width (1.14x X) so all desktop
	# props sit 15-26 cm clear of the 21.27 cm diorama without blocking the north window.
	var desk_probe := _load_bounds("desk")
	var desk_scale := DESK_TOP / maxf(desk_probe.size.y, 0.001)
	_place_glb(furniture, "Desk", "desk", Vector3(0.0, 0.0, 0.0),
		Vector3(desk_scale * 1.14, desk_scale, desk_scale), 0.0, false, mat_wood_soft, cast_major)

	var chair_pos := Vector3(0.0, 0.0, 0.64)
	_place_glb(furniture, "ChairDesk", "chairDesk", chair_pos,
		Vector3.ONE * CHAIR_SCALE, PI, false, mat_chair, cast_major)

	# Exported/accessible anchor above the chairDesk cushion facing `sandbox_anchor`
	# for Phase 3 seated anime Yumeka.
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
	add_child(ultra_giant_anchor)
	ultra_giant_anchor.look_at(
		Vector3(sandbox_anchor.position.x, ultra_giant_seat_y, sandbox_anchor.position.z),
		Vector3.UP,
	)

	# --- 2. Desktop landmarks pulled 15-26 cm clear of the 21.27 cm sandbox ---
	# Left flank (monitor shifted well left so the sunlit north window stays open behind the city).
	_place_glb(furniture, "ComputerScreen", "computerScreen",
		Vector3(-0.46, DESK_TOP, -0.26), Vector3.ONE * 0.98, deg_to_rad(20.0), false, mat_screen, cast_major)
	_place_glb(furniture, "ComputerKeyboard", "computerKeyboard",
		Vector3(-0.48, DESK_TOP, 0.02), Vector3.ONE * 1.12, deg_to_rad(18.0), false, mat_periph, false)
	_place_glb(furniture, "ComputerMouse", "computerMouse",
		Vector3(-0.29, DESK_TOP, 0.16), Vector3.ONE * 1.10, deg_to_rad(16.0), false, mat_periph, false)
	_place_glb(furniture, "PlantSmallDesk", "plantSmall1",
		Vector3(-0.70, DESK_TOP, 0.23), Vector3.ONE * 1.45, deg_to_rad(15.0), false, mat_wood_soft, false)
	_place_glb(furniture, "SpeakerLeft", "speakerSmall",
		Vector3(-0.74, DESK_TOP, -0.15), Vector3.ONE * 0.76, deg_to_rad(32.0), false, mat_wood_soft, false)

	# Right flank: warm glowing table lamp, upright books, right speaker (BearDesk removed).
	_place_glb(furniture, "LampRoundTable", "lampRoundTable",
		Vector3(0.48, DESK_TOP, -0.25), Vector3.ONE * 1.20, deg_to_rad(-20.0), false, mat_lamp, cast_major)
	_place_glb(furniture, "BooksDesk", "books",
		Vector3(0.47, DESK_TOP, 0.11), Vector3.ONE * 1.55, deg_to_rad(-22.0), false, mat_wood_soft, false)
	_place_glb(furniture, "SpeakerRight", "speakerSmall",
		Vector3(0.74, DESK_TOP, -0.15), Vector3.ONE * 0.76, deg_to_rad(-32.0), false, mat_wood_soft, false)

	# --- 3. Large bedroom background furniture ---
	# West wall: potted floor plant (NW), bedside nightstand, double bed with accent pillows.
	_place_glb(furniture, "PottedPlant", "pottedPlant",
		Vector3(-1.88, 0.0, -0.18), Vector3.ONE * 1.85, deg_to_rad(25.0), false, mat_wood_soft, cast_major)
	var nightstand := _place_glb(furniture, "CabinetBedDrawer", "cabinetBedDrawer",
		Vector3(-2.02, 0.0, 0.62), Vector3.ONE * 1.95, PI * 0.5, false, mat_wood_soft, cast_major)
	# Small succulent accent on the nightstand (reuses plantSmall1.glb).
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

	# Floor rug under chair / alongside bed (+2 mm to guarantee zero z-fighting with floor).
	_place_glb(furniture, "RugRounded", "rugRounded",
		Vector3(0.38, 0.002, 1.55), Vector3.ONE * 1.45, PI * 0.5, false, mat_rug, false)

	# North-east & East wall: open bookcase (with shelf books), closed-door cabinet, trashcan, coat rack.
	_place_glb(furniture, "BookcaseOpen", "bookcaseOpen",
		Vector3(1.50, 0.0, -0.26), Vector3.ONE * 1.95, 0.0, false, mat_wood_soft, cast_major)
	# Shelf decoration on open bookcase (exact shelf top Ys in bookcaseOpen.glb: 0.37 & 0.61).
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

	# Ceiling pendant light flush-mounted against y = ROOM.y.
	_place_glb(furniture, "LampSquareCeiling", "lampSquareCeiling",
		Vector3(0.0, ROOM.y, 1.20), Vector3.ONE * 2.10, 0.0, true, mat_lamp, cast_major)


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


func _prepare_visual_subtree(node: Node, material_overrides: Dictionary, cast_shadow: bool) -> void:
	# Strip any physics collider if present and set shadow casting per major/minor asset tier.
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


func _build_lights() -> void:
	var lights := Node3D.new()
	lights.name = "Lights"
	add_child(lights)
	# Warm afternoon sunlight pouring through the north window with a single lightweight
	# orthogonal shadow cascade on desktop (half-rate SubViewport keeps iGPU cost minimal).
	_window_sun = DirectionalLight3D.new()
	_window_sun.name = "WindowSun"
	_window_sun.light_color = Color(1.0, 0.92, 0.80)
	_window_sun.light_energy = 0.76
	_window_sun.shadow_enabled = not _is_mobile_platform()
	_window_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	_window_sun.directional_shadow_max_distance = 6.0
	_window_sun.shadow_bias = 0.02
	_window_sun.shadow_normal_bias = 1.2
	_window_sun.shadow_blur = 2.2
	_window_sun.shadow_opacity = 0.56
	lights.add_child(_window_sun)
	_window_sun.look_at_from_position(Vector3(1.3, 3.1, -3.8), Vector3(-0.35, 0.55, 1.0), Vector3.UP)
	# Soft warm-cream bounce fill from inside the room so shaded walls stay warm without flattening.
	var bounce := DirectionalLight3D.new()
	bounce.name = "InteriorBounce"
	bounce.light_color = Color(0.96, 0.92, 0.86)
	bounce.light_energy = 0.22
	bounce.shadow_enabled = false
	lights.add_child(bounce)
	bounce.look_at_from_position(Vector3(-0.8, 2.2, 3.0), Vector3(0.2, 1.0, -0.5), Vector3.UP)
	# Subtle warm fill near the ceiling pendant.
	var fill := OmniLight3D.new()
	fill.name = "CeilingFill"
	fill.position = Vector3(0.0, ROOM.y - 0.52, 1.20)
	fill.light_color = Color(1.0, 0.92, 0.80)
	fill.light_energy = 0.14
	fill.omni_range = 6.5
	fill.shadow_enabled = false
	lights.add_child(fill)


func _build_environment() -> void:
	# Lower ambient (0.28) + tuned exposure (0.82) prevent BG_CANVAS compositing blowout while
	# keeping warm sunlit vs shaded contrast crisp across walls, floor, desk, and chair.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.76, 0.86, 0.95)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.96, 0.91, 0.84)
	env.ambient_light_energy = 0.28
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 0.82
	var we := WorldEnvironment.new()
	we.name = "BedroomEnvironment"
	we.environment = env
	add_child(we)
