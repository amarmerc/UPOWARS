class_name CerebroBot
extends RefCounted
## IA de un `Bot`: percepcion + maquina de estados simple. Solo actua a traves de `ComandosBot` y solo percibe como el jugador:
## vision limitada por distancia y campo de vision, con linea de vision real (`Utilidades.linea_de_vision`: paredes y humo / extintor),
## ceguera (`EstadoCeguera`), ruido (`SenalesCombate.ruido`) y bajas (`SenalesCombate.baja`).
##
## Prioridades de cada tick: ciego -> combate (enemigo visible) -> espera (tras una granada) -> perseguir lo ultimo visto ->
## rutina del rol:
##  - atacante: va (en grupo flexible, ver `DirectorBots.permiso_avanzar`) al site elegido; el portador monta la Cachimba (4 s quieto
##    dentro del site) y los demas escoltan detras de coberturas; montada, defienden alrededor de ella.
##  - defensor: mantiene su posicion de defensa detras de una cobertura del site asignado; rota si el director se lo ordena (ruido o
##    vista del enemigo en el otro site) y, al enterarse de la Cachimba montada, uno (el mas cercano) la apaga y los demas cubren.
##  - cazador (eliminacion): patrulla hacia el enemigo, el centro y los sites, sigue ruidos e informacion de companeros.
##  - libre: deambula por la malla y combate. - estatico: no se mueve (pruebas).
## Cualquier rol recoge del suelo una arma mejor que la suya si esta cerca y usa granadas "de vez en cuando" (`perfil.p_utilidad`).

enum Estado { ESPERA, IR, COMBATE, BUSCAR, MONTAR, APAGAR, DEFENDER, RECOGER, DEAMBULAR, CIEGO }

const UMBRAL_CEGUERA: float = 0.45
const INTERVALO_UTIL: float = 0.8
const MAX_ESPERA_GRUPO: float = 7.0
## Multiplicadores de `perfil.p_utilidad` segun el rol (los atacantes usan mas humo y cegadoras para entrar al site).
const MULT_UTIL_ATAQUE: float = 3.5
const MULT_UTIL_DEFENSA: float = 2.0

var bot: Bot
var estado: Estado = Estado.ESPERA
# asignaciones del director
var site: String = ""
var punto_hold: Vector3 = Vector3.INF
var lleva_cachimba: bool = false
var punto_post: Vector3 = Vector3.INF
# percepcion
var objetivo: Dictionary = {}
var visibles: Array[Dictionary] = []
var ultimo_visto_pos: Vector3 = Vector3.INF
var ultimo_visto_t: float = -1000.0
var ruido_pos: Vector3 = Vector3.INF
var ruido_t: float = -1000.0
# estadisticas (tests)
var n_granadas: int = 0
var n_recogidas: int = 0
var n_objetivos: int = 0

var _t: float = 0.0
var _t_percibir: float = 0.0
var _t_adq: float = 0.0
var _t_vista: float = -1000.0
var _zona_obj: String = "torso"
var _hb_cache: Dictionary = {}
var _espera_hasta: float = 0.0
var _cd_util: float = 0.0
var _t_eval_util: float = 0.0
var _humo_lanzado: bool = false
var _cegadora_lanzada: bool = false
var _t_arma: float = 0.0
var _arma_obj: ArmaSuelo = null
var _t_arma_ini: float = 0.0
var _ruido_sigue: bool = false
var _dano_punto: Vector3 = Vector3.INF
var _dano_hasta: float = -1.0
var _t_llegada: float = -1.0
var _espera_grupo: float = 0.0
var _destino_patrulla: Vector3 = Vector3.INF
var _pausa_patrulla: float = 0.0
var _fase: float = 0.0


func _init(duenio: Bot) -> void:
	bot = duenio
	_fase = float(hash(duenio.name) % 628) / 100.0


func reiniciar() -> void:
	objetivo = {}
	visibles.clear()
	ultimo_visto_pos = Vector3.INF
	ultimo_visto_t = -1000.0
	ruido_pos = Vector3.INF
	ruido_t = -1000.0
	punto_post = Vector3.INF
	_arma_obj = null
	_humo_lanzado = false
	_cegadora_lanzada = false
	_espera_hasta = 0.0
	_destino_patrulla = Vector3.INF
	_t_llegada = -1.0
	estado = Estado.ESPERA


