extends RefCounted
## Builds the 1,418 × 1,418 m harbor around the original four core blocks.
##
## The districts are dressed with the Kenney 3D kits under `assets/kenney/` (one directory per
## kit so every kit keeps its own colormap atlas):
##
##   commercial  midtown skyscrapers, old-harbor mid-rise blocks, awnings and parasols
##   industrial  container-terminal warehouses, refinery halls, tanks and stacks, shipyard halls
##   suburban    outer-ward houses, park trees, plaza planters
##   roads       street lights
##   watercraft  container stacks, drydock boats, moored ships, buoys
##   car         parked cars along the avenues (static MultiMesh, never a collider)
##
## Destructible kit props are `damageable.gd` nodes driven by `intact_scene` + `kit_scale`;
## the kit's real AABB decides their footprint, ground offset and blocking box. The gantry
## cranes, lighthouse and radar tower stay procedural so their silhouettes and collapse
## behaviour are unchanged.
##
## Everything static is batched into ONE MultiMeshInstance3D per asset for the whole map
## (roads, lot pads, trees, street lights, cars, bollards) instead of the old 108 m render
## chunks: 2,117 chipped MultiMeshes became a few dozen global ones and the road tiles are
## pruned to their visible faces. Buildings are drawn by `scenes/district_batches.gd`
## (near detail / far low-detail / ruins), so only the individual scenery props under
## `Scenery` are still culled by `render_chunk()`.

const DAMAGEABLE_SCRIPT := preload("res://scenes/damageable.gd")
const CityNightLights := preload("res://scenes/city_night_lights.gd")

const ROAD_STRAIGHT := preload("res://assets/district/roads/RoadStraight.glb")
const ROAD_CROSS := preload("res://assets/district/roads/RoadCross.glb")
const ROAD_TEE := preload("res://assets/district/roads/RoadTee.glb")
const ROAD_BEND := preload("res://assets/district/roads/RoadBend90.glb")

const DOCKPRESS_FLOOR := preload("res://assets/district/ruin_collision/DockPress.tres")

const TIDEWATER_FLOOR := preload("res://assets/district/ruin_collision/Tidewater.tres")

const MARINEWORKS_FLOOR := preload("res://assets/district/ruin_collision/MarineWorks.tres")

const BLOCK_STEP := 36.0
const TILE_STEP := 12.0
const QUAY_MARGIN := 20.0
const RENDER_CHUNK_SIZE := 108.0

# Zone identifiers for the harbor blocks.
const ZONE_CORE := 0
const ZONE_PARK := 1
const ZONE_PLAZA := 2
const ZONE_HIGHRISE := 3
const ZONE_CONTAINERS := 4
const ZONE_REFINERY := 5
const ZONE_SHIPYARD := 6
const ZONE_HISTORIC := 7
const ZONE_OLDCORE := 8

# Bitmask for road neighbor connectivity
const DIR_N := 1
const DIR_S := 2
const DIR_E := 4
const DIR_W := 8

# ---------------------------------------------------------------------------
# Kenney kit catalogs ("<pack>/<model>"; the pack directory holds its own atlas)
# ---------------------------------------------------------------------------

const KENNEY_ROOT := "res://assets/kenney/"
const KIT_SCALE := 12.0

const HIGHRISE_LANDMARKS: PackedStringArray = [
	"commercial/building-skyscraper-a",
	"commercial/building-skyscraper-b",
	"commercial/building-skyscraper-c",
	"commercial/building-skyscraper-d",
	"commercial/building-skyscraper-e",
]
const MIDRISE_TOWERS: PackedStringArray = [
	"commercial/building-l",
	"commercial/building-m",
	"commercial/building-n",
]
const OLD_HARBOR_BLOCKS: PackedStringArray = [
	"commercial/building-a", "commercial/building-b", "commercial/building-c",
	"commercial/building-d", "commercial/building-e", "commercial/building-f",
	"commercial/building-g", "commercial/building-h", "commercial/building-i",
]
const OLD_HARBOR_DETAILS: PackedStringArray = [
	"commercial/detail-awning",
	"commercial/detail-awning-wide",
]
const TERMINAL_WAREHOUSES: PackedStringArray = [
	"industrial/building-h", "industrial/building-i", "industrial/building-j",
	"industrial/building-k", "industrial/building-p", "industrial/building-s",
]
const REFINERY_HALLS: PackedStringArray = [
	"industrial/building-a", "industrial/building-b", "industrial/building-e",
	"industrial/building-f", "industrial/building-m",
]
const SHIPYARD_HALLS: PackedStringArray = [
	"industrial/building-c", "industrial/building-l", "industrial/building-q",
	"industrial/building-r", "industrial/building-t",
]
const CONTAINER_MODELS: PackedStringArray = [
	"watercraft/cargo-container-a",
	"watercraft/cargo-container-b",
	"watercraft/cargo-container-c",
]
const CONTAINER_PILES: PackedStringArray = [
	"watercraft/cargo-pile-a",
	"watercraft/cargo-pile-b",
]
const SUBURBAN_HOUSES: PackedStringArray = [
	"suburban/building-type-a", "suburban/building-type-b", "suburban/building-type-c",
	"suburban/building-type-d", "suburban/building-type-e", "suburban/building-type-f",
	"suburban/building-type-g", "suburban/building-type-h", "suburban/building-type-i",
	"suburban/building-type-j",
]
const PARK_TREES: PackedStringArray = ["suburban/tree-large", "suburban/tree-small"]
const STREET_LIGHTS: PackedStringArray = ["roads/light-curved", "roads/light-square"]
const HARBOR_SHIPS: PackedStringArray = [
	"watercraft/ship-cargo-a",
	"watercraft/ship-cargo-b",
	"watercraft/ship-cargo-c",
]
const MOORED_BOATS: PackedStringArray = [
	"watercraft/boat-fishing-small",
	"watercraft/boat-tug-a",
	"watercraft/boat-tug-b",
]
const DRYDOCK_BOATS: PackedStringArray = [
	"watercraft/boat-tug-a",
	"watercraft/boat-tug-b",
	"watercraft/boat-tow-a",
	"watercraft/boat-tow-b",
]
const PARKED_CARS: PackedStringArray = [
	"car/sedan", "car/suv", "car/taxi", "car/van", "car/delivery",
	"car/truck", "car/police", "car/firetruck", "car/ambulance",
]

const KIT_SCALE_TREE := 11.0
const KIT_SCALE_LIGHT := 12.0
const KIT_SCALE_AWNING := 8.0
const KIT_SCALE_PLANTER := 12.0
const KIT_SCALE_PARASOL := 10.0
const KIT_SCALE_CONTAINER := 4.0
const KIT_SCALE_BOAT := 4.0
const KIT_SCALE_SHIP := 6.0
const KIT_SCALE_BUOY := 4.0
const KIT_SCALE_CAR := 1.25

static var _mats: Dictionary = {}
static var _road_tile_meshes: Dictionary = {}
static var _ground_materials: Dictionary[Material, Material] = {}
static var _surface_grain: NoiseTexture2D
static var _kit_scenes: Dictionary = {}
static var _kit_merged: Dictionary = {}


static func populate(district: Node3D, micro_ground: bool, half_land: float) -> PackedVector3Array:
	_ensure_materials()
	var roads_node: Node3D = district.get_node("Roads")
	var lots_node: Node3D = district.get_node("Lots")
	var targets_node: Node3D = district.get_node("Targets")

	var scenery := Node3D.new()
	scenery.name = "Scenery"
	district.add_child(scenery)
	# Global, always-visible batches live outside `Scenery` so the chunk culling that keeps
	# the small props cheap never hides the whole harbour.
	var batches := Node3D.new()
	batches.name = "Batches"
	district.add_child(batches)

	var tree_transforms: Array[Transform3D] = []
	var tree_scales: Array[float] = []
	var lamp_transforms: Array[Transform3D] = []
	var bollard_transforms: Array[Transform3D] = []
	var car_transforms: Dictionary[String, Array] = {}
	var lot_pads: Dictionary[Material, Array] = {}

	var half_blocks := floori((half_land - QUAY_MARGIN) / BLOCK_STEP)
	var core_road_edge := mini(3, floori((half_land - TILE_STEP * 0.5) / TILE_STEP))
	var road_edge := maxi(half_blocks * 3, core_road_edge)
	var spawn_points := _build_roads(roads_node, lamp_transforms, car_transforms, micro_ground, road_edge)
	if road_edge < 0:
		spawn_points.append(Vector3.UP * 0.02)
	elif road_edge < 3:
		var end := minf(half_land - 8.0, road_edge * TILE_STEP + 4.0)
		if end > 0.0:
			for direction in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT]:
				spawn_points.append(direction * end + Vector3.UP * 0.02)
	_build_sandbox_frame(district, half_land)
	_build_seawalls_and_maritime(bollard_transforms, half_land)

	var building_id := 1
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261122

	for bx in range(-half_blocks, half_blocks):
		for bz in range(-half_blocks, half_blocks):
			var zone := _zone_of(bx, bz)
			if zone == ZONE_CORE:
				continue
			var center := Vector3(bx * BLOCK_STEP + 18.0, 0.0, bz * BLOCK_STEP + 18.0)
			_add_lot_pad(lot_pads, center, zone)
			match zone:
				ZONE_PARK:
					_build_park_block(scenery, center, bx, bz, rng, tree_transforms, tree_scales, micro_ground)
				ZONE_PLAZA:
					_build_plaza_block(scenery, center, bx, bz, tree_transforms, tree_scales, micro_ground)
				ZONE_HIGHRISE:
					building_id = _build_highrise_block(targets_node, center, bx, bz, rng, building_id,
							tree_transforms, tree_scales)
				ZONE_OLDCORE:
					building_id = _build_oldharbor_block(targets_node, scenery, center, bx, bz, rng, building_id)
				ZONE_CONTAINERS:
					building_id = _build_container_block(targets_node, scenery, center, bx, bz, rng, building_id, half_land)
				ZONE_REFINERY:
					building_id = _build_refinery_block(targets_node, scenery, center, bx, bz, rng, building_id)
				ZONE_SHIPYARD:
					building_id = _build_shipyard_block(targets_node, scenery, center, bx, bz, rng, building_id)
				ZONE_HISTORIC:
					building_id = _build_historic_block(targets_node, center, bx, bz, rng, building_id,
							tree_transforms, tree_scales)

	_batch_lot_pads(lots_node, lot_pads, micro_ground)

	# Keep the coast clear of the original blocks on compact maps.
	if half_blocks > 0:
		_add_lighthouse(targets_node, Vector3(half_land - 12.0, 0.02, -half_land + 12.0))
		_add_radar_tower(targets_node, Vector3(-half_land + 12.0, 0.02, -half_land + 12.0))
		_build_waterfront_quays(targets_node, scenery, rng, building_id, half_land)

	# Batch-render all trees, streetlamps, parked cars and quay bollards, one MultiMesh each.
	_build_tree_multimesh(batches, tree_transforms, tree_scales)
	_build_lamp_multimesh(batches, lamp_transforms)
	_build_car_multimesh(batches, car_transforms)
	_build_bollard_multimesh(batches, bollard_transforms)
	return spawn_points


