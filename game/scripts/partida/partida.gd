class_name Partida
extends ApiPartida
## Partida AUTORITATIVA (paquete P4): estado de rondas, equipos, dinero e inventarios. Separada de la entrada y del render: el
## jugador (via `ComandosJugador`) y los bots (via `ComandosBot`) actuan SOLO a traves de esta API (`comprar`, `vender`,
## `montar_cachimba`, `apagar_cachimba`); el HUD y los menus solo leen su estado y escuchan sus senales. Con ella se podra montar
## despues un servidor headless sin tocar la logica.
##
## Fases (competitivo): COMPRA (25 s, barreras activas, bots quietos, tienda) -> RONDA (1:40; con la Cachimba montada el reloj de
## la ronda se detiene y manda la cuenta atras de 40 s) -> FIN_RONDA (5 s) -> siguiente COMPRA ... -> FIN_PARTIDA. En el modo
## libre la fase es LIBRE: sin rondas, dinero infinito y compra siempre posible.
## Grupos y lados: hay dos grupos (0 y 1, con su nombre). `lado_grupo[g]` es el equipo (1 = atacantes, 2 = defensores) que ese
## grupo juega ahora; cambia tras la mitad de las rondas. `Salud.equipo` de cada combatiente es siempre su LADO actual.
## Una `Partida` en pruebas se avanza a mano con `avanzar(dt)` (`manual = true`); en el juego avanza sola en `_physics_process`.

signal fase_cambiada(fase: int)
signal ronda_iniciada(numero: int)
signal ronda_terminada(grupo_ganador: int, motivo: String)
signal partida_terminada(grupo_ganador: int)
signal lados_cambiados
signal cachimba_montada(site: String)
signal cachimba_apagada
signal cachimba_alarma
signal baja_registrada(asesino: Node, victima: Node)
signal compra_hecha(combatiente: Node, id: StringName)
signal portador_cambiado(nuevo: Node)

enum Fase { COMPRA, RONDA, FIN_RONDA, FIN_PARTIDA, LIBRE }

const EQ_ATACANTES: int = 1
const EQ_DEFENSORES: int = 2
const SIRENA: String = "res://assets/sonidos/sirena_alarma.wav"
const GRUPOS_LIMPIEZA: Array[String] = ["lanzables", "nubes", "proyectiles", "altavoces"]

## Datos de un combatiente en la partida.
class DatosJugador:
	extends RefCounted
	var nodo: Node
	var nombre: String = ""
	var grupo: int = 0
	var indice: int = 0
	var dinero: int = 0
	var bajas: int = 0
	var muertes: int = 0
	var ingreso_ronda: int = 0
	## Compras de la fase actual: [{"id": StringName, "precio": int}] (se pueden devolver con reembolso completo).
	var compras: Array[Dictionary] = []

var cfg: ConfigPartida = ConfigPartida.new()
var zona_activa: ZonaActiva = null
var cachimba_nodo: Cachimba = null
var director: DirectorBots = null
var fase: Fase = Fase.LIBRE
## Segundos que quedan de la fase actual.
var t_fase: float = 0.0
var ronda: int = 0
var puntos: Array[int] = [0, 0]
var consecutivas: Array[int] = [0, 0]
var lado_grupo: Array[int] = [EQ_ATACANTES, EQ_DEFENSORES]
var jugadores: Array[Node] = []
var datos: Dictionary = {}
var ganador_partida: int = -1
var ultimo_ganador: int = -1
var ultimo_motivo: String = ""
var manual: bool = false
var portador: Node = null
var rng := RandomNumberGenerator.new()
## Mensaje de evacuacion de la UPO (alarma de incendios).
var mensaje_evacuacion: String = ""

var _t: float = 0.0
var _montador: Node = null
var _t_montar: float = -10.0
var _apagador: Node = null
var _t_apagar: float = -10.0
var _site_montaje: String = ""
var _caida: CachimbaSuelo = null
var _sirena: AudioStreamPlayer = null
var _reset_total: bool = false


