extends Node2D

const TurnIntentType = preload("res://scripts/model/turn_intent.gd")
const GridActorStateType = preload("res://scripts/model/grid_actor_state.gd")
const TurnResolverType = preload("res://scripts/core/turn_resolver.gd")
const DrunkControllerType = preload("res://scripts/core/drunk_controller.gd")
const CharacterViewType = preload("res://scripts/ui/character_view.gd")

const BOARD_SIZE := Vector2i(12, 8)
const CELL_SIZE := 48.0
const BOARD_ORIGIN := Vector2(24.0, 78.0)
const APPROACH_DURATION := 0.12
const COMBAT_EVENT_DURATION := 0.10
const SETTLE_DURATION := 0.12
const FAILED_MOVE_BUMP_DISTANCE := 10.0
const COLLISION_STAGING_DISTANCE := 11.0
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
	if _busy or not _actors.has(&"player") or not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return

	var player_intent = null
	if event.is_action_pressed(&"move_up"):
		player_intent = _move_intent(&"player", Vector2i.UP)
	elif event.is_action_pressed(&"move_down"):
		player_intent = _move_intent(&"player", Vector2i.DOWN)
	elif event.is_action_pressed(&"move_left"):
		player_intent = _move_intent(&"player", Vector2i.LEFT)
	elif event.is_action_pressed(&"move_right"):
		player_intent = _move_intent(&"player", Vector2i.RIGHT)
	elif event.is_action_pressed(&"wait_turn"):
		player_intent = _wait_intent(&"player")

	if player_intent == null:
		return
	get_viewport().set_input_as_handled()
	_play_turn(player_intent)


func _play_turn(player_intent) -> void:
	if _busy or not _actors.has(&"player"):
		return
	_busy = true
	_update_interface("正在结算第 %d 回合…" % _turn_number, _log_label.text)

	var intents: Dictionary = {&"player": player_intent}
	if _actors.has(&"drunk"):
		intents[&"drunk"] = _drunk_controller.choose_intent(&"drunk")

	var actor_states: Array = []
	for actor_id: StringName in _active_actor_ids():
		actor_states.append(_actors[actor_id])
		if not intents.has(actor_id):
			intents[actor_id] = _wait_intent(actor_id)

	var resolved_turn := _turn_number
	var resolution = TurnResolverType.resolve(BOARD_SIZE, _blocked, actor_states, intents)
	var turn_log := _format_turn_log(resolved_turn, intents, resolution)
	var animation_starts: Dictionary = {}
	for actor_id: StringName in _active_actor_ids():
		animation_starts[actor_id] = _actor_views[actor_id].position

	await _play_resolution_animation(animation_starts, intents, resolution)
	_actors = resolution.final_actor_states.duplicate()

	for actor_id: StringName in _active_actor_ids():
		var actor = _actors[actor_id]
		var view = _actor_views[actor_id]
		view.position = _cell_to_world(actor.cell)
		view.set_stats(actor.health, actor.max_health, actor.attack)
		view.reset_visual_state()

	_turn_number += 1
	_busy = false
	var status := "等待玩家输入" if _actors.has(&"player") else "主角已死亡，原型结束"
	_update_interface(status, turn_log)


func _play_resolution_animation(
	start_positions: Dictionary,
	intents: Dictionary,
	resolution
) -> void:
	var collision_stages := _build_collision_stages(resolution)
	var approach := create_tween()
	approach.tween_method(
		_apply_approach_animation.bind(start_positions, collision_stages, intents, resolution),
		0.0,
		1.0,
		APPROACH_DURATION
	)
	await approach.finished

	for wave_index in resolution.collision_waves.size():
		var wave: Dictionary = resolution.collision_waves[wave_index]
		await _play_collision_wave(wave)
		var next_wave: Dictionary = {}
		if wave_index + 1 < resolution.collision_waves.size():
			next_wave = resolution.collision_waves[wave_index + 1]
		await _play_wave_settle(wave, next_wave)