func _dir() -> DirectorBots:
	return bot.director if bot.director != null and is_instance_valid(bot.director) else null


func _partida() -> ApiPartida:
	return bot.partida if bot.partida != null and is_instance_valid(bot.partida) else null


func _cachimba() -> Cachimba:
	var p: ApiPartida = _partida()
	return p.cachimba() if p != null else null


# ------------------------------------------------------------------ bucle principal

func avanzar(dt: float) -> void:
	_t += dt
	_t_percibir -= dt
	if _t_percibir <= 0.0:
		_t_percibir = 0.1 + bot.rng.randf() * 0.04
		_percibir()
	var cm: ComandosBot = bot.comandos
	if bot.ceguera.nivel() > UMBRAL_CEGUERA:
		_ciego()
		return
	if not objetivo.is_empty():
		_combate(dt)
		return
	_recarga_ociosa()
	if _t < _dano_hasta and _dano_punto != Vector3.INF:
		cm.mirar_punto(_dano_punto)
	if _t < _espera_hasta:
		cm.detener()
		estado = Estado.ESPERA
		return
	var p: float = float(bot.perfil["memoria"])
	if ultimo_visto_pos != Vector3.INF and _t - ultimo_visto_t < p and _debe_perseguir():
		_buscar(ultimo_visto_pos, dt)
		return
	_evaluar_utilidad(false, dt)
	if _revisar_arma_suelo(dt):
		return
	match bot.rol:
		Bot.ROL_ATACANTE:
			_rutina_atacante(dt)
		Bot.ROL_DEFENSOR:
			_rutina_defensor(dt)
		Bot.ROL_CAZADOR:
			_rutina_cazador(dt)
		Bot.ROL_LIBRE:
			_rutina_libre(dt)
		_:
			cm.detener()
			estado = Estado.ESPERA


## Los defensores y el portador de la Cachimba no persiguen: mantienen su plan.
func _debe_perseguir() -> bool:
	if bot.rol == Bot.ROL_DEFENSOR or bot.rol == Bot.ROL_ESTATICO:
		return false
	if lleva_cachimba:
		var c: Cachimba = _cachimba()
		return c != null and c.estado != Cachimba.Estado.SIN_MONTAR
	return true


# ------------------------------------------------------------------ percepcion

func _es_enemigo(s: Salud) -> bool:
	return s != bot.salud and (bot.equipo == 0 or s.equipo != bot.equipo)


func _puntos(s: Salud) -> Dictionary:
	var dueno: Node3D = s.get_parent() as Node3D
	var hb: Hitboxes = null
	if _hb_cache.has(s) and is_instance_valid(_hb_cache[s]):
		hb = _hb_cache[s]
	elif dueno != null:
		var hs: Array[Node] = dueno.find_children("*", "Hitboxes", true, false)
		if not hs.is_empty():
			hb = hs[0] as Hitboxes
			_hb_cache[s] = hb
	if hb != null:
		return {"torso": hb.centro_zona("torso"), "cabeza": hb.centro_zona("cabeza")}
	var p: Vector3 = dueno.global_position if dueno != null else Vector3.ZERO
	return {"torso": p + Vector3(0, 1.15, 0), "cabeza": p + Vector3(0, 1.62, 0)}


func _ver(s: Salud, ojos: Vector3, mirada: Vector3) -> Dictionary:
	var pts: Dictionary = _puntos(s)
	var torso: Vector3 = pts["torso"]
	var d: float = ojos.distance_to(torso)
	var alcance: float = float(bot.perfil["vision"])
	var dd: DirectorBots = _dir()
	if bot.rol == Bot.ROL_DEFENSOR:
		alcance = minf(alcance, dd.vision_defensor() if dd != null else DirectorBots.VISION_DEFENSOR_M)   # esperan: no inician duelos lejanos
	elif bot.rol == Bot.ROL_ATACANTE and dd != null:
		alcance = dd.vision_atacante(alcance)
	if d > alcance:
		return {}
	var ang: float = rad_to_deg(mirada.angle_to(torso - ojos))
	if ang > float(bot.perfil["fov"]) * 0.5 and d > 6.0:
		return {}
	var ok_t: bool = Utilidades.linea_de_vision(bot, ojos, torso)
	var ok_c: bool = Utilidades.linea_de_vision(bot, ojos, pts["cabeza"])
	if not ok_t and not ok_c:
		return {}
	return {"salud": s, "nodo": s.get_parent(), "torso": torso, "cabeza": pts["cabeza"], "dist": d,
			"ve_torso": ok_t, "ve_cabeza": ok_c}


