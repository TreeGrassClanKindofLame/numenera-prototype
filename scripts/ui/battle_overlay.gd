extends Control

const SquadUnitStateType = preload("res://scripts/model/squad_unit_state.gd")

const STAGE_RECT := Rect2(32.0, 28.0, 1136.0, 664.0)
const FIELD_RECT := Rect2(62.0, 102.0, 802.0, 520.0)
const QUEUE_RECT := Rect2(888.0, 102.0, 250.0, 520.0)
const CARD_SIZE := Vector2(156.0, 98.0)
const COLUMN_GAP := 30.0
const ROW_GAP := 12.0
const PLAYER_ROW_Y := [444.0, 554.0]
const ENEMY_ROW_Y := [304.0, 194.0]

var snapshot: Dictionary = {}
var encounter: Dictionary = {}
var context: Dictionary = {}
var schedule: Array = []
var current_schedule_index := -1
var attacker_squad_id: StringName = &""
var attacker_unit_id: StringName = &""
var defender_squad_id: StringName = &""
var defender_unit_id: StringName = &""
var bottom_squad_id: StringName = &""
var top_squad_id: StringName = &""
var headline := ""
var detail_text := ""
var engagement_text := ""
var result_text := ""
var mode: StringName = &"hidden"
var slow_motion := false
var attack_progress := 0.0
var damage_progress := 0.0
var impact_flash := 0.0
var target_died := false
var active_event: Dictionary = {}
var _audio_players: Dictionary = {}


func setup() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_audio_players()
	hide()


func begin_encounter(p_encounter: Dictionary, p_context: Dictionary, p_slow_motion: bool) -> void:
	encounter = p_encounter
	context = p_context
	slow_motion = p_slow_motion
	snapshot = encounter.get("formations_before", {}).duplicate(true)
	schedule = encounter.get("turn_schedule", []).duplicate(true)
	current_schedule_index = -1
	active_event.clear()
	_reset_action_visuals()
	_assign_sides()
	headline = _context_title()
	engagement_text = _engagement_summary()
	detail_text = "准备自动战斗"
	result_text = ""
	mode = &"battle"
	show()
	queue_redraw()


func preview_action(schedule_entry: Dictionary, event: Dictionary) -> void:
	current_schedule_index = schedule_entry.get("schedule_index", -1)
	active_event = event
	snapshot = event.get("formations_before", snapshot).duplicate(true)
	attacker_squad_id = event.get("attacker_squad_id", &"")
	attacker_unit_id = event.get("attacker_unit_id", &"")
	defender_squad_id = event.get("defender_squad_id", &"")
	defender_unit_id = event.get("defender_unit_id", &"")
	attack_progress = 0.0
	damage_progress = 0.0
	impact_flash = 0.0
	target_died = event.get("target_died", false)
	var phase_text := "第零回合" if event.get("phase", &"round_one") == &"round_zero" else "第一回合"
	var action_name := "连击" if event.get("action_kind", &"normal_attack") == &"combo_attack" else "普通攻击"
	if event.get("passive_ids", []).has(&"bloodied"):
		action_name += "＋浴血"
	var action_text: String = _target_reason_text(event) if slow_motion else "%s 准备攻击 %s" % [
		_unit_display_name(attacker_squad_id, attacker_unit_id),
		_unit_display_name(defender_squad_id, defender_unit_id),
	]
	detail_text = "%s｜%s｜%s" % [phase_text, action_name, action_text]
	mode = &"battle"
	queue_redraw()


func set_attack_progress(value: float) -> void:
	attack_progress = clampf(value, 0.0, 1.0)
	queue_redraw()


func set_impact_flash(value: float) -> void:
	impact_flash = clampf(value, 0.0, 1.0)
	queue_redraw()


func set_damage_progress(value: float) -> void:
	damage_progress = clampf(value, 0.0, 1.0)
	queue_redraw()


