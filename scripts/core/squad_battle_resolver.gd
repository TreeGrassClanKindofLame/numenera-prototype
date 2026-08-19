extends RefCounted

const SquadUnitStateType = preload("res://scripts/model/squad_unit_state.gd")

const SKILL_COMBO := &"combo"
const SKILL_VOLLEY := &"volley"
const SKILL_PROTECT := &"protect"
const SKILL_BULLY := &"bullying"
const PASSIVE_BLOODIED := &"bloodied"
const COMBO_TP_COST := 4
const VOLLEY_MP_COST := 3
const PROTECT_TP_COST := 2
const BULLY_MP_COST := 2


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
	var protection_queues: Dictionary = {
		first_squad.actor_id: [],
		second_squad.actor_id: [],
	}

	var round_zero_turns := _build_round_zero_order(
		first_squad, second_squad, first_advantage, second_advantage, rng
	)
	if not round_zero_turns.is_empty():
		result["round_zero_selected"] = _selected_unit_ids(round_zero_turns)
		_resolve_turns(result, round_zero_turns, &"round_zero", first_squad, second_squad, rng, protection_queues)

	if first_squad.is_alive() and second_squad.is_alive():
		_resolve_turns(
			result,
			_build_turn_order(first_squad, second_squad),
			&"round_one",
			first_squad,
			second_squad,
			rng,
			protection_queues
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
	rng: RandomNumberGenerator,
	protection_queues: Dictionary
) -> void:
	var schedule_start: int = result["turn_schedule"].size()
	var event_start: int = result["events"].size()
	for phase_index in turns.size():
		var turn: Dictionary = turns[phase_index]
		var schedule_index: int = result["turn_schedule"].size()
		var schedule_entry := _schedule_entry(
			turn, phase, phase_index, &"normal_action", &""
		)
		schedule_entry["schedule_index"] = schedule_index
		result["turn_schedule"].append(schedule_entry)
		var acting_squad = first_squad if turn["squad_id"] == first_squad.actor_id else second_squad
		var defending_squad = second_squad if acting_squad == first_squad else first_squad
		var attacker = acting_squad.unit_by_id(turn["unit_id"])
		if attacker == null or not attacker.is_alive():
			_mark_schedule_skipped(result, schedule_index, &"actor_dead")
			continue
		if not defending_squad.is_alive():
			_mark_schedule_skipped(result, schedule_index, &"no_living_enemy")
			continue

		var turn_event_start: int = result["events"].size()
		var summary_action_kind := &"normal_action"
		var summary_skill_id: StringName = &""
		var activation: Dictionary = {}
		if (
			attacker.unit_class == SquadUnitStateType.CLASS_TANK
			and attacker.can_spend_resource(SquadUnitStateType.RESOURCE_TP, PROTECT_TP_COST)
			and acting_squad.living_unit_count() > 1
			and not _queue_contains(protection_queues[acting_squad.actor_id], attacker.unit_id)
		):
			var protect_tp_before: int = attacker.resource_value(SquadUnitStateType.RESOURCE_TP)
			attacker.spend_resource(SquadUnitStateType.RESOURCE_TP, PROTECT_TP_COST)
			protection_queues[acting_squad.actor_id].append(attacker.unit_id)
			activation = {
				"activated_skill_id": SKILL_PROTECT,
				"resource_id": SquadUnitStateType.RESOURCE_TP,
				"resource_before": protect_tp_before,
				"resource_spent": PROTECT_TP_COST,
			}
			summary_action_kind = &"protect_action"
			summary_skill_id = SKILL_PROTECT

		if (
			attacker.unit_class == SquadUnitStateType.CLASS_ASSASSIN
			and defending_squad.living_unit_count() > 1
			and attacker.can_spend_resource(SquadUnitStateType.RESOURCE_MP, BULLY_MP_COST)
		):
			var bully_target_info := _lowest_health_target_info(attacker, defending_squad, rng)
			var bully_mp_before: int = attacker.resource_value(SquadUnitStateType.RESOURCE_MP)
			attacker.spend_resource(SquadUnitStateType.RESOURCE_MP, BULLY_MP_COST)
			_resolve_attack(
				result, turn, phase, phase_index, &"bullying_attack", SKILL_BULLY,
				acting_squad, defending_squad, attacker, first_squad, second_squad, rng,
				{}, -1, 0, {
					"schedule_index": schedule_index,
					"target_info": bully_target_info,
					"resource_id": SquadUnitStateType.RESOURCE_MP,
					"resource_before": bully_mp_before,
					"resource_spent": BULLY_MP_COST,
					"protection_queues": protection_queues,
				}
			)
			summary_action_kind = &"bullying_action"
			summary_skill_id = SKILL_BULLY
			_finalize_schedule(
				result, schedule_index, turn_event_start,
				summary_action_kind, summary_skill_id
			)
			continue

		if attacker.unit_class == SquadUnitStateType.CLASS_ARCHER:
			var primary_info := _choose_target(attacker, defending_squad, rng)
			var primary = primary_info["target"]
			var other_targets: Array = []
			if primary != null:
				for candidate in defending_squad.living_units_in_row(primary.slot.y):
					if candidate.unit_id != primary.unit_id:
						other_targets.append(candidate)
			other_targets.sort_custom(func(first, second):
				if first.slot.x != second.slot.x:
					return first.slot.x < second.slot.x
				return String(first.unit_id) < String(second.unit_id)
			)
			if (
				primary != null and not other_targets.is_empty()
				and attacker.can_spend_resource(SquadUnitStateType.RESOURCE_MP, VOLLEY_MP_COST)
			):
				var volley_mp_before: int = attacker.resource_value(SquadUnitStateType.RESOURCE_MP)
				attacker.spend_resource(SquadUnitStateType.RESOURCE_MP, VOLLEY_MP_COST)
				var volley_options := {
					"schedule_index": schedule_index,
					"target_info": primary_info,
					"resource_id": SquadUnitStateType.RESOURCE_MP,
					"resource_before": volley_mp_before,
					"resource_spent": VOLLEY_MP_COST,
					"protection_queues": protection_queues,
					"volley_role": &"primary",
				}
				_resolve_attack(
					result, turn, phase, phase_index, &"volley_primary", SKILL_VOLLEY,
					acting_squad, defending_squad, attacker, first_squad, second_squad, rng,
					{}, -1, 0, volley_options
				)
				for target in other_targets:
					if not target.is_alive():
						continue
					_resolve_attack(
						result, turn, phase, phase_index, &"volley_secondary", SKILL_VOLLEY,
						acting_squad, defending_squad, attacker, first_squad, second_squad, rng,
						{}, -1, 0, {
							"schedule_index": schedule_index,
							"target_info": _explicit_target_info(attacker, target),
							"resource_id": SquadUnitStateType.RESOURCE_MP,
							"protection_queues": protection_queues,
							"volley_role": &"secondary",
						}
					)
				summary_action_kind = &"volley_action"
				summary_skill_id = SKILL_VOLLEY
				_finalize_schedule(
					result, schedule_index, turn_event_start,
					summary_action_kind, summary_skill_id
				)
				continue

		if (
			attacker.unit_class == SquadUnitStateType.CLASS_WARRIOR
			and attacker.can_spend_resource(SquadUnitStateType.RESOURCE_TP, COMBO_TP_COST)
		):
			summary_action_kind = &"combo_action"
			summary_skill_id = SKILL_COMBO
			var combo_target_info := _choose_target(attacker, defending_squad, rng)
			var combo_formations_before := formation_snapshot(first_squad, second_squad)
			var combo_tp_before: int = attacker.resource_value(SquadUnitStateType.RESOURCE_TP)
			attacker.spend_resource(SquadUnitStateType.RESOURCE_TP, COMBO_TP_COST)
			_resolve_attack(
				result, turn, phase, phase_index, &"combo_attack", SKILL_COMBO,
				acting_squad, defending_squad, attacker, first_squad, second_squad, rng,
				combo_formations_before, combo_tp_before, COMBO_TP_COST,
				{
					"schedule_index": schedule_index,
					"target_info": combo_target_info,
					"protection_queues": protection_queues,
				}
			)
			var locked_target = combo_target_info.get("target")
			if locked_target == null or not locked_target.is_alive():
				_append_missed_strike(
					result, schedule_index, turn, phase, phase_index,
					acting_squad, defending_squad, attacker, locked_target,
					first_squad, second_squad
				)
			else:
				_resolve_attack(
					result, turn, phase, phase_index, &"normal_attack", &"",
					acting_squad, defending_squad, attacker, first_squad, second_squad, rng,
					{}, -1, 0, {
						"schedule_index": schedule_index,
						"target_info": combo_target_info,
						"protection_queues": protection_queues,
					}
				)
			_finalize_schedule(
				result, schedule_index, turn_event_start,
				summary_action_kind, summary_skill_id
			)
			continue

		_resolve_attack(
			result, turn, phase, phase_index, &"normal_attack", &"",
			acting_squad, defending_squad, attacker, first_squad, second_squad, rng,
			{}, -1, 0, activation.merged({
				"schedule_index": schedule_index,
				"protection_queues": protection_queues,
			}, true)
		)
		_finalize_schedule(
			result, schedule_index, turn_event_start,
			summary_action_kind, summary_skill_id
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
	resource_spent: int = 0,
	options: Dictionary = {}
) -> void:
	var schedule_index: int = options.get("schedule_index", -1)
	var target_info: Dictionary = options.get("target_info", _choose_target(attacker, defending_squad, rng))
	var intended_target = target_info["target"]
	var target = intended_target
	if target == null:
		return
	var protected_by: StringName = &""
	var queues: Dictionary = options.get("protection_queues", {})
	if not queues.is_empty():
		var redirect = _consume_protection(defending_squad, intended_target, queues)
		if redirect != null:
			target = redirect
			protected_by = redirect.unit_id

	var health_before: int = target.health
	var squad_health_before: int = defending_squad.health
	var formations_before := (
		formation_snapshot(first_squad, second_squad)
		if formations_before_override.is_empty()
		else formations_before_override
	)
	var resource_id: StringName = options.get(
		"resource_id",
		SquadUnitStateType.RESOURCE_TP if attacker.has_resource(SquadUnitStateType.RESOURCE_TP) else &""
	)
	var resource_before: int = (
		attacker.resource_value(resource_id)
		if resource_before_override < 0
		else resource_before_override
	)
	if options.has("resource_before"):
		resource_before = options["resource_before"]
	if options.has("resource_spent"):
		resource_spent = options["resource_spent"]
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
		"strike_status": &"hit",
		"missed": false,
		"passive_ids": passive_ids,
		"attacker_squad_id": acting_squad.actor_id,
		"defender_squad_id": defending_squad.actor_id,
		"attacker_unit_id": attacker.unit_id,
		"defender_unit_id": target.unit_id,
		"intended_defender_unit_id": intended_target.unit_id,
		"protected_by_unit_id": protected_by,
		"protection_triggered": protected_by != &"",
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
		"resource_id": resource_id,
		"resource_before": resource_before,
		"resource_spent": resource_spent,
		"resource_gained": tp_gained,
		"resource_after": attacker.resource_value(resource_id),
		"activated_skill_id": options.get("activated_skill_id", &""),
		"volley_role": options.get("volley_role", &""),
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


