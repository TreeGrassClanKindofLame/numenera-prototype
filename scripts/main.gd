extends Node2D

signal combat_step_requested

const TurnIntentType = preload("res://scripts/model/turn_intent.gd")
const GridActorStateType = preload("res://scripts/model/grid_actor_state.gd")
const SquadUnitStateType = preload("res://scripts/model/squad_unit_state.gd")
const TurnResolverType = preload("res://scripts/core/turn_resolver.gd")
const EnemyAIControllerType = preload("res://scripts/core/enemy_ai_controller.gd")
const EnemyBrainStateType = preload("res://scripts/model/enemy_brain_state.gd")
const ScenarioCatalogType = preload("res://scripts/core/test_scenario_catalog.gd")
const CharacterViewType = preload("res://scripts/ui/character_view.gd")
const BattleOverlayType = preload("res://scripts/ui/battle_overlay.gd")

const BOARD_SIZE := Vector2i(12, 8)
const CELL_SIZE := 48.0
const BOARD_ORIGIN := Vector2(24.0, 78.0)
const APPROACH_DURATION := 0.12
const COMBAT_PREVIEW_DURATION := 0.03
const COMBAT_STRIKE_DURATION := 0.045
const COMBAT_IMPACT_DURATION := 0.03
const COMBAT_DAMAGE_DURATION := 0.045
const COMBAT_EVENT_DURATION := 0.15
const ENCOUNTER_TRANSITION_DURATION := 0.10
const RESULT_HOLD_DURATION := 0.35
const SETTLE_DURATION := 0.12
const FAILED_MOVE_BUMP_DISTANCE := 10.0
const COLLISION_STAGING_DISTANCE := 11.0
const RNG_SEED := 1337
const UNIT_CLASS_CYCLE := [&"", &"tank", &"warrior", &"archer", &"assassin"]

const COLOR_BACKGROUND := Color("111722")
const COLOR_FLOOR_A := Color("202b3a")
const COLOR_FLOOR_B := Color("243244")
const COLOR_WALL := Color("667182")
const COLOR_GRID := Color("3b4a60")
const COLOR_PANEL := Color("182231")
const COLOR_TEXT := Color("e8edf4")
const COLOR_MUTED := Color("9eabbc")
const COLOR_PLAYER := Color("4da3ff")
const COLOR_DUMMY := Color("c79a62")
const COLOR_ROBOT := Color("7d8fe8")
const COLOR_BANDIT := Color("e16f5b")
const COLOR_VISION := Color(0.95, 0.72, 0.22, 0.20)
const COLOR_ALERT_VISION := Color(0.95, 0.25, 0.20, 0.24)
const COLOR_PATROL := Color(0.48, 0.58, 0.96, 0.24)

var _blocked: Dictionary = {}
var _actors: Dictionary = {}
var _actor_views: Dictionary = {}
var _enemy_brains: Dictionary = {}
var _enemy_ai = EnemyAIControllerType.new()
var _scenario_id: StringName = ScenarioCatalogType.SCENARIO_DUMMY
var _scenario: Dictionary = {}
var _turn_number := 1
var _busy := false

var _turn_label: Label
var _status_label: Label
var _log_label: Label
var _formation_labels: Dictionary = {}
var _selected_squad_id: StringName = &"player"
var _battle_overlay
var _battle_slow_motion_enabled := false
var _waiting_for_combat_step := false
var _slow_motion_toggle: CheckButton
var _ai_debug_toggle: CheckButton
var _scenario_buttons: Dictionary = {}
var _squad_selector_ids: Array = []
var _squad_selector_buttons: Array = []


