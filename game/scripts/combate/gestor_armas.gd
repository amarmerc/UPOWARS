class_name GestorArmas
extends Node
## Gestor de armas del jugador (hijo de `Jugador`). Usa un `Inventario` con 4 huecos: 0 principal (tecla 1), 1 secundaria (2),
## 2 cuerpo a cuerpo (3) y 3 utilidades (4, o la rueda, para ciclar entre ellas; Q = la ultima). Dispara segun el tipo de arma
## (hitscan, perdigones, proyectil con gravedad, cohete, cuerpo a cuerpo, sable, puño-bot, utilidades lanzables), apunta
## (clic derecho), bloquea con el sable, suelta/recoge armas (G / E) y avanza con `avanzar(delta)` (lo llama
## `_physics_process`): la entrada solo rellena `gatillo` y `gatillo_alt`, asi que los tests simulan el tiempo y los botones
## sin teclado (`entrada_manual = true`). La resolucion del dano la hace `Balistica`; los efectos escuchan las senales.

signal disparo_realizado(arma: ArmaDatos, res: Dictionary, origen_visual: Vector3)
signal impacto_confirmado(zona: String, mato: bool)
signal arma_cambiada(arma: ArmaDatos)
signal municion_cambiada
signal recarga_iniciada(arma: ArmaDatos)
signal recarga_cancelada
signal sin_municion
signal ataque_cuerpo(fuerte: bool)
signal bloqueo_realizado
signal sable_sobrecalentado
signal inventario_cambiado
signal arma_soltada(id: StringName)
signal arma_recogida(id: StringName)

const NOMBRES_SONIDOS: Array[String] = [
	"disparo_fusil", "disparo_pistola", "disparo_subfusil", "disparo_pesada", "disparo_combate", "disparo_precision",
	"disparo_escopeta", "disparo_ametralladora", "disparo_cohete", "arco_disparo", "arco_tensar", "tirachinas",
	"puno_disparo", "sable_golpe", "sable_bloqueo", "sable_sobrecalentamiento", "lanzar", "recoger", "navaja",
	"recarga", "cambio_arma", "clic_vacio"]
## Desplazamiento (en el espacio de la camara) del punto de donde salen el trazador y el fogonazo.
const BOCA_LOCAL: Vector3 = Vector3(0.16, -0.13, -0.6)
## Segundos tras dejar de correr hasta poder disparar.
const DEMORA_CORRER: float = 0.25
const DISTANCIA_RECOGER: float = 2.8
const CARGA_MINIMA_SOLTAR: float = 0.12
const EPS: float = 0.000001

@export var auto_recargar: bool = true
## Armas que se reciben al reaparecer (no se sueltan al morir). La Partida (P4) lo deja vacio y usa la tienda.
var kit_reaparicion: Array[StringName] = [&"fusil_asalto"]
## Si es verdadero no se lee el teclado/raton: quien use el gestor fija `gatillo` y `gatillo_alt`.
var entrada_manual: bool = false
var gatillo: bool = false
var gatillo_alt: bool = false

var inventario := Inventario.new()
## Hueco activo: 0 principal, 1 secundaria, 2 cuerpo a cuerpo, 3 utilidades.
var indice: int = 0
var indice_previo: int = 1
## Utilidad seleccionada dentro de `inventario.tipos_utilidad()`.
var sel_util: int = 0
var recargando: bool = false
var cambiando: bool = false
var disparos_totales: int = 0
var rng := RandomNumberGenerator.new()
## Apuntar (clic derecho con armas de fuego): `aim_t` va de 0 a 1.
var apuntando: bool = false
var aim_t: float = 0.0
## Nivel de aumento elegido (indice de `ArmaDatos.zoom_niveles`) y aumento mostrado ahora (suavizado entre niveles).
var nivel_zoom: int = 0
var zoom_vis: float = 1.0
var _t_alt_suelta: float = -10.0
## Carga del arco / puño-bot (0..1) mientras se mantiene el clic izquierdo.
var cargando: bool = false
var carga: float = 0.0
var puno_en_vuelo: bool = false
## Sable: calor (0..100), bloqueo activo y sobrecalentamiento.
var calor: float = 0.0
var bloqueando: bool = false
var sobrecalentado: bool = false

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
var _rafaga_pend: int = 0
var _ultimo_disparo: float = -100.0
var _ret_pitch: float = 0.0
var _ret_yaw: float = 0.0
var _t_carga0: float = 0.0
var _fin_puno: float = 0.0
var _puno: Proyectil = null
var _fin_sobre: float = 0.0
var _bloqueo_correr_hasta: float = 0.0
var _sonidos: Dictionary = {}
var _p_disparo: AudioStreamPlayer
var _p_aux: AudioStreamPlayer
var _p_recarga: AudioStreamPlayer
var _vm: ViewmodelCapa
var _mirada: ArmaSuelo = null