static func _append_missed_strike(
	result: Dictionary, schedule_index: int, turn: Dictionary,
	phase: StringName, phase_index: int, acting_squad, defending_squad,
	attacker, intended_target, first_squad, second_squad
) -> void:
	var target_id: StringName = intended_target.unit_id if intended_target != null else &""
	var target_class: StringName = intended_target.unit_class if intended_target != null else &""
	var target_slot: Vector2i = intended_target.slot if intended_target != null else Vector2i.ZERO
	var target_health: int = intended_target.health if intended_target != null else 0
	var formations := formation_snapshot(first_squad, second_squad)
	result["events"].append({
		"schedule_index": schedule_index,
		"phase": phase,
		"phase_index": phase_index,
		"action_kind": &"combo_miss",
		"skill_id": SKILL_COMBO,
		"strike_status": &"missed_dead_target",
		"missed": true,
		"passive_ids": [],
		"attacker_squad_id": acting_squad.actor_id,
		"defender_squad_id": defending_squad.actor_id,
		"attacker_unit_id": attacker.unit_id,
		"defender_unit_id": target_id,
		"intended_defender_unit_id": target_id,
		"protected_by_unit_id": &"",
		"protection_triggered": false,
		"attacker_class": attacker.unit_class,
		"defender_class": target_class,
		"attacker_slot": attacker.slot,
		"defender_slot": target_slot,
		"speed": attacker.speed,
		"base_damage": attacker.attack,
		"damage_bonus": 0,
		"damage": 0,
		"health_before": target_health,
		"health_after": target_health,
		"defender_squad_health_before": defending_squad.health,
		"defender_squad_health_after": defending_squad.health,
		"target_died": false,
		"resource_id": SquadUnitStateType.RESOURCE_TP,
		"resource_before": attacker.resource_value(SquadUnitStateType.RESOURCE_TP),
		"resource_spent": 0,
		"resource_gained": 0,
		"resource_after": attacker.resource_value(SquadUnitStateType.RESOURCE_TP),
		"activated_skill_id": &"",
		"volley_role": &"",
		"preferred_row": attacker.preferred_row(),
		"selected_row": target_slot.y,
		"used_fallback_row": false,
		"used_random_tie": false,
		"candidate_unit_ids": [target_id] if target_id != &"" else [],
		"target_rule": &"locked_combo_target_dead",
		"target_distance": absi(target_slot.x - attacker.slot.x),
		"formations_before": formations,
		"formations_after": formations.duplicate(true),
	})


