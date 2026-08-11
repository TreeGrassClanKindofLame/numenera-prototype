extends Node

const TurnIntentType = preload("res://scripts/model/turn_intent.gd")
const GridActorStateType = preload("res://scripts/model/grid_actor_state.gd")
const TurnResolverType = preload("res://scripts/core/turn_resolver.gd")
const DrunkControllerType = preload("res://scripts/core/drunk_controller.gd")
const MainScene = preload("res://scenes/main.tscn")

var _failures := 0
var _checks := 0


class FixedController:
	extends RefCounted
	var fixed_intent

	func _init(p_intent) -> void:
		fixed_intent = p_intent

	func choose_intent(_actor_id: StringName):
		return fixed_intent


func _ready() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_test_move_to_empty_and_wait()
	_test_wall_and_bounds_fail()
	_test_friendly_target_collision()
	_test_head_on_swap_causes_combat()
	_test_friendly_head_on_collision_returns()
	_test_chain_into_empty_succeeds()
	_test_four_actor_cycle_succeeds()
	_test_friendly_waiter_blocks()
	_test_failed_middle_actor_propagates_failure()
	_test_abc_no_second_wave_when_a_dies()
	_test_abc_return_creates_second_wave()
	_test_independent_groups_share_wave()
	_test_three_wave_return_cascade()
	_test_blocked_actor_can_be_collided_at_origin()
	_test_edge_wave_precedes_independent_grid_wave()
	_test_four_actor_mixed_faction_collision()
	_test_final_state_invariants()
	_test_drunk_rng_is_reproducible()
	_test_actor_state_clone_and_stats()
	_test_two_round_player_drunk_combat()
	_test_stationary_defender_is_sole_survivor()
	_test_mutual_death_empties_target()
	_test_directional_pair_order_and_delayed_death()
	_test_mixed_factions_only_fight_hostile_pairs()
	_test_combat_return_blocks_upstream_move()
	_test_combat_death_releases_origin()
	await _test_main_scene_combat_flow()
	await _test_main_scene_player_death_stops_input()

	if _failures == 0:
		print("PASS: %d checks across 28 synchronous-turn and combat scenarios." % _checks)
	else:
		push_error("FAIL: %d of %d checks failed." % [_failures, _checks])


func _test_move_to_empty_and_wait() -> void:
	var result = _resolve_neutral(
		Vector2i(5, 5), [],
		{&"a": Vector2i(1, 1), &"b": Vector2i(3, 3)},
		{&"a": _move(&"a", Vector2i.RIGHT), &"b": _wait(&"b")}
	)
	_expect_equal(result.final_positions[&"a"], Vector2i(2, 1), "move to empty succeeds")
	_expect_equal(result.final_positions[&"b"], Vector2i(3, 3), "wait keeps position")
	_expect_true(result.outcome_for(&"b")["success"], "wait is a successful action")


func _test_wall_and_bounds_fail() -> void:
	var result = _resolve_neutral(
		Vector2i(4, 4), [Vector2i(2, 1)],
		{&"a": Vector2i(1, 1), &"b": Vector2i(0, 0)},
		{&"a": _move(&"a", Vector2i.RIGHT), &"b": _move(&"b", Vector2i.LEFT)}
	)
	_expect_equal(result.outcome_for(&"a")["reason"], &"blocked_by_terrain", "terrain blocks movement")
	_expect_equal(result.outcome_for(&"b")["reason"], &"out_of_bounds", "board edge blocks movement")


func _test_friendly_target_collision() -> void:
	var result = _resolve_neutral(
		Vector2i(5, 3), [],
		{&"a": Vector2i(1, 1), &"b": Vector2i(3, 1)},
		{&"a": _move(&"a", Vector2i.RIGHT), &"b": _move(&"b", Vector2i.LEFT)}
	)
	_expect_equal(result.final_positions[&"a"], Vector2i(1, 1), "first friendly claimant returns")
	_expect_equal(result.final_positions[&"b"], Vector2i(3, 1), "second friendly claimant returns")
	_expect_equal(result.outcome_for(&"a")["reason"], &"friendly_collision", "friendly conflict reason is reported")
	_expect_equal(result.combat_events.size(), 0, "friendly collision deals no damage")