func _ready() -> void:
	_scenario = ScenarioCatalogType.definition(_scenario_id)
	_parse_map()
	_ensure_input_actions()
	_build_actor_views()
	_build_interface()
	_battle_overlay = BattleOverlayType.new()
	add_child(_battle_overlay)
	_battle_overlay.setup()
	_refresh_scenario_controls()
	_update_interface("等待玩家输入", "尚未结算。")
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if _waiting_for_combat_step:
		if key_event.keycode == KEY_SPACE or key_event.physical_keycode == KEY_SPACE:
			get_viewport().set_input_as_handled()
			_advance_slow_battle()
		return
	if _busy or not _actors.has(&"player"):
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
	_set_slow_motion_toggle_locked(true)
	_set_scenario_controls_locked(true)
	_update_interface("正在结算第 %d 回合…" % _turn_number, _log_label.text)

	var intents: Dictionary = {&"player": player_intent}
	for actor_id: StringName in _enemy_brains:
		if not _actors.has(actor_id):
			continue
		intents[actor_id] = _enemy_ai.choose_intent(
			_enemy_brains[actor_id],
			_actors[actor_id],
			_actors.get(&"player"),
			_blocked,
			BOARD_SIZE
		)

	var actor_states: Array = []
	for actor_id: StringName in _active_actor_ids():
		actor_states.append(_actors[actor_id])
		if not intents.has(actor_id):
			intents[actor_id] = _wait_intent(actor_id)

	var resolved_turn := _turn_number
	var resolution = TurnResolverType.resolve(
		BOARD_SIZE, _blocked, actor_states, intents, RNG_SEED + resolved_turn
	)
	for actor_id: StringName in _enemy_brains.keys():
		if not _enemy_brains.has(actor_id):
			continue
		var events := _enemy_ai.commit_after_turn(
			_enemy_brains[actor_id], resolution, _blocked, BOARD_SIZE
		)
		resolution.enemy_events.append_array(events)
	var turn_log := _format_turn_log(resolved_turn, intents, resolution)
	var animation_starts: Dictionary = {}
	for actor_id: StringName in _active_actor_ids():
		animation_starts[actor_id] = _actor_views[actor_id].position

	await _play_resolution_animation(animation_starts, intents, resolution)
	_actors = resolution.final_actor_states.duplicate()
	for actor_id: StringName in _enemy_brains.keys():
		if not _actors.has(actor_id):
			_enemy_brains.erase(actor_id)

	for actor_id: StringName in _active_actor_ids():
		var actor = _actors[actor_id]
		var view = _actor_views[actor_id]
		view.position = _cell_to_world(actor.cell)
		view.set_squad_stats(actor.health, actor.max_health, actor.attack, actor.living_unit_count())
		view.set_facing(actor.facing)
		view.reset_visual_state()

	_turn_number += 1
	_busy = false
	_set_slow_motion_toggle_locked(false)
	_set_scenario_controls_locked(false)
	var status := "等待玩家输入" if _actors.has(&"player") else "主角已死亡，原型结束"
	_update_interface(status, turn_log)
	_refresh_formation_panel()
	queue_redraw()


func _play_resolution_animation(
	start_positions: Dictionary,
	intents: Dictionary,
	resolution
) -> void:
	for actor_id: StringName in resolution.movement_results:
		if _actor_views.has(actor_id):
			_actor_views[actor_id].set_facing(
				resolution.movement_results[actor_id].get("facing", Vector2i.DOWN)
			)
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
	var groups: Array = wave.get("groups", [])
	var played_encounter := false
	for group_index in groups.size():
		var group: Dictionary = groups[group_index]
		var encounters: Array = group.get("encounters", [])
		for pair_index in encounters.size():
			var encounter: Dictionary = encounters[pair_index]
			if played_encounter:
				await get_tree().create_timer(ENCOUNTER_TRANSITION_DURATION).timeout
			var context := {
				"wave_index": wave.get("wave_index", 0),
				"group_index": group_index,
				"group_count": groups.size(),
				"pair_index": pair_index,
				"pair_count": encounters.size(),
			}
			if encounter.get("skipped", false):
				_battle_overlay.show_skipped_encounter(encounter, context)
				await get_tree().create_timer(COMBAT_EVENT_DURATION).timeout
				played_encounter = true
				continue
			await _play_squad_encounter(encounter, context)
			played_encounter = true
	if played_encounter:
		_battle_overlay.end_encounter()


