extends RefCounted

const TurnIntentType = preload("res://scripts/model/turn_intent.gd")
const TurnResolutionType = preload("res://scripts/model/turn_resolution.gd")
const SquadBattleResolverType = preload("res://scripts/core/squad_battle_resolver.gd")
const SquadUnitStateType = preload("res://scripts/model/squad_unit_state.gd")

const SKILL_BANDAGE := &"bandage"
const SKILL_FIRST_STRIKE := &"first_strike"
const SKILL_TRAP := &"trap"
const SKILL_GUARD := &"guard"
const BANDAGE_HEAL := 2
const FIRST_STRIKE_DAMAGE := 1
const TRAP_DAMAGE := 2
const FACILITY_MEDICAL := &"medical_station"
const FACILITY_CANNON := &"electromagnetic_cannon"
const MEDICAL_HEAL := 10
const MEDICAL_MP_GAIN := 10
const CANNON_DAMAGE := 3
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
	battle_seed: int = 1337,
	map_effects: Dictionary = {}
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
	var pending_grid_skills: Array = []
	var facility_bumps: Dictionary = {}
	var effects: Dictionary = map_effects.duplicate(true)
	if not effects.has("traps"):
		effects["traps"] = []
	if not effects.has("facilities"):
		effects["facilities"] = []
	var effective_blocked := blocked.duplicate()
	for facility: Dictionary in effects["facilities"]:
		effective_blocked[facility.get("cell", Vector2i(-1, -1))] = true

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
		elif intent.action_type == TurnIntentType.ActionType.USE_SKILL:
			var skill_event := _prepare_grid_skill(states[actor_id], intent, effects)
			if skill_event.get("valid", false):
				movement_result["reason"] = &"used_grid_skill"
				actor_reasons[actor_id] = &"used_grid_skill"
				pending_grid_skills.append(skill_event)
			else:
				movement_result["valid"] = false
				movement_result["reason"] = skill_event.get("reason", &"invalid_grid_skill")
				actor_reasons[actor_id] = movement_result["reason"]
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
			elif _facility_index_at(effects, target) >= 0:
				movement_result["valid"] = false
				var facility_index := _facility_index_at(effects, target)
				var facility: Dictionary = effects["facilities"][facility_index]
				if facility.get("used", false):
					movement_result["reason"] = &"blocked_by_spent_facility"
					actor_reasons[actor_id] = &"blocked_by_spent_facility"
				else:
					movement_result["reason"] = &"facility_candidate"
					actor_reasons[actor_id] = &"facility_candidate"
					var facility_id: StringName = facility["facility_id"]
					var candidates: Array = facility_bumps.get(facility_id, [])
					candidates.append(actor_id)
					facility_bumps[facility_id] = candidates
			elif effective_blocked.has(target):
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

	var pending_facilities := _prepare_facility_activations(
		facility_bumps, states, effects, result, actor_reasons, battle_seed
	)

	var next_wave_index := 0
	var dead_actor_ids: Array = []
	_resolve_traps(
		actor_ids, states, current_positions, last_sources, result.movement_results,
		dead_actor_ids, actor_reasons, effects, result, battle_rng
	)

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

	_resolve_post_combat_effects(
		pending_grid_skills, pending_facilities, states, current_positions,
		dead_actor_ids, actor_reasons, result,
		effective_blocked, board_size, effects, battle_rng
	)
	result.final_map_effects = effects.duplicate(true)

	# Commit final living states and summarize each actor's complete turn.
	result.final_positions.clear()
	for actor_id: StringName in actor_ids:
		if actor_id in dead_actor_ids:
			var dead_target: Vector2i = result.movement_positions[actor_id]
			result.set_outcome(
				actor_id, false, false,
				actor_reasons.get(actor_id, &"died_to_grid_skill"), dead_target
			)
			continue

		var actor = states[actor_id]
		actor.cell = current_positions[actor_id]
		result.final_actor_states[actor_id] = actor
		result.final_positions[actor_id] = actor.cell

		var reason: StringName = actor_reasons.get(actor_id, &"waited")
		var moved: bool = actor.cell != initial_positions[actor_id]
		var success: bool = reason in [
			&"moved", &"waited", &"used_grid_skill", &"activated_facility",
			&"combat_winner_moved", &"combat_winner_held"
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
			engagement["first_direction_advantage"] = engagement["first_advantage"]
			engagement["second_direction_advantage"] = engagement["second_advantage"]
			var guard_result := _apply_guard_advantage(first, second, engagement)
			engagement.merge(guard_result, true)
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


static func _resolve_traps(
	actor_ids: Array,
	states: Dictionary,
	current_positions: Dictionary,
	last_sources: Dictionary,
	movement_results: Dictionary,
	dead_actor_ids: Array,
	actor_reasons: Dictionary,
	map_effects: Dictionary,
	result,
	battle_rng: RandomNumberGenerator
) -> void:
	var traps: Array = map_effects.get("traps", [])
	for actor_id: StringName in actor_ids:
		if not current_positions.has(actor_id):
			continue
		if not movement_results[actor_id].get("moved", false):
			continue
		var trap_index := -1
		for index in traps.size():
			var trap: Dictionary = traps[index]
			if (
				trap.get("cell", Vector2i(-1, -1)) == current_positions[actor_id]
				and trap.get("faction", &"") != states[actor_id].faction
			):
				trap_index = index
				break
		if trap_index < 0:
			continue
		var triggered_trap: Dictionary = traps[trap_index]
		traps.remove_at(trap_index)
		var squad = states[actor_id]
		var candidates: Array = []
		var lowest_health := 1000000
		for unit in squad.units:
			if not unit.is_alive():
				continue
			if unit.health < lowest_health:
				lowest_health = unit.health
				candidates = [unit]
			elif unit.health == lowest_health:
				candidates.append(unit)
		var target = candidates[battle_rng.randi_range(0, candidates.size() - 1)]
		var health_before: int = target.health
		target.health -= TRAP_DAMAGE
		squad.sync_summary_stats()
		result.trap_events.append({
			"actor_id": actor_id,
			"target_unit_id": target.unit_id,
			"health_before": health_before,
			"health_after": target.health,
			"amount": TRAP_DAMAGE,
			"cell": current_positions[actor_id],
			"trap": triggered_trap,
		})
		if not squad.is_alive():
			dead_actor_ids.append(actor_id)
			actor_reasons[actor_id] = &"died_to_trap"
			current_positions.erase(actor_id)
			last_sources.erase(actor_id)
	map_effects["traps"] = traps


static func _trap_index_at(map_effects: Dictionary, cell: Vector2i) -> int:
	var traps: Array = map_effects.get("traps", [])
	for index in traps.size():
		if traps[index].get("cell", Vector2i(-1, -1)) == cell:
			return index
	return -1


static func _apply_guard_advantage(first, second, engagement: Dictionary) -> Dictionary:
	var first_before: int = engagement["first_advantage"]
	var second_before: int = engagement["second_advantage"]
	var first_bonus := 0
	var second_bonus := 0
	var first_source: StringName = &""
	var second_source: StringName = &""
	if first_before < second_before:
		var guard = _oldest_armed_guard(first)
		if guard != null:
			first_bonus = second_before - first_before
			first_source = guard.unit_id
			guard.consume_guard()
	elif second_before < first_before:
		var guard = _oldest_armed_guard(second)
		if guard != null:
			second_bonus = first_before - second_before
			second_source = guard.unit_id
			guard.consume_guard()
	engagement["first_advantage"] += first_bonus
	engagement["second_advantage"] += second_bonus
	return {
		"first_guard_advantage": first_bonus,
		"second_guard_advantage": second_bonus,
		"first_guard_unit_id": first_source,
		"second_guard_unit_id": second_source,
	}


static func _oldest_armed_guard(squad):
	var selected = null
	for unit in squad.units:
		if not unit.is_alive() or not unit.is_guard_armed():
			continue
		if selected == null or unit.guard_order() < selected.guard_order():
			selected = unit
	return selected


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


static func _prepare_grid_skill(actor, intent, map_effects: Dictionary) -> Dictionary:
	var event := {
		"valid": false,
		"actor_id": actor.actor_id,
		"source_unit_id": intent.source_unit_id,
		"skill_id": intent.skill_id,
		"status": &"invalid",
		"heals": [],
		"damages": [],
	}
	var required_class: StringName
	match intent.skill_id:
		SKILL_BANDAGE:
			required_class = SquadUnitStateType.CLASS_WARRIOR
		SKILL_FIRST_STRIKE:
			required_class = SquadUnitStateType.CLASS_ARCHER
		SKILL_TRAP:
			required_class = SquadUnitStateType.CLASS_ASSASSIN
		SKILL_GUARD:
			required_class = SquadUnitStateType.CLASS_TANK
		_:
			event["reason"] = &"unknown_grid_skill"
			return event
	var source = actor.unit_by_id(intent.source_unit_id)
	if source == null or not source.is_alive() or source.unit_class != required_class:
		event["reason"] = &"invalid_skill_source"
		return event
	if source.has_used_grid_skill(intent.skill_id):
		event["reason"] = &"grid_skill_already_used"
		return event
	if intent.skill_id == SKILL_TRAP and _trap_index_at(map_effects, actor.cell) >= 0:
		event["reason"] = &"trap_already_present"
		return event
	if intent.skill_id not in [SKILL_BANDAGE, SKILL_FIRST_STRIKE, SKILL_TRAP, SKILL_GUARD]:
		event["reason"] = &"unknown_grid_skill"
		return event
	source.mark_grid_skill_used(intent.skill_id)
	event["valid"] = true
	event["status"] = &"pending"
	return event


static func _prepare_facility_activations(
	facility_bumps: Dictionary,
	states: Dictionary,
	map_effects: Dictionary,
	result,
	actor_reasons: Dictionary,
	battle_seed: int
) -> Array:
	var pending: Array = []
	var facility_ids := facility_bumps.keys()
	facility_ids.sort()
	for facility_id: StringName in facility_ids:
		var index := _facility_index_by_id(map_effects, facility_id)
		if index < 0:
			continue
		var facility: Dictionary = map_effects["facilities"][index].duplicate(true)
		if facility.get("used", false):
			continue
		var candidates: Array = facility_bumps[facility_id].duplicate()
		candidates.sort()
		var player_candidates: Array = []
		for actor_id: StringName in candidates:
			if states[actor_id].controller == &"player":
				player_candidates.append(actor_id)
		var winner: StringName
		if not player_candidates.is_empty():
			winner = player_candidates[0]
		else:
			var facility_rng := RandomNumberGenerator.new()
			facility_rng.seed = hash("%d:%s" % [battle_seed, String(facility_id)])
			winner = candidates[facility_rng.randi_range(0, candidates.size() - 1)]
		facility["used"] = true
		map_effects["facilities"][index] = facility
		for actor_id: StringName in candidates:
			var won := actor_id == winner
			actor_reasons[actor_id] = &"activated_facility" if won else &"facility_contested"
			result.movement_results[actor_id]["valid"] = won
			result.movement_results[actor_id]["reason"] = actor_reasons[actor_id]
		pending.append({
			"facility_id": facility_id,
			"facility_type": facility["type"],
			"cell": facility["cell"],
			"facing": facility.get("facing", Vector2i.ZERO),
			"candidate_actor_ids": candidates,
			"activator_actor_id": winner,
			"status": &"pending",
			"heals": [],
			"resource_gains": [],
			"damages": [],
			"ray_cells": [],
		})
	return pending


static func _resolve_post_combat_effects(
	pending_grid_skills: Array,
	pending_facilities: Array,
	states: Dictionary,
	current_positions: Dictionary,
	dead_actor_ids: Array,
	actor_reasons: Dictionary,
	result,
	blocked: Dictionary,
	board_size: Vector2i,
	map_effects: Dictionary,
	battle_rng: RandomNumberGenerator
) -> void:
	var health_deltas: Dictionary = {}
	var resource_deltas: Dictionary = {}
	var resolved_events: Array = []
	var resolved_facilities: Array = []
	var facility_damage_targets: Dictionary = {}
	var next_guard_order := _next_guard_order(states)
	for pending: Dictionary in pending_grid_skills:
		var event := pending.duplicate(true)
		var actor_id: StringName = event["actor_id"]
		var actor = states.get(actor_id)
		var source = actor.unit_by_id(event["source_unit_id"]) if actor != null else null
		if actor == null or actor_id in dead_actor_ids or source == null or not source.is_alive():
			event["status"] = &"source_dead"
			resolved_events.append(event)
			continue
		event["status"] = &"resolved"
		match event["skill_id"]:
			SKILL_BANDAGE:
				for unit in actor.units:
					if unit.is_alive():
						var heal_amount := mini(BANDAGE_HEAL, unit.max_health - unit.health)
						_add_health_delta(health_deltas, actor_id, unit.unit_id, heal_amount)
						event["heals"].append({
							"unit_id": unit.unit_id,
							"health_before": unit.health,
							"amount": heal_amount,
						})
			SKILL_FIRST_STRIKE:
				var target_id := _first_hostile_in_ray(
					actor, current_positions, states, blocked, board_size
				)
				event["target_actor_id"] = target_id
				if target_id != &"":
					for unit in states[target_id].units:
						if unit.is_alive():
							_add_health_delta(health_deltas, target_id, unit.unit_id, -FIRST_STRIKE_DAMAGE)
							event["damages"].append({
								"unit_id": unit.unit_id,
								"health_before": unit.health,
								"amount": FIRST_STRIKE_DAMAGE,
							})
			SKILL_TRAP:
				var trap := {
					"cell": current_positions[actor_id],
					"faction": actor.faction,
					"source_actor_id": actor_id,
					"source_unit_id": source.unit_id,
				}
				if _trap_index_at(map_effects, trap["cell"]) < 0:
					map_effects["traps"].append(trap)
					event["cell"] = trap["cell"]
				else:
					event["status"] = &"trap_already_present"
			SKILL_GUARD:
				source.arm_guard(next_guard_order)
				event["guard_order"] = next_guard_order
				next_guard_order += 1
		resolved_events.append(event)

	for pending: Dictionary in pending_facilities:
		var event := pending.duplicate(true)
		var activator_id: StringName = event["activator_actor_id"]
		match event["facility_type"]:
			FACILITY_MEDICAL:
				var actor = states.get(activator_id)
				if actor == null or activator_id in dead_actor_ids or not actor.is_alive():
					event["status"] = &"activator_dead"
				else:
					event["status"] = &"resolved"
					for unit in actor.units:
						if not unit.is_alive():
							continue
						var heal_amount := mini(MEDICAL_HEAL, unit.max_health - unit.health)
						_add_health_delta(health_deltas, activator_id, unit.unit_id, heal_amount)
						event["heals"].append({
							"unit_id": unit.unit_id,
							"health_before": unit.health,
							"amount": heal_amount,
						})
						if unit.has_resource(SquadUnitStateType.RESOURCE_MP):
							var gain := mini(
								MEDICAL_MP_GAIN,
								unit.resource_max(SquadUnitStateType.RESOURCE_MP)
									- unit.resource_value(SquadUnitStateType.RESOURCE_MP)
							)
							_add_resource_delta(
								resource_deltas, activator_id, unit.unit_id,
								SquadUnitStateType.RESOURCE_MP, gain
							)
							event["resource_gains"].append({
								"unit_id": unit.unit_id,
								"resource_id": SquadUnitStateType.RESOURCE_MP,
								"resource_before": unit.resource_value(SquadUnitStateType.RESOURCE_MP),
								"amount": gain,
							})
			FACILITY_CANNON:
				event["status"] = &"resolved"
				var ray := _first_squad_in_facility_ray(
					event["cell"], event["facing"], current_positions,
					states, blocked, board_size
				)
				event["ray_cells"] = ray["ray_cells"]
				var target_id: StringName = ray["target_actor_id"]
				event["target_actor_id"] = target_id
				if target_id == &"":
					event["status"] = &"no_target"
				else:
					facility_damage_targets[target_id] = true
					for unit in states[target_id].units:
						if unit.is_alive():
							_add_health_delta(
								health_deltas, target_id, unit.unit_id, -CANNON_DAMAGE
							)
							event["damages"].append({
								"unit_id": unit.unit_id,
								"health_before": unit.health,
								"amount": CANNON_DAMAGE,
							})
			_:
				event["status"] = &"unknown_facility"
		resolved_facilities.append(event)

	# All post-combat skills selected their targets from the same snapshot. Apply
	# their combined health changes only after every live source has resolved.
	for actor_id: StringName in health_deltas:
		var actor = states.get(actor_id)
		if actor == null:
			continue
		for unit_id: StringName in health_deltas[actor_id]:
			var unit = actor.unit_by_id(unit_id)
			if unit == null:
				continue
			var delta: int = health_deltas[actor_id][unit_id]
			unit.health = mini(unit.health + delta, unit.max_health)
		actor.sync_summary_stats()
		if not actor.is_alive() and not actor_id in dead_actor_ids:
			dead_actor_ids.append(actor_id)
			actor_reasons[actor_id] = (
				&"died_to_facility" if facility_damage_targets.has(actor_id)
				else &"died_to_grid_skill"
			)
			current_positions.erase(actor_id)

	for actor_id: StringName in resource_deltas:
		var actor = states.get(actor_id)
		if actor == null:
			continue
		for unit_id: StringName in resource_deltas[actor_id]:
			var unit = actor.unit_by_id(unit_id)
			if unit == null:
				continue
			for resource_id: StringName in resource_deltas[actor_id][unit_id]:
				unit.gain_resource(resource_id, resource_deltas[actor_id][unit_id][resource_id])

	for event: Dictionary in resolved_events:
		var event_actor = states.get(event["actor_id"])
		for heal: Dictionary in event["heals"]:
			var unit = event_actor.unit_by_id(heal["unit_id"])
			heal["health_after"] = unit.health
		if event.has("target_actor_id") and event["target_actor_id"] != &"":
			var target_actor = states.get(event["target_actor_id"])
			for damage: Dictionary in event["damages"]:
				var unit = target_actor.unit_by_id(damage["unit_id"])
				damage["health_after"] = unit.health
		result.grid_skill_events.append(event)

	for event: Dictionary in resolved_facilities:
		var activator = states.get(event["activator_actor_id"])
		for heal: Dictionary in event["heals"]:
			heal["health_after"] = activator.unit_by_id(heal["unit_id"]).health
		for gain: Dictionary in event["resource_gains"]:
			gain["resource_after"] = activator.unit_by_id(gain["unit_id"]).resource_value(
				gain["resource_id"]
			)
		var target_id: StringName = event.get("target_actor_id", &"")
		if target_id != &"":
			var target_actor = states.get(target_id)
			for damage: Dictionary in event["damages"]:
				damage["health_after"] = target_actor.unit_by_id(damage["unit_id"]).health
		result.facility_events.append(event)


static func _add_health_delta(
	deltas: Dictionary, actor_id: StringName, unit_id: StringName, amount: int
) -> void:
	if not deltas.has(actor_id):
		deltas[actor_id] = {}
	deltas[actor_id][unit_id] = deltas[actor_id].get(unit_id, 0) + amount


static func _add_resource_delta(
	deltas: Dictionary,
	actor_id: StringName,
	unit_id: StringName,
	resource_id: StringName,
	amount: int
) -> void:
	if not deltas.has(actor_id):
		deltas[actor_id] = {}
	if not deltas[actor_id].has(unit_id):
		deltas[actor_id][unit_id] = {}
	deltas[actor_id][unit_id][resource_id] = (
		deltas[actor_id][unit_id].get(resource_id, 0) + amount
	)


static func _first_hostile_in_ray(
	actor, current_positions: Dictionary, states: Dictionary,
	blocked: Dictionary, board_size: Vector2i
) -> StringName:
	for distance in range(1, 4):
		var cell: Vector2i = current_positions[actor.actor_id] + actor.facing * distance
		if not _is_inside(cell, board_size) or blocked.has(cell):
			break
		var candidates: Array = []
		for other_id: StringName in current_positions:
			if current_positions[other_id] == cell and states[other_id].faction != actor.faction:
				candidates.append(other_id)
		candidates.sort()
		if not candidates.is_empty():
			return candidates[0]
	return &""


static func _first_squad_in_facility_ray(
	origin: Vector2i,
	facing: Vector2i,
	current_positions: Dictionary,
	states: Dictionary,
	blocked: Dictionary,
	board_size: Vector2i
) -> Dictionary:
	var ray_cells: Array = []
	var cell := origin + facing
	while _is_inside(cell, board_size):
		if blocked.has(cell):
			break
		ray_cells.append(cell)
		var candidates: Array = []
		for actor_id: StringName in current_positions:
			if current_positions[actor_id] == cell and states[actor_id].is_alive():
				candidates.append(actor_id)
		candidates.sort()
		if not candidates.is_empty():
			return {"target_actor_id": candidates[0], "ray_cells": ray_cells}
		cell += facing
	return {"target_actor_id": &"", "ray_cells": ray_cells}


static func _facility_index_at(map_effects: Dictionary, cell: Vector2i) -> int:
	var facilities: Array = map_effects.get("facilities", [])
	for index in facilities.size():
		if facilities[index].get("cell", Vector2i(-1, -1)) == cell:
			return index
	return -1


static func _facility_index_by_id(map_effects: Dictionary, facility_id: StringName) -> int:
	var facilities: Array = map_effects.get("facilities", [])
	for index in facilities.size():
		if facilities[index].get("facility_id", &"") == facility_id:
			return index
	return -1


static func _next_guard_order(states: Dictionary) -> int:
	var order := 0
	for actor in states.values():
		for unit in actor.units:
			if unit.is_guard_armed():
				order = maxi(order, unit.guard_order() + 1)
	return order


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
