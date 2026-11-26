extends Node3D

const HistoricBuildings := preload("res://scenes/historic_buildings.gd")
const BuildingBatches := preload("res://scenes/district_batches.gd")
const BUILDING_LAYER := 8
const RUBBLE_LAYER := 16

## Destructible district prop: an intact model plus a blocking box, a 3.5 s collapse,
## walkable rubble and a rebuild path for growth mode.
##
## The intact model is either a baked procedural Node3D (added as "IntactModel" before the
## node enters the tree), a historic Kenney GLB scene (`historic_style`), or any Kenney kit
## GLB passed as `intact_scene`. Kit models are fitted from their real AABB: `kit_scale`
## magnifies the raw kit units (the city kits are authored on a ~12 m grid), the model is
## clamped into the `footprint` slot box, grounded on y = 0, re-centred horizontally, and
## `footprint` is rewritten to the resulting box so collision, rubble and `district._fit_core()`
## all use the true size.

const KIT_EPSILON := 0.0001
const COLLAPSE_SECONDS := 3.5

@export var kind: String
@export var historic_style: StringName
@export var footprint := Vector3.ONE
@export var ruin_floor: HeightMapShape3D
@export var procedural_style := ""
@export var ruin_color := Color("#7c7468")
## Kenney GLB used as the intact model, e.g. "res://assets/kenney/commercial/building-a.glb".
@export var intact_scene: PackedScene
## Magnification applied to the raw kit units. 0 fits the model exactly into `footprint`.
@export var kit_scale := 0.0
## Extra copies of `intact_scene` in raw kit space (container stacks, tank clusters).
var kit_layout: Array[Transform3D] = []
## The batch layer that draws this building, assigned by `district_batches.gd`.
var batch: Node = null
## True for the ~1,570 district buildings that are drawn by `scenes/district_batches.gd`
## instead of their own IntactModel: the batch owns the intact, far and ruin looks, this node
## keeps the collision box, the collapse animation and the walkable rubble.
@export var batched := false

var _visual: Node3D
var _blocker: StaticBody3D
var _blocker_shape: CollisionShape3D
var _jolt: Tween
var _collapse: Tween
var _rebuild_model: Node3D
var _intact_transform: Transform3D
var _before_grab: Variant = null
var _cracked := false
var _destroyed := false
var _kit_fit := Vector3.ZERO
var _kit_anchor := Vector3.ZERO
static var _scorch: StandardMaterial3D
static var _dust_mesh: SphereMesh
## PackedScene -> Array of [Mesh, Transform3D] parts (kit GLBs are tiny; instantiate once).
static var _kit_parts: Dictionary = {}
static var _kit_bounds: Dictionary = {}


func _ready() -> void:
	_visual = get_node_or_null("IntactModel")
	# Kit buildings are fitted up front (collision, footprint, AI routes need the real box)
	# but their meshes are only instanced once the render chunk becomes active.
	if _visual == null and intact_scene != null:
		_fit_kit_intact()
	if not batched and _visual == null and (intact_scene != null or not historic_style.is_empty()):
		# Hero buildings (the twelve core lots and the two landmarks) are never culled, so
		# their model is built up front instead of waiting for a render chunk to wake up.
		_ensure_intact_visual()
	if _visual:
		_intact_transform = _visual.transform
	elif historic_style.is_empty() and not batched:
		_ensure_intact_visual()
	_blocker = StaticBody3D.new()
	_blocker.name = "BlockingBody"
	_blocker.collision_layer = BUILDING_LAYER if kind == "building" else 2
	_blocker.collision_mask = 0
	var collider := CollisionShape3D.new()
	var box := BoxShape3D.new()
	var blocking_size := footprint
	if kind == "barrier":
		# Keep the intact barrier too tall for the grown capsule to slide over.
		blocking_size.y = maxf(blocking_size.y, 1.65)
	box.size = blocking_size
	collider.shape = box
	collider.position.y = blocking_size.y * 0.5
	_blocker_shape = collider
	_blocker.add_child(collider)
	add_child(_blocker)


func set_render_active(active: bool) -> void:
	if batched:
		# Batched buildings stay visible everywhere; their instances are streamed by the
		# batch and hidden individually when the building falls.
		visible = true
		return
	visible = active
	if not active or _visual:
		return
	if _destroyed:
		_show_ruins()
	else:
		_ensure_intact_visual()


