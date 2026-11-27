class_name ApiPartida
extends Node
## Interfaz que la `Partida` (P4) ofrece a los combatientes: la API de comandos que valida y aplica sobre el estado autoritativo.
## Los bots (`ComandosBot`) la usan para comprar, montar y apagar la Cachimba; el jugador usara la misma. `PartidaPrueba` es una
## implementacion minima (sin rondas ni economia) para probar los bots; P4 hereda de esta clase (o la implementa con los mismos
## metodos). Un combatiente es el nodo dueno de la `Salud` (Bot o Jugador).

## Modo de juego: &"cachimba", &"eliminacion" o &"libre".
func modo() -> StringName:
	return &"libre"


## Zona competitiva activa (null en el modo libre).
func zona() -> ZonaActiva:
	return null


## Cachimba de la ronda (null si el modo no la usa).
func cachimba() -> Cachimba:
	return null


## Dinero del combatiente (muy grande = infinito).
func dinero_de(_combatiente: Node) -> int:
	return 1 << 30


## Compra `id` descontando el dinero y equipando. false si no llega, no cabe o la fase de compra ha acabado.
func comprar(_combatiente: Node, _id: StringName) -> bool:
	return false


## Orden sostenida de montar (activo) o cancelar la Cachimba; valida equipo, site y que este quieto.
func montar_cachimba(_combatiente: Node, _activo: bool) -> void:
	pass


## Orden sostenida de apagar la Cachimba; valida equipo, cercania y que este quieto.
func apagar_cachimba(_combatiente: Node, _activo: bool) -> void:
	pass


## Vende (devuelve con reembolso completo) un articulo comprado en la fase de compra actual.
func vender(_combatiente: Node, _id: StringName) -> bool:
	return false


## true si ahora se puede comprar (fase de compra, o modo libre).
func fase_compra() -> bool:
	return true


## true si en este modo solo el portador de la Cachimba puede montarla (la `Partida`; `PartidaPrueba` deja montar a cualquier atacante).
func exige_portador() -> bool:
	return false


## Combatiente que lleva la Cachimba (null si nadie la lleva, o el modo no usa portador).
func portador_cachimba() -> Node:
	return null


## Nodo 3D de la Cachimba caida al suelo (murio el portador): hay que recogerla. null si no hay.
func cachimba_caida() -> Node3D:
	return null
