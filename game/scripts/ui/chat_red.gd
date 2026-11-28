class_name ChatRed
extends CanvasLayer
## Chat de texto simple de la partida en red: T abre la linea, Enter envia, Esc cierra. Los mensajes se desvanecen a los 8 s.
## `enviar(texto)` lo recoge quien tenga la red (ClienteRed o ServidorRed); `anadir()` recibe los mensajes del servidor.

signal enviar(texto: String)
signal abierto
signal cerrado

const MAX_LINEAS: int = 8
const VIDA_S: float = 8.0

var _caja: VBoxContainer
var _linea: LineEdit
var _vida: Array = []


func _init() -> void:
	layer = 8
	var raiz := Control.new()
	raiz.set_anchors_preset(Control.PRESET_FULL_RECT)
	raiz.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(raiz)
	_caja = VBoxContainer.new()
	_caja.position = Vector2(16, 300)
	_caja.custom_minimum_size = Vector2(520, 0)
	_caja.mouse_filter = Control.MOUSE_FILTER_IGNORE
	raiz.add_child(_caja)
	_linea = LineEdit.new()
	_linea.position = Vector2(16, 520)
	_linea.custom_minimum_size = Vector2(520, 30)
	_linea.max_length = ServidorRed.MAX_CHAT
	_linea.placeholder_text = "Mensaje (Enter envia, Esc cancela)"
	_linea.visible = false
	_linea.text_submitted.connect(_al_enviar)
	raiz.add_child(_linea)
	visible = false


func esta_abierto() -> bool:
	return _linea.visible


func abrir() -> void:
	visible = true
	_linea.visible = true
	_linea.text = ""
	_linea.grab_focus()
	abierto.emit()


func cerrar() -> void:
	_linea.visible = false
	_linea.release_focus()
	cerrado.emit()


func _al_enviar(t: String) -> void:
	if t.strip_edges() != "":
		enviar.emit(t)
	cerrar()


func _input(event: InputEvent) -> void:
	if _linea.visible and event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		cerrar()


func anadir(de: String, g: int, texto: String) -> void:
	visible = true
	var l := Label.new()
	l.text = ("%s: %s" % [de, texto]) if de != "" else texto
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", [Color(1.0, 0.7, 0.35), Color(0.45, 0.7, 1.0)][g] if g >= 0 and g < 2 else Color(0.9, 0.9, 0.9))
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_caja.add_child(l)
	_vida.append([l, VIDA_S])
	while _caja.get_child_count() > MAX_LINEAS:
		var v: Node = _caja.get_child(0)
		_vida = _vida.filter(func(x: Array) -> bool: return x[0] != v)
		v.queue_free()
		_caja.remove_child(v)


func _process(delta: float) -> void:
	for x: Array in _vida:
		x[1] = float(x[1]) - delta
		(x[0] as Label).modulate.a = 1.0 if _linea.visible else clampf(float(x[1]), 0.0, 1.0)
