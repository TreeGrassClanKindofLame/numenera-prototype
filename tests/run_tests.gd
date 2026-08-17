extends Node

const TurnIntentType = preload("res://scripts/model/turn_intent.gd")
const SquadUnitStateType = preload("res://scripts/model/squad_unit_state.gd")
const GridActorStateType = preload("res://scripts/model/grid_actor_state.gd")
const SquadBattleResolverType = preload("res://scripts/core/squad_battle_resolver.gd")
const TurnResolverType = preload("res://scripts/core/turn_resolver.gd")
const EnemyAIControllerType = preload("res://scripts/core/enemy_ai_controller.gd")
const EnemyBrainStateType = preload("res://scripts/model/enemy_brain_state.gd")
const ScenarioCatalogType = preload("res://scripts/core/test_scenario_catalog.gd")
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
	_test_turn_schedule_records_actions_and_skips()
	_test_target_rule_metadata()
	_test_later_unit_retargets_current_battlefield()
	_test_single_attack_has_no_counterattack()
	_test_facing_updates_from_move_intent()
	_test_contact_scores_and_advantage_difference()
	_test_return_collision_keeps_facing_and_scores_again()
	_test_round_zero_selection_and_extra_actions()
	_test_map_move_wait_wall_and_chain()
	_test_head_on_squad_battle_returns_survivors()
	_test_sole_squad_survivor_takes_collision_cell()
	_test_squad_damage_persists_across_encounters()
	_test_multi_squad_melee_inherits_damage_and_skips_eliminated()
	_test_friendly_squads_do_not_fight()
	_test_seeded_map_resolution_is_reproducible()
	_test_robot_patrol_move_wait_loop()
	_test_robot_reverse_and_collision_retry()
	_test_bandit_vision_and_wall_occlusion()
	_test_bandit_tentative_detection_and_pursuit()
	await _test_main_scene_gm_panel_and_combat()
	await _test_enemy_scenario_switching_and_debug()
	await _test_focused_stage_auto_playback()
	await _test_slow_motion_requires_one_step_per_action()
	# Let queued scene/audio frees reach the ObjectDB before the command-line
	# runner exits; otherwise the fast Compatibility run reports transient leaks.
	await get_tree().process_frame
	await get_tree().create_timer(0.15).timeout

	if _failures == 0:
		print("PASS: %d checks across 31 squad-combat scenarios." % _checks)
		get_tree().quit(0)
	else:
		push_error("FAIL: %d of %d checks failed." % [_failures, _checks])
		get_tree().quit(1)


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


func _test_turn_schedule_records_actions_and_skips() -> void:
	var fast = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"killer", &"custom", 1, 0, 5, 5, 3),
		_unit(&"reserve", &"custom", 2, 0, 5, 1, 2),
	])
	var slow = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"victim", &"custom", 1, 0, 3, 99, 1),
	])
	var result := _battle(fast, slow, 51)
	var schedule: Array = result["turn_schedule"]
	_expect_equal(schedule.size(), 3, "turn schedule retains every unit planned at round start")
	_expect_equal(schedule[0]["status"], &"acted", "executed unit is marked acted")
	_expect_equal(schedule[0]["event_index"], 0, "acted schedule entry points at combat event")
	_expect_equal(schedule[1]["skipped_reason"], &"no_living_enemy", "later ally records enemy-eliminated skip")
	_expect_equal(schedule[2]["skipped_reason"], &"actor_dead", "killed unit records actor-dead skip")


