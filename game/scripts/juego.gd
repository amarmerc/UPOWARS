class_name Juego
extends Node
## Escena principal del juego (run/main_scene): carga el mundo (main.tscn: campus, jugador, HUD de combate) y lo ordena todo:
## lobby -> montar la partida (zona, navegacion, Partida, Director, bots) -> jugar -> volver al lobby. Es la capa de ENTRADA y de
## render de la arquitectura: traduce teclas a comandos (`ComandosJugador`) y pasa a los menus lo que lee de la `Partida`.
##   Esc: pausa (competitivo) o tienda + opciones (libre) · B: tienda (solo en la fase de compra) · Tab: marcador ·
##   E mantenido: montar (portador, en un site) o apagar la Cachimba (defensor) · clic al morir: cambiar de aliado.

const NOMBRES_BOTS: Array[String] = ["Marta", "Luis", "Carmen", "Pablo", "Lucía", "Diego", "Elena", "Álvaro", "Sara", "Hugo",
		"Irene", "Nacho", "Paula", "Dani", "Rocío", "Jorge", "Alba", "Raúl", "Nerea", "Víctor"]

var mundo: Node
var jugador: Jugador
var lobby: LobbyUI
var tienda: TiendaUI
var pausa: MenuPausaUI
var hud_partida: HudPartida
## Camara del lobby y del espectador.
var camara: Camera3D
## Si no es null, nadie cambia la camara activa (capturas de pantalla).
var camara_fija: Camera3D = null
var cfg: ConfigPartida = ConfigPartida.new()
var partida: Partida = null
var director: DirectorBots = null
var zona: ZonaActiva = null
var region: NavigationRegion3D = null
var bots: Array[Bot] = []
var comandos_jugador: ComandosJugador = null
var en_partida: bool = false
var montando_partida: bool = false

## Red: `red` vive en /root/Red. red_modo = "" (un jugador), "host" (este proceso es el servidor y el jugador local es un participante
## mas) o "cliente" (el servidor es otro proceso: `partida` es un espejo, el jugador predice y el servidor decide).
var red: Red = null
var red_modo: String = ""
var chat: ChatRed

var _espec: Node = null
var _interactuando: bool = false
var _pausado: bool = false


func _ready() -> void:
	var args: Dictionary = ArranqueRed.argumentos()
	if bool(args["servidor"]):
		await ArranqueRed.arrancar_servidor(self, args)       # servidor dedicado: sin lobby, sin HUD, sin audio
		return
	mundo = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(mundo)
	jugador = mundo.get_node("Jugador")
	camara = Camera3D.new()
	camara.name = "CamaraLobby"
	camara.far = 4500.0
	camara.fov = 65.0
	add_child(camara)
	lobby = LobbyUI.new()
	lobby.name = "Lobby"
	add_child(lobby)
	tienda = TiendaUI.new()
	tienda.name = "Tienda"
	add_child(tienda)
	pausa = MenuPausaUI.new()
	pausa.name = "Pausa"
	add_child(pausa)
	hud_partida = HudPartida.new()
	hud_partida.name = "HudPartida"
	add_child(hud_partida)
	chat = ChatRed.new()
	chat.name = "Chat"
	add_child(chat)
	chat.abierto.connect(func() -> void: jugador.activo = false)
	chat.cerrado.connect(func() -> void:
		if en_partida and not _pausado and not tienda.visible:
			jugador.activo = true)
	chat.enviar.connect(_enviar_chat)
	lobby.crear_local_pedido.connect(iniciar_host)
	lobby.unirse_pedido.connect(unirse)
	lobby.desconectar_pedido.connect(cerrar_red)
	lobby.iniciar.connect(func(c: ConfigPartida) -> void: iniciar(c))
	lobby.salir_juego.connect(func() -> void: get_tree().quit())
	lobby.zona_elegida.connect(_ver_zona)
	tienda.cerrada.connect(_al_cerrar_tienda)
	tienda.reanudar.connect(tienda.cerrar_tienda)
	tienda.volver_lobby.connect(mostrar_lobby)
	tienda.salir_juego.connect(func() -> void: get_tree().quit())
	pausa.reanudar.connect(_reanudar)
	pausa.volver_lobby.connect(mostrar_lobby)
	pausa.salir_juego.connect(func() -> void: get_tree().quit())
	jugador.reaparecido.connect(_al_reaparecer)
	for i in 4:
		await get_tree().physics_frame
	mundo.menu.cerrar()                      # el selector de spawn de la escena de pruebas solo se usa en el modo libre
	for d: Diana in mundo.campo.dianas:      # el campo de practica no forma parte de la partida
		d.salud.vivo = false
		d.hitboxes.activar(false)
	mostrar_lobby()
	if str(args["sim"]) != "":
		lobby.visible = false
		mundo.set_process_unhandled_input(false)
		ClienteSim.iniciar(self, mundo, jugador, str(args["sim"]), str((args["kv"] as Dictionary).get("nombre", "Sim")), args)