func _build_collision_stages(resolution) -> Dictionary:
	var stages: Dictionary = {}
	var occupancy: Dictionary = {}
	for actor_id: StringName in resolution.movement_positions:
		var cell: Vector2i = resolution.movement_positions[actor_id]
		var participants: Array = occupancy.get(cell, [])
		participants.append(actor_id)
		occupancy[cell] = participants

	# Stage every overlap created by the initial simultaneous move, even when an
	# unrelated head-on group is presented first.
	for cell: Vector2i in occupancy:
		if occupancy[cell].size() < 2:
			continue
		var collision_center := Vector2(cell)
		var center := _grid_point_to_world(collision_center)
		for actor_id: StringName in occupancy[cell]:
			var source_cell: Vector2 = resolution.initial_positions[actor_id]
			var source_direction := (source_cell - collision_center).normalized()
			stages[actor_id] = center + source_direction * COLLISION_STAGING_DISTANCE

	# Reciprocal moves visually meet on their crossed edge instead of passing
	# through into each other's cells.
	if resolution.collision_waves.is_empty():
		return stages
	var first_wave: Dictionary = resolution.collision_waves[0]
	if first_wave.get("kind", &"") != &"edge":
		return stages
	for group: Dictionary in first_wave.get("groups", []):
		var collision_center: Vector2 = group["center"]
		var center := _grid_point_to_world(collision_center)
		for actor_id: StringName in group["participants"]:
			var source_cell: Vector2 = group["source_positions"][actor_id]
			var source_direction := (source_cell - collision_center).normalized()
			stages[actor_id] = center + source_direction * COLLISION_STAGING_DISTANCE
	return stages


func _build_wave_stages(wave: Dictionary) -> Dictionary:
	var stages: Dictionary = {}
	for group: Dictionary in wave.get("groups", []):
		var collision_center: Vector2 = group["center"]
		var center := _grid_point_to_world(collision_center)
		for actor_id: StringName in group["participants"]:
			if not _actor_views.has(actor_id):
				continue
			var source_cell: Vector2 = group["source_positions"][actor_id]
			var source_direction := (source_cell - collision_center).normalized()
			stages[actor_id] = center + source_direction * COLLISION_STAGING_DISTANCE
	return stages


func _apply_approach_animation(
	progress: float,
	start_positions: Dictionary,
	collision_stages: Dictionary,
	intents: Dictionary,
	resolution
) -> void:
	var move_progress := 0.5 - cos(progress * PI) * 0.5
	var bump_progress := sin(progress * PI)
	for actor_id: StringName in start_positions:
		var view = _actor_views[actor_id]
		var start_position: Vector2 = start_positions[actor_id]
		if collision_stages.has(actor_id):
			view.position = start_position.lerp(collision_stages[actor_id], move_progress)
			continue

		var movement: Dictionary = resolution.movement_results[actor_id]
		if movement.get("moved", false):
			view.position = start_position.lerp(
				_cell_to_world(resolution.movement_positions[actor_id]),
				move_progress
			)
			continue

		var intent = intents[actor_id]
		if not movement.get("valid", false) and intent.action_type == TurnIntentType.ActionType.MOVE:
			var bump_direction := Vector2(intent.delta).normalized()
			view.position = start_position + bump_direction * FAILED_MOVE_BUMP_DISTANCE * bump_progress
		else:
			view.position = start_position


func _play_collision_wave(wave: Dictionary) -> void:
	var max_event_count := 0
	for group: Dictionary in wave.get("groups", []):
		max_event_count = maxi(max_event_count, group["combat_events"].size())

	# Pair N in every independent group is played together. Pair order inside a
	# group remains deterministic while coordinate iteration cannot affect timing.
	for event_index in max_event_count:
		var event_batch: Array = []
		for group: Dictionary in wave["groups"]:
			if event_index < group["combat_events"].size():
				event_batch.append(group["combat_events"][event_index])
		await _play_combat_event_batch(event_batch)


func _play_combat_event_batch(events: Array) -> void:
	var visible_events: Array = []
	var base_positions: Dictionary = {}
	for event: Dictionary in events:
		var first_id: StringName = event["first_id"]
		var second_id: StringName = event["second_id"]
		if not _actor_views.has(first_id) or not _actor_views.has(second_id):
			continue
		visible_events.append(event)
		base_positions[first_id] = _actor_views[first_id].position
		base_positions[second_id] = _actor_views[second_id].position
	if visible_events.is_empty():
		return

	var pulse := create_tween()
	pulse.tween_method(
		_apply_combat_pulse_batch.bind(visible_events, base_positions),
		0.0,
		1.0,
		COMBAT_EVENT_DURATION
	)
	await pulse.finished

	for actor_id: StringName in base_positions:
		if not _actor_views.has(actor_id):
			continue
		_actor_views[actor_id].position = base_positions[actor_id]
		_actor_views[actor_id].set_hit_flash(0.0)
	for event: Dictionary in visible_events:
		_actor_views[event["first_id"]].set_health(event["first_health_after"])
		_actor_views[event["second_id"]].set_health(event["second_health_after"])


