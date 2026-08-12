extends RefCounted


static func resolve_round(first_squad, second_squad, rng: RandomNumberGenerator) -> Dictionary:
	var result := {
		"first_squad_id": first_squad.actor_id,
		"second_squad_id": second_squad.actor_id,
		"events": [],
		"action_order": [],
		"first_alive_before": first_squad.living_unit_count(),
		"second_alive_before": second_squad.living_unit_count(),
		"formations_before": _formation_snapshot(first_squad, second_squad),
	}
	var turns := _build_turn_order(first_squad, second_squad)
	for turn: Dictionary in turns:
		var acting_squad = first_squad if turn["squad_id"] == first_squad.actor_id else second_squad
		var defending_squad = second_squad if acting_squad == first_squad else first_squad
		var attacker = acting_squad.unit_by_id(turn["unit_id"])
		if attacker == null or not attacker.is_alive() or not defending_squad.is_alive():
			continue
		var target_info := _choose_target(attacker, defending_squad, rng)
		var target = target_info["target"]
		if target == null:
			continue
		var health_before: int = target.health
		var squad_health_before: int = defending_squad.health
		var formations_before := _formation_snapshot(first_squad, second_squad)
		target.health -= attacker.attack
		defending_squad.sync_summary_stats()
		var event := {
			"attacker_squad_id": acting_squad.actor_id,
			"defender_squad_id": defending_squad.actor_id,
			"attacker_unit_id": attacker.unit_id,
			"defender_unit_id": target.unit_id,
			"attacker_class": attacker.unit_class,
			"defender_class": target.unit_class,
			"attacker_slot": attacker.slot,
			"defender_slot": target.slot,
			"speed": attacker.speed,
			"damage": attacker.attack,
			"health_before": health_before,
			"health_after": target.health,
			"defender_squad_health_before": squad_health_before,
			"defender_squad_health_after": defending_squad.health,
			"target_died": not target.is_alive(),
			"preferred_row": attacker.preferred_row(),
			"selected_row": target_info["selected_row"],
			"used_fallback_row": target_info["used_fallback_row"],
			"used_random_tie": target_info["used_random_tie"],
			"candidate_unit_ids": target_info["candidate_unit_ids"],
			"formations_before": formations_before,
			"formations_after": _formation_snapshot(first_squad, second_squad),
		}
		result["events"].append(event)
		result["action_order"].append([acting_squad.actor_id, attacker.unit_id])

	first_squad.sync_summary_stats()
	second_squad.sync_summary_stats()
	result["first_alive_after"] = first_squad.living_unit_count()
	result["second_alive_after"] = second_squad.living_unit_count()
	result["first_eliminated"] = not first_squad.is_alive()
	result["second_eliminated"] = not second_squad.is_alive()
	result["formations_after"] = _formation_snapshot(first_squad, second_squad)
	return result


static func _formation_snapshot(first_squad, second_squad) -> Dictionary:
	return {
		first_squad.actor_id: _unit_snapshot(first_squad),
		second_squad.actor_id: _unit_snapshot(second_squad),
	}


static func _unit_snapshot(squad) -> Array:
	var snapshot: Array = []
	for unit in squad.units:
		snapshot.append({
			"unit_id": unit.unit_id,
			"unit_class": unit.unit_class,
			"slot": unit.slot,
			"health": unit.health,
			"max_health": unit.max_health,
			"attack": unit.attack,
			"speed": unit.speed,
			"alive": unit.is_alive(),
		})
	return snapshot


static func _build_turn_order(first_squad, second_squad) -> Array:
	var turns: Array = []
	for squad in [first_squad, second_squad]:
		for unit in squad.living_units():
			turns.append({
				"squad_id": squad.actor_id,
				"unit_id": unit.unit_id,
				"speed": unit.speed,
				"is_player": squad.controller == &"player",
			})
	turns.sort_custom(func(first: Dictionary, second: Dictionary):
		if first["speed"] != second["speed"]:
			return first["speed"] > second["speed"]
		if first["is_player"] != second["is_player"]:
			return first["is_player"]
		if first["squad_id"] != second["squad_id"]:
			return String(first["squad_id"]) < String(second["squad_id"])
		return String(first["unit_id"]) < String(second["unit_id"])
	)
	return turns


static func _choose_target(attacker, defending_squad, rng: RandomNumberGenerator) -> Dictionary:
	var selected_row: int = attacker.preferred_row()
	var row_targets: Array = defending_squad.living_units_in_row(selected_row)
	var used_fallback_row := false
	if row_targets.is_empty():
		selected_row = 1 - selected_row
		row_targets = defending_squad.living_units_in_row(selected_row)
		used_fallback_row = true
	if row_targets.is_empty():
		return {
			"target": null,
			"selected_row": selected_row,
			"used_fallback_row": used_fallback_row,
			"used_random_tie": false,
			"candidate_unit_ids": [],
		}

	var nearest_distance := 99
	var nearest: Array = []
	for target in row_targets:
		var distance := absi(target.slot.x - attacker.slot.x)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = [target]
		elif distance == nearest_distance:
			nearest.append(target)
	nearest.sort_custom(func(first, second): return String(first.unit_id) < String(second.unit_id))
	var candidate_ids: Array = []
	for candidate in nearest:
		candidate_ids.append(candidate.unit_id)
	var used_random_tie := nearest.size() > 1
	var target = nearest[0] if nearest.size() == 1 else nearest[rng.randi_range(0, nearest.size() - 1)]
	return {
		"target": target,
		"selected_row": selected_row,
		"used_fallback_row": used_fallback_row,
		"used_random_tie": used_random_tie,
		"candidate_unit_ids": candidate_ids,
	}
