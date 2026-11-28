class_name ClienteRed
extends Node
## Cliente de red. Hace tres cosas:
##  1. LOBBY: se une al servidor, manda ordenes (hueco, nombre, personaje, listo, config) y recibe el estado de los huecos.
##  2. PREDICCION: cada tick de fisica toma la entrada (teclado, o `entrada_externa` en los tests), mueve a su `Jugador` con
##     `MovimientoJugador` (igual que el servidor), guarda la entrada en un buffer y manda las ultimas 4 al servidor (redundancia). Con
##     cada snapshot recibe la ultima entrada que el servidor proceso (`ack`) y su posicion exacta, descarta lo reconocido, y RE-APLICA lo
##     pendiente sobre el estado del servidor (reconciliacion). La diferencia se esconde con un desplazamiento visual de camara que se
##     desvanece (error pequeno) o se corrige de golpe (error grande / teletransporte).
##  3. INTERPOLACION: los demas participantes (`ProxyRed`) se dibujan ~100 ms en el pasado, interpolando entre dos snapshots; la hora del
##     servidor se estima con los propios snapshots. El disparo manda la hora de servidor que el jugador VE (`t_vista`) para que el
##     servidor rebobine los hitboxes (compensacion de latencia).
## No hay logica de juego aqui: el estado de la partida (`PartidaCliente`) es un espejo de lo que dice el servidor.

signal conectado
signal rechazado(motivo: String)
signal lobby_actualizado(estado: Dictionary)
signal sesion_iniciada(datos: Dictionary)
signal mundo_montado
signal sesion_terminada
signal desconectado
signal chat_recibido(datos: Dictionary)

enum Estado { CONECTANDO, LOBBY, CARGANDO, JUGANDO, CERRADO }

const INTERP_MS: int = 100
const REDUNDANCIA: int = 4
const MAX_PENDIENTES: int = 180
const ERROR_SUAVE_MAX: float = 2.0
const ERROR_IGNORAR: float = 0.004
const DESVANECER: float = 12.0

var red: Red
var estado: Estado = Estado.CONECTANDO
var nombre: String = "Jugador"
var personaje: StringName = &""
## Version del protocolo que anuncia al unirse (solo se cambia en pruebas).
var version: int = ProtoRed.VERSION
var lobby: Dictionary = {}
var mi_id: int = 0
var tu_id: int = -1
var cfg: ConfigPartida = null
var mundo: Node3D = null
var jugador: Jugador = null
var partida: PartidaCliente = null
var zona: ZonaActiva = null
var proxies: Dictionary = {}
var tick_hz: int = 60
## Estimaciones: RTT (ms), desplazamiento hora-servidor - hora-local (ms).
var rtt_ms: float = 0.0
var rtt_ultimo: float = 0.0
var offset_ms: float = 0.0
var snapshots_recibidos: int = 0
var bytes_snapshots: int = 0
var correcciones: int = 0
var ultimo_error: float = 0.0
var max_error: float = 0.0
var eventos_recibidos: Dictionary = {}
var ultimos_hits: Array = []
## Si es valida devuelve la `EntradaRed` de este tick (tests, bots de prueba); si no se lee el teclado.
var entrada_externa: Callable = Callable()
## Si es valida devuelve [Node3D raiz, Jugador] para montar el mundo al recibir `s_iniciar`.
var proveedor_mundo: Callable = Callable()

var _seq: int = 0
var _pendientes: Array = []
var _st := MovimientoJugador.Estado.new()
var _snap_pend: Dictionary = {}
var _buffer: Array = []
var _ultimo_snap_ms: int = 0
var _epoch: int = -1
var _eventos_cola: Array = []
var _mundo_listo: bool = false
var _cmd_prev: Dictionary = {}
var _t_ping: float = 0.0
var _armas_suelo: Dictionary = {}
var _error_visual: Vector3 = Vector3.ZERO
var _dt: float = 1.0 / 60.0
var _t_ultimo_disparo: float = -10.0
var _cach_estado_prev: int = 0
var _ult_lado0: int = 0
var _ult_vida: float = 100.0


func _ready() -> void:
	_dt = 1.0 / float(Engine.physics_ticks_per_second)
	if red != null:
		red.conectado_al_servidor.connect(_al_conectar)
		red.conexion_fallida.connect(func() -> void:
			estado = Estado.CERRADO
			rechazado.emit("no se pudo conectar"))
		red.servidor_perdido.connect(func() -> void:
			estado = Estado.CERRADO
			desconectado.emit())