func _play_squad_encounter(encounter: Dictionary, context: Dictionary) -> void:
	_battle_overlay.begin_encounter(encounter, context, _battle_slow_motion_enabled)
	var events: Array = encounter.get("events", [])
	for schedule_entry: Dictionary in encounter.get("turn_schedule", []):
		if schedule_entry.get("status", &"") == &"skipped":
			_battle_overlay.show_skipped_action(schedule_entry)
			await get_tree().create_timer(COMBAT_PREVIEW_DURATION).timeout
			continue
		var event_index: int = schedule_entry.get("event_index", -1)
		if event_index < 0 or event_index >= events.size():
			continue
		await _play_unit_battle_action(schedule_entry, events[event_index])
	_battle_overlay.show_result(encounter)
	_battle_overlay.play_audio_cue(&"result")
	if _battle_slow_motion_enabled:
		await _wait_for_combat_step("战斗慢放｜按空格确认战果")
	else:
		await get_tree().create_timer(RESULT_HOLD_DURATION).timeout


func _play_unit_battle_action(schedule_entry: Dictionary, event: Dictionary) -> void:
	_battle_overlay.preview_action(schedule_entry, event)
	if _battle_slow_motion_enabled:
		await _wait_for_combat_step("战斗慢放｜按空格结算当前单位行动")
	else:
		await get_tree().create_timer(COMBAT_PREVIEW_DURATION).timeout

	_battle_overlay.play_audio_cue(&"attack")
	var strike := create_tween()
	strike.tween_method(_battle_overlay.set_attack_progress, 0.0, 1.0, COMBAT_STRIKE_DURATION)
	await strike.finished

	_battle_overlay.play_audio_cue(&"hit")
	var impact := create_tween()
	impact.tween_method(_battle_overlay.set_impact_flash, 1.0, 0.0, COMBAT_IMPACT_DURATION)
	await impact.finished

	var damage := create_tween()
	damage.tween_method(_battle_overlay.set_damage_progress, 0.0, 1.0, COMBAT_DAMAGE_DURATION)
	await damage.finished
	if event.get("target_died", false):
		_battle_overlay.play_audio_cue(&"death")
	_battle_overlay.commit_action(event)


func _play_combat_event_batch(events: Array) -> void:
	# Compatibility entry point used by focused animation tests. Production
	# playback goes through encounters so map pieces never impersonate units.
	for event: Dictionary in events:
		var schedule_entry := {
			"schedule_index": event.get("schedule_index", 0),
			"squad_id": event.get("attacker_squad_id", &""),
			"unit_id": event.get("attacker_unit_id", &""),
			"speed": event.get("speed", 0),
			"status": &"acted",
			"event_index": 0,
		}
		_battle_overlay.snapshot = event.get("formations_before", {}).duplicate(true)
		_battle_overlay.show()
		await _play_unit_battle_action(schedule_entry, event)


func _wait_for_combat_step(prompt := "战斗慢放｜按空格结算当前单位行动") -> void:
	_waiting_for_combat_step = true
	_status_label.text = prompt
	await combat_step_requested
	_waiting_for_combat_step = false
	_status_label.text = "正在播放单位行动…"


func _advance_slow_battle() -> void:
	if not _waiting_for_combat_step:
		return
	_waiting_for_combat_step = false
	combat_step_requested.emit()


func _on_slow_motion_toggled(enabled: bool) -> void:
	if _busy:
		_slow_motion_toggle.set_pressed_no_signal(_battle_slow_motion_enabled)
		return
	_battle_slow_motion_enabled = enabled