# ------------------------------------------------------------------ lobby

func mostrar_lobby() -> void:
	desmontar_partida()
	get_tree().paused = false
	_pausado = false
	pausa.visible = false
	tienda.visible = false
	hud_partida.visible = false
	mundo.hud.visible = false
	mundo.set_process_unhandled_input(false)
	lobby.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_ver_zona(ZonaActiva.ids_disponibles()[0] if not ZonaActiva.ids_disponibles().is_empty() else "")


## Coloca la camara del lobby mirando a la zona `id` (vista previa).
func _ver_zona(id: String) -> void:
	if id == "":
		return
	var d: Dictionary = ZonaActiva.datos_de(id)
	if d.is_empty():
		return
	var c: Dictionary = d["camara_lobby"]
	var p: Array = c["pos"]
	var m: Array = c["mira"]
	camara.global_position = Vector3(p[0], p[1], p[2])
	camara.look_at(Vector3(m[0], m[1], m[2]), Vector3.UP)
	camara.fov = float(c.get("fov", 60.0))
	if camara_fija == null:
		camara.make_current()


## Estado de observador: sin vida, sin hitboxes, sin entrada, sin arma en pantalla.
func _jugador_observador() -> void:
	jugador.activo = false
	jugador.muerto = false
	jugador.salud.vivo = false
	jugador.hitboxes.activar(false)
	jugador.gestor.mostrar_viewmodel(false)
	jugador.tiempo_reaparicion = 2.0
	jugador.gestor.kit_reaparicion = [&"fusil_asalto"]
	jugador.gestor.reiniciar()
	jugador.salud.equipo = 0


func desmontar_partida() -> void:
	en_partida = false
	_espec = null
	_interactuando = false
	if red != null and red_modo == "host" and red.servidor != null:
		red.servidor.desmontar()
	elif red != null and red_modo == "cliente" and red.cliente != null:
		red.cliente.desmontar()
	for b: Bot in bots:
		if is_instance_valid(b):
			b.queue_free()
	bots.clear()
	for n: Node in [director, partida, region, zona]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	director = null
	partida = null
	region = null
	zona = null
	comandos_jugador = null
	for g: String in ["lanzables", "nubes", "proyectiles", "altavoces", "armas_suelo", "cachimba_suelo"]:
		for n: Node in get_tree().get_nodes_in_group(g):
			n.queue_free()
	_jugador_observador()


# ------------------------------------------------------------------ montar la partida