func _ready() -> void:
	_jugador = get_parent() as Jugador
	rng.randomize()
	for id: StringName in kit_reaparicion:
		inventario.equipar(id)
	for k: String in NOMBRES_SONIDOS:
		var ruta: String = "res://assets/sonidos/%s.wav" % k
		if ResourceLoader.exists(ruta):
			_sonidos[k] = load(ruta)
	_p_disparo = _nuevo_player()
	_p_aux = _nuevo_player()
	_p_recarga = _nuevo_player()
	_vm = ViewmodelCapa.new()
	add_child(_vm)
	_vm.vincular(self, _jugador)
	var armero := Armero.new()
	armero.name = "Armero"
	add_child(armero)
	armero.vincular(self, _jugador)
	_asegurar_indice()
	_aplicar_arma()


## Pinta las manos del viewmodel con la piel / manga del personaje `id` (`CatalogoPersonajes`).
func poner_personaje(id: StringName) -> void:
	if _vm != null:
		_vm.poner_personaje(id)


## Muestra u oculta el arma en primera persona (lobby, espectador).
func mostrar_viewmodel(valor: bool) -> void:
	if _vm != null:
		_vm.visible = valor


func _nuevo_player() -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.volume_db = -4.0
	add_child(p)
	return p


# ------------------------------------------------------------------ consultas

## Id del arma o utilidad del hueco `i` (vacio si no hay).
func id_en(i: int) -> StringName:
	match i:
		0:
			return inventario.principal
		1:
			return inventario.secundaria
		2:
			return inventario.cuerpo
		3:
			var t: Array[StringName] = inventario.tipos_utilidad()
			if t.is_empty():
				return &""
			return t[clampi(sel_util, 0, t.size() - 1)]
	return &""


func arma_en(i: int) -> ArmaDatos:
	var id: StringName = id_en(i)
	return Catalogo.arma(id) if id != &"" else null


func actual() -> ArmaDatos:
	var a: ArmaDatos = arma_en(indice)
	return a if a != null else arma_en(1)


func id_actual() -> StringName:
	return id_en(indice)


## Cargador del hueco `i` (para utilidades, la cantidad que queda).
func cargador_en(i: int) -> int:
	if i == 3:
		return inventario.cantidad_utilidad(id_en(3))
	return inventario.cargador(id_en(i))


func reserva_en(i: int) -> int:
	return 0 if i == 3 else inventario.reserva(id_en(i))


func municion_cargador() -> int:
	return cargador_en(indice)


func municion_reserva() -> int:
	return reserva_en(indice)


func progreso_recarga() -> float:
	if not recargando:
		return 0.0
	return clampf((_t - _inicio_recarga) / maxf(_fin_recarga - _inicio_recarga, 0.001), 0.0, 1.0)


func progreso_cambio() -> float:
	if not cambiando:
		return 1.0
	return clampf((_t - _inicio_cambio) / maxf(_fin_cambio - _inicio_cambio, 0.001), 0.0, 1.0)


## Progreso (0..1) del regreso del puño a la mano (1 = ya esta en la mano).
func progreso_puno() -> float:
	if not puno_en_vuelo:
		return 1.0
	var a: ArmaDatos = Catalogo.arma(&"puno_bot")
	return clampf(1.0 - (_fin_puno - _t) / maxf(a.retorno_tiempo, 0.01), 0.0, 1.0)


## Resumen para el HUD: [{id, nombre, cantidad, seleccionada}].
func utilidades_info() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var sel: StringName = id_en(3)
	for id: StringName in inventario.tipos_utilidad():
		out.append({"id": id, "nombre": str(Catalogo.info(id).get("nombre", id)),
				"cantidad": inventario.cantidad_utilidad(id), "seleccionada": id == sel})
	return out


## Aumentos del nivel de zoom elegido del arma actual.
func zoom_actual() -> float:
	var a: ArmaDatos = actual()
	if a.zoom_niveles.size() > 0:
		return a.zoom_niveles[clampi(nivel_zoom, 0, a.zoom_niveles.size() - 1)]
	return a.zoom


