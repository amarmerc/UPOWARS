class_name ArmasBot
extends Node
## Armas de un bot: el mismo `Inventario`, `ArmaDatos`, `Catalogo` y `Balistica` que usa el jugador, pero sin camara ni entrada
## (el `GestorArmas` esta atado a `Jugador`). Todo el dano sale de `Balistica`; aqui solo hay cadencia, cargador, recarga, cambio
## de arma y el ruido que oyen los demas bots. Hueco activo: 0 principal, 1 secundaria, 2 cuerpo a cuerpo.
## Soporta hitscan, perdigones, proyectil (arco con carga completa, tirachinas), cohete y navaja; NO sable ni Puño-Bot (los bots no
## los compran ni los recogen). Se avanza con `avanzar(dt)` (lo llama el Bot).

signal disparo_realizado(arma: ArmaDatos, res: Dictionary)
signal arma_soltada(id: StringName)
signal inventario_cambiado

const EPS: float = 0.000001
const DISTANCIA_RECOGER: float = 2.4
const NO_SOPORTADAS: Array[StringName] = [&"sable_plasma", &"puno_bot"]

var inventario := Inventario.new()
var indice: int = 1
var recargando: bool = false
var cambiando: bool = false
var disparos_totales: int = 0
var rng := RandomNumberGenerator.new()
## Dueno (CharacterBody3D): excluido de sus propios disparos y lanzador de lo que lance.
var bot: Node3D = null

var _t: float = 0.0
var _proximo: float = 0.0
var _fin_recarga: float = 0.0
var _fin_cambio: float = 0.0
var _rafaga: int = 0
var _carga_desde: float = -1.0


func _ready() -> void:
	_aplicar_arma()


# ------------------------------------------------------------------ consultas

func id_en(i: int) -> StringName:
	match i:
		0:
			return inventario.principal
		1:
			return inventario.secundaria
		2:
			return inventario.cuerpo
	return &""


func arma_en(i: int) -> ArmaDatos:
	var id: StringName = id_en(i)
	return Catalogo.arma(id) if id != &"" else null


func actual() -> ArmaDatos:
	var a: ArmaDatos = arma_en(indice)
	return a if a != null else arma_en(1)


func id_actual() -> StringName:
	return id_en(indice) if id_en(indice) != &"" else id_en(1)


func cargador_actual() -> int:
	return inventario.cargador(id_actual())


func reserva_actual() -> int:
	return inventario.reserva(id_actual())


## Municion total del hueco `i` (el cuerpo a cuerpo siempre tiene).
func municion_en(i: int) -> int:
	if i == 2:
		return 1
	var id: StringName = id_en(i)
	return 0 if id == &"" else inventario.cargador(id) + inventario.reserva(id)


func tiene_municion(i: int) -> bool:
	return id_en(i) != &"" and municion_en(i) > 0


func cargador_lleno() -> bool:
	var a: ArmaDatos = actual()
	return a.cargador <= 0 or cargador_actual() >= a.cargador


func puede_disparar() -> bool:
	var a: ArmaDatos = actual()
	if a == null or cambiando or recargando or _t + EPS < _proximo or a.es_utilidad():
		return false
	return a.cargador <= 0 or cargador_actual() > 0


## Mejor hueco para combatir: la principal con municion, si no la secundaria, si no el cuerpo a cuerpo.
func mejor_hueco() -> int:
	if tiene_municion(0):
		return 0
	if tiene_municion(1):
		return 1
	return 2


# ------------------------------------------------------------------ simulacion

func avanzar(dt: float) -> void:
	_t += dt
	if cambiando and _t >= _fin_cambio:
		cambiando = false
	if recargando and _t >= _fin_recarga:
		_terminar_recarga()