## Monta la partida segun `config`: zona y navegacion (competitivo) o campus (libre), Partida, Director y bots.
func iniciar(config: ConfigPartida) -> void:
	if montando_partida:
		return
	montando_partida = true
	cfg = config
	lobby.visible = false
	desmontar_partida()
	var libre: bool = cfg.es_libre()
	var origen := Vector3.ZERO
	if libre:
		var spawns: Array = mundo.spawns
		var p: Array = (spawns[0] as Dictionary)["pos"] if not spawns.is_empty() else [-486.58, -1.9, 142.56]
		origen = Vector3(p[0], p[1], p[2])
		if cfg.bots_libres > 0:
			region = NavBots.hornear_campus(mundo)
			await NavBots.esperar_listo(mundo, origen)
	else:
		zona = ZonaActiva.crear(cfg.zona)
		mundo.add_child(zona)
		await get_tree().physics_frame
		region = NavBots.hornear_zona(mundo, zona)
		await NavBots.esperar_listo(mundo, zona.punto_spawn("atacantes", 0)["pos"])
	partida = Partida.new()
	partida.name = "Partida"
	add_child(partida)
	partida.configurar(cfg, zona)
	var mapa: RID = NavBots.mapa(mundo) if region != null else RID()
	if region != null:
		director = DirectorBots.new()
		director.name = "Director"
		add_child(director)
		director.configurar(zona, partida, cfg.modo_partida(), mapa, cfg.semilla)
		partida.director = director if not libre else null
	_crear_combatientes(origen)
	comandos_jugador = ComandosJugador.new(jugador, partida)
	hud_partida.vincular(partida, jugador)
	hud_partida.visible = true
	mundo.hud.visible = true
	mundo.hud.get_node("Info").visible = false
	tienda.vincular(partida, jugador)
	tienda.configurar(libre)
	partida.fase_cambiada.connect(_al_cambiar_fase)
	partida.ronda_iniciada.connect(func(_n: int) -> void: _espec = null)
	en_partida = true
	montando_partida = false
	if libre:
		mundo.set_process_unhandled_input(true)
		jugador.salud.reiniciar()
		jugador.hitboxes.activar(true)
		jugador.muerto = false
		jugador.activo = false
		jugador.gestor.mostrar_viewmodel(true)
		partida.iniciar_partida()
		mundo.menu.abrir()                   # elegir el punto de aparicion (cualquiera del campus)
	else:
		mundo.set_process_unhandled_input(false)
		jugador.gestor.mostrar_viewmodel(true)
		partida.iniciar_partida()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_actualizar_camara()


func _nombre_bot(i: int) -> String:
	return NOMBRES_BOTS[i % NOMBRES_BOTS.size()]


func _crear_combatientes(origen: Vector3) -> void:
	var dif: StringName = cfg.dificultad
	var n_bot: int = 0
	var pj: StringName = cfg.personaje_jugador if CatalogoPersonajes.existe(cfg.personaje_jugador) else StringName(PerfilJugador.cargar()["personaje"])
	jugador.gestor.poner_personaje(pj)
	var nombre_local: String = cfg.nombre_jugador if cfg.nombre_jugador.strip_edges() != "" else "Tú"
	if cfg.es_libre():
		partida.registrar(jugador, 0, nombre_local)
		var rng := RandomNumberGenerator.new()
		rng.seed = cfg.semilla
		for i in cfg.bots_libres:
			var b: Bot = Bot.crear(_nombre_bot(n_bot), 0, Bot.ROL_LIBRE, dif, cfg.semilla * 100 + i, partida, CatalogoPersonajes.aleatorio(rng))
			n_bot += 1
			add_child(b)
			var p: Vector3 = NavigationServer3D.map_get_closest_point(NavBots.mapa(mundo), origen + Vector3(randf_range(-40, 40), 0, randf_range(-40, 40)))
			b.teletransportar(p, randf() * 360.0)
			partida.registrar(b, 0, b.nombre)
			if director != null:
				director.agregar(b)
			bots.append(b)
			b.comprar_kit()
		if director != null:
			director.preparar()
		return
	# competitivo: un combatiente por hueco; el humano local es el jugador (otros humanos: pendiente de red, de momento bots)
	var huecos: Array = cfg.huecos_efectivos()
	for g in 2:
		var lado: int = Partida.EQ_ATACANTES if g == 0 else Partida.EQ_DEFENSORES
		var lista: Array = huecos[g]
		for i in lista.size():
			var h: Dictionary = lista[i]
			if bool(h.get("local", false)) and h["tipo"] == ConfigPartida.TIPO_HUMANO:
				partida.registrar(jugador, g, nombre_local)
				continue
			var rol: StringName = Bot.ROL_CAZADOR if cfg.submodo == ConfigPartida.SUB_ELIMINACION else (Bot.ROL_ATACANTE if lado == Partida.EQ_ATACANTES else Bot.ROL_DEFENSOR)
			var nombre_b: String = str(h.get("nombre", ""))
			if nombre_b == "":
				nombre_b = _nombre_bot(n_bot)
			var b: Bot = Bot.crear(nombre_b, lado, rol, dif, cfg.semilla * 100 + g * 10 + i, partida, StringName(h["personaje"]))
			n_bot += 1
			add_child(b)
			partida.registrar(b, g, "%s (%s)" % [b.nombre, cfg.nombres[g]])
			director.agregar(b)
			bots.append(b)