func commit_action(event: Dictionary) -> void:
	snapshot = event.get("formations_after", snapshot).duplicate(true)
	attack_progress = 0.0
	damage_progress = 1.0
	impact_flash = 0.0
	var damage_text := "%d" % event.get("damage", 0)
	if event.get("damage_bonus", 0) > 0:
		damage_text += "（基础%d＋浴血%d）" % [
			event.get("base_damage", 0), event.get("damage_bonus", 0)
		]
	var resource_text := ""
	if event.get("resource_id", &"") != &"":
		resource_text = "｜TP %d→%d" % [
			event.get("resource_before", 0), event.get("resource_after", 0)
		]
	detail_text = "%s 造成 %s 点伤害%s%s" % [
		_unit_display_name(event.get("attacker_squad_id", &""), event.get("attacker_unit_id", &"")),
		damage_text,
		"，目标阵亡" if event.get("target_died", false) else "",
		resource_text,
	]
	queue_redraw()


func show_skipped_action(schedule_entry: Dictionary) -> void:
	current_schedule_index = schedule_entry.get("schedule_index", -1)
	active_event.clear()
	_reset_action_visuals()
	var phase_text := "第零回合" if schedule_entry.get("phase", &"round_one") == &"round_zero" else "第一回合"
	detail_text = "%s｜%s：%s" % [
		phase_text,
		_unit_display_name(schedule_entry.get("squad_id", &""), schedule_entry.get("unit_id", &"")),
		_skip_reason_text(schedule_entry.get("skipped_reason", &"")),
	]
	queue_redraw()


func show_skipped_encounter(p_encounter: Dictionary, p_context: Dictionary) -> void:
	begin_encounter(p_encounter, p_context, slow_motion)
	mode = &"skipped"
	detail_text = "该小队已全灭，本场跳过"
	queue_redraw()


func show_result(p_encounter: Dictionary) -> void:
	encounter = p_encounter
	snapshot = encounter.get("formations_after", snapshot).duplicate(true)
	current_schedule_index = schedule.size()
	active_event.clear()
	_reset_action_visuals()
	mode = &"result"
	var first_id: StringName = encounter.get("first_squad_id", &"")
	var second_id: StringName = encounter.get("second_squad_id", &"")
	var first_before: int = encounter.get("first_alive_before", 0)
	var second_before: int = encounter.get("second_alive_before", 0)
	var first_after: int = encounter.get("first_alive_after", 0)
	var second_after: int = encounter.get("second_alive_after", 0)
	var verdict := "双方仍有战力"
	if first_after <= 0 and second_after <= 0:
		verdict = "双方全灭"
	elif first_after <= 0:
		verdict = "%s 胜利" % _squad_display_name(second_id)
	elif second_after <= 0:
		verdict = "%s 胜利" % _squad_display_name(first_id)
	result_text = "%s　｜　%s 阵亡 %d，剩余 %d　｜　%s 阵亡 %d，剩余 %d" % [
		verdict,
		_squad_display_name(first_id), first_before - first_after, first_after,
		_squad_display_name(second_id), second_before - second_after, second_after,
	]
	detail_text = "战斗结束"
	queue_redraw()


func end_encounter() -> void:
	hide()
	mode = &"hidden"
	snapshot.clear()
	encounter.clear()
	schedule.clear()
	active_event.clear()
	queue_redraw()


func play_audio_cue(cue: StringName) -> void:
	if _audio_players.has(cue):
		_audio_players[cue].play()


