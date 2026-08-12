extends RefCounted

const TurnIntentType = preload("res://scripts/model/turn_intent.gd")

const DELTAS := [
	Vector2i.UP,
	Vector2i.DOWN,
	Vector2i.LEFT,
	Vector2i.RIGHT,
	Vector2i.ZERO,
]

var _rng := RandomNumberGenerator.new()


func _init(seed_value: int = 1337) -> void:
	_rng.seed = seed_value


func choose_intent(actor_id: StringName):
	var delta: Vector2i = DELTAS[_rng.randi_range(0, DELTAS.size() - 1)]
	if delta == Vector2i.ZERO:
		return TurnIntentType.new(actor_id, TurnIntentType.ActionType.WAIT, Vector2i.ZERO)
	return TurnIntentType.new(actor_id, TurnIntentType.ActionType.MOVE, delta)


func choose_pursuit_intent(
	actor_id: StringName,
	actor_cell: Vector2i,
	target_cell: Vector2i,
	blocked: Dictionary,
	board_size: Vector2i
):
	var offset := target_cell - actor_cell
	var candidates: Array[Vector2i] = []
	if offset.x != 0:
		candidates.append(Vector2i(signi(offset.x), 0))
	if offset.y != 0:
		candidates.append(Vector2i(0, signi(offset.y)))
	for delta: Vector2i in candidates:
		var destination := actor_cell + delta
		if (
			destination.x >= 0 and destination.y >= 0
			and destination.x < board_size.x and destination.y < board_size.y
			and not blocked.has(destination)
		):
			return TurnIntentType.new(actor_id, TurnIntentType.ActionType.MOVE, delta)
	return TurnIntentType.new(actor_id, TurnIntentType.ActionType.WAIT, Vector2i.ZERO)