func _test_head_on_swap_causes_combat() -> void:
	var result = _resolve_states(
		Vector2i(5, 3), [],
		[
			_state(&"a", Vector2i(1, 1), &"red", 5, 1),
			_state(&"b", Vector2i(2, 1), &"blue", 5, 1),
		],
		{&"a": _move(&"a", Vector2i.RIGHT), &"b": _move(&"b", Vector2i.LEFT)}
	)
	_expect_equal(result.final_positions[&"a"], Vector2i(1, 1), "surviving head-on actor a returns")
	_expect_equal(result.final_positions[&"b"], Vector2i(2, 1), "surviving head-on actor b returns")
	_expect_equal(result.actor_state_for(&"a").health, 4, "head-on collision damages first actor")
	_expect_equal(result.actor_state_for(&"b").health, 4, "head-on collision damages second actor")
	_expect_equal(result.combat_events.size(), 1, "head-on crossing creates one combat pair")
	_expect_equal(result.collision_groups[0]["center"], Vector2(1.5, 1.0), "head-on collision is staged between cells")
	_expect_equal(result.collision_waves.size(), 1, "head-on crossing creates one collision wave")
	_expect_equal(result.collision_waves[0]["kind"], &"edge", "reciprocal move uses edge collision wave")
	_expect_equal(result.combat_events[0]["wave_index"], 0, "head-on event records its wave")

	var lethal = _resolve_states(
		Vector2i(5, 3), [],
		[
			_state(&"winner", Vector2i(1, 1), &"red", 5, 2),
			_state(&"loser", Vector2i(2, 1), &"blue", 1, 1),
		],
		{&"winner": _move(&"winner", Vector2i.RIGHT), &"loser": _move(&"loser", Vector2i.LEFT)}
	)
	_expect_true(lethal.is_dead(&"loser"), "lethal head-on collision removes loser")
	_expect_equal(lethal.final_positions[&"winner"], Vector2i(2, 1), "sole head-on winner completes intended move")


func _test_friendly_head_on_collision_returns() -> void:
	var result = _resolve_neutral(
		Vector2i(5, 3), [],
		{&"a": Vector2i(1, 1), &"b": Vector2i(2, 1)},
		{&"a": _move(&"a", Vector2i.RIGHT), &"b": _move(&"b", Vector2i.LEFT)}
	)
	_expect_equal(result.final_positions[&"a"], Vector2i(1, 1), "friendly head-on actor a returns")
	_expect_equal(result.final_positions[&"b"], Vector2i(2, 1), "friendly head-on actor b returns")
	_expect_equal(result.combat_events.size(), 0, "friendly head-on collision causes no damage")
	_expect_equal(result.collision_waves[0]["kind"], &"edge", "friendly reciprocal move still uses edge wave")


func _test_chain_into_empty_succeeds() -> void:
	var result = _resolve_neutral(
		Vector2i(6, 3), [],
		{&"a": Vector2i(1, 1), &"b": Vector2i(2, 1), &"c": Vector2i(3, 1)},
		{
			&"a": _move(&"a", Vector2i.RIGHT),
			&"b": _move(&"b", Vector2i.RIGHT),
			&"c": _move(&"c", Vector2i.RIGHT),
		}
	)
	_expect_equal(result.final_positions[&"a"], Vector2i(2, 1), "chain head follows vacated cell")
	_expect_equal(result.final_positions[&"b"], Vector2i(3, 1), "chain middle follows vacated cell")
	_expect_equal(result.final_positions[&"c"], Vector2i(4, 1), "chain tail enters empty cell")


func _test_four_actor_cycle_succeeds() -> void:
	var result = _resolve_neutral(
		Vector2i(5, 5), [],
		{
			&"a": Vector2i(1, 1), &"b": Vector2i(2, 1),
			&"c": Vector2i(2, 2), &"d": Vector2i(1, 2),
		},
		{
			&"a": _move(&"a", Vector2i.RIGHT), &"b": _move(&"b", Vector2i.DOWN),
			&"c": _move(&"c", Vector2i.LEFT), &"d": _move(&"d", Vector2i.UP),
		}
	)
	for actor_id: StringName in [&"a", &"b", &"c", &"d"]:
		_expect_true(result.outcome_for(actor_id)["moved"], "cycle actor %s moves" % actor_id)


func _test_friendly_waiter_blocks() -> void:
	var result = _resolve_neutral(
		Vector2i(5, 3), [],
		{&"a": Vector2i(1, 1), &"b": Vector2i(2, 1)},
		{&"a": _move(&"a", Vector2i.RIGHT), &"b": _wait(&"b")}
	)
	_expect_equal(result.final_positions[&"a"], Vector2i(1, 1), "actor cannot enter friendly waiter's cell")
	_expect_equal(result.outcome_for(&"a")["reason"], &"friendly_collision", "friendly waiter causes collision return")


