class_name ComandosBot
extends Comandos
## Implementacion de `Comandos` para un `Bot`: mueve el CharacterBody3D por la malla de navegacion (ruta de
## `NavigationServer3D.map_get_path`, sin NavigationAgent3D, asi es sincrono y determinista), gira la mira con la velocidad de giro de
## la dificultad (con error de punteria al apuntar a enemigos), dispara por `ArmasBot` -> `Balistica` y delega compra, Cachimba y
## recogida en la `ApiPartida`. Detecta atascos: si no avanza reintenta la ruta, luego un paso lateral y, como ultimo recurso, se
## recoloca en la malla (`rescates`, que los tests miden).

const VEL_NORMAL: float = 5.0
const ACELERACION: float = 40.0
const GRAVEDAD: float = 20.0
const LLEGADA_M: float = 0.7
const RADIO_WAYPOINT: float = 0.6
const TOLERANCIA_APUNTADO_DEG: float = 1.6
const T_ATASCO: float = 1.4
const AVANCE_MIN_M: float = 0.45

var bot: Bot

# movimiento
var llego: bool = false
var hay_destino: bool = false
var atascos: int = 0
var rescates: int = 0
var _destino: Vector3 = Vector3.ZERO
var _vel_rel: float = 1.0
var _ruta: PackedVector3Array = PackedVector3Array()
var _idx: int = 0
var _destino_ruta: Vector3 = Vector3.INF
var _t_ruta: float = -10.0
var _t: float = 0.0
var _ref_pos: Vector3 = Vector3.INF
var _ref_t: float = 0.0
var _atasco_seguido: int = 0
var _paso_lateral_hasta: float = -1.0
var _lateral: Vector3 = Vector3.ZERO
var _ultima_nav: Vector3 = Vector3.INF
var _empuje_h: Vector3 = Vector3.ZERO

# mirada
var _mirar_activo: bool = false
var _mirar_punto: Vector3 = Vector3.ZERO
var _mirar_con_error: bool = false
var _err0_yaw: float = 0.0
var _err0_pitch: float = 0.0
var _t_error: float = 0.0
var _jit_yaw: float = 0.0
var _jit_pitch: float = 0.0
var _t_jit: float = 0.0
var _yaw_obj: float = 0.0
var _pitch_obj: float = 0.0
## Angulo (grados) entre la mirada real y la deseada (con error): el bot dispara cuando es < TOLERANCIA_APUNTADO_DEG.
var angulo_apuntado_deg: float = 180.0

# disparo
var _gatillo: bool = false
var _spray: float = 0.0
var _rafaga_n: int = 0
var _pausa_hasta: float = 0.0


func _init(duenio: Bot) -> void:
	bot = duenio


# ------------------------------------------------------------------ comandos

func mover_hacia(destino: Vector3, velocidad_rel: float = 1.0) -> void:
	_vel_rel = velocidad_rel
	if hay_destino and _destino.distance_to(destino) < 1.2:
		return
	_destino = destino
	hay_destino = true
	llego = false
	_ruta = PackedVector3Array()
	_t_ruta = -10.0


func detener() -> void:
	hay_destino = false
	llego = true
	_ruta = PackedVector3Array()
	_atasco_seguido = 0


func mirar_punto(punto: Vector3, con_error: bool = false) -> void:
	_mirar_activo = true
	_mirar_punto = punto
	_mirar_con_error = con_error


## Re-sortea el error inicial de punteria (el bot adquiere un objetivo nuevo).
func nuevo_objetivo() -> void:
	var e: float = float(bot.perfil["error_inicial"])
	_err0_yaw = bot.rng.randf_range(-e, e)
	_err0_pitch = bot.rng.randf_range(-e, e) * 0.6
	_t_error = 0.0


func disparar(activo: bool) -> void:
	_gatillo = activo


func recargar() -> void:
	bot.armas.recargar()


func cambiar_arma(hueco: int) -> void:
	bot.armas.cambiar_arma(hueco)