static func _mark_schedule_skipped(
	result: Dictionary, schedule_index: int, reason: StringName
) -> void:
	var entry: Dictionary = result["turn_schedule"][schedule_index]
	entry["status"] = &"skipped"
	entry["skipped_reason"] = reason
	result["turn_schedule"][schedule_index] = entry


static func _finalize_schedule(
	result: Dictionary, schedule_index: int, event_start: int,
	action_kind: StringName, skill_id: StringName
) -> void:
	var entry: Dictionary = result["turn_schedule"][schedule_index]
	var event_indices: Array = []
	var intended_targets: Dictionary = {}
	for event_index in range(event_start, result["events"].size()):
		var event: Dictionary = result["events"][event_index]
		if event.get("schedule_index", -1) != schedule_index:
			continue
		event_indices.append(event_index)
		var intended_id: StringName = event.get("intended_defender_unit_id", &"")
		if intended_id != &"":
			intended_targets[intended_id] = true
	var strike_count := event_indices.size()
	for strike_index in strike_count:
		var event_index: int = event_indices[strike_index]
		result["events"][event_index]["strike_index"] = strike_index
		result["events"][event_index]["strike_count"] = strike_count
	entry["action_kind"] = action_kind
	entry["skill_id"] = skill_id
	entry["status"] = &"acted" if strike_count > 0 else &"skipped"
	entry["skipped_reason"] = &"" if strike_count > 0 else &"no_valid_target"
	entry["event_indices"] = event_indices
	entry["event_index"] = event_indices[0] if strike_count > 0 else -1
	entry["strike_count"] = strike_count
	entry["target_count"] = intended_targets.size()
	result["turn_schedule"][schedule_index] = entry


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
	entry["event_indices"] = []
	entry["strike_count"] = 0
	entry["target_count"] = 0
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
			"map_skill_state": unit.map_skill_state.duplicate(true),
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


