extends Node2D

var actor_color := Color.WHITE
var radius := 16.0
var health := 1
var max_health := 1
var attack := 0
var hit_flash := 0.0


func setup(
	p_color: Color,
	p_health: int,
	p_max_health: int,
	p_attack: int,
	p_radius: float = 16.0
) -> void:
	actor_color = p_color
	radius = p_radius
	set_stats(p_health, p_max_health, p_attack)


func set_stats(p_health: int, p_max_health: int, p_attack: int) -> void:
	health = p_health
	max_health = p_max_health
	attack = p_attack
	queue_redraw()


func set_health(p_health: int) -> void:
	health = p_health
	queue_redraw()


func set_hit_flash(amount: float) -> void:
	hit_flash = clampf(amount, 0.0, 1.0)
	queue_redraw()


func reset_visual_state() -> void:
	scale = Vector2.ONE
	modulate = Color.WHITE
	hit_flash = 0.0
	queue_redraw()


func _draw() -> void:
	var display_color := actor_color.lerp(Color("ff4f55"), hit_flash)
	draw_circle(Vector2.ZERO, radius, display_color)
	draw_circle(Vector2.ZERO, radius, Color(1.0, 1.0, 1.0, 0.9), false, 2.0, true)

	var stat_text := "HP%d/%d  ATK%d" % [maxi(health, 0), max_health, attack]
	draw_string(
		ThemeDB.fallback_font,
		Vector2(-45.0, -23.0),
		stat_text,
		HORIZONTAL_ALIGNMENT_CENTER,
		90.0,
		10,
		Color.WHITE
	)
