class_name Armero
extends CanvasLayer
## Armero de pruebas (F6): equipa cualquier arma, utilidad o escudo del catalogo sin tienda ni dinero, hasta que exista la tienda
## de la Partida (P4). Es un hijo del GestorArmas. `abrir()` / `cerrar()` tambien se pueden llamar desde codigo.

var _gestor: GestorArmas
var _jugador: Jugador
var _panel: PanelContainer
var _aviso: Label


func _init() -> void:
	layer = 20
	visible = false


func vincular(gestor: GestorArmas, jugador: Jugador) -> void:
	_gestor = gestor
	_jugador = jugador
	_construir()


func _construir() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(760, 0)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_panel)
	var margen := MarginContainer.new()
	for lado: String in ["left", "right", "top", "bottom"]:
		margen.add_theme_constant_override("margin_" + lado, 14)
	_panel.add_child(margen)
	var caja := VBoxContainer.new()
	margen.add_child(caja)
	var titulo := Label.new()
	titulo.text = "ARMERO DE PRUEBAS  (F6 para cerrar)"
	titulo.add_theme_font_size_override("font_size", 20)
	caja.add_child(titulo)
	var nombres: Dictionary = {"secundaria": "Secundarias", "principal": "Principales", "especial": "Especiales",
			"utilidad": "Utilidades (max. 2 de cada, 4 en total)", "escudo": "Escudo"}
	for cat: String in Catalogo.CATEGORIAS:
		var l := Label.new()
		l.text = nombres[cat]
		l.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
		caja.add_child(l)
		var rejilla := GridContainer.new()
		rejilla.columns = 4
		caja.add_child(rejilla)
		for it: Dictionary in Catalogo.por_categoria(cat):
			var b := Button.new()
			b.text = str(it["nombre"])
			b.tooltip_text = "%s (%d)" % [it["descripcion"], int(it["precio"])]
			b.focus_mode = Control.FOCUS_NONE
			b.pressed.connect(_equipar.bind(StringName(it["id"])))
			rejilla.add_child(b)
	var fila := HBoxContainer.new()
	caja.add_child(fila)
	for par: Array in [["Municion llena", _gestor.reponer_municion], ["Reiniciar inventario", _gestor.reiniciar],
			["Vida y escudo", _curar]]:
		var b2 := Button.new()
		b2.text = par[0]
		b2.focus_mode = Control.FOCUS_NONE
		b2.pressed.connect(par[1])
		fila.add_child(b2)
	_aviso = Label.new()
	caja.add_child(_aviso)


func _curar() -> void:
	_jugador.salud.vida = _jugador.salud.vida_max
	_jugador.salud.escudo = _jugador.gestor.inventario.escudo


func _equipar(id: StringName) -> void:
	var ok: bool = _gestor.equipar(id)
	_aviso.text = ("Equipado: %s" if ok else "No se puede equipar: %s (limite de utilidades)") % str(Catalogo.info(id)["nombre"])


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("armero") and _jugador != null:
		if visible:
			cerrar()
			get_viewport().set_input_as_handled()
		elif _jugador.activo and not _jugador.muerto:
			abrir()
			get_viewport().set_input_as_handled()


func abrir() -> void:
	visible = true
	_jugador.activo = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func cerrar() -> void:
	visible = false
	_jugador.activo = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