## Cambia de nivel de aumento (rueda o segundo clic derecho) si el arma tiene varios. Devuelve verdadero si lo cambio.
func ciclar_zoom(paso: int = 1) -> bool:
	var a: ArmaDatos = actual()
	var n: int = a.zoom_niveles.size()
	if n < 2:
		return false
	nivel_zoom = posmod(nivel_zoom + paso, n)
	return true


## Semiangulo (grados) del cono de dispersion en este instante: velocidad, suelo, postura, apuntar y ceguera.
func dispersion_actual() -> float:
	var a: ArmaDatos = actual()
	if _jugador.corriendo:
		return a.dispersion_correr
	var en_suelo: bool = _jugador.is_on_floor() and not _jugador.vuelo
	var ceg: float = _jugador.ceguera.nivel() if _jugador.ceguera != null else 0.0
	return Balistica.dispersion(a, _jugador.velocidad_horizontal(), en_suelo, _jugador.agachado, aim_t, ceg)


## Se puede disparar armas de fuego: no corriendo y pasada la breve demora tras dejar de correr.
func puede_disparar() -> bool:
	return not _jugador.corriendo and _t + EPS >= _bloqueo_correr_hasta


func _puede_entrada() -> bool:
	return _jugador != null and _jugador.activo and not _jugador.muerto \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


# ------------------------------------------------------------------ entrada

func _unhandled_input(event: InputEvent) -> void:
	if entrada_manual or not _puede_entrada():
		return
	if event.is_action_pressed("arma_1"):
		cambiar_arma(0)
	elif event.is_action_pressed("arma_2"):
		cambiar_arma(1)
	elif event.is_action_pressed("arma_3"):
		cambiar_arma(2)
	elif event.is_action_pressed("arma_4"):
		cambiar_arma(3)
	elif event.is_action_pressed("arma_ultima"):
		cambiar_arma(indice_previo)
	elif event.is_action_pressed("arma_siguiente"):
		if not (apuntando and ciclar_zoom(1)):
			_ciclar(1)
	elif event.is_action_pressed("arma_anterior"):
		if not (apuntando and ciclar_zoom(-1)):
			_ciclar(-1)
	elif event.is_action_pressed("recargar"):
		recargar()
	elif event.is_action_pressed("recoger"):
		recoger()
	elif event.is_action_pressed("tirar_arma"):
		tirar_arma()


func _physics_process(delta: float) -> void:
	if not entrada_manual:
		var ok: bool = _puede_entrada()
		gatillo = ok and Input.is_action_pressed("disparar")
		gatillo_alt = ok and Input.is_action_pressed("disparo_secundario")
	avanzar(delta)


func _process(_delta: float) -> void:
	var m: ArmaSuelo = arma_mirada() if (_jugador != null and not _jugador.muerto and _jugador.activo) else null
	if m != _mirada:
		if _mirada != null and is_instance_valid(_mirada):
			_mirada.resaltar(false)
		_mirada = m
		if _mirada != null:
			_mirada.resaltar(true)


## Lista plana de entradas seleccionables para la rueda: [hueco, utilidad].
func _entradas() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for i in 3:
		if id_en(i) != &"":
			out.append(Vector2i(i, 0))
	for u in inventario.tipos_utilidad().size():
		out.append(Vector2i(3, u))
	return out


func _ciclar(dir: int) -> void:
	var lista: Array[Vector2i] = _entradas()
	if lista.size() < 2:
		return
	var pos: int = lista.find(Vector2i(indice, sel_util if indice == 3 else 0))
	var nuevo: Vector2i = lista[posmod(pos + dir, lista.size())]
	if nuevo.x == 3:
		sel_util = nuevo.y
		if indice == 3:
			_forzar_arma(3)
			return
	cambiar_arma(nuevo.x)


# ------------------------------------------------------------------ simulacion

## Avanza `delta` segundos de simulacion: temporizadores, estados (correr, apuntar, bloquear), gatillo y retroceso.
func avanzar(delta: float) -> void:
	_t += delta
	if cambiando and _t >= _fin_cambio:
		cambiando = false
	if recargando and _t >= _fin_recarga:
		_terminar_recarga()
	if puno_en_vuelo and _t >= _fin_puno:
		_recoger_puno()
	var a: ArmaDatos = actual()
	_actualizar_estados(a, delta)
	if not cambiando and not recargando and _jugador != null and not _jugador.muerto:
		if a.es_utilidad():
			_procesar_utilidad(a)
		else:
			match a.tipo:
				ArmaDatos.T_CUERPO:
					_procesar_cuerpo_a_cuerpo(a)
				ArmaDatos.T_SABLE:
					_procesar_sable(a)
				ArmaDatos.T_PUNO:
					_procesar_carga(a)
				ArmaDatos.T_PROYECTIL:
					if a.carga_tiempo > 0.0:
						_procesar_carga(a)
					else:
						_procesar_disparo(a)
				_:
					_procesar_disparo(a)
	_actualizar_retroceso(a, delta)
	_gatillo_prev = gatillo
	_alt_prev = gatillo_alt


