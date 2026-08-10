extends Node

const TurnIntentType = preload("res://scripts/model/turn_intent.gd")
const GridActorStateType = preload("res://scripts/model/grid_actor_state.gd")
const TurnResolverType = preload("res://scripts/core/turn_resolver.gd")
const DrunkControllerType = preload("res://scripts/core/drunk_controller.gd")
const MainScene = preload("res://scenes/main.tscn")

var _failures := 0
var _checks := 0


func _ready() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_test_move_to_empty_and_wait()
	_test_wall_and_bounds_fail()
	_test_same_target_conflict()
	_test_swap_succeeds()
	_test_chain_into_empty_succeeds()
	_test_four_actor_cycle_succeeds()
	_test_chain_ending_at_waiter_fails()
	_test_failed_middle_actor_propagates_failure()
	_test_final_state_invariants()
	_test_drunk_rng_is_reproducible()
	await _test_main_scene_turn_flow()

	if _failures == 0:
		print("PASS: %d checks across 11 synchronous-turn scenarios." % _checks)
	else:
		push_error("FAIL: %d of %d checks failed." % [_failures, _checks])


func _test_move_to_empty_and_wait() -> void:
	var result = _resolve(
		Vector2i(5, 5),
		[],
		{&"a": Vector2i(1, 1), &"b": Vector2i(3, 3)},
		{
			&"a": _move(&"a", Vector2i.RIGHT),
			&"b": _wait(&"b"),
		}
	)
	_expect_equal(result.final_positions[&"a"], Vector2i(2, 1), "move to empty succeeds")
	_expect_equal(result.final_positions[&"b"], Vector2i(3, 3), "wait keeps position")
	_expect_true(result.outcome_for(&"b")["success"], "wait is a successful action")


func _test_wall_and_bounds_fail() -> void:
	var result = _resolve(
		Vector2i(4, 4),
		[Vector2i(2, 1)],
		{&"a": Vector2i(1, 1), &"b": Vector2i(0, 0)},
		{
			&"a": _move(&"a", Vector2i.RIGHT),
			&"b": _move(&"b", Vector2i.LEFT),
		}
	)
	_expect_equal(result.outcome_for(&"a")["reason"], &"blocked_by_terrain", "terrain blocks movement")
	_expect_equal(result.outcome_for(&"b")["reason"], &"out_of_bounds", "board edge blocks movement")


func _test_same_target_conflict() -> void:
	var result = _resolve(
		Vector2i(5, 3),
		[],
		{&"a": Vector2i(1, 1), &"b": Vector2i(3, 1)},
		{
			&"a": _move(&"a", Vector2i.RIGHT),
			&"b": _move(&"b", Vector2i.LEFT),
		}
	)
	_expect_equal(result.final_positions[&"a"], Vector2i(1, 1), "first claimant stays on conflict")
	_expect_equal(result.final_positions[&"b"], Vector2i(3, 1), "second claimant stays on conflict")
	_expect_equal(result.outcome_for(&"a")["reason"], &"target_conflict", "conflict reason is reported")


func _test_swap_succeeds() -> void:
	var result = _resolve(
		Vector2i(5, 3),
		[],
		{&"a": Vector2i(1, 1), &"b": Vector2i(2, 1)},
		{
			&"a": _move(&"a", Vector2i.RIGHT),
			&"b": _move(&"b", Vector2i.LEFT),
		}
	)
	_expect_equal(result.final_positions[&"a"], Vector2i(2, 1), "swap moves first actor")
	_expect_equal(result.final_positions[&"b"], Vector2i(1, 1), "swap moves second actor")