# ------------------------------------------------------------------ configuracion

## Prepara la partida con `config` y la zona (null en el modo libre). Crea la Cachimba si el submodo la usa.
func configurar(config: ConfigPartida, zona_nueva: ZonaActiva) -> void:
	cfg = config
	zona_activa = zona_nueva
	rng.seed = cfg.semilla + 7919
	if not cfg.es_libre() and cfg.submodo == ConfigPartida.SUB_CACHIMBA:
		_crear_cachimba()
	elif cachimba_nodo != null:
		cachimba_nodo.queue_free()
		cachimba_nodo = null
	fase = Fase.LIBRE if cfg.es_libre() else Fase.COMPRA
	lado_grupo = [EQ_ATACANTES, EQ_DEFENSORES]
	_sirena = AudioStreamPlayer.new()
	_sirena.name = "Sirena"
	if ResourceLoader.exists(SIRENA):
		_sirena.stream = load(SIRENA)
	add_child(_sirena)


func _crear_cachimba() -> void:
	cachimba_nodo = Cachimba.new()
	cachimba_nodo.name = "Cachimba"
	add_child(cachimba_nodo)
	cachimba_nodo.montada.connect(_on_montada)
	cachimba_nodo.apagada.connect(func() -> void: cachimba_apagada.emit())
	cachimba_nodo.alarma.connect(_on_alarma)


## Anade un combatiente (Bot o Jugador) al grupo `grupo` (0 o 1). El orden de registro fija su punto de aparicion.
func registrar(c: Node, grupo: int, nombre: String) -> DatosJugador:
	var d := DatosJugador.new()
	d.nodo = c
	d.nombre = nombre
	d.grupo = grupo
	for o: Node in jugadores:
		if (datos[o] as DatosJugador).grupo == grupo:
			d.indice += 1
	d.dinero = cfg.dinero_inicial
	jugadores.append(c)
	datos[c] = d
	var s: Salud = Salud.de(c)
	if s != null:
		s.nombre = nombre
		s.muerto.connect(_on_muerto.bind(c))
	if cfg.es_libre():
		if c is Bot and (c as Bot).humano_red:
			(c as Bot).reaparicion_auto = false      # el humano remoto reaparece cuando el servidor lo decide y compra el: sin kit automatico
		elif c is Bot:
			(c as Bot).reaparicion_auto = true
			(c as Bot).reaparecido.connect(func(b: Bot) -> void: b.comprar_kit())
	else:
		if c is Bot:
			(c as Bot).reaparicion_auto = false
		elif c is Jugador:
			(c as Jugador).tiempo_reaparicion = 1.0e9      # la Partida lo reaparece al empezar la ronda
			(c as Jugador).gestor.kit_reaparicion = []      # solo pistola 9 mm + navaja
			(c as Jugador).gestor.reiniciar()
	return d


func modo() -> StringName:
	return cfg.modo_partida()


func zona() -> ZonaActiva:
	return zona_activa


func cachimba() -> Cachimba:
	return cachimba_nodo


func exige_portador() -> bool:
	return cachimba_nodo != null


func portador_cachimba() -> Node:
	return portador if portador != null and is_instance_valid(portador) else null


func cachimba_caida() -> Node3D:
	return _caida if _caida != null and is_instance_valid(_caida) else null


func fase_compra() -> bool:
	return fase == Fase.COMPRA or fase == Fase.LIBRE


# ------------------------------------------------------------------ consultas

func lado_de(c: Node) -> int:
	var d: DatosJugador = datos.get(c)
	return lado_grupo[d.grupo] if d != null else 0


func grupo_de(c: Node) -> int:
	var d: DatosJugador = datos.get(c)
	return d.grupo if d != null else -1


func grupo_de_lado(lado: int) -> int:
	return lado_grupo.find(lado)


func nombre_grupo(g: int) -> String:
	return cfg.nombres[g]


func estaba_vivo(c: Node) -> bool:
	var s: Salud = Salud.de(c)
	return s != null and s.vivo