## Un disparo (o golpe) desde `origen` en `dir` con `dispersion` grados. Devuelve el resultado de `Balistica` ({} si no se pudo:
## cadencia, cargador vacio, recargando, arco sin cargar). Todo el dano lo aplica `Balistica`; aqui se emite el ruido y el efecto.
func intentar_disparo(origen: Vector3, dir: Vector3, dispersion: float) -> Dictionary:
	if not puede_disparar():
		return {}
	var a: ArmaDatos = actual()
	var id: StringName = id_actual()
	if a.tipo == ArmaDatos.T_SABLE or a.tipo == ArmaDatos.T_PUNO:
		return {}
	if a.carga_tiempo > 0.0 and a.tipo == ArmaDatos.T_PROYECTIL:  # arco: se mantiene la carga completa
		if _carga_desde < 0.0:
			_carga_desde = _t
		if _t - _carga_desde < a.carga_tiempo:
			return {}
		_carga_desde = -1.0
	var res: Dictionary
	match a.tipo:
		ArmaDatos.T_PERDIGONES:
			res = Balistica.resolver_perdigones(origen, dir, a, bot, rng, dispersion)
			Balistica.aplicar_multiple(res, a, bot)
		ArmaDatos.T_PROYECTIL, ArmaDatos.T_COHETE:
			var d: Vector3 = Balistica.aplicar_dispersion(dir, dispersion, rng)
			Proyectil.lanzar(self, a, origen + d * 0.5, d * a.velocidad_proyectil, bot)
			res = {"impacto": false, "punto": origen + d * 10.0, "normal": -d, "collider": null, "zona": "", "daño": 0.0,
					"distancia": 10.0, "direccion": d, "salud": null, "fuerte": false}
		ArmaDatos.T_CUERPO:
			res = Balistica.resolver_disparo(origen, dir, a, bot, rng, 0.0, false)
			Balistica.aplicar(res, a, bot)
		_:
			res = Balistica.resolver_disparo(origen, dir, a, bot, rng, dispersion)
			Balistica.aplicar(res, a, bot)
	if a.cargador > 0:
		inventario.fijar_municion(id, inventario.cargador(id) - 1, inventario.reserva(id))
	disparos_totales += 1
	_rafaga += 1
	if a.rafaga > 1 and _rafaga >= a.rafaga:
		_rafaga = 0
		_proximo = _t + a.pausa_rafaga
	else:
		_proximo = _t + a.intervalo()
	if a.ruido > 0.0 and is_inside_tree():
		SenalesCombate.obtener(get_tree()).ruido.emit(origen, a.ruido, bot)
	var boca: Vector3 = origen + dir * 0.6 + Vector3(0.0, -0.15, 0.0)
	if is_inside_tree():
		var ef: EfectosCombate = Utilidades.efectos(self)
		if ef != null:
			ef.mostrar_disparo(a, res, boca)
			ef.sonido_en(boca, a.sonido)
	disparo_realizado.emit(a, res)
	return res


func cancelar_carga() -> void:
	_carga_desde = -1.0


func recargar() -> bool:
	var a: ArmaDatos = actual()
	if a.cargador <= 0 or a.es_utilidad() or recargando or cambiando:
		return false
	var id: StringName = id_actual()
	if inventario.cargador(id) >= a.cargador or inventario.reserva(id) <= 0:
		return false
	cancelar_carga()
	recargando = true
	_fin_recarga = _t + a.tiempo_recarga
	return true


func _terminar_recarga() -> void:
	recargando = false
	var a: ArmaDatos = actual()
	var id: StringName = id_actual()
	var n: int = mini(a.cargador - inventario.cargador(id), inventario.reserva(id))
	inventario.fijar_municion(id, inventario.cargador(id) + n, inventario.reserva(id) - n)


## Cambia al hueco `i` (0 principal, 1 secundaria, 2 cuerpo). No se puede disparar hasta acabar el cambio.
func cambiar_arma(i: int) -> void:
	if i < 0 or i > 2 or id_en(i) == &"" or i == indice:
		return
	recargando = false
	cancelar_carga()
	_rafaga = 0
	indice = i
	_aplicar_arma()


func _aplicar_arma() -> void:
	var a: ArmaDatos = actual()
	if a == null:
		return
	cambiando = true
	_fin_cambio = _t + a.tiempo_cambio
	_proximo = maxf(_proximo, _fin_cambio)


# ------------------------------------------------------------------ inventario

## Equipa un articulo del catalogo (compra o recogida). Si sustituye a un arma soltable, esta cae al suelo.
func equipar(id: StringName, carg: int = -1, res: int = -1) -> bool:
	if NO_SOPORTADAS.has(id):
		return false
	var r: Dictionary = inventario.equipar(id, carg, res)
	if not bool(r["ok"]):
		return false
	var soltada: Dictionary = r["soltada"]
	if not soltada.is_empty():
		_soltar_al_suelo(soltada, Vector3.UP * 1.5, 0.9)
	match Catalogo.hueco(id):
		Inventario.PRINCIPAL:
			_forzar(0)
		Inventario.SECUNDARIA:
			if inventario.principal == &"":
				_forzar(1)
	inventario_cambiado.emit()
	return true


