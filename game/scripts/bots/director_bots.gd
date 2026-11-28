class_name DirectorBots
extends Node
## Coordina a los bots de una partida: reparte roles y sites, designa al portador de la Cachimba y al que la apaga, calcula los
## puntos tacticos (detras de coberturas) y comparte informacion entre companeros (vistas, ruidos, la Cachimba montada).
## No decide por ellos: cada `CerebroBot` consulta al director (`permiso_avanzar`, `punto_*`, `intel_enemiga`...).
## Uso: `configurar(...)`, `agregar(bot)` para cada bot y `preparar()` (con la malla de navegacion ya lista). Sin zona ni partida
## (modo libre) los bots son `libre` y no hace falta director.
##  - Cachimba: los atacantes eligen un site (al azar), el portador es uno de ellos (si muere lo hereda otro) y van en grupo
##    flexible; los defensores se reparten los dos sites (3/2) y el volante rota al site con presion.
##  - Eliminacion: todos cazadores; pasados 40 s sin bajas se dirigen al spawn enemigo.

## Alcance (m) con el que un defensor detecta enemigos (los defensores esperan, no inician duelos lejanos). Ajustado por zona con
## `tests/sim_partida.gd` para equilibrar la tasa de victoria por bando (las zonas abiertas favorecen a quien ve mas lejos).
const VISION_DEFENSOR_M: float = 70.0
## Ajuste por zona (id -> alcance en m) de defensores y atacantes: las zonas abiertas favorecen a quien ve mas lejos. Medido con 3 semillas x 24
## rondas por zona con `tests/sim_partida.gd` (ver README); 80 = sin limite con el perfil normal.
const VISION_DEFENSOR_ZONA: Dictionary = {"plaza_america": 80.0, "biblioteca_24": 67.0, "detras_22": 47.0}
const VISION_ATACANTE_ZONA: Dictionary = {"el_eje": 69.0}
const PRESION_S: float = 6.0
const INTERVALO_REVISION: float = 0.5

var zona: ZonaActiva = null
var partida: ApiPartida = null
var modo: StringName = &"cachimba"
var mapa: RID
var rng := RandomNumberGenerator.new()
var bots: Array[Bot] = []
var site_ataque: String = "A"
var portador: Bot = null
var apagador: Bot = null
## Bot que va a recoger la Cachimba caida (solo con una `Partida` que exige portador).
var recogedor: Bot = null
var cachimba_conocida: bool = false
var rotaciones: int = 0
## Instante (t_ronda) del ultimo humo lanzado por cada equipo (evita lanzar cinco seguidos).
var _t_humo: Dictionary = {}
## Tiempo transcurrido desde `preparar()` (s).
var t_ronda: float = 0.0

var _puntos_defensa: Dictionary = {}
var _puntos_escolta: Dictionary = {}
var _puntos_montaje: Dictionary = {}
var _puntos_post: Array[Vector3] = []
var _puntos_apagado: Array[Vector3] = []
var _presion: Dictionary = {}
var _intel: Dictionary = {}
var _volante: Bot = null
var _t: float = 0.0
var _t_rev: float = 0.0
var _estado_cachimba_prev: int = -1
var _ult_baja_t: float = 0.0


func configurar(zona_activa: ZonaActiva, api: ApiPartida, modo_juego: StringName, mapa_nav: RID, semilla: int = 1) -> void:
	zona = zona_activa
	partida = api
	modo = modo_juego
	mapa = mapa_nav
	rng.seed = semilla
	SenalesCombate.obtener(get_tree()).baja.connect(_on_baja)


func agregar(bot: Bot) -> void:
	if not bots.has(bot):
		bots.append(bot)
	bot.director = self
	bot.partida = partida


func _on_baja(_a: Node, _v: Salud, _arma: ArmaDatos) -> void:
	_ult_baja_t = t_ronda


# ------------------------------------------------------------------ preparacion

