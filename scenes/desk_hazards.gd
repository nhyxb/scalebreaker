extends Node3D
## Reusable tabletop desk-hazard controller & Phase 3B-1 event: `finger_poke`.
##
## Mounted as a direct child of `HarborRound` (`scenes/round.tscn`), inheriting
## `PROCESS_MODE_PAUSABLE` so pausing freezes both timers and descent animation
## automatically, and leaving/restarting a round cleanly resets Yumeka's
## background arm and gaze relay in `_exit_tree()`.
##
## Architectural invariants:
##   - Foreground hazard geometry NEVER registers into Rust's `giants`, `rivals`,
##     or `targets` arrays and carries ZERO `CollisionObject3D` nodes, so players
##     and AI can never target, lock onto, or attack it.
##   - Active warning circles register with `HarborRound.set_hazard_warning()` so
##     Phase 4 Utility AI and civilians immediately flee outside the strike zone.
##   - Missing licensed Yumeka GLB (`assets/characters/yumeka/Yumeka_hand_relay.glb`)
##     gracefully falls back to a clean stylized procedural hand mesh with zero errors.

const CityNightLights := preload("res://scenes/city_night_lights.gd")

const HAND_GLB_PATH := "res://assets/characters/yumeka/Yumeka_hand_relay.glb"
const HAZARD_ID_POKE := 1

## Auto-trigger cadence (seconds) when `desk_hazards` is enabled in Sandbox/Growth/Brawl.
const AUTO_MIN_DELAY := 45.0
const AUTO_MAX_DELAY := 90.0

## Three-phase cadence for `finger_poke` (1:6,667 scale: fingertip width ~96-100 m).
const POKE_WINDUP_SECONDS := 2.4
const POKE_HOLD_SECONDS := 0.5
const POKE_RETRACT_SECONDS := 1.2
const POKE_RADIUS := 110.0
const POKE_DAMAGE_FRACTION := 0.85
const POKE_KNOCKBACK_SPEED := 68.0

## Direction from ground landing spot UP toward Yumeka's right shoulder in the
## south-east bedroom sky (+X east, +Y up, +Z south). Matches export_yumeka_hand_relay.py.
const APPROACH_DIR := Vector3(0.24, 0.94, 0.24)
const WINDUP_START_DIST := 920.0
const RETRACT_END_DIST := 1150.0
const HOLD_PRESS_DEPTH := 3.5

## Unified matte anime shading constants matching Yumeka_seated.glb + AGX anti-blowout.
const MATTE_ROUGHNESS := 0.89
const MATTE_SPECULAR := 0.16
const BODY_TINT := Color(0.90, 0.88, 0.87)
const CLOTHES_TINT := Color(0.86, 0.87, 0.90)

enum HazardKind { NONE, FINGER_POKE }
enum Phase { IDLE, WINDUP, HOLD, RETRACT }

var _rng := RandomNumberGenerator.new()
var _approach_unit := APPROACH_DIR.normalized()
var _hazard: HazardKind = HazardKind.NONE
var _phase: Phase = Phase.IDLE
var _phase_time := 0.0
var _next_auto_in := 60.0
var _target := Vector3.ZERO
var _whoosh_played := false
var _trigger_count := 0
var _last_impact_summary: Dictionary = {}

var _hand_root: Node3D
var _hand_visual: Node3D
var _using_placeholder := false
var _force_placeholder := false

var _warning_root: Node3D
var _shadow_quad: MeshInstance3D
var _shadow_mat: ShaderMaterial
var _warn_quad: MeshInstance3D
var _warn_mat: ShaderMaterial
var _vfx_root: Node3D


func _ready() -> void:
	_rng.randomize()
	_approach_unit = APPROACH_DIR.normalized()
	_next_auto_in = _rng.randf_range(AUTO_MIN_DELAY, AUTO_MAX_DELAY)
	_vfx_root = Node3D.new()
	_vfx_root.name = "HazardVfx"
	add_child(_vfx_root)


