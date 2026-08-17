extends RefCounted

const BEHAVIOR_DUMMY := &"dummy"
const BEHAVIOR_ROBOT := &"robot"
const BEHAVIOR_BANDIT := &"bandit"

var actor_id: StringName
var behavior: StringName
var alerted := false
var move_turn := true
var patrol_path: Array = []
var patrol_index := 0
var patrol_direction := 1
var has_pending_target := false
var pending_target := Vector2i.ZERO
var pending_path_index := -1


func _init(
	p_actor_id: StringName = &"",
	p_behavior: StringName = BEHAVIOR_DUMMY,
	p_patrol_path: Array = []
) -> void:
	actor_id = p_actor_id
	behavior = p_behavior
	patrol_path = p_patrol_path.duplicate()
	move_turn = true
	patrol_direction = 1


func clear_pending_target() -> void:
	has_pending_target = false
	pending_target = Vector2i.ZERO
	pending_path_index = -1