func equipo_de(equipo: int) -> Array[Bot]:
	var out: Array[Bot] = []
	for b: Bot in bots:
		if b.equipo == equipo and is_instance_valid(b):
			out.append(b)
	return out


func vivos_de(equipo: int) -> Array[Bot]:
	var out: Array[Bot] = []
	for b: Bot in equipo_de(equipo):
		if not b.muerto:
			out.append(b)
	return out


func _centro_spawns(equipo_txt: String) -> Vector3:
	var c := Vector3.ZERO
	var n: int = zona.n_spawns(equipo_txt)
	for i in n:
		c += zona.punto_spawn(equipo_txt, i)["pos"]
	return c / maxf(float(n), 1.0)


## Reparte roles y puntos. Llamar con la malla de navegacion lista y los bots ya agregados.
func preparar() -> void:
	t_ronda = 0.0
	_ult_baja_t = 0.0
	cachimba_conocida = false
	portador = null
	apagador = null
	_volante = null
	_presion.clear()
	_intel.clear()
	_t_humo.clear()
	_puntos_post.clear()
	_puntos_apagado.clear()
	_estado_cachimba_prev = -1
	recogedor = null
	_t_rev = 0.0
	for b: Bot in bots:
		b.cerebro.site = ""
		b.cerebro.punto_hold = Vector3.INF
		b.cerebro.punto_post = Vector3.INF
		b.cerebro.lleva_cachimba = false
		b.cerebro.reiniciar()
	if zona == null:
		for b: Bot in bots:
			if b.rol != Bot.ROL_ESTATICO:
				b.rol = Bot.ROL_LIBRE
		return
	if modo == &"eliminacion":
		for b: Bot in bots:
			if b.rol != Bot.ROL_ESTATICO:
				b.rol = Bot.ROL_CAZADOR
		return
	_preparar_cachimba()


func _preparar_cachimba() -> void:
	var c_atq: Vector3 = _centro_spawns("atacantes")
	var c_def: Vector3 = _centro_spawns("defensores")
	site_ataque = "A" if rng.randf() < 0.5 else "B"
	for s: String in ["A", "B"]:
		var centro: Vector3 = zona.centro_site(s)
		_puntos_defensa[s] = PuntosTacticos.puntos_defensa(mapa, centro, c_atq, 6, 4.0, 22.0, rng, zona, 3.5, 10.0)
		_puntos_escolta[s] = PuntosTacticos.puntos_defensa(mapa, centro, c_def, 6, 7.0, 24.0, rng, zona, 3.5, 13.0)
		_puntos_montaje[s] = _punto_montaje(s)
	# atacantes: site elegido, escoltas y portador
	var atq: Array[Bot] = equipo_de(Bot.EQ_ATACANTES)
	var i: int = 0
	for b: Bot in atq:
		if b.rol == Bot.ROL_ESTATICO:
			continue
		b.rol = Bot.ROL_ATACANTE
		b.cerebro.site = site_ataque
		var lista: Array = _puntos_escolta[site_ataque]
		if not lista.is_empty():
			b.cerebro.punto_hold = lista[i % lista.size()]
		i += 1
	_designar_portador()
	# defensores: reparto 3/2 entre los sites (el sitio con 3 se elige al azar); el ultimo es el volante
	var defs: Array[Bot] = equipo_de(Bot.EQ_DEFENSORES)
	var extra: String = "A" if rng.randf() < 0.5 else "B"
	var usados: Dictionary = {"A": 0, "B": 0}
	for k in defs.size():
		var b: Bot = defs[k]
		if b.rol == Bot.ROL_ESTATICO:
			continue
		b.rol = Bot.ROL_DEFENSOR
		var s: String = extra if k % 2 == 0 else ("B" if extra == "A" else "A")
		_asignar_defensa(b, s, int(usados[s]))
		usados[s] = int(usados[s]) + 1
		if k == defs.size() - 1 and defs.size() >= 4:
			_volante = b
	# puntos alrededor del futuro sitio de la Cachimba (post-plant): se calculan al montarse