static func _zone_of(bx: int, bz: int) -> int:
	# Preserve original 2x2 central core ([-36..+36]^2) untouched.
	if bx >= -1 and bx <= 0 and bz >= -1 and bz <= 0:
		return ZONE_CORE
	# Open welcoming plaza just south of GiantSpawn & north civic park so center stays breathable.
	if (bx == -1 or bx == 0) and bz == 1:
		return ZONE_PLAZA
	if (bx == -1 or bx == 0) and bz == -2:
		return ZONE_PARK
	if (bx == 2 and (bz == -1 or bz == 0)) or (bx == -3 and bz == 0) or (bx == -2 and bz == -2):
		return ZONE_PARK
	if bx == 1 and bz == 1:
		return ZONE_PLAZA
	# The old-harbor ring hugging the preserved core: commercial mid-rise blocks with awnings.
	if absi(bx) <= 2 and absi(bz) <= 2:
		return ZONE_OLDCORE
	# Repeat civic spaces in the outer wards so the large industrial zones
	# have open landmarks and a mix of short and long sightlines.
	if maxi(absi(bx), absi(bz)) > 5:
		if posmod(bx - 2, 7) == 0 and posmod(bz - 2, 7) == 0:
			return ZONE_PLAZA
		if posmod(bx * 5 + bz * 3, 17) < 2:
			return ZONE_PARK
		if posmod(bx, 7) in [5, 6] and posmod(bz, 6) < 2:
			return ZONE_HISTORIC
	# Northwest: Petrochemical refinery & silo industrial complex.
	if bx <= -2 and bz <= -2:
		return ZONE_REFINERY
	# Southwest: Heavy shipyard, drydocks & arched hangars.
	if bx <= -2 and bz >= 1:
		return ZONE_SHIPYARD
	# South & Southeast waterfront: Container freight terminal.
	if bz >= 2 and bx >= -1:
		return ZONE_CONTAINERS
	if bx == 4 and bz >= 0:
		return ZONE_CONTAINERS
	# East & Northeast: Midtown glass high-rises & harbor headquarters towers.
	if bx >= 1 and bz <= 0:
		if (bx == 1 and (bz == -1 or bz == 0)):
			return ZONE_HISTORIC
		return ZONE_HIGHRISE
	if bx >= -1 and bx <= 0 and bz <= -3:
		return ZONE_HIGHRISE
	# Remaining transitional blocks around the central core: historic brick docklands.
	return ZONE_HISTORIC


# ---------------------------------------------------------------------------
# Road Network (11x11 avenues on 12m grid, cleanly upgrading core perimeter)
# ---------------------------------------------------------------------------

static func _build_roads(roads_node: Node3D, lamps: Array[Transform3D],
		cars: Dictionary[String, Array], micro_ground: bool, road_edge: int) -> PackedVector3Array:
	for child in roads_node.get_children():
		roads_node.remove_child(child)
		child.queue_free()

	var spawn_points := PackedVector3Array()
	var tile_groups: Dictionary[PackedScene, Array] = {}

	# Avenues sit at every multiple of three tiles.
	# Skip a few interior cross-segments inside merged superblocks (south freight yard & drydock)
	# so the grid doesn't feel like a monotonous uniform checkerboard.
	var road_cells := {}
	for gx in range(-road_edge, road_edge + 1):
		for gz in range(-road_edge, road_edge + 1):
			var on_v := (gx % 3 == 0)
			var on_h := (gz % 3 == 0)
			if not (on_v or on_h):
				continue
			# Open superblock gaps: merge container yard (bx 1..2, bz 3), drydock (bx -4..-3, bz 3),
			# north park (bx -1..0, bz -2), and refinery yard (bx -4..-3, bz -4).
			if gx == 6 and gz > 9 and gz < 12:
				continue
			if gx == -9 and gz > 9 and gz < 12:
				continue
			if gx == -9 and gz > -12 and gz < -9:
				continue
			if gx == 0 and gz > -6 and gz < -3:
				continue
			road_cells[Vector2i(gx, gz)] = true

	for key: Vector2i in road_cells.keys():
		var gx := key.x
		var gz := key.y
		var mask := 0
		if road_cells.has(Vector2i(gx, gz - 1)):
			mask |= DIR_N
		if road_cells.has(Vector2i(gx, gz + 1)):
			mask |= DIR_S
		if road_cells.has(Vector2i(gx + 1, gz)):
			mask |= DIR_E
		if road_cells.has(Vector2i(gx - 1, gz)):
			mask |= DIR_W

		var scene: PackedScene = ROAD_STRAIGHT
		var rot_y := 0.0
		match mask:
			15:
				scene = ROAD_CROSS
				rot_y = 0.0
			7: # N+S+E (missing W)
				scene = ROAD_TEE
				rot_y = 3.0 * PI * 0.5
			11: # N+S+W (missing E)
				scene = ROAD_TEE
				rot_y = PI * 0.5
			13: # E+W+N (missing S)
				scene = ROAD_TEE
				rot_y = 0.0
			14: # E+W+S (missing N)
				scene = ROAD_TEE
				rot_y = PI
			5: # E+N
				scene = ROAD_BEND
				rot_y = 0.0
			9: # W+N
				scene = ROAD_BEND
				rot_y = PI * 0.5
			10: # W+S
				scene = ROAD_BEND
				rot_y = PI
			6: # E+S
				scene = ROAD_BEND
				rot_y = 3.0 * PI * 0.5
			12, 4, 8: # E-W straight
				scene = ROAD_STRAIGHT
				rot_y = PI * 0.5
			_: # N-S straight
				scene = ROAD_STRAIGHT
				rot_y = 0.0

		var tile_position := Vector3(gx * TILE_STEP, 0.0 if micro_ground else 0.017, gz * TILE_STEP)
		var tiles: Array = tile_groups.get_or_add(scene, [])
		tiles.append(Transform3D(Basis(Vector3.UP, rot_y), tile_position))
		spawn_points.append(Vector3(tile_position.x, 0.02, tile_position.z))

		# Place streetlamps cleanly along avenues at mid-block intervals (outside core spawn points).
		# The kit lamp arm points along -Z, so each pose is turned to face the carriageway.
		if mask == (DIR_N | DIR_S) and abs(gz) % 3 == 1 and abs(gx) % 6 == 0:
			var px := gx * TILE_STEP
			var pz := gz * TILE_STEP
			lamps.append(Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(px + 5.6, 0.0, pz)))
			lamps.append(Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(px - 5.6, 0.0, pz)))
		elif mask == (DIR_E | DIR_W) and abs(gx) % 3 == 1 and abs(gz) % 6 == 0:
			var px := gx * TILE_STEP
			var pz := gz * TILE_STEP
			lamps.append(Transform3D(Basis(Vector3.UP, PI), Vector3(px, 0.0, pz - 5.6)))
			lamps.append(Transform3D(Basis.IDENTITY, Vector3(px, 0.0, pz + 5.6)))

		# Parked cars near the core: static kit dressing with no collider at all.
		var parked := mask == (DIR_N | DIR_S) or mask == (DIR_E | DIR_W)
		if parked and absi(gx) <= 16 and absi(gz) <= 16 and posmod(gx * 31 + gz * 17, 5) == 0:
			var model: String = PARKED_CARS[posmod(gx * 7 + gz * 13, PARKED_CARS.size())]
			var lane := 4.35 if posmod(gx + gz, 2) == 0 else -4.35
			var facing := 0.0 if posmod(gx + 3 * gz, 4) < 2 else PI
			var pose := Transform3D()
			if mask == (DIR_N | DIR_S):
				pose = Transform3D(Basis(Vector3.UP, facing), tile_position + Vector3(lane, 0.03, 0.0))
			else:
				pose = Transform3D(Basis(Vector3.UP, facing + PI * 0.5), tile_position + Vector3(0.0, 0.03, lane))
			pose.basis = pose.basis.scaled(Vector3.ONE * KIT_SCALE_CAR)
			var group: Array = cars.get_or_add(model, [])
			group.append(pose)

	_build_road_layers(roads_node, tile_groups, micro_ground)
	return spawn_points


## Detailed tiles for the whole map in one MultiMesh per tile type. The authored asphalt and
## sidewalk are replaced by flat quads (their textures are kept, planar UVs) because the kit
## tiles carry 4,562 triangles per intersection, almost all of it sidewalk bevels; the paint,
## gutters and markings keep their original geometry.
static func _build_road_layers(roads_node: Node3D, tile_groups: Dictionary,
		micro_ground: bool) -> void:
	for scene: PackedScene in tile_groups:
		var transforms: Array[Transform3D] = []
		transforms.assign(tile_groups[scene])
		var mesh := _road_tile_mesh(scene, micro_ground)
		if mesh != null:
			_batch_mesh(roads_node, mesh, transforms,
					"road/" + scene.resource_path.get_file().get_basename())