func _apply_combat_pulse_batch(
	progress: float,
	events: Array,
	base_positions: Dictionary
) -> void:
	for event: Dictionary in events:
		_apply_combat_pulse(
			progress,
			event["first_id"],
			event["second_id"],
			base_positions
		)


func _apply_combat_pulse(
	progress: float,
	first_id: StringName,
	second_id: StringName,
	base_positions: Dictionary
) -> void:
	var flash := sin(progress * PI)
	var shake := sin(progress * PI * 4.0) * 2.5
	var first_view = _actor_views[first_id]
	var second_view = _actor_views[second_id]
	first_view.position = base_positions[first_id] + Vector2(shake, 0.0)
	second_view.position = base_positions[second_id] - Vector2(shake, 0.0)
	first_view.set_hit_flash(flash)
	second_view.set_hit_flash(flash)


func _play_wave_settle(wave: Dictionary, next_wave: Dictionary) -> void:
	var next_stages := _build_wave_stages(next_wave) if not next_wave.is_empty() else {}
	var positions_after: Dictionary = wave.get("positions_after", {})
	var health_after: Dictionary = wave.get("health_after", {})
	var wave_dead: Array = wave.get("dead_actor_ids", [])
	var settle := create_tween().set_parallel(true)
	for actor_id: StringName in _actor_views.keys():
		var view = _actor_views[actor_id]
		if actor_id in wave_dead:
			settle.tween_property(view, "scale", Vector2.ONE * 0.35, SETTLE_DURATION)
			settle.tween_property(view, "modulate", Color(1.0, 1.0, 1.0, 0.0), SETTLE_DURATION)
		elif positions_after.has(actor_id):
			var target: Vector2 = next_stages.get(
				actor_id,
				_cell_to_world(positions_after[actor_id])
			)
			settle.tween_property(
				view,
				"position",
				target,
				SETTLE_DURATION
			).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await settle.finished

	for actor_id: StringName in wave_dead:
		if not _actor_views.has(actor_id):
			continue
		_actor_views[actor_id].queue_free()
		_actor_views.erase(actor_id)
	for actor_id: StringName in health_after:
		if not _actor_views.has(actor_id):
			continue
		_actor_views[actor_id].set_health(health_after[actor_id])
		_actor_views[actor_id].reset_visual_state()


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
					_actors[&"player"] = GridActorStateType.new(
						&"player", cell, &"player", &"player", 5, 5, 2
					)
				"D":
					_actors[&"drunk"] = GridActorStateType.new(
						&"drunk", cell, &"npc", &"drunk", 3, 3, 1
					)


func _active_actor_ids() -> Array:
	var result: Array = []
	for actor_id: StringName in ACTOR_ORDER:
		if _actors.has(actor_id):
			result.append(actor_id)
	var remaining := _actors.keys()
	remaining.sort()
	for actor_id: StringName in remaining:
		if not actor_id in result:
			result.append(actor_id)
	return result


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
	for actor_id: StringName in _active_actor_ids():
		var actor = _actors[actor_id]
		var view = CharacterViewType.new()
		view.name = String(actor_id).capitalize()
		view.setup(
			COLOR_PLAYER if actor_id == &"player" else COLOR_DRUNK,
			actor.health,
			actor.max_health,
			actor.attack
		)
		view.position = _cell_to_world(actor.cell)
		_actor_views[actor_id] = view
		add_child(view)


