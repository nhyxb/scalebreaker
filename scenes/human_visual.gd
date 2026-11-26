extends CharacterBody3D

@onready var _animation: AnimationPlayer = $Model/AnimationPlayer
var pace := 1.0
@onready var _health_bar: MeshInstance3D = $HealthBar
var _step_segment := -1
var _health_height := 0.0
var _shown_health := 1.0


func _ready() -> void:
	set_process(false)
	for clip in [&"idle", &"walk", &"sprint"]:
		_animation.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	_animation.play(&"idle")


func show_health(height: float, fraction: float, nearby: bool) -> void:
	if _health_bar.visible != nearby:
		_health_bar.visible = nearby
		set_process(nearby)
	if nearby:
		_health_height = height
		if _shown_health != fraction:
			_shown_health = fraction
			(_health_bar.material_override as ShaderMaterial).set_shader_parameter("health", fraction)


func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var anchor := global_position + Vector3.UP * _health_height * 1.08
	var width := maxf(0.001, camera.global_position.distance_to(anchor) * 0.065)
	_health_bar.global_transform = Transform3D(camera.global_basis.scaled(Vector3.ONE * width), anchor)


func show_motion(speed: float, sprinting: bool) -> bool:
	var clip := &"idle"
	if speed > 0.3:
		clip = &"sprint" if sprinting else &"walk"
	if _animation.current_animation != clip:
		_animation.play(clip, 0.15)
		_step_segment = -1
	var reference := (9.5 if sprinting else 5.8) * pace
	_animation.speed_scale = 1.0 if clip == &"idle" else clampf(speed / reference, 0.5, 1.5)
	if clip == &"idle" or not is_on_floor():
		_step_segment = -1
		return false
	# The walk and sprint loops each have two alternating contacts per cycle.
	var phase := fposmod(_animation.current_animation_position / _animation.current_animation_length, 1.0)
	var segment := int(phase * 2.0)
	var footfall := _step_segment >= 0 and segment != _step_segment
	_step_segment = segment
	return footfall


func show_fall() -> void:
	_animation.speed_scale = 1.0
	_animation.play(&"die", 0.1)
	var audio := get_node_or_null("/root/HarborAudio")
	if audio != null:
		audio.call("play_3d", &"human_defeat", global_position, -3.5, 1.0, 8.0, 65.0, 0.06)


func set_render_active(active: bool) -> void:
	visible = active
	_animation.active = active
	_step_segment = -1
