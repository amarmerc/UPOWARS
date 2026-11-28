class_name ServidorRed
extends Node
## Servidor AUTORITATIVO (dedicado headless o anfitrion de una partida local). Mantiene el lobby (huecos de los dos equipos), monta la
## partida (`Partida`, `DirectorBots`, bots) y simula a los humanos remotos: cada uno es un `Bot` "avatar" (`humano_red`) que ESTE
## nodo mueve y dispara con las ENTRADAS que manda el cliente (nunca su posicion). Todo pasa por la API que ya usan los bots:
## `Partida.comprar / vender / montar_cachimba / apagar_cachimba`, `ArmasBot` (cadencia, cargador, recarga) y `Balistica` (dano).
##
## Cada tick de fisica: 1) consume las entradas pendientes de cada humano (limitadas por tiempo real: no se puede ir mas rapido de lo
## fisicamente posible), 2) mueve el avatar con `MovimientoJugador`, 3) dispara con COMPENSACION DE LATENCIA (rebobina los hitboxes de
## los demas a la hora que veia el tirador, con un limite) y 4) guarda el historial; cada `TICK_SNAPSHOT` ticks envia a cada cliente su
## snapshot compacto. Los eventos (killfeed, rondas, chat, hitmarker, tienda) van por RPC fiables.

signal lobby_cambiado(estado: Dictionary)
signal sesion_montada
signal sesion_terminada
signal peer_unido(peer: int)
signal peer_salio(peer: int)

const TICK_SNAPSHOT: int = 3
const HISTORIAL_MS: int = 1200
## Maximo que se rebobina a los demas (ms): interpolacion de ~100 ms + hasta ~200 ms de latencia.
const LIMITE_REBOBINADO_MS: int = 300
const MAX_COLA: int = 8
const CREDITO_MAX: float = 0.12
const MAX_CMD_SEG: int = 40
const T_MUNDO_LISTO_MAX: float = 25.0
const T_VOLVER_LOBBY: float = 7.0
const MAX_CHAT: int = 120
const MAX_NOMBRE: int = 16
const HUECOS_POR_EQUIPO: int = 5
const REPETIR_HUECO_MAX: int = 4

## Datos de simulacion de un humano remoto (el avatar es `nodo`).
class AvatarRed:
	extends RefCounted
	var peer: int = 0
	var id: int = -1
	var nodo: Bot = null
	var st := MovimientoJugador.Estado.new()
	var cola: Array = []
	var ultimo_seq: int = 0
	var ultima: EntradaRed = null
	var credito: float = CREDITO_MAX
	var aim_t: float = 0.0
	var fire_prev: bool = false
	var rafaga_pend: int = 0
	var no_disparar_hasta: int = 0
	var pos_prev: Vector3 = Vector3.INF
	var epoch: int = 0
	var cmds: int = 0
	var t_cmds: float = 0.0
	var rechazos: int = 0
	var priv_hash: String = ""
	var ultimo_chat: float = -10.0
	var ping_ms: int = 0
	var bytes_snap: int = 0
	var entradas_procesadas: int = 0
	var vel_max_vista: float = 0.0

var red: Red
var max_clientes: int = 10
# lobby
var modo: StringName = ConfigPartida.M_CACHIMBA_WARS
var zona_id: String = "plaza_america"
var nombres_equipo: Array[String] = ["EPS", "CEUPO"]
var tam_equipo: int = HUECOS_POR_EQUIPO
var dificultad: StringName = &"normal"
var rondas_ganar: int = 7
var bots_libres: int = 4
var t_compra: float = 25.0
var t_ronda: float = 100.0
## Compensacion de latencia (rebobinado de hitboxes) activada; solo se desactiva en pruebas para medir su efecto.
var rebobinado: bool = true
var huecos: Array = [[], []]
var clientes: Dictionary = {}
var anfitrion: int = 0
# sesion
var en_partida: bool = false
var cargando: bool = false
var mundo: Node3D = null
var cfg: ConfigPartida = null
var partida: Partida = null
var zona: ZonaActiva = null
var region: NavigationRegion3D = null
var director: DirectorBots = null
var bots: Array[Bot] = []
var jugador_local: Jugador = null
var participantes: Array[Dictionary] = []
var avatares: Dictionary = {}
var t_s: float = 0.0
var t_ms: int = 0
var tick: int = 0
var historial: Array = []
## Estadisticas: snapshots enviados, bytes de carga util.
var stats: Dictionary = {"snapshots": 0, "bytes_snapshots": 0, "disparos": 0, "rechazos": 0}

var _armas_suelo: Dictionary = {}
var _armas_suelo_ids: Dictionary = {}
var _sig_id_arma: int = 1
var _proyectiles_vistos: Dictionary = {}
var _lanzables_vistos: Dictionary = {}
var _nubes_vistas: Dictionary = {}
var _t_tabla: float = 0.0
var _t_carga: float = 0.0
var _t_fin: float = -1.0
var _cargado_por: Dictionary = {}
var _fase_prev: int = -1
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	process_physics_priority = 10


func _ready() -> void:
	_rng.randomize()
	_iniciar_huecos()
	if red != null:
		red.peer_desconectado.connect(on_peer_desconectado)
		red.peer_conectado.connect(func(id: int) -> void: peer_unido.emit(id))
	SenalesCombate.obtener(get_tree()).baja.connect(_on_baja)


func cerrar() -> void:
	desmontar()
	cargando = false


# ------------------------------------------------------------------ lobby

func _iniciar_huecos() -> void:
	huecos = [[], []]
	for g in 2:
		for i in tam_equipo:
			(huecos[g] as Array).append(_hueco_bot())


static func _hueco_bot() -> Dictionary:
	return {"tipo": ConfigPartida.TIPO_BOT, "nombre": "", "personaje": &"", "listo": false, "peer": 0}


func humanos() -> int:
	return clientes.size()


func estado_lobby() -> Dictionary:
	var h: Array = [[], []]
	for g in 2:
		for x: Dictionary in huecos[g]:
			h[g].append({"tipo": String(x["tipo"]), "nombre": str(x["nombre"]), "personaje": String(x["personaje"]),
					"listo": bool(x["listo"]), "peer": int(x["peer"])})
	return {"modo": String(modo), "zona": zona_id, "nombres": nombres_equipo.duplicate(), "tam": tam_equipo, "dificultad": String(dificultad),
			"rondas": rondas_ganar, "bots_libres": bots_libres, "huecos": h, "anfitrion": anfitrion, "en_partida": en_partida or cargando,
			"max": max_clientes}


func _emitir_lobby() -> void:
	var e: Dictionary = estado_lobby()
	lobby_cambiado.emit(e)
	if red == null:
		return
	for peer: int in clientes:
		if peer != 1:
			red.enviar(peer, &"s_lobby", [e])


static func _limpiar_nombre(n: String) -> String:
	var s: String = ""
	for c in n.strip_edges():
		if c.unicode_at(0) >= 32 and c.unicode_at(0) != 127:
			s += c
	s = s.substr(0, MAX_NOMBRE).strip_edges()
	return s if s != "" else "Jugador"


