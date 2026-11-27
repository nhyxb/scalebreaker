extends Node3D

const TEAL := Color("#69fbd6")
const AMBER := Color("#ffa64c")
const DUST := Color("#c7a47d")
const IMPACT_DRAW_DISTANCE := 175.0
const FOOTPRINT_SHADER := preload("res://scenes/footprint.gdshader")
const FOOTPRINT_CAPACITY := 72
const FOOTPRINT_LIFETIME := 12.0
const FOOTPRINT_FADE := 4.5
const FOOTPRINT_OPACITY := 0.78
const MASK_CACHE_CAPACITY := 16
const MASK_SIZE := Vector2i(48, 96)
const RIGHT_SOLE := [
	Vector2(-0.72, -0.83), Vector2(-0.29, -1.0), Vector2(0.57, -0.90),
	Vector2(1.0, -0.52), Vector2(0.88, -0.12), Vector2(0.66, 0.25),
	Vector2(0.63, 0.75), Vector2(0.38, 1.0), Vector2(-0.49, 0.94),
	Vector2(-0.74, 0.66), Vector2(-0.67, 0.19), Vector2(-1.0, -0.36)
]

var _sit_warnings: Dictionary[int, Node3D] = {}
var _footprint_root: Node3D
var _footprint_mesh: BoxMesh
var _footprints: Array[Footprint] = []
var _footprint_cursor := 0
var _sole_masks: Dictionary[PackedVector2Array, ImageTexture] = {}
var _dust_material: StandardMaterial3D
var _dust_quad: QuadMesh
var _rng := RandomNumberGenerator.new()


class Footprint:
	var mesh: MeshInstance3D
	var material: ShaderMaterial
	var half_extents: Vector2
	var outline: PackedVector2Array
	var left: bool
	var age := 0.0
	var opacity := 0.0


func _ready() -> void:
	set_physics_process(false)


func _physics_process(delta: float) -> void:
	var any_visible := false
	for mark in _footprints:
		if not mark.mesh.visible:
			continue
		mark.age += delta
		if mark.age >= FOOTPRINT_LIFETIME:
			mark.mesh.hide()
			continue
		any_visible = true
		if mark.age > FOOTPRINT_LIFETIME - FOOTPRINT_FADE:
			mark.opacity = FOOTPRINT_OPACITY * (1.0 - smoothstep(
					FOOTPRINT_LIFETIME - FOOTPRINT_FADE, FOOTPRINT_LIFETIME, mark.age))
			mark.material.set_shader_parameter(&"opacity", mark.opacity)
	if not any_visible:
		set_physics_process(false)


func footfall_effect(center: Vector3, yaw: float, sole_half_extents: Vector2, left: bool,
		height: float, is_player: bool, profile := PackedVector2Array()) -> void:
	_stamp_footprint(center, yaw, sole_half_extents, left, profile)
	var audio := get_node_or_null("/root/HarborAudio")
	if audio != null:
		audio.call("play_giant_footfall", center, height, is_player)
	var camera := get_viewport().get_camera_3d()
	if camera:
		var offset := camera.global_position - center
		var reach := IMPACT_DRAW_DISTANCE + maxf(sole_half_extents.x, sole_half_extents.y)
		if Vector2(offset.x, offset.z).length_squared() > reach * reach:
			return
	_footfall_dust(center, yaw, sole_half_extents, height)


func footprint_debug() -> Array[Dictionary]:
	var active: Array[Dictionary] = []
	for mark in _footprints:
		if mark.mesh.visible:
			active.append({
				"position": mark.mesh.global_position,
				"yaw": mark.mesh.global_rotation.y,
				"half_extents": mark.half_extents,
				"left": mark.left,
				"outline": mark.outline,
				"age": mark.age,
				"opacity": mark.opacity,
			})
	return active


func _stamp_footprint(center: Vector3, yaw: float, half_extents: Vector2, left: bool,
		profile: PackedVector2Array) -> void:
	if _footprint_root == null:
		_footprint_root = Node3D.new()
		_footprint_root.name = "Footprints"
		add_child(_footprint_root)
		_footprint_mesh = BoxMesh.new()
		_footprint_mesh.size = Vector3(2.0, 2.0, 2.0)
	if _footprint_cursor == _footprints.size():
		var slot := Footprint.new()
		slot.mesh = MeshInstance3D.new()
		slot.mesh.name = "Footprint%02d" % (_footprint_cursor + 1)
		slot.mesh.mesh = _footprint_mesh
		slot.mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		slot.material = ShaderMaterial.new()
		slot.material.shader = FOOTPRINT_SHADER
		# Draw the print before transparent dust, shadows, and warning overlays.
		slot.material.render_priority = -10
		slot.mesh.material_override = slot.material
		_footprint_root.add_child(slot.mesh)
		_footprints.append(slot)
	var mark := _footprints[_footprint_cursor]
	_footprint_cursor = (_footprint_cursor + 1) % FOOTPRINT_CAPACITY
	var profile_height := clampf(0.28 + half_extents.length() * 0.035, 0.28, 0.95)
	mark.mesh.global_transform = Transform3D(
			Basis(Vector3.UP, yaw).scaled_local(Vector3(half_extents.x, profile_height, half_extents.y)), center)
	mark.half_extents = half_extents
	mark.left = left
	mark.outline = profile if profile.size() >= 3 else _fallback_sole(left)
	mark.age = 0.0
	mark.opacity = FOOTPRINT_OPACITY
	mark.material.set_shader_parameter(&"sole_mask", _sole_mask(mark.outline))
	mark.material.set_shader_parameter(&"side", -1.0 if left else 1.0)
	mark.material.set_shader_parameter(&"opacity", mark.opacity)
	mark.mesh.show()
	set_physics_process(true)


