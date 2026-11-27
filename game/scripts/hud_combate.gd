extends Control
## HUD de combate (dibujado a mano, sin imagenes, estetica propia): vida y escudo abajo a la izquierda, arma y municion abajo
## a la derecha, utilidades, barra de carga (arco, puño-bot) y de calor (sable), aviso "E para recoger", marcas de pintura,
## kill feed, indicador de la direccion del dano y destello de ceguera. Se alimenta con `poner()` cada frame.

const DURACION_GOLPE: float = 1.4
const DURACION_BAJA: float = 5.0
const MAX_BAJAS: int = 5

var d: Dictionary = {}
var marcas: Array[Dictionary] = []  # {pos: Vector2, texto: String}
var ceguera: float = 0.0
var _golpes: Array[Dictionary] = []  # {ang: float (rad, 0 = delante), t: float}
var _bajas: Array[Dictionary] = []  # {texto: String, t: float, propia: bool}


func poner(datos: Dictionary) -> void:
	d = datos
	queue_redraw()


func poner_marcas(lista: Array[Dictionary], ceg: float) -> void:
	marcas = lista
	ceguera = ceg


## Un golpe recibido desde `angulo` (radianes respecto a la mirada: 0 = delante, + = derecha).
func anadir_golpe(angulo: float) -> void:
	_golpes.append({"ang": angulo, "t": DURACION_GOLPE})


func anadir_baja(atacante: String, arma: String, victima: String, propia: bool) -> void:
	_bajas.push_front({"texto": "%s  [%s]  %s" % [atacante, arma, victima] if arma != "" else "%s  >  %s" % [atacante, victima],
			"t": DURACION_BAJA, "propia": propia})
	if _bajas.size() > MAX_BAJAS:
		_bajas.pop_back()


func n_bajas() -> int:
	return _bajas.size()


func n_golpes() -> int:
	return _golpes.size()


func _process(delta: float) -> void:
	for i in range(_golpes.size() - 1, -1, -1):
		_golpes[i]["t"] = float(_golpes[i]["t"]) - delta
		if float(_golpes[i]["t"]) <= 0.0:
			_golpes.remove_at(i)
	for i in range(_bajas.size() - 1, -1, -1):
		_bajas[i]["t"] = float(_bajas[i]["t"]) - delta
		if float(_bajas[i]["t"]) <= 0.0:
			_bajas.remove_at(i)
	if not _golpes.is_empty() or not _bajas.is_empty():
		queue_redraw()


