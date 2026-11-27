class_name EstiloUI
extends RefCounted
## Estilo comun de los menus de UPOWARS (lobby, tienda, pausa): paleta propia (azul noche y naranja albero) y helpers para
## construir controles desde codigo.

const FONDO := Color(0.05, 0.07, 0.11, 0.94)
const PANEL := Color(0.09, 0.12, 0.18, 0.97)
const TARJETA := Color(0.12, 0.16, 0.24, 1.0)
const ACENTO := Color(1.0, 0.62, 0.15)
const ACENTO2 := Color(0.3, 0.78, 1.0)
const TEXTO := Color(0.93, 0.95, 0.98)
const TEXTO_SUAVE := Color(0.62, 0.7, 0.8)
const BUENO := Color(0.4, 0.9, 0.5)
const MALO := Color(1.0, 0.35, 0.3)
const ORO := Color(1.0, 0.85, 0.3)


static func caja(color: Color, borde: Color = Color(0, 0, 0, 0), grosor: int = 0, radio: int = 6, margen: int = 10) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.border_color = borde
	sb.set_border_width_all(grosor)
	sb.set_corner_radius_all(radio)
	sb.set_content_margin_all(margen)
	return sb


static func etiqueta(texto: String, tam: int = 16, color: Color = TEXTO) -> Label:
	var l := Label.new()
	l.text = texto
	l.add_theme_font_size_override("font_size", tam)
	l.add_theme_color_override("font_color", color)
	return l


static func boton(texto: String, tam: int = 16) -> Button:
	var b := Button.new()
	b.text = texto
	b.add_theme_font_size_override("font_size", tam)
	b.add_theme_stylebox_override("normal", caja(Color(0.16, 0.22, 0.32), Color(0.3, 0.4, 0.55), 1, 5, 8))
	b.add_theme_stylebox_override("hover", caja(Color(0.22, 0.3, 0.44), ACENTO, 2, 5, 8))
	b.add_theme_stylebox_override("pressed", caja(Color(0.3, 0.2, 0.1), ACENTO, 2, 5, 8))
	b.add_theme_stylebox_override("disabled", caja(Color(0.1, 0.12, 0.16), Color(0.2, 0.24, 0.3), 1, 5, 8))
	b.add_theme_color_override("font_color", TEXTO)
	b.add_theme_color_override("font_disabled_color", Color(0.4, 0.45, 0.52))
	b.focus_mode = Control.FOCUS_NONE
	return b


static func vaciar(n: Node) -> void:
	for h: Node in n.get_children():
		n.remove_child(h)
		h.queue_free()