## Miembros del grupo `g`.
func miembros(g: int) -> Array[Node]:
	var out: Array[Node] = []
	for c: Node in jugadores:
		if (datos[c] as DatosJugador).grupo == g:
			out.append(c)
	return out


func vivos_de_lado(lado: int) -> int:
	var n: int = 0
	for c: Node in jugadores:
		if lado_de(c) == lado and estaba_vivo(c):
			n += 1
	return n


## Companeros vivos de `c` (sin incluirle), para espectar.
func aliados_vivos(c: Node) -> Array[Node]:
	var out: Array[Node] = []
	var g: int = grupo_de(c)
	for o: Node in jugadores:
		if o != c and (datos[o] as DatosJugador).grupo == g and estaba_vivo(o):
			out.append(o)
	return out


func dinero_de(combatiente: Node) -> int:
	if cfg.es_libre():
		return 1 << 30
	var d: DatosJugador = datos.get(combatiente)
	return d.dinero if d != null else 0


func compras_de(combatiente: Node) -> Array[Dictionary]:
	var d: DatosJugador = datos.get(combatiente)
	return d.compras if d != null else ([] as Array[Dictionary])


## Tabla de puntuacion: [{"grupo", "nombre", "lado", "puntos", "filas": [{"nombre", "bajas", "muertes", "dinero", "vivo", "nodo"}]}]
func tabla() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for g in 2:
		var filas: Array[Dictionary] = []
		for c: Node in miembros(g):
			var d: DatosJugador = datos[c]
			filas.append({"nombre": d.nombre, "bajas": d.bajas, "muertes": d.muertes, "dinero": d.dinero,
					"vivo": estaba_vivo(c), "nodo": c})
		filas.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["bajas"]) > int(b["bajas"]))
		out.append({"grupo": g, "nombre": cfg.nombres[g], "lado": lado_grupo[g], "puntos": puntos[g], "filas": filas})
	return out


# ------------------------------------------------------------------ economia

func _dar(c: Node, cantidad: int) -> void:
	var d: DatosJugador = datos.get(c)
	if d == null or cfg.es_libre():
		return
	var antes: int = d.dinero
	d.dinero = clampi(d.dinero + cantidad, 0, cfg.dinero_max)
	d.ingreso_ronda += d.dinero - antes


func _inv(c: Node) -> Inventario:
	if c is Jugador:
		return (c as Jugador).gestor.inventario
	if c is Bot:
		return (c as Bot).armas.inventario
	return null


## true si `c` lleva `id` (arma, utilidad o el escudo de ese tipo).
func lleva(c: Node, id: StringName) -> bool:
	return _tiene(c, id)


func _tiene(c: Node, id: StringName) -> bool:
	var inv: Inventario = _inv(c)
	if inv == null:
		return false
	if Catalogo.hueco(id) == Inventario.ESCUDO:
		return inv.escudo > 0.0 and is_equal_approx(inv.escudo, float(Catalogo.PUNTOS_ESCUDO.get(id, 0.0)))
	return inv.tiene(id)