func _actualizar_estados(a: ArmaDatos, delta: float) -> void:
	if _jugador == null:
		return
	if _jugador.corriendo:
		_bloqueo_correr_hasta = _t + DEMORA_CORRER
	var vivo: bool = not _jugador.muerto
	apuntando = vivo and gatillo_alt and a.apuntable and not _jugador.corriendo and not recargando and not cambiando
	aim_t = move_toward(aim_t, 1.0 if apuntando else 0.0, delta / maxf(a.tiempo_apuntar, 0.01))
	bloqueando = vivo and a.tipo == ArmaDatos.T_SABLE and gatillo_alt and not sobrecalentado and not cambiando
	if sobrecalentado:
		if _t >= _fin_sobre:
			sobrecalentado = false
			calor = 0.0
	elif not bloqueando:
		var enf: float = a.enfriamiento if a.tipo == ArmaDatos.T_SABLE else 12.0
		calor = maxf(calor - enf * delta, 0.0)
	if gatillo_alt and not _alt_prev and _t - _t_alt_suelta < 0.45 and aim_t > 0.0:
		ciclar_zoom(1)                       # segundo clic derecho rapido: siguiente nivel de aumento
	if _alt_prev and not gatillo_alt:
		_t_alt_suelta = _t
	var z_obj: float = zoom_actual()
	zoom_vis = z_obj if zoom_vis < 1.0 else lerpf(zoom_vis, z_obj, 1.0 - exp(-14.0 * delta))
	_jugador.fijar_apuntado(aim_t, zoom_vis)
	var m: float = lerpf(1.0, a.velocidad_apuntando, aim_t)
	if bloqueando:
		m *= a.velocidad_bloqueando
	_jugador.mult_velocidad_estado = m


## Callback del escudo de plasma: llamado por `Salud.intenta_bloquear` con la direccion en que viaja el golpe.
## Bloquea si el sable esta en alto (clic derecho), no esta sobrecalentado y el golpe viene del cono frontal.
func _intentar_bloqueo(direccion: Vector3) -> bool:
	if not bloqueando or sobrecalentado or _jugador == null or _jugador.muerto:
		return false
	var a: ArmaDatos = actual()
	var adelante: Vector3 = -_jugador.camara.global_transform.basis.z
	if rad_to_deg(adelante.angle_to(-direccion)) > a.angulo_bloqueo * 0.5:
		return false
	calor = minf(calor + a.calor_por_bloqueo, 100.0)
	bloqueo_realizado.emit()
	_sonar("sable_bloqueo", _p_aux)
	if calor >= 100.0:
		sobrecalentado = true
		bloqueando = false
		_fin_sobre = _t + a.tiempo_sobrecalentado
		_sonar("sable_sobrecalentamiento", _p_recarga)
		sable_sobrecalentado.emit()
	return true


func _procesar_disparo(a: ArmaDatos) -> void:
	if _rafaga_pend > 0:  # rafaga en curso
		if inventario.cargador(id_actual()) <= 0 or not puede_disparar():
			_rafaga_pend = 0
			return
		if _t + EPS >= _proximo:
			_disparar(a)
			_rafaga_pend -= 1
			if _rafaga_pend == 0:
				_proximo = _t + a.pausa_rafaga
		return
	var flanco: bool = gatillo and not _gatillo_prev
	var quiere: bool = gatillo if a.automatica else flanco
	if not quiere:
		return
	if municion_cargador() <= 0:
		if flanco:
			sin_municion.emit()
			_sonar("clic_vacio", _p_aux)
			if auto_recargar:
				recargar()
		return
	if not puede_disparar():
		return
	if _t + EPS >= _proximo:
		_disparar(a)
		if a.rafaga > 1:
			_rafaga_pend = a.rafaga - 1


func _procesar_cuerpo_a_cuerpo(a: ArmaDatos) -> void:
	if _t + EPS < _proximo:
		return
	if gatillo_alt and not _alt_prev:
		_atacar(a, true)
	elif gatillo and not _gatillo_prev:
		_atacar(a, false)