## Batched rendering hooks used by scenes/district_batches.gd ---------------------------

func _batch_hidden(hidden: bool) -> void:
	if batch != null:
		batch.call(&"set_hidden", self, hidden)


func _batch_cracked(cracked: bool) -> void:
	if batch != null:
		batch.call(&"set_cracked", self, cracked)


func _batch_is_near() -> bool:
	return batch != null and bool(batch.call(&"is_near", self))


func _batch_ruin(visible: bool) -> void:
	if batch == null:
		return
	if visible:
		batch.call(&"show_ruin", self)
	else:
		batch.call(&"clear_ruin", self)


## Unique key of the kit model + extra copies, so every copy shares one MultiMesh.
func batch_spec() -> String:
	if intact_scene == null:
		return "historic/%s" % historic_style if not historic_style.is_empty() else ""
	var key := intact_scene.resource_path
	# The magnification is NOT part of the key: every copy shares the model mesh and the
	# per-instance transform carries its own fit, so landmarks and street blocks batch together.
	if not kit_layout.is_empty():
		key += "@x%d" % kit_layout.size()
	return key


## Kit geometry with every `kit_layout` copy baked in, in raw kit space.
func batch_detail_mesh() -> ArrayMesh:
	if intact_scene == null:
		if not historic_style.is_empty():
			return HistoricBuildings.unit_mesh(historic_style)
		return null
	var parts := _kit_parts_of(intact_scene)
	var slots: Array[Transform3D] = []
	if kit_layout.is_empty():
		slots.append(Transform3D())
	else:
		slots.assign(kit_layout)
	var placed: Array = []
	for slot: Transform3D in slots:
		for part: Array in parts:
			placed.append([part[0], slot * (part[1] as Transform3D)])
	return BuildingBatches.merge_parts(placed)


## Far proxy: commercial/high-rise keep a Kenney `low-detail-building-*` silhouette,
## warehouses, houses and container stacks use the shared box proxy.
func batch_proxy() -> String:
	if procedural_style in ["highrise", "oldharbor"]:
		var pool: PackedStringArray = BuildingBatches.LOW_DETAIL_PROXIES
		return pool[posmod(hash(batch_spec()), pool.size())]
	return BuildingBatches.BOX_PROXY


## Far proxy tint. The kit atlases are tinted per instance, so neighbouring blocks of the
## same model still read as different buildings.
func batch_tint() -> Color:
	var tint := ruin_color
	if tint == Color(0, 0, 0, 0):
		tint = Color("#7c7468")
	var spread := float(posmod(int(absf(position.x) * 7.0 + absf(position.z) * 13.0), 7)) / 7.0
	return tint.lightened(0.05 + spread * 0.16)


## Visual transform of `batch_detail_mesh()` relative to this node.
func batch_instance_local() -> Transform3D:
	if intact_scene == null:
		# Historic silhouettes are baked in a 1 m cube and scaled to the footprint.
		return Transform3D(Basis.from_scale(footprint), Vector3.ZERO)
	if _kit_fit == Vector3.ZERO:
		_fit_kit_intact()
	return Transform3D(Basis.from_scale(_kit_fit), _kit_anchor)


## Builds the kit model as a real child node (used while a batched building is held in a
## hand or falling) because the batch only draws it through a MultiMesh instance.
func _materialize_visual() -> void:
	if _visual != null:
		return
	_visual = _build_kit_intact()
	if _visual != null:
		_visual.name = "IntactModel"
		add_child(_visual)


func _ensure_intact_visual() -> void:
	if _visual or batched:
		return
	if intact_scene != null:
		_visual = _build_kit_intact()
	else:
		_visual = HistoricBuildings.intact(historic_style, footprint) if not historic_style.is_empty() else _roadblock()
	if _visual == null:
		return
	_visual.name = "IntactModel"
	add_child(_visual)
	if _cracked:
		_show_cracks()