# ------------------------------------------------------------------ fases, tienda y menus

func _al_cambiar_fase(fase: int) -> void:
	if cfg.es_libre():
		return
	if fase == Partida.Fase.COMPRA:
		_abrir_tienda_compra.call_deferred()
	elif tienda.visible:
		tienda.cerrar_tienda()


func _abrir_tienda_compra() -> void:
	if not en_partida or partida == null or partida.fase != Partida.Fase.COMPRA or _pausado:
		return
	if jugador.muerto or not jugador.salud.vivo:
		return
	tienda.configurar(false)
	jugador.activo = false
	tienda.abrir()


func _al_cerrar_tienda() -> void:
	if not en_partida or _pausado:
		return
	jugador.activo = true
	if not (jugador.muerto and not cfg.es_libre()):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _reanudar() -> void:
	pausa.visible = false
	tienda.visible = false
	_pausado = false
	get_tree().paused = false
	if en_partida:
		jugador.activo = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _al_reaparecer() -> void:
	_espec = null
	_actualizar_camara()


func _unhandled_input(event: InputEvent) -> void:
	if not en_partida or montando_partida:
		return
	if red_modo != "" and event is InputEventKey and event.pressed and not event.echo and (event as InputEventKey).keycode == KEY_T \
			and not chat.esta_abierto() and not tienda.visible:
		get_viewport().set_input_as_handled()
		chat.abrir()
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if cfg.es_libre():
			if tienda.visible:
				_reanudar()
			else:
				tienda.configurar(true)
				jugador.activo = false
				tienda.abrir()
		elif tienda.visible:
			tienda.cerrar_tienda()
		else:
			_pausado = true
			jugador.activo = false
			pausa.visible = true
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			get_tree().paused = true
	elif event.is_action_pressed("tienda") and not cfg.es_libre():
		if tienda.visible:
			tienda.cerrar_tienda()
		else:
			_abrir_tienda_compra()
	elif _espec != null and event is InputEventMouseButton and event.pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_siguiente_aliado()


func _siguiente_aliado() -> void:
	var lista: Array[Node] = partida.aliados_vivos(jugador)
	if lista.is_empty():
		return
	var i: int = lista.find(_espec)
	_espec = lista[(i + 1) % lista.size()]


# ------------------------------------------------------------------ bucle

func _physics_process(_delta: float) -> void:
	if not en_partida or partida == null or cfg.es_libre() or partida.cachimba_nodo == null:
		return
	var puede: bool = jugador.activo and not jugador.muerto and jugador.salud.vivo and Input.is_action_pressed("recoger") \
			and jugador.gestor.arma_mirada() == null
	if puede:
		_interactuando = true
		if partida.lado_de(jugador) == Partida.EQ_ATACANTES:
			comandos_jugador.montar_cachimba(true)
		else:
			comandos_jugador.apagar_cachimba(true)
	elif _interactuando:
		_interactuando = false
		comandos_jugador.montar_cachimba(false)
		comandos_jugador.apagar_cachimba(false)