## Lanza una utilidad con un arco hacia `objetivo` (lanzamiento fuerte, 17 m/s; flojo, 7 m/s). Calcula el angulo de elevacion.
func lanzar_utilidad(id: StringName, objetivo: Vector3, fuerte: bool = true) -> bool:
	var a: ArmaDatos = Catalogo.arma(id)
	if a == null or not a.es_utilidad() or bot.armas.inventario.cantidad_utilidad(id) <= 0:
		return false
	var origen: Vector3 = bot.ojos() + Vector3(0.0, -0.1, 0.0)
	var v: float = a.velocidad_lanzamiento if fuerte else a.velocidad_lanzamiento_flojo
	var d: Vector3 = objetivo - origen
	var horiz: Vector2 = Vector2(d.x, d.z)
	var dh: float = horiz.length()
	if dh < 0.5:
		return false
	# angulo de elevacion para alcanzar (dh, d.y) con gravedad Lanzable.GRAVEDAD (tiro parabolico, solucion baja)
	var g: float = Lanzable.GRAVEDAD
	var disc: float = v * v * v * v - g * (g * dh * dh + 2.0 * d.y * v * v)
	var elev: float = deg_to_rad(40.0)
	if disc >= 0.0:
		elev = atan2(v * v - sqrt(disc), g * dh)
	var dir := Vector3(horiz.x / dh * cos(elev), sin(elev), horiz.y / dh * cos(elev))
	return bot.armas.lanzar_utilidad(id, origen + dir * 0.4, dir * v) != null


func comprar(id: StringName) -> bool:
	if bot.partida != null:
		return bot.partida.comprar(bot, id)
	return bot.armas.equipar(id)


func montar_cachimba(activo: bool) -> void:
	if bot.partida != null:
		bot.partida.montar_cachimba(bot, activo)


func apagar_cachimba(activo: bool) -> void:
	if bot.partida != null:
		bot.partida.apagar_cachimba(bot, activo)


func recoger_arma(arma: ArmaSuelo) -> bool:
	return bot.armas.recoger(arma)


func tirar_arma() -> bool:
	return bot.armas.tirar_arma()


# ------------------------------------------------------------------ simulacion

## Un tick: movimiento, mirada y disparo con lo que haya pedido la IA este tick. Las ordenes sostenidas se piden de nuevo cada tick.
func ejecutar(dt: float) -> void:
	_t += dt
	_actualizar_mirada(dt)
	_actualizar_movimiento(dt)
	_actualizar_disparo(dt)
	_mirar_activo = false
	_gatillo = false


func velocidad_horizontal() -> float:
	return Vector2(bot.velocity.x, bot.velocity.z).length()


func _arma_vel() -> float:
	var a: ArmaDatos = bot.armas.actual()
	return a.velocidad_mov if a != null else 1.0


func _actualizar_movimiento(dt: float) -> void:
	var objetivo := Vector3.ZERO
	if hay_destino and not llego:
		var wp: Vector3 = _siguiente_waypoint(dt)
		if hay_destino and not llego:
			var d := Vector3(wp.x - bot.global_position.x, 0.0, wp.z - bot.global_position.z)
			if d.length() > 0.05:
				objetivo = d.normalized() * VEL_NORMAL * _vel_rel * _arma_vel()
			if _t < _paso_lateral_hasta:
				objetivo += _lateral * VEL_NORMAL * 0.8
	# evitar solaparse con otros bots (no colisionan entre si): empuje suave
	objetivo += _separacion() * 1.6
	var h := Vector3(bot.velocity.x, 0.0, bot.velocity.z)
	h = h.move_toward(objetivo, ACELERACION * dt)
	bot.velocity.x = h.x
	bot.velocity.z = h.z
	if bot.is_on_floor():
		bot.velocity.y = -1.0
	else:
		bot.velocity.y -= GRAVEDAD * dt
	bot.move_and_slide()
	if hay_destino and not llego:
		_vigilar_atasco(dt)
	elif bot.is_on_floor():
		_ultima_nav = bot.global_position
	if bot.global_position.y < -80.0:
		_rescatar()