func _al_conectar() -> void:
	mi_id = red.mi_id()
	red.enviar(1, &"c_unirse", [nombre, String(personaje), version])
	conectado.emit()


func cerrar() -> void:
	desmontar()


func hora_servidor_ms() -> int:
	return Time.get_ticks_msec() + int(offset_ms)


## Hora de servidor (ms) que se esta dibujando ahora (interpolacion).
func hora_vista_ms() -> int:
	return hora_servidor_ms() - INTERP_MS


# ------------------------------------------------------------------ lobby

func lobby_cmd(accion: StringName, a: Variant = null, b: Variant = null) -> void:
	if red != null:
		red.enviar(1, &"c_lobby", [String(accion), a, b])


func enviar_chat(texto: String) -> void:
	if red != null:
		red.enviar(1, &"c_chat", [texto])


func on_bienvenida(info: Dictionary) -> void:
	estado = Estado.LOBBY
	tick_hz = int(info.get("tick_hz", 60))


func on_rechazo(motivo: String) -> void:
	estado = Estado.CERRADO
	rechazado.emit(motivo)


func on_lobby(e: Dictionary) -> void:
	lobby = e
	if estado == Estado.CONECTANDO:
		estado = Estado.LOBBY
	if not bool(e.get("en_partida", false)) and (estado == Estado.JUGANDO or estado == Estado.CARGANDO):
		desmontar()
		estado = Estado.LOBBY
		sesion_terminada.emit()
	lobby_actualizado.emit(e)


func on_pong(t: int) -> void:
	var r: float = float(Time.get_ticks_msec() - t)
	rtt_ultimo = r
	rtt_ms = r if rtt_ms == 0.0 else lerpf(rtt_ms, r, 0.2)


# ------------------------------------------------------------------ montar el mundo del cliente

func on_iniciar(datos: Dictionary) -> void:
	estado = Estado.CARGANDO
	tu_id = int(datos.get("tu_id", -1))
	tick_hz = int(datos.get("tick_hz", 60))
	sesion_iniciada.emit(datos)
	if proveedor_mundo.is_valid():
		var r: Array = proveedor_mundo.call()
		await montar_mundo(r[0], r[1], datos)


## Construye zona, espejo de la partida y proxies sobre `raiz` con `jug` como jugador local. Avisa al servidor cuando termina.
func montar_mundo(raiz: Node3D, jug: Jugador, datos: Dictionary) -> void:
	desmontar_mundo_parcial()
	mundo = raiz
	jugador = jug
	var cd: Dictionary = datos["cfg"]
	cfg = ConfigPartida.new()
	cfg.aplicar_modo(StringName(str(cd["modo"])))
	cfg.zona = str(cd["zona"])
	cfg.nombres = [str((cd["nombres"] as Array)[0]), str((cd["nombres"] as Array)[1])]
	cfg.rondas_ganar = int(cd["rondas"])
	cfg.dificultad = StringName(str(cd["dificultad"]))
	cfg.semilla = int(cd["semilla"])
	var libre: bool = cfg.es_libre()
	zona = null
	if not libre:
		zona = ZonaActiva.crear(cfg.zona)
		raiz.add_child(zona)
		await get_tree().physics_frame
	partida = PartidaCliente.new()
	partida.name = "PartidaCliente"
	add_child(partida)
	partida.configurar(cfg, zona)
	partida.enviar_cmd = _enviar_cmd
	var vistos: Dictionary = {}
	for p: Dictionary in datos["parts"]:
		var g: int = int(p["grupo"])
		var id: int = int(p["id"])
		if id == tu_id:
			partida.registrar(jugador, g, str(p["nombre"]))
			continue
		var px: ProxyRed = ProxyRed.crear(id, str(p["nombre"]), StringName(str(p["personaje"])), 0)
		add_child(px)
		proxies[id] = px
		partida.registrar(px, g, "%s (%s)" % [p["nombre"], cfg.nombres[g]] if not libre else str(p["nombre"]))
		vistos[id] = true
	jugador.modo_red = true
	jugador.gestor.red = true
	jugador.activo = true
	jugador.muerto = false
	jugador.salud.reiniciar()
	jugador.hitboxes.activar(false)
	jugador.gestor.peticion_red.connect(_on_peticion_gestor)
	jugador.estado_mov = MovimientoJugador.Estado.new()
	_st = jugador.estado_mov
	MovimientoJugador.de_pie(jugador, _st)
	_pendientes.clear()
	_seq = 0
	_epoch = -1
	_buffer.clear()
	_armas_suelo.clear()
	if zona != null:
		zona.activar_barreras(true)
	ContornoEnemigos.asegurar(raiz, jugador)
	_mundo_listo = true
	estado = Estado.JUGANDO
	for ev: Array in _eventos_cola:
		_aplicar_evento(ev[0], ev[1])
	_eventos_cola.clear()
	mundo_montado.emit()
	red.enviar(1, &"c_mundo_listo", [])


