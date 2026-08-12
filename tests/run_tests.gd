extends Node

const TurnIntentType = preload("res://scripts/model/turn_intent.gd")
const SquadUnitStateType = preload("res://scripts/model/squad_unit_state.gd")
const GridActorStateType = preload("res://scripts/model/grid_actor_state.gd")
const SquadBattleResolverType = preload("res://scripts/core/squad_battle_resolver.gd")
const TurnResolverType = preload("res://scripts/core/turn_resolver.gd")
const DrunkControllerType = preload("res://scripts/core/drunk_controller.gd")
const MainScene = preload("res://scenes/main.tscn")

var _failures := 0
var _checks := 0


func _ready() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_test_class_stats_and_free_formation()
	_test_front_and_back_row_preferences()
	_test_empty_preferred_row_falls_back()
	_test_facing_column_then_nearest_column()
	_test_seeded_equidistant_target_is_reproducible()
	_test_speed_player_squad_and_unit_tiebreakers()
	_test_instant_death_prevents_action()
	_test_later_unit_retargets_current_battlefield()
	_test_single_attack_has_no_counterattack()
	_test_map_move_wait_wall_and_chain()
	_test_head_on_squad_battle_returns_survivors()
	_test_sole_squad_survivor_takes_collision_cell()
	_test_squad_damage_persists_across_encounters()
	_test_multi_squad_melee_inherits_damage_and_skips_eliminated()
	_test_friendly_squads_do_not_fight()
	_test_seeded_map_resolution_is_reproducible()
	_test_pursuit_ai_is_stable_and_terrain_aware()
	await _test_main_scene_gm_panel_and_combat()
	await _test_slow_motion_requires_one_step_per_action()

	if _failures == 0:
		print("PASS: %d checks across 19 squad-combat scenarios." % _checks)
	else:
		push_error("FAIL: %d of %d checks failed." % [_failures, _checks])


func _test_class_stats_and_free_formation() -> void:
	var tank = SquadUnitStateType.create_for_class(&"tank", &"tank", Vector2i(2, 1))
	var warrior = SquadUnitStateType.create_for_class(&"warrior", &"warrior", Vector2i(0, 1))
	var archer = SquadUnitStateType.create_for_class(&"archer", &"archer", Vector2i(1, 0))
	var assassin = SquadUnitStateType.create_for_class(&"assassin", &"assassin", Vector2i(2, 0))
	_expect_equal([tank.health, tank.attack, tank.speed], [8, 1, 1], "tank baseline stats")
	_expect_equal([warrior.health, warrior.attack, warrior.speed], [5, 2, 2], "warrior baseline stats")
	_expect_equal([archer.health, archer.attack, archer.speed], [3, 3, 2], "archer baseline stats")
	_expect_equal([assassin.health, assassin.attack, assassin.speed], [3, 2, 3], "assassin baseline stats")
	var squad = _squad(&"free", &"player", &"player", Vector2i.ZERO, [tank, warrior, archer, assassin])
	_expect_equal(squad.living_unit_count(), 4, "formation accepts four units")
	_expect_equal(squad.unit_at(Vector2i(2, 1)).unit_class, &"tank", "tank can stand in back row")
	_expect_true(not squad.set_unit_at(Vector2i(1, 1), &"tank"), "fifth unit is rejected")
	squad.set_unit_at(Vector2i(0, 1), &"")
	_expect_true(squad.set_unit_at(Vector2i(1, 1), &"tank"), "duplicate class is allowed after freeing a slot")


func _test_front_and_back_row_preferences() -> void:
	for attacker_class: StringName in [&"tank", &"warrior", &"archer"]:
		var attacker = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
			_unit(&"attacker", attacker_class, 1, 0, 20, 1, 5),
		])
		var defender = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
			_unit(&"front", &"custom", 1, 0, 20, 1, 1),
			_unit(&"back", &"custom", 1, 1, 20, 1, 1),
		])
		var event: Dictionary = _battle(attacker, defender, 1)["events"][0]
		_expect_equal(event["defender_unit_id"], &"front", "%s prioritizes front row" % attacker_class)

	var assassin = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"assassin", &"assassin", 1, 0, 20, 1, 5),
	])
	var target = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"front", &"custom", 1, 0, 20, 1, 1),
		_unit(&"back", &"custom", 1, 1, 20, 1, 1),
	])
	_expect_equal(_battle(assassin, target, 1)["events"][0]["defender_unit_id"], &"back", "assassin prioritizes back row")


