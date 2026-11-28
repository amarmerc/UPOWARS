class_name LobbyUI
extends CanvasLayer
## Lobby: pantalla previa a la partida. A la izquierda un panel por equipo (nombre editable) con los huecos del equipo como tarjetas
## con retrato; los huecos que no son humanos son bots ("BOT"), y un clic sobre una tarjeta de bot intercambia al jugador con ese bot
## (asi se cambia de equipo o de hueco). A la derecha las opciones (Modo, Zona, Tamaño de equipos, Dificultad, Rondas), la tarjeta
## del jugador (nombre y personaje, guardados en user://perfil.cfg) y el boton "Listo" con el contador listos/humanos.
##
## Modelo de datos: `equipos[g]` (g = 0 EPS, empieza atacando; 1 CEUPO) es un Array de huecos
## `ConfigPartida.hueco(tipo, nombre, personaje, listo, local)`. Hoy solo hay un humano (el local); mas adelante los humanos de la
## red ocuparan huecos `humano` no locales y la partida arranca cuando todos los humanos estan listos. `iniciar` lleva el `ConfigPartida`.

signal iniciar(config: ConfigPartida)
signal salir_juego
signal zona_elegida(zona_id: String)
## Red: botones del panel de red.
signal crear_local_pedido(puerto: int)
signal unirse_pedido(ip: String, puerto: int)
signal desconectar_pedido

const MAX_EQUIPO: int = 5
const COLORES_EQUIPO: Array[Color] = [Color(0.16, 0.2, 0.72), Color(0.86, 0.45, 0.05)]
const TAM_TARJETA: Vector2 = Vector2(100, 112)
const COLOR_RETRATO: Color = Color(0.8, 0.84, 0.88)

var equipos: Array = [[], []]
var perfil: Dictionary = {}

var _retratos: RetratosPersonajes
var _modo: OptionButton
var _zona: OptionButton
var _tam: SpinBox
var _dificultad: OptionButton
var _rondas: SpinBox
var _bots_libres: SpinBox
var _nombre: LineEdit
var _nombres_equipo: Array[LineEdit] = []
var _flujos: Array[HFlowContainer] = []
var _paneles_equipo: Array[Control] = []
var _panel_libre: Control
var _filas_comp: Array[Control] = []
var _retrato_yo: TextureRect
var _nombre_pers: Label
var _boton_listo: Button
var _descripcion: Label
var _ids_zona: PackedStringArray = PackedStringArray()
var _creditos: Control
## Red: cuando es true el lobby es una VISTA del lobby del servidor (huecos, opciones y "listo" viven alli) y las acciones se mandan por
## `red_enviar` (Callable(accion, a, b)). `mi_peer` identifica la tarjeta propia; solo el anfitrion cambia las opciones.
var red_activa: bool = false
var red_enviar: Callable = Callable()
var mi_peer: int = 0
var es_anfitrion: bool = false
var _ignorar: bool = false
var _ip: LineEdit
var _estado_red: Label
var _boton_desconectar: Button
var _boton_forzar: Button
var _boton_crear: Button
var _boton_unirse: Button


func _init() -> void:
	layer = 20
	perfil = PerfilJugador.cargar()
	_retratos = RetratosPersonajes.new()
	_retratos.name = "Retratos"
	add_child(_retratos)
	_construir()
	_iniciar_huecos(MAX_EQUIPO)


# ------------------------------------------------------------------ construccion

