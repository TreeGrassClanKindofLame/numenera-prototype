extends RefCounted

var actor_id: StringName
var cell: Vector2i
var controller: StringName
var faction: StringName
var health: int
var max_health: int
var attack: int


func _init(
	p_actor_id: StringName = &"",
	p_cell: Vector2i = Vector2i.ZERO,
	p_controller: StringName = &"npc",
	p_faction: StringName = &"neutral",
	p_health: int = 1,
	p_max_health: int = 1,
	p_attack: int = 0
) -> void:
	actor_id = p_actor_id
	cell = p_cell
	controller = p_controller
	faction = p_faction
	health = p_health
	max_health = p_max_health
	attack = p_attack


func clone():
	return get_script().new(
		actor_id,
		cell,
		controller,
		faction,
		health,
		max_health,
		attack
	)


func is_alive() -> bool:
	return health > 0