func _set_slow_motion_toggle_locked(locked: bool) -> void:
	if _slow_motion_toggle != null:
		_slow_motion_toggle.disabled = locked


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
	_enemy_brains.clear()
	var map_rows: Array = _scenario.get("map_rows", [])
	for y in BOARD_SIZE.y:
		var row: String = map_rows[y]
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
				"T":
					_actors[&"dummy"] = _make_default_squad(
						&"dummy", cell, &"npc", &"dummy", Vector2i.DOWN
					)
					_enemy_brains[&"dummy"] = EnemyBrainStateType.new(
						&"dummy", EnemyBrainStateType.BEHAVIOR_DUMMY
					)
				"R":
					var robot_facing: Vector2i = _scenario.get("enemy_facing", Vector2i.RIGHT)
					_actors[&"robot"] = _make_default_squad(
						&"robot", cell, &"npc", &"robot", robot_facing
					)
					_enemy_brains[&"robot"] = EnemyBrainStateType.new(
						&"robot",
						EnemyBrainStateType.BEHAVIOR_ROBOT,
						_scenario.get("patrol_path", [])
					)
				"B":
					var bandit_facing: Vector2i = _scenario.get("enemy_facing", Vector2i.LEFT)
					_actors[&"bandit"] = _make_default_squad(
						&"bandit", cell, &"npc", &"bandit", bandit_facing
					)
					_enemy_brains[&"bandit"] = EnemyBrainStateType.new(
						&"bandit", EnemyBrainStateType.BEHAVIOR_BANDIT
					)
	if _actors.has(&"player"):
		var player_cell: Vector2i = _actors[&"player"].cell
		_actors[&"player"] = _make_default_squad(
			&"player", player_cell, &"player", &"player", Vector2i.DOWN
		)


func _make_default_squad(
	actor_id: StringName,
	cell: Vector2i,
	controller: StringName,
	faction: StringName,
	facing: Vector2i = Vector2i.DOWN
):
	var unit_specs := [
		[&"tank", Vector2i(0, 0)],
		[&"warrior", Vector2i(1, 0)],
		[&"archer", Vector2i(1, 1)],
		[&"assassin", Vector2i(2, 1)],
	]
	var units: Array = []
	if actor_id == &"dummy":
		unit_specs = [
			[&"custom", Vector2i(0, 0)],
			[&"custom", Vector2i(1, 0)],
			[&"custom", Vector2i(2, 0)],
			[&"custom", Vector2i(1, 1)],
		]
	elif actor_id == &"robot":
		unit_specs = [
			[&"tank", Vector2i(0, 0)],
			[&"tank", Vector2i(2, 0)],
			[&"archer", Vector2i(0, 1)],
			[&"archer", Vector2i(2, 1)],
		]
	elif actor_id == &"bandit":
		unit_specs = [
			[&"warrior", Vector2i(0, 0)],
			[&"warrior", Vector2i(2, 0)],
			[&"assassin", Vector2i(0, 1)],
			[&"assassin", Vector2i(2, 1)],
		]
	for index in unit_specs.size():
		var spec: Array = unit_specs[index]
		if actor_id == &"dummy":
			units.append(SquadUnitStateType.new(
				StringName("%s_%d" % [actor_id, index]),
				SquadUnitStateType.CLASS_CUSTOM,
				spec[1],
				50,
				50,
				0,
				1
			))
		else:
			units.append(SquadUnitStateType.create_for_class(
				StringName("%s_%d" % [actor_id, index]), spec[0], spec[1]
			))
	return GridActorStateType.new(
		actor_id, cell, controller, faction, 1, 1, 1, units, facing
	)


func _active_actor_ids() -> Array:
	var result: Array = [&"player"] if _actors.has(&"player") else []
	var remaining := _actors.keys()
	remaining.sort()
	for actor_id: StringName in remaining:
		if actor_id != &"player":
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
			_actor_color(actor_id),
			actor.health,
			actor.max_health,
			actor.attack
		)
		view.set_squad_stats(actor.health, actor.max_health, actor.attack, actor.living_unit_count())
		view.set_facing(actor.facing)
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
	_build_scenario_controls()

	add_child(_make_label(
		"操作\nW / A / S / D　移动一格\nR　　　　　　 等待",
		Vector2(644.0, 151.0), Vector2(268.0, 78.0), 15, COLOR_TEXT
	))
	add_child(_make_label(
		"GM编队面板｜点击标题切换小队\n每格点击：空→肉→战→射→刺→空",
		Vector2(644.0, 224.0), Vector2(330.0, 46.0), 14, COLOR_TEXT
	))
	_slow_motion_toggle = CheckButton.new()
	_slow_motion_toggle.text = "战斗慢放｜空格逐步"
	_slow_motion_toggle.position = Vector2(960.0, 274.0)
	_slow_motion_toggle.size = Vector2(208.0, 30.0)
	_slow_motion_toggle.button_pressed = false
	_slow_motion_toggle.toggled.connect(_on_slow_motion_toggled)
	add_child(_slow_motion_toggle)
	_ai_debug_toggle = CheckButton.new()
	_ai_debug_toggle.text = "显示AI调试覆盖"
	_ai_debug_toggle.position = Vector2(960.0, 310.0)
	_ai_debug_toggle.size = Vector2(208.0, 30.0)
	_ai_debug_toggle.button_pressed = true
	_ai_debug_toggle.toggled.connect(_on_ai_debug_toggled)
	add_child(_ai_debug_toggle)
	_build_formation_panel()
	add_child(_make_label(
		"上一回合",
		Vector2(644.0, 465.0), Vector2(520.0, 24.0), 17, COLOR_TEXT
	))
	_log_label = _make_label("", Vector2(644.0, 494.0), Vector2(520.0, 184.0), 12, COLOR_MUTED)
	_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_log_label)


