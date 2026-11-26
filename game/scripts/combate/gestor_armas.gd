class_name GestorArmas
extends Node
## Gestor de armas del jugador (hijo de `Jugador`): ranuras 1-3, disparo, recarga, cambio, retroceso y dispersion.
## La logica avanza con `avanzar(delta)` (lo llama `_physics_process`); la entrada solo rellena `gatillo` y
## `gatillo_alt`, asi que los tests pueden simular el tiempo y los botones sin teclado (`entrada_manual = true`).
## La resolucion del impacto la hace `Balistica`; los efectos (viewmodel, trazadores, sonido) escuchan las senales.

signal disparo_realizado(arma: ArmaDatos, res: Dictionary, origen_visual: Vector3)
signal impacto_confirmado(zona: String, mato: bool)
signal arma_cambiada(arma: ArmaDatos)
signal municion_cambiada
signal recarga_iniciada(arma: ArmaDatos)
signal recarga_cancelada
signal sin_municion
signal ataque_cuerpo(fuerte: bool)

const RUTAS_ARMAS: Array[String] = [
	"res://data/armas/fusil_r7.tres", "res://data/armas/pistola_p9.tres", "res://data/armas/navaja.tres"]
const RUTAS_SONIDOS: Dictionary = {
	"fusil": "res://assets/sonidos/disparo_fusil.wav", "pistola": "res://assets/sonidos/disparo_pistola.wav",
	"navaja": "res://assets/sonidos/navaja.wav", "recarga": "res://assets/sonidos/recarga.wav",
	"cambio": "res://assets/sonidos/cambio_arma.wav", "vacio": "res://assets/sonidos/clic_vacio.wav"}
## Desplazamiento (en el espacio de la camara) del punto de donde salen el trazador y el fogonazo.
const BOCA_LOCAL: Vector3 = Vector3(0.16, -0.13, -0.6)

@export var auto_recargar: bool = true
## Si es verdadero no se lee el teclado/raton: quien use el gestor fija `gatillo` y `gatillo_alt`.
var entrada_manual: bool = false
var gatillo: bool = false
var gatillo_alt: bool = false

var armas: Array[ArmaDatos] = []
var cargadores: Array[int] = []
var reservas: Array[int] = []
var indice: int = 0
var indice_previo: int = 1
var recargando: bool = false
var cambiando: bool = false
var disparos_totales: int = 0
var rng := RandomNumberGenerator.new()

var _jugador: Jugador
var _t: float = 0.0
var _proximo: float = 0.0
var _fin_recarga: float = 0.0
var _inicio_recarga: float = 0.0
var _fin_cambio: float = 0.0
var _inicio_cambio: float = 0.0
var _gatillo_prev: bool = false
var _alt_prev: bool = false
var _rafaga: int = 0
var _ultimo_disparo: float = -100.0
var _ret_pitch: float = 0.0
var _ret_yaw: float = 0.0
var _sonidos: Dictionary = {}
var _p_disparo: AudioStreamPlayer
var _p_aux: AudioStreamPlayer
var _p_recarga: AudioStreamPlayer
var _vm: ViewmodelCapa


func _ready() -> void:
	_jugador = get_parent() as Jugador
	rng.randomize()
	for r: String in RUTAS_ARMAS:
		var a: ArmaDatos = load(r) as ArmaDatos
		armas.append(a)
		cargadores.append(a.cargador)
		reservas.append(a.reserva)
	for k: String in RUTAS_SONIDOS:
		if ResourceLoader.exists(RUTAS_SONIDOS[k]):
			_sonidos[k] = load(RUTAS_SONIDOS[k])
	_p_disparo = _nuevo_player()
	_p_aux = _nuevo_player()
	_p_recarga = _nuevo_player()
	_vm = ViewmodelCapa.new()
	add_child(_vm)
	_vm.vincular(self, _jugador)
	_aplicar_arma()


func _nuevo_player() -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.volume_db = -4.0
	add_child(p)
	return p


func actual() -> ArmaDatos:
	return armas[indice]


func municion_cargador() -> int:
	return cargadores[indice]


func municion_reserva() -> int:
	return reservas[indice]


func progreso_recarga() -> float:
	if not recargando:
		return 0.0
	return clampf((_t - _inicio_recarga) / maxf(_fin_recarga - _inicio_recarga, 0.001), 0.0, 1.0)


