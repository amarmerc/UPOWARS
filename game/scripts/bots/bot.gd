class_name Bot
extends CharacterBody3D
## Bot jugable: CharacterBody3D (capa 3 "cuerpo", mascara 1 "mundo") con los MISMOS componentes de combate que el jugador: `Salud`
## (vida, escudo, equipo), `Hitboxes` (cabeza / torso / piernas en la capa 2), `Inventario` (via `ArmasBot`), `EstadoCeguera`, y
## disparo solo por `Balistica`. Es un cuerpo ciego: sus decisiones las toma `CerebroBot` y las ejecuta a traves de `ComandosBot`
## (la API de comandos que comparten jugador y Partida). Origen en los pies; mira hacia -Z. Los ojos estan a 1,6 m.
## Crear con `Bot.crear(...)` y anadir al arbol; `avanzar(dt)` lo llama `_physics_process` (los tests ponen `entrada_manual = true`
## y lo llaman a mano).

signal murio(bot: Bot, atacante: Node)
signal reaparecido(bot: Bot)

const RUTA_ESCENA: String = "res://scenes/bot.tscn"
const EQ_ATACANTES: int = 1
const EQ_DEFENSORES: int = 2
const ROL_ATACANTE: StringName = &"atacante"
const ROL_DEFENSOR: StringName = &"defensor"
## Eliminacion: busca y caza al otro equipo.
const ROL_CAZADOR: StringName = &"cazador"
## Modo libre: deambula y combate.
const ROL_LIBRE: StringName = &"libre"
## Pruebas: no se mueve por iniciativa propia, solo combate lo que ve.
const ROL_ESTATICO: StringName = &"estatico"
const ALTURA_OJOS: float = 1.6
## Servidor dedicado sin pantalla: los bots no construyen modelo ni etiqueta (no hay nada que dibujar).
static var sin_visual: bool = false
const COLORES_EQUIPO: Dictionary = {
	0: Color(0.55, 0.78, 0.45), 1: Color(1.0, 0.48, 0.12), 2: Color(0.25, 0.6, 1.0), 3: Color(0.9, 0.3, 0.8), 4: Color(0.95, 0.9, 0.2),
}

@export var equipo: int = 0
@export var rol: StringName = &"libre"
@export var dificultad: StringName = &"normal"
@export var nombre: String = "Bot"
## Personaje (`CatalogoPersonajes`) que viste el cuerpo.
@export var personaje: StringName = &""
## Si es verdadero reaparece solo a los `tiempo_reaparicion` s (modo libre).
@export var reaparicion_auto: bool = false
@export var tiempo_reaparicion: float = 3.0

var perfil: Dictionary = {}
var rng := RandomNumberGenerator.new()
var partida: ApiPartida = null
var director: DirectorBots = null
var muerto: bool = false
var pitch: float = 0.0
var punto_reaparicion: Vector3 = Vector3.ZERO
var yaw_reaparicion: float = 0.0
## Si es verdadero `_physics_process` no avanza al bot (quien lo use llama a `avanzar`).
var entrada_manual: bool = false
## Fase de compra (Partida): el bot no actua (solo avanzan los temporizadores de sus armas).
var congelado: bool = false
var bajas: int = 0
var muertes: int = 0
var salud: Salud
var hitboxes: Hitboxes
var armas: ArmasBot
var cabeza: Node3D
var ceguera: EstadoCeguera
var comandos: ComandosBot
var cerebro: CerebroBot
## Red (servidor): este "bot" es el avatar de un jugador humano remoto. No lo gobierna la IA: `ServidorRed` lo mueve y dispara
## con las entradas del cliente (mismos componentes de combate que un bot: Salud, Hitboxes, ArmasBot, ceguera). Si el humano se
## desconecta, `humano_red = false` y el cerebro toma el control.
var humano_red: bool = false
var id_red: int = -1
var peer_red: int = 0

var _caida: Node3D
var _arma_mano: StringName = &"-"
var _mat_torso: StandardMaterial3D
var _etiqueta: Label3D
var _t_muerte: float = 0.0
var _colision: CollisionShape3D