## Quita `id` del inventario SIN soltarlo al suelo (la tienda lo usa al vender o devolver). false si no lo tiene.
func quitar(id: StringName) -> bool:
	var hueco: StringName = Catalogo.hueco(id)
	match hueco:
		Inventario.ESCUDO:
			if inventario.escudo <= 0.0:
				return false
			inventario.escudo = 0.0
		Inventario.UTILIDADES:
			if not inventario.consumir_utilidad(id):
				return false
		Inventario.PRINCIPAL, Inventario.SECUNDARIA:
			if inventario.en_hueco(hueco) != id or inventario.soltar(hueco).is_empty():
				return false
			recargando = false
			cancelar_carga()
		_:
			return false
	if actual() == null or id_en(indice) == &"":
		_forzar(1 if id_en(1) != &"" else 2)
	inventario_cambiado.emit()
	return true


func _forzar(i: int) -> void:
	recargando = false
	cancelar_carga()
	_rafaga = 0
	indice = i
	_aplicar_arma()


func _soltar_al_suelo(d: Dictionary, vel: Vector3, alto: float) -> ArmaSuelo:
	var ang: float = rng.randf() * TAU
	var dir := Vector3(cos(ang), 0.0, sin(ang))
	var a: ArmaSuelo = ArmaSuelo.crear(self, StringName(d["id"]), int(d["cargador"]), int(d["reserva"]),
			bot.global_position + dir * 0.4 + Vector3(0.0, alto, 0.0), vel + dir * 1.3)
	arma_soltada.emit(StringName(d["id"]))
	return a


## Recoge un arma del suelo (si esta a menos de DISTANCIA_RECOGER): cambia por la del mismo hueco (que cae) y conserva su municion.
func recoger(a: ArmaSuelo) -> bool:
	if a == null or not is_instance_valid(a) or NO_SOPORTADAS.has(a.arma_id):
		return false
	if a.global_position.distance_to(bot.global_position) > DISTANCIA_RECOGER:
		return false
	var hueco: StringName = Catalogo.hueco(a.arma_id)
	if hueco != Inventario.PRINCIPAL and hueco != Inventario.SECUNDARIA:
		return false
	var id: StringName = a.arma_id
	var carg: int = a.cargador
	var res: int = a.reserva
	a.remove_from_group("armas_suelo")
	a.queue_free()
	return equipar(id, carg, res)


## Tira al suelo el arma activa (principal o secundaria comprada).
func tirar_arma() -> bool:
	var hueco: StringName = Inventario.PRINCIPAL if indice == 0 else (Inventario.SECUNDARIA if indice == 1 else &"")
	if hueco == &"":
		return false
	var d: Dictionary = inventario.soltar(hueco)
	if d.is_empty():
		return false
	_soltar_al_suelo(d, Vector3.UP * 1.2, 1.0)
	if id_en(indice) == &"":
		_forzar(1 if indice == 0 else indice)
	inventario_cambiado.emit()
	return true


## Al morir se sueltan la principal y la secundaria compradas (la Pistola 9 mm gratuita no).
func soltar_al_morir() -> void:
	recargando = false
	cancelar_carga()
	for hueco: StringName in [Inventario.PRINCIPAL, Inventario.SECUNDARIA]:
		if not inventario.es_soltable(inventario.en_hueco(hueco)):
			continue
		var d: Dictionary = inventario.soltar(hueco)
		_soltar_al_suelo(d, Vector3.UP * 2.0, 1.0)
	inventario_cambiado.emit()


## Vuelve al inventario base (Pistola 9 mm y navaja, sin utilidades ni escudo).
func reiniciar() -> void:
	recargando = false
	cancelar_carga()
	inventario.reiniciar_a_base()
	indice = 1
	_rafaga = 0
	_proximo = _t
	_aplicar_arma()
	inventario_cambiado.emit()


## Lanza una utilidad del inventario desde `pos` con la velocidad `vel` (el lanzador es el dueno). null si no la tiene.
func lanzar_utilidad(id: StringName, pos: Vector3, vel: Vector3) -> Lanzable:
	var a: ArmaDatos = Catalogo.arma(id)
	if a == null or not a.es_utilidad() or inventario.cantidad_utilidad(id) <= 0:
		return null
	inventario.consumir_utilidad(id)
	_proximo = maxf(_proximo, _t + 0.9)
	inventario_cambiado.emit()
	return Utilidades.lanzar(self, a, pos, vel, bot)