## Road triangles below this area (20 cm², roughly a 4.5 cm equilateral) are invisible at
## gameplay distance and account for most of the 4,562-triangle intersection tile.
const ROAD_MIN_AREA := 0.002
## Faces pointing further down than this are the slab underside: always hidden.
const ROAD_MIN_NORMAL_Y := -0.3
## Trianges entirely below this local height are buried under the ground plane.
const ROAD_MIN_Y := -0.02


## Builds one draw-call tile mesh for a road tile type: every visible face is kept at its
## original position/UV, the sub-centimetre bevels, slab backs and buried faces are dropped,
## and all surfaces sharing a material are merged into a single surface.
static func _road_tile_mesh(scene: PackedScene, micro_ground: bool) -> ArrayMesh:
	var key := "%s|%s" % [scene.resource_path, micro_ground]
	if _road_tile_meshes.has(key):
		return _road_tile_meshes[key]
	var prototype := scene.instantiate() as Node3D
	var groups: Dictionary = {}
	for part: MeshInstance3D in prototype.find_children("*", "MeshInstance3D", true, false):
		var local := part.transform
		var parent := part.get_parent() as Node3D
		while parent != prototype and parent != null:
			local = parent.transform * local
			parent = parent.get_parent() as Node3D
		local = prototype.transform * local
		var mesh := part.mesh
		if mesh == null:
			continue
		for surface in mesh.get_surface_count():
			var surface_material := mesh.surface_get_material(surface)
			var surface_name := String(surface_material.resource_name) if surface_material != null else ""
			if surface_name.contains("Asphalt"):
				# One flat slab under everything; the authored paint stays on top of it.
				_append_flat_slabs(groups, surface_material, true, local, micro_ground)
				continue
			if surface_name.contains("Formed_Concrete"):
				# The pavement is rebuilt from its own top faces on a 1 m grid: the authored
				# surface is 2,752 bevelled triangles per intersection and cannot be pruned
				# without punching holes in the sidewalk.
				_append_pavement(groups, surface_material, surface, local, mesh, micro_ground)
				continue
			var arrays: Array = mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] \
					if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] \
					if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] \
					if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var material := surface_material
			var corner_has_normals := normals.size() >= vertices.size()
			var group: Dictionary = groups.get_or_add(material, {
				"vertices": PackedVector3Array(), "normals": PackedVector3Array(),
				"uvs": PackedVector2Array(), "indices": PackedInt32Array()})
			var tris: int = (indices.size() if not indices.is_empty() else vertices.size()) / 3
			for t in tris:
				var i0: int = indices[t * 3] if not indices.is_empty() else t * 3
				var i1: int = indices[t * 3 + 1] if not indices.is_empty() else t * 3 + 1
				var i2: int = indices[t * 3 + 2] if not indices.is_empty() else t * 3 + 2
				var a: Vector3 = local * vertices[i0]
				var b: Vector3 = local * vertices[i1]
				var c: Vector3 = local * vertices[i2]
				var cross := (b - a).cross(c - a)
				if cross.length() * 0.5 < ROAD_MIN_AREA:
					continue
				# Which way a face points comes from the authored vertex normals, not the
				# cross product: the GLB uses the opposite winding convention, so testing the
				# geometric normal kept the slab undersides and erased the whole road surface.
				var facing := Vector3.UP
				if corner_has_normals:
					facing = (normals[i0] + normals[i1] + normals[i2]).normalized()
				if (local.basis * facing).normalized().y < ROAD_MIN_NORMAL_Y:
					continue
				if maxf(a.y, maxf(b.y, c.y)) < ROAD_MIN_Y:
					continue
				var base: int = group["vertices"].size()
				for corner: int in [i0, i1, i2]:
					var point: Vector3 = local * vertices[corner]
					if micro_ground:
						point.y = minf(minf(point.y, 0.0063) * 0.65
								+ maxf(point.y - 0.0063, 0.0) * 0.012 - 0.0043, 0.0015)
					group["vertices"].append(point)
					group["normals"].append((local.basis * (normals[corner]
							if corner < normals.size() else Vector3.UP)).normalized())
					group["uvs"].append(uvs[corner] if corner < uvs.size() else Vector2.ZERO)
				group["indices"].append(base)
				group["indices"].append(base + 1)
				group["indices"].append(base + 2)
	prototype.free()
	var merged := ArrayMesh.new()
	var grain := surface_grain_texture() if micro_ground else null
	for material: Material in groups:
		var group: Dictionary = groups[material]
		if group["indices"].is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = group["vertices"]
		arrays[Mesh.ARRAY_NORMAL] = group["normals"]
		arrays[Mesh.ARRAY_TEX_UV] = group["uvs"]
		arrays[Mesh.ARRAY_INDEX] = group["indices"]
		merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		merged.surface_set_material(merged.get_surface_count() - 1,
				CityNightLights.shadowed_surface_material(material, grain))
	_road_tile_meshes[key] = merged
	return merged


## Flat asphalt slab plus the sidewalk quads for one tile, in the tile's own space.
## `KIT_SIDEWALK` is the band width taken from the authored tiles (12 m tile, ~7 m road).
const KIT_SIDEWALK := 2.45
const KIT_SIDEWALK_TOP := 0.15


## Rebuilds the pavement from the authored top faces on a 1 m grid: keeps the real sidewalk
## outline (corners, straights, closed sides) at ~100 triangles instead of 2,752.
const PAVEMENT_CELL := 1.0


static func _append_pavement(groups: Dictionary, material: Material, surface: int,
		local: Transform3D, mesh: Mesh, micro_ground: bool) -> void:
	var arrays: Array = mesh.surface_get_arrays(surface)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] \
			if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] \
			if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var tris: int = (indices.size() if not indices.is_empty() else vertices.size()) / 3
	var cells: Dictionary = {}
	var half := PAVEMENT_CELL * 0.5
	for t in tris:
		var i0: int = indices[t * 3] if not indices.is_empty() else t * 3
		var i1: int = indices[t * 3 + 1] if not indices.is_empty() else t * 3 + 1
		var i2: int = indices[t * 3 + 2] if not indices.is_empty() else t * 3 + 2
		if normals.size() >= vertices.size():
			var facing := (normals[i0] + normals[i1] + normals[i2]).normalized()
			if facing.y < 0.7:
				continue
		var a: Vector3 = local * vertices[i0]
		var b: Vector3 = local * vertices[i1]
		var c: Vector3 = local * vertices[i2]
		var min_x := minf(a.x, minf(b.x, c.x))
		var max_x := maxf(a.x, maxf(b.x, c.x))
		var min_z := minf(a.z, minf(b.z, c.z))
		var max_z := maxf(a.z, maxf(b.z, c.z))
		var start_x := floori((min_x - half) / PAVEMENT_CELL)
		var end_x := ceili((max_x + half) / PAVEMENT_CELL)
		var start_z := floori((min_z - half) / PAVEMENT_CELL)
		var end_z := ceili((max_z + half) / PAVEMENT_CELL)
		for cx in range(start_x, end_x):
			for cz in range(start_z, end_z):
				var point := Vector2((float(cx) + 0.5) * PAVEMENT_CELL,
						(float(cz) + 0.5) * PAVEMENT_CELL)
				var heights := _triangle_heights(a, b, c, point)
				if heights.is_empty():
					continue
				var key := Vector2i(cx, cz)
				var previous: float = cells.get(key, -INF)
				var top: float = heights[0]
				if top > previous:
					cells[key] = top
	for key: Vector2i in cells:
		var origin := Vector2(float(key.x) * PAVEMENT_CELL, float(key.y) * PAVEMENT_CELL)
		_append_vertex_pair(groups, material, origin, cells[key], local, micro_ground)


## Height of the triangle at a 2D point when the point is inside it, else an empty array.
static func _triangle_heights(a: Vector3, b: Vector3, c: Vector3, point: Vector2) -> Array:
	var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(d) < 0.0001:
		return []
	var wa := ((b.z - c.z) * (point.x - c.x) + (c.x - b.x) * (point.y - c.z)) / d
	var wb := ((c.z - a.z) * (point.x - c.x) + (a.x - c.x) * (point.y - c.z)) / d
	var wc := 1.0 - wa - wb
	if wa < -0.001 or wb < -0.001 or wc < -0.001:
		return []
	return [wa * a.y + wb * b.y + wc * c.y]


static func _append_vertex_pair(groups: Dictionary, material: Material, origin: Vector2,
		height: float, local: Transform3D, micro_ground: bool) -> void:
	var size := PAVEMENT_CELL
	var corners := [
		Vector3(origin.x, height, origin.y),
		Vector3(origin.x + size, height, origin.y),
		Vector3(origin.x + size, height, origin.y + size),
		Vector3(origin.x, height, origin.y + size),
	]
	for index: int in [0, 1, 2, 0, 2, 3]:
		var point: Vector3 = local * corners[index]
		var normal := (local.basis * Vector3.UP).normalized()
		if micro_ground:
			point.y = minf(minf(point.y, 0.0063) * 0.65
					+ maxf(point.y - 0.0063, 0.0) * 0.012 - 0.0043, 0.0015)
		_append_vertex(groups, material, point, normal, Vector2(point.x, point.z) * (1.0 / 3.0))


static func _append_flat_slabs(groups: Dictionary, material: Material, asphalt: bool,
		local: Transform3D, micro_ground: bool) -> void:
	# The asphalt sits a centimetre under the authored paint so the markings never z-fight
	# with the slab; the tile itself is placed at y = 0.017, so this stays above the ground.
	var height := -0.010 if asphalt else KIT_SIDEWALK_TOP
	var rects: Array = [Rect2(-6.0, -6.0, 12.0, 12.0)]
	for rect: Rect2 in rects:
		var a := Vector3(rect.position.x, height, rect.position.y)
		var b := Vector3(rect.end.x, height, rect.position.y)
		var c := Vector3(rect.end.x, height, rect.end.y)
		var d := Vector3(rect.position.x, height, rect.end.y)
		for point: Vector3 in [a, b, c, a, c, d]:
			var world: Vector3 = local * point
			var normal := (local.basis * Vector3.UP).normalized()
			if micro_ground:
				world.y = minf(minf(world.y, 0.0063) * 0.65
						+ maxf(world.y - 0.0063, 0.0) * 0.012 - 0.0043, 0.0015)
			# Both kit atlases map one UV unit to 3 m (the authored -2..2 range over a 12 m
			# tile), so the flat slabs reuse exactly that scale.
			_append_vertex(groups, material, world, normal,
					Vector2(world.x, world.z) * (1.0 / 3.0))


