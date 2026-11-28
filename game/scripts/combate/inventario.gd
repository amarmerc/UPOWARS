class_name Inventario
extends RefCounted
## Inventario de un combatiente: 1 arma principal, 1 secundaria, cuerpo a cuerpo, utilidades (max. 2 de cada tipo y 4 en
## total) y escudo, con la municion de cada arma. API pura: sin dinero, sin entrada y sin nodos (la usan igual el jugador,
## los bots y la futura Partida/servidor). Los precios y los huecos de cada articulo salen de `Catalogo`.
## Equipar un arma en un hueco ocupado sustituye a la anterior, que se devuelve para soltarla al suelo.

const PRINCIPAL: StringName = &"principal"
const SECUNDARIA: StringName = &"secundaria"
const CUERPO: StringName = &"cuerpo"
const UTILIDADES: StringName = &"utilidades"
const ESCUDO: StringName = &"escudo"
const PISTOLA_BASE: StringName = &"pistola_9mm"
const NAVAJA: StringName = &"navaja"
const MAX_POR_TIPO: int = 2
const MAX_TOTAL: int = 4

var principal: StringName = &""
var secundaria: StringName = PISTOLA_BASE
var cuerpo: StringName = NAVAJA
## Con repeticiones: dos granadas de humo = [&"granada_humo", &"granada_humo"].
var utilidades: Array[StringName] = []
## Puntos de escudo comprados (0, 25 o 50).
var escudo: float = 0.0
## id -> {"cargador": int, "reserva": int}
var municion: Dictionary = {}


func _init() -> void:
	reiniciar_a_base()


## Vuelve a lo gratuito: Pistola 9 mm con la municion llena, navaja, sin principal, sin utilidades y sin escudo.
func reiniciar_a_base() -> void:
	principal = &""
	secundaria = PISTOLA_BASE
	cuerpo = NAVAJA
	utilidades.clear()
	escudo = 0.0
	municion.clear()
	_llenar(PISTOLA_BASE)


func _llenar(id: StringName) -> void:
	var a: ArmaDatos = Catalogo.arma(id)
	if a != null:
		municion[id] = {"cargador": a.cargador, "reserva": a.reserva}


func en_hueco(hueco: StringName) -> StringName:
	match hueco:
		PRINCIPAL:
			return principal
		SECUNDARIA:
			return secundaria
		CUERPO:
			return cuerpo
	return &""


func tiene(id: StringName) -> bool:
	return id == principal or id == secundaria or id == cuerpo or utilidades.has(id)


## Soltable: lo comprado. La Pistola 9 mm gratuita y la navaja no se sueltan nunca.
func es_soltable(id: StringName) -> bool:
	return id != &"" and id != PISTOLA_BASE and id != NAVAJA


func cantidad_utilidad(id: StringName) -> int:
	return utilidades.count(id)


## Utilidades distintas, en el orden en que se compraron.
func tipos_utilidad() -> Array[StringName]:
	var out: Array[StringName] = []
	for u: StringName in utilidades:
		if not out.has(u):
			out.append(u)
	return out


func consumir_utilidad(id: StringName) -> bool:
	var i: int = utilidades.find(id)
	if i < 0:
		return false
	utilidades.remove_at(i)
	return true


func cargador(id: StringName) -> int:
	return int((municion.get(id, {}) as Dictionary).get("cargador", 0))


func reserva(id: StringName) -> int:
	return int((municion.get(id, {}) as Dictionary).get("reserva", 0))


func fijar_municion(id: StringName, carg: int, res: int) -> void:
	municion[id] = {"cargador": carg, "reserva": res}


## Rellena la municion de todas las armas equipadas.
func rellenar_municion() -> void:
	for id: StringName in [principal, secundaria, cuerpo]:
		if id != &"":
			_llenar(id)


