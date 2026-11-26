extends Node3D

const DistrictExpansion := preload("res://scenes/district_expansion.gd")
const DistrictBatches := preload("res://scenes/district_batches.gd")
const CHUNK_SIZE := DistrictExpansion.RENDER_CHUNK_SIZE
const CULL_INTERVAL := 0.18
const CULL_MARGIN := 24.0
const DRAW_DISTANCE := 300.0

var spawn_points: PackedVector3Array
var map_side := 0
var play_edge: float
var micro_ground := false
var _render_chunks: Dictionary[Vector2i, Array] = {}
var _active_chunks: Dictionary[Vector2i, bool] = {}
var _cull_in := 0.0
var _last_camera_id := 0
var _last_cull_position := Vector2.INF
var _last_draw_distance := -1.0
var building_batches: Node3D


func _ready() -> void:
	var surface: MeshInstance3D = $Ground/Surface
	var land := surface.mesh as BoxMesh
	if map_side == 0:
		map_side = roundi(land.size.x)
	if map_side != land.size.x:
		_resize_land(surface, land)
	var east: CollisionShape3D = $Boundary/East
	play_edge = east.position.x - (east.shape as BoxShape3D).size.z * 0.5
	if map_side != land.size.x:
		_fit_core()
	if micro_ground:
		# Separate the terrain backing from the asphalt and lot faces at shallow angles.
		# The walkable collider stays at zero so coin and character contact heights agree.
		surface.position.y = -0.012
		$Lots.position.y = -0.015
		for floor_mesh: MeshInstance3D in [surface] + $Lots.get_children():
			floor_mesh.material_override = DistrictExpansion.ground_detail(floor_mesh.mesh.material)
	spawn_points = DistrictExpansion.populate(self, micro_ground, map_side * 0.5)
	# Buildings are drawn by three map-wide MultiMesh layers (near detail, far low-detail,
	# ruins) and stay visible everywhere; only the loose props under `Scenery` still stream
	# with the render chunks.
	building_batches = DistrictBatches.new()
	building_batches.name = "BuildingBatches"
	add_child(building_batches)
	building_batches.prepare($Targets)
	for item: Node3D in $Scenery.get_children():
		var key := DistrictExpansion.render_chunk(item.position)
		var chunk: Array = _render_chunks.get_or_add(key, [])
		chunk.append(item)
		item.hide()


func _resize_land(surface: MeshInstance3D, land: BoxMesh) -> void:
	var mesh := land.duplicate() as BoxMesh
	mesh.size = Vector3(map_side, land.size.y, map_side)
	surface.mesh = mesh

	var ground: CollisionShape3D = $Ground/Collision
	var ground_shape := ground.shape.duplicate() as BoxShape3D
	ground_shape.size = mesh.size
	ground.shape = ground_shape

	var half_land := map_side * 0.5
	# Preserve the regular coastline and thin the walls when the land is too narrow.
	var coast_gap := clampf(half_land - 7.0, 0.0, 3.0)
	var thickness := minf(2.0, half_land * 0.1)
	var edge := half_land - coast_gap - thickness * 0.5
	var wall_shape := $Boundary/East.shape.duplicate() as BoxShape3D
	wall_shape.size = Vector3(2.0 * edge + thickness * 2.0, wall_shape.size.y, thickness)
	for wall: CollisionShape3D in $Boundary.get_children():
		var outward := Vector3(wall.position.x, 0.0, wall.position.z).normalized()
		wall.position = outward * edge + Vector3.UP * wall.position.y
		wall.shape = wall_shape