func desmontar_mundo_parcial() -> void:
	_mundo_listo = false
	for p: ProxyRed in proxies.values():
		if is_instance_valid(p):
			p.queue_free()
	proxies.clear()
	if partida != null and is_instance_valid(partida):
		partida.queue_free()
	partida = null
	if zona != null and is_instance_valid(zona):
		zona.queue_free()
	zona = null
	for a: Node in _armas_suelo.values():
		if is_instance_valid(a):
			a.queue_free()
	_armas_suelo.clear()


func desmontar() -> void:
	if jugador != null and is_instance_valid(jugador):
		jugador.modo_red = false
		jugador.gestor.red = false
		if jugador.gestor.peticion_red.is_connected(_on_peticion_gestor):
			jugador.gestor.peticion_red.disconnect(_on_peticion_gestor)
	desmontar_mundo_parcial()
	for g: String in ["lanzables", "nubes", "proyectiles", "altavoces", "armas_suelo", "cachimba_suelo"]:
		if is_inside_tree():
			for n: Node in get_tree().get_nodes_in_group(g):
				n.queue_free()
	_buffer.clear()
	_pendientes.clear()
	_error_visual = Vector3.ZERO


# ------------------------------------------------------------------ comandos

func _enviar_cmd(nombre_cmd: StringName, a: Variant = null, b: Variant = null) -> void:
	if nombre_cmd == &"montar" or nombre_cmd == &"apagar":
		if _cmd_prev.get(nombre_cmd) == a:
			return
		_cmd_prev[nombre_cmd] = a
	red.enviar(1, &"c_cmd", [String(nombre_cmd), a, b])


func _on_peticion_gestor(nombre_cmd: StringName, a: Variant, b: Variant) -> void:
	_enviar_cmd(nombre_cmd, a, b)


# ------------------------------------------------------------------ bucle de fisica: prediccion y envio

func _physics_process(dt: float) -> void:
	if estado != Estado.JUGANDO or jugador == null or not _mundo_listo:
		return
	_dt = dt
	_reconciliar()
	_seq += 1
	var e: EntradaRed = entrada_externa.call() if entrada_externa.is_valid() else _leer_entrada()
	e.seq = _seq
	e.t_vista = hora_vista_ms()
	e.yaw = jugador.rotation.y
	_pendientes.append(e)
	if _pendientes.size() > MAX_PENDIENTES:
		_pendientes.pop_front()
	if not jugador.muerto:
		jugador.paso_red(e, dt)
	if e.disparar():
		_t_ultimo_disparo = Time.get_ticks_msec() / 1000.0
	var n: int = mini(REDUNDANCIA, _pendientes.size())
	red.enviar(1, &"c_entradas", [ProtoRed.empaquetar_entradas(_pendientes.slice(_pendientes.size() - n))])
	_t_ping -= dt
	if _t_ping <= 0.0:
		_t_ping = 1.0
		red.enviar(1, &"c_ping", [Time.get_ticks_msec()])
	# el error visual se desvanece
	if _error_visual.length_squared() > 0.000001:
		_error_visual = _error_visual.lerp(Vector3.ZERO, 1.0 - exp(-DESVANECER * dt))
	else:
		_error_visual = Vector3.ZERO
	jugador.poner_error_visual(_error_visual)


