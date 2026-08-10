extends RefCounted

var actor_id: StringName
var cell: Vector2i
var controller: StringName


func _init(
	p_actor_id: StringName = &"",
	p_cell: Vector2i = Vector2i.ZERO,
	p_controller: StringName = &"npc"
) -> void:
	actor_id = p_actor_id
	cell = p_cell
	controller = p_controller
