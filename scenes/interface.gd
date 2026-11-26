extends CanvasLayer
## Maritime Civil Defense × Industrial Print UI for "Scalebreaker".
## Avoids generic dark-cyan glowing cards in favor of warm charcoal iron,
## off-white industrial stencil print, signal vermilion, evacuation green,
## and heavy-machinery amber with custom vector HUD widgets.

# Palette: warm iron charcoal + stencil off-white + maritime industrial accents.
const CHARCOAL := Color("#111316")
const IRON := Color("#1a1e23")
const SLATE := Color("#2a3038")
const PAPER := Color("#efeae0")
const WARM_GRAY := Color("#9ea5a8")
const DIM_GRAY := Color("#666e73")
const SIGNAL_RED := Color("#e44d2e")
const EVAC_GREEN := Color("#2ec995")
const CRANE_AMBER := Color("#eba930")
const BEDROOM_BLUE := Color("#8fcbd4")
const HOT_WHITE := Color("#fffaf0")
const MODE_NAMES := ["人类撤离", "巨人沙盒", "成长模式", "大乱斗"]
const GROWTH_ROLE_NAMES := ["成长模式", "旁观者模式", "人类模式"]
const GROWTH_MODE := 2
const BRAWL_MODE := 3
const DEFEAT_ACTIONS := {
	"step": "落脚击倒",
	"stomp": "重踏击倒",
	"contact_stomp": "碰撞踩倒",
	"punch": "挥拳击倒",
	"grab_crush": "捏碎击倒",
	"bump": "撞击击倒",
	"sit_crush": "坐压压扁",
}
const DEFEAT_FEED_LIMIT := 3
const PERCENT_SETTINGS := ["shake_strength", "sfx_volume", "ambience_volume", "coin_growth_rate", "building_growth_rate", "coin_reward_rate"]
const AUDIO_SETTING_KEYS := ["sfx_volume", "ambience_volume"]
const TouchControls := preload("res://scenes/touch_controls.gd")
const SettingsSchema := preload("res://scenes/settings_schema.gd")

const FONT_SANS := ["Source Han Sans CN", "Noto Sans CJK SC", "Microsoft YaHei", "PingFang SC"]
const FONT_MONO := ["Source Code Pro", "JetBrainsMono Nerd Font Mono", "Source Han Sans CN", "Noto Sans Mono CJK SC", "DejaVu Sans Mono"]

enum MenuPage { MAIN, HARBOR, BEDROOM, GROWTH }
enum PlayerRole { EVACUEE, GIANT, SPECTATOR, HUMAN_OBSERVER }

@onready var _game: Node = get_parent()

var _font_regular: Font
var _font_medium: Font
var _font_bold: Font
var _font_heavy: Font
var _font_title: FontVariation
var _font_mono: Font
var _font_mono_bold: Font
var _font_tag: FontVariation

var _root: Control
var _menu: Control
var _hud: Control
var _modal: Control
var _touch_enabled := OS.has_feature("android")
var _touch: TouchControls
var _full_bleed: Array[Control] = []
var _frame_times := PackedFloat32Array()
var _perf_elapsed := 0.0
var _last_frame_usec := 0

# Menu references for entrance choreography & live telemetry.
var _menu_stack: Control
var _menu_cam_badge: Control
var _menu_cam_dot: ColorRect
var _menu_title: Label
## Menu column width the big title has to stay inside (see `_build_menu`).
const MENU_TITLE_WIDTH := 428.0
const MENU_TITLE_MAX := 76
const MENU_TITLE_MIN := 44
var _menu_rule: HazardStripe
var _menu_page := MenuPage.MAIN
var _front_choices: VBoxContainer
var _harbor_choices: VBoxContainer
var _growth_choices: VBoxContainer
var _bedroom_choices: VBoxContainer
var _harbor_ribbon: VBoxContainer
var _harbor_entry: TacticalButton
var _bedroom_entry: TacticalButton
var _bedroom_play: TacticalButton
var _bedroom_status: Label
var _primary_mode: TacticalButton
var _growth_entry: TacticalButton
var _growth_play: TacticalButton
var _harbor_keys: Control

# HUD references.
var _human_hud: Control
var _giant_hud: Control
var _demo_hud: Control
var _growth_hud: Control
var _giant_health: ProgressBar
var _growth_height: Label
var _growth_stats: Label
var _growth_status: Label
var _growth_coins: Label
var _ranking_box: ChamferBox
var _desktop_ranking_scroll: ScrollContainer
var _ranking_table: GrowthRankTable
var _ranking_round: Node
var _ranking_expanded := false
var _ranking_refresh_in := 0.0
var _defeat_feed: VBoxContainer
var _defeat_round_id := 0
var _touch_ranking_layer: Control
var _touch_ranking_scroll: ScrollContainer
var _touch_ranking_player: Label
var _giant_hp_ratio := 1.0
var _health_meter: HealthMeter
var _stamina_gauge: StaminaGauge
var _evac_compass: EvacCompass
var _evac_dist_num: Label
var _evac_dist_unit: Label
var _evac_sub: Label
var _evac_panel: ChamferBox
var _count_num: Label
var _count_total: Label
var _count_status: Label
var _building_matrix: BuildingMatrix
var _stomp_gauge: StompGauge
var _hud_keys: KeycapBar
var _vignette: ColorRect
var _vignette_mat: ShaderMaterial

# Modal references.
var _modal_card: Control
var _modal_stripe: HazardStripe
var _modal_kicker: Label
var _modal_title: Label
var _modal_text: Label
var _modal_stat: Label
var _resume_button: TacticalButton
var _primary_modal: TacticalButton
var _menu_button: TacticalButton
var _pause_settings_button: TacticalButton

var _settings_panel: Control
var _settings_page := "gameplay"
var _settings_page_tabs: Array[Button] = []
var _settings_page_views: Dictionary = {}
var _settings_row_host: Dictionary = {}
var _settings_graphics_scroll: ScrollContainer
var _settings_groups: Dictionary = {}
var _settings_rows: Dictionary = {}
var _settings_hints: Dictionary = {}
var _settings_hint_open: Dictionary = {}
var _settings_group_open: Dictionary = {}
var _settings_advanced_open: Dictionary = {}
var _display_draft: Dictionary = {}
var _audio_draft: Dictionary = {}
var _settings_fields: Dictionary[String, SpinBox] = {}
var _settings_flags: Dictionary[String, CheckButton] = {}
var _settings_tabs: Array[Button] = []
var _settings_respawn: CheckButton
var _settings_audio_muted: CheckButton
var _growth_settings_rows: Control
var _settings_scroll: ScrollContainer
var _settings_center: CenterContainer
var _settings_heading: Label
var _settings_tab_row: HBoxContainer
var _settings_actions: HBoxContainer
var _keyboard_height := -1
var _settings_note: Label
var _settings_return_focus: Control
var _settings_mode := 0
var _settings_drafts: Array[Dictionary] = []
var _saved_audio_settings: Dictionary = {}

# Dynamic HUD state.
var _screen := "menu"
var _is_giant := false
var _player := PlayerRole.EVACUEE
var _mode := 0
var _last_health := 3
var _last_destroyed := 0
var _last_player_destroyed := 0
var _last_can_crush := false
var _last_giant_hits := 0
var _giant_hit_marker: Label
var _hit_marker_tween: Tween
var _total_buildings := 12
var _damage_flash := 0.0
var _ui_time := 0.0
var _menu_tween: Tween
var _modal_tween: Tween
var _count_tween: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_fonts()

	_root = Control.new()
	add_child(_root)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var theme := Theme.new()
	theme.default_font = _font_regular
	theme.default_font_size = 16
	_root.theme = theme

	_build_menu()
	_build_hud()
	_build_modal()
	_build_settings()
	if _touch_enabled:
		_touch = TouchControls.new()
		_touch.name = "TouchControls"
		_touch.game = _game
		_touch.label_font = _font_bold
		_touch.ranking_requested.connect(_open_touch_ranking)
		_hud.add_child(_touch)
		_touch.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		get_viewport().size_changed.connect(_fit_mobile_root)
		_fit_mobile_root()
		if OS.has_feature("android") and OS.is_debug_build():
			RenderingServer.frame_post_draw.connect(_log_first_menu_frame, CONNECT_ONE_SHOT)


func _process(delta: float) -> void:
	if _touch_enabled and _settings_panel.visible and DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		_fit_settings(DisplayServer.virtual_keyboard_get_height())
	if OS.has_feature("android") and OS.is_debug_build() and _screen == "playing":
		_sample_frame_times()
	if _ranking_round != null:
		_ranking_refresh_in -= delta
		if _ranking_refresh_in <= 0.0:
			_refresh_growth_ranking()
	var dt := minf(delta, 0.05)
	_ui_time += dt

	# Live camera blink dot on title screen.
	if _menu.visible and _menu_cam_dot != null:
		var pulse := 0.45 + 0.55 * (0.5 + 0.5 * sin(_ui_time * 3.6))
		_menu_cam_dot.color = Color(SIGNAL_RED, pulse)

	# Decay radial damage vignette & drive subtle low-health pulse while unpaused.
	if _vignette_mat != null:
		var playing := _screen == "playing" and not get_tree().paused
		if playing:
			_damage_flash = maxf(0.0, _damage_flash - dt * 2.2)
		var low_hp := 0.0
		if _hud.visible and ((_player == PlayerRole.EVACUEE and _last_health == 1) or (_is_giant and _has_growth_hud(_mode) and _giant_hp_ratio < 0.25)):
			low_hp = 0.24 + 0.14 * (0.5 + 0.5 * sin(_ui_time * 5.2))
		_vignette_mat.set_shader_parameter("hit_flash", _damage_flash)
		_vignette_mat.set_shader_parameter("danger_pulse", low_hp)

	# Advance HUD visual widget animations (frozen during pause for accuracy).
	if _hud.visible and not get_tree().paused:
		if _player == PlayerRole.EVACUEE:
			_health_meter.tick(dt)
			_stamina_gauge.tick(dt)
			_evac_compass.tick(dt)
		elif _is_giant:
			_building_matrix.tick(dt)
			_stomp_gauge.tick(dt)
			if _has_growth_hud(_mode):
				_evac_compass.tick(dt)


func _input(event: InputEvent) -> void:
	if _touch_enabled or _ranking_round == null:
		return
	if event.is_action_pressed("toggle_ranking", false, true):
		get_viewport().set_input_as_handled()
		_ranking_expanded = not _ranking_expanded
		_desktop_ranking_scroll.scroll_vertical = 0
		_refresh_growth_ranking()
		_play_ui(&"ui_click" if _ranking_expanded else &"ui_back")
	elif _ranking_expanded and event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				var direction := 1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1
				_desktop_ranking_scroll.scroll_vertical += direction * 3 * GrowthRankTable.ROW_HEIGHT
				get_viewport().set_input_as_handled()


func prepare_bedroom_menu() -> void:
	_menu_page = MenuPage.BEDROOM


func handle_back() -> bool:
	if dismiss_settings(true) or dismiss_ranking():
		return true
	if _menu.visible and _menu_page != MenuPage.MAIN:
		_play_ui(&"ui_back")
		_show_menu_page(MenuPage.HARBOR if _menu_page == MenuPage.GROWTH else MenuPage.MAIN)
		return true
	return false


func _audio() -> Node:
	return get_node_or_null("/root/HarborAudio")


func _play_ui(id: StringName) -> void:
	var audio := _audio()
	if audio != null:
		audio.call("play_ui", id)


func _has_growth_hud(mode: int) -> bool:
	return mode == GROWTH_MODE or mode == BRAWL_MODE


func show_screen(screen: String, mode: int, current_round: Node, player: PlayerRole) -> void:
	var prev_screen := _screen
	var giant := player == PlayerRole.GIANT
	var evacuation := player == PlayerRole.EVACUEE
	var observing := not giant and not evacuation
	_screen = screen
	_mode = mode
	_is_giant = giant
	_player = player
	_settings_panel.hide()
	if _touch_enabled:
		_touch_ranking_layer.hide()
		_touch.present(screen, mode, current_round, evacuation or player == PlayerRole.HUMAN_OBSERVER, giant)
		_touch_ranking_player.visible = giant
		_frame_times.clear()
		_perf_elapsed = 0.0
		_last_frame_usec = 0

	_menu.visible = screen == "menu"
	_hud.visible = screen != "menu"
	_modal.visible = screen in ["paused", "evacuated", "lost"]
	_pause_settings_button.visible = screen == "paused"

	_human_hud.visible = evacuation
	_evac_panel.visible = evacuation
	_giant_hud.visible = giant
	_growth_hud.visible = giant and _has_growth_hud(mode)
	var defeat_round_id := current_round.get_instance_id() if current_round != null and _has_growth_hud(mode) else 0
	if defeat_round_id != _defeat_round_id:
		for child in _defeat_feed.get_children():
			_defeat_feed.remove_child(child)
			child.queue_free()
		_defeat_round_id = defeat_round_id
	_defeat_feed.visible = defeat_round_id != 0 and screen == "playing"
	if current_round != _ranking_round or screen != "playing":
		_ranking_expanded = false
	_ranking_round = current_round if _has_growth_hud(mode) and screen == "playing" else null
	if not _touch_enabled:
		_ranking_box.visible = _ranking_round != null
	if _ranking_round != null:
		_refresh_growth_ranking()
	_demo_hud.visible = mode == 1
	_stomp_gauge.visible = mode == 1
	_modal_stat.visible = not observing
	if observing:
		_damage_flash = 0.0
		_giant_hit_marker.modulate.a = 0.0

	_set_hud_keys()

	match screen:
		"menu":
			_damage_flash = 0.0
			_last_health = 3
			_last_destroyed = 0
			_last_player_destroyed = 0
			_last_can_crush = false
			_last_giant_hits = 0
			_giant_hit_marker.modulate.a = 0.0
			_show_menu_page(_menu_page)
			_animate_menu_in()
		"playing":
			if prev_screen == "paused":
				_play_ui(&"ui_resume")
			if prev_screen != "playing":
				_giant_hp_ratio = 1.0
				_damage_flash = 0.0
			if prev_screen == "menu":
				_damage_flash = 0.0
				_last_health = 3
				_last_destroyed = 0
				_last_player_destroyed = 0
				_last_can_crush = false
				_health_meter.reset(3)
				_stamina_gauge.reset(1.0)
				_building_matrix.reset(0)
				_stomp_gauge.reset()
		"paused":
			if prev_screen == "playing":
				_play_ui(&"ui_pause")
			var accent := CRANE_AMBER if giant else EVAC_GREEN
			_modal_stripe.set_colors(accent, CHARCOAL)
			_modal_kicker.text = GROWTH_ROLE_NAMES[player - PlayerRole.GIANT] if mode == GROWTH_MODE else MODE_NAMES[mode]
			_modal_kicker.add_theme_color_override("font_color", accent)
			_modal_title.text = "已暂停"
			_modal_text.text = "当前进度已冻结，随时可继续或重新开始。"
			_modal_stat.text = ("已摧毁建筑  %02d / %d" % [_last_destroyed, _total_buildings]) if giant else ("剩余生命  %d / 3" % _last_health)
			_resume_button.set_accent(accent)
			_primary_modal.set_accent(accent)
			_resume_button.show()
			_resume_button.grab_focus()
			_animate_modal_in()
		"evacuated":
			_play_ui(&"evac_victory")
			_modal_stripe.set_colors(EVAC_GREEN, CHARCOAL)
			_modal_kicker.text = "人类撤离"
			_modal_kicker.add_theme_color_override("font_color", EVAC_GREEN)
			_modal_title.text = "撤离成功"
			_modal_text.text = "已突破封锁线并抵达港区东南撤离点。"
			_modal_stat.text = "剩余生命  %d / 3" % _last_health
			_primary_modal.set_accent(EVAC_GREEN)
			_resume_button.hide()
			_primary_modal.grab_focus()
			_animate_modal_in()
		"lost":
			_play_ui(&"evac_lost")
			_modal_stripe.set_colors(SIGNAL_RED, CHARCOAL)
			_modal_kicker.text = "人类撤离"
			_modal_kicker.add_theme_color_override("font_color", SIGNAL_RED)
			_modal_title.text = "撤离失败"
			_modal_text.text = "未能避开巨人重踏，生命已耗尽。"
			_modal_stat.text = "剩余生命  0 / 3"
			_primary_modal.set_accent(SIGNAL_RED)
			_resume_button.hide()
			_primary_modal.grab_focus()
			_animate_modal_in()
	var audio := _audio()
	if audio != null:
		audio.call("set_ambience", &"harbor")