func _leer_entrada() -> EntradaRed:
	var e := EntradaRed.new()
	var puede: bool = jugador.activo and not jugador.muerto
	if puede:
		var v: Vector2 = Input.get_vector("mover_izquierda", "mover_derecha", "mover_adelante", "mover_atras")
		e.mx = int(roundf(v.x * 127.0))
		e.mz = int(roundf(v.y * 127.0))
		var b: int = 0
		b |= EntradaRed.B_SALTAR if Input.is_action_pressed("saltar") else 0
		b |= EntradaRed.B_CORRER if Input.is_action_pressed("correr") else 0
		b |= EntradaRed.B_SIGILO if Input.is_action_pressed("caminar_lento") else 0
		b |= EntradaRed.B_AGACHAR if Input.is_action_pressed("agacharse") else 0
		var raton: bool = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		b |= EntradaRed.B_DISPARAR if (raton and Input.is_action_pressed("disparar")) else 0
		b |= EntradaRed.B_APUNTAR if (raton and Input.is_action_pressed("disparo_secundario")) else 0
		e.botones = b
	var d: Vector3 = -jugador.camara.global_transform.basis.z
	e.mira_yaw = atan2(-d.x, -d.z)
	e.mira_pitch = asin(clampf(d.y, -1.0, 1.0))
	return e


## Aplica el ultimo snapshot propio: corrige el estado con lo que dijo el servidor y vuelve a simular las entradas aun no reconocidas.
func _reconciliar() -> void:
	if _snap_pend.is_empty():
		return
	var p: Dictionary = _snap_pend["propio"]
	_snap_pend = {}
	var fl: int = int(p["flags"])
	var vivo: bool = fl & ProtoRed.P_VIVO != 0
	_sincronizar_vida(p, vivo)
	if int(p["epoch"]) != _epoch:
		_epoch = int(p["epoch"])
		_pendientes.clear()
		jugador.global_position = p["pos"]
		jugador.velocity = p["vel"]
		_estado_desde_servidor(p)
		_error_visual = Vector3.ZERO
		return
	var ack: int = int(p["ack"])
	while not _pendientes.is_empty() and (_pendientes[0] as EntradaRed).seq <= ack:
		_pendientes.pop_front()
	var antes: Vector3 = jugador.global_position
	jugador.global_position = p["pos"]
	jugador.velocity = p["vel"]
	_estado_desde_servidor(p)
	if vivo:
		for e: EntradaRed in _pendientes:
			MovimientoJugador.paso(jugador, _st, e, _dt)
	jugador._cabeza_y(_st.ojos_y)
	jugador.agachado = _st.agachado
	var err: Vector3 = antes - jugador.global_position
	ultimo_error = err.length()
	max_error = maxf(max_error, ultimo_error)
	if ultimo_error > ERROR_SUAVE_MAX:
		_error_visual = Vector3.ZERO
		correcciones += 1
	elif ultimo_error > ERROR_IGNORAR:
		_error_visual += err
		correcciones += 1


func _estado_desde_servidor(p: Dictionary) -> void:
	var fl: int = int(p["flags"])
	var ag: bool = fl & ProtoRed.P_AGACHADO != 0
	if ag != _st.agachado:
		MovimientoJugador.poner_postura(jugador, _st, ag)
	_st.en_suelo = fl & ProtoRed.P_EN_SUELO != 0
	_st.corriendo = fl & ProtoRed.P_CORRIENDO != 0
	_st.saltar_prev = fl & ProtoRed.P_SALTAR_PREV != 0
	_st.ojos_y = float(p["ojos_y"])
	_st.mult_arma = jugador.mult_velocidad_arma
	_st.mult_estado = jugador.mult_velocidad_estado
	jugador.estado_mov = _st


func _sincronizar_vida(p: Dictionary, vivo: bool) -> void:
	var s: Salud = jugador.salud
	s.vida = float(p["vida"])
	s.escudo = float(p["escudo"])
	if vivo and jugador.muerto:
		jugador.revivir_red()
	elif not vivo and not jugador.muerto:
		jugador.morir_red()
	s.vivo = vivo
	# municion: se corrige con la del servidor solo si estamos quietos (no disparando ni recargando) y es la misma arma
	var g: GestorArmas = jugador.gestor
	var id: StringName = g.id_actual()
	if vivo and id != &"" and ProtoRed.id_arma(id) == int(p["arma"]) and not g.recargando and g.indice != 3 \
			and Time.get_ticks_msec() / 1000.0 - _t_ultimo_disparo > 0.5:
		var a: ArmaDatos = Catalogo.arma(id)
		if a != null and a.cargador > 0 and (g.inventario.cargador(id) != int(p["cargador"]) or g.inventario.reserva(id) != int(p["reserva"])):
			g.inventario.fijar_municion(id, int(p["cargador"]), int(p["reserva"]))
			g.municion_cambiada.emit()


