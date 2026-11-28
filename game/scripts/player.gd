class_name Jugador
extends CharacterBody3D
## Jugador en primera persona. Controles: WASD, Espacio salta, Shift corre (~7,8 m/s), Alt camina sigiloso, Ctrl se agacha,
## clic derecho apunta (lo gestiona el GestorArmas), E recoge, G tira el arma; F1 vuelo/noclip, M selector de spawn, F3 depuracion,
## K suicidio (pruebas). Las acciones se definen en el Input Map de project.godot.

signal reaparecido

@export_group("Ratón")
## Radianes por píxel de movimiento del ratón.
@export var sensibilidad: float = 0.0022

@export_group("Velocidades (m/s)")
## Andar normal (sin modificadores).
@export var vel_normal: float = 5.0
## Correr (Shift).
@export var vel_sprint: float = 7.8
## Caminar sigiloso (Alt).
@export var vel_sigilo: float = 2.6
@export var vel_agachado: float = 1.7
@export var vel_vuelo: float = 20.0
@export var mult_vuelo_rapido: float = 3.0

@export_group("Física")
@export var aceleracion_suelo: float = 40.0
@export var friccion_suelo: float = 30.0
@export var aceleracion_aire: float = 5.0
@export var gravedad: float = 20.0
@export var altura_salto: float = 1.0

@export_group("Combate")
@export var tiempo_reaparicion: float = 2.0
## Campo de vision (grados) sin apuntar.
@export var fov_base: float = 80.0

@export_group("Dimensiones (m)")
@export var altura_pie: float = 1.8
@export var altura_agachado: float = 1.2
@export var ojos_pie: float = 1.65
@export var ojos_agachado: float = 1.15
@export var vel_transicion_camara: float = 6.0

## Si es falso el jugador no se mueve ni procesa entrada (menú abierto).
var activo: bool = false
## Combate: el jugador muerto no se mueve y reaparece en `punto_reaparicion` tras `tiempo_reaparicion` s.
var muerto: bool = false
var punto_reaparicion: Vector3 = Vector3.ZERO
var yaw_reaparicion: float = 0.0
## Multiplicador de velocidad segun el arma en la mano (lo fija el gestor de armas).
var mult_velocidad_arma: float = 1.0
## Multiplicador de velocidad segun el estado (apuntando, bloqueando con el sable); lo fija el gestor de armas.
var mult_velocidad_estado: float = 1.0
var vuelo: bool = false
var agachado: bool = false
var nombre_spawn: String = ""
## Estados que fija el movimiento (corriendo) y el gestor de armas (apuntando).
var corriendo: bool = false
var apuntando: bool = false
## Entrada manual (tests, bots): no se lee el teclado para correr / sigilo / agacharse.
var entrada_manual: bool = false
var quiere_correr: bool = false
var quiere_sigilo: bool = false
var quiere_agachar: bool = false

## Red (cliente): el servidor es autoritativo; el cuerpo se mueve con `paso_red` (prediccion) y `ClienteRed` reconcilia.
var modo_red: bool = false
var estado_mov := MovimientoJugador.Estado.new()

var _pitch: float = 0.0
var _ret_pitch: float = 0.0
var _ret_yaw: float = 0.0
var _t_muerte: float = 0.0
var _capsula: CapsuleShape3D

@onready var _cabeza: Node3D = $Cabeza
@onready var _colision: CollisionShape3D = $Colision
@onready var camara: Camera3D = $Cabeza/Camara
@onready var salud: Salud = $Salud
@onready var hitboxes: Hitboxes = $Hitboxes
@onready var gestor: GestorArmas = $Armas
var ceguera: EstadoCeguera


func _ready() -> void:
	_capsula = _colision.shape as CapsuleShape3D
	_aplicar_postura(false)
	_cabeza.position.y = ojos_pie
	camara.fov = fov_base
	ceguera = EstadoCeguera.new()
	ceguera.name = "Ceguera"
	add_child(ceguera)
	salud.muerto.connect(_on_muerto)
	salud.bloqueo = gestor._intentar_bloqueo  # el sable de plasma bloquea disparos y proyectiles


## Coloca al jugador (pos en coordenadas del juego, yaw en grados) y lo deja en pie.
func teletransportar(pos: Vector3, yaw_deg: float) -> void:
	global_position = pos
	rotation = Vector3(0.0, deg_to_rad(yaw_deg), 0.0)
	punto_reaparicion = pos
	yaw_reaparicion = yaw_deg
	_pitch = 0.0
	_ret_pitch = 0.0
	_ret_yaw = 0.0
	_aplicar_rotacion_cabeza()
	velocity = Vector3.ZERO
	_poner_vuelo(false)
	_aplicar_postura(false)
	_cabeza.position.y = ojos_pie


