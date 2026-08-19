extends RefCounted

var final_positions: Dictionary = {}
var final_actor_states: Dictionary = {}
var initial_positions: Dictionary = {}
var movement_positions: Dictionary = {}
var movement_results: Dictionary = {}
var tentative_positions: Dictionary = {}
var outcomes: Dictionary = {}
var combat_events: Array = []
var enemy_events: Array = []
var grid_skill_events: Array = []
var facility_events: Array = []
var trap_events: Array = []
var final_map_effects: Dictionary = {}
var collision_groups: Array = []
var collision_waves: Array = []
var dead_actor_ids: Array = []
var collision_cycle_detected := false


func _init(p_initial_positions: Dictionary = {}) -> void:
	final_positions = p_initial_positions.duplicate(true)
	initial_positions = p_initial_positions.duplicate(true)
	final_actor_states = {}
	movement_positions = {}
	movement_results = {}
	tentative_positions = {}
	outcomes = {}
	combat_events = []
	enemy_events = []
	grid_skill_events = []
	facility_events = []
	trap_events = []
	final_map_effects = {}
	collision_groups = []
	collision_waves = []
	dead_actor_ids = []
	collision_cycle_detected = false


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


func actor_state_for(actor_id: StringName):
	return final_actor_states.get(actor_id)


func is_dead(actor_id: StringName) -> bool:
	return actor_id in dead_actor_ids
