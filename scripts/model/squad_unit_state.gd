extends RefCounted

const CLASS_TANK := &"tank"
const CLASS_WARRIOR := &"warrior"
const CLASS_ARCHER := &"archer"
const CLASS_ASSASSIN := &"assassin"
const CLASS_CUSTOM := &"custom"

const RESOURCE_MP := &"mp"
const RESOURCE_TP := &"tp"
const RESOURCE_LIMIT := 5

const FRONT_ROW := 0
const BACK_ROW := 1
const COLUMN_COUNT := 3
const ROW_COUNT := 2

var unit_id: StringName
var unit_class: StringName
var slot: Vector2i
var health: int
var max_health: int
var attack: int
var speed: int
var resources: Dictionary
var map_skill_state: Dictionary


func _init(
	p_unit_id: StringName = &"",
	p_unit_class: StringName = CLASS_WARRIOR,
	p_slot: Vector2i = Vector2i.ZERO,
	p_health: int = 5,
	p_max_health: int = 5,
	p_attack: int = 2,
	p_speed: int = 2,
	p_resources: Dictionary = {},
	p_map_skill_state: Dictionary = {}
) -> void:
	unit_id = p_unit_id
	unit_class = p_unit_class
	slot = p_slot
	health = p_health
	max_health = p_max_health
	attack = p_attack
	speed = p_speed
	resources = (
		initial_resources_for_class(unit_class)
		if p_resources.is_empty()
		else p_resources.duplicate(true)
	)
	map_skill_state = p_map_skill_state.duplicate(true)


static func create_for_class(
	p_unit_id: StringName,
	p_unit_class: StringName,
	p_slot: Vector2i
):
	var stats := class_stats(p_unit_class)
	return load("res://scripts/model/squad_unit_state.gd").new(
		p_unit_id,
		p_unit_class,
		p_slot,
		stats["health"],
		stats["health"],
		stats["attack"],
		stats["speed"]
	)


static func class_stats(p_unit_class: StringName) -> Dictionary:
	match p_unit_class:
		CLASS_TANK:
			return {"health": 8, "attack": 1, "speed": 1, "preferred_row": FRONT_ROW}
		CLASS_ARCHER:
			return {"health": 3, "attack": 3, "speed": 2, "preferred_row": FRONT_ROW}
		CLASS_ASSASSIN:
			return {"health": 3, "attack": 2, "speed": 3, "preferred_row": BACK_ROW}
		CLASS_CUSTOM:
			return {"health": 1, "attack": 1, "speed": 1, "preferred_row": FRONT_ROW}
		_:
			return {"health": 5, "attack": 2, "speed": 2, "preferred_row": FRONT_ROW}


static func initial_resources_for_class(p_unit_class: StringName) -> Dictionary:
	match p_unit_class:
		CLASS_WARRIOR, CLASS_TANK:
			return {
				RESOURCE_TP: {"current": 0, "max": RESOURCE_LIMIT},
			}
		CLASS_ARCHER, CLASS_ASSASSIN:
			return {
				RESOURCE_MP: {"current": RESOURCE_LIMIT, "max": RESOURCE_LIMIT},
			}
	return {}


func clone():
	return get_script().new(
		unit_id,
		unit_class,
		slot,
		health,
		max_health,
		attack,
		speed,
		resources,
		map_skill_state
	)


func has_used_grid_skill(skill_id: StringName) -> bool:
	return map_skill_state.get("used_%s" % String(skill_id), false)


func mark_grid_skill_used(skill_id: StringName) -> void:
	map_skill_state["used_%s" % String(skill_id)] = true


func is_guard_armed() -> bool:
	return map_skill_state.get("guard_armed", false)


func guard_order() -> int:
	return map_skill_state.get("guard_order", -1)


func arm_guard(order: int) -> void:
	map_skill_state["guard_armed"] = true
	map_skill_state["guard_order"] = order


func consume_guard() -> void:
	map_skill_state["guard_armed"] = false
	map_skill_state["guard_order"] = -1


func has_resource(resource_id: StringName) -> bool:
	return resources.has(resource_id)


func resource_value(resource_id: StringName) -> int:
	if not resources.has(resource_id):
		return 0
	return resources[resource_id].get("current", 0)


func resource_max(resource_id: StringName) -> int:
	if not resources.has(resource_id):
		return 0
	return resources[resource_id].get("max", 0)


func can_spend_resource(resource_id: StringName, amount: int) -> bool:
	return amount >= 0 and has_resource(resource_id) and resource_value(resource_id) >= amount


func spend_resource(resource_id: StringName, amount: int) -> bool:
	if not can_spend_resource(resource_id, amount):
		return false
	var entry: Dictionary = resources[resource_id]
	entry["current"] = clampi(entry.get("current", 0) - amount, 0, entry.get("max", 0))
	resources[resource_id] = entry
	return true


func gain_resource(resource_id: StringName, amount: int) -> int:
	if amount <= 0 or not has_resource(resource_id):
		return 0
	var entry: Dictionary = resources[resource_id]
	var before: int = entry.get("current", 0)
	entry["current"] = clampi(before + amount, 0, entry.get("max", 0))
	resources[resource_id] = entry
	return entry["current"] - before


func is_alive() -> bool:
	return health > 0


func preferred_row() -> int:
	return BACK_ROW if unit_class == CLASS_ASSASSIN else FRONT_ROW


func class_name_zh() -> String:
	match unit_class:
		CLASS_TANK:
			return "肉盾"
		CLASS_WARRIOR:
			return "战士"
		CLASS_ARCHER:
			return "射手"
		CLASS_ASSASSIN:
			return "刺客"
	return "单位"