func _test_chain_into_empty_succeeds() -> void:
	var result = _resolve(
		Vector2i(6, 3),
		[],
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
	var result = _resolve(
		Vector2i(5, 5),
		[],
		{
			&"a": Vector2i(1, 1),
			&"b": Vector2i(2, 1),
			&"c": Vector2i(2, 2),
			&"d": Vector2i(1, 2),
		},
		{
			&"a": _move(&"a", Vector2i.RIGHT),
			&"b": _move(&"b", Vector2i.DOWN),
			&"c": _move(&"c", Vector2i.LEFT),
			&"d": _move(&"d", Vector2i.UP),
		}
	)
	for actor_id: StringName in [&"a", &"b", &"c", &"d"]:
		_expect_true(result.outcome_for(actor_id)["moved"], "cycle actor %s moves" % actor_id)


func _test_chain_ending_at_waiter_fails() -> void:
	var result = _resolve(
		Vector2i(5, 3),
		[],
		{&"a": Vector2i(1, 1), &"b": Vector2i(2, 1)},
		{
			&"a": _move(&"a", Vector2i.RIGHT),
			&"b": _wait(&"b"),
		}
	)
	_expect_equal(result.final_positions[&"a"], Vector2i(1, 1), "actor cannot enter waiter's cell")
	_expect_equal(result.outcome_for(&"a")["reason"], &"occupied_actor_not_leaving", "waiter blocks dependency chain")


func _test_failed_middle_actor_propagates_failure() -> void:
	var result = _resolve(
		Vector2i(6, 5),
		[],
		{&"a": Vector2i(1, 1), &"b": Vector2i(2, 1), &"c": Vector2i(3, 2)},
		{
			&"a": _move(&"a", Vector2i.RIGHT),
			&"b": _move(&"b", Vector2i.RIGHT),
			&"c": _move(&"c", Vector2i.UP),
		}
	)
	_expect_equal(result.outcome_for(&"b")["reason"], &"target_conflict", "middle actor loses contested destination")
	_expect_equal(result.outcome_for(&"a")["reason"], &"occupied_actor_not_leaving", "failure propagates to follower")


func _test_final_state_invariants() -> void:
	var walls := [Vector2i(0, 0)]
	var result = _resolve(
		Vector2i(5, 5),
		walls,
		{&"a": Vector2i(1, 1), &"b": Vector2i(2, 1), &"c": Vector2i(3, 1)},
		{
			&"a": _move(&"a", Vector2i.RIGHT),
			&"b": _move(&"b", Vector2i.RIGHT),
			&"c": _move(&"c", Vector2i.DOWN),
		}
	)
	var occupied := {}
	for actor_id: StringName in result.final_positions:
		var cell: Vector2i = result.final_positions[actor_id]
		_expect_true(not occupied.has(cell), "final cells never overlap")
		_expect_true(not cell in walls, "final cells never contain terrain")
		occupied[cell] = actor_id


func _test_drunk_rng_is_reproducible() -> void:
	var first = DrunkControllerType.new(1337)
	var second = DrunkControllerType.new(1337)
	for index in 20:
		var first_intent = first.choose_intent(&"drunk")
		var second_intent = second.choose_intent(&"drunk")
		_expect_equal(first_intent.action_type, second_intent.action_type, "seeded action %d matches" % index)
		_expect_equal(first_intent.delta, second_intent.delta, "seeded direction %d matches" % index)


func _test_main_scene_turn_flow() -> void:
	var main = MainScene.instantiate()
	add_child(main)
	await get_tree().process_frame

	_expect_equal(main._turn_number, 1, "main scene starts on turn one")
	_expect_true(not main._busy, "main scene initially accepts input")

	await main._play_turn(_wait(&"player"))
	_expect_equal(main._turn_number, 2, "wait advances exactly one turn")
	_expect_true(main._log_label.text.contains("第 1 回合"), "panel records the resolved turn")
	_expect_true(main._log_label.text.contains("主角：等待"), "panel records the player intent")

	var player_before_invalid: Vector2i = main._actors[&"player"]
	await main._play_turn(_move(&"player", Vector2i.LEFT))
	_expect_equal(main._turn_number, 3, "invalid move still advances one turn")
	_expect_equal(main._actors[&"player"], player_before_invalid, "terrain collision keeps player in place")
	_expect_true(main._log_label.text.contains("地形阻挡"), "panel explains invalid movement")

	await main._play_turn(_move(&"player", Vector2i.DOWN))
	_expect_equal(main._turn_number, 4, "successful move advances one turn")
	_expect_equal(main._actors[&"player"], Vector2i(1, 2), "successful move updates the player cell")

	var occupied := {}
	for actor_id: StringName in main._actors:
		var cell: Vector2i = main._actors[actor_id]
		_expect_true(not occupied.has(cell), "integrated turn leaves unique actor cells")
		_expect_true(not main._blocked.has(cell), "integrated turn keeps actors off terrain")
		occupied[cell] = actor_id

	await get_tree().process_frame
	var preview_image := get_viewport().get_texture().get_image()
	var preview_path := ProjectSettings.globalize_path("res://.godot/test_preview.png")
	_expect_true(not preview_image.is_empty(), "main scene produces a rendered viewport")
	_expect_equal(preview_image.save_png(preview_path), OK, "rendered preview can be captured")

	main.queue_free()
	await get_tree().process_frame


func _resolve(
	board_size: Vector2i,
	walls: Array,
	positions: Dictionary,
	intents: Dictionary
):
	var blocked := {}
	for wall: Vector2i in walls:
		blocked[wall] = true
	var states: Array = []
	for actor_id: StringName in positions:
		states.append(GridActorStateType.new(actor_id, positions[actor_id], &"test"))
	return TurnResolverType.resolve(board_size, blocked, states, intents)


func _move(actor_id: StringName, delta: Vector2i):
	return TurnIntentType.new(actor_id, TurnIntentType.ActionType.MOVE, delta)


func _wait(actor_id: StringName):
	return TurnIntentType.new(actor_id, TurnIntentType.ActionType.WAIT, Vector2i.ZERO)


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
