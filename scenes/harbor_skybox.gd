extends Node3D
## Desktop-sandbox 3D skybox: a 1:1 bedroom (scenes/skybox_bedroom.gd) rendered in its own
## SubViewport world and composited behind the harbour as the viewport's canvas background
## (Atmosphere uses Environment.BG_CANVAS). The bedroom camera copies the active gameplay
## camera's pose at 1:6667 (1 m -> 0.15 mm), so the 1,418 m port reads as the ~21.27 cm
## sandbox sitting in the middle of the bedroom desk — fog and harbour lights stay confined
## to the main scene, so the sea fog can never wash over the bedroom and the bedroom lights
## can never overexpose the port.

const BedroomShell := preload("res://scenes/skybox_bedroom.gd")
const SKY_SCALE := BedroomShell.SKY_SCALE
const CANVAS_LAYER := -64
## Bedroom resolution relative to the window; the backdrop is soft, so a reduced buffer
## keeps the second viewport cheap on integrated GPUs.
const RES_RATIO := 0.4
const MIN_SIZE := Vector2i(640, 360)

var _sub: SubViewport
var _sky_cam: Camera3D
var _layer: CanvasLayer
var _rect: TextureRect
var _anchor: Node3D
var _half_flip := false


func _ready() -> void:
	_sub = SubViewport.new()
	_sub.name = "BedroomViewport"
	_sub.own_world_3d = true
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub.audio_listener_enable_3d = false
	add_child(_sub)
	var shell: Node3D = BedroomShell.new()
	shell.name = "Bedroom"
	_sub.add_child(shell)
	_anchor = shell.sandbox_anchor
	_sky_cam = Camera3D.new()
	_sky_cam.name = "BedroomCamera"
	_sky_cam.near = 0.01
	_sky_cam.far = 40.0
	_sub.add_child(_sky_cam)
	_layer = CanvasLayer.new()
	_layer.name = "BedroomBackdrop"
	_layer.layer = CANVAS_LAYER
	add_child(_layer)
	_rect = TextureRect.new()
	_rect.name = "BedroomPicture"
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.texture = _sub.get_texture()
	_layer.add_child(_rect)
	_resize(get_viewport().size)
	get_viewport().size_changed.connect(_on_size_changed)


func _on_size_changed() -> void:
	_resize(get_viewport().size)


func _resize(window_size: Vector2) -> void:
	var ratio := Vector2i(maxi(MIN_SIZE.x, roundi(window_size.x * RES_RATIO)),
			maxi(MIN_SIZE.y, roundi(window_size.y * RES_RATIO)))
	_sub.size = ratio


func _process(_delta: float) -> void:
	# The whole pose sync: anchor at the sandbox centre, harbour origin at (0,0,0), camera
	# offset scaled by 1/6667 into the bedroom frame, rotation carried over untouched.
	var view: Viewport = get_viewport()
	var cam := view.get_camera_3d()
	if cam == null or _anchor == null:
		return
	var xf := cam.global_transform
	_sky_cam.global_transform = _anchor.global_transform \
			* Transform3D(xf.basis, xf.origin * SKY_SCALE)
	_sky_cam.fov = cam.fov
	# The backdrop moves imperceptibly at 1:6667, so rendering the bedroom every other
	# frame halves the second viewport's cost on integrated GPUs with no visible loss.
	if _half_flip:
		_sub.render_target_update_mode = SubViewport.UPDATE_ONCE
	_half_flip = not _half_flip