func _build_interface() -> void:
	add_child(_make_label(
		"同步回合制 · 碰撞战斗验证",
		Vector2(24.0, 24.0), Vector2(576.0, 34.0), 24, COLOR_TEXT
	))
	add_child(_make_label(
		"回合验证面板",
		Vector2(644.0, 42.0), Vector2(268.0, 30.0), 22, COLOR_TEXT
	))

	_turn_label = _make_label("", Vector2(644.0, 84.0), Vector2(268.0, 28.0), 20, COLOR_TEXT)
	add_child(_turn_label)
	_status_label = _make_label("", Vector2(644.0, 116.0), Vector2(268.0, 24.0), 15, COLOR_MUTED)
	add_child(_status_label)

	add_child(_make_label(
		"操作\nW / A / S / D　移动一格\nR　　　　　　 等待",
		Vector2(644.0, 151.0), Vector2(268.0, 78.0), 15, COLOR_TEXT
	))
	add_child(_make_label(
		"角色\n● 主角　HP 5　ATK 2\n● 酒鬼　HP 3　ATK 1",
		Vector2(644.0, 232.0), Vector2(268.0, 82.0), 15, COLOR_TEXT
	))
	add_child(_make_label(
		"上一回合",
		Vector2(644.0, 321.0), Vector2(268.0, 24.0), 17, COLOR_TEXT
	))
	_log_label = _make_label("", Vector2(644.0, 350.0), Vector2(268.0, 132.0), 13, COLOR_MUTED)
	_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_log_label)
	add_child(_make_label(
		"RNG seed: %d" % RNG_SEED,
		Vector2(644.0, 488.0), Vector2(268.0, 22.0), 13, COLOR_MUTED
	))


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
	for wave: Dictionary in resolution.collision_waves:
		var wave_number: int = wave["wave_index"] + 1
		if wave.get("kind", &"") == &"cycle_reset":
			lines.append("第 %d 波：检测到重复状态，安全复位" % wave_number)
			continue
		for group: Dictionary in wave.get("groups", []):
			var location_text := "边中点 %s" % group["center"]
			if group["kind"] == &"grid":
				var cell: Vector2i = group["cell"]
				location_text = "网格(%d,%d)" % [cell.x, cell.y]
			lines.append("第 %d 波｜%s" % [wave_number, location_text])
			if group["combat_events"].is_empty():
				lines.append("  同阵营：跳过战斗")
			for event: Dictionary in group["combat_events"]:
				lines.append(
					"  %s %d→%d ↔ %s %d→%d" % [
						_actor_name(event["first_id"]),
						event["first_health_before"],
						event["first_health_after"],
						_actor_name(event["second_id"]),
						event["second_health_before"],
						event["second_health_after"],
					]
				)
			if not group["dead_actor_ids"].is_empty():
				var dead_names: Array = []
				for actor_id: StringName in group["dead_actor_ids"]:
					dead_names.append(_actor_name(actor_id))
				lines.append("  死亡：%s" % "、".join(dead_names))
			if not group["returned_actor_ids"].is_empty():
				lines.append("  多人存活：退回回合初始格")
			elif group["survivors"].size() == 1:
				lines.append("  唯一幸存者：留在碰撞位置")
	for actor_id: StringName in intents:
		var intent = intents[actor_id]
		var outcome: Dictionary = resolution.outcome_for(actor_id)
		var result_text := "死亡" if resolution.is_dead(actor_id) else _reason_text(outcome.get("reason", &""))
		lines.append("%s：%s｜%s" % [_actor_name(actor_id), _intent_text(intent), result_text])
	return "\n".join(lines)


func _actor_name(actor_id: StringName) -> String:
	match actor_id:
		&"player":
			return "主角"
		&"drunk":
			return "酒鬼"
	return String(actor_id)


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
		&"friendly_collision":
			return "友方碰撞，退回"
		&"combat_survivor_returned":
			return "战后多人存活，退回"
		&"combat_winner_moved":
			return "战斗胜利，进入目标格"
		&"combat_winner_held":
			return "战斗胜利，守住原格"
		&"collision_cycle_reset":
			return "碰撞状态异常，安全复位"
		&"died_in_combat":
			return "战斗死亡"
		&"occupied_actor_not_leaving":
			return "占用者未离开"
		&"invalid_direction":
			return "无效方向"
	return "未知结果"


func _move_intent(actor_id: StringName, delta: Vector2i):
	return TurnIntentType.new(actor_id, TurnIntentType.ActionType.MOVE, delta)


func _wait_intent(actor_id: StringName):
	return TurnIntentType.new(actor_id, TurnIntentType.ActionType.WAIT, Vector2i.ZERO)


func _cell_to_world(cell: Vector2i) -> Vector2:
	return _grid_point_to_world(Vector2(cell))


func _grid_point_to_world(grid_point: Vector2) -> Vector2:
	return BOARD_ORIGIN + grid_point * CELL_SIZE + Vector2.ONE * CELL_SIZE * 0.5


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