func _build_formation_panel() -> void:
	for index in 2:
		var selector := Button.new()
		selector.position = Vector2(644.0 + index * 158.0, 274.0)
		selector.size = Vector2(150.0, 30.0)
		selector.pressed.connect(_select_formation_squad_by_index.bind(index))
		_squad_selector_buttons.append(selector)
		add_child(selector)
	for row in 2:
		for column in 3:
			var slot := Vector2i(column, row)
			var button := Button.new()
			button.position = Vector2(644.0 + column * 104.0, 312.0 + row * 62.0)
			button.size = Vector2(96.0, 54.0)
			button.pressed.connect(_cycle_formation_slot.bind(slot))
			_formation_labels[slot] = button
			add_child(button)
	_refresh_squad_selectors()
	_refresh_formation_panel()


func _build_scenario_controls() -> void:
	var ids := ScenarioCatalogType.scenario_ids()
	for index in ids.size():
		var scenario_id: StringName = ids[index]
		var button := Button.new()
		button.text = ScenarioCatalogType.definition(scenario_id)["display_name"].trim_suffix("测试")
		button.position = Vector2(920.0 + index * 82.0, 42.0)
		button.size = Vector2(76.0, 30.0)
		button.pressed.connect(_switch_scenario.bind(scenario_id))
		_scenario_buttons[scenario_id] = button
		add_child(button)


func _switch_scenario(scenario_id: StringName) -> void:
	if _busy or scenario_id == _scenario_id:
		return
	for view in _actor_views.values():
		view.queue_free()
	_actor_views.clear()
	if _battle_overlay != null:
		_battle_overlay.end_encounter()
	_scenario_id = scenario_id
	_scenario = ScenarioCatalogType.definition(scenario_id)
	_turn_number = 1
	_selected_squad_id = &"player"
	_parse_map()
	_build_actor_views()
	_refresh_squad_selectors()
	_refresh_formation_panel()
	_refresh_scenario_controls()
	_update_interface("等待玩家输入", "%s已重置。" % _scenario["display_name"])
	queue_redraw()


func _refresh_scenario_controls() -> void:
	for scenario_id: StringName in _scenario_buttons:
		_scenario_buttons[scenario_id].disabled = (
			_busy or scenario_id == _scenario_id
		)


func _set_scenario_controls_locked(locked: bool) -> void:
	for scenario_id: StringName in _scenario_buttons:
		_scenario_buttons[scenario_id].disabled = locked or scenario_id == _scenario_id


func _on_ai_debug_toggled(_enabled: bool) -> void:
	queue_redraw()


func _refresh_squad_selectors() -> void:
	_squad_selector_ids = _active_actor_ids()
	for index in _squad_selector_buttons.size():
		var button: Button = _squad_selector_buttons[index]
		if index >= _squad_selector_ids.size():
			button.hide()
			continue
		button.show()
		button.text = "%s小队" % _actor_name(_squad_selector_ids[index])


func _select_formation_squad_by_index(index: int) -> void:
	if index < 0 or index >= _squad_selector_ids.size():
		return
	_select_formation_squad(_squad_selector_ids[index])


