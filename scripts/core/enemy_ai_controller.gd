extends RefCounted

const TurnIntentType = preload("res://scripts/model/turn_intent.gd")
const EnemyBrainStateType = preload("res://scripts/model/enemy_brain_state.gd")

const CARDINAL_DIRECTIONS := [
	Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT,
]


func choose_intent(
	brain,
	actor,
	player,
	blocked: Dictionary,
	board_size: Vector2i
):
	if actor == null or not actor.is_alive():
		return _wait(brain.actor_id)
	match brain.behavior:
		EnemyBrainStateType.BEHAVIOR_ROBOT:
			return _robot_intent(brain, actor, blocked, board_size)
		EnemyBrainStateType.BEHAVIOR_BANDIT:
			if brain.alerted and player != null and player.is_alive():
				return _pursuit_intent(brain.actor_id, actor.cell, actor.facing, player.cell, blocked, board_size)
	return _wait(brain.actor_id)


func commit_after_turn(
	brain,
	resolution,
	blocked: Dictionary,
	board_size: Vector2i,
	player_id: StringName = &"player"
) -> Array:
	var events: Array = []
	if resolution.is_dead(brain.actor_id):
		brain.clear_pending_target()
		return events
	match brain.behavior:
		EnemyBrainStateType.BEHAVIOR_ROBOT:
			if brain.move_turn and brain.has_pending_target:
				var final_actor = resolution.actor_state_for(brain.actor_id)
				if final_actor != null and final_actor.cell == brain.pending_target:
					brain.patrol_index = brain.pending_path_index
			brain.move_turn = not brain.move_turn
			brain.clear_pending_target()
		EnemyBrainStateType.BEHAVIOR_BANDIT:
			if not brain.alerted and _bandit_detected_player(
				brain, resolution, blocked, board_size, player_id
			):
				brain.alerted = true
				events.append({
					"kind": &"bandit_alerted",
					"actor_id": brain.actor_id,
					"player_id": player_id,
				})
	return events


func vision_cells(
	cell: Vector2i,
	facing: Vector2i,
	blocked: Dictionary,
	board_size: Vector2i
) -> Dictionary:
	var result: Dictionary = {}
	var forward := facing if facing in CARDINAL_DIRECTIONS else Vector2i.DOWN
	var right := Vector2i(-forward.y, forward.x)
	var offsets: Array[Vector2i] = []
	# Keep only immediate lateral awareness. The three rear-adjacent cells are
	# deliberate blind spots so approaching from behind remains meaningful.
	offsets.append(right)
	offsets.append(-right)
	for distance in range(1, 4):
		# A shortened continuous cone: 3 cells, 3 cells, then 5 cells.
		var half_width := maxi(1, distance - 1)
		for lateral in range(-half_width, half_width + 1):
			offsets.append(forward * distance + right * lateral)
	for offset: Vector2i in offsets:
		var target := cell + offset
		if not _is_inside(target, board_size) or blocked.has(target):
			continue
		if _has_line_of_sight(cell, target, blocked):
			result[target] = true
	return result


func robot_next_target(brain) -> Vector2i:
	if brain.patrol_path.is_empty():
		return Vector2i(-1, -1)
	var next_index := wrapi(
		brain.patrol_index + brain.patrol_direction,
		0,
		brain.patrol_path.size()
	)
	return brain.patrol_path[next_index]


func _robot_intent(brain, actor, blocked: Dictionary, board_size: Vector2i):
	brain.clear_pending_target()
	if not brain.move_turn or brain.patrol_path.is_empty():
		return _wait(brain.actor_id)
	var next_index := wrapi(
		brain.patrol_index + brain.patrol_direction,
		0,
		brain.patrol_path.size()
	)
	var target: Vector2i = brain.patrol_path[next_index]
	if _is_blocked(target, blocked, board_size):
		brain.patrol_direction *= -1
		next_index = wrapi(
			brain.patrol_index + brain.patrol_direction,
			0,
			brain.patrol_path.size()
		)
		target = brain.patrol_path[next_index]
	if _is_blocked(target, blocked, board_size):
		return _wait(brain.actor_id)
	var delta: Vector2i = target - actor.cell
	if not delta in CARDINAL_DIRECTIONS:
		return _wait(brain.actor_id)
	brain.has_pending_target = true
	brain.pending_target = target
	brain.pending_path_index = next_index
	return TurnIntentType.new(brain.actor_id, TurnIntentType.ActionType.MOVE, delta)