## Sable de plasma: clic izquierdo = golpe en arco; el clic derecho (bloqueo) lo gestiona `_actualizar_estados`.
func _procesar_sable(a: ArmaDatos) -> void:
	if sobrecalentado or _t + EPS < _proximo:
		return
	if gatillo and not _gatillo_prev and not gatillo_alt:
		var cam: Camera3D = _jugador.camara
		var res: Dictionary = Balistica.resolver_arco(cam.global_position, cam.global_transform.basis, a, _jugador, rng)
		Balistica.aplicar_multiple(res, a, _jugador)
		disparos_totales += 1
		_proximo = _t + a.intervalo()
		_sonar(String(a.sonido), _p_disparo)
		ataque_cuerpo.emit(false)
		disparo_realizado.emit(a, res, cam.global_transform * BOCA_LOCAL)
		_emitir_impacto(res)


## Arco y puño-bot: se mantiene el clic izquierdo para cargar y al soltar sale el tiro.
func _procesar_carga(a: ArmaDatos) -> void:
	var es_puno: bool = a.tipo == ArmaDatos.T_PUNO
	if puno_en_vuelo:
		cargando = false
		carga = 0.0
		return
	var flanco: bool = gatillo and not _gatillo_prev
	if gatillo and _t + EPS >= _proximo and puede_disparar():
		if not es_puno and municion_cargador() <= 0:
			if flanco:
				sin_municion.emit()
				_sonar("clic_vacio", _p_aux)
				if auto_recargar:
					recargar()
			return
		if not cargando:
			cargando = true
			_t_carga0 = _t
			if not es_puno:
				_sonar("arco_tensar", _p_recarga)
		carga = clampf((_t - _t_carga0) / maxf(a.carga_tiempo, 0.01), 0.0, 1.0)
	elif cargando:
		cargando = false
		if carga >= CARGA_MINIMA_SOLTAR and puede_disparar():
			_soltar_carga(a, lerpf(a.carga_minima, 1.0, carga))
		carga = 0.0


func _procesar_utilidad(a: ArmaDatos) -> void:
	if _t + EPS < _proximo:
		return
	var flanco: bool = gatillo and not _gatillo_prev
	var flanco_alt: bool = gatillo_alt and not _alt_prev
	if flanco or flanco_alt:
		_lanzar_utilidad(a, flanco)


## Lanza la utilidad seleccionada: clic izquierdo = lanzamiento fuerte, clic derecho = flojo.
func _lanzar_utilidad(a: ArmaDatos, fuerte: bool) -> Lanzable:
	var id: StringName = a.id
	if not inventario.consumir_utilidad(id):
		return null
	var cam: Camera3D = _jugador.camara
	var b: Basis = cam.global_transform.basis
	var dir: Vector3 = -b.z
	var v: Vector3 = (dir + b.y * 0.18).normalized() * (a.velocidad_lanzamiento if fuerte else a.velocidad_lanzamiento_flojo)
	v += _jugador.velocity * 0.4
	var l: Lanzable = Utilidades.lanzar(self, a, cam.global_position + dir * 0.35 - b.y * 0.1, v, _jugador)
	_proximo = _t + 0.9
	_sonar("lanzar", _p_disparo)
	ataque_cuerpo.emit(not fuerte)
	municion_cambiada.emit()
	if inventario.cantidad_utilidad(id) == 0:
		sel_util = 0
		_asegurar_indice(true)
	inventario_cambiado.emit()
	return l


## Un tiro (hitscan, perdigones, proyectil sin carga o cohete) desde la camara con la dispersion del estado actual.
func _disparar(a: ArmaDatos) -> void:
	var cam: Camera3D = _jugador.camara
	var origen: Vector3 = cam.global_position
	var dir: Vector3 = -cam.global_transform.basis.z
	var disp: float = dispersion_actual()
	var res: Dictionary
	match a.tipo:
		ArmaDatos.T_PERDIGONES:
			res = Balistica.resolver_perdigones(origen, dir, a, _jugador, rng, disp)
			Balistica.aplicar_multiple(res, a, _jugador)
		ArmaDatos.T_PROYECTIL, ArmaDatos.T_COHETE:
			var d: Vector3 = Balistica.aplicar_dispersion(dir, disp, rng)
			Proyectil.lanzar(self, a, origen, d * a.velocidad_proyectil, _jugador)
			res = _res_proyectil(origen, d)
		_:
			res = Balistica.resolver_disparo(origen, dir, a, _jugador, rng, disp)
			Balistica.aplicar(res, a, _jugador)
	_tras_disparo(a, res)