func _process(_delta: float) -> void:
	_actualizar_camara()


## Camara activa: la del jugador mientras juega; la del compañero espectado al morir; la del lobby fuera de partida.
func _actualizar_camara() -> void:
	if camara_fija != null:
		return
	if not en_partida or partida == null:
		hud_partida.espectando = null
		return
	var muerto: bool = jugador.muerto and not cfg.es_libre() and partida.datos.has(jugador)
	var aliados: Array[Node] = partida.aliados_vivos(jugador) if muerto else ([] as Array[Node])
	if muerto and not aliados.is_empty():
		if _espec == null or not aliados.has(_espec):
			_espec = aliados[0]
		var b: Variant = _espec if (_espec is Bot or _espec is ProxyRed) else null
		if b != null:
			var dir: Vector3 = b.mirada_dir()
			camara.global_transform = Transform3D(Basis.looking_at(dir, Vector3.UP), b.ojos())
			camara.fov = jugador.fov_base
			if not camara.is_current():
				camara.make_current()
			jugador.gestor.mostrar_viewmodel(false)
			hud_partida.espectando = _espec
			return
	_espec = null
	hud_partida.espectando = null
	jugador.gestor.mostrar_viewmodel(not jugador.muerto and jugador.salud.vivo)
	if not jugador.camara.is_current():
		jugador.camara.make_current()


# ------------------------------------------------------------------ red (multijugador)

func _nuevo_red() -> Red:
	var r := Red.new()
	r.name = "Red"
	r.leer_argumentos(OS.get_cmdline_user_args())
	get_tree().root.add_child(r)
	return r


func _datos_perfil() -> Dictionary:
	var p: Dictionary = PerfilJugador.cargar()
	if lobby != null:
		p["nombre"] = lobby._nombre_local()
		p["personaje"] = lobby.personaje_elegido()
	return p


## "Crear partida local": este proceso hace de servidor y el jugador local es un participante mas (sin latencia). Otros se unen por IP:puerto.
func iniciar_host(puerto: int) -> void:
	cerrar_red()
	red = _nuevo_red()
	await get_tree().process_frame
	var err: Error = red.iniciar_servidor(puerto, 10)
	if err != OK:
		lobby.poner_estado_red("No se pudo abrir el puerto UDP %d (error %d)" % [puerto, err])
		red.queue_free()
		red = null
		return
	red_modo = "host"
	var s: ServidorRed = red.servidor
	s.mundo = mundo
	s.jugador_local = jugador
	s.lobby_cambiado.connect(func(e: Dictionary) -> void: lobby.aplicar_estado_red(e, 1))
	s.sesion_montada.connect(_on_sesion_host)
	s.sesion_terminada.connect(_on_sesion_terminada_red)
	s.chat_local.connect(func(d: Dictionary) -> void: chat.anadir(str(d["de"]), int(d["g"]), str(d["texto"])))
	lobby.red_enviar = func(accion: StringName, a: Variant, b: Variant) -> void: s.lobby_cmd(1, accion, a, b)
	var p: Dictionary = _datos_perfil()
	s.on_unirse(1, str(p["nombre"]), String(p["personaje"]), ProtoRed.VERSION)
	var ips: PackedStringArray = []
	for a: String in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			ips.append(a)
	lobby.poner_estado_red("Anfitrion en UDP %d. IP para unirse: %s" % [puerto, ", ".join(ips) if not ips.is_empty() else "127.0.0.1"])


