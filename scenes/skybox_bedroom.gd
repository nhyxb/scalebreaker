extends Node3D
## 1:1 bedroom shell rendered inside the harbour skybox SubViewport (scenes/harbor_skybox.gd).
##新版 Phase-2 step 1: CSG walls/floor/ceiling/window with Poly Haven CC0 textures
## (assets/textures/polyhaven, all CC0), dimensionally correct gray-box furniture placeholders
## (desk, chair, bed, bookshelf — final furniture style is a later step), and the desktop
## sandbox whose inner tray is exactly 1.418 m / 6666.67 = 21.27 cm square, centred on the desk,
## mirroring the harbour footprint the scale-matched camera hovers over.

const RES_PATH := "res://assets/textures/polyhaven/"
## 1 m of harbour ↔ 0.15 mm of bedroom (1:6667). Kept in one place with the skybox sync.
const SKY_SCALE := 1.0 / 6666.67
## Inner tray side for the default 1418 m harbour, in metres.
const SANDBOX_SIDE := 0.2127

const ROOM := Vector3(4.4, 2.8, 3.6)  # width, height, depth
const WALL := 0.12
const DESK_TOP := 0.75
const WINDOW := Rect2(Vector2(0.6, 0.9), Vector2(1.7, 1.25))  # x from centre, sill height

var _mat_wall: StandardMaterial3D
var _mat_ceiling: StandardMaterial3D
var _mat_floor: StandardMaterial3D
var _mat_wood: StandardMaterial3D
var _mat_gray: StandardMaterial3D
var sandbox_anchor: Node3D


func _ready() -> void:
	_build_materials()
	_build_shell()
	_build_furniture()
	_build_sandbox()
	_build_lights()
	_build_environment()


func _build_materials() -> void:
	_mat_wall = _textured("wall_plaster", Color(1, 1, 1), Vector3(2.6, 2.6, 2.6))
	_mat_ceiling = _textured("wall_plaster", Color(0.97, 0.97, 1.0), Vector3(3.4, 3.4, 3.4))
	_mat_floor = _textured("floor_wood", Color(1, 1, 1), Vector3(2.9, 2.9, 2.9))
	_mat_wood = _textured("floor_wood", Color(0.86, 0.8, 0.72), Vector3.ONE)
	var rough := StandardMaterial3D.new()
	rough.albedo_color = Color(0.62, 0.62, 0.62)
	rough.roughness = 0.9
	_mat_gray = rough