func _fallback_sole(left: bool) -> PackedVector2Array:
	var outline := PackedVector2Array(RIGHT_SOLE)
	if left:
		for i in outline.size():
			outline[i] *= Vector2(-1.0, 1.0)
	return outline


func _sole_mask(outline: PackedVector2Array) -> ImageTexture:
	if _sole_masks.has(outline):
		return _sole_masks[outline]
	var mask := Image.create_empty(MASK_SIZE.x, MASK_SIZE.y, false, Image.FORMAT_R8)
	for y in MASK_SIZE.y:
		for x in MASK_SIZE.x:
			var point := (Vector2(x, y) + Vector2(0.5, 0.5)) * 2.0 / Vector2(MASK_SIZE) - Vector2.ONE
			if Geometry2D.is_point_in_polygon(point, outline):
				mask.set_pixel(x, y, Color.WHITE)
	mask.generate_mipmaps()
	var mask_texture := ImageTexture.create_from_image(mask)
	if _sole_masks.size() >= MASK_CACHE_CAPACITY:
		_sole_masks.erase(_sole_masks.keys()[0])
	_sole_masks[outline] = mask_texture
	return mask_texture


func _footfall_dust(center: Vector3, yaw: float, half_extents: Vector2, height: float) -> void:
	if _dust_material == null:
		_create_dust_material()
	var burst := Node3D.new()
	burst.name = "FootfallDust"
	add_child(burst)
	burst.global_position = center
	burst.global_rotation.y = yaw
	var tween := burst.create_tween().set_parallel().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	var size := clampf(height * 0.046, 0.08, 9.0)
	for i in 6:
		var angle := float(i) * TAU / 6.0 + _rng.randf_range(-0.25, 0.25)
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		var puff := MeshInstance3D.new()
		puff.mesh = _dust_quad
		puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		puff.material_override = _dust_material.duplicate()
		puff.scale = Vector3(size, size * _rng.randf_range(0.38, 0.58), 1.0)
		puff.position = Vector3(direction.x * half_extents.x * 0.78, size * 0.17,
				direction.z * half_extents.y * 0.78)
		burst.add_child(puff)
		var end := puff.position + direction * size * _rng.randf_range(1.20, 2.20) + Vector3.UP * size * 0.5
		var lifetime := _rng.randf_range(0.57, 0.86)
		tween.tween_property(puff, "position", end, lifetime).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.tween_property(puff, "scale", puff.scale * 2.6, lifetime)
		tween.tween_property(puff.material_override, "albedo_color:a", 0.0, lifetime).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(burst.queue_free)