func _test_failed_middle_actor_propagates_failure() -> void:
	var result = _resolve_neutral(
		Vector2i(6, 5), [],
		{&"a": Vector2i(1, 1), &"b": Vector2i(2, 1), &"c": Vector2i(3, 2)},
		{
			&"a": _move(&"a", Vector2i.RIGHT),
			&"b": _move(&"b", Vector2i.RIGHT),
			&"c": _move(&"c", Vector2i.UP),
		}
	)
	_expect_equal(result.outcome_for(&"b")["reason"], &"friendly_collision", "middle actor loses friendly destination")
	_expect_equal(result.outcome_for(&"a")["reason"], &"friendly_collision", "returned middle actor collides with follower")
	_expect_equal(result.collision_waves.size(), 2, "friendly return creates a second collision wave")


func _test_abc_no_second_wave_when_a_dies() -> void:
	var result = _resolve_states(
		Vector2i(5, 5), [],
		[
			_state(&"a", Vector2i(1, 1), &"a", 1, 1),
			_state(&"b", Vector2i(1, 2), &"b", 5, 2),
			_state(&"c", Vector2i(2, 2), &"c", 5, 1),
		],
		{
			&"a": _wait(&"a"),
			&"b": _move(&"b", Vector2i.UP),
			&"c": _move(&"c", Vector2i.LEFT),
		}
	)
	_expect_equal(result.collision_waves.size(), 1, "A death ends the A/B/C collision after wave one")
	_expect_equal(_pair_ids(result.combat_events[0]), [&"b", &"a"], "B from below fights stationary A")
	_expect_true(result.is_dead(&"a"), "A dies in the first wave")
	_expect_equal(result.final_positions[&"b"], Vector2i(1, 1), "sole survivor B remains in A's cell")
	_expect_equal(result.final_positions[&"c"], Vector2i(1, 2), "C remains in B's vacated initial cell")
	_expect_equal(result.combat_events.size(), 1, "B and C do not fight when B never returns")


func _test_abc_return_creates_second_wave() -> void:
	var result = _resolve_states(
		Vector2i(5, 5), [],
		[
			_state(&"a", Vector2i(1, 1), &"a", 10, 1),
			_state(&"b", Vector2i(1, 2), &"b", 10, 1),
			_state(&"c", Vector2i(2, 2), &"c", 10, 1),
		],
		{
			&"a": _wait(&"a"),
			&"b": _move(&"b", Vector2i.UP),
			&"c": _move(&"c", Vector2i.LEFT),
		}
	)
	_expect_equal(result.collision_waves.size(), 2, "A/B survival creates a B/C second wave")
	_expect_equal(_pair_ids(result.collision_waves[0]["groups"][0]["combat_events"][0]), [&"b", &"a"], "wave one resolves B against A")
	_expect_equal(_pair_ids(result.collision_waves[1]["groups"][0]["combat_events"][0]), [&"b", &"c"], "returned B fights C in wave two")
	_expect_equal(result.actor_state_for(&"a").health, 9, "A only fights in wave one")
	_expect_equal(result.actor_state_for(&"b").health, 8, "B carries damage into wave two")
	_expect_equal(result.actor_state_for(&"c").health, 9, "C only fights in wave two")


func _test_independent_groups_share_wave() -> void:
	var states := [
		_state(&"left_top", Vector2i(1, 0), &"red", 5, 1),
		_state(&"left_down", Vector2i(1, 2), &"blue", 5, 1),
		_state(&"right_top", Vector2i(4, 0), &"red", 5, 1),
		_state(&"right_down", Vector2i(4, 2), &"blue", 5, 1),
	]
	var intents := {
		&"left_top": _move(&"left_top", Vector2i.DOWN),
		&"left_down": _move(&"left_down", Vector2i.UP),
		&"right_top": _move(&"right_top", Vector2i.DOWN),
		&"right_down": _move(&"right_down", Vector2i.UP),
	}
	var first = _resolve_states(Vector2i(6, 4), [], states, intents)
	var reversed_states := states.duplicate()
	reversed_states.reverse()
	var reversed = _resolve_states(Vector2i(6, 4), [], reversed_states, intents)

	_expect_equal(first.collision_waves.size(), 1, "independent collision cells resolve in one wave")
	_expect_equal(first.collision_waves[0]["groups"].size(), 2, "one wave snapshots both overloaded cells")
	_expect_equal(first.collision_waves[0]["groups"][0]["cell"], Vector2i(1, 1), "first stable group records left cell")
	_expect_equal(first.collision_waves[0]["groups"][1]["cell"], Vector2i(4, 1), "second stable group records right cell")
	for actor_id: StringName in first.final_actor_states:
		_expect_equal(
			first.actor_state_for(actor_id).health,
			reversed.actor_state_for(actor_id).health,
			"input ordering does not change %s health" % actor_id
		)
		_expect_equal(
			first.final_positions[actor_id],
			reversed.final_positions[actor_id],
			"input ordering does not change %s position" % actor_id
		)


