extends Node3D

const SPIN_RATE := TAU / 1.8
const DEFAULT_DRAW_DISTANCE := 300.0
const DRAW_MARGIN := 24.0
const CULL_INTERVAL := 0.18

var _mesh: ArrayMesh
var _visible_tokens: Array[Node3D] = []
var _cull_in := 0.0


func spawn_coin(at: Vector3, radius: float) -> Node3D:
	if _mesh == null:
		_mesh = _build_coin_mesh()
	var coin := Node3D.new()
	coin.position = at
	add_child(coin)

	var token := MeshInstance3D.new()
	token.mesh = _mesh
	token.position.y = radius * 1.12
	token.scale = Vector3.ONE * radius
	token.rotation.y = randf() * TAU
	token.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	coin.add_child(token)
	_cull_in = 0.0
	return coin


func _process(delta: float) -> void:
	var count := get_child_count()
	if count == 0:
		_visible_tokens.clear()
		return
	_cull_in -= delta
	if _cull_in <= 0.0:
		_refresh_visible(count)
	var step := SPIN_RATE * delta
	for i in range(_visible_tokens.size() - 1, -1, -1):
		var token := _visible_tokens[i]
		if not is_instance_valid(token):
			_visible_tokens.remove_at(i)
			continue
		token.rotation.y = fposmod(token.rotation.y + step, TAU)


func _refresh_visible(count: int) -> void:
	_cull_in = CULL_INTERVAL
	_visible_tokens.clear()
	var camera := get_viewport().get_camera_3d()
	var cull := camera != null
	var cam_x := 0.0
	var cam_z := 0.0
	var limit_sq := 0.0
	if cull:
		var cam_pos := to_local(camera.global_position)
		cam_x = cam_pos.x
		cam_z = cam_pos.z
		var range_m := float(camera.get_meta(&"district_draw_distance", DEFAULT_DRAW_DISTANCE)) + DRAW_MARGIN
		limit_sq = range_m * range_m
	for i in count:
		var coin := get_child(i) as Node3D
		if cull:
			var dx := coin.position.x - cam_x
			var dz := coin.position.z - cam_z
			var active := dx * dx + dz * dz <= limit_sq
			if coin.visible != active:
				coin.visible = active
			if not active:
				continue
		_visible_tokens.append(coin.get_child(0) as Node3D)


func _build_coin_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var flip := Basis(Vector3.RIGHT, PI * 0.5)
	for spec: Array in [
		[1.0, 0.24, Color("#ffe18a"), 0.71],
		[0.74, 0.29, Color("#eaaa2d"), 0.45],
	]:
		var cylinder := _coin_cylinder(spec[0], spec[1], spec[2], spec[3])
		var arrays := cylinder.get_mesh_arrays()
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in vertices.size():
			vertices[i] = flip * vertices[i]
			normals[i] = flip * normals[i]
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		if arrays[Mesh.ARRAY_TANGENT] is PackedFloat32Array:
			var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
			for i in range(0, tangents.size(), 4):
				var tangent := flip * Vector3(tangents[i], tangents[i + 1], tangents[i + 2])
				tangents[i] = tangent.x
				tangents[i + 1] = tangent.y
				tangents[i + 2] = tangent.z
			arrays[Mesh.ARRAY_TANGENT] = tangents
		var surface := mesh.get_surface_count()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(surface, cylinder.material)
	return mesh


func _coin_cylinder(radius: float, thickness: float, color: Color, metallic: float) -> CylinderMesh:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = 0.34
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 0.35
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = thickness
	mesh.radial_segments = 20
	mesh.rings = 0
	mesh.material = material
	return mesh
