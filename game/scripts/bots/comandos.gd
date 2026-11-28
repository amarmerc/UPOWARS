class_name Comandos
extends RefCounted
## Contrato de acciones de un combatiente (jugador o bot). La IA del bot SOLO actua a traves de estos comandos, de modo que la
## Partida (P4) y el jugador puedan usar la misma API: `ComandosBot` la implementa para los bots; un futuro `ComandosJugador`
## la implementaria sobre `Jugador` / `GestorArmas` (que ya tienen cambiar_arma, recargar, recoger, equipar...) sin tocar
## `player.gd` ahora. Las acciones sostenidas (mirar, disparar, montar, apagar) se repiten cada tick mientras se quieren; las de
## movimiento persisten hasta `detener()` o llegar.

func mover_hacia(_destino: Vector3, _velocidad_rel: float = 1.0) -> void:
	_no_implementado("mover_hacia")


func detener() -> void:
	_no_implementado("detener")


## Mira a un punto del mundo. `con_error` aplica el error de punteria de la dificultad (solo al apuntar a un enemigo).
func mirar_punto(_punto: Vector3, _con_error: bool = false) -> void:
	_no_implementado("mirar_punto")


## Mantiene (true) o suelta (false) el gatillo este tick. Dispara siempre por `Balistica`.
func disparar(_activo: bool) -> void:
	_no_implementado("disparar")


func recargar() -> void:
	_no_implementado("recargar")


## Cambia al hueco 0 principal, 1 secundaria, 2 cuerpo a cuerpo.
func cambiar_arma(_hueco: int) -> void:
	_no_implementado("cambiar_arma")


## Lanza una utilidad del inventario hacia `objetivo`. Devuelve false si no la tiene o no puede.
func lanzar_utilidad(_id: StringName, _objetivo: Vector3, _fuerte: bool = true) -> bool:
	_no_implementado("lanzar_utilidad")
	return false


## Compra un articulo a la Partida (valida dinero e inventario). Devuelve false si no se pudo.
func comprar(_id: StringName) -> bool:
	_no_implementado("comprar")
	return false


## Monta (true) la Cachimba: hay que repetirlo cada tick durante los 4 s, quieto dentro de un site. Soltar cancela.
func montar_cachimba(_activo: bool) -> void:
	_no_implementado("montar_cachimba")


## Apaga (true) la Cachimba: hay que repetirlo cada tick durante los 7 s, quieto junto a ella.
func apagar_cachimba(_activo: bool) -> void:
	_no_implementado("apagar_cachimba")


func recoger_arma(_arma: ArmaSuelo) -> bool:
	_no_implementado("recoger_arma")
	return false


func tirar_arma() -> bool:
	_no_implementado("tirar_arma")
	return false


## Vende (devuelve) un articulo comprado en esta fase de compra. Devuelve false si no se pudo.
func vender(_id: StringName) -> bool:
	_no_implementado("vender")
	return false


func _no_implementado(nombre: String) -> void:
	push_warning("Comandos.%s no esta implementado en esta clase" % nombre)