func progreso_cambio() -> float:
	if not cambiando:
		return 1.0
	return clampf((_t - _inicio_cambio) / maxf(_fin_cambio - _inicio_cambio, 0.001), 0.0, 1.0)


## Semiangulo (grados) del cono de dispersion en este instante, segun velocidad, suelo y postura.
func dispersion_actual() -> float:
	var a: ArmaDatos = actual()
	var en_suelo: bool = _jugador.is_on_floor() and not _jugador.vuelo
	return Balistica.dispersion(a, _jugador.velocidad_horizontal(), en_suelo, _jugador.agachado)


func _puede_entrada() -> bool:
	return _jugador != null and _jugador.activo and not _jugador.muerto \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if entrada_manual or not _puede_entrada():
		return
	if event.is_action_pressed("arma_1"):
		cambiar_arma(0)
	elif event.is_action_pressed("arma_2"):
		cambiar_arma(1)
	elif event.is_action_pressed("arma_3"):
		cambiar_arma(2)
	elif event.is_action_pressed("arma_ultima"):
		cambiar_arma(indice_previo)
	elif event.is_action_pressed("arma_siguiente"):
		cambiar_arma((indice + 1) % armas.size())
	elif event.is_action_pressed("arma_anterior"):
		cambiar_arma((indice + armas.size() - 1) % armas.size())
	elif event.is_action_pressed("recargar"):
		recargar()


func _physics_process(delta: float) -> void:
	if not entrada_manual:
		var ok: bool = _puede_entrada()
		gatillo = ok and Input.is_action_pressed("disparar")
		gatillo_alt = ok and Input.is_action_pressed("disparo_secundario")
	avanzar(delta)


## Avanza `delta` segundos de simulacion: temporizadores, gatillo y retroceso.
func avanzar(delta: float) -> void:
	_t += delta
	if cambiando and _t >= _fin_cambio:
		cambiando = false
	if recargando and _t >= _fin_recarga:
		_terminar_recarga()
	var a: ArmaDatos = actual()
	if not cambiando and not recargando and _jugador != null and not _jugador.muerto:
		if a.cuerpo_a_cuerpo:
			_procesar_cuerpo_a_cuerpo(a)
		else:
			_procesar_disparo(a)
	_actualizar_retroceso(a, delta)
	_gatillo_prev = gatillo
	_alt_prev = gatillo_alt


func _procesar_disparo(a: ArmaDatos) -> void:
	var flanco: bool = gatillo and not _gatillo_prev
	var quiere: bool = gatillo if a.automatica else flanco
	if not quiere:
		return
	if cargadores[indice] <= 0:
		if flanco:
			sin_municion.emit()
			_sonar("vacio", _p_aux)
			if auto_recargar:
				recargar()
		return
	if _t + 0.000001 >= _proximo:
		_disparar(a)


func _procesar_cuerpo_a_cuerpo(a: ArmaDatos) -> void:
	if _t + 0.000001 < _proximo:
		return
	if gatillo_alt and not _alt_prev:
		_atacar(a, true)
	elif gatillo and not _gatillo_prev:
		_atacar(a, false)


## Dispara un tiro desde la camara con la dispersion del estado actual.
func _disparar(a: ArmaDatos) -> void:
	var cam: Camera3D = _jugador.camara
	var origen: Vector3 = cam.global_position
	var dir: Vector3 = -cam.global_transform.basis.z
	var res: Dictionary = Balistica.resolver_disparo(origen, dir, a, _jugador, rng, dispersion_actual())
	Balistica.aplicar(res, a, _jugador)
	cargadores[indice] -= 1
	disparos_totales += 1
	_programar_siguiente(a.intervalo())
	_sumar_retroceso(a)
	_sonar(String(a.id), _p_disparo)
	disparo_realizado.emit(a, res, cam.global_transform * BOCA_LOCAL)
	_emitir_impacto(res)
	municion_cambiada.emit()