## Instantiates the kit GLB with the scale/offset computed by `_fit_kit_intact()`.
func _build_kit_intact() -> Node3D:
	var parts := _kit_parts_of(intact_scene)
	if parts.is_empty():
		push_warning("damageable: %s has no mesh" % intact_scene.resource_path)
		return null
	if _kit_fit == Vector3.ZERO:
		_fit_kit_intact()
	var slots: Array[Transform3D] = []
	if kit_layout.is_empty():
		slots.append(Transform3D())
	else:
		slots.assign(kit_layout)
	var wrapper := Node3D.new()
	wrapper.name = "IntactModel"
	var model := Node3D.new()
	model.name = "KitModel"
	model.scale = _kit_fit
	model.position = _kit_anchor
	wrapper.add_child(model)
	for slot_transform: Transform3D in slots:
		for part: Array in parts:
			var instance := MeshInstance3D.new()
			instance.mesh = part[0]
			instance.transform = slot_transform * (part[1] as Transform3D)
			model.add_child(instance)
	return wrapper


## Fits the kit AABB into the lot: horizontal and vertical magnification, ground offset and
## the real `footprint` used by collision, rubble, `district._fit_core()` and the Rust planner.
func _fit_kit_intact() -> void:
	var raw := _kit_bounds_of(intact_scene, kit_layout)
	var slot := footprint if footprint.x > 0.0 and footprint.z > 0.0 else Vector3.ZERO
	var horizontal := maxf(kit_scale, 0.0)
	var exact_fit := horizontal <= 0.0
	if exact_fit:
		horizontal = 1.0
	var vertical := horizontal
	if slot != Vector3.ZERO:
		var fit := minf(slot.x / maxf(raw.size.x, KIT_EPSILON),
				slot.z / maxf(raw.size.z, KIT_EPSILON))
		horizontal = fit if exact_fit else minf(horizontal, fit)
		vertical = horizontal
		if slot.y > 0.0:
			var height_fit := slot.y / maxf(raw.size.y, KIT_EPSILON)
			vertical = height_fit if exact_fit else minf(horizontal, height_fit)
	elif exact_fit:
		vertical = 1.0
	var center := raw.get_center()
	_kit_fit = Vector3(horizontal, vertical, horizontal)
	# Ground the lowest vertex on y = 0 and centre the footprint on the node origin.
	_kit_anchor = Vector3(-center.x * horizontal, -raw.position.y * vertical, -center.z * horizontal)
	footprint = Vector3(raw.size.x * horizontal, raw.size.y * vertical, raw.size.z * horizontal)


static func _kit_parts_of(scene: PackedScene) -> Array:
	if _kit_parts.has(scene):
		return _kit_parts[scene]
	var parts: Array = []
	var prototype := scene.instantiate() as Node3D
	if prototype != null:
		for part: MeshInstance3D in prototype.find_children("*", "MeshInstance3D", true, false):
			if part.mesh == null:
				continue
			parts.append([part.mesh, _transform_within(part, prototype)])
		prototype.free()
	_kit_parts[scene] = parts
	return parts


static func _kit_bounds_of(scene: PackedScene, layout: Array[Transform3D]) -> AABB:
	if layout.is_empty() and _kit_bounds.has(scene):
		return _kit_bounds[scene]
	var parts := _kit_parts_of(scene)
	var slots: Array = layout if not layout.is_empty() else [Transform3D()]
	var bounds := AABB()
	var first := true
	for slot: Transform3D in slots:
		for part: Array in parts:
			var placed := slot * (part[1] as Transform3D)
			var mesh: Mesh = part[0]
			var box := placed * mesh.get_aabb()
			bounds = box if first else bounds.merge(box)
			first = false
	if layout.is_empty():
		_kit_bounds[scene] = bounds
	return bounds


static func _transform_within(node: Node3D, root: Node3D) -> Transform3D:
	var local := node.transform
	var parent := node.get_parent() as Node3D
	while parent != null and parent != root:
		local = parent.transform * local
		parent = parent.get_parent() as Node3D
	return local


## Public helpers so the district can place the same kit scenes with one yardstick.
static func kit_parts(scene: PackedScene) -> Array:
	return _kit_parts_of(scene)


static func kit_bounds(scene: PackedScene) -> AABB:
	var empty: Array[Transform3D] = []
	return _kit_bounds_of(scene, empty)


func hold_for_hand_attack(palm: Vector3) -> void:
	if batched:
		_batch_hidden(true)
		_materialize_visual()
	_ensure_intact_visual()
	if _before_grab == null:
		_before_grab = _visual.transform
	_visual.global_position = palm - Vector3.UP * footprint.y * 0.5


func release_from_hand_attack() -> void:
	if _before_grab != null:
		_visual.transform = _before_grab
		_before_grab = null
	if batched:
		_replace_visual(null)
		_batch_hidden(false)