func _test_three_wave_return_cascade() -> void:
	var result = _resolve_states(
		Vector2i(5, 5), [],
		[
			_state(&"a", Vector2i(1, 1), &"a", 10, 1),
			_state(&"b", Vector2i(1, 2), &"b", 10, 1),
			_state(&"c", Vector2i(2, 2), &"c", 10, 1),
			_state(&"d", Vector2i(2, 3), &"d", 10, 1),
		],
		{
			&"a": _wait(&"a"),
			&"b": _move(&"b", Vector2i.UP),
			&"c": _move(&"c", Vector2i.LEFT),
			&"d": _move(&"d", Vector2i.UP),
		}
	)
	_expect_equal(result.collision_waves.size(), 3, "returns can create second and third collision waves")
	_expect_equal(_pair_ids(result.combat_events[0]), [&"b", &"a"], "cascade wave one is B/A")
	_expect_equal(_pair_ids(result.combat_events[1]), [&"b", &"c"], "cascade wave two is B/C")
	_expect_equal(_pair_ids(result.combat_events[2]), [&"d", &"c"], "latest sources order cascade wave three as D/C")
	_expect_equal(result.actor_state_for(&"c").health, 8, "C keeps damage across cascade waves")
	_expect_true(not result.collision_cycle_detected, "normal three-wave cascade converges")


func _test_blocked_actor_can_be_collided_at_origin() -> void:
	var result = _resolve_states(
		Vector2i(5, 5), [Vector2i(2, 1)],
		[
			_state(&"blocked", Vector2i(1, 1), &"red", 5, 2),
			_state(&"incoming", Vector2i(1, 2), &"blue", 5, 1),
		],
		{
			&"blocked": _move(&"blocked", Vector2i.RIGHT),
			&"incoming": _move(&"incoming", Vector2i.UP),
		}
	)
	_expect_equal(result.movement_results[&"blocked"]["reason"], &"blocked_by_terrain", "terrain failure is decided before actor collisions")
	_expect_equal(result.movement_positions[&"blocked"], Vector2i(1, 1), "terrain-blocked actor stays at origin during movement phase")
	_expect_equal(result.movement_positions[&"incoming"], Vector2i(1, 1), "incoming actor may overlap the blocked actor")
	_expect_equal(result.collision_waves.size(), 1, "movement overlap creates one collision wave")
	_expect_equal(result.collision_waves[0]["kind"], &"grid", "blocked-origin conflict is a grid collision")
	_expect_equal(result.actor_state_for(&"blocked").health, 4, "blocked actor takes incoming attack")
	_expect_equal(result.actor_state_for(&"incoming").health, 3, "incoming actor takes blocked actor attack")
	_expect_equal(result.final_positions[&"blocked"], Vector2i(1, 1), "blocked survivor returns to its turn-start cell")
	_expect_equal(result.final_positions[&"incoming"], Vector2i(1, 2), "incoming survivor returns to its turn-start cell")


func _test_edge_wave_precedes_independent_grid_wave() -> void:
	var result = _resolve_states(
		Vector2i(6, 4), [],
		[
			_state(&"edge_left", Vector2i(1, 1), &"red", 5, 1),
			_state(&"edge_right", Vector2i(2, 1), &"blue", 5, 1),
			_state(&"grid_top", Vector2i(4, 0), &"red", 5, 1),
			_state(&"grid_down", Vector2i(4, 2), &"blue", 5, 1),
		],
		{
			&"edge_left": _move(&"edge_left", Vector2i.RIGHT),
			&"edge_right": _move(&"edge_right", Vector2i.LEFT),
			&"grid_top": _move(&"grid_top", Vector2i.DOWN),
			&"grid_down": _move(&"grid_down", Vector2i.UP),
		}
	)
	_expect_equal(result.collision_waves.size(), 2, "edge and independent grid conflicts use two ordered waves")
	_expect_equal(result.collision_waves[0]["kind"], &"edge", "reciprocal edge conflict resolves first")
	_expect_equal(result.collision_waves[1]["kind"], &"grid", "ordinary overlap resolves after edge wave")
	_expect_equal(result.collision_waves[0]["groups"][0]["center"], Vector2(1.5, 1.0), "edge collision records crossed midpoint")
	_expect_equal(result.collision_waves[1]["groups"][0]["cell"], Vector2i(4, 1), "grid collision records overloaded cell")
	_expect_equal(result.collision_waves[0]["groups"][0]["combat_events"][0]["wave_index"], 0, "edge event is tagged wave zero")
	_expect_equal(result.collision_waves[1]["groups"][0]["combat_events"][0]["wave_index"], 1, "grid event is tagged wave one")
	_expect_equal(result.actor_state_for(&"edge_left").health, 4, "edge participant takes exactly one hit")
	_expect_equal(result.actor_state_for(&"grid_top").health, 4, "grid participant takes exactly one hit")


