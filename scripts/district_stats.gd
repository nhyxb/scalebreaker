extends SceneTree
## District geometry probe: prints build time, node counts, triangle totals and the
## per-category / per-asset bill for the harbour so asset swaps and batching can be
## compared with the same yardstick.
##
##   XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --fixed-fps 60 \
##       --script res://scripts/district_stats.gd
##
## Triangles are counted from MeshInstance3D surfaces and MultiMesh instance counts, so
## the numbers do not depend on a renderer; draw calls are NOT reported (headless uses a
## dummy renderer and would report zero). `draw_items` is an estimate: one item per
## rendered surface of every MeshInstance3D and one per surface of every
## MultiMeshInstance3D node (a MultiMesh draws all of its instances per surface in one
## call). It is the number of draw submissions the map asks for, before frustum culling.

## Batches hold the global prop MultiMeshes, BuildingBatches the three building layers.
const ROOTS: Array[String] = ["Roads", "Lots", "Scenery", "Targets", "Batches",
		"BuildingBatches"]
const TOP_ASSETS := 12

var _game: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_game = load("res://scenes/main.tscn").instantiate()
	_game.settings_path = "user://district-stats-%d.cfg" % OS.get_process_id()
	root.add_child(_game)
	await process_frame
	_game.save_all_mode_settings(_game.default_mode_settings(0),
			_game.default_mode_settings(1), _game.default_mode_settings(2),
			_game.default_mode_settings(3))
	var begin := Time.get_ticks_usec()
	_game.start_mode(true)
	var build_ms := (Time.get_ticks_usec() - begin) / 1000.0
	await process_frame
	var round_node := _game.get_node("MapSlot/Round")
	var district := round_node.get_node("District")
	var total := _blank()
	for root_name in ROOTS:
		var node := district.get_node_or_null(root_name)
		if node == null:
			continue
		var stats := _blank()
		_scan(node, stats)
		_add(total, stats)
		print("STATS %-8s nodes=%6d mesh_nodes=%5d multimesh_nodes=%5d instances=%6d surfaces=%5d tris=%9d" % [
			root_name, stats.nodes, stats.meshes, stats.multimeshes, stats.instances,
			stats.surfaces, stats.tris])
	print("STATS TOTAL    nodes=%6d mesh_nodes=%5d multimesh_nodes=%5d instances=%6d surfaces=%5d tris=%9d build_ms=%.1f" % [
		total.nodes, total.meshes, total.multimeshes, total.instances, total.surfaces,
		total.tris, build_ms])
	print("STATS FRAGMENT avg_instances_per_multimesh=%.1f multimesh_with_one_instance=%d" % [
		float(total.instances) / maxf(float(total.multimeshes), 1.0), total.singles])
	# Chunk culling keeps most target meshes unbuilt; force every lot visible so the tri
	# totals cover the whole harbour instead of only the spawn area.
	for target in district.get_node("Targets").get_children():
		if target.has_method(&"set_render_active"):
			target.set_render_active(true)
	for scenery in district.get_node("Scenery").get_children():
		if scenery.has_method(&"set_render_active"):
			scenery.set_render_active(true)
		else:
			scenery.visible = true
	var built := _blank()
	_built_assets.clear()
	for root_name in ROOTS:
		var node := district.get_node_or_null(root_name)
		if node != null:
			_scan(node, built)
	print("STATS built_nodes=%d built_mesh_nodes=%d built_instances=%d built_tris=%d built_surfaces=%d" % [
			built.nodes, built.meshes, built.instances, built.tris, built.surfaces])
	var batches := district.get_node_or_null("BuildingBatches")
	if batches != null:
		var info: Dictionary = batches.call(&"stats")
		print("STATS BUILDING_BATCHES buildings=%d near_nodes=%d far_nodes=%d near_live=%d far_live=%d ruins=%d refills=%d refill_us=%d" % [
			info["buildings"], info["near_nodes"], info["far_nodes"], info["near_live"],
			info["far_live"], info["ruins"], info["refills"], info["refill_us"]])
	print("STATS targets=%d scenery=%d" % [
			district.get_node("Targets").get_child_count(),
			district.get_node("Scenery").get_child_count()])
	# Same-yardstick triangle bill, largest first. `nodes` is how many render nodes carry
	# the asset and `instances` how many copies they draw.
	var rows: Array = []
	for key: String in _built_assets:
		var row: Dictionary = _built_assets[key]
		rows.append([row.tris, key, row.nodes, row.instances])
	rows.sort_custom(func(a, b): return a[0] > b[0])
	print("STATS TOP_ASSETS (built)")
	for i in mini(rows.size(), TOP_ASSETS):
		var row: Array = rows[i]
		print("  %9d tris  nodes=%4d instances=%5d  %s" % [row[0], row[2], row[3], row[1]])
	var kinds := {}
	for target in district.get_node("Targets").get_children():
		var style: String = String(target.procedural_style)
		if style == "":
			style = "historic"
		var row: Array = kinds.get_or_add(style, [0, 0])
		row[0] += 1
		row[1] += _tris_of(target)
		kinds[style] = row
	var keys := kinds.keys()
	keys.sort()
	for key: String in keys:
		print("  %-14s count=%4d tris=%8d" % [key, kinds[key][0], kinds[key][1]])
	_game.show_menu()
	DirAccess.remove_absolute(_game.settings_path)
	quit(0)