## Evalua una compra sin aplicarla: {"ok": bool, "motivo": String, "precio": int, "reemplazo": Dictionary (compra de esta fase que se
## devolveria sola, {} si no hay)}.
func evaluar_compra(c: Node, id: StringName) -> Dictionary:
	var inv: Inventario = _inv(c)
	var info: Dictionary = Catalogo.info(id)
	var r: Dictionary = {"ok": false, "motivo": "", "precio": 0, "reemplazo": {}}
	if info.is_empty() or inv == null:
		r["motivo"] = "articulo desconocido"
		return r
	var precio: int = int(info["precio"])
	r["precio"] = precio
	if not fase_compra():
		r["motivo"] = "fuera de la fase de compra"
		return r
	if id == Inventario.PISTOLA_BASE or id == Inventario.NAVAJA:
		r["motivo"] = "gratuita: siempre la tienes"
		return r
	var hueco: StringName = StringName(info["hueco"])
	if (hueco == Inventario.PRINCIPAL or hueco == Inventario.SECUNDARIA) and inv.en_hueco(hueco) == id:
		r["motivo"] = "ya lo llevas"
		return r
	if hueco == Inventario.ESCUDO and inv.escudo >= float(Catalogo.PUNTOS_ESCUDO.get(id, 0.0)):
		r["motivo"] = "ya llevas ese escudo o mejor"
		return r
	var reemplazo: Dictionary = {}
	if hueco == Inventario.PRINCIPAL or hueco == Inventario.SECUNDARIA or hueco == Inventario.ESCUDO:
		reemplazo = _compra_del_hueco(c, hueco)
	var efectivo: int = dinero_de(c) + int(reemplazo.get("precio", 0))
	if precio > efectivo:
		r["motivo"] = "te faltan %d" % (precio - efectivo)
		return r
	var sim := Inventario.new()
	sim.deserializar(inv.serializar())
	if not reemplazo.is_empty():
		_quitar_sim(sim, StringName(reemplazo["id"]))
	var e: Dictionary = sim.equipar(id)
	if not bool(e["ok"]):
		r["motivo"] = str(e["motivo"])
		return r
	if c is Bot and ArmasBot.NO_SOPORTADAS.has(id):
		r["motivo"] = "el bot no lo usa"
		return r
	r["ok"] = true
	r["reemplazo"] = reemplazo
	return r


## Compra de esta fase que ocupa `hueco` y sigue en el inventario ({} si no hay).
func _compra_del_hueco(c: Node, hueco: StringName) -> Dictionary:
	var d: DatosJugador = datos.get(c)
	if d == null:
		return {}
	for e: Dictionary in d.compras:
		if Catalogo.hueco(StringName(e["id"])) == hueco and _tiene(c, StringName(e["id"])):
			return e
	return {}


func _quitar_sim(sim: Inventario, id: StringName) -> void:
	var hueco: StringName = Catalogo.hueco(id)
	if hueco == Inventario.ESCUDO:
		sim.escudo = 0.0
	elif hueco == Inventario.PRINCIPAL or hueco == Inventario.SECUNDARIA:
		sim.soltar(hueco)


func _quitar(c: Node, id: StringName) -> bool:
	if c is Jugador:
		return (c as Jugador).gestor.quitar(id)
	if c is Bot:
		var ok: bool = (c as Bot).armas.quitar(id)
		if ok:
			(c as Bot).salud.escudo = (c as Bot).armas.inventario.escudo
		return ok
	return false


func _equipar(c: Node, id: StringName) -> bool:
	var ok: bool = false
	if c is Jugador:
		ok = (c as Jugador).gestor.equipar(id)
	elif c is Bot:
		ok = (c as Bot).armas.equipar(id)
		if ok:
			(c as Bot).salud.escudo = (c as Bot).armas.inventario.escudo
	return ok


## Compra `id`: descuenta el dinero y equipa. Si ocupa el hueco de algo comprado en esta misma fase, lo devuelve antes (reembolso
## completo, sin dejarlo en el suelo); si ocupa el de algo anterior, ese cae al suelo. false si no llega, no cabe o no es la fase.
func comprar(combatiente: Node, id: StringName) -> bool:
	var ev: Dictionary = evaluar_compra(combatiente, id)
	if not bool(ev["ok"]):
		return false
	var d: DatosJugador = datos.get(combatiente)
	var precio: int = int(ev["precio"])
	var reemplazo: Dictionary = ev["reemplazo"]
	if not reemplazo.is_empty():
		_quitar(combatiente, StringName(reemplazo["id"]))
		if d != null:
			if not cfg.es_libre():
				d.dinero = mini(d.dinero + int(reemplazo["precio"]), cfg.dinero_max)
			d.compras.erase(reemplazo)
	if not _equipar(combatiente, id):
		return false
	if d != null:
		if not cfg.es_libre():
			d.dinero -= precio
		d.compras.append({"id": id, "precio": precio})
	compra_hecha.emit(combatiente, id)
	return true