func _draw() -> void:
	if mode == &"hidden" or snapshot.is_empty():
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.01, 0.015, 0.025, 0.82), true)
	draw_rect(STAGE_RECT, Color(0.035, 0.055, 0.085, 0.985), true)
	draw_rect(STAGE_RECT, Color("8ea4c4"), false, 2.0)
	draw_rect(FIELD_RECT, Color("111d2c"), true)
	draw_rect(FIELD_RECT, Color("344b68"), false, 2.0)
	draw_rect(QUEUE_RECT, Color("121b28"), true)
	draw_rect(QUEUE_RECT, Color("344b68"), false, 2.0)
	draw_string(ThemeDB.fallback_font, Vector2(58.0, 69.0), headline, HORIZONTAL_ALIGNMENT_LEFT, 780.0, 22, Color.WHITE)
	draw_string(ThemeDB.fallback_font, Vector2(58.0, 94.0), detail_text, HORIZONTAL_ALIGNMENT_LEFT, 780.0, 14, Color("dbe7f7"))
	draw_string(ThemeDB.fallback_font, Vector2(88.0, 124.0), engagement_text, HORIZONTAL_ALIGNMENT_LEFT, 740.0, 13, Color("ffe38a"))
	draw_string(ThemeDB.fallback_font, Vector2(910.0, 134.0), "行动队列", HORIZONTAL_ALIGNMENT_LEFT, 200.0, 20, Color.WHITE)

	_draw_formation(top_squad_id, false)
	_draw_formation(bottom_squad_id, true)
	_draw_attack_connection()
	_draw_action_queue()
	if mode == &"result":
		_draw_result_banner()
	elif mode == &"skipped":
		_draw_skip_banner()


func _draw_formation(squad_id: StringName, is_bottom: bool) -> void:
	if squad_id == &"" or not snapshot.has(squad_id):
		return
	var label_y := 466.0 if is_bottom else 142.0
	draw_string(
		ThemeDB.fallback_font,
		Vector2(88.0, label_y),
		_squad_display_name(squad_id),
		HORIZONTAL_ALIGNMENT_LEFT,
		300.0,
		18,
		Color("6db4ff") if _controller_for(squad_id) == &"player" else Color("ffad68")
	)
	var by_slot: Dictionary = {}
	for unit: Dictionary in snapshot[squad_id]:
		by_slot[unit["slot"]] = unit
	for row in 2:
		for column in 3:
			var slot := Vector2i(column, row)
			var rect := _slot_rect(slot, is_bottom)
			if by_slot.has(slot):
				_draw_unit_card(squad_id, by_slot[slot], rect)
			else:
				draw_rect(rect, Color("172638"), true)
				draw_rect(rect, Color("30455f"), false, 1.0)
				draw_string(ThemeDB.fallback_font, rect.position + Vector2(0.0, 54.0), "空", HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 13, Color("58697d"))