func _exit_tree() -> void:
	_clear_rust_warning()
	_sync_background_yumeka(false, Vector3.ZERO, 0.0)


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	var is_f8 := (key.keycode == KEY_F8 or key.physical_keycode == KEY_F8)
	if not (key.pressed and not key.echo and is_f8):
		return
	if key.ctrl_pressed or key.alt_pressed or key.meta_pressed:
		return
	if get_tree().paused or not _is_round_playing() or not _is_enabled():
		return
	if trigger_finger_poke():
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if get_tree().paused:
		return
	var dt := minf(delta, 0.1)
	if not _is_round_playing() or not _is_enabled():
		if _phase != Phase.IDLE:
			_abort_to_idle()
		return

	if _phase == Phase.IDLE:
		_next_auto_in -= dt
		if _next_auto_in <= 0.0:
			trigger_finger_poke()
		return

	match _hazard:
		HazardKind.FINGER_POKE:
			_step_finger_poke(dt)
		_:
			_abort_to_idle()


# --------------------------------------------------------------------------- #
# Public / Reusable Hazard Entry Points
# --------------------------------------------------------------------------- #

## Trigger a single-finger poke immediately (used by auto scheduler, F8 hotkey,
## and tests). Returns false if desk hazards are disabled, round is inactive,
## or a hazard is already running.
func trigger_finger_poke(target_override := Vector3.INF) -> bool:
	if _phase != Phase.IDLE or not _is_enabled() or not _is_round_playing():
		return false
	var chosen := target_override
	if not chosen.is_finite():
		chosen = _pick_target()
	_target = Vector3(chosen.x, 0.0, chosen.z)
	_hazard = HazardKind.FINGER_POKE
	_phase = Phase.WINDUP
	_phase_time = 0.0
	_whoosh_played = false
	_trigger_count += 1
	_last_impact_summary = {}

	_ensure_hand_visual()
	_ensure_warning_visuals()

	_hand_root.visible = true
	_hand_root.global_position = _target + _approach_unit * WINDUP_START_DIST
	_warning_root.visible = true
	_warning_root.global_position = _target
	_shadow_quad.visible = true
	_warn_quad.visible = true
	_update_warning_visuals(0.0, 1.0, true)

	_register_rust_warning(_target, POKE_RADIUS)
	_sync_background_yumeka(true, _target, 0.25)

	var audio := get_node_or_null("/root/HarborAudio")
	if audio != null and audio.has_method(&"play_desk_hazard_warn"):
		audio.call(&"play_desk_hazard_warn", _target)
	return true


# --------------------------------------------------------------------------- #
# Phase Machine: `finger_poke`
# --------------------------------------------------------------------------- #

func _step_finger_poke(dt: float) -> void:
	_phase_time += dt
	match _phase:
		Phase.WINDUP:
			var p := clampf(_phase_time / POKE_WINDUP_SECONDS, 0.0, 1.0)
			# Two-stage descent: looming steady press over the skyline (0..0.72),
			# then weighty acceleration into the city block (0.72..1.0).
			var dist_frac: float
			if p < 0.72:
				var u := p / 0.72
				dist_frac = lerpf(1.0, 0.28, smoothstep(0.0, 1.0, u))
			else:
				var u := (p - 0.72) / 0.28
				dist_frac = lerpf(0.28, 0.0, u * u)
			_hand_root.global_position = _target + _approach_unit * (WINDUP_START_DIST * dist_frac)

			var arm_lift := smoothstep(0.0, 0.45, p)
			_sync_background_yumeka(true, _target, arm_lift)
			_update_warning_visuals(p, 1.0, true)

			if not _whoosh_played and p >= 0.68:
				_whoosh_played = true
				var audio := get_node_or_null("/root/HarborAudio")
				if audio != null and audio.has_method(&"play_desk_hazard_whoosh"):
					audio.call(&"play_desk_hazard_whoosh", _target)

			if _phase_time >= POKE_WINDUP_SECONDS:
				_enter_poke_impact()

		Phase.HOLD:
			var p := clampf(_phase_time / POKE_HOLD_SECONDS, 0.0, 1.0)
			# Fingertip presses slightly into the shattered rubble with a tiny damped settle.
			var settle := sin(p * PI * 2.5) * exp(-p * 5.0) * 1.4
			_hand_root.global_position = _target + Vector3(0.0, -HOLD_PRESS_DEPTH + settle, 0.0)
			_sync_background_yumeka(true, _target, 1.0)
			_update_warning_visuals(1.0, 1.0, false)
			if _phase_time >= POKE_HOLD_SECONDS:
				_phase = Phase.RETRACT
				_phase_time = 0.0

		Phase.RETRACT:
			var p := clampf(_phase_time / POKE_RETRACT_SECONDS, 0.0, 1.0)
			var lift_curve := p * p * (3.0 - 2.0 * p)
			var dist := lerpf(0.0, RETRACT_END_DIST, lift_curve * (0.45 + 0.55 * p))
			var y_offset := lerpf(-HOLD_PRESS_DEPTH, 0.0, clampf(p * 3.5, 0.0, 1.0))
			_hand_root.global_position = _target + Vector3(0.0, y_offset, 0.0) + _approach_unit * dist
			var shadow_fade := 1.0 - smoothstep(0.0, 0.72, p)
			_update_warning_visuals(1.0 - p * 0.6, shadow_fade, false)
			var arm_lift := 1.0 - smoothstep(0.0, 0.85, p)
			_sync_background_yumeka(arm_lift > 0.01, _target, arm_lift)
			if _phase_time >= POKE_RETRACT_SECONDS:
				_finish_hazard()