## Equipa `id` en su hueco. `carg`/`res` < 0 = municion llena (un arma recogida del suelo conserva la suya).
## Devuelve {"ok": bool, "motivo": String, "soltada": Dictionary}; `soltada` = {id, cargador, reserva} del arma sustituida
## (vacio si no habia ninguna o no es soltable), para que quien llama la deje en el suelo.
func equipar(id: StringName, carg: int = -1, res: int = -1) -> Dictionary:
	var info: Dictionary = Catalogo.info(id)
	if info.is_empty():
		return {"ok": false, "motivo": "articulo desconocido", "soltada": {}}
	var hueco: StringName = StringName(info["hueco"])
	match hueco:
		ESCUDO:
			escudo = float(Catalogo.PUNTOS_ESCUDO.get(id, 0.0))
			return {"ok": true, "motivo": "", "soltada": {}}
		UTILIDADES:
			if utilidades.count(id) >= MAX_POR_TIPO:
				return {"ok": false, "motivo": "maximo %d de cada tipo" % MAX_POR_TIPO, "soltada": {}}
			if utilidades.size() >= MAX_TOTAL:
				return {"ok": false, "motivo": "maximo %d utilidades" % MAX_TOTAL, "soltada": {}}
			utilidades.append(id)
			return {"ok": true, "motivo": "", "soltada": {}}
		CUERPO:
			if id != NAVAJA:
				return {"ok": false, "motivo": "solo hay una arma cuerpo a cuerpo", "soltada": {}}
			return {"ok": true, "motivo": "", "soltada": {}}
	var anterior: StringName = en_hueco(hueco)
	var soltada: Dictionary = {}
	if anterior != &"" and anterior != id and es_soltable(anterior):
		soltada = {"id": anterior, "cargador": cargador(anterior), "reserva": reserva(anterior)}
	if anterior != &"" and anterior != id and anterior != PISTOLA_BASE:
		municion.erase(anterior)
	if hueco == PRINCIPAL:
		principal = id
	else:
		secundaria = id
	if carg >= 0:
		fijar_municion(id, carg, maxi(res, 0))
	else:
		_llenar(id)
	return {"ok": true, "motivo": "", "soltada": soltada}


## Suelta el arma del hueco ("principal" o "secundaria"). Devuelve {id, cargador, reserva} o {} si no hay nada soltable.
## La secundaria vuelve a la Pistola 9 mm gratuita; la principal queda vacia.
func soltar(hueco: StringName) -> Dictionary:
	var id: StringName = en_hueco(hueco)
	if hueco == CUERPO or not es_soltable(id):
		return {}
	var d: Dictionary = {"id": id, "cargador": cargador(id), "reserva": reserva(id)}
	municion.erase(id)
	if hueco == PRINCIPAL:
		principal = &""
	else:
		secundaria = PISTOLA_BASE
		if not municion.has(PISTOLA_BASE):
			_llenar(PISTOLA_BASE)
	return d


func serializar() -> Dictionary:
	var m: Dictionary = {}
	for id: StringName in municion:
		m[String(id)] = [cargador(id), reserva(id)]
	var u: Array = []
	for x: StringName in utilidades:
		u.append(String(x))
	return {"principal": String(principal), "secundaria": String(secundaria), "cuerpo": String(cuerpo),
			"utilidades": u, "escudo": escudo, "municion": m}


func deserializar(d: Dictionary) -> void:
	principal = StringName(str(d.get("principal", "")))
	secundaria = StringName(str(d.get("secundaria", PISTOLA_BASE)))
	cuerpo = StringName(str(d.get("cuerpo", NAVAJA)))
	utilidades.clear()
	for x: Variant in d.get("utilidades", []):
		utilidades.append(StringName(str(x)))
	escudo = float(d.get("escudo", 0.0))
	municion.clear()
	var m: Dictionary = d.get("municion", {})
	for k: Variant in m:
		var par: Array = m[k]
		municion[StringName(str(k))] = {"cargador": int(par[0]), "reserva": int(par[1])}