## Crea un bot de la escena. Hay que anadirlo al arbol y colocarlo (`teletransportar`).
static func crear(nombre_bot: String, equipo_bot: int, rol_bot: StringName, dificultad_bot: StringName = &"normal",
		semilla: int = 0, partida_api: ApiPartida = null, personaje_id: StringName = &"") -> Bot:
	var b: Bot = (load(RUTA_ESCENA) as PackedScene).instantiate() as Bot
	b.nombre = nombre_bot
	b.name = nombre_bot.replace(" ", "_")
	b.equipo = equipo_bot
	b.rol = rol_bot
	b.dificultad = dificultad_bot
	b.perfil = DificultadBot.perfil(dificultad_bot)
	b.rng.seed = semilla if semilla != 0 else hash(nombre_bot)
	b.partida = partida_api
	# sin personaje asignado (escena de prueba): uno determinista por semilla / nombre
	b.personaje = personaje_id if CatalogoPersonajes.existe(personaje_id) else CatalogoPersonajes.ids()[absi(b.rng.seed) % CatalogoPersonajes.ids().size()]
	return b


func _ready() -> void:
	if perfil.is_empty():
		perfil = DificultadBot.perfil(dificultad)
	salud = $Salud
	hitboxes = $Hitboxes
	armas = $Armas
	cabeza = $Cabeza
	_colision = $Colision
	salud.equipo = equipo
	salud.nombre = nombre
	armas.bot = self
	armas.rng = rng
	ceguera = EstadoCeguera.new()
	ceguera.name = "Ceguera"
	add_child(ceguera)
	comandos = ComandosBot.new(self)
	cerebro = CerebroBot.new(self)
	salud.muerto.connect(_on_muerto)
	salud.herido.connect(_on_herido)
	var senales: SenalesCombate = SenalesCombate.obtener(get_tree())
	senales.ruido.connect(_on_ruido)
	senales.baja.connect(_on_baja)
	add_to_group("bots")
	_construir_visual()
	punto_reaparicion = global_position


func _physics_process(delta: float) -> void:
	if not entrada_manual:
		avanzar(delta)


## Un tick de simulacion: IA -> comandos (movimiento, mirada, disparo) -> temporizadores de las armas.
func avanzar(dt: float) -> void:
	if muerto:
		_procesar_muerte(dt)
		return
	armas.avanzar(dt)
	_actualizar_modelo()
	if humano_red:
		return
	if congelado:
		velocity = Vector3.ZERO
		return
	cerebro.avanzar(dt)
	comandos.ejecutar(dt)


## Animacion del cuerpo segun la velocidad y arma en la mano segun la que lleve activa.
func _actualizar_modelo() -> void:
	if _caida == null:
		return
	ModeloPersonaje.actualizar(_caida, velocidad_horizontal() if not congelado else 0.0)
	var id: StringName = armas.id_actual()
	if id != _arma_mano:
		_arma_mano = id
		ModeloPersonaje.poner_arma(_caida, id)


func ojos() -> Vector3:
	return cabeza.global_position


## Direccion en la que mira (con el pitch de la cabeza).
func mirada_dir() -> Vector3:
	return -cabeza.global_transform.basis.z


func velocidad_horizontal() -> float:
	return Vector2(velocity.x, velocity.z).length()


## Impulso (m/s) de explosiones, extintor, etc. (lo usa `Balistica.empujar`).
func aplicar_impulso(v: Vector3) -> void:
	if not muerto:
		velocity += v


## Coloca al bot (pos del juego, yaw en grados) y lo deja listo.
func teletransportar(pos: Vector3, yaw_deg: float) -> void:
	global_position = pos
	rotation = Vector3(0.0, deg_to_rad(yaw_deg), 0.0)
	pitch = 0.0
	if cabeza != null:
		cabeza.rotation = Vector3.ZERO
	velocity = Vector3.ZERO
	punto_reaparicion = pos
	yaw_reaparicion = yaw_deg
	if comandos != null:
		comandos.detener()


## Cambia de equipo y rol (cambio de lado de la Partida): actualiza la Salud y los colores.
func asignar_equipo(equipo_nuevo: int, rol_nuevo: StringName) -> void:
	equipo = equipo_nuevo
	rol = rol_nuevo
	if salud != null:
		salud.equipo = equipo_nuevo
	var color: Color = COLORES_EQUIPO.get(equipo_nuevo, Color(0.7, 0.7, 0.7))
	if _mat_torso != null:
		_mat_torso.albedo_color = color
	if _etiqueta != null:
		_etiqueta.modulate = color.lightened(0.35)


