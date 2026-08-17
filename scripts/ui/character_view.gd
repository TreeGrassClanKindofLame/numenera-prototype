extends Node2D

var actor_color := Color.WHITE
var radius := 16.0
var health := 1
var max_health := 1
var attack := 0
var hit_flash := 0.0
var squad_size := 1
var facing := Vector2i.DOWN


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


func set_facing(p_facing: Vector2i) -> void:
	if p_facing in [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
		facing = p_facing
	queue_redraw()


func set_squad_stats(p_health: int, p_max_health: int, p_attack: int, p_squad_size: int) -> void:
	squad_size = p_squad_size
	set_stats(p_health, p_max_health, p_attack)


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
	var facing_direction := Vector2(facing).normalized()
	var facing_side := facing_direction.rotated(PI * 0.5)
	var arrow_tip := facing_direction * (radius + 8.0)
	var arrow_base := facing_direction * (radius - 2.0)
	draw_colored_polygon(PackedVector2Array([
		arrow_tip,
		arrow_base + facing_side * 5.0,
		arrow_base - facing_side * 5.0,
	]), Color("ffe38a"))

	var stat_text := "%d人  HP%d/%d" % [squad_size, maxi(health, 0), max_health]
	draw_string(
		ThemeDB.fallback_font,
		Vector2(-45.0, -23.0),
		stat_text,
		HORIZONTAL_ALIGNMENT_CENTER,
		90.0,
		10,
		Color.WHITE
	)
