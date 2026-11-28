class_name ProxyRed
extends Node3D
## Representacion en el CLIENTE de otro participante (humano remoto o bot): solo el modelo animado, el nombre y una `Salud` sin hitboxes
## (el dano lo decide el servidor). Imita lo justo de la interfaz de `Bot` que usan `ContornoEnemigos`, la camara de espectador y el
## HUD (`muerto`, `equipo`, `ojos()`, `mirada_dir()`, `fijar_contorno()`, `mostrar_etiqueta()`). Lo mueve `ClienteRed` interpolando
## los snapshots con ~100 ms de retraso.

var id: int = -1
var nombre: String = ""
var personaje: StringName = &""
var equipo: int = 0
var muerto: bool = false
var pitch: float = 0.0
var agachado: bool = false
var salud: Salud
var arma_id: StringName = &""

var _caida: Node3D
var _mat_torso: StandardMaterial3D
var _etiqueta: Label3D
var _pos_ant: Vector3 = Vector3.INF
var _vel: float = 0.0


static func crear(id_red: int, nombre_p: String, personaje_id: StringName, lado: int) -> ProxyRed:
	var p := ProxyRed.new()
	p.id = id_red
	p.nombre = nombre_p
	p.name = "Proxy_%d" % id_red
	p.personaje = personaje_id if CatalogoPersonajes.existe(personaje_id) else CatalogoPersonajes.ids()[0]
	p.equipo = lado
	return p


func _ready() -> void:
	salud = Salud.new()
	salud.name = "Salud"
	salud.equipo = equipo
	salud.nombre = nombre
	add_child(salud)
	salud.remove_from_group("salud")        # no es un objetivo de la IA ni de los marcadores: el servidor decide el dano
	add_to_group("proxies_red")
	var color: Color = Bot.COLORES_EQUIPO.get(equipo, Color(0.7, 0.7, 0.7))
	_caida = ModeloPersonaje.crear(CatalogoPersonajes.por_id(personaje), color)
	add_child(_caida)
	_mat_torso = _caida.get_meta("mat_equipo", null) as StandardMaterial3D
	_etiqueta = Label3D.new()
	_etiqueta.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_etiqueta.no_depth_test = true
	_etiqueta.fixed_size = true
	_etiqueta.pixel_size = 0.00045
	_etiqueta.font_size = 36
	_etiqueta.outline_size = 8
	_etiqueta.modulate = color.lightened(0.35)
	_etiqueta.position = Vector3(0, 2.1, 0)
	_etiqueta.text = nombre
	_etiqueta.visible = false
	add_child(_etiqueta)


func ojos() -> Vector3:
	return global_position + Vector3(0.0, 1.15 if agachado else 1.6, 0.0)


func mirada_dir() -> Vector3:
	return Vector3(-sin(rotation.y) * cos(pitch), sin(pitch), -cos(rotation.y) * cos(pitch))


func fijar_contorno(mat: Material) -> void:
	if _caida != null:
		ModeloPersonaje.fijar_contorno(_caida, mat)


func mostrar_etiqueta(on: bool) -> void:
	if _etiqueta != null:
		_etiqueta.visible = on and not muerto


func asignar_equipo(lado: int) -> void:
	equipo = lado
	if salud != null:
		salud.equipo = lado
	var color: Color = Bot.COLORES_EQUIPO.get(lado, Color(0.7, 0.7, 0.7))
	if _mat_torso != null:
		_mat_torso.albedo_color = color
	if _etiqueta != null:
		_etiqueta.modulate = color.lightened(0.35)


## Aplica el estado interpolado (posicion, yaw, pitch) y el discreto (vivo, arma, lado).
func aplicar(pos: Vector3, yaw: float, pitch_nuevo: float, vivo: bool, ag: bool, arma: StringName, lado: int, dt: float) -> void:
	if _pos_ant != Vector3.INF and dt > 0.0:
		var v: float = Vector2(pos.x - _pos_ant.x, pos.z - _pos_ant.z).length() / dt
		_vel = lerpf(_vel, v, 0.35)
	_pos_ant = pos
	global_position = pos
	rotation.y = yaw
	pitch = pitch_nuevo
	agachado = ag
	if lado != equipo:
		asignar_equipo(lado)
	if vivo == muerto:
		muerto = not vivo
		salud.vivo = vivo
		salud.vida = salud.vida_max if vivo else 0.0
		if muerto:
			if _caida != null and not ModeloPersonaje.morir(_caida):
				_caida.rotation.x = deg_to_rad(90.0)
			if _etiqueta != null:
				_etiqueta.visible = false
		elif _caida != null:
			_caida.rotation.x = 0.0
			ModeloPersonaje.revivir(_caida)
	if _caida != null and not muerto:
		ModeloPersonaje.actualizar(_caida, _vel)
		if arma != arma_id:
			arma_id = arma
			ModeloPersonaje.poner_arma(_caida, arma)


func disparo() -> void:
	if _caida != null and not muerto:
		ModeloPersonaje.disparar(_caida)