## Un cliente (o el anfitrion local, peer 1) pide unirse. Devuelve "" si entra o el motivo del rechazo.
func on_unirse(peer: int, nombre: String, personaje: String, version: int) -> String:
	var motivo: String = ""
	if version != ProtoRed.VERSION:
		motivo = "version de red distinta (servidor %d, cliente %d)" % [ProtoRed.VERSION, version]
	elif en_partida or cargando:
		motivo = "partida en curso"
	elif clientes.has(peer):
		return ""
	elif clientes.size() >= max_clientes or _hueco_libre_para_humano() == Vector2i(-1, -1):
		motivo = "servidor lleno"
	if motivo != "":
		if peer != 1 and red != null:
			red.enviar(peer, &"s_rechazo", [motivo])
			red.desconectar_peer.call_deferred(peer)
		return motivo
	var pers: StringName = StringName(personaje) if CatalogoPersonajes.existe(StringName(personaje)) else CatalogoPersonajes.ids()[0]
	var pos: Vector2i = _hueco_libre_para_humano()
	huecos[pos.x][pos.y] = {"tipo": ConfigPartida.TIPO_HUMANO, "nombre": _limpiar_nombre(nombre), "personaje": pers, "listo": false, "peer": peer}
	clientes[peer] = {"peer": peer}
	if anfitrion == 0 or not clientes.has(anfitrion):
		anfitrion = peer
	if peer != 1 and red != null:
		red.enviar(peer, &"s_bienvenida", [{"id": peer, "version": ProtoRed.VERSION, "max": max_clientes, "tick_hz": Engine.physics_ticks_per_second}])
	_emitir_lobby()
	return ""


## Primer hueco de bot del equipo con menos humanos.
func _hueco_libre_para_humano() -> Vector2i:
	var cuenta: Array[int] = [0, 0]
	for g in 2:
		for h: Dictionary in huecos[g]:
			if h["tipo"] == ConfigPartida.TIPO_HUMANO:
				cuenta[g] += 1
	var orden: Array = [0, 1] if cuenta[0] <= cuenta[1] else [1, 0]
	for g: int in orden:
		for i in (huecos[g] as Array).size():
			if (huecos[g][i] as Dictionary)["tipo"] == ConfigPartida.TIPO_BOT:
				return Vector2i(g, i)
	return Vector2i(-1, -1)


func _pos_de(peer: int) -> Vector2i:
	for g in 2:
		for i in (huecos[g] as Array).size():
			var h: Dictionary = huecos[g][i]
			if h["tipo"] == ConfigPartida.TIPO_HUMANO and int(h["peer"]) == peer:
				return Vector2i(g, i)
	return Vector2i(-1, -1)


## Orden del lobby de un cliente. Acciones: hueco(g, i), nombre(txt), personaje(id), listo(bool), config(dict, solo anfitrion), forzar, salir.
func lobby_cmd(peer: int, accion: StringName, a: Variant = null, b: Variant = null) -> void:
	if not clientes.has(peer) or en_partida or cargando:
		return
	var pos: Vector2i = _pos_de(peer)
	if pos.x < 0:
		return
	var h: Dictionary = huecos[pos.x][pos.y]
	match accion:
		&"hueco":
			if typeof(a) != TYPE_INT or typeof(b) != TYPE_INT:
				return
			var g: int = int(a)
			var i: int = int(b)
			if g < 0 or g > 1 or i < 0 or i >= (huecos[g] as Array).size():
				return
			if (huecos[g][i] as Dictionary)["tipo"] != ConfigPartida.TIPO_BOT:
				return
			huecos[g][i] = h
			huecos[pos.x][pos.y] = _hueco_bot()
		&"nombre":
			h["nombre"] = _limpiar_nombre(str(a))
		&"personaje":
			if CatalogoPersonajes.existe(StringName(str(a))):
				h["personaje"] = StringName(str(a))
		&"listo":
			h["listo"] = bool(a)
		&"config":
			if peer == anfitrion and a is Dictionary:
				_aplicar_config(a as Dictionary)
		&"forzar":
			if peer == anfitrion:
				_emitir_lobby()
				iniciar_sesion()
				return
		&"salir":
			if peer == 1:
				_quitar_cliente(peer)
				_emitir_lobby()
				return
	_emitir_lobby()
	_comprobar_arranque()


func _aplicar_config(c: Dictionary) -> void:
	if c.has("modo"):
		for m: Array in ConfigPartida.MODOS:
			if String(m[0]) == str(c["modo"]):
				modo = m[0]
	if c.has("zona") and ZonaActiva.ids_disponibles().has(str(c["zona"])):
		zona_id = str(c["zona"])
	if c.has("dificultad") and DificultadBot.TODAS.has(StringName(str(c["dificultad"]))):
		dificultad = StringName(str(c["dificultad"]))
	if c.has("rondas"):
		rondas_ganar = clampi(int(c["rondas"]), 1, 13)
	if c.has("bots_libres"):
		bots_libres = clampi(int(c["bots_libres"]), 0, 10)
	if c.has("nombres") and c["nombres"] is Array and (c["nombres"] as Array).size() == 2:
		for g in 2:
			var n: String = str((c["nombres"] as Array)[g]).strip_edges().substr(0, 14)
			if n != "":
				nombres_equipo[g] = n
	if c.has("tam"):
		_ajustar_tam(clampi(int(c["tam"]), 1, HUECOS_POR_EQUIPO))


func _ajustar_tam(n: int) -> void:
	for g in 2:
		var humanos_g: int = 0
		for h: Dictionary in huecos[g]:
			humanos_g += 1 if h["tipo"] == ConfigPartida.TIPO_HUMANO else 0
		if humanos_g > n:
			return                                   # no se expulsa a nadie: se rechaza el cambio
	tam_equipo = n
	for g in 2:
		var lista: Array = huecos[g]
		while lista.size() > n:
			var k: int = lista.size() - 1
			while k > 0 and (lista[k] as Dictionary)["tipo"] != ConfigPartida.TIPO_BOT:
				k -= 1
			lista.remove_at(k)
		while lista.size() < n:
			lista.append(_hueco_bot())


func contador_listos() -> Vector2i:
	var listos: int = 0
	var n: int = 0
	for g in 2:
		for h: Dictionary in huecos[g]:
			if h["tipo"] == ConfigPartida.TIPO_HUMANO:
				n += 1
				listos += 1 if bool(h["listo"]) else 0
	return Vector2i(listos, n)


func _comprobar_arranque() -> void:
	var c: Vector2i = contador_listos()
	if c.y > 0 and c.x == c.y and not en_partida and not cargando:
		iniciar_sesion()


func _quitar_cliente(peer: int) -> void:
	var pos: Vector2i = _pos_de(peer)
	if pos.x >= 0:
		huecos[pos.x][pos.y] = _hueco_bot()
	clientes.erase(peer)
	if anfitrion == peer:
		anfitrion = 0
		for p: int in clientes:
			anfitrion = p
			break