func _select_formation_squad(actor_id: StringName) -> void:
	if _busy or not _actors.has(actor_id):
		return
	_selected_squad_id = actor_id
	_refresh_formation_panel()


func _cycle_formation_slot(slot: Vector2i) -> void:
	if _busy or not _actors.has(_selected_squad_id):
		return
	var squad = _actors[_selected_squad_id]
	var existing = squad.unit_at(slot)
	var current_class: StringName = existing.unit_class if existing != null else &""
	var current_index := UNIT_CLASS_CYCLE.find(current_class)
	for offset in range(1, UNIT_CLASS_CYCLE.size() + 1):
		var next_class: StringName = UNIT_CLASS_CYCLE[(current_index + offset) % UNIT_CLASS_CYCLE.size()]
		if next_class != &"" and existing == null and squad.living_unit_count() >= 4:
			continue
		squad.set_unit_at(slot, next_class)
		break
	_refresh_formation_panel()
	if _actor_views.has(_selected_squad_id):
		_actor_views[_selected_squad_id].set_squad_stats(
			squad.health, squad.max_health, squad.attack, squad.living_unit_count()
		)


func _refresh_formation_panel() -> void:
	if _formation_labels.is_empty() or not _actors.has(_selected_squad_id):
		return
	var squad = _actors[_selected_squad_id]
	for slot: Vector2i in _formation_labels:
		var button: Button = _formation_labels[slot]
		var unit = squad.unit_at(slot)
		var row_name := "前" if slot.y == 0 else "后"
		if unit == null:
			button.text = "%s%d｜空" % [row_name, slot.x + 1]
		else:
			var unit_name: String = "木桩" if _selected_squad_id == &"dummy" and unit.unit_class == SquadUnitStateType.CLASS_CUSTOM else unit.class_name_zh()
			button.text = "%s%d｜%s\nHP%d 攻%d 速%d" % [
				row_name, slot.x + 1, unit_name,
				maxi(unit.health, 0), unit.attack, unit.speed,
			]


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
			for encounter: Dictionary in group.get("encounters", []):
				if encounter.get("skipped", false):
					continue
				var engagement: Dictionary = encounter.get("engagement", {})
				if engagement.is_empty():
					continue
				var first_contact: Dictionary = engagement.get("first_contact", {})
				var second_contact: Dictionary = engagement.get("second_contact", {})
				var advantage_text := "均无优势"
				if encounter.get("first_advantage", 0) > 0:
					advantage_text = "%s优势%d" % [
						_actor_name(encounter["first_squad_id"]),
						encounter["first_advantage"],
					]
				elif encounter.get("second_advantage", 0) > 0:
					advantage_text = "%s优势%d" % [
						_actor_name(encounter["second_squad_id"]),
						encounter["second_advantage"],
					]
				lines.append("  接敌：%s%d vs %s%d → %s" % [
					_contact_side_text(first_contact.get("side", &"front")),
					first_contact.get("score", 2),
					_contact_side_text(second_contact.get("side", &"front")),
					second_contact.get("score", 2),
					advantage_text,
				])
			if group["combat_events"].is_empty():
				lines.append("  同阵营：跳过战斗")
			for event: Dictionary in group["combat_events"]:
				lines.append(
					"  %s｜%s/%s → %s/%s  %d→%d%s" % [
						"第零回合" if event.get("phase", &"round_one") == &"round_zero" else "第一回合",
						_actor_name(event["attacker_squad_id"]),
						String(event["attacker_unit_id"]),
						_actor_name(event["defender_squad_id"]),
						String(event["defender_unit_id"]),
						event["health_before"],
						event["health_after"],
						" 死亡" if event["target_died"] else "",
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
	for event: Dictionary in resolution.enemy_events:
		if event.get("kind", &"") == &"bandit_alerted":
			lines.append("强盗发现主角：进入永久追击，下回合开始移动")
	for actor_id: StringName in intents:
		var intent = intents[actor_id]
		var outcome: Dictionary = resolution.outcome_for(actor_id)
		var result_text := "死亡" if resolution.is_dead(actor_id) else _reason_text(outcome.get("reason", &""))
		lines.append("%s：%s｜%s" % [_actor_name(actor_id), _intent_text(intent), result_text])
	return "\n".join(lines)


func _contact_side_text(side: StringName) -> String:
	match side:
		&"front": return "正面"
		&"side": return "侧面"
		&"back": return "背面"
	return "未知"


func _actor_name(actor_id: StringName) -> String:
	match actor_id:
		&"player":
			return "主角"
		&"dummy":
			return "木桩"
		&"robot":
			return "机器人"
		&"bandit":
			return "强盗"
	return String(actor_id)


func _actor_color(actor_id: StringName) -> Color:
	match actor_id:
		&"player": return COLOR_PLAYER
		&"dummy": return COLOR_DUMMY
		&"robot": return COLOR_ROBOT
		&"bandit": return COLOR_BANDIT
	return COLOR_DUMMY


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
	draw_rect(Rect2(Vector2.ZERO, Vector2(1200.0, 720.0)), COLOR_BACKGROUND)
	draw_rect(Rect2(Vector2(620.0, 24.0), Vector2(556.0, 672.0)), COLOR_PANEL)

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
	if _ai_debug_toggle == null or not _ai_debug_toggle.button_pressed:
		return
	match _scenario_id:
		ScenarioCatalogType.SCENARIO_ROBOT:
			_draw_robot_debug()
		ScenarioCatalogType.SCENARIO_BANDIT:
			_draw_bandit_debug()


func _draw_robot_debug() -> void:
	if not _actors.has(&"robot") or not _enemy_brains.has(&"robot"):
		return
	var brain = _enemy_brains[&"robot"]
	var next_target: Vector2i = _enemy_ai.robot_next_target(brain)
	for index in brain.patrol_path.size():
		var cell: Vector2i = brain.patrol_path[index]
		var rect := Rect2(
			BOARD_ORIGIN + Vector2(cell) * CELL_SIZE,
			Vector2.ONE * CELL_SIZE
		)
		draw_rect(rect, COLOR_PATROL, true)
		draw_string(
			ThemeDB.fallback_font,
			rect.position + Vector2(4.0, 14.0),
			str(index + 1),
			HORIZONTAL_ALIGNMENT_LEFT,
			18.0,
			10,
			COLOR_TEXT
		)
		if cell == next_target:
			draw_rect(rect.grow(-3.0), COLOR_ROBOT, false, 3.0)
	var actor = _actors[&"robot"]
	var direction_text := "顺时针" if brain.patrol_direction > 0 else "逆时针"
	var phase_text := "移动" if brain.move_turn else "等待"
	draw_string(
		ThemeDB.fallback_font,
		_cell_to_world(actor.cell) + Vector2(-72.0, 38.0),
		"%s｜%s｜目标%s" % [phase_text, direction_text, next_target],
		HORIZONTAL_ALIGNMENT_CENTER,
		144.0,
		11,
		COLOR_TEXT
	)


func _draw_bandit_debug() -> void:
	if not _actors.has(&"bandit") or not _enemy_brains.has(&"bandit"):
		return
	var actor = _actors[&"bandit"]
	var brain = _enemy_brains[&"bandit"]
	var visible := _enemy_ai.vision_cells(
		actor.cell, actor.facing, _blocked, BOARD_SIZE
	)
	var vision_color := COLOR_ALERT_VISION if brain.alerted else COLOR_VISION
	for cell: Vector2i in visible:
		var rect := Rect2(
			BOARD_ORIGIN + Vector2(cell) * CELL_SIZE,
			Vector2.ONE * CELL_SIZE
		)
		draw_rect(rect.grow(-2.0), vision_color, true)
	var state_text := "追击" if brain.alerted else "未察觉"
	draw_string(
		ThemeDB.fallback_font,
		_cell_to_world(actor.cell) + Vector2(-52.0, 38.0),
		"强盗｜%s" % state_text,
		HORIZONTAL_ALIGNMENT_CENTER,
		104.0,
		11,
		COLOR_TEXT
	)