func _enter_poke_impact() -> void:
	_phase = Phase.HOLD
	_phase_time = 0.0
	_hand_root.global_position = _target + Vector3(0.0, -HOLD_PRESS_DEPTH, 0.0)
	_warn_quad.visible = false
	_update_warning_visuals(1.0, 1.0, false)
	_clear_rust_warning()

	var round := get_parent()
	if round != null and round.has_method(&"apply_desk_hazard_impact"):
		_last_impact_summary = round.call(
			&"apply_desk_hazard_impact",
			_target,
			POKE_RADIUS,
			POKE_DAMAGE_FRACTION,
			POKE_KNOCKBACK_SPEED,
		)

	var audio := get_node_or_null("/root/HarborAudio")
	if audio != null and audio.has_method(&"play_desk_hazard_impact"):
		audio.call(&"play_desk_hazard_impact", _target)
	_spawn_impact_vfx(_target)


func _finish_hazard() -> void:
	_phase = Phase.IDLE
	_hazard = HazardKind.NONE
	_phase_time = 0.0
	_clear_rust_warning()
	if _hand_root != null:
		_hand_root.visible = false
	if _warning_root != null:
		_warning_root.visible = false
	_sync_background_yumeka(false, Vector3.ZERO, 0.0)
	_next_auto_in = _rng.randf_range(AUTO_MIN_DELAY, AUTO_MAX_DELAY)


func _abort_to_idle() -> void:
	_finish_hazard()


# --------------------------------------------------------------------------- #
# Rust Round & Background Skybox Bridges
# --------------------------------------------------------------------------- #

func _is_enabled() -> bool:
	var round := get_parent()
	if round == null or not round.has_method(&"desk_hazards_enabled"):
		return false
	return bool(round.call(&"desk_hazards_enabled"))


func _is_round_playing() -> bool:
	var round := get_parent()
	if round == null:
		return false
	var game := _harbor_game()
	if game != null and game.has_method(&"get_screen"):
		return String(game.call(&"get_screen")) == "playing"
	return true


func _harbor_game() -> Node:
	var p := get_parent()
	while p != null:
		if p.has_method(&"get_screen") and p.has_node("Skybox"):
			return p
		p = p.get_parent()
	return get_tree().current_scene if get_tree() != null else null


func _pick_target() -> Vector3:
	var round := get_parent()
	if round != null and round.has_method(&"pick_hazard_target"):
		return round.call(&"pick_hazard_target")
	return Vector3.ZERO


func _register_rust_warning(center: Vector3, radius: float) -> void:
	var round := get_parent()
	if round != null and round.has_method(&"set_hazard_warning"):
		round.call(&"set_hazard_warning", HAZARD_ID_POKE, center, radius)


func _clear_rust_warning() -> void:
	var round := get_parent()
	if round != null and round.has_method(&"clear_hazard_warning"):
		round.call(&"clear_hazard_warning", HAZARD_ID_POKE)