func velocidad_horizontal() -> float:
	return Vector2(velocity.x, velocity.z).length()


## Impulso (m/s) que se suma a la velocidad: explosiones, extintor y puno empujan con esto.
func aplicar_impulso(v: Vector3) -> void:
	if vuelo or muerto:
		return
	velocity += v


## Velocidad objetivo (m/s) del estado actual: andar 5, correr 7,8, sigilo 2,6, agachado 1,7, por los multiplicadores del arma
## y del estado (apuntar o bloquear).
func velocidad_objetivo() -> float:
	var v: float = vel_normal
	if agachado:
		v = vel_agachado
	elif quiere_sigilo:
		v = vel_sigilo
	elif corriendo:
		v = vel_sprint
	return v * mult_velocidad_arma * mult_velocidad_estado


## Apuntado (0..1) y aumentos: el gestor de armas lo llama cada tick. Reduce el campo de vision de la camara.
func fijar_apuntado(t: float, zoom: float) -> void:
	apuntando = t > 0.0
	var k: float = lerpf(1.0, maxf(zoom, 1.0), t)
	camara.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(fov_base) * 0.5) / k))


func _unhandled_input(event: InputEvent) -> void:
	if not activo or muerto:
		return
	if modo_red and (event.is_action_pressed("modo_vuelo") or event.is_action_pressed("suicidio")):
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var m := event as InputEventMouseMotion
		# apuntando con zoom, la sensibilidad baja en proporcion al campo de vision
		var s: float = sensibilidad * tan(deg_to_rad(camara.fov) * 0.5) / tan(deg_to_rad(fov_base) * 0.5)
		rotate_y(-m.relative.x * s)
		_pitch = clampf(_pitch - m.relative.y * s, -deg_to_rad(89.0), deg_to_rad(89.0))
		_aplicar_rotacion_cabeza()
	elif event.is_action_pressed("alternar_raton"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("modo_vuelo"):
		_poner_vuelo(not vuelo)
	elif event.is_action_pressed("suicidio"):
		salud.recibir_dano(9999.0, "torso", 1.0, null)
	elif event is InputEventMouseButton and event.pressed \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if modo_red:
		_fisica_red(delta)
		return
	# La cámara se acerca suavemente a la altura de ojos de la postura actual.
	var ojos: float = ojos_agachado if agachado else ojos_pie
	if muerto:
		_procesar_muerte(delta)
		return
	_cabeza.position.y = move_toward(_cabeza.position.y, ojos, vel_transicion_camara * delta)
	if not activo:
		return
	if not entrada_manual:
		quiere_correr = Input.is_action_pressed("correr")
		quiere_sigilo = Input.is_action_pressed("caminar_lento")
		quiere_agachar = Input.is_action_pressed("agacharse")
	if vuelo:
		_mover_vuelo(delta)
	else:
		_mover_suelo(delta)


# ------------------------------------------------------------------ red (cliente)

func _fisica_red(delta: float) -> void:
	if muerto:
		_t_muerte += delta
		_cabeza.position.y = move_toward(_cabeza.position.y, 0.5, 3.0 * delta)


## Un paso de prediccion con la entrada de red `e` (lo llama `ClienteRed` cada tick de fisica).
func paso_red(e: EntradaRed, dt: float) -> void:
	estado_mov.mult_arma = mult_velocidad_arma
	estado_mov.mult_estado = mult_velocidad_estado
	MovimientoJugador.paso(self, estado_mov, e, dt)
	agachado = estado_mov.agachado
	corriendo = estado_mov.corriendo
	_cabeza.position.y = estado_mov.ojos_y


func _cabeza_y(y: float) -> void:
	_cabeza.position.y = y


## Desplaza la camara (error de prediccion que se esta desvaneciendo) sin tocar el cuerpo.
func poner_error_visual(v: Vector3) -> void:
	var l: Vector3 = global_transform.basis.inverse() * v
	_cabeza.position.x = l.x
	_cabeza.position.z = l.z


## El servidor dice que has muerto: igual que `_on_muerto` pero sin soltar armas al mundo (las suelta el servidor).
func morir_red() -> void:
	muerto = true
	_t_muerte = 0.0
	corriendo = false
	hitboxes.activar(false)
	fijar_retroceso(0.0, 0.0)
	gestor.soltar_al_morir()
	_cabeza.rotation = Vector3(deg_to_rad(-20.0), 0.0, deg_to_rad(18.0))


func revivir_red() -> void:
	muerto = false
	_pitch = 0.0
	_ret_pitch = 0.0
	_ret_yaw = 0.0
	_aplicar_rotacion_cabeza()
	gestor.cancelar_recarga()
	gestor._resetear_estados()
	reaparecido.emit()


## Pitch/yaw de retroceso (rad) que se suman a la mira; los fija el gestor de armas.
func fijar_retroceso(pitch: float, yaw: float) -> void:
	_ret_pitch = pitch
	_ret_yaw = yaw
	_aplicar_rotacion_cabeza()


func _aplicar_rotacion_cabeza() -> void:
	_cabeza.rotation = Vector3(_pitch + _ret_pitch, _ret_yaw, 0.0)


func _on_muerto(_atacante: Node, _arma: ArmaDatos) -> void:
	muerto = true
	_t_muerte = 0.0
	corriendo = false
	hitboxes.activar(false)
	fijar_retroceso(0.0, 0.0)
	gestor.soltar_al_morir()
	_cabeza.rotation = Vector3(deg_to_rad(-20.0), 0.0, deg_to_rad(18.0))


func _procesar_muerte(delta: float) -> void:
	_t_muerte += delta
	_cabeza.position.y = move_toward(_cabeza.position.y, 0.5, 3.0 * delta)
	if not vuelo:
		velocity.y -= gravedad * delta
		velocity.x = move_toward(velocity.x, 0.0, friccion_suelo * delta)
		velocity.z = move_toward(velocity.z, 0.0, friccion_suelo * delta)
		move_and_slide()
	if _t_muerte >= tiempo_reaparicion:
		reaparecer()


## Vuelve al punto de aparicion con vida 100, escudo 0 y el inventario base (lo comprado se soltó al morir).
func reaparecer() -> void:
	muerto = false
	salud.reiniciar()
	hitboxes.activar(true)
	teletransportar(punto_reaparicion, yaw_reaparicion)
	gestor.reiniciar()
	reaparecido.emit()


func _poner_vuelo(valor: bool) -> void:
	vuelo = valor
	_colision.set_deferred("disabled", valor)
	velocity = Vector3.ZERO


func _mover_vuelo(delta: float) -> void:
	var entrada: Vector2 = Input.get_vector("mover_izquierda", "mover_derecha",
			"mover_adelante", "mover_atras")
	var dir: Vector3 = _cabeza.global_transform.basis * Vector3(entrada.x, 0.0, entrada.y)
	dir.y += Input.get_axis("agacharse", "saltar")
	var vel: float = vel_vuelo
	if Input.is_action_pressed("correr"):
		vel *= mult_vuelo_rapido
	velocity = dir.limit_length(1.0) * vel
	global_position += velocity * delta


func _mover_suelo(delta: float) -> void:
	_actualizar_postura()
	var en_suelo: bool = is_on_floor()

	if not en_suelo:
		velocity.y -= gravedad * delta
	elif Input.is_action_just_pressed("saltar"):
		velocity.y = sqrt(2.0 * gravedad * altura_salto)

	var entrada: Vector2 = Input.get_vector("mover_izquierda", "mover_derecha",
			"mover_adelante", "mover_atras")
	corriendo = quiere_correr and entrada.y < -0.1 and en_suelo and not agachado and not quiere_sigilo
	var dir: Vector3 = transform.basis * Vector3(entrada.x, 0.0, entrada.y)
	var objetivo: Vector3 = dir.normalized() * velocidad_objetivo()

	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var ritmo: float
	if en_suelo:
		ritmo = aceleracion_suelo if dir.length_squared() > 0.0 else friccion_suelo
	else:
		ritmo = aceleracion_aire if dir.length_squared() > 0.0 else 0.0
	horizontal = horizontal.move_toward(objetivo, ritmo * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z
	move_and_slide()


func _actualizar_postura() -> void:
	if quiere_agachar:
		if not agachado:
			_aplicar_postura(true)
	elif agachado and _puede_levantarse():
		_aplicar_postura(false)


## Comprueba que hay sitio sobre la cápsula agachada para volver a la altura normal.
func _puede_levantarse() -> bool:
	return not test_move(global_transform, Vector3.UP * (altura_pie - altura_agachado))


func _aplicar_postura(abajo: bool) -> void:
	agachado = abajo
	var h: float = altura_agachado if abajo else altura_pie
	_capsula.height = h
	_colision.position.y = h * 0.5
	if hitboxes != null:
		hitboxes.ajustar_altura(h)
