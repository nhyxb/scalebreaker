extends Node3D

const SPIN_RATE := TAU / 1.8
const DEFAULT_DRAW_DISTANCE := 300.0
const DRAW_MARGIN := 24.0
const CULL_INTERVAL := 0.18
const EXPIRY_WARNING_SECONDS := 4.0

# Risk-tier visual language (index matches CoinTier on the Rust side):
#   0 normal  — the classic gold coin.
#   1 high    — bigger bright-gold coin with a subtle ground micro-ring (2.5×).
#   2 extreme — red-gold coin with a pulsing violet halo ring (5×).
const TIER_COLORS := [
	Color("#ffe18a"),
	Color("#ffd24a"),
	Color("#ff9d3c"),
]
const TIER_HALO_COLORS := [
	Color(0.0, 0.0, 0.0, 0.0),
	Color("#ffd24a"),
	Color("#c46bff"),
]
const TIER_SCALE := [1.0, 1.45, 1.9]
const TIER_EMISSION := [0.35, 0.85, 1.6]
const EXTREME_PULSE_SPEED := 4.2

var _meshes: Array[ArrayMesh] = []
var _visible_tokens: Array[Node3D] = []
var _halos: Array[MeshInstance3D] = []
var _cull_in := 0.0
var _pulse := 0.0
var _dwell_ring: MeshInstance3D
var _dwell_material: ShaderMaterial
var _dwell_shown := false


func spawn_coin(at: Vector3, radius: float, tier: int = 0) -> Node3D:
	_build_meshes()
	var coin := Node3D.new()
	coin.position = at
	add_child(coin)
	_dress_coin(coin, radius, tier)
	_cull_in = 0.0
	return coin


func set_coin_tier(coin: Node3D, tier: int) -> void:
	if not is_instance_valid(coin) or coin.get_child_count() == 0:
		return
	# The token carries the spawn radius it was dressed with.
	var token := coin.get_child(0) as MeshInstance3D
	if token == null:
		return
	var radius: float = token.get_meta(&"spawn_radius", 0.45)
	for child in coin.get_children():
		coin.remove_child(child)
		child.queue_free()
	_dress_coin(coin, radius, tier)
	_cull_in = 0.0


func set_coin_expiry(coin: Node3D, remaining: float) -> void:
	coin.set_meta(&"expiry_remaining", remaining)


func show_dwell(at: Vector3, progress: float, tier: int) -> void:
	if _dwell_ring == null:
		_build_dwell_ring()
	_dwell_ring.visible = true
	_dwell_shown = true
	_dwell_ring.position = Vector3(at.x, at.y + 0.035, at.z)
	var span := 1.3 + 0.55 * float(tier)
	_dwell_ring.scale = Vector3.ONE * span
	_dwell_material.set_shader_parameter(&"progress", clampf(progress, 0.0, 1.0))
	_dwell_material.set_shader_parameter(
		&"ring_color", TIER_HALO_COLORS[clampi(tier, 0, 2)])


func hide_dwell() -> void:
	if _dwell_ring != null and _dwell_shown:
		_dwell_ring.visible = false
		_dwell_shown = false


func _process(delta: float) -> void:
	var count := get_child_count()
	if count == 0:
		_visible_tokens.clear()
		_halos.clear()
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
		var coin := token.get_parent_node_3d()
		if coin != null and coin.has_meta(&"expiry_remaining"):
			var elapsed := EXPIRY_WARNING_SECONDS - float(coin.get_meta(&"expiry_remaining"))
			# Integrate a steadily rising frequency, from 1 to 4 flashes per second.
			var lit := fposmod(elapsed * (1.0 + 0.375 * elapsed), 1.0) < 0.65
			token.visible = lit
			if coin.get_child_count() > 1:
				(coin.get_child(1) as Node3D).visible = lit
	_pulse += delta * EXTREME_PULSE_SPEED
	var breathe := 0.5 + 0.5 * sin(_pulse)
	for halo in _halos:
		if is_instance_valid(halo):
			halo.scale = halo.get_meta(&"base_scale", Vector3.ONE) * (1.0 + 0.16 * breathe)
			(halo.material_override as ShaderMaterial).set_shader_parameter(
				&"energy", 0.55 + 0.45 * breathe)


func _refresh_visible(count: int) -> void:
	_cull_in = CULL_INTERVAL
	_visible_tokens.clear()
	_halos.clear()
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
		# The dwell ring helper also lives under this node; real coins always
		# carry a spinning token child, so skip anything without one.
		if coin.get_child_count() == 0:
			continue
		if cull:
			var dx := coin.position.x - cam_x
			var dz := coin.position.z - cam_z
			var active := dx * dx + dz * dz <= limit_sq
			if coin.visible != active:
				coin.visible = active
			if not active:
				continue
		_visible_tokens.append(coin.get_child(0) as Node3D)
		if coin.get_child_count() > 1:
			_halos.append(coin.get_child(1) as MeshInstance3D)