func update_hud(state: Dictionary) -> void:
	if _player == PlayerRole.SPECTATOR or _player == PlayerRole.HUMAN_OBSERVER:
		return
	var health: int = state.health
	if health < _last_health:
		_damage_flash = 0.92
		_health_meter.set_health(health, true)
	elif health > _last_health:
		_damage_flash = 0.0
		_health_meter.reset(health)
	else:
		_health_meter.set_health(health, false)
	_last_health = health

	_stamina_gauge.set_stamina(float(state.stamina))

	var destroyed: int = state.destroyed
	var total: int = maxi(int(state.get("total_buildings", 12)), 1)
	_total_buildings = total
	if destroyed != _last_destroyed:
		if destroyed > _last_destroyed:
			_punch_control(_count_num)
		_last_destroyed = destroyed
		_building_matrix.set_progress(destroyed, total, destroyed > 0)
	else:
		_building_matrix.set_progress(destroyed, total, false)
	_count_num.text = "%02d" % destroyed
	_count_total.text = "/ %d" % total
	var height_m: float = float(state.giant_height)
	var scale_text := _format_height(height_m)
	if state.giant_at_max_height:
		scale_text += "（上限）"
	var player_destroyed: int = state.giant_destroyed
	var can_crush_now: bool = bool(state.get("can_crush_buildings", false))
	if _is_giant and _screen == "playing":
		var unlocked := false
		if not _has_growth_hud(_mode):
			unlocked = (_last_player_destroyed < 3 and player_destroyed >= 3) or (_last_player_destroyed < 6 and player_destroyed >= 6)
		elif can_crush_now and not _last_can_crush and not state.giant_respawning and _last_player_destroyed >= 0 and height_m >= 40.0:
			# Avoid triggering on initial spawn above 40m (only once the player actually grows across 40m).
			unlocked = _last_destroyed > 0 or int(state.get("coins_collected", 0)) > 0 or int(state.get("giant_kills", 0)) > 0
		if unlocked:
			var audio := _audio()
			if audio != null:
				audio.call("play_unlock_milestone")
	_last_player_destroyed = player_destroyed
	_last_can_crush = can_crush_now
	if destroyed >= total:
		_count_status.text = "全港已夷平  ·  身高 %s" % scale_text
		_count_status.add_theme_color_override("font_color", CRANE_AMBER)
	elif _has_growth_hud(_mode) and state.can_crush_buildings:
		_count_status.text = "触碰碾压已解锁"
		_count_status.add_theme_color_override("font_color", CRANE_AMBER)
	elif _has_growth_hud(_mode):
		_count_status.text = "拆楼需 %d 次命中" % state.building_hits
		_count_status.add_theme_color_override("font_color", WARM_GRAY)
	elif player_destroyed >= 6:
		_count_status.text = "触碰碾压已解锁  ·  %s" % scale_text
		_count_status.add_theme_color_override("font_color", CRANE_AMBER)
	elif player_destroyed >= 3:
		_count_status.text = "一击拆楼已解锁  ·  %s" % scale_text
		_count_status.add_theme_color_override("font_color", PAPER)
	else:
		_count_status.text = "剩余 %d 栋  ·  身高 %s" % [total - destroyed, scale_text]
		_count_status.add_theme_color_override("font_color", WARM_GRAY)

	if state.get("giant_pinned", false):
		_stomp_gauge.set_phase("pinned", 0.0)
	elif not String(state.get("sit_action", "")).is_empty():
		_stomp_gauge.set_phase(
			"sit_" + String(state.sit_action), float(state.get("sit_progress", 0.0))
		)
	elif state.giant_grabbed:
		_stomp_gauge.set_phase("grabbed", 0.0)
	elif not state.hand_action.is_empty():
		_stomp_gauge.set_phase(state.hand_action, state.hand_action_progress)
	else:
		_stomp_gauge.set_phase(state.stomp, state.stomp_progress)
	if _has_growth_hud(_mode):
		_update_growth_hud(state)
	elif _is_giant:
		_stomp_gauge.visible = not state.giant_respawning
		if state.giant_respawning:
			_count_status.text = "倒下了 · %.1f 秒后复活" % state.giant_respawn_in
			_count_status.add_theme_color_override("font_color", SIGNAL_RED)
	if _touch_enabled and _is_giant:
		var can_stomp: bool = state.get("can_demolish", true) and not state.giant_respawning and not state.giant_grabbed and state.hand_action.is_empty()
		if _touch.can_stomp != can_stomp:
			_touch.can_stomp = can_stomp
			_touch.queue_redraw()
		var sitting := not String(state.get("sit_action", "")).is_empty()
		if _touch.sitting != sitting:
			_touch.sitting = sitting
			_touch.queue_redraw()

	if state.has("exit_distance"):
		var dist: float = float(state.exit_distance)
		var angle: float = float(state.exit_angle)
		_evac_compass.set_target(angle, dist)
		_evac_dist_num.text = "%02d" % roundi(dist)
		if dist <= 15.0:
			_evac_sub.text = "即将抵达撤离圈"
			_evac_sub.add_theme_color_override("font_color", EVAC_GREEN)
			_evac_dist_num.add_theme_color_override("font_color", EVAC_GREEN)
		else:
			_evac_sub.text = "港区撤离点"
			_evac_sub.add_theme_color_override("font_color", WARM_GRAY)
			_evac_dist_num.add_theme_color_override("font_color", PAPER)


func announce_growth_defeats(messages: Array[Dictionary]) -> void:
	for event in messages:
		var message := "%s 被更大的人类撞倒" % event.victim
		if event.has("attacker"):
			message = "%s  %s  %s" % [event.attacker, DEFEAT_ACTIONS[event.method], event.victim]
		var row := ChamferBox.new()
		row.fill_color = Color(CHARCOAL, 0.9)
		row.accent_color = SIGNAL_RED if event.player_defeated else (CRANE_AMBER if event.player_attack else DIM_GRAY)
		row.chamfer = 6.0
		row.set_padding(12, 5, 14, 5)
		row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		row.add_child(_label(message, 20 if _touch_enabled else 16, PAPER, _font_bold))
		_defeat_feed.add_child(row)
		_defeat_feed.move_child(row, 0)
		if _defeat_feed.get_child_count() > DEFEAT_FEED_LIMIT:
			var oldest := _defeat_feed.get_child(-1)
			_defeat_feed.remove_child(oldest)
			oldest.queue_free()
		var fade := row.create_tween().set_pause_mode(Tween.TWEEN_PAUSE_STOP)
		fade.tween_interval(4.5)
		fade.tween_property(row, "modulate:a", 0.0, 0.5)
		fade.tween_callback(row.queue_free)


func _set_hud_keys() -> void:
	if _touch_enabled:
		return
	var flying := _player == PlayerRole.SPECTATOR
	var bindings := [["WASD", "飞行" if flying else "移动"], ["鼠标 / 方向键", "环视"]]
	if _is_giant:
		bindings.append(["V", "切换视角"])
		bindings.append(["SPACE", "踩踏"])
		bindings.append(["Q", "捡起捏碎"])
		bindings.append(["E", "挥拳"])
	elif not flying:
		bindings.append(["SHIFT", "疾跑"])
	if _has_growth_hud(_mode):
		bindings.append(["TAB", "排名"])
	bindings.append(["ESC", "暂停"])
	_hud_keys.set_bindings(bindings, CRANE_AMBER if _is_giant else EVAC_GREEN)


func _format_height(meters: float) -> String:
	return ("%.2f 厘米" % (meters * 100.0)) if meters < 1.0 else ("%.2f 米" % meters)


func _refresh_growth_ranking() -> void:
	_ranking_refresh_in = 0.15
	var entries: Array[Dictionary] = _ranking_round.call("growth_leaderboard")
	if _touch_enabled:
		for entry in entries:
			if entry.is_player:
				_touch.set_player_rank(entry.rank)
				if _ranking_expanded:
					var position_text := "第 %d 名" % entry.rank if entry.rank > 0 else "复活中"
					_touch_ranking_player.text = "%s · %s" % [entry.name, position_text]
				break
		if not _ranking_expanded:
			return
	for entry in entries:
		entry["size_text"] = _format_height(entry.height) if entry.rank > 0 else "复活中"
	if _ranking_table.set_entries(entries, _ranking_expanded):
		if _touch_enabled:
			_fit_touch_ranking.call_deferred()
		else:
			_fit_growth_ranking.call_deferred()


func _open_touch_ranking() -> void:
	if _ranking_round == null or _ranking_expanded:
		return
	_play_ui(&"ui_click")
	_ranking_expanded = true
	_touch.set_ranking_open(true)
	_refresh_growth_ranking()
	_fit_touch_ranking()
	_touch_ranking_scroll.scroll_vertical = 0
	_touch_ranking_layer.show()


func dismiss_ranking() -> bool:
	if not _touch_enabled or not _touch_ranking_layer.visible:
		return false
	_play_ui(&"ui_back")
	_ranking_expanded = false
	_touch_ranking_layer.hide()
	_touch.set_ranking_open(false)
	return true


func _fit_touch_ranking() -> void:
	_ranking_box.custom_minimum_size.x = minf(640.0, _root.size.x - 24.0)
	_touch_ranking_scroll.custom_minimum_size.y = minf(
		_ranking_table.custom_minimum_size.y, maxf(0.0, _root.size.y - 156.0))


func _fit_growth_ranking() -> void:
	var frame_height := _ranking_box.get_combined_minimum_size().y - _desktop_ranking_scroll.get_combined_minimum_size().y
	var available := maxf(0.0, _root.size.y - _ranking_box.offset_top - frame_height - 24.0)
	var table_size := _ranking_table.custom_minimum_size
	if table_size.y > available:
		table_size.x += _desktop_ranking_scroll.get_v_scroll_bar().get_combined_minimum_size().x
	table_size.y = minf(table_size.y, available)
	_desktop_ranking_scroll.custom_minimum_size = table_size
	var minimum := _ranking_box.get_combined_minimum_size()
	_ranking_box.offset_left = -28 - minimum.x
	_ranking_box.offset_right = -28
	_ranking_box.offset_bottom = _ranking_box.offset_top + minimum.y


func _update_growth_hud(state: Dictionary) -> void:
	var hits: int = state.giant_hits
	if hits > _last_giant_hits:
		if _hit_marker_tween and _hit_marker_tween.is_valid():
			_hit_marker_tween.kill()
		_giant_hit_marker.modulate.a = 1.0
		_hit_marker_tween = create_tween().set_pause_mode(Tween.TWEEN_PAUSE_STOP)
		_hit_marker_tween.tween_property(_giant_hit_marker, "modulate:a", 0.0, 0.27)
	elif hits < _last_giant_hits:
		_giant_hit_marker.modulate.a = 0.0
	_last_giant_hits = hits
	var health: float = float(state.giant_health)
	var max_health: float = float(state.giant_max_health)
	var ratio := health / max_health
	if ratio < _giant_hp_ratio - 0.001:
		_damage_flash = 0.92
	elif ratio > _giant_hp_ratio:
		_damage_flash = 0.0
	_giant_hp_ratio = ratio
	_giant_health.value = ratio
	_growth_height.text = "身高 %s" % _format_height(state.giant_height)
	if state.giant_at_max_height:
		_growth_height.text += "（上限）"
	elif state.growth_band_locked:
		_growth_height.text += "（档位已满）"
	_growth_stats.text = "生命 %.0f / %.0f  ·  攻击 %.0f" % [health, max_health, state.giant_attack]
	var can_attack: bool = state.can_attack
	var can_demolish: bool = state.can_demolish
	_demo_hud.visible = can_demolish
	if _stomp_gauge.visible != can_attack:
		_stomp_gauge.visible = can_attack
	if state.giant_respawning:
		_growth_status.text = "倒下了 · %.1f 秒后复活" % state.giant_respawn_in
		_growth_coins.text = "击倒 %d  ·  存活 %d/%d" % [state.giant_kills, state.giants_alive, state.giant_count]
	elif _mode == BRAWL_MODE:
		_growth_status.text = "击倒巨人增加身高"
		_growth_coins.text = "金币 %d  ·  击倒 %d  ·  存活 %d/%d" % [state.coins_collected, state.giant_kills, state.giants_alive, state.giant_count]
	elif can_demolish:
		_growth_status.text = "巨人形态 · 踩踏、抓取并拆楼"
		_growth_coins.text = "金币 %d  ·  击倒 %d  ·  存活 %d/%d" % [state.coins_collected, state.giant_kills, state.giants_alive, state.giant_count]
	else:
		_growth_status.text = "人类形态 · 长到 %s 后变成巨人" % _format_height(state.attack_height)
		_growth_coins.text = "金币 %d  ·  击倒 %d  ·  %.1f 秒后刷新" % [state.coins_collected, state.giant_kills, state.coin_refresh_in]
	_evac_panel.visible = state.has("coin_distance")
	if _evac_panel.visible:
		var distance: float = float(state.coin_distance)
		_evac_compass.set_target(float(state.coin_angle), distance)
		_evac_sub.text = "最近金币"
		if distance < 1.0:
			_evac_dist_num.text = "%.2f" % (distance * 100.0)
			_evac_dist_unit.text = "厘米"
		elif distance < 100.0:
			_evac_dist_num.text = "%.1f" % distance
			_evac_dist_unit.text = "米"
		else:
			_evac_dist_num.text = "%.0f" % distance
			_evac_dist_unit.text = "米"
		_evac_dist_num.add_theme_color_override("font_color", CRANE_AMBER)


# ---------------------------------------------------------------------------
# Font setup
# ---------------------------------------------------------------------------

func _build_fonts() -> void:
	if _touch_enabled:
		var bundled := preload("res://assets/fonts/harbor-ui.otf")
		_font_regular = _mobile_font(bundled, 450)
		_font_medium = _mobile_font(bundled, 550)
		_font_bold = _mobile_font(bundled, 700)
		_font_heavy = _mobile_font(bundled, 900)
		_font_mono = _font_medium
		_font_mono_bold = _font_bold
		_font_title = _mobile_font(bundled, 900)
		_font_tag = _mobile_font(bundled, 700)
	else:
		_font_regular = _sys_font(FONT_SANS, 400)
		_font_medium = _sys_font(FONT_SANS, 500)
		_font_bold = _sys_font(FONT_SANS, 700)
		_font_heavy = _sys_font(FONT_SANS, 900)
		_font_mono = _sys_font(FONT_MONO, 500)
		_font_mono_bold = _sys_font(FONT_MONO, 700)
		_font_title = FontVariation.new()
		_font_title.base_font = _font_heavy
		_font_tag = FontVariation.new()
		_font_tag.base_font = _font_mono_bold
	_font_title.spacing_glyph = 5
	_font_tag.spacing_glyph = 2


func _mobile_font(font: Font, weight: int) -> FontVariation:
	var variation := FontVariation.new()
	variation.base_font = font
	variation.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
	return variation


func _sys_font(names: Array, weight: int) -> SystemFont:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(names)
	f.font_weight = weight
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	return f


# ---------------------------------------------------------------------------
# Menu Screen (Editorial Poster + Live Harbor Viewfinder)
# ---------------------------------------------------------------------------