## Devuelve (vende) un articulo comprado en esta fase, con reembolso completo.
func vender(combatiente: Node, id: StringName) -> bool:
	if not fase_compra():
		return false
	var d: DatosJugador = datos.get(combatiente)
	if d == null:
		return false
	for i in range(d.compras.size() - 1, -1, -1):
		var e: Dictionary = d.compras[i]
		if StringName(e["id"]) != id:
			continue
		if not _tiene(combatiente, id) or not _quitar(combatiente, id):
			return false
		if not cfg.es_libre():
			d.dinero = mini(d.dinero + int(e["precio"]), cfg.dinero_max)
		d.compras.remove_at(i)
		return true
	return false


# ------------------------------------------------------------------ Cachimba: montar y apagar

func montar_cachimba(combatiente: Node, activo: bool) -> void:
	if cachimba_nodo == null:
		return
	if not activo:
		if _montador == combatiente:
			_montador = null
		return
	_montador = combatiente
	_t_montar = _t
	if cachimba_nodo.estado == Cachimba.Estado.SIN_MONTAR and _puede_montar(combatiente):
		cachimba_nodo.global_position = (combatiente as Node3D).global_position
		cachimba_nodo.site = _site_montaje
		cachimba_nodo.empezar_montaje(combatiente)


func apagar_cachimba(combatiente: Node, activo: bool) -> void:
	if cachimba_nodo == null:
		return
	if not activo:
		if _apagador == combatiente:
			_apagador = null
		return
	_apagador = combatiente
	_t_apagar = _t
	if cachimba_nodo.estado == Cachimba.Estado.MONTADA and _puede_apagar(combatiente):
		cachimba_nodo.empezar_apagado(combatiente)


## Regla de montar: en ronda, el portador (atacante vivo) quieto dentro de un site.
func _puede_montar(c: Node) -> bool:
	if fase != Fase.RONDA or zona_activa == null or c != portador or not _vivo_de_lado(c, EQ_ATACANTES):
		return false
	_site_montaje = zona_activa.site_en((c as Node3D).global_position)
	return _site_montaje != "" and _quieto(c)


## Regla de apagar: en ronda, defensor vivo y quieto a menos de `RADIO_APAGAR` de la Cachimba montada.
func _puede_apagar(c: Node) -> bool:
	if fase != Fase.RONDA or not _vivo_de_lado(c, EQ_DEFENSORES):
		return false
	return (c as Node3D).global_position.distance_to(cachimba_nodo.global_position) <= Cachimba.RADIO_APAGAR and _quieto(c)


func _vivo_de_lado(c: Node, lado: int) -> bool:
	return c is Node3D and estaba_vivo(c) and lado_de(c) == lado


func _quieto(c: Node) -> bool:
	if c is CharacterBody3D:
		var v: Vector3 = (c as CharacterBody3D).velocity
		return Vector2(v.x, v.z).length() < 0.8
	return true


func _on_montada(site: String) -> void:
	var m: Node = cachimba_nodo.montador
	if m != null and datos.has(m):
		_dar(m, cfg.por_montar)
	portador = null
	portador_cambiado.emit(null)
	cachimba_montada.emit(site)


func _on_alarma() -> void:
	mensaje_evacuacion = "ALARMA DE INCENDIOS: se desaloja la UPO"
	if _sirena != null and _sirena.stream != null:
		_sirena.play()
	cachimba_alarma.emit()


# ------------------------------------------------------------------ flujo de la partida

## Empieza la partida: economia inicial, marcador a cero y primera ronda (competitivo) o modo libre.
func iniciar_partida() -> void:
	puntos = [0, 0]
	consecutivas = [0, 0]
	ronda = 0
	ganador_partida = -1
	lado_grupo = [EQ_ATACANTES, EQ_DEFENSORES]
	for c: Node in jugadores:
		(datos[c] as DatosJugador).dinero = cfg.dinero_inicial
	if cfg.es_libre():
		fase = Fase.LIBRE
		for c: Node in jugadores:
			_aplicar_lado(c)
		fase_cambiada.emit(fase)
		return
	_reset_total = true
	_empezar_ronda()