func _punto_montaje(s: String) -> Vector3:
	var centro: Vector3 = zona.centro_site(s)
	var p: Vector3 = PuntosTacticos.navegable(mapa, centro, centro.y, 3.0)
	if p != Vector3.INF and zona.site_en(p) == s:
		return p
	var cand: Array[Vector3] = PuntosTacticos.puntos_anillo(mapa, centro, 6, 1.0, float(zona.zona["sites"][s]["radio"]) * 0.7, rng, zona, 1.0)
	for q: Vector3 in cand:
		if zona.site_en(q) == s:
			return q
	return centro


func _asignar_defensa(b: Bot, s: String, idx: int) -> void:
	b.cerebro.site = s
	var lista: Array = _puntos_defensa.get(s, [])
	b.cerebro.punto_hold = lista[idx % lista.size()] if not lista.is_empty() else zona.centro_site(s)


func _designar_portador() -> void:
	if partida != null and partida.exige_portador():
		_sincronizar_portador()
		return
	var vivos: Array[Bot] = vivos_de(Bot.EQ_ATACANTES)
	for b: Bot in bots:
		b.cerebro.lleva_cachimba = false
	portador = null
	var candidatos: Array[Bot] = []
	for b: Bot in vivos:
		if b.rol == Bot.ROL_ATACANTE:
			candidatos.append(b)
	if candidatos.is_empty():
		return
	portador = candidatos[rng.randi_range(0, candidatos.size() - 1)]
	portador.cerebro.lleva_cachimba = true


## Con una `Partida` que exige portador, el portador lo decide ella (puede ser el jugador); aqui solo se refleja en los cerebros y,
## si la Cachimba cayo al suelo, el atacante vivo mas cercano va a recogerla.
func _sincronizar_portador() -> void:
	var p: Node = partida.portador_cachimba()
	portador = p as Bot
	for b: Bot in bots:
		b.cerebro.lleva_cachimba = (b == portador)
	var caida: Node3D = partida.cachimba_caida()
	if caida == null:
		recogedor = null
		return
	if recogedor != null and not recogedor.muerto and recogedor.rol == Bot.ROL_ATACANTE:
		return
	recogedor = null
	var md: float = 1.0e9
	for b: Bot in vivos_de(Bot.EQ_ATACANTES):
		if b.rol != Bot.ROL_ATACANTE:
			continue
		var d: float = b.global_position.distance_to(caida.global_position)
		if d < md:
			md = d
			recogedor = b


# ------------------------------------------------------------------ consultas de los cerebros

## Punto dentro del site donde montar.
func punto_montaje(s: String) -> Vector3:
	return _puntos_montaje.get(s, zona.centro_site(s))


## true si el equipo de `bot` puede lanzar otro humo (pasaron >= 14 s desde el ultimo de su equipo).
func permitir_humo(bot: Bot) -> bool:
	return t_ronda - float(_t_humo.get(bot.equipo, -100.0)) >= 14.0


func anotar_humo(equipo: int) -> void:
	_t_humo[equipo] = t_ronda


## Alcance de deteccion de los defensores en la zona actual.
func vision_defensor() -> float:
	if zona == null:
		return VISION_DEFENSOR_M
	return float(VISION_DEFENSOR_ZONA.get(zona.id, VISION_DEFENSOR_M))


## Alcance de deteccion de los atacantes en la zona actual (el del perfil de dificultad si la zona no lo limita).
func vision_atacante(del_perfil: float) -> float:
	if zona == null:
		return del_perfil
	return minf(del_perfil, float(VISION_ATACANTE_ZONA.get(zona.id, del_perfil)))


## Direccion horizontal unitaria desde `desde` hacia los spawns de los atacantes (de donde vendra el ataque).
func direccion_atacantes_desde(desde: Vector3) -> Vector3:
	var d: Vector3 = _centro_spawns("atacantes") - desde
	d.y = 0.0
	return d.normalized() if d.length() > 0.1 else Vector3.FORWARD