static func _append_vertex(groups: Dictionary, material: Material, point: Vector3,
		normal: Vector3, uv: Vector2) -> void:
	var group: Dictionary = groups.get_or_add(material, {
		"vertices": PackedVector3Array(), "normals": PackedVector3Array(),
		"uvs": PackedVector2Array(), "indices": PackedInt32Array()})
	group["indices"].append(group["vertices"].size())
	group["vertices"].append(point)
	group["normals"].append(normal)
	group["uvs"].append(uv)


static func surface_grain_texture() -> NoiseTexture2D:
	if _surface_grain == null:
		var noise := FastNoiseLite.new()
		noise.frequency = 0.28
		var tones := Gradient.new()
		tones.colors = PackedColorArray([Color(0.57, 0.57, 0.57), Color.WHITE])
		_surface_grain = NoiseTexture2D.new()
		_surface_grain.width = 256
		_surface_grain.height = 256
		_surface_grain.seamless = true
		_surface_grain.generate_mipmaps = true
		_surface_grain.color_ramp = tones
		_surface_grain.noise = noise
	return _surface_grain


static func ground_detail(source: Material) -> Material:
	if not source is BaseMaterial3D:
		return source
	if _ground_materials.has(source):
		return _ground_materials[source]
	var grain := surface_grain_texture()
	var material := source.duplicate() as BaseMaterial3D
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	material.uv2_triplanar = true
	material.uv2_world_triplanar = true
	material.uv2_scale = Vector3.ONE * 5.0
	material.detail_enabled = true
	material.detail_uv_layer = BaseMaterial3D.DETAIL_UV_2
	material.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
	material.detail_albedo = grain
	_ground_materials[source] = material
	return material


# ---------------------------------------------------------------------------
# Kenney kit helpers
# ---------------------------------------------------------------------------

static func kit(spec: String) -> PackedScene:
	if _kit_scenes.has(spec):
		return _kit_scenes[spec]
	var scene := load(KENNEY_ROOT + spec + ".glb") as PackedScene
	if scene == null:
		push_error("district: missing Kenney asset " + spec)
	_kit_scenes[spec] = scene
	return scene


static func kit_bounds(spec: String) -> AABB:
	var scene := kit(spec)
	if scene == null:
		return AABB(Vector3.ZERO, Vector3.ONE)
	return DAMAGEABLE_SCRIPT.kit_bounds(scene)


## Adds one static kit prop, grounded on y = 0 and centred on the node origin.
static func _add_kit_scenery(parent: Node3D, spec: String, at: Vector3, rot_y: float,
		magnification: float) -> Node3D:
	var scene := kit(spec)
	if scene == null:
		return null
	var bounds := kit_bounds(spec)
	var center := bounds.get_center()
	var root := Node3D.new()
	root.name = spec.replace("/", "_")
	root.position = at
	root.rotation.y = rot_y
	root.scale = Vector3.ONE * magnification
	var model := scene.instantiate() as Node3D
	model.position = Vector3(-center.x, -bounds.position.y, -center.z)
	root.add_child(model)
	parent.add_child(root)
	return root


## Batches every copy of a kit model into MultiMeshInstance3D render chunks.
static func _batch_kit(parent: Node3D, spec: String, transforms: Array[Transform3D]) -> void:
	if transforms.is_empty():
		return
	var mesh := _kit_merged_mesh(spec)
	if mesh != null:
		_batch_mesh(parent, mesh, transforms, spec)


## Merges the kit model's parts into one surface so a MultiMesh needs a single draw.
static func _kit_merged_mesh(spec: String) -> ArrayMesh:
	if _kit_merged.has(spec):
		return _kit_merged[spec]
	var merged: ArrayMesh = null
	var scene := kit(spec)
	if scene != null:
		merged = _merge_kit_parts(DAMAGEABLE_SCRIPT.kit_parts(scene))
	_kit_merged[spec] = merged
	return merged


static func _merge_kit_parts(parts: Array) -> ArrayMesh:
	if parts.is_empty():
		return null
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var material: Material = null
	for part: Array in parts:
		var mesh: Mesh = part[0]
		var place: Transform3D = part[1]
		for surface in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface)
			var source: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var source_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] \
					if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			var source_uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] \
					if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
			var base := vertices.size()
			for i in source.size():
				vertices.append(place * source[i])
				normals.append((place.basis * (source_normals[i] if i < source_normals.size()
						else Vector3.UP)).normalized())
				uvs.append(source_uvs[i] if i < source_uvs.size() else Vector2.ZERO)
			var source_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] \
					if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if source_indices.is_empty():
				for i in source.size():
					indices.append(base + i)
			else:
				for index in source_indices:
					indices.append(base + index)
			if material == null:
				material = mesh.surface_get_material(surface)
	var merged_arrays := []
	merged_arrays.resize(Mesh.ARRAY_MAX)
	merged_arrays[Mesh.ARRAY_VERTEX] = vertices
	merged_arrays[Mesh.ARRAY_NORMAL] = normals
	merged_arrays[Mesh.ARRAY_TEX_UV] = uvs
	merged_arrays[Mesh.ARRAY_INDEX] = indices
	var merged := ArrayMesh.new()
	merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged_arrays)
	merged.surface_set_material(0, material)
	return merged


## Same AABB fit the damageable node applies, exposed so scenery can hug a kit wall.
static func _kit_fit_size(spec: String, slot: Vector3, magnification: float) -> Vector3:
	var raw := kit_bounds(spec)
	var horizontal := magnification
	if slot.x > 0.0 and slot.z > 0.0:
		horizontal = minf(horizontal, minf(slot.x / maxf(raw.size.x, 0.0001),
				slot.z / maxf(raw.size.z, 0.0001)))
	var vertical := horizontal
	if slot.y > 0.0:
		vertical = minf(horizontal, slot.y / maxf(raw.size.y, 0.0001))
	return Vector3(raw.size.x * horizontal, raw.size.y * vertical, raw.size.z * horizontal)


## Two containers side by side, stacked `layers` high in raw kit units.
static func _container_stack(layers: int, rng: RandomNumberGenerator) -> Array[Transform3D]:
	var layout: Array[Transform3D] = []
	for layer in layers:
		for side in 2:
			var yaw := rng.randf_range(-0.05, 0.05)
			layout.append(Transform3D(Basis(Vector3.UP, yaw),
					Vector3(-0.70 if side == 0 else 0.70, 1.104 * float(layer), 0.0)))
	return layout


# ---------------------------------------------------------------------------
# Block Ground Pads
# ---------------------------------------------------------------------------

static func _add_lot_pad(pads: Dictionary[Material, Array], center: Vector3, zone: int) -> void:
	var material_key := "historic_pad"
	match zone:
		ZONE_PARK:
			material_key = "grass"
		ZONE_PLAZA:
			material_key = "plaza"
		ZONE_CONTAINERS:
			material_key = "freight_pad"
		ZONE_REFINERY:
			material_key = "refinery_pad"
		ZONE_SHIPYARD:
			material_key = "shipyard_pad"
		ZONE_HIGHRISE:
			material_key = "midtown_pad"
		ZONE_OLDCORE:
			material_key = "plaza"
	var empty: Array[Transform3D] = []
	var transforms: Array[Transform3D] = pads.get_or_add(_mats[material_key], empty)
	transforms.append(Transform3D(Basis.IDENTITY, Vector3(center.x, -0.055, center.z)))


static func _batch_lot_pads(parent: Node3D, pads: Dictionary[Material, Array], micro_ground: bool) -> void:
	var grain := surface_grain_texture() if micro_ground else null
	for material: Material in pads:
		var mesh := BoxMesh.new()
		mesh.size = Vector3(24.0, 0.14, 24.0)
		mesh.material = CityNightLights.shadowed_surface_material(material, grain)
		_batch_mesh(parent, mesh, pads[material], "lot_pad/" + material.resource_name)


# ---------------------------------------------------------------------------
# Zone Builders
# ---------------------------------------------------------------------------

static func _build_park_block(scenery: Node3D, center: Vector3, bx: int, bz: int,
		rng: RandomNumberGenerator, trees: Array[Transform3D], scales: Array[float], micro_ground: bool) -> void:
	# Cross-shaped stone footpaths
	if micro_ground:
		# Three pieces share edges instead of overlapping at the crossing.
		var path_center := center + Vector3.DOWN * 0.024
		var material := ground_detail(_mats["plaza"])
		scenery.add_child(_make_box(Vector3(24.0, 0.05, 3.6), path_center, material, false))
		for z: float in [-6.9, 6.9]:
			scenery.add_child(_make_box(Vector3(3.6, 0.05, 10.2), path_center + Vector3.BACK * z, material, false))
	else:
		for size_v: Vector3 in [Vector3(24.0, 0.05, 3.6), Vector3(3.6, 0.05, 24.0)]:
			var path := _make_box(size_v, center + Vector3(0.0, 0.03, 0.0), _mats["plaza"], false)
			scenery.add_child(path)

	# Center feature: fountain pool or sculptural memorial obelisk
	if (bx + bz) % 2 == 0:
		var rim := _make_cyl(4.4, 4.7, 0.55, center + Vector3(0.0, 0.28, 0.0), _mats["concrete_light"], false)
		scenery.add_child(rim)
		var water := _make_cyl(3.8, 3.8, 0.42, center + Vector3(0.0, 0.32, 0.0), _mats["fountain_water"], false)
		scenery.add_child(water)
		var spire := _make_cyl(0.45, 0.9, 2.2, center + Vector3(0.0, 1.1, 0.0), _mats["concrete_light"], true)
		scenery.add_child(spire)
	else:
		var plinth := _make_box(Vector3(4.6, 0.7, 4.6), center + Vector3(0.0, 0.35, 0.0), _mats["concrete_light"], false)
		scenery.add_child(plinth)
		var obelisk := _make_box(Vector3(1.5, 6.4, 1.5), center + Vector3(0.0, 3.6, 0.0), _mats["concrete_warm"], true)
		scenery.add_child(obelisk)

	# Perimeter & quadrant groves of kit trees
	for qx: int in [-1, 1]:
		for qz: int in [-1, 1]:
			for k in 3:
				var tx: float = center.x + float(qx) * rng.randf_range(4.2, 10.2)
				var tz: float = center.z + float(qz) * rng.randf_range(4.2, 10.2)
				var rot := rng.randf_range(0.0, TAU)
				trees.append(Transform3D(Basis(Vector3.UP, rot), Vector3(tx, 0.02, tz)))
				scales.append(rng.randf_range(0.82, 1.38))