func _test_empty_preferred_row_falls_back() -> void:
	var warrior = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"warrior", &"warrior", 1, 0, 20, 1, 5),
	])
	var back_only = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"back", &"custom", 1, 1, 20, 1, 1),
	])
	var event: Dictionary = _battle(warrior, back_only, 2)["events"][0]
	_expect_equal(event["defender_unit_id"], &"back", "front-preferring unit attacks back row when front is empty")
	_expect_true(event["used_fallback_row"], "row fallback is recorded")

	var assassin = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"assassin", &"assassin", 1, 1, 20, 1, 5),
	])
	var front_only = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"front", &"custom", 1, 0, 20, 1, 1),
	])
	_expect_equal(_battle(assassin, front_only, 2)["events"][0]["defender_unit_id"], &"front", "assassin falls back to front row")


func _test_facing_column_then_nearest_column() -> void:
	var attacker = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"archer", &"archer", 1, 1, 20, 1, 5),
	])
	var facing = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"left", &"custom", 0, 0, 20, 1, 1),
		_unit(&"center", &"custom", 1, 0, 20, 1, 1),
	])
	_expect_equal(_battle(attacker, facing, 3)["events"][0]["defender_unit_id"], &"center", "facing column is chosen first")

	attacker = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"archer", &"archer", 2, 1, 20, 1, 5),
	])
	var nearest = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"left", &"custom", 0, 0, 20, 1, 1),
		_unit(&"center", &"custom", 1, 0, 20, 1, 1),
	])
	_expect_equal(_battle(attacker, nearest, 3)["events"][0]["defender_unit_id"], &"center", "nearest occupied column is chosen when facing is empty")


func _test_seeded_equidistant_target_is_reproducible() -> void:
	var selected: Array = []
	for repetition in 2:
		var attacker = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
			_unit(&"archer", &"archer", 1, 1, 20, 1, 5),
		])
		var defender = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
			_unit(&"left", &"custom", 0, 0, 20, 1, 1),
			_unit(&"right", &"custom", 2, 0, 20, 1, 1),
		])
		var event: Dictionary = _battle(attacker, defender, 98765)["events"][0]
		selected.append(event["defender_unit_id"])
		_expect_true(event["used_random_tie"], "equidistant targets record random tie")
		_expect_equal(event["candidate_unit_ids"], [&"left", &"right"], "random candidates are recorded")
	_expect_equal(selected[0], selected[1], "same seed reproduces equidistant choice")


func _test_speed_player_squad_and_unit_tiebreakers() -> void:
	var player = _squad(&"z_player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"b", &"custom", 0, 0, 20, 1, 2),
		_unit(&"a", &"custom", 1, 0, 20, 1, 2),
	])
	var enemy = _squad(&"a_enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"enemy_fast", &"custom", 2, 0, 20, 1, 3),
		_unit(&"enemy_tie", &"custom", 1, 0, 20, 1, 2),
	])
	var order: Array = _battle(player, enemy, 4)["action_order"]
	_expect_equal(order[0], [&"a_enemy", &"enemy_fast"], "higher speed acts first")
	_expect_equal(order[1], [&"z_player", &"a"], "player squad wins same-speed squad tie")
	_expect_equal(order[2], [&"z_player", &"b"], "smaller unit id acts first within squad")
	_expect_equal(order[3], [&"a_enemy", &"enemy_tie"], "enemy same-speed unit follows player squad")

	var enemy_b = _squad(&"b_enemy", &"b", &"npc", Vector2i.ZERO, [_unit(&"u", &"custom", 1, 0, 20, 1, 2)])
	var enemy_a = _squad(&"a_enemy", &"a", &"npc", Vector2i.ZERO, [_unit(&"u", &"custom", 1, 0, 20, 1, 2)])
	_expect_equal(_battle(enemy_b, enemy_a, 4)["action_order"][0][0], &"a_enemy", "smaller non-player squad id wins speed tie")


