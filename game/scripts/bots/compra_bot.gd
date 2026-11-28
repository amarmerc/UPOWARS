class_name CompraBot
extends RefCounted
## Compra de los bots: funcion PURA (sin escena, sin Partida). Dado el dinero, el inventario actual, el rol y el catalogo devuelve la
## lista ordenada de articulos a comprar; quien la aplica (la Partida, o `Bot.comprar_kit`) compra uno a uno con `Comandos.comprar`.
## No modifica el inventario recibido (simula sobre una copia) y la suma de precios nunca supera el dinero.
##
## Prioridades: 1) escudo (pesado si sobra mucho, ligero si no; solo si despues aun llega a un arma principal), 2) arma principal
## segun el dinero (elegida con pesos por rol entre las que llegan), 3) utilidades (hasta 3: atacantes cegadora > humo > explosiva,
## defensores humo > explosiva > cegadora), 4) mejora de la secundaria con lo que sobre.
## Ahorro: sin principal y sin llegar a la mas barata (1500) no se gasta, salvo la "ronda de pistolas" (>= 800) en la que, la mitad
## de las veces, se compra escudo ligero y una utilidad. Las armas especiales (tirachinas, arco, lanzacohetes) salen raramente
## (`P_ESPECIAL`); el Sable de Plasma y el Puño-Bot no los compran los bots.

const ROL_ATACANTE: StringName = &"atacante"
const ROL_DEFENSOR: StringName = &"defensor"
const P_ESPECIAL: float = 0.07
const RONDA_PISTOLAS: int = 800
## Pesos de eleccion de la principal por rol (id -> peso); entre las que llegan se elige al azar ponderado.
const PESOS_ATACANTE: Dictionary = {
	&"fusil_asalto": 5.0, &"carabina_556": 3.0, &"subfusil_45": 2.0, &"subfusil_9mm": 2.0, &"fusil_combate": 2.0,
	&"escopeta_auto": 0.5, &"escopeta_corredera": 0.4,
}
const PESOS_DEFENSOR: Dictionary = {
	&"fusil_asalto": 4.0, &"carabina_556": 3.0, &"fusil_combate": 2.0, &"fusil_tirador": 1.5, &"subfusil_45": 1.5,
	&"subfusil_9mm": 1.0, &"fusil_precision": 1.0, &"ametralladora": 0.5, &"escopeta_corredera": 0.5,
}
const ESPECIALES: Array[StringName] = [&"tirachinas", &"arco_olivo", &"lanzacohetes"]
const UTIL_ATACANTE: Array[StringName] = [&"granada_cegadora", &"granada_humo", &"granada_explosiva"]
const UTIL_DEFENSOR: Array[StringName] = [&"granada_humo", &"granada_explosiva", &"granada_cegadora"]
const SECUNDARIAS: Array[StringName] = [&"pistola_auto", &"revolver_357", &"pistola_pesada", &"subfusil_compacto"]
const MAX_UTILIDADES_BOT: int = 3


