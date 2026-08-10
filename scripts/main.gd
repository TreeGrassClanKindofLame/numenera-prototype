extends Node2D

const TurnIntentType = preload("res://scripts/model/turn_intent.gd")
const GridActorStateType = preload("res://scripts/model/grid_actor_state.gd")
const TurnResolverType = preload("res://scripts/core/turn_resolver.gd")
const DrunkControllerType = preload("res://scripts/core/drunk_controller.gd")
const CharacterViewType = preload("res://scripts/ui/character_view.gd")

const BOARD_SIZE := Vector2i(12, 8)
const CELL_SIZE := 48.0
const BOARD_ORIGIN := Vector2(24.0, 78.0)
const MOVE_DURATION := 0.12
const RNG_SEED := 1337
const ACTOR_ORDER := [&"player", &"drunk"]
const MAP_ROWS := [
	"############",
	"#P.D.#.....#",
	"#....#.....#",
	"#....#.....#",
	"#..........#",
	"#..###.....#",
	"#..........#",
	"############",
]

const COLOR_BACKGROUND := Color("111722")
const COLOR_FLOOR_A := Color("202b3a")
const COLOR_FLOOR_B := Color("243244")
const COLOR_WALL := Color("667182")
const COLOR_GRID := Color("3b4a60")
const COLOR_PANEL := Color("182231")
const COLOR_TEXT := Color("e8edf4")
const COLOR_MUTED := Color("9eabbc")
const COLOR_PLAYER := Color("4da3ff")
const COLOR_DRUNK := Color("f19a4b")

var _blocked: Dictionary = {}
var _actors: Dictionary = {}
var _actor_views: Dictionary = {}
var _turn_number := 1
var _busy := false
var _drunk_controller = DrunkControllerType.new(RNG_SEED)

var _turn_label: Label
var _status_label: Label
var _log_label: Label


func _ready() -> void:
	_parse_map()
	_ensure_input_actions()
	_build_actor_views()
	_build_interface()
	_update_interface("等待玩家输入", "尚未结算。")
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if _busy or not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return

	var player_intent = null
	if event.is_action_pressed(&"move_up"):
		player_intent = TurnIntentType.new(&"player", TurnIntentType.ActionType.MOVE, Vector2i.UP)
	elif event.is_action_pressed(&"move_down"):
		player_intent = TurnIntentType.new(&"player", TurnIntentType.ActionType.MOVE, Vector2i.DOWN)
	elif event.is_action_pressed(&"move_left"):
		player_intent = TurnIntentType.new(&"player", TurnIntentType.ActionType.MOVE, Vector2i.LEFT)
	elif event.is_action_pressed(&"move_right"):
		player_intent = TurnIntentType.new(&"player", TurnIntentType.ActionType.MOVE, Vector2i.RIGHT)
	elif event.is_action_pressed(&"wait_turn"):
		player_intent = TurnIntentType.new(&"player", TurnIntentType.ActionType.WAIT, Vector2i.ZERO)

	if player_intent == null:
		return
	get_viewport().set_input_as_handled()
	_play_turn(player_intent)


func _play_turn(player_intent) -> void:
	_busy = true
	_update_interface("正在结算第 %d 回合…" % _turn_number, _log_label.text)

	var intents: Dictionary = {
		&"player": player_intent,
		&"drunk": _drunk_controller.choose_intent(&"drunk"),
	}
	var actor_states: Array = []
	for actor_id: StringName in ACTOR_ORDER:
		var controller := &"player" if actor_id == &"player" else &"npc"
		actor_states.append(GridActorStateType.new(actor_id, _actors[actor_id], controller))

	var resolved_turn := _turn_number
	var resolution = TurnResolverType.resolve(BOARD_SIZE, _blocked, actor_states, intents)
	var turn_log := _format_turn_log(resolved_turn, intents, resolution)
	_actors = resolution.final_positions.duplicate(true)

	var tween := create_tween().set_parallel(true)
	for actor_id: StringName in ACTOR_ORDER:
		var view = _actor_views[actor_id]
		tween.tween_property(
			view,
			"position",
			_cell_to_world(_actors[actor_id]),
			MOVE_DURATION
		).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await tween.finished

	_turn_number += 1
	_busy = false
	_update_interface("等待玩家输入", turn_log)


func _parse_map() -> void:
	_blocked.clear()
	_actors.clear()
	for y in BOARD_SIZE.y:
		var row: String = MAP_ROWS[y]
		for x in BOARD_SIZE.x:
			var marker := row.substr(x, 1)
			var cell := Vector2i(x, y)
			match marker:
				"#":
					_blocked[cell] = true
				"P":
					_actors[&"player"] = cell
				"D":
					_actors[&"drunk"] = cell


func _ensure_input_actions() -> void:
	_add_key_action(&"move_up", KEY_W)
	_add_key_action(&"move_down", KEY_S)
	_add_key_action(&"move_left", KEY_A)
	_add_key_action(&"move_right", KEY_D)
	_add_key_action(&"wait_turn", KEY_R)


