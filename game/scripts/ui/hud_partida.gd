class_name HudPartida
extends CanvasLayer
## HUD de la partida (se dibuja con una sola Control): marcador de rondas y equipos arriba, temporizador, dinero, aviso de la
## Cachimba (llevarla, montarla, montada, caida, alarma de incendios), resultado de la ronda y de la partida, tabla de puntuacion
## (Tab), minimapa de la zona (limite, sites, aliados), espectador al morir y recordatorio de la fase de compra. El killfeed y la
## vida / municion los dibuja el HUD de combate (hud.tscn). Solo LEE la `Partida`.

const COLOR_ATQ := Color(1.0, 0.55, 0.15)
const COLOR_DEF := Color(0.3, 0.65, 1.0)
const MM_TAM: float = 190.0
const MOTIVOS: Dictionary = {
	"apagada": "La Cachimba ha sido apagada",
	"alarma": "Suena la alarma de incendios: se desaloja la UPO",
	"defensores_eliminados": "Defensores eliminados",
	"atacantes_eliminados": "Atacantes eliminados",
	"tiempo": "Se ha acabado el tiempo",
	"eliminacion": "Equipo eliminado",
}

var partida: Partida
var jugador: Jugador
## Combatiente que se esta espectando (null = no se espectea).
var espectando: Node = null
var mostrar_tabla: bool = false
## Fuerza la tabla de puntuacion (capturas de pantalla).
var forzar_tabla: bool = false

var _lienzo: Control
var _mm_min: Vector2 = Vector2.ZERO
var _mm_k: float = 1.0
var _mm_off: Vector2 = Vector2.ZERO
var _poligono: PackedVector2Array = PackedVector2Array()
var _t_aviso: float = 0.0
var _aviso: String = ""


func _init() -> void:
	layer = 6
	var l := _Lienzo.new()
	l.hud = self
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	_lienzo = l


func vincular(partida_api: Partida, jugador_propio: Jugador) -> void:
	partida = partida_api
	jugador = jugador_propio
	partida.cachimba_montada.connect(func(s: String) -> void: avisar("¡CACHIMBA MONTADA EN EL SITE %s!" % s, 3.0))
	partida.ronda_iniciada.connect(func(n: int) -> void: avisar("RONDA %d" % n, 2.0))
	partida.lados_cambiados.connect(func() -> void: avisar("CAMBIO DE LADO", 3.0))
	_configurar_mapa()


func avisar(texto: String, segundos: float) -> void:
	_aviso = texto
	_t_aviso = segundos


func _configurar_mapa() -> void:
	_poligono = PackedVector2Array()
	if partida == null or partida.zona_activa == null:
		return
	var lim: Dictionary = partida.zona_activa.limites()
	var mn: Vector3 = lim["min"]
	var mx: Vector3 = lim["max"]
	_mm_min = Vector2(mn.x, mn.z)
	var tam: Vector2 = Vector2(mx.x - mn.x, mx.z - mn.z)
	_mm_k = MM_TAM / maxf(tam.x, tam.y)
	_mm_off = (Vector2(MM_TAM, MM_TAM) - tam * _mm_k) * 0.5
	_poligono = lim["poligono"]


func _process(delta: float) -> void:
	if _t_aviso > 0.0:
		_t_aviso -= delta
	mostrar_tabla = forzar_tabla or Input.is_action_pressed("marcador")
	_lienzo.queue_redraw()


func _mm(p: Vector3) -> Vector2:
	return Vector2(16.0, 96.0) + _mm_off + (Vector2(p.x, p.z) - _mm_min) * _mm_k


func _color_lado(lado: int) -> Color:
	return COLOR_ATQ if lado == Partida.EQ_ATACANTES else COLOR_DEF


static func tiempo(s: float) -> String:
	var t: int = maxi(ceili(s), 0)
	return "%d:%02d" % [t / 60, t % 60]


# ------------------------------------------------------------------ dibujo

class _Lienzo:
	extends Control
	var hud: HudPartida

	func _draw() -> void:
		hud._dibujar(self)