func _pursuit_intent(
	actor_id: StringName,
	start: Vector2i,
	facing: Vector2i,
	target: Vector2i,
	blocked: Dictionary,
	board_size: Vector2i
):
	if start == target:
		return _wait(actor_id)
	var forward := facing if facing in CARDINAL_DIRECTIONS else Vector2i.DOWN
	var left := Vector2i(forward.y, -forward.x)
	var right := -left
	var preferred_directions := [forward, left, right, -forward]
	var best_delta := Vector2i.ZERO
	var best_distance := 1_000_000
	for delta: Vector2i in preferred_directions:
		var next := start + delta
		if _is_blocked(next, blocked, board_size):
			continue
		var distance := _shortest_distance(next, target, blocked, board_size)
		if distance >= 0 and distance < best_distance:
			best_distance = distance
			best_delta = delta
	if best_delta == Vector2i.ZERO:
		return _wait(actor_id)
	return TurnIntentType.new(actor_id, TurnIntentType.ActionType.MOVE, best_delta)


func _shortest_distance(
	start: Vector2i,
	target: Vector2i,
	blocked: Dictionary,
	board_size: Vector2i
) -> int:
	if start == target:
		return 0
	var queue: Array[Vector2i] = [start]
	var distances: Dictionary = {start: 0}
	var read_index := 0
	while read_index < queue.size():
		var current: Vector2i = queue[read_index]
		read_index += 1
		for delta: Vector2i in CARDINAL_DIRECTIONS:
			var next := current + delta
			if distances.has(next) or _is_blocked(next, blocked, board_size):
				continue
			var next_distance: int = distances[current] + 1
			if next == target:
				return next_distance
			distances[next] = next_distance
			queue.append(next)
	return -1


func _bandit_detected_player(
	brain,
	resolution,
	blocked: Dictionary,
	board_size: Vector2i,
	player_id: StringName
) -> bool:
	if not resolution.movement_positions.has(brain.actor_id):
		return false
	if not resolution.movement_positions.has(player_id):
		return false
	for event: Dictionary in resolution.combat_events:
		var first_id: StringName = event.get("attacker_squad_id", &"")
		var second_id: StringName = event.get("defender_squad_id", &"")
		if (
			(first_id == brain.actor_id and second_id == player_id)
			or (first_id == player_id and second_id == brain.actor_id)
		):
			return true
	var actor_cell: Vector2i = resolution.movement_positions[brain.actor_id]
	var player_cell: Vector2i = resolution.movement_positions[player_id]
	var facing: Vector2i = resolution.movement_results[brain.actor_id].get(
		"facing", Vector2i.DOWN
	)
	return vision_cells(actor_cell, facing, blocked, board_size).has(player_cell)


func _has_line_of_sight(
	start: Vector2i,
	target: Vector2i,
	blocked: Dictionary
) -> bool:
	var x := start.x
	var y := start.y
	var dx := absi(target.x - start.x)
	var dy := absi(target.y - start.y)
	var step_x := 1 if start.x < target.x else -1
	var step_y := 1 if start.y < target.y else -1
	var error := dx - dy
	while x != target.x or y != target.y:
		var doubled_error := error * 2
		if doubled_error > -dy:
			error -= dy
			x += step_x
		if doubled_error < dx:
			error += dx
			y += step_y
		var point := Vector2i(x, y)
		if point != target and blocked.has(point):
			return false
	return true


func _is_blocked(
	cell: Vector2i,
	blocked: Dictionary,
	board_size: Vector2i
) -> bool:
	return not _is_inside(cell, board_size) or blocked.has(cell)


func _is_inside(cell: Vector2i, board_size: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < board_size.x and cell.y < board_size.y


func _wait(actor_id: StringName):
	return TurnIntentType.new(actor_id, TurnIntentType.ActionType.WAIT, Vector2i.ZERO)
