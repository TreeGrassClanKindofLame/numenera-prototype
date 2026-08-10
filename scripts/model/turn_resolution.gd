extends RefCounted

var final_positions: Dictionary = {}
var outcomes: Dictionary = {}


func _init(initial_positions: Dictionary = {}) -> void:
	final_positions = initial_positions.duplicate(true)
	outcomes = {}


func set_outcome(
	actor_id: StringName,
	success: bool,
	moved: bool,
	reason: StringName,
	target: Vector2i
) -> void:
	outcomes[actor_id] = {
		"success": success,
		"moved": moved,
		"reason": reason,
		"target": target,
	}


func outcome_for(actor_id: StringName) -> Dictionary:
	return outcomes.get(actor_id, {})