func _test_target_rule_metadata() -> void:
	var attacker = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"a", &"warrior", 1, 0, 20, 1, 5),
	])
	var facing = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"f", &"custom", 1, 0, 20, 1, 1),
	])
	var facing_event: Dictionary = _battle(attacker, facing, 52)["events"][0]
	_expect_equal(facing_event["target_rule"], &"preferred_facing", "preferred facing-column rule is explicit")
	_expect_equal(facing_event["target_distance"], 0, "facing target records zero horizontal distance")

	attacker = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"a", &"warrior", 2, 0, 20, 1, 5),
	])
	var nearest = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"n", &"custom", 0, 0, 20, 1, 1),
	])
	var nearest_event: Dictionary = _battle(attacker, nearest, 53)["events"][0]
	_expect_equal(nearest_event["target_rule"], &"preferred_nearest", "preferred nearest-column rule is explicit")
	_expect_equal(nearest_event["target_distance"], 2, "nearest target records horizontal distance")

	attacker = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"a", &"warrior", 1, 0, 20, 1, 5),
	])
	var fallback_facing = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"b", &"custom", 1, 1, 20, 1, 1),
	])
	_expect_equal(_battle(attacker, fallback_facing, 54)["events"][0]["target_rule"], &"fallback_facing", "fallback facing-column rule is explicit")

	attacker = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"a", &"warrior", 2, 0, 20, 1, 5),
	])
	var fallback_nearest = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"b", &"custom", 0, 1, 20, 1, 1),
	])
	_expect_equal(_battle(attacker, fallback_nearest, 55)["events"][0]["target_rule"], &"fallback_nearest", "fallback nearest-column rule is explicit")


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


func _test_facing_updates_from_move_intent() -> void:
	var actor = _squad(&"actor", &"player", &"player", Vector2i(1, 1), [
		_unit(&"u", &"warrior", 1, 0, 10, 1, 1),
	])
	var bumped = _resolve(
		Vector2i(4, 4), [Vector2i(0, 1)], [actor],
		{&"actor": _move(&"actor", Vector2i.LEFT)}
	)
	_expect_equal(bumped.actor_state_for(&"actor").cell, Vector2i(1, 1), "wall bump does not move squad")
	_expect_equal(bumped.actor_state_for(&"actor").facing, Vector2i.LEFT, "wall bump still turns squad")
	var waited = _resolve(
		Vector2i(4, 4), [], [bumped.actor_state_for(&"actor")],
		{&"actor": _wait(&"actor")}
	)
	_expect_equal(waited.actor_state_for(&"actor").facing, Vector2i.LEFT, "wait preserves facing")
	var edge_actor = _squad(&"edge", &"player", &"player", Vector2i.ZERO, [
		_unit(&"edge_u", &"warrior", 1, 0, 10, 1, 1),
	])
	var out_of_bounds = _resolve(
		Vector2i(4, 4), [], [edge_actor],
		{&"edge": _move(&"edge", Vector2i.UP)}
	)
	_expect_equal(out_of_bounds.actor_state_for(&"edge").facing, Vector2i.UP, "out-of-bounds move still turns squad")


func _test_contact_scores_and_advantage_difference() -> void:
	var cases := [
		[Vector2i.DOWN, &"front", 2, 0],
		[Vector2i.RIGHT, &"side", 1, 1],
		[Vector2i.UP, &"back", 0, 2],
	]
	for case_data: Array in cases:
		var mover = _squad(&"mover", &"mover", &"player", Vector2i(1, 2), [
			_unit(&"m", &"warrior", 1, 0, 20, 1, 1),
		], Vector2i.DOWN)
		var defender = _squad(&"defender", &"defender", &"npc", Vector2i(1, 1), [
			_unit(&"d", &"tank", 1, 0, 20, 1, 1),
		], case_data[0])
		var resolution = _resolve(
			Vector2i(4, 4), [], [mover, defender],
			{&"mover": _move(&"mover", Vector2i.UP), &"defender": _wait(&"defender")},
			700 + case_data[2]
		)
		var encounter: Dictionary = resolution.collision_waves[0]["groups"][0]["encounters"][0]
		var engagement: Dictionary = encounter["engagement"]
		_expect_equal(engagement["first_contact"]["side"], &"front", "moving squad presents its front")
		_expect_equal(engagement["first_score"], 2, "moving front scores two")
		_expect_equal(engagement["second_contact"]["side"], case_data[1], "waiting squad contact side is classified")
		_expect_equal(engagement["second_score"], case_data[2], "waiting squad contact score matches side")
		_expect_equal(encounter["first_advantage"], case_data[3], "higher score receives only the score difference")


