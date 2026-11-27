extends RefCounted
## Shared driver for exercising actual gait contacts through the round's movement input.

const WALK := Vector2(0.0, -1.0)
const BASE_HEIGHT := 25.2


static func actor(round_node: Node, index := 0) -> Dictionary:
	var actors: Array = round_node.growth_actors()
	return actors[index] if index < actors.size() else {}


static func face(round_node: Node, body: CharacterBody3D, yaw: float) -> void:
	round_node.set_camera_view(0)
	body.rotation = Vector3(0.0, yaw, 0.0)
	var orbit := round_node.get_node("Orbit") as Node3D
	round_node.look(Vector2(-angle_difference(orbit.rotation.y, yaw) / 0.0028, 0.0))


static func land(round_node: Node, place_target := Callable(), limit := 180) -> Dictionary:
	var tree := round_node.get_tree()
	var giant := round_node.get_node("Giant")
	var before := int(actor(round_node).get("footfall_count", 0))
	round_node.set_touch_motion(WALK, false)
	for _frame in limit:
		await tree.physics_frame
		var gait := actor(round_node)
		if int(gait.get("footfall_count", 0)) > before:
			round_node.set_touch_motion(Vector2.ZERO, false)
			return gait
		var preview: Dictionary = giant.heavy_step_preview()
		if preview.get("locked", false) and gait.get("footfall_pending", false):
			if place_target.is_valid():
				place_target.call(gait)
			# Finish this swing after releasing input so a standing shoe cannot hit twice.
			round_node.set_touch_motion(Vector2.ZERO, false)
	round_node.set_touch_motion(Vector2.ZERO, false)
	return {}


static func strike_building(round_node: Node, building: Node3D, yaw := NAN,
		height := -1.0, gap_in_scales := 3.8, lateral_in_scales := 0.0) -> Dictionary:
	var body := round_node.get_node("Giant") as CharacterBody3D
	var tree := round_node.get_tree()
	if height < 0.0:
		height = float(round_node.snapshot().giant_height)
	if is_nan(yaw):
		# The closely stacked central lots have different approaches at small scale.
		yaw = 0.0 if height < 5.0 else PI
	var scale := height / BASE_HEIGHT
	var approach := Vector3.BACK.rotated(Vector3.UP, yaw)
	var direction := building.global_basis.inverse() * approach
	var footprint: Vector3 = building.footprint
	var edge := minf(
		footprint.x * 0.5 / maxf(absf(direction.x), 0.0001),
		footprint.z * 0.5 / maxf(absf(direction.z), 0.0001)
	)
	# Reinitialize the swing before a test teleport onto the same approach.
	# At human scale this position change can be below the usual teleport threshold.
	body.rotation.y = fposmod(yaw + PI, TAU)
	await tree.physics_frame
	face(round_node, body, yaw)
	var lateral := Vector3.RIGHT.rotated(Vector3.UP, yaw) * lateral_in_scales * scale
	body.global_position = building.global_position + approach * (edge + gap_in_scales * scale) + lateral + Vector3.UP * 0.02
	body.velocity = Vector3.ZERO
	for _frame in 6:
		await tree.physics_frame
	return await land(round_node, Callable(), maxi(180, ceili(48.0 * scale)))


static func place_under(body: CharacterBody3D, gait: Dictionary, offset := Vector3.ZERO) -> void:
	var center: Vector3 = gait.footfall_center
	body.global_position = center + offset.rotated(Vector3.UP, float(gait.footfall_yaw)) + Vector3.UP * 0.01
	body.velocity = Vector3.ZERO
