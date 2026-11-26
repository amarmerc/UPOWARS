extends Control
## Punto de mira: una cruz pequeña en el centro de la pantalla.


func _draw() -> void:
	var c: Vector2 = size * 0.5
	var col := Color(1, 1, 1, 0.9)
	var sombra := Color(0, 0, 0, 0.6)
	var trazos: Array[Array] = [
		[Vector2(-9, 0), Vector2(-3, 0)], [Vector2(3, 0), Vector2(9, 0)],
		[Vector2(0, -9), Vector2(0, -3)], [Vector2(0, 3), Vector2(0, 9)]]
	for t: Array in trazos:
		draw_line(c + (t[0] as Vector2), c + (t[1] as Vector2), sombra, 4.0)
		draw_line(c + (t[0] as Vector2), c + (t[1] as Vector2), col, 2.0)
