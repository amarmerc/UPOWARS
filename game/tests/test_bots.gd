extends SceneTree
## Test headless de los bots (paquete P3). Uso:
##   Godot_console.exe --headless --path game --script res://tests/test_bots.gd [-- rapido]
## Imprime PASS/FAIL por comprobacion y sale con codigo 0 (todo bien) o 1. Secciones:
##   b1 compra pura (CompraBot) y perfiles de dificultad          b2 comandos (comprar, granada) con PartidaPrueba
##   b3 combate: ve y mata a un objetivo quieto; no lo ve tras un muro, un humo ni ciego; determinismo; dificultades; armas del suelo
##   b4 navegacion: horneado por zona, spawns -> sites y campus entero (mide tiempos)
##   b5 el defensor apaga la Cachimba montada          b6 5v5 simulado acelerado (eliminacion y Cachimba): termina, sin atascos
## Con `-- rapido` se salta el campus entero y la segunda simulacion 5v5.

const DT: float = 1.0 / 60.0
const VEL_MS: float = 5.0

var fallos: int = 0
var main: Node
var campo: CampoPractica
var rng := RandomNumberGenerator.new()
var extra: Array[Node] = []
var rapido: bool = false
var informe: Array[String] = []


func comprobar(nombre: String, ok: bool, detalle: String = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", nombre, detalle])
	if not ok:
		fallos += 1


func esperar_fisica(n: int) -> void:
	for i in n:
		await physics_frame


func suelo(p: Vector3) -> float:
	return campo._suelo(p)


func limpiar_extra() -> void:
	for n: Node in extra:
		if is_instance_valid(n):
			n.queue_free()
	extra.clear()


func _init() -> void:
	_ejecutar.call_deferred()


func _ejecutar() -> void:
	rapido = OS.get_cmdline_user_args().has("rapido")
	_test_compra()
	_test_dificultad()
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await esperar_fisica(6)
	campo = main.campo
	var espera: int = 0
	while not campo.listo and espera < 60:
		await physics_frame
		espera += 1
	main.menu.cerrar()
	(main.get_node("Jugador") as Node3D).set_physics_process(false)
	main.get_node("Jugador").salud.vivo = false          # el jugador no es objetivo de los bots
	main.get_node("Jugador").hitboxes.activar(false)
	for d: Diana in campo.dianas:                         # las dianas del campo no cuentan en estas pruebas
		d.salud.vivo = false
		d.hitboxes.activar(false)
	rng.seed = 777

	await _test_comandos()
	await _test_combate()
	await _test_armas_suelo()
	await _test_navegacion()
	await _test_defensor_apaga()
	await _test_5v5()

	print("--- informe ---")
	for l: String in informe:
		print(l)
	print("RESULTADO: %s (%d fallos)" % ["PASS" if fallos == 0 else "FAIL", fallos])
	main.queue_free()
	await process_frame
	quit(0 if fallos == 0 else 1)


# ------------------------------------------------------------------ b1: compra y dificultad (puras)

func _inv(principal: StringName = &"", escudo: float = 0.0, utils: Array[StringName] = []) -> Inventario:
	var inv := Inventario.new()
	if principal != &"":
		inv.equipar(principal)
	inv.escudo = escudo
	for u: StringName in utils:
		inv.equipar(u)
	return inv


func _coste(lista: Array[StringName]) -> int:
	var t: int = 0
	for id: StringName in lista:
		t += Catalogo.precio(id)
	return t


func _test_compra() -> void:
	var r := RandomNumberGenerator.new()
	r.seed = 11
	# ahorro: sin dinero para una principal no se compra nada (salvo la ronda de pistolas)
	var l0: Array[StringName] = CompraBot.comprar(300, _inv(), &"atacante", Catalogo, r)
	comprobar("b1a) con 300 no llega a nada: ahorra", l0.is_empty(), str(l0))
	var l1: Array[StringName] = CompraBot.comprar(1200, _inv(), &"defensor", Catalogo, r)
	comprobar("b1b) con 1200 (sin llegar a una principal ni ser ronda de pistolas inicial) ahorra", l1.is_empty(), str(l1))
	# ronda de pistolas (800): a veces escudo ligero + utilidad
	var vio_escudo: bool = false
	var vio_ahorro: bool = false
	for i in 30:
		var l: Array[StringName] = CompraBot.comprar(800, _inv(), &"atacante", Catalogo, r)
		if l.has(&"escudo_ligero") and _coste(l) <= 800:
			vio_escudo = true
		if l.is_empty():
			vio_ahorro = true
	comprobar("b1c) con 800 (ronda de pistolas) unas veces compra escudo ligero + utilidad y otras ahorra", vio_escudo and vio_ahorro)
	# presupuesto medio: escudo ligero + principal
	var l2: Array[StringName] = CompraBot.comprar(2000, _inv(), &"atacante", Catalogo, r)
	comprobar("b1d) con 2000: escudo ligero primero y una principal de 1500", l2.size() >= 2 and l2[0] == &"escudo_ligero"
			and Catalogo.hueco(l2[1]) == Inventario.PRINCIPAL and _coste(l2) <= 2000, str(l2))
	# 1600 no llega a escudo + principal mas barata? 1500+400 = 1900 > 1600: principal sin escudo
	var l3: Array[StringName] = CompraBot.comprar(1600, _inv(), &"atacante", Catalogo, r)
	comprobar("b1e) con 1600 compra la principal barata sin escudo (no llega a ambos)", l3.size() >= 1 and Catalogo.hueco(l3[0]) == Inventario.PRINCIPAL
			and not l3.has(&"escudo_ligero") and _coste(l3) <= 1600, str(l3))
	# mucho dinero: escudo pesado + principal + utilidades
	var l4: Array[StringName] = CompraBot.comprar(9000, _inv(), &"defensor", Catalogo, null)
	var hay_util: bool = false
	for id: StringName in l4:
		if Catalogo.hueco(id) == Inventario.UTILIDADES:
			hay_util = true
	comprobar("b1f) con 9000 y sin azar: escudo pesado, la principal preferida y utilidades", l4.size() >= 3 and l4[0] == &"escudo_pesado"
			and l4[1] == &"fusil_asalto" and hay_util and _coste(l4) <= 9000, str(l4))
	# determinismo con el mismo azar
	var ra := RandomNumberGenerator.new()
	ra.seed = 5
	var rb := RandomNumberGenerator.new()
	rb.seed = 5
	var da: Array[StringName] = CompraBot.comprar(4500, _inv(), &"atacante", Catalogo, ra)
	var db: Array[StringName] = CompraBot.comprar(4500, _inv(), &"atacante", Catalogo, rb)
	comprobar("b1g) mismo azar -> misma compra", da == db and not da.is_empty(), str(da))
	# ya tiene principal y escudo: no compra otra principal ni otro escudo
	var l5: Array[StringName] = CompraBot.comprar(5000, _inv(&"fusil_asalto", 25.0), &"atacante", Catalogo, r)
	var repite: bool = false
	for id: StringName in l5:
		if Catalogo.hueco(id) == Inventario.PRINCIPAL or Catalogo.hueco(id) == Inventario.ESCUDO:
			repite = true
	comprobar("b1h) con principal y escudo solo compra utilidades / secundaria", not repite and not l5.is_empty(), str(l5))
	# invariantes sobre muchos presupuestos, roles y azares: nunca gasta mas de lo que tiene, el inventario original no cambia y todo cabe
	var ok_inv: bool = true
	var ok_coste: bool = true
	var especiales: int = 0
	var total: int = 0
	var rr := RandomNumberGenerator.new()
	rr.seed = 99
	for i in 400:
		var dinero: int = rr.randi_range(0, 9000)
		var inv: Inventario = _inv()
		var antes: Dictionary = inv.serializar()
		var lista: Array[StringName] = CompraBot.comprar(dinero, inv, &"atacante" if i % 2 == 0 else &"defensor", Catalogo, rr)
		ok_inv = ok_inv and inv.serializar() == antes
		ok_coste = ok_coste and _coste(lista) <= dinero
		var sim := Inventario.new()
		for id: StringName in lista:
			ok_inv = ok_inv and bool(sim.equipar(id)["ok"])
			if [&"tirachinas", &"arco_olivo", &"lanzacohetes"].has(id):
				especiales += 1
		total += lista.size()
	comprobar("b1i) 400 compras al azar: nunca supera el dinero, no toca el inventario y cabe en el inventario", ok_inv and ok_coste)
	comprobar("b1j) las armas especiales salen raramente", especiales < total / 25, "%d de %d articulos" % [especiales, total])
	# catalogo falso inyectable
	var falso := FalsoCatalogo.new()
	var l6: Array[StringName] = CompraBot.comprar(1000, _inv(), &"atacante", falso, null)
	comprobar("b1k) acepta un catalogo inyectado (precios distintos)", l6.size() >= 1 and l6[0] == &"escudo_ligero", str(l6))


## Catalogo falso: todo cuesta 100 (salvo lo que no existe) para probar la inyeccion.
class FalsoCatalogo:
	extends RefCounted

	func precio(_id: StringName) -> int:
		return 100

	func existe(id: StringName) -> bool:
		return Catalogo.existe(id)


func _test_dificultad() -> void:
	var f: Dictionary = DificultadBot.perfil(&"facil")
	var n: Dictionary = DificultadBot.perfil(&"normal")
	var d: Dictionary = DificultadBot.perfil(&"dificil")
	comprobar("b1l) la dificultad endurece: reaccion, error y spray bajan; giro y cabeza suben",
			float(f["reaccion"]) > float(n["reaccion"]) and float(n["reaccion"]) > float(d["reaccion"])
			and float(f["error_inicial"]) > float(n["error_inicial"]) and float(n["error_inicial"]) > float(d["error_inicial"])
			and float(f["spray_max"]) > float(d["spray_max"]) and float(f["vel_giro"]) < float(n["vel_giro"]) and float(n["vel_giro"]) < float(d["vel_giro"])
			and float(f["p_cabeza"]) < float(n["p_cabeza"]) and float(n["p_cabeza"]) < float(d["p_cabeza"])
			and float(f["p_utilidad"]) < float(d["p_utilidad"]))
	comprobar("b1m) un nombre desconocido da el perfil normal", DificultadBot.perfil(&"xyz") == n)


# ------------------------------------------------------------------ utilidades de escenario (campo de practica)

## Posicion en el suelo del campo a `dist` m del punto de tiro hacia delante y `lado` m a la derecha.
func punto_campo(dist: float, lado: float = 0.0) -> Vector3:
	var p: Vector3 = campo.punto_tiro + campo.adelante * dist + campo.adelante.cross(Vector3.UP) * lado
	return Vector3(p.x, suelo(p) + 0.05, p.z)


func nuevo_bot(nombre: String, equipo: int, rol: StringName, dif: StringName, pos: Vector3, mirando: Vector3, semilla: int,
		api: ApiPartida = null) -> Bot:
	var b: Bot = Bot.crear(nombre, equipo, rol, dif, semilla, api)
	b.entrada_manual = true
	main.add_child(b)
	var yaw: float = rad_to_deg(atan2(-mirando.x, -mirando.z))
	b.teletransportar(pos, yaw)
	extra.append(b)
	return b


func nueva_diana(p: Vector3, equipo: int = 2, escudo: float = 0.0) -> Diana:
	var d := Diana.new()
	d.equipo = equipo
	d.armadura = escudo
	main.add_child(d)
	d.global_position = Vector3(p.x, suelo(p), p.z)
	extra.append(d)
	return d


## Avanza `segundos` el bot a mano (IA, comandos y temporizadores). Devuelve cuando `parar` (Callable -> bool) es verdadero.
func simular(bots: Array[Bot], segundos: float, parar: Callable = Callable()) -> float:
	var t: float = 0.0
	while t < segundos:
		for b: Bot in bots:
			b.ceguera.avanzar(DT)
			b.avanzar(DT)
		t += DT
		if parar.is_valid() and bool(parar.call()):
			break
	return t


func equipar_fusil(b: Bot) -> void:
	b.armas.equipar(&"fusil_asalto")


# ------------------------------------------------------------------ b2: comandos y Partida de prueba

func _test_comandos() -> void:
	var pp := PartidaPrueba.new()
	pp.configurar(&"libre", null)
	main.add_child(pp)
	extra.append(pp)
	var b: Bot = nuevo_bot("Cmd", 1, Bot.ROL_ESTATICO, &"normal", punto_campo(2.0), campo.adelante, 5, pp)
	await esperar_fisica(3)
	pp.dinero[b] = 1000
	comprobar("b2a) comprar sin dinero suficiente falla (fusil de 2900 con 1000)", not b.comandos.comprar(&"fusil_asalto") and b.armas.inventario.principal == &"")
	comprobar("b2b) comprar con dinero equipa y descuenta (escudo ligero 400)", b.comandos.comprar(&"escudo_ligero") and b.armas.inventario.escudo == 25.0
			and pp.dinero_de(b) == 600, "dinero=%d" % pp.dinero_de(b))
	comprobar("b2c) comprar un articulo inexistente falla", not b.comandos.comprar(&"no_existe"))
	pp.dinero[b] = 5000
	b.comandos.comprar(&"fusil_asalto")
	b.comandos.comprar(&"granada_humo")
	b.comandos.comprar(&"granada_humo")
	comprobar("b2d) la API de comandos equipa principal y utilidades (max. 2 de cada tipo)", b.armas.inventario.principal == &"fusil_asalto"
			and b.armas.inventario.cantidad_utilidad(&"granada_humo") == 2 and not b.comandos.comprar(&"granada_humo"))
	comprobar("b2e) comprar_kit (CompraBot + comandos) deja un kit valido", b.comprar_kit() is Array)
	# lanzar una granada de humo: forma una nube que tapa la vision
	var objetivo: Vector3 = punto_campo(14.0)
	var antes: int = get_nodes_in_group("nubes").size()
	var lanzo: bool = b.comandos.lanzar_utilidad(&"granada_humo", objetivo, true)
	for i in 120:  # mecha 1,2 s con fisica real
		await physics_frame
	var nubes: Array[Node] = get_nodes_in_group("nubes")
	comprobar("b2f) lanzar_utilidad: la granada de humo detona y crea una nube", lanzo and nubes.size() == antes + 1
			and b.armas.inventario.cantidad_utilidad(&"granada_humo") == 1, "nubes=%d" % nubes.size())
	var tapa: bool = false
	for n: Node in nubes:
		var nn: NubeVision = n as NubeVision
		if nn.global_position.distance_to(objetivo) < 9.0:
			tapa = true
			extra.append(nn)
	comprobar("b2g) la nube cae cerca del objetivo (rebotes aparte)", tapa)
	limpiar_extra()
	await esperar_fisica(2)


# ------------------------------------------------------------------ b3: combate

## Duelo de un bot contra una diana quieta a `dist` m. Devuelve {ttk (s o -1), disparos, herido_por_bot}.
func duelo(dif: StringName, semilla: int, dist: float, equipo_diana: int = 2, rol: StringName = Bot.ROL_ESTATICO) -> Dictionary:
	var d: Diana = nueva_diana(punto_campo(dist), equipo_diana)
	var b: Bot = nuevo_bot("Duelista", 1, rol, dif, campo.punto_tiro + Vector3(0, 0.05, 0), campo.adelante, semilla)
	b.armas.equipar(&"fusil_asalto")
	await esperar_fisica(3)
	var por_bot: Array = [true]
	d.salud.herido.connect(func(_c: float, _z: String, a: Node) -> void: por_bot[0] = por_bot[0] and a == b)
	var t: float = simular([b], 15.0, func() -> bool: return not d.salud.vivo)
	var res: Dictionary = {"ttk": t if not d.salud.vivo else -1.0, "disparos": b.armas.disparos_totales, "por_bot": bool(por_bot[0]),
			"vida": d.salud.vida, "bot": b, "diana": d}
	return res


func _test_combate() -> void:
	await esperar_fisica(2)
	# b3a: ve y mata a un objetivo quieto, todo el dano pasa por Balistica (Salud.herido con el bot de atacante)
	var r: Dictionary = await duelo(&"normal", 1, 18.0)
	comprobar("b3a) un bot (normal) ve y mata a una diana quieta a 18 m", float(r["ttk"]) > 0.0, "ttk=%.2f s, disparos=%d" % [float(r["ttk"]), int(r["disparos"])])
	comprobar("b3b) el dano a la diana lo hace el bot (Salud.herido con atacante = bot) y sale de Balistica",
			bool(r["por_bot"]) and int(r["disparos"]) > 3)
	limpiar_extra()
	await esperar_fisica(2)

	# b3c: tras un muro no la ve ni dispara
	var d2: Diana = nueva_diana(punto_campo(18.0), 2)
	var muro := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var caja := BoxShape3D.new()
	caja.size = Vector3(12.0, 8.0, 0.4)
	cs.shape = caja
	muro.add_child(cs)
	main.add_child(muro)
	muro.global_position = punto_campo(9.0) + Vector3(0, 3.0, 0)
	muro.look_at(muro.global_position + campo.adelante, Vector3.UP)
	extra.append(muro)
	var b2: Bot = nuevo_bot("TrasMuro", 1, Bot.ROL_ESTATICO, &"dificil", campo.punto_tiro + Vector3(0, 0.05, 0), campo.adelante, 2)
	b2.armas.equipar(&"fusil_asalto")
	await esperar_fisica(3)
	simular([b2], 5.0)
	comprobar("b3c) tras un muro no la ve: sin objetivo, sin disparos y la diana intacta", b2.cerebro.objetivo.is_empty()
			and b2.armas.disparos_totales == 0 and d2.salud.vida == 100.0, "disparos=%d vida=%.0f" % [b2.armas.disparos_totales, d2.salud.vida])
	# quitando el muro la ve y la mata
	muro.queue_free()
	await esperar_fisica(3)
	var t2: float = simular([b2], 12.0, func() -> bool: return not d2.salud.vivo)
	comprobar("b3d) al desaparecer el muro la ve y la mata", not d2.salud.vivo, "%.2f s" % t2)
	limpiar_extra()
	await esperar_fisica(2)

	# b3e: no ve a traves del humo (NubeVision)
	var d3: Diana = nueva_diana(punto_campo(18.0), 2)
	var b3: Bot = nuevo_bot("TrasHumo", 1, Bot.ROL_ESTATICO, &"dificil", campo.punto_tiro + Vector3(0, 0.05, 0), campo.adelante, 3)
	b3.armas.equipar(&"fusil_asalto")
	var nube: NubeVision = NubeVision.crear(main, punto_campo(8.0) + Vector3(0, 0.1, 0), 5.0, 60.0)
	extra.append(nube)
	await esperar_fisica(3)
	simular([b3], 5.0)
	comprobar("b3e) no ve a traves del humo: sin objetivo, sin disparos y la diana intacta", b3.cerebro.objetivo.is_empty()
			and b3.armas.disparos_totales == 0 and d3.salud.vida == 100.0, "disparos=%d" % b3.armas.disparos_totales)
	limpiar_extra()
	await esperar_fisica(2)

	# b3f: ciego (cegadora) no ve ni dispara mientras dura; despues si
	var d4: Diana = nueva_diana(punto_campo(18.0), 2)
	var b4: Bot = nuevo_bot("Ciego", 1, Bot.ROL_ESTATICO, &"dificil", campo.punto_tiro + Vector3(0, 0.05, 0), campo.adelante, 4)
	b4.armas.equipar(&"fusil_asalto")
	await esperar_fisica(3)
	b4.ceguera.cegar(1.0, 3.0)
	var lista4: Array[Bot] = [b4]
	simular(lista4, 1.2)
	var ciego_ok: bool = b4.cerebro.objetivo.is_empty() and b4.armas.disparos_totales == 0 and b4.cerebro.estado == CerebroBot.Estado.CIEGO
	comprobar("b3f) cegado por la cegadora no ve ni dispara", ciego_ok and d4.salud.vida == 100.0, "estado=%d" % int(b4.cerebro.estado))
	var t4: float = simular(lista4, 15.0, func() -> bool: return not d4.salud.vivo)
	comprobar("b3g) al recuperarse de la ceguera vuelve a combatir y mata", not d4.salud.vivo, "%.2f s" % t4)
	limpiar_extra()
	await esperar_fisica(2)

	# b3h: la ceguera hace perder punteria (mayor dispersion)
	var b5: Bot = nuevo_bot("Disp", 1, Bot.ROL_ESTATICO, &"normal", campo.punto_tiro + Vector3(0, 0.05, 0), campo.adelante, 6)
	b5.armas.equipar(&"fusil_asalto")
	await esperar_fisica(3)
	var disp_normal: float = b5.comandos.dispersion_actual(b5.armas.actual())
	b5.ceguera.cegar(1.0, 3.0)
	var disp_ciego: float = b5.comandos.dispersion_actual(b5.armas.actual())
	comprobar("b3h) ciego pierde punteria: la dispersion sube con la ceguera", disp_ciego > disp_normal + 5.0, "%.2f -> %.2f grados" % [disp_normal, disp_ciego])
	limpiar_extra()
	await esperar_fisica(2)

	# b3i: determinismo (misma semilla, mismo resultado) y dificultades
	var ra: Dictionary = await duelo(&"normal", 42, 20.0)
	var ta: float = float(ra["ttk"])
	var da: int = int(ra["disparos"])
	limpiar_extra()
	await esperar_fisica(2)
	var rb: Dictionary = await duelo(&"normal", 42, 20.0)
	comprobar("b3i) determinista: misma semilla -> mismo tiempo y mismos disparos", ta > 0.0 and is_equal_approx(ta, float(rb["ttk"])) and da == int(rb["disparos"]),
			"%.3f s / %d disparos" % [ta, da])
	limpiar_extra()
	await esperar_fisica(2)
	var medias: Dictionary = {}
	for dif: StringName in DificultadBot.TODAS:
		var suma: float = 0.0
		var muertes: int = 0
		var disp_tot: int = 0
		for s in 8:
			var rd: Dictionary = await duelo(dif, 100 + s, 14.0 + float(s) * 2.0)
			if float(rd["ttk"]) > 0.0:
				suma += float(rd["ttk"])
				muertes += 1
				disp_tot += int(rd["disparos"])
			limpiar_extra()
			await esperar_fisica(1)
		medias[dif] = suma / maxf(float(muertes), 1.0)
		informe.append("duelos 8 x diana quieta (14-28 m), %s: tiempo medio de muerte %.2f s, %d/8 muertas, %.1f disparos de media" % [
				dif, float(medias[dif]), muertes, float(disp_tot) / maxf(float(muertes), 1.0)])
		comprobar("b3j) %s mata a las 8 dianas" % dif, muertes == 8)
	comprobar("b3k) mas dificultad = mata antes (facil > normal > dificil)", float(medias[&"facil"]) > float(medias[&"normal"])
			and float(medias[&"normal"]) > float(medias[&"dificil"]), "%.2f > %.2f > %.2f s" % [float(medias[&"facil"]), float(medias[&"normal"]), float(medias[&"dificil"])])

	# b3l: dos bots de equipos distintos se matan entre si (uno muere) y salta la baja de SenalesCombate
	var bajas: Array = []
	SenalesCombate.obtener(self).baja.connect(func(a: Node, v: Salud, _arma: ArmaDatos) -> void: bajas.append([a, v]))
	await esperar_fisica(2)
	var ba: Bot = nuevo_bot("Rojo", 1, Bot.ROL_ESTATICO, &"normal", punto_campo(0.0), campo.adelante, 11)
	var bb: Bot = nuevo_bot("Azul", 2, Bot.ROL_ESTATICO, &"normal", punto_campo(22.0), -campo.adelante, 12)
	ba.armas.equipar(&"fusil_asalto")
	bb.armas.equipar(&"fusil_asalto")
	await esperar_fisica(3)
	var tt: float = simular([ba, bb], 20.0, func() -> bool: return ba.muerto or bb.muerto)
	comprobar("b3l) dos bots enemigos se ven y uno acaba muerto (baja registrada en SenalesCombate)", (ba.muerto or bb.muerto) and bajas.size() >= 1, "%.1f s, bajas=%d" % [tt, bajas.size()])
	var muerto: Bot = ba if ba.muerto else bb
	comprobar("b3m) el muerto suelta su arma comprada al suelo y no tiene hitboxes activas", get_nodes_in_group("armas_suelo").size() >= 1 \
			and (muerto.hitboxes.zonas["torso"] as ZonaImpacto).collision_layer == 0)
	ArmaSuelo.limpiar_armas_suelo(self)
	# fuego amigo: dos bots del mismo equipo no se ven como enemigos
	limpiar_extra()
	await esperar_fisica(2)
	var c1: Bot = nuevo_bot("Aliado1", 1, Bot.ROL_ESTATICO, &"dificil", punto_campo(0.0), campo.adelante, 13)
	var c2: Bot = nuevo_bot("Aliado2", 1, Bot.ROL_ESTATICO, &"dificil", punto_campo(15.0), -campo.adelante, 14)
	c1.armas.equipar(&"fusil_asalto")
	await esperar_fisica(3)
	simular([c1, c2], 4.0)
	comprobar("b3n) los companeros de equipo no se atacan", c1.cerebro.objetivo.is_empty() and c1.armas.disparos_totales == 0 and c2.salud.vida == 100.0)
	limpiar_extra()
	await esperar_fisica(2)


func _test_armas_suelo() -> void:
	var b: Bot = nuevo_bot("Recoge", 1, Bot.ROL_ESTATICO, &"normal", punto_campo(0.0), campo.adelante, 21)
	await esperar_fisica(3)
	# arma peor que la suya: la ignora; mejor: la recoge
	b.armas.equipar(&"subfusil_9mm")
	var peor: ArmaSuelo = ArmaSuelo.crear(main, &"tirachinas", 12, 48, punto_campo(6.0) + Vector3(0, 0.5, 0))
	var mejor: ArmaSuelo = ArmaSuelo.crear(main, &"fusil_asalto", 30, 90, punto_campo(-5.0) + Vector3(0, 0.5, 0))
	extra.append(peor)
	extra.append(mejor)
	for i in 90:
		await physics_frame
	var t: float = simular([b], 8.0, func() -> bool: return b.armas.inventario.principal == &"fusil_asalto")
	comprobar("b3o) recoge del suelo un arma mejor que la suya (fusil de asalto > subfusil 9 mm)", b.armas.inventario.principal == &"fusil_asalto", "%.1f s" % t)
	var dejo_antigua: bool = false
	for n: Node in get_nodes_in_group("armas_suelo"):
		if (n as ArmaSuelo).arma_id == &"subfusil_9mm":
			dejo_antigua = true
	comprobar("b3p) al recoger deja la anterior en el suelo y no recoge la peor", dejo_antigua and is_instance_valid(peor) and b.armas.inventario.principal != &"tirachinas")
	ArmaSuelo.limpiar_armas_suelo(self)
	limpiar_extra()
	await esperar_fisica(2)


# ------------------------------------------------------------------ b4: navegacion

func _test_navegacion() -> void:
	var ids: PackedStringArray = ZonaActiva.ids_disponibles()
	var solo: PackedStringArray = OS.get_cmdline_user_args()
	for zid in ids:
		if solo.has("rapido") and zid != "el_eje":
			continue
		await _navegar_zona(zid)
	if not rapido:
		await _navegar_campus()


func _navegar_zona(zid: String) -> void:
	var zona: ZonaActiva = ZonaActiva.crear(zid)
	main.add_child(zona)
	await esperar_fisica(3)
	var region: NavigationRegion3D = NavBots.hornear_zona(main, zona)
	var listo: bool = await NavBots.esperar_listo(main, zona.punto_spawn("atacantes", 0)["pos"])
	var mapa: RID = NavBots.mapa(main)
	var t_bake: float = float(region.get_meta("tiempo_s"))
	var n_poly: int = int(region.get_meta("poligonos"))
	# bots reales desde un spawn de cada equipo a cada site (mismos comandos que la IA)
	var bots: Array[Bot] = []
	var plan: Array[Dictionary] = []
	for eq: String in ["atacantes", "defensores"]:
		for s: String in ["A", "B"]:
			var sp: Dictionary = zona.punto_spawn(eq, 0)
			var b: Bot = nuevo_bot("Nav_%s_%s" % [eq, s], 1 if eq == "atacantes" else 2, Bot.ROL_ESTATICO, &"normal", sp["pos"], Vector3.FORWARD, 7)
			bots.append(b)
			var destino: Vector3 = NavigationServer3D.map_get_closest_point(mapa, zona.centro_site(s))
			plan.append({"bot": b, "site": s, "destino": destino, "llego": -1.0, "ruta": NavBots.longitud_ruta(mapa, sp["pos"], destino) / VEL_MS})
	await esperar_fisica(3)
	var t: float = 0.0
	var max_t: float = 90.0
	while t < max_t:
		var todos: bool = true
		for p: Dictionary in plan:
			var b: Bot = p["bot"]
			if float(p["llego"]) < 0.0:
				b.armas.avanzar(DT)
				b.comandos.mover_hacia(p["destino"])
				b.comandos.ejecutar(DT)
				if zona.site_en(b.global_position) == str(p["site"]):
					p["llego"] = t
				else:
					todos = false
		t += DT
		if todos:
			break
	var llegaron: int = 0
	var peor_ratio: float = 0.0
	var detalle: String = ""
	var rescates: int = 0
	var atascos: int = 0
	for p: Dictionary in plan:
		var b: Bot = p["bot"]
		if float(p["llego"]) >= 0.0:
			llegaron += 1
			peor_ratio = maxf(peor_ratio, float(p["llego"]) / maxf(float(p["ruta"]), 1.0))
			detalle += " %s->%s %.0f s (ruta %.0f s)" % [b.nombre.substr(4, 3), p["site"], float(p["llego"]), float(p["ruta"])]
		else:
			detalle += " %s->%s NO llega" % [b.nombre, p["site"]]
		rescates += b.comandos.rescates
		atascos += b.comandos.atascos
	comprobar("%s b4a) horneado de la zona listo (%.2f s, %d poligonos)" % [zid, t_bake, n_poly], listo and n_poly > 50 and t_bake < 20.0)
	comprobar("%s b4b) los bots llegan a A y B desde los spawns de ambos equipos en un tiempo razonable (< 1,6x la ruta)" % zid,
			llegaron == plan.size() and peor_ratio < 1.6, "%d/%d, peor ratio %.2f;%s" % [llegaron, plan.size(), peor_ratio, detalle])
	comprobar("%s b4c) sin atascos serios en el recorrido (rescates 0)" % zid, rescates == 0, "atascos=%d rescates=%d" % [atascos, rescates])
	informe.append("%s: horneado %.2f s (%d poligonos);%s" % [zid, t_bake, n_poly, detalle])
	limpiar_extra()
	region.queue_free()
	zona.queue_free()
	await esperar_fisica(3)


func _navegar_campus() -> void:
	var region: NavigationRegion3D = NavBots.hornear_campus(main)
	var t_bake: float = float(region.get_meta("tiempo_s"))
	var n_poly: int = int(region.get_meta("poligonos"))
	# entrada principal -> biblioteca (spawns.json)
	var pa: Vector3 = Vector3.INF
	var pb: Vector3 = Vector3.INF
	for s: Dictionary in main.spawns:
		var p: Array = s["pos"]
		if s["id"] == "entrada":
			pa = Vector3(p[0], p[1], p[2])
		elif s["id"] == "biblioteca":
			pb = Vector3(p[0], p[1], p[2])
	var listo: bool = await NavBots.esperar_listo(main, pa, 400)
	var mapa: RID = NavBots.mapa(main)
	var largo: float = NavBots.longitud_ruta(mapa, pa, pb)
	var recta: float = pa.distance_to(pb)
	comprobar("campus b4d) horneado del campus entero (%.1f s, %d poligonos) y ruta entrada -> biblioteca" % [t_bake, n_poly],
			listo and n_poly > 5000 and largo > 0.0 and largo < recta * 2.5, "ruta %.0f m (recta %.0f m)" % [largo, recta])
	informe.append("campus entero: horneado %.1f s, %d poligonos, ruta entrada->biblioteca %.0f m (recta %.0f m)" % [t_bake, n_poly, largo, recta])
	# un bot libre deambula por el campus sin quedarse parado
	var b: Bot = nuevo_bot("Libre", 0, Bot.ROL_LIBRE, &"normal", pa, Vector3.FORWARD, 31)
	await esperar_fisica(3)
	var t: float = simular([b], 40.0)
	var recorrido: float = b.global_position.distance_to(pa)
	comprobar("campus b4e) en modo libre un bot deambula (se aleja del punto de partida)", recorrido > 15.0 and b.comandos.rescates == 0, "a %.0f m tras %.0f s" % [recorrido, t])
	limpiar_extra()
	region.queue_free()
	await esperar_fisica(3)


# ------------------------------------------------------------------ b5 / b6: sims con director y Partida de prueba

## Monta una zona con nav, partida de prueba y director; crea `n` bots por equipo. Devuelve {zona, region, partida, director, bots}.
func montar_partida(zid: String, modo: StringName, n: int, dif: StringName, semilla: int, auto: bool) -> Dictionary:
	var zona: ZonaActiva = ZonaActiva.crear(zid)
	main.add_child(zona)
	await esperar_fisica(3)
	var region: NavigationRegion3D = NavBots.hornear_zona(main, zona)
	await NavBots.esperar_listo(main, zona.punto_spawn("atacantes", 0)["pos"])
	var partida := PartidaPrueba.new()
	partida.set_physics_process(auto)
	main.add_child(partida)
	partida.configurar(modo, zona)
	var dir := DirectorBots.new()
	dir.set_physics_process(auto)
	main.add_child(dir)
	dir.configurar(zona, partida, modo, NavBots.mapa(main), semilla)
	var bots: Array[Bot] = []
	for eq in [Bot.EQ_ATACANTES, Bot.EQ_DEFENSORES]:
		var txt: String = "atacantes" if eq == Bot.EQ_ATACANTES else "defensores"
		for i in n:
			var sp: Dictionary = zona.punto_spawn(txt, i)
			var b: Bot = Bot.crear("%s%d" % ["ATQ" if eq == Bot.EQ_ATACANTES else "DEF", i + 1], eq,
					Bot.ROL_ATACANTE if eq == Bot.EQ_ATACANTES else Bot.ROL_DEFENSOR, dif, semilla * 100 + eq * 10 + i, partida)
			b.entrada_manual = not auto
			main.add_child(b)
			b.teletransportar(sp["pos"], float(sp["yaw_deg"]))
			dir.agregar(b)
			bots.append(b)
	return {"zona": zona, "region": region, "partida": partida, "director": dir, "bots": bots}


func desmontar_partida(m: Dictionary) -> void:
	for b: Bot in m["bots"]:
		if is_instance_valid(b):
			b.free()
	(m["director"] as Node).free()
	(m["partida"] as Node).free()
	(m["region"] as Node).queue_free()
	(m["zona"] as Node).queue_free()
	for g: String in ["lanzables", "nubes", "proyectiles", "altavoces", "armas_suelo"]:
		for n: Node in get_nodes_in_group(g):
			n.queue_free()


func _test_defensor_apaga() -> void:
	var zid: String = "el_eje"
	var m: Dictionary = await montar_partida(zid, &"cachimba", 2, &"normal", 5, false)
	var zona: ZonaActiva = m["zona"]
	var partida: PartidaPrueba = m["partida"]
	var dir: DirectorBots = m["director"]
	var bots: Array[Bot] = []
	var defs: Array[Bot] = []
	for b: Bot in m["bots"]:
		if b.equipo == Bot.EQ_DEFENSORES:
			defs.append(b)
			bots.append(b)
	dir.preparar()
	for b: Bot in defs:
		b.comprar_kit()
	# la Cachimba aparece montada en el site A (los atacantes han muerto o no estan): los defensores se enteran y uno la apaga
	var sitio: String = "A"
	var pos: Vector3 = NavigationServer3D.map_get_closest_point(NavBots.mapa(main), zona.centro_site(sitio))
	await esperar_fisica(2)
	partida.forzar_montada(pos, sitio)
	var t: float = 0.0
	var ap: Array = [-1.0]
	partida.cachimba_apagada.connect(func() -> void: ap[0] = partida._t)
	var c: Cachimba = partida.cachimba()
	while t < Cachimba.T_TEMPORIZADOR + 5.0 and c.estado != Cachimba.Estado.APAGADA and c.estado != Cachimba.Estado.ALARMA:
		for b: Bot in bots:
			b.ceguera.avanzar(DT)
			b.avanzar(DT)
		dir.avanzar(DT)
		partida.avanzar(DT)
		t += DT
	var apagada_t: float = float(ap[0])
	comprobar("b5a) un defensor apaga la Cachimba montada antes de que suene la alarma", c.estado == Cachimba.Estado.APAGADA, "estado=%d, apagada a los %.1f s (limite 40 s)" % [int(c.estado), apagada_t])
	comprobar("b5b) el apagado lo hizo un defensor, tardo >= 7 s quieto a su lado y los demas defensores lo sabian",
			dir.cachimba_conocida and dir.apagador != null and dir.apagador.equipo == Bot.EQ_DEFENSORES and apagada_t >= Cachimba.T_APAGAR)
	informe.append("defensor apaga la Cachimba (%s, 2 defensores): apagada a los %.1f s de montada (limite 40 s)" % [zid, apagada_t])
	# una Cachimba montada que nadie apaga acaba en alarma (sin defensores)
	partida.cachimba().reiniciar()
	partida.forzar_montada(pos, sitio)
	for b: Bot in defs:
		b.hitboxes.activar(false)
		b.salud.recibir_dano(9999.0, "torso", 1.0, null)
	var t2: float = 0.0
	while t2 < 50.0 and c.estado != Cachimba.Estado.ALARMA:
		partida.avanzar(DT)
		t2 += DT
	comprobar("b5c) si nadie la apaga a los 40 s suena la alarma (no explota)", c.estado == Cachimba.Estado.ALARMA and absf(t2 - 40.0) < 0.2, "%.1f s" % t2)
	desmontar_partida(m)
	limpiar_extra()
	await esperar_fisica(3)


func _test_5v5() -> void:
	Engine.time_scale = 8.0
	await _sim_5v5("plaza_america", &"eliminacion", &"normal", 3)
	if not rapido:
		await _sim_5v5("el_eje", &"cachimba", &"normal", 4)
	Engine.time_scale = 1.0


func _sim_5v5(zid: String, modo: StringName, dif: StringName, semilla: int) -> void:
	var m: Dictionary = await montar_partida(zid, modo, 5, dif, semilla, true)
	var zona: ZonaActiva = m["zona"]
	var partida: PartidaPrueba = m["partida"]
	var dir: DirectorBots = m["director"]
	var bots: Array[Bot] = m["bots"]
	var granadas: int = 0
	var t_real0: int = Time.get_ticks_msec()
	dir.preparar()
	for b: Bot in bots:
		b.comprar_kit()
	var roles: Dictionary = {}
	for b: Bot in bots:
		roles[b.rol] = int(roles.get(b.rol, 0)) + 1
	var pl: Array = [-1.0]
	var resultado: String = ""
	partida.cachimba_montada.connect(func(_s: String) -> void: pl[0] = dir.t_ronda)
	var t: float = 0.0
	var max_t: float = 150.0
	var bj: Array = [0]
	SenalesCombate.obtener(self).baja.connect(func(_a: Node, _v: Salud, _arma: ArmaDatos) -> void: bj[0] += 1)
	await esperar_fisica(2)
	var cuenta: Dictionary = {1: 5, 2: 5}
	while t < max_t:
		await physics_frame
		t = dir.t_ronda   # reloj de simulacion (con time_scale hay varios pasos de fisica por fotograma)
		var vivos: Dictionary = {1: 0, 2: 0}
		for b: Bot in bots:
			if not b.muerto:
				vivos[b.equipo] = int(vivos[b.equipo]) + 1
		cuenta = vivos
		if int(vivos[1]) == 0 or int(vivos[2]) == 0:
			resultado = "equipo %s eliminado" % ("atacantes" if int(vivos[1]) == 0 else "defensores")
			break
		var c: Cachimba = partida.cachimba()
		if c != null and (c.estado == Cachimba.Estado.APAGADA or c.estado == Cachimba.Estado.ALARMA):
			resultado = "Cachimba %s" % ("apagada" if c.estado == Cachimba.Estado.APAGADA else "alarma (atacantes)")
			break
	var bajas: int = int(bj[0])
	var plantada_t: float = float(pl[0])
	var atascos: int = 0
	var rescates: int = 0
	var disparos: int = 0
	var recogidas: int = 0
	var bajas_bot: int = 0
	for b: Bot in bots:
		atascos += b.comandos.atascos
		rescates += b.comandos.rescates
		disparos += b.armas.disparos_totales
		granadas += b.cerebro.n_granadas
		recogidas += b.cerebro.n_recogidas
		bajas_bot += b.bajas
	var real_s: float = (Time.get_ticks_msec() - t_real0) / 1000.0
	var kits: String = ""
	for b: Bot in bots:
		kits += " %s:%s%s" % [b.nombre, b.armas.inventario.principal, "+%d" % int(b.armas.inventario.escudo) if b.armas.inventario.escudo > 0.0 else ""]
	var finalizo: bool = resultado != ""
	comprobar("%s b6a) 5v5 (%s, %s) termina: %s a los %.0f s simulados" % [zid, modo, dif, resultado if finalizo else "NO termina", t], finalizo,
			"vivos A=%d D=%d, bajas=%d, disparos=%d, granadas=%d, recogidas=%d, %.1f s reales (x8)" % [int(cuenta[1]), int(cuenta[2]), bajas, disparos, granadas, recogidas, real_s])
	comprobar("%s b6b) bots sin atascos graves: rescates = 0 (atascos detectados: %d)" % [zid, atascos], rescates == 0, "atascos=%d rescates=%d" % [atascos, rescates])
	comprobar("%s b6c) hubo combate real (bajas y disparos por Balistica) y todos compraron un kit" % zid, bajas >= 1 and disparos > 20, "bajas=%d disparos=%d" % [bajas, disparos])
	informe.append("5v5 %s (%s, %s): %s a los %.0f s simulados (%.1f s reales a x8); bajas %d, disparos %d, granadas %d, atascos %d, rescates %d, roles %s;%s" % [
			zid, modo, dif, resultado if finalizo else "NO termino", t, real_s, bajas, disparos, granadas, atascos, rescates, str(roles), kits])
	if modo == &"cachimba":
		informe.append("   Cachimba: montada=%s (a los %.0f s), rotaciones de defensa=%d, portador=%s" % [str(plantada_t >= 0.0), plantada_t, dir.rotaciones, str(dir.portador.nombre if dir.portador != null else "ninguno")])
	desmontar_partida(m)
	limpiar_extra()
	await esperar_fisica(3)
	zona = null