func _test_return_collision_keeps_facing_and_scores_again() -> void:
	var a = _squad(&"a", &"a", &"npc", Vector2i(1, 0), [
		_unit(&"a_u", &"tank", 1, 0, 30, 1, 1),
	], Vector2i.DOWN)
	var b = _squad(&"b", &"b", &"npc", Vector2i(1, 1), [
		_unit(&"b_u", &"tank", 1, 0, 30, 1, 1),
	], Vector2i.DOWN)
	var c = _squad(&"c", &"c", &"npc", Vector2i(1, 2), [
		_unit(&"c_u", &"tank", 1, 0, 30, 1, 1),
	], Vector2i.DOWN)
	var resolution = _resolve(
		Vector2i(3, 4), [], [a, b, c], {
			&"a": _wait(&"a"),
			&"b": _move(&"b", Vector2i.UP),
			&"c": _move(&"c", Vector2i.UP),
		}, 812
	)
	_expect_equal(resolution.collision_waves.size(), 2, "combat return creates a second collision wave")
	var second_encounter: Dictionary = resolution.collision_waves[1]["groups"][0]["encounters"][0]
	var engagement: Dictionary = second_encounter["engagement"]
	_expect_equal(engagement["first_contact"]["side"], &"back", "returning B keeps facing up and enters backward")
	_expect_equal(engagement["first_score"], 0, "backward return scores zero")
	_expect_equal(engagement["second_contact"]["side"], &"front", "C enters the return collision from its front")
	_expect_equal(second_encounter["second_advantage"], 2, "C gains two advantage from front versus back")


func _test_round_zero_selection_and_extra_actions() -> void:
	var first = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"p0", &"tank", 0, 0, 20, 1, 1),
		_unit(&"p1", &"warrior", 1, 0, 20, 1, 2),
		_unit(&"p2", &"archer", 2, 0, 20, 1, 2),
		_unit(&"p3", &"assassin", 1, 1, 20, 1, 3),
	])
	var second = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"enemy_u", &"tank", 1, 0, 50, 1, 1),
	])
	var result := _battle(first, second, 901, 2, 0)
	var selected: Array = result["round_zero_selected"][&"player"]
	_expect_equal(selected.size(), 2, "two advantage selects two units")
	_expect_true(selected[0] != selected[1], "round-zero selection has no duplicates")
	_expect_equal(result["turn_schedule"][0]["phase"], &"round_zero", "round zero is scheduled first")
	_expect_equal(result["turn_schedule"][1]["phase"], &"round_zero", "both advantage actions are in round zero")
	for unit_id: StringName in selected:
		var normal_action_found := false
		for entry: Dictionary in result["turn_schedule"]:
			if entry["phase"] == &"round_one" and entry["unit_id"] == unit_id:
				normal_action_found = true
		_expect_true(normal_action_found, "round-zero unit can act again in round one")
	var repeat_first = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"p0", &"tank", 0, 0, 20, 1, 1),
		_unit(&"p1", &"warrior", 1, 0, 20, 1, 2),
		_unit(&"p2", &"archer", 2, 0, 20, 1, 2),
		_unit(&"p3", &"assassin", 1, 1, 20, 1, 3),
	])
	var repeat_second = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"enemy_u", &"tank", 1, 0, 50, 1, 1),
	])
	var repeated := _battle(repeat_first, repeat_second, 901, 2, 0)
	_expect_equal(repeated["round_zero_selected"][&"player"], selected, "same seed reproduces round-zero selection and order")
	var finishers = _squad(&"finishers", &"finishers", &"player", Vector2i.ZERO, [
		_unit(&"f0", &"warrior", 0, 0, 10, 2, 2),
		_unit(&"f1", &"warrior", 1, 0, 10, 2, 2),
	])
	var fragile = _squad(&"fragile", &"fragile", &"npc", Vector2i.ZERO, [
		_unit(&"fragile_u", &"custom", 1, 0, 1, 1, 1),
	])
	var lethal_zero := _battle(finishers, fragile, 902, 2, 0)
	_expect_true(lethal_zero.get("round_one_cancelled", false), "round one is cancelled when round zero eliminates a squad")
	_expect_equal(lethal_zero["turn_schedule"].size(), 2, "remaining selected round-zero unit is retained as a skipped schedule entry")
	_expect_equal(lethal_zero["turn_schedule"][1]["skipped_reason"], &"no_living_enemy", "remaining round-zero action skips after elimination")


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


