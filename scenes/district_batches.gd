extends Node3D
## Three-layer MultiMesh renderer for every destructible kit building.
##
## One MultiMesh node per building used to mean ~1,600 draw calls and a 300 m cull that
## hid most of the harbour. This node instead draws the whole map from three layers:
##
##   near   detailed kit mesh, one MultiMesh per kit spec, only the buildings inside
##          `NEAR_RADIUS` of the camera (refilled when the camera moves)
##   far    `low-detail-building-*` proxies (86-378 faces) + one box proxy, one MultiMesh
##          per proxy for every building outside `NEAR_RADIUS`, shadows off
##   ruin   one shared rubble mound for every collapsed building, shadows off
##
## Hidden slots use zero scale to collapse the mesh to a point. The original building
## node still drives the collapse animation and the walkable rubble.
## `cracked` buildings are tinted through the per-instance colour instead of a material
## overlay, which costs nothing.

const CityNightLights := preload("res://scenes/city_night_lights.gd")
const NEAR_RADIUS := 280.0
## The near/far split is only refreshed after the camera moved this far (metres).
const REFILL_STEP := 40.0
const LOW_DETAIL_PROXIES: PackedStringArray = [
	"commercial/low-detail-building-a",
	"commercial/low-detail-building-d",
	"commercial/low-detail-building-f",
	"commercial/low-detail-building-h",
]
const BOX_PROXY := "proxy/box"
const CRACK_TINT := Color(0.52, 0.42, 0.36)
const HIDDEN_TRANSFORM := Transform3D(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)

## node -> entry index
var _index_of: Dictionary = {}
var _entries: Array[Dictionary] = []
## spec -> MultiMeshInstance3D (near layer, one per kit model family)
var _near_nodes: Dictionary = {}
## proxy id -> MultiMeshInstance3D (far layer)
var _far_nodes: Dictionary = {}
var _ruin_node: MultiMeshInstance3D
var _ruin_mesh: ArrayMesh
var _ruins: Array[int] = []
var _last_refill := Vector2(INF, INF)
var _refills := 0
var _refill_us := 0


func prepare(targets: Node3D) -> void:
	var detail_cache: Dictionary = {}
	var proxy_raw: Dictionary = {}
	for proxy: String in LOW_DETAIL_PROXIES:
		proxy_raw[proxy] = _normalized_proxy(proxy)
	proxy_raw[BOX_PROXY] = _box_proxy()
	for node in targets.get_children():
		if not (node is Node3D) or not node.get("batched"):
			continue
		var spec: String = node.call(&"batch_spec")
		if spec == "":
			continue
		node.set(&"batch", self)
		if not detail_cache.has(spec):
			detail_cache[spec] = node.call(&"batch_detail_mesh")
			if detail_cache[spec] == null:
				detail_cache[spec] = _box_proxy()
		var proxy: String = node.call(&"batch_proxy")
		var entry := {
			"node": node,
			"spec": spec,
			"proxy": proxy,
			"position": node.global_position,
			"basis": node.global_transform.basis.orthonormalized(),
			"footprint": node.footprint,
			"color": node.call(&"batch_tint"),
			"ruin_color": node.ruin_color,
			"alive": true,
			"cracked": false,
			"near_slot": -1,
			"far_slot": -1,
		}
		_index_of[node] = _entries.size()
		_entries.append(entry)
	for spec: String in detail_cache:
		_near_nodes[spec] = _make_layer("Near_%s" % spec.get_slice("/", -1), detail_cache[spec], true)
	# The far layer keeps one permanent slot per building: it is written once here and only
	# toggled when a building crosses into the near radius or falls, so a refill never has to
	# rewrite a thousand proxies.
	var far_counts: Dictionary = {}
	for i in _entries.size():
		var entry: Dictionary = _entries[i]
		var proxy: String = entry["proxy"]
		var slot: int = far_counts.get(proxy, 0)
		far_counts[proxy] = slot + 1
		entry["far_slot"] = slot
		entry["far_zeroed"] = false
	for proxy: String in proxy_raw:
		var node := _make_layer("Far_%s" % String(proxy).get_slice("/", -1), proxy_raw[proxy], true)
		node.multimesh.instance_count = far_counts.get(proxy, 0)
		_far_nodes[proxy] = node
	for i in _entries.size():
		var entry: Dictionary = _entries[i]
		_write_far(entry, false)
	_ruin_mesh = _mound_proxy()
	_ruin_node = _make_layer("Ruins", _ruin_mesh, true)
	_refill(Vector2(0.0, 0.0), true)


