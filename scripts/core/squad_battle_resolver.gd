extends RefCounted

const SquadUnitStateType = preload("res://scripts/model/squad_unit_state.gd")

const SKILL_COMBO := &"combo"
const PASSIVE_BLOODIED := &"bloodied"
const COMBO_TP_COST := 4


static func resolve_round(
	first_squad,
	second_squad,
	rng: RandomNumberGenerator,
	first_advantage: int = 0,
	second_advantage: int = 0,
	engagement: Dictionary = {}
) -> Dictionary:
	var result := {
		"first_squad_id": first_squad.actor_id,
		"second_squad_id": second_squad.actor_id,
		"first_controller": first_squad.controller,
		"second_controller": second_squad.controller,
		"events": [],
		"action_order": [],
		"turn_schedule": [],
		"combat_phases": [],
		"round_zero_selected": {},
		"first_advantage": maxi(first_advantage, 0),
		"second_advantage": maxi(second_advantage, 0),
		"engagement": engagement.duplicate(true),
		"first_alive_before": first_squad.living_unit_count(),
		"second_alive_before": second_squad.living_unit_count(),
		"formations_before": formation_snapshot(first_squad, second_squad),
	}

	var round_zero_turns := _build_round_zero_order(
		first_squad, second_squad, first_advantage, second_advantage, rng
	)
	if not round_zero_turns.is_empty():
		result["round_zero_selected"] = _selected_unit_ids(round_zero_turns)
		_resolve_turns(result, round_zero_turns, &"round_zero", first_squad, second_squad, rng)

	if first_squad.is_alive() and second_squad.is_alive():
		_resolve_turns(
			result,
			_build_turn_order(first_squad, second_squad),
			&"round_one",
			first_squad,
			second_squad,
			rng
		)
	else:
		result["round_one_cancelled"] = true

	first_squad.sync_summary_stats()
	second_squad.sync_summary_stats()
	result["first_alive_after"] = first_squad.living_unit_count()
	result["second_alive_after"] = second_squad.living_unit_count()
	result["first_eliminated"] = not first_squad.is_alive()
	result["second_eliminated"] = not second_squad.is_alive()
	result["formations_after"] = formation_snapshot(first_squad, second_squad)
	return result


static func _resolve_turns(
	result: Dictionary,
	turns: Array,
	phase: StringName,
	first_squad,
	second_squad,
	rng: RandomNumberGenerator
) -> void:
	var schedule_start: int = result["turn_schedule"].size()
	var event_start: int = result["events"].size()
	for phase_index in turns.size():
		var turn: Dictionary = turns[phase_index]
		var acting_squad = first_squad if turn["squad_id"] == first_squad.actor_id else second_squad
		var defending_squad = second_squad if acting_squad == first_squad else first_squad
		var attacker = acting_squad.unit_by_id(turn["unit_id"])
		if attacker == null or not attacker.is_alive():
			_append_skipped_action(result, turn, phase, phase_index, &"normal_attack", &"", &"actor_dead")
			continue
		if not defending_squad.is_alive():
			_append_skipped_action(result, turn, phase, phase_index, &"normal_attack", &"", &"no_living_enemy")
			continue

		if (
			attacker.unit_class == SquadUnitStateType.CLASS_WARRIOR
			and attacker.can_spend_resource(SquadUnitStateType.RESOURCE_TP, COMBO_TP_COST)
		):
			var combo_formations_before := formation_snapshot(first_squad, second_squad)
			var combo_tp_before: int = attacker.resource_value(SquadUnitStateType.RESOURCE_TP)
			attacker.spend_resource(SquadUnitStateType.RESOURCE_TP, COMBO_TP_COST)
			_resolve_attack(
				result, turn, phase, phase_index, &"combo_attack", SKILL_COMBO,
				acting_squad, defending_squad, attacker, first_squad, second_squad, rng,
				combo_formations_before, combo_tp_before, COMBO_TP_COST
			)

		if not defending_squad.is_alive():
			_append_skipped_action(result, turn, phase, phase_index, &"normal_attack", &"", &"no_living_enemy")
			continue
		_resolve_attack(
			result, turn, phase, phase_index, &"normal_attack", &"",
			acting_squad, defending_squad, attacker, first_squad, second_squad, rng
		)
	result["combat_phases"].append({
		"phase": phase,
		"schedule_start": schedule_start,
		"schedule_count": result["turn_schedule"].size() - schedule_start,
		"event_start": event_start,
		"event_count": result["events"].size() - event_start,
	})