func _dress_coin(coin: Node3D, radius: float, tier: int) -> void:
	tier = clampi(tier, 0, 2)
	var token := MeshInstance3D.new()
	token.mesh = _meshes[tier]
	token.position.y = radius * 1.12 * TIER_SCALE[tier]
	token.scale = Vector3.ONE * radius * TIER_SCALE[tier]
	token.rotation.y = randf() * TAU
	token.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	token.set_meta(&"spawn_radius", radius)
	coin.add_child(token)
	if tier == 1:
		# High-risk: a quiet bright-gold ground ring under the coin.
		var ring := _make_ring(TIER_HALO_COLORS[1], 1.35 * radius, 0.05, 0.42)
		ring.position.y = 0.03
		coin.add_child(ring)
	elif tier == 2:
		# Extreme: a pulsing red-violet halo ring on the ground.
		var halo := _make_ring(TIER_HALO_COLORS[2], 1.6 * radius, 0.09, 0.62)
		halo.position.y = 0.03
		coin.add_child(halo)


func _make_ring(color: Color, radius: float, thickness: float, opacity: float) -> MeshInstance3D:
	var material := ShaderMaterial.new()
	material.shader = _ring_shader()
	material.set_shader_parameter(&"progress", 1.0)
	material.set_shader_parameter(&"thickness", thickness)
	material.set_shader_parameter(&"energy", 1.0)
	material.set_shader_parameter(&"ring_color", color)
	material.set_shader_parameter(&"ambient", opacity)
	var mesh := MeshInstance3D.new()
	mesh.mesh = _ring_mesh()
	mesh.material_override = material
	mesh.scale = Vector3.ONE * radius * 2.0
	mesh.set_meta(&"base_scale", mesh.scale)
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mesh


func _ring_mesh() -> PlaneMesh:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2.ONE
	mesh.orientation = PlaneMesh.FACE_Y
	return mesh


func _ring_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
	shader_type spatial;
	render_mode blend_add, depth_draw_never, cull_disabled, unshaded;
	uniform float progress : hint_range(0.0, 1.0) = 1.0;
	uniform float thickness : hint_range(0.01, 0.4) = 0.1;
	uniform float energy : hint_range(0.0, 2.0) = 1.0;
	uniform vec4 ring_color : source_color = vec4(1.0);
	uniform float ambient : hint_range(0.0, 1.0) = 0.5;
	void fragment() {
		vec2 point = UV - vec2(0.5);
		float r = length(point) * 2.0;
		float band = 1.0 - smoothstep(thickness * 0.55, thickness, abs(r - 0.78));
		float a = atan(point.y, point.x);
		float done = step(a + PI, progress * TAU);
		float glow = band * (ambient + (1.0 - ambient) * done * energy);
		ALBEDO = ring_color.rgb * glow;
		EMISSION = ring_color.rgb * glow * 0.85;
		ALPHA = glow;
	}
	"""
	return shader


func _build_dwell_ring() -> void:
	_dwell_material = ShaderMaterial.new()
	_dwell_material.shader = _ring_shader()
	_dwell_material.set_shader_parameter(&"thickness", 0.10)
	_dwell_material.set_shader_parameter(&"energy", 1.0)
	_dwell_material.set_shader_parameter(&"ambient", 0.30)
	_dwell_ring = MeshInstance3D.new()
	_dwell_ring.mesh = _ring_mesh()
	_dwell_ring.material_override = _dwell_material
	_dwell_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dwell_ring.visible = false
	add_child(_dwell_ring)


func _build_meshes() -> void:
	if not _meshes.is_empty():
		return
	for tier in 3:
		_meshes.append(_build_coin_mesh(tier))


func _build_coin_mesh(tier: int) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var flip := Basis(Vector3.RIGHT, PI * 0.5)
	var color: Color = TIER_COLORS[tier]
	for spec: Array in [
		[1.0, 0.24, color, 0.71],
		[0.74, 0.29, color.darkened(0.18), 0.45],
	]:
		var cylinder := _coin_cylinder(spec[0], spec[1], spec[2], spec[3], TIER_EMISSION[tier])
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


func _coin_cylinder(radius: float, thickness: float, color: Color, metallic: float,
		emission: float) -> CylinderMesh:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = 0.34
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = emission
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = thickness
	mesh.radial_segments = 20
	mesh.rings = 0
	mesh.material = material
	return mesh