## Compras en orden. `catalogo` ofrece precio(id), existe(id) (por defecto `Catalogo`); `rng` = azar inyectable (null = el
## resultado es determinista: siempre la principal de mayor peso que llega y nunca armas especiales).
static func comprar(dinero: int, inventario: Inventario, rol: StringName, catalogo: Variant = null,
		rng: RandomNumberGenerator = null) -> Array[StringName]:
	var cat: Variant = catalogo if catalogo != null else Catalogo
	var compras: Array[StringName] = []
	var sim := Inventario.new()
	sim.deserializar(inventario.serializar())
	var presupuesto: int = maxi(dinero, 0)
	var pesos: Dictionary = PESOS_DEFENSOR if rol == ROL_DEFENSOR else PESOS_ATACANTE
	var utils: Array[StringName] = UTIL_DEFENSOR if rol == ROL_DEFENSOR else UTIL_ATACANTE
	var precio_min: int = _precio_minimo_principal(cat, pesos)
	var tiene_principal: bool = sim.principal != &""

	if not tiene_principal and presupuesto < precio_min:
		# No llega a una principal: ahorro (salvo ronda de pistolas)
		if presupuesto >= RONDA_PISTOLAS and rng != null and rng.randf() < 0.5:
			presupuesto = _intentar(cat, sim, compras, &"escudo_ligero", presupuesto)
			presupuesto = _intentar(cat, sim, compras, utils[0], presupuesto)
		return compras

	# 1) escudo, solo si despues aun llega a una principal
	var reserva: int = 0 if tiene_principal else precio_min
	var objetivo_principal: StringName = &""
	if not tiene_principal:
		objetivo_principal = _elegir_principal(cat, pesos, presupuesto - 400, rng)
		if objetivo_principal == &"":
			objetivo_principal = _elegir_principal(cat, pesos, presupuesto, rng)  # no llega al escudo: arma sin escudo
		elif rng != null and rng.randf() < P_ESPECIAL:
			var esp: StringName = _elegir_especial(cat, presupuesto - 400, rng)
			if esp != &"":
				objetivo_principal = esp
	var precio_obj: int = int(cat.precio(objetivo_principal)) if objetivo_principal != &"" else reserva
	if sim.escudo < 25.0:
		var tras: int = presupuesto - precio_obj
		if tras >= 1000 and presupuesto >= 1000 + precio_obj:
			presupuesto = _intentar(cat, sim, compras, &"escudo_pesado", presupuesto)
		elif tras >= 400:
			presupuesto = _intentar(cat, sim, compras, &"escudo_ligero", presupuesto)
	# 2) principal
	if objetivo_principal != &"":
		presupuesto = _intentar(cat, sim, compras, objetivo_principal, presupuesto)
	# 3) utilidades
	for u: StringName in utils:
		if sim.utilidades.size() >= MAX_UTILIDADES_BOT:
			break
		presupuesto = _intentar(cat, sim, compras, u, presupuesto)
	# 4) secundaria
	if sim.secundaria == Inventario.PISTOLA_BASE and presupuesto >= 500:
		var orden: Array[StringName] = SECUNDARIAS.duplicate()
		if rng != null:
			var k: int = rng.randi_range(0, orden.size() - 1)
			orden = orden.slice(k) + orden.slice(0, k)
		for s: StringName in orden:
			var antes: int = presupuesto
			presupuesto = _intentar(cat, sim, compras, s, presupuesto)
			if presupuesto != antes:
				break
	return compras


## Intenta comprar `id` sobre la simulacion: si llega y cabe lo anota y devuelve el presupuesto restante.
static func _intentar(cat: Variant, sim: Inventario, compras: Array[StringName], id: StringName, presupuesto: int) -> int:
	if not bool(cat.existe(id)):
		return presupuesto
	var precio: int = int(cat.precio(id))
	if precio > presupuesto:
		return presupuesto
	var r: Dictionary = sim.equipar(id)
	if not bool(r["ok"]):
		return presupuesto
	compras.append(id)
	return presupuesto - precio


static func _precio_minimo_principal(cat: Variant, pesos: Dictionary) -> int:
	var m: int = 1 << 30
	for id: StringName in pesos:
		if bool(cat.existe(id)):
			m = mini(m, int(cat.precio(id)))
	return m


## Principal que llega con `tope` de dinero: ponderada por rol con rng; sin rng, la de mayor peso (y, a igual peso, mas cara).
static func _elegir_principal(cat: Variant, pesos: Dictionary, tope: int, rng: RandomNumberGenerator) -> StringName:
	var candidatas: Array[StringName] = []
	for id: StringName in pesos:
		if bool(cat.existe(id)) and int(cat.precio(id)) <= tope:
			candidatas.append(id)
	if candidatas.is_empty():
		return &""
	if rng == null:
		var mejor: StringName = candidatas[0]
		for id: StringName in candidatas:
			var p: float = float(pesos[id])
			var pm: float = float(pesos[mejor])
			if p > pm or (is_equal_approx(p, pm) and int(cat.precio(id)) > int(cat.precio(mejor))):
				mejor = id
		return mejor
	var total: float = 0.0
	for id: StringName in candidatas:
		total += float(pesos[id])
	var x: float = rng.randf() * total
	for id: StringName in candidatas:
		x -= float(pesos[id])
		if x <= 0.0:
			return id
	return candidatas[candidatas.size() - 1]


static func _elegir_especial(cat: Variant, tope: int, rng: RandomNumberGenerator) -> StringName:
	var ok: Array[StringName] = []
	for id: StringName in ESPECIALES:
		if bool(cat.existe(id)) and int(cat.precio(id)) <= tope:
			ok.append(id)
	if ok.is_empty():
		return &""
	return ok[rng.randi_range(0, ok.size() - 1)]