func _draw_unit_card(squad_id: StringName, unit: Dictionary, rect: Rect2) -> void:
	var alive: bool = unit.get("alive", false)
	var unit_id: StringName = unit.get("unit_id", &"")
	var is_attacker: bool = squad_id == attacker_squad_id and unit_id == attacker_unit_id
	var is_defender: bool = squad_id == defender_squad_id and unit_id == defender_unit_id
	var card_rect := rect
	if is_attacker and attack_progress > 0.0:
		var target_center := _unit_center(defender_squad_id, defender_unit_id)
		var direction := (target_center - rect.get_center()).normalized()
		card_rect.position += direction * sin(attack_progress * PI) * 18.0
	if not alive:
		card_rect = card_rect.grow(-8.0)
	var color := _class_color(unit.get("unit_class", &""))
	if not alive:
		color = Color("3f4650")
	elif is_defender and impact_flash > 0.0:
		color = color.lerp(Color("ff4f55"), impact_flash)
	if is_defender and impact_flash > 0.0:
		card_rect.position.x += sin(impact_flash * PI * 6.0) * 4.0
	draw_rect(card_rect, color, true)
	draw_rect(card_rect, Color("ffdf75") if is_attacker else Color("ff6570") if is_defender else Color("71859e"), false, 4.0 if is_attacker or is_defender else 1.0)
	var class_label: String = "木桩" if squad_id == &"dummy" and unit.get("unit_class", &"") == SquadUnitStateType.CLASS_CUSTOM else _class_short(unit.get("unit_class", &""))
	draw_string(ThemeDB.fallback_font, card_rect.position + Vector2(8.0, 24.0), class_label, HORIZONTAL_ALIGNMENT_LEFT, card_rect.size.x - 16.0, 17, Color.WHITE)
	draw_string(ThemeDB.fallback_font, card_rect.position + Vector2(8.0, 45.0), "攻%d　速%d" % [unit.get("attack", 0), unit.get("speed", 0)], HORIZONTAL_ALIGNMENT_LEFT, card_rect.size.x - 16.0, 12, Color("e1e9f3"))
	var health_value: float = unit.get("health", 0)
	if is_defender and not active_event.is_empty() and damage_progress < 1.0:
		health_value = lerpf(active_event.get("health_before", health_value), active_event.get("health_after", health_value), damage_progress)
	var max_health: float = maxf(unit.get("max_health", 1), 1.0)
	var health_ratio := clampf(health_value / max_health, 0.0, 1.0)
	var resources: Dictionary = unit.get("resources", {})
	var has_resource := resources.has(SquadUnitStateType.RESOURCE_TP) or resources.has(SquadUnitStateType.RESOURCE_MP)
	var bar_rect := Rect2(card_rect.position + Vector2(8.0, 56.0), Vector2(card_rect.size.x - 16.0, 9.0 if has_resource else 12.0))
	draw_rect(bar_rect, Color("281d25"), true)
	draw_rect(Rect2(bar_rect.position, Vector2(bar_rect.size.x * health_ratio, bar_rect.size.y)), Color("55c97a") if health_ratio > 0.35 else Color("e05b5b"), true)
	if has_resource:
		draw_string(ThemeDB.fallback_font, card_rect.position + Vector2(8.0, 76.0), "HP %d/%d" % [maxi(roundi(health_value), 0), roundi(max_health)], HORIZONTAL_ALIGNMENT_LEFT, 62.0, 11, Color.WHITE)
		var resource_id: StringName = SquadUnitStateType.RESOURCE_TP if resources.has(SquadUnitStateType.RESOURCE_TP) else SquadUnitStateType.RESOURCE_MP
		var resource: Dictionary = resources[resource_id]
		var resource_max: float = maxf(resource.get("max", 1), 1.0)
		var resource_value: float = resource.get("current", 0)
		var resource_rect := Rect2(card_rect.position + Vector2(8.0, 80.0), Vector2(card_rect.size.x - 16.0, 7.0))
		draw_rect(resource_rect, Color("192331"), true)
		draw_rect(
			Rect2(resource_rect.position, Vector2(resource_rect.size.x * clampf(resource_value / resource_max, 0.0, 1.0), resource_rect.size.y)),
			Color("e4a64f") if resource_id == SquadUnitStateType.RESOURCE_TP else Color("558ee6"),
			true
		)
		draw_string(ThemeDB.fallback_font, card_rect.position + Vector2(76.0, 76.0), "%s %d/%d" % [String(resource_id).to_upper(), roundi(resource_value), roundi(resource_max)], HORIZONTAL_ALIGNMENT_RIGHT, card_rect.size.x - 84.0, 11, Color.WHITE)
	else:
		draw_string(ThemeDB.fallback_font, card_rect.position + Vector2(8.0, 88.0), "HP %d/%d" % [maxi(roundi(health_value), 0), roundi(max_health)], HORIZONTAL_ALIGNMENT_LEFT, card_rect.size.x - 16.0, 12, Color.WHITE)
	if not alive:
		draw_rect(card_rect, Color(0.05, 0.05, 0.06, 0.48), true)
		draw_string(ThemeDB.fallback_font, card_rect.position + Vector2(0.0, 57.0), "阵亡", HORIZONTAL_ALIGNMENT_CENTER, card_rect.size.x, 18, Color("ff8a8a"))
	if is_defender and not active_event.is_empty() and damage_progress > 0.0:
		var float_y := lerpf(card_rect.position.y + 12.0, card_rect.position.y - 18.0, damage_progress)
		draw_string(ThemeDB.fallback_font, Vector2(card_rect.end.x - 52.0, float_y), "-%d" % active_event.get("damage", 0), HORIZONTAL_ALIGNMENT_CENTER, 52.0, 20, Color("ffdc65"))