func _test_four_actor_mixed_faction_collision() -> void:
	var result = _resolve_states(
		Vector2i(5, 5), [],
		[
			_state(&"top", Vector2i(2, 1), &"red", 1, 1),
			_state(&"right", Vector2i(3, 2), &"blue", 1, 1),
			_state(&"down", Vector2i(2, 3), &"green", 1, 1),
			_state(&"left", Vector2i(1, 2), &"red", 1, 1),
		],
		{
			&"top": _move(&"top", Vector2i.DOWN),
			&"right": _move(&"right", Vector2i.LEFT),
			&"down": _move(&"down", Vector2i.UP),
			&"left": _move(&"left", Vector2i.RIGHT),
		}
	)
	var group: Dictionary = result.collision_waves[0]["groups"][0]
	_expect_equal(group["participants"], [&"top", &"right", &"down", &"left"], "four-way collision follows top-right-down-left source order")
	_expect_equal(group["combat_events"].size(), 5, "four-way mixed group skips only the red-red allied pair")
	_expect_equal(_pair_ids(group["combat_events"][0]), [&"top", &"right"], "pair one follows participant order")
	_expect_equal(_pair_ids(group["combat_events"][1]), [&"top", &"down"], "pair two follows participant order")
	_expect_equal(_pair_ids(group["combat_events"][2]), [&"right", &"down"], "pair three follows participant order")
	_expect_equal(_pair_ids(group["combat_events"][3]), [&"right", &"left"], "pair four follows participant order")
	_expect_equal(_pair_ids(group["combat_events"][4]), [&"down", &"left"], "pair five follows participant order")
	_expect_equal(result.dead_actor_ids.size(), 4, "death is delayed until all five hostile pairs have attacked")
	_expect_equal(result.final_actor_states.size(), 0, "all-dead four-way collision clears the target cell")


func _test_final_state_invariants() -> void:
	var walls := [Vector2i(0, 0)]
	var result = _resolve_neutral(
		Vector2i(5, 5), walls,
		{&"a": Vector2i(1, 1), &"b": Vector2i(2, 1), &"c": Vector2i(3, 1)},
		{
			&"a": _move(&"a", Vector2i.RIGHT),
			&"b": _move(&"b", Vector2i.RIGHT),
			&"c": _move(&"c", Vector2i.DOWN),
		}
	)
	_assert_state_invariants(result, walls, "ordinary movement")


func _test_drunk_rng_is_reproducible() -> void:
	var first = DrunkControllerType.new(1337)
	var second = DrunkControllerType.new(1337)
	for index in 20:
		var first_intent = first.choose_intent(&"drunk")
		var second_intent = second.choose_intent(&"drunk")
		_expect_equal(first_intent.action_type, second_intent.action_type, "seeded action %d matches" % index)
		_expect_equal(first_intent.delta, second_intent.delta, "seeded direction %d matches" % index)


func _test_actor_state_clone_and_stats() -> void:
	var original = GridActorStateType.new(&"hero", Vector2i(1, 2), &"player", &"town", 5, 5, 2)
	var copy = original.clone()
	copy.health -= 2
	copy.cell = Vector2i(2, 2)
	_expect_equal(original.health, 5, "cloning does not mutate source health")
	_expect_equal(original.cell, Vector2i(1, 2), "cloning does not mutate source position")
	_expect_equal(copy.faction, &"town", "clone preserves faction")
	_expect_equal(copy.attack, 2, "clone preserves attack")
	_expect_true(copy.is_alive(), "positive health actor is alive")


