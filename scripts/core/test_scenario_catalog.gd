extends RefCounted

const SCENARIO_DUMMY := &"dummy"
const SCENARIO_ROBOT := &"robot"
const SCENARIO_BANDIT := &"bandit"


static func scenario_ids() -> Array:
	return [SCENARIO_DUMMY, SCENARIO_ROBOT, SCENARIO_BANDIT]


static func definition(scenario_id: StringName) -> Dictionary:
	match scenario_id:
		SCENARIO_ROBOT:
			return {
				"id": SCENARIO_ROBOT,
				"display_name": "机器人测试",
				"enemy_id": &"robot",
				"enemy_behavior": &"robot",
				"enemy_facing": Vector2i.RIGHT,
				"map_rows": [
					"############",
					"#..........#",
					"#.....R....#",
					"#..........#",
					"#.P........#",
					"#..........#",
					"#..........#",
					"############",
				],
				"patrol_path": [
					Vector2i(6, 2), Vector2i(7, 2), Vector2i(8, 2),
					Vector2i(8, 3), Vector2i(8, 4), Vector2i(7, 4),
					Vector2i(6, 4), Vector2i(6, 3),
				],
				"facilities": [
					_facility(&"robot_medical", &"medical_station", Vector2i(2, 2)),
					_facility(&"robot_cannon", &"electromagnetic_cannon", Vector2i(6, 5), Vector2i.UP),
				],
			}
		SCENARIO_BANDIT:
			return {
				"id": SCENARIO_BANDIT,
				"display_name": "强盗测试",
				"enemy_id": &"bandit",
				"enemy_behavior": &"bandit",
				"enemy_facing": Vector2i.LEFT,
				"map_rows": [
					"############",
					"#..........#",
					"#..........#",
					"#......#...#",
					"#.P.....B..#",
					"#..........#",
					"#..........#",
					"############",
				],
				"patrol_path": [],
				"facilities": [
					_facility(&"bandit_medical", &"medical_station", Vector2i(2, 2)),
					_facility(&"bandit_cannon", &"electromagnetic_cannon", Vector2i(5, 3), Vector2i.RIGHT),
				],
			}
		_:
			return {
				"id": SCENARIO_DUMMY,
				"display_name": "木桩测试",
				"enemy_id": &"dummy",
				"enemy_behavior": &"dummy",
				"enemy_facing": Vector2i.DOWN,
				"map_rows": [
					"############",
					"#P...#.....#",
					"#..T.#.....#",
					"#....#.....#",
					"#..........#",
					"#..###.....#",
					"#..........#",
					"############",
				],
				"patrol_path": [],
				"facilities": [
					_facility(&"dummy_medical", &"medical_station", Vector2i(1, 5)),
					_facility(&"dummy_cannon", &"electromagnetic_cannon", Vector2i(3, 4), Vector2i.UP),
				],
			}


static func _facility(
	facility_id: StringName,
	type: StringName,
	cell: Vector2i,
	facing: Vector2i = Vector2i.ZERO
) -> Dictionary:
	return {
		"facility_id": facility_id,
		"type": type,
		"cell": cell,
		"facing": facing,
	}