func _test_robot_patrol_move_wait_loop() -> void:
	var controller = EnemyAIControllerType.new()
	var path: Array = ScenarioCatalogType.definition(&"robot")["patrol_path"]
	var brain = EnemyBrainStateType.new(&"robot", EnemyBrainStateType.BEHAVIOR_ROBOT, path)
	var robot = _squad(&"robot", &"robot", &"npc", path[0], [
		_unit(&"robot_u", &"tank", 1, 0, 30, 0, 1),
	], Vector2i.RIGHT)
	var move_count := 0
	var wait_count := 0
	for turn_index in 16:
		var intent = controller.choose_intent(brain, robot, null, {}, Vector2i(12, 8))
		if turn_index == 0:
			_expect_equal(intent.delta, Vector2i.RIGHT, "robot begins clockwise from the patrol top-left")
		if intent.action_type == TurnIntentType.ActionType.MOVE:
			move_count += 1
		else:
			wait_count += 1
		var resolution = _resolve(
			Vector2i(12, 8), [], [robot], {&"robot": intent}, 1000 + turn_index
		)
		controller.commit_after_turn(brain, resolution, {}, Vector2i(12, 8))
		robot = resolution.actor_state_for(&"robot")
	_expect_equal(move_count, 8, "robot moves exactly eight times in a sixteen-turn loop")
	_expect_equal(wait_count, 8, "robot waits after every patrol move")
	_expect_equal(robot.cell, path[0], "robot completes the 3x3 perimeter loop")
	_expect_equal(brain.patrol_index, 0, "patrol index returns to its starting waypoint")
	_expect_true(brain.move_turn, "robot is ready to move after the final wait turn")


func _test_robot_reverse_and_collision_retry() -> void:
	var controller = EnemyAIControllerType.new()
	var path: Array = ScenarioCatalogType.definition(&"robot")["patrol_path"]
	var brain = EnemyBrainStateType.new(&"robot", EnemyBrainStateType.BEHAVIOR_ROBOT, path)
	brain.patrol_index = 1
	var robot = _squad(&"robot", &"robot", &"npc", path[1], [
		_unit(&"robot_u", &"tank", 1, 0, 30, 0, 1),
	], Vector2i.RIGHT)
	var wall_map := {path[2]: true}
	var reverse_intent = controller.choose_intent(
		brain, robot, null, wall_map, Vector2i(12, 8)
	)
	_expect_equal(brain.patrol_direction, -1, "blocked clockwise waypoint reverses patrol direction immediately")
	_expect_equal(reverse_intent.delta, Vector2i.LEFT, "robot moves counterclockwise in the same turn")
	var reverse_result = _resolve(
		Vector2i(12, 8), [path[2]], [robot], {&"robot": reverse_intent}, 1101
	)
	controller.commit_after_turn(brain, reverse_result, wall_map, Vector2i(12, 8))
	_expect_equal(brain.patrol_index, 0, "successful reverse movement commits the previous waypoint")

	var collision_brain = EnemyBrainStateType.new(&"robot", EnemyBrainStateType.BEHAVIOR_ROBOT, path)
	var collision_robot = _squad(&"robot", &"robot", &"npc", path[0], [
		_unit(&"robot_c", &"custom", 1, 0, 30, 0, 1),
	], Vector2i.RIGHT)
	var blocker = _squad(&"blocker", &"blocker", &"npc", path[1], [
		_unit(&"blocker_u", &"custom", 1, 0, 30, 0, 1),
	], Vector2i.LEFT)
	var collision_intent = controller.choose_intent(
		collision_brain, collision_robot, null, {}, Vector2i(12, 8)
	)
	var collision_result = _resolve(
		Vector2i(12, 8), [], [collision_robot, blocker], {
			&"robot": collision_intent, &"blocker": _wait(&"blocker"),
		}, 1102
	)
	controller.commit_after_turn(collision_brain, collision_result, {}, Vector2i(12, 8))
	_expect_equal(collision_result.final_positions[&"robot"], path[0], "surviving robot returns after collision")
	_expect_equal(collision_brain.patrol_index, 0, "collision return does not advance patrol progress")
	_expect_true(not collision_brain.move_turn, "collision attempt is followed by a wait phase")
	var wait_intent = controller.choose_intent(
		collision_brain, collision_result.actor_state_for(&"robot"), null, {}, Vector2i(12, 8)
	)
	_expect_equal(wait_intent.action_type, TurnIntentType.ActionType.WAIT, "robot waits before retrying a collision waypoint")
	var wait_result = _resolve(
		Vector2i(12, 8), [], [collision_result.actor_state_for(&"robot")],
		{&"robot": wait_intent}, 1103
	)
	controller.commit_after_turn(collision_brain, wait_result, {}, Vector2i(12, 8))
	var retry = controller.choose_intent(
		collision_brain, wait_result.actor_state_for(&"robot"), null, {}, Vector2i(12, 8)
	)
	_expect_equal(retry.delta, Vector2i.RIGHT, "robot retries the uncommitted waypoint after waiting")


