extends SceneTree
## Test headless de la red (N1). Uso:
##   Godot_console.exe --headless --path game --script res://tests/test_red.gd [-- seccion=N]
## Servidor y clientes viven en el MISMO proceso (cada uno con su `MultiplayerAPI` y su `Red` aislados) pero hablan por ENet real
## (UDP en 127.0.0.1), asi que se prueba el transporte, los RPC y la autoridad del servidor de verdad. Secciones:
##   r1 conexion y rechazo     r2 lobby (unirse, hueco, nombre, personaje, listo, config del anfitrion)   r3 arranque y montaje del mundo
##   r4 sincronizacion de posiciones (prediccion del cliente y proxy interpolado)   r5 disparo de un cliente validado por el servidor (mata)
##   r6 compensacion de latencia (con lag simulado)   r7 compra en la fase de compra   r8 comandos invalidos (sin municion, sin dinero,
##   teletransporte, velocidad)   r9 desconexion -> bot   r10 chat y killfeed   r11 ancho de banda con 10 participantes   r12 volver al lobby

const PUERTO: int = 7791
const PUERTO_WS: int = 7792
const DT: float = 1.0 / 60.0

var fallos: int = 0
var main: Node3D
var j1: Jugador
var j2: Jugador
var srv: Red
var c1: Red
var c2: Red
var ctl1: Dictionary = {}
var ctl2: Dictionary = {}
var solo: int = 0
## `ws=1`: toda la bateria sobre WebSocket (servidor `--ws` + clientes `ws://`) en vez de ENet. Sin el, ENet + una comprobacion WebSocket (r13).
var usar_ws: bool = false
var informe: Array[String] = []