func _percibir() -> void:
	visibles.clear()
	var ojos: Vector3 = bot.ojos()
	var mirada: Vector3 = bot.mirada_dir()
	if bot.ceguera.nivel() <= UMBRAL_CEGUERA:
		for n: Node in bot.get_tree().get_nodes_in_group("salud"):
			var s: Salud = n as Salud
			if s == null or not s.vivo or not _es_enemigo(s):
				continue
			var v: Dictionary = _ver(s, ojos, mirada)
			if not v.is_empty():
				visibles.append(v)
		visibles.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["dist"]) < float(b["dist"]))
		_percibir_cachimba(ojos, mirada)
	var previo: Salud = objetivo["salud"] as Salud if not objetivo.is_empty() else null
	var elegido: Dictionary = {}
	if previo != null:
		for v: Dictionary in visibles:
			if v["salud"] == previo:
				elegido = v
	if elegido.is_empty() and not visibles.is_empty():
		elegido = visibles[0]
	if elegido.is_empty():
		if not objetivo.is_empty() and (_t - _t_vista > 0.4 or not (objetivo["salud"] as Salud).vivo):
			objetivo = {}
		_percibir_marcados()
		return
	if objetivo.is_empty() or objetivo["salud"] != elegido["salud"]:
		_t_adq = _t
		_zona_obj = "cabeza" if bot.rng.randf() < float(bot.perfil["p_cabeza"]) else "torso"
		bot.comandos.nuevo_objetivo()
		n_objetivos += 1
	objetivo = elegido
	_t_vista = _t
	ultimo_visto_pos = elegido["torso"]
	ultimo_visto_t = _t
	var d: DirectorBots = _dir()
	if d != null:
		d.reportar_vista(bot, elegido["torso"])


## Los enemigos marcados con el bote de pintura (aunque haya paredes) pasan a ser "lo ultimo visto".
func _percibir_marcados() -> void:
	if bot.equipo == 0:
		return
	var mejor: Vector3 = Vector3.INF
	var md: float = 1000000.0
	for s: Salud in Utilidades.marcados_para(bot, bot.equipo):
		var pts: Dictionary = _puntos(s)
		var d: float = bot.global_position.distance_to(pts["torso"])
		if d < md and d < 60.0:
			md = d
			mejor = pts["torso"]
	if mejor != Vector3.INF:
		ultimo_visto_pos = mejor
		ultimo_visto_t = _t


## Si ve la Cachimba montada (a menos de 50 m, en su campo de vision y sin paredes) se lo cuenta al director.
func _percibir_cachimba(ojos: Vector3, mirada: Vector3) -> void:
	var c: Cachimba = _cachimba()
	var d: DirectorBots = _dir()
	if c == null or d == null or bot.rol != Bot.ROL_DEFENSOR or d.cachimba_conocida:
		return
	if c.estado != Cachimba.Estado.MONTADA and c.estado != Cachimba.Estado.MONTANDO:
		return
	var p: Vector3 = c.global_position + Vector3(0, 0.4, 0)
	if ojos.distance_to(p) < 50.0 and rad_to_deg(mirada.angle_to(p - ojos)) < float(bot.perfil["fov"]) * 0.5 \
			and Utilidades.linea_de_vision(bot, ojos, p):
		d.avisar_cachimba(bot)


func on_ruido(posicion: Vector3, radio: float, fuente: Node) -> void:
	if fuente == bot or bot.global_position.distance_to(posicion) > radio:
		return
	var s: Salud = Salud.de(fuente) if fuente != null else null
	if s != null and not _es_enemigo(s):
		return
	var d: DirectorBots = _dir()
	if fuente is Cachimba:
		if d != null and bot.rol == Bot.ROL_DEFENSOR:
			d.avisar_cachimba(bot)
		return
	ruido_pos = posicion
	ruido_t = _t
	_ruido_sigue = bot.rng.randf() < float(bot.perfil["sigue_ruido"])
	if d != null:
		d.reportar_ruido(bot, posicion)
	if objetivo.is_empty():
		_dano_punto = Vector3(posicion.x, bot.ojos().y, posicion.z)
		_dano_hasta = _t + 1.2