func _add_key_action(action: StringName, physical_keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for existing_event in InputMap.action_get_events(action):
		if existing_event is InputEventKey and existing_event.physical_keycode == physical_keycode:
			return
	var key_event := InputEventKey.new()
	key_event.physical_keycode = physical_keycode
	InputMap.action_add_event(action, key_event)


func _build_actor_views() -> void:
	for actor_id: StringName in ACTOR_ORDER:
		var view = CharacterViewType.new()
		view.name = String(actor_id).capitalize()
		view.setup(COLOR_PLAYER if actor_id == &"player" else COLOR_DRUNK)
		view.position = _cell_to_world(_actors[actor_id])
		_actor_views[actor_id] = view
		add_child(view)


func _build_interface() -> void:
	var board_title := _make_label(
		"同步回合制 · 移动验证",
		Vector2(24.0, 24.0),
		Vector2(576.0, 34.0),
		24,
		COLOR_TEXT
	)
	add_child(board_title)

	var panel_title := _make_label(
		"回合验证面板",
		Vector2(644.0, 42.0),
		Vector2(268.0, 30.0),
		22,
		COLOR_TEXT
	)
	add_child(panel_title)

	_turn_label = _make_label("", Vector2(644.0, 84.0), Vector2(268.0, 28.0), 20, COLOR_TEXT)
	add_child(_turn_label)
	_status_label = _make_label("", Vector2(644.0, 116.0), Vector2(268.0, 24.0), 15, COLOR_MUTED)
	add_child(_status_label)

	var controls := _make_label(
		"操作\nW / A / S / D　移动一格\nR　　　　　　 等待",
		Vector2(644.0, 158.0),
		Vector2(268.0, 82.0),
		15,
		COLOR_TEXT
	)
	add_child(controls)

	var legend := _make_label(
		"图例\n● 主角　蓝色\n● 酒鬼　橙色\n■ 地形阻挡　灰色",
		Vector2(644.0, 246.0),
		Vector2(268.0, 100.0),
		15,
		COLOR_TEXT
	)
	add_child(legend)

	var log_title := _make_label(
		"上一回合",
		Vector2(644.0, 356.0),
		Vector2(268.0, 24.0),
		17,
		COLOR_TEXT
	)
	add_child(log_title)
	_log_label = _make_label("", Vector2(644.0, 386.0), Vector2(268.0, 100.0), 14, COLOR_MUTED)
	_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_log_label)

	var seed_label := _make_label(
		"RNG seed: %d" % RNG_SEED,
		Vector2(644.0, 488.0),
		Vector2(268.0, 22.0),
		13,
		COLOR_MUTED
	)
	add_child(seed_label)


func _make_label(
	label_text: String,
	label_position: Vector2,
	label_size: Vector2,
	font_size: int,
	font_color: Color
) -> Label:
	var label := Label.new()
	label.text = label_text
	label.position = label_position
	label.size = label_size
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", font_color)
	return label


func _update_interface(status_text: String, log_text: String) -> void:
	_turn_label.text = "第 %d 回合" % _turn_number
	_status_label.text = status_text
	_log_label.text = log_text


func _format_turn_log(turn_index: int, intents: Dictionary, resolution) -> String:
	var lines := ["第 %d 回合" % turn_index]
	for actor_id: StringName in ACTOR_ORDER:
		var actor_name := "主角" if actor_id == &"player" else "酒鬼"
		var intent = intents[actor_id]
		var outcome: Dictionary = resolution.outcome_for(actor_id)
		var action_text := _intent_text(intent)
		var result_text := "成功" if outcome.get("success", false) else "失败"
		var reason_text := _reason_text(outcome.get("reason", &""))
		lines.append("%s：%s → %s（%s）" % [actor_name, action_text, result_text, reason_text])
	return "\n".join(lines)


func _intent_text(intent) -> String:
	if intent.action_type == TurnIntentType.ActionType.WAIT:
		return "等待"
	match intent.delta:
		Vector2i.UP:
			return "向上"
		Vector2i.DOWN:
			return "向下"
		Vector2i.LEFT:
			return "向左"
		Vector2i.RIGHT:
			return "向右"
	return "无效动作"


func _reason_text(reason: StringName) -> String:
	match reason:
		&"moved":
			return "已移动"
		&"waited":
			return "主动等待"
		&"blocked_by_terrain":
			return "地形阻挡"
		&"out_of_bounds":
			return "超出地图"
		&"target_conflict":
			return "争夺同一格"
		&"occupied_actor_not_leaving":
			return "占用者未离开"
		&"invalid_direction":
			return "无效方向"
	return "未知结果"


func _cell_to_world(cell: Vector2i) -> Vector2:
	return BOARD_ORIGIN + Vector2(cell) * CELL_SIZE + Vector2.ONE * CELL_SIZE * 0.5


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(960.0, 540.0)), COLOR_BACKGROUND)
	draw_rect(Rect2(Vector2(620.0, 24.0), Vector2(316.0, 492.0)), COLOR_PANEL)

	for y in BOARD_SIZE.y:
		for x in BOARD_SIZE.x:
			var cell := Vector2i(x, y)
			var cell_rect := Rect2(
				BOARD_ORIGIN + Vector2(cell) * CELL_SIZE,
				Vector2.ONE * CELL_SIZE
			)
			var floor_color := COLOR_FLOOR_A if (x + y) % 2 == 0 else COLOR_FLOOR_B
			draw_rect(cell_rect, COLOR_WALL if _blocked.has(cell) else floor_color)
			draw_rect(cell_rect, COLOR_GRID, false, 1.0)