func strike(destroyed: bool, passer: CharacterBody3D = null, rebuild := false,
		crushed_in_hand := false) -> StaticBody3D:
	if _destroyed:
		return null
	if destroyed:
		_destroyed = true
		if batched:
			# Clear the intact instance in both batch layers before the collapse plays.
			_batch_hidden(true)
		if rebuild and procedural_style != "":
			_rebuild_model = _visual
		_blocker.collision_layer = 0
		if _blocker_shape != null:
			_blocker_shape.disabled = true
		if ruin_floor == null and kind == "building" and (procedural_style != "" or intact_scene != null):
			ruin_floor = _build_procedural_ruin_floor()
		var floor_body: StaticBody3D
		if ruin_floor:
			floor_body = _add_ruin_floor(passer)
		if _jolt and _jolt.is_running():
			_jolt.kill()
		if not is_visible_in_tree() or (batched and not _batch_is_near()):
			_replace_visual(null)
			if batched:
				_show_ruins()
		elif not crushed_in_hand and kind == "building" \
				and (not historic_style.is_empty() or procedural_style != "" or intact_scene != null):
			if batched and _visual == null:
				# The batch owns the intact look, so the collapse needs its own copy.
				_materialize_visual()
			else:
				_ensure_intact_visual()
			_play_procedural_collapse()
		else:
			_show_ruins()
		var audio := get_node_or_null("/root/HarborAudio")
		if audio != null:
			audio.call("play_building_event", &"collapse" if kind == "building" else &"barrier_break", global_position, footprint.y)
		return floor_body
	_cracked = true
	if batched:
		_batch_cracked(true)
	var crack_audio := get_node_or_null("/root/HarborAudio")
	if crack_audio != null:
		crack_audio.call("play_building_event", &"crack", global_position, footprint.y)
	if is_visible_in_tree() and not batched:
		_ensure_intact_visual()
		_show_cracks()
		if kind == "building":
			_jolt = create_tween()
			_jolt.tween_property(_visual, "rotation:z", 0.035, 0.06)
			_jolt.tween_property(_visual, "rotation:z", -0.025, 0.08)
			_jolt.tween_property(_visual, "rotation:z", 0.0, 0.10)
	return null


func restore_building() -> void:
	if not _destroyed:
		return
	_destroyed = false
	_cracked = false
	if _collapse and _collapse.is_running():
		_collapse.kill()
		var dust := get_node_or_null("CollapseDust")
		if dust:
			remove_child(dust)
			dust.queue_free()
	_collapse = null
	var rubble := get_node_or_null("RuinBody")
	if rubble:
		remove_child(rubble)
		rubble.queue_free()
	_replace_visual(null)
	if batched:
		_batch_ruin(false)
		_batch_cracked(false)
		_batch_hidden(false)
	if _rebuild_model:
		_visual = _rebuild_model
		_rebuild_model = null
		_visual.name = "IntactModel"
		_visual.transform = _intact_transform
		for mesh: MeshInstance3D in _visual.find_children("*", "MeshInstance3D", true, false):
			mesh.material_overlay = null
		_visual.show()
	elif not batched and is_visible_in_tree():
		_ensure_intact_visual()
	_blocker.collision_layer = BUILDING_LAYER
	_blocker_shape.disabled = false
	var audio := get_node_or_null("/root/HarborAudio")
	if audio != null:
		audio.call("play_building_event", &"restore", global_position, footprint.y)


func _show_cracks() -> void:
	if _scorch == null:
		_scorch = StandardMaterial3D.new()
		_scorch.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_scorch.albedo_color = Color(0.24, 0.11, 0.055, 0.48)
		_scorch.roughness = 1.0
	for mesh: MeshInstance3D in _visual.find_children("*", "MeshInstance3D", true, false):
		mesh.material_overlay = _scorch