func _test_instant_death_prevents_action() -> void:
	var fast = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"killer", &"custom", 1, 0, 5, 5, 3),
	])
	var slow = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"victim", &"custom", 1, 0, 3, 99, 1),
	])
	var result := _battle(fast, slow, 5)
	_expect_equal(result["events"].size(), 1, "dead slower unit loses its action")
	_expect_equal(result["action_order"], [[&"player", &"killer"]], "only living attacker appears in executed order")
	_expect_true(not slow.is_alive(), "lethal damage immediately eliminates squad")


func _test_later_unit_retargets_current_battlefield() -> void:
	var attackers = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"a", &"custom", 1, 1, 5, 3, 3),
		_unit(&"b", &"custom", 1, 1, 5, 1, 2),
	])
	var defenders = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"front_center", &"custom", 1, 0, 3, 1, 1),
		_unit(&"front_left", &"custom", 0, 0, 5, 1, 1),
	])
	var events: Array = _battle(attackers, defenders, 6)["events"]
	_expect_equal(events[0]["defender_unit_id"], &"front_center", "first attacker kills facing target")
	_expect_equal(events[1]["defender_unit_id"], &"front_left", "later attacker retargets after death")


func _test_single_attack_has_no_counterattack() -> void:
	var attacker = _squad(&"player", &"player", &"player", Vector2i.ZERO, [_unit(&"a", &"custom", 1, 0, 8, 2, 3)])
	var defender = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [_unit(&"d", &"custom", 1, 0, 8, 5, 1)])
	var result := _battle(attacker, defender, 7)
	_expect_equal(result["events"][0]["damage"], 2, "attack deals only attacker damage")
	_expect_equal(attacker.unit_by_id(&"a").health, 3, "attacker is only damaged when defender later takes its own action")
	_expect_equal(result["events"].size(), 2, "each living unit attacks at most once")


func _test_map_move_wait_wall_and_chain() -> void:
	var states := [
		_squad(&"a", &"neutral", &"npc", Vector2i(1, 1), [_unit(&"a1", &"custom", 1, 0, 5, 1, 1)]),
		_squad(&"b", &"neutral", &"npc", Vector2i(2, 1), [_unit(&"b1", &"custom", 1, 0, 5, 1, 1)]),
		_squad(&"c", &"neutral", &"npc", Vector2i(3, 1), [_unit(&"c1", &"custom", 1, 0, 5, 1, 1)]),
	]
	var chain = _resolve(Vector2i(6, 4), [], states, {
		&"a": _move(&"a", Vector2i.RIGHT), &"b": _move(&"b", Vector2i.RIGHT), &"c": _move(&"c", Vector2i.RIGHT),
	})
	_expect_equal(chain.final_positions[&"a"], Vector2i(2, 1), "chain follows vacated cells")
	_expect_equal(chain.final_positions[&"c"], Vector2i(4, 1), "chain tail reaches empty cell")
	var wall = _resolve(Vector2i(4, 4), [Vector2i(2, 1)], [states[0]], {&"a": _move(&"a", Vector2i.RIGHT)})
	_expect_equal(wall.outcome_for(&"a")["reason"], &"blocked_by_terrain", "terrain still blocks squads")


