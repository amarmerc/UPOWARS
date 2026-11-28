extends Control
## Punto de mira dinamico: cuatro trazos que se separan segun la dispersion (`apertura`, en pixeles)
## y hit marker (aspa) al acertar a una hitbox; rojo y mas grande si es a la cabeza.

const DURACION_HIT: float = 0.18

## Separacion (px) entre el centro y el inicio de cada trazo.
var apertura: float = 3.0
var _hit_t: float = 0.0
var _hit_cabeza: bool = false
var _hit_muerte: bool = false
## Mira de zoom (fusil de precision / tirador): reticula fina y vineta circular negra.
var zoom_activo: bool = false


func mostrar_hit(cabeza: bool, muerte: bool = false) -> void:
	_hit_t = DURACION_HIT
	_hit_cabeza = cabeza
	_hit_muerte = muerte
	queue_redraw()


func poner_zoom(valor: bool) -> void:
	if valor != zoom_activo:
		zoom_activo = valor
		queue_redraw()


func poner_apertura(px: float) -> void:
	if absf(px - apertura) > 0.05:
		apertura = px
		queue_redraw()


func _process(delta: float) -> void:
	if _hit_t > 0.0:
		_hit_t = maxf(_hit_t - delta, 0.0)
		queue_redraw()


func _draw() -> void:
	var c: Vector2 = size * 0.5
	if zoom_activo:
		_dibujar_mira_zoom(c)
		return
	var col := Color(1, 1, 1, 0.9)
	var sombra := Color(0, 0, 0, 0.6)
	var a: float = apertura
	var l: float = 7.0
	var trazos: Array[Array] = [
		[Vector2(-a - l, 0), Vector2(-a, 0)], [Vector2(a, 0), Vector2(a + l, 0)],
		[Vector2(0, -a - l), Vector2(0, -a)], [Vector2(0, a), Vector2(0, a + l)]]
	for t: Array in trazos:
		draw_line(c + (t[0] as Vector2), c + (t[1] as Vector2), sombra, 4.0)
		draw_line(c + (t[0] as Vector2), c + (t[1] as Vector2), col, 2.0)
	if _hit_t > 0.0:
		var k: float = _hit_t / DURACION_HIT
		var d0: float = 6.0
		var d1: float = 15.0 if _hit_cabeza else 11.0
		var hc: Color = Color(1.0, 0.2, 0.15, k + 0.2) if (_hit_cabeza or _hit_muerte) else Color(1, 1, 1, k + 0.2)
		var w: float = 3.5 if _hit_cabeza else 2.5
		for dir: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			draw_line(c + dir * d0, c + dir * d1, Color(0, 0, 0, 0.6 * k), w + 2.0)
			draw_line(c + dir * d0, c + dir * d1, hc, w)


func _dibujar_mira_zoom(c: Vector2) -> void:
	var r: float = size.y * 0.46
	# todo lo de fuera del circulo en negro (anillo gigante)
	draw_arc(c, r + size.length() * 0.5, 0.0, TAU, 96, Color(0, 0, 0, 1), size.length())
	draw_arc(c, r, 0.0, TAU, 96, Color(0.05, 0.05, 0.05, 1), 5.0)
	var fino := Color(0, 0, 0, 0.92)
	draw_line(c + Vector2(-r, 0), c + Vector2(-14, 0), fino, 2.0)
	draw_line(c + Vector2(14, 0), c + Vector2(r, 0), fino, 2.0)
	draw_line(c + Vector2(0, -r), c + Vector2(0, -14), fino, 2.0)
	draw_line(c + Vector2(0, 14), c + Vector2(0, r), fino, 3.5)
	draw_line(c + Vector2(-26, 0), c + Vector2(-8, 0), fino, 3.0)
	draw_line(c + Vector2(8, 0), c + Vector2(26, 0), fino, 3.0)
	draw_line(c + Vector2(0, -26), c + Vector2(0, -8), fino, 3.0)
	draw_circle(c, 1.6, Color(0.9, 0.1, 0.05))
	for k in range(1, 5):  # marcas de caida bajo el centro
		draw_line(c + Vector2(-6, 30 + 22 * k), c + Vector2(6, 30 + 22 * k), fino, 2.0)
