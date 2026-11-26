extends "res://scenes/human_visual.gd"

const HEIGHT := 0.01
const MODEL_HEIGHT := 1.8
const WALK_SPEED := 0.082
const CLIMB_SPEED := 0.055
const GRAVITY := 1.2
const REACH := 0.009
const SNAP := 0.0008
const CLIMB_CLIP := &"bedroom/climb"
const MOUSE_LOOK_SENSITIVITY := 0.003
const KEYBOARD_LOOK_SPEED := PI * 0.5

@onready var _model: Node3D = $Model
@onready var _orbit: Node3D = $Orbit
@onready var _arm: SpringArm3D = $Orbit/SpringArm3D
@onready var _camera: Camera3D = $Orbit/SpringArm3D/Camera3D

var _spawn: Vector3
var _facing := Vector3.FORWARD
var _climb_normal := Vector3.ZERO
var _touch_axes := Vector2.ZERO
var _touch_climb := false


func _ready() -> void:
	super._ready()
	_spawn = global_position
	var collision: CollisionShape3D = $Collision
	var capsule := CapsuleShape3D.new()
	capsule.height = HEIGHT
	capsule.radius = HEIGHT * 0.25
	collision.shape = capsule
	collision.position.y = HEIGHT * 0.5
	_model.scale = Vector3.ONE * (HEIGHT / MODEL_HEIGHT)
	_face(-_orbit.global_basis.z)
	_arm.add_excluded_object(get_rid())
	_build_climb_animation()
	_camera.make_current()


func look(relative: Vector2) -> void:
	_rotate_view(relative * MOUSE_LOOK_SENSITIVITY)


func _rotate_view(angles: Vector2) -> void:
	_orbit.rotation.y -= angles.x
	_arm.rotation.x = clampf(_arm.rotation.x - angles.y, -1.22, 0.62)


func set_touch_motion(axes: Vector2, climbing: bool) -> void:
	_touch_axes = axes
	_touch_climb = climbing


func clear_touch() -> void:
	set_touch_motion(Vector2.ZERO, false)


func _physics_process(delta: float) -> void:
	var view_axes := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	if view_axes != Vector2.ZERO:
		_rotate_view(view_axes * (KEYBOARD_LOOK_SPEED * delta))
	var keys := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var axes := (keys + _touch_axes).limit_length()
	var forward := -_orbit.global_basis.z
	var direction := _orbit.global_basis.x * axes.x - forward * axes.y
	if (Input.is_action_pressed("climb") or _touch_climb) and _try_climb(direction):
		return

	_climb_normal = Vector3.ZERO
	if direction.length_squared() > 0.01:
		_face(direction)
	velocity.x = direction.x * WALK_SPEED
	velocity.z = direction.z * WALK_SPEED
	velocity.y = -GRAVITY * delta if is_on_floor() else maxf(velocity.y - GRAVITY * delta, -0.85)
	move_and_slide()
	if global_position.y < -0.2 or absf(global_position.x) > 2.75 or absf(global_position.z) > 2.45:
		global_position = _spawn
		velocity = Vector3.ZERO
	var travel := get_real_velocity()
	if show_motion(Vector2(travel.x, travel.z).length() * 5.8 / WALK_SPEED, false):
		var audio := get_node_or_null("/root/HarborAudio")
		if audio != null:
			audio.call("play_bedroom_step")


func _try_climb(direction: Vector3) -> bool:
	var into_wall := -_climb_normal if _climb_normal != Vector3.ZERO else _facing
	if _climb_normal == Vector3.ZERO and direction.length_squared() > 0.01:
		into_wall = direction.normalized()
	var hit := _wall_at(into_wall, HEIGHT * 0.62)
	if hit.is_empty() and _climb_normal != Vector3.ZERO:
		if _try_mantle():
			_climb_normal = Vector3.ZERO
			velocity = Vector3.ZERO
			show_motion(0.0, false)
			var audio := get_node_or_null("/root/HarborAudio")
			if audio != null:
				audio.call("play_bedroom_mantle")
			return true
		hit = _wall_at(into_wall, HEIGHT * 0.22)
	if hit.is_empty():
		return false

	_climb_normal = hit.normal
	_face(into_wall)
	var sideways := direction.slide(_climb_normal)
	sideways.y = 0.0
	velocity = Vector3.UP * CLIMB_SPEED - _climb_normal * 0.018 + sideways * 0.035
	move_and_slide()
	var climb_rate := get_real_velocity().y
	if climb_rate < CLIMB_SPEED * 0.25 and _step_around_trim():
		climb_rate = CLIMB_SPEED
		var trim_audio := get_node_or_null("/root/HarborAudio")
		if trim_audio != null:
			trim_audio.call("play_bedroom_mantle")
	elif climb_rate > CLIMB_SPEED * 0.20:
		var climb_audio := get_node_or_null("/root/HarborAudio")
		if climb_audio != null:
			climb_audio.call("play_bedroom_climb")
	if _animation.current_animation != CLIMB_CLIP:
		_animation.play(CLIMB_CLIP, 0.10)
	_animation.speed_scale = clampf(climb_rate / CLIMB_SPEED, 0.0, 1.0)
	return true