func _test_bandit_vision_and_wall_occlusion() -> void:
	var controller = EnemyAIControllerType.new()
	var origin := Vector2i(4, 4)
	var visible := controller.vision_cells(origin, Vector2i.UP, {}, Vector2i(10, 10))
	for expected: Vector2i in [
		Vector2i(3, 4), Vector2i(5, 4),
		Vector2i(3, 3), Vector2i(4, 3), Vector2i(5, 3),
		Vector2i(3, 2), Vector2i(4, 2), Vector2i(5, 2),
		Vector2i(2, 1), Vector2i(4, 1), Vector2i(6, 1),
	]:
		_expect_true(visible.has(expected), "bandit vision includes shortened continuous cone cell %s" % expected)
	for hidden: Vector2i in [
		Vector2i(2, 4), Vector2i(6, 4),
		Vector2i(3, 5), Vector2i(4, 5), Vector2i(5, 5),
		Vector2i(4, 0),
	]:
		_expect_true(not visible.has(hidden), "bandit vision excludes distant side, rear, or fourth-layer cell %s" % hidden)
	var wall_visible := controller.vision_cells(
		origin, Vector2i.UP, {Vector2i(4, 2): true}, Vector2i(10, 10)
	)
	_expect_true(not wall_visible.has(Vector2i(4, 1)), "terrain hides cone cells behind it")
	var right_visible := controller.vision_cells(
		origin, Vector2i.RIGHT, {}, Vector2i(10, 10)
	)
	_expect_true(right_visible.has(Vector2i(7, 4)), "vision cone rotates with a right-facing bandit")
	_expect_true(right_visible.has(Vector2i(4, 3)), "immediate side vision rotates with bandit facing")
	_expect_true(not right_visible.has(Vector2i(3, 3)), "rear diagonal remains blind after rotating")