func on_baja(_atacante: Node, victima: Salud) -> void:
	if victima == bot.salud or bot.equipo == 0 or victima.equipo != bot.equipo:
		return
	var dueno: Node3D = victima.get_parent() as Node3D
	if dueno != null and bot.global_position.distance_to(dueno.global_position) < 60.0:
		ruido_pos = dueno.global_position
		ruido_t = _t
		_ruido_sigue = bot.rol != Bot.ROL_DEFENSOR
		var d: DirectorBots = _dir()
		if d != null:
			d.reportar_ruido(bot, dueno.global_position)


func on_herido(atacante: Node) -> void:
	var n3: Node3D = atacante as Node3D
	if n3 == null:
		return
	var s: Salud = Salud.de(atacante)
	if s != null and not _es_enemigo(s):
		return
	var p: Vector3 = n3.global_position + Vector3(0, 1.2, 0)
	if objetivo.is_empty():
		ultimo_visto_pos = p
		ultimo_visto_t = _t
		_dano_punto = p
		_dano_hasta = _t + 1.0


# ------------------------------------------------------------------ combate

func _combate(dt: float) -> void:
	estado = Estado.COMBATE
	var cm: ComandosBot = bot.comandos
	_refrescar_objetivo()
	var o: Dictionary = objetivo
	var dist: float = float(o["dist"])
	var punto: Vector3
	if _zona_obj == "cabeza" and bool(o["ve_cabeza"]):
		punto = o["cabeza"]
	elif bool(o["ve_torso"]):
		punto = o["torso"]
	else:
		punto = o["cabeza"]
	cm.mirar_punto(punto, true)
	_gestionar_arma()
	var A: ArmasBot = bot.armas
	var a: ArmaDatos = A.actual()
	var cuerpo_a_cuerpo: bool = a != null and a.tipo == ArmaDatos.T_CUERPO
	var corto: bool = a != null and a.alcance < 45.0 and a.tipo != ArmaDatos.T_CUERPO
	if cuerpo_a_cuerpo and bot.rol != Bot.ROL_DEFENSOR:
		cm.mover_hacia(o["torso"])
	elif corto and dist > 12.0 and bot.rol != Bot.ROL_DEFENSOR and not lleva_cachimba:
		cm.mover_hacia(o["torso"])
	elif bool(bot.perfil["quieto_al_disparar"]):
		cm.detener()
	if _t - _t_adq >= float(bot.perfil["reaccion"]):
		cm.disparar(true)
	_montar_en_combate(dist)
	_evaluar_utilidad(true, dt)


## El portador que ya esta dentro del site y quieto sigue montando la Cachimba mientras dispara (los 4 s los pasa quieto igualmente)
## si el enemigo no esta encima (> 7 m) y tiene compania; asi la Cachimba se monta aunque haya tiros en el site.
func _montar_en_combate(dist: float) -> void:
	if not lleva_cachimba or site == "":
		return
	var c: Cachimba = _cachimba()
	var d: DirectorBots = _dir()
	if c == null or d == null or d.zona == null:
		return
	if c.estado != Cachimba.Estado.SIN_MONTAR and c.estado != Cachimba.Estado.MONTANDO:
		return
	if d.zona.site_en(bot.global_position) != site or not (d.escolta_cerca(bot) or c.estado == Cachimba.Estado.MONTANDO):
		return
	if dist > 7.0 or c.estado == Cachimba.Estado.MONTANDO:
		bot.comandos.detener()
		bot.comandos.montar_cachimba(true)


## Actualiza las posiciones del objetivo con las del cuerpo vivo mientras se le ve (la mira sigue a un objetivo que se mueve).
func _refrescar_objetivo() -> void:
	if _t - _t_vista > 0.2:
		return
	var s: Salud = objetivo["salud"] as Salud
	if s == null or not s.vivo:
		return
	var pts: Dictionary = _puntos(s)
	objetivo["torso"] = pts["torso"]
	objetivo["cabeza"] = pts["cabeza"]
	objetivo["dist"] = bot.ojos().distance_to(pts["torso"])


