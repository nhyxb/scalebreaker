extends RefCounted
## Shared low-poly silhouettes for the three historic port lots.

enum Tile { BRICK, TOWER, SIDING, ROOF, STONE, TRIM, DOOR, RUBBLE }

const TILE_SIZE := 64
const ATLAS_SIZE := Vector2(256, 128)

static var _atlas_material: StandardMaterial3D
static var _intact_meshes: Dictionary[StringName, ArrayMesh] = {}
static var _rubble_meshes: Dictionary[HeightMapShape3D, ArrayMesh] = {}


static func intact(style: StringName, footprint: Vector3) -> Node3D:
	return _model(unit_mesh(style), footprint)


## The 1 × 1 × 1 block every building of this style is scaled from (used by the batch
## renderer, which needs one shared mesh for every copy).
static func unit_mesh(style: StringName) -> ArrayMesh:
	if not _intact_meshes.has(style):
		_intact_meshes[style] = _build_intact(style)
	return _intact_meshes[style]


static func rubble(floor_shape: HeightMapShape3D) -> Node3D:
	if not _rubble_meshes.has(floor_shape):
		_rubble_meshes[floor_shape] = _build_rubble(floor_shape)
	var model := _model(_rubble_meshes[floor_shape], Vector3.ONE)
	var mesh := model.get_child(0) as MeshInstance3D
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return model


static func _model(mesh: ArrayMesh, size: Vector3) -> Node3D:
	var model := Node3D.new()
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.scale = size
	model.add_child(visual)
	return model


static func _build_intact(style: StringName) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	match style:
		&"dockpress":
			_box(surface, Vector3(1.0, 0.10, 1.0), Vector3(0.0, 0.05, 0.0), Tile.STONE)
			_box(surface, Vector3(0.94, 0.72, 0.92), Vector3(0.0, 0.44, 0.0), Tile.BRICK)
			_box(surface, Vector3(0.98, 0.045, 0.96), Vector3(0.0, 0.77, 0.0), Tile.STONE)
			_gable(surface, Vector3(0.0, 0.79, 0.0), 1.0, 0.98, 0.17, Tile.BRICK)
			_box(surface, Vector3(0.11, 0.22, 0.14), Vector3(-0.31, 0.89, -0.21), Tile.BRICK, Tile.TRIM)
			_box(surface, Vector3(0.23, 0.23, 0.035), Vector3(0.19, 0.155, -0.467), Tile.DOOR, Tile.STONE)
		&"tidewater":
			_box(surface, Vector3(1.0, 0.12, 1.0), Vector3(0.0, 0.06, 0.0), Tile.STONE)
			_box(surface, Vector3(0.92, 0.70, 0.91), Vector3(0.0, 0.47, 0.0), Tile.TOWER)
			_box(surface, Vector3(0.96, 0.035, 0.96), Vector3(0.0, 0.805, 0.0), Tile.STONE)
			_box(surface, Vector3(0.78, 0.15, 0.75), Vector3(0.0, 0.895, 0.0), Tile.TOWER, Tile.ROOF)
			_box(surface, Vector3(0.43, 0.030, 0.44), Vector3(-0.04, 0.985, 0.03), Tile.TRIM)
			_box(surface, Vector3(0.28, 0.105, 0.033), Vector3(0.0, 0.062, -0.505), Tile.DOOR)
		_: # MarineWorks is the low, wide metal warehouse.
			_box(surface, Vector3(1.0, 0.12, 1.0), Vector3(0.0, 0.06, 0.0), Tile.STONE)
			_box(surface, Vector3(0.95, 0.65, 0.92), Vector3(0.0, 0.415, 0.0), Tile.SIDING)
			_gable(surface, Vector3(0.0, 0.74, 0.0), 1.0, 1.0, 0.24, Tile.SIDING)
			_box(surface, Vector3(0.70, 0.48, 0.037), Vector3(0.0, 0.30, -0.475), Tile.DOOR)
			_box(surface, Vector3(0.80, 0.045, 0.14), Vector3(0.0, 0.55, -0.48), Tile.TRIM)
	return _finish(surface)


static func _box(surface: SurfaceTool, size: Vector3, at: Vector3, walls: Tile, roof := Tile.ROOF) -> void:
	var x := Vector3.RIGHT * size.x * 0.5
	var y := Vector3.UP * size.y * 0.5
	var z := Vector3.BACK * size.z * 0.5
	_quad(surface, at + z, x, y, walls)
	_quad(surface, at - z, -x, y, walls)
	_quad(surface, at + x, -z, y, walls)
	_quad(surface, at - x, z, y, walls)
	_quad(surface, at + y, x, -z, roof)
	_quad(surface, at - y, x, z, roof)


static func _gable(surface: SurfaceTool, at: Vector3, width: float, depth: float, height: float, wall: Tile) -> void:
	var x := Vector3.RIGHT * width * 0.5
	var z := Vector3.BACK * depth * 0.5
	var peak := Vector3.UP * height
	_quad(surface, at + (peak + z) * 0.5, x, (peak - z) * 0.5, Tile.ROOF)
	_quad(surface, at + (peak - z) * 0.5, -x, (peak + z) * 0.5, Tile.ROOF)
	_triangle(surface, at + x + z, at + x + peak, at + x - z, wall)
	_triangle(surface, at - x - z, at - x + peak, at - x + z, wall)