func direccion_defensores_desde(desde: Vector3) -> Vector3:
	var d: Vector3 = _centro_spawns("defensores") - desde
	d.y = 0.0
	return d.normalized() if d.length() > 0.1 else Vector3.FORWARD


## Grupo flexible: un atacante que lleva mucha ventaja sobre la mediana del grupo espera (el cerebro nunca espera > 7 s seguidos).
func permiso_avanzar(bot: Bot) -> bool:
	if zona == null or site_ataque == "" or t_ronda > 30.0:
		return true
	var c: Cachimba = partida.cachimba() if partida != null else null
	if c != null and c.estado != Cachimba.Estado.SIN_MONTAR:
		return true
	var vivos: Array[Bot] = []
	for b: Bot in vivos_de(Bot.EQ_ATACANTES):
		if b.rol == Bot.ROL_ATACANTE:
			vivos.append(b)
	if vivos.size() < 3:
		return true
	var centro: Vector3 = zona.centro_site(site_ataque)
	var ds: Array[float] = []
	for b: Bot in vivos:
		ds.append(b.global_position.distance_to(centro))
	ds.sort()
	var mediana: float = ds[ds.size() / 2]
	var mia: float = bot.global_position.distance_to(centro)
	return not (mia < mediana - 14.0 and mia > 30.0)


func escolta_cerca(bot: Bot) -> bool:
	for b: Bot in vivos_de(Bot.EQ_ATACANTES):
		if b != bot and b.global_position.distance_to(bot.global_position) < 22.0:
			return true
	return false


## Punto donde un atacante defiende la Cachimba ya montada (detras de coberturas, vistas desde los defensores).
func punto_post_plant(bot: Bot) -> Vector3:
	var c: Cachimba = partida.cachimba() if partida != null else null
	if c == null:
		return bot.global_position
	if _puntos_post.is_empty():
		_puntos_post = PuntosTacticos.puntos_defensa(mapa, c.global_position, _centro_spawns("defensores"), 6, 3.0, 16.0, rng, zona, 3.0, 8.0)
		if _puntos_post.is_empty():
			_puntos_post.append(c.global_position)
	var i: int = bots.find(bot)
	return _puntos_post[maxi(i, 0) % _puntos_post.size()]


## Punto donde un defensor cubre al que apaga la Cachimba.
func punto_cobertura_apagado(bot: Bot) -> Vector3:
	var c: Cachimba = partida.cachimba() if partida != null else null
	if c == null:
		return bot.global_position
	if _puntos_apagado.is_empty():
		_puntos_apagado = PuntosTacticos.puntos_defensa(mapa, c.global_position, _centro_spawns("atacantes"), 6, 3.0, 20.0, rng, zona, 3.0, 9.0)
		if _puntos_apagado.is_empty():
			_puntos_apagado.append(c.global_position)
	var i: int = bots.find(bot)
	return _puntos_apagado[maxi(i, 0) % _puntos_apagado.size()]


## Siguiente destino de un cazador (eliminacion): spawn enemigo, sites, centro y puntos al azar.
func siguiente_patrulla(bot: Bot) -> Vector3:
	var enemigo: String = "defensores" if bot.equipo == Bot.EQ_ATACANTES else "atacantes"
	var base: Vector3
	var x: float = rng.randf()
	var presion: bool = t_ronda - _ult_baja_t > 40.0
	if zona == null:
		return bot.global_position
	if presion or x < 0.3:
		var i: int = rng.randi_range(0, zona.n_spawns(enemigo) - 1)
		base = zona.punto_spawn(enemigo, i)["pos"]
	elif x < 0.55:
		base = zona.centro_site("A")
	elif x < 0.8:
		base = zona.centro_site("B")
	else:
		base = zona.limites()["centro"]
		base += Vector3(rng.randf_range(-30, 30), 0.0, rng.randf_range(-30, 30))
	return NavigationServer3D.map_get_closest_point(mapa, base)