func _dibujar(c: Control) -> void:
	if partida == null or jugador == null:
		return
	var f: Font = ThemeDB.fallback_font
	var w: float = c.size.x
	var h: float = c.size.y
	if partida.cfg.es_libre():
		_t(c, f, Vector2(w * 0.5 - 60.0, 28.0), "MODO LIBRE", 20, Color(1, 1, 1, 0.85))
		_dibujar_tabla(c, f, w, h)
		return
	_dibujar_barra(c, f, w)
	_dibujar_dinero(c, f, h)
	_dibujar_cachimba(c, f, w, h)
	_dibujar_resultado(c, f, w, h)
	_dibujar_minimapa(c, f)
	_dibujar_espectador(c, f, w, h)
	if _t_aviso > 0.0 and (partida.fase == Partida.Fase.COMPRA or partida.fase == Partida.Fase.RONDA):
		_centrado(c, f, Vector2(w * 0.5, h * 0.3), _aviso, 34, Color(1, 1, 1, clampf(_t_aviso, 0.0, 1.0)))
	_dibujar_tabla(c, f, w, h)


func _dibujar_barra(c: Control, f: Font, w: float) -> void:
	var p: Partida = partida
	var cx: float = w * 0.5
	c.draw_rect(Rect2(cx - 290.0, 8.0, 580.0, 54.0), Color(0.04, 0.06, 0.1, 0.78))
	for g in 2:
		var col: Color = _color_lado(p.lado_grupo[g])
		var izq: bool = g == 0
		var x: float = cx - 280.0 if izq else cx + 280.0
		var nombre: String = p.nombre_grupo(g)
		var anc: float = f.get_string_size(nombre, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		_t(c, f, Vector2(x if izq else x - anc, 28.0), nombre, 16, col)
		_t(c, f, Vector2(x if izq else x - anc, 52.0), "ATACA" if p.lado_grupo[g] == Partida.EQ_ATACANTES else "DEFIENDE", 12, Color(1, 1, 1, 0.6))
		var pts: String = str(p.puntos[g])
		var ap: float = f.get_string_size(pts, HORIZONTAL_ALIGNMENT_LEFT, -1, 34).x
		_t(c, f, Vector2(cx - 96.0 - ap if izq else cx + 96.0, 46.0), pts, 34, col)
	# reloj
	var etiqueta: String = ""
	var reloj: float = p.t_fase
	var col_reloj: Color = Color(1, 1, 1)
	match p.fase:
		Partida.Fase.COMPRA:
			etiqueta = "COMPRA"
			col_reloj = EstiloUI.ORO
		Partida.Fase.RONDA:
			etiqueta = "RONDA %d" % p.ronda
			var cach: Cachimba = p.cachimba_nodo
			if cach != null and cach.estado != Cachimba.Estado.SIN_MONTAR and cach.estado != Cachimba.Estado.MONTANDO:
				reloj = cach.restante
				col_reloj = Color(1.0, 0.3, 0.2)
				etiqueta = "CACHIMBA"
		Partida.Fase.FIN_RONDA:
			etiqueta = "FIN DE RONDA"
		Partida.Fase.FIN_PARTIDA:
			etiqueta = "FIN DE PARTIDA"
			reloj = 0.0
	_centrado(c, f, Vector2(cx, 38.0), tiempo(reloj), 30, col_reloj)
	_centrado(c, f, Vector2(cx, 56.0), etiqueta, 12, Color(1, 1, 1, 0.7))
	var rg: int = p.cfg.rondas_ganar
	_centrado(c, f, Vector2(cx, 78.0), "Ronda %d · gana quien llegue a %d" % [p.ronda, rg], 12, Color(1, 1, 1, 0.55))
	if p.fase == Partida.Fase.COMPRA:
		_centrado(c, f, Vector2(cx, 104.0), "FASE DE COMPRA · B abre la tienda", 18, EstiloUI.ORO)


func _dibujar_dinero(c: Control, f: Font, h: float) -> void:
	var d: Partida.DatosJugador = partida.datos.get(jugador)
	if d == null:
		return
	_t(c, f, Vector2(28.0, h - 112.0), "$ %d" % d.dinero, 30, EstiloUI.ORO)
	if d.ingreso_ronda > 0 and partida.fase != Partida.Fase.RONDA:
		_t(c, f, Vector2(190.0, h - 112.0), "+%d" % d.ingreso_ronda, 20, EstiloUI.BUENO)


func _dibujar_cachimba(c: Control, f: Font, w: float, h: float) -> void:
	var p: Partida = partida
	var cach: Cachimba = p.cachimba_nodo
	if cach == null:
		return
	var cx: float = w * 0.5
	var lado: int = p.lado_de(jugador)
	var y: float = 130.0
	match cach.estado:
		Cachimba.Estado.MONTANDO:
			_barra(c, Vector2(cx - 110.0, h * 0.62), Vector2(220.0, 10.0), cach.progreso / Cachimba.T_MONTAR, COLOR_ATQ)
			_centrado(c, f, Vector2(cx, h * 0.62 - 8.0), "MONTANDO LA CACHIMBA", 15, Color(1, 1, 1))
		Cachimba.Estado.MONTADA, Cachimba.Estado.APAGANDO:
			c.draw_rect(Rect2(cx - 230.0, y - 26.0, 460.0, 38.0), Color(0.5, 0.05, 0.03, 0.8))
			_centrado(c, f, Vector2(cx, y), "CACHIMBA MONTADA EN EL SITE %s · %s" % [cach.site, tiempo(cach.restante)], 20, Color(1, 0.9, 0.8))
			if cach.estado == Cachimba.Estado.APAGANDO:
				_barra(c, Vector2(cx - 110.0, h * 0.62), Vector2(220.0, 10.0), cach.progreso / Cachimba.T_APAGAR, COLOR_DEF)
				_centrado(c, f, Vector2(cx, h * 0.62 - 8.0), "APAGANDO", 15, Color(1, 1, 1))
			elif lado == Partida.EQ_DEFENSORES and p.estaba_vivo(jugador):
				_centrado(c, f, Vector2(cx, h * 0.62), "Mantén E junto a la Cachimba para apagarla", 17, EstiloUI.ACENTO2)
		Cachimba.Estado.ALARMA:
			var ya: float = h * (0.2 if p.fase == Partida.Fase.FIN_RONDA or p.fase == Partida.Fase.FIN_PARTIDA else 0.4)
			c.draw_rect(Rect2(Vector2.ZERO, c.size), Color(1.0, 0.0, 0.0, 0.10 + 0.07 * sin(Time.get_ticks_msec() * 0.012)))
			c.draw_rect(Rect2(cx - 380.0, ya - 46.0, 760.0, 110.0), Color(0.5, 0.0, 0.0, 0.85))
			_centrado(c, f, Vector2(cx, ya), "ALARMA DE INCENDIOS", 44, Color(1.0, 0.9, 0.85))
			_centrado(c, f, Vector2(cx, ya + 40.0), "Se desaloja la UPO. Todos al exterior.", 24, Color(1.0, 0.85, 0.7))
		_:
			pass
	if p.fase != Partida.Fase.RONDA or not p.estaba_vivo(jugador):
		return
	if p.portador_cachimba() == jugador and cach.estado == Cachimba.Estado.SIN_MONTAR:
		_centrado(c, f, Vector2(cx, h * 0.62), "Llevas la Cachimba: ve a un site (A/B) y mantén E quieto", 17, COLOR_ATQ)
	elif p.cachimba_caida() != null and lado == Partida.EQ_ATACANTES:
		_centrado(c, f, Vector2(cx, h * 0.62), "La Cachimba está en el suelo: ve a recogerla", 17, COLOR_ATQ)


func _dibujar_resultado(c: Control, f: Font, w: float, h: float) -> void:
	var p: Partida = partida
	if p.fase != Partida.Fase.FIN_RONDA and p.fase != Partida.Fase.FIN_PARTIDA:
		return
	var g_propio: int = p.grupo_de(jugador)
	var gano: bool = g_propio == p.ultimo_ganador if g_propio >= 0 else false
	var titulo: String = ("RONDA GANADA" if gano else "RONDA PERDIDA") if g_propio >= 0 else "RONDA PARA %s" % p.nombre_grupo(p.ultimo_ganador)
	var col: Color = EstiloUI.BUENO if gano else EstiloUI.MALO
	var y: float = h * (0.55 if p.ultimo_motivo == "alarma" else 0.34)
	if p.fase == Partida.Fase.FIN_PARTIDA:
		var g: int = p.ganador_partida
		titulo = ("PARTIDA GANADA" if g == g_propio else "PARTIDA PERDIDA") if g_propio >= 0 else "GANA %s" % p.nombre_grupo(g)
		col = EstiloUI.BUENO if g == g_propio else EstiloUI.MALO
	c.draw_rect(Rect2(w * 0.5 - 380.0, y - 54.0, 760.0, 150.0), Color(0.03, 0.05, 0.09, 0.82))
	_centrado(c, f, Vector2(w * 0.5, y), titulo, 46, col)
	_centrado(c, f, Vector2(w * 0.5, y + 32.0), str(MOTIVOS.get(p.ultimo_motivo, "")), 20, Color(1, 1, 1, 0.9))
	_centrado(c, f, Vector2(w * 0.5, y + 64.0), "%s  %d - %d  %s" % [p.nombre_grupo(0), p.puntos[0], p.puntos[1], p.nombre_grupo(1)], 24, EstiloUI.ORO)
	if p.fase == Partida.Fase.FIN_PARTIDA:
		_centrado(c, f, Vector2(w * 0.5, y + 90.0), "Esc: volver al lobby", 16, Color(1, 1, 1, 0.7))


func _dibujar_minimapa(c: Control, f: Font) -> void:
	if _poligono.is_empty() or partida.zona_activa == null:
		return
	var o: Vector2 = Vector2(16.0, 96.0)
	c.draw_rect(Rect2(o, Vector2(MM_TAM, MM_TAM)), Color(0.03, 0.05, 0.08, 0.7))
	c.draw_rect(Rect2(o, Vector2(MM_TAM, MM_TAM)), Color(1, 1, 1, 0.25), false, 1.0)
	var pts := PackedVector2Array()
	for v: Vector2 in _poligono:
		pts.append(_mm(Vector3(v.x, 0.0, v.y)))
	pts.append(pts[0])
	c.draw_polyline(pts, Color(0.45, 0.86, 1.0, 0.9), 2.0)
	var zona: ZonaActiva = partida.zona_activa
	for s: String in zona.zona["sites"]:
		var pc: Vector2 = _mm(zona.centro_site(s))
		var r: float = float(zona.zona["sites"][s].get("radio", 8.0)) * _mm_k
		c.draw_arc(pc, maxf(r, 8.0), 0.0, TAU, 20, ZonaActiva.COLOR_SITE, 1.5)
		_t(c, f, pc + Vector2(-5.0, 6.0), s, 16, ZonaActiva.COLOR_SITE)
	for eq: String in ZonaActiva.EQUIPOS:
		for i in zona.n_spawns(eq):
			var sp: Vector2 = _mm(zona.punto_spawn(eq, i)["pos"])
			c.draw_rect(Rect2(sp - Vector2(2, 2), Vector2(4, 4)), ZonaActiva.COLORES_EQUIPO[eq] * Color(1, 1, 1, 0.5))
	# la Cachimba
	var cach: Cachimba = partida.cachimba_nodo
	if cach != null and cach.estado != Cachimba.Estado.SIN_MONTAR:
		var pc2: Vector2 = _mm(cach.global_position)
		c.draw_rect(Rect2(pc2 - Vector2(4, 4), Vector2(8, 8)), Color(1.0, 0.3, 0.1))
	var caida: Node3D = partida.cachimba_caida()
	if caida != null and partida.lado_de(jugador) == Partida.EQ_ATACANTES:
		c.draw_rect(Rect2(_mm(caida.global_position) - Vector2(4, 4), Vector2(8, 8)), Color(1.0, 0.8, 0.2))
	# aliados (y uno mismo)
	var mi_g: int = partida.grupo_de(jugador)
	for n: Node in partida.jugadores:
		if partida.grupo_de(n) != mi_g or not partida.estaba_vivo(n):
			continue
		var p3: Vector3 = (n as Node3D).global_position
		var pm: Vector2 = _mm(p3)
		if n == jugador:
			var fw: Vector3 = -jugador.global_transform.basis.z
			var dir: Vector2 = Vector2(fw.x, fw.z).normalized()
			var perp: Vector2 = Vector2(-dir.y, dir.x)
			c.draw_colored_polygon(PackedVector2Array([pm + dir * 8.0, pm - dir * 5.0 + perp * 5.0, pm - dir * 5.0 - perp * 5.0]), Color(1, 1, 1))
		else:
			c.draw_circle(pm, 4.0, _color_lado(partida.lado_de(n)))
			c.draw_arc(pm, 4.0, 0.0, TAU, 10, Color(0, 0, 0, 0.8), 1.0)


func _dibujar_espectador(c: Control, f: Font, w: float, h: float) -> void:
	if espectando == null or not is_instance_valid(espectando):
		return
	var nombre: String = partida.datos[espectando].nombre if partida.datos.has(espectando) else str(espectando.name)
	_centrado(c, f, Vector2(w * 0.5, h - 70.0), "ESPECTANDO: %s" % nombre, 24, Color(1, 1, 1))
	_centrado(c, f, Vector2(w * 0.5, h - 44.0), "Clic: cambiar de aliado", 15, Color(1, 1, 1, 0.7))


func _dibujar_tabla(c: Control, f: Font, w: float, h: float) -> void:
	if not mostrar_tabla:
		return
	var ancho: float = 760.0
	var x0: float = (w - ancho) * 0.5
	var filas: int = 0
	for g: Dictionary in partida.tabla():
		filas += (g["filas"] as Array).size() + 2
	var alto: float = 50.0 + filas * 26.0
	var y0: float = maxf((h - alto) * 0.5, 120.0)
	c.draw_rect(Rect2(x0, y0, ancho, alto), Color(0.03, 0.05, 0.09, 0.9))
	c.draw_rect(Rect2(x0, y0, ancho, alto), EstiloUI.ACENTO, false, 2.0)
	_t(c, f, Vector2(x0 + 16.0, y0 + 30.0), "MARCADOR", 22, EstiloUI.ACENTO)
	var y: float = y0 + 60.0
	var mi_g: int = partida.grupo_de(jugador)
	for g: Dictionary in partida.tabla():
		var col: Color = _color_lado(int(g["lado"]))
		_t(c, f, Vector2(x0 + 16.0, y), "%s · %d" % [g["nombre"], int(g["puntos"])], 18, col)
		_t(c, f, Vector2(x0 + 420.0, y), "Bajas", 14, Color(1, 1, 1, 0.6))
		_t(c, f, Vector2(x0 + 520.0, y), "Muertes", 14, Color(1, 1, 1, 0.6))
		_t(c, f, Vector2(x0 + 640.0, y), "Dinero", 14, Color(1, 1, 1, 0.6))
		y += 26.0
		for r: Dictionary in g["filas"]:
			var vivo: bool = bool(r["vivo"])
			var cc: Color = Color(1, 1, 1, 0.95 if vivo else 0.4)
			if r["nodo"] == jugador:
				c.draw_rect(Rect2(x0 + 8.0, y - 17.0, ancho - 16.0, 24.0), Color(1, 1, 1, 0.1))
			_t(c, f, Vector2(x0 + 30.0, y), str(r["nombre"]), 16, cc)
			_t(c, f, Vector2(x0 + 440.0, y), str(r["bajas"]), 16, cc)
			_t(c, f, Vector2(x0 + 550.0, y), str(r["muertes"]), 16, cc)
			var din: String = ("$ %d" % int(r["dinero"])) if (int(g["grupo"]) == mi_g and not partida.cfg.es_libre()) else "—"
			_t(c, f, Vector2(x0 + 640.0, y), din, 16, EstiloUI.ORO if vivo else Color(1, 1, 1, 0.4))
			y += 26.0
		y += 26.0


# ------------------------------------------------------------------ utilidades de dibujo

func _t(c: Control, f: Font, pos: Vector2, s: String, tam: int, col: Color) -> void:
	c.draw_string_outline(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, tam, 6, Color(0, 0, 0, 0.8 * col.a))
	c.draw_string(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, tam, col)


func _centrado(c: Control, f: Font, pos: Vector2, s: String, tam: int, col: Color) -> void:
	var ancho: float = f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, tam).x
	_t(c, f, pos - Vector2(ancho * 0.5, 0.0), s, tam, col)


func _barra(c: Control, pos: Vector2, tam: Vector2, frac: float, col: Color) -> void:
	c.draw_rect(Rect2(pos - Vector2(2, 2), tam + Vector2(4, 4)), Color(0, 0, 0, 0.6))
	c.draw_rect(Rect2(pos, tam), Color(1, 1, 1, 0.12))
	c.draw_rect(Rect2(pos, Vector2(tam.x * clampf(frac, 0.0, 1.0), tam.y)), col)
