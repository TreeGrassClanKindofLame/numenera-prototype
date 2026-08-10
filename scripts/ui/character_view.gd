extends Node2D

var actor_color := Color.WHITE
var radius := 16.0


func setup(p_color: Color, p_radius: float = 16.0) -> void:
	actor_color = p_color
	radius = p_radius
	queue_redraw()


func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, actor_color)
	draw_circle(Vector2.ZERO, radius, Color(1.0, 1.0, 1.0, 0.85), false, 2.0, true)
