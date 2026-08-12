extends RefCounted

const CLASS_TANK := &"tank"
const CLASS_WARRIOR := &"warrior"
const CLASS_ARCHER := &"archer"
const CLASS_ASSASSIN := &"assassin"
const CLASS_CUSTOM := &"custom"

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


func _init(
	p_unit_id: StringName = &"",
	p_unit_class: StringName = CLASS_WARRIOR,
	p_slot: Vector2i = Vector2i.ZERO,
	p_health: int = 5,
	p_max_health: int = 5,
	p_attack: int = 2,
	p_speed: int = 2
) -> void:
	unit_id = p_unit_id
	unit_class = p_unit_class
	slot = p_slot
	health = p_health
	max_health = p_max_health
	attack = p_attack
	speed = p_speed


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


func clone():
	return get_script().new(
		unit_id,
		unit_class,
		slot,
		health,
		max_health,
		attack,
		speed
	)


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