static func _resolve_attack(
	result: Dictionary,
	turn: Dictionary,
	phase: StringName,
	phase_index: int,
	action_kind: StringName,
	skill_id: StringName,
	acting_squad,
	defending_squad,
	attacker,
	first_squad,
	second_squad,
	rng: RandomNumberGenerator,
	formations_before_override: Dictionary = {},
	resource_before_override: int = -1,
	resource_spent: int = 0
) -> void:
	var schedule_entry := _schedule_entry(turn, phase, phase_index, action_kind, skill_id)
	var schedule_index: int = result["turn_schedule"].size()
	schedule_entry["schedule_index"] = schedule_index
	var target_info := _choose_target(attacker, defending_squad, rng)
	var target = target_info["target"]
	if target == null:
		schedule_entry["status"] = &"skipped"
		schedule_entry["skipped_reason"] = &"no_valid_target"
		result["turn_schedule"].append(schedule_entry)
		return

	var health_before: int = target.health
	var squad_health_before: int = defending_squad.health
	var formations_before := (
		formation_snapshot(first_squad, second_squad)
		if formations_before_override.is_empty()
		else formations_before_override
	)
	var tp_before: int = (
		attacker.resource_value(SquadUnitStateType.RESOURCE_TP)
		if resource_before_override < 0
		else resource_before_override
	)
	var damage_bonus := 0
	var passive_ids: Array = []
	if (
		attacker.unit_class == SquadUnitStateType.CLASS_WARRIOR
		and attacker.health * 2 < attacker.max_health
	):
		damage_bonus = 1
		passive_ids.append(PASSIVE_BLOODIED)
	var damage: int = attacker.attack + damage_bonus
	target.health -= damage
	defending_squad.sync_summary_stats()
	var tp_gained: int = attacker.gain_resource(SquadUnitStateType.RESOURCE_TP, 1)
	var event_index: int = result["events"].size()
	var event := {
		"schedule_index": schedule_index,
		"phase": phase,
		"phase_index": phase_index,
		"action_kind": action_kind,
		"skill_id": skill_id,
		"passive_ids": passive_ids,
		"attacker_squad_id": acting_squad.actor_id,
		"defender_squad_id": defending_squad.actor_id,
		"attacker_unit_id": attacker.unit_id,
		"defender_unit_id": target.unit_id,
		"attacker_class": attacker.unit_class,
		"defender_class": target.unit_class,
		"attacker_slot": attacker.slot,
		"defender_slot": target.slot,
		"speed": attacker.speed,
		"base_damage": attacker.attack,
		"damage_bonus": damage_bonus,
		"damage": damage,
		"health_before": health_before,
		"health_after": target.health,
		"defender_squad_health_before": squad_health_before,
		"defender_squad_health_after": defending_squad.health,
		"target_died": not target.is_alive(),
		"resource_id": SquadUnitStateType.RESOURCE_TP if attacker.has_resource(SquadUnitStateType.RESOURCE_TP) else &"",
		"resource_before": tp_before,
		"resource_spent": resource_spent,
		"resource_gained": tp_gained,
		"resource_after": attacker.resource_value(SquadUnitStateType.RESOURCE_TP),
		"preferred_row": attacker.preferred_row(),
		"selected_row": target_info["selected_row"],
		"used_fallback_row": target_info["used_fallback_row"],
		"used_random_tie": target_info["used_random_tie"],
		"candidate_unit_ids": target_info["candidate_unit_ids"],
		"target_rule": target_info["target_rule"],
		"target_distance": target_info["target_distance"],
		"formations_before": formations_before,
		"formations_after": formation_snapshot(first_squad, second_squad),
	}
	result["events"].append(event)
	result["action_order"].append([acting_squad.actor_id, attacker.unit_id])
	schedule_entry["status"] = &"acted"
	schedule_entry["event_index"] = event_index
	result["turn_schedule"].append(schedule_entry)


static func _append_skipped_action(
	result: Dictionary,
	turn: Dictionary,
	phase: StringName,
	phase_index: int,
	action_kind: StringName,
	skill_id: StringName,
	reason: StringName
) -> void:
	var entry := _schedule_entry(turn, phase, phase_index, action_kind, skill_id)
	entry["schedule_index"] = result["turn_schedule"].size()
	entry["status"] = &"skipped"
	entry["skipped_reason"] = reason
	result["turn_schedule"].append(entry)


static func _schedule_entry(
	turn: Dictionary,
	phase: StringName,
	phase_index: int,
	action_kind: StringName,
	skill_id: StringName
) -> Dictionary:
	var entry := turn.duplicate(true)
	entry["phase"] = phase
	entry["phase_index"] = phase_index
	entry["action_kind"] = action_kind
	entry["skill_id"] = skill_id
	entry["status"] = &"pending"
	entry["skipped_reason"] = &""
	entry["event_index"] = -1
	return entry


static func _build_round_zero_order(
	first_squad,
	second_squad,
	first_advantage: int,
	second_advantage: int,
	rng: RandomNumberGenerator
) -> Array:
	var turns: Array = []
	for entry: Array in [
		[first_squad, maxi(first_advantage, 0)],
		[second_squad, maxi(second_advantage, 0)],
	]:
		var squad = entry[0]
		var advantage: int = entry[1]
		if advantage <= 0:
			continue
		var candidates: Array = squad.living_units().duplicate()
		_shuffle_with_rng(candidates, rng)
		for index in mini(advantage, candidates.size()):
			var unit = candidates[index]
			turns.append({
				"squad_id": squad.actor_id,
				"unit_id": unit.unit_id,
				"speed": unit.speed,
				"is_player": squad.controller == &"player",
			})
	return turns


static func _shuffle_with_rng(items: Array, rng: RandomNumberGenerator) -> void:
	for index in range(items.size() - 1, 0, -1):
		var swap_index := rng.randi_range(0, index)
		var temporary = items[index]
		items[index] = items[swap_index]
		items[swap_index] = temporary


static func _selected_unit_ids(turns: Array) -> Dictionary:
	var selected: Dictionary = {}
	for turn: Dictionary in turns:
		var squad_id: StringName = turn["squad_id"]
		var unit_ids: Array = selected.get(squad_id, [])
		unit_ids.append(turn["unit_id"])
		selected[squad_id] = unit_ids
	return selected


static func formation_snapshot(first_squad, second_squad) -> Dictionary:
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
			"resources": unit.resources.duplicate(true),
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
			"target_rule": &"no_valid_target",
			"target_distance": -1,
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
	var target_distance: int = absi(target.slot.x - attacker.slot.x)
	var row_rule := "fallback" if used_fallback_row else "preferred"
	var column_rule := "facing" if target_distance == 0 else "nearest"
	return {
		"target": target,
		"selected_row": selected_row,
		"used_fallback_row": used_fallback_row,
		"used_random_tie": used_random_tie,
		"candidate_unit_ids": candidate_ids,
		"target_rule": StringName("%s_%s" % [row_rule, column_rule]),
		"target_distance": target_distance,
	}