func on_peer_desconectado(peer: int) -> void:
	if not clientes.has(peer):
		return
	var av: AvatarRed = avatares.get(peer)
	if av != null:
		_humano_a_bot(av)
	_quitar_cliente(peer)
	avatares.erase(peer)
	peer_salio.emit(peer)
	_emitir_lobby()
	if en_partida:
		difundir(&"chat", {"de": "", "g": -1, "texto": "Un jugador se ha desconectado: su hueco pasa a un bot."})
		if clientes.is_empty() and jugador_local == null:
			_t_fin = 3.0


## Un humano que se desconecta en plena partida: su avatar pasa a ser un bot normal (cerebro, director).
func _humano_a_bot(av: AvatarRed) -> void:
	var b: Bot = av.nodo
	if b == null or not is_instance_valid(b):
		return
	b.humano_red = false
	b.peer_red = 0
	b.nombre = "Bot " + b.nombre
	b.salud.nombre = b.nombre
	if partida != null and partida.datos.has(b):
		(partida.datos[b] as Partida.DatosJugador).nombre = "%s (%s)" % [b.nombre, partida.nombre_grupo(partida.grupo_de(b))]
	b.asignar_equipo(partida.lado_de(b), partida._rol_para(partida.lado_de(b)))
	b.cerebro.reiniciar()
	b.comandos.detener()
	if director != null:
		director.agregar(b)
	for p: Dictionary in participantes:
		if p["nodo"] == b:
			p["humano"] = false
			p["peer"] = 0
			p["nombre"] = b.nombre


# ------------------------------------------------------------------ montar y arrancar la sesion

static func primer_spawn_libre() -> Vector3:
	var f := FileAccess.open("res://data/spawns.json", FileAccess.READ)
	if f != null:
		var d: Variant = JSON.parse_string(f.get_as_text())
		if d is Dictionary and (d as Dictionary).has("spawns") and not ((d as Dictionary)["spawns"] as Array).is_empty():
			var p: Array = ((d as Dictionary)["spawns"] as Array)[0]["pos"]
			return Vector3(p[0], p[1], p[2])
	return Vector3(-486.58, -1.9, 142.56)


func _config_partida() -> ConfigPartida:
	var c := ConfigPartida.new()
	c.aplicar_modo(modo)
	c.zona = zona_id
	c.nombres = [nombres_equipo[0], nombres_equipo[1]]
	c.jugadores_por_equipo = tam_equipo
	c.dificultad = dificultad
	c.rondas_ganar = rondas_ganar
	c.bots_libres = bots_libres
	c.semilla = _rng.randi() % 100000
	c.t_compra = t_compra
	c.t_ronda = t_ronda
	c.con_jugador = false
	var h: Array = [[], []]
	for g in 2:
		for x: Dictionary in huecos[g]:
			h[g].append(x.duplicate())
	c.huecos = h
	c.huecos = c.huecos_efectivos()
	return c


## Arranca la sesion con los humanos conectados: monta el mundo, avisa a los clientes y espera a que todos esten listos.
func iniciar_sesion() -> void:
	if en_partida or cargando or clientes.is_empty() or mundo == null:
		return
	cargando = true
	_emitir_lobby()
	var c: ConfigPartida = _config_partida()
	await montar(mundo, c, jugador_local)
	_enviar_inicio()
	_t_carga = 0.0
	_cargado_por.clear()
	if jugador_local != null:
		_cargado_por[1] = true
	sesion_montada.emit()
	_comprobar_carga()


## Construye zona, navegacion, Partida, Director y combatientes sobre `raiz` (que ya contiene el mapa). `jugador` = el humano local del
## anfitrion (sin red); null en el servidor dedicado. La partida NO empieza hasta que `empezar()` (cuando los clientes cargan).
func montar(raiz: Node3D, config: ConfigPartida, jugador: Jugador = null) -> void:
	desmontar()
	mundo = raiz
	cfg = config
	jugador_local = jugador
	var libre: bool = cfg.es_libre()
	var origen := Vector3.ZERO
	var humanos_n: int = clientes.size()
	if libre:
		origen = primer_spawn_libre()
		if cfg.bots_libres > 0:
			region = NavBots.hornear_campus(raiz)
			await NavBots.esperar_listo(raiz, origen)
	else:
		zona = ZonaActiva.crear(cfg.zona)
		raiz.add_child(zona)
		await get_tree().physics_frame
		region = NavBots.hornear_zona(raiz, zona)
		await NavBots.esperar_listo(raiz, zona.punto_spawn("atacantes", 0)["pos"])
	partida = Partida.new()
	partida.name = "Partida"
	add_child(partida)
	partida.configurar(cfg, zona)
	var mapa: RID = NavBots.mapa(raiz) if region != null else RID()
	if region != null:
		director = DirectorBots.new()
		director.name = "Director"
		add_child(director)
		director.configurar(zona, partida, cfg.modo_partida(), mapa, cfg.semilla)
		partida.director = director if not libre else null
	_crear_combatientes(origen, humanos_n)
	partida.baja_registrada.connect(_on_baja_partida)
	partida.fase_cambiada.connect(_on_fase)
	partida.ronda_terminada.connect(func(g: int, m: String) -> void: difundir(&"ronda_fin", {"g": g, "motivo": m, "puntos": partida.puntos.duplicate()}))
	partida.partida_terminada.connect(func(g: int) -> void:
		difundir(&"partida_fin", {"g": g})
		_t_fin = T_VOLVER_LOBBY)
	partida.lados_cambiados.connect(func() -> void: difundir(&"lados", {}))
	partida.cachimba_montada.connect(func(s: String) -> void: difundir(&"cachimba", {"que": "montada", "site": s}))
	partida.cachimba_apagada.connect(func() -> void: difundir(&"cachimba", {"que": "apagada"}))
	partida.cachimba_alarma.connect(func() -> void: difundir(&"cachimba", {"que": "alarma"}))
	partida.portador_cambiado.connect(func(_n: Node) -> void: pass)
	partida.compra_hecha.connect(func(_c: Node, _id: StringName) -> void: pass)
	_armas_suelo.clear()
	_armas_suelo_ids.clear()
	historial.clear()
	tick = 0