# ------------------------------------------------------------------ snapshots, interpolacion y eventos

func on_snapshot(paq: PackedByteArray) -> void:
	var d: Dictionary = ProtoRed.decodificar(paq)
	if d.is_empty() or not _mundo_listo:
		return
	snapshots_recibidos += 1
	bytes_snapshots += paq.size()
	var ahora: int = Time.get_ticks_msec()
	var off: float = float(int(d["t_ms"]) - ahora)
	offset_ms = off if snapshots_recibidos == 1 else lerpf(offset_ms, off, 0.08)
	_ultimo_snap_ms = ahora
	_snap_pend = d
	var ents: Dictionary = {}
	for e: Dictionary in d["ents"]:
		ents[int(e["id"])] = e
	_buffer.append({"t": int(d["t_ms"]), "ents": ents})
	while _buffer.size() > 30:
		_buffer.pop_front()
	_aplicar_cabecera(d)


func _aplicar_cabecera(d: Dictionary) -> void:
	var p: PartidaCliente = partida
	if p == null:
		return
	var fase_nueva: int = int(d["fase"])
	var cambio_fase: bool = fase_nueva != int(p.fase)
	if cambio_fase and not (cfg.es_libre()):
		_cambiar_fase(fase_nueva, int(d["ronda"]))
	p.t_fase = float(d["t_fase"]) if abs(p.t_fase - float(d["t_fase"])) > 0.3 or cambio_fase else p.t_fase
	p.ronda = int(d["ronda"])
	p.puntos = [int(d["puntos"][0]), int(d["puntos"][1])]
	var l0: int = int(d["lado0"])
	if not cfg.es_libre() and l0 != 0:
		p.lado_grupo = [l0, 3 - l0]
		if _ult_lado0 != 0 and l0 != _ult_lado0:
			p.lados_cambiados.emit()
		_ult_lado0 = l0
		jugador.salud.equipo = p.lado_de(jugador)
	var c: Cachimba = p.cachimba_nodo
	if c != null:
		_aplicar_cachimba(c, d)
	# portador y Cachimba caida
	var pid: int = int(d["portador"])
	var nuevo: Node = null if pid == ProtoRed.SIN_PORTADOR else _nodo_de(pid)
	if nuevo != p.portador:
		p.portador = nuevo
		p.portador_cambiado.emit(nuevo)
	if d["caida"] != null:
		if p._caida == null or not is_instance_valid(p._caida):
			p._caida = CachimbaSuelo.new()
			p.add_child(p._caida)
		p._caida.global_position = d["caida"]
	elif p._caida != null:
		p._caida.queue_free()
		p._caida = null


func _aplicar_cachimba(c: Cachimba, d: Dictionary) -> void:
	var estado_n: int = int(d["cach_estado"])
	c.site = char(int(d["cach_site"])) if int(d["cach_site"]) > 0 else ""
	c.restante = float(d["cach_restante"])
	c.progreso = float(d["cach_progreso"])
	c.global_position = d["cach_pos"]
	if estado_n != _cach_estado_prev:
		var prev: int = _cach_estado_prev
		_cach_estado_prev = estado_n
		c.estado = estado_n as Cachimba.Estado
		c._actualizar_visual()
		if estado_n == Cachimba.Estado.MONTADA and prev != Cachimba.Estado.APAGANDO:
			c.montada.emit(c.site)
		elif estado_n == Cachimba.Estado.APAGADA:
			c.apagada.emit()
		elif estado_n == Cachimba.Estado.ALARMA:
			c.alarma.emit()
	elif estado_n != Cachimba.Estado.SIN_MONTAR:
		c._actualizar_visual()


func _cambiar_fase(fase_nueva: int, ronda: int) -> void:
	var p: PartidaCliente = partida
	p.fase = fase_nueva as Partida.Fase
	if zona != null:
		zona.activar_barreras(fase_nueva == Partida.Fase.COMPRA)
	if fase_nueva == Partida.Fase.COMPRA:
		p.ronda = ronda
		for g: String in Partida.GRUPOS_LIMPIEZA:
			for n: Node in get_tree().get_nodes_in_group(g):
				n.queue_free()
		for d: Partida.DatosJugador in p.datos.values():
			d.compras.clear()
			d.ingreso_ronda = 0
		p.ronda_iniciada.emit(ronda)
	p.fase_cambiada.emit(p.fase)