func _test_bandit_tentative_detection_and_pursuit() -> void:
	var controller = EnemyAIControllerType.new()
	var brain = EnemyBrainStateType.new(&"bandit", EnemyBrainStateType.BEHAVIOR_BANDIT)
	var player = _squad(&"player", &"player", &"player", Vector2i(1, 2), [
		_unit(&"p", &"custom", 1, 0, 30, 0, 1),
	], Vector2i.RIGHT)
	var blocker = _squad(&"blocker", &"bandit", &"npc", Vector2i(2, 2), [
		_unit(&"block", &"custom", 1, 0, 30, 0, 1),
	], Vector2i.LEFT)
	var bandit = _squad(&"bandit", &"bandit", &"npc", Vector2i(5, 2), [
		_unit(&"b", &"warrior", 1, 0, 30, 0, 1),
	], Vector2i.LEFT)
	var resolution = _resolve(
		Vector2i(8, 5), [], [player, blocker, bandit], {
			&"player": _move(&"player", Vector2i.RIGHT),
			&"blocker": _wait(&"blocker"),
			&"bandit": _wait(&"bandit"),
		}, 1201
	)
	_expect_equal(resolution.final_positions[&"player"], Vector2i(1, 2), "player returns after entering an occupied visible cell")
	var alert_events := controller.commit_after_turn(
		brain, resolution, {}, Vector2i(8, 5)
	)
	_expect_true(brain.alerted, "bandit detects the player's tentative pre-return position")
	_expect_equal(alert_events[0]["kind"], &"bandit_alerted", "detection emits an explicit alert event")
	var pursuit = controller.choose_intent(
		brain,
		resolution.actor_state_for(&"bandit"),
		resolution.actor_state_for(&"player"),
		{},
		Vector2i(8, 5)
	)
	_expect_equal(pursuit.delta, Vector2i.LEFT, "alerted bandit pursues on the following turn")
	var tie_bandit = _squad(&"tie", &"bandit", &"npc", Vector2i(3, 3), [
		_unit(&"tie_u", &"warrior", 1, 0, 20, 1, 1),
	], Vector2i.UP)
	var tie_player = _squad(&"target", &"player", &"player", Vector2i(2, 2), [
		_unit(&"target_u", &"custom", 1, 0, 20, 0, 1),
	])
	var tie_brain = EnemyBrainStateType.new(&"tie", EnemyBrainStateType.BEHAVIOR_BANDIT)
	tie_brain.alerted = true
	var tie_intent = controller.choose_intent(
		tie_brain, tie_bandit, tie_player, {}, Vector2i(7, 7)
	)
	_expect_equal(tie_intent.delta, Vector2i.UP, "equal shortest paths prefer continuing forward")
	var trapped := {
		Vector2i(3, 2): true, Vector2i(2, 3): true,
		Vector2i(4, 3): true, Vector2i(3, 4): true,
	}
	var trapped_intent = controller.choose_intent(
		tie_brain, tie_bandit, tie_player, trapped, Vector2i(7, 7)
	)
	_expect_equal(trapped_intent.action_type, TurnIntentType.ActionType.WAIT, "bandit waits when no path exists")


func _test_main_scene_gm_panel_and_combat() -> void:
	var main = MainScene.instantiate()
	add_child(main)
	await get_tree().process_frame
	_expect_equal(main._actors[&"player"].living_unit_count(), 4, "main scene player starts with four-unit squad")
	_expect_equal(main._actors[&"dummy"].living_unit_count(), 4, "main scene dummy exposes full four-unit formation")
	_expect_equal(main._actors[&"dummy"].attack, 0, "dummy squad cannot damage the player")
	_expect_equal(main._actors[&"dummy"].health, 200, "dummy squad has durable test health")
	_expect_equal(main._formation_labels.size(), 6, "GM panel exposes all 2x3 slots")
	main._selected_squad_id = &"player"
	var original_class: StringName = main._actors[&"player"].unit_at(Vector2i(0, 0)).unit_class
	main._cycle_formation_slot(Vector2i(0, 0))
	_expect_true(main._actors[&"player"].unit_at(Vector2i(0, 0)).unit_class != original_class, "GM slot cycles class before movement")
	_expect_true(main._formation_labels[Vector2i(0, 0)].text.contains("HP"), "GM panel shows full unit attributes")
	await main._play_turn(_move(&"player", Vector2i.RIGHT))
	await main._play_turn(_move(&"player", Vector2i.DOWN))
	await main._play_turn(_move(&"player", Vector2i.RIGHT))
	_expect_true(main._log_label.text.contains("player_"), "integrated combat log records unit attacker")
	_expect_equal(main._actors[&"dummy"].cell, Vector2i(3, 2), "dummy waits at its open test cell")
	_expect_equal(main._actors[&"dummy"].facing, Vector2i.DOWN, "dummy keeps its initial downward facing")
	_expect_true(not main._battle_overlay.visible, "battle overlay closes after complete presentation")
	_expect_true(not main._busy, "input unlocks after squad battle animation")
	var preview := get_viewport().get_texture().get_image()
	_expect_true(not preview.is_empty(), "squad prototype renders a viewport")
	_expect_equal(preview.save_png(ProjectSettings.globalize_path("res://.godot/test_preview.png")), OK, "squad preview can be captured")
	main.queue_free()
	await get_tree().process_frame