## Siguiente punto de la ruta (calcula o refresca la ruta si hace falta). Marca `llego` al alcanzar el destino.
func _siguiente_waypoint(_dt: float) -> Vector3:
	var pos: Vector3 = bot.global_position
	var hd: float = Vector2(_destino.x - pos.x, _destino.z - pos.z).length()
	if hd < LLEGADA_M and absf(_destino.y - pos.y) < 2.5:
		llego = true
		return pos
	if _ruta.size() < 2 or _t - _t_ruta > 3.0:
		_pedir_ruta()
	if _ruta.size() < 2:
		return _destino
	while _idx < _ruta.size() - 1:
		var w: Vector3 = _ruta[_idx]
		if Vector2(w.x - pos.x, w.z - pos.z).length() < RADIO_WAYPOINT and absf(w.y - pos.y) < 2.0:
			_idx += 1
		else:
			break
	var ultimo: Vector3 = _ruta[_ruta.size() - 1]
	if _idx >= _ruta.size() - 1 and Vector2(ultimo.x - pos.x, ultimo.z - pos.z).length() < LLEGADA_M:
		llego = true
		return pos
	return _ruta[mini(_idx, _ruta.size() - 1)]


func _pedir_ruta() -> void:
	var mapa: RID = bot.get_world_3d().navigation_map
	_t_ruta = _t
	_destino_ruta = _destino
	var r: PackedVector3Array = NavigationServer3D.map_get_path(mapa, bot.global_position, _destino, true)
	if r.size() < 2:
		_ruta = PackedVector3Array([bot.global_position, _destino])  # sin malla: linea recta
	else:
		_ruta = r
	_idx = 1


func _separacion() -> Vector3:
	var push := Vector3.ZERO
	for n: Node in bot.get_tree().get_nodes_in_group("bots"):
		if n == bot:
			continue
		var o := n as Bot
		if o == null or o.muerto:
			continue
		var d := Vector3(bot.global_position.x - o.global_position.x, 0.0, bot.global_position.z - o.global_position.z)
		var l: float = d.length()
		if l < 0.8:
			push += (d / maxf(l, 0.05)) * (0.8 - l)
	return push


func _vigilar_atasco(_dt: float) -> void:
	var pos: Vector3 = bot.global_position
	if _ref_pos == Vector3.INF:
		_ref_pos = pos
		_ref_t = _t
		return
	if _t - _ref_t < T_ATASCO:
		return
	var avance: float = Vector2(pos.x - _ref_pos.x, pos.z - _ref_pos.z).length()
	_ref_pos = pos
	_ref_t = _t
	if avance >= AVANCE_MIN_M * _vel_rel * _arma_vel():
		_atasco_seguido = 0
		_ultima_nav = pos
		return
	atascos += 1
	_atasco_seguido += 1
	if _atasco_seguido == 1:
		_ruta = PackedVector3Array()  # nueva ruta
	elif _atasco_seguido == 2:
		var lado: Vector3 = Vector3(bot.velocity.z, 0.0, -bot.velocity.x)
		if lado.length() < 0.1:
			lado = Vector3(bot.rng.randf_range(-1, 1), 0.0, bot.rng.randf_range(-1, 1))
		_lateral = lado.normalized() * (1.0 if bot.rng.randf() < 0.5 else -1.0)
		_paso_lateral_hasta = _t + 0.8
		_ruta = PackedVector3Array()
	else:
		_rescatar()


## Ultimo recurso: se recoloca en el punto de la malla mas cercano al siguiente tramo de la ruta (cuenta en `rescates`).
func _rescatar() -> void:
	rescates += 1
	_atasco_seguido = 0
	var mapa: RID = bot.get_world_3d().navigation_map
	var objetivo: Vector3 = _ultima_nav if _ultima_nav != Vector3.INF else bot.global_position
	if _ruta.size() > 2:
		objetivo = _ruta[mini(_idx + 2, _ruta.size() - 1)]
	var p: Vector3 = NavigationServer3D.map_get_closest_point(mapa, objetivo)
	bot.global_position = p + Vector3(0.0, 0.1, 0.0)
	bot.velocity = Vector3.ZERO
	_ruta = PackedVector3Array()
	_ref_pos = Vector3.INF