func _draw_attack_connection() -> void:
	if active_event.is_empty() or attacker_unit_id == &"" or defender_unit_id == &"":
		return
	var from := _unit_center(attacker_squad_id, attacker_unit_id)
	var to := _unit_center(defender_squad_id, defender_unit_id)
	if from == Vector2.ZERO or to == Vector2.ZERO:
		return
	var alpha := 0.35 + 0.65 * maxf(attack_progress, 0.25)
	draw_dashed_line(from, to, Color(1.0, 0.82, 0.32, alpha), 3.0, 9.0)
	var direction := (to - from).normalized()
	var side := direction.rotated(PI * 0.5)
	draw_colored_polygon(PackedVector2Array([to, to - direction * 16.0 + side * 7.0, to - direction * 16.0 - side * 7.0]), Color(1.0, 0.82, 0.32, alpha))


func _draw_action_queue() -> void:
	var y := 164.0
	const VISIBLE_ACTIONS := 9
	var first_visible := 0
	if schedule.size() > VISIBLE_ACTIONS:
		first_visible = clampi(current_schedule_index - int(VISIBLE_ACTIONS / 2), 0, schedule.size() - VISIBLE_ACTIONS)
	var last_visible := mini(first_visible + VISIBLE_ACTIONS, schedule.size())
	for index in range(first_visible, last_visible):
		var entry: Dictionary = schedule[index]
		var rect := Rect2(904.0, y, 218.0, 40.0)
		var state := &"pending"
		if index < current_schedule_index:
			state = entry.get("status", &"acted")
		elif index == current_schedule_index:
			state = &"current"
		var background := Color("1b2b3d")
		var text_color := Color("dce7f4")
		if state == &"current":
			background = Color("5c4d25")
			text_color = Color("ffe78d")
		elif state == &"acted":
			background = Color("17212e")
			text_color = Color("718196")
		elif state == &"skipped":
			background = Color("281d25")
			text_color = Color("cf7880")
		draw_rect(rect, background, true)
		draw_rect(rect, Color("3b516b"), false, 1.0)
		var prefix := "▶" if state == &"current" else "×" if state == &"skipped" else "✓" if state == &"acted" else "%d" % (index + 1)
		var phase_mark := "零" if entry.get("phase", &"round_one") == &"round_zero" else "一"
		var action_mark := "连" if entry.get("action_kind", &"normal_attack") == &"combo_attack" else "攻"
		var label := "%s[%s·%s] %s　速%d" % [prefix, phase_mark, action_mark, _unit_display_name(entry.get("squad_id", &""), entry.get("unit_id", &"")), entry.get("speed", 0)]
		draw_string(ThemeDB.fallback_font, rect.position + Vector2(8.0, 17.0), label, HORIZONTAL_ALIGNMENT_LEFT, 202.0, 12, text_color)
		if state == &"skipped":
			draw_string(ThemeDB.fallback_font, rect.position + Vector2(8.0, 34.0), _skip_reason_text(entry.get("skipped_reason", &"")), HORIZONTAL_ALIGNMENT_LEFT, 202.0, 10, text_color)
		y += 46.0


func _draw_result_banner() -> void:
	var rect := Rect2(104.0, 340.0, 718.0, 86.0)
	draw_rect(rect, Color(0.06, 0.09, 0.13, 0.97), true)
	draw_rect(rect, Color("f1ca64"), false, 3.0)
	draw_string(ThemeDB.fallback_font, rect.position + Vector2(0.0, 30.0), "战果", HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 24, Color("ffe38a"))
	draw_string(ThemeDB.fallback_font, rect.position + Vector2(18.0, 62.0), result_text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x - 36.0, 14, Color.WHITE)