func _test_enemy_scenario_switching_and_debug() -> void:
	var main = MainScene.instantiate()
	add_child(main)
	await get_tree().process_frame
	_expect_equal(main._scenario_buttons.size(), 3, "GM panel exposes all three enemy test modes")
	_expect_true(main._ai_debug_toggle.button_pressed, "AI debug overlay defaults to visible")
	main._switch_scenario(ScenarioCatalogType.SCENARIO_ROBOT)
	await get_tree().process_frame
	_expect_equal(main._scenario_id, &"robot", "robot test mode becomes active")
	_expect_true(main._actors.has(&"robot"), "robot scenario spawns a robot squad")
	_expect_equal(main._enemy_brains[&"robot"].patrol_path.size(), 8, "robot scenario exposes the 3x3 perimeter")
	var robot_classes: Array = []
	for unit in main._actors[&"robot"].units:
		robot_classes.append(unit.unit_class)
	_expect_equal(robot_classes.count(&"tank"), 2, "robot formation contains two tanks")
	_expect_equal(robot_classes.count(&"archer"), 2, "robot formation contains two archers")
	var robot_preview := get_viewport().get_texture().get_image()
	_expect_equal(robot_preview.save_png(ProjectSettings.globalize_path("res://.godot/robot_scenario_preview.png")), OK, "robot debug scenario can be captured")
	await main._play_turn(_wait(&"player"))
	_expect_equal(main._actors[&"robot"].cell, Vector2i(7, 2), "robot moves clockwise on scenario turn one")
	await main._play_turn(_wait(&"player"))
	_expect_equal(main._actors[&"robot"].cell, Vector2i(7, 2), "robot waits on scenario turn two")
	main._switch_scenario(ScenarioCatalogType.SCENARIO_BANDIT)
	await get_tree().process_frame
	_expect_equal(main._turn_number, 1, "scenario switch resets turn count")
	_expect_true(not main._enemy_brains[&"bandit"].alerted, "bandit scenario begins unaware")
	var bandit_classes: Array = []
	for unit in main._actors[&"bandit"].units:
		bandit_classes.append(unit.unit_class)
	_expect_equal(bandit_classes.count(&"warrior"), 2, "bandit formation contains two warriors")
	_expect_equal(bandit_classes.count(&"assassin"), 2, "bandit formation contains two assassins")
	var bandit_preview := get_viewport().get_texture().get_image()
	_expect_equal(bandit_preview.save_png(ProjectSettings.globalize_path("res://.godot/bandit_scenario_preview.png")), OK, "bandit vision scenario can be captured")
	main._ai_debug_toggle.button_pressed = false
	main._switch_scenario(ScenarioCatalogType.SCENARIO_DUMMY)
	await get_tree().process_frame
	_expect_true(not main._ai_debug_toggle.button_pressed, "scenario switch preserves the debug overlay preference")
	_expect_true(main._actors.has(&"dummy"), "dummy scenario restores the stationary target")
	main.queue_free()
	await get_tree().process_frame