func _construir() -> void:
	var raiz := Control.new()
	raiz.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(raiz)
	var fondo := ColorRect.new()
	fondo.color = Color(0.02, 0.03, 0.06, 0.4)
	fondo.set_anchors_preset(Control.PRESET_FULL_RECT)
	raiz.add_child(fondo)
	var margen := MarginContainer.new()
	margen.set_anchors_preset(Control.PRESET_FULL_RECT)
	for lado: String in ["left", "right", "top", "bottom"]:
		margen.add_theme_constant_override("margin_" + lado, 20)
	raiz.add_child(margen)
	var fila := HBoxContainer.new()
	fila.add_theme_constant_override("separation", 20)
	margen.add_child(fila)
	# izquierda: equipos
	var izq := VBoxContainer.new()
	izq.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	izq.size_flags_stretch_ratio = 1.0
	izq.add_theme_constant_override("separation", 12)
	fila.add_child(izq)
	for g in 2:
		izq.add_child(_panel_equipo(g))
	_panel_libre = _construir_panel_libre()
	izq.add_child(_panel_libre)
	# derecha: opciones, tu tarjeta y Listo
	var der := VBoxContainer.new()
	der.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	der.size_flags_stretch_ratio = 1.0
	der.add_theme_constant_override("separation", 12)
	fila.add_child(der)
	der.add_child(_panel_opciones())
	der.add_child(_panel_red())
	der.add_child(_panel_tu())
	_boton_listo = EstiloUI.boton("LISTO", 30)
	_boton_listo.custom_minimum_size = Vector2(0, 84)
	_boton_listo.pressed.connect(pulsar_listo)
	der.add_child(_boton_listo)
	var pie := HBoxContainer.new()
	der.add_child(pie)
	var ayuda: Label = EstiloUI.etiqueta("WASD mover · Shift correr · Ctrl agacharse · E interactuar · B tienda · Tab marcador · Esc menú", 11, EstiloUI.TEXTO_SUAVE)
	ayuda.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ayuda.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pie.add_child(ayuda)
	var salir: Button = EstiloUI.boton("Salir", 14)
	salir.pressed.connect(func() -> void: salir_juego.emit())
	salir.visible = not OS.has_feature("web")      # en el navegador no se puede "cerrar" el juego
	pie.add_child(salir)
	var cred: Button = EstiloUI.boton("Créditos", 14)
	cred.pressed.connect(_mostrar_creditos)
	pie.add_child(cred)
	pie.move_child(cred, pie.get_child_count() - 2)
	_actualizar_modo()
	_al_elegir_zona(0)
	_modo.item_selected.connect(func(_i: int) -> void: _enviar_config())
	_zona.item_selected.connect(func(_i: int) -> void: _enviar_config())
	_tam.value_changed.connect(func(_n: float) -> void: _enviar_config())
	_dificultad.item_selected.connect(func(_i: int) -> void: _enviar_config())
	_rondas.value_changed.connect(func(_n: float) -> void: _enviar_config())
	_bots_libres.value_changed.connect(func(_n: float) -> void: _enviar_config())
	for le: LineEdit in _nombres_equipo:
		le.text_submitted.connect(func(_t: String) -> void: _enviar_config())
		le.focus_exited.connect(_enviar_config)


## Panel de red: crear una partida local (este proceso hace de servidor) o unirse a la de otro por IP:puerto (ENet) o por URL
## ws:// / wss:// (WebSocket). En la version web no hay "Crear partida local" (el navegador no puede abrir un servidor) y el campo
## viene con la direccion del servidor web del propio sitio (wss://<host de la pagina>/ws).
func _panel_red() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", EstiloUI.caja(EstiloUI.PANEL, EstiloUI.ACENTO2, 2, 10, 10))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)
	v.add_child(EstiloUI.etiqueta("RED (multijugador)", 17, EstiloUI.ACENTO2))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	v.add_child(h)
	_boton_crear = EstiloUI.boton("Crear partida local", 15)
	_boton_crear.pressed.connect(func() -> void: crear_local_pedido.emit(_puerto_ip()))
	_boton_crear.visible = not OS.has_feature("web")
	h.add_child(_boton_crear)
	_ip = LineEdit.new()
	_ip.text = _destino_por_defecto()
	_ip.placeholder_text = "IP:puerto o ws://host/ws"
	_ip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(_ip)
	_boton_unirse = EstiloUI.boton("Unirse", 15)
	_boton_unirse.pressed.connect(_pulsar_unirse)
	h.add_child(_boton_unirse)
	var h2 := HBoxContainer.new()
	v.add_child(h2)
	_estado_red = EstiloUI.etiqueta("Sin conexion: modo un jugador", 13, EstiloUI.TEXTO_SUAVE)
	_estado_red.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h2.add_child(_estado_red)
	_boton_forzar = EstiloUI.boton("Forzar inicio", 13)
	_boton_forzar.visible = false
	_boton_forzar.pressed.connect(func() -> void: _red_cmd(&"forzar", null, null))
	h2.add_child(_boton_forzar)
	_boton_desconectar = EstiloUI.boton("Desconectar", 13)
	_boton_desconectar.visible = false
	_boton_desconectar.pressed.connect(func() -> void: desconectar_pedido.emit())
	h2.add_child(_boton_desconectar)
	return panel