func _make_layer(node_name: String, mesh: Mesh, colors: bool) -> MultiMeshInstance3D:
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.use_colors = colors
	batch.mesh = mesh
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = batch
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.set_meta(&"asset", "building/" + node_name)
	add_child(instance)
	return instance


# ---------------------------------------------------------------------------
# Streaming the near/far split
# ---------------------------------------------------------------------------

## Called by `district.gd` every cull tick with the live camera position.
func update_for_camera(at: Vector3) -> void:
	var flat := Vector2(at.x, at.z)
	if _last_refill.distance_squared_to(flat) < REFILL_STEP * REFILL_STEP:
		return
	_refill(flat, false)


func _refill(flat: Vector2, force: bool) -> void:
	if not force and _last_refill.distance_squared_to(flat) < REFILL_STEP * REFILL_STEP:
		return
	var begin := Time.get_ticks_usec()
	_last_refill = flat
	var near_lists: Dictionary = {}
	for i in _entries.size():
		var entry: Dictionary = _entries[i]
		entry["near_slot"] = -1
		if not entry["alive"]:
			continue
		var offset: Vector2 = Vector2(entry["position"].x, entry["position"].z) - flat
		if offset.length_squared() <= NEAR_RADIUS * NEAR_RADIUS:
			var list: Array = near_lists.get_or_add(entry["spec"], [])
			list.append(i)
	for spec: String in _near_nodes:
		var node: MultiMeshInstance3D = _near_nodes[spec]
		_fill_near(node, near_lists.get(spec, []))
	for i in _entries.size():
		var entry: Dictionary = _entries[i]
		var zeroed: bool = (not entry["alive"]) or entry["near_slot"] >= 0
		if zeroed != entry["far_zeroed"]:
			_write_far(entry, zeroed)
	_refills += 1
	_refill_us += Time.get_ticks_usec() - begin


func _fill_near(node: MultiMeshInstance3D, indices: Array) -> void:
	var mm := node.multimesh
	node.set_meta(&"live", indices.size())
	mm.instance_count = indices.size()
	for slot in indices.size():
		var entry: Dictionary = _entries[indices[slot]]
		entry["near_slot"] = slot
		mm.set_instance_transform(slot, _instance_transform(entry, false))
		mm.set_instance_color(slot, CRACK_TINT if entry["cracked"] else Color.WHITE)


## Writes (or clears) the permanent far slot of one building.
func _write_far(entry: Dictionary, zeroed: bool) -> void:
	entry["far_zeroed"] = zeroed
	var node: MultiMeshInstance3D = _far_nodes[entry["proxy"]]
	var slot: int = entry["far_slot"]
	if slot >= node.multimesh.instance_count:
		return
	if zeroed:
		node.multimesh.set_instance_transform(slot, HIDDEN_TRANSFORM)
		return
	node.multimesh.set_instance_transform(slot, _instance_transform(entry, true))
	node.multimesh.set_instance_color(slot, CRACK_TINT if entry["cracked"] else entry["color"])


func _instance_transform(entry: Dictionary, proxy: bool) -> Transform3D:
	var node: Node3D = entry["node"]
	var footprint: Vector3 = node.get(&"footprint")
	var basis: Basis = entry["basis"]
	var position: Vector3 = entry["position"]
	if proxy:
		# The proxy meshes are baked into a unit box: x/z in [-0.5, 0.5], y in [0, 1].
		var scale := Vector3(maxf(footprint.x, 0.05), maxf(footprint.y, 0.05),
				maxf(footprint.z, 0.05))
		return Transform3D(basis * Basis.from_scale(scale), position)
	return Transform3D(basis, position) * (node.call(&"batch_instance_local") as Transform3D)


# ---------------------------------------------------------------------------
# Damageable callbacks
# ---------------------------------------------------------------------------

func set_hidden(node: Node3D, hidden: bool) -> void:
	var entry: Dictionary = _entry(node)
	if entry.is_empty() or entry["alive"] == not hidden:
		return
	entry["alive"] = not hidden
	if hidden:
		_clear_slot(entry, "near_slot")
		_write_far(entry, true)
	else:
		_write_far(entry, entry["near_slot"] >= 0)
		_refill(_last_refill, true)