func _rol_para(lado: int) -> StringName:
	if cfg.submodo == ConfigPartida.SUB_ELIMINACION:
		return Bot.ROL_CAZADOR
	return Bot.ROL_ATACANTE if lado == EQ_ATACANTES else Bot.ROL_DEFENSOR


func _aplicar_lado(c: Node) -> void:
	var d: DatosJugador = datos[c]
	if cfg.es_libre():
		return
	var lado: int = lado_grupo[d.grupo]
	if c is Bot:
		(c as Bot).asignar_equipo(lado, _rol_para(lado))
	else:
		var s: Salud = Salud.de(c)
		if s != null:
			s.equipo = lado


func _empezar_ronda() -> void:
	ronda += 1
	ultimo_ganador = -1
	ultimo_motivo = ""
	mensaje_evacuacion = ""
	ArmaSuelo.limpiar_armas_suelo(get_tree())
	for g: String in GRUPOS_LIMPIEZA:
		for n: Node in get_tree().get_nodes_in_group(g):
			n.queue_free()
	_quitar_caida()
	if _sirena != null:
		_sirena.stop()
	if cachimba_nodo != null:
		cachimba_nodo.reiniciar()
	_montador = null
	_apagador = null
	if zona_activa != null:
		zona_activa.activar_barreras(true)
	fase = Fase.COMPRA
	t_fase = cfg.t_compra
	for c: Node in jugadores:
		var d: DatosJugador = datos[c]
		d.compras.clear()
		d.ingreso_ronda = 0
		_aplicar_lado(c)
		_colocar_en_spawn(c, d)
		if c is Bot:
			(c as Bot).congelado = true
	_reset_total = false
	_elegir_portador()
	if director != null:
		director.preparar()
	for c: Node in jugadores:
		if c is Bot and not (c as Bot).humano_red:      # los humanos remotos compran ellos (tienda por red)
			(c as Bot).comprar_kit()
	ronda_iniciada.emit(ronda)
	fase_cambiada.emit(fase)


## Coloca a `c` en su punto de aparicion: si murio (o el reinicio es total) vuelve con el inventario base; si sobrevivio conserva
## armas, municion, utilidades y el escudo restante (la vida se repone).
func _colocar_en_spawn(c: Node, d: DatosJugador) -> void:
	var lado: int = lado_grupo[d.grupo]
	var sp: Dictionary = zona_activa.punto_spawn("atacantes" if lado == EQ_ATACANTES else "defensores", d.indice)
	var pos: Vector3 = sp["pos"]
	var yaw: float = float(sp["yaw_deg"])
	var s: Salud = Salud.de(c)
	var revivir: bool = _reset_total or s == null or not s.vivo
	if c is Bot:
		var b: Bot = c as Bot
		if revivir or b.muerto:
			b.reaparecer(pos, yaw)
		else:
			b.teletransportar(pos, yaw)
			_curar(s)
	elif c is Jugador:
		var j: Jugador = c as Jugador
		if revivir or j.muerto:
			j.punto_reaparicion = pos
			j.yaw_reaparicion = yaw
			j.reaparecer()
		else:
			j.teletransportar(pos, yaw)
			_curar(s)
		j.activo = true


func _curar(s: Salud) -> void:
	var escudo: float = s.escudo
	s.reiniciar()
	s.escudo = escudo


func _elegir_portador() -> void:
	portador = null
	if cachimba_nodo == null:
		return
	var cand: Array[Node] = []
	for c: Node in jugadores:
		if _vivo_de_lado(c, EQ_ATACANTES):
			cand.append(c)
	if not cand.is_empty():
		portador = cand[rng.randi_range(0, cand.size() - 1)]
	portador_cambiado.emit(portador)