func _draw() -> void:
	if d.is_empty():
		return
	var f: Font = ThemeDB.fallback_font
	var h: float = size.y
	var w: float = size.x
	var vida: float = d["vida"]
	var vmax: float = d["vida_max"]
	var escudo: float = d["escudo"]
	# --- vida y escudo (abajo izquierda)
	var x0: float = 28.0
	var y0: float = h - 90.0
	var col_vida: Color = Color(0.9, 0.2, 0.2) if vida > 25.0 else Color(1.0, 0.1, 0.05)
	_texto(f, Vector2(x0, y0 + 34.0), str(ceili(vida)), 48, col_vida)
	_texto(f, Vector2(x0 + 100.0, y0 + 34.0), "VIDA", 16, Color(1, 1, 1, 0.75))
	_barra(Vector2(x0, y0 + 44.0), Vector2(190.0, 8.0), vida / vmax, col_vida)
	_texto(f, Vector2(x0 + 218.0, y0 + 34.0), str(ceili(escudo)), 48, Color(0.35, 0.65, 1.0))
	_texto(f, Vector2(x0 + 318.0, y0 + 34.0), "ESCUDO", 16, Color(1, 1, 1, 0.75))
	_barra(Vector2(x0 + 218.0, y0 + 44.0), Vector2(190.0, 8.0), escudo / 50.0, Color(0.35, 0.65, 1.0))
	# --- arma y municion (abajo derecha)
	var xr: float = w - 28.0
	var anc: float = f.get_string_size(str(d["arma"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
	_texto(f, Vector2(xr - anc, h - 78.0), str(d["arma"]), 22, Color(1, 1, 1, 0.9))
	if bool(d["infinita"]):
		_texto(f, Vector2(xr - 40.0, h - 30.0), "--", 48, Color(1, 1, 1))
	else:
		var s_res: String = "/ %d" % int(d["reserva"])
		var a_res: float = f.get_string_size(s_res, HORIZONTAL_ALIGNMENT_LEFT, -1, 26).x
		if not bool(d["utilidad"]):
			_texto(f, Vector2(xr - a_res, h - 30.0), s_res, 26, Color(1, 1, 1, 0.7))
		else:
			a_res = 0.0
		var s_car: String = str(int(d["cargador"]))
		var a_car: float = f.get_string_size(s_car, HORIZONTAL_ALIGNMENT_LEFT, -1, 52).x
		var col_car: Color = Color(1, 1, 1) if int(d["cargador"]) > 0 else Color(1.0, 0.25, 0.2)
		_texto(f, Vector2(xr - a_res - (10.0 if a_res > 0.0 else 0.0) - a_car, h - 30.0), s_car, 52, col_car)
		if bool(d["recargando"]):
			_texto(f, Vector2(xr - 130.0, h - 108.0), "RECARGANDO", 18, Color(1.0, 0.85, 0.3))
	# --- utilidades (a la izquierda del arma)
	var ux: float = xr - 330.0
	for u: Dictionary in d["utilidades"]:
		var sel: bool = bool(u["seleccionada"])
		var r := Rect2(Vector2(ux, h - 70.0), Vector2(74.0, 44.0))
		draw_rect(r, Color(0, 0, 0, 0.55))
		draw_rect(r, Color(1.0, 0.85, 0.3, 0.95) if sel else Color(1, 1, 1, 0.25), false, 2.0 if sel else 1.0)
		_texto(f, r.position + Vector2(6.0, 18.0), _sigla(str(u["nombre"])), 15, Color(1, 1, 1, 0.95 if sel else 0.6))
		_texto(f, r.position + Vector2(6.0, 38.0), "x%d" % int(u["cantidad"]), 18, Color(0.7, 0.95, 1.0, 0.95 if sel else 0.6))
		ux -= 82.0
	# --- barra de carga (arco, puño-bot) bajo la mira
	var cx: float = w * 0.5
	var carga: float = float(d["carga"])
	if carga >= 0.0:
		_barra(Vector2(cx - 70.0, h * 0.5 + 60.0), Vector2(140.0, 7.0), carga, Color(1.0, 0.85, 0.3) if carga < 1.0 else Color(0.5, 1.0, 0.5))
		_centrado(f, Vector2(cx, h * 0.5 + 54.0), str(d["etiqueta_carga"]), 13, Color(1, 1, 1, 0.8))
	# --- calor del sable
	var calor: float = float(d["calor"])
	if calor >= 0.0:
		var sobre: bool = bool(d["sobrecalentado"])
		var col_c: Color = Color(1.0, 0.25, 0.1) if (sobre or calor > 70.0) else Color(0.3, 0.85, 1.0)
		_barra(Vector2(cx - 80.0, h * 0.5 + 60.0), Vector2(160.0, 7.0), calor / 100.0, col_c)
		_centrado(f, Vector2(cx, h * 0.5 + 54.0), "SOBRECALENTADO" if sobre else "CALOR", 13, col_c)
	# --- aviso de recoger
	var aviso: String = str(d["prompt"])
	if aviso != "":
		_centrado(f, Vector2(cx, h * 0.5 + 110.0), aviso, 22, Color(0.75, 0.95, 1.0))
	# --- marcas de pintura (visibles a traves de paredes)
	for m: Dictionary in marcas:
		var p: Vector2 = m["pos"]
		var rombo: PackedVector2Array = PackedVector2Array([p + Vector2(0, -12), p + Vector2(10, 0), p + Vector2(0, 12), p + Vector2(-10, 0)])
		draw_colored_polygon(rombo, Color(0.95, 0.15, 0.55, 0.35))
		draw_polyline(PackedVector2Array([rombo[0], rombo[1], rombo[2], rombo[3], rombo[0]]), Color(1.0, 0.3, 0.7), 2.0)
		_centrado(f, p + Vector2(0, -18), str(m["texto"]), 13, Color(1.0, 0.6, 0.85))
	# --- indicador de la direccion del dano
	var c: Vector2 = size * 0.5
	for g: Dictionary in _golpes:
		var k: float = clampf(float(g["t"]) / DURACION_GOLPE, 0.0, 1.0)
		var a: float = float(g["ang"]) - PI * 0.5  # 0 rad = arriba en pantalla
		draw_arc(c, 110.0, a - 0.35, a + 0.35, 14, Color(1.0, 0.1, 0.05, 0.85 * k), 10.0)
	# --- kill feed (arriba a la derecha)
	var y: float = 34.0
	for b: Dictionary in _bajas:
		var k2: float = clampf(float(b["t"]) / 1.0, 0.0, 1.0)
		var s: String = str(b["texto"])
		var ancho: float = f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x
		draw_rect(Rect2(w - ancho - 36.0, y - 18.0, ancho + 16.0, 24.0), Color(0, 0, 0, 0.5 * k2))
		if bool(b["propia"]):
			draw_rect(Rect2(w - ancho - 36.0, y - 18.0, ancho + 16.0, 24.0), Color(1.0, 0.8, 0.2, 0.9 * k2), false, 1.5)
		_texto(f, Vector2(w - ancho - 28.0, y), s, 17, Color(1, 1, 1, k2))
		y += 28.0
	# --- ceguera: destello blanco
	if ceguera > 0.0:
		draw_rect(Rect2(Vector2.ZERO, size), Color(1.0, 1.0, 0.97, clampf(ceguera, 0.0, 1.0) * 0.97))


func _sigla(nombre: String) -> String:
	var n: String = nombre.replace("Granada de ", "").replace("Granada ", "")
	return n.substr(0, 9)


func _texto(f: Font, pos: Vector2, s: String, tam: int, col: Color) -> void:
	draw_string_outline(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, tam, 6, Color(0, 0, 0, 0.8 * col.a))
	draw_string(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, tam, col)


func _centrado(f: Font, pos: Vector2, s: String, tam: int, col: Color) -> void:
	var ancho: float = f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, tam).x
	_texto(f, pos - Vector2(ancho * 0.5, 0.0), s, tam, col)


func _barra(pos: Vector2, tam: Vector2, frac: float, col: Color) -> void:
	draw_rect(Rect2(pos - Vector2(2, 2), tam + Vector2(4, 4)), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(pos, tam), Color(1, 1, 1, 0.12))
	draw_rect(Rect2(pos, Vector2(tam.x * clampf(frac, 0.0, 1.0), tam.y)), col)