func _res_proyectil(origen: Vector3, d: Vector3) -> Dictionary:
	return {"impacto": false, "punto": origen + d * 10.0, "normal": -d, "collider": null, "zona": "",
			"daño": 0.0, "distancia": 10.0, "direccion": d, "salud": null, "fuerte": false}


func _tras_disparo(a: ArmaDatos, res: Dictionary) -> void:
	var cam: Camera3D = _jugador.camara
	var id: StringName = id_actual()
	inventario.fijar_municion(id, inventario.cargador(id) - 1, inventario.reserva(id))
	disparos_totales += 1
	_programar_siguiente(a.intervalo())
	_sumar_retroceso(a)
	_sonar(String(a.sonido), _p_disparo)
	if a.ruido > 0.0:
		SenalesCombate.obtener(get_tree()).ruido.emit(cam.global_position, a.ruido, _jugador)
	disparo_realizado.emit(a, res, cam.global_transform * BOCA_LOCAL)
	_emitir_impacto(res)
	municion_cambiada.emit()


## Suelta el tiro cargado del arco (flecha, dano y velocidad segun la carga) o del puño-bot.
func _soltar_carga(a: ArmaDatos, mult: float) -> void:
	var cam: Camera3D = _jugador.camara
	var origen: Vector3 = cam.global_position
	var d: Vector3 = Balistica.aplicar_dispersion(-cam.global_transform.basis.z, dispersion_actual(), rng)
	var p: Proyectil = Proyectil.lanzar(self, a, origen, d * a.velocidad_proyectil * mult, _jugador, mult)
	var res: Dictionary = _res_proyectil(origen, d)
	if a.tipo == ArmaDatos.T_PUNO:
		puno_en_vuelo = true
		_puno = p
		_fin_puno = _t + a.retorno_tiempo
		disparos_totales += 1
		_proximo = _t + a.intervalo()
		_sonar(String(a.sonido), _p_disparo)
		if a.ruido > 0.0:
			SenalesCombate.obtener(get_tree()).ruido.emit(origen, a.ruido, _jugador)
		disparo_realizado.emit(a, res, cam.global_transform * BOCA_LOCAL)
		return
	_tras_disparo(a, res)
	_proximo = _t + a.intervalo()


func _recoger_puno() -> void:
	puno_en_vuelo = false
	if _puno != null and is_instance_valid(_puno):
		_puno._acabar()
	_puno = null
	_sonar("cambio_arma", _p_aux)


func _atacar(a: ArmaDatos, fuerte: bool) -> void:
	var cam: Camera3D = _jugador.camara
	var origen: Vector3 = cam.global_position
	var dir: Vector3 = -cam.global_transform.basis.z
	var res: Dictionary = Balistica.resolver_disparo(origen, dir, a, _jugador, rng, 0.0, fuerte)
	Balistica.aplicar(res, a, _jugador)
	disparos_totales += 1
	_proximo = _t + (a.intervalo_fuerte if fuerte else a.intervalo())
	_sonar(String(a.sonido), _p_disparo)
	ataque_cuerpo.emit(fuerte)
	disparo_realizado.emit(a, res, cam.global_transform * BOCA_LOCAL)
	_emitir_impacto(res)


func _emitir_impacto(res: Dictionary) -> void:
	var s: Salud = res.get("salud") as Salud
	if s != null and not bool(res.get("bloqueado", false)):
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


# ------------------------------------------------------------------ recarga y cambio

func recargar() -> void:
	var a: ArmaDatos = actual()
	if a.cargador <= 0 or a.es_utilidad() or recargando or cambiando:
		return
	var id: StringName = id_actual()
	if inventario.cargador(id) >= a.cargador or inventario.reserva(id) <= 0:
		return
	cargando = false
	carga = 0.0
	recargando = true
	_inicio_recarga = _t
	_fin_recarga = _t + a.tiempo_recarga
	_sonar("recarga", _p_recarga)
	recarga_iniciada.emit(a)


func _terminar_recarga() -> void:
	recargando = false
	var a: ArmaDatos = actual()
	var id: StringName = id_actual()
	var falta: int = a.cargador - inventario.cargador(id)
	var n: int = mini(falta, inventario.reserva(id))
	inventario.fijar_municion(id, inventario.cargador(id) + n, inventario.reserva(id) - n)
	municion_cambiada.emit()


func cancelar_recarga() -> void:
	if recargando:
		recargando = false
		_p_recarga.stop()
		recarga_cancelada.emit()


