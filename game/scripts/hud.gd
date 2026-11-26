extends CanvasLayer
## HUD mínimo: punto de mira y datos de depuración (spawn, posición, velocidad).

@onready var _info: Label = $Info


func actualizar(nombre: String, pos: Vector3, velocidad: float, vuelo: bool) -> void:
	_info.text = "%s%s\nx %.1f  y %.1f  z %.1f\nv %.2f m/s" % [
			nombre, "  [VUELO]" if vuelo else "", pos.x, pos.y, pos.z, velocidad]
