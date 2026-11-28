class_name PartidaPrueba
extends ApiPartida
## Partida minima de pruebas (NO es la Partida de P4: no hay rondas, economia ni victoria). Da a los bots lo que necesitan: modo,
## zona, Cachimba con sus reglas de montar / apagar y una compra con dinero por combatiente (por defecto infinito, como el modo
## libre). Avanza con `avanzar(dt)` desde `_physics_process`.

signal cachimba_montada(site: String)
signal cachimba_apagada
signal cachimba_alarma

## Equipos: atacantes = 1, defensores = 2.
const EQ_ATACANTES: int = 1
const EQ_DEFENSORES: int = 2

var modo_juego: StringName = &"cachimba"
var zona_activa: ZonaActiva = null
var cachimba_nodo: Cachimba = null
## Dinero por combatiente (Node -> int). Si no esta, `dinero_por_defecto`.
var dinero: Dictionary = {}
var dinero_por_defecto: int = 1 << 30

var _t: float = 0.0
var _montador: Node = null
var _t_montar: float = -10.0
var _apagador: Node = null
var _t_apagar: float = -10.0
var _site_montaje: String = ""


func configurar(modo_nuevo: StringName, zona_nueva: ZonaActiva) -> void:
	modo_juego = modo_nuevo
	zona_activa = zona_nueva
	if modo_juego == &"cachimba":
		_crear_cachimba()
	elif cachimba_nodo != null:
		cachimba_nodo.queue_free()
		cachimba_nodo = null


func _crear_cachimba() -> void:
	if cachimba_nodo != null and is_instance_valid(cachimba_nodo):
		cachimba_nodo.reiniciar()
		return
	cachimba_nodo = Cachimba.new()
	cachimba_nodo.name = "Cachimba"
	add_child(cachimba_nodo)
	cachimba_nodo.montada.connect(func(s: String) -> void: cachimba_montada.emit(s))
	cachimba_nodo.apagada.connect(func() -> void: cachimba_apagada.emit())
	cachimba_nodo.alarma.connect(func() -> void: cachimba_alarma.emit())


func modo() -> StringName:
	return modo_juego


func zona() -> ZonaActiva:
	return zona_activa


func cachimba() -> Cachimba:
	return cachimba_nodo


func dinero_de(combatiente: Node) -> int:
	return int(dinero.get(combatiente, dinero_por_defecto))


func comprar(combatiente: Node, id: StringName) -> bool:
	var precio: int = Catalogo.precio(id)
	if not Catalogo.existe(id) or precio > dinero_de(combatiente):
		return false
	var ok: bool = false
	if combatiente is Bot:
		ok = (combatiente as Bot).armas.equipar(id)
	elif combatiente is Jugador:
		ok = (combatiente as Jugador).gestor.equipar(id)
	if ok and dinero.has(combatiente):
		dinero[combatiente] = int(dinero[combatiente]) - precio
	return ok


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


## Regla de montar: atacante vivo y quieto dentro de un site.
func _puede_montar(c: Node) -> bool:
	if not _vivo_de_equipo(c, EQ_ATACANTES) or zona_activa == null:
		return false
	_site_montaje = zona_activa.site_en((c as Node3D).global_position)
	return _site_montaje != "" and _quieto(c)


## Regla de apagar: defensor vivo y quieto a menos de `RADIO_APAGAR` de la Cachimba montada.
func _puede_apagar(c: Node) -> bool:
	if not _vivo_de_equipo(c, EQ_DEFENSORES):
		return false
	return (c as Node3D).global_position.distance_to(cachimba_nodo.global_position) <= Cachimba.RADIO_APAGAR and _quieto(c)


func _vivo_de_equipo(c: Node, equipo: int) -> bool:
	var s: Salud = Salud.de(c)
	return s != null and s.vivo and s.equipo == equipo and c is Node3D


func _quieto(c: Node) -> bool:
	if c is CharacterBody3D:
		var v: Vector3 = (c as CharacterBody3D).velocity
		return Vector2(v.x, v.z).length() < 0.8
	return true


func _physics_process(delta: float) -> void:
	avanzar(delta)


func avanzar(dt: float) -> void:
	_t += dt
	if cachimba_nodo == null:
		return
	var montando: bool = false
	var apagando: bool = false
	if cachimba_nodo.estado == Cachimba.Estado.MONTANDO:
		montando = _montador != null and is_instance_valid(_montador) and _t - _t_montar < 0.2 and _puede_montar(_montador)
	if cachimba_nodo.estado == Cachimba.Estado.APAGANDO:
		apagando = _apagador != null and is_instance_valid(_apagador) and _t - _t_apagar < 0.2 and _puede_apagar(_apagador)
	cachimba_nodo.avanzar(dt, montando, apagando)


## Prueba: deja la Cachimba montada en `pos` (sin pasar por los 4 s).
func forzar_montada(pos: Vector3, site: String) -> void:
	_crear_cachimba()
	cachimba_nodo.montar_en(pos, site)
