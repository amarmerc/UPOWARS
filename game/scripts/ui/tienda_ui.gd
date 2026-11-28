class_name TiendaUI
extends CanvasLayer
## Tienda a pantalla completa estilo Valorant: una columna por categoria (Pequeñas | Grandes en dos columnas | Especiales | Escudos y
## utilidades), cada articulo en una tarjeta con su icono (PNG de res://assets/iconos, regenerables con tests/generar_iconos.gd),
## nombre y precio. Al pasar el raton sale un panel de detalle con las estadisticas en barras. Clic izquierdo compra, clic derecho
## devuelve (reembolso completo) lo comprado en esta fase. Las tarjetas que no llegan se atenuan; lo equipado y lo comprado se marca.
## Arriba: dinero y fase / tiempo. En competitivo se abre sola en la fase de compra y con B; en el modo libre (dinero infinito) se
## abre con Esc junto a "Reanudar / Volver al lobby / Salir del juego" (`configurar(true)`). Solo lee la Partida y compra por su API.

signal cerrada
signal reanudar
signal volver_lobby
signal salir_juego

const RUTA_ICONOS: String = "res://assets/iconos/%s.png"
## Columnas: titulo, peso de anchura, si los bloques van lado a lado y bloques {sub, cat | ids}.
const COLUMNAS: Array = [
	{"titulo": "PEQUEÑAS", "peso": 1.0, "lado": false, "bloques": [{"sub": "", "cat": "secundaria"}]},
	{"titulo": "GRANDES", "peso": 2.1, "lado": true, "bloques": [
		{"sub": "Subfusiles y escopetas", "ids": [&"subfusil_9mm", &"subfusil_45", &"escopeta_corredera", &"escopeta_auto"]},
		{"sub": "Fusiles, precisión y ametralladora", "ids": [&"carabina_556", &"fusil_asalto", &"fusil_combate", &"fusil_tirador", &"fusil_precision", &"ametralladora"]}]},
	{"titulo": "ESPECIALES", "peso": 1.0, "lado": false, "bloques": [{"sub": "", "cat": "especial"}]},
	{"titulo": "ESCUDOS Y UTILIDADES", "peso": 1.0, "lado": false, "bloques": [{"sub": "Escudos", "cat": "escudo"}, {"sub": "Utilidades", "cat": "utilidad"}]},
]
const TAM_TARJETA: Vector2 = Vector2(0, 58)
const ANCHO_DETALLE: float = 290.0

var partida: Partida
var jugador: Jugador
var modo_libre: bool = false
## id -> PanelContainer de la tarjeta (con el metadato "estado" actualizado en `refrescar`).
var tarjetas: Dictionary = {}

var _raiz: Control
var _dinero: Label
var _titulo: Label
var _fase: Label
var _equipo: Label
var _extra: HBoxContainer
var _detalle: PanelContainer
var _det_cont: VBoxContainer
var _hover: StringName = &""
var _maximos: Dictionary = {}
var _partes: Dictionary = {}   # id -> {precio: Label, marca: Label}


func _init() -> void:
	layer = 15
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	_construir()


# ------------------------------------------------------------------ construccion

func _construir() -> void:
	_raiz = Control.new()
	_raiz.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_raiz)
	var fondo := ColorRect.new()
	fondo.color = Color(0.035, 0.045, 0.08, 0.99)
	fondo.set_anchors_preset(Control.PRESET_FULL_RECT)
	_raiz.add_child(fondo)
	var margen := MarginContainer.new()
	margen.set_anchors_preset(Control.PRESET_FULL_RECT)
	for lado: String in ["left", "right", "top", "bottom"]:
		margen.add_theme_constant_override("margin_" + lado, 16)
	_raiz.add_child(margen)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	margen.add_child(v)
	# barra superior
	var barra := HBoxContainer.new()
	barra.add_theme_constant_override("separation", 26)
	v.add_child(barra)
	_titulo = EstiloUI.etiqueta("ARMERÍA UPO", 26, EstiloUI.ACENTO)
	barra.add_child(_titulo)
	_dinero = EstiloUI.etiqueta("", 26, EstiloUI.ORO)
	barra.add_child(_dinero)
	_fase = EstiloUI.etiqueta("", 18, EstiloUI.TEXTO)
	_fase.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fase.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	barra.add_child(_fase)
	_extra = HBoxContainer.new()
	_extra.add_theme_constant_override("separation", 8)
	barra.add_child(_extra)
	_equipo = EstiloUI.etiqueta("", 14, EstiloUI.TEXTO_SUAVE)
	_equipo.clip_text = true
	v.add_child(_equipo)
	# columnas
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 14)
	v.add_child(cols)
	for c: Dictionary in COLUMNAS:
		cols.add_child(_columna(c))
	v.add_child(EstiloUI.etiqueta("Clic izquierdo: comprar  ·  Clic derecho: devolver lo comprado en esta fase  ·  B / Esc: cerrar", 12, EstiloUI.TEXTO_SUAVE))
	# panel de detalle (flotante)
	_detalle = PanelContainer.new()
	_detalle.visible = false
	_detalle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detalle.custom_minimum_size = Vector2(ANCHO_DETALLE, 0)
	_detalle.add_theme_stylebox_override("panel", EstiloUI.caja(Color(0.06, 0.08, 0.13, 0.99), EstiloUI.ACENTO2, 2, 8, 12))
	_det_cont = VBoxContainer.new()
	_det_cont.add_theme_constant_override("separation", 5)
	_det_cont.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detalle.add_child(_det_cont)
	_raiz.add_child(_detalle)


