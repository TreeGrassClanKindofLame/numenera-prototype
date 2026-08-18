extends RefCounted

enum ActionType {
	WAIT,
	MOVE,
	USE_SKILL,
}

var actor_id: StringName
var action_type: int
var delta: Vector2i
var skill_id: StringName
var source_unit_id: StringName


func _init(
	p_actor_id: StringName = &"",
	p_action_type: int = ActionType.WAIT,
	p_delta: Vector2i = Vector2i.ZERO,
	p_skill_id: StringName = &"",
	p_source_unit_id: StringName = &""
) -> void:
	actor_id = p_actor_id
	action_type = p_action_type
	delta = p_delta
	skill_id = p_skill_id
	source_unit_id = p_source_unit_id