static func _build_plaza_block(scenery: Node3D, center: Vector3, bx: int, bz: int,
		trees: Array[Transform3D], scales: Array[float], micro_ground: bool) -> void:
	# Decorative tiled harbor plaza with kit planters and parasols (open sightlines!)
	var inlay_y := -0.029 if micro_ground else 0.03
	var material: Material = ground_detail(_mats["concrete_warm"]) if micro_ground else _mats["concrete_warm"]
	var inlay := _make_box(Vector3(15.0, 0.06, 15.0), center + Vector3.UP * inlay_y, material, false)
	scenery.add_child(inlay)
	if bx == 0 and bz == 1:
		var marker := _make_cyl(2.6, 3.0, 0.35, center + Vector3(0.0, 0.18, 0.0), _mats["concrete_light"], false)
		scenery.add_child(marker)
	for cx: float in [-9.2, 9.2]:
		for cz: float in [-9.2, 9.2]:
			_add_kit_scenery(scenery, "suburban/planter", center + Vector3(cx, 0.02, cz),
					TAU * 0.125 * float(int(cx + cz)), KIT_SCALE_PLANTER)
			trees.append(Transform3D(Basis.IDENTITY, center + Vector3(cx, 2.1, cz)))
			scales.append(1.05)
	# Market parasols on the plaza apron
	for i in 2:
		var spec := "commercial/detail-parasol-a" if (bx + bz + i) % 2 == 0 else "commercial/detail-parasol-b"
		_add_kit_scenery(scenery, spec, center + Vector3(-4.2 + float(i) * 8.4, 0.02, 2.6),
				float(i) * 1.1, KIT_SCALE_PARASOL)


static func _build_highrise_block(targets: Node3D, center: Vector3, bx: int, bz: int,
		rng: RandomNumberGenerator, next_id: int,
		trees: Array[Transform3D], scales: Array[float]) -> int:
	# Landmark towers on every third block, paired slimmer towers elsewhere. Every building
	# stays inside the 24 m lot pad so streets, spawn points and the test corridors stay clear.
	var ruin_col: Color = [Color("#62737c"), Color("#7c6f5c"), Color("#5f646b")][posmod(bx * 7 + bz * 13, 3)]
	if posmod(bx + bz, 3) == 0:
		var spec: String = HIGHRISE_LANDMARKS[posmod(bx * 5 + bz * 11, HIGHRISE_LANDMARKS.size())]
		var landmark_scale := 14.0 + rng.randf_range(0.0, 1.0)
		_spawn_kit_building(targets, "Highrise_%02d" % next_id, center + Vector3(0.0, 0.02, 0.0),
				0.0, Vector3(22.0, 140.0, 22.0), spec, landmark_scale, "highrise", ruin_col)
		next_id += 1
		for sx: float in [-10.6, 10.6]:
			trees.append(Transform3D(Basis.IDENTITY, center + Vector3(sx, 0.02, 11.2)))
			scales.append(0.95)
	else:
		var tower: String = HIGHRISE_LANDMARKS[posmod(bx * 3 + bz * 7, HIGHRISE_LANDMARKS.size())]
		_spawn_kit_building(targets, "Tower_%02d" % next_id, center + Vector3(-5.75, 0.02, -5.75),
				0.0, Vector3(10.5, 96.0, 10.5), tower, KIT_SCALE, "highrise", ruin_col)
		next_id += 1
		var annex: String = MIDRISE_TOWERS[posmod(bx * 11 + bz * 5, MIDRISE_TOWERS.size())]
		_spawn_kit_building(targets, "Tower_%02d" % next_id, center + Vector3(5.75, 0.02, 5.75),
				PI * 0.5, Vector3(10.5, 64.0, 10.5), annex, KIT_SCALE, "highrise", ruin_col)
		next_id += 1
		trees.append(Transform3D(Basis.IDENTITY, center + Vector3(-11.0, 0.02, 0.0)))
		scales.append(0.9)
	return next_id


static func _build_oldharbor_block(targets: Node3D, scenery: Node3D, center: Vector3, bx: int, bz: int,
		rng: RandomNumberGenerator, next_id: int) -> int:
	# Brick-and-stucco mid-rise ring hugging the preserved core warehouses.
	var ruin_col: Color = [Color("#8a6a55"), Color("#7c7468"), Color("#6f7c82")][posmod(bx + bz, 3)]
	var pick := posmod(bx * 13 + bz * 7, OLD_HARBOR_BLOCKS.size())
	if posmod(bx * 3 + bz * 5, 3) == 0:
		# One deep corner block with awnings hung on its street-facing wall.
		var slot := Vector3(20.0, 26.0, 16.0)
		var spec := OLD_HARBOR_BLOCKS[pick]
		_spawn_kit_building(targets, "OldHarbor_%02d" % next_id, center + Vector3(0.0, 0.02, -2.0),
				0.0, slot, spec, KIT_SCALE, "oldharbor", ruin_col)
		next_id += 1
		var fit := _kit_fit_size(spec, slot, KIT_SCALE)
		for i in 2:
			if posmod(bx + bz + i, 3) == 0:
				continue
			var awning: String = OLD_HARBOR_DETAILS[posmod(pick + i, OLD_HARBOR_DETAILS.size())]
			var at := center + Vector3(-4.4 + float(i) * 8.2, 2.3, -2.0 + fit.z * 0.5 + 0.16)
			_add_kit_scenery(scenery, awning, at, 0.0, KIT_SCALE_AWNING)
	else:
		var front: String = OLD_HARBOR_BLOCKS[pick]
		_spawn_kit_building(targets, "OldHarbor_%02d" % next_id, center + Vector3(-5.75, 0.02, -5.75),
				0.0, Vector3(10.5, 26.0, 10.5), front, KIT_SCALE, "oldharbor", ruin_col)
		next_id += 1
		var back: String = OLD_HARBOR_BLOCKS[posmod(pick + 4, OLD_HARBOR_BLOCKS.size())]
		_spawn_kit_building(targets, "OldHarbor_%02d" % next_id, center + Vector3(5.75, 0.02, 5.75),
				PI * 0.5, Vector3(10.5, 24.0, 10.5), back, 11.0, "oldharbor", ruin_col)
		next_id += 1
	return next_id


static func _build_container_block(targets: Node3D, scenery: Node3D, center: Vector3,
		bx: int, bz: int, rng: RandomNumberGenerator, next_id: int, half_land: float) -> int:
	# Painted yellow freight lane stripes
	var stripe := _make_box(Vector3(21.5, 0.03, 0.35), center + Vector3(0.0, 0.03, 0.0), _mats["hazard_yellow"], false)
	scenery.add_child(stripe)

	var ruin_col := Color("#9a533b") if posmod(bx + bz, 2) == 0 else Color("#7c6a5c")
	var slot := Vector3(20.0, 26.0, 20.0)
	if posmod(bx * 5 + bz * 7, 4) == 0:
		# A low terminal warehouse shares the yard with loose container piles.
		var hall: String = TERMINAL_WAREHOUSES[posmod(bx * 9 + bz * 7, TERMINAL_WAREHOUSES.size())]
		_spawn_kit_building(targets, "Warehouse_%02d" % next_id, center + Vector3(0.0, 0.02, 0.0),
				PI * 0.5 if posmod(bz, 2) == 0 else 0.0, Vector3(20.0, 20.0, 20.0), hall,
				KIT_SCALE, "terminal", Color("#6d7378"))
		next_id += 1
	elif posmod(bx * 7 + bz * 11, 3) == 0:
		var pile: String = CONTAINER_PILES[posmod(bx + bz, CONTAINER_PILES.size())]
		_spawn_kit_building(targets, "Containers_%02d" % next_id, center + Vector3(0.0, 0.02, 0.0),
				PI * 0.5 if posmod(bx, 2) == 0 else 0.0, slot, pile,
				KIT_SCALE_CONTAINER, "containers", ruin_col)
		next_id += 1
	else:
		var spec: String = CONTAINER_MODELS[posmod(bx * 3 + bz * 5, CONTAINER_MODELS.size())]
		var layers := rng.randi_range(2, 3)
		_spawn_kit_building(targets, "Containers_%02d" % next_id, center + Vector3(0.0, 0.02, 0.0), 0.0,
				slot, spec, KIT_SCALE_CONTAINER, "containers", ruin_col, _container_stack(layers, rng))
		next_id += 1

	# Loose piles stacked around the yard corners as cheap, collider-free dressing.
	for corner: Vector2 in [Vector2(-8.2, -8.2), Vector2(8.2, 8.2)]:
		if posmod(bx + int(corner.x) * 3 + bz, 3) == 0:
			continue
		var pile: String = CONTAINER_PILES[posmod(bx + bz + int(corner.y), CONTAINER_PILES.size())]
		_add_kit_scenery(scenery, pile, center + Vector3(corner.x, 0.02, corner.y),
				TAU * 0.25 * float(posmod(bx + bz, 4)), 3.0)

	# Add occasional tall port gantry crane straddling the freight yard (kept strictly inside land)
	if bx % 2 == 0 and bz == 4 and center.z + 16.0 + 23.5 <= half_land - 2.0:
		scenery.add_child(_build_gantry_crane(center + Vector3(0.0, 0.02, 16.0), 0.0, bx == 0))
	return next_id