## Compra un kit con el dinero de la Partida (o hasta 9000 sin ella) usando `CompraBot` y los comandos. Devuelve lo comprado.
func comprar_kit() -> Array[StringName]:
	var dinero: int = 9000 if partida == null else mini(partida.dinero_de(self), 9000)
	var r: StringName = CompraBot.ROL_DEFENSOR if rol == ROL_DEFENSOR else CompraBot.ROL_ATACANTE
	var lista: Array[StringName] = CompraBot.comprar(dinero, armas.inventario, r, Catalogo, rng)
	var hechas: Array[StringName] = []
	for id: StringName in lista:
		if comandos.comprar(id):
			hechas.append(id)
	if salud != null:
		salud.escudo = armas.inventario.escudo
	return hechas


## Vuelve a la vida: vida 100, escudo 0, inventario base (la Partida decide si compra de nuevo).
func reaparecer(pos: Vector3 = Vector3.INF, yaw_deg: float = 0.0) -> void:
	muerto = false
	_t_muerte = 0.0
	salud.reiniciar()
	hitboxes.activar(true)
	_colision.set_deferred("disabled", false)
	collision_layer = 4
	if _caida != null:
		_caida.rotation.x = 0.0
		ModeloPersonaje.revivir(_caida)
	armas.reiniciar()
	if pos != Vector3.INF:
		teletransportar(pos, yaw_deg)
	else:
		teletransportar(punto_reaparicion, yaw_reaparicion)
	cerebro.reiniciar()
	_actualizar_etiqueta()
	reaparecido.emit(self)


func _on_herido(_cantidad: float, _zona: String, atacante: Node) -> void:
	_actualizar_etiqueta()
	if cerebro != null and not muerto:
		cerebro.on_herido(atacante)


func _on_muerto(atacante: Node, _arma: ArmaDatos) -> void:
	muerto = true
	muertes += 1
	_t_muerte = 0.0
	hitboxes.activar(false)
	collision_layer = 0
	_colision.set_deferred("disabled", true)
	velocity = Vector3.ZERO
	comandos.detener()
	comandos.montar_cachimba(false)
	comandos.apagar_cachimba(false)
	armas.soltar_al_morir()
	if _caida != null and not ModeloPersonaje.morir(_caida):   # modelo sin animaciones (blockout): se tumba
		_caida.rotation.x = deg_to_rad(90.0)
	var s: Salud = Salud.de(atacante)
	if s != null and s != salud and atacante is Bot:
		(atacante as Bot).bajas += 1
	_actualizar_etiqueta()
	murio.emit(self, atacante)


func _procesar_muerte(dt: float) -> void:
	_t_muerte += dt
	if reaparicion_auto and _t_muerte >= tiempo_reaparicion:
		reaparecer()


func _on_ruido(posicion: Vector3, radio: float, fuente: Node) -> void:
	if not muerto and cerebro != null:
		cerebro.on_ruido(posicion, radio, fuente)


func _on_baja(atacante: Node, victima: Salud, _arma: ArmaDatos) -> void:
	if not muerto and cerebro != null:
		cerebro.on_baja(atacante, victima)


## Contorno de enemigo visible: `mat` = ShaderMaterial de contorno, o null para quitarlo (lo gestiona `ContornoEnemigos`).
func fijar_contorno(mat: Material) -> void:
	if _caida != null:
		ModeloPersonaje.fijar_contorno(_caida, mat)


## Nombre flotante (solo aliados y espectador; `ContornoEnemigos` lo muestra a corta distancia o al apuntar).
func mostrar_etiqueta(on: bool) -> void:
	if _etiqueta != null:
		_etiqueta.visible = on and not muerto


func _actualizar_etiqueta() -> void:
	if _etiqueta == null:
		return
	_etiqueta.text = nombre


func _construir_visual() -> void:
	if sin_visual:
		return
	var color: Color = COLORES_EQUIPO.get(equipo, Color(0.7, 0.7, 0.7))
	_caida = ModeloPersonaje.crear(CatalogoPersonajes.por_id(personaje), color)
	add_child(_caida)
	_mat_torso = _caida.get_meta("mat_equipo", null) as StandardMaterial3D
	armas.disparo_realizado.connect(func(_a: ArmaDatos, _r: Dictionary) -> void: ModeloPersonaje.disparar(_caida))
	_etiqueta = Label3D.new()
	_etiqueta.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_etiqueta.no_depth_test = true
	_etiqueta.fixed_size = true
	_etiqueta.pixel_size = 0.00045
	_etiqueta.font_size = 36
	_etiqueta.outline_size = 8
	_etiqueta.modulate = color.lightened(0.35)
	_etiqueta.position = Vector3(0, 2.1, 0)
	_etiqueta.visible = false           # sin nombres por defecto: solo aliados cercanos (ContornoEnemigos)
	add_child(_etiqueta)
	_actualizar_etiqueta()

