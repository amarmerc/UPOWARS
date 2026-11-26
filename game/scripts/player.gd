class_name Jugador
extends CharacterBody3D
## Jugador en primera persona, controles tipo CS (WASD, salto, caminar lento, agacharse)
## y modo vuelo/noclip (F1). Las acciones se definen en el Input Map de project.godot.

@export_group("Ratón")
## Radianes por píxel de movimiento del ratón.
@export var sensibilidad: float = 0.0022

@export_group("Velocidades (m/s)")
@export var vel_correr: float = 5.0
@export var vel_caminar: float = 2.6
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
var vuelo: bool = false
var agachado: bool = false
var nombre_spawn: String = ""

signal reaparecido

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


func _ready() -> void:
	_capsula = _colision.shape as CapsuleShape3D
	_aplicar_postura(false)
	_cabeza.position.y = ojos_pie
	salud.muerto.connect(_on_muerto)


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


func _unhandled_input(event: InputEvent) -> void:
	if not activo or muerto:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var m := event as InputEventMouseMotion
		rotate_y(-m.relative.x * sensibilidad)
		_pitch = clampf(_pitch - m.relative.y * sensibilidad, -deg_to_rad(89.0), deg_to_rad(89.0))
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
	# La cámara se acerca suavemente a la altura de ojos de la postura actual.
	var ojos: float = ojos_agachado if agachado else ojos_pie
	if muerto:
		_procesar_muerte(delta)
		return
	_cabeza.position.y = move_toward(_cabeza.position.y, ojos, vel_transicion_camara * delta)
	if not activo:
		return
	if vuelo:
		_mover_vuelo(delta)
	else:
		_mover_suelo(delta)


## Pitch/yaw de retroceso (rad) que se suman a la mira; los fija el gestor de armas.
func fijar_retroceso(pitch: float, yaw: float) -> void:
	_ret_pitch = pitch
	_ret_yaw = yaw
	_aplicar_rotacion_cabeza()


func _aplicar_rotacion_cabeza() -> void:
	_cabeza.rotation = Vector3(_pitch + _ret_pitch, _ret_yaw, 0.0)


func _on_muerto(_atacante: Node) -> void:
	muerto = true
	_t_muerte = 0.0
	hitboxes.activar(false)
	fijar_retroceso(0.0, 0.0)
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


## Vuelve al punto de aparicion con vida 100, armadura 0 y municion llena.
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
	if Input.is_action_pressed("caminar_lento"):
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
	var dir: Vector3 = transform.basis * Vector3(entrada.x, 0.0, entrada.y)
	var objetivo: Vector3 = dir.normalized() * _velocidad_objetivo() * mult_velocidad_arma

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


func _velocidad_objetivo() -> float:
	if agachado:
		return vel_agachado
	if Input.is_action_pressed("caminar_lento"):
		return vel_caminar
	return vel_correr


func _actualizar_postura() -> void:
	if Input.is_action_pressed("agacharse"):
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