func _draw_skip_banner() -> void:
	var rect := Rect2(176.0, 344.0, 574.0, 70.0)
	draw_rect(rect, Color(0.12, 0.08, 0.09, 0.97), true)
	draw_rect(rect, Color("bf6570"), false, 2.0)
	draw_string(ThemeDB.fallback_font, rect.position + Vector2(0.0, 43.0), detail_text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 20, Color("ffb4b9"))


func _assign_sides() -> void:
	var first_id: StringName = encounter.get("first_squad_id", &"")
	var second_id: StringName = encounter.get("second_squad_id", &"")
	var first_controller: StringName = encounter.get("first_controller", &"npc")
	var second_controller: StringName = encounter.get("second_controller", &"npc")
	if first_controller == &"player":
		bottom_squad_id = first_id
		top_squad_id = second_id
	elif second_controller == &"player":
		bottom_squad_id = second_id
		top_squad_id = first_id
	else:
		bottom_squad_id = first_id
		top_squad_id = second_id


func _slot_rect(slot: Vector2i, is_bottom: bool) -> Rect2:
	var total_width := CARD_SIZE.x * 3.0 + COLUMN_GAP * 2.0
	var start_x := FIELD_RECT.position.x + (FIELD_RECT.size.x - total_width) * 0.5
	var row_y: float = PLAYER_ROW_Y[slot.y] if is_bottom else ENEMY_ROW_Y[slot.y]
	return Rect2(Vector2(start_x + slot.x * (CARD_SIZE.x + COLUMN_GAP), row_y), CARD_SIZE)


func _unit_center(squad_id: StringName, unit_id: StringName) -> Vector2:
	if squad_id == &"" or not snapshot.has(squad_id):
		return Vector2.ZERO
	for unit: Dictionary in snapshot[squad_id]:
		if unit.get("unit_id", &"") == unit_id:
			return _slot_rect(unit["slot"], squad_id == bottom_squad_id).get_center()
	return Vector2.ZERO


func _context_title() -> String:
	return "第%d波　｜　同步冲突点 %d/%d　｜　乱战配对 %d/%d　｜　表现依次回放，逻辑同时结算" % [
		context.get("wave_index", 0) + 1,
		context.get("group_index", 0) + 1,
		maxi(context.get("group_count", 1), 1),
		context.get("pair_index", 0) + 1,
		maxi(context.get("pair_count", 1), 1),
	]


func _engagement_summary() -> String:
	var data: Dictionary = encounter.get("engagement", {})
	if data.is_empty():
		return "接敌方向：无"
	var first_contact: Dictionary = data.get("first_contact", {})
	var second_contact: Dictionary = data.get("second_contact", {})
	var first_id: StringName = encounter.get("first_squad_id", &"")
	var second_id: StringName = encounter.get("second_squad_id", &"")
	var advantage_parts: Array = []
	for spec: Array in [
		[first_id, "first", encounter.get("first_advantage", 0)],
		[second_id, "second", encounter.get("second_advantage", 0)],
	]:
		var total: int = spec[2]
		if total <= 0:
			continue
		var direction: int = data.get("%s_direction_advantage" % spec[1], total)
		var class_bonus: int = data.get("%s_class_advantage" % spec[1], 0)
		advantage_parts.append("%s 方向%d＋越战%d＝%d" % [
			_squad_display_name(spec[0]), direction, class_bonus, total
		])
	var verdict := "均无优势" if advantage_parts.is_empty() else "；".join(advantage_parts)
	return "接敌：%s %s%d vs %s %s%d → %s" % [
		_squad_display_name(first_id),
		_contact_side_text(first_contact.get("side", &"front")),
		first_contact.get("score", 2),
		_squad_display_name(second_id),
		_contact_side_text(second_contact.get("side", &"front")),
		second_contact.get("score", 2),
		verdict,
	]