func _sync_background_yumeka(active: bool, main_world_target: Vector3, arm_lift: float) -> void:
	var game := _harbor_game()
	if game == null:
		return
	var sky := game.get_node_or_null("Skybox")
	if sky == null or not sky.has_method(&"get_yumeka"):
		return
	var yumeka: Node = sky.call(&"get_yumeka")
	if yumeka != null and yumeka.has_method(&"set_hazard_relay"):
		yumeka.call(&"set_hazard_relay", active, main_world_target, arm_lift)


# --------------------------------------------------------------------------- #
# Foreground Hand Visual (GLB with graceful stylized placeholder fallback)
# --------------------------------------------------------------------------- #

func _ensure_hand_visual() -> void:
	if _hand_root != null and is_instance_valid(_hand_root):
		return
	_hand_root = Node3D.new()
	_hand_root.name = "ForegroundHand"
	_hand_root.visible = false
	add_child(_hand_root)
	_build_hand_model()


func _build_hand_model() -> void:
	if _hand_visual != null and is_instance_valid(_hand_visual):
		_hand_root.remove_child(_hand_visual)
		_hand_visual.free()
		_hand_visual = null

	var packed: PackedScene = null
	if not _force_placeholder and ResourceLoader.exists(HAND_GLB_PATH, "PackedScene"):
		packed = load(HAND_GLB_PATH) as PackedScene

	if packed != null:
		_hand_visual = packed.instantiate() as Node3D
		if _hand_visual != null:
			_hand_visual.name = "YumekaHandRelay"
			_using_placeholder = false
			_hand_root.add_child(_hand_visual)
			_strip_collisions(_hand_visual)
			_apply_hand_materials(_hand_visual)
			return

	_hand_visual = _build_placeholder_hand()
	_using_placeholder = true
	_hand_root.add_child(_hand_visual)


func _strip_collisions(node: Node) -> void:
	for child in node.get_children():
		if child is CollisionObject3D:
			node.remove_child(child)
			child.free()
			continue
		_strip_collisions(child)


func _apply_hand_materials(root_node: Node) -> void:
	_walk(root_node, func(node: Node) -> void:
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			return
		# Disable 180 m directional shadow-map casting on the 3 km foreground arm
		# so it never corrupts city shadow cascades; ground shadow is rendered by
		# our dedicated world-aligned soft penumbra projection (`FingerShadow`).
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = 600.0
		for surf in mi.mesh.get_surface_count():
			var src := mi.get_active_material(surf) as StandardMaterial3D
			if src == null:
				continue
			var dup := src.duplicate() as StandardMaterial3D
			dup.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			dup.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
			dup.roughness = MATTE_ROUGHNESS
			dup.metallic = 0.0
			dup.metallic_specular = MATTE_SPECULAR
			dup.emission_enabled = false
			var lower := src.resource_name.to_lower()
			if lower.contains("clothes") or lower.contains("jacket") or lower.contains("vest"):
				dup.albedo_color = CLOTHES_TINT
			else:
				dup.albedo_color = BODY_TINT
			mi.set_surface_override_material(surf, dup)
	)


