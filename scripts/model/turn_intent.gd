extends RefCounted

enum ActionType {
	WAIT,
	MOVE,
}

var actor_id: StringName
var action_type: int
var delta: Vector2i


func _init(
	p_actor_id: StringName = &"",
	p_action_type: int = ActionType.WAIT,
	p_delta: Vector2i = Vector2i.ZERO
) -> void:
	actor_id = p_actor_id
	action_type = p_action_type
	delta = p_delta