func _play_procedural_collapse() -> void:
	_visual.name = "CollapseModel"
	var drop_h := maxf(footprint.y * 0.92, 4.0)
	var duration := COLLAPSE_SECONDS if (not historic_style.is_empty() or intact_scene != null) \
			else clampf(1.25 + footprint.y * 0.035, 1.35, 2.55)
	var tilt_x := 0.24 if int(absf(position.x + position.z)) % 2 == 0 else -0.22
	var tilt_z := 0.18 if int(absf(position.x * 3.0)) % 2 == 0 else -0.19

	# Spawn dust plume around the collapsing base.
	var dust_root := Node3D.new()
	dust_root.name = "CollapseDust"
	add_child(dust_root)
	if _dust_mesh == null:
		_dust_mesh = SphereMesh.new()
		_dust_mesh.radial_segments = 6
		_dust_mesh.rings = 3
	var puff_mat := StandardMaterial3D.new()
	puff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff_mat.albedo_color = Color("#b8a389", 0.50)
	var base_rad := maxf(footprint.x, footprint.z) * 0.45
	var dust_tween := dust_root.create_tween().set_parallel(true)
	for i in 5:
		var a := float(i) * TAU / 5.0
		var dir := Vector3(cos(a), 0.0, sin(a))
		var puff := MeshInstance3D.new()
		puff.mesh = _dust_mesh
		puff.material_override = puff_mat
		puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		puff.position = dir * base_rad * 0.65 + Vector3.UP * 0.8
		puff.scale = Vector3.ONE * clampf(base_rad * 0.28, 1.0, 3.2)
		dust_root.add_child(puff)
		dust_tween.tween_property(puff, "position", puff.position + dir * (base_rad * 0.85) + Vector3.UP * (2.5 + float(i % 3)), duration * 0.95).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		dust_tween.tween_property(puff, "scale", puff.scale * 2.4, duration * 0.95)
	dust_tween.tween_property(puff_mat, "albedo_color:a", 0.0, duration)
	dust_tween.chain().tween_callback(dust_root.queue_free)

	_collapse = create_tween().set_parallel(true)
	_collapse.tween_property(_visual, "position:y", -drop_h, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_collapse.tween_property(_visual, "rotation", Vector3(tilt_x, 0.06, tilt_z), duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_collapse.tween_property(_visual, "scale:y", 0.35, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_collapse.chain().tween_callback(_show_ruins)


func _show_ruins() -> void:
	_collapse = null
	if batched:
		_replace_visual(null)
		if not historic_style.is_empty() and ruin_floor != null:
			# The three historic silhouettes keep their heightmap rubble as one node.
			var rubble_model := HistoricBuildings.rubble(ruin_floor)
			rubble_model.name = "RuinModel"
			add_child(rubble_model)
			_visual = rubble_model
			return
		_batch_ruin(true)
		return
	var model: Node3D
	if not historic_style.is_empty():
		model = HistoricBuildings.rubble(ruin_floor)
	elif kind == "building" and (procedural_style != "" or intact_scene != null):
		model = _procedural_ruins()
	else:
		model = _roadblock(true)
	model.name = "RuinModel"
	_replace_visual(model)


func _add_ruin_floor(passer: CharacterBody3D) -> StaticBody3D:
	var floor_body := StaticBody3D.new()
	floor_body.name = "RuinBody"
	# The characters treat the mound as ground, and the spring arm can also hit it.
	floor_body.collision_layer = RUBBLE_LAYER
	floor_body.collision_mask = 0
	var surface := CollisionShape3D.new()
	surface.shape = ruin_floor
	floor_body.add_child(surface)
	add_child(floor_body)

	if passer:
		passer.add_collision_exception_with(floor_body)

	# Move actors already on the lot up to the new surface.
	for actor: CharacterBody3D in get_tree().get_nodes_in_group(&"harbor_actor"):
		if actor == passer or (actor.collision_mask & RUBBLE_LAYER) == 0:
			continue
		var local := floor_body.to_local(actor.global_position)
		var height := _ruin_height(Vector2(local.x, local.z))
		if local.y < height:
			local.y = height + 0.06
			actor.global_position = floor_body.to_global(local)
	return floor_body


func _ruin_height(point: Vector2) -> float:
	var width := ruin_floor.map_width
	var depth := ruin_floor.map_depth
	var index := point + Vector2(width - 1, depth - 1) * 0.5
	if index.x < 0 or index.x >= width - 1 or index.y < 0 or index.y >= depth - 1:
		return -INF
	var cell := Vector2i(index)
	var first := cell.y * width + cell.x
	var values := ruin_floor.map_data
	var row_a := lerpf(values[first], values[first + 1], index.x - cell.x)
	var row_b := lerpf(values[first + width], values[first + width + 1], index.x - cell.x)
	return lerpf(row_a, row_b, index.y - cell.y)


func _replace_visual(model: Node3D) -> void:
	if _visual:
		if _visual == _rebuild_model:
			_visual.hide()
		else:
			remove_child(_visual)
			_visual.queue_free()
	_visual = model
	if model:
		add_child(model)


func _procedural_ruins() -> Node3D:
	var model := Node3D.new()
	var rubble_mat := _material(ruin_color.darkened(0.18))
	var slab_mat := _material(Color("#5f5a52"))
	var peak := clampf(footprint.y * 0.11, 0.9, 2.6)

	# Low walkable rubble mound core
	var mound := _box(Vector3(footprint.x * 0.88, peak * 0.72, footprint.z * 0.88), Vector3(0.0, peak * 0.32, 0.0), slab_mat)
	mound.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	model.add_child(mound)
	var crest := _box(Vector3(footprint.x * 0.52, peak * 0.65, footprint.z * 0.52), Vector3(0.0, peak * 0.62, 0.0), rubble_mat)
	crest.rotation = Vector3(0.08, 0.35, -0.06)
	crest.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	model.add_child(crest)

	# Scattered tilted structural slabs/beams matching building palette
	var rng := RandomNumberGenerator.new()
	rng.seed = int(absf(position.x * 73.0 + position.z * 131.0)) + 17
	for i in 7:
		var sx := rng.randf_range(footprint.x * 0.16, footprint.x * 0.36)
		var sy := rng.randf_range(0.45, peak * 0.65)
		var sz := rng.randf_range(footprint.z * 0.16, footprint.z * 0.36)
		var px := rng.randf_range(-footprint.x * 0.34, footprint.x * 0.34)
		var pz := rng.randf_range(-footprint.z * 0.34, footprint.z * 0.34)
		var mat := rubble_mat if i % 2 == 0 else slab_mat
		var chunk := _box(Vector3(sx, sy, sz), Vector3(px, sy * 0.42, pz), mat)
		chunk.rotation = Vector3(rng.randf_range(-0.32, 0.32), rng.randf_range(0.0, TAU), rng.randf_range(-0.32, 0.32))
		chunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		model.add_child(chunk)
	return model


func _build_procedural_ruin_floor() -> HeightMapShape3D:
	var w := clampi(int(ceilf(footprint.x)) + 3, 5, 25)
	var d := clampi(int(ceilf(footprint.z)) + 3, 5, 25)
	var shape := HeightMapShape3D.new()
	shape.map_width = w
	shape.map_depth = d
	var data := PackedFloat32Array()
	data.resize(w * d)
	var peak := clampf(footprint.y * 0.11, 0.9, 2.6)
	var half_x := maxf(footprint.x * 0.52, 1.0)
	var half_z := maxf(footprint.z * 0.52, 1.0)
	for z in d:
		var wz := float(z) - float(d - 1) * 0.5
		for x in w:
			var wx := float(x) - float(w - 1) * 0.5
			var nx := absf(wx) / half_x
			var nz := absf(wz) / half_z
			var radial := maxf(nx, nz)
			var h := 0.0
			if radial < 1.0:
				h = peak * smoothstep(1.0, 0.15, radial)
			data[z * w + x] = h
	shape.map_data = data
	return shape


func _roadblock(broken := false) -> Node3D:
	var model := Node3D.new()
	var concrete := _material(Color("#9c917f"))
	var orange := _material(Color("#d8703c"))
	var pale := _material(Color("#e9d8a7"))
	for index in 4:
		var x := (float(index) - 1.5) * footprint.x / 4.0
		if broken:
			var debris := _box(Vector3(footprint.x * 0.16, 0.18, 0.40), Vector3(x, 0.10, sin(float(index)) * 0.5), concrete)
			debris.rotation.y = index * 0.7
			model.add_child(debris)
		else:
			model.add_child(_box(Vector3(footprint.x * 0.24, 0.52, footprint.z), Vector3(x, 0.26, 0), concrete))
			model.add_child(_box(Vector3(footprint.x * 0.22, 0.19, footprint.z * 0.76), Vector3(x, 0.61, 0), orange))
			model.add_child(_box(Vector3(footprint.x * 0.08, 0.19, footprint.z * 0.78), Vector3(x, 0.61, 0), pale))
	return model


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.85
	return material


func _box(size: Vector3, center: Vector3, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	instance.mesh = mesh
	instance.position = center
	instance.material_override = material
	return instance