func _build_placeholder_hand() -> Node3D:
	# Clean stylized procedural right hand (origin at index fingertip pad, width ~96 m,
	# forearm rising along APPROACH_DIR) for public clones without the licensed Yumeka GLB.
	var root_node := Node3D.new()
	root_node.name = "PlaceholderHandRelay"

	var skin := StandardMaterial3D.new()
	skin.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	skin.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	skin.albedo_color = Color(0.92, 0.80, 0.74)
	skin.roughness = MATTE_ROUGHNESS
	skin.metallic = 0.0
	skin.metallic_specular = MATTE_SPECULAR

	var nail_mat := StandardMaterial3D.new()
	nail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	nail_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	nail_mat.albedo_color = Color(0.95, 0.88, 0.87)
	nail_mat.roughness = 0.52
	nail_mat.metallic = 0.0
	nail_mat.metallic_specular = 0.25

	var cuff_mat := StandardMaterial3D.new()
	cuff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	cuff_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	cuff_mat.albedo_color = Color(0.84, 0.86, 0.90)
	cuff_mat.roughness = 0.90
	cuff_mat.metallic = 0.0
	cuff_mat.metallic_specular = 0.14

	var sleeve_mat := StandardMaterial3D.new()
	sleeve_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	sleeve_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	sleeve_mat.albedo_color = Color(0.24, 0.28, 0.38)
	sleeve_mat.roughness = 0.92
	sleeve_mat.metallic = 0.0
	sleeve_mat.metallic_specular = 0.14

	# Build oriented arm container so its local +Y points along `_approach_unit`,
	# local -X points west (thumb side), and local -Z points north (back of hand).
	var arm := Node3D.new()
	arm.name = "ArmFrame"
	var y_axis := _approach_unit
	var thumb_hint := Vector3(-1.0, 0.0, 0.25).normalized()
	var z_axis := thumb_hint.cross(y_axis).normalized()
	var x_axis := y_axis.cross(z_axis).normalized()
	arm.basis = Basis(x_axis, y_axis, z_axis)
	root_node.add_child(arm)

	# Extended index finger: radius 48 m (diameter 96 m), length 420 m, tip pad at y = 0.
	var index_mesh := CapsuleMesh.new()
	index_mesh.radius = 48.0
	index_mesh.height = 460.0
	index_mesh.radial_segments = 20
	index_mesh.rings = 8
	_add_placeholder_part(arm, "IndexFinger", index_mesh, Vector3(0.0, 230.0, 0.0), Vector3.ZERO, skin)

	# Subtle fingernail plate on dorsal (-Z) side of fingertip.
	var nail_mesh := SphereMesh.new()
	nail_mesh.radius = 34.0
	nail_mesh.height = 68.0
	nail_mesh.radial_segments = 14
	nail_mesh.rings = 6
	var nail := _add_placeholder_part(arm, "IndexNail", nail_mesh, Vector3(0.0, 62.0, -34.0), Vector3.ZERO, nail_mat)
	nail.scale = Vector3(0.85, 1.15, 0.28)

	# Palm block above index knuckle.
	var palm_mesh := BoxMesh.new()
	palm_mesh.size = Vector3(340.0, 320.0, 145.0)
	_add_placeholder_part(arm, "Palm", palm_mesh, Vector3(110.0, 560.0, 22.0), Vector3.ZERO, skin)

	# Curled middle, ring, and little fingers tucked on the palm (+Z) side well above ground.
	var curled_specs := [
		["MiddleCurled", Vector3(98.0, 360.0, 92.0), 46.0, 220.0, Vector3(1.15, 0.0, 0.0)],
		["RingCurled", Vector3(186.0, 385.0, 95.0), 43.0, 200.0, Vector3(1.22, 0.0, 0.0)],
		["LittleCurled", Vector3(264.0, 420.0, 92.0), 37.0, 175.0, Vector3(1.28, 0.0, 0.0)],
		["ThumbTucked", Vector3(-65.0, 410.0, 88.0), 46.0, 210.0, Vector3(0.75, 0.0, -0.55)],
	]
	for spec in curled_specs:
		var cap := CapsuleMesh.new()
		cap.radius = float(spec[2])
		cap.height = float(spec[3])
		cap.radial_segments = 14
		cap.rings = 6
		_add_placeholder_part(arm, String(spec[0]), cap, spec[1] as Vector3, spec[4] as Vector3, skin)

	# Wrist, white shirt cuff, and navy jacket sleeve reaching up into the sky.
	var wrist_mesh := CylinderMesh.new()
	wrist_mesh.top_radius = 128.0
	wrist_mesh.bottom_radius = 115.0
	wrist_mesh.height = 240.0
	wrist_mesh.radial_segments = 18
	_add_placeholder_part(arm, "Wrist", wrist_mesh, Vector3(110.0, 810.0, 24.0), Vector3.ZERO, skin)

	var cuff_mesh := CylinderMesh.new()
	cuff_mesh.top_radius = 165.0
	cuff_mesh.bottom_radius = 145.0
	cuff_mesh.height = 170.0
	cuff_mesh.radial_segments = 20
	_add_placeholder_part(arm, "ShirtCuff", cuff_mesh, Vector3(110.0, 950.0, 24.0), Vector3.ZERO, cuff_mat)

	var sleeve_mesh := CylinderMesh.new()
	sleeve_mesh.top_radius = 250.0
	sleeve_mesh.bottom_radius = 180.0
	sleeve_mesh.height = 1450.0
	sleeve_mesh.radial_segments = 20
	_add_placeholder_part(arm, "JacketSleeve", sleeve_mesh, Vector3(110.0, 1730.0, 24.0), Vector3.ZERO, sleeve_mat)

	return root_node


