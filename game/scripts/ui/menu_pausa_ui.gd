class_name MenuPausaUI
extends CanvasLayer
## Menu de pausa del modo competitivo (Esc): solo Reanudar, Volver al lobby y Salir del juego. La tienda NO se abre desde aqui.

signal reanudar
signal volver_lobby
signal salir_juego


func _init() -> void:
	layer = 25
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	var raiz := Control.new()
	raiz.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(raiz)
	var fondo := ColorRect.new()
	fondo.color = Color(0, 0, 0, 0.6)
	fondo.set_anchors_preset(Control.PRESET_FULL_RECT)
	raiz.add_child(fondo)
	var centro := CenterContainer.new()
	centro.set_anchors_preset(Control.PRESET_FULL_RECT)
	raiz.add_child(centro)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(360, 0)
	panel.add_theme_stylebox_override("panel", EstiloUI.caja(EstiloUI.PANEL, EstiloUI.ACENTO, 2, 12, 22))
	centro.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	v.add_child(EstiloUI.etiqueta("PAUSA", 32, EstiloUI.ACENTO))
	var datos: Array = [["Reanudar", reanudar], ["Volver al lobby", volver_lobby], ["Salir del juego", salir_juego]]
	if OS.has_feature("web"):      # en el navegador no se puede cerrar el juego
		datos.pop_back()
	for d: Array in datos:
		var b: Button = EstiloUI.boton(str(d[0]), 20)
		var sen: Signal = d[1]
		b.pressed.connect(func() -> void: sen.emit())
		v.add_child(b)


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		reanudar.emit()
		get_viewport().set_input_as_handled()