func _test_two_round_player_drunk_combat() -> void:
	var states := [
		GridActorStateType.new(&"player", Vector2i(1, 1), &"player", &"player", 5, 5, 2),
		GridActorStateType.new(&"drunk", Vector2i(3, 1), &"npc", &"drunk", 3, 3, 1),
	]
	var intents := {
		&"player": _move(&"player", Vector2i.RIGHT),
		&"drunk": _move(&"drunk", Vector2i.LEFT),
	}
	var first = _resolve_states(Vector2i(5, 3), [], states, intents)
	_expect_equal(first.actor_state_for(&"player").health, 4, "first clash damages player by one")
	_expect_equal(first.actor_state_for(&"drunk").health, 1, "first clash damages drunk by two")
	_expect_equal(first.final_positions[&"player"], Vector2i(1, 1), "both survivors return player")
	_expect_equal(first.final_positions[&"drunk"], Vector2i(3, 1), "both survivors return drunk")
	_expect_equal(first.outcome_for(&"player")["reason"], &"combat_survivor_returned", "combat return is reported")

	var second_states := [first.actor_state_for(&"player"), first.actor_state_for(&"drunk")]
	var second = _resolve_states(Vector2i(5, 3), [], second_states, intents)
	_expect_equal(second.actor_state_for(&"player").health, 3, "second clash persists previous player damage")
	_expect_true(second.is_dead(&"drunk"), "second clash kills drunk")
	_expect_true(not second.final_actor_states.has(&"drunk"), "dead drunk is removed from final states")
	_expect_equal(second.final_positions[&"player"], Vector2i(2, 1), "sole surviving mover enters target")
	_expect_equal(second.outcome_for(&"player")["reason"], &"combat_winner_moved", "moving winner result is reported")


func _test_stationary_defender_is_sole_survivor() -> void:
	var result = _resolve_states(
		Vector2i(5, 3), [],
		[
			_state(&"attacker", Vector2i(1, 1), &"red", 1, 1),
			_state(&"defender", Vector2i(2, 1), &"blue", 3, 2),
		],
		{&"attacker": _move(&"attacker", Vector2i.RIGHT), &"defender": _wait(&"defender")}
	)
	_expect_true(result.is_dead(&"attacker"), "strong defender kills incoming attacker")
	_expect_equal(result.final_positions[&"defender"], Vector2i(2, 1), "sole defender remains in original cell")
	_expect_equal(result.outcome_for(&"defender")["reason"], &"combat_winner_held", "defender hold result is reported")


func _test_mutual_death_empties_target() -> void:
	var result = _resolve_states(
		Vector2i(5, 3), [],
		[
			_state(&"a", Vector2i(1, 1), &"red", 1, 1),
			_state(&"b", Vector2i(3, 1), &"blue", 1, 1),
		],
		{&"a": _move(&"a", Vector2i.RIGHT), &"b": _move(&"b", Vector2i.LEFT)}
	)
	_expect_equal(result.dead_actor_ids.size(), 2, "mutual lethal damage removes both actors")
	_expect_equal(result.final_actor_states.size(), 0, "mutual death leaves no actor state")
	_expect_equal(result.final_positions.size(), 0, "mutual death leaves target empty")


func _test_directional_pair_order_and_delayed_death() -> void:
	var result = _resolve_states(
		Vector2i(5, 5), [],
		[
			_state(&"top", Vector2i(2, 1), &"top", 1, 1),
			_state(&"right", Vector2i(3, 2), &"right", 1, 1),
			_state(&"down", Vector2i(2, 3), &"down", 1, 1),
		],
		{
			&"top": _move(&"top", Vector2i.DOWN),
			&"right": _move(&"right", Vector2i.LEFT),
			&"down": _move(&"down", Vector2i.UP),
		}
	)
	_expect_equal(result.combat_events.size(), 3, "three hostile actors create all three pairs")
	_expect_equal(_pair_ids(result.combat_events[0]), [&"top", &"right"], "top pair resolves first")
	_expect_equal(_pair_ids(result.combat_events[1]), [&"top", &"down"], "top fights remaining actor before right")
	_expect_equal(_pair_ids(result.combat_events[2]), [&"right", &"down"], "right-down pair resolves last")
	_expect_equal(result.dead_actor_ids.size(), 3, "death waits until every scheduled pair attacks")


func _test_mixed_factions_only_fight_hostile_pairs() -> void:
	var result = _resolve_states(
		Vector2i(5, 5), [],
		[
			_state(&"ally_top", Vector2i(2, 1), &"ally", 10, 1),
			_state(&"ally_right", Vector2i(3, 2), &"ally", 10, 1),
			_state(&"enemy", Vector2i(2, 3), &"enemy", 10, 1),
		],
		{
			&"ally_top": _move(&"ally_top", Vector2i.DOWN),
			&"ally_right": _move(&"ally_right", Vector2i.LEFT),
			&"enemy": _move(&"enemy", Vector2i.UP),
		}
	)
	_expect_equal(result.combat_events.size(), 2, "mixed group skips allied pair")
	_expect_equal(result.actor_state_for(&"ally_top").health, 9, "first ally only takes enemy damage")
	_expect_equal(result.actor_state_for(&"ally_right").health, 9, "second ally only takes enemy damage")
	_expect_equal(result.actor_state_for(&"enemy").health, 8, "enemy takes damage from both allies")