func _columna(c: Dictionary) -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = float(c["peso"])
	col.add_theme_constant_override("separation", 6)
	col.add_child(EstiloUI.etiqueta(str(c["titulo"]), 20, EstiloUI.TEXTO))
	var linea := ColorRect.new()
	linea.color = EstiloUI.ACENTO
	linea.custom_minimum_size = Vector2(0, 2)
	col.add_child(linea)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	var cuerpo: BoxContainer = HBoxContainer.new() if bool(c["lado"]) else VBoxContainer.new()
	cuerpo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cuerpo.add_theme_constant_override("separation", 10 if bool(c["lado"]) else 4)
	scroll.add_child(cuerpo)
	for b: Dictionary in c["bloques"]:
		var bloque := VBoxContainer.new()
		bloque.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bloque.add_theme_constant_override("separation", 4)
		cuerpo.add_child(bloque)
		if str(b["sub"]) != "":
			bloque.add_child(EstiloUI.etiqueta(str(b["sub"]), 14, EstiloUI.ACENTO2))
		var items: Array = []
		if b.has("ids"):
			for id: StringName in b["ids"]:
				items.append(Catalogo.info(id))
		else:
			items = Catalogo.por_categoria(str(b["cat"]))
		for it: Dictionary in items:
			bloque.add_child(_tarjeta(it))
	return col


func _tarjeta(it: Dictionary) -> Control:
	var id: StringName = it["id"]
	var p := PanelContainer.new()
	p.custom_minimum_size = TAM_TARJETA
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(h)
	h.add_child(_icono(id))
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(v)
	var nombre: Label = EstiloUI.etiqueta(str(it["nombre"]), 13)
	nombre.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	nombre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(nombre)
	var fila := HBoxContainer.new()
	fila.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(fila)
	var precio: Label = EstiloUI.etiqueta("", 15, EstiloUI.ORO)
	precio.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fila.add_child(precio)
	var marca: Label = EstiloUI.etiqueta("", 11, EstiloUI.ORO)
	marca.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	marca.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	marca.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fila.add_child(marca)
	p.gui_input.connect(func(e: InputEvent) -> void:
		var mb := e as InputEventMouseButton
		if mb != null and mb.pressed:
			clic_tarjeta(id, mb.button_index))
	p.mouse_entered.connect(func() -> void:
		_hover = id
		_pintar(id)
		mostrar_detalle(id))
	p.mouse_exited.connect(func() -> void:
		if _hover == id:
			_hover = &""
			_pintar(id)
			_detalle.visible = false)
	tarjetas[id] = p
	_partes[id] = {"precio": precio, "marca": marca}
	var n: int = int(it["precio"])
	precio.text = "gratis" if n == 0 else "$ %d" % n
	p.add_theme_stylebox_override("panel", EstiloUI.caja(EstiloUI.TARJETA, Color(0.25, 0.32, 0.45), 1, 6, 5))
	return p


func _icono(id: StringName) -> Control:
	var ruta: String = RUTA_ICONOS % String(id)
	if ResourceLoader.exists(ruta):
		var t := TextureRect.new()
		t.texture = load(ruta) as Texture2D
		t.custom_minimum_size = Vector2(88, 44)
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return t
	var e := IconoEscudo.new()
	e.custom_minimum_size = Vector2(88, 44)
	e.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if id == &"escudo_pesado":
		e.color = Color(0.95, 0.7, 0.25)
	return e