func _comenzar_ronda() -> void:
	fase = Fase.RONDA
	t_fase = cfg.t_ronda
	if zona_activa != null:
		zona_activa.activar_barreras(false)
	for c: Node in jugadores:
		if c is Bot:
			(c as Bot).congelado = false
	if director != null:
		director.t_ronda = 0.0
	fase_cambiada.emit(fase)


## Marca el fin de ronda con el ganador (grupo) y el motivo: "apagada", "alarma", "defensores_eliminados", "atacantes_eliminados",
## "tiempo" o "eliminacion". Reparte la economia y decide si acaba la partida.
func terminar_ronda(grupo_ganador: int, motivo: String) -> void:
	if fase != Fase.RONDA:
		return
	ultimo_ganador = grupo_ganador
	ultimo_motivo = motivo
	var perdedor: int = 1 - grupo_ganador
	puntos[grupo_ganador] += 1
	consecutivas[perdedor] += 1
	consecutivas[grupo_ganador] = 0
	for c: Node in jugadores:
		var d: DatosJugador = datos[c]
		if d.grupo == grupo_ganador:
			_dar(c, cfg.por_victoria)
			if motivo == "alarma":
				_dar(c, cfg.por_alarma)
		else:
			_dar(c, cfg.recompensa_derrota(consecutivas[perdedor]))
		if c is Bot:
			(c as Bot).congelado = true
	for c: Node in jugadores:
		montar_cachimba(c, false)
		apagar_cachimba(c, false)
	var g: int = _ganador_partida()
	if g >= 0:
		ganador_partida = g
		fase = Fase.FIN_PARTIDA
		t_fase = 0.0
	else:
		fase = Fase.FIN_RONDA
		t_fase = cfg.t_fin_ronda
	ronda_terminada.emit(grupo_ganador, motivo)
	fase_cambiada.emit(fase)
	if g >= 0:
		partida_terminada.emit(g)


## Grupo que ha ganado la partida (o -1): llega a las rondas necesarias y saca 2 al rival; sin prorroga posible, con 1 de ventaja.
func _ganador_partida() -> int:
	var rpg: int = cfg.rondas_ganar
	for g in 2:
		var o: int = 1 - g
		if puntos[g] < rpg:
			continue
		if rpg <= 1 or puntos[o] < rpg - 1 or puntos[g] - puntos[o] >= 2:
			return g
	return -1


func _siguiente_ronda() -> void:
	if ronda == cfg.ronda_cambio_lado() and cfg.rondas_ganar >= 2:
		_cambiar_lados()
	_empezar_ronda()


func _cambiar_lados() -> void:
	lado_grupo = [lado_grupo[1], lado_grupo[0]]
	if cfg.reiniciar_al_cambiar_lado:
		_reset_total = true
		consecutivas = [0, 0]
		for c: Node in jugadores:
			(datos[c] as DatosJugador).dinero = cfg.dinero_inicial
	lados_cambiados.emit()


func _quitar_caida() -> void:
	if _caida != null and is_instance_valid(_caida):
		_caida.queue_free()
	_caida = null


# ------------------------------------------------------------------ bajas

func _combatiente_de(nodo: Node) -> Node:
	var n: Node = nodo
	while n != null:
		if datos.has(n):
			return n
		n = n.get_parent()
	return null


func _on_muerto(atacante: Node, _arma: ArmaDatos, victima: Node) -> void:
	var dv: DatosJugador = datos.get(victima)
	if dv == null:
		return
	dv.muertes += 1
	var asesino: Node = _combatiente_de(atacante) if atacante != null else null
	if asesino != null and asesino != victima:
		var da: DatosJugador = datos[asesino]
		da.bajas += 1
		if cfg.es_libre() or lado_de(asesino) != lado_de(victima):
			_dar(asesino, cfg.por_baja)
	if victima == portador and cachimba_nodo != null:
		portador = null
		_soltar_cachimba(victima)
	baja_registrada.emit(asesino, victima)