## Cambia al hueco `i` (0-3). Cancela la recarga y la carga en curso; no se puede disparar hasta acabar el cambio.
## Pulsar 4 estando en las utilidades pasa a la siguiente utilidad.
func cambiar_arma(i: int) -> void:
	if i < 0 or i > 3 or id_en(i) == &"":
		return
	if i == 3 and indice == 3:
		var n: int = inventario.tipos_utilidad().size()
		if n > 1:
			sel_util = (sel_util + 1) % n
			_forzar_arma(3)
		return
	if i == indice:
		return
	_forzar_arma(i)


func _forzar_arma(i: int) -> void:
	cancelar_recarga()
	cargando = false
	carga = 0.0
	_rafaga_pend = 0
	if i != indice:
		indice_previo = indice
	indice = i
	nivel_zoom = 0
	_aplicar_arma()
	_sonar("cambio_arma", _p_aux)


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


## Si el hueco activo se ha quedado vacio (se tiro el arma, se gasto la ultima granada) pasa a otro con arma.
func _asegurar_indice(_forzar: bool = false) -> void:
	if id_en(indice) != &"":
		return
	for i: int in [indice_previo, 1, 0, 2]:
		if id_en(i) != &"":
			_forzar_arma(i)
			return


# ------------------------------------------------------------------ inventario, suelo y muerte

## Equipa un articulo del catalogo (armero de pruebas, tienda de la Partida o recogida). Si sustituye a un arma que se puede
## soltar, esta cae al suelo. Devuelve false si no se pudo (limite de utilidades...).
func equipar(id: StringName, carg: int = -1, res: int = -1) -> bool:
	var r: Dictionary = inventario.equipar(id, carg, res)
	if not bool(r["ok"]):
		return false
	var soltada: Dictionary = r["soltada"]
	if not soltada.is_empty():
		_soltar_al_suelo(soltada, _delante() * 2.0 + Vector3.UP, _jugador.global_position + Vector3(0, 1.2, 0))
	var hueco: StringName = Catalogo.hueco(id)
	match hueco:
		Inventario.ESCUDO:
			_jugador.salud.escudo = inventario.escudo
		Inventario.PRINCIPAL:
			_forzar_arma(0)
		Inventario.SECUNDARIA:
			_forzar_arma(1)
	inventario_cambiado.emit()
	municion_cambiada.emit()
	return true


## Quita `id` del inventario SIN soltarlo al suelo (la tienda lo usa al vender o devolver). false si no lo tiene.
func quitar(id: StringName) -> bool:
	var hueco: StringName = Catalogo.hueco(id)
	match hueco:
		Inventario.ESCUDO:
			if inventario.escudo <= 0.0:
				return false
			inventario.escudo = 0.0
			_jugador.salud.escudo = 0.0
		Inventario.UTILIDADES:
			if not inventario.consumir_utilidad(id):
				return false
		Inventario.PRINCIPAL, Inventario.SECUNDARIA:
			if inventario.en_hueco(hueco) != id or inventario.soltar(hueco).is_empty():
				return false
			cancelar_recarga()
		_:
			return false
	_asegurar_indice(true)
	inventario_cambiado.emit()
	municion_cambiada.emit()
	return true


func _delante() -> Vector3:
	var f: Vector3 = -_jugador.camara.global_transform.basis.z
	f.y = 0.0
	return f.normalized() if f.length() > 0.01 else Vector3.FORWARD


func _soltar_al_suelo(d: Dictionary, vel: Vector3, pos: Vector3) -> ArmaSuelo:
	var a: ArmaSuelo = ArmaSuelo.crear(self, StringName(d["id"]), int(d["cargador"]), int(d["reserva"]), pos, vel)
	arma_soltada.emit(StringName(d["id"]))
	return a


## G: tira al suelo el arma en mano (principal o secundaria comprada; no la Pistola 9 mm gratuita, ni la navaja).
func tirar_arma() -> bool:
	if _jugador == null or _jugador.muerto:
		return false
	var hueco: StringName = &""
	if indice == 0:
		hueco = Inventario.PRINCIPAL
	elif indice == 1:
		hueco = Inventario.SECUNDARIA
	var d: Dictionary = inventario.soltar(hueco) if hueco != &"" else {}
	if d.is_empty():
		return false
	var cam: Camera3D = _jugador.camara
	var f: Vector3 = -cam.global_transform.basis.z
	cancelar_recarga()
	cargando = false
	carga = 0.0
	_soltar_al_suelo(d, f * 3.2 + Vector3.UP * 1.2, cam.global_position + f * 0.6)
	_asegurar_indice(true)
	inventario_cambiado.emit()
	return true


