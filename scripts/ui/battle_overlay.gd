extends Control

const SquadUnitStateType = preload("res://scripts/model/squad_unit_state.gd")

var snapshot: Dictionary = {}
var attacker_squad_id: StringName = &""
var attacker_unit_id: StringName = &""
var defender_squad_id: StringName = &""
var defender_unit_id: StringName = &""
var caption := ""


func setup() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hide()


func show_event(event: Dictionary, after_damage: bool = false) -> void:
	snapshot = event["formations_after"] if after_damage else event["formations_before"]
	attacker_squad_id = event["attacker_squad_id"]
	attacker_unit_id = event["attacker_unit_id"]
	defender_squad_id = event["defender_squad_id"]
	defender_unit_id = event["defender_unit_id"]
	caption = "%s/%s  攻击  %s/%s　伤害 %d" % [
		attacker_squad_id, attacker_unit_id,
		defender_squad_id, defender_unit_id,
		event["damage"],
	]
	show()
	queue_redraw()


func clear_event() -> void:
	hide()
	snapshot.clear()
	queue_redraw()


func _draw() -> void:
	if snapshot.is_empty():
		return
	var panel := Rect2(Vector2(86.0, 138.0), Vector2(448.0, 300.0))
	draw_rect(panel, Color(0.035, 0.055, 0.085, 0.96), true)
	draw_rect(panel, Color("8ea4c4"), false, 2.0)
	draw_string(ThemeDB.fallback_font, Vector2(110.0, 174.0), "小队自动战斗", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color.WHITE)
	draw_string(ThemeDB.fallback_font, Vector2(110.0, 204.0), caption, HORIZONTAL_ALIGNMENT_LEFT, 400.0, 14, Color("dbe7f7"))

	var squad_ids := snapshot.keys()
	squad_ids.sort()
	for squad_index in squad_ids.size():
		var squad_id: StringName = squad_ids[squad_index]
		var origin := Vector2(116.0 + squad_index * 218.0, 248.0)
		draw_string(ThemeDB.fallback_font, origin + Vector2(0.0, -16.0), String(squad_id), HORIZONTAL_ALIGNMENT_LEFT, 190.0, 16, Color.WHITE)
		for row in 2:
			for column in 3:
				var rect := Rect2(origin + Vector2(column * 62.0, row * 76.0), Vector2(56.0, 66.0))
				draw_rect(rect, Color("1b2a3e"), true)
				draw_rect(rect, Color("4d627d"), false, 1.0)
		for unit: Dictionary in snapshot[squad_id]:
			var slot: Vector2i = unit["slot"]
			var rect := Rect2(origin + Vector2(slot.x * 62.0, slot.y * 76.0), Vector2(56.0, 66.0))
			var color := _class_color(unit["unit_class"])
			if not unit["alive"]:
				color = Color("4b5059")
			draw_rect(rect.grow(-3.0), color, true)
			if squad_id == attacker_squad_id and unit["unit_id"] == attacker_unit_id:
				draw_rect(rect.grow(-1.0), Color("ffdb66"), false, 4.0)
			elif squad_id == defender_squad_id and unit["unit_id"] == defender_unit_id:
				draw_rect(rect.grow(-1.0), Color("ff5d68"), false, 4.0)
			draw_string(ThemeDB.fallback_font, rect.position + Vector2(3.0, 22.0), _class_short(unit["unit_class"]), HORIZONTAL_ALIGNMENT_CENTER, 50.0, 13, Color.WHITE)
			draw_string(ThemeDB.fallback_font, rect.position + Vector2(3.0, 45.0), "HP%d" % maxi(unit["health"], 0), HORIZONTAL_ALIGNMENT_CENTER, 50.0, 12, Color.WHITE)


func _class_short(unit_class: StringName) -> String:
	match unit_class:
		SquadUnitStateType.CLASS_TANK: return "肉盾"
		SquadUnitStateType.CLASS_WARRIOR: return "战士"
		SquadUnitStateType.CLASS_ARCHER: return "射手"
		SquadUnitStateType.CLASS_ASSASSIN: return "刺客"
	return "单位"


func _class_color(unit_class: StringName) -> Color:
	match unit_class:
		SquadUnitStateType.CLASS_TANK: return Color("55728e")
		SquadUnitStateType.CLASS_WARRIOR: return Color("b06b4f")
		SquadUnitStateType.CLASS_ARCHER: return Color("4d9b70")
		SquadUnitStateType.CLASS_ASSASSIN: return Color("7657a3")
	return Color("687386")