func _textured(prefix: String, tint: Color, uv1_scale: Vector3) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var diff := load(RES_PATH + prefix + "_diff.jpg") as Texture2D
	var rough := load(RES_PATH + prefix + "_rough.jpg") as Texture2D
	if diff != null:
		mat.albedo_texture = diff
		mat.albedo_color = tint
	if rough != null:
		mat.roughness_texture = rough
		mat.roughness = 1.0
	mat.metallic = 0.0
	mat.uv1_scale = uv1_scale
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
	var floor_root := CSGCombiner3D.new()
	floor_root.name = "Shell"
	add_child(floor_root)
	# Floor: top surface at y = 0.
	_box(floor_root, Vector3(ROOM.x, 0.06, ROOM.z), Vector3(0, -0.03, 0), _mat_floor,
		CSGBox3D.OPERATION_UNION)
	# Ceiling.
	_box(floor_root, Vector3(ROOM.x, 0.06, ROOM.z), Vector3(0, ROOM.y + 0.03, 0),
		_mat_ceiling, CSGBox3D.OPERATION_UNION)
	# North wall (-Z) with the window cut out; other walls are plain slabs.
	var north := _box(floor_root, Vector3(ROOM.x, ROOM.y, WALL),
		Vector3(0, ROOM.y * 0.5, -ROOM.z * 0.5 - WALL * 0.5), _mat_wall,
		CSGBox3D.OPERATION_UNION)
	north.name = "WallNorth"
	_box(north, Vector3(WINDOW.size.x, WINDOW.size.y, WALL),
		Vector3(-WINDOW.position.x, WINDOW.position.y, 0), _mat_wall,
		CSGBox3D.OPERATION_SUBTRACTION)
	_box(floor_root, Vector3(ROOM.x, ROOM.y, WALL),
		Vector3(0, ROOM.y * 0.5, ROOM.z * 0.5 + WALL * 0.5), _mat_wall,
		CSGBox3D.OPERATION_UNION).name = "WallSouth"
	_box(floor_root, Vector3(WALL, ROOM.y, ROOM.z + WALL * 2.0),
		Vector3(-ROOM.x * 0.5 - WALL * 0.5, ROOM.y * 0.5, 0), _mat_wall,
		CSGBox3D.OPERATION_UNION).name = "WallWest"
	_box(floor_root, Vector3(WALL, ROOM.y, ROOM.z + WALL * 2.0),
		Vector3(ROOM.x * 0.5 + WALL * 0.5, ROOM.y * 0.5, 0), _mat_wall,
		CSGBox3D.OPERATION_UNION).name = "WallEast"
	# Window glass + wooden frame (the cut above leaves the opening).
	var glass := CSGBox3D.new()
	glass.size = Vector3(WINDOW.size.x - 0.06, WINDOW.size.y - 0.06, 0.015)
	glass.position = Vector3(-WINDOW.position.x, WINDOW.position.y,
			-ROOM.z * 0.5 - WALL * 0.5)
	var glass_mat := StandardMaterial3D.new()
	glass_mat.albedo_color = Color(0.86, 0.93, 0.98, 0.28)
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass_mat.roughness = 0.08
	glass_mat.metallic = 0.05
	glass_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	glass.material = glass_mat
	glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	floor_root.add_child(glass)
	# A bolder window frame that stands out from both sides of the wall.
	var frame_t := 0.07
	var frame_z := -ROOM.z * 0.5 - WALL * 0.5
	_box(floor_root, Vector3(WINDOW.size.x + frame_t * 2.0, frame_t, WALL),
		Vector3(-WINDOW.position.x, WINDOW.position.y - WINDOW.size.y * 0.5 - frame_t * 0.5,
				frame_z), _mat_wood, CSGBox3D.OPERATION_UNION)
	_box(floor_root, Vector3(WINDOW.size.x + frame_t * 2.0, frame_t, WALL),
		Vector3(-WINDOW.position.x, WINDOW.position.y + WINDOW.size.y * 0.5 + frame_t * 0.5,
				frame_z), _mat_wood, CSGBox3D.OPERATION_UNION)
	var frame_x := WINDOW.position.x - WINDOW.size.x * 0.5 - frame_t * 0.5
	_box(floor_root, Vector3(frame_t, WINDOW.size.y + frame_t * 2.0, WALL),
		Vector3(-frame_x, WINDOW.position.y, frame_z), _mat_wood, CSGBox3D.OPERATION_UNION)
	_box(floor_root, Vector3(frame_t, WINDOW.size.y + frame_t * 2.0, WALL),
		Vector3(frame_x, WINDOW.position.y, frame_z), _mat_wood, CSGBox3D.OPERATION_UNION)
	# Window sill inside the room plus a thick mullion for a clear two-pane look.
	_box(floor_root, Vector3(WINDOW.size.x + frame_t * 2.0, 0.05, 0.16),
		Vector3(-WINDOW.position.x, WINDOW.position.y - WINDOW.size.y * 0.5 - 0.03,
				-ROOM.z * 0.5 + 0.08), _mat_wood, CSGBox3D.OPERATION_UNION)
	_box(floor_root, Vector3(0.05, WINDOW.size.y, WALL),
		Vector3(-WINDOW.position.x, WINDOW.position.y, frame_z), _mat_wood,
		CSGBox3D.OPERATION_UNION)
	# Door slab on the east wall: a shallow gray inset that reads as a closed door.
	_box(floor_root, Vector3(0.02, 2.05, 0.82),
		Vector3(ROOM.x * 0.5 - 0.015, 1.025, 0.72), _mat_gray,
		CSGBox3D.OPERATION_UNION)


func _build_furniture() -> void:
	var furniture := CSGCombiner3D.new()
	furniture.name = "Furniture"
	add_child(furniture)
	# Gray-box placeholders with real-world dimensions; final furniture art is a later step.
	var desk_top := DESK_TOP
	_box(furniture, Vector3(1.4, 0.035, 0.68), Vector3(0, desk_top - 0.0175, 0), _mat_gray)
	for leg: Vector2 in [Vector2(-0.64, -0.29), Vector2(-0.64, 0.29),
			Vector2(0.64, -0.29), Vector2(0.64, 0.29)]:
		_box(furniture, Vector3(0.05, desk_top - 0.035, 0.05),
			Vector3(leg.x, (desk_top - 0.035) * 0.5, leg.y), _mat_gray)
	# Chair: seat 45x45 at 45 cm, backrest to 85 cm.
	_box(furniture, Vector3(0.44, 0.04, 0.44), Vector3(0, 0.45, 0.62), _mat_gray)
	_box(furniture, Vector3(0.44, 0.4, 0.04), Vector3(0, 0.65, 0.84), _mat_gray)
	for leg: Vector2 in [Vector2(-0.18, 0.45), Vector2(0.18, 0.45),
			Vector2(-0.18, 0.79), Vector2(0.18, 0.79)]:
		_box(furniture, Vector3(0.035, 0.43, 0.035), Vector3(leg.x, 0.215, leg.y), _mat_gray)
	# Bed: single 90x200, mattress top ~35 cm; headboard toward the north wall.
	_box(furniture, Vector3(0.9, 0.22, 2.0), Vector3(-1.55, 0.24, -0.06), _mat_gray)
	_box(furniture, Vector3(0.9, 0.05, 1.95), Vector3(-1.55, 0.375, -0.03), _mat_gray)
	_box(furniture, Vector3(0.9, 0.45, 0.06), Vector3(-1.55, 0.5, -1.06), _mat_gray)
	# Bookshelf against the north wall, east of the window.
	_box(furniture, Vector3(0.9, 1.9, 0.28), Vector3(1.35, 0.95, -1.6), _mat_gray)
	for i in 4:
		_box(furniture, Vector3(0.86, 0.03, 0.26), Vector3(1.35, 0.32 + i * 0.42, -1.6), _mat_gray)