# ------------------------------------------------------------------ API

func vincular(partida_api: Partida, jugador_propio: Jugador) -> void:
	partida = partida_api
	jugador = jugador_propio
	partida.compra_hecha.connect(func(_c: Node, _id: StringName) -> void: refrescar())


## Configura el modo: libre muestra los botones de pausa y el dinero infinito.
func configurar(libre: bool) -> void:
	modo_libre = libre
	EstiloUI.vaciar(_extra)
	if libre:
		_titulo.text = "TIENDA · modo libre"
		var datos: Array = [["Reanudar", reanudar], ["Volver al lobby", volver_lobby], ["Salir del juego", salir_juego]]
		if OS.has_feature("web"):      # en el navegador no se puede cerrar el juego
			datos.pop_back()
		for d: Array in datos:
			var b: Button = EstiloUI.boton(str(d[0]), 16)
			var sen: Signal = d[1]
			b.pressed.connect(func() -> void: sen.emit())
			_extra.add_child(b)
	else:
		_titulo.text = "ARMERÍA UPO"
		var cerrar: Button = EstiloUI.boton("Cerrar (B)", 16)
		cerrar.pressed.connect(cerrar_tienda)
		_extra.add_child(cerrar)


func abrir() -> void:
	visible = true
	_detalle.visible = false
	refrescar()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func cerrar_tienda() -> void:
	if not visible:
		return
	visible = false
	_detalle.visible = false
	cerrada.emit()


func _process(_delta: float) -> void:
	if not visible or partida == null:
		return
	match partida.fase:
		Partida.Fase.COMPRA:
			_fase.text = "FASE DE COMPRA · quedan %d s" % ceili(partida.t_fase)
		Partida.Fase.LIBRE:
			_fase.text = "MODO LIBRE · dinero infinito · cambia de sitio con M"
		_:
			_fase.text = "La compra ya ha terminado"


## Actualiza dinero, estado de cada tarjeta y resumen del equipo.
func refrescar() -> void:
	if partida == null or jugador == null or not visible:
		return
	_dinero.text = "∞ créditos" if partida.cfg.es_libre() else "$ %d" % partida.dinero_de(jugador)
	for id: StringName in tarjetas:
		_pintar(id)
	_refrescar_equipo()
	if _hover != &"":
		mostrar_detalle(_hover)


func _estado(id: StringName) -> Dictionary:
	var ev: Dictionary = partida.evaluar_compra(jugador, id)
	var lleva: bool = partida.lleva(jugador, id)
	var comprado: bool = false
	for e: Dictionary in partida.compras_de(jugador):
		if StringName(e["id"]) == id:
			comprado = true
	var ok: bool = bool(ev["ok"])
	return {"ok": ok, "lleva": lleva, "comprado": comprado, "motivo": str(ev["motivo"]),
			"reemplazo": not (ev["reemplazo"] as Dictionary).is_empty(), "deshabilitada": not ok and not lleva and not comprado}


func _pintar(id: StringName) -> void:
	if partida == null or jugador == null:
		return
	var p: PanelContainer = tarjetas[id]
	var est: Dictionary = _estado(id)
	p.set_meta("estado", est)
	var borde: Color = Color(0.25, 0.32, 0.45)
	var grosor: int = 1
	if est["comprado"]:
		borde = EstiloUI.ORO
		grosor = 2
	elif est["lleva"]:
		borde = EstiloUI.BUENO
		grosor = 2
	if _hover == id and not est["deshabilitada"]:
		borde = EstiloUI.ACENTO
		grosor = 2
	var fondo: Color = EstiloUI.TARJETA
	if est["comprado"] or est["lleva"]:
		fondo = Color(0.15, 0.2, 0.2) if est["lleva"] and not est["comprado"] else Color(0.22, 0.2, 0.12)
	p.add_theme_stylebox_override("panel", EstiloUI.caja(fondo, borde, grosor, 6, 5))
	p.modulate = Color(1, 1, 1, 0.5) if est["deshabilitada"] else Color(1, 1, 1, 1)
	var partes: Dictionary = _partes[id]
	var marca: Label = partes["marca"]
	var precio: Label = partes["precio"]
	marca.text = "COMPRADO" if est["comprado"] else ("EQUIPADO" if est["lleva"] else ("sustituye" if est["reemplazo"] else ""))
	marca.add_theme_color_override("font_color", EstiloUI.ORO if est["comprado"] else (EstiloUI.BUENO if est["lleva"] else EstiloUI.TEXTO_SUAVE))
	precio.add_theme_color_override("font_color", EstiloUI.MALO if est["deshabilitada"] else EstiloUI.ORO)