func _crear_combatientes(origen: Vector3, humanos_n: int) -> void:
	participantes.clear()
	bots.clear()
	avatares.clear()
	var dif: StringName = cfg.dificultad
	var n_bot: int = 0
	var rng := RandomNumberGenerator.new()
	rng.seed = cfg.semilla
	if cfg.es_libre():
		# humanos (ordenados por peer) y despues los bots que deambulan
		var peers: Array = clientes.keys()
		peers.sort()
		var k: int = 0
		for peer: int in peers:
			var h: Dictionary = huecos[0][0]
			for g in 2:
				for x: Dictionary in huecos[g]:
					if x["tipo"] == ConfigPartida.TIPO_HUMANO and int(x["peer"]) == peer:
						h = x
			_crear_humano(peer, h, 0, k, 0, Bot.ROL_LIBRE, origen)
			k += 1
		for i in cfg.bots_libres:
			var b: Bot = Bot.crear(_nombre_bot(n_bot), 0, Bot.ROL_LIBRE, dif, cfg.semilla * 100 + i, partida, CatalogoPersonajes.aleatorio(rng))
			n_bot += 1
			add_child(b)
			var p: Vector3 = NavigationServer3D.map_get_closest_point(NavBots.mapa(mundo), origen + Vector3(_rng.randf_range(-40, 40), 0, _rng.randf_range(-40, 40)))
			b.teletransportar(p, _rng.randf() * 360.0)
			_registrar_bot(b, 0, 0, i, b.nombre)
			bots.append(b)
		if director != null:
			director.preparar()
		return
	var huecos_ef: Array = cfg.huecos
	for g in 2:
		var lado: int = Partida.EQ_ATACANTES if g == 0 else Partida.EQ_DEFENSORES
		var rol: StringName = Bot.ROL_CAZADOR if cfg.submodo == ConfigPartida.SUB_ELIMINACION else (Bot.ROL_ATACANTE if lado == Partida.EQ_ATACANTES else Bot.ROL_DEFENSOR)
		var lista: Array = huecos_ef[g]
		for i in lista.size():
			var h: Dictionary = lista[i]
			if h["tipo"] == ConfigPartida.TIPO_HUMANO:
				_crear_humano(int(h["peer"]), h, g, i, lado, rol, origen)
				continue
			var nombre_b: String = str(h.get("nombre", ""))
			if nombre_b == "":
				nombre_b = _nombre_bot(n_bot)
			var b: Bot = Bot.crear(nombre_b, lado, rol, dif, cfg.semilla * 100 + g * 10 + i, partida, StringName(h["personaje"]))
			n_bot += 1
			add_child(b)
			_registrar_bot(b, g, lado, i, "%s (%s)" % [b.nombre, cfg.nombres[g]])
			if director != null:
				director.agregar(b)
			bots.append(b)


func _nombre_bot(i: int) -> String:
	return Juego.NOMBRES_BOTS[i % Juego.NOMBRES_BOTS.size()]


func _registrar_bot(b: Bot, g: int, _lado: int, indice: int, nombre_reg: String) -> void:
	var d: Partida.DatosJugador = partida.registrar(b, g, nombre_reg)
	var id: int = participantes.size()
	b.id_red = id
	participantes.append({"id": id, "nodo": b, "grupo": g, "indice": indice, "humano": false, "peer": 0, "nombre": b.nombre,
			"personaje": String(b.personaje)})
	b.armas.disparo_realizado.connect(_on_disparo_bot.bind(b))
	d.nombre = nombre_reg


func _crear_humano(peer: int, h: Dictionary, g: int, indice: int, lado: int, rol: StringName, origen: Vector3) -> void:
	var nombre: String = str(h["nombre"])
	if peer == 1 and jugador_local != null:
		var id: int = participantes.size()
		partida.registrar(jugador_local, g, nombre)
		participantes.append({"id": id, "nodo": jugador_local, "grupo": g, "indice": indice, "humano": true, "peer": 1, "nombre": nombre,
				"personaje": String(h["personaje"])})
		jugador_local.gestor.disparo_realizado.connect(_on_disparo_jugador_local)
		return
	var b: Bot = Bot.crear(nombre, lado, rol, cfg.dificultad, cfg.semilla * 100 + 50 + participantes.size(), partida, StringName(h["personaje"]))
	b.humano_red = true
	b.peer_red = peer
	add_child(b)
	var id2: int = participantes.size()
	b.id_red = id2
	partida.registrar(b, g, nombre)
	participantes.append({"id": id2, "nodo": b, "grupo": g, "indice": indice, "humano": true, "peer": peer, "nombre": nombre,
			"personaje": String(h["personaje"])})
	var av := AvatarRed.new()
	av.peer = peer
	av.id = id2
	av.nodo = b
	avatares[peer] = av
	b.armas.disparo_realizado.connect(_on_disparo_bot.bind(b))
	b.ceguera.cegado.connect(_on_ceguera.bind(av))
	if cfg.es_libre():
		var p: Vector3 = NavigationServer3D.map_get_closest_point(NavBots.mapa(mundo), origen + Vector3(_rng.randf_range(-6, 6), 0, _rng.randf_range(-6, 6))) \
				if region != null else origen
		b.teletransportar(p, 0.0)
		b.reaparecer(p, 0.0)


func _enviar_inicio() -> void:
	var parts: Array = []
	for p: Dictionary in participantes:
		parts.append({"id": p["id"], "nombre": p["nombre"], "grupo": p["grupo"], "indice": p["indice"], "humano": p["humano"],
				"peer": p["peer"], "personaje": p["personaje"]})
	var cd: Dictionary = {"modo": String(cfg.id_modo()), "zona": cfg.zona, "nombres": cfg.nombres.duplicate(), "rondas": cfg.rondas_ganar,
			"dificultad": String(cfg.dificultad), "semilla": cfg.semilla}
	for peer: int in clientes:
		if peer == 1:
			continue
		var av: AvatarRed = avatares.get(peer)
		red.enviar(peer, &"s_iniciar", [{"cfg": cd, "parts": parts, "tu_id": av.id if av != null else -1, "t_ms": t_ms,
				"tick_hz": Engine.physics_ticks_per_second}])


func on_mundo_listo(peer: int) -> void:
	if not cargando or not clientes.has(peer):
		return
	_cargado_por[peer] = true
	_comprobar_carga()


func _comprobar_carga() -> void:
	for peer: int in clientes:
		if not _cargado_por.has(peer):
			return
	empezar()


## Arranca la partida (todos los clientes han cargado, o ha vencido el tiempo de carga).
func empezar() -> void:
	if not cargando or partida == null:
		return
	cargando = false
	en_partida = true
	partida.iniciar_partida()
	_emitir_lobby()
	for av: AvatarRed in avatares.values():
		_marcar_teleport(av)


func desmontar() -> void:
	en_partida = false
	for b: Bot in bots:
		if is_instance_valid(b):
			b.queue_free()
	for p: Dictionary in participantes:
		var n: Node = p["nodo"]
		if n is Bot and is_instance_valid(n):
			n.queue_free()
	bots.clear()
	participantes.clear()
	avatares.clear()
	for n: Node in [director, partida, region, zona]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	director = null
	partida = null
	region = null
	zona = null
	if is_inside_tree():
		for g: String in ["lanzables", "nubes", "proyectiles", "altavoces", "armas_suelo", "cachimba_suelo"]:
			for n: Node in get_tree().get_nodes_in_group(g):
				n.queue_free()
	_t_fin = -1.0
	historial.clear()


## Fin de la partida: vuelve al lobby con todos sin "listo".
func volver_al_lobby() -> void:
	desmontar()
	cargando = false
	for g in 2:
		for h: Dictionary in huecos[g]:
			h["listo"] = false
	sesion_terminada.emit()
	_emitir_lobby()


# ------------------------------------------------------------------ difusion de eventos