func _build_menu() -> void:
	_menu = _layer()

	# Warm cinema scrim: keeps the sunlit 3D harbor crisp and open on the right,
	# darkens the left editorial column with subtle film grain and edge vignette.
	var backdrop := ColorRect.new()
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = """
		shader_type canvas_item;
		float hash12(vec2 p) {
			vec3 p3 = fract(vec3(p.xyx) * 0.1031);
			p3 += dot(p3, p3.yzx + 33.33);
			return fract((p3.x + p3.y) * p3.z);
		}
		void fragment() {
			float left_scrim = 0.84 * (1.0 - smoothstep(0.06, 0.56, UV.x));
			vec2 centered = UV - vec2(0.5);
			float vignette = smoothstep(0.42, 0.92, length(centered * vec2(1.15, 1.35))) * 0.42;
			float bottom_fade = smoothstep(0.76, 1.0, UV.y) * 0.38;
			float grain = (hash12(floor(FRAGCOORD.xy)) - 0.5) * 0.022;
			float alpha = clamp(max(left_scrim, vignette) + bottom_fade * 0.55, 0.0, 0.90);
			vec3 ink = vec3(0.055, 0.062, 0.072) + vec3(grain);
			COLOR = vec4(ink, alpha);
		}
	"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	backdrop.material = mat
	_menu.add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_full_bleed.append(backdrop)

	# Delicate optical viewfinder corners framing the live 3D harbor preview.
	var frame := ViewfinderFrame.new()
	_menu.add_child(frame)
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Left title and mode selectors, centered as the number of choices changes.
	_menu_stack = CenterContainer.new()
	_menu_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(_menu_stack)
	_menu_stack.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	_menu_stack.offset_left = 74
	_menu_stack.offset_right = 516
	var column := _column(0)
	column.custom_minimum_size.x = 442
	_menu_stack.add_child(column)

	_harbor_ribbon = _column(14)
	column.add_child(_harbor_ribbon)
	var alert_row := HBoxContainer.new()
	alert_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	alert_row.add_theme_constant_override("separation", 10)
	_harbor_ribbon.add_child(alert_row)
	alert_row.add_child(_pill_tag("紧急警报", SIGNAL_RED, HOT_WHITE))
	var sector := _label("临港工业区  ·  第四街区", 14, WARM_GRAY, _font_medium)
	sector.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	alert_row.add_child(sector)
	_add_spacer(_harbor_ribbon, 0)

	# Bold industrial print title.
	_menu_title = _label("Scalebreaker", MENU_TITLE_MAX, PAPER, _font_title)
	_menu_title.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.55))
	_menu_title.add_theme_constant_override("shadow_offset_x", 0)
	_menu_title.add_theme_constant_override("shadow_offset_y", 5)
	column.add_child(_menu_title)

	_add_spacer(column, 8)

	# Crisp thin hazard accent bar under title.
	var rule_row := HBoxContainer.new()
	rule_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule_row.add_theme_constant_override("separation", 8)
	column.add_child(rule_row)

	_menu_rule = HazardStripe.new()
	_menu_rule.custom_minimum_size = Vector2(72, 6)
	rule_row.add_child(_menu_rule)

	var rule_line := ColorRect.new()
	rule_line.color = Color(PAPER, 0.20)
	rule_line.custom_minimum_size = Vector2(0, 2)
	rule_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule_line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rule_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule_row.add_child(rule_line)

	_add_spacer(column, 24)

	_front_choices = _column(12)
	column.add_child(_front_choices)
	_harbor_entry = _add_mode_entry(
		_front_choices, &"HarborEntry", "", "港区模式", "人类撤离、巨人沙盒、成长模式、大乱斗",
		SIGNAL_RED, _show_menu_page.bind(MenuPage.HARBOR)
	)
	_bedroom_entry = _add_mode_entry(
		_front_choices, &"BedroomEntry", "", "微缩卧室", "以一厘米身高探索房间",
		BEDROOM_BLUE, _show_menu_page.bind(MenuPage.BEDROOM)
	)

	_harbor_choices = _column(8)
	column.add_child(_harbor_choices)
	_harbor_choices.hide()
	_primary_mode = _add_mode_entry(
		_harbor_choices, &"HumanMode", "01", "人类撤离",
		"躲避巨人，抵达东南撤离点" if _touch_enabled else "避开巨人追击与踩踏，穿越街道抵达东南撤离点",
		EVAC_GREEN, func(): _game.call("start_mode", false)
	)
	_add_mode_entry(
		_harbor_choices, &"SandboxMode", "02", "巨人沙盒",
		"踩踏拆楼，在港区自由探索" if _touch_enabled else "踏平摩天港区、货运码头与石化油库，在废墟间自由漫游",
		CRANE_AMBER, func(): _game.call("start_mode", true)
	)
	_growth_entry = _add_mode_entry(
		_harbor_choices, &"GrowthMode", "03", "成长模式", "人类成长、旁观者与人类观察",
		CRANE_AMBER, _show_menu_page.bind(MenuPage.GROWTH)
	)
	_add_mode_entry(
		_harbor_choices, &"BrawlMode", "04", "大乱斗", "巨人对战，击倒对手增加身高",
		CRANE_AMBER, func(): _game.call("start_brawl")
	)
	for entry: Control in _harbor_choices.get_children():
		entry.custom_minimum_size.y = 76
	_add_menu_back(_harbor_choices, &"HarborBack", "返回主菜单", MenuPage.MAIN)

	_growth_choices = _column(12)
	column.add_child(_growth_choices)
	_growth_choices.hide()
	_growth_play = _add_mode_entry(
		_growth_choices, &"GrowthGiant", "", "成长模式", "捡金币从人类长成巨人，拆楼并与其他角色对战",
		CRANE_AMBER, func(): _game.call("start_growth")
	)
	_add_mode_entry(
		_growth_choices, &"GrowthSpectator", "", "旁观者模式", "自由飞行，观察巨人",
		CRANE_AMBER, func(): _game.call("start_growth_spectator")
	)
	_add_mode_entry(
		_growth_choices, &"GrowthHuman", "", "人类模式", "在港区街道上近距离观看",
		EVAC_GREEN, func(): _game.call("start_growth_human")
	)
	_add_menu_back(_growth_choices, &"GrowthBack", "返回港区菜单", MenuPage.HARBOR)

	_bedroom_choices = _column(12)
	column.add_child(_bedroom_choices)
	_bedroom_choices.hide()
	_bedroom_play = _add_mode_entry(
		_bedroom_choices, &"BedroomPlay", "", "进入卧室", "移动、环视与攀爬",
		BEDROOM_BLUE, _open_bedroom
	)
	_add_menu_back(_bedroom_choices, &"BedroomMenuBack", "返回主菜单", MenuPage.MAIN)
	_bedroom_status = _label("无法加载卧室场景，请重试。", 15, SIGNAL_RED, _font_bold)
	_bedroom_status.hide()
	_bedroom_choices.add_child(_bedroom_status)

	# Top-right live harbor surveillance badge.
	_menu_cam_badge = _build_camera_badge()
	_menu.add_child(_menu_cam_badge)
	_menu_cam_badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_menu_cam_badge.offset_right = -34
	_menu_cam_badge.offset_left = -152
	_menu_cam_badge.offset_top = 30
	_menu_cam_badge.offset_bottom = 62
	var settings_button := TacticalButton.new()
	settings_button.name = "MenuSettings"
	settings_button.setup_action("玩法设置", WARM_GRAY, _font_bold)
	settings_button.mouse_entered.connect(_play_ui.bind(&"ui_hover"))
	settings_button.pressed.connect(func():
		_play_ui(&"ui_click")
		_open_settings(settings_button)
	)
	_menu.add_child(settings_button)
	settings_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	settings_button.offset_left = -184
	settings_button.offset_right = -34
	settings_button.offset_top = 78
	settings_button.offset_bottom = 126

	# Bottom-left controls for the harbor modes.
	if _touch_enabled:
		_harbor_keys = _label("左下拖动移动  ·  右侧滑动环视", 19, PAPER, _font_medium)
	else:
		var keys := KeycapBar.new()
		keys.setup(_font_mono_bold, _font_medium)
		keys.set_bindings([
			["WASD", "移动"],
			["鼠标 / 方向键", "环视"],
			["ESC", "暂停"],
		], PAPER)
		_harbor_keys = keys
	_menu.add_child(_harbor_keys)
	_harbor_keys.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_harbor_keys.offset_left = 74
	_harbor_keys.offset_bottom = -28
	_harbor_keys.offset_top = -60


func _add_mode_entry(parent: VBoxContainer, node_name: StringName, number: String,
		title: String, description: String, accent: Color, action: Callable) -> TacticalButton:
	var button := TacticalButton.new()
	button.name = node_name
	button.setup_mode(number, title, description, accent, _font_bold, _font_regular, _font_mono_bold, _touch_enabled)
	button.mouse_entered.connect(_play_ui.bind(&"ui_hover"))
	button.pressed.connect(func():
		_play_ui(&"ui_click")
		action.call()
	)
	parent.add_child(button)
	return button


func _add_menu_back(parent: VBoxContainer, node_name: StringName, title: String, page: MenuPage) -> void:
	var button := TacticalButton.new()
	button.name = node_name
	button.setup_action(title, WARM_GRAY, _font_bold)
	button.mouse_entered.connect(_play_ui.bind(&"ui_hover"))
	button.pressed.connect(func():
		_play_ui(&"ui_back")
		_show_menu_page(page)
	)
	parent.add_child(button)


## The brand is Latin and much wider than the CJK page names, so the big title shrinks to
## fit the 442 px menu column instead of overflowing the panel.
func _set_menu_title(text: String) -> void:
	_menu_title.text = text
	var font := _menu_title.get_theme_font(&"font")
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, MENU_TITLE_MAX).x
	var size := MENU_TITLE_MAX
	if width > MENU_TITLE_WIDTH:
		size = maxi(MENU_TITLE_MIN, int(MENU_TITLE_MAX * MENU_TITLE_WIDTH / width))
	_menu_title.add_theme_font_size_override(&"font_size", size)


func _show_menu_page(page: MenuPage) -> void:
	var from_bedroom := _menu_page == MenuPage.BEDROOM
	var from_growth := _menu_page == MenuPage.GROWTH
	_menu_page = page
	var harbor := page == MenuPage.HARBOR
	var bedroom := page == MenuPage.BEDROOM
	_front_choices.visible = page == MenuPage.MAIN
	_harbor_choices.visible = harbor
	_growth_choices.visible = page == MenuPage.GROWTH
	_harbor_ribbon.visible = harbor
	_harbor_keys.visible = harbor
	_bedroom_choices.visible = bedroom
	_menu_rule.set_colors(BEDROOM_BLUE if bedroom else SIGNAL_RED, Color(CHARCOAL, 0.0))
	match page:
		MenuPage.MAIN:
			_set_menu_title("Scalebreaker")
			var entry := _bedroom_entry if from_bedroom else _harbor_entry
			entry.grab_focus()
		MenuPage.HARBOR:
			_set_menu_title("Scalebreaker")
			var entry := _growth_entry if from_growth else _primary_mode
			entry.grab_focus()
		MenuPage.GROWTH:
			_set_menu_title("成长模式")
			_growth_play.grab_focus()
		MenuPage.BEDROOM:
			_set_menu_title("微缩卧室")
			_bedroom_play.grab_focus()


func _open_bedroom() -> void:
	_bedroom_status.hide()
	var result := get_tree().change_scene_to_file("res://scenes/GirlBedroom.tscn")
	if result != OK:
		_bedroom_status.show()
		push_error("Unable to open the bedroom: %s" % error_string(result))


func _build_camera_badge() -> Control:
	var box := ChamferBox.new()
	box.fill_color = Color(CHARCOAL, 0.72)
	box.accent_color = Color(PAPER, 0.24)
	box.accent_width = 2.0
	box.chamfer = 8.0
	box.set_padding(12, 6, 14, 6)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)

	_menu_cam_dot = ColorRect.new()
	_menu_cam_dot.color = SIGNAL_RED
	_menu_cam_dot.custom_minimum_size = Vector2(7, 7)
	_menu_cam_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_menu_cam_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_menu_cam_dot)

	var lbl := _label("港区总览", 13, Color(PAPER, 0.90), _font_medium)
	row.add_child(lbl)
	return box


# ---------------------------------------------------------------------------
# In-Game HUD (Minimal, High-Contrast, Mode-Distinct Tactical Instruments)
# ---------------------------------------------------------------------------

func _build_hud() -> void:
	_hud = _layer()
	_giant_hit_marker = _label("×", 29, HOT_WHITE, _font_bold)
	_giant_hit_marker.name = "GiantHitMarker"
	_giant_hit_marker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_giant_hit_marker.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_giant_hit_marker.add_theme_color_override("font_outline_color", CHARCOAL)
	_giant_hit_marker.add_theme_constant_override("outline_size", 4)
	_giant_hit_marker.modulate.a = 0.0
	_hud.add_child(_giant_hit_marker)
	_giant_hit_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_full_bleed.append(_giant_hit_marker)

	# Radial cinema hit-flash & low-health tension vignette (keeps center crisp).
	_vignette = ColorRect.new()
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v_shader := Shader.new()
	v_shader.code = """
		shader_type canvas_item;
		uniform float hit_flash : hint_range(0.0, 1.0) = 0.0;
		uniform float danger_pulse : hint_range(0.0, 1.0) = 0.0;
		void fragment() {
			vec2 d = (UV - vec2(0.5)) * vec2(1.45, 1.25);
			float edge = smoothstep(0.38, 0.92, length(d));
			float red_a = edge * clamp(hit_flash * 0.72 + danger_pulse * 0.42, 0.0, 0.82);
			vec3 col = mix(vec3(0.58, 0.07, 0.04), vec3(0.88, 0.16, 0.09), hit_flash);
			COLOR = vec4(col, red_a);
		}
	"""
	_vignette_mat = ShaderMaterial.new()
	_vignette_mat.shader = v_shader
	_vignette.material = _vignette_mat
	_hud.add_child(_vignette)
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_full_bleed.append(_vignette)

	# --- HUMAN MODE: Top-Left Vitality & Stamina ---
	var human_box := ChamferBox.new()
	human_box.fill_color = Color(CHARCOAL, 0.80)
	human_box.accent_color = EVAC_GREEN
	human_box.accent_width = 3.5
	human_box.chamfer = 10.0
	human_box.set_padding(16, 11, 18, 13)
	_hud.add_child(human_box)
	human_box.offset_left = 28
	human_box.offset_top = 24
	human_box.custom_minimum_size = Vector2(236, 0)
	_human_hud = human_box

	var h_col := _column(9)
	human_box.add_child(h_col)

	h_col.add_child(_label("人类撤离", 13, EVAC_GREEN, _font_bold))

	var hp_row := HBoxContainer.new()
	hp_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_row.add_theme_constant_override("separation", 10)
	h_col.add_child(hp_row)
	var hp_lbl := _label("生命", 13, WARM_GRAY, _font_medium)
	hp_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_row.add_child(hp_lbl)
	_health_meter = HealthMeter.new()
	_health_meter.custom_minimum_size = Vector2(148, 17)
	_health_meter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hp_row.add_child(_health_meter)

	var stam_row := HBoxContainer.new()
	stam_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stam_row.add_theme_constant_override("separation", 10)
	h_col.add_child(stam_row)
	var st_lbl := _label("体力", 13, WARM_GRAY, _font_medium)
	st_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	stam_row.add_child(st_lbl)
	_stamina_gauge = StaminaGauge.new()
	_stamina_gauge.custom_minimum_size = Vector2(148, 12)
	_stamina_gauge.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stamina_gauge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stam_row.add_child(_stamina_gauge)

	# --- HUMAN MODE: Top-Right Maritime Evacuation Compass ---
	_evac_panel = ChamferBox.new()
	_evac_panel.fill_color = Color(CHARCOAL, 0.80)
	_evac_panel.accent_color = EVAC_GREEN
	_evac_panel.accent_width = 3.0
	_evac_panel.accent_right = true
	_evac_panel.chamfer = 10.0
	_evac_panel.set_padding(14, 9, 16, 9)
	_hud.add_child(_evac_panel)
	_evac_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_evac_panel.offset_top = 24
	_evac_panel.offset_right = -28
	_evac_panel.offset_left = -236

	var evac_row := HBoxContainer.new()
	evac_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	evac_row.add_theme_constant_override("separation", 13)
	_evac_panel.add_child(evac_row)

	_evac_compass = EvacCompass.new()
	_evac_compass.custom_minimum_size = Vector2(50, 50)
	evac_row.add_child(_evac_compass)

	var evac_info := _column(1)
	evac_info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	evac_row.add_child(evac_info)
	_evac_sub = _label("港区撤离点", 12, WARM_GRAY, _font_medium)
	evac_info.add_child(_evac_sub)

	var dist_row := HBoxContainer.new()
	dist_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dist_row.add_theme_constant_override("separation", 4)
	evac_info.add_child(dist_row)
	_evac_dist_num = _label("00", 28, PAPER, _font_mono_bold)
	dist_row.add_child(_evac_dist_num)
	_evac_dist_unit = _label("米", 14, EVAC_GREEN, _font_bold)
	_evac_dist_unit.size_flags_vertical = Control.SIZE_SHRINK_END
	dist_row.add_child(_evac_dist_unit)

	# --- GIANT MODE: Top-Left Heavy Demolition Counter + Stomp Instrument ---
	var giant_stack := _column(10)
	_hud.add_child(giant_stack)
	giant_stack.offset_left = 28
	giant_stack.offset_top = 24
	giant_stack.custom_minimum_size = Vector2(248, 0)
	_giant_hud = giant_stack

	var growth_box := ChamferBox.new()
	growth_box.fill_color = Color(CHARCOAL, 0.82)
	growth_box.accent_color = CRANE_AMBER
	growth_box.accent_width = 3.5
	growth_box.chamfer = 10.0
	growth_box.set_padding(16, 10, 18, 12)
	giant_stack.add_child(growth_box)
	_growth_hud = growth_box
	var growth_col := _column(7)
	growth_box.add_child(growth_col)
	_growth_height = _label("", 20, CRANE_AMBER, _font_bold)
	growth_col.add_child(_growth_height)
	_growth_stats = _label("", 14, PAPER, _font_bold)
	growth_col.add_child(_growth_stats)
	_giant_health = ProgressBar.new()
	_giant_health.name = "GiantHealth"
	_giant_health.max_value = 1.0
	_giant_health.step = 0.0
	_giant_health.show_percentage = false
	_giant_health.custom_minimum_size.y = 8
	_giant_health.add_theme_stylebox_override("background", _settings_style(SLATE, SLATE))
	_giant_health.add_theme_stylebox_override("fill", _settings_style(SIGNAL_RED, SIGNAL_RED))
	growth_col.add_child(_giant_health)
	_growth_status = _label("", 13, CRANE_AMBER, _font_bold)
	growth_col.add_child(_growth_status)
	_growth_coins = _label("", 13, WARM_GRAY, _font_medium)
	growth_col.add_child(_growth_coins)

	var demo_box := ChamferBox.new()
	demo_box.fill_color = Color(CHARCOAL, 0.82)
	demo_box.accent_color = CRANE_AMBER
	demo_box.accent_width = 3.5
	demo_box.chamfer = 10.0
	demo_box.set_padding(16, 10, 18, 12)
	giant_stack.add_child(demo_box)
	_demo_hud = demo_box

	var d_col := _column(6)
	demo_box.add_child(d_col)

	d_col.add_child(_label("已摧毁建筑", 13, CRANE_AMBER, _font_bold))

	var num_row := HBoxContainer.new()
	num_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	num_row.add_theme_constant_override("separation", 6)
	d_col.add_child(num_row)

	_count_num = _label("00", 38, PAPER, _font_mono_bold)
	num_row.add_child(_count_num)
	_count_total = _label("/ 12", 18, DIM_GRAY, _font_mono)
	_count_total.size_flags_vertical = Control.SIZE_SHRINK_END
	num_row.add_child(_count_total)

	_building_matrix = BuildingMatrix.new()
	_building_matrix.custom_minimum_size = Vector2(204, 14)
	_building_matrix.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	d_col.add_child(_building_matrix)

	_count_status = _label("剩余目标  12 栋", 12, WARM_GRAY, _font_medium)
	d_col.add_child(_count_status)

	# Stomp tactical state bar directly beneath demolition card.
	_stomp_gauge = StompGauge.new()
	_stomp_gauge.setup(_font_bold, _font_mono_bold, _touch_enabled)
	_stomp_gauge.custom_minimum_size = Vector2(248, 40)
	giant_stack.add_child(_stomp_gauge)

	_defeat_feed = _column(4)
	_defeat_feed.name = "GrowthDefeatFeed"
	_hud.add_child(_defeat_feed)
	_defeat_feed.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_defeat_feed.offset_top = 85 if _touch_enabled else 24
	_defeat_feed.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_defeat_feed.hide()

	if _touch_enabled:
		_build_touch_ranking()
	else:
		_build_growth_ranking()
		# Bottom keycaps are specific to the keyboard controls.
		_hud_keys = KeycapBar.new()
		_hud_keys.setup(_font_mono_bold, _font_medium)
		_hud.add_child(_hud_keys)
		_hud_keys.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
		_hud_keys.offset_bottom = -18
		_hud_keys.offset_top = -50
		_hud_keys.grow_horizontal = Control.GROW_DIRECTION_BOTH


func _build_growth_ranking() -> void:
	_ranking_box = ChamferBox.new()
	_ranking_box.name = "GrowthRanking"
	_ranking_box.fill_color = Color(CHARCOAL, 0.91)
	_ranking_box.accent_right = true
	_ranking_box.set_padding(14, 10, 14, 12)
	_hud.add_child(_ranking_box)
	_ranking_box.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_ranking_box.offset_left = -28
	_ranking_box.offset_right = -28
	_ranking_box.offset_top = 106
	_ranking_box.offset_bottom = 106
	_ranking_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_ranking_box.hide()

	var content := _column(6)
	_ranking_box.add_child(content)
	content.add_child(_label("身高排名", 16, CRANE_AMBER, _font_bold))
	_desktop_ranking_scroll = ScrollContainer.new()
	_desktop_ranking_scroll.name = "DesktopRankingScroll"
	_desktop_ranking_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(_desktop_ranking_scroll)
	_add_ranking_table(_desktop_ranking_scroll)
	_root.resized.connect(_fit_growth_ranking)


func _build_touch_ranking() -> void:
	_touch_ranking_layer = _layer()
	_touch_ranking_layer.name = "TouchRanking"
	_touch_ranking_layer.hide()
	var veil := ColorRect.new()
	veil.color = Color(CHARCOAL, 0.67)
	_touch_ranking_layer.add_child(veil)
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_full_bleed.append(veil)

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_touch_ranking_layer.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ranking_box = ChamferBox.new()
	_ranking_box.name = "GrowthRanking"
	_ranking_box.fill_color = Color(CHARCOAL, 0.97)
	_ranking_box.accent_width = 0
	_ranking_box.set_padding(18, 12, 18, 16)
	center.add_child(_ranking_box)
	var content := _column(10)
	_ranking_box.add_child(content)

	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_theme_constant_override("separation", 14)
	content.add_child(header)
	var title := _column(2)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(title)
	title.add_child(_label("身高排名", 28, CRANE_AMBER, _font_bold))
	_touch_ranking_player = _label("", 22, PAPER, _font_medium)
	_touch_ranking_player.name = "PersonalRank"
	title.add_child(_touch_ranking_player)
	var close := Button.new()
	close.name = "CloseRanking"
	close.text = "关闭"
	close.custom_minimum_size = Vector2(124, 88)
	close.add_theme_font_override("font", _font_bold)
	close.add_theme_font_size_override("font_size", 24)
	close.add_theme_stylebox_override("normal", _settings_style(IRON, WARM_GRAY))
	close.add_theme_stylebox_override("hover", _settings_style(SLATE, PAPER))
	close.add_theme_stylebox_override("pressed", _settings_style(CRANE_AMBER.darkened(0.72), CRANE_AMBER))
	close.pressed.connect(dismiss_ranking)
	header.add_child(close)

	_touch_ranking_scroll = TouchRankScroll.new()
	_touch_ranking_scroll.name = "RankingScroll"
	_touch_ranking_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_touch_ranking_scroll.get_v_scroll_bar().custom_minimum_size.x = 12
	content.add_child(_touch_ranking_scroll)
	_add_ranking_table(_touch_ranking_scroll)


func _add_ranking_table(parent: Container) -> void:
	_ranking_table = GrowthRankTable.new()
	_ranking_table.name = "RankRows"
	_ranking_table.label_font = _font_medium
	_ranking_table.number_font = _font_mono_bold
	_ranking_table.touch_layout = _touch_enabled
	_ranking_table.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(_ranking_table)


# ---------------------------------------------------------------------------
# Pause & Result Modal (Civil Defense Dispatch Card)
# ---------------------------------------------------------------------------

func _build_modal() -> void:
	_modal = _layer()

	# Cinema dark scrim that stops clicks behind modal.
	var veil := ColorRect.new()
	veil.color = Color(0.045, 0.052, 0.062, 0.72)
	veil.mouse_filter = Control.MOUSE_FILTER_STOP
	_modal.add_child(veil)
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_full_bleed.append(veil)

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_modal.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var card := ChamferBox.new()
	card.fill_color = Color("#15181c", 0.96)
	card.accent_color = Color(PAPER, 0.14)
	card.accent_width = 1.5
	card.chamfer = 16.0
	card.set_padding(0, 0, 0, 0)
	card.custom_minimum_size = Vector2(420, 0)
	center.add_child(card)
	_modal_card = card

	var outer := _column(0)
	card.add_child(outer)

	_modal_stripe = HazardStripe.new()
	_modal_stripe.set_colors(CRANE_AMBER, CHARCOAL)
	_modal_stripe.custom_minimum_size = Vector2(0, 8)
	outer.add_child(_modal_stripe)

	var pad := MarginContainer.new()
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_theme_constant_override("margin_left", 28)
	pad.add_theme_constant_override("margin_right", 28)
	pad.add_theme_constant_override("margin_top", 22)
	pad.add_theme_constant_override("margin_bottom", 26)
	outer.add_child(pad)

	var content := _column(8)
	pad.add_child(content)

	_modal_kicker = _label("", 13, CRANE_AMBER, _font_bold)
	content.add_child(_modal_kicker)

	_modal_title = _label("", 38, PAPER, _font_heavy)
	content.add_child(_modal_title)

	_modal_text = _label("", 15, WARM_GRAY, _font_regular)
	_modal_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_modal_text)

	var divider := ColorRect.new()
	divider.color = Color(PAPER, 0.12)
	divider.custom_minimum_size = Vector2(0, 1)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_add_spacer(content, 4)
	content.add_child(divider)

	_modal_stat = _label("", 14, PAPER, _font_medium)
	content.add_child(_modal_stat)

	_add_spacer(content, 10)

	_resume_button = TacticalButton.new()
	_resume_button.setup_action("继续游戏", EVAC_GREEN, _font_bold)
	_resume_button.mouse_entered.connect(_play_ui.bind(&"ui_hover"))
	_resume_button.pressed.connect(func(): _game.call("resume"))
	content.add_child(_resume_button)

	_primary_modal = TacticalButton.new()
	_primary_modal.setup_action("重开当前模式", CRANE_AMBER, _font_bold)
	_primary_modal.mouse_entered.connect(_play_ui.bind(&"ui_hover"))
	_primary_modal.pressed.connect(func():
		_play_ui(&"ui_click")
		_game.call("restart")
	)
	content.add_child(_primary_modal)

	_pause_settings_button = TacticalButton.new()
	_pause_settings_button.name = "PauseSettings"
	_pause_settings_button.setup_action("玩法设置", WARM_GRAY, _font_bold)
	_pause_settings_button.mouse_entered.connect(_play_ui.bind(&"ui_hover"))
	_pause_settings_button.pressed.connect(func():
		_play_ui(&"ui_click")
		_open_settings(_pause_settings_button)
	)
	content.add_child(_pause_settings_button)

	_menu_button = TacticalButton.new()
	_menu_button.setup_action("返回港区菜单", WARM_GRAY, _font_bold)
	_menu_button.mouse_entered.connect(_play_ui.bind(&"ui_hover"))
	_menu_button.pressed.connect(func():
		_play_ui(&"ui_back")
		_game.call("show_menu")
	)
	content.add_child(_menu_button)


func _build_settings() -> void:
	_settings_panel = _layer()
	_settings_panel.name = "GameplaySettings"
	_settings_panel.hide()
	var veil := ColorRect.new()
	veil.color = Color(0.045, 0.052, 0.062, 0.78)
	_settings_panel.add_child(veil)
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_full_bleed.append(veil)

	var center := CenterContainer.new()
	_settings_center = center
	_settings_panel.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var card := ChamferBox.new()
	card.name = "SettingsCard"
	card.custom_minimum_size.x = 640
	card.fill_color = Color("#15181c", 0.98)
	card.accent_width = 0.0
	card.chamfer = 15.0
	card.set_padding(26, 21, 26, 21)
	center.add_child(card)
	var content := _column(10)
	card.add_child(content)
	_settings_heading = _label("设置", 31, PAPER, _font_heavy)
	content.add_child(_settings_heading)

	# Two pages: pictures/sound are global, gameplay rules are stored per mode.
	var page_row := HBoxContainer.new()
	page_row.add_theme_constant_override("separation", 8)
	content.add_child(page_row)
	var page_choices := ButtonGroup.new()
	for page in [SettingsSchema.PAGE_GRAPHICS, SettingsSchema.PAGE_GAMEPLAY]:
		var tab := Button.new()
		tab.name = "SettingsPageGraphics" if page == SettingsSchema.PAGE_GRAPHICS else "SettingsPageGameplay"
		tab.text = SettingsSchema.PAGE_GRAPHIC_TITLE if page == SettingsSchema.PAGE_GRAPHICS else SettingsSchema.PAGE_GAMEPLAY_TITLE
		tab.custom_minimum_size.y = 52 if _touch_enabled else 39
		tab.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.toggle_mode = true
		tab.button_group = page_choices
		tab.add_theme_font_override("font", _font_bold)
		tab.add_theme_stylebox_override("normal", _settings_style(IRON, SLATE))
		tab.add_theme_stylebox_override("hover", _settings_style(SLATE, WARM_GRAY))
		tab.add_theme_stylebox_override("pressed", _settings_style(CRANE_AMBER.darkened(0.78), CRANE_AMBER))
		tab.add_theme_stylebox_override("hover_pressed", _settings_style(CRANE_AMBER.darkened(0.73), CRANE_AMBER))
		tab.add_theme_stylebox_override("focus", _settings_style(Color.TRANSPARENT, HOT_WHITE))
		tab.pressed.connect(func():
			_play_ui(&"ui_click")
			_select_settings_page(page)
		)
		page_row.add_child(tab)
		_settings_page_tabs.append(tab)

	# --- Gameplay page: mode tabs + collapsible groups ------------------------
	var gameplay := VBoxContainer.new()
	gameplay.add_theme_constant_override("separation", 8)
	content.add_child(gameplay)
	_settings_page_views[SettingsSchema.PAGE_GAMEPLAY] = gameplay
	var tabs := HBoxContainer.new()
	_settings_tab_row = tabs
	tabs.add_theme_constant_override("separation", 8)
	gameplay.add_child(tabs)
	var choices := ButtonGroup.new()
	for mode in MODE_NAMES.size():
		var tab := Button.new()
		tab.name = ["HumanSettingsTab", "GiantSettingsTab", "GrowthSettingsTab", "BrawlSettingsTab"][mode]
		tab.text = MODE_NAMES[mode]
		tab.custom_minimum_size.y = 52 if _touch_enabled else 39
		tab.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.toggle_mode = true
		tab.button_group = choices
		tab.add_theme_font_override("font", _font_bold)
		var accent := EVAC_GREEN if mode == 0 else CRANE_AMBER
		tab.add_theme_stylebox_override("normal", _settings_style(IRON, SLATE))
		tab.add_theme_stylebox_override("hover", _settings_style(SLATE, WARM_GRAY))
		tab.add_theme_stylebox_override("pressed", _settings_style(accent.darkened(0.78), accent))
		tab.add_theme_stylebox_override("hover_pressed", _settings_style(accent.darkened(0.73), accent))
		tab.add_theme_stylebox_override("focus", _settings_style(Color.TRANSPARENT, HOT_WHITE))
		tab.pressed.connect(func():
			_play_ui(&"ui_click")
			_select_settings_mode(mode)
		)
		tabs.add_child(tab)
		_settings_tabs.append(tab)

	_settings_scroll = _settings_scroller()
	gameplay.add_child(_settings_scroll)
	var gameplay_rows := _column(6)
	gameplay_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_scroll.add_child(gameplay_rows)
	_settings_row_host[SettingsSchema.PAGE_GAMEPLAY] = gameplay_rows

	# --- Graphics page: audio + display, set once for every mode --------------
	var graphics := VBoxContainer.new()
	graphics.add_theme_constant_override("separation", 8)
	graphics.visible = false
	content.add_child(graphics)
	_settings_page_views[SettingsSchema.PAGE_GRAPHICS] = graphics
	_settings_graphics_scroll = _settings_scroller()
	graphics.add_child(_settings_graphics_scroll)
	var graphics_rows := _column(6)
	graphics_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_graphics_scroll.add_child(graphics_rows)
	_settings_row_host[SettingsSchema.PAGE_GRAPHICS] = graphics_rows

	_build_settings_options()

	_settings_note = _label("「下局」的项在下一局生效，「立即」的项保存后马上生效。点行尾的 ? 看说明。",
			14, WARM_GRAY, _font_regular)
	_settings_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_settings_note.custom_minimum_size.y = 25
	content.add_child(_settings_note)

	var actions := HBoxContainer.new()
	_settings_actions = actions
	actions.add_theme_constant_override("separation", 8)
	content.add_child(actions)
	var reset := _settings_action(actions, "恢复本页默认", "ResetSettings", WARM_GRAY)
	reset.pressed.connect(func():
		_play_ui(&"ui_click")
		_reset_settings_page()
	)
	var cancel := _settings_action(actions, "取消", "CancelSettings", WARM_GRAY)
	cancel.pressed.connect(dismiss_settings.bind(true))
	var save := _settings_action(actions, "保存设置", "SaveSettings", CRANE_AMBER)
	save.pressed.connect(_save_settings)


func _settings_scroller() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 385
	scroll.scroll_deadzone = 12 if _touch_enabled else 0
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	return scroll


func _build_settings_options() -> void:
	for option in SettingsSchema.page_options(SettingsSchema.PAGE_GRAPHICS):
		_build_settings_option(_settings_row_host[SettingsSchema.PAGE_GRAPHICS], option)
	var host: VBoxContainer = _settings_row_host[SettingsSchema.PAGE_GAMEPLAY]
	for group in SettingsSchema.GROUPS:
		var id: String = String(group["id"])
		var header := Button.new()
		header.name = "SettingsGroup" + id.capitalize()
		header.text = "▾  " + String(group["title"])
		header.alignment = HORIZONTAL_ALIGNMENT_LEFT
		header.custom_minimum_size.y = 40 if _touch_enabled else 30
		header.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		header.add_theme_font_override("font", _font_bold)
		header.add_theme_color_override("font_color", CRANE_AMBER)
		header.add_theme_stylebox_override("normal", _settings_style(IRON, SLATE))
		header.add_theme_stylebox_override("hover", _settings_style(SLATE, WARM_GRAY))
		header.add_theme_stylebox_override("pressed", _settings_style(IRON, CRANE_AMBER))
		header.pressed.connect(func():
			_play_ui(&"ui_click")
			_toggle_settings_group(id)
		)
		host.add_child(header)
		var body := _column(4)
		host.add_child(body)
		_settings_groups[id] = {"header": header, "body": body}
		_settings_group_open[id] = true
		_settings_advanced_open[id] = false
		if id == "growth":
			_growth_settings_rows = body
		# Common rows first, then a collapsed 「高级」 section holding the rest.
		for option in SettingsSchema.page_options(SettingsSchema.PAGE_GAMEPLAY):
			if String(option.get("group", "")) != id or bool(option.get("advanced", false)):
				continue
			_build_settings_option(body, option)
		var advanced_header := Button.new()
		advanced_header.name = "SettingsAdvanced" + id.capitalize()
		advanced_header.text = "▸  高级"
		advanced_header.alignment = HORIZONTAL_ALIGNMENT_LEFT
		advanced_header.custom_minimum_size.y = 34 if _touch_enabled else 26
		advanced_header.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		advanced_header.add_theme_font_override("font", _font_regular)
		advanced_header.add_theme_color_override("font_color", WARM_GRAY)
		advanced_header.add_theme_stylebox_override("normal", _settings_style(Color.TRANSPARENT, SLATE))
		advanced_header.add_theme_stylebox_override("hover", _settings_style(SLATE, WARM_GRAY))
		advanced_header.add_theme_stylebox_override("pressed", _settings_style(IRON, WARM_GRAY))
		advanced_header.pressed.connect(func():
			_play_ui(&"ui_click")
			_toggle_settings_advanced(id)
		)
		body.add_child(advanced_header)
		var advanced_body := _column(2)
		advanced_body.visible = false
		body.add_child(advanced_body)
		_settings_groups[id]["advanced_header"] = advanced_header
		_settings_groups[id]["advanced_body"] = advanced_body
		for option in SettingsSchema.page_options(SettingsSchema.PAGE_GAMEPLAY):
			if String(option.get("group", "")) != id or not bool(option.get("advanced", false)):
				continue
			_build_settings_option(advanced_body, option)


func _build_settings_option(host: VBoxContainer, option: Dictionary) -> void:
	var key: String = String(option["key"])
	var row := HBoxContainer.new()
	row.name = "SettingsRow" + key.capitalize()
	row.custom_minimum_size.y = 52 if _touch_enabled else 37
	row.add_theme_constant_override("separation", 10)
	host.add_child(row)
	var label := _label(String(option["label"]), 16, PAPER, _font_medium)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var hint_button := Button.new()
	hint_button.text = "?"
	hint_button.flat = true
	hint_button.tooltip_text = String(option.get("hint", ""))
	hint_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	hint_button.add_theme_color_override("font_color", WARM_GRAY)
	hint_button.pressed.connect(func():
		_play_ui(&"ui_click")
		_toggle_settings_hint(key)
	)
	row.add_child(hint_button)
	row.add_child(_settings_badge(String(option.get("apply", SettingsSchema.APPLY_LIVE))))
	if String(option.get("kind", "number")) == "toggle":
		_add_setting_toggle(row, option)
	else:
		_add_number_setting(row, option)
	var hint := _label(String(option.get("hint", "")), 13, WARM_GRAY, _font_regular)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.visible = false
	host.add_child(hint)
	_settings_rows[key] = row
	_settings_hints[key] = hint


func _settings_badge(text: String) -> Label:
	var badge := _label(text, 12, WARM_GRAY, _font_regular)
	badge.custom_minimum_size.x = 52
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return badge


func _toggle_settings_hint(key: String) -> void:
	_settings_hint_open[key] = not bool(_settings_hint_open.get(key, false))
	if _settings_hints.has(key):
		_settings_hints[key].visible = bool(_settings_hint_open[key])


func _toggle_settings_group(id: String) -> void:
	_settings_group_open[id] = not bool(_settings_group_open.get(id, true))
	_apply_settings_group_state(id)


func _toggle_settings_advanced(id: String) -> void:
	_settings_advanced_open[id] = not bool(_settings_advanced_open.get(id, false))
	_apply_settings_group_state(id)


func _apply_settings_group_state(id: String) -> void:
	if not _settings_groups.has(id):
		return
	var entry: Dictionary = _settings_groups[id]
	var open: bool = bool(_settings_group_open.get(id, true))
	entry["body"].visible = open
	entry["header"].text = ("▾  " if open else "▸  ") + SettingsSchema.group_title(id)
	var advanced_open: bool = bool(_settings_advanced_open.get(id, false))
	entry["advanced_body"].visible = advanced_open
	entry["advanced_header"].text = ("▾  高级" if advanced_open else "▸  高级")
	_refresh_settings_visibility()


func _settings_row(rows: VBoxContainer, title: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = 52 if _touch_enabled else 37
	row.add_theme_constant_override("separation", 14)
	rows.add_child(row)
	var label := _label(title, 16, PAPER, _font_medium)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	return row


func _add_setting_toggle(row: HBoxContainer, option: Dictionary) -> void:
	var key: String = String(option["key"])
	var button := CheckButton.new()
	button.name = SettingsSchema.node_name(option)
	button.text = "关闭"
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.toggled.connect(func(enabled: bool):
		button.text = "开启" if enabled else "关闭"
		_play_ui(&"ui_click")
		_refresh_settings_visibility()
	)
	row.add_child(button)
	_settings_flags[key] = button
	if key == "npc_respawn":
		_settings_respawn = button
	if key == "audio_muted":
		_settings_audio_muted = button


func _add_number_setting(row: HBoxContainer, option: Dictionary) -> void:
	var key: String = String(option["key"])
	var integer: bool = bool(option.get("integer", false))
	var spin := SpinBox.new()
	spin.name = SettingsSchema.node_name(option)
	spin.set_meta(&"setting_label", String(option["label"]))
	spin.allow_lesser = true
	spin.allow_greater = true
	spin.step = 1.0 if integer else 0.0
	spin.custom_arrow_step = float(option.get("step", 1.0))
	spin.suffix = String(option.get("suffix", ""))
	spin.custom_minimum_size = Vector2(178, 50) if _touch_enabled else Vector2(155, 34)
	spin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	spin.get_line_edit().select_all_on_focus = true
	var edit := spin.get_line_edit()
	if _touch_enabled:
		edit.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER if integer else LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL
	edit.add_theme_stylebox_override("normal", _settings_style(IRON, SLATE))
	edit.add_theme_stylebox_override("focus", _settings_style(Color.TRANSPARENT, CRANE_AMBER))
	edit.add_theme_stylebox_override("read_only", _settings_style(CHARCOAL, SLATE))
	edit.add_theme_color_override("font_color", PAPER)
	edit.add_theme_color_override("font_selected_color", HOT_WHITE)
	edit.add_theme_color_override("selection_color", Color("#65542d"))
	row.add_child(spin)
	_settings_fields[key] = spin
	if not integer:
		spin.value_changed.connect(func(_value: float): _format_setting.call_deferred(spin))
		edit.focus_exited.connect(func(): _format_setting.call_deferred(spin))
	if String(option.get("scope", "")) == "audio":
		spin.value_changed.connect(func(_value: float): _preview_audio_settings())


func _format_setting(spin: SpinBox) -> void:
	var edit := spin.get_line_edit()
	if edit.has_focus() or spin.step != 0.0:
		return
	var number := String.num_scientific(spin.value)
	if spin.localize_numeral_system:
		number = TextServerManager.get_primary_interface().format_number(number)
	edit.text = number + (" " + spin.suffix if not spin.suffix.is_empty() else "")
	edit.caret_column = 0


func _settings_style(fill: Color, edge: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = edge
	style.set_border_width_all(1)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	return style


func _settings_action(row: HBoxContainer, title: String, node_name: String, accent: Color) -> TacticalButton:
	var button := TacticalButton.new()
	button.name = node_name
	button.setup_action(title, accent, _font_bold)
	button.mouse_entered.connect(_play_ui.bind(&"ui_hover"))
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(button)
	return button


func _open_settings(opener: Control) -> void:
	_settings_return_focus = opener
	_settings_drafts.clear()
	for mode in MODE_NAMES.size():
		_settings_drafts.append(_game.call("get_mode_settings", mode))
	_saved_audio_settings = _game.call("get_audio_settings")
	_audio_draft = _saved_audio_settings.duplicate()
	_settings_mode = GROWTH_MODE if _screen == "menu" and _menu_page == MenuPage.GROWTH else _mode
	var source: Dictionary = _settings_drafts[_settings_mode]
	var defaults: Dictionary = _game.call("default_mode_settings", _settings_mode)
	_display_draft = {
		"view_distance": float(source.get("view_distance", defaults.get("view_distance", 300.0))),
		"shake_strength": float(source.get("shake_strength", defaults.get("shake_strength", 1.0))),
		"own_camera_shake": bool(source.get("own_camera_shake", true)),
	}
	_settings_page = SettingsSchema.PAGE_GAMEPLAY
	_show_settings_page(_settings_page)
	_load_settings_fields(_settings_drafts[_settings_mode])
	_load_audio_fields(_saved_audio_settings)
	_load_display_fields(_display_draft)
	_sync_settings_tabs()
	_menu.hide()
	_modal.hide()
	_settings_panel.show()
	if _touch_enabled:
		_fit_settings(0, true)
	_settings_tabs[_settings_mode].grab_focus()


func dismiss_settings(play_back := false) -> bool:
	if not _settings_panel.visible:
		return false
	if play_back:
		_play_ui(&"ui_back")
		var audio := _audio()
		if audio != null:
			audio.call("apply_audio_settings", float(_saved_audio_settings.sfx_volume),
					float(_saved_audio_settings.ambience_volume), bool(_saved_audio_settings.audio_muted))
	_settings_panel.hide()
	if _touch_enabled and DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		DisplayServer.virtual_keyboard_hide()
	_menu.visible = _screen == "menu"
	_modal.visible = _screen == "paused"
	_settings_return_focus.grab_focus()
	return true


func _fit_mobile_root() -> void:
	var viewport := get_viewport()
	var area := viewport.get_visible_rect()
	var safe := area
	if OS.has_feature("android"):
		var window_to_canvas := viewport.get_screen_transform().affine_inverse()
		var reported := Rect2(DisplayServer.get_display_safe_area())
		var in_canvas := area.intersection(window_to_canvas * reported)
		if in_canvas.has_area():
			safe = in_canvas
	_root.offset_left = maxf(24.0, safe.position.x - area.position.x)
	_root.offset_top = maxf(12.0, safe.position.y - area.position.y)
	_root.offset_right = -maxf(24.0, area.end.x - safe.end.x)
	_root.offset_bottom = -maxf(18.0, area.end.y - safe.end.y)
	for element in _full_bleed:
		element.offset_left = -_root.offset_left
		element.offset_top = -_root.offset_top
		element.offset_right = -_root.offset_right
		element.offset_bottom = -_root.offset_bottom
	var keyboard := DisplayServer.virtual_keyboard_get_height() if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD) else 0
	_fit_settings(keyboard, true)
	_fit_touch_ranking.call_deferred()


func _notification(what: int) -> void:
	if _touch_enabled and is_node_ready() and what == NOTIFICATION_APPLICATION_RESUMED:
		_fit_mobile_root.call_deferred()


func _fit_settings(keyboard_height: int, force := false) -> void:
	if not force and keyboard_height == _keyboard_height:
		return
	_keyboard_height = keyboard_height
	var overlap := 0.0
	if keyboard_height > 0:
		var top_pixels := DisplayServer.screen_get_size().y - keyboard_height
		var from_screen := get_viewport().get_screen_transform().affine_inverse()
		var keyboard_y := (from_screen * Vector2(0, top_pixels)).y
		overlap = maxf(0.0, _root.get_global_rect().end.y - keyboard_y)
	var compact := overlap > 0.0
	_settings_center.offset_bottom = -overlap
	_settings_heading.visible = not compact
	_settings_tab_row.visible = not compact
	_settings_note.visible = not compact
	_settings_actions.visible = not compact
	var reserved := 62.0 if compact else 236.0
	_settings_scroll.custom_minimum_size.y = clampf(_root.size.y - overlap - reserved, 52.0, 385.0)
	var focused := get_viewport().gui_get_focus_owner()
	if compact and is_instance_valid(focused) and _settings_scroll.is_ancestor_of(focused):
		_settings_scroll.ensure_control_visible.call_deferred(focused)


func _sample_frame_times() -> void:
	var now := Time.get_ticks_usec()
	var elapsed := now - _last_frame_usec
	var has_previous := _last_frame_usec > 0
	_last_frame_usec = now
	if not has_previous:
		return
	_frame_times.append(elapsed / 1000.0)
	_perf_elapsed += elapsed / 1_000_000.0
	if _perf_elapsed < 5.0:
		return
	_frame_times.sort()
	var frames := _frame_times.size()
	var p95 := _frame_times[ceili(frames * 0.95) - 1]
	print("[Harbor] frame mode=%d fps=%.1f p95_ms=%.1f max_ms=%.1f" %
		[_mode, frames / _perf_elapsed, p95, _frame_times[frames - 1]])
	_frame_times.clear()
	_perf_elapsed = 0.0


func _log_first_menu_frame() -> void:
	print("[Harbor] first_menu_frame engine_ms=%d" % Time.get_ticks_msec())


func _select_settings_page(page: String) -> void:
	if page == _settings_page:
		return
	_capture_settings_page()
	_settings_page = page
	_show_settings_page(page)
	_load_settings_fields(_settings_drafts[_settings_mode])
	_load_audio_fields(_audio_draft)
	_load_display_fields(_display_draft)


func _show_settings_page(page: String) -> void:
	for key in _settings_page_views:
		_settings_page_views[key].visible = key == page
	for index in _settings_page_tabs.size():
		_settings_page_tabs[index].set_pressed_no_signal(index == (0 if page == SettingsSchema.PAGE_GRAPHICS else 1))
	_settings_tab_row.visible = page == SettingsSchema.PAGE_GAMEPLAY
	if _settings_note != null:
		_settings_note.text = "「下局」的项在下一局生效，「立即」的项保存后马上生效。点行尾的 ? 看说明。"
		_settings_note.add_theme_color_override("font_color", WARM_GRAY)


func _capture_settings_page() -> void:
	if _settings_page == SettingsSchema.PAGE_GRAPHICS:
		_audio_draft = _capture_audio_fields()
		_display_draft = _capture_display_fields()
	else:
		_settings_drafts[_settings_mode] = _capture_settings_fields()


func _select_settings_mode(mode: int) -> void:
	if mode != _settings_mode:
		_settings_drafts[_settings_mode] = _capture_settings_fields()
		_settings_mode = mode
		_load_settings_fields(_settings_drafts[mode])
	_sync_settings_tabs()


func _sync_settings_tabs() -> void:
	for index in _settings_tabs.size():
		_settings_tabs[index].set_pressed_no_signal(index == _settings_mode)


func _load_settings_fields(values: Dictionary) -> void:
	var defaults: Dictionary = _game.call("default_mode_settings", _settings_mode)
	for option in SettingsSchema.page_options(SettingsSchema.PAGE_GAMEPLAY):
		var key: String = String(option["key"])
		if String(option.get("kind", "number")) == "toggle":
			if _settings_flags.has(key):
				var pressed: bool = bool(values.get(key, defaults.get(key, false)))
				_settings_flags[key].set_pressed_no_signal(pressed)
				_settings_flags[key].text = "开启" if pressed else "关闭"
		elif _settings_fields.has(key):
			var spin: SpinBox = _settings_fields[key]
			var percent: bool = bool(option.get("percent", false))
			spin.set_value_no_signal(float(values.get(key, defaults.get(key, spin.value))) * (100.0 if percent else 1.0))
			_format_setting.call_deferred(spin)
	if _settings_fields.has("giant_height"):
		_settings_fields["giant_height"].custom_arrow_step = 0.005 if _settings_mode == GROWTH_MODE else 0.1
	_refresh_settings_visibility()
	if _settings_scroll != null:
		_settings_scroll.set_deferred("scroll_vertical", 0)


func _load_audio_fields(values: Dictionary) -> void:
	for key in ["sfx_volume", "ambience_volume"]:
		if _settings_fields.has(key) and values.has(key):
			var spin: SpinBox = _settings_fields[key]
			spin.set_value_no_signal(float(values[key]) * 100.0)
			_format_setting.call_deferred(spin)
	if _settings_audio_muted != null:
		var muted: bool = bool(values.get("audio_muted", false))
		_settings_audio_muted.set_pressed_no_signal(muted)
		_settings_audio_muted.text = "开启" if muted else "关闭"
	_refresh_settings_visibility()


func _load_display_fields(values: Dictionary) -> void:
	for key in ["view_distance", "shake_strength"]:
		if _settings_fields.has(key) and values.has(key):
			var spin: SpinBox = _settings_fields[key]
			var percent: bool = key == "shake_strength"
			spin.set_value_no_signal(float(values[key]) * (100.0 if percent else 1.0))
			_format_setting.call_deferred(spin)
	if _settings_flags.has("own_camera_shake") and values.has("own_camera_shake"):
		var enabled: bool = bool(values["own_camera_shake"])
		_settings_flags["own_camera_shake"].set_pressed_no_signal(enabled)
		_settings_flags["own_camera_shake"].text = "开启" if enabled else "关闭"
	_refresh_settings_visibility()


func _refresh_settings_visibility() -> void:
	for option in SettingsSchema.OPTIONS:
		var key: String = String(option["key"])
		if not _settings_rows.has(key):
			continue
		var visible := _option_visible(option)
		var row: Control = _settings_rows[key]
		row.visible = visible
		if _settings_hints.has(key):
			_settings_hints[key].visible = visible and bool(_settings_hint_open.get(key, false))
	if _settings_audio_muted != null:
		for key in ["sfx_volume", "ambience_volume"]:
			if _settings_fields.has(key):
				_settings_fields[key].editable = not _settings_audio_muted.button_pressed


func _option_visible(option: Dictionary) -> bool:
	if String(option.get("page", SettingsSchema.PAGE_GAMEPLAY)) != SettingsSchema.PAGE_GAMEPLAY:
		return true
	var modes: Array = option.get("modes", SettingsSchema.ALL_MODES)
	if not modes.has(_settings_mode):
		return false
	if not _settings_requires_met(option):
		return false
	if bool(option.get("advanced", false)):
		var group: String = String(option.get("group", ""))
		return bool(_settings_advanced_open.get(group, false))
	return true


func _settings_requires_met(option: Dictionary) -> bool:
	var requirement: Dictionary = option.get("requires", {})
	if requirement.is_empty():
		return true
	var modes: Array = requirement.get("modes", [])
	if not modes.is_empty() and not modes.has(_settings_mode):
		return true
	var key: String = String(requirement["key"])
	if not _settings_flags.has(key):
		return true
	return _settings_flags[key].button_pressed == bool(requirement.get("equals", true))


func _preview_audio_settings() -> void:
	var audio := _audio()
	if audio == null or _settings_panel == null or not _settings_panel.visible:
		return
	var sfx: float = _settings_fields["sfx_volume"].value / 100.0
	var amb: float = _settings_fields["ambience_volume"].value / 100.0
	var muted: bool = _settings_audio_muted != null and _settings_audio_muted.button_pressed
	audio.call("apply_audio_settings", sfx, amb, muted)


func _capture_audio_fields() -> Dictionary:
	for key in ["sfx_volume", "ambience_volume"]:
		if _settings_fields.has(key):
			var spin: SpinBox = _settings_fields[key]
			if spin.get_line_edit().has_focus():
				spin.apply()
	return {
		"sfx_volume": _settings_fields["sfx_volume"].value / 100.0,
		"ambience_volume": _settings_fields["ambience_volume"].value / 100.0,
		"audio_muted": _settings_audio_muted.button_pressed if _settings_audio_muted != null else false,
	}


func _capture_display_fields() -> Dictionary:
	for key in ["view_distance", "shake_strength"]:
		if _settings_fields.has(key):
			var spin: SpinBox = _settings_fields[key]
			if spin.get_line_edit().has_focus():
				spin.apply()
	return {
		"view_distance": _settings_fields["view_distance"].value,
		"shake_strength": _settings_fields["shake_strength"].value / 100.0,
		"own_camera_shake": _settings_flags["own_camera_shake"].button_pressed,
	}


func _capture_settings_fields() -> Dictionary:
	for spin in _settings_fields.values():
		if spin.get_line_edit().has_focus():
			spin.apply()
			break
	var values := {}
	for option in SettingsSchema.page_options(SettingsSchema.PAGE_GAMEPLAY):
		var key: String = String(option["key"])
		if not SettingsSchema.ALL_MODES.has(_settings_mode):
			continue
		var modes: Array = option.get("modes", SettingsSchema.ALL_MODES)
		if not modes.has(_settings_mode):
			continue
		if String(option.get("kind", "number")) == "toggle":
			if _settings_flags.has(key):
				values[key] = _settings_flags[key].button_pressed
		elif _settings_fields.has(key):
			var percent: bool = bool(option.get("percent", false))
			values[key] = _settings_fields[key].value / (100.0 if percent else 1.0)
	return values


func _reset_settings_page() -> void:
	if _settings_page == SettingsSchema.PAGE_GRAPHICS:
		_audio_draft = _game.call("default_audio_settings")
		_display_draft = _default_display_settings()
		_load_audio_fields(_audio_draft)
		_load_display_fields(_display_draft)
		_preview_audio_settings()
		return
	_settings_drafts[_settings_mode] = _game.call("default_mode_settings", _settings_mode)
	_load_settings_fields(_settings_drafts[_settings_mode])


func _default_display_settings() -> Dictionary:
	var defaults: Dictionary = _game.call("default_mode_settings", _settings_mode)
	return {
		"view_distance": float(defaults.get("view_distance", 300.0)),
		"shake_strength": float(defaults.get("shake_strength", 1.0)),
		"own_camera_shake": bool(defaults.get("own_camera_shake", true)),
	}


func debug_expand_settings() -> void:
	for group in SettingsSchema.GROUPS:
		var id: String = String(group["id"])
		_settings_group_open[id] = true
		_settings_advanced_open[id] = true
		_apply_settings_group_state(id)


func _save_settings() -> void:
	# Capture every page: the display/audio controls stay live while the gameplay page is open.
	_settings_drafts[_settings_mode] = _capture_settings_fields()
	_audio_draft = _capture_audio_fields()
	_display_draft = _capture_display_fields()
	for index in _settings_drafts.size():
		_settings_drafts[index].merge(_display_draft, true)
	if _game.call("save_all_settings", _settings_drafts[0], _settings_drafts[1],
			_settings_drafts[GROWTH_MODE], _settings_drafts[BRAWL_MODE], _capture_audio_fields()):
		_play_ui(&"ui_click")
		dismiss_settings(false)
		return
	_play_ui(&"ui_error")
	_show_invalid_setting(String(_game.call("invalid_setting")))


func _show_invalid_setting(key: String) -> void:
	var option := SettingsSchema.find(key)
	_settings_note.add_theme_color_override("font_color", SIGNAL_RED)
	if option.is_empty():
		_settings_note.text = "设置保存失败，请重试。"
		_settings_note.show()
		return
	var page: String = String(option.get("page", SettingsSchema.PAGE_GAMEPLAY))
	if page != _settings_page:
		_select_settings_page(page)
	var group: String = String(option.get("group", ""))
	if not group.is_empty():
		if bool(option.get("advanced", false)) and not bool(_settings_advanced_open.get(group, false)):
			_toggle_settings_advanced(group)
		if not bool(_settings_group_open.get(group, true)):
			_toggle_settings_group(group)
	_refresh_settings_visibility()
	_settings_note.text = "「%s」的取值不合法，请调整后重试。" % String(option["label"])
	_settings_note.show()
	var scroll: ScrollContainer = _settings_graphics_scroll if page == SettingsSchema.PAGE_GRAPHICS else _settings_scroll
	if _settings_rows.has(key):
		scroll.ensure_control_visible.call_deferred(_settings_rows[key])


func _animate_menu_in() -> void:
	if _menu_tween and _menu_tween.is_valid():
		_menu_tween.kill()
	_menu_stack.modulate.a = 0.0
	_menu_stack.offset_left = 54
	_menu_stack.offset_right = 496
	_menu_cam_badge.modulate.a = 0.0
	_menu_tween = create_tween().set_parallel(true)
	_menu_tween.tween_property(_menu_stack, "modulate:a", 1.0, 0.34).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_menu_tween.tween_property(_menu_stack, "offset_left", 74.0, 0.38).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_menu_tween.tween_property(_menu_stack, "offset_right", 516.0, 0.38).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_menu_tween.tween_property(_menu_cam_badge, "modulate:a", 1.0, 0.42).set_delay(0.10)


func _animate_modal_in() -> void:
	if _modal_tween and _modal_tween.is_valid():
		_modal_tween.kill()
	_modal.modulate.a = 0.0
	_modal_card.modulate.a = 0.0
	_modal_tween = create_tween().set_parallel(true)
	_modal_tween.tween_property(_modal, "modulate:a", 1.0, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_modal_tween.tween_property(_modal_card, "modulate:a", 1.0, 0.20).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# Defer scale bounce one frame so CenterContainer has finalized exact card size.
	_play_modal_pop.call_deferred()


func _play_modal_pop() -> void:
	if not _modal.visible:
		return
	_modal_card.pivot_offset = _modal_card.size * 0.5
	_modal_card.scale = Vector2(0.96, 0.96)
	var pop := create_tween()
	pop.tween_property(_modal_card, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _punch_control(ctrl: Control) -> void:
	if _count_tween and _count_tween.is_valid():
		_count_tween.kill()
	ctrl.pivot_offset = ctrl.size * 0.5
	ctrl.scale = Vector2(1.26, 1.26)
	ctrl.modulate = CRANE_AMBER
	_count_tween = create_tween().set_parallel(true)
	_count_tween.tween_property(ctrl, "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_count_tween.tween_property(ctrl, "modulate", Color.WHITE, 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


# ---------------------------------------------------------------------------
# Basic UI Builders
# ---------------------------------------------------------------------------

func _layer() -> Control:
	var c := Control.new()
	_root.add_child(c)
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _column(gap: int) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", gap)
	return col


func _label(value: String, points: int, color := PAPER, font: Font = null) -> Label:
	var lbl := Label.new()
	lbl.text = value
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_theme_font_size_override("font_size", maxi(points, 15) if _touch_enabled else points)
	lbl.add_theme_color_override("font_color", color)
	if font != null:
		lbl.add_theme_font_override("font", font)
	return lbl


func _pill_tag(text: String, bg: Color, fg: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	panel.add_theme_stylebox_override("panel", style)
	panel.add_child(_label(text, 12, fg, _font_bold))
	return panel


func _add_spacer(parent: Control, height: int) -> void:
	var sp := Control.new()
	sp.custom_minimum_size.y = height
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(sp)


# ===========================================================================
# Custom Vector UI Components
# ===========================================================================

## Industrial chamfered container with subtle top highlight & vertical accent stripe.
class TouchRankScroll extends ScrollContainer:
	var _finger := -1
	var _start_y := 0.0
	var _start_scroll := 0

	func _ready() -> void:
		visibility_changed.connect(_release_finger)
		resized.connect(_release_finger)

	func _release_finger() -> void:
		_finger = -1

	func _input(event: InputEvent) -> void:
		if not is_visible_in_tree():
			return
		var to_local := get_global_transform_with_canvas().affine_inverse()
		if event is InputEventScreenTouch:
			var at: Vector2 = to_local * event.position
			if event.index == _finger and (not event.pressed or event.canceled):
				_release_finger()
				get_viewport().set_input_as_handled()
			elif _finger == -1 and event.pressed and not event.canceled and Rect2(Vector2.ZERO, size).has_point(at):
				_finger = event.index
				_start_y = at.y
				_start_scroll = scroll_vertical
				get_viewport().set_input_as_handled()
		elif event is InputEventScreenDrag and event.index == _finger:
			var at: Vector2 = to_local * event.position
			scroll_vertical = _start_scroll + roundi(_start_y - at.y)
			get_viewport().set_input_as_handled()
		elif event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
			# Touch swipes update the scrollbar directly, including on desktops simulating touch.
			if _finger != -1 or Rect2(Vector2.ZERO, size).has_point(to_local * event.position):
				get_viewport().set_input_as_handled()


class GrowthRankTable extends Control:
	const SUMMARY_ROWS := 5
	const ROW_HEIGHT := 24
	const COLUMN_WIDTH := 214
	const COLUMN_GAP := 20

	var label_font: Font
	var number_font: Font
	var rows: Array[Dictionary] = []
	var touch_layout := false
	var _column_length := 1

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_entries(entries: Array[Dictionary], expanded: bool) -> bool:
		var shown := entries
		if not expanded and entries.size() > SUMMARY_ROWS:
			shown = entries.slice(0, SUMMARY_ROWS)
			for entry in entries.slice(SUMMARY_ROWS):
				if entry.is_player:
					shown.append(entry)
					break
		if rows == shown:
			return false
		rows = shown
		var columns := 2 if not touch_layout and rows.size() > 16 else 1
		_column_length = maxi(1, ceili(float(rows.size()) / columns))
		var minimum := Vector2(384, _row_height() * _column_length) if touch_layout else Vector2(
			COLUMN_WIDTH * columns + COLUMN_GAP * (columns - 1), ROW_HEIGHT * _column_length)
		var resized := minimum != custom_minimum_size
		custom_minimum_size = minimum
		queue_redraw()
		return resized

	func _row_height() -> int:
		return 44 if touch_layout else ROW_HEIGHT

	func _draw() -> void:
		if rows.size() > _column_length:
			var separator_x := COLUMN_WIDTH + COLUMN_GAP * 0.5
			draw_line(Vector2(separator_x, 0), Vector2(separator_x, size.y), SLATE)
		var column_width := size.x if touch_layout else float(COLUMN_WIDTH)
		var row_height := _row_height()
		var points := 23 if touch_layout else 14
		var baseline := 30 if touch_layout else 17
		var rank_x := 14 if touch_layout else 8
		var name_x := 64 if touch_layout else 37
		var right_padding := 14 if touch_layout else 8
		var measurement_width := 152 if touch_layout else 77
		var measurement_x := column_width - right_padding - measurement_width
		for i in rows.size():
			var entry := rows[i]
			var x: float = float(floori(float(i) / _column_length) * (COLUMN_WIDTH + COLUMN_GAP))
			var y: float = float(i % _column_length * row_height)
			var color := CRANE_AMBER if entry.is_player else (PAPER if entry.rank > 0 else WARM_GRAY)
			if entry.is_player:
				draw_rect(Rect2(x, y, column_width, row_height - 1), Color(CRANE_AMBER, 0.14))
				draw_rect(Rect2(x, y, 2, row_height - 1), CRANE_AMBER)
			var rank_text := str(entry.rank) if entry.rank > 0 else "–"
			var meters: String = entry.size_text
			var name_text: String = entry.name + (" · 你" if entry.is_player else "")
			draw_string(number_font, Vector2(x + rank_x, y + baseline), rank_text, HORIZONTAL_ALIGNMENT_LEFT, name_x - rank_x - 3, points, color)
			draw_string(label_font, Vector2(x + name_x, y + baseline), name_text, HORIZONTAL_ALIGNMENT_LEFT, measurement_x - name_x, points, color)
			draw_string(label_font, Vector2(x + measurement_x, y + baseline), meters, HORIZONTAL_ALIGNMENT_RIGHT, measurement_width, points, color)


class ChamferBox extends MarginContainer:
	var fill_color := Color("#111316", 0.84)
	var accent_color := Color("#eba930")
	var accent_width := 3.0
	var accent_right := false
	var chamfer := 10.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_padding(left: int, top: int, right: int, bottom: int) -> void:
		add_theme_constant_override("margin_left", left)
		add_theme_constant_override("margin_top", top)
		add_theme_constant_override("margin_right", right)
		add_theme_constant_override("margin_bottom", bottom)

	func _draw() -> void:
		var w := size.x
		var h := size.y
		if w <= 1.0 or h <= 1.0:
			return
		var c := minf(chamfer, minf(w, h) * 0.45)
		var poly: PackedVector2Array
		if accent_right:
			poly = PackedVector2Array([
				Vector2(0, 0), Vector2(w, 0), Vector2(w, h),
				Vector2(c, h), Vector2(0, h - c)
			])
		else:
			poly = PackedVector2Array([
				Vector2(0, 0), Vector2(w, 0), Vector2(w, h - c),
				Vector2(w - c, h), Vector2(0, h)
			])
		# Soft ground shadow
		var shadow_poly := PackedVector2Array()
		for pt in poly:
			shadow_poly.append(pt + Vector2(0, 3))
		draw_colored_polygon(shadow_poly, Color(0, 0, 0, 0.26))
		draw_colored_polygon(poly, fill_color)

		# Subtle industrial bevel edge
		draw_line(Vector2(0, 0.5), Vector2(w, 0.5), Color(1, 1, 1, 0.11), 1.0)
		var border := PackedVector2Array(poly)
		border.append(poly[0])
		draw_polyline(border, Color(1, 1, 1, 0.08), 1.0, true)

		# Crisp solid accent bar
		if accent_width > 0.0:
			if accent_right:
				draw_rect(Rect2(w - accent_width, 0, accent_width, h), accent_color)
			else:
				draw_rect(Rect2(0, 0, accent_width, h), accent_color)


## Diagonal 45-degree maritime hazard stripe bar.
class HazardStripe extends Control:
	var _color_a := Color("#eba930")
	var _color_b := Color("#111316")

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_contents = true

	func set_colors(a: Color, b: Color) -> void:
		_color_a = a
		_color_b = b
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		if w <= 1.0 or h <= 1.0:
			return
		draw_rect(Rect2(Vector2.ZERO, size), _color_b)
		var step := 14.0
		var stripe_w := 6.5
		var x := -h - step
		while x < w + h:
			var quad := PackedVector2Array([
				Vector2(x, h),
				Vector2(x + stripe_w, h),
				Vector2(x + stripe_w + h, 0),
				Vector2(x + h, 0),
			])
			draw_colored_polygon(quad, _color_a)
			x += step


## Minimal optical viewfinder L-brackets at viewport corners on the title screen.
class ViewfinderFrame extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var m := 22.0
		var l := 16.0
		var col := Color("#efeae0", 0.22)
		# Top-left
		draw_line(Vector2(m, m), Vector2(m + l, m), col, 1.5)
		draw_line(Vector2(m, m), Vector2(m, m + l), col, 1.5)
		# Top-right
		draw_line(Vector2(w - m, m), Vector2(w - m - l, m), col, 1.5)
		draw_line(Vector2(w - m, m), Vector2(w - m, m + l), col, 1.5)
		# Bottom-left
		draw_line(Vector2(m, h - m), Vector2(m + l, h - m), col, 1.5)
		draw_line(Vector2(m, h - m), Vector2(m, h - m - l), col, 1.5)
		# Bottom-right
		draw_line(Vector2(w - m, h - m), Vector2(w - m - l, h - m), col, 1.5)
		draw_line(Vector2(w - m, h - m), Vector2(w - m, h - m - l), col, 1.5)


## Tactile chamfered industrial button with smooth slide-in accent ribbon on hover/focus.
class TacticalButton extends BaseButton:
	var _is_mode := false
	var _accent := Color("#2ec995")
	var _hover_t := 0.0
	var _press_t := 0.0

	var _num_lbl: Label
	var _title_lbl: Label
	var _desc_lbl: Label
	var _content_box: Control

	func _init() -> void:
		focus_mode = Control.FOCUS_ALL
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		clip_contents = false

	func setup_mode(num: String, title: String, desc: String, accent: Color,
			f_title: Font, f_desc: Font, f_mono: Font, touch: bool) -> void:
		_is_mode = true
		_accent = accent
		custom_minimum_size = Vector2(0, 88)

		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override("separation", 16)
		add_child(row)
		row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		row.offset_left = 22
		row.offset_right = -44
		row.offset_top = 14
		row.offset_bottom = -12
		_content_box = row

		if not num.is_empty():
			_num_lbl = Label.new()
			_num_lbl.text = num
			_num_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_num_lbl.add_theme_font_override("font", f_mono)
			_num_lbl.add_theme_font_size_override("font_size", 15)
			_num_lbl.add_theme_color_override("font_color", accent)
			_num_lbl.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			row.add_child(_num_lbl)

		var col := VBoxContainer.new()
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 3)
		row.add_child(col)

		_title_lbl = Label.new()
		_title_lbl.text = title
		_title_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_title_lbl.add_theme_font_override("font", f_title)
		_title_lbl.add_theme_font_size_override("font_size", 24)
		_title_lbl.add_theme_color_override("font_color", Color("#efeae0"))
		col.add_child(_title_lbl)

		_desc_lbl = Label.new()
		_desc_lbl.text = desc
		_desc_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_desc_lbl.add_theme_font_override("font", f_desc)
		_desc_lbl.add_theme_font_size_override("font_size", 15 if touch else 13)
		_desc_lbl.add_theme_color_override("font_color", Color("#9ea5a8"))
		col.add_child(_desc_lbl)

	func setup_action(title: String, accent: Color, f_title: Font) -> void:
		_is_mode = false
		_accent = accent
		custom_minimum_size = Vector2(0, 48)

		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(row)
		row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		row.offset_left = 20
		row.offset_right = -34
		_content_box = row

		_title_lbl = Label.new()
		_title_lbl.text = title
		_title_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_title_lbl.add_theme_font_override("font", f_title)
		_title_lbl.add_theme_font_size_override("font_size", 17)
		_title_lbl.add_theme_color_override("font_color", Color("#efeae0"))
		_title_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(_title_lbl)

	func set_accent(accent: Color) -> void:
		_accent = accent
		if _num_lbl != null:
			_num_lbl.add_theme_color_override("font_color", accent)
		queue_redraw()

	func _process(delta: float) -> void:
		var active := is_hovered() or has_focus()
		var target_h := 1.0 if active else 0.0
		var target_p := 1.0 if button_pressed else 0.0
		var dt := minf(delta, 0.05)
		var next_h := lerpf(_hover_t, target_h, minf(dt * 16.0, 1.0))
		var next_p := lerpf(_press_t, target_p, minf(dt * 24.0, 1.0))
		if absf(next_h - _hover_t) > 0.001 or absf(next_p - _press_t) > 0.001:
			_hover_t = next_h
			_press_t = next_p
			_sync_text_style()
			queue_redraw()

	func _sync_text_style() -> void:
		if _content_box == null:
			return
		var slide := _hover_t * (8.0 if _is_mode else 5.0) - _press_t * 2.0
		_content_box.offset_left = (22.0 if _is_mode else 20.0) + slide
		if _title_lbl != null:
			_title_lbl.add_theme_color_override("font_color", Color("#efeae0").lerp(Color("#fffaf0"), _hover_t))
		if _desc_lbl != null:
			_desc_lbl.add_theme_color_override("font_color", Color("#9ea5a8").lerp(Color("#d8d4c8"), _hover_t))

	func _draw() -> void:
		var w := size.x
		var h := size.y
		if w <= 1.0 or h <= 1.0:
			return
		var c := 12.0 if _is_mode else 9.0
		var shift_x := _hover_t * (6.0 if _is_mode else 3.0) - _press_t * 2.0
		var poly := PackedVector2Array([
			Vector2(shift_x, 0),
			Vector2(w + shift_x, 0),
			Vector2(w + shift_x, h - c),
			Vector2(w + shift_x - c, h),
			Vector2(shift_x, h),
		])

		var base_bg := Color("#121519", 0.68 if _is_mode else 0.85)
		var hover_bg := Color("#1e232a", 0.94 if _is_mode else 0.98)
		var fill := base_bg.lerp(hover_bg, _hover_t)
		if _press_t > 0.05:
			fill = fill.lerp(_accent.darkened(0.68), _press_t)
		draw_colored_polygon(poly, fill)

		# Subtle warm sheen wash from the left accent bar on hover/focus
		if _hover_t > 0.01:
			var wash_w := w * 0.42 * _hover_t
			var wash := PackedVector2Array([
				Vector2(shift_x, 0),
				Vector2(shift_x + wash_w, 0),
				Vector2(shift_x + maxf(0.0, wash_w - 18.0), h),
				Vector2(shift_x, h),
			])
			draw_colored_polygon(wash, Color(_accent, 0.14 * _hover_t))

		# Hairline structural bottom rule & crisp top highlight
		var edge_col := Color(1, 1, 1, lerpf(0.09, 0.22, _hover_t))
		draw_line(Vector2(shift_x, 0.5), Vector2(w + shift_x, 0.5), edge_col, 1.0)
		draw_line(Vector2(shift_x, h - 0.5), Vector2(w + shift_x - c, h - 0.5), Color(_accent, lerpf(0.18, 0.72, _hover_t)), 1.0)

		# Left bold color flag that expands on hover/focus
		var bar_w := lerpf(3.0, 7.0 if _is_mode else 5.5, _hover_t)
		draw_rect(Rect2(shift_x, 0, bar_w, h), Color(_accent, lerpf(0.55, 1.0, _hover_t)))

		# Crisp geometric right chevron arrow (always subtle on mode cards, emerges on action hover)
		var arrow_a := lerpf(0.28, 0.98, _hover_t) if _is_mode else _hover_t * 0.92
		if arrow_a > 0.02:
			var ax := w + shift_x - (24.0 if _is_mode else 20.0) + _hover_t * 4.0
			var ay := h * 0.5
			var sz := 6.0 if _is_mode else 4.5
			draw_polyline(PackedVector2Array([
				Vector2(ax - sz + 1.0, ay - sz),
				Vector2(ax + 1.5, ay),
				Vector2(ax - sz + 1.0, ay + sz),
			]), Color(_accent, arrow_a), 2.0 if _is_mode else 1.8, true)


## Three chamfered vitality blocks with impact shake & low-health danger pulse.
class HealthMeter extends Control:
	var _health := 3
	var _flash_slot := -1
	var _flash_t := 0.0
	var _shake_t := 0.0
	var _pulse_t := 0.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func reset(hp: int) -> void:
		_health = clampi(hp, 0, 3)
		_flash_slot = -1
		_flash_t = 0.0
		_shake_t = 0.0
		queue_redraw()

	func set_health(hp: int, hurt: bool) -> void:
		hp = clampi(hp, 0, 3)
		if hurt and hp < _health:
			_flash_slot = hp
			_flash_t = 1.0
			_shake_t = 1.0
		if hp != _health:
			_health = hp
			queue_redraw()

	func tick(dt: float) -> void:
		var dirty := false
		if _flash_t > 0.0:
			_flash_t = maxf(0.0, _flash_t - dt * 2.8)
			dirty = true
		if _shake_t > 0.0:
			_shake_t = maxf(0.0, _shake_t - dt * 5.0)
			dirty = true
		if _health == 1:
			_pulse_t += dt * 5.5
			dirty = true
		if dirty:
			queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var gap := 6.0
		var skew := 5.0
		var slot_w := (w - gap * 2.0 - skew) / 3.0
		var shake_x := sin(_shake_t * 36.0) * _shake_t * 3.5

		for i in 3:
			var x := i * (slot_w + gap) + shake_x
			var quad := PackedVector2Array([
				Vector2(x + skew, 1.0),
				Vector2(x + skew + slot_w, 1.0),
				Vector2(x + slot_w, h - 1.0),
				Vector2(x, h - 1.0),
			])
			if i < _health:
				var col := Color("#efeae0")
				if _health == 1:
					var p := 0.5 + 0.5 * sin(_pulse_t)
					col = Color("#e44d2e").lerp(Color("#ff9b82"), p * 0.55)
				elif _health == 2:
					col = Color("#eba930")
				draw_colored_polygon(quad, col)
				# Subtle specular top edge
				draw_line(quad[0] + Vector2(1, 1), quad[1] + Vector2(-1, 1), Color(1, 1, 1, 0.35), 1.0)
			else:
				var empty_col := Color("#252b31", 0.78)
				if i == _flash_slot and _flash_t > 0.0:
					empty_col = empty_col.lerp(Color("#e44d2e"), _flash_t)
				draw_colored_polygon(quad, empty_col)
				var outline := PackedVector2Array(quad)
				outline.append(quad[0])
				draw_polyline(outline, Color(1, 1, 1, 0.14), 1.0, true)


## Segmented tactical stamina gauge with delayed white burn trail & low-stamina tint.
class StaminaGauge extends Control:
	var _value := 1.0
	var _trail := 1.0
	var _full_shine := 0.0
	var _was_full := true
	var _low_t := 0.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func reset(val: float) -> void:
		_value = clampf(val, 0.0, 1.0)
		_trail = _value
		_full_shine = 0.0
		_was_full = _value >= 0.999
		queue_redraw()

	func set_stamina(val: float) -> void:
		val = clampf(val, 0.0, 1.0)
		if val >= 0.999 and not _was_full:
			_full_shine = 1.0
		_was_full = val >= 0.999
		if absf(val - _value) > 0.0005:
			_value = val
			if _value > _trail:
				_trail = _value
			queue_redraw()

	func tick(dt: float) -> void:
		var dirty := false
		if _trail > _value:
			_trail = maxf(_value, _trail - dt * 0.65)
			dirty = true
		if _full_shine > 0.0:
			_full_shine = maxf(0.0, _full_shine - dt * 2.4)
			dirty = true
		if _value < 0.25:
			_low_t += dt * 7.0
			dirty = true
		if dirty:
			queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var skew := 4.0

		# Dark etched trough
		var bg := PackedVector2Array([
			Vector2(skew, 0), Vector2(w, 0), Vector2(w - skew, h), Vector2(0, h)
		])
		draw_colored_polygon(bg, Color("#1d2228", 0.92))

		# White burn trail
		if _trail > _value + 0.004:
			var tw := (w - skew) * _trail
			var trail_poly := PackedVector2Array([
				Vector2(skew, 1.0),
				Vector2(skew + tw, 1.0),
				Vector2(tw, h - 1.0),
				Vector2(0, h - 1.0),
			])
			draw_colored_polygon(trail_poly, Color("#fffaf0", 0.55))

		# Active fill
		if _value > 0.002:
			var fw := (w - skew) * _value
			var fill_poly := PackedVector2Array([
				Vector2(skew, 1.0),
				Vector2(skew + fw, 1.0),
				Vector2(fw, h - 1.0),
				Vector2(0, h - 1.0),
			])
			var fill_col := Color("#2ec995")
			if _value < 0.25:
				var blink := 0.5 + 0.5 * sin(_low_t)
				fill_col = Color("#e44d2e").lerp(Color("#eba930"), blink * 0.65)
			elif _full_shine > 0.0:
				fill_col = fill_col.lerp(Color("#fffaf0"), _full_shine * 0.5)
			draw_colored_polygon(fill_poly, fill_col)

		# Subtle quarter tick cutouts
		for seg: float in [0.25, 0.50, 0.75]:
			var sx: float = (w - skew) * seg
			draw_line(Vector2(skew + sx, 0), Vector2(sx, h), Color("#111316", 0.85), 1.6)


## Custom vector maritime compass pointing smoothly toward the evacuation beacon.
class EvacCompass extends Control:
	var _angle := 0.0
	var _display_angle := 0.0
	var _distance := 99.0
	var _initialized := false
	var _pulse := 0.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_target(angle: float, distance: float) -> void:
		_angle = angle
		_distance = distance
		if not _initialized:
			_display_angle = angle
			_initialized = true
			queue_redraw()

	func tick(dt: float) -> void:
		var prev := _display_angle
		_display_angle = lerp_angle(_display_angle, _angle, minf(dt * 12.0, 1.0))
		_pulse += dt * 3.4
		if absf(angle_difference(prev, _display_angle)) > 0.001 or _distance <= 20.0:
			queue_redraw()

	func _draw() -> void:
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.46
		var accent := Color("#2ec995")

		# Dial background
		draw_circle(center, radius, Color("#171b20", 0.92))
		draw_arc(center, radius, 0.0, TAU, 40, Color(accent, 0.32), 1.4, true)

		# Subtle 12-tick compass bezel
		for i in 12:
			var a: float = float(i) * TAU / 12.0
			var dir := Vector2(sin(a), -cos(a))
			var inner := radius - (4.5 if i % 3 == 0 else 2.5)
			var col := Color("#efeae0", 0.35 if i % 3 == 0 else 0.16)
			draw_line(center + dir * inner, center + dir * (radius - 0.5), col, 1.2, true)

		# Active heading highlight arc around target bearing
		var bearing := _display_angle - PI * 0.5
		var glow_a := 0.85
		if _distance <= 15.0:
			glow_a = 0.65 + 0.35 * (0.5 + 0.5 * sin(_pulse * 2.0))
		draw_arc(center, radius, bearing - 0.42, bearing + 0.42, 16, Color(accent, glow_a), 2.4, true)

		# Crisp directional needle (pointing up at angle=0)
		var fwd := Vector2(sin(_display_angle), -cos(_display_angle))
		var side := Vector2(fwd.y, -fwd.x)
		var tip := center + fwd * (radius - 5.5)
		var wing_l := center - fwd * 4.5 + side * 6.5
		var wing_r := center - fwd * 4.5 - side * 6.5
		var notch := center - fwd * 1.0
		draw_colored_polygon(PackedVector2Array([tip, wing_l, notch, wing_r]), accent)
		draw_circle(center, 2.2, Color("#111316"))


## 12-segment industrial destruction progress bar scaling cleanly to any city size.
class BuildingMatrix extends Control:
	var _fraction := 0.0
	var _flash_cell := -1
	var _flash_t := 0.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func reset(count: int) -> void:
		_fraction = clampf(float(count) / 12.0, 0.0, 1.0)
		_flash_cell = -1
		_flash_t = 0.0
		queue_redraw()

	func set_progress(destroyed: int, total: int, animate: bool) -> void:
		var next_frac := clampf(float(destroyed) / float(maxi(total, 1)), 0.0, 1.0)
		if animate and next_frac > _fraction:
			_flash_cell = clampi(int(floorf(next_frac * 12.0 - 0.001)), 0, 11)
			_flash_t = 1.0
		if absf(next_frac - _fraction) > 0.0005 or animate:
			_fraction = next_frac
			queue_redraw()

	func tick(dt: float) -> void:
		if _flash_t > 0.0:
			_flash_t = maxf(0.0, _flash_t - dt * 2.4)
			queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var gap := 3.5
		var skew := 2.5
		var cell_w := (w - gap * 11.0 - skew) / 12.0
		var scaled := _fraction * 12.0
		for i in 12:
			var x := i * (cell_w + gap)
			var quad := PackedVector2Array([
				Vector2(x + skew, 1.0),
				Vector2(x + skew + cell_w, 1.0),
				Vector2(x + cell_w, h - 1.0),
				Vector2(x, h - 1.0),
			])
			draw_colored_polygon(quad, Color("#242a31", 0.85))
			var fill := clampf(scaled - float(i), 0.0, 1.0)
			if fill > 0.005:
				var fw := cell_w * fill
				var fquad := PackedVector2Array([
					Vector2(x + skew, 1.0),
					Vector2(x + skew + fw, 1.0),
					Vector2(x + fw, h - 1.0),
					Vector2(x, h - 1.0),
				])
				var col := Color("#eba930")
				if i == _flash_cell and _flash_t > 0.0:
					col = col.lerp(Color("#fffaf0"), _flash_t)
				draw_colored_polygon(fquad, col)


## Dynamic stomp phase telemetry bar synced with Rust windup/impact/cooldown timings.
class StompGauge extends Control:
	var _phase := "ready"
	var _progress := 1.0
	var _impact_flash := 0.0
	var _status_lbl: Label
	var _space_key: Control

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func setup(f_label: Font, f_mono: Font, touch: bool) -> void:
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override("separation", 10)
		add_child(row)
		row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		row.offset_left = 14
		row.offset_right = -14
		row.offset_top = 4
		row.offset_bottom = -10

		if not touch:
			var key := Label.new()
			key.text = "SPACE"
			key.mouse_filter = Control.MOUSE_FILTER_IGNORE
			key.add_theme_font_override("font", f_mono)
			key.add_theme_font_size_override("font_size", 11)
			key.add_theme_color_override("font_color", Color("#111316"))
			key.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			var key_pad := PanelContainer.new()
			key_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
			key_pad.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var ks := StyleBoxFlat.new()
			ks.bg_color = Color("#eba930")
			ks.content_margin_left = 6
			ks.content_margin_right = 6
			ks.content_margin_top = 1
			ks.content_margin_bottom = 1
			key_pad.add_theme_stylebox_override("panel", ks)
			key_pad.add_child(key)
			row.add_child(key_pad)
			_space_key = key_pad

		_status_lbl = Label.new()
		_status_lbl.text = "踩踏就绪"
		_status_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_status_lbl.add_theme_font_override("font", f_label)
		_status_lbl.add_theme_font_size_override("font_size", 17 if touch else 14)
		_status_lbl.add_theme_color_override("font_color", Color("#efeae0"))
		_status_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(_status_lbl)

	func reset() -> void:
		_phase = "ready"
		_progress = 1.0
		_impact_flash = 0.0
		_update_label()
		queue_redraw()

	func set_phase(phase: String, progress: float) -> void:
		if phase == _phase and progress == _progress:
			return
		if phase != _phase:
			_phase = phase
			if phase == "impact":
				_impact_flash = 1.0
			_update_label()
		_progress = progress
		queue_redraw()

	func tick(dt: float) -> void:
		if _impact_flash > 0.0:
			_impact_flash = maxf(0.0, _impact_flash - dt * 3.0)
			queue_redraw()

	func _update_label() -> void:
		if _status_lbl == null:
			return
		if _space_key:
			_space_key.visible = _phase in ["ready", "windup", "impact", "cooldown"]
		match _phase:
			"grab_crush", "punch", "grabbed":
				_status_lbl.text = {"grab_crush": "捡起捏碎", "punch": "挥拳", "grabbed": "被抓住"}[_phase]
				_status_lbl.add_theme_color_override("font_color", Color("#eba930"))
			"sit_turn":
				_status_lbl.text = "转身对准"
				_status_lbl.add_theme_color_override("font_color", Color("#eba930"))
			"sit_drop":
				_status_lbl.text = "坐压落下"
				_status_lbl.add_theme_color_override("font_color", Color("#ff8a5b"))
			"sit_hold":
				_status_lbl.text = "坐压压实（X 起身）"
				_status_lbl.add_theme_color_override("font_color", Color("#eba930"))
			"sit_rise":
				_status_lbl.text = "起身"
				_status_lbl.add_theme_color_override("font_color", Color("#fffaf0"))
			"pinned":
				_status_lbl.text = "被坐压制服"
				_status_lbl.add_theme_color_override("font_color", Color("#e44d2e"))
			"windup":
				_status_lbl.text = "蓄力预警"
				_status_lbl.add_theme_color_override("font_color", Color("#ff8a5b"))
			"impact":
				_status_lbl.text = "重踏冲击"
				_status_lbl.add_theme_color_override("font_color", Color("#fffaf0"))
			"cooldown":
				_status_lbl.text = "重蓄冷却"
				_status_lbl.add_theme_color_override("font_color", Color("#9ea5a8"))
			_:
				_status_lbl.text = "踩踏就绪"
				_status_lbl.add_theme_color_override("font_color", Color("#efeae0"))

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var c := 8.0
		var poly := PackedVector2Array([
			Vector2(0, 0), Vector2(w, 0), Vector2(w, h - c), Vector2(w - c, h), Vector2(0, h)
		])
		var bg := Color("#111316", 0.82)
		if _impact_flash > 0.0:
			bg = bg.lerp(Color("#eba930", 0.85), _impact_flash * 0.55)
		draw_colored_polygon(poly, bg)
		draw_line(Vector2(0, 0.5), Vector2(w, 0.5), Color(1, 1, 1, 0.10), 1.0)

		# Progress bar along the lower edge
		var bar_y := h - 5.5
		var bar_h := 3.5
		var bar_w := w - c - 6.0
		draw_rect(Rect2(3.0, bar_y, bar_w, bar_h), Color("#242a31", 0.9))

		var fill_frac := 1.0
		var bar_col := Color("#eba930")
		match _phase:
			"grab_crush", "punch", "grabbed", "sit_drop", "sit_hold":
				fill_frac = _progress
			"sit_turn":
				fill_frac = 0.0
				bar_col = Color("#eba930")
			"sit_rise":
				fill_frac = 1.0 - _progress
				bar_col = Color("#fffaf0")
			"windup":
				fill_frac = _progress
				bar_col = Color("#e44d2e").lerp(Color("#eba930"), 0.5 + 0.5 * sin(_progress * 16.64))
			"impact":
				fill_frac = 1.0 - _progress
				bar_col = Color("#fffaf0").lerp(Color("#eba930"), 1.0 - _impact_flash)
			"cooldown":
				fill_frac = _progress
				bar_col = Color("#8f7848")
			_:
				fill_frac = 1.0
				bar_col = Color("#eba930")

		draw_rect(Rect2(3.0, bar_y, bar_w * fill_frac, bar_h), bar_col)
		draw_rect(Rect2(0, 0, 3.0, h), bar_col)


## Clean frameless floating row of tactile keycap badges + concise labels.
class KeycapBar extends HBoxContainer:
	var _font_mono: Font
	var _font_label: Font

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		alignment = BoxContainer.ALIGNMENT_CENTER
		add_theme_constant_override("separation", 18)

	func setup(f_mono: Font, f_label: Font) -> void:
		_font_mono = f_mono
		_font_label = f_label

	func set_bindings(pairs: Array, accent: Color) -> void:
		for child in get_children():
			remove_child(child)
			child.queue_free()

		for pair in pairs:
			var item := HBoxContainer.new()
			item.mouse_filter = Control.MOUSE_FILTER_IGNORE
			item.add_theme_constant_override("separation", 7)
			add_child(item)

			var cap := PanelContainer.new()
			cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var style := StyleBoxFlat.new()
			style.bg_color = Color("#121519", 0.82)
			style.border_color = Color(accent, 0.42)
			style.border_width_left = 1
			style.border_width_right = 1
			style.border_width_top = 1
			style.border_width_bottom = 2
			style.corner_radius_top_left = 3
			style.corner_radius_top_right = 3
			style.corner_radius_bottom_left = 3
			style.corner_radius_bottom_right = 3
			style.content_margin_left = 7
			style.content_margin_right = 7
			style.content_margin_top = 2
			style.content_margin_bottom = 2
			cap.add_theme_stylebox_override("panel", style)

			var k_lbl := Label.new()
			k_lbl.text = pair[0]
			k_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			k_lbl.add_theme_font_override("font", _font_mono)
			k_lbl.add_theme_font_size_override("font_size", 11)
			k_lbl.add_theme_color_override("font_color", Color("#efeae0"))
			cap.add_child(k_lbl)
			item.add_child(cap)

			var d_lbl := Label.new()
			d_lbl.text = pair[1]
			d_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			d_lbl.add_theme_font_override("font", _font_label)
			d_lbl.add_theme_font_size_override("font_size", 13)
			d_lbl.add_theme_color_override("font_color", Color("#efeae0", 0.84))
			d_lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
			d_lbl.add_theme_constant_override("shadow_offset_y", 1)
			d_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			item.add_child(d_lbl)
