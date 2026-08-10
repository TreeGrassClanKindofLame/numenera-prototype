extends RefCounted

const TurnIntentType = preload("res://scripts/model/turn_intent.gd")
const TurnResolutionType = preload("res://scripts/model/turn_resolution.gd")

const STATUS_PENDING := &"pending"
const STATUS_SUCCESS := &"success"
const STATUS_FAILED := &"failed"
const STATUS_WAITING := &"waiting"

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
	intents: Dictionary
):
	var positions: Dictionary = {}
	var occupancy: Dictionary = {}
	var actor_ids: Array = []

	for actor in actor_states:
		actor_ids.append(actor.actor_id)
		positions[actor.actor_id] = actor.cell
		occupancy[actor.cell] = actor.actor_id

	var result := TurnResolutionType.new(positions)
	var statuses: Dictionary = {}
	var reasons: Dictionary = {}
	var targets: Dictionary = {}
	var target_claimants: Dictionary = {}

	# Phase 1: validate each raw intent without changing the board.
	for actor_id: StringName in actor_ids:
		var intent = intents.get(
			actor_id,
			TurnIntentType.new(actor_id, TurnIntentType.ActionType.WAIT, Vector2i.ZERO)
		)
		if intent.action_type == TurnIntentType.ActionType.WAIT:
			statuses[actor_id] = STATUS_WAITING
			reasons[actor_id] = &"waited"
			targets[actor_id] = positions[actor_id]
			continue

		if intent.action_type != TurnIntentType.ActionType.MOVE or not intent.delta in VALID_DELTAS:
			statuses[actor_id] = STATUS_FAILED
			reasons[actor_id] = &"invalid_direction"
			targets[actor_id] = positions[actor_id]
			continue

		var target: Vector2i = positions[actor_id] + intent.delta
		targets[actor_id] = target
		if not _is_inside(target, board_size):
			statuses[actor_id] = STATUS_FAILED
			reasons[actor_id] = &"out_of_bounds"
			continue
		if blocked.has(target):
			statuses[actor_id] = STATUS_FAILED
			reasons[actor_id] = &"blocked_by_terrain"
			continue

		statuses[actor_id] = STATUS_PENDING
		var claimants: Array = target_claimants.get(target, [])
		claimants.append(actor_id)
		target_claimants[target] = claimants

	# Phase 2: nobody wins a contested destination.
	for target: Vector2i in target_claimants:
		var claimants: Array = target_claimants[target]
		if claimants.size() <= 1:
			continue
		for actor_id: StringName in claimants:
			statuses[actor_id] = STATUS_FAILED
			reasons[actor_id] = &"target_conflict"

	# Phase 3: build dependencies on actors that must vacate their start cells.
	var dependencies: Dictionary = {}
	for actor_id: StringName in actor_ids:
		if statuses[actor_id] != STATUS_PENDING:
			continue
		var target: Vector2i = targets[actor_id]
		if not occupancy.has(target):
			dependencies[actor_id] = StringName()
			continue

		var occupant_id: StringName = occupancy[target]
		if statuses[occupant_id] == STATUS_PENDING:
			dependencies[actor_id] = occupant_id
		else:
			statuses[actor_id] = STATUS_FAILED
			reasons[actor_id] = &"occupied_actor_not_leaving"

	# Phase 4: resolve chains and cycles, then commit every success together.
	for actor_id: StringName in actor_ids:
		if statuses[actor_id] == STATUS_PENDING:
			_resolve_pending_chain(actor_id, statuses, reasons, dependencies)

	for actor_id: StringName in actor_ids:
		var status: StringName = statuses[actor_id]
		var target: Vector2i = targets[actor_id]
		if status == STATUS_SUCCESS:
			result.final_positions[actor_id] = target
			result.set_outcome(actor_id, true, true, &"moved", target)
		elif status == STATUS_WAITING:
			result.set_outcome(actor_id, true, false, &"waited", target)
		else:
			result.set_outcome(actor_id, false, false, reasons[actor_id], target)

	return result


static func _resolve_pending_chain(
	start_actor_id: StringName,
	statuses: Dictionary,
	reasons: Dictionary,
	dependencies: Dictionary
) -> void:
	var path: Array = []
	var path_indices: Dictionary = {}
	var current_actor_id: StringName = start_actor_id

	while true:
		var status: StringName = statuses[current_actor_id]
		if status == STATUS_SUCCESS:
			_mark_path_success(path, statuses)
			return
		if status != STATUS_PENDING:
			_mark_path_failed(path, statuses, reasons)
			return
		if path_indices.has(current_actor_id):
			# Reaching an actor already in this path means the dependency graph
			# contains a swap or a larger closed movement cycle.
			_mark_path_success(path, statuses)
			return

		path_indices[current_actor_id] = path.size()
		path.append(current_actor_id)
		var dependency: StringName = dependencies.get(current_actor_id, StringName())
		if dependency == StringName():
			_mark_path_success(path, statuses)
			return
		current_actor_id = dependency


static func _mark_path_success(path: Array, statuses: Dictionary) -> void:
	for actor_id: StringName in path:
		statuses[actor_id] = STATUS_SUCCESS


static func _mark_path_failed(path: Array, statuses: Dictionary, reasons: Dictionary) -> void:
	for actor_id: StringName in path:
		statuses[actor_id] = STATUS_FAILED
		reasons[actor_id] = &"occupied_actor_not_leaving"


static func _is_inside(cell: Vector2i, board_size: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < board_size.x and cell.y < board_size.y