func _create_dust_material() -> void:
	var texture_size := 48
	var cloud := Image.create_empty(texture_size, texture_size, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.12
	for y in texture_size:
		for x in texture_size:
			var point := Vector2(x, y) / float(texture_size - 1) * 2.0 - Vector2.ONE
			var breakup := 0.72 + noise.get_noise_2d(x, y) * 0.6
			var opacity := (1.0 - smoothstep(0.05, 1.0, point.length())) * breakup
			cloud.set_pixel(x, y, Color(1.0, 1.0, 1.0, opacity))
	cloud.generate_mipmaps()
	_dust_quad = QuadMesh.new()
	_dust_material = StandardMaterial3D.new()
	_dust_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_dust_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_dust_material.billboard_keep_scale = true
	_dust_material.albedo_color = Color(DUST, 0.63)
	_dust_material.albedo_texture = ImageTexture.create_from_image(cloud)
	_dust_material.roughness = 1.0


func show_exit(center: Vector3, radius: float) -> void:
	var beacon := Node3D.new()
	beacon.name = "EvacuationBeacon"
	beacon.position = center
	add_child(beacon)
	_ring(beacon, radius, minf(0.12, radius * 0.2), Color(TEAL, 0.88))
	_disc(beacon, radius, 0.12, Color(TEAL, 0.12))
	var light := CylinderMesh.new()
	light.top_radius = 0.12
	light.bottom_radius = 0.50
	light.height = 9.0
	light.radial_segments = 16
	_mesh(beacon, light, Vector3(0, 4.5, 0), Color(TEAL, 0.38))
	var signpost := Label3D.new()
	signpost.text = "撤离点"
	signpost.font_size = 68
	signpost.outline_size = 18
	signpost.pixel_size = 0.024
	signpost.position.y = 5.0
	signpost.modulate = TEAL
	signpost.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	beacon.add_child(signpost)


## Yellow landing ring for the sit-crush: the giant's back is about to come down here.
func sit_warn(center: Vector3, radius: float, giant_index: int) -> void:
	var warning: Node3D = _sit_warnings.get(giant_index)
	if warning == null:
		warning = Node3D.new()
		warning.name = "SitWarning" if giant_index == 0 else "SitWarning%d" % (giant_index + 1)
		add_child(warning)
		_ring(warning, radius, maxf(0.10, radius * 0.025), Color(AMBER, 0.95))
		_disc(warning, radius, 0.05, Color(AMBER, 0.18))
		var sweep := _ring(warning, radius * 0.97, maxf(0.06, radius * 0.012), Color("#ffe0a3"))
		var tween := sweep.create_tween().set_loops()
		tween.tween_property(sweep, "scale", Vector3.ONE, 0.75).from(Vector3(0.3, 1.0, 0.3))
		warning.set_meta(&"sweep", sweep)
		_sit_warnings[giant_index] = warning
	warning.position = Vector3(center.x, 0.02, center.z)


func sit_warn_end(giant_index: int) -> void:
	if _sit_warnings.has(giant_index):
		var warning: Node3D = _sit_warnings[giant_index]
		remove_child(warning)
		warning.queue_free()
		_sit_warnings.erase(giant_index)


func impact(center: Vector3, yaw: float, radii: Vector2, shattered: bool, heavy: bool, height_scale := 1.0) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera:
		var offset := camera.global_position - center
		var reach := IMPACT_DRAW_DISTANCE + maxf(radii.x, radii.y)
		if Vector2(offset.x, offset.z).length_squared() > reach * reach:
			return
	var burst := Node3D.new()
	burst.position = center
	burst.rotation.y = yaw
	burst.scale = Vector3(radii.x, height_scale, radii.y)
	add_child(burst)
	var wave := _ring(burst, 0.5, 0.09, Color(Color("#ffe0a3"), 1.0 if heavy else 0.6))
	var wave_material: StandardMaterial3D = wave.material_override
	var tween := burst.create_tween().set_parallel()
	tween.tween_property(wave, "scale", Vector3(3.0, 0.5, 3.0), 0.38)
	tween.tween_property(wave_material, "albedo_color:a", 0.0, 0.40)
	var rng := RandomNumberGenerator.new()
	var dust_mesh := SphereMesh.new()
	dust_mesh.radial_segments = 7
	dust_mesh.rings = 3
	var puff_count := 9 if heavy else 4
	if shattered:
		puff_count += 6
	for i in puff_count:
		var angle := rng.randf_range(0.0, TAU)
		var direction := Vector3(cos(angle), 0, sin(angle))
		var puff := _mesh(burst, dust_mesh, direction * rng.randf_range(0.08, 0.55), Color(DUST, 0.56))
		puff.scale = Vector3.ONE * rng.randf_range(0.35, 0.65)
		tween.tween_property(puff, "position", puff.position + direction * rng.randf_range(0.6, 1.25)
				+ Vector3.UP * rng.randf_range(0.7, 1.8), 0.75).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(puff, "scale", puff.scale * 2.7, 0.75)
		tween.tween_property(puff.material_override, "albedo_color:a", 0.0, 0.75)
	if shattered:
		var chip_mesh := BoxMesh.new()
		chip_mesh.size = Vector3(0.34, 0.26, 0.42)
		for i in 7:
			var angle := rng.randf_range(0.0, TAU)
			var direction := Vector3(cos(angle), 0, sin(angle))
			var chip := _mesh(burst, chip_mesh, direction * 0.4, Color("#857564"))
			var apogee := chip.position + direction * 0.7 + Vector3.UP * rng.randf_range(0.5, 2.2)
			tween.tween_property(chip, "position", apogee, 0.3).set_ease(Tween.EASE_OUT)
			tween.tween_property(chip, "position", direction * 1.6, 0.35).from(apogee).set_delay(0.30)
			tween.tween_property(chip, "rotation", Vector3(3.0, angle, 2.1), 0.64)
	tween.chain().tween_callback(burst.queue_free)


func _ring(at: Node3D, radius: float, thickness: float, color: Color) -> MeshInstance3D:
	var ring := TorusMesh.new()
	ring.inner_radius = radius - thickness
	ring.outer_radius = radius
	ring.rings = 64
	ring.ring_segments = 8
	return _mesh(at, ring, Vector3(0, 0.023, 0), color)


func _disc(at: Node3D, radius: float, elevation: float, color: Color) -> void:
	var disc := CylinderMesh.new()
	disc.top_radius = radius
	disc.bottom_radius = radius
	disc.height = 0.015
	disc.radial_segments = 64
	_mesh(at, disc, Vector3.UP * elevation, color)


func _mesh(at: Node3D, mesh: Mesh, position: Vector3, color: Color) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.position = position
	at.add_child(instance)
	return instance