func set_cracked(node: Node3D, cracked: bool) -> void:
	var entry: Dictionary = _entry(node)
	if entry.is_empty() or entry["cracked"] == cracked:
		return
	entry["cracked"] = cracked
	_tint_slot(entry, "near_slot", Color.WHITE if not cracked else CRACK_TINT)
	if not entry["far_zeroed"]:
		_tint_slot(entry, "far_slot", entry["color"] if not cracked else CRACK_TINT)


func show_ruin(node: Node3D) -> void:
	var entry: Dictionary = _entry(node)
	if entry.is_empty():
		return
	var index: int = _index_of[node]
	if not _ruins.has(index):
		_ruins.append(index)
	_refill_ruins()


func clear_ruin(node: Node3D) -> void:
	var entry: Dictionary = _entry(node)
	if entry.is_empty():
		return
	var index: int = _index_of[node]
	var at := _ruins.find(index)
	if at >= 0:
		_ruins.remove_at(at)
	_refill_ruins()


func _refill_ruins() -> void:
	var mm := _ruin_node.multimesh
	mm.instance_count = _ruins.size()
	for slot in _ruins.size():
		var entry: Dictionary = _entries[_ruins[slot]]
		var footprint: Vector3 = entry["node"].get(&"footprint")
		var scale := Vector3(maxf(footprint.x, 0.2), maxf(footprint.y * 0.22, 0.15), maxf(footprint.z, 0.2))
		mm.set_instance_transform(slot, Transform3D(
				entry["basis"] * Basis.from_scale(scale), entry["position"]))
		mm.set_instance_color(slot, entry["ruin_color"])


func _entry(node: Node3D) -> Dictionary:
	if not _index_of.has(node):
		return {}
	return _entries[_index_of[node]]


func _clear_slot(entry: Dictionary, key: String) -> void:
	var slot: int = entry[key]
	if slot < 0:
		return
	var node: MultiMeshInstance3D = _near_nodes[entry["spec"]] if key == "near_slot" \
			else _far_nodes[entry["proxy"]]
	if slot < node.multimesh.instance_count:
		node.multimesh.set_instance_transform(slot, HIDDEN_TRANSFORM)
	entry[key] = -1


func _tint_slot(entry: Dictionary, key: String, color: Color) -> void:
	var slot: int = entry[key]
	if slot < 0:
		return
	var node: MultiMeshInstance3D = _near_nodes[entry["spec"]] if key == "near_slot" \
			else _far_nodes[entry["proxy"]]
	if slot < node.multimesh.instance_count:
		node.multimesh.set_instance_color(slot, color)


# ---------------------------------------------------------------------------
# Proxy meshes (baked to a unit box so one MultiMesh can scale per instance)
# ---------------------------------------------------------------------------

func _normalized_proxy(spec: String) -> ArrayMesh:
	var scene := load("res://assets/kenney/%s.glb" % spec) as PackedScene
	if scene == null:
		return _box_proxy()
	var parts: Array = []
	var bounds := AABB()
	var first := true
	var prototype := scene.instantiate() as Node3D
	for part: MeshInstance3D in prototype.find_children("*", "MeshInstance3D", true, false):
		if part.mesh == null:
			continue
		var place := _transform_within(part, prototype)
		parts.append([part.mesh, place])
		var box: AABB = place * part.mesh.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	prototype.free()
	if parts.is_empty():
		return _box_proxy()
	var size := Vector3(maxf(bounds.size.x, 0.0001), maxf(bounds.size.y, 0.0001),
			maxf(bounds.size.z, 0.0001))
	var normalize := Transform3D(
			Basis.IDENTITY.scaled(Vector3(1.0 / size.x, 1.0 / size.y, 1.0 / size.z)),
			Vector3(-bounds.position.x / size.x, -bounds.position.y / size.y, -bounds.position.z / size.z))
	return merge_parts(parts, normalize, true)


func _box_proxy() -> ArrayMesh:
	var size := Vector3(1.0, 1.0, 1.0)
	var material: Material = CityNightLights.far_box_material()
	var body := BoxMesh.new()
	body.material = material
	body.size = Vector3(size.x, size.y * 0.86, size.z)
	var parts: Array = [[body, Transform3D(Basis.IDENTITY, Vector3(0.0, size.y * 0.43, 0.0))]]
	var roof := PrismMesh.new()
	roof.material = material
	roof.size = Vector3(size.x * 1.04, size.y * 0.14, size.z * 1.04)
	parts.append([roof, Transform3D(Basis.IDENTITY, Vector3(0.0, size.y * 0.93, 0.0))])
	return merge_parts(parts, Transform3D(), true)