func _atacar(a: ArmaDatos, fuerte: bool) -> void:
	var cam: Camera3D = _jugador.camara
	var origen: Vector3 = cam.global_position
	var dir: Vector3 = -cam.global_transform.basis.z
	var res: Dictionary = Balistica.resolver_disparo(origen, dir, a, _jugador, rng, 0.0, fuerte)
	Balistica.aplicar(res, a, _jugador)
	disparos_totales += 1
	_proximo = _t + (a.intervalo_fuerte if fuerte else a.intervalo())
	_sonar(String(a.id), _p_disparo)
	ataque_cuerpo.emit(fuerte)
	disparo_realizado.emit(a, res, cam.global_transform * BOCA_LOCAL)
	_emitir_impacto(res)


func _emitir_impacto(res: Dictionary) -> void:
	var s: Salud = res.get("salud") as Salud
	if s != null:
		impacto_confirmado.emit(str(res["zona"]), not s.vivo)


## Cadencia sin deriva: en fuego continuo el siguiente disparo cuenta desde el previsto, no desde el real.
func _programar_siguiente(intervalo: float) -> void:
	if _t - _proximo < intervalo:
		_proximo += intervalo
	else:
		_proximo = _t + intervalo


func _sumar_retroceso(a: ArmaDatos) -> void:
	if _t - _ultimo_disparo > a.retroceso_pausa + a.intervalo():
		_rafaga = 0
	var n: int = mini(_rafaga, a.retroceso_pitch.size() - 1)
	_ret_pitch += deg_to_rad(a.retroceso_pitch[n])
	var ny: int = mini(_rafaga, a.retroceso_yaw.size() - 1)
	_ret_yaw += deg_to_rad(a.retroceso_yaw[ny])
	_rafaga += 1
	_ultimo_disparo = _t


func _actualizar_retroceso(a: ArmaDatos, delta: float) -> void:
	if _t - _ultimo_disparo > a.retroceso_pausa:
		var paso: float = deg_to_rad(a.retroceso_recuperacion) * delta
		_ret_pitch = move_toward(_ret_pitch, 0.0, paso)
		_ret_yaw = move_toward(_ret_yaw, 0.0, paso)
	if _jugador != null:
		_jugador.fijar_retroceso(_ret_pitch, _ret_yaw)


func recargar() -> void:
	var a: ArmaDatos = actual()
	if a.cuerpo_a_cuerpo or recargando or cambiando:
		return
	if cargadores[indice] >= a.cargador or reservas[indice] <= 0:
		return
	recargando = true
	_inicio_recarga = _t
	_fin_recarga = _t + a.tiempo_recarga
	_sonar("recarga", _p_recarga)
	recarga_iniciada.emit(a)


func _terminar_recarga() -> void:
	recargando = false
	var a: ArmaDatos = actual()
	var falta: int = a.cargador - cargadores[indice]
	var n: int = mini(falta, reservas[indice])
	cargadores[indice] += n
	reservas[indice] -= n
	municion_cambiada.emit()


func cancelar_recarga() -> void:
	if recargando:
		recargando = false
		_p_recarga.stop()
		recarga_cancelada.emit()


## Cambia a la ranura `i` (0-2). Cancela la recarga en curso; no se puede disparar hasta acabar el cambio.
func cambiar_arma(i: int) -> void:
	if i == indice or i < 0 or i >= armas.size():
		return
	cancelar_recarga()
	indice_previo = indice
	indice = i
	_aplicar_arma()
	_sonar("cambio", _p_aux)


func _aplicar_arma() -> void:
	var a: ArmaDatos = actual()
	cambiando = true
	_inicio_cambio = _t
	_fin_cambio = _t + a.tiempo_cambio
	_proximo = maxf(_proximo, _fin_cambio)
	_rafaga = 0
	if _jugador != null:
		_jugador.mult_velocidad_arma = a.velocidad_mov
	arma_cambiada.emit(a)
	municion_cambiada.emit()


## Municion llena y arma en reposo (al reaparecer).
func reiniciar() -> void:
	cancelar_recarga()
	for i in armas.size():
		cargadores[i] = armas[i].cargador
		reservas[i] = armas[i].reserva
	_ret_pitch = 0.0
	_ret_yaw = 0.0
	_rafaga = 0
	cambiando = false
	_proximo = _t
	municion_cambiada.emit()


func _sonar(clave: String, player: AudioStreamPlayer) -> void:
	if _sonidos.has(clave):
		player.stream = _sonidos[clave]
		player.play()
