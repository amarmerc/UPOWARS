class_name Salud
extends Node
## Vida y escudo (0 a 50) de un combatiente (jugador, diana, bot). Es un nodo hijo del dueno.
## El escudo absorbe parte del dano segun la penetracion del arma: a la vida llega `dano * penetracion`; el resto lo
## absorbe el escudo a razon de 2 puntos de dano por punto de escudo; si el escudo no basta, el sobrante pasa a la vida.
## Equipos: `equipo` 0 = sin equipo (todos contra todos); con equipo, el fuego amigo esta desactivado por defecto
## (`Salud.fuego_amigo`), salvo el autodano (un explosivo propio si hace dano al lanzador).

signal herido(cantidad: float, zona: String, atacante: Node)
signal muerto(atacante: Node, arma: ArmaDatos)

const ESCUDO_MAX: float = 50.0

## Configurable: si es verdadero los companeros de equipo se hacen dano.
static var fuego_amigo: bool = false

@export var vida_max: float = 100.0
@export_range(0.0, 50.0) var escudo_inicial: float = 0.0
@export var equipo: int = 0
## Nombre para el kill feed y las marcas (por defecto, el nombre del nodo dueno).
@export var nombre: String = ""

var vida: float = 100.0
var escudo: float = 0.0
var vivo: bool = true
## equipo_marcador -> segundos restantes (bote de pintura).
var marcas: Dictionary = {}
## Opcional: Callable(direccion_del_disparo: Vector3) -> bool. Si devuelve true el golpe se bloquea (sable).
var bloqueo: Callable = Callable()

## Alias historico del escudo (la armadura paso a llamarse escudo).
var armadura: float:
	get:
		return escudo
	set(v):
		escudo = clampf(v, 0.0, ESCUDO_MAX)
var armadura_inicial: float:
	get:
		return escudo_inicial
	set(v):
		escudo_inicial = clampf(v, 0.0, ESCUDO_MAX)


func _ready() -> void:
	add_to_group("salud")
	reiniciar()


func _process(delta: float) -> void:
	avanzar(delta)


## Avanza `delta` s las marcas de pintura (separado para poder simular el tiempo en tests).
func avanzar(delta: float) -> void:
	if marcas.is_empty():
		return
	for k: Variant in marcas.keys():
		marcas[k] = float(marcas[k]) - delta
		if float(marcas[k]) <= 0.0:
			marcas.erase(k)


func reiniciar() -> void:
	vida = vida_max
	escudo = clampf(escudo_inicial, 0.0, ESCUDO_MAX)
	vivo = true
	marcas.clear()


func nombre_visible() -> String:
	if nombre != "":
		return nombre
	return str(get_parent().name) if get_parent() != null else str(name)


## Salud del nodo dado (o el propio nodo si ya es una Salud).
static func de(nodo: Node) -> Salud:
	if nodo == null:
		return null
	if nodo is Salud:
		return nodo as Salud
	var ss: Array[Node] = nodo.find_children("*", "Salud", false, false)
	return ss[0] as Salud if not ss.is_empty() else null


## Verdadero si `atacante` es companero de equipo (y no el mismo) y el fuego amigo esta desactivado.
func protege_de(atacante: Node) -> bool:
	if fuego_amigo or equipo == 0 or atacante == null:
		return false
	var sa: Salud = Salud.de(atacante)
	return sa != null and sa != self and sa.equipo == equipo


func marcar(equipo_marcador: int, segundos: float) -> void:
	marcas[equipo_marcador] = maxf(float(marcas.get(equipo_marcador, 0.0)), segundos)


func marcado_para(equipo_observador: int) -> bool:
	return vivo and float(marcas.get(equipo_observador, 0.0)) > 0.0


## Consulta del bloqueo (sable): true si el golpe que viaja en `direccion` se detiene.
func intenta_bloquear(direccion: Vector3) -> bool:
	return bloqueo.is_valid() and bool(bloqueo.call(direccion))


## Aplica un golpe. Devuelve el dano que ha llegado a la vida.
func recibir_dano(cantidad: float, zona: String = "torso", penetracion: float = 1.0, atacante: Node = null,
		arma: ArmaDatos = null) -> float:
	if not vivo or cantidad <= 0.0 or protege_de(atacante):
		return 0.0
	var a_vida: float = cantidad
	if escudo > 0.0:
		a_vida = cantidad * penetracion
		var a_escudo: float = (cantidad - a_vida) * 0.5
		if escudo >= a_escudo:
			escudo -= a_escudo
		else:
			a_vida += (a_escudo - escudo) * 2.0
			escudo = 0.0
	a_vida = minf(a_vida, vida)
	vida -= a_vida
	herido.emit(a_vida, zona, atacante)
	if vida <= 0.0:
		vida = 0.0
		vivo = false
		muerto.emit(atacante, arma)
		if is_inside_tree():
			SenalesCombate.obtener(get_tree()).baja.emit(atacante, self, arma)
	return a_vida