## Valor inicial del campo de union: en la exportacion web, el servidor del propio sitio; en escritorio, el servidor local.
func _destino_por_defecto() -> String:
	if OS.has_feature("web"):
		var esquema: String = str(JavaScriptBridge.eval("location.protocol === 'https:' ? 'wss://' : 'ws://'", true))
		var host: String = str(JavaScriptBridge.eval("location.host", true))
		if host != "" and host != "null":
			return "%s%s/ws" % [esquema, host]
	return "127.0.0.1:%d" % ProtoRed.PUERTO_DEFECTO


## `ws://...` / `wss://...` se manda tal cual (puerto 0 = el de la URL); lo demas es IP[:puerto] de ENet.
func _pulsar_unirse() -> void:
	var t: String = _ip.text.strip_edges()
	if Red.es_url_ws(t):
		unirse_pedido.emit(t, 0)
	else:
		unirse_pedido.emit(t.get_slice(":", 0).strip_edges(), _puerto_ip())


func _puerto_ip() -> int:
	var t: String = _ip.text.strip_edges()
	return int(t.get_slice(":", 1)) if t.contains(":") and int(t.get_slice(":", 1)) > 0 else ProtoRed.PUERTO_DEFECTO


func _red_cmd(accion: StringName, a: Variant, b: Variant) -> void:
	if red_enviar.is_valid():
		red_enviar.call(accion, a, b)


func poner_estado_red(texto: String) -> void:
	if _estado_red != null:
		_estado_red.text = texto


## Vuelve al lobby de un jugador (cierra la vista de red).
func salir_red() -> void:
	red_activa = false
	red_enviar = Callable()
	es_anfitrion = false
	_boton_desconectar.visible = false
	_boton_forzar.visible = false
	_boton_crear.disabled = false
	_boton_unirse.disabled = false
	_estado_red.text = "Sin conexion: modo un jugador"
	_fijar_opciones_activas(true)
	_iniciar_huecos(MAX_EQUIPO)


func _fijar_opciones_activas(on: bool) -> void:
	_modo.disabled = not on
	_zona.disabled = not on
	_tam.editable = on
	_dificultad.disabled = not on
	_rondas.editable = on
	_bots_libres.editable = on
	for le: LineEdit in _nombres_equipo:
		le.editable = on


## Aplica el estado del lobby que manda el servidor (`ServidorRed.estado_lobby`).
func aplicar_estado_red(e: Dictionary, mi_id: int) -> void:
	red_activa = true
	mi_peer = mi_id
	es_anfitrion = int(e["anfitrion"]) == mi_id
	_ignorar = true
	for i in ConfigPartida.MODOS.size():
		if String(ConfigPartida.MODOS[i][0]) == str(e["modo"]):
			_modo.select(i)
	var zi: int = _ids_zona.find(str(e["zona"]))
	if zi >= 0:
		_zona.select(zi)
	_tam.value = int(e["tam"])
	var di: int = DificultadBot.TODAS.find(StringName(str(e["dificultad"])))
	if di >= 0:
		_dificultad.select(di)
	_rondas.value = int(e["rondas"])
	_bots_libres.value = int(e["bots_libres"])
	for g in 2:
		if not _nombres_equipo[g].has_focus():
			_nombres_equipo[g].text = str((e["nombres"] as Array)[g])
	_ignorar = false
	equipos = [[], []]
	for g in 2:
		for h: Dictionary in e["huecos"][g]:
			var humano: bool = str(h["tipo"]) == "humano"
			var pers: StringName = StringName(str(h["personaje"]))
			equipos[g].append(ConfigPartida.hueco(ConfigPartida.TIPO_HUMANO if humano else ConfigPartida.TIPO_BOT, str(h["nombre"]), pers,
					bool(h["listo"]), humano and int(h["peer"]) == mi_id))
	var yo: Vector2i = pos_local()
	if yo.x >= 0:
		perfil["personaje"] = (equipos[yo.x][yo.y] as Dictionary)["personaje"]
	_fijar_opciones_activas(es_anfitrion)
	_boton_forzar.visible = es_anfitrion
	_boton_desconectar.visible = true
	_boton_crear.disabled = true
	_boton_unirse.disabled = true
	_actualizar_modo()
	_refrescar()