## Evento fiable a todos los clientes remotos con mundo montado.
func difundir(tipo: StringName, datos: Variant) -> void:
	if red == null:
		return
	for peer: int in clientes:
		if peer != 1:
			red.enviar(peer, &"s_evento", [String(tipo), datos])


func a_cliente(peer: int, tipo: StringName, datos: Variant) -> void:
	if red != null and peer != 1 and clientes.has(peer):
		red.enviar(peer, &"s_evento", [String(tipo), datos])


func _id_de(nodo: Node) -> int:
	if nodo == null or partida == null:
		return -1
	var c: Node = partida._combatiente_de(nodo)
	if c == null:
		return -1
	for p: Dictionary in participantes:
		if p["nodo"] == c:
			return int(p["id"])
	return -1


func _on_baja(atacante: Node, victima: Salud, arma: ArmaDatos) -> void:
	if not en_partida:
		return
	var idv: int = _id_de(victima)
	if idv < 0:
		return
	difundir(&"baja", {"asesino": _id_de(atacante), "victima": idv, "arma": String(arma.id) if arma != null else ""})


func _on_baja_partida(_asesino: Node, _victima: Node) -> void:
	_t_tabla = 0.0


func _on_fase(fase: int) -> void:
	difundir(&"fase", {"fase": fase, "ronda": partida.ronda})
	if fase == Partida.Fase.COMPRA:
		for av: AvatarRed in avatares.values():
			_marcar_teleport(av)
	_t_tabla = 0.0


func _on_ceguera(nivel: float, segundos: float, av: AvatarRed) -> void:
	a_cliente(av.peer, &"ceguera", {"nivel": nivel, "seg": segundos})


# ------------------------------------------------------------------ entradas, comandos y chat

func on_entradas(peer: int, paq: PackedByteArray) -> void:
	var av: AvatarRed = avatares.get(peer)
	if av == null or not en_partida:
		return
	var lista: Array = ProtoRed.desempaquetar_entradas(paq, t_ms)
	for e: EntradaRed in lista:
		if e.seq <= av.ultimo_seq:
			continue
		var dup: bool = false
		var pos: int = av.cola.size()
		for i in av.cola.size():
			var q: EntradaRed = av.cola[i]
			if q.seq == e.seq:
				dup = true
				break
			if q.seq > e.seq:
				pos = i
				break
		if dup:
			continue
		av.cola.insert(pos, e)
	while av.cola.size() > MAX_COLA:
		var d: EntradaRed = av.cola.pop_front()
		av.ultimo_seq = d.seq
		av.ultima = d


func on_cmd(peer: int, nombre: StringName, a: Variant, b: Variant) -> void:
	var av: AvatarRed = avatares.get(peer)
	if av == null or not en_partida or av.nodo == null:
		return
	if t_s - av.t_cmds > 1.0:
		av.t_cmds = t_s
		av.cmds = 0
	av.cmds += 1
	if av.cmds > MAX_CMD_SEG:
		_rechazar(av, "demasiados comandos")
		return
	var nodo: Bot = av.nodo
	if nodo.muerto and nombre != &"vender":
		return
	match nombre:
		&"comprar":
			if _es_id(a):
				if not partida.comprar(nodo, StringName(a)):
					_rechazar(av, "compra rechazada %s" % str(a), false)
		&"vender":
			if _es_id(a):
				partida.vender(nodo, StringName(a))
		&"montar":
			partida.montar_cachimba(nodo, bool(a))
		&"apagar":
			partida.apagar_cachimba(nodo, bool(a))
		&"cambiar":
			if typeof(a) == TYPE_INT and int(a) >= 0 and int(a) <= 2:
				nodo.armas.cambiar_arma(int(a))
		&"recargar":
			nodo.armas.recargar()
		&"tirar":
			nodo.armas.tirar_arma()
		&"recoger":
			if typeof(a) == TYPE_INT:
				var n: Node = _armas_suelo_ids.get(int(a))
				if n != null and is_instance_valid(n):
					nodo.armas.recoger(n as ArmaSuelo)
		&"lanzar":
			if _es_id(a):
				_lanzar_utilidad(av, StringName(a), bool(b))
		_:
			_rechazar(av, "comando desconocido %s" % str(nombre))


static func _es_id(v: Variant) -> bool:
	return (v is String or v is StringName) and str(v).length() < 40 and Catalogo.existe(StringName(str(v)))


func _rechazar(av: AvatarRed, motivo: String, contar: bool = true) -> void:
	if contar:
		av.rechazos += 1
	stats["rechazos"] = int(stats["rechazos"]) + 1
	push_warning("[servidor] %s: %s" % [av.nodo.nombre if av.nodo != null else str(av.peer), motivo])


func on_chat(peer: int, texto: String) -> void:
	if not clientes.has(peer):
		return
	var t: String = ""
	for c in texto.strip_edges():
		if c.unicode_at(0) >= 32 and c.unicode_at(0) != 127:
			t += c
	t = t.substr(0, MAX_CHAT)
	if t == "":
		return
	var av: AvatarRed = avatares.get(peer)
	if av != null:
		if t_s - av.ultimo_chat < 0.5:
			return
		av.ultimo_chat = t_s
	var quien: String = ""
	var g: int = -1
	var pos: Vector2i = _pos_de(peer)
	if pos.x >= 0:
		quien = str((huecos[pos.x][pos.y] as Dictionary)["nombre"])
		g = pos.x
	if en_partida and partida != null:
		for p: Dictionary in participantes:
			if int(p["peer"]) == peer and p["humano"]:
				quien = str(p["nombre"])
				g = int(p["grupo"])
	var datos: Dictionary = {"de": quien, "g": g, "texto": t}
	difundir(&"chat", datos)
	chat_local.emit(datos)


signal chat_local(datos: Dictionary)


func chat_anfitrion(texto: String) -> void:
	on_chat(1, texto)


func _lanzar_utilidad(av: AvatarRed, id: StringName, fuerte: bool) -> void:
	var b: Bot = av.nodo
	var a: ArmaDatos = Catalogo.arma(id)
	if a == null or not a.es_utilidad() or b.armas.inventario.cantidad_utilidad(id) <= 0 or av.ultima == null:
		_rechazar(av, "lanzar invalido", false)
		return
	if b.armas._t + 0.000001 < b.armas._proximo:
		return
	var dir: Vector3 = av.ultima.mira_dir()
	var v: float = a.velocidad_lanzamiento if fuerte else a.velocidad_lanzamiento_flojo
	var vel: Vector3 = (dir + Vector3.UP * 0.18).normalized() * v + b.velocity * 0.4
	b.armas.lanzar_utilidad(id, b.ojos() + dir * 0.35 - Vector3.UP * 0.1, vel)


# ------------------------------------------------------------------ bucle del servidor