func _hueco_preferido() -> int:
	var A: ArmasBot = bot.armas
	for i in [0, 1]:
		var id: StringName = A.id_en(i)
		if id != &"" and A.inventario.cargador(id) > 0:
			return i
	for i in [0, 1]:
		var id: StringName = A.id_en(i)
		if id != &"" and A.inventario.reserva(id) > 0:
			return i
	return 2


func _gestionar_arma() -> void:
	var A: ArmasBot = bot.armas
	var pref: int = _hueco_preferido()
	if pref != A.indice and not A.cambiando:
		bot.comandos.cambiar_arma(pref)
	elif A.cargador_actual() <= 0 and A.reserva_actual() > 0 and not A.recargando and A.actual().cargador > 0:
		bot.comandos.recargar()


func _recarga_ociosa() -> void:
	var A: ArmasBot = bot.armas
	if _t - ultimo_visto_t > 1.5 and not A.recargando and not A.cargador_lleno() and A.reserva_actual() > 0:
		var a: ArmaDatos = A.actual()
		if a != null and a.cargador > 0 and A.cargador_actual() * 2 < a.cargador:
			bot.comandos.recargar()
	var mejor: int = _hueco_preferido()
	if mejor != A.indice and mejor != 2 and not A.cambiando and objetivo.is_empty():
		bot.comandos.cambiar_arma(mejor)


## Ciego: se queda quieto, mira donde vio por ultima vez al enemigo y, si fue hace poco, dispara "a ciegas" (con la dispersion
## extra de la ceguera que ya anade `ComandosBot.dispersion_actual`).
func _ciego() -> void:
	estado = Estado.CIEGO
	var cm: ComandosBot = bot.comandos
	cm.detener()
	if ultimo_visto_pos != Vector3.INF and _t - ultimo_visto_t < 2.5:
		cm.mirar_punto(ultimo_visto_pos, true)
		_gestionar_arma()
		cm.disparar(true)


# ------------------------------------------------------------------ utilidades (granadas)

func _evaluar_utilidad(visible: bool, dt: float) -> void:
	var inv: Inventario = bot.armas.inventario
	if inv.utilidades.is_empty() or _t < _cd_util:
		return
	_t_eval_util += dt
	if _t_eval_util < INTERVALO_UTIL:
		return
	_t_eval_util = 0.0
	var cm: ComandosBot = bot.comandos
	var ojos: Vector3 = bot.ojos()
	var d: DirectorBots = _dir()
	var atacante: bool = bot.rol == Bot.ROL_ATACANTE
	# los atacantes usan mas las granadas (humo y cegadora para entrar al site); el resto, con la probabilidad del perfil
	var p_util: float = float(bot.perfil["p_utilidad"]) * (MULT_UTIL_ATAQUE if atacante else MULT_UTIL_DEFENSA)
	# A/B: enemigo visible o recien visto
	var objetivo_pos: Vector3 = Vector3.INF
	if visible and not objetivo.is_empty():
		objetivo_pos = objetivo["torso"]
	elif ultimo_visto_pos != Vector3.INF and _t - ultimo_visto_t < 3.0:
		objetivo_pos = ultimo_visto_pos
	if objetivo_pos != Vector3.INF:
		var dist: float = ojos.distance_to(objetivo_pos)
		# humo de cobertura: el atacante que ve al enemigo lejos corta la linea de vision a medio camino y sigue su avance
		if atacante and dist >= 18.0 and inv.cantidad_utilidad(&"granada_humo") > 0 and (d == null or d.permitir_humo(bot)):
			var medio: Vector3 = ojos.lerp(objetivo_pos, 0.6)
			if cm.lanzar_utilidad(&"granada_humo", medio - Vector3(0, 1.2, 0), true):
				_tras_lanzar(&"granada_humo")
				if d != null:
					d.anotar_humo(bot.equipo)
				return
		if bot.rng.randf() < p_util and dist >= 8.0 and dist <= 26.0:
			var cand: Array[StringName] = [&"granada_explosiva", &"granada_cegadora"]
			if atacante:
				cand = [&"granada_cegadora", &"granada_explosiva"]
			for id: StringName in cand:
				if inv.cantidad_utilidad(id) > 0 and cm.lanzar_utilidad(id, objetivo_pos - Vector3(0, 0.9, 0), true):
					_tras_lanzar(id)
					return
	# C: entrada al site: humo (una por equipo y ronda) y cegadora hacia donde estaran los defensores
	if atacante and site != "" and objetivo.is_empty() and d != null and d.zona != null and not lleva_cachimba:
		var c: Vector3 = d.zona.centro_site(site)
		var dd: float = ojos.distance_to(c)
		if dd >= 12.0 and dd <= 30.0:
			if not _humo_lanzado and inv.cantidad_utilidad(&"granada_humo") > 0 and d.permitir_humo(bot):
				var al: Vector3 = c + d.direccion_defensores_desde(c) * 4.0
				if cm.lanzar_utilidad(&"granada_humo", al, true):
					_humo_lanzado = true
					d.anotar_humo(bot.equipo)
					_tras_lanzar(&"granada_humo")
					return
			if not _cegadora_lanzada and inv.cantidad_utilidad(&"granada_cegadora") > 0 and dd <= 24.0 and bot.rng.randf() < minf(p_util * 3.0, 0.9):
				var al2: Vector3 = c + d.direccion_defensores_desde(c) * 6.0
				if cm.lanzar_utilidad(&"granada_cegadora", al2, true):
					_cegadora_lanzada = true
					_tras_lanzar(&"granada_cegadora")