static func _build_refinery_block(targets: Node3D, scenery: Node3D, center: Vector3,
		bx: int, bz: int, rng: RandomNumberGenerator, next_id: int) -> int:
	var variant := absi(bx * 5 + bz * 3) % 3
	if variant == 0:
		# Heavy tank farm: one destructible storage tank plus smaller feeder tanks.
		_spawn_kit_building(targets, "SiloComplex_%02d" % next_id, center + Vector3(0.0, 0.02, 0.0),
				PI * 0.5 if posmod(bx, 2) == 0 else 0.0, Vector3(20.0, 26.0, 20.0),
				"industrial/detail-tank-large", 11.0, "silo", Color("#8a867e"))
		next_id += 1
		for side: float in [-8.6, 8.6]:
			_add_kit_scenery(scenery, "industrial/detail-tank",
					center + Vector3(side, 0.02, 9.4), 0.0, 7.0)
	elif variant == 1:
		# Refinery hall plus its stack cluster.
		var hall: String = REFINERY_HALLS[posmod(bx * 7 + bz * 13, REFINERY_HALLS.size())]
		_spawn_kit_building(targets, "Refinery_%02d" % next_id, center + Vector3(0.0, 0.02, 0.0),
				0.0, Vector3(20.0, 28.0, 20.0), hall, KIT_SCALE, "silo", Color("#7c7369"))
		next_id += 1
		_add_kit_scenery(scenery, "industrial/chimney-large", center + Vector3(8.6, 0.02, -6.2), 0.0, 8.0)
		_add_kit_scenery(scenery, "industrial/chimney-medium", center + Vector3(10.4, 0.02, 4.4), 0.0, 8.0)
		_add_kit_scenery(scenery, "industrial/chimney-basic", center + Vector3(4.6, 0.02, 9.8), 0.0, 8.0)
	else:
		# Water tower landmark + pump house + overhead industrial pipe rack.
		var pump: String = REFINERY_HALLS[posmod(bx * 5 + bz * 11 + 1, REFINERY_HALLS.size())]
		_spawn_kit_building(targets, "PumpHouse_%02d" % next_id, center + Vector3(-2.6, 0.02, 2.4),
				0.0, Vector3(18.0, 22.0, 16.0), pump, 10.0, "hangar", Color("#7e5d4a"))
		next_id += 1
		_add_kit_scenery(scenery, "industrial/water-tower", center + Vector3(8.8, 0.02, -7.6), 0.0, 9.0)
		var pipe := _make_cyl(0.55, 0.55, 21.0, center + Vector3(0.0, 5.2, -9.8), _mats["steel_light"], false)
		pipe.rotation.z = PI * 0.5
		scenery.add_child(pipe)
		for px: float in [-8.0, 0.0, 8.0]:
			scenery.add_child(_make_box(Vector3(0.6, 5.4, 0.6), center + Vector3(px, 2.7, -9.8), _mats["steel_dark"], false))
	return next_id


static func _build_shipyard_block(targets: Node3D, scenery: Node3D, center: Vector3,
		bx: int, bz: int, rng: RandomNumberGenerator, next_id: int) -> int:
	# Dedicated drydock basin block at (-4, 3) and (-3, 3)
	if (bx == -4 or bx == -3) and bz == 3:
		var basin := _make_box(Vector3(22.0, 0.25, 16.0), center + Vector3(0.0, 0.05, 0.0), _mats["drydock_water"], false)
		scenery.add_child(basin)
		for z_wall: float in [-8.6, 8.6]:
			scenery.add_child(_make_box(Vector3(23.0, 0.85, 1.4), center + Vector3(0.0, 0.42, z_wall), _mats["concrete_light"], false))
		# Hulls waiting in the dock: tugs lengthwise, two tow boats across the wider basin.
		if bx == -4:
			_add_kit_scenery(scenery, DRYDOCK_BOATS[0], center + Vector3(-4.6, -0.35, 0.0), 0.0, KIT_SCALE_BOAT)
			_add_kit_scenery(scenery, DRYDOCK_BOATS[1], center + Vector3(4.8, -0.35, 0.4), 0.0, KIT_SCALE_BOAT)
		else:
			_add_kit_scenery(scenery, DRYDOCK_BOATS[2], center + Vector3(0.0, -0.3, -2.6), PI * 0.5, 3.5)
			_add_kit_scenery(scenery, DRYDOCK_BOATS[3], center + Vector3(0.0, -0.3, 3.4), PI * 0.5, 3.5)
		return next_id

	# Wide-span shipyard assembly halls (destructible)
	var hall: String = SHIPYARD_HALLS[posmod(bx * 7 + bz * 5, SHIPYARD_HALLS.size())]
	var rot_y := 0.0 if posmod(bz, 2) == 0 else PI * 0.5
	_spawn_kit_building(targets, "ShipyardHangar_%02d" % next_id, center + Vector3(0.0, 0.02, 0.0),
			rot_y, Vector3(22.0, 30.0, 22.0), hall, KIT_SCALE, "hangar", Color("#586872"))
	next_id += 1
	return next_id


static func _build_historic_block(targets: Node3D, center: Vector3, bx: int, bz: int,
		rng: RandomNumberGenerator, next_id: int,
		trees: Array[Transform3D], scales: Array[float]) -> int:
	# Outer wards mix in whole suburban blocks so the brick skyline gets a lower second layer.
	if maxi(absi(bx), absi(bz)) > 4 and posmod(bx * 7 + bz * 11, 3) == 0:
		var ruin_palette: Array[Color] = [Color("#8d7a63"), Color("#7f6f5a"), Color("#77827f")]
		for i in 2:
			var spec: String = SUBURBAN_HOUSES[posmod(bx * 5 + bz * 3 + i * 4, SUBURBAN_HOUSES.size())]
			var offset := Vector3(-5.75 if i == 0 else 5.75, 0.02, -5.75 if i == 0 else 5.75)
			_spawn_kit_building(targets, "Suburban_%02d" % next_id, center + offset,
					PI * 0.5 if posmod(bx + i, 2) == 0 else 0.0, Vector3(10.5, 16.0, 10.5),
					spec, 10.0, "suburban", ruin_palette[posmod(bx + bz + i, 3)])
			next_id += 1
		for qx: float in [-10.4, 10.4]:
			trees.append(Transform3D(Basis.IDENTITY, center + Vector3(qx, 0.02, 9.6)))
			scales.append(rng.randf_range(0.9, 1.2))
		return next_id

	# Reuse the three low-poly historic silhouettes in varied orientations.
	var pick := absi(bx * 11 + bz * 7) % 3
	var rot_y := float(absi(bx + bz) % 4) * PI * 0.5
	match pick:
		0:
			_spawn_historic_building(targets, "DockPressExt_%02d" % next_id,
					center + Vector3(-5.2, 0.015, -4.6), rot_y,
					&"dockpress", DOCKPRESS_FLOOR, Vector3(10.1, 7.8, 7.4))
			next_id += 1
			_spawn_historic_building(targets, "TidewaterExt_%02d" % next_id,
					center + Vector3(5.6, 0.015, 5.0), rot_y + PI,
					&"tidewater", TIDEWATER_FLOOR, Vector3(8.9, 16.0, 7.6))
			next_id += 1
		1:
			_spawn_historic_building(targets, "MarineWorksExt_%02d" % next_id,
					center + Vector3(0.0, 0.015, 0.0), rot_y,
					&"marineworks", MARINEWORKS_FLOOR, Vector3(14.2, 5.5, 9.3))
			next_id += 1
			trees.append(Transform3D(Basis.IDENTITY, center + Vector3(-9.5, 0.02, 9.5)))
			scales.append(rng.randf_range(0.9, 1.25))
		_:
			_spawn_historic_building(targets, "TidewaterExt_%02d" % next_id,
					center + Vector3(0.0, 0.015, -5.2), 0.0,
					&"tidewater", TIDEWATER_FLOOR, Vector3(8.9, 16.0, 7.6))
			next_id += 1
			_spawn_historic_building(targets, "DockPressExt_%02d" % next_id,
					center + Vector3(0.0, 0.015, 5.6), PI,
					&"dockpress", DOCKPRESS_FLOOR, Vector3(10.1, 7.8, 7.4))
			next_id += 1
	return next_id


# ---------------------------------------------------------------------------
# Desktop Diorama Wood Frame, Waterfront Quays, Cranes & Landmarks
# ---------------------------------------------------------------------------

static func sandbox_frame_depth(half_land: float) -> float:
	return clampf(half_land * (32.0 / 709.0), 0.12, 32.0)