func _fit_core() -> void:
	var limit := Vector2.ONE * (play_edge - 0.5)
	for target: Node3D in $Targets.get_children():
		var half: Vector3 = target.footprint * 0.5
		var footprint := Vector2(
				absf(target.basis.x.x) * half.x + absf(target.basis.z.x) * half.z,
				absf(target.basis.x.z) * half.x + absf(target.basis.z.z) * half.z)
		var center := Vector2(target.position.x, target.position.z)
		var fits := absf(center.x) + footprint.x <= limit.x and absf(center.y) + footprint.y <= limit.y
		var can_move: bool = target.historic_style == &"marineworks" \
				and footprint.x * 2.0 + 3.5 <= limit.x and footprint.y * 2.0 + 3.5 <= limit.y
		if not fits and can_move:
			var fitted := center.clamp(footprint - limit, limit - footprint)
			target.position = Vector3(fitted.x, target.position.y, fitted.y)
		elif not fits:
			$Targets.remove_child(target)
			target.queue_free()

	var land_edge := Vector2.ONE * map_side * 0.5
	for lot: Node3D in $Lots.get_children():
		if lot is MultiMeshInstance3D:
			_trim_lot_batch(lot, land_edge)
			continue
		var size: Vector3 = lot.mesh.size
		var half := Vector2(size.x, size.z) * 0.5
		var center := Vector2(lot.position.x, lot.position.z)
		var lower := (center - half).max(-land_edge)
		var upper := (center + half).min(land_edge)
		if upper.x <= lower.x or upper.y <= lower.y:
			$Lots.remove_child(lot)
			lot.queue_free()
			continue
		if upper - lower != half * 2.0:
			var mesh := lot.mesh.duplicate() as BoxMesh
			mesh.size = Vector3(upper.x - lower.x, size.y, upper.y - lower.y)
			lot.mesh = mesh
			lot.position = Vector3((lower.x + upper.x) * 0.5, lot.position.y, (lower.y + upper.y) * 0.5)

	# The central east-west road stays available even when the outer avenue is cut off.
	var marker_edge := play_edge - minf(4.0, play_edge * 0.25)
	# Leave room for the evacuee's 0.42 m capsule on metre-scale maps.
	marker_edge = minf(marker_edge, play_edge - 0.43)
	var exit: Vector3 = $Evacuation.position
	if maxf(absf(exit.x), absf(exit.z)) + 3.0 > play_edge:
		$Evacuation.position = Vector3(marker_edge, 0.0, 0.0)
	$HumanSpawn.position.z = maxf($HumanSpawn.position.z, -marker_edge)
	$GiantSpawn.position.z = minf($GiantSpawn.position.z, marker_edge)


## Drops the lot-pad instances that fall outside the land on compact maps.
func _trim_lot_batch(lot: MultiMeshInstance3D, land_edge: Vector2) -> void:
	var mm := lot.multimesh
	var kept: Array[Transform3D] = []
	for i in mm.instance_count:
		var pose := mm.get_instance_transform(i)
		var center := Vector2(pose.origin.x, pose.origin.z)
		# The pad mesh is a 24 m box; keep it only while it fits inside the land.
		if absf(center.x) + 12.0 <= land_edge.x and absf(center.y) + 12.0 <= land_edge.y:
			kept.append(pose)
	if kept.size() == mm.instance_count:
		return
	if kept.is_empty():
		$Lots.remove_child(lot)
		lot.queue_free()
		return
	mm.instance_count = kept.size()
	for i in kept.size():
		mm.set_instance_transform(i, kept[i])


func _process(delta: float) -> void:
	_cull_in -= delta
	if _cull_in > 0.0:
		return
	_cull_in = CULL_INTERVAL
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var at := to_local(camera.global_position)
	var flat := Vector2(at.x, at.z)
	if building_batches != null:
		building_batches.call(&"update_for_camera", at)
	var camera_id := camera.get_instance_id()
	var range_m := float(camera.get_meta(&"district_draw_distance", DRAW_DISTANCE))
	if camera_id == _last_camera_id and range_m == _last_draw_distance and _last_cull_position.distance_squared_to(flat) < 0.25:
		return
	_last_camera_id = camera_id
	_last_cull_position = flat
	_last_draw_distance = range_m
	var point := flat / CHUNK_SIZE
	for key: Vector2i in _render_chunks:
		var was_active := _active_chunks.has(key)
		var nearest := point.clamp(Vector2(key), Vector2(key + Vector2i.ONE))
		var distance_sq := point.distance_squared_to(nearest) * CHUNK_SIZE * CHUNK_SIZE
		var limit := range_m + CULL_MARGIN if was_active else range_m
		var active := distance_sq <= limit * limit
		if active == was_active:
			continue
		if active:
			_active_chunks[key] = true
		else:
			_active_chunks.erase(key)
		for item: Node3D in _render_chunks[key]:
			if item.has_method(&"set_render_active"):
				item.set_render_active(active)
			else:
				item.visible = active