func _tras_lanzar(id: StringName) -> void:
	n_granadas += 1
	_cd_util = _t + 5.0
	if id == &"granada_cegadora":
		_espera_hasta = _t + 1.8


# ------------------------------------------------------------------ armas del suelo

## Va a recoger un arma del suelo mejor que la suya si esta cerca. Devuelve true si esta ocupado con ello.
func _revisar_arma_suelo(dt: float) -> bool:
	if lleva_cachimba:
		return false
	var c: Cachimba = _cachimba()
	if bot.rol == Bot.ROL_DEFENSOR and c != null and c.esta_montada():
		return false
	if _arma_obj != null and (not is_instance_valid(_arma_obj) or _t - _t_arma_ini > 14.0 or not _vale(_arma_obj)):
		_arma_obj = null
	_t_arma -= dt
	if _arma_obj == null and _t_arma <= 0.0:
		_t_arma = 1.0
		var radio: float = 8.0 if bot.rol == Bot.ROL_DEFENSOR else (14.0 if bot.rol == Bot.ROL_ATACANTE else 20.0)
		var mejor: ArmaSuelo = null
		var md: float = radio
		for n: Node in bot.get_tree().get_nodes_in_group("armas_suelo"):
			var a: ArmaSuelo = n as ArmaSuelo
			var d: float = a.global_position.distance_to(bot.global_position)
			if d < md and a.quieta and _vale(a):
				md = d
				mejor = a
		if mejor != null:
			_arma_obj = mejor
			_t_arma_ini = _t
	if _arma_obj == null:
		return false
	estado = Estado.RECOGER
	if _arma_obj.global_position.distance_to(bot.global_position) < ArmasBot.DISTANCIA_RECOGER - 0.4:
		bot.comandos.detener()
		if bot.comandos.recoger_arma(_arma_obj):
			n_recogidas += 1
		_arma_obj = null
		return false
	bot.comandos.mover_hacia(_arma_obj.global_position)
	return true


## Un arma del suelo vale la pena si es de un hueco que mejora (principal sin tener, o de mas precio; secundaria base) y tiene municion.
func _vale(a: ArmaSuelo) -> bool:
	if ArmasBot.NO_SOPORTADAS.has(a.arma_id) or a.cargador + a.reserva <= 0:
		return false
	var hueco: StringName = Catalogo.hueco(a.arma_id)
	var inv: Inventario = bot.armas.inventario
	var precio: int = Catalogo.precio(a.arma_id)
	if hueco == Inventario.PRINCIPAL:
		return inv.principal == &"" or precio > Catalogo.precio(inv.principal)
	if hueco == Inventario.SECUNDARIA:
		return precio > Catalogo.precio(inv.secundaria) and a.arma_id != Inventario.PISTOLA_BASE
	return false


# ------------------------------------------------------------------ rutinas de rol

