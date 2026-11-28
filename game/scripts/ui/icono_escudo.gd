class_name IconoEscudo
extends Control
## Icono dibujado de un escudo (los escudos no tienen modelo en el viewmodel, asi que no hay PNG en assets/iconos).

var color: Color = Color(0.4, 0.75, 1.0)


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	var cx: float = w * 0.5
	var a: float = minf(w * 0.5, h) * 0.9
	var x0: float = cx - a * 0.42
	var x1: float = cx + a * 0.42
	var y0: float = (h - a) * 0.5
	var pts := PackedVector2Array([Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y0 + a * 0.55), Vector2(cx, y0 + a), Vector2(x0, y0 + a * 0.55)])
	draw_colored_polygon(pts, color.darkened(0.35))
	var dentro := PackedVector2Array()
	for p: Vector2 in pts:
		dentro.append(Vector2(cx, y0 + a * 0.45).lerp(p, 0.78))
	draw_colored_polygon(dentro, color)
	draw_polyline(pts + PackedVector2Array([pts[0]]), color.lightened(0.5), 2.0)