var _built_assets: Dictionary = {}


func _blank() -> Dictionary:
	return {"nodes": 0, "meshes": 0, "multimeshes": 0, "instances": 0, "surfaces": 0,
			"tris": 0, "singles": 0}


func _add(stats: Dictionary, other: Dictionary) -> void:
	for key: String in other:
		stats[key] += other[key]


func _scan(node: Node, stats: Dictionary) -> void:
	stats.nodes += 1
	if node is MultiMeshInstance3D:
		stats.multimeshes += 1
		var mm: MultiMesh = node.multimesh
		if mm != null and mm.mesh != null:
			stats.instances += mm.instance_count
			stats.surfaces += maxi(mm.mesh.get_surface_count(), 1)
			stats.tris += _mesh_tris(mm.mesh) * mm.instance_count
			if mm.instance_count <= 1:
				stats.singles += 1
			_count_asset(_asset_key(node), 1, mm.instance_count, _mesh_tris(mm.mesh) * mm.instance_count)
	elif node is MeshInstance3D:
		stats.meshes += 1
		var mi: MeshInstance3D = node
		if mi.mesh != null:
			stats.instances += 1
			stats.surfaces += maxi(mi.mesh.get_surface_count(), 1)
			stats.tris += _mesh_tris(mi.mesh)
			_count_asset(_mesh_key(mi), 1, 1, _mesh_tris(mi.mesh))
	for child in node.get_children():
		_scan(child, stats)


func _count_asset(key: String, nodes: int, instances: int, tris: int) -> void:
	var row: Dictionary = _built_assets.get_or_add(key, {"nodes": 0, "instances": 0, "tris": 0})
	row["nodes"] += nodes
	row["instances"] += instances
	row["tris"] += tris
	_built_assets[key] = row


## Asset label for a batched node: the generator stamps the source spec ("suburban/tree-large",
## "road/RoadStraight", "lot_pad/…"); older batches fall back to the mesh resource path.
func _asset_key(node: MultiMeshInstance3D) -> String:
	var tag: String = String(node.get_meta(&"asset", ""))
	if tag != "":
		return tag
	var mm := node.multimesh
	if mm != null and mm.mesh != null and mm.mesh.resource_path != "":
		return mm.mesh.resource_path
	return "multimesh/" + node.name


## Asset label for a single mesh: the GLB path for kit props, otherwise the owning node.
func _mesh_key(node: MeshInstance3D) -> String:
	var mesh := node.mesh
	if mesh != null and mesh.resource_path != "":
		return mesh.resource_path.trim_prefix("res://assets/kenney/")
	var owner := node.get_parent()
	var depth := 0
	while owner != null and depth < 3 and (owner.name.ends_with("Model") or owner.name == "KitModel"):
		owner = owner.get_parent()
		depth += 1
	if owner != null and owner.get("kind") != null:
		var style: String = String(owner.get("historic_style"))
		if style == "":
			style = String(owner.get("procedural_style"))
		if style == "":
			style = "custom"
		return "target/%s" % style
	if owner == null:
		return "mesh/" + (mesh.get_class() if mesh != null else "null")
	return "procedural/%s/%s" % [owner.name, mesh.get_class() if mesh != null else "null"]


func _tris_of(node: Node) -> int:
	var total := 0
	for child in node.get_children():
		total += _tris_of(child)
	if node is MeshInstance3D and node.mesh != null:
		total += _mesh_tris(node.mesh)
	return total


func _mesh_tris(mesh: Mesh) -> int:
	var total := 0
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var index = arrays[Mesh.ARRAY_INDEX]
		total += (index.size() if index != null else arrays[Mesh.ARRAY_VERTEX].size()) / 3
	return total