func _add_placeholder_part(parent: Node3D, part_name: String, mesh: Mesh, pos: Vector3,
		rot: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = mesh
	mi.position = pos
	mi.rotation = rot
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 600.0
	parent.add_child(mi)
	return mi


func _walk(node: Node, fn: Callable) -> void:
	fn.call(node)
	for child in node.get_children():
		_walk(child, fn)


# --------------------------------------------------------------------------- #
# Ground Shadow, Pulsing Amber Warning Circle & Impact Shockwave VFX
# --------------------------------------------------------------------------- #

func _ensure_warning_visuals() -> void:
	if _warning_root != null and is_instance_valid(_warning_root):
		return
	_warning_root = Node3D.new()
	_warning_root.name = "HazardWarning"
	_warning_root.visible = false
	add_child(_warning_root)

	# 1. Soft giant finger ground shadow (penumbra tightens & darkens as finger approaches).
	var shadow_mesh := QuadMesh.new()
	shadow_mesh.size = Vector2(460.0, 460.0)
	_shadow_mat = ShaderMaterial.new()
	var shadow_shader := Shader.new()
	shadow_shader.code = """
shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled;

uniform float u_progress = 0.0;
uniform float u_alpha_scale = 1.0;
uniform float u_night = 0.0;
uniform vec2 u_arm_dir = vec2(0.73, 0.68);

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0; // [-1, 1] across 460 m (1.0 == 230 m)
	float tight = mix(1.48, 0.96, smoothstep(0.0, 1.0, u_progress));
	// Core fingertip shadow centered at (0, 0)
	float r_tip = length(p / vec2(0.56 * tight));
	float m_tip = exp(-r_tip * r_tip * 1.95);
	// Trailing hand & forearm canopy extending along +u_arm_dir (southeast)
	vec2 d_arm = p - u_arm_dir * (0.48 * tight);
	float along = dot(d_arm, u_arm_dir);
	vec2 perp = d_arm - u_arm_dir * along;
	float r_arm = length(vec2(along / (0.86 * tight), length(perp) / (0.52 * tight)));
	float m_arm = exp(-r_arm * r_arm * 1.65) * 0.78;
	float mask = clamp(1.0 - (1.0 - m_tip) * (1.0 - m_arm), 0.0, 1.0);
	float edge_fade = 1.0 - smoothstep(0.72, 1.0, length(p));
	float peak = mix(0.30, 0.68, smoothstep(0.0, 1.0, u_progress)) * mix(1.0, 0.56, u_night);
	ALBEDO = mix(vec3(0.06, 0.09, 0.16), vec3(0.03, 0.04, 0.09), u_night);
	ALPHA = clamp(mask * edge_fade * peak * u_alpha_scale, 0.0, 0.76);
}
"""
	_shadow_mat.shader = shadow_shader
	var arm_xz := Vector2(_approach_unit.x, _approach_unit.z).normalized()
	_shadow_mat.set_shader_parameter(&"u_arm_dir", arm_xz)

	_shadow_quad = MeshInstance3D.new()
	_shadow_quad.name = "FingerShadow"
	_shadow_quad.mesh = shadow_mesh
	_shadow_quad.material_override = _shadow_mat
	_shadow_quad.rotation_degrees.x = -90.0
	# Clears 0.15 m raised sidewalks cleanly with zero Z-fighting.
	_shadow_quad.position = Vector3(0.0, 0.24, 0.0)
	_shadow_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_warning_root.add_child(_shadow_quad)

	# 2. Pulsing amber warning circle (radius = POKE_RADIUS = 110 m).
	var warn_mesh := QuadMesh.new()
	var warn_size := POKE_RADIUS * 2.18
	warn_mesh.size = Vector2(warn_size, warn_size)
	_warn_mat = ShaderMaterial.new()
	var warn_shader := Shader.new()
	warn_shader.code = """
shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled;

uniform float u_progress = 0.0;
uniform float u_time = 0.0;

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.18; // radius 1.0 == POKE_RADIUS (110 m)
	float r = length(p);
	if (r > 1.06) {
		discard;
	}
	float pulse = 0.5 + 0.5 * sin(u_time * mix(7.5, 16.0, u_progress));
	// Crisp outer perimeter ring at r = 1.0
	float outer = smoothstep(0.945, 0.975, r) * (1.0 - smoothstep(1.015, 1.045, r));
	// Subtle hazard tick accents around outer ring
	float ang = atan(p.y, p.x);
	float ticks = step(0.18, fract((ang / 6.2831853) * 24.0 + u_time * 0.12));
	float outer_bright = outer * mix(0.68, 1.0, ticks);
	// Expanding progress ring sweeping from center out to 1.0 on impact
	float sweep_r = mix(0.12, 0.99, u_progress);
	float sweep = smoothstep(sweep_r - 0.045, sweep_r - 0.008, r) * (1.0 - smoothstep(sweep_r + 0.008, sweep_r + 0.032, r));
	// Translucent amber fill inside the danger zone
	float fill = (1.0 - smoothstep(0.96, 1.0, r)) * (0.13 + 0.10 * pulse + 0.10 * u_progress);
	// Subtle inner bullseye ring at r = 0.42
	float inner = smoothstep(0.395, 0.415, r) * (1.0 - smoothstep(0.435, 0.455, r)) * 0.42;

	vec3 amber = vec3(1.00, 0.62, 0.22);
	vec3 hot = vec3(1.00, 0.88, 0.58);
	vec3 danger = vec3(1.00, 0.36, 0.16);
	vec3 base_col = mix(amber, danger, smoothstep(0.55, 1.0, u_progress) * 0.55);
	vec3 col = mix(base_col, hot, clamp(sweep * 0.85 + outer_bright * 0.35, 0.0, 1.0));
	float alpha = clamp(fill + outer_bright * (0.78 + 0.20 * pulse) + sweep * 0.88 + inner, 0.0, 0.95);
	ALBEDO = col;
	ALPHA = alpha;
}
"""
	_warn_mat.shader = warn_shader

	_warn_quad = MeshInstance3D.new()
	_warn_quad.name = "WarningCircle"
	_warn_quad.mesh = warn_mesh
	_warn_quad.material_override = _warn_mat
	_warn_quad.rotation_degrees.x = -90.0
	_warn_quad.position = Vector3(0.0, 0.34, 0.0)
	_warn_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_warning_root.add_child(_warn_quad)


func _update_warning_visuals(progress: float, shadow_alpha: float, show_circle: bool) -> void:
	if _shadow_mat != null:
		_shadow_mat.set_shader_parameter(&"u_progress", clampf(progress, 0.0, 1.0))
		_shadow_mat.set_shader_parameter(&"u_alpha_scale", clampf(shadow_alpha, 0.0, 1.0))
		_shadow_mat.set_shader_parameter(&"u_night", CityNightLights.get_night_glow())
	if _warn_quad != null:
		_warn_quad.visible = show_circle
	if show_circle and _warn_mat != null:
		_warn_mat.set_shader_parameter(&"u_progress", clampf(progress, 0.0, 1.0))
		_warn_mat.set_shader_parameter(&"u_time", _phase_time)


func _spawn_impact_vfx(center: Vector3) -> void:
	var burst := Node3D.new()
	burst.name = "PokeShockwave"
	burst.position = Vector3(center.x, 0.5, center.z)
	_vfx_root.add_child(burst)

	# Giant expanding shockwave ring (110 m -> 270 m).
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 0.82
	ring_mesh.outer_radius = 1.0
	ring_mesh.rings = 48
	ring_mesh.ring_segments = 8
	var ring := MeshInstance3D.new()
	ring.mesh = ring_mesh
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	ring_mat.albedo_color = Color(1.0, 0.85, 0.56, 0.86)
	ring.material_override = ring_mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.scale = Vector3(POKE_RADIUS * 0.72, 6.0, POKE_RADIUS * 0.72)
	burst.add_child(ring)

	var tween := burst.create_tween().set_parallel(true)
	tween.tween_property(ring, "scale", Vector3(POKE_RADIUS * 2.45, 2.5, POKE_RADIUS * 2.45), 0.85) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(ring_mat, "albedo_color:a", 0.0, 0.88)

	# 14 smooth soft-edged billowing dust clouds erupting around the fingertip rim.
	var puff_mesh := SphereMesh.new()
	puff_mesh.radial_segments = 18
	puff_mesh.rings = 10
	var dust_shader := Shader.new()
	dust_shader.code = """
shader_type spatial;
render_mode unshaded, depth_draw_never;

uniform vec3 u_color : source_color = vec3(0.80, 0.70, 0.58);
uniform float u_alpha = 0.56;

void fragment() {
	float fres = pow(clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 1.65);
	ALBEDO = u_color;
	ALPHA = clamp(fres * u_alpha, 0.0, 0.72);
}
"""
	var night := CityNightLights.get_night_glow()
	var dust_col := Color(0.82, 0.73, 0.62).lerp(Color(0.36, 0.38, 0.48), night * 0.65)
	var puff_count := 14
	for i in puff_count:
		var ang := float(i) * TAU / float(puff_count) + _rng.randf_range(-0.14, 0.14)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var puff := MeshInstance3D.new()
		puff.mesh = puff_mesh
		var puff_mat := ShaderMaterial.new()
		puff_mat.shader = dust_shader
		puff_mat.set_shader_parameter(&"u_color", dust_col)
		puff_mat.set_shader_parameter(&"u_alpha", 0.58)
		puff.material_override = puff_mat
		puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var start_r := _rng.randf_range(POKE_RADIUS * 0.42, POKE_RADIUS * 0.88)
		puff.position = dir * start_r + Vector3(0.0, _rng.randf_range(4.0, 14.0), 0.0)
		var base_sz := _rng.randf_range(18.0, 34.0)
		puff.scale = Vector3.ONE * base_sz
		burst.add_child(puff)
		var end_pos := puff.position + dir * _rng.randf_range(55.0, 130.0) \
				+ Vector3(0.0, _rng.randf_range(34.0, 78.0), 0.0)
		var dur := _rng.randf_range(1.15, 1.55)
		tween.tween_property(puff, "position", end_pos, dur) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(puff, "scale", Vector3.ONE * (base_sz * 2.3), dur)
		tween.tween_property(puff_mat, "shader_parameter/u_alpha", 0.0, dur)

	tween.chain().tween_callback(burst.queue_free)


# --------------------------------------------------------------------------- #
# Debug / Test Inspection Helpers
# --------------------------------------------------------------------------- #

func debug_force_placeholder(enabled: bool) -> void:
	_force_placeholder = enabled
	if _hand_root != null and is_instance_valid(_hand_root):
		_build_hand_model()


func debug_state() -> Dictionary:
	var phase_names := {
		Phase.IDLE: "idle",
		Phase.WINDUP: "windup",
		Phase.HOLD: "hold",
		Phase.RETRACT: "retract",
	}
	var kind_names := {
		HazardKind.NONE: "none",
		HazardKind.FINGER_POKE: "finger_poke",
	}
	return {
		"enabled": _is_enabled(),
		"active": _phase != Phase.IDLE,
		"phase": phase_names.get(_phase, "idle"),
		"phase_time": _phase_time,
		"hazard": kind_names.get(_hazard, "none"),
		"target": _target,
		"fingertip_pos": _hand_root.global_position if _hand_root != null else Vector3.ZERO,
		"hand_visible": _hand_root != null and _hand_root.visible,
		"warning_visible": _warn_quad != null and _warn_quad.visible,
		"shadow_visible": _shadow_quad != null and _shadow_quad.visible and _warning_root != null and _warning_root.visible,
		"using_placeholder": _using_placeholder,
		"next_auto_in": _next_auto_in,
		"trigger_count": _trigger_count,
		"last_impact": _last_impact_summary.duplicate(),
	}
