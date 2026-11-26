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

## Subtle optical depth cue on the 1:6667 backdrop: single-pass micro-softening
## (~0.78 px) + 4–7% day/dusk/night atmospheric haze separates the multi-kilometre
## bedroom/Yumeka from crisp foreground skyscrapers without softening eye detail.
const BACKDROP_BLUR_RADIUS_PX := 0.78

var bedroom: Node3D
var ultra_giant_anchor: Node3D
var _sub: SubViewport
var _sky_cam: Camera3D
var _layer: CanvasLayer
var _rect: TextureRect
var _backdrop_mat: ShaderMaterial
var _anchor: Node3D
var _last_vp_size := Vector2i.ZERO
## Change-driven refresh state: the backdrop re-renders only on frames the main camera's
## pose/fov/frustum actually moved, so fast rotation shows zero frame lag while static
## frames skip the second viewport entirely.
var _pose_dirty := true
var _last_cam_xf := Transform3D()
var _last_cam_fov := -1.0
var _last_cam_keep_aspect := -1
var _last_cam_offset := Vector2(NAN, NAN)


func _ready() -> void:
	# Run after HarbourRound settles the gameplay camera this frame (higher priority runs
	# later), so the bedroom copy always uses the final pose — no 1–2 frame rotation lag.
	process_priority = 100
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
	# EXPAND_IGNORE_SIZE + STRETCH_SCALE: the old default EXPAND_KEEP_SIZE let the viewport
	# texture drive the control's minimum size, so a 0.85-ratio 1632x918 texture at a
	# 1920x1080 window blew the rect up to 1.275x the 1280x720 logical canvas and shifted
	# the optical centre ~14% down-right — floating the sandbox off the desk. With
	# ignore-size the full-rect anchors alone govern: the rect is exactly the visible
	# canvas at every window resolution and RES_RATIO.
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.texture = _sub.get_texture()
	_backdrop_mat = _build_backdrop_shader_material()
	_rect.material = _backdrop_mat
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
	_sky_cam.keep_aspect = cam.keep_aspect
	_sky_cam.h_offset = cam.h_offset * SKY_SCALE
	_sky_cam.v_offset = cam.v_offset * SKY_SCALE
	# Change-driven refresh: render the bedroom the very frame the camera moved so fast
	# rotation shows zero lag, and skip the second viewport entirely while it is static.
	# (The old alternating _half_flip rendered unconditionally on odd frames and lagged.)
	var offset := Vector2(cam.h_offset, cam.v_offset)
	if _pose_dirty or _last_cam_xf != xf or _last_cam_fov != cam.fov \
			or _last_cam_keep_aspect != cam.keep_aspect or _last_cam_offset != offset:
		_sub.render_target_update_mode = SubViewport.UPDATE_ONCE
		_last_cam_xf = xf
		_last_cam_fov = cam.fov
		_last_cam_keep_aspect = cam.keep_aspect
		_last_cam_offset = offset
		_pose_dirty = false


## Queue one immediate backdrop re-render, outside camera-tracking timescales. Needed by
## any future bedroom content the change-driven refresh cannot see (e.g. the phase-3
## seated Yumeka) — call this whenever such content animates.
func mark_dirty() -> void:
	_pose_dirty = true


func is_yumeka_mounted() -> bool:
	if ultra_giant_anchor == null:
		return false
	var y := ultra_giant_anchor.get_node_or_null("Yumeka")
	return y != null and y.has_method(&"debug_is_mounted") and bool(y.call(&"debug_is_mounted"))


func get_backdrop_shader_material() -> ShaderMaterial:
	return _backdrop_mat


## Forward day/dusk/night atmosphere weights to the bedroom world + 2D atmospheric haze
## shader and force a redraw.
func apply_day_night(day_w: float, dusk_w: float, night_w: float, cycle_time: float = 0.0) -> void:
	var sum := maxf(day_w + dusk_w + night_w, 0.0001)
	var d := day_w / sum
	var u := dusk_w / sum
	var n := night_w / sum
	if _backdrop_mat != null:
		var haze_col := Color(0.76, 0.86, 0.96) * d \
				+ Color(0.92, 0.64, 0.48) * u \
				+ Color(0.20, 0.24, 0.38) * n
		var haze_str := 0.058 * d + 0.064 * u + 0.044 * n
		_backdrop_mat.set_shader_parameter(&"haze_color", haze_col)
		_backdrop_mat.set_shader_parameter(&"haze_strength", haze_str)
	if bedroom != null and bedroom.has_method(&"apply_day_night"):
		bedroom.call(&"apply_day_night", day_w, dusk_w, night_w, cycle_time)
	mark_dirty()


func _build_backdrop_shader_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;

uniform float blur_radius_px = 0.78;
uniform vec3 haze_color : source_color = vec3(0.76, 0.86, 0.96);
uniform float haze_strength = 0.058;

void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE * blur_radius_px;
	vec4 c0 = texture(TEXTURE, UV);
	vec4 c1 = texture(TEXTURE, UV + vec2( px.x,  px.y * 0.5));
	vec4 c2 = texture(TEXTURE, UV + vec2(-px.x, -px.y * 0.5));
	vec4 c3 = texture(TEXTURE, UV + vec2(-px.x * 0.5,  px.y));
	vec4 c4 = texture(TEXTURE, UV + vec2( px.x * 0.5, -px.y));
	vec3 col = c0.rgb * 0.44 + (c1.rgb + c2.rgb + c3.rgb + c4.rgb) * 0.14;
	float horizon_boost = mix(0.86, 1.14, smoothstep(0.15, 0.85, UV.y));
	float haze = clamp(haze_strength * horizon_boost, 0.0, 0.12);
	col = mix(col, haze_color, haze);
	COLOR = vec4(col, c0.a);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter(&"blur_radius_px", BACKDROP_BLUR_RADIUS_PX)
	mat.set_shader_parameter(&"haze_color", Color(0.76, 0.86, 0.96))
	mat.set_shader_parameter(&"haze_strength", 0.058)
	return mat
