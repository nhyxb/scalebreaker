extends Node3D

const TEAL := Color("#69fbd6")
const AMBER := Color("#ffa64c")
const DUST := Color("#c7a47d")
const IMPACT_DRAW_DISTANCE := 175.0

var _warnings: Dictionary[int, Node3D] = {}
var _sit_warnings: Dictionary[int, Node3D] = {}


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


func warn(center: Vector3, yaw: float, radii: Vector2, seconds: float, giant_index: int, height_scale := 1.0) -> void:
	cancel_warning(giant_index)
	var warning := Node3D.new()
	warning.name = "StompWarning" if giant_index == 0 else "StompWarning%d" % (giant_index + 1)
	warning.position = center
	warning.rotation.y = yaw
	warning.scale = Vector3(radii.x, height_scale, radii.y)
	add_child(warning)
	_warnings[giant_index] = warning
	_ring(warning, 1.0, 0.09, Color(AMBER, 0.98))
	_disc(warning, 1.0, 0.05, Color(AMBER, 0.24))
	var sweep := _ring(warning, 1.0, 0.055, Color("#ffe0a3"))
	sweep.scale = Vector3(0.12, 1, 0.12)
	var tween := sweep.create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	tween.tween_property(sweep, "scale", Vector3.ONE, seconds).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	var audio := get_node_or_null("/root/HarborAudio")
	if audio != null:
		var est_height := maxf(radii.y / 1.49 * 25.2, 0.5)
		audio.call("play_stomp_warn", center, est_height)


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


func cancel_warning(giant_index: int) -> void:
	if _warnings.has(giant_index):
		var warning: Node3D = _warnings[giant_index]
		remove_child(warning)
		warning.queue_free()
		_warnings.erase(giant_index)


func impact(center: Vector3, yaw: float, radii: Vector2, shattered: bool, stomp: bool, height_scale := 1.0) -> void:
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
	var wave := _ring(burst, 0.5, 0.09, Color(Color("#ffe0a3"), 1.0 if stomp else 0.6))
	var wave_material: StandardMaterial3D = wave.material_override
	var tween := burst.create_tween().set_parallel()
	tween.tween_property(wave, "scale", Vector3(3.0, 0.5, 3.0), 0.38)
	tween.tween_property(wave_material, "albedo_color:a", 0.0, 0.40)
	var rng := RandomNumberGenerator.new()
	var dust_mesh := SphereMesh.new()
	dust_mesh.radial_segments = 7
	dust_mesh.rings = 3
	var puff_count := 9 if stomp else 4
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
