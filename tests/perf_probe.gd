extends SceneTree
## Manual physics-time probe for many-actor rounds. It only prints numbers and always
## exits 0, so it is not part of the automated gameplay suite.
##
##   cargo build --locked --release --manifest-path rust/Cargo.toml --target-dir rust/target
##   XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --fixed-fps 60 --script res://tests/perf_probe.gd
##
## Use a release extension for meaningful results; the debug extension exaggerates the
## GDScript and Rust costs. To run this script against a release extension:
##
##   cp rust/target/release/libharbor.so rust/target/debug/libharbor.so
##   # ... measure ...
##   touch rust/src/lib.rs && cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
##
## Compare the mean/p95 values before and after AI, collision or animation changes.
## `growth-contact` lowers the rival ignore ratio so nearly every pair enters the contact
## pass.

const FRAMES := 150
const COUNTS := [60, 20]

var _game: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	seed(90210)
	_game = load("res://scenes/main.tscn").instantiate()
	_game.settings_path = "user://perf-probe-%d.cfg" % OS.get_process_id()
	root.add_child(_game)
	await process_frame
	for count in COUNTS:
		var growth: Dictionary = _game.default_mode_settings(2)
		growth.giant_count = count
		growth.npc_initial = 0
		growth.npc_respawn = false
		var sandbox: Dictionary = _game.default_mode_settings(1)
		sandbox.giant_count = count
		sandbox.npc_initial = 0
		sandbox.npc_respawn = false
		var mixed: Dictionary = _game.default_mode_settings(2)
		mixed.giant_count = count
		mixed.npc_initial = 0
		mixed.npc_respawn = false
		mixed.random_start = true
		mixed.giant_height = 25.0
		mixed.giant_max_height = 200.0
		mixed.height_bands = false
		mixed.coin_count = 60
		var contact: Dictionary = _game.default_mode_settings(2)
		contact.giant_count = count
		contact.npc_initial = 0
		contact.npc_respawn = false
		contact.random_start = true
		contact.giant_height = 25.0
		contact.giant_max_height = 200.0
		contact.height_bands = false
		contact.coin_count = 0
		contact.rival_ignore_ratio = 1.1
		var brawl: Dictionary = _game.default_mode_settings(3)
		brawl.giant_count = count
		brawl.npc_initial = 0
		brawl.npc_respawn = false
		brawl.start_min_height = 10.0
		brawl.start_max_height = 100.0
		_game.save_all_mode_settings(_game.default_mode_settings(0), sandbox, growth, brawl)
		await _measure("brawl-mixed-%d" % count, _game.start_brawl)
		_game.save_all_mode_settings(_game.default_mode_settings(0), sandbox, mixed, brawl)
		await _measure("growth-mixed-%d" % count, _game.start_growth)
		_game.save_all_mode_settings(_game.default_mode_settings(0), sandbox, contact, brawl)
		await _measure("growth-contact-%d" % count, _game.start_growth)
		_game.save_all_mode_settings(_game.default_mode_settings(0), sandbox, growth, brawl)
		await _measure("growth-human-%d" % count, _game.start_growth)
		await _measure("sandbox-giant-%d" % count, _game.start_mode.bind(true))
	_game.show_menu()
	DirAccess.remove_absolute(_game.settings_path)
	quit(0)


func _measure(label: String, starter: Callable) -> void:
	starter.call()
	for frame in 8:
		await physics_frame
	var current := _game.get_node("MapSlot/Round")
	var count: int = current.snapshot().giant_count
	var times: Array[float] = []
	for frame in FRAMES:
		var begin := Time.get_ticks_usec()
		await physics_frame
		times.append((Time.get_ticks_usec() - begin) / 1000.0)
	times.sort()
	var total := 0.0
	for value in times:
		total += value
	var mean := total / times.size()
	print("PERF %s actors=%d mean_ms=%.2f p50=%.2f p95=%.2f max=%.2f" % [
		label, count, mean, times[times.size() / 2], times[int(times.size() * 0.95)],
		times[times.size() - 1]])
