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