func _test_combat_return_blocks_upstream_move() -> void:
	var result = _resolve_states(
		Vector2i(6, 3), [],
		[
			_state(&"follower", Vector2i(0, 1), &"ally", 5, 1),
			_state(&"middle", Vector2i(1, 1), &"red", 5, 1),
			_state(&"opponent", Vector2i(3, 1), &"blue", 5, 1),
		],
		{
			&"follower": _move(&"follower", Vector2i.RIGHT),
			&"middle": _move(&"middle", Vector2i.RIGHT),
			&"opponent": _move(&"opponent", Vector2i.LEFT),
		}
	)
	_expect_equal(result.outcome_for(&"middle")["reason"], &"combat_survivor_returned", "combat survivors return")
	_expect_equal(result.outcome_for(&"follower")["reason"], &"combat_survivor_returned", "returned survivor fights upstream actor next wave")
	_expect_equal(result.collision_waves.size(), 2, "combat return creates an explicit second wave")
	_expect_equal(_pair_ids(result.combat_events[1]), [&"middle", &"follower"], "second wave uses recent return source order")


func _test_combat_death_releases_origin() -> void:
	var result = _resolve_states(
		Vector2i(6, 3), [],
		[
			_state(&"follower", Vector2i(0, 1), &"ally", 5, 1),
			_state(&"middle", Vector2i(1, 1), &"red", 1, 1),
			_state(&"opponent", Vector2i(3, 1), &"blue", 5, 2),
		],
		{
			&"follower": _move(&"follower", Vector2i.RIGHT),
			&"middle": _move(&"middle", Vector2i.RIGHT),
			&"opponent": _move(&"opponent", Vector2i.LEFT),
		}
	)
	_expect_true(result.is_dead(&"middle"), "middle actor dies in combat")
	_expect_equal(result.final_positions[&"follower"], Vector2i(1, 1), "death releases origin for follower")
	_expect_equal(result.final_positions[&"opponent"], Vector2i(2, 1), "sole combat winner reaches collision cell")


func _test_main_scene_combat_flow() -> void:
	var main = MainScene.instantiate()
	add_child(main)
	await get_tree().process_frame

	_expect_equal(main._actors[&"player"].health, 5, "main scene player starts with five health")
	_expect_equal(main._actors[&"player"].attack, 2, "main scene player starts with two attack")
	_expect_equal(main._actors[&"drunk"].health, 3, "main scene drunk starts with three health")
	_expect_equal(main._actors[&"drunk"].attack, 1, "main scene drunk starts with one attack")
	_expect_true(main._actors[&"player"].faction != main._actors[&"drunk"].faction, "main scene actors are hostile")

	# Verify the non-combat blocked-move bump remains intact.
	var bump_intents := {&"player": _move(&"player", Vector2i.LEFT), &"drunk": _wait(&"drunk")}
	var bump_result = TurnResolverType.resolve(
		main.BOARD_SIZE, main._blocked,
		[main._actors[&"player"], main._actors[&"drunk"]], bump_intents
	)
	var bump_starts := {
		&"player": main._actor_views[&"player"].position,
		&"drunk": main._actor_views[&"drunk"].position,
	}
	main._apply_approach_animation(0.5, bump_starts, {}, bump_intents, bump_result)
	_expect_true(main._actor_views[&"player"].position.x < bump_starts[&"player"].x, "blocked move still bumps toward wall")
	main._apply_approach_animation(1.0, bump_starts, {}, bump_intents, bump_result)
	_expect_equal(main._actor_views[&"player"].position, bump_starts[&"player"], "blocked move returns visually")
	var pulse_bases := {
		&"player": main._actor_views[&"player"].position,
		&"drunk": main._actor_views[&"drunk"].position,
	}
	main._apply_combat_pulse(0.125, &"player", &"drunk", pulse_bases)
	_expect_true(main._actor_views[&"player"].hit_flash > 0.0, "combat pulse flashes the player")
	_expect_true(main._actor_views[&"drunk"].position != pulse_bases[&"drunk"], "combat pulse shakes the drunk")
	main._actor_views[&"player"].position = pulse_bases[&"player"]
	main._actor_views[&"drunk"].position = pulse_bases[&"drunk"]
	main._actor_views[&"player"].set_hit_flash(0.0)
	main._actor_views[&"drunk"].set_hit_flash(0.0)

	main._drunk_controller = FixedController.new(_move(&"drunk", Vector2i.LEFT))
	await main._play_turn(_move(&"player", Vector2i.RIGHT))
	_expect_equal(main._actors[&"player"].health, 4, "first integrated clash updates player health")
	_expect_equal(main._actors[&"drunk"].health, 1, "first integrated clash updates drunk health")
	_expect_equal(main._actors[&"player"].cell, Vector2i(1, 1), "first integrated clash returns player")
	_expect_true(main._actor_views.has(&"drunk"), "surviving drunk view remains")

	await main._play_turn(_move(&"player", Vector2i.RIGHT))
	_expect_equal(main._actors[&"player"].health, 3, "second integrated clash persists health")
	_expect_equal(main._actors[&"player"].cell, Vector2i(2, 1), "winning player enters collision cell")
	_expect_true(not main._actors.has(&"drunk"), "dead drunk leaves active actor set")
	_expect_true(not main._actor_views.has(&"drunk"), "dead drunk view is removed")
	_expect_true(main._log_label.text.contains("死亡"), "combat log reports death")

	await get_tree().process_frame
	var preview_image := get_viewport().get_texture().get_image()
	var preview_path := ProjectSettings.globalize_path("res://.godot/test_preview.png")
	_expect_true(not preview_image.is_empty(), "combat scene produces a rendered viewport")
	_expect_equal(preview_image.save_png(preview_path), OK, "combat preview can be captured")

	await main._play_turn(_wait(&"player"))
	_expect_equal(main._turn_number, 4, "turns continue without dead drunk intent")
	_expect_true(not main._busy, "input unlocks after complete combat presentation")

	main.queue_free()
	await get_tree().process_frame


