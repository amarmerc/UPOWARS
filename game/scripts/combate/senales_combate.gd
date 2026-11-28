class_name SenalesCombate
extends Node
## Bus global de senales del combate (un unico nodo colgado de la raiz). Lo usan los bots (oyen `ruido`), el kill feed del
## HUD (`baja`) y cualquier sistema que quiera enterarse sin acoplarse a quien dispara.
## `ruido(posicion, radio, fuente)`: un disparo, un paso o un altavoz senuelo.
## `baja(atacante, victima, arma)`: una Salud ha llegado a 0.

signal ruido(posicion: Vector3, radio: float, fuente: Node)
signal baja(atacante: Node, victima: Salud, arma: ArmaDatos)

static var _instancia: SenalesCombate = null


static func obtener(arbol: SceneTree) -> SenalesCombate:
	if _instancia == null or not is_instance_valid(_instancia):
		_instancia = SenalesCombate.new()
		_instancia.name = "SenalesCombate"
		arbol.root.add_child.call_deferred(_instancia)  # la raiz puede estar ocupada cargando la escena principal
	return _instancia