func _physics_process(dt: float) -> void:
	t_s += dt
	t_ms = int(t_s * 1000.0)
	if cargando:
		_t_carga += dt
		if _t_carga > T_MUNDO_LISTO_MAX:
			empezar()
		return
	if not en_partida or partida == null:
		return
	tick += 1
	for av: AvatarRed in avatares.values():
		_tick_avatar(av, dt)
	_registrar_historial()
	if jugador_local != null and is_instance_valid(jugador_local):
		pass
	if tick % TICK_SNAPSHOT == 0:
		_vigilar_entidades()
		_enviar_snapshots()
	_t_tabla -= dt
	if _t_tabla <= 0.0:
		_t_tabla = 1.0
		_enviar_tablas()
	if _t_fin >= 0.0:
		_t_fin -= dt
		if _t_fin <= 0.0:
			volver_al_lobby()


func _marcar_teleport(av: AvatarRed) -> void:
	av.epoch = (av.epoch + 1) & 0xFF
	av.cola.clear()
	av.ultima = null
	av.rafaga_pend = 0
	av.st = MovimientoJugador.Estado.new()
	if av.nodo != null:
		MovimientoJugador.de_pie(av.nodo, av.st)
		av.nodo.cabeza.position.y = MovimientoJugador.OJOS_PIE
		av.pos_prev = av.nodo.global_position


func _tick_avatar(av: AvatarRed, dt: float) -> void:
	var b: Bot = av.nodo
	if b == null or not is_instance_valid(b):
		return
	if av.pos_prev != Vector3.INF and b.global_position.distance_to(av.pos_prev) > 1.5:
		_marcar_teleport(av)
	elif b.muerto:
		# muerto: se descartan las entradas (se reconocen igual) y se reinicia el estado para la siguiente vida
		if not av.cola.is_empty():
			av.ultimo_seq = (av.cola[av.cola.size() - 1] as EntradaRed).seq
			av.cola.clear()
		av.st.agachado = false
		av.fire_prev = false
		av.pos_prev = b.global_position
		return
	av.credito = minf(av.credito + dt, CREDITO_MAX)
	var n: int = 0
	while not av.cola.is_empty() and n < 2 and av.credito >= dt:
		var e: EntradaRed = av.cola[0]
		if e.seq > av.ultimo_seq + 1 and av.ultima != null and e.seq - av.ultimo_seq - 1 <= REPETIR_HUECO_MAX:
			# se perdieron entradas: se repite la ultima (el cliente tambien simulo esos ticks)
			e = av.ultima.copiar()
			e.seq = av.ultimo_seq + 1
		else:
			av.cola.pop_front()
		av.credito -= dt
		_aplicar_entrada(av, e, dt)
		n += 1
	av.pos_prev = b.global_position
	var v: float = Vector2(b.velocity.x, b.velocity.z).length()
	av.vel_max_vista = maxf(av.vel_max_vista, v)


func _aplicar_entrada(av: AvatarRed, e: EntradaRed, dt: float) -> void:
	var b: Bot = av.nodo
	var a: ArmaDatos = b.armas.actual()
	av.st.mult_arma = a.velocidad_mov if a != null else 1.0
	var apunta: bool = a != null and e.apuntar() and a.apuntable and not av.st.corriendo and not b.armas.recargando and not b.armas.cambiando
	av.aim_t = move_toward(av.aim_t, 1.0 if apunta else 0.0, dt / maxf(a.tiempo_apuntar if a != null else 0.1, 0.01))
	av.st.mult_estado = lerpf(1.0, a.velocidad_apuntando if a != null else 1.0, av.aim_t)
	MovimientoJugador.paso(b, av.st, e, dt)
	b.cabeza.position.y = av.st.ojos_y
	b.pitch = clampf(e.mira_pitch, -deg_to_rad(89.0), deg_to_rad(89.0))
	b.cabeza.rotation = Vector3(b.pitch, 0.0, 0.0)
	av.ultimo_seq = e.seq
	av.ultima = e
	av.entradas_procesadas += 1
	if av.st.corriendo:
		av.no_disparar_hasta = t_ms + int(GestorArmas.DEMORA_CORRER * 1000.0)
	_procesar_fuego(av, e)
	av.fire_prev = e.disparar()



func _dispersion(av: AvatarRed, a: ArmaDatos) -> float:
	if av.st.corriendo:
		return a.dispersion_correr
	var b: Bot = av.nodo
	var vel: float = Vector2(b.velocity.x, b.velocity.z).length()
	return Balistica.dispersion(a, vel, av.st.en_suelo, av.st.agachado, av.aim_t, b.ceguera.nivel())


func _procesar_fuego(av: AvatarRed, e: EntradaRed) -> void:
	var b: Bot = av.nodo
	var armas: ArmasBot = b.armas
	var a: ArmaDatos = armas.actual()
	if a == null or a.es_utilidad() or a.tipo == ArmaDatos.T_SABLE or a.tipo == ArmaDatos.T_PUNO:
		return
	var flanco: bool = e.disparar() and not av.fire_prev
	var quiere: bool
	if a.automatica or a.carga_tiempo > 0.0:
		quiere = e.disparar()
	else:
		quiere = flanco or av.rafaga_pend > 0
	if not quiere:
		return
	if a.tipo != ArmaDatos.T_CUERPO and (av.st.corriendo or t_ms < av.no_disparar_hasta):
		return
	var disp: float = _dispersion(av, a)
	var rest: Array = _rebobinar(e.t_vista, av.id)
	var res: Dictionary = armas.intentar_disparo(b.ojos(), e.mira_dir(), disp)
	_restaurar(rest)
	if res.is_empty():
		if flanco and a.cargador > 0 and armas.cargador_actual() <= 0:
			armas.recargar()
		return
	stats["disparos"] = int(stats["disparos"]) + 1
	if a.rafaga > 1:
		av.rafaga_pend = a.rafaga - 1 if flanco else maxi(av.rafaga_pend - 1, 0)
	_confirmar_impacto(av, res, a)


func _confirmar_impacto(av: AvatarRed, res: Dictionary, a: ArmaDatos) -> void:
	var lista: Array = res.get("impactos", [res])
	var zona_hit: String = ""
	var mato: bool = false
	var dano: float = 0.0
	for r: Dictionary in lista:
		var s: Salud = r.get("salud") as Salud
		if s == null or bool(r.get("bloqueado", false)) or s == av.nodo.salud:
			continue
		if s.equipo != 0 and s.equipo == av.nodo.salud.equipo:
			continue
		if float(r.get("daño", 0.0)) <= 0.0:
			continue
		zona_hit = str(r["zona"])
		dano += float(r["daño"])
		mato = mato or not s.vivo
		var vh: int = _id_de(s)
		var peer_v: int = _peer_de_id(vh)
		if peer_v > 0:
			a_cliente(peer_v, &"dano", {"cant": float(r["daño"]), "origen": av.nodo.global_position, "zona": zona_hit})
	if zona_hit != "":
		a_cliente(av.peer, &"hit", {"zona": zona_hit, "mato": mato, "dano": dano})


func _peer_de_id(id: int) -> int:
	if id < 0 or id >= participantes.size():
		return 0
	var p: Dictionary = participantes[id]
	return int(p["peer"]) if p["humano"] else 0


# ------------------------------------------------------------------ compensacion de latencia