func _nodo_de(id: int) -> Node:
	if id == tu_id:
		return jugador
	return proxies.get(id)


func _process(_delta: float) -> void:
	if estado != Estado.JUGANDO or _buffer.size() < 1:
		return
	# al acabar la compra se abren las barreras sin esperar al servidor (prediccion: el movimiento depende de ellas)
	if partida != null and zona != null and partida.fase == Partida.Fase.COMPRA and partida.t_fase <= 0.0:
		zona.activar_barreras(false)
	var t: int = hora_vista_ms()
	var a: Dictionary = _buffer[0]
	var b: Dictionary = _buffer[_buffer.size() - 1]
	for i in range(_buffer.size() - 1, -1, -1):
		if int(_buffer[i]["t"]) <= t:
			a = _buffer[i]
			b = _buffer[mini(i + 1, _buffer.size() - 1)]
			break
	var dt_s: int = int(b["t"]) - int(a["t"])
	var k: float = clampf(float(t - int(a["t"])) / float(dt_s), 0.0, 1.0) if dt_s > 0 else 1.0
	var dt: float = get_process_delta_time()
	for id: int in proxies:
		var px: ProxyRed = proxies[id]
		var ea: Dictionary = (a["ents"] as Dictionary).get(id, {})
		var eb: Dictionary = (b["ents"] as Dictionary).get(id, ea)
		if ea.is_empty():
			ea = eb
		if ea.is_empty():
			continue
		var pos: Vector3 = (ea["pos"] as Vector3).lerp(eb["pos"], k)
		var yaw: float = lerp_angle(float(ea["yaw"]), float(eb["yaw"]), k)
		var pit: float = lerpf(float(ea["pitch"]), float(eb["pitch"]), k)
		px.aplicar(pos, yaw, pit, bool(eb["vivo"]), bool(eb["agachado"]), ProtoRed.arma_de_indice(int(eb["arma"])), int(eb["lado"]), dt)


func on_evento(tipo: StringName, datos: Variant) -> void:
	eventos_recibidos[tipo] = int(eventos_recibidos.get(tipo, 0)) + 1
	if not _mundo_listo:
		_eventos_cola.append([tipo, datos])
		if _eventos_cola.size() > 200:
			_eventos_cola.pop_front()
		return
	_aplicar_evento(tipo, datos)


func _aplicar_evento(tipo: StringName, d: Variant) -> void:
	match tipo:
		&"fase":
			pass     # el cambio de fase llega en el snapshot; el evento solo garantiza que no se pierda
		&"ronda_fin":
			partida.ultimo_ganador = int(d["g"])
			partida.ultimo_motivo = str(d["motivo"])
			partida.puntos = [int(d["puntos"][0]), int(d["puntos"][1])]
			partida.ronda_terminada.emit(partida.ultimo_ganador, partida.ultimo_motivo)
		&"partida_fin":
			partida.ganador_partida = int(d["g"])
			partida.partida_terminada.emit(partida.ganador_partida)
		&"baja":
			var atac: Node = _nodo_de(int(d["asesino"])) if int(d["asesino"]) >= 0 else null
			var vic: Node = _nodo_de(int(d["victima"]))
			if vic != null:
				SenalesCombate.obtener(get_tree()).baja.emit(atac, Salud.de(vic), Catalogo.arma(StringName(str(d["arma"]))))
		&"privado":
			_aplicar_privado(d)
		&"tabla":
			for f: Array in d["filas"]:
				var n: Node = _nodo_de(int(f[0]))
				var dj: Partida.DatosJugador = partida.datos.get(n)
				if dj != null:
					dj.bajas = int(f[1])
					dj.muertes = int(f[2])
					if int(f[3]) >= 0:
						dj.dinero = int(f[3])
		&"hit":
			ultimos_hits.append(d)
			jugador.gestor.impacto_confirmado.emit(str(d["zona"]), bool(d["mato"]))
		&"dano":
			var origen: Vector3 = d["origen"]
			var cercano: Node = null
			var mejor: float = 1.0
			for px: ProxyRed in proxies.values():
				var dd: float = px.global_position.distance_to(origen)
				if dd < mejor:
					mejor = dd
					cercano = px
			jugador.salud.herido.emit(float(d["cant"]), str(d["zona"]), cercano)
		&"ceguera":
			jugador.ceguera.cegar(float(d["nivel"]), float(d["seg"]))
		&"chat":
			chat_recibido.emit(d)
		&"arma_suelo":
			var a: ArmaSuelo = ArmaSuelo.crear(self, StringName(str(d["arma"])), int(d["carg"]), int(d["res"]), d["pos"], d["vel"])
			a.set_meta("id_red", int(d["id"]))
			_armas_suelo[int(d["id"])] = a
		&"arma_quitada":
			var q: Node = _armas_suelo.get(int(d["id"]))
			_armas_suelo.erase(int(d["id"]))
			if q != null and is_instance_valid(q):
				q.remove_from_group("armas_suelo")
				q.queue_free()
		&"proyectil":
			var arma_p: ArmaDatos = Catalogo.arma(StringName(str(d["arma"])))
			if arma_p != null and int(d["dueno"]) != tu_id:
				var pr: Proyectil = Proyectil.lanzar(self, arma_p, d["pos"], d["vel"], null, float(d["mult"]))
				pr.solo_visual = true
		&"lanzable":
			var arma_l: ArmaDatos = Catalogo.arma(StringName(str(d["arma"])))
			if arma_l != null:
				var l: Lanzable = Lanzable.crear(self, arma_l, d["pos"], d["vel"], null)
				l.solo_visual = true
		&"nube":
			NubeVision.crear(self, d["pos"], float(d["radio"]), float(d["dur"]), float(d["empuje"]), d["color"])
		_:
			pass