func _soltar_cachimba(quien: Node) -> void:
	_quitar_caida()
	if cachimba_nodo.estado != Cachimba.Estado.SIN_MONTAR and cachimba_nodo.estado != Cachimba.Estado.MONTANDO:
		return
	_caida = CachimbaSuelo.new()
	_caida.name = "CachimbaSuelo"
	add_child(_caida)
	_caida.global_position = (quien as Node3D).global_position
	portador_cambiado.emit(null)


## Un atacante vivo que se acerca a la Cachimba caida la recoge y pasa a ser el portador.
func _recoger_caida() -> void:
	var caida: Node3D = cachimba_caida()
	if caida == null:
		return
	for c: Node in jugadores:
		if _vivo_de_lado(c, EQ_ATACANTES) and (c as Node3D).global_position.distance_to(caida.global_position) < CachimbaSuelo.RADIO_RECOGER:
			portador = c
			_quitar_caida()
			portador_cambiado.emit(c)
			return


# ------------------------------------------------------------------ simulacion

func _physics_process(delta: float) -> void:
	if not manual:
		avanzar(delta)


func avanzar(dt: float) -> void:
	_t += dt
	if cachimba_nodo != null:
		var montando: bool = false
		var apagando: bool = false
		if cachimba_nodo.estado == Cachimba.Estado.MONTANDO:
			montando = _montador != null and is_instance_valid(_montador) and _t - _t_montar < 0.2 and _puede_montar(_montador)
		if cachimba_nodo.estado == Cachimba.Estado.APAGANDO:
			apagando = _apagador != null and is_instance_valid(_apagador) and _t - _t_apagar < 0.2 and _puede_apagar(_apagador)
		cachimba_nodo.avanzar(dt, montando, apagando)
	match fase:
		Fase.COMPRA:
			t_fase -= dt
			if t_fase <= 0.0:
				_comenzar_ronda()
		Fase.RONDA:
			_avanzar_ronda(dt)
		Fase.FIN_RONDA:
			t_fase -= dt
			if t_fase <= 0.0:
				_siguiente_ronda()


func _avanzar_ronda(dt: float) -> void:
	var c: Cachimba = cachimba_nodo
	if c != null:
		_recoger_caida()
		# con la Cachimba montada o montandose el reloj de la ronda se detiene
		if c.estado == Cachimba.Estado.SIN_MONTAR:
			t_fase -= dt
	else:
		t_fase -= dt
	_comprobar_fin()


func _comprobar_fin() -> void:
	var g_atq: int = grupo_de_lado(EQ_ATACANTES)
	var g_def: int = grupo_de_lado(EQ_DEFENSORES)
	var vivos_atq: int = vivos_de_lado(EQ_ATACANTES)
	var vivos_def: int = vivos_de_lado(EQ_DEFENSORES)
	var c: Cachimba = cachimba_nodo
	if c != null:
		if c.estado == Cachimba.Estado.APAGADA:
			terminar_ronda(g_def, "apagada")
		elif c.estado == Cachimba.Estado.ALARMA:
			terminar_ronda(g_atq, "alarma")
		elif vivos_def == 0:
			terminar_ronda(g_atq, "defensores_eliminados")
		elif vivos_atq == 0 and (c.estado == Cachimba.Estado.SIN_MONTAR or c.estado == Cachimba.Estado.MONTANDO):
			terminar_ronda(g_def, "atacantes_eliminados")
		elif t_fase <= 0.0 and c.estado == Cachimba.Estado.SIN_MONTAR:
			terminar_ronda(g_def, "tiempo")
		return
	# eliminacion
	if vivos_def == 0 and vivos_atq > 0:
		terminar_ronda(g_atq, "eliminacion")
	elif vivos_atq == 0:
		terminar_ronda(g_def, "eliminacion")
	elif t_fase <= 0.0:
		if cfg.elim_gana_mas_vivos and vivos_atq > vivos_def:
			terminar_ronda(g_atq, "tiempo")
		else:
			terminar_ronda(g_def, "tiempo")