static func _quad(surface: SurfaceTool, at: Vector3, right: Vector3, up: Vector3, tile: Tile) -> void:
	var normal := right.cross(up).normalized()
	var a := at - right - up
	var b := at - right + up
	var c := at + right + up
	var d := at + right - up
	_vertex(surface, a, normal, tile, Vector2(0, 1))
	_vertex(surface, b, normal, tile, Vector2(0, 0))
	_vertex(surface, c, normal, tile, Vector2(1, 0))
	_vertex(surface, a, normal, tile, Vector2(0, 1))
	_vertex(surface, c, normal, tile, Vector2(1, 0))
	_vertex(surface, d, normal, tile, Vector2(1, 1))


static func _triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, tile: Tile) -> void:
	var normal := (c - a).cross(b - a).normalized()
	_vertex(surface, a, normal, tile, Vector2(0, 1))
	_vertex(surface, b, normal, tile, Vector2(0.5, 0))
	_vertex(surface, c, normal, tile, Vector2(1, 1))


static func _vertex(surface: SurfaceTool, at: Vector3, normal: Vector3, tile: Tile, uv: Vector2) -> void:
	var pixel := Vector2(_tile_origin(tile)) + Vector2(2.0, 2.0) + uv * float(TILE_SIZE - 4)
	surface.set_uv(pixel / ATLAS_SIZE)
	surface.set_normal(normal)
	surface.add_vertex(at)


static func _build_rubble(shape: HeightMapShape3D) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var samples := shape.map_data
	var width := shape.map_width
	var depth := shape.map_depth
	var origin := Vector3(-0.5 * (width - 1), 0.0, -0.5 * (depth - 1))
	# Keep the existing collision heightmap and render a coarser version of it.
	for z in range(0, depth - 1, 2):
		for x in range(0, width - 1, 2):
			var x1 := mini(x + 2, width - 1)
			var z1 := mini(z + 2, depth - 1)
			var a := origin + Vector3(x, samples[z * width + x], z)
			var b := origin + Vector3(x1, samples[z * width + x1], z)
			var c := origin + Vector3(x1, samples[z1 * width + x1], z1)
			var d := origin + Vector3(x, samples[z1 * width + x], z1)
			if maxf(maxf(a.y, b.y), maxf(c.y, d.y)) <= 0.0:
				continue
			_triangle(surface, a, b, c, Tile.RUBBLE)
			_triangle(surface, a, c, d, Tile.RUBBLE if (x + z) % 6 != 0 else Tile.STONE)
	return _finish(surface)


static func _finish(surface: SurfaceTool) -> ArrayMesh:
	surface.index()
	var mesh := surface.commit()
	mesh.surface_set_material(0, _material())
	return mesh


static func _tile_origin(tile: Tile) -> Vector2i:
	return Vector2i(tile % 4, floori(tile / 4.0)) * TILE_SIZE


static func _material() -> StandardMaterial3D:
	if _atlas_material:
		return _atlas_material
	var image := Image.create(int(ATLAS_SIZE.x), int(ATLAS_SIZE.y), false, Image.FORMAT_RGBA8)
	var palette := [
		Color("#a45b42"), Color("#c6b99e"), Color("#467272"), Color("#495158"),
		Color("#a59a83"), Color("#41484a"), Color("#596362"), Color("#8f7361"),
	]
	for tile: Tile in Tile.values():
		_paint(image, tile, Rect2i(0, 0, TILE_SIZE, TILE_SIZE), palette[tile])
	for y in range(3, TILE_SIZE, 4):
		_paint(image, Tile.BRICK, Rect2i(0, y, TILE_SIZE, 1), Color("#784732"))
		for x in range(2 + (y % 8), TILE_SIZE, 8):
			_paint(image, Tile.BRICK, Rect2i(x, y - 3, 1, 3), Color("#884c37"))
	for x in range(4, TILE_SIZE, 4):
		_paint(image, Tile.SIDING, Rect2i(x, 0, 1, TILE_SIZE), Color("#34595e"))
		_paint(image, Tile.ROOF, Rect2i(x, 0, 1, TILE_SIZE), Color("#3c4248"))
	for y in range(2, TILE_SIZE, 5):
		_paint(image, Tile.DOOR, Rect2i(0, y, TILE_SIZE, 1), Color("#444c4f"))
	for y: int in [4, 20, 36, 50]:
		for x: int in [6, 20, 34, 48]:
			_window(image, Tile.TOWER, Rect2i(x, y, 10, 10), Color("#647b84"))
	for y: int in [7, 27, 46]:
		for x: int in [7, 25, 43]:
			_window(image, Tile.BRICK, Rect2i(x, y, 13, 14), Color("#465c66"))
	for x: int in [5, 23, 41]:
		_window(image, Tile.SIDING, Rect2i(x, 11, 17, 11), Color("#809597"))
	for y in range(3, TILE_SIZE - 6, 7):
		for x in range(2 + y % 4, TILE_SIZE - 8, 9):
			var tint: Color = palette[Tile.RUBBLE].darkened(((x * 3 + y) % 5) * 0.06)
			_paint(image, Tile.RUBBLE, Rect2i(x, y, 5 + x % 4, 3 + y % 3), tint)
	image.generate_mipmaps()
	_atlas_material = StandardMaterial3D.new()
	_atlas_material.albedo_texture = ImageTexture.create_from_image(image)
	_atlas_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_atlas_material.roughness = 0.87
	return _atlas_material


static func _window(image: Image, tile: Tile, rect: Rect2i, glass: Color) -> void:
	_paint(image, tile, rect, Color("#a79a83"))
	_paint(image, tile, rect.grow(-1), glass)
	var center := rect.position.x + rect.size.x / 2
	_paint(image, tile, Rect2i(center, rect.position.y + 1, 1, rect.size.y - 2), Color("#394e58"))


static func _paint(image: Image, tile: Tile, rect: Rect2i, color: Color) -> void:
	image.fill_rect(Rect2i(_tile_origin(tile) + rect.position, rect.size), color)
