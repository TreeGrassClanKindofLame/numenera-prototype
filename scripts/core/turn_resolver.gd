extends RefCounted

const TurnIntentType = preload("res://scripts/model/turn_intent.gd")
const TurnResolutionType = preload("res://scripts/model/turn_resolution.gd")
const SquadBattleResolverType = preload("res://scripts/core/squad_battle_resolver.gd")

const VALID_DELTAS := [
	Vector2i.UP,
	Vector2i.DOWN,
	Vector2i.LEFT,
	Vector2i.RIGHT,
]


static func resolve(
	board_size: Vector2i,
	blocked: Dictionary,
	actor_states: Array,
	intents: Dictionary,
	battle_seed: int = 1337
):
	var battle_rng := RandomNumberGenerator.new()
	battle_rng.seed = battle_seed
	var states: Dictionary = {}
	var actor_ids: Array = []
	var initial_positions: Dictionary = {}
	var current_positions: Dictionary = {}
	var last_sources: Dictionary = {}
	var valid_movers: Dictionary = {}
	var actor_reasons: Dictionary = {}

	for source_actor in actor_states:
		var actor = source_actor.clone()
		actor_ids.append(actor.actor_id)
		states[actor.actor_id] = actor
		initial_positions[actor.actor_id] = actor.cell
		current_positions[actor.actor_id] = actor.cell
		last_sources[actor.actor_id] = Vector2(actor.cell)

	var result := TurnResolutionType.new(initial_positions)

	# Movement phase: terrain is the only occupancy restriction. Character
	# overlaps are deliberately preserved for the collision waves below.
	for actor_id: StringName in actor_ids:
		var start: Vector2i = initial_positions[actor_id]
		var intent = intents.get(
			actor_id,
			TurnIntentType.new(actor_id, TurnIntentType.ActionType.WAIT, Vector2i.ZERO)
		)
		var movement_result := {
			"valid": true,
			"moved": false,
			"reason": &"waited",
			"start": start,
			"target": start,
		}

		if intent.action_type == TurnIntentType.ActionType.WAIT:
			actor_reasons[actor_id] = &"waited"
		elif intent.action_type != TurnIntentType.ActionType.MOVE or not intent.delta in VALID_DELTAS:
			movement_result["valid"] = false
			movement_result["reason"] = &"invalid_direction"
			actor_reasons[actor_id] = &"invalid_direction"
		else:
			# Facing follows the declared move before terrain validation. Bumping a
			# wall is therefore a valid way to turn without changing cells.
			states[actor_id].facing = intent.delta
			var target: Vector2i = start + intent.delta
			movement_result["target"] = target
			if not _is_inside(target, board_size):
				movement_result["valid"] = false
				movement_result["reason"] = &"out_of_bounds"
				actor_reasons[actor_id] = &"out_of_bounds"
			elif blocked.has(target):
				movement_result["valid"] = false
				movement_result["reason"] = &"blocked_by_terrain"
				actor_reasons[actor_id] = &"blocked_by_terrain"
			else:
				movement_result["moved"] = true
				movement_result["reason"] = &"moved"
				actor_reasons[actor_id] = &"moved"
				valid_movers[actor_id] = true
				current_positions[actor_id] = target
				last_sources[actor_id] = Vector2(start)

		movement_result["facing"] = states[actor_id].facing
		result.movement_results[actor_id] = movement_result
		result.movement_positions[actor_id] = current_positions[actor_id]
		result.tentative_positions[actor_id] = current_positions[actor_id]

	var next_wave_index := 0
	var dead_actor_ids: Array = []

	# Special wave zero: reciprocal initial moves collide on the crossed edge.
	var edge_specs := _build_head_on_specs(
		actor_ids, initial_positions, current_positions, valid_movers
	)
	if not edge_specs.is_empty():
		var edge_wave := _resolve_collision_wave(
			&"edge",
			edge_specs,
			next_wave_index,
			states,
			initial_positions,
			current_positions,
			last_sources,
			actor_reasons,
			dead_actor_ids,
			result,
			battle_rng
		)
		result.collision_waves.append(edge_wave)
		next_wave_index += 1

	# Grid collision waves: every wave snapshots all overloaded cells, resolves
	# their disjoint groups, then applies every death and return simultaneously.
	var seen_states: Dictionary = {}
	var max_grid_waves := maxi(4, actor_ids.size() * actor_ids.size() + 1)
	var grid_wave_count := 0
	while true:
		var grid_specs := _build_grid_specs(current_positions)
		if grid_specs.is_empty():
			break

		var signature := _state_signature(current_positions, states, last_sources)
		if seen_states.has(signature) or grid_wave_count >= max_grid_waves:
			result.collision_cycle_detected = true
			for actor_id: StringName in current_positions.keys():
				current_positions[actor_id] = initial_positions[actor_id]
				last_sources[actor_id] = Vector2(initial_positions[actor_id])
				actor_reasons[actor_id] = &"collision_cycle_reset"
			result.collision_waves.append({
				"wave_index": next_wave_index,
				"kind": &"cycle_reset",
				"groups": [],
				"positions_after": current_positions.duplicate(true),
				"dead_actor_ids": [],
			})
			break
		seen_states[signature] = true

		var grid_wave := _resolve_collision_wave(
			&"grid",
			grid_specs,
			next_wave_index,
			states,
			initial_positions,
			current_positions,
			last_sources,
			actor_reasons,
			dead_actor_ids,
			result,
			battle_rng
		)
		result.collision_waves.append(grid_wave)
		next_wave_index += 1
		grid_wave_count += 1

	# Commit final living states and summarize each actor's complete turn.
	result.final_positions.clear()
	for actor_id: StringName in actor_ids:
		if actor_id in dead_actor_ids:
			var dead_target: Vector2i = result.movement_positions[actor_id]
			result.set_outcome(actor_id, false, false, &"died_in_combat", dead_target)
			continue

		var actor = states[actor_id]
		actor.cell = current_positions[actor_id]
		result.final_actor_states[actor_id] = actor
		result.final_positions[actor_id] = actor.cell

		var reason: StringName = actor_reasons.get(actor_id, &"waited")
		var moved: bool = actor.cell != initial_positions[actor_id]
		var success: bool = reason in [
			&"moved", &"waited", &"combat_winner_moved", &"combat_winner_held"
		]
		result.set_outcome(actor_id, success, moved, reason, actor.cell)

	result.dead_actor_ids = dead_actor_ids.duplicate()
	return result