func _enviar_config() -> void:
	if not red_activa or not es_anfitrion or _ignorar:
		return
	var a: String = _nombres_equipo[0].text.strip_edges()
	var d: String = _nombres_equipo[1].text.strip_edges()
	_red_cmd(&"config", {"modo": String(modo_id()), "zona": _ids_zona[_zona.selected] if not _ids_zona.is_empty() else "",
			"tam": int(_tam.value), "dificultad": String(DificultadBot.TODAS[_dificultad.selected]), "rondas": int(_rondas.value),
			"bots_libres": int(_bots_libres.value), "nombres": [a if a != "" else "EPS", d if d != "" else "CEUPO"]}, null)


## Ventana con los créditos de los recursos externos (`res://data/creditos.md`, copia de CREDITOS.md).
func _mostrar_creditos() -> void:
	if _creditos != null and is_instance_valid(_creditos):
		_creditos.visible = true
		return
	_creditos = Control.new()
	_creditos.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_creditos)
	var vel := ColorRect.new()
	vel.color = Color(0, 0, 0, 0.75)
	vel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_creditos.add_child(vel)
	var centro := CenterContainer.new()
	centro.set_anchors_preset(Control.PRESET_FULL_RECT)
	_creditos.add_child(centro)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(860, 560)
	panel.add_theme_stylebox_override("panel", EstiloUI.caja(Color(0.08, 0.1, 0.16, 0.98), Color(0.95, 0.65, 0.2), 2, 12, 14))
	centro.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	v.add_child(EstiloUI.etiqueta("Créditos", 26, Color(0.95, 0.65, 0.2)))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	var texto: String = FileAccess.get_file_as_string("res://data/creditos.md") if FileAccess.file_exists("res://data/creditos.md") else "Sin información de créditos."
	var et: Label = EstiloUI.etiqueta(texto, 13, Color(0.9, 0.92, 0.97))
	et.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	et.custom_minimum_size = Vector2(800, 0)
	scroll.add_child(et)
	var cerrar: Button = EstiloUI.boton("Cerrar", 16)
	cerrar.pressed.connect(func() -> void: _creditos.visible = false)
	v.add_child(cerrar)


func _panel_equipo(g: int) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", EstiloUI.caja(COLORES_EQUIPO[g], COLORES_EQUIPO[g].lightened(0.35), 2, 10, 10))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	panel.add_child(v)
	var nombre := LineEdit.new()
	nombre.text = "EPS" if g == 0 else "CEUPO"
	nombre.max_length = 14
	nombre.alignment = HORIZONTAL_ALIGNMENT_CENTER
	nombre.tooltip_text = "Nombre del equipo (editable)"
	nombre.add_theme_font_size_override("font_size", 28)
	nombre.add_theme_color_override("font_color", Color(1, 1, 1))
	nombre.add_theme_color_override("caret_color", Color(1, 1, 1))
	var plano := StyleBoxFlat.new()
	plano.bg_color = Color(0, 0, 0, 0)
	plano.set_content_margin_all(2)
	var foco := StyleBoxFlat.new()
	foco.bg_color = Color(0, 0, 0, 0.25)
	foco.set_corner_radius_all(6)
	foco.set_content_margin_all(2)
	nombre.add_theme_stylebox_override("normal", plano)
	nombre.add_theme_stylebox_override("focus", foco)
	v.add_child(nombre)
	_nombres_equipo.append(nombre)
	var sub: Label = EstiloUI.etiqueta("empieza atacando" if g == 0 else "empieza defendiendo", 12, Color(1, 1, 1, 0.7))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)
	var centro := CenterContainer.new()
	centro.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(centro)
	var flujo := HFlowContainer.new()
	flujo.alignment = FlowContainer.ALIGNMENT_CENTER
	flujo.custom_minimum_size = Vector2(3.0 * TAM_TARJETA.x + 24.0, 0)
	flujo.add_theme_constant_override("h_separation", 10)
	flujo.add_theme_constant_override("v_separation", 8)
	centro.add_child(flujo)
	_flujos.append(flujo)
	_paneles_equipo.append(panel)
	return panel