func _test_main_scene_player_death_stops_input() -> void:
	var main = MainScene.instantiate()
	add_child(main)
	await get_tree().process_frame
	main._actors[&"player"].health = 1
	main._actors[&"player"].max_health = 1
	main._actors[&"drunk"].attack = 5
	main._actor_views[&"player"].set_stats(1, 1, 2)
	main._actor_views[&"drunk"].set_stats(3, 3, 5)
	main._drunk_controller = FixedController.new(_move(&"drunk", Vector2i.LEFT))

	await main._play_turn(_move(&"player", Vector2i.RIGHT))
	_expect_true(not main._actors.has(&"player"), "lethal combat removes player state")
	_expect_true(not main._actor_views.has(&"player"), "lethal combat removes player view")
	_expect_true(main._status_label.text.contains("主角已死亡"), "player death ends prototype input")
	_expect_true(not main._busy, "player death still completes the turn cleanly")

	main.queue_free()
	await get_tree().process_frame


func _resolve_neutral(
	board_size: Vector2i,
	walls: Array,
	positions: Dictionary,
	intents: Dictionary
):
	var states: Array = []
	for actor_id: StringName in positions:
		states.append(_state(actor_id, positions[actor_id], &"neutral", 10, 1))
	return _resolve_states(board_size, walls, states, intents)


func _resolve_states(
	board_size: Vector2i,
	walls: Array,
	states: Array,
	intents: Dictionary
):
	var blocked := {}
	for wall: Vector2i in walls:
		blocked[wall] = true
	return TurnResolverType.resolve(board_size, blocked, states, intents)


func _state(
	actor_id: StringName,
	cell: Vector2i,
	faction: StringName,
	health: int,
	attack: int
):
	return GridActorStateType.new(actor_id, cell, &"test", faction, health, health, attack)


func _move(actor_id: StringName, delta: Vector2i):
	return TurnIntentType.new(actor_id, TurnIntentType.ActionType.MOVE, delta)


func _wait(actor_id: StringName):
	return TurnIntentType.new(actor_id, TurnIntentType.ActionType.WAIT, Vector2i.ZERO)


func _pair_ids(event: Dictionary) -> Array:
	return [event["first_id"], event["second_id"]]


func _assert_state_invariants(result, walls: Array, context: String) -> void:
	var occupied := {}
	for actor_id: StringName in result.final_positions:
		var cell: Vector2i = result.final_positions[actor_id]
		_expect_true(not occupied.has(cell), "%s final cells never overlap" % context)
		_expect_true(not cell in walls, "%s final cells avoid terrain" % context)
		occupied[cell] = actor_id


func _expect_true(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	push_error("Assertion failed: %s" % message)


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	_checks += 1
	if actual == expected:
		return
	_failures += 1
	push_error("Assertion failed: %s | expected=%s actual=%s" % [message, expected, actual])