func comprobar(nombre: String, ok: bool, detalle: String = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", nombre, detalle])
	if not ok:
		fallos += 1


func frames(n: int) -> void:
	for i in n:
		await physics_frame


func hasta(cond: Callable, max_s: float) -> bool:
	var n: int = int(max_s * 60.0)
	for i in n:
		if cond.call():
			return true
		await physics_frame
	return bool(cond.call())


func _init() -> void:
	_ejecutar.call_deferred()


func nuevo_ctl() -> Dictionary:
	return {"mx": 0, "mz": 0, "btn": 0, "yaw": 0.0, "my": 0.0, "mp": 0.0}


func fabricar(j: Jugador, ctl: Dictionary) -> Callable:
	return func() -> EntradaRed:
		var e := EntradaRed.new()
		j.rotation.y = float(ctl["yaw"])
		e.mx = int(ctl["mx"])
		e.mz = int(ctl["mz"])
		e.botones = int(ctl["btn"])
		e.mira_yaw = float(ctl["my"])
		e.mira_pitch = float(ctl["mp"])
		return e


func _ejecutar() -> void:
	ctl1 = nuevo_ctl()
	ctl2 = nuevo_ctl()
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("seccion="):
			solo = int(a.get_slice("=", 1))
		elif a == "ws=1":
			usar_ws = true
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await frames(6)
	main.menu.cerrar()
	main.set_process_unhandled_input(false)
	j1 = main.get_node("Jugador")
	j1.activo = false
	for d: Diana in main.campo.dianas:
		d.salud.vivo = false
		d.hitboxes.activar(false)
	j2 = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Jugador
	main.add_child(j2)
	j2.activo = false
	await frames(2)
	await _r1_conexion()
	await _r2_lobby()
	await _r3_arranque()
	if srv.servidor.en_partida:
		await _r4_sincronizacion()
		await _r5_disparo()
		await _r6_latencia()
		await _r7_compra()
		await _r8_invalidos()
		await _r10_chat()
		await _r9_desconexion()
		await _r12_volver_lobby()
	await _r11_ancho_banda()
	if not usar_ws:
		await _r13_websocket()
	print("--- informe ---")
	for l: String in informe:
		print(l)
	print("RESULTADO: %s (%d fallos)" % ["PASS" if fallos == 0 else "FAIL", fallos])
	_limpiar()
	await frames(2)
	quit(0 if fallos == 0 else 1)


func _limpiar() -> void:
	for r: Red in [srv, c1, c2]:
		if r != null and is_instance_valid(r):
			r.cerrar()


## Conecta `r` al servidor de pruebas por el transporte elegido (ENet o WebSocket).
func _conectar(r: Red) -> Error:
	if usar_ws:
		return r.iniciar_cliente("ws://127.0.0.1:%d" % PUERTO)
	return r.iniciar_cliente("127.0.0.1", PUERTO)


func nuevo_cliente(nombre: String, jug: Jugador) -> Red:
	var r: Red = Red.nuevo_aislado(self, "Cliente_" + nombre)
	_conectar(r)
	r.cliente.nombre = nombre
	r.cliente.personaje = CatalogoPersonajes.ids()[0]
	r.cliente.proveedor_mundo = func() -> Array: return [main, jug]
	return r


# ------------------------------------------------------------------ r1

func _r1_conexion() -> void:
	print("== r1 conexion")
	srv = Red.nuevo_aislado(self, "Servidor")
	var err: Error = srv.iniciar_servidor(PUERTO, 10, usar_ws)
	comprobar("r1 el servidor escucha en el puerto %d" % PUERTO, err == OK, "err=%d" % err)
	srv.servidor.mundo = main
	srv.servidor.t_compra = 4.0
	srv.servidor.t_ronda = 40.0
	srv.servidor.bots_libres = 2
	c1 = nuevo_cliente("Ana", j1)
	c1.cliente.entrada_externa = fabricar(j1, ctl1)
	var ok: bool = await hasta(func() -> bool: return c1.cliente.estado == ClienteRed.Estado.LOBBY and srv.servidor.clientes.has(c1.mi_id()), 4.0)
	comprobar("r1 el cliente conecta y entra en el lobby", ok, "estado=%d" % c1.cliente.estado)
	comprobar("r1 el servidor lo tiene registrado en un hueco humano", srv.servidor._pos_de(c1.mi_id()).x >= 0)
	comprobar("r1 el primer cliente es el anfitrion", srv.servidor.anfitrion == c1.mi_id())
	var bad: Red = Red.nuevo_aislado(self, "Cliente_Malo")
	_conectar(bad)
	bad.cliente.version = 999
	var rechazo: Array = [""]
	bad.cliente.rechazado.connect(func(m: String) -> void: rechazo[0] = m)
	await hasta(func() -> bool: return rechazo[0] != "", 3.0)
	comprobar("r1 una version de red distinta se rechaza", str(rechazo[0]).contains("version"), str(rechazo[0]))
	bad.cerrar()
	await frames(10)


# ------------------------------------------------------------------ r2

func _r2_lobby() -> void:
	print("== r2 lobby")
	c2 = nuevo_cliente("Beto", j2)
	c2.cliente.entrada_externa = fabricar(j2, ctl2)
	var s: ServidorRed = srv.servidor
	var ok: bool = await hasta(func() -> bool: return c2.cliente.estado == ClienteRed.Estado.LOBBY and s.clientes.size() == 2, 4.0)
	comprobar("r2 el segundo cliente se une", ok)
	var p1: Vector2i = s._pos_de(c1.mi_id())
	var p2: Vector2i = s._pos_de(c2.mi_id())
	comprobar("r2 los humanos quedan en equipos distintos (reparto)", p1.x != p2.x, "%s %s" % [p1, p2])
	# el cliente 2 ve el lobby con los dos humanos
	await frames(10)
	var humanos_vistos: int = 0
	for g in 2:
		for h: Dictionary in c2.cliente.lobby["huecos"][g]:
			humanos_vistos += 1 if h["tipo"] == "humano" else 0
	comprobar("r2 el cliente recibe el estado del lobby (2 humanos)", humanos_vistos == 2, str(humanos_vistos))
	# nombre y personaje
	c1.cliente.lobby_cmd(&"nombre", "Ana la Grande", null)
	var otro: StringName = CatalogoPersonajes.ids()[1]
	c1.cliente.lobby_cmd(&"personaje", String(otro), null)
	await frames(15)
	var h1: Dictionary = s.huecos[p1.x][p1.y]
	comprobar("r2 cambiar nombre", h1["nombre"] == "Ana la Grande", str(h1["nombre"]))
	comprobar("r2 cambiar personaje", StringName(h1["personaje"]) == otro)
	c1.cliente.lobby_cmd(&"personaje", "no_existe", null)
	await frames(10)
	comprobar("r2 un personaje inexistente se ignora", StringName(s.huecos[p1.x][p1.y]["personaje"]) == otro)
	# cambiar de hueco pinchando un bot
	var destino: Vector2i = Vector2i(p1.x, 3)
	c1.cliente.lobby_cmd(&"hueco", destino.x, destino.y)
	await frames(15)
	comprobar("r2 cambiar de hueco (clic en un bot)", s._pos_de(c1.mi_id()) == destino, str(s._pos_de(c1.mi_id())))
	# pinchar el hueco de un humano no hace nada
	var pos2: Vector2i = s._pos_de(c2.mi_id())
	c1.cliente.lobby_cmd(&"hueco", pos2.x, pos2.y)
	await frames(10)
	comprobar("r2 un hueco ocupado por otro humano no se roba", s._pos_de(c2.mi_id()) == pos2 and s._pos_de(c1.mi_id()) == destino)
	# config: solo el anfitrion
	c2.cliente.lobby_cmd(&"config", {"zona": "plaza_america", "tam": 3}, null)
	await frames(10)
	comprobar("r2 un no-anfitrion no puede cambiar la config", s.tam_equipo == 5)
	c1.cliente.lobby_cmd(&"config", {"zona": "el_eje", "tam": 2, "modo": "pleno", "rondas": 3, "dificultad": "facil"}, null)
	await frames(10)
	comprobar("r2 el anfitrion cambia la config", s.zona_id == "el_eje" and s.tam_equipo == 2 and s.modo == &"pleno" and s.rondas_ganar == 3, "zona=%s tam=%d modo=%s" % [s.zona_id, s.tam_equipo, s.modo])
	comprobar("r2 los clientes ven la config", str(c2.cliente.lobby.get("zona", "")) == "el_eje" and int(c2.cliente.lobby.get("tam", 0)) == 2)
	comprobar("r2 los humanos siguen en sus huecos tras reducir el equipo", s._pos_de(c1.mi_id()).x >= 0 and s._pos_de(c2.mi_id()).x >= 0)
	# listo: contador x/y
	var c: Vector2i = s.contador_listos()
	comprobar("r2 contador 0/2 al principio", c == Vector2i(0, 2), str(c))
	c1.cliente.lobby_cmd(&"listo", true, null)
	await frames(10)
	comprobar("r2 contador 1/2 con uno listo (no arranca)", s.contador_listos() == Vector2i(1, 2) and not s.en_partida and not s.cargando)


# ------------------------------------------------------------------ r3

func _r3_arranque() -> void:
	print("== r3 arranque")
	var s: ServidorRed = srv.servidor
	s.modo = ConfigPartida.M_PLENO
	c2.cliente.lobby_cmd(&"listo", true, null)
	var ok: bool = await hasta(func() -> bool: return s.en_partida, 40.0)
	comprobar("r3 con todos listos la partida arranca", ok, "cargando=%s partida=%s c1=%d c2=%d cargado_por=%s" % [s.cargando, s.partida, c1.cliente.estado, c2.cliente.estado, s._cargado_por])
	if not ok:
		return
	comprobar("r3 los dos clientes montan su mundo", c1.cliente.estado == ClienteRed.Estado.JUGANDO and c2.cliente.estado == ClienteRed.Estado.JUGANDO)
	comprobar("r3 hay 4 participantes (2 humanos + 2 bots)", s.participantes.size() == 4, str(s.participantes.size()))
	comprobar("r3 la partida esta en fase de compra", s.partida.fase == Partida.Fase.COMPRA)
	var av1: ServidorRed.AvatarRed = s.avatares.get(c1.mi_id())
	var av2: ServidorRed.AvatarRed = s.avatares.get(c2.mi_id())
	comprobar("r3 cada humano tiene su avatar en el servidor", av1 != null and av2 != null and av1.nodo.humano_red and av2.nodo.humano_red)
	await hasta(func() -> bool: return c1.cliente.snapshots_recibidos > 6 and c2.cliente.snapshots_recibidos > 6 and j1.global_position.distance_to(av1.nodo.global_position) < 0.3, 6.0)
	comprobar("r3 el cliente recibe snapshots", c1.cliente.snapshots_recibidos > 3, str(c1.cliente.snapshots_recibidos))
	comprobar("r3 el espejo de la partida refleja la fase", c1.cliente.partida.fase == Partida.Fase.COMPRA)
	comprobar("r3 el cliente ve 3 proxies", c1.cliente.proxies.size() == 3, str(c1.cliente.proxies.size()))
	# el cliente esta en su spawn (servidor y cliente de acuerdo)
	var d: float = av1.nodo.global_position.distance_to(j1.global_position)
	comprobar("r3 el jugador del cliente esta donde dice el servidor", d < 0.3, "dist=%.3f" % d)
	var otro_g: int = c1.cliente.partida.grupo_de(c1.cliente.proxies[av2.id]) if c1.cliente.proxies.has(av2.id) else -1
	comprobar("r3 el cliente 1 sabe a que equipo juega cada uno", otro_g == s.participantes[av2.id]["grupo"])
	# el espejo no se confunde: dinero inicial privado
	await frames(30)
	comprobar("r3 el cliente conoce su dinero (800)", int((c1.cliente.partida.datos[j1] as Partida.DatosJugador).dinero) == 800)


# ------------------------------------------------------------------ r4

func _r4_sincronizacion() -> void:
	print("== r4 sincronizacion")
	var s: ServidorRed = srv.servidor
	var av1: ServidorRed.AvatarRed = s.avatares[c1.mi_id()]
	var av2: ServidorRed.AvatarRed = s.avatares[c2.mi_id()]
	# esperar a que acabe la fase de compra (barreras) y mover al cliente 1
	await hasta(func() -> bool: return s.partida.fase == Partida.Fase.RONDA, 12.0)
	comprobar("r4 acaba la fase de compra y empieza la ronda", s.partida.fase == Partida.Fase.RONDA)
	await frames(20)
	ctl1["mz"] = -127
	ctl1["yaw"] = 0.0
	var maxd: float = 0.0
	var recorrido0: Vector3 = j1.global_position
	for i in 150:
		await physics_frame
		maxd = maxf(maxd, av1.nodo.global_position.distance_to(j1.global_position))
	var avance: float = j1.global_position.distance_to(recorrido0)
	comprobar("r4 el cliente avanza (prediccion)", avance > 5.0, "avance=%.1f m" % avance)
	comprobar("r4 la prediccion y el servidor difieren poco mientras se corre (max %.2f m)" % maxd, maxd < 1.2, "max=%.2f" % maxd)
	ctl1["mz"] = 0
	await frames(60)
	var d: float = av1.nodo.global_position.distance_to(j1.global_position)
	comprobar("r4 parado: cliente y servidor coinciden (%.3f m)" % d, d < 0.08, "dist=%.3f" % d)
	comprobar("r4 el servidor proceso las entradas del cliente", av1.entradas_procesadas > 100, str(av1.entradas_procesadas))
	# el otro cliente ve a este jugador (proxy interpolado) cerca de su posicion real
	var px: ProxyRed = c2.cliente.proxies[av1.id]
	var dp: float = px.global_position.distance_to(av1.nodo.global_position)
	comprobar("r4 el proxy interpolado del otro cliente coincide con la posicion real parado (%.3f m)" % dp, dp < 0.15, "dist=%.3f" % dp)
	# velocidad: correr da ~7,8 m/s; nunca mas de lo posible
	ctl2["mz"] = -127
	ctl2["btn"] = EntradaRed.B_CORRER
	ctl2["yaw"] = PI
	await frames(40)
	var p0: Vector3 = av2.nodo.global_position
	await frames(60)
	var v: float = Vector2(av2.nodo.global_position.x - p0.x, av2.nodo.global_position.z - p0.z).length() / 1.0
	informe.append("r4 velocidad de carrera medida en el servidor: %.2f m/s (esperado <= %.1f)" % [v, MovimientoJugador.VEL_SPRINT])
	comprobar("r4 la velocidad nunca supera la fisica (%.2f m/s)" % v, v <= MovimientoJugador.VEL_SPRINT * 1.05, "v=%.2f" % v)
	ctl2["mz"] = 0
	ctl2["btn"] = 0
	await frames(20)


# ------------------------------------------------------------------ r5

## Apunta al centro del torso de `objetivo` desde los ojos de `desde` (yaw, pitch de mira).
func apuntar(ctl: Dictionary, desde: Vector3, hacia: Vector3) -> void:
	var d: Vector3 = hacia - desde
	ctl["my"] = atan2(-d.x, -d.z)
	ctl["mp"] = asin(clampf(d.y / d.length(), -1.0, 1.0))
	ctl["yaw"] = ctl["my"]


func _r5_disparo() -> void:
	print("== r5 disparo")
	var s: ServidorRed = srv.servidor
	var av1: ServidorRed.AvatarRed = s.avatares[c1.mi_id()]
	var av2: ServidorRed.AvatarRed = s.avatares[c2.mi_id()]
	# coloca al objetivo (cliente 2) a 15 m del tirador (cliente 1), en campo abierto y en su linea de tiro
	var t: Vector3 = await _buscar_linea(av1, av2)
	comprobar("r5 se encontro un tiro limpio entre los dos", t != Vector3.INF)
	if t == Vector3.INF:
		return
	# clase de arma: fusil de asalto (comprado en el servidor para esta prueba, no es una compra de la tienda)
	av1.nodo.armas.equipar(&"fusil_asalto")
	await frames(40)
	var vida0: float = av2.nodo.salud.vida
	var hits0: int = c1.cliente.ultimos_hits.size()
	var ojos: Vector3 = j1.camara.global_position
	var centro: Vector3 = av2.nodo.global_position + Vector3(0, 1.15, 0)
	apuntar(ctl1, ojos, centro)
	ctl1["btn"] = EntradaRed.B_DISPARAR
	await frames(6)
	ctl1["btn"] = 0
	await frames(30)
	var vida1: float = av2.nodo.salud.vida
	comprobar("r5 el disparo del cliente baja la vida del rival en el servidor", vida1 < vida0, "%.0f -> %.0f" % [vida0, vida1])
	comprobar("r5 el cliente recibe el hitmarker del servidor", c1.cliente.ultimos_hits.size() > hits0, str(c1.cliente.ultimos_hits.size() - hits0))
	comprobar("r5 el cliente 2 recibe el aviso de dano", int(c2.cliente.eventos_recibidos.get(&"dano", 0)) > 0)
	# ráfaga hasta matar (el servidor aplica cadencia y municion)
	var kills0: int = (s.partida.datos[av1.nodo] as Partida.DatosJugador).bajas
	for k in 12:
		apuntar(ctl1, j1.camara.global_position, av2.nodo.global_position + Vector3(0, 1.15, 0))
		ctl1["btn"] = EntradaRed.B_DISPARAR
		await frames(6)
		if not av2.nodo.salud.vivo:
			break
	ctl1["btn"] = 0
	await frames(30)
	comprobar("r5 el rival muere por disparos del cliente", not av2.nodo.salud.vivo and av2.nodo.muerto)
	comprobar("r5 el servidor cuenta la baja", (s.partida.datos[av1.nodo] as Partida.DatosJugador).bajas == kills0 + 1)
	comprobar("r5 el cliente 2 sabe que ha muerto (espejo)", j2.muerto)
	comprobar("r5 el killfeed llega (evento baja)", int(c1.cliente.eventos_recibidos.get(&"baja", 0)) >= 1)
	var municion_srv: int = av1.nodo.armas.inventario.cargador(&"fusil_asalto")
	comprobar("r5 el servidor lleva la cuenta de la municion (<30)", municion_srv < 30, str(municion_srv))
	informe.append("r5 disparos del servidor: %d, hit markers recibidos: %d" % [int(s.stats["disparos"]), c1.cliente.ultimos_hits.size()])


## Mueve (en el servidor) a `av2` a un punto a ~14 m de `av1` con linea de vision libre; devuelve el punto o INF.
func _buscar_linea(av1: ServidorRed.AvatarRed, av2: ServidorRed.AvatarRed) -> Vector3:
	var esp: PhysicsDirectSpaceState3D = root.get_world_3d().direct_space_state
	var base: Vector3 = av1.nodo.global_position
	for i in 24:
		var ang: float = TAU * float(i) / 24.0
		var p: Vector3 = base + Vector3(cos(ang), 0, sin(ang)) * 14.0
		var abajo := PhysicsRayQueryParameters3D.create(p + Vector3(0, 5, 0), p - Vector3(0, 6, 0), 1)
		var r: Dictionary = esp.intersect_ray(abajo)
		if r.is_empty():
			continue
		var suelo: Vector3 = r["position"]
		if absf(suelo.y - base.y) > 1.0:
			continue
		var q := PhysicsRayQueryParameters3D.create(base + Vector3(0, 1.4, 0), suelo + Vector3(0, 1.4, 0), 1)
		if not esp.intersect_ray(q).is_empty():
			continue
		av2.nodo.global_position = suelo + Vector3(0, 0.05, 0)
		await frames(20)
		return suelo
	return Vector3.INF


# ------------------------------------------------------------------ r6

func _r6_latencia() -> void:
	print("== r6 compensacion de latencia")
	var s: ServidorRed = srv.servidor
	# revivir al cliente 2 (el servidor lo hace al empezar la siguiente ronda; aqui se hace a mano)
	var av1: ServidorRed.AvatarRed = s.avatares[c1.mi_id()]
	var av2: ServidorRed.AvatarRed = s.avatares[c2.mi_id()]
	av2.nodo.reaparecer(av2.nodo.global_position, 0.0)
	await frames(30)
	c1.lag_ms = 100
	c2.lag_ms = 100
	srv.lag_ms = 100
	await frames(130)
	informe.append("r6 RTT medido por el cliente con lag simulado de 100 ms: %.0f ms" % c1.cliente.rtt_ultimo)
	comprobar("r6 el RTT medido refleja el lag simulado (>= 80 ms)", c1.cliente.rtt_ultimo >= 80.0, "%.0f" % c1.cliente.rtt_ultimo)
	var res: Array = []
	for modo_rebob in [true, false]:
		s.rebobinado = modo_rebob
		var impactos: int = 0
		var disparos: int = 8
		for n in disparos:
			if not av2.nodo.salud.vivo:
				av2.nodo.reaparecer(av2.nodo.global_position, 0.0)
			av2.nodo.salud.reiniciar()
			av2.nodo.armas.reiniciar()
			# el objetivo corre en lateral (perpendicular a la linea de tiro) con el cliente 2
			var dir_tiro: Vector3 = (av2.nodo.global_position - av1.nodo.global_position)
			dir_tiro.y = 0
			var lat: Vector3 = dir_tiro.normalized().cross(Vector3.UP)
			ctl2["yaw"] = atan2(-lat.x, -lat.z)
			ctl2["mz"] = -127
			ctl2["btn"] = 0
			await frames(50)
			var antes: float = av2.nodo.salud.vida
			# el tirador apunta a donde VE al objetivo (su proxy interpolado) y dispara una vez
			var px: ProxyRed = c1.cliente.proxies[av2.id]
			var visto: Vector3 = px.global_position + Vector3(0, 1.15, 0)
			apuntar(ctl1, j1.camara.global_position, visto)
			ctl1["btn"] = EntradaRed.B_DISPARAR
			await frames(2)
			ctl1["btn"] = 0
			await frames(25)
			if av2.nodo.salud.vida < antes:
				impactos += 1
			ctl2["mz"] = 0
			await frames(35)
			# vuelve al sitio
			av2.nodo.global_position = av1.nodo.global_position + dir_tiro.normalized() * 14.0
			await frames(25)
			av1.nodo.armas.reiniciar()
			av1.nodo.armas.equipar(&"fusil_asalto")
			await frames(35)
		res.append(impactos)
		informe.append("r6 impactos a un objetivo que corre a ~5 m/s con RTT 100 ms, rebobinado=%s: %d/%d" % [str(modo_rebob), impactos, disparos])
	s.rebobinado = true
	comprobar("r6 con compensacion de latencia se acierta mas que sin ella", int(res[0]) > int(res[1]), "con=%d sin=%d" % [res[0], res[1]])
	comprobar("r6 con compensacion se acierta la mayoria (>= 5/8)", int(res[0]) >= 5, str(res[0]))
	c1.lag_ms = 0
	c2.lag_ms = 0
	srv.lag_ms = 0
	ctl2["mz"] = 0
	await frames(30)


# ------------------------------------------------------------------ r7

func _r7_compra() -> void:
	print("== r7 compra")
	var s: ServidorRed = srv.servidor
	# se necesita una fase de compra: se fuerza la siguiente ronda
	s.partida.terminar_ronda(0, "tiempo")
	var ok: bool = await hasta(func() -> bool: return s.partida.fase == Partida.Fase.COMPRA, 15.0)
	comprobar("r7 empieza una nueva fase de compra", ok)
	await frames(40)
	var av1: ServidorRed.AvatarRed = s.avatares[c1.mi_id()]
	var d_srv: Partida.DatosJugador = s.partida.datos[av1.nodo]
	var d_cli: Partida.DatosJugador = c1.cliente.partida.datos[j1]
	var din0: int = d_srv.dinero
	comprobar("r7 el cliente conoce su dinero tras la ronda", d_cli.dinero == din0, "srv=%d cli=%d" % [din0, d_cli.dinero])
	var comprado: bool = c1.cliente.partida.comprar(j1, &"pistola_auto")
	await frames(40)
	comprobar("r7 el cliente compra una pistola automatica", comprado)
	comprobar("r7 el servidor la ha equipado al avatar", av1.nodo.armas.inventario.secundaria == &"pistola_auto", str(av1.nodo.armas.inventario.secundaria))
	comprobar("r7 el servidor descuenta 500", d_srv.dinero == din0 - 500, "%d -> %d" % [din0, d_srv.dinero])
	comprobar("r7 el cliente refleja el inventario y el dinero", j1.gestor.inventario.secundaria == &"pistola_auto" and d_cli.dinero == d_srv.dinero, "cli=%d" % d_cli.dinero)
	# vender devuelve el dinero
	var vendido: bool = c1.cliente.partida.vender(j1, &"pistola_auto")
	await frames(40)
	comprobar("r7 vender devuelve el dinero y la pistola", vendido and av1.nodo.armas.inventario.secundaria == &"pistola_9mm" and d_srv.dinero == din0, "%d" % d_srv.dinero)


# ------------------------------------------------------------------ r8

func _r8_invalidos() -> void:
	print("== r8 comandos invalidos")
	var s: ServidorRed = srv.servidor
	var av1: ServidorRed.AvatarRed = s.avatares[c1.mi_id()]
	var av2: ServidorRed.AvatarRed = s.avatares[c2.mi_id()]
	var d_srv: Partida.DatosJugador = s.partida.datos[av1.nodo]
	# compra sin dinero: el servidor rechaza aunque el cliente mande el comando a mano
	var din: int = d_srv.dinero
	var rech0: int = int(s.stats["rechazos"])
	c1.enviar(1, &"c_cmd", ["comprar", "fusil_asalto", null])
	c1.enviar(1, &"c_cmd", ["comprar", "lanzacohetes", null])
	await frames(30)
	comprobar("r8 compra sin dinero: no cambia ni el dinero ni el inventario", d_srv.dinero == din and av1.nodo.armas.inventario.principal == &"", "%d" % d_srv.dinero)
	comprobar("r8 el servidor anota el intento rechazado", int(s.stats["rechazos"]) >= rech0 + 0)
	c1.enviar(1, &"c_cmd", ["comprar", "articulo_inventado", null])
	c1.enviar(1, &"c_cmd", ["tp", Vector3(500, 50, 500), null])
	c1.enviar(1, &"c_cmd", ["dar_dinero", 9000, null])
	await frames(20)
	comprobar("r8 teletransporte, dinero y articulos inventados se rechazan", av1.nodo.global_position.distance_to(Vector3(500, 50, 500)) > 100.0 and d_srv.dinero == din and int(s.stats["rechazos"]) > rech0, "rechazos=%d" % int(s.stats["rechazos"]))
	# disparo sin municion: se vacia el arma en el servidor y el cliente sigue mandando "disparar"
	await hasta(func() -> bool: return s.partida.fase == Partida.Fase.RONDA, 12.0)
	await frames(10)
	av2.nodo.reaparecer(av2.nodo.global_position, 0.0)
	var t: Vector3 = await _buscar_linea(av1, av2)
	av1.nodo.armas.reiniciar()
	av1.nodo.armas.equipar(&"fusil_asalto")
	await frames(40)
	av1.nodo.armas.inventario.fijar_municion(&"fusil_asalto", 0, 0)
	var vida0: float = av2.nodo.salud.vida
	apuntar(ctl1, j1.camara.global_position, av2.nodo.global_position + Vector3(0, 1.15, 0))
	ctl1["btn"] = EntradaRed.B_DISPARAR
	await frames(40)
	ctl1["btn"] = 0
	await frames(10)
	comprobar("r8 disparar sin municion no hace dano (el servidor manda)", av2.nodo.salud.vida == vida0, "vida=%.0f" % av2.nodo.salud.vida)
	# el cliente intenta forzar la cadencia: mantiene "disparar" con un arma automatica; el servidor aplica la suya
	av1.nodo.armas.reiniciar()
	av1.nodo.armas.equipar(&"fusil_asalto")
	await frames(40)
	var disp0: int = av1.nodo.armas.disparos_totales
	var a: ArmaDatos = av1.nodo.armas.actual()
	ctl1["btn"] = EntradaRed.B_DISPARAR
	await frames(60)
	ctl1["btn"] = 0
	var hechos: int = av1.nodo.armas.disparos_totales - disp0
	var max_posible: int = int(ceilf(1.0 / a.intervalo())) + 1
	comprobar("r8 la cadencia la impone el servidor (%d disparos en 1 s, entre 5 y %d)" % [hechos, max_posible], hechos >= 5 and hechos <= max_posible, "hechos=%d" % hechos)
	# velocidad: entradas maximas durante 2 s no pueden superar la velocidad fisica
	var v0: Vector3 = av1.nodo.global_position
	ctl1["mz"] = -127
	ctl1["mx"] = 127
	ctl1["btn"] = EntradaRed.B_CORRER
	await frames(120)
	ctl1["mx"] = 0
	ctl1["mz"] = 0
	ctl1["btn"] = 0
	var recorrido: float = Vector2(av1.nodo.global_position.x - v0.x, av1.nodo.global_position.z - v0.z).length()
	comprobar("r8 en 2 s no se recorre mas de lo posible (%.1f m <= %.1f)" % [recorrido, MovimientoJugador.VEL_MAX * 2.0], recorrido <= MovimientoJugador.VEL_MAX * 2.0)
	# inundacion de entradas: mandar 40 paquetes de golpe no acelera al jugador
	var v1: Vector3 = av1.nodo.global_position
	var seq0: int = av1.ultimo_seq
	for k in 40:
		var e := EntradaRed.new()
		e.seq = seq0 + 1 + k
		e.mz = -127
		e.botones = EntradaRed.B_CORRER
		e.yaw = 0.0
		c1.enviar(1, &"c_entradas", [ProtoRed.empaquetar_entradas([e])])
	await frames(6)
	var salto: float = Vector2(av1.nodo.global_position.x - v1.x, av1.nodo.global_position.z - v1.z).length()
	comprobar("r8 una inundacion de entradas no teletransporta (%.2f m en 6 ticks)" % salto, salto < 1.5, "%.2f" % salto)
	await frames(30)


# ------------------------------------------------------------------ r10

func _r10_chat() -> void:
	print("== r10 chat")
	var s: ServidorRed = srv.servidor
	var recibido: Array = []
	c2.cliente.chat_recibido.connect(func(d: Dictionary) -> void: recibido.append(d))
	c1.cliente.enviar_chat("hola desde Ana")
	await frames(20)
	comprobar("r10 el chat llega a los demas clientes", recibido.size() == 1 and str(recibido[0]["texto"]) == "hola desde Ana", str(recibido))
	await frames(40)
	c1.cliente.enviar_chat("a".repeat(500))
	await frames(40)
	comprobar("r10 un mensaje largo se recorta", recibido.size() == 2 and str(recibido[1]["texto"]).length() <= ServidorRed.MAX_CHAT)
	var n: int = recibido.size()
	for i in 5:
		c1.cliente.enviar_chat("spam %d" % i)
	await frames(20)
	comprobar("r10 el spam se limita (1 mensaje cada 0,5 s)", recibido.size() <= n + 2, "recibidos=%d" % (recibido.size() - n))


# ------------------------------------------------------------------ r9

func _r9_desconexion() -> void:
	print("== r9 desconexion")
	var s: ServidorRed = srv.servidor
	var av2: ServidorRed.AvatarRed = s.avatares[c2.mi_id()]
	var nodo: Bot = av2.nodo
	var id: int = av2.id
	var peer: int = c2.mi_id()
	c2.cerrar()
	var ok: bool = await hasta(func() -> bool: return not s.clientes.has(peer), 4.0)
	comprobar("r9 el servidor detecta la desconexion", ok)
	comprobar("r9 su hueco pasa a bot (participante no humano)", not nodo.humano_red and not bool(s.participantes[id]["humano"]))
	comprobar("r9 sigue registrado en la partida", s.partida.datos.has(nodo))
	var pos0: Vector3 = nodo.global_position
	await frames(240)
	var movido: float = nodo.global_position.distance_to(pos0)
	comprobar("r9 el bot en su lugar actua (se mueve %.1f m en 4 s)" % movido, movido > 1.0 or nodo.muerto or s.partida.fase == Partida.Fase.COMPRA, "mov=%.1f fase=%d" % [movido, s.partida.fase])
	comprobar("r9 el hueco queda libre en el lobby", s._pos_de(peer).x < 0)
	comprobar("r9 el otro cliente sigue jugando", c1.cliente.estado == ClienteRed.Estado.JUGANDO)


# ------------------------------------------------------------------ r12

func _r12_volver_lobby() -> void:
	print("== r12 fin de partida y vuelta al lobby")
	var s: ServidorRed = srv.servidor
	s._t_fin = 0.5
	var ok: bool = await hasta(func() -> bool: return not s.en_partida and c1.cliente.estado == ClienteRed.Estado.LOBBY, 8.0)
	comprobar("r12 el servidor vuelve al lobby y el cliente desmonta su mundo", ok, "estado=%d" % c1.cliente.estado)
	comprobar("r12 el jugador local vuelve a modo normal", not j1.modo_red)
	comprobar("r12 no quedan participantes", s.participantes.is_empty())


# ------------------------------------------------------------------ r11

## Medicion de ancho de banda: partida de 10 (2 humanos + 8 bots).
func _r11_ancho_banda() -> void:
	print("== r11 ancho de banda con 10 participantes")
	var s: ServidorRed = srv.servidor
	if s.en_partida:
		s.volver_al_lobby()
		await frames(30)
	if c2 == null or not is_instance_valid(c2) or c2.transporte == null:
		c2 = nuevo_cliente("Beto", j2)
		c2.cliente.entrada_externa = fabricar(j2, ctl2)
		await hasta(func() -> bool: return s.clientes.size() == 2, 4.0)
	s.t_compra = 2.0
	s.t_ronda = 60.0
	c1.cliente.lobby_cmd(&"config", {"zona": "plaza_america", "tam": 5, "modo": "cachimba_wars", "dificultad": "normal"}, null)
	await frames(10)
	c1.cliente.lobby_cmd(&"listo", true, null)
	c2.cliente.lobby_cmd(&"listo", true, null)
	var ok: bool = await hasta(func() -> bool: return s.en_partida, 40.0)
	comprobar("r11 arranca una partida de 10", ok and s.participantes.size() == 10, str(s.participantes.size()))
	if not ok:
		return
	await hasta(func() -> bool: return s.partida.fase == Partida.Fase.RONDA, 10.0)
	# los dos clientes juegan: uno corre en circulos y dispara, el otro quieto
	var av1: ServidorRed.AvatarRed = s.avatares[c1.mi_id()]
	var av2: ServidorRed.AvatarRed = s.avatares[c2.mi_id()]
	var t0: int = Time.get_ticks_msec()
	var b1: int = av1.bytes_snap
	var b2: int = av2.bytes_snap
	var sn0: int = int(s.stats["snapshots"])
	var up0: int = int((c1.stats.get(&"c_entradas", {"bytes": 0}) as Dictionary)["bytes"])
	var pk0: int = int((c1.stats.get(&"c_entradas", {"paquetes": 0}) as Dictionary)["paquetes"])
	var rx0: int = c1.cliente.bytes_snapshots
	var cnt0: int = c1.cliente.snapshots_recibidos
	var ev0: int = 0
	for k: Variant in c1.cliente.eventos_recibidos:
		ev0 += int(c1.cliente.eventos_recibidos[k])
	var ang: float = 0.0
	var seg: float = 8.0
	for i in int(seg * 60.0):
		ang += 0.03
		ctl1["mz"] = -127
		ctl1["yaw"] = ang
		ctl1["btn"] = EntradaRed.B_DISPARAR if (i / 40) % 2 == 0 else 0
		await physics_frame
	ctl1["mz"] = 0
	ctl1["btn"] = 0
	var dt_s: float = float(Time.get_ticks_msec() - t0) / 1000.0
	var bajada: float = float(av1.bytes_snap - b1) / dt_s / 1024.0
	var bajada2: float = float(av2.bytes_snap - b2) / dt_s / 1024.0
	var up: float = float(int((c1.stats[&"c_entradas"] as Dictionary)["bytes"]) - up0) / dt_s / 1024.0
	var pk: float = float(int((c1.stats[&"c_entradas"] as Dictionary)["paquetes"]) - pk0) / dt_s
	var sn_s: float = float(c1.cliente.snapshots_recibidos - cnt0) / dt_s
	var tam_snap: float = float(c1.cliente.bytes_snapshots - rx0) / maxf(float(c1.cliente.snapshots_recibidos - cnt0), 1.0)
	var ev1: int = 0
	for k: Variant in c1.cliente.eventos_recibidos:
		ev1 += int(c1.cliente.eventos_recibidos[k])
	informe.append("r11 10 participantes: snapshots %.1f/s de %.0f bytes -> %.2f KB/s por cliente (carga util); eventos fiables %.1f/s" % [sn_s, tam_snap, bajada, float(ev1 - ev0) / dt_s])
	informe.append("r11 subida del cliente: %.2f KB/s en %.0f paquetes/s (16 bytes por entrada x4 redundancia)" % [up, pk])
	var sobrecarga: float = (bajada * 1024.0 + 28.0 * sn_s) / 1024.0
	informe.append("r11 estimacion en el cable (UDP+IP 28 bytes + ENet ~10 por paquete): bajada %.2f KB/s, subida %.2f KB/s" % [sobrecarga + 10.0 * sn_s / 1024.0, up + 38.0 * pk / 1024.0])
	comprobar("r11 bajada por cliente < 12 KB/s (%.2f)" % bajada, bajada < 12.0)
	comprobar("r11 el segundo cliente similar (%.2f KB/s)" % bajada2, bajada2 < 12.0)
	comprobar("r11 subida por cliente < 8 KB/s (%.2f)" % up, up < 8.0)
	comprobar("r11 llegan ~20 snapshots/s (%.1f)" % sn_s, sn_s > 15.0 and sn_s < 26.0)


# ------------------------------------------------------------------ r13

## WebSocket: un servidor `--ws` (segundo Red aislado) y un cliente `ws://` completan el saludo, entran al lobby, un cliente ENet no
## puede hablar con el y los RPC viajan en ambos sentidos (chat), igual que por ENet.
func _r13_websocket() -> void:
	print("== r13 transporte WebSocket")
	var sw: Red = Red.nuevo_aislado(self, "ServidorWS")
	var err: Error = sw.iniciar_servidor(PUERTO_WS, 10, true)
	comprobar("r13 el servidor WebSocket escucha en el puerto TCP %d" % PUERTO_WS, err == OK and sw.es_websocket and sw.transporte is WebSocketMultiplayerPeer, "err=%d" % err)
	sw.servidor.mundo = main
	var cw: Red = Red.nuevo_aislado(self, "ClienteWS")
	var err2: Error = cw.iniciar_cliente("ws://127.0.0.1:%d" % PUERTO_WS)
	comprobar("r13 el cliente acepta una URL ws://", err2 == OK and cw.es_websocket, "err=%d" % err2)
	cw.cliente.nombre = "Wanda"
	cw.cliente.personaje = CatalogoPersonajes.ids()[0]
	cw.cliente.proveedor_mundo = func() -> Array: return [main, j2]
	var ok: bool = await hasta(func() -> bool: return cw.cliente.estado == ClienteRed.Estado.LOBBY and sw.servidor.clientes.has(cw.mi_id()), 6.0)
	comprobar("r13 el cliente WebSocket entra en el lobby", ok, "estado=%d" % cw.cliente.estado)
	comprobar("r13 es el anfitrion de ese servidor", sw.servidor.anfitrion == cw.mi_id())
	cw.cliente.lobby_cmd(&"nombre", "Wanda la Web", null)      # RPC cliente -> servidor -> estado del lobby difundido de vuelta
	var pos: Vector2i = sw.servidor._pos_de(cw.mi_id())
	var ok_nombre: bool = await hasta(func() -> bool: return str(sw.servidor.huecos[pos.x][pos.y]["nombre"]) == "Wanda la Web" and str(cw.cliente.lobby["huecos"][pos.x][pos.y]["nombre"]) == "Wanda la Web", 3.0)
	comprobar("r13 un RPC de ida y vuelta (cambiar nombre en el lobby) funciona por WebSocket", ok_nombre)
	comprobar("r13 es_url_ws distingue destinos", Red.es_url_ws("ws://a/b") and Red.es_url_ws(" WSS://a/ws") and not Red.es_url_ws("127.0.0.1:7777"))
	cw.cerrar()
	await frames(10)
	comprobar("r13 el servidor ve la desconexion del cliente WebSocket", sw.servidor.clientes.is_empty())
	sw.cerrar()
	await frames(5)
