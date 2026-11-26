extends CanvasLayer
## Selector de punto de aparición: un botón por spawn.

signal spawn_elegido(datos: Dictionary)

@onready var _botones: VBoxContainer = $Fondo/Centro/Caja/Botones


func cargar(spawns: Array) -> void:
	for h: Node in _botones.get_children():
		h.queue_free()
	for s: Dictionary in spawns:
		var b := Button.new()
		b.text = str(s["nombre"])
		b.custom_minimum_size = Vector2(420, 44)
		b.pressed.connect(func() -> void: spawn_elegido.emit(s))
		_botones.add_child(b)


func abrir() -> void:
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func cerrar() -> void:
	visible = false