## Builds the wooden frame and solid tray skirt aligned to the bedroom desk top.
static func _build_sandbox_frame(district: Node3D, half_land: float) -> void:
	if half_land <= 0.25:
		return
	var frame_w := clampf(half_land * 0.056, 0.05, 40.0)
	var lip_h := clampf(half_land * 0.011, 0.02, 8.0)
	var base_depth := sandbox_frame_depth(half_land)
	var overlap := minf(0.6, half_land * 0.05)
	var inner := half_land - overlap
	var outer := half_land + frame_w
	var rail_w := outer - inner
	var rail_h := lip_h + base_depth
	var rail_cy := (lip_h - base_depth) * 0.5
	var full_span := outer * 2.0

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# North & South wooden frame rails (full outer span across corners)
	var ns_size := Vector3(full_span, rail_h, rail_w)
	_append_box(st, ns_size, Vector3(0.0, rail_cy, -(inner + rail_w * 0.5)))
	_append_box(st, ns_size, Vector3(0.0, rail_cy, inner + rail_w * 0.5))
	# West & East wooden frame rails (between north/south inner edges)
	var we_size := Vector3(rail_w, rail_h, inner * 2.0)
	_append_box(st, we_size, Vector3(-(inner + rail_w * 0.5), rail_cy, 0.0))
	_append_box(st, we_size, Vector3(inner + rail_w * 0.5, rail_cy, 0.0))
	# Solid underside baseplate closing the tray bottom flush against the desk surface
	var base_top := -0.42
	if base_top > -base_depth + 0.02:
		var plate_h := base_top + base_depth
		_append_box(st, Vector3(inner * 2.0, plate_h, inner * 2.0),
				Vector3(0.0, -base_depth + plate_h * 0.5, 0.0))

	var mesh := st.commit()
	mesh.surface_set_material(0, CityNightLights.shadowed_surface_material(_mats["sandbox_wood"]))
	var frame := MeshInstance3D.new()
	frame.name = "SandboxFrame"
	frame.mesh = mesh
	frame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	frame.set_meta(&"asset", "sandbox_frame")
	district.add_child(frame)


static func _append_box(st: SurfaceTool, size: Vector3, center: Vector3) -> void:
	var h := size * 0.5
	var faces := [
		# +Y top
		[Vector3(0, 1, 0), Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z)],
		# -Y bottom
		[Vector3(0, -1, 0), Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, -h.y, -h.z), Vector3(-h.x, -h.y, -h.z)],
		# +Z front
		[Vector3(0, 0, 1), Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(-h.x, -h.y, h.z)],
		# -Z back
		[Vector3(0, 0, -1), Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z)],
		# +X right
		[Vector3(1, 0, 0), Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, -h.y, h.z)],
		# -X left
		[Vector3(-1, 0, 0), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, -h.y, h.z), Vector3(-h.x, -h.y, -h.z)],
	]
	for face: Array in faces:
		var n: Vector3 = face[0]
		var a: Vector3 = center + face[1]
		var b: Vector3 = center + face[2]
		var c: Vector3 = center + face[3]
		var d: Vector3 = center + face[4]
		for v: Vector3 in [a, b, c, a, c, d]:
			st.set_normal(n)
			st.add_vertex(v)


static func _build_seawalls_and_maritime(bollards: Array[Transform3D],
		half_land: float) -> void:
	# Keep on-land perimeter bollards; offshore ships, ocean liners, buoys and sea rocks are
	# omitted so the 1,418 m city sits cleanly inside its desktop sandbox frame with zero
	# geometry spilling over the bedroom desk.
	var pos := -half_land + 14.0
	while pos <= half_land - 14.0:
		for side: float in [-1.0, 1.0]:
			var edge := (half_land - 1.8) * side
			bollards.append(Transform3D(Basis.IDENTITY, Vector3(pos, 0.02, edge)))
			bollards.append(Transform3D(Basis.IDENTITY, Vector3(edge, 0.02, pos)))
		pos += 24.0


static func _build_waterfront_quays(targets: Node3D, scenery: Node3D,
		rng: RandomNumberGenerator, next_id: int, half_land: float) -> void:
	# East & South quay aprons feature iconic tall gantry cranes & waterfront container rows.
	# Cranes face INWARD over the yard so their 23 m cantilever booms stay strictly inside
	# `half_land` and never poke past the miniature sandbox wood frame.
	var play_edge := half_land - 5.0
	var crane_inset := 14.0
	if half_land > crane_inset + 24.0:
		for x_pos: float in [-96.0, 24.0, 108.0]:
			if absf(x_pos) + 8.0 <= play_edge:
				scenery.add_child(_build_gantry_crane(
						Vector3(x_pos, 0.02, half_land - crane_inset), PI, x_pos > 0.0))
		for z_pos: float in [-72.0, 48.0]:
			if absf(z_pos) + 8.0 <= play_edge:
				scenery.add_child(_build_gantry_crane(
						Vector3(half_land - crane_inset, 0.02, z_pos), -PI * 0.5, z_pos > 0.0))

	# Additional waterfront destructible container stacks on the south apron
	for x_pos: float in [-144.0, -48.0, 64.0, 152.0]:
		if absf(x_pos) + 7.25 > play_edge:
			continue
		var layers := rng.randi_range(2, 3)
		var spec: String = CONTAINER_MODELS[posmod(int(x_pos), CONTAINER_MODELS.size())]
		_spawn_kit_building(targets, "QuayContainers_%02d" % next_id,
				Vector3(x_pos, 0.02, half_land - 12.0), 0.0, Vector3(19.0, 26.0, 19.0), spec,
				KIT_SCALE_CONTAINER, "containers", Color("#9a533b"), _container_stack(layers, rng))
		next_id += 1


static func _add_lighthouse(targets: Node3D, at: Vector3) -> void:
	var vis := Node3D.new()
	vis.name = "IntactModel"
	vis.add_child(_make_cyl(4.8, 5.4, 3.0, Vector3(0.0, 1.5, 0.0), _mats["concrete_light"], true))
	vis.add_child(_make_cyl(2.6, 4.0, 26.0, Vector3(0.0, 15.5, 0.0), _mats["lighthouse"], true))
	vis.add_child(_make_cyl(3.2, 3.2, 1.0, Vector3(0.0, 28.8, 0.0), _mats["steel_dark"], true))
	vis.add_child(_make_cyl(2.1, 2.1, 3.4, Vector3(0.0, 31.0, 0.0), _mats["beacon_glow"], false))
	vis.add_child(_make_cyl(0.2, 2.8, 2.6, Vector3(0.0, 33.9, 0.0), _mats["hull_red"], true))
	_spawn_procedural_building(targets, "HarborLighthouse", at, 0.0,
			Vector3(9.6, 35.0, 9.6), vis, "lighthouse", Color("#b84b36"))


static func _add_radar_tower(targets: Node3D, at: Vector3) -> void:
	var vis := Node3D.new()
	vis.name = "IntactModel"
	vis.add_child(_make_box(Vector3(10.0, 6.0, 10.0), Vector3(0.0, 3.0, 0.0), _mats["concrete_light"], true))
	vis.add_child(_make_box(Vector3(5.4, 18.0, 5.4), Vector3(0.0, 15.0, 0.0), _mats["steel_light"], true))
	vis.add_child(_make_box(Vector3(8.2, 3.2, 8.2), Vector3(0.0, 25.0, 0.0), _mats["glass_blue"], true))
	var dish := _make_cyl(3.2, 3.2, 1.4, Vector3(0.0, 28.5, 0.0), _mats["concrete_light"], true)
	dish.rotation.x = 0.5
	vis.add_child(dish)
	_spawn_procedural_building(targets, "HarborRadarTower", at, 0.0,
			Vector3(10.2, 30.0, 10.2), vis, "highrise", Color("#7c838a"))


# ---------------------------------------------------------------------------
# Building Spawners
# ---------------------------------------------------------------------------

static func _spawn_procedural_building(targets: Node3D, node_name: String, pos: Vector3,
		rot_y: float, footprint: Vector3, intact_model: Node3D, style: String, ruin_col: Color) -> void:
	var node := Node3D.new()
	node.name = node_name
	node.position = pos
	node.rotation.y = rot_y
	node.set_script(DAMAGEABLE_SCRIPT)
	node.kind = "building"
	node.footprint = footprint
	node.procedural_style = style
	node.ruin_color = ruin_col
	intact_model.name = "IntactModel"
	node.add_child(intact_model)
	targets.add_child(node)


## Destructible Kenney kit building. `slot` is the free box on the lot; the kit AABB is
## fitted into it, so `footprint` ends up being the model's real size.
static func _spawn_kit_building(targets: Node3D, node_name: String, pos: Vector3, rot_y: float,
		slot: Vector3, spec: String, magnification: float, style: String, ruin_col: Color,
		layout: Array = []) -> Node3D:
	var scene := kit(spec)
	if scene == null:
		return null
	var node := Node3D.new()
	node.name = node_name
	node.position = pos
	node.rotation.y = rot_y
	node.set_script(DAMAGEABLE_SCRIPT)
	node.kind = "building"
	node.footprint = slot
	node.procedural_style = style
	node.ruin_color = ruin_col
	node.intact_scene = scene
	node.kit_scale = magnification
	node.kit_layout.assign(layout)
	node.batched = true
	targets.add_child(node)
	return node


static func _spawn_historic_building(targets: Node3D, node_name: String, pos: Vector3,
		rot_y: float, style: StringName, ruin_floor: HeightMapShape3D, footprint: Vector3) -> void:
	var node := Node3D.new()
	node.name = node_name
	node.position = pos
	node.rotation.y = rot_y
	node.set_script(DAMAGEABLE_SCRIPT)
	node.kind = "building"
	node.historic_style = style
	# The same Kenney kits the central twelve wear in scenes/district.tscn, so the outer
	# wards batch into the real models instead of falling back to HistoricBuildings.unit_mesh()
	# boxes. `_fit_kit_intact()` still clamps the kit AABB by the `footprint` slot below and
	# rewrites the runtime footprint, so collision, rubble and routing follow the real model
	# exactly like the core lots; `batch_spec()` shares the MultiMesh with the central copies.
	match style:
		&"dockpress":
			node.intact_scene = kit("commercial/building-e")
			node.kit_scale = 6.16
		&"tidewater":
			node.intact_scene = kit("commercial/building-m")
			node.kit_scale = 5.08
		&"marineworks":
			node.intact_scene = kit("industrial/building-s")
			node.kit_scale = 6.55
		_:
			push_error("historic style %s has no Kenney kit mapping" % style)
	node.ruin_floor = ruin_floor
	node.footprint = footprint
	node.batched = true
	targets.add_child(node)