func _construir_panel_libre() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", EstiloUI.caja(EstiloUI.PANEL, EstiloUI.ACENTO2, 2, 10, 18))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	v.add_child(EstiloUI.etiqueta("MODO LIBRE", 34, EstiloUI.ACENTO2))
	var t: Label = EstiloUI.etiqueta("Todo el campus a tu disposición: apareces donde quieras, con dinero infinito y bots opcionales que deambulan. Esc abre la tienda y las opciones de salir.", 16, EstiloUI.TEXTO)
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(t)
	var h := HBoxContainer.new()
	v.add_child(h)
	var l: Label = EstiloUI.etiqueta("Bots en el campus", 16)
	l.custom_minimum_size = Vector2(190, 0)
	h.add_child(l)
	_bots_libres = _spin(0, 10, 4)
	_bots_libres.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(_bots_libres)
	panel.visible = false
	return panel


func _panel_opciones() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", EstiloUI.caja(EstiloUI.PANEL, EstiloUI.ACENTO, 2, 10, 14))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 7)
	panel.add_child(v)
	v.add_child(EstiloUI.etiqueta("UPOWARS · lobby de partida", 22, EstiloUI.ACENTO))
	var nombres_modo: Array = []
	for m: Array in ConfigPartida.MODOS:
		nombres_modo.append(str(m[1]))
	_modo = _opcion(v, "Modo", nombres_modo, false)
	_modo.select(1)
	_modo.item_selected.connect(func(_i: int) -> void: _actualizar_modo())
	_ids_zona = ZonaActiva.ids_disponibles()
	var zonas: Array = []
	for z: String in _ids_zona:
		zonas.append(str(ZonaActiva.datos_de(z).get("nombre", z)))
	_zona = _opcion(v, "Zona", zonas, true)
	_zona.item_selected.connect(func(i: int) -> void: _al_elegir_zona(i))
	_tam = _spin(1, MAX_EQUIPO, MAX_EQUIPO)
	_fila(v, "Tamaño equipos", _tam, true)
	_tam.value_changed.connect(func(n: float) -> void: _ajustar_tam(int(n)))
	_dificultad = _opcion(v, "Dificultad bots", ["Fácil", "Normal", "Difícil"], false)
	_dificultad.select(1)
	_rondas = _spin(1, 13, 7)
	_fila(v, "Rondas", _rondas, true)
	_descripcion = EstiloUI.etiqueta("", 13, EstiloUI.TEXTO_SUAVE)
	_descripcion.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_descripcion.custom_minimum_size = Vector2(0, 54)
	v.add_child(_descripcion)
	return panel


func _panel_tu() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", EstiloUI.caja(Color(0.36, 0.12, 0.12, 0.97), Color(0.9, 0.35, 0.3), 2, 10, 12))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	panel.add_child(h)
	var marco := PanelContainer.new()
	marco.custom_minimum_size = Vector2(TAM_TARJETA.x + 20, TAM_TARJETA.y + 30)
	marco.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	marco.add_theme_stylebox_override("panel", EstiloUI.caja(COLOR_RETRATO, EstiloUI.ORO, 3, 10, 2))
	h.add_child(marco)
	_retrato_yo = TextureRect.new()
	_retrato_yo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_retrato_yo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	marco.add_child(_retrato_yo)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 6)
	h.add_child(v)
	v.add_child(EstiloUI.etiqueta("TÚ", 14, EstiloUI.ORO))
	v.add_child(EstiloUI.etiqueta("Nombre", 14, EstiloUI.TEXTO_SUAVE))
	_nombre = LineEdit.new()
	_nombre.text = str(perfil["nombre"])
	_nombre.max_length = 16
	_nombre.placeholder_text = PerfilJugador.NOMBRE_DEFECTO
	_nombre.add_theme_font_size_override("font_size", 18)
	_nombre.text_changed.connect(func(_t: String) -> void: _al_cambiar_nombre())
	v.add_child(_nombre)
	v.add_child(EstiloUI.etiqueta("Personaje", 14, EstiloUI.TEXTO_SUAVE))
	var sel := HBoxContainer.new()
	sel.add_theme_constant_override("separation", 6)
	v.add_child(sel)
	var ant: Button = EstiloUI.boton("<", 18)
	ant.custom_minimum_size = Vector2(40, 0)
	ant.pressed.connect(cambiar_personaje.bind(-1))
	sel.add_child(ant)
	_nombre_pers = EstiloUI.etiqueta("", 18)
	_nombre_pers.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_nombre_pers.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sel.add_child(_nombre_pers)
	var sig: Button = EstiloUI.boton(">", 18)
	sig.custom_minimum_size = Vector2(40, 0)
	sig.pressed.connect(cambiar_personaje.bind(1))
	sel.add_child(sig)
	return panel