## Ultima posicion en que un companero vio al enemigo (< 8 s); Vector3.INF si no hay.
func intel_enemiga(bot: Bot) -> Vector3:
	var d: Dictionary = _intel.get(bot.equipo, {})
	if d.is_empty() or t_ronda - float(d["t"]) > 8.0:
		return Vector3.INF
	return d["pos"]


func reportar_vista(bot: Bot, pos: Vector3) -> void:
	_intel[bot.equipo] = {"pos": pos, "t": t_ronda}
	if bot.rol == Bot.ROL_DEFENSOR:
		_marcar_presion(pos)


func reportar_ruido(bot: Bot, pos: Vector3) -> void:
	if bot.rol == Bot.ROL_DEFENSOR:
		_marcar_presion(pos)
	elif bot.rol != Bot.ROL_ATACANTE and not _intel.has(bot.equipo):
		_intel[bot.equipo] = {"pos": pos, "t": t_ronda}


func _marcar_presion(pos: Vector3) -> void:
	if zona == null:
		return
	for s: String in ["A", "B"]:
		if zona.centro_site(s).distance_to(pos) < 32.0:
			_presion[s] = t_ronda


func avisar_cachimba(_bot: Bot) -> void:
	cachimba_conocida = true


# ------------------------------------------------------------------ simulacion

func _physics_process(delta: float) -> void:
	avanzar(delta)


func avanzar(dt: float) -> void:
	_t += dt
	t_ronda += dt
	_t_rev -= dt
	if _t_rev > 0.0:
		return
	_t_rev = INTERVALO_REVISION
	if zona == null or modo != &"cachimba":
		return
	var c: Cachimba = partida.cachimba() if partida != null else null
	if c != null:
		if int(c.estado) != _estado_cachimba_prev:
			if c.estado == Cachimba.Estado.SIN_MONTAR:
				cachimba_conocida = false
				apagador = null
			_estado_cachimba_prev = int(c.estado)
		_elegir_apagador(c)
	if partida != null and partida.exige_portador():
		_sincronizar_portador()
	elif portador == null or portador.muerto:
		if c == null or c.estado == Cachimba.Estado.SIN_MONTAR:
			_designar_portador()
	_rotar_defensas()


func _elegir_apagador(c: Cachimba) -> void:
	if not cachimba_conocida or not c.esta_montada():
		return
	if apagador != null and not apagador.muerto:
		return
	apagador = null
	var mejor: Bot = null
	var md: float = 1.0e9
	for b: Bot in vivos_de(Bot.EQ_DEFENSORES):
		var d: float = b.global_position.distance_to(c.global_position)
		if d < md:
			md = d
			mejor = b
	apagador = mejor


## Rotaciones: si un site esta presionado (enemigo visto u oido cerca hace < 6 s) y no lo defiende nadie, va el defensor mas
## cercano; si lo defienden otros, va tambien el volante.
func _rotar_defensas() -> void:
	var defs: Array[Bot] = vivos_de(Bot.EQ_DEFENSORES)
	if defs.is_empty():
		return
	for s: String in ["A", "B"]:
		if t_ronda - float(_presion.get(s, -1000.0)) > PRESION_S:
			continue
		var cubren: Array[Bot] = []
		for b: Bot in defs:
			if b.cerebro.site == s:
				cubren.append(b)
		if cubren.is_empty():
			var mejor: Bot = null
			var md: float = 1.0e9
			for b: Bot in defs:
				var d: float = b.global_position.distance_to(zona.centro_site(s))
				if d < md and b != apagador:
					md = d
					mejor = b
			if mejor != null:
				_reasignar(mejor, s)
		elif _volante != null and not _volante.muerto and _volante.cerebro.site != s and _volante != apagador:
			_reasignar(_volante, s)


func _reasignar(b: Bot, s: String) -> void:
	var n: int = 0
	for o: Bot in vivos_de(Bot.EQ_DEFENSORES):
		if o != b and o.cerebro.site == s:
			n += 1
	_asignar_defensa(b, s, n)
	rotaciones += 1
