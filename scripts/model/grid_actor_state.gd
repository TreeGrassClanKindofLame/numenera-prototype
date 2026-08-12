extends RefCounted

const SquadUnitStateType = preload("res://scripts/model/squad_unit_state.gd")

var actor_id: StringName
var cell: Vector2i
var controller: StringName
var faction: StringName
var health: int
var max_health: int
var attack: int
var units: Array


func _init(
	p_actor_id: StringName = &"",
	p_cell: Vector2i = Vector2i.ZERO,
	p_controller: StringName = &"npc",
	p_faction: StringName = &"neutral",
	p_health: int = 1,
	p_max_health: int = 1,
	p_attack: int = 0,
	p_units: Array = []
) -> void:
	actor_id = p_actor_id
	cell = p_cell
	controller = p_controller
	faction = p_faction
	units = []
	for source_unit in p_units:
		units.append(source_unit.clone())
	if units.is_empty():
		units.append(SquadUnitStateType.new(
			StringName("%s_unit" % p_actor_id),
			SquadUnitStateType.CLASS_CUSTOM,
			Vector2i(1, SquadUnitStateType.FRONT_ROW),
			p_health,
			p_max_health,
			p_attack,
			1
		))
	health = p_health
	max_health = p_max_health
	attack = p_attack
	sync_summary_stats()


func clone():
	return get_script().new(
		actor_id,
		cell,
		controller,
		faction,
		health,
		max_health,
		attack,
		units
	)


func is_alive() -> bool:
	return living_unit_count() > 0


func living_units() -> Array:
	var result: Array = []
	for unit in units:
		if unit.is_alive():
			result.append(unit)
	return result


func living_units_in_row(row: int) -> Array:
	var result: Array = []
	for unit in units:
		if unit.is_alive() and unit.slot.y == row:
			result.append(unit)
	return result


func living_unit_count() -> int:
	return living_units().size()


func unit_by_id(unit_id: StringName):
	for unit in units:
		if unit.unit_id == unit_id:
			return unit
	return null


func unit_at(slot: Vector2i):
	for unit in units:
		if unit.slot == slot and unit.is_alive():
			return unit
	return null


func set_unit_at(slot: Vector2i, unit_class: StringName) -> bool:
	if slot.x < 0 or slot.x >= 3 or slot.y < 0 or slot.y >= 2:
		return false
	var previous = unit_at(slot)
	if unit_class == &"" and previous != null and living_unit_count() <= 1:
		return false
	for index in range(units.size() - 1, -1, -1):
		if units[index].slot == slot:
			units.remove_at(index)
	if unit_class == &"":
		sync_summary_stats()
		return true
	if living_unit_count() >= 4:
		return false
	var new_id := StringName("%s_r%d_c%d" % [actor_id, slot.y, slot.x])
	units.append(SquadUnitStateType.create_for_class(new_id, unit_class, slot))
	sync_summary_stats()
	return true


func sync_summary_stats() -> void:
	health = 0
	max_health = 0
	attack = 0
	for unit in units:
		max_health += unit.max_health
		if unit.is_alive():
			health += unit.health
			attack += unit.attack