## Fila titulo + control. `solo_comp` = solo visible en los modos competitivos.
func _fila(padre: Control, titulo: String, control: Control, solo_comp: bool) -> HBoxContainer:
	var h := HBoxContainer.new()
	var l: Label = EstiloUI.etiqueta(titulo, 17, EstiloUI.TEXTO)
	l.custom_minimum_size = Vector2(190, 0)
	h.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(control)
	padre.add_child(h)
	if solo_comp:
		_filas_comp.append(h)
	return h


func _opcion(padre: Control, titulo: String, items: Array, solo_comp: bool) -> OptionButton:
	var o := OptionButton.new()
	o.add_theme_font_size_override("font_size", 16)
	for it: Variant in items:
		o.add_item(str(it))
	_fila(padre, titulo, o, solo_comp)
	return o


func _spin(minimo: int, maximo: int, valor: int) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = minimo
	s.max_value = maximo
	s.value = valor
	return s


# ------------------------------------------------------------------ modelo de huecos

func _iniciar_huecos(n: int) -> void:
	equipos = [[], []]
	for g in 2:
		for i in n:
			equipos[g].append(ConfigPartida.hueco(ConfigPartida.TIPO_BOT))
	equipos[0][0] = ConfigPartida.hueco(ConfigPartida.TIPO_HUMANO, str(perfil["nombre"]), perfil["personaje"], false, true)
	_refrescar()


## Posicion (equipo, hueco) del jugador local.
func pos_local() -> Vector2i:
	for g in 2:
		for i in (equipos[g] as Array).size():
			if bool((equipos[g][i] as Dictionary)["local"]):
				return Vector2i(g, i)
	return Vector2i(-1, -1)


func grupo_jugador() -> int:
	return pos_local().x


func tam_equipos() -> int:
	return int(_tam.value)


## Cambia los huecos por equipo (1-5): se quitan antes los bots del final; los nuevos huecos son bots.
func poner_tam(n: int) -> void:
	_tam.value = clampi(n, 1, MAX_EQUIPO)


func _ajustar_tam(n: int) -> void:
	if red_activa:
		return
	for g in 2:
		var lista: Array = equipos[g]
		while lista.size() > n:
			var k: int = lista.size() - 1
			while k > 0 and (lista[k] as Dictionary)["tipo"] != ConfigPartida.TIPO_BOT:
				k -= 1
			lista.remove_at(k)
		while lista.size() < n:
			lista.append(ConfigPartida.hueco(ConfigPartida.TIPO_BOT))
	_refrescar()


## Clic en el hueco (g, i): si es un bot, el jugador se intercambia con el.
func clic_hueco(g: int, i: int) -> void:
	if red_activa:
		_red_cmd(&"hueco", g, i)
		return
	var yo: Vector2i = pos_local()
	if yo.x < 0 or g < 0 or g > 1 or i < 0 or i >= (equipos[g] as Array).size():
		return
	if (equipos[g][i] as Dictionary)["tipo"] != ConfigPartida.TIPO_BOT:
		return
	var mio: Dictionary = equipos[yo.x][yo.y]
	equipos[yo.x][yo.y] = equipos[g][i]
	equipos[g][i] = mio
	_refrescar()


func personaje_elegido() -> StringName:
	return perfil["personaje"]


func poner_nombre(texto: String) -> void:
	_nombre.text = texto
	_al_cambiar_nombre()


func cambiar_personaje(dir: int) -> void:
	perfil["personaje"] = CatalogoPersonajes.vecino(perfil["personaje"], dir)
	if red_activa:
		_red_cmd(&"personaje", String(perfil["personaje"]), null)
		_guardar_perfil()
		_refrescar()
		return
	var yo: Vector2i = pos_local()
	if yo.x >= 0:
		(equipos[yo.x][yo.y] as Dictionary)["personaje"] = perfil["personaje"]
	_guardar_perfil()
	_refrescar()