func _mound_proxy() -> ArrayMesh:
	var rings := 8
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var low := 0.0
	var high := 1.0
	var inner := 0.34
	for i in rings:
		var a0 := TAU * float(i) / float(rings)
		var a1 := TAU * float(i + 1) / float(rings)
		var p0 := Vector3(cos(a0) * 0.5, low, sin(a0) * 0.5)
		var p1 := Vector3(cos(a1) * 0.5, low, sin(a1) * 0.5)
		var q0 := Vector3(cos(a0) * inner, high * (0.75 + 0.25 * float(i % 2)), sin(a0) * inner)
		var q1 := Vector3(cos(a1) * inner, high * (0.75 + 0.25 * float((i + 1) % 2)), sin(a1) * inner)
		_add_tri(surface, p0, p1, q1)
		_add_tri(surface, p0, q1, q0)
		var apex := Vector3(0.0, high * 1.1, 0.0)
		_add_tri(surface, q0, q1, apex)
	var mesh := surface.commit() as ArrayMesh
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = false
	material.roughness = 0.95
	mesh.surface_set_material(0, material)
	return mesh


func _add_tri(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var normal := (b - a).cross(c - a).normalized()
	surface.set_normal(normal)
	surface.add_vertex(a)
	surface.set_normal(normal)
	surface.add_vertex(b)
	surface.set_normal(normal)
	surface.add_vertex(c)


## MultiMesh instance colours only reach the albedo when the material asks for vertex
## colours, so every batched material is duplicated once with that flag on.
static func tintable(source: Material) -> Material:
	if source == null:
		return null
	var material := source.duplicate() as BaseMaterial3D
	if material == null:
		return source
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = false
	return material


static func merge_parts(parts: Array, place := Transform3D(), far_proxy := false) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var material: Material = null
	for part: Array in parts:
		var mesh: Mesh = part[0]
		var offset: Transform3D = place * (part[1] as Transform3D)
		for surface in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(surface)
			var source: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var source_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] \
					if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			var source_uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] \
					if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
			var base := vertices.size()
			for i in source.size():
				vertices.append(offset * source[i])
				normals.append((offset.basis * (source_normals[i] if i < source_normals.size()
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
	var merged := ArrayMesh.new()
	var merged_arrays := []
	merged_arrays.resize(Mesh.ARRAY_MAX)
	merged_arrays[Mesh.ARRAY_VERTEX] = vertices
	merged_arrays[Mesh.ARRAY_NORMAL] = normals
	merged_arrays[Mesh.ARRAY_TEX_UV] = uvs
	merged_arrays[Mesh.ARRAY_INDEX] = indices
	merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged_arrays)
	var final_mat: Material = null
	if far_proxy:
		final_mat = material if material is ShaderMaterial else CityNightLights.far_textured_material(material)
	else:
		final_mat = CityNightLights.near_building_material(material)
	if final_mat == null:
		final_mat = tintable(material)
	merged.surface_set_material(0, final_mat)
	return merged


func _transform_within(node: Node3D, root: Node3D) -> Transform3D:
	var local := node.transform
	var parent := node.get_parent() as Node3D
	while parent != null and parent != root:
		local = parent.transform * local
		parent = parent.get_parent() as Node3D
	return local


## True while this building's detailed instance sits inside the near radius. Demolition far
## away skips the collapse model because nothing is close enough to see it.
func is_near(node: Node3D) -> bool:
	var entry: Dictionary = _entry(node)
	return not entry.is_empty() and entry["near_slot"] >= 0


## Debug helper for scripts/district_stats.gd and the perf probe.
func stats() -> Dictionary:
	var near_live := 0
	var far_live := 0
	for spec: String in _near_nodes:
		near_live += int(_near_nodes[spec].get_meta(&"live", 0))
	for entry: Dictionary in _entries:
		if entry["alive"] and not entry["far_zeroed"]:
			far_live += 1
	return {
		"buildings": _entries.size(),
		"near_nodes": _near_nodes.size(),
		"far_nodes": _far_nodes.size(),
		"near_live": near_live,
		"far_live": far_live,
		"ruins": _ruins.size(),
		"refills": _refills,
		"refill_us": _refill_us,
	}
