extends Control
## HUD de combate (dibujado a mano, sin imagenes): vida y armadura abajo a la izquierda,
## arma y municion abajo a la derecha. Se alimenta con `poner()`.

var vida: float = 100.0
var vida_max: float = 100.0
var armadura: float = 0.0
var arma: String = ""
var cargador: int = 0
var reserva: int = 0
var infinita: bool = false
var recargando: bool = false


func poner(v: float, vmax: float, arm: float, nombre: String, carg: int, res: int, inf: bool, recarga: bool) -> void:
	if v == vida and arm == armadura and nombre == arma and carg == cargador and res == reserva \
			and recarga == recargando:
		return
	vida = v
	vida_max = vmax
	armadura = arm
	arma = nombre
	cargador = carg
	reserva = res
	infinita = inf
	recargando = recarga
	queue_redraw()


func _draw() -> void:
	var f: Font = ThemeDB.fallback_font
	var h: float = size.y
	var w: float = size.x
	# --- vida y armadura (abajo izquierda)
	var x0: float = 28.0
	var y0: float = h - 90.0
	var col_vida: Color = Color(0.9, 0.2, 0.2) if vida > 25.0 else Color(1.0, 0.1, 0.05)
	_texto(f, Vector2(x0, y0 + 34.0), str(ceili(vida)), 48, col_vida)
	_texto(f, Vector2(x0 + 100.0, y0 + 34.0), "VIDA", 16, Color(1, 1, 1, 0.75))
	_barra(Vector2(x0, y0 + 44.0), Vector2(190.0, 8.0), vida / vida_max, col_vida)
	_texto(f, Vector2(x0 + 218.0, y0 + 34.0), str(ceili(armadura)), 48, Color(0.35, 0.65, 1.0))
	_texto(f, Vector2(x0 + 318.0, y0 + 34.0), "ARM", 16, Color(1, 1, 1, 0.75))
	_barra(Vector2(x0 + 218.0, y0 + 44.0), Vector2(190.0, 8.0), armadura / 100.0, Color(0.35, 0.65, 1.0))
	# --- arma y municion (abajo derecha)
	var xr: float = w - 28.0
	var txt_arma: String = arma
	var anc: float = f.get_string_size(txt_arma, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
	_texto(f, Vector2(xr - anc, h - 78.0), txt_arma, 22, Color(1, 1, 1, 0.9))
	if infinita:
		_texto(f, Vector2(xr - 40.0, h - 30.0), "--", 48, Color(1, 1, 1))
	else:
		var s_res: String = "/ %d" % reserva
		var a_res: float = f.get_string_size(s_res, HORIZONTAL_ALIGNMENT_LEFT, -1, 26).x
		_texto(f, Vector2(xr - a_res, h - 30.0), s_res, 26, Color(1, 1, 1, 0.7))
		var s_car: String = str(cargador)
		var a_car: float = f.get_string_size(s_car, HORIZONTAL_ALIGNMENT_LEFT, -1, 52).x
		var col_car: Color = Color(1, 1, 1) if cargador > 0 else Color(1.0, 0.25, 0.2)
		_texto(f, Vector2(xr - a_res - 10.0 - a_car, h - 30.0), s_car, 52, col_car)
		if recargando:
			_texto(f, Vector2(xr - 130.0, h - 108.0), "RECARGANDO", 18, Color(1.0, 0.85, 0.3))


func _texto(f: Font, pos: Vector2, s: String, tam: int, col: Color) -> void:
	draw_string_outline(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, tam, 6, Color(0, 0, 0, 0.8))
	draw_string(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, tam, col)


func _barra(pos: Vector2, tam: Vector2, frac: float, col: Color) -> void:
	draw_rect(Rect2(pos - Vector2(2, 2), tam + Vector2(4, 4)), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(pos, tam), Color(1, 1, 1, 0.12))
	draw_rect(Rect2(pos, Vector2(tam.x * clampf(frac, 0.0, 1.0), tam.y)), col)