static func _resolve_collision_wave(
	kind: StringName,
	group_specs: Array,
	wave_index: int,
	states: Dictionary,
	initial_positions: Dictionary,
	current_positions: Dictionary,
	last_sources: Dictionary,
	actor_reasons: Dictionary,
	dead_actor_ids: Array,
	result,
	battle_rng: RandomNumberGenerator
) -> Dictionary:
	var wave := {
		"wave_index": wave_index,
		"kind": kind,
		"groups": [],
		"positions_before": current_positions.duplicate(true),
		"health_before": _health_snapshot(current_positions, states),
		"dead_actor_ids": [],
	}
	var position_updates: Dictionary = {}
	var source_updates: Dictionary = {}
	var wave_dead: Array = []

	for group_index in group_specs.size():
		var spec: Dictionary = group_specs[group_index]
		var participants: Array = spec["participants"]
		var center: Vector2 = spec["center"]
		var ordered := _sort_participants(participants, center, last_sources)
		var hostile_pairs := _hostile_pairs(ordered, states)
		var group_events: Array = []
		var encounters: Array = []

		for pair_index in hostile_pairs.size():
			var pair: Array = hostile_pairs[pair_index]
			var first_id: StringName = pair[0]
			var second_id: StringName = pair[1]
			var first = states[first_id]
			var second = states[second_id]
			if not first.is_alive() or not second.is_alive():
				encounters.append({
					"pair_index": pair_index,
					"first_squad_id": first_id,
					"second_squad_id": second_id,
					"first_controller": first.controller,
					"second_controller": second.controller,
					"skipped": true,
					"reason": &"eliminated_squad",
					"events": [],
					"turn_schedule": [],
					"formations_before": SquadBattleResolverType.formation_snapshot(first, second),
					"formations_after": SquadBattleResolverType.formation_snapshot(first, second),
					"first_alive_before": first.living_unit_count(),
					"second_alive_before": second.living_unit_count(),
					"first_alive_after": first.living_unit_count(),
					"second_alive_after": second.living_unit_count(),
					"first_advantage": 0,
					"second_advantage": 0,
					"engagement": {},
				})
				continue

			var engagement := _build_engagement(
				first_id, second_id, center, last_sources, states
			)
			var encounter: Dictionary = SquadBattleResolverType.resolve_round(
				first,
				second,
				battle_rng,
				engagement["first_advantage"],
				engagement["second_advantage"],
				engagement
			)
			encounter["pair_index"] = pair_index
			encounter["skipped"] = false
			for unit_event: Dictionary in encounter["events"]:
				unit_event["wave_index"] = wave_index
				unit_event["group_index"] = group_index
				unit_event["pair_index"] = pair_index
				unit_event["kind"] = kind
				unit_event["center"] = center
				unit_event["first_id"] = unit_event["attacker_squad_id"]
				unit_event["second_id"] = unit_event["defender_squad_id"]
				group_events.append(unit_event)
				result.combat_events.append(unit_event)
			encounters.append(encounter)

		var survivors: Array = []
		var group_dead: Array = []
		for actor_id: StringName in ordered:
			if states[actor_id].is_alive():
				survivors.append(actor_id)
			else:
				group_dead.append(actor_id)
				wave_dead.append(actor_id)
				if not actor_id in dead_actor_ids:
					dead_actor_ids.append(actor_id)
				actor_reasons[actor_id] = &"died_in_combat"

		var returned: Array = []
		if survivors.size() > 1:
			for actor_id: StringName in survivors:
				returned.append(actor_id)
				position_updates[actor_id] = initial_positions[actor_id]
				source_updates[actor_id] = center
				actor_reasons[actor_id] = (
					&"combat_survivor_returned"
					if not hostile_pairs.is_empty()
					else &"friendly_collision"
				)
		elif survivors.size() == 1:
			var winner_id: StringName = survivors[0]
			actor_reasons[winner_id] = (
				&"combat_winner_held"
				if current_positions[winner_id] == initial_positions[winner_id]
				else &"combat_winner_moved"
			)

		var source_snapshot: Dictionary = {}
		for actor_id: StringName in ordered:
			source_snapshot[actor_id] = last_sources[actor_id]
		var group_result := {
				"wave_index": wave_index,
				"group_index": group_index,
				"kind": kind,
				"center": center,
			"cell": spec.get("cell", Vector2i(-1, -1)),
			"participants": ordered,
			"source_positions": source_snapshot,
			"planned_pairs": hostile_pairs,
			"encounters": encounters,
			"combat_events": group_events,
			"survivors": survivors,
			"returned_actor_ids": returned,
			"dead_actor_ids": group_dead,
			"had_combat": not hostile_pairs.is_empty(),
		}
		wave["groups"].append(group_result)
		result.collision_groups.append(group_result)

	# All groups in this wave are disjoint. Commit their deaths and returns only
	# after every group has finished calculating its result.
	for actor_id: StringName in wave_dead:
		current_positions.erase(actor_id)
		last_sources.erase(actor_id)
	for actor_id: StringName in position_updates:
		if actor_id in wave_dead:
			continue
		current_positions[actor_id] = position_updates[actor_id]
		last_sources[actor_id] = source_updates[actor_id]

	wave["dead_actor_ids"] = wave_dead
	wave["positions_after"] = current_positions.duplicate(true)
	wave["health_after"] = _health_snapshot(current_positions, states)
	return wave