func _al_cambiar_nombre() -> void:
	perfil["nombre"] = _nombre.text
	if red_activa:
		_red_cmd(&"nombre", _nombre.text, null)
		_guardar_perfil()
		return
	_guardar_perfil()
	_refrescar()


func _guardar_perfil() -> void:
	var n: String = str(perfil["nombre"]).strip_edges()
	PerfilJugador.guardar(n if n != "" else PerfilJugador.NOMBRE_DEFECTO, perfil["personaje"])


func _nombre_local() -> String:
	var n: String = _nombre.text.strip_edges()
	return n if n != "" else PerfilJugador.NOMBRE_DEFECTO


## (listos, humanos) sobre todos los huecos.
func contador_listos() -> Vector2i:
	var listos: int = 0
	var humanos: int = 0
	for g in 2:
		for h: Dictionary in equipos[g]:
			if h["tipo"] == ConfigPartida.TIPO_HUMANO:
				humanos += 1
				listos += 1 if bool(h["listo"]) else 0
	return Vector2i(listos, humanos)


## Marca / desmarca al jugador local como listo; cuando todos los humanos lo estan, arranca la partida.
func pulsar_listo() -> void:
	var yo: Vector2i = pos_local()
	if yo.x < 0:
		return
	if red_activa:
		_red_cmd(&"listo", not bool((equipos[yo.x][yo.y] as Dictionary)["listo"]), null)
		return
	var h: Dictionary = equipos[yo.x][yo.y]
	h["listo"] = not bool(h["listo"])
	_refrescar()
	var c: Vector2i = contador_listos()
	if c.y > 0 and c.x == c.y:
		var cfg: ConfigPartida = config()
		h["listo"] = false
		_refrescar()
		iniciar.emit(cfg)


# ------------------------------------------------------------------ refresco de la interfaz

func _actualizar_modo() -> void:
	var libre: bool = modo_id() == ConfigPartida.M_LIBRE
	for f: Control in _filas_comp:
		f.visible = not libre
	for p: Control in _paneles_equipo:
		p.visible = not libre
	_panel_libre.visible = libre
	if libre:
		_descripcion.text = "Libre: todo el campus, sin rondas ni equipos. Esc abre la tienda."
	else:
		_al_elegir_zona(_zona.selected)
	_refrescar()


func modo_id() -> StringName:
	return ConfigPartida.MODOS[_modo.selected][0]


func poner_modo(id: StringName) -> void:
	for i in ConfigPartida.MODOS.size():
		if ConfigPartida.MODOS[i][0] == id:
			_modo.select(i)
	_actualizar_modo()


func _al_elegir_zona(i: int) -> void:
	if _ids_zona.is_empty() or modo_id() == ConfigPartida.M_LIBRE:
		return
	var id: String = _ids_zona[clampi(i, 0, _ids_zona.size() - 1)]
	var modo_txt: String = "Gana el equipo que elimina al otro; si se acaba el tiempo, los defensores." if modo_id() == ConfigPartida.M_PLENO \
			else "Los atacantes montan la Cachimba en un site; los defensores la apagan."
	_descripcion.text = "%s\n%s" % [str(ZonaActiva.datos_de(id).get("descripcion", "")), modo_txt]
	zona_elegida.emit(id)


func _refrescar() -> void:
	if _boton_listo == null:
		return
	var yo: Vector2i = pos_local()
	for g in 2:
		EstiloUI.vaciar(_flujos[g])
		var lista: Array = equipos[g]
		for i in lista.size():
			_flujos[g].add_child(_tarjeta(g, i, lista[i]))
	var id_yo: StringName = perfil["personaje"]
	_retrato_yo.texture = _retratos.textura(id_yo)
	_nombre_pers.text = str(CatalogoPersonajes.por_id(id_yo)["nombre"])
	var c: Vector2i = contador_listos()
	var listo: bool = yo.x >= 0 and bool((equipos[yo.x][yo.y] as Dictionary)["listo"])
	_boton_listo.text = ("ESPERANDO…  %d/%d" if listo else "LISTO  %d/%d") % [c.x, c.y]
	var color: Color = Color(0.35, 0.8, 0.45) if listo else Color(0.98, 0.84, 0.25)
	for estado: String in ["normal", "hover", "pressed"]:
		_boton_listo.add_theme_stylebox_override(estado, EstiloUI.caja(color.lightened(0.15) if estado == "hover" else color, Color(0, 0, 0, 0.5), 2, 10, 8))
	_boton_listo.add_theme_color_override("font_color", Color(0.1, 0.1, 0.12))
	_boton_listo.add_theme_color_override("font_hover_color", Color(0.1, 0.1, 0.12))
	_boton_listo.add_theme_color_override("font_pressed_color", Color(0.1, 0.1, 0.12))


