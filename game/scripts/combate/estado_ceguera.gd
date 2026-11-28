class_name EstadoCeguera
extends Node
## Ceguera de un combatiente (granada cegadora). Se cuelga como hijo del jugador, de un bot o de una diana.
## `nivel()` va de 0 a 1: total durante la primera parte y luego se desvanece. Los bots lo usan para perder punteria
## (`error_punteria()` = grados extra de dispersion) y el HUD del jugador para el destello blanco.

var nivel_max: float = 0.0
var restante: float = 0.0
var total: float = 0.0


func _ready() -> void:
	add_to_group("cegables")


func _process(delta: float) -> void:
	avanzar(delta)


func avanzar(delta: float) -> void:
	restante = maxf(restante - delta, 0.0)
	if restante <= 0.0:
		nivel_max = 0.0


## Ciega con `nivel` (0-1) durante `segundos`; no reduce una ceguera mas fuerte que ya este activa.
func cegar(nivel_nuevo: float, segundos: float) -> void:
	if nivel_nuevo >= nivel():
		nivel_max = clampf(nivel_nuevo, 0.0, 1.0)
		total = maxf(segundos, 0.01)
		restante = total


func nivel() -> float:
	if restante <= 0.0:
		return 0.0
	return nivel_max * clampf(restante / (total * 0.45), 0.0, 1.0)


func error_punteria() -> float:
	return nivel() * Balistica.DISPERSION_CEGUERA


## Posicion de los ojos del dueno (camara si es el jugador).
func ojos() -> Vector3:
	var p: Node = get_parent()
	if p is Jugador:
		return (p as Jugador).camara.global_position
	if p is Node3D:
		return (p as Node3D).global_position + Vector3(0.0, 1.6, 0.0)
	return Vector3.ZERO


## Direccion de la mirada del dueno.
func mirada() -> Vector3:
	var p: Node = get_parent()
	if p is Jugador:
		return -(p as Jugador).camara.global_transform.basis.z
	if p is Node3D:
		return -(p as Node3D).global_transform.basis.z
	return Vector3.FORWARD