func _aplicar_privado(d: Dictionary) -> void:
	var dj: Partida.DatosJugador = partida.datos.get(jugador)
	if dj != null:
		dj.dinero = int(d["dinero"])
		dj.compras.clear()
		for c: Dictionary in d["compras"]:
			dj.compras.append({"id": StringName(str(c["id"])), "precio": int(c["precio"])})
	var g: GestorArmas = jugador.gestor
	var viejo: Inventario = g.inventario
	var nuevo := Inventario.new()
	nuevo.deserializar(d["inv"])
	# la municion de lo que ya llevabas se conserva (la predijo el cliente); lo nuevo trae la del servidor
	for id: StringName in nuevo.municion.keys():
		if viejo.municion.has(id) and viejo.tiene(id):
			nuevo.fijar_municion(id, viejo.cargador(id), viejo.reserva(id))
	g.inventario.deserializar(nuevo.serializar())
	jugador.salud.escudo = g.inventario.escudo
	g._asegurar_indice()
	g.inventario_cambiado.emit()
	g.municion_cambiada.emit()


func on_disparo(paq: PackedByteArray) -> void:
	if not _mundo_listo or paq.size() < 24:
		return
	var id: int = paq.decode_u8(0)
	var arma: ArmaDatos = Catalogo.arma(ProtoRed.arma_de_indice(paq.decode_u8(1)))
	if arma == null:
		return
	var origen := Vector3(paq.decode_float(4), paq.decode_float(8), paq.decode_float(12))
	var punto: Vector3 = origen + Vector3(paq.decode_half(16), paq.decode_half(18), paq.decode_half(20))
	var normal := Vector3(float(paq.decode_s8(22)) / 100.0, 0.0, float(paq.decode_s8(23)) / 100.0)
	normal.y = sqrt(maxf(1.0 - normal.x * normal.x - normal.z * normal.z, 0.0)) * (-1.0 if paq.decode_u8(3) == 1 else 1.0)
	var impacto: bool = paq.decode_u8(2) == 1
	var px: ProxyRed = proxies.get(id)
	if px != null:
		px.disparo()
	var ef: EfectosCombate = Utilidades.efectos(self)
	if ef != null:
		var res: Dictionary = {"impacto": impacto, "punto": punto, "normal": normal.normalized(), "collider": null, "zona": "", "daño": 0.0,
				"distancia": origen.distance_to(punto), "direccion": (punto - origen).normalized(), "salud": null, "fuerte": false}
		var boca: Vector3 = origen + (punto - origen).normalized() * 0.6 + Vector3(0.0, -0.15, 0.0)
		ef.mostrar_disparo(arma, res, boca)
		ef.sonido_en(boca, arma.sonido)
