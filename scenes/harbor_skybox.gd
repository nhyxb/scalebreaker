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
## Bedroom SubViewport resolution relative to the window: crisp on desktop to remove
## stair-stepped window/furniture edges, lighter on mobile GPUs.
const DESKTOP_RES_RATIO := 0.85
const MOBILE_RES_RATIO := 0.55
const DESKTOP_MIN_SIZE := Vector2i(960, 540)
const MOBILE_MIN_SIZE := Vector2i(640, 360)

var bedroom: Node3D
var ultra_giant_anchor: Node3D
var _sub: SubViewport
var _sky_cam: Camera3D
var _layer: CanvasLayer
var _rect: TextureRect
var _anchor: Node3D
var _half_flip := false
var _last_vp_size := Vector2i.ZERO


func _ready() -> void:
	var is_mobile := _is_mobile_platform()
	_sub = SubViewport.new()
	_sub.name = "BedroomViewport"
	_sub.own_world_3d = true
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub.audio_listener_enable_3d = false
	_sub.msaa_3d = Viewport.MSAA_DISABLED if is_mobile else Viewport.MSAA_2X
	# Only the bedroom's single DirectionalLight3D casts shadows; skip omni/spot shadow atlas.
	_sub.positional_shadow_atlas_size = 0
	add_child(_sub)
	bedroom = BedroomShell.new()
	bedroom.name = "Bedroom"
	_sub.add_child(bedroom)
	_anchor = bedroom.sandbox_anchor
	ultra_giant_anchor = bedroom.ultra_giant_anchor
	_sky_cam = Camera3D.new()
	_sky_cam.name = "BedroomCamera"
	_sky_cam.near = 0.005
	_sky_cam.far = 20.0
	_sub.add_child(_sky_cam)
	_layer = CanvasLayer.new()
	_layer.name = "BedroomBackdrop"
	_layer.layer = CANVAS_LAYER
	add_child(_layer)
	_rect = TextureRect.new()
	_rect.name = "BedroomPicture"
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.texture = _sub.get_texture()
	_layer.add_child(_rect)
	_resize(get_viewport().size)
	get_viewport().size_changed.connect(_on_size_changed)


func _is_mobile_platform() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")


func _on_size_changed() -> void:
	_resize(get_viewport().size)


func _resize(window_size: Vector2) -> void:
	var vp := Vector2i(roundi(window_size.x), roundi(window_size.y))
	if vp.x <= 0 or vp.y <= 0:
		return
	_last_vp_size = vp
	var is_mobile := _is_mobile_platform()
	var res_ratio := MOBILE_RES_RATIO if is_mobile else DESKTOP_RES_RATIO
	var min_size := MOBILE_MIN_SIZE if is_mobile else DESKTOP_MIN_SIZE
	# Apply a single uniform scale to both axes so the SubViewport always matches the main
	# viewport's exact aspect ratio (preventing STRETCH_KEEP_ASPECT_COVERED zoom drift).
	var scale := clampf(
		maxf(res_ratio, maxf(float(min_size.x) / float(vp.x), float(min_size.y) / float(vp.y))),
		0.25,
		1.0,
	)
	_sub.size = Vector2i(
		maxi(64, roundi(float(vp.x) * scale)),
		maxi(64, roundi(float(vp.y) * scale)),
	)
	_sub.render_target_update_mode = SubViewport.UPDATE_ONCE


func _process(_delta: float) -> void:
	# The whole pose sync: anchor at the sandbox centre, harbour origin at (0,0,0), camera
	# offset scaled by 1/6667 into the bedroom frame, rotation carried over untouched.
	var view: Viewport = get_viewport()
	var vp_size := Vector2i(view.size)
	if vp_size != _last_vp_size and vp_size.x > 0 and vp_size.y > 0:
		_resize(Vector2(vp_size))
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