func _actualizar_mirada(dt: float) -> void:
	var yaw_actual: float = bot.rotation.y
	var pitch_actual: float = bot.pitch
	var vel_giro: float = deg_to_rad(float(bot.perfil["vel_giro"]))
	var hay_obj: bool = false
	if _mirar_activo:
		var d: Vector3 = _mirar_punto - bot.ojos()
		if d.length() > 0.05:
			hay_obj = true
			_yaw_obj = atan2(-d.x, -d.z)
			_pitch_obj = atan2(d.y, Vector2(d.x, d.z).length())
			if _mirar_con_error:
				_t_error += dt
				_t_jit += dt
				if _t_jit >= 0.25:
					_t_jit = 0.0
					var r: float = float(bot.perfil["error_residual"])
					_jit_yaw = bot.rng.randf_range(-r, r)
					_jit_pitch = bot.rng.randf_range(-r, r) * 0.6
				var k: float = exp(-_t_error / maxf(float(bot.perfil["tau_error"]), 0.01))
				_yaw_obj += deg_to_rad(_err0_yaw * k + _jit_yaw)
				_pitch_obj += deg_to_rad(_err0_pitch * k + _jit_pitch)
	if not hay_obj:
		var vh := Vector3(bot.velocity.x, 0.0, bot.velocity.z)
		if vh.length() > 0.8:
			_yaw_obj = atan2(-vh.x, -vh.z)
		else:
			_yaw_obj = yaw_actual
		_pitch_obj = 0.0
	_pitch_obj = clampf(_pitch_obj, -deg_to_rad(80.0), deg_to_rad(80.0))
	var paso: float = vel_giro * dt
	bot.rotation.y = yaw_actual + clampf(angle_difference(yaw_actual, _yaw_obj), -paso, paso)
	bot.pitch = pitch_actual + clampf(_pitch_obj - pitch_actual, -paso, paso)
	bot.cabeza.rotation.x = bot.pitch
	if hay_obj:
		var deseada := Vector3(-sin(_yaw_obj) * cos(_pitch_obj), sin(_pitch_obj), -cos(_yaw_obj) * cos(_pitch_obj))
		angulo_apuntado_deg = rad_to_deg(bot.mirada_dir().angle_to(deseada))
	else:
		angulo_apuntado_deg = 180.0


func _actualizar_disparo(dt: float) -> void:
	_spray = maxf(_spray - float(bot.perfil["spray_recup"]) * dt, 0.0)
	var armas: ArmasBot = bot.armas
	if not _gatillo:
		_rafaga_n = 0
		armas.cancelar_carga()
		return
	if _t < _pausa_hasta or armas.recargando or armas.cambiando:
		return
	var a: ArmaDatos = armas.actual()
	if a == null:
		return
	if a.cargador > 0 and armas.cargador_actual() <= 0:
		armas.recargar()
		return
	if angulo_apuntado_deg > TOLERANCIA_APUNTADO_DEG:
		armas.cancelar_carga()
		return
	var res: Dictionary = armas.intentar_disparo(bot.ojos(), bot.mirada_dir(), dispersion_actual(a))
	if res.is_empty():
		return
	_spray = minf(_spray + float(bot.perfil["spray_por_disparo"]), float(bot.perfil["spray_max"]))
	_rafaga_n += 1
	if _rafaga_n >= int(bot.perfil["rafaga"]):
		_rafaga_n = 0
		_pausa_hasta = _t + float(bot.perfil["pausa_rafaga"])


## Semiangulo (grados) del cono de este instante: el del arma (`Balistica.dispersion`: quieto o en movimiento, ceguera) mas el spray.
func dispersion_actual(a: ArmaDatos) -> float:
	var vel: float = velocidad_horizontal()
	var apunta: float = float(bot.perfil["apunta"]) if vel < 0.6 else 0.0
	var ceg: float = bot.ceguera.nivel() if bot.ceguera != null else 0.0
	return Balistica.dispersion(a, vel, bot.is_on_floor(), false, apunta, ceg) + _spray
