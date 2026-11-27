extends Control

signal ranking_requested
signal leave_requested

const STICK_RADIUS := 61.0
const STICK_TRAVEL := 47.0
const LOOK_GAIN := 1.65
const PAPER := Color("#efeae0")
const AMBER := Color("#eba930")
const EVAC_GREEN := Color("#2ec995")
const GROWTH_MODE := 2
const BRAWL_MODE := 3

var game: Node
var label_font: Font
var round_node: Node
var mode := 0
var bedroom_controls := false
var can_use_hands := true
var sitting := false
var sit_ready := false
var _allow_sprint := false
var _allow_giant := false
var _move_id := -1
var _look_id := -1
var _action_id := -1
var _hand_id := -1
var _hand_button := -1
var _view_id := -1
var _sit_id := -1
var _pause_id := -1
var _ranking_id := -1
var _player_rank := 0
var _stick_center := Vector2.ZERO
var _stick_motion := Vector2.ZERO
var _axes := Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(clear_input)
	hide()


func present(screen: String, new_mode: int, current_round: Node, allow_sprint: bool, allow_giant: bool) -> void:
	mode = new_mode
	round_node = current_round if screen == "playing" else null
	can_use_hands = true
	sitting = false
	sit_ready = false
	_allow_sprint = allow_sprint
	_allow_giant = allow_giant
	_player_rank = 0
	_reset_fingers()
	visible = round_node != null


func set_player_rank(rank: int) -> void:
	if _player_rank != rank:
		_player_rank = rank
		queue_redraw()


func set_ranking_open(open: bool) -> void:
	if is_instance_valid(round_node):
		_reset_fingers()
		round_node.clear_touch()
		visible = not open


func _input(event: InputEvent) -> void:
	if not visible or not is_instance_valid(round_node):
		return
	if event is InputEventScreenTouch:
		var position_local: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		if event.canceled or not event.pressed:
			_release_finger(event.index, position_local, event.canceled)
		else:
			_press_finger(event.index, position_local)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		if event.index == _move_id:
			var position_local: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
			_move_stick(position_local)
		elif event.index == _look_id:
			round_node.look(event.relative * LOOK_GAIN)
		get_viewport().set_input_as_handled()


func _press_finger(id: int, at: Vector2) -> void:
	if _pause_rect().has_point(at):
		if _pause_id == -1:
			_pause_id = id
	elif mode in [GROWTH_MODE, BRAWL_MODE] and _ranking_rect().has_point(at):
		if _ranking_id == -1:
			_ranking_id = id
	elif _allow_sprint and _action_rect().has_point(at):
		if _action_id == -1:
			_action_id = id
			_send_motion()
	elif _allow_giant and _sit_rect().has_point(at):
		if _sit_id == -1:
			_sit_id = id
	elif _allow_giant and _view_rect().has_point(at):
		if _view_id == -1:
			_view_id = id
	elif _allow_giant and (_hand_rect(0).has_point(at) or _hand_rect(1).has_point(at)):
		if _hand_id == -1:
			_hand_id = id
			_hand_button = 0 if _hand_rect(0).has_point(at) else 1
	elif at.x < size.x * 0.46:
		if _move_id == -1 and at.y >= size.y * 0.44 and Rect2(Vector2.ZERO, size).has_point(at):
			_move_id = id
			_stick_center = at
	else:
		if _look_id == -1 and Rect2(Vector2.ZERO, size).has_point(at):
			_look_id = id
	queue_redraw()


func _release_finger(id: int, at: Vector2, canceled: bool) -> void:
	if id == _move_id:
		_move_id = -1
		_stick_motion = Vector2.ZERO
		_axes = Vector2.ZERO
		_send_motion()
	elif id == _look_id:
		_look_id = -1
	elif id == _action_id:
		_action_id = -1
		_send_motion()
	elif id == _sit_id:
		_sit_id = -1
		if not canceled and _sit_rect().has_point(at):
			if sitting:
				round_node.tap_stand_up()
			elif sit_ready:
				round_node.tap_sit_down()
	elif id == _view_id:
		_view_id = -1
		if not canceled and _view_rect().has_point(at):
			round_node.toggle_view()
	elif id == _hand_id:
		if can_use_hands and not canceled and _hand_rect(_hand_button).has_point(at):
			if _hand_button == 0:
				round_node.tap_grab_crush()
			else:
				round_node.tap_punch()
		_hand_id = -1
		_hand_button = -1
	elif id == _pause_id:
		_pause_id = -1
		if not canceled and _pause_rect().has_point(at):
			if bedroom_controls:
				leave_requested.emit()
			else:
				game.pause()
	elif id == _ranking_id:
		_ranking_id = -1
		if not canceled and _ranking_rect().has_point(at):
			ranking_requested.emit()
	queue_redraw()