func _test_head_on_squad_battle_returns_survivors() -> void:
	var player = _squad(&"player", &"player", &"player", Vector2i(1, 1), [_unit(&"p", &"custom", 1, 0, 10, 1, 2)])
	var enemy = _squad(&"enemy", &"enemy", &"npc", Vector2i(2, 1), [_unit(&"e", &"custom", 1, 0, 10, 1, 2)])
	var result = _resolve(Vector2i(5, 3), [], [player, enemy], {
		&"player": _move(&"player", Vector2i.RIGHT), &"enemy": _move(&"enemy", Vector2i.LEFT),
	})
	_expect_equal(result.collision_waves[0]["kind"], &"edge", "reciprocal squads fight at edge midpoint")
	_expect_equal(result.final_positions[&"player"], Vector2i(1, 1), "surviving player squad returns")
	_expect_equal(result.final_positions[&"enemy"], Vector2i(2, 1), "surviving enemy squad returns")
	_expect_equal(result.actor_state_for(&"player").unit_by_id(&"p").health, 9, "persistent unit HP records enemy action")


func _test_sole_squad_survivor_takes_collision_cell() -> void:
	var winner = _squad(&"winner", &"red", &"player", Vector2i(1, 1), [_unit(&"w", &"custom", 1, 0, 5, 5, 3)])
	var loser = _squad(&"loser", &"blue", &"npc", Vector2i(3, 1), [_unit(&"l", &"custom", 1, 0, 3, 1, 1)])
	var result = _resolve(Vector2i(5, 3), [], [winner, loser], {
		&"winner": _move(&"winner", Vector2i.RIGHT), &"loser": _move(&"loser", Vector2i.LEFT),
	})
	_expect_true(result.is_dead(&"loser"), "eliminated squad is removed from map")
	_expect_equal(result.final_positions[&"winner"], Vector2i(2, 1), "sole surviving squad stays in collision cell")
	_expect_equal(result.outcome_for(&"winner")["reason"], &"combat_winner_moved", "map reports moving combat winner")


func _test_squad_damage_persists_across_encounters() -> void:
	var player = _squad(&"player", &"player", &"player", Vector2i(1, 1), [_unit(&"p", &"custom", 1, 0, 10, 1, 2)])
	var enemy = _squad(&"enemy", &"enemy", &"npc", Vector2i(3, 1), [_unit(&"e", &"custom", 1, 0, 10, 1, 2)])
	var intents := {&"player": _move(&"player", Vector2i.RIGHT), &"enemy": _move(&"enemy", Vector2i.LEFT)}
	var first = _resolve(Vector2i(5, 3), [], [player, enemy], intents)
	var second = _resolve(Vector2i(5, 3), [], [first.actor_state_for(&"player"), first.actor_state_for(&"enemy")], intents)
	_expect_equal(first.actor_state_for(&"player").unit_by_id(&"p").health, 9, "first encounter persists damage")
	_expect_equal(second.actor_state_for(&"player").unit_by_id(&"p").health, 8, "second encounter begins from previous HP")


func _test_multi_squad_melee_inherits_damage_and_skips_eliminated() -> void:
	var top = _squad(&"top", &"top", &"npc", Vector2i(2, 1), [_unit(&"t", &"custom", 1, 0, 1, 5, 3)])
	var right = _squad(&"right", &"right", &"npc", Vector2i(3, 2), [_unit(&"r", &"custom", 1, 0, 3, 1, 1)])
	var down = _squad(&"down", &"down", &"npc", Vector2i(2, 3), [_unit(&"d", &"custom", 1, 0, 8, 1, 1)])
	var result = _resolve(Vector2i(5, 5), [], [top, right, down], {
		&"top": _move(&"top", Vector2i.DOWN),
		&"right": _move(&"right", Vector2i.LEFT),
		&"down": _move(&"down", Vector2i.UP),
	})
	var group: Dictionary = result.collision_waves[0]["groups"][0]
	_expect_equal(group["planned_pairs"].size(), 3, "three hostile squads plan C3,2 encounters")
	_expect_true(group["encounters"][0]["second_eliminated"], "top eliminates right in first encounter")
	_expect_equal(group["encounters"][1]["first_squad_id"], &"top", "top carries into second planned encounter")
	_expect_true(group["encounters"][2]["skipped"], "later pair involving eliminated right is skipped")
	_expect_equal(group["encounters"][1]["events"].size(), 2, "top and down both act in the inherited second encounter")
	_expect_true(result.is_dead(&"top") and result.is_dead(&"right"), "sequential melee removes squads immediately")
	_expect_equal(result.final_positions[&"down"], Vector2i(2, 2), "sole melee survivor holds collision cell")