func _mantener(punto: Vector3, mirar_a: Vector3, tol: float = 1.2) -> void:
	var cm: ComandosBot = bot.comandos
	var p: Vector3 = punto if punto != Vector3.INF else bot.global_position
	var d: float = Vector2(p.x - bot.global_position.x, p.z - bot.global_position.z).length()
	if d > tol:
		cm.mover_hacia(p)
		estado = Estado.IR
		return
	cm.detener()
	estado = Estado.DEFENDER
	if _t < _dano_hasta and _dano_punto != Vector3.INF:
		return
	if mirar_a != Vector3.INF:
		var ojos: Vector3 = bot.ojos()
		var h := Vector3(mirar_a.x - ojos.x, 0.0, mirar_a.z - ojos.z)
		if h.length() > 0.5:
			h = h.normalized().rotated(Vector3.UP, sin(_t * 0.45 + _fase) * 0.6)
			cm.mirar_punto(ojos + h * 20.0)


func _buscar(pos: Vector3, _dt: float) -> void:
	estado = Estado.BUSCAR
	var cm: ComandosBot = bot.comandos
	var d: float = Vector2(pos.x - bot.global_position.x, pos.z - bot.global_position.z).length()
	if d < 2.5:
		cm.detener()
		ultimo_visto_pos = Vector3.INF
		return
	cm.mover_hacia(pos)


func _rutina_atacante(dt: float) -> void:
	var c: Cachimba = _cachimba()
	var d: DirectorBots = _dir()
	if c == null or d == null or d.zona == null or site == "":
		_rutina_cazador(dt)
		return
	match c.estado:
		Cachimba.Estado.APAGADA, Cachimba.Estado.ALARMA:
			_rutina_cazador(dt)
		Cachimba.Estado.MONTADA, Cachimba.Estado.APAGANDO:
			if punto_post == Vector3.INF:
				punto_post = d.punto_post_plant(bot)
			_mantener(punto_post, d.direccion_defensores_desde(c.global_position))
		_:
			var centro: Vector3 = d.zona.centro_site(site)
			var caida: Node3D = _partida().cachimba_caida() if _partida() != null else null
			if d.recogedor == bot and caida != null:
				estado = Estado.IR
				bot.comandos.mover_hacia(caida.global_position)
			elif lleva_cachimba:
				_montar(c, centro, d, dt)
			elif c.estado == Cachimba.Estado.MONTANDO:
				_mantener(bot.global_position, c.global_position)
			else:
				_escoltar(centro, d, dt)


## Grupo flexible: el director puede pedir que espere a los companeros, pero nunca mas de MAX_ESPERA_GRUPO s seguidos.
func _permitido_avanzar(d: DirectorBots, dt: float) -> bool:
	if d.permiso_avanzar(bot):
		_espera_grupo = 0.0
		return true
	_espera_grupo += dt
	return _espera_grupo >= MAX_ESPERA_GRUPO


func _montar(c: Cachimba, centro: Vector3, d: DirectorBots, dt: float) -> void:
	var cm: ComandosBot = bot.comandos
	var destino: Vector3 = d.punto_montaje(site)
	var dist: float = Vector2(destino.x - bot.global_position.x, destino.z - bot.global_position.z).length()
	var en_site: bool = d.zona.site_en(bot.global_position) == site
	if dist > 1.2 and not (en_site and dist < 2.5 and _t_llegada >= 0.0):
		if not _permitido_avanzar(d, dt):
			cm.detener()
			estado = Estado.ESPERA
			return
		cm.mover_hacia(destino)
		estado = Estado.IR
		return
	cm.detener()
	estado = Estado.MONTAR
	if _t_llegada < 0.0:
		_t_llegada = _t
	var espera: float = _t - _t_llegada
	var compania: bool = d.escolta_cerca(bot) or espera > 5.0
	cm.mirar_punto(centro + d.direccion_defensores_desde(centro) * 12.0 + Vector3(0, 1.4, 0))
	if espera > 0.8 and compania and c.estado != Cachimba.Estado.MONTADA:
		cm.montar_cachimba(true)


func _escoltar(centro: Vector3, d: DirectorBots, dt: float) -> void:
	var cm: ComandosBot = bot.comandos
	var p: Vector3 = punto_hold if punto_hold != Vector3.INF else centro
	if not _permitido_avanzar(d, dt):
		cm.detener()
		estado = Estado.ESPERA
		return
	_mantener(p, centro)