static func _build_head_on_specs(
	actor_ids: Array,
	initial_positions: Dictionary,
	movement_positions: Dictionary,
	valid_movers: Dictionary
) -> Array:
	var specs: Array = []
	var paired: Dictionary = {}
	for first_index in actor_ids.size():
		var first_id: StringName = actor_ids[first_index]
		if paired.has(first_id) or not valid_movers.has(first_id):
			continue
		for second_index in range(first_index + 1, actor_ids.size()):
			var second_id: StringName = actor_ids[second_index]
			if paired.has(second_id) or not valid_movers.has(second_id):
				continue
			if (
				movement_positions[first_id] == initial_positions[second_id]
				and movement_positions[second_id] == initial_positions[first_id]
			):
				paired[first_id] = true
				paired[second_id] = true
				specs.append({
					"participants": [first_id, second_id],
					"center": (
						Vector2(initial_positions[first_id])
						+ Vector2(initial_positions[second_id])
					) * 0.5,
				})
				break
	return specs


static func _build_grid_specs(current_positions: Dictionary) -> Array:
	var occupancy: Dictionary = {}
	for actor_id: StringName in current_positions:
		var cell: Vector2i = current_positions[actor_id]
		var participants: Array = occupancy.get(cell, [])
		participants.append(actor_id)
		occupancy[cell] = participants

	var crowded_cells: Array = []
	for cell: Vector2i in occupancy:
		if occupancy[cell].size() > 1:
			crowded_cells.append(cell)
	crowded_cells.sort_custom(func(first: Vector2i, second: Vector2i):
		return first.y < second.y or (first.y == second.y and first.x < second.x)
	)

	var specs: Array = []
	for cell: Vector2i in crowded_cells:
		specs.append({
			"participants": occupancy[cell].duplicate(),
			"center": Vector2(cell),
			"cell": cell,
		})
	return specs