func _test_friendly_squads_do_not_fight() -> void:
	var first = _squad(&"a", &"ally", &"npc", Vector2i(1, 1), [_unit(&"a1", &"custom", 1, 0, 5, 2, 2)])
	var second = _squad(&"b", &"ally", &"npc", Vector2i(3, 1), [_unit(&"b1", &"custom", 1, 0, 5, 2, 2)])
	var result = _resolve(Vector2i(5, 3), [], [first, second], {&"a": _move(&"a", Vector2i.RIGHT), &"b": _move(&"b", Vector2i.LEFT)})
	_expect_equal(result.combat_events.size(), 0, "friendly collision creates no unit attacks")
	_expect_equal(result.outcome_for(&"a")["reason"], &"friendly_collision", "friendly squads return")


func _test_seeded_map_resolution_is_reproducible() -> void:
	var target_ids: Array = []
	for repetition in 2:
		var attacker = _squad(&"player", &"player", &"player", Vector2i(1, 1), [_unit(&"a", &"archer", 1, 1, 10, 1, 3)])
		var defender = _squad(&"enemy", &"enemy", &"npc", Vector2i(3, 1), [
			_unit(&"left", &"custom", 0, 0, 10, 1, 1), _unit(&"right", &"custom", 2, 0, 10, 1, 1),
		])
		var result = _resolve(Vector2i(5, 3), [], [attacker, defender], {&"player": _move(&"player", Vector2i.RIGHT), &"enemy": _move(&"enemy", Vector2i.LEFT)}, 42)
		target_ids.append(result.combat_events[0]["defender_unit_id"])
	_expect_equal(target_ids[0], target_ids[1], "turn-level battle seed reproduces targeting")


func _test_pursuit_ai_is_stable_and_terrain_aware() -> void:
	var controller = DrunkControllerType.new(1)
	var horizontal = controller.choose_pursuit_intent(&"enemy", Vector2i(3, 3), Vector2i(1, 1), {}, Vector2i(6, 6))
	_expect_equal(horizontal.delta, Vector2i.LEFT, "pursuit AI uses stable horizontal-first rule")
	var vertical = controller.choose_pursuit_intent(&"enemy", Vector2i(3, 3), Vector2i(1, 1), {Vector2i(2, 3): true}, Vector2i(6, 6))
	_expect_equal(vertical.delta, Vector2i.UP, "terrain forces learnable vertical alternative")


func _test_main_scene_gm_panel_and_combat() -> void:
	var main = MainScene.instantiate()
	add_child(main)
	await get_tree().process_frame
	_expect_equal(main._actors[&"player"].living_unit_count(), 4, "main scene player starts with four-unit squad")
	_expect_equal(main._actors[&"drunk"].living_unit_count(), 4, "main scene enemy exposes full four-unit formation")
	_expect_equal(main._formation_labels.size(), 6, "GM panel exposes all 2x3 slots")
	main._selected_squad_id = &"player"
	var original_class: StringName = main._actors[&"player"].unit_at(Vector2i(0, 0)).unit_class
	main._cycle_formation_slot(Vector2i(0, 0))
	_expect_true(main._actors[&"player"].unit_at(Vector2i(0, 0)).unit_class != original_class, "GM slot cycles class before movement")
	_expect_true(main._formation_labels[Vector2i(0, 0)].text.contains("HP"), "GM panel shows full unit attributes")
	main._drunk_controller = FixedController.new(_move(&"drunk", Vector2i.LEFT))
	await main._play_turn(_move(&"player", Vector2i.RIGHT))
	_expect_true(main._log_label.text.contains("player_"), "integrated combat log records unit attacker")
	_expect_true(not main._battle_overlay.visible, "battle overlay closes after complete presentation")
	_expect_true(not main._busy, "input unlocks after squad battle animation")
	var preview := get_viewport().get_texture().get_image()
	_expect_true(not preview.is_empty(), "squad prototype renders a viewport")
	_expect_equal(preview.save_png(ProjectSettings.globalize_path("res://.godot/test_preview.png")), OK, "squad preview can be captured")
	main.queue_free()
	await get_tree().process_frame