func _wall_at(direction: Vector3, height: float) -> Dictionary:
	var from := global_position + Vector3.UP * height
	var hit := _ray(from, from + direction * REACH)
	if hit.is_empty() or absf(hit.normal.y) > 0.58:
		return {}
	return hit


func _try_mantle() -> bool:
	var inward := -_climb_normal
	inward.y = 0.0
	var step := inward.normalized() * (HEIGHT * 0.92)
	var ahead := global_position + step
	var ledge := _ray(ahead + Vector3.UP * HEIGHT, ahead + Vector3.UP * (HEIGHT * 0.05))
	if ledge.is_empty() or ledge.normal.y < 0.7:
		return false

	var rise: Vector3 = Vector3.UP * (ledge.position.y - global_position.y + SNAP)
	return _move_in_two_steps(rise, step)


func _step_around_trim() -> bool:
	var outward := Vector3(_climb_normal.x, 0.0, _climb_normal.z).normalized()
	var from := global_position + Vector3.UP * (HEIGHT * 1.75) + outward * (HEIGHT * 2.0)
	var front := _ray(from, from - outward * (HEIGHT * 3.0))
	if front.is_empty() or outward.dot(front.normal) < 0.6:
		return false
	var offset: Vector3 = front.position - global_position
	var clearance := offset.dot(outward) + HEIGHT * 0.25 + SNAP
	if clearance < safe_margin or clearance > HEIGHT * 1.6:
		return false
	return _move_in_two_steps(outward * clearance, Vector3.UP * (HEIGHT * 0.95))


func _move_in_two_steps(first: Vector3, second: Vector3) -> bool:
	if test_move(global_transform, first, null, safe_margin):
		return false
	var next := global_transform
	next.origin += first
	if test_move(next, second, null, safe_margin):
		return false
	global_position += first + second
	return true


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, collision_mask, [get_rid()])
	return get_world_3d().direct_space_state.intersect_ray(query)


func _face(direction: Vector3) -> void:
	_facing = direction.normalized()
	_model.rotation.y = atan2(_facing.x, _facing.z)


func _build_climb_animation() -> void:
	var skeleton := _model.find_child("Skeleton3D", true, false) as Skeleton3D
	var path := str(_model.get_path_to(skeleton))
	var clip := Animation.new()
	clip.length = 0.70
	clip.loop_mode = Animation.LOOP_LINEAR
	for side in ["left", "right"]:
		var sign := 1.0 if side == "left" else -1.0
		var reach := Quaternion(Vector3.RIGHT, 0.58) * Quaternion(Vector3.BACK, sign * 1.55)
		var pull := Quaternion(Vector3.RIGHT, 1.82) * Quaternion(Vector3.BACK, sign * 1.35)
		var tuck := Quaternion(Vector3.RIGHT, -0.72)
		var extend := Quaternion(Vector3.RIGHT, 0.10)
		_climb_track(clip, NodePath("%s:arm-%s" % [path, side]), reach, pull, side == "right")
		_climb_track(clip, NodePath("%s:leg-%s" % [path, side]), extend, tuck, side == "right")
	var library := AnimationLibrary.new()
	library.add_animation(&"climb", clip)
	_animation.add_animation_library(&"bedroom", library)


func _climb_track(clip: Animation, path: NodePath, first: Quaternion, second: Quaternion,
		reverse: bool) -> void:
	var track := clip.add_track(Animation.TYPE_ROTATION_3D)
	clip.track_set_path(track, path)
	var begin := second if reverse else first
	var middle := first if reverse else second
	clip.rotation_track_insert_key(track, 0.0, begin)
	clip.rotation_track_insert_key(track, clip.length * 0.5, middle)
	clip.rotation_track_insert_key(track, clip.length, begin)
