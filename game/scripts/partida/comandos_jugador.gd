class_name ComandosJugador
extends Comandos
## `Comandos` del jugador humano: la misma API que usan los bots, implementada sobre `Jugador` / `GestorArmas` y la `Partida`.
## El movimiento, la mirada y el disparo del jugador los lleva la entrada (teclado y raton) del propio `Jugador`, asi que aqui
## solo estan las acciones de partida (comprar, vender, montar, apagar) y las de inventario (cambiar, recargar, recoger, tirar).

var jugador: Jugador
var partida: ApiPartida


func _init(jugador_propio: Jugador, partida_api: ApiPartida) -> void:
	jugador = jugador_propio
	partida = partida_api


func comprar(id: StringName) -> bool:
	return partida.comprar(jugador, id)


func vender(id: StringName) -> bool:
	return partida.vender(jugador, id)


func montar_cachimba(activo: bool) -> void:
	partida.montar_cachimba(jugador, activo)


func apagar_cachimba(activo: bool) -> void:
	partida.apagar_cachimba(jugador, activo)


func cambiar_arma(hueco: int) -> void:
	jugador.gestor.cambiar_arma(hueco)


func recargar() -> void:
	jugador.gestor.recargar()


func recoger_arma(arma: ArmaSuelo) -> bool:
	return jugador.gestor.recoger(arma)


func tirar_arma() -> bool:
	return jugador.gestor.tirar_arma()