func _test_slow_motion_requires_one_step_per_action() -> void:
	var main = MainScene.instantiate()
	add_child(main)
	await get_tree().process_frame
	_expect_true(not main._battle_slow_motion_enabled, "slow battle defaults to disabled")
	_expect_true(not main._slow_motion_toggle.button_pressed, "GM slow battle toggle defaults off")
	main._slow_motion_toggle.button_pressed = true
	_expect_true(main._battle_slow_motion_enabled, "GM toggle enables slow battle")

	var first_event := {
		"first_id": &"player", "second_id": &"drunk",
		"attacker_squad_id": &"player", "defender_squad_id": &"drunk",
		"attacker_unit_id": &"p", "defender_unit_id": &"d",
		"damage": 1, "defender_squad_health_after": main._actors[&"drunk"].health - 1,
		"formations_before": {&"player": [], &"drunk": []},
		"formations_after": {&"player": [], &"drunk": []},
	}
	var second_event := first_event.duplicate(true)
	second_event["attacker_squad_id"] = &"drunk"
	second_event["defender_squad_id"] = &"player"
	second_event["attacker_unit_id"] = &"d"
	second_event["defender_unit_id"] = &"p"
	second_event["first_id"] = &"drunk"
	second_event["second_id"] = &"player"
	second_event["defender_squad_health_after"] = main._actors[&"player"].health - 1

	main._play_combat_event_batch([first_event])
	await get_tree().process_frame
	_expect_true(main._waiting_for_combat_step, "slow battle pauses before first action resolves")
	main._advance_slow_battle()
	await get_tree().create_timer(main.COMBAT_EVENT_DURATION * 2.0).timeout
	_expect_true(not main._waiting_for_combat_step, "one space step releases exactly one unit action")

	main._play_combat_event_batch([second_event])
	await get_tree().process_frame
	_expect_true(main._waiting_for_combat_step, "next unit action pauses again")
	main._advance_slow_battle()
	await get_tree().create_timer(main.COMBAT_EVENT_DURATION * 2.0).timeout
	_expect_true(not main._waiting_for_combat_step, "second space step releases second action")
	main.queue_free()
	await get_tree().process_frame


class FixedController:
	extends RefCounted
	var fixed_intent
	func _init(p_intent) -> void: fixed_intent = p_intent
	func choose_pursuit_intent(_a, _b, _c, _d, _e): return fixed_intent


func _unit(id: StringName, unit_class: StringName, column: int, row: int, hp: int, atk: int, speed: int):
	return SquadUnitStateType.new(id, unit_class, Vector2i(column, row), hp, hp, atk, speed)


func _squad(id: StringName, faction: StringName, controller: StringName, cell: Vector2i, units: Array):
	return GridActorStateType.new(id, cell, controller, faction, 1, 1, 1, units)


func _battle(first, second, battle_seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = battle_seed
	return SquadBattleResolverType.resolve_round(first, second, rng)


func _resolve(board_size: Vector2i, walls: Array, states: Array, intents: Dictionary, battle_seed: int = 1337):
	var blocked := {}
	for wall: Vector2i in walls: blocked[wall] = true
	return TurnResolverType.resolve(board_size, blocked, states, intents, battle_seed)


func _move(id: StringName, delta: Vector2i):
	return TurnIntentType.new(id, TurnIntentType.ActionType.MOVE, delta)


func _wait(id: StringName):
	return TurnIntentType.new(id, TurnIntentType.ActionType.WAIT, Vector2i.ZERO)


func _expect_true(condition: bool, message: String) -> void:
	_checks += 1
	if condition: return
	_failures += 1
	push_error("Assertion failed: %s" % message)


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	_checks += 1
	if actual == expected: return
	_failures += 1
	push_error("Assertion failed: %s | expected=%s actual=%s" % [message, expected, actual])