static func _explicit_target_info(attacker, target) -> Dictionary:
	return {
		"target": target,
		"selected_row": target.slot.y,
		"used_fallback_row": target.slot.y != attacker.preferred_row(),
		"used_random_tie": false,
		"candidate_unit_ids": [target.unit_id],
		"target_rule": &"volley_same_row",
		"target_distance": absi(target.slot.x - attacker.slot.x),
	}


static func _lowest_health_target_info(
	attacker, defending_squad, rng: RandomNumberGenerator
) -> Dictionary:
	var lowest_health := 1000000
	var candidates: Array = []
	for target in defending_squad.living_units():
		if target.health < lowest_health:
			lowest_health = target.health
			candidates = [target]
		elif target.health == lowest_health:
			candidates.append(target)
	candidates.sort_custom(func(first, second): return String(first.unit_id) < String(second.unit_id))
	var target = (
		candidates[0]
		if candidates.size() == 1
		else candidates[rng.randi_range(0, candidates.size() - 1)]
	)
	return {
		"target": target,
		"selected_row": target.slot.y,
		"used_fallback_row": target.slot.y != attacker.preferred_row(),
		"used_random_tie": candidates.size() > 1,
		"candidate_unit_ids": candidates.map(func(candidate): return candidate.unit_id),
		"target_rule": &"lowest_current_health",
		"target_distance": absi(target.slot.x - attacker.slot.x),
	}


static func _queue_contains(queue: Array, unit_id: StringName) -> bool:
	return unit_id in queue


static func _consume_protection(defending_squad, intended_target, queues: Dictionary):
	var queue: Array = queues.get(defending_squad.actor_id, [])
	var index := 0
	while index < queue.size():
		var protector = defending_squad.unit_by_id(queue[index])
		if protector == null or not protector.is_alive():
			queue.remove_at(index)
			continue
		if protector.unit_id == intended_target.unit_id:
			index += 1
			continue
		queue.remove_at(index)
		queues[defending_squad.actor_id] = queue
		return protector
	queues[defending_squad.actor_id] = queue
	return null