static func _build_gantry_crane(at: Vector3, rot_y: float, amber: bool) -> Node3D:
	var crane := Node3D.new()
	crane.position = at
	crane.rotation.y = rot_y
	var mat: Material = _mats["hazard_yellow"] if amber else _mats["crane_red"]
	var h := 27.0
	for lx: float in [-6.8, 6.8]:
		for lz: float in [-5.2, 5.2]:
			crane.add_child(_make_box(Vector3(1.1, h, 1.1), Vector3(lx, h * 0.5, lz), mat, true))
	# Crossbeams & high cantilever boom extending out over the harbor water
	crane.add_child(_make_box(Vector3(15.0, 1.8, 12.0), Vector3(0.0, h * 0.58, 0.0), mat, false))
	crane.add_child(_make_box(Vector3(4.6, 2.2, 34.0), Vector3(0.0, h - 1.5, 6.0), mat, true))
	crane.add_child(_make_box(Vector3(3.6, 3.0, 3.8), Vector3(0.0, h + 1.4, -1.0), _mats["concrete_light"], false))
	return crane


# ---------------------------------------------------------------------------
# MultiMesh Batching (Trees, Streetlamps, Parked Cars, Quay Bollards)
# ---------------------------------------------------------------------------

static func render_chunk(at: Vector3) -> Vector2i:
	return Vector2i(floori(at.x / RENDER_CHUNK_SIZE), floori(at.z / RENDER_CHUNK_SIZE))


## Batches every instance of one static asset into a single map-wide MultiMeshInstance3D.
## One node per asset instead of one per 108 m chunk keeps the whole harbour visible without
## paying a draw call per block; the instance transforms stay absolute (the node sits at the
## district origin) so nothing has to be re-centred.
static func _batch_mesh(parent: Node3D, mesh: Mesh, transforms: Array[Transform3D],
		asset: String = "") -> void:
	if transforms.is_empty():
		return
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.mesh = mesh
	batch.instance_count = transforms.size()
	for i in transforms.size():
		batch.set_instance_transform(i, transforms[i])
	var instance := MultiMeshInstance3D.new()
	instance.name = "Batch_%s" % asset.get_slice("/", -1).validate_node_name()
	instance.multimesh = batch
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Feeds scripts/district_stats.gd so the triangle bill names the real asset.
	instance.set_meta(&"asset", asset)
	parent.add_child(instance)


static func _build_tree_multimesh(scenery: Node3D, transforms: Array[Transform3D], scales: Array[float]) -> void:
	var large: Array[Transform3D] = []
	var small: Array[Transform3D] = []
	for i in transforms.size():
		var pose := transforms[i]
		var s: float = scales[i]
		if s >= 1.08:
			large.append(Transform3D(pose.basis.scaled(Vector3.ONE * (s * KIT_SCALE_TREE)), pose.origin))
		else:
			small.append(Transform3D(pose.basis.scaled(Vector3.ONE * (s * KIT_SCALE_TREE * 1.18)), pose.origin))
	for pair in [[PARK_TREES[0], large], [PARK_TREES[1], small]]:
		var spec: String = pair[0]
		var poses: Array[Transform3D] = pair[1]
		if poses.is_empty():
			continue
		var mesh := _kit_merged_mesh(spec)
		if mesh == null:
			continue
		_batch_mesh(scenery, mesh, poses, spec)
		var node := scenery.get_child(scenery.get_child_count() - 1) as MultiMeshInstance3D
		if node != null and mesh.get_surface_count() > 0:
			node.material_override = CityNightLights.shadowed_surface_material(mesh.surface_get_material(0))


static func _build_lamp_multimesh(scenery: Node3D, transforms: Array[Transform3D]) -> void:
	var curved: Array[Transform3D] = []
	var square: Array[Transform3D] = []
	for pose in transforms:
		var scaled := Transform3D(pose.basis.scaled(Vector3.ONE * KIT_SCALE_LIGHT), pose.origin)
		if posmod(int(absf(pose.origin.x) + absf(pose.origin.z)), 2) == 0:
			curved.append(scaled)
		else:
			square.append(scaled)
	for pair in [[STREET_LIGHTS[0], curved], [STREET_LIGHTS[1], square]]:
		var spec: String = pair[0]
		var poses: Array[Transform3D] = pair[1]
		if poses.is_empty():
			continue
		var mesh := _kit_merged_mesh(spec)
		if mesh == null:
			continue
		_batch_mesh(scenery, mesh, poses, spec)
		var node := scenery.get_child(scenery.get_child_count() - 1) as MultiMeshInstance3D
		if node != null and mesh.get_surface_count() > 0:
			node.material_override = CityNightLights.streetlamp_material(mesh.surface_get_material(0))


static func _build_car_multimesh(scenery: Node3D, cars: Dictionary[String, Array]) -> void:
	for spec: String in cars:
		var poses: Array[Transform3D] = []
		poses.assign(cars[spec])
		_batch_kit(scenery, spec, poses)


static func _build_bollard_multimesh(scenery: Node3D, transforms: Array[Transform3D]) -> void:
	var bollard := CylinderMesh.new()
	bollard.top_radius = 0.42
	bollard.bottom_radius = 0.34
	bollard.height = 0.85
	bollard.radial_segments = 8
	bollard.material = _mats["hazard_yellow"]
	var poses: Array[Transform3D] = []
	for pose in transforms:
		poses.append(pose.translated(Vector3.UP * 0.42))
	_batch_mesh(scenery, bollard, poses, "scenery/bollard")


# ---------------------------------------------------------------------------
# Material Cache (Created Once, Shared City-Wide)
# ---------------------------------------------------------------------------

static func _ensure_materials() -> void:
	if not _mats.is_empty():
		return

	# Ground pads per district theme
	_mats["grass"] = _simple_mat(Color("#3b5d3f"), 0.96, 0.0)
	_mats["plaza"] = _simple_mat(Color("#8c877c"), 0.90, 0.0)
	_mats["freight_pad"] = _simple_mat(Color("#474b4e"), 0.95, 0.0)
	_mats["refinery_pad"] = _simple_mat(Color("#4c4640"), 0.95, 0.0)
	_mats["shipyard_pad"] = _simple_mat(Color("#434b52"), 0.94, 0.0)
	_mats["midtown_pad"] = _simple_mat(Color("#5c5f61"), 0.92, 0.0)
	_mats["historic_pad"] = _simple_mat(Color("#6b6352"), 0.94, 0.0)

	# Architectural & maritime solids (landmarks, cranes, quay walls)
	_mats["concrete_light"] = _simple_mat(Color("#b6b0a3"), 0.88, 0.0)
	_mats["concrete_warm"] = _simple_mat(Color("#9e8f7b"), 0.90, 0.0)
	_mats["seawall"] = _simple_mat(Color("#54595c"), 0.94, 0.0)
	# Warm light natural oak matching the bedroom desk/trim under main-world Filmic lighting
	_mats["sandbox_wood"] = _simple_mat(Color(0.73, 0.59, 0.44), 0.78, 0.0)
	_mats["steel_dark"] = _simple_mat(Color("#2f363c"), 0.58, 0.42)
	_mats["steel_light"] = _simple_mat(Color("#8d969d"), 0.52, 0.48)
	_mats["crane_red"] = _simple_mat(Color("#bf442c"), 0.58, 0.22)
	_mats["hull_red"] = _simple_mat(Color("#862c22"), 0.72, 0.15)
	_mats["hazard_yellow"] = _simple_mat(Color("#d99a26"), 0.55, 0.15)
	_mats["fountain_water"] = _simple_mat(Color("#2d7f8c"), 0.22, 0.10)
	_mats["drydock_water"] = _simple_mat(Color("#1d454c"), 0.30, 0.08)
	_mats["glass_blue"] = _window_mat(Color("#2f4656"), Color("#5f8396"), Color("#d6bb8a"))

	# Emissive coastal beacons
	var glow := _simple_mat(Color("#ffdf94"), 0.2, 0.0)
	glow.emission_enabled = true
	glow.emission = Color("#ffcf6e")
	glow.emission_energy_multiplier = 2.6
	_mats["beacon_glow"] = glow

	var red_glow := _simple_mat(Color("#ff442b"), 0.2, 0.0)
	red_glow.emission_enabled = true
	red_glow.emission = Color("#ff3a22")
	red_glow.emission_energy_multiplier = 3.0
	_mats["beacon_red"] = red_glow

	# Striped lighthouse texture
	_mats["lighthouse"] = _striped_mat(Color("#ebe6da"), Color("#bf3626"), 0.50, 0.78, 0.0)


static func _simple_mat(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m


static func _window_mat(frame: Color, glass: Color, lit: Color) -> StandardMaterial3D:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		var floor_band := (y % 16) < 4
		for x in 64:
			var mullion := (x % 8) < 2
			if floor_band or mullion:
				img.set_pixel(x, y, frame)
			else:
				var cell_hash := ((x / 8) * 37 + (y / 16) * 71) % 11
				var col := lit if cell_hash == 0 or cell_hash == 4 else glass.darkened(float(cell_hash % 3) * 0.07)
				img.set_pixel(x, y, col)
	var tex := ImageTexture.create_from_image(img)
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.uv1_triplanar = true
	m.uv1_scale = Vector3(0.085, 0.085, 0.085)
	m.roughness = 0.28
	m.metallic = 0.38
	return m


static func _striped_mat(base: Color, stripe: Color, ratio: float, roughness: float, metallic: float) -> StandardMaterial3D:
	var img := Image.create(32, 64, false, Image.FORMAT_RGBA8)
	var cut := int(64.0 * ratio)
	for y in 64:
		var col := stripe if (y % 32) < (cut / 2) else base
		for x in 32:
			img.set_pixel(x, y, col)
	var tex := ImageTexture.create_from_image(img)
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.uv1_scale = Vector3(1.0, 2.5, 1.0)
	m.roughness = roughness
	m.metallic = metallic
	return m


static func _make_box(size: Vector3, pos: Vector3, mat: Material, shadow: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	if not shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func _make_cyl(top_r: float, bot_r: float, height: float, pos: Vector3, mat: Material, shadow: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_r
	mesh.bottom_radius = bot_r
	mesh.height = height
	mesh.radial_segments = 14
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	if not shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