func unirse(ip: String, puerto: int) -> void:
	cerrar_red()
	red = _nuevo_red()
	await get_tree().process_frame
	if red.iniciar_cliente(ip if ip != "" else "127.0.0.1", puerto) != OK:
		lobby.poner_estado_red("No se pudo iniciar la conexion")
		red.queue_free()
		red = null
		return
	red_modo = "cliente"
	var c: ClienteRed = red.cliente
	var p: Dictionary = _datos_perfil()
	c.nombre = str(p["nombre"])
	c.personaje = p["personaje"]
	c.proveedor_mundo = func() -> Array: return [mundo, jugador]
	c.lobby_actualizado.connect(func(e: Dictionary) -> void: lobby.aplicar_estado_red(e, red.mi_id()))
	lobby.red_enviar = func(accion: StringName, a: Variant, b: Variant) -> void: c.lobby_cmd(accion, a, b)
	c.sesion_iniciada.connect(func(_d: Dictionary) -> void: lobby.visible = false)
	c.mundo_montado.connect(_on_mundo_cliente)
	c.sesion_terminada.connect(_on_sesion_terminada_red)
	c.chat_recibido.connect(func(d: Dictionary) -> void: chat.anadir(str(d["de"]), int(d["g"]), str(d["texto"])))
	c.rechazado.connect(func(m: String) -> void:
		cerrar_red()
		lobby.poner_estado_red("Rechazado: " + m))
	c.desconectado.connect(func() -> void:
		cerrar_red()
		mostrar_lobby()
		lobby.poner_estado_red("Se perdio la conexion con el servidor"))
	lobby.poner_estado_red("Conectando a %s:%d..." % [ip, puerto])


func cerrar_red() -> void:
	if red == null:
		return
	desmontar_partida()
	red.cerrar()
	red.queue_free()
	red = null
	red_modo = ""
	if lobby != null:
		lobby.salir_red()


func _enviar_chat(texto: String) -> void:
	if red == null:
		return
	if red_modo == "host" and red.servidor != null:
		red.servidor.chat_anfitrion(texto)
	elif red.cliente != null:
		red.cliente.enviar_chat(texto)


func _on_sesion_terminada_red() -> void:
	mostrar_lobby()
	if red != null and red.servidor != null:
		lobby.aplicar_estado_red(red.servidor.estado_lobby(), 1)
	elif red != null and red.cliente != null and not red.cliente.lobby.is_empty():
		lobby.aplicar_estado_red(red.cliente.lobby, red.mi_id())


## Vistas y menus de una partida ya montada (Partida, zona, bots) para el anfitrion o el cliente de red.
func _vincular_vistas_red() -> void:
	var libre: bool = cfg.es_libre()
	lobby.visible = false
	hud_partida.vincular(partida, jugador)
	hud_partida.visible = true
	mundo.hud.visible = true
	mundo.hud.get_node("Info").visible = false
	tienda.vincular(partida, jugador)
	tienda.configurar(libre)
	partida.fase_cambiada.connect(_al_cambiar_fase)
	partida.ronda_iniciada.connect(func(_n: int) -> void: _espec = null)
	comandos_jugador = ComandosJugador.new(jugador, partida)
	en_partida = true
	montando_partida = false
	mundo.set_process_unhandled_input(libre)
	jugador.gestor.mostrar_viewmodel(true)
	jugador.salud.reiniciar()
	jugador.hitboxes.activar(red_modo == "host")
	jugador.muerto = false
	if libre:
		jugador.activo = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_actualizar_camara()


func _on_sesion_host() -> void:
	var s: ServidorRed = red.servidor
	cfg = s.cfg
	partida = s.partida
	zona = s.zona
	region = s.region
	director = s.director
	bots = s.bots
	var pj: StringName = StringName(PerfilJugador.cargar()["personaje"])
	if lobby != null:
		pj = lobby.personaje_elegido()
	jugador.gestor.poner_personaje(pj)
	_vincular_vistas_red()


func _on_mundo_cliente() -> void:
	var c: ClienteRed = red.cliente
	cfg = c.cfg
	partida = c.partida
	zona = c.zona
	jugador.gestor.poner_personaje(lobby.personaje_elegido())
	_vincular_vistas_red()
	jugador.hitboxes.activar(false)