func _test_focused_stage_auto_playback() -> void:
	var main = MainScene.instantiate()
	add_child(main)
	await get_tree().process_frame
	var first = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"p", &"warrior", 1, 0, 5, 2, 2),
	])
	var second = _squad(&"enemy", &"enemy", &"npc", Vector2i.ZERO, [
		_unit(&"e", &"tank", 1, 0, 8, 1, 1),
	])
	var encounter := _battle(first, second, 61)
	main._battle_slow_motion_enabled = false
	main._play_squad_encounter(encounter, {
		"wave_index": 0, "group_index": 0, "group_count": 2,
		"pair_index": 0, "pair_count": 1,
	})
	await get_tree().process_frame
	_expect_true(main._battle_overlay.visible, "focused battle stage stays visible during encounter")
	_expect_true(main._battle_overlay.headline.contains("同步冲突点 1/2"), "stage identifies sequential replay inside simultaneous wave")
	_expect_true(not main._waiting_for_combat_step, "automatic playback never waits for space")
	var stage_preview := get_viewport().get_texture().get_image()
	_expect_equal(stage_preview.save_png(ProjectSettings.globalize_path("res://.godot/focused_stage_preview.png")), OK, "focused battle stage can be captured")
	await get_tree().create_timer(main.COMBAT_EVENT_DURATION * 3.0 + main.RESULT_HOLD_DURATION).timeout
	_expect_equal(main._battle_overlay.mode, &"result", "automatic encounter reaches persistent result state before caller closes it")
	main._battle_overlay.end_encounter()
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

	var first = _squad(&"player", &"player", &"player", Vector2i.ZERO, [
		_unit(&"p", &"warrior", 1, 0, 5, 2, 2),
	])
	var second = _squad(&"dummy", &"dummy", &"npc", Vector2i.ZERO, [
		_unit(&"d", &"tank", 1, 0, 8, 1, 1),
	])
	var encounter := _battle(first, second, 62, 1, 0)
	main._play_squad_encounter(encounter, {
		"wave_index": 0, "group_index": 0, "group_count": 1,
		"pair_index": 0, "pair_count": 1,
	})
	await get_tree().process_frame
	_expect_true(main._waiting_for_combat_step, "slow battle pauses before first action resolves")
	_expect_true(main._battle_overlay.detail_text.contains("第零回合"), "slow battle identifies the round-zero action")
	main._advance_slow_battle()
	await get_tree().create_timer(main.COMBAT_EVENT_DURATION * 1.2).timeout
	_expect_true(main._waiting_for_combat_step, "round one pauses after the round-zero action")
	main._advance_slow_battle()
	await get_tree().create_timer(main.COMBAT_EVENT_DURATION * 1.2).timeout
	_expect_true(main._waiting_for_combat_step, "next normal unit action pauses again")
	main._advance_slow_battle()
	await get_tree().create_timer(main.COMBAT_EVENT_DURATION * 1.2).timeout
	_expect_true(main._waiting_for_combat_step, "slow battle pauses again on result confirmation")
	_expect_equal(main._battle_overlay.mode, &"result", "result screen remains visible while awaiting confirmation")
	main._advance_slow_battle()
	await get_tree().process_frame
	_expect_true(not main._waiting_for_combat_step, "extra space confirms result and releases encounter")
	main._battle_overlay.end_encounter()
	main.queue_free()
	await get_tree().process_frame


func _unit(id: StringName, unit_class: StringName, column: int, row: int, hp: int, atk: int, speed: int):
	return SquadUnitStateType.new(id, unit_class, Vector2i(column, row), hp, hp, atk, speed)


func _squad(
	id: StringName,
	faction: StringName,
	controller: StringName,
	cell: Vector2i,
	units: Array,
	facing: Vector2i = Vector2i.DOWN
):
	return GridActorStateType.new(id, cell, controller, faction, 1, 1, 1, units, facing)


func _battle(first, second, battle_seed: int, first_advantage: int = 0, second_advantage: int = 0) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = battle_seed
	return SquadBattleResolverType.resolve_round(first, second, rng, first_advantage, second_advantage)


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
