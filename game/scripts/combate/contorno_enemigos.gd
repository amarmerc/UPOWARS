class_name ContornoEnemigos
extends Node3D
## Contorno de color (estilo Valorant) en los enemigos que el jugador VE de verdad, y nombres de los aliados solo cuando toca.
##
## Cada enemigo vivo se revisa cada `PERIODO` fotogramas (con desfase por bot, asi que con 10 personajes son ~3 comprobaciones por
## fotograma): si la camara ve su cabeza o su torso (`Utilidades.linea_de_vision`: pared, prop, tronco y humo/extintor tapan) se pone el
## `material_overlay` de contorno en las mallas del personaje; si no, se quita. El shader (`contorno_enemigo.gdshader`) es un inverted
## hull con prueba de profundidad, de modo que tampoco se dibuja a traves de nada por delante. Los enemigos no llevan etiqueta de
## nombre. Los aliados enseñan un nombre pequeño solo a menos de `DIST_NOMBRE_M`, o al apuntarles, o siempre (con vista despejada) si
## se esta espectando.
## Quien ve: la camara activa; si es la del jugador, su equipo; si es la de un companero espectado, el de ese bot; si no hay ninguno
## cerca (lobby), no se contornea a nadie. Equipo 0 (modo libre) = todos enemigos entre si.

const PERIODO: int = 3
const DIST_NOMBRE_M: float = 14.0
const DIST_MAX_CONTORNO_M: float = 250.0
const COS_APUNTAR: float = 0.997
const RUTA_SHADER: String = "res://shaders/contorno_enemigo.gdshader"

var jugador: Jugador = null
## Si es falso no se contornea a nadie (opcion / pruebas).
var activo: bool = true
var material: ShaderMaterial
var contornos_puestos: int = 0
var _marco: int = 0
var _estado: Dictionary = {}   # Bot -> bool (contorno puesto)


func _ready() -> void:
	material = ShaderMaterial.new()
	material.shader = load(RUTA_SHADER) as Shader


## Crea (una vez) el controlador bajo `ctx` y lo enlaza con el jugador.
static func asegurar(ctx: Node, jug: Jugador) -> ContornoEnemigos:
	var c: ContornoEnemigos = ctx.get_node_or_null("ContornoEnemigos") as ContornoEnemigos
	if c == null:
		c = ContornoEnemigos.new()
		c.name = "ContornoEnemigos"
		ctx.add_child(c)
	c.jugador = jug
	return c


func _process(_delta: float) -> void:
	_marco += 1
	if _marco % 240 == 0:
		for k: Variant in _estado.keys():
			if not is_instance_valid(k):
				_estado.erase(k)
	if jugador == null:
		return
	var cam: Camera3D = get_viewport().get_camera_3d()
	var bots: Array[Node] = get_tree().get_nodes_in_group("bots")
	if cam == null or bots.is_empty():
		return
	var equipo_vista: int = -1
	var espectando: bool = false
	if cam == jugador.camara:
		equipo_vista = jugador.salud.equipo
	else:
		var mejor: float = 1.5
		for n: Node in bots:
			var b0: Bot = n as Bot
			if b0 != null and not b0.muerto:
				var d0: float = b0.ojos().distance_to(cam.global_position)
				if d0 < mejor:
					mejor = d0
					equipo_vista = b0.equipo
					espectando = true
	var i: int = 0
	for n: Node in bots:
		var b: Bot = n as Bot
		if b == null:
			continue
		i += 1
		if b.muerto or equipo_vista < 0:
			_poner(b, false)
			_etiqueta(b, false)
			continue
		var enemigo: bool = b.equipo == 0 or b.equipo != equipo_vista
		if (i + _marco) % PERIODO != 0:
			continue
		var origen: Vector3 = cam.global_position
		var dist: float = origen.distance_to(b.global_position)
		var visible_: bool = false
		if dist < DIST_MAX_CONTORNO_M and not b.global_position.is_equal_approx(origen) and not cam.is_position_behind(b.global_position + Vector3(0, 1.0, 0)):
			visible_ = Utilidades.linea_de_vision(self, origen, b.global_position + Vector3(0, 1.6, 0)) \
					or Utilidades.linea_de_vision(self, origen, b.global_position + Vector3(0, 1.1, 0))
		if enemigo:
			_poner(b, visible_ and activo)
			_etiqueta(b, false)
		else:
			_poner(b, false)
			var cerca: bool = dist < DIST_NOMBRE_M
			var apuntado: bool = visible_ and (-cam.global_transform.basis.z).dot((b.global_position + Vector3(0, 1.2, 0) - origen).normalized()) > COS_APUNTAR
			_etiqueta(b, visible_ and (cerca or apuntado or espectando))


## Activa / desactiva el contorno de las mallas de un bot.
func _poner(b: Bot, on: bool) -> void:
	if bool(_estado.get(b, false)) == on:
		return
	_estado[b] = on
	contornos_puestos += 1 if on else 0
	b.fijar_contorno(material if on else null)


func _etiqueta(b: Bot, on: bool) -> void:
	b.mostrar_etiqueta(on)