func _rutina_defensor(_dt: float) -> void:
	var c: Cachimba = _cachimba()
	var d: DirectorBots = _dir()
	if c != null and d != null and d.cachimba_conocida and (c.estado == Cachimba.Estado.MONTADA \
			or c.estado == Cachimba.Estado.APAGANDO or c.estado == Cachimba.Estado.MONTANDO):
		if d.apagador == bot and c.estado != Cachimba.Estado.MONTANDO:
			_apagar(c)
		else:
			_mantener(d.punto_cobertura_apagado(bot), c.global_position)
		return
	var centro: Vector3 = d.zona.centro_site(site) if (d != null and d.zona != null and site != "") else Vector3.INF
	var mirar: Vector3 = Vector3.INF
	if d != null and centro != Vector3.INF:
		mirar = centro + d.direccion_atacantes_desde(centro) * 25.0
	if ruido_pos != Vector3.INF and _t - ruido_t < 4.0 and centro != Vector3.INF and ruido_pos.distance_to(centro) < 40.0:
		mirar = ruido_pos
	_mantener(punto_hold, mirar)


func _apagar(c: Cachimba) -> void:
	var cm: ComandosBot = bot.comandos
	var dist: float = Vector2(c.global_position.x - bot.global_position.x, c.global_position.z - bot.global_position.z).length()
	if dist > Cachimba.RADIO_APAGAR - 1.2:
		cm.mover_hacia(c.global_position)
		estado = Estado.IR
		return
	cm.detener()
	estado = Estado.APAGAR
	cm.mirar_punto(c.global_position + Vector3(0, 0.3, 0))
	cm.apagar_cachimba(true)


func _rutina_cazador(dt: float) -> void:
	var cm: ComandosBot = bot.comandos
	var d: DirectorBots = _dir()
	# informacion de companeros / ruido reciente
	if ruido_pos != Vector3.INF and _t - ruido_t < 8.0 and _ruido_sigue:
		if bot.global_position.distance_to(ruido_pos) > 3.0:
			estado = Estado.BUSCAR
			cm.mover_hacia(ruido_pos)
			return
		ruido_pos = Vector3.INF
	if d != null:
		var intel: Vector3 = d.intel_enemiga(bot)
		if intel != Vector3.INF and bot.global_position.distance_to(intel) > 4.0:
			estado = Estado.BUSCAR
			cm.mover_hacia(intel)
			return
	_patrullar(d, dt)


func _patrullar(d: DirectorBots, dt: float) -> void:
	var cm: ComandosBot = bot.comandos
	estado = Estado.IR
	if _pausa_patrulla > 0.0:
		_pausa_patrulla -= dt
		cm.detener()
		cm.mirar_punto(bot.ojos() + Vector3(sin(_t + _fase), 0.0, cos(_t + _fase)) * 10.0)
		return
	if _destino_patrulla == Vector3.INF or (cm.llego and bot.global_position.distance_to(_destino_patrulla) < 3.0):
		if _destino_patrulla != Vector3.INF:
			_pausa_patrulla = 0.6
			_destino_patrulla = Vector3.INF
			return
		_destino_patrulla = d.siguiente_patrulla(bot) if d != null else _punto_cercano_azar(40.0)
	cm.mover_hacia(_destino_patrulla)


func _rutina_libre(dt: float) -> void:
	var cm: ComandosBot = bot.comandos
	if ruido_pos != Vector3.INF and _t - ruido_t < 8.0 and _ruido_sigue:
		if bot.global_position.distance_to(ruido_pos) > 3.0:
			estado = Estado.BUSCAR
			cm.mover_hacia(ruido_pos)
			return
		ruido_pos = Vector3.INF
	estado = Estado.DEAMBULAR
	if _pausa_patrulla > 0.0:
		_pausa_patrulla -= dt
		cm.detener()
		return
	if _destino_patrulla == Vector3.INF or (cm.llego and bot.global_position.distance_to(_destino_patrulla) < 3.0):
		if _destino_patrulla != Vector3.INF:
			_pausa_patrulla = bot.rng.randf_range(0.3, 1.5)
			_destino_patrulla = Vector3.INF
			return
		_destino_patrulla = _punto_cercano_azar(70.0)
	cm.mover_hacia(_destino_patrulla)


func _punto_cercano_azar(radio: float) -> Vector3:
	var ang: float = bot.rng.randf() * TAU
	var r: float = bot.rng.randf_range(radio * 0.3, radio)
	var p := bot.global_position + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
	return NavigationServer3D.map_get_closest_point(bot.get_world_3d().navigation_map, p)