static func _hostile_pairs(ordered: Array, states: Dictionary) -> Array:
	var pairs: Array = []
	for first_index in ordered.size():
		for second_index in range(first_index + 1, ordered.size()):
			var first_id: StringName = ordered[first_index]
			var second_id: StringName = ordered[second_index]
			if states[first_id].faction != states[second_id].faction:
				pairs.append([first_id, second_id])
	return pairs


static func _sort_participants(
	participants: Array,
	center: Vector2,
	source_positions: Dictionary
) -> Array:
	var ordered: Array = []
	for actor_id: StringName in participants:
		var insert_at := ordered.size()
		for index in ordered.size():
			if _participant_before(actor_id, ordered[index], center, source_positions):
				insert_at = index
				break
		ordered.insert(insert_at, actor_id)
	return ordered


static func _participant_before(
	first_id: StringName,
	second_id: StringName,
	center: Vector2,
	source_positions: Dictionary
) -> bool:
	var first_priority := _source_priority(source_positions[first_id] - center)
	var second_priority := _source_priority(source_positions[second_id] - center)
	if first_priority != second_priority:
		return first_priority < second_priority
	return String(first_id) < String(second_id)


static func _source_priority(offset: Vector2) -> int:
	if offset.is_zero_approx():
		return 4
	if absf(offset.y) >= absf(offset.x):
		return 0 if offset.y < 0.0 else 2
	return 1 if offset.x > 0.0 else 3


static func _health_snapshot(current_positions: Dictionary, states: Dictionary) -> Dictionary:
	var snapshot: Dictionary = {}
	for actor_id: StringName in current_positions:
		snapshot[actor_id] = states[actor_id].health
	return snapshot


static func _build_engagement(
	first_id: StringName,
	second_id: StringName,
	center: Vector2,
	source_positions: Dictionary,
	states: Dictionary
) -> Dictionary:
	var first_contact := _contact_info(
		first_id, second_id, center, source_positions, states
	)
	var second_contact := _contact_info(
		second_id, first_id, center, source_positions, states
	)
	var first_score: int = first_contact["score"]
	var second_score: int = second_contact["score"]
	return {
		"first_squad_id": first_id,
		"second_squad_id": second_id,
		"first_contact": first_contact,
		"second_contact": second_contact,
		"first_score": first_score,
		"second_score": second_score,
		"first_advantage": maxi(first_score - second_score, 0),
		"second_advantage": maxi(second_score - first_score, 0),
	}


static func _contact_info(
	actor_id: StringName,
	opponent_id: StringName,
	center: Vector2,
	source_positions: Dictionary,
	states: Dictionary
) -> Dictionary:
	var source: Vector2 = source_positions[actor_id]
	var opponent_source: Vector2 = source_positions[opponent_id]
	var contact_direction := center - source
	var used_opponent_source := false
	if contact_direction.is_zero_approx():
		contact_direction = opponent_source - center
		used_opponent_source = true
	var facing_direction := Vector2(states[actor_id].facing).normalized()
	var normalized_contact := contact_direction.normalized()
	var alignment := facing_direction.dot(normalized_contact)
	var contact_side: StringName = &"side"
	var score := 1
	if normalized_contact.is_zero_approx() or alignment > 0.5:
		contact_side = &"front"
		score = 2
	elif alignment < -0.5:
		contact_side = &"back"
		score = 0
	return {
		"side": contact_side,
		"score": score,
		"facing": states[actor_id].facing,
		"source": source,
		"contact_direction": contact_direction,
		"used_opponent_source": used_opponent_source,
	}


static func _state_signature(
	current_positions: Dictionary,
	states: Dictionary,
	last_sources: Dictionary
) -> String:
	var ids := current_positions.keys()
	ids.sort()
	var parts: Array = []
	for actor_id: StringName in ids:
		parts.append("%s:%s:%d:%s" % [
			actor_id,
			current_positions[actor_id],
			states[actor_id].health,
			"%s:%s" % [last_sources[actor_id], states[actor_id].facing],
		])
	return "|".join(parts)


static func _is_inside(cell: Vector2i, board_size: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < board_size.x and cell.y < board_size.y