func _registrar_historial() -> void:
	var n: int = participantes.size()
	var pos := PackedVector3Array()
	var yaw := PackedFloat32Array()
	var ag := PackedByteArray()
	pos.resize(n)
	yaw.resize(n)
	ag.resize(n)
	for i in n:
		var nodo: Node3D = participantes[i]["nodo"] as Node3D
		if nodo == null or not is_instance_valid(nodo):
			continue
		pos[i] = nodo.global_position
		yaw[i] = nodo.rotation.y
		ag[i] = 1 if _agachado(nodo) else 0
	historial.append({"t": t_ms, "pos": pos, "yaw": yaw, "ag": ag})
	while historial.size() > 2 and t_ms - int(historial[0]["t"]) > HISTORIAL_MS:
		historial.pop_front()


func _agachado(nodo: Node) -> bool:
	if nodo is Bot:
		var av: AvatarRed = avatares.get((nodo as Bot).peer_red)
		return av != null and av.st.agachado
	if nodo is Jugador:
		return (nodo as Jugador).agachado
	return false


## Lleva a todos los participantes (menos `excepto`) a donde estaban en la hora `t_vista` (ms de servidor, limitada a ahora - limite).
## Devuelve lo necesario para `_restaurar`.
func _rebobinar(t_vista: int, excepto: int) -> Array:
	var rest: Array = []
	if historial.size() < 2 or not rebobinado:
		return rest
	var t_obj: int = clampi(t_vista, t_ms - LIMITE_REBOBINADO_MS, t_ms)
	var i: int = historial.size() - 1
	while i > 0 and int(historial[i]["t"]) > t_obj:
		i -= 1
	var h0: Dictionary = historial[i]
	var h1: Dictionary = historial[mini(i + 1, historial.size() - 1)]
	var dt: int = int(h1["t"]) - int(h0["t"])
	var k: float = clampf(float(t_obj - int(h0["t"])) / float(dt), 0.0, 1.0) if dt > 0 else 0.0
	var n: int = mini((h0["pos"] as PackedVector3Array).size(), participantes.size())
	for j in n:
		if j == excepto:
			continue
		var nodo: Node3D = participantes[j]["nodo"] as Node3D
		if nodo == null or not is_instance_valid(nodo):
			continue
		var p0: Vector3 = (h0["pos"] as PackedVector3Array)[j]
		var p1: Vector3 = (h1["pos"] as PackedVector3Array)[j] if (h1["pos"] as PackedVector3Array).size() > j else p0
		var p: Vector3 = p0.lerp(p1, k)
		if p.distance_to(nodo.global_position) < 0.02:
			continue
		var hb: Hitboxes = nodo.get_node_or_null("Hitboxes") as Hitboxes
		var ag_ahora: bool = _agachado(nodo)
		var ag_antes: bool = (h0["ag"] as PackedByteArray)[j] == 1
		rest.append([nodo, nodo.global_position, nodo.rotation.y, ag_ahora, hb])
		nodo.global_position = p
		nodo.rotation.y = lerp_angle(float((h0["yaw"] as PackedFloat32Array)[j]), float((h1["yaw"] as PackedFloat32Array)[j]) if (h1["yaw"] as PackedFloat32Array).size() > j else 0.0, k)
		if hb != null:
			if ag_antes != ag_ahora:
				hb.ajustar_altura(MovimientoJugador.ALTURA_AGACHADO if ag_antes else MovimientoJugador.ALTURA_PIE)
			for z: Node3D in hb.zonas.values():
				z.force_update_transform()
	return rest


func _restaurar(rest: Array) -> void:
	for r: Array in rest:
		var nodo: Node3D = r[0]
		if not is_instance_valid(nodo):
			continue
		nodo.global_position = r[1]
		nodo.rotation.y = r[2]
		var hb: Hitboxes = r[4]
		if hb != null:
			hb.ajustar_altura(MovimientoJugador.ALTURA_AGACHADO if bool(r[3]) else MovimientoJugador.ALTURA_PIE)
			for z: Node3D in hb.zonas.values():
				z.force_update_transform()


# ------------------------------------------------------------------ snapshots y estado privado

func _entidad(p: Dictionary) -> Dictionary:
	var n: Node3D = p["nodo"] as Node3D
	var e: Dictionary = {"id": int(p["id"]), "vivo": false, "agachado": false, "corriendo": false, "lado": 0, "pos": Vector3.ZERO,
			"yaw": 0.0, "pitch": 0.0, "arma": 255}
	if n == null or not is_instance_valid(n):
		return e
	e["pos"] = n.global_position
	e["yaw"] = n.rotation.y
	e["lado"] = partida.lado_de(n) if not cfg.es_libre() else 0
	if n is Bot:
		var b: Bot = n as Bot
		var av: AvatarRed = avatares.get(b.peer_red) if b.humano_red else null
		e["vivo"] = not b.muerto
		e["pitch"] = b.pitch
		e["agachado"] = av != null and av.st.agachado
		e["corriendo"] = (av.st.corriendo if av != null else b.velocidad_horizontal() > 6.2)
		e["arma"] = ProtoRed.id_arma(b.armas.id_actual())
	elif n is Jugador:
		var j: Jugador = n as Jugador
		e["vivo"] = j.salud.vivo and not j.muerto
		e["pitch"] = j._pitch
		e["agachado"] = j.agachado
		e["corriendo"] = j.corriendo
		e["arma"] = ProtoRed.id_arma(j.gestor.id_actual())
	return e


func _cabecera() -> Dictionary:
	var c: Cachimba = partida.cachimba_nodo
	var port: int = ProtoRed.SIN_PORTADOR
	var pn: Node = partida.portador_cachimba()
	if pn != null:
		for p: Dictionary in participantes:
			if p["nodo"] == pn:
				port = int(p["id"])
	var caida: Node3D = partida.cachimba_caida()
	return {"tick": tick, "t_ms": t_ms, "fase": int(partida.fase), "t_fase": partida.t_fase, "ronda": partida.ronda,
			"puntos": partida.puntos, "lado0": partida.lado_grupo[0],
			"cach_estado": int(c.estado) if c != null else 0, "cach_site": (c.site.unicode_at(0) if c != null and c.site != "" else 0),
			"cach_restante": c.restante if c != null else 0.0, "cach_progreso": c.progreso if c != null else 0.0,
			"cach_pos": c.global_position if c != null else Vector3.ZERO, "portador": port,
			"caida": caida.global_position if caida != null else null}