func _build_sandbox() -> void:
	var sandbox := CSGCombiner3D.new()
	sandbox.name = "Sandbox"
	add_child(sandbox)
	# Tray floor centred on the desk top; port ground (y = 0) sits at its surface.
	const TRAY_DEPTH := 0.012
	_box(sandbox, Vector3(SANDBOX_SIDE + 0.016, TRAY_DEPTH, SANDBOX_SIDE + 0.016),
		Vector3(0, DESK_TOP + TRAY_DEPTH * 0.5, 0), _mat_gray)
	# Rim: thin wooden walls around the tray so the sandbox reads as a model base.
	var rim_h := 0.014
	var half := SANDBOX_SIDE * 0.5 + 0.008
	var rim_pos := [Vector3(0, DESK_TOP + rim_h * 0.5, -half), Vector3(0, DESK_TOP + rim_h * 0.5, half),
			Vector3(-half, DESK_TOP + rim_h * 0.5, 0), Vector3(half, DESK_TOP + rim_h * 0.5, 0)]
	var rim_size := [Vector3(SANDBOX_SIDE + 0.032, rim_h, 0.008),
			Vector3(SANDBOX_SIDE + 0.032, rim_h, 0.008),
			Vector3(0.008, rim_h, SANDBOX_SIDE + 0.016),
			Vector3(0.008, rim_h, SANDBOX_SIDE + 0.016)]
	for i in 4:
		_box(sandbox, rim_size[i], rim_pos[i], _mat_wood, CSGBox3D.OPERATION_UNION)
	# The anchor the skybox camera extrapolates from: port origin (0,0,0) lands here, in the
	# tray surface centre, facing the same axes as the harbour.
	sandbox_anchor = Node3D.new()
	sandbox_anchor.name = "SandboxAnchor"
	sandbox_anchor.position = Vector3(0, DESK_TOP + TRAY_DEPTH, 0)
	sandbox.add_child(sandbox_anchor)


func _build_lights() -> void:
	var lights := Node3D.new()
	lights.name = "Lights"
	add_child(lights)
	# Warm afternoon sun through the north window. Shadows stay off: the room only fills
	# the harbour's backdrop band, and a second shadow pass is too costly on iGPUs.
	var sun := DirectionalLight3D.new()
	sun.name = "WindowSun"
	sun.light_color = Color(1.0, 0.82, 0.6)
	sun.light_energy = 3.2
	sun.shadow_enabled = false
	lights.add_child(sun)
	sun.look_at_from_position(Vector3(1.4, 3.6, -6.4), Vector3(-0.5, 0.4, 1.6), Vector3.UP)
	# Soft warm ceiling fill so the room reads at a glance even away from the window light.
	var fill := OmniLight3D.new()
	fill.name = "CeilingFill"
	fill.position = Vector3(0.0, ROOM.y - 0.18, 0.4)
	fill.light_color = Color(0.96, 0.87, 0.78)
	fill.light_energy = 0.55
	fill.omni_range = 7.0
	fill.shadow_enabled = false
	lights.add_child(fill)


func _build_environment() -> void:
	# Ambient + tonemapping only: no glow/SSAO/SDFGI so the second viewport stays cheap on
	# the integrated GPU. The outside seen through the window is a plain sky colour.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.66, 0.76, 0.85)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.74, 0.68, 0.62)
	env.ambient_light_energy = 0.38
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.12
	var we := WorldEnvironment.new()
	we.name = "BedroomEnvironment"
	we.environment = env
	add_child(we)