func _move_stick(at: Vector2) -> void:
	_stick_motion = (at - _stick_center).limit_length(STICK_TRAVEL)
	var magnitude := remap(maxf(_stick_motion.length(), 7.0), 7.0, STICK_TRAVEL, 0.0, 1.0)
	_axes = _stick_motion.normalized() * magnitude
	_send_motion()
	queue_redraw()


func _send_motion() -> void:
	round_node.set_touch_motion(_axes, _allow_sprint and _action_id != -1)


func _reset_fingers() -> void:
	_move_id = -1
	_look_id = -1
	_action_id = -1
	_hand_id = -1
	_hand_button = -1
	_view_id = -1
	_sit_id = -1
	_pause_id = -1
	_ranking_id = -1
	_stick_motion = Vector2.ZERO
	_axes = Vector2.ZERO
	queue_redraw()


func clear_input() -> void:
	_reset_fingers()
	if is_instance_valid(round_node):
		round_node.clear_touch()


func _pause_rect() -> Rect2:
	return Rect2(size.x * 0.5 - 58.0, 15.0, 116.0, 62.0)


func _action_rect() -> Rect2:
	return Rect2(size.x - 184.0, size.y - 122.0, 160.0, 96.0)


func _view_rect() -> Rect2:
	return Rect2(size.x - 164.0, size.y - 201.0, 140.0, 67.0)


func _sit_rect() -> Rect2:
	return Rect2(size.x - 317.0, size.y - 201.0, 140.0, 67.0)


func _hand_rect(index: int) -> Rect2:
	return Rect2(size.x - 317.0 + 153.0 * index, size.y - 122.0, 140.0, 96.0)


func _ranking_rect() -> Rect2:
	return Rect2(size.x - 220.0, 122.0, 192.0, 96.0)


func _draw() -> void:
	var accent := EVAC_GREEN if _allow_sprint else AMBER
	var center := _stick_center if _move_id != -1 else Vector2(109.0, size.y - 104.0)
	draw_circle(center, STICK_RADIUS, Color("#111316", 0.68), true, -1, true)
	draw_arc(center, STICK_RADIUS, 0.0, TAU, 48, Color(accent, 0.75), 2.0, true)
	draw_circle(center + _stick_motion, 24.0, Color(accent, 0.82), true, -1, true)
	_draw_button(_pause_rect(), "返回" if bedroom_controls else "暂停", PAPER, _pause_id != -1)
	if mode in [GROWTH_MODE, BRAWL_MODE]:
		var title := "排名 %d" % _player_rank if _player_rank > 0 else "排名"
		_draw_button(_ranking_rect(), title, AMBER, _ranking_id != -1)
	if _allow_giant:
		_draw_button(_view_rect(), "切换视角", PAPER, _view_id != -1)
		_draw_button(_sit_rect(), "起身" if sitting else "坐压", AMBER, _sit_id != -1, sitting or sit_ready)
		_draw_button(_hand_rect(0), "捡起捏碎", AMBER, _hand_button == 0, can_use_hands)
		_draw_button(_hand_rect(1), "挥拳", AMBER, _hand_button == 1, can_use_hands)
	if _allow_sprint:
		var action := "按住攀爬" if bedroom_controls else "按住疾跑"
		_draw_button(_action_rect(), action, accent, _action_id != -1)


func _draw_button(rect: Rect2, text: String, accent: Color, pressed: bool, enabled := true) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = accent if pressed and enabled else Color("#111316", 0.78)
	style.border_color = Color(accent, 0.8 if enabled else 0.25)
	style.set_corner_radius_all(12)
	style.set_border_width_all(2)
	style.anti_aliasing = true
	draw_style_box(style, rect)
	var points := 24
	var label_size := label_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, points)
	var baseline := rect.get_center() + Vector2(-label_size.x * 0.5,
		label_font.get_ascent(points) - label_size.y * 0.5)
	var ink := Color("#111316") if pressed and enabled else Color(PAPER, 1.0 if enabled else 0.45)
	draw_string(label_font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, points, ink)