## Clic en una tarjeta: izquierdo compra, derecho devuelve lo comprado en esta fase (lo mismo que hace el raton).
func clic_tarjeta(id: StringName, boton: int) -> void:
	if partida == null or jugador == null or not tarjetas.has(id):
		return
	var est: Dictionary = _estado(id)
	if boton == MOUSE_BUTTON_LEFT:
		if bool(est["ok"]) and not bool(est["lleva"]):
			partida.comprar(jugador, id)
	elif boton == MOUSE_BUTTON_RIGHT:
		if bool(est["comprado"]):
			partida.vender(jugador, id)
	refrescar()


func _refrescar_equipo() -> void:
	var inv: Inventario = jugador.gestor.inventario
	var us: PackedStringArray = PackedStringArray()
	for u: StringName in inv.tipos_utilidad():
		us.append("%s x%d" % [_nombre(u), inv.cantidad_utilidad(u)])
	_equipo.text = "Principal: %s   ·   Secundaria: %s   ·   Cuerpo a cuerpo: %s   ·   Escudo: %d / 50   ·   Utilidades: %s" % [
			_nombre(inv.principal), _nombre(inv.secundaria), _nombre(inv.cuerpo), int(inv.escudo), ", ".join(us) if not us.is_empty() else "—"]


func _nombre(id: StringName) -> String:
	if id == &"":
		return "—"
	return str(Catalogo.info(id).get("nombre", id))


# ------------------------------------------------------------------ detalle

## Muestra el panel de detalle del articulo `id` junto a su tarjeta.
func mostrar_detalle(id: StringName) -> void:
	if not tarjetas.has(id):
		return
	EstiloUI.vaciar(_det_cont)
	var info: Dictionary = Catalogo.info(id)
	var a: ArmaDatos = Catalogo.arma(id)
	_det_cont.add_child(EstiloUI.etiqueta(str(info["nombre"]), 20, EstiloUI.ACENTO))
	var desc: Label = EstiloUI.etiqueta(str(info["descripcion"]), 13, EstiloUI.TEXTO_SUAVE)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(ANCHO_DETALLE - 26.0, 0)
	_det_cont.add_child(desc)
	var precio: int = int(info["precio"])
	if a == null:
		var pts: float = float(Catalogo.PUNTOS_ESCUDO.get(id, 0.0))
		_det_cont.add_child(_fila_barra("Escudo", pts / 50.0, "%d pts" % int(pts), EstiloUI.ACENTO2))
	elif a.es_utilidad():
		for linea: String in _lineas_utilidad(a):
			_det_cont.add_child(EstiloUI.etiqueta(linea, 14, EstiloUI.ACENTO2))
	else:
		var m: Dictionary = _maximos_armas()
		for z: Array in [["Daño cabeza", "cabeza"], ["Daño cuerpo", "torso"], ["Daño piernas", "piernas"]]:
			var d: float = _dano(a, str(z[1]))
			_det_cont.add_child(_fila_barra(str(z[0]), d / maxf(float(m["dano"]), 1.0), "%d" % roundi(d), Color(1.0, 0.45, 0.35)))
		_det_cont.add_child(_fila_barra("Cadencia", a.cadencia / maxf(float(m["cadencia"]), 0.1), "%.1f/s" % a.cadencia, EstiloUI.ACENTO))
		if a.es_melee() or a.cargador <= 0:
			_det_cont.add_child(_fila_barra("Cargador", 0.0, "—", EstiloUI.ACENTO2))
			_det_cont.add_child(_fila_barra("Recarga", 0.0, "—", EstiloUI.ACENTO2))
		else:
			_det_cont.add_child(_fila_barra("Cargador", float(a.cargador) / maxf(float(m["cargador"]), 1.0), "%d" % a.cargador, EstiloUI.ACENTO2))
			_det_cont.add_child(_fila_barra("Recarga", a.tiempo_recarga / maxf(float(m["recarga"]), 0.1), "%.1f s" % a.tiempo_recarga, EstiloUI.ACENTO2))
		_det_cont.add_child(_fila_barra("Movilidad", a.velocidad_mov / maxf(float(m["movilidad"]), 0.1), "%d%%" % roundi(a.velocidad_mov * 100.0), EstiloUI.BUENO))
	_det_cont.add_child(_fila_barra("Precio", 0.0, "gratis" if precio == 0 else "$ %d" % precio, EstiloUI.ORO, false))
	var est: Dictionary = tarjetas[id].get_meta("estado", {})
	if bool(est.get("deshabilitada", false)):
		var mot: Label = EstiloUI.etiqueta(str(est["motivo"]), 13, EstiloUI.MALO)
		mot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		mot.custom_minimum_size = Vector2(ANCHO_DETALLE - 26.0, 0)
		_det_cont.add_child(mot)
	elif bool(est.get("comprado", false)):
		_det_cont.add_child(EstiloUI.etiqueta("Clic derecho: devolver (+$ %d)" % precio, 13, EstiloUI.ORO))
	_detalle.visible = true
	_detalle.size = Vector2(ANCHO_DETALLE, 0)
	_detalle.size = _detalle.get_combined_minimum_size()
	var t: Control = tarjetas[id]
	var r: Rect2 = t.get_global_rect()
	var pantalla: Vector2 = _raiz.size
	var x: float = r.end.x + 8.0
	if x + _detalle.size.x > pantalla.x - 8.0:
		x = r.position.x - 8.0 - _detalle.size.x
	var y: float = clampf(r.position.y, 8.0, maxf(pantalla.y - _detalle.size.y - 8.0, 8.0))
	_detalle.position = Vector2(maxf(x, 8.0), y)