## Arma del suelo a la que apunta la camara (a menos de DISTANCIA_RECOGER m), la mas centrada. null si no hay.
func arma_mirada() -> ArmaSuelo:
	if _jugador == null:
		return null
	var cam: Camera3D = _jugador.camara
	var o: Vector3 = cam.global_position
	var f: Vector3 = -cam.global_transform.basis.z
	var mejor: ArmaSuelo = null
	var mejor_ang: float = 1000.0
	for n: Node in get_tree().get_nodes_in_group("armas_suelo"):
		var a: ArmaSuelo = n as ArmaSuelo
		var d: Vector3 = a.global_position + Vector3(0, 0.1, 0) - o
		var dist: float = d.length()
		if dist > DISTANCIA_RECOGER or dist < 0.01:
			continue
		var ang: float = f.angle_to(d)
		if ang < atan2(0.5, dist) and ang < mejor_ang:
			mejor = a
			mejor_ang = ang
	return mejor


## E: recoge el arma del suelo mirada (o `objetivo`). Cambia por la del mismo hueco (que cae al suelo) y conserva la municion.
func recoger(objetivo: ArmaSuelo = null) -> bool:
	if _jugador == null or _jugador.muerto:
		return false
	var a: ArmaSuelo = objetivo if objetivo != null else arma_mirada()
	if a == null or not is_instance_valid(a):
		return false
	var id: StringName = a.arma_id
	var r: Dictionary = inventario.equipar(id, a.cargador, a.reserva)
	if not bool(r["ok"]):
		return false
	a.remove_from_group("armas_suelo")
	a.queue_free()
	_mirada = null
	var soltada: Dictionary = r["soltada"]
	if not soltada.is_empty():
		_soltar_al_suelo(soltada, _delante() * 1.0 + Vector3.UP * 0.5, _jugador.global_position + Vector3(0, 0.9, 0))
	var hueco: StringName = Catalogo.hueco(id)
	_forzar_arma(0 if hueco == Inventario.PRINCIPAL else 1)
	_sonar("recoger", _p_aux)
	arma_recogida.emit(id)
	inventario_cambiado.emit()
	return true


## Al morir se sueltan la principal y la secundaria compradas (la Pistola 9 mm y las del kit de reaparicion no).
func soltar_al_morir() -> void:
	cancelar_recarga()
	cargando = false
	carga = 0.0
	_rafaga_pend = 0
	for hueco: StringName in [Inventario.PRINCIPAL, Inventario.SECUNDARIA]:
		var id: StringName = inventario.en_hueco(hueco)
		if not inventario.es_soltable(id) or kit_reaparicion.has(id):
			continue
		var d: Dictionary = inventario.soltar(hueco)
		var ang: float = rng.randf() * TAU
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		_soltar_al_suelo(d, dir * 1.4 + Vector3.UP * 2.0, _jugador.global_position + dir * 0.4 + Vector3(0, 1.0, 0))
	_asegurar_indice()
	inventario_cambiado.emit()


## Quita del mundo todas las armas del suelo (la Partida lo llama al acabar la ronda).
func limpiar_armas_suelo() -> int:
	return ArmaSuelo.limpiar_armas_suelo(get_tree())


## Reaparicion: vuelve al inventario base (Pistola 9 mm, navaja, sin utilidades ni escudo) mas el kit, con municion llena.
func reiniciar() -> void:
	cancelar_recarga()
	inventario.reiniciar_a_base()
	sel_util = 0
	for id: StringName in kit_reaparicion:
		inventario.equipar(id)
	_resetear_estados()
	indice = 0 if inventario.principal != &"" else 1
	indice_previo = 1
	_aplicar_arma()
	inventario_cambiado.emit()


## Municion llena en todas las armas equipadas (sin cambiar el inventario).
func reponer_municion() -> void:
	cancelar_recarga()
	inventario.rellenar_municion()
	_resetear_estados()
	municion_cambiada.emit()


func _resetear_estados() -> void:
	_ret_pitch = 0.0
	_ret_yaw = 0.0
	_rafaga = 0
	_rafaga_pend = 0
	cambiando = false
	cargando = false
	carga = 0.0
	calor = 0.0
	sobrecalentado = false
	bloqueando = false
	aim_t = 0.0
	apuntando = false
	nivel_zoom = 0
	zoom_vis = 1.0
	if puno_en_vuelo:
		_recoger_puno()
	_proximo = _t


func _sonar(clave: String, player: AudioStreamPlayer) -> void:
	if _sonidos.has(clave):
		player.stream = _sonidos[clave]
		player.play()