func _enviar_snapshots() -> void:
	if avatares.is_empty() or red == null:
		return
	var ents: Array = []
	for p: Dictionary in participantes:
		ents.append(_entidad(p))
	var comun: PackedByteArray = ProtoRed.codificar_comun(_cabecera(), ents)
	for av: AvatarRed in avatares.values():
		var b: Bot = av.nodo
		if b == null or not is_instance_valid(b):
			continue
		var fl: int = 0
		fl |= ProtoRed.P_AGACHADO if av.st.agachado else 0
		fl |= ProtoRed.P_EN_SUELO if av.st.en_suelo else 0
		fl |= ProtoRed.P_CORRIENDO if av.st.corriendo else 0
		fl |= ProtoRed.P_SALTAR_PREV if av.st.saltar_prev else 0
		fl |= ProtoRed.P_VIVO if not b.muerto else 0
		var propio: PackedByteArray = ProtoRed.codificar_propio({"ack": av.ultimo_seq, "pos": b.global_position, "vel": b.velocity,
				"ojos_y": av.st.ojos_y, "flags": fl, "vida": b.salud.vida, "escudo": b.salud.escudo,
				"cargador": b.armas.cargador_actual(), "reserva": b.armas.reserva_actual(), "epoch": av.epoch,
				"arma": ProtoRed.id_arma(b.armas.id_actual())})
		var paq: PackedByteArray = propio + comun
		red.enviar(av.peer, &"s_snapshot", [paq])
		av.bytes_snap += paq.size()
		stats["snapshots"] = int(stats["snapshots"]) + 1
		stats["bytes_snapshots"] = int(stats["bytes_snapshots"]) + paq.size()
		_enviar_privado_si_cambia(av)


func _estado_privado(av: AvatarRed) -> Dictionary:
	var b: Bot = av.nodo
	var compras: Array = []
	for c: Dictionary in partida.compras_de(b):
		compras.append({"id": String(c["id"]), "precio": int(c["precio"])})
	return {"dinero": partida.dinero_de(b), "inv": b.armas.inventario.serializar(), "compras": compras}


func _enviar_privado_si_cambia(av: AvatarRed) -> void:
	var b: Bot = av.nodo
	var inv: Inventario = b.armas.inventario
	var h: String = "%d|%s|%s|%s|%s|%s|%d|%d" % [partida.dinero_de(b), inv.principal, inv.secundaria, inv.utilidades, inv.escudo,
			partida.compras_de(b).size(), 1 if b.muerto else 0, partida.fase]
	if h == av.priv_hash:
		return
	av.priv_hash = h
	a_cliente(av.peer, &"privado", _estado_privado(av))


func _enviar_tablas() -> void:
	for peer: int in clientes:
		if peer == 1:
			continue
		var av: AvatarRed = avatares.get(peer)
		var mi_g: int = partida.grupo_de(av.nodo) if av != null else -1
		var filas: Array = []
		for p: Dictionary in participantes:
			var d: Partida.DatosJugador = partida.datos.get(p["nodo"])
			if d == null:
				continue
			filas.append([int(p["id"]), d.bajas, d.muertes, d.dinero if (d.grupo == mi_g or cfg.es_libre()) else -1])
		a_cliente(peer, &"tabla", {"filas": filas, "puntos": partida.puntos})


## Armas del suelo, proyectiles, granadas y nubes nuevos: se avisa a los clientes para que los dibujen (visual-only).
func _vigilar_entidades() -> void:
	var tree: SceneTree = get_tree()
	var vivos: Dictionary = {}
	for n: Node in tree.get_nodes_in_group("armas_suelo"):
		var a: ArmaSuelo = n as ArmaSuelo
		vivos[a] = true
		if not _armas_suelo.has(a):
			var id: int = _sig_id_arma
			_sig_id_arma += 1
			_armas_suelo[a] = id
			_armas_suelo_ids[id] = a
			difundir(&"arma_suelo", {"id": id, "arma": String(a.arma_id), "carg": a.cargador, "res": a.reserva, "pos": a.global_position, "vel": a.vel})
	for a: ArmaSuelo in _armas_suelo.keys():
		if not vivos.has(a) or not is_instance_valid(a) or not a.is_in_group("armas_suelo"):
			var id2: int = int(_armas_suelo[a])
			_armas_suelo.erase(a)
			_armas_suelo_ids.erase(id2)
			difundir(&"arma_quitada", {"id": id2})
	for n: Node in tree.get_nodes_in_group("proyectiles"):
		var p: Proyectil = n as Proyectil
		if p != null and not _proyectiles_vistos.has(p):
			_proyectiles_vistos[p] = true
			difundir(&"proyectil", {"arma": String(p.arma.id), "pos": p.global_position, "vel": p.vel, "mult": p.mult, "dueno": _id_de(p.lanzador)})
	for n: Node in tree.get_nodes_in_group("lanzables"):
		var l: Lanzable = n as Lanzable
		if l != null and not _lanzables_vistos.has(l):
			_lanzables_vistos[l] = true
			difundir(&"lanzable", {"arma": String(l.arma.id), "pos": l.global_position, "vel": l.vel, "dueno": _id_de(l.lanzador)})
	for n: Node in tree.get_nodes_in_group("nubes"):
		var nb: NubeVision = n as NubeVision
		if nb != null and not _nubes_vistas.has(nb):
			_nubes_vistas[nb] = true
			difundir(&"nube", {"pos": nb.global_position, "radio": nb.radio, "dur": nb.duracion, "empuje": nb.empuje, "color": nb.color})
	if tick % 120 == 0:
		for d: Dictionary in [_proyectiles_vistos, _lanzables_vistos, _nubes_vistas]:
			for k: Variant in d.keys():
				if not is_instance_valid(k):
					d.erase(k)


# ------------------------------------------------------------------ efectos de los disparos de los demas

func _on_disparo_bot(a: ArmaDatos, res: Dictionary, b: Bot) -> void:
	_difundir_disparo(a, res, b.id_red, b.peer_red if b.humano_red else 0, b.ojos())


func _on_disparo_jugador_local(a: ArmaDatos, res: Dictionary, boca: Vector3) -> void:
	_difundir_disparo(a, res, _id_jugador_local(), 1, boca)


func _id_jugador_local() -> int:
	for p: Dictionary in participantes:
		if p["nodo"] == jugador_local:
			return int(p["id"])
	return -1


func _difundir_disparo(a: ArmaDatos, res: Dictionary, id_tirador: int, peer_tirador: int, origen: Vector3) -> void:
	if red == null or id_tirador < 0 or a.tipo == ArmaDatos.T_PROYECTIL or a.tipo == ArmaDatos.T_COHETE or a.tipo == ArmaDatos.T_CUERPO:
		return
	var b := PackedByteArray()
	b.resize(24)
	b.encode_u8(0, id_tirador)
	b.encode_u8(1, ProtoRed.id_arma(a.id))
	b.encode_u8(2, 1 if bool(res.get("impacto", false)) else 0)
	var pt: Vector3 = res.get("punto", origen)
	var nm: Vector3 = res.get("normal", Vector3.UP)
	b.encode_float(4, origen.x)
	b.encode_float(8, origen.y)
	b.encode_float(12, origen.z)
	b.encode_half(16, pt.x - origen.x)
	b.encode_half(18, pt.y - origen.y)
	b.encode_half(20, pt.z - origen.z)
	b.encode_s8(22, clampi(int(nm.x * 100.0), -100, 100))
	b.encode_s8(23, clampi(int(nm.z * 100.0), -100, 100))
	b.encode_u8(3, 1 if nm.y < 0.0 else 0)
	for peer: int in clientes:
		if peer != 1 and peer != peer_tirador:
			red.enviar(peer, &"s_disparo", [b])