## Fila "nombre ---barra--- valor".
func _fila_barra(nombre: String, ratio: float, valor: String, color: Color, con_barra: bool = true) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var n: Label = EstiloUI.etiqueta(nombre, 13, EstiloUI.TEXTO_SUAVE)
	n.custom_minimum_size = Vector2(92, 0)
	h.add_child(n)
	var barra := Control.new()
	barra.custom_minimum_size = Vector2(80, 8)
	barra.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	barra.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if con_barra:
		var f := ColorRect.new()
		f.color = Color(1, 1, 1, 0.1)
		f.set_anchors_preset(Control.PRESET_FULL_RECT)
		barra.add_child(f)
		var r := ColorRect.new()
		r.color = color
		r.anchor_right = clampf(ratio, 0.0, 1.0)
		r.anchor_bottom = 1.0
		barra.add_child(r)
	h.add_child(barra)
	var v: Label = EstiloUI.etiqueta(valor, 14, EstiloUI.TEXTO if con_barra else color)
	v.custom_minimum_size = Vector2(58, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(v)
	return h


## Dano de un impacto en la zona (cohete = explosion; escopetas = todos los perdigones).
func _dano(a: ArmaDatos, zona: String) -> float:
	if a.tipo == ArmaDatos.T_COHETE:
		return a.dano_explosion
	var d: float = a.dano_base * a.mult_zona(zona)
	if a.perdigones > 1:
		d *= a.perdigones
	return d


## Maximos del catalogo de armas (para escalar las barras), calculados una vez.
func _maximos_armas() -> Dictionary:
	if not _maximos.is_empty():
		return _maximos
	_maximos = {"dano": 1.0, "cadencia": 0.1, "cargador": 1.0, "recarga": 0.1, "movilidad": 1.0}
	for it: Dictionary in Catalogo.todos():
		var a: ArmaDatos = Catalogo.arma(it["id"])
		if a == null or a.es_utilidad():
			continue
		for z: String in ["cabeza", "torso", "piernas"]:
			_maximos["dano"] = maxf(float(_maximos["dano"]), _dano(a, z))
		_maximos["cadencia"] = maxf(float(_maximos["cadencia"]), a.cadencia)
		_maximos["cargador"] = maxf(float(_maximos["cargador"]), float(a.cargador))
		_maximos["recarga"] = maxf(float(_maximos["recarga"]), a.tiempo_recarga)
		_maximos["movilidad"] = maxf(float(_maximos["movilidad"]), a.velocidad_mov)
	return _maximos


func _lineas_utilidad(a: ArmaDatos) -> PackedStringArray:
	var l: PackedStringArray = PackedStringArray()
	if a.dano_explosion > 0.0:
		l.append("Daño: %d" % roundi(a.dano_explosion))
	var radio: float = maxf(a.radio_efecto, a.radio_explosion)
	if radio > 0.0:
		l.append("Radio: %.0f m" % radio)
	if a.duracion_efecto > 0.0:
		l.append("Duración: %.0f s" % a.duracion_efecto)
	if a.mecha > 0.0:
		l.append("Mecha: %.1f s" % a.mecha)
	return l
