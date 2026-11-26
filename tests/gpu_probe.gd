extends SceneTree
## Real-GPU probe: measures frame rate, draw calls and primitives per second for the
## sandbox harbour with different district subtrees visible, plus a whole-map overview.
## Numbers come from the Godot Performance monitors of a real window, so they are only
## comparable on the same machine, renderer, resolution and vsync state.
##
##   XDG_DATA_HOME="$PWD/build/xdg" timeout 900 godot --path . --script res://tests/gpu_probe.gd
##
## The first seconds of a fresh process pay for shader and material compilation on the
## compatibility renderer, so the probe warms up until 30 consecutive frames stay above
## WARM_FPS (or WARM_FRAMES frames) before the first measurement, and repeats the "full"
## baseline last so drift is visible in the report.
##
## Screenshots are written to res://build/tmp/gpu_probe/<label>.png for visual review.
## This probe only prints; it is not part of the automated gameplay suite.

const WARM_FRAMES := 420
const WARM_FPS := 26.0
const WARM_RUN := 30
const FRAMES := 60
const SHOTS := "res://build/tmp/gpu_probe/"

var _game: Node
var _round: Node
var _district: Node
var _camera: Camera3D

const CONFIGS: Array = [
	["full", [], false],
	["no_roads", ["Roads"], false],
	["no_targets", ["Targets"], false],
	["no_scenery", ["Scenery"], false],
	["no_buildings_all", ["Roads", "Targets", "Scenery", "Lots"], false],
	["overview", [], true],
	["spawn_all_chunks", [], false, 4000.0],
	["spawn_all_no_roads", ["Roads"], false, 4000.0],
	["full_again", [], false],
]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOTS))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	seed(4242)
	_game = load("res://scenes/main.tscn").instantiate()
	_game.settings_path = "user://gpu-probe-%d.cfg" % OS.get_process_id()
	root.add_child(_game)
	await process_frame
	_game.save_all_mode_settings(_game.default_mode_settings(0),
			_game.default_mode_settings(1), _game.default_mode_settings(2),
			_game.default_mode_settings(3))
	_game.start_mode(true)
	_round = _game.get_node("MapSlot/Round")
	_district = _round.get_node("District")
	_camera = _round.get_node("Orbit/Arm/Camera")
	_base_draw_distance = _camera.get_meta(&"district_draw_distance", 300.0)
	await _warm_up()
	var window := DisplayServer.window_get_size()
	print("GPU_PROBE window=%dx%d renderer=%s vsync=%d warm_frames=%d" % [window.x, window.y,
			ProjectSettings.get_setting("rendering/renderer/rendering_method"),
			DisplayServer.window_get_vsync_mode(), _warm_used])
	for entry: Array in CONFIGS:
		await _measure(entry[0], entry[1], entry[2], entry[3] if entry.size() > 3 else 0.0)
	_game.show_menu()
	DirAccess.remove_absolute(_game.settings_path)
	quit(0)


var _warm_used := 0
var _base_draw_distance := 300.0


## Draw the whole city from the spawn camera until shader compilation settles.
func _warm_up() -> void:
	var steady := 0
	for frame in WARM_FRAMES:
		await process_frame
		_warm_used = frame + 1
		if Performance.get_monitor(Performance.TIME_FPS) >= WARM_FPS:
			steady += 1
			if steady >= WARM_RUN:
				return
		else:
			steady = 0


func _measure(label: String, hidden: Array, overview: bool, draw_distance := 0.0) -> void:
	# 0 keeps the round's own view distance; anything else forces every chunk active so the
	# whole-map-visibility case can be measured with the normal gameplay camera.
	_camera.set_meta(&"district_draw_distance",
			draw_distance if draw_distance > 0.0 else _base_draw_distance)
	for name: String in ["Roads", "Targets", "Scenery", "Lots"]:
		var node := _district.get_node_or_null(name)
		if node != null:
			node.visible = not hidden.has(name)
	var extra: Camera3D
	if overview:
		extra = Camera3D.new()
		extra.fov = 55.0
		extra.far = 4200.0
		extra.near = 1.0
		extra.set_meta(&"district_draw_distance", 3600.0)
		_district.add_child(extra)
		extra.global_position = Vector3(0.0, 620.0, 980.0)
		extra.look_at(Vector3.ZERO, Vector3.UP)
		extra.make_current()
	else:
		_camera.make_current()
	for frame in 30:
		await process_frame
	var fps := 0.0
	var draws := 0.0
	var prims := 0.0
	var objects := 0.0
	var worst := 120.0
	for frame in FRAMES:
		await process_frame
		var frame_fps: float = Performance.get_monitor(Performance.TIME_FPS)
		fps += frame_fps
		if frame_fps > 0.0:
			worst = minf(worst, frame_fps)
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		objects += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(SHOTS + label + ".png")
	print("GPU %-18s fps=%6.1f worst=%5.1f draws=%6.0f prims=%10.0f objects=%6.0f" % [
		label, fps / FRAMES, worst, draws / FRAMES, prims / FRAMES, objects / FRAMES])
	if extra != null:
		extra.queue_free()
		await process_frame
		_camera.make_current()
