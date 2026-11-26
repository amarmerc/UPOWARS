class_name Salud
extends Node
## Vida y armadura de un combatiente (jugador, diana, bot). Es un nodo hijo del dueno.
## La armadura absorbe parte del dano segun la penetracion del arma: a la vida llega
## `dano * penetracion`; el resto (`dano * (1 - penetracion)`) lo absorbe la armadura a razon de 2 puntos de dano por
## punto de armadura. Si la armadura no basta, el sobrante pasa a la vida.

signal herido(cantidad: float, zona: String, atacante: Node)
signal muerto(atacante: Node)

@export var vida_max: float = 100.0
@export_range(0.0, 100.0) var armadura_inicial: float = 0.0

var vida: float = 100.0
var armadura: float = 0.0
var vivo: bool = true


func _ready() -> void:
	reiniciar()


func reiniciar() -> void:
	vida = vida_max
	armadura = armadura_inicial
	vivo = true


## Aplica un golpe. Devuelve el dano que ha llegado a la vida.
func recibir_dano(cantidad: float, zona: String = "torso", penetracion: float = 1.0, atacante: Node = null) -> float:
	if not vivo or cantidad <= 0.0:
		return 0.0
	var a_vida: float = cantidad
	if armadura > 0.0:
		a_vida = cantidad * penetracion
		var a_armadura: float = (cantidad - a_vida) * 0.5
		if armadura >= a_armadura:
			armadura -= a_armadura
		else:
			a_vida += (a_armadura - armadura) * 2.0
			armadura = 0.0
	a_vida = minf(a_vida, vida)
	vida -= a_vida
	herido.emit(a_vida, zona, atacante)
	if vida <= 0.0:
		vida = 0.0
		vivo = false
		muerto.emit(atacante)
	return a_vida