func _tarjeta(g: int, i: int, h: Dictionary) -> Control:
	var es_bot: bool = h["tipo"] == ConfigPartida.TIPO_BOT
	var local: bool = bool(h["local"])
	var p := PanelContainer.new()
	p.custom_minimum_size = TAM_TARJETA
	var borde: Color = EstiloUI.ORO if local else (Color(0, 0, 0, 0.35))
	p.add_theme_stylebox_override("panel", EstiloUI.caja(COLOR_RETRATO, borde, 4 if local else 1, 10, 2))
	var foto := TextureRect.new()
	foto.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	foto.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	foto.texture = _retratos.textura(&"_bot" if es_bot else StringName(h["personaje"]))
	foto.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(foto)
	var texto := Label.new()
	texto.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if es_bot:
		texto.text = "BOT"
		texto.add_theme_font_size_override("font_size", 34)
		texto.add_theme_color_override("font_color", Color(0.08, 0.09, 0.12))
		texto.add_theme_constant_override("outline_size", 8)
		texto.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.85))
		texto.set_anchors_preset(Control.PRESET_FULL_RECT)
		texto.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		texto.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		p.add_child(texto)
		p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		p.tooltip_text = "Cambiarte a este hueco"
		p.gui_input.connect(func(e: InputEvent) -> void:
			var mb := e as InputEventMouseButton
			if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				clic_hueco(g, i))
	else:
		var nombre: String = _nombre_local() if local else str(h["nombre"])
		texto.text = nombre
		texto.add_theme_font_size_override("font_size", 15)
		texto.add_theme_color_override("font_color", Color(1, 1, 1))
		texto.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		texto.clip_text = true
		texto.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var franja := PanelContainer.new()
		franja.mouse_filter = Control.MOUSE_FILTER_IGNORE
		franja.size_flags_vertical = Control.SIZE_SHRINK_END
		franja.add_theme_stylebox_override("panel", EstiloUI.caja(Color(0, 0, 0, 0.6), Color(0, 0, 0, 0), 0, 5, 2))
		franja.add_child(texto)
		p.add_child(franja)
		if bool(h["listo"]):
			p.add_theme_stylebox_override("panel", EstiloUI.caja(COLOR_RETRATO, EstiloUI.BUENO, 4, 10, 2))
	return p


# ------------------------------------------------------------------ configuracion

## Config con lo elegido en el lobby (huecos incluidos; los bots reciben su personaje al azar con la semilla).
func config() -> ConfigPartida:
	var c := ConfigPartida.new()
	c.aplicar_modo(modo_id())
	c.zona = _ids_zona[_zona.selected] if not _ids_zona.is_empty() else "plaza_america"
	var a: String = _nombres_equipo[0].text.strip_edges()
	var d: String = _nombres_equipo[1].text.strip_edges()
	c.nombres = [a if a != "" else "EPS", d if d != "" else "CEUPO"]
	c.jugadores_por_equipo = tam_equipos()
	c.grupo_jugador = maxi(grupo_jugador(), 0)
	c.dificultad = DificultadBot.TODAS[_dificultad.selected]
	c.rondas_ganar = int(_rondas.value)
	c.bots_libres = int(_bots_libres.value)
	c.semilla = int(Time.get_ticks_msec() % 100000)
	c.nombre_jugador = _nombre_local()
	c.personaje_jugador = perfil["personaje"]
	var h: Array = [[], []]
	for g in 2:
		for s: Dictionary in equipos[g]:
			var copia: Dictionary = s.duplicate()
			if copia["local"]:
				copia["nombre"] = c.nombre_jugador
			h[g].append(copia)
	c.huecos = h
	c.huecos = c.huecos_efectivos()
	return c