func _contact_side_text(side: StringName) -> String:
	match side:
		&"front": return "正面"
		&"side": return "侧面"
		&"back": return "背面"
	return "未知"


func _target_reason_text(event: Dictionary) -> String:
	var preferred := "前排" if event.get("preferred_row", 0) == 0 else "后排"
	var selected := "前排" if event.get("selected_row", 0) == 0 else "后排"
	var parts := ["%s优先" % preferred]
	if event.get("used_fallback_row", false):
		parts.append("%s为空" % preferred)
		parts.append("转向%s" % selected)
	parts.append("正对列" if event.get("target_distance", 0) == 0 else "最近列")
	if event.get("used_random_tie", false):
		var candidates: Array = event.get("candidate_unit_ids", [])
		var candidate_names: Array = []
		for candidate_id: StringName in candidates:
			candidate_names.append(String(candidate_id))
		parts.append("等距随机：%s" % "/".join(candidate_names))
		parts.append("本次选择%s" % String(event.get("defender_unit_id", &"")))
	return " → ".join(parts)


func _controller_for(squad_id: StringName) -> StringName:
	if squad_id == encounter.get("first_squad_id", &""):
		return encounter.get("first_controller", &"npc")
	if squad_id == encounter.get("second_squad_id", &""):
		return encounter.get("second_controller", &"npc")
	return &"npc"


func _unit_display_name(squad_id: StringName, unit_id: StringName) -> String:
	var class_text := "单位"
	if snapshot.has(squad_id):
		for unit: Dictionary in snapshot[squad_id]:
			if unit.get("unit_id", &"") == unit_id:
				class_text = "木桩" if squad_id == &"dummy" and unit.get("unit_class", &"") == SquadUnitStateType.CLASS_CUSTOM else _class_short(unit.get("unit_class", &""))
				break
	return "%s/%s" % [_squad_display_name(squad_id), class_text]


func _squad_display_name(squad_id: StringName) -> String:
	match squad_id:
		&"player": return "主角小队"
		&"dummy": return "木桩小队"
		&"robot": return "机器人小队"
		&"bandit": return "强盗小队"
	return String(squad_id)


func _skip_reason_text(reason: StringName) -> String:
	match reason:
		&"actor_dead": return "阵亡，跳过行动"
		&"no_living_enemy": return "敌方已全灭，跳过行动"
		&"no_valid_target": return "没有有效目标，跳过行动"
	return "跳过行动"


func _reset_action_visuals() -> void:
	attacker_squad_id = &""
	attacker_unit_id = &""
	defender_squad_id = &""
	defender_unit_id = &""
	attack_progress = 0.0
	damage_progress = 0.0
	impact_flash = 0.0
	target_died = false


func _build_audio_players() -> void:
	var cue_specs := {
		&"attack": [520.0, 0.045, 0.20],
		&"hit": [145.0, 0.055, 0.28],
		&"death": [92.0, 0.13, 0.30],
		&"result": [660.0, 0.16, 0.20],
	}
	for cue: StringName in cue_specs:
		var spec: Array = cue_specs[cue]
		var player := AudioStreamPlayer.new()
		player.stream = _make_tone(spec[0], spec[1], spec[2])
		player.volume_db = -14.0
		_audio_players[cue] = player
		add_child(player)


func _make_tone(frequency: float, duration: float, amplitude: float) -> AudioStreamWAV:
	var mix_rate := 22050
	var sample_count := maxi(roundi(duration * mix_rate), 1)
	var data := PackedByteArray()
	data.resize(sample_count * 2)
	for index in sample_count:
		var t := float(index) / float(mix_rate)
		var envelope := 1.0 - float(index) / float(sample_count)
		var sample := roundi(sin(TAU * frequency * t) * envelope * amplitude * 32767.0)
		data.encode_s16(index * 2, sample)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = mix_rate
	stream.stereo = false
	stream.data = data
	return stream


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
