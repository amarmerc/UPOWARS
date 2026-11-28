extends SceneTree
## Test headless del arsenal (paquete P2). Uso:
##   Godot_console.exe --headless --path game --script res://tests/test_arsenal.gd
## Imprime PASS/FAIL por comprobacion y sale con codigo 0 (todo bien) o 1.
## Usa el campo de practica real y la escena principal; el tiempo se simula a mano (avanzar / avanzar de cada nodo).

const DT: float = 1.0 / 60.0

var fallos: int = 0
var main: Node
var jugador: Jugador
var gestor: GestorArmas
var campo: CampoPractica
var fwd: Vector3
var base: Vector3
var rng := RandomNumberGenerator.new()
var extra: Array[Node] = []


func comprobar(nombre: String, ok: bool, detalle: String = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", nombre, detalle])
	if not ok:
		fallos += 1


func cerca(a: float, b: float, tol: float = 0.05) -> bool:
	return absf(a - b) <= tol


func esperar_fisica(n: int) -> void:
	for i in n:
		await physics_frame


func avanzar_gestor(g: GestorArmas, segundos: float) -> void:
	for i in int(round(segundos / DT)):
		g.avanzar(DT)


func suelo(p: Vector3) -> float:
	return campo._suelo(p)


## Diana nueva (con equipo y escudo) apoyada en el terreno, a `desde` + desplazamiento (x, z de juego).
func nueva_diana(p: Vector3, equipo: int = 0, escudo: float = 0.0) -> Diana:
	var d := Diana.new()
	d.equipo = equipo
	d.armadura = escudo
	main.add_child(d)
	d.global_position = Vector3(p.x, suelo(p), p.z)
	extra.append(d)
	return d


func nuevo_nodo(p: Vector3) -> Node3D:
	var n := Node3D.new()
	root.add_child(n)
	n.global_position = p
	extra.append(n)
	return n


func limpiar_extra() -> void:
	for n: Node in extra:
		if is_instance_valid(n):
			n.queue_free()
	extra.clear()


func nueva_pared(centro: Vector3, normal_hacia: Vector3) -> StaticBody3D:
	var muro := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var caja := BoxShape3D.new()
	caja.size = Vector3(10.0, 10.0, 0.3)
	cs.shape = caja
	muro.add_child(cs)
	root.add_child(muro)
	muro.global_position = centro
	muro.look_at(centro + normal_hacia, Vector3.UP)
	extra.append(muro)
	return muro


func _init() -> void:
	_ejecutar.call_deferred()


func _ejecutar() -> void:
	# ---------------------------------------------------------------- a1: inventario (puro, sin escena)
	_test_inventario()
	_test_catalogo()

	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await esperar_fisica(6)
	jugador = main.get_node("Jugador")
	gestor = jugador.gestor
	campo = main.campo
	var n_espera: int = 0
	while not campo.listo and n_espera < 60:
		await physics_frame
		n_espera += 1
	var sp: Dictionary = {}
	for s: Dictionary in main.spawns:
		if s["id"] == "campo_practica":
			sp = s
	main._colocar(sp)
	jugador.activo = false
	jugador.entrada_manual = true
	gestor.entrada_manual = true
	gestor.auto_recargar = false
	gestor.rng.seed = 2024
	rng.seed = 31337
	await esperar_fisica(4)
	avanzar_gestor(gestor, 1.0)
	base = jugador.global_position
	fwd = campo.adelante

	_test_controles_input_map()
	await _test_hitscan()
	await _test_escopetas()
	await _test_flecha()
	await _test_explosion()
	await _test_sable()
	await _test_humo()
	await _test_cegadora()
	await _test_pintura()
	await _test_fuego_amigo()
	await _test_apuntar_correr()
	await _test_carga_y_utilidades()
	await _test_suelo()

	print("RESULTADO: %s (%d fallos)" % ["PASS" if fallos == 0 else "FAIL", fallos])
	limpiar_extra()
	main.queue_free()
	await process_frame
	quit(0 if fallos == 0 else 1)


# ---------------------------------------------------------------- a1
func _test_inventario() -> void:
	var inv := Inventario.new()
	comprobar("a1a) base: Pistola 9 mm gratis, navaja, sin principal, sin utilidades, sin escudo",
			inv.secundaria == &"pistola_9mm" and inv.cuerpo == &"navaja" and inv.principal == &"" and inv.utilidades.is_empty()
			and inv.escudo == 0.0 and inv.cargador(&"pistola_9mm") == 12 and inv.reserva(&"pistola_9mm") == 48)
	var r: Dictionary = inv.equipar(&"fusil_asalto")
	comprobar("a1b) equipar principal; hueco vacio: nada que soltar", bool(r["ok"]) and inv.principal == &"fusil_asalto"
			and (r["soltada"] as Dictionary).is_empty() and inv.cargador(&"fusil_asalto") == 30)
	inv.fijar_municion(&"fusil_asalto", 7, 21)
	r = inv.equipar(&"subfusil_9mm")
	var s: Dictionary = r["soltada"]
	comprobar("a1c) sustituir la principal devuelve la anterior con su municion para soltarla",
			inv.principal == &"subfusil_9mm" and s.get("id") == &"fusil_asalto" and s["cargador"] == 7 and s["reserva"] == 21
			and inv.cargador(&"fusil_asalto") == 0, str(s))
	r = inv.equipar(&"revolver_357")
	comprobar("a1d) la secundaria gratuita al sustituirse NO se suelta", bool(r["ok"]) and inv.secundaria == &"revolver_357"
			and (r["soltada"] as Dictionary).is_empty())
	r = inv.equipar(&"puno_bot")
	comprobar("a1e) el Puño-Bot cuenta como secundaria (suelta el revolver) y el arco como principal",
			inv.secundaria == &"puno_bot" and (r["soltada"] as Dictionary).get("id") == &"revolver_357"
			and Catalogo.hueco(&"arco_olivo") == &"principal" and Catalogo.hueco(&"sable_plasma") == &"principal"
			and Catalogo.hueco(&"lanzacohetes") == &"principal" and Catalogo.hueco(&"tirachinas") == &"principal")
	var ok_u: Array[bool] = []
	for id: StringName in [&"granada_humo", &"granada_humo", &"granada_humo", &"granada_explosiva", &"granada_explosiva",
			&"altavoz", &"extintor"]:
		ok_u.append(bool(inv.equipar(id)["ok"]))
	comprobar("a1f) utilidades: max. 2 de cada tipo y 4 en total", ok_u == [true, true, false, true, true, false, false]
			and inv.utilidades.size() == 4 and inv.cantidad_utilidad(&"granada_humo") == 2, str(ok_u))
	inv.equipar(&"escudo_ligero")
	var e1: float = inv.escudo
	inv.equipar(&"escudo_pesado")
	comprobar("a1g) escudo ligero 25 y pesado 50", e1 == 25.0 and inv.escudo == 50.0)
	comprobar("a1h) consumir utilidad", inv.consumir_utilidad(&"granada_humo") and inv.cantidad_utilidad(&"granada_humo") == 1)
	inv.fijar_municion(&"subfusil_9mm", 11, 33)
	var d: Dictionary = inv.serializar()
	var json: String = JSON.stringify(d)
	var inv2 := Inventario.new()
	inv2.deserializar(JSON.parse_string(json) as Dictionary)
	comprobar("a1i) serializar / deserializar (incluido ida y vuelta por JSON) conserva todo y la municion",
			inv2.serializar() == d and inv2.principal == &"subfusil_9mm" and inv2.cargador(&"subfusil_9mm") == 11
			and inv2.reserva(&"subfusil_9mm") == 33 and inv2.utilidades.size() == 3 and inv2.escudo == 50.0)
	var sol: Dictionary = inv2.soltar(&"principal")
	comprobar("a1j) soltar: devuelve el arma con su municion y deja el hueco vacio; la secundaria vuelve a la Pistola 9 mm",
			sol.get("id") == &"subfusil_9mm" and sol["cargador"] == 11 and inv2.principal == &"" and inv2.cargador(&"subfusil_9mm") == 0
			and inv2.soltar(&"secundaria").get("id") == &"puno_bot" and inv2.secundaria == &"pistola_9mm"
			and inv2.soltar(&"secundaria").is_empty() and inv2.soltar(&"cuerpo").is_empty())
	inv2.reiniciar_a_base()
	comprobar("a1k) reiniciar_a_base", inv2.principal == &"" and inv2.secundaria == &"pistola_9mm" and inv2.utilidades.is_empty()
			and inv2.escudo == 0.0 and inv2.serializar()["municion"].size() == 1)


func _test_catalogo() -> void:
	var precios: Dictionary = {
		"pistola_9mm": 0, "pistola_auto": 500, "pistola_pesada": 800, "revolver_357": 700, "escopeta_recortada": 600,
		"subfusil_compacto": 900, "subfusil_9mm": 1500, "subfusil_45": 1900, "escopeta_corredera": 1800,
		"escopeta_auto": 2600, "carabina_556": 2500, "fusil_asalto": 2900, "fusil_combate": 3200, "fusil_tirador": 3500,
		"fusil_precision": 4700, "ametralladora": 3300, "arco_olivo": 2200, "tirachinas": 400, "lanzacohetes": 4000,
		"sable_plasma": 3000, "puno_bot": 600, "navaja": 0, "granada_humo": 300, "granada_cegadora": 250,
		"granada_explosiva": 400, "bote_pintura": 300, "extintor": 350, "altavoz": 200, "escudo_ligero": 400,
		"escudo_pesado": 1000}
	var mal: Array[String] = []
	for k: String in precios:
		var id := StringName(k)
		if not Catalogo.existe(id) or Catalogo.precio(id) != int(precios[k]):
			mal.append(k)
		elif Catalogo.hueco(id) != &"escudo" and Catalogo.arma(id) == null:
			mal.append(k + "(sin .tres)")
	comprobar("a1l) el catalogo tiene los 30 articulos con el precio pedido y su .tres", mal.is_empty() and Catalogo.todos().size() == 30,
			str(mal))
	var nombres_ok: bool = true
	for it: Dictionary in Catalogo.todos():
		var n: String = str(it["nombre"]).to_lower()
		for marca: String in ["glock", "ak", "m4", "awp", "deagle", "mp5", "ump", "r-7", "p-9"]:
			if n.contains(marca) and marca.length() > 2:
				nombres_ok = false
	comprobar("a1m) los nombres son genericos (sin marcas ni la antigua R-7 / P-9)", nombres_ok)


func _test_controles_input_map() -> void:
	var esperado: Dictionary = {
		"correr": KEY_SHIFT, "caminar_lento": KEY_ALT, "agacharse": KEY_CTRL, "recoger": KEY_E, "tirar_arma": KEY_G,
		"modo_vuelo": KEY_F1, "abrir_selector": KEY_M, "depuracion": KEY_F3, "suicidio": KEY_K, "arma_4": KEY_4,
		"armero": KEY_F6}
	var mal: Array[String] = []
	for a: String in esperado:
		var ok: bool = false
		if InputMap.has_action(a):
			for ev: InputEvent in InputMap.action_get_events(a):
				if ev is InputEventKey and (ev as InputEventKey).physical_keycode == esperado[a]:
					ok = true
		if not ok:
			mal.append(a)
	comprobar("a0) Input Map: Shift correr, Alt sigilo, Ctrl agacharse, E recoger, G tirar, 4, F6 armero; F1/M/F3/K intactos",
			mal.is_empty(), str(mal))


# ---------------------------------------------------------------- a2
func _test_hitscan() -> void:
	var d10: Diana = campo.dianas[0]
	var mal: Array[String] = []
	var n: int = 0
	for it: Dictionary in Catalogo.todos():
		var a: ArmaDatos = Catalogo.arma(StringName(it["id"]))
		if a == null or a.tipo != ArmaDatos.T_HITSCAN or a.es_utilidad():
			continue
		n += 1
		var origen: Vector3 = jugador.camara.global_position
		var res: Dictionary = Balistica.resolver_disparo(origen, (d10.centro("torso") - origen).normalized(), a, jugador, rng, 0.0)
		var esperado: float = a.dano_base * a.mult_torso
		if res["zona"] != "torso" or not cerca(float(res["daño"]), esperado):
			mal.append("%s %.2f/%.2f" % [a.id, res["daño"], esperado])
	comprobar("a2a) el dano al torso a 10 m de cada hitscan (%d armas) es el de su .tres" % n, mal.is_empty() and n == 13, str(mal))
	var origen2: Vector3 = jugador.camara.global_position
	var fc: ArmaDatos = Catalogo.arma(&"fusil_combate")
	var fp: ArmaDatos = Catalogo.arma(&"fusil_precision")
	var obj: Salud = d10.salud
	obj.escudo = 50.0
	var rc: Dictionary = Balistica.resolver_disparo(origen2, (d10.centro("cabeza") - origen2).normalized(), fc, jugador, rng, 0.0)
	Balistica.aplicar(rc, fc, jugador)
	var mata_cabeza: bool = not obj.vivo
	_restaurar(d10)
	obj.escudo = 50.0
	var rp: Dictionary = Balistica.resolver_disparo(origen2, (d10.centro("torso") - origen2).normalized(), fp, jugador, rng, 0.0)
	Balistica.aplicar(rp, fp, jugador)
	var mata_torso: bool = not obj.vivo
	_restaurar(d10)
	comprobar("a2b) fusil de combate 7,62: un tiro a la cabeza mata incluso con escudo; fusil de precision: letal al torso",
			mata_cabeza and mata_torso)
	# rafaga de la pistola automatica: 3 disparos por pulsacion
	gestor.equipar(&"pistola_auto")
	avanzar_gestor(gestor, 1.0)
	var antes: int = gestor.disparos_totales
	gestor.gatillo = true
	gestor.avanzar(DT)
	gestor.gatillo = false
	avanzar_gestor(gestor, 0.5)
	comprobar("a2c) pistola automatica: una pulsacion = rafaga de 3", gestor.disparos_totales - antes == 3,
			"disparos=%d" % (gestor.disparos_totales - antes))
	gestor.reiniciar()
	avanzar_gestor(gestor, 1.0)


func _restaurar(d: Diana) -> void:
	d.muerta = false
	d.caida.rotation.x = 0.0
	d.salud.reiniciar()
	d.hitboxes.activar(true)


# ---------------------------------------------------------------- a3
func _test_escopetas() -> void:
	var lado: Vector3 = fwd.cross(Vector3.UP).normalized()
	var objetivo: Diana = nueva_diana(base + fwd * 12.0 - lado * 10.0)
	await esperar_fisica(3)
	var centro: Vector3 = objetivo.centro("torso")
	var res_txt: Array[String] = []
	var todas_ok: bool = true
	var medias: Dictionary = {}
	for id: StringName in [&"escopeta_recortada", &"escopeta_corredera", &"escopeta_auto"]:
		var a: ArmaDatos = Catalogo.arma(id)
		var m: Array[float] = [0.0, 0.0]
		for k in 2:
			var dist: float = 5.0 if k == 0 else 25.0
			var t: Node3D = nuevo_nodo(centro - fwd * dist)
			await physics_frame
			var suma: float = 0.0
			for i in 40:
				var r: Dictionary = Balistica.resolver_perdigones(t.global_position, fwd, a, t, rng, 0.0)
				suma += float(r["daño_total"])
			m[k] = suma / 40.0
		medias[id] = m
		res_txt.append("%s 5m=%.1f 25m=%.1f" % [id, m[0], m[1]])
		if not (m[0] > 3.0 * m[1] and m[0] > 25.0):
			todas_ok = false
	comprobar("a3a) escopetas: mucho mas dano a 5 m que a 25 m (media de 40 salvas)", todas_ok, "; ".join(res_txt))
	var rec: ArmaDatos = Catalogo.arma(&"escopeta_recortada")
	var cor: ArmaDatos = Catalogo.arma(&"escopeta_corredera")
	comprobar("a3b) la recortada cae antes que la de corredera (factor de distancia a 12 y 25 m)",
			Balistica.factor_distancia(rec, 12.0) < Balistica.factor_distancia(cor, 12.0)
			and Balistica.factor_distancia(rec, 25.0) < Balistica.factor_distancia(cor, 25.0)
			and (medias[&"escopeta_recortada"] as Array)[1] < (medias[&"escopeta_corredera"] as Array)[1],
			"rec12=%.2f cor12=%.2f" % [Balistica.factor_distancia(rec, 12.0), Balistica.factor_distancia(cor, 12.0)])
	comprobar("a3c) datos: recortada 2 cartuchos / 8 perdigones; corredera 6 / 9; automatica con menos dano por perdigon y mas cadencia",
			rec.cargador == 2 and rec.perdigones == 8 and cor.cargador == 6 and cor.perdigones == 9
			and Catalogo.arma(&"escopeta_auto").dano_base < cor.dano_base and Catalogo.arma(&"escopeta_auto").cadencia > cor.cadencia)
	# disparo real del gestor: salva y cargador
	gestor.equipar(&"escopeta_corredera")
	avanzar_gestor(gestor, 1.5)
	var antes: int = gestor.municion_cargador()
	jugador.camara.look_at(centro, Vector3.UP)
	gestor.gatillo = true
	gestor.avanzar(DT)
	gestor.gatillo = false
	gestor.avanzar(DT)
	comprobar("a3d) la escopeta del gestor gasta un cartucho por salva", gestor.municion_cargador() == antes - 1)
	gestor.reiniciar()
	jugador.camara.rotation = Vector3.ZERO
	avanzar_gestor(gestor, 1.0)
	limpiar_extra()


# ---------------------------------------------------------------- a4
func _test_flecha() -> void:
	var arco: ArmaDatos = Catalogo.arma(&"arco_olivo")
	var origen: Vector3 = base + Vector3(0, 14.0, 0)  # en alto para que la flecha no toque el suelo antes de los 40 m
	var p: Proyectil = Proyectil.lanzar(jugador, arco, origen, fwd * arco.velocidad_proyectil, jugador, 1.0, false)
	var y10: float = INF
	var y40: float = INF
	var pasos: int = 0
	while p.estado == Proyectil.Estado.VOLANDO and pasos < 600:
		p.avanzar(DT)
		pasos += 1
		var horiz: float = Vector2(p.global_position.x - origen.x, p.global_position.z - origen.z).length()
		if y10 == INF and horiz >= 10.0:
			y10 = p.global_position.y
		if y40 == INF and horiz >= 40.0:
			y40 = p.global_position.y
	p.queue_free()
	comprobar("a4a) la flecha cae: mas baja a 40 m que a 10 m", y10 < INF and y40 < INF and y40 < y10 - 1.0,
			"y10=%.2f y40=%.2f (origen %.2f)" % [y10, y40, origen.y])
	# no atraviesa una pared
	var lado: Vector3 = fwd.cross(Vector3.UP).normalized()
	var objetivo: Diana = nueva_diana(base + fwd * 20.0 - lado * 10.0)
	var tirador: Node3D = nuevo_nodo(Vector3(objetivo.global_position.x, 0, objetivo.global_position.z) - fwd * 20.0)
	tirador.global_position.y = objetivo.global_position.y + 1.2
	var muro: StaticBody3D = nueva_pared(tirador.global_position + fwd * 12.0, -fwd)
	await esperar_fisica(3)
	var dir: Vector3 = (objetivo.centro("torso") - tirador.global_position).normalized()
	var p2: Proyectil = Proyectil.lanzar(jugador, arco, tirador.global_position, dir * arco.velocidad_proyectil, tirador, 1.0, false)
	pasos = 0
	while p2.estado == Proyectil.Estado.VOLANDO and pasos < 600:
		p2.avanzar(DT)
		pasos += 1
	var dist_muro: float = absf((p2.global_position - muro.global_position).dot(fwd))
	comprobar("a4b) la flecha no atraviesa una pared: se clava en ella y no hace dano al objetivo de detras",
			p2.estado == Proyectil.Estado.CLAVADO and dist_muro < 0.4 and objetivo.salud.vida == 100.0,
			"estado=%d dist_muro=%.2f vida=%.0f" % [p2.estado, dist_muro, objetivo.salud.vida])
	p2.queue_free()
	muro.queue_free()
	await esperar_fisica(3)
	# control positivo: sin pared acierta (cabeza letal, torso 78 a plena carga)
	dir = (objetivo.centro("torso") + Vector3(0, 0.4, 0) - tirador.global_position).normalized()  # compensa la caida
	var p3: Proyectil = Proyectil.lanzar(jugador, arco, tirador.global_position, dir * arco.velocidad_proyectil, tirador, 1.0, false)
	pasos = 0
	while p3.estado == Proyectil.Estado.VOLANDO and pasos < 600:
		p3.avanzar(DT)
		pasos += 1
	comprobar("a4c) sin pared la flecha acierta al torso (78 de dano a plena carga)", cerca(objetivo.salud.vida, 22.0, 1.5),
			"vida=%.1f" % objetivo.salud.vida)
	_restaurar(objetivo)
	var rc: Dictionary = Balistica.resolver_impacto({"impacto": false, "zona": "", "daño": 0.0, "salud": null}, {
			"position": Vector3.ZERO, "normal": Vector3.UP, "collider": objetivo.hitboxes.zonas["cabeza"]}, Vector3(0, 0, 10), arco)
	comprobar("a4d) la flecha a la cabeza es letal (x3,5)", float(rc["daño"]) >= 100.0, "dano=%.1f" % rc["daño"])
	limpiar_extra()


# ---------------------------------------------------------------- a5
func _test_explosion() -> void:
	var lado: Vector3 = fwd.cross(Vector3.UP).normalized()
	var traca: ArmaDatos = Catalogo.arma(&"lanzacohetes")
	jugador.salud.reiniciar()
	var p_centro: Vector3 = base + fwd * 3.0
	p_centro.y = suelo(p_centro) + 1.15
	var cerca_d: Diana = nueva_diana(p_centro + fwd * 1.0 - Vector3(0, 1.15, 0))
	var lejos_d: Diana = nueva_diana(p_centro + fwd * 5.0 - Vector3(0, 1.15, 0))
	var tras_muro: Diana = nueva_diana(p_centro + lado * 4.0 - Vector3(0, 1.15, 0))
	var muro: StaticBody3D = nueva_pared(p_centro + lado * 2.0, -lado)
	await esperar_fisica(3)
	var hits: Array[Dictionary] = Balistica.aplicar_explosion(p_centro, traca, jugador, jugador)
	var d_cerca: float = 100.0 - cerca_d.salud.vida
	var d_lejos: float = 100.0 - lejos_d.salud.vida
	comprobar("a5a) explosion: dano en area con caida (cerca > lejos > 0, lo mas cercano casi el maximo)",
			d_cerca > d_lejos and d_lejos > 0.0 and d_cerca > 0.9 * traca.dano_explosion * 0.5,
			"cerca=%.1f lejos=%.1f" % [d_cerca, d_lejos])
	comprobar("a5b) la pared bloquea la explosion (objetivo tras el muro sin dano)", tras_muro.salud.vida == 100.0
			and hits.size() >= 2, "vida=%.1f" % tras_muro.salud.vida)
	# autodano reducido: el jugador y una diana a la misma distancia (3 m) a lados opuestos
	jugador.salud.reiniciar()
	jugador.velocity = Vector3.ZERO
	var par: Diana = nueva_diana(p_centro + fwd * 3.0 - Vector3(0, 1.15, 0))
	await esperar_fisica(2)
	_restaurar(par)
	Balistica.aplicar_explosion(p_centro, traca, jugador, jugador)
	var d_diana: float = 100.0 - par.salud.vida
	var d_jugador: float = 100.0 - jugador.salud.vida
	comprobar("a5c) autodano reducido (la mitad) y empuje al jugador",
			d_jugador > 0.0 and cerca(d_jugador, d_diana * traca.autodano, 3.0) and jugador.velocity.length() > 1.0,
			"jugador=%.1f diana=%.1f vel=%.1f" % [d_jugador, d_diana, jugador.velocity.length()])
	# cohete real: viaja, explota al chocar y mata a la diana a 10 m
	jugador.salud.reiniciar()
	jugador.velocity = Vector3.ZERO
	var d10: Diana = campo.dianas[0]
	var origen: Vector3 = jugador.camara.global_position
	var dir: Vector3 = (d10.centro("torso") - origen).normalized()
	var p: Proyectil = Proyectil.lanzar(jugador, traca, origen, dir * traca.velocidad_proyectil, jugador, 1.0, false)
	var pasos: int = 0
	while p.estado == Proyectil.Estado.VOLANDO and pasos < 600:
		p.avanzar(DT)
		pasos += 1
	comprobar("a5d) el cohete (Traca) explota en el impacto y mata a la diana; solo 2 cohetes en total",
			not d10.salud.vivo and traca.cargador + traca.reserva == 2, "vida=%.1f pasos=%d" % [d10.salud.vida, pasos])
	_restaurar(d10)
	muro.queue_free()
	limpiar_extra()
	jugador.salud.reiniciar()
	jugador.velocity = Vector3.ZERO


# ---------------------------------------------------------------- a6
func _test_sable() -> void:
	var pistola: ArmaDatos = Catalogo.arma(&"pistola_9mm")
	gestor.equipar(&"sable_plasma")
	jugador.camara.rotation = Vector3.ZERO
	avanzar_gestor(gestor, 1.0)
	jugador.salud.reiniciar()
	var sable: ArmaDatos = Catalogo.arma(&"sable_plasma")
	var delante: Node3D = nuevo_nodo(jugador.camara.global_position + (-jugador.camara.global_transform.basis.z) * 8.0)
	var detras: Node3D = nuevo_nodo(jugador.camara.global_position + (jugador.camara.global_transform.basis.z) * 8.0)
	await esperar_fisica(2)
	var obj: Vector3 = jugador.hitboxes.centro_zona("torso")
	# sin bloquear el disparo hace dano
	var r0: Dictionary = Balistica.resolver_disparo(delante.global_position, (obj - delante.global_position).normalized(), pistola, delante, rng)
	Balistica.aplicar(r0, pistola, delante)
	var sin_bloqueo: float = 100.0 - jugador.salud.vida
	jugador.salud.reiniciar()
	gestor.gatillo_alt = true
	avanzar_gestor(gestor, 0.3)
	var lento: float = jugador.mult_velocidad_estado
	var r1: Dictionary = Balistica.resolver_disparo(delante.global_position, (obj - delante.global_position).normalized(), pistola, delante, rng)
	Balistica.aplicar(r1, pistola, delante)
	var calor1: float = gestor.calor
	comprobar("a6a) el sable bloquea un disparo frontal (sin dano, sube el calor) y se mueve mas lento al bloquear",
			sin_bloqueo > 0.0 and jugador.salud.vida == 100.0 and bool(r1.get("bloqueado", false)) and calor1 > 0.0 and lento < 1.0,
			"sin_bloqueo=%.1f calor=%.1f mult=%.2f" % [sin_bloqueo, calor1, lento])
	var r2: Dictionary = Balistica.resolver_disparo(detras.global_position, (obj - detras.global_position).normalized(), pistola, detras, rng)
	Balistica.aplicar(r2, pistola, detras)
	comprobar("a6b) no bloquea por la espalda", jugador.salud.vida < 100.0 and not bool(r2.get("bloqueado", false)),
			"vida=%.1f" % jugador.salud.vida)
	jugador.salud.reiniciar()
	# proyectil (flecha) bloqueado
	var arco: ArmaDatos = Catalogo.arma(&"arco_olivo")
	var flecha: Proyectil = Proyectil.lanzar(jugador, arco, delante.global_position, (obj - delante.global_position).normalized() * arco.velocidad_proyectil, delante, 1.0, false)
	var pasos: int = 0
	while flecha.estado == Proyectil.Estado.VOLANDO and pasos < 400:
		flecha.avanzar(DT)
		pasos += 1
	comprobar("a6c) tambien bloquea proyectiles", jugador.salud.vida == 100.0 and bool(flecha.ultimo_impacto.get("bloqueado", false)),
			"vida=%.1f" % jugador.salud.vida)
	# sobrecalentamiento: con muchos bloqueos llega a 100 y deja de bloquear durante 4 s; despues se recupera
	var bloqueados: int = 0
	var n: int = 0
	while not gestor.sobrecalentado and n < 60:
		var r: Dictionary = Balistica.resolver_disparo(delante.global_position, (obj - delante.global_position).normalized(), pistola, delante, rng)
		Balistica.aplicar(r, pistola, delante)
		if bool(r.get("bloqueado", false)):
			bloqueados += 1
		n += 1
	jugador.salud.reiniciar()
	var r3: Dictionary = Balistica.resolver_disparo(delante.global_position, (obj - delante.global_position).normalized(), pistola, delante, rng)
	Balistica.aplicar(r3, pistola, delante)
	var dano_sobre: bool = jugador.salud.vida < 100.0
	comprobar("a6d) con %d bloqueos seguidos se sobrecalienta (calor 100) y entonces no bloquea" % bloqueados,
			gestor.sobrecalentado and gestor.calor >= 100.0 and dano_sobre and bloqueados >= 10, "bloqueados=%d" % bloqueados)
	avanzar_gestor(gestor, sable.tiempo_sobrecalentado - 0.5)
	var aun: bool = gestor.sobrecalentado
	avanzar_gestor(gestor, 0.7)
	jugador.salud.reiniciar()
	var r4: Dictionary = Balistica.resolver_disparo(delante.global_position, (obj - delante.global_position).normalized(), pistola, delante, rng)
	Balistica.aplicar(r4, pistola, delante)
	comprobar("a6e) tras 4 s se recupera y vuelve a bloquear", aun and not gestor.sobrecalentado and gestor.calor < 20.0
			and jugador.salud.vida == 100.0 and bool(r4.get("bloqueado", false)), "calor=%.1f" % gestor.calor)
	# no bloquea explosiones
	var traca: ArmaDatos = Catalogo.arma(&"lanzacohetes")
	var punto: Vector3 = jugador.global_position + Vector3(0, 1.1, 0) + (-jugador.camara.global_transform.basis.z) * 3.5
	Balistica.aplicar_explosion(punto, traca, delante, jugador)
	comprobar("a6f) el sable NO bloquea explosiones", jugador.salud.vida < 100.0, "vida=%.1f" % jugador.salud.vida)
	# golpe en arco con el sable: da a un objetivo delante
	gestor.gatillo_alt = false
	jugador.salud.reiniciar()
	avanzar_gestor(gestor, 1.0)
	var dsa: Diana = nueva_diana(base + fwd * 1.8)
	await esperar_fisica(3)
	jugador.camara.look_at(dsa.centro("torso"), Vector3.UP)
	gestor.gatillo = true
	gestor.avanzar(DT)
	gestor.gatillo = false
	gestor.avanzar(DT)
	comprobar("a6g) el golpe en arco del sable hace dano (68)", cerca(100.0 - dsa.salud.vida, 68.0, 1.0),
			"vida=%.1f" % dsa.salud.vida)
	jugador.camara.rotation = Vector3.ZERO
	gestor.reiniciar()
	avanzar_gestor(gestor, 1.0)
	jugador.salud.reiniciar()
	limpiar_extra()


# ---------------------------------------------------------------- a7
func _test_humo() -> void:
	var a: Vector3 = base + Vector3(0, 1.65, 0)
	var b: Vector3 = a + fwd * 12.0
	var libre: bool = Utilidades.linea_de_vision(jugador, a, b)
	var humo: ArmaDatos = Catalogo.arma(&"granada_humo")
	var medio: Vector3 = a + fwd * 6.0
	medio.y = suelo(medio)
	var nube: NubeVision = NubeVision.crear(jugador, medio, humo.radio_efecto, humo.duracion_efecto)
	await physics_frame
	var con_humo: bool = Utilidades.linea_de_vision(jugador, a, b)
	var lado: Vector3 = fwd.cross(Vector3.UP).normalized()
	var fuera: bool = Utilidades.linea_de_vision(jugador, a + lado * 9.0, b + lado * 9.0)
	nube.avanzar(14.0)
	var aun: bool = not Utilidades.linea_de_vision(jugador, a, b)
	nube.avanzar(1.5)
	await process_frame
	var despues: bool = Utilidades.linea_de_vision(jugador, a, b)
	comprobar("a7a) humo de 5 m y 15 s: bloquea la linea de vision mientras dura, no a 9 m al lado, y despues se despeja",
			libre and not con_humo and fuera and aun and despues and humo.radio_efecto == 5.0 and humo.duracion_efecto == 15.0,
			"libre=%s con=%s fuera=%s aun=%s despues=%s" % [libre, con_humo, fuera, aun, despues])
	# una pared tambien corta la vision
	var muro: StaticBody3D = nueva_pared(a + fwd * 6.0, -fwd)
	await esperar_fisica(3)
	var tras_muro: bool = Utilidades.linea_de_vision(jugador, a, b)
	muro.queue_free()
	await esperar_fisica(3)
	comprobar("a7b) una pared corta la linea de vision", not tras_muro and Utilidades.linea_de_vision(jugador, a, b))
	# granada de humo lanzada: rebota, mecha de 1,2 s y crea la nube
	var l: Lanzable = Utilidades.lanzar(jugador, humo, a + fwd * 1.0, fwd * 8.0 + Vector3.UP * 2.0, jugador)
	l.set_physics_process(false)
	var n: int = 0
	while is_instance_valid(l) and not l.activada and n < 400:
		l.avanzar(DT)
		n += 1
	await process_frame
	var nubes: Array[Node] = get_nodes_in_group("nubes")
	comprobar("a7c) la granada de humo lanzada (con rebotes) crea la nube tras su mecha", nubes.size() == 1 and n >= 60,
			"nubes=%d pasos=%d" % [nubes.size(), n])
	for nb: Node in nubes:
		(nb as NubeVision).avanzar(20.0)
	await process_frame
	limpiar_extra()


# ---------------------------------------------------------------- a8
func _test_cegadora() -> void:
	var ceg: ArmaDatos = Catalogo.arma(&"granada_cegadora")
	jugador.camara.rotation = Vector3.ZERO
	var ojos: Vector3 = jugador.camara.global_position
	var flash: Vector3 = ojos + (-jugador.camara.global_transform.basis.z) * 8.0
	Utilidades.cegar_en(jugador, flash, ceg)
	var de_cara: float = jugador.ceguera.nivel()
	jugador.ceguera.restante = 0.0
	jugador.rotate_y(PI)  # de espaldas al flash
	await physics_frame
	Utilidades.cegar_en(jugador, flash, ceg)
	var de_espaldas: float = jugador.ceguera.nivel()
	jugador.rotate_y(-PI)
	comprobar("a8a) cegadora: mirando hacia ella ciega mucho mas que de espaldas (pero algo)",
			de_cara > 0.7 and de_espaldas > 0.0 and de_cara > 2.0 * de_espaldas, "cara=%.2f espaldas=%.2f" % [de_cara, de_espaldas])
	# distancia
	jugador.ceguera.restante = 0.0
	Utilidades.cegar_en(jugador, ojos + (-jugador.camara.global_transform.basis.z) * 25.0, ceg)
	var lejos: float = jugador.ceguera.nivel()
	jugador.ceguera.restante = 0.0
	comprobar("a8b) la ceguera disminuye con la distancia", lejos > 0.0 and lejos < de_cara, "lejos=%.2f" % lejos)
	# pared: sin linea de vision no ciega
	var muro: StaticBody3D = nueva_pared(ojos + (-jugador.camara.global_transform.basis.z) * 4.0, jugador.camara.global_transform.basis.z)
	await esperar_fisica(3)
	Utilidades.cegar_en(jugador, flash, ceg)
	comprobar("a8c) una pared protege de la cegadora", jugador.ceguera.nivel() == 0.0)
	muro.queue_free()
	await esperar_fisica(2)
	# la ceguera desaparece con el tiempo y los bots ciegos pierden punteria (dispersion mayor)
	Utilidades.cegar_en(jugador, flash, ceg)
	var disp_ciego: float = Balistica.dispersion(Catalogo.arma(&"fusil_asalto"), 0.0, true, false, 0.0, jugador.ceguera.nivel())
	var disp_normal: float = Balistica.dispersion(Catalogo.arma(&"fusil_asalto"), 0.0, true, false)
	var error_bot: float = jugador.ceguera.error_punteria()
	jugador.ceguera.avanzar(10.0)
	comprobar("a8d) ciego: dispersion y error de punteria mayores; pasa con el tiempo",
			disp_ciego > disp_normal + 3.0 and error_bot > 3.0 and jugador.ceguera.nivel() == 0.0,
			"ciego=%.2f normal=%.2f error=%.2f" % [disp_ciego, disp_normal, error_bot])
	# una diana (futuro bot) tambien se ciega
	var dd: Diana = nueva_diana(base + fwd * 8.0 + fwd.cross(Vector3.UP) * 8.0)
	dd.look_at(Vector3(base.x, dd.global_position.y, base.z), Vector3.UP)
	await esperar_fisica(2)
	Utilidades.cegar_en(jugador, dd.global_position + Vector3(0, 1.6, 0) + (-dd.global_transform.basis.z) * 3.0, ceg)
	comprobar("a8e) los combatientes con EstadoCeguera (bots, dianas) tambien se ciegan", dd.ceguera.nivel() > 0.3,
			"nivel=%.2f" % dd.ceguera.nivel())
	jugador.ceguera.restante = 0.0
	limpiar_extra()


# ---------------------------------------------------------------- a9
func _test_pintura() -> void:
	var bote: ArmaDatos = Catalogo.arma(&"bote_pintura")
	jugador.salud.equipo = 1
	var lado: Vector3 = fwd.cross(Vector3.UP).normalized()
	var centro: Vector3 = base + fwd * 12.0 - lado * 10.0
	var enemigo: Diana = nueva_diana(centro + lado * 2.0, 2)
	var aliado: Diana = nueva_diana(centro - lado * 2.0, 1)
	var lejano: Diana = nueva_diana(centro + lado * 9.0, 2)
	await esperar_fisica(3)
	var n: int = Utilidades.marcar_en(jugador, centro + Vector3(0, 1.0, 0), bote, jugador)
	var m1: Array[Salud] = Utilidades.marcados_para(jugador, 1)
	var m2: Array[Salud] = Utilidades.marcados_para(jugador, 2)
	comprobar("a9a) el bote marca a los enemigos a menos de 4 m (no al aliado ni al lejano), visibles para el equipo",
			n == 1 and m1.size() == 1 and m1[0] == enemigo.salud and m2.is_empty() and aliado.salud.marcas.is_empty()
			and lejano.salud.marcas.is_empty() and bote.radio_efecto == 4.0 and bote.duracion_efecto == 5.0,
			"marcados=%d" % m1.size())
	enemigo.salud.avanzar(4.9)
	var aun: bool = Utilidades.marcados_para(jugador, 1).size() == 1
	enemigo.salud.avanzar(0.2)
	comprobar("a9b) la marca dura 5 s", aun and Utilidades.marcados_para(jugador, 1).is_empty())
	# el bote lanzado se rompe al primer impacto
	var l: Lanzable = Utilidades.lanzar(jugador, bote, base + Vector3(0, 1.5, 0), fwd * 6.0, jugador)
	l.set_physics_process(false)
	var pasos: int = 0
	while is_instance_valid(l) and not l.activada and pasos < 300:
		l.avanzar(DT)
		pasos += 1
	comprobar("a9c) el bote lanzado se rompe al chocar con el suelo (antes de acabar su mecha)", pasos < 200 and pasos > 3,
			"pasos=%d" % pasos)
	jugador.salud.equipo = 0
	limpiar_extra()


# ---------------------------------------------------------------- a10
func _test_fuego_amigo() -> void:
	var pistola: ArmaDatos = Catalogo.arma(&"pistola_9mm")
	jugador.salud.equipo = 1
	jugador.salud.reiniciar()
	var lado: Vector3 = fwd.cross(Vector3.UP).normalized()
	var base_d: Vector3 = base + fwd * 12.0 - lado * 10.0
	var aliado: Diana = nueva_diana(base_d - lado * 1.5, 1)
	var enemigo: Diana = nueva_diana(base_d + lado * 1.5, 2)
	await esperar_fisica(3)
	var origen: Vector3 = jugador.camara.global_position
	var r1: Dictionary = Balistica.resolver_disparo(origen, (aliado.centro("torso") - origen).normalized(), pistola, jugador, rng)
	Balistica.aplicar(r1, pistola, jugador)
	var r2: Dictionary = Balistica.resolver_disparo(origen, (enemigo.centro("torso") - origen).normalized(), pistola, jugador, rng)
	Balistica.aplicar(r2, pistola, jugador)
	var f1: bool = aliado.salud.vida == 100.0 and enemigo.salud.vida < 100.0
	Salud.fuego_amigo = true
	Balistica.aplicar(r1, pistola, jugador)
	var f2: bool = aliado.salud.vida < 100.0
	Salud.fuego_amigo = false
	comprobar("a10a) sin fuego amigo por defecto (el companero no recibe dano, el enemigo si); activable por configuracion",
			f1 and f2 and not Salud.fuego_amigo)
	_restaurar(aliado)
	_restaurar(enemigo)
	var traca: ArmaDatos = Catalogo.arma(&"lanzacohetes")
	var c: Vector3 = (aliado.global_position + enemigo.global_position) * 0.5 + Vector3(0, 1.15, 0)
	var muerto_jugador: Array[int] = [0]
	# el jugador se pone junto a la explosion
	jugador.global_position = Vector3(c.x, suelo(c), c.z) + fwd * 1.5
	jugador.salud.reiniciar()
	await esperar_fisica(2)
	Balistica.aplicar_explosion(c, traca, jugador, jugador)
	comprobar("a10b) explosivo propio: el companero no recibe dano, el enemigo si, y el lanzador se hace autodano",
			aliado.salud.vida == 100.0 and enemigo.salud.vida < 100.0 and jugador.salud.vida < 100.0,
			"aliado=%.0f enemigo=%.0f yo=%.0f" % [aliado.salud.vida, enemigo.salud.vida, jugador.salud.vida])
	# senal muerto(atacante, arma) y bus de bajas
	var recibido: Array = [null, null]
	var bajas: Array[int] = [0]
	enemigo.salud.muerto.connect(func(a: Node, w: ArmaDatos) -> void: recibido[0] = a; recibido[1] = w)
	SenalesCombate.obtener(self).baja.connect(func(_a: Node, _v: Salud, _w: ArmaDatos) -> void: bajas[0] += 1)
	_restaurar(enemigo)
	enemigo.salud.recibir_dano(500.0, "torso", 1.0, jugador, pistola)
	comprobar("a10c) Salud.muerto lleva (atacante, arma) y el bus de bajas lo anuncia para el kill feed",
			recibido[0] == jugador and recibido[1] == pistola and bajas[0] == 1)
	jugador.global_position = base
	jugador.velocity = Vector3.ZERO
	jugador.salud.equipo = 0
	jugador.salud.reiniciar()
	limpiar_extra()


# ---------------------------------------------------------------- a11
func _test_apuntar_correr() -> void:
	gestor.reiniciar()
	avanzar_gestor(gestor, 1.5)
	gestor.cambiar_arma(0)
	avanzar_gestor(gestor, 1.0)
	var fusil: ArmaDatos = gestor.actual()
	jugador.corriendo = false
	var d0: float = gestor.dispersion_actual()
	var fov0: float = jugador.camara.fov
	gestor.gatillo_alt = true
	avanzar_gestor(gestor, 0.5)
	var d1: float = gestor.dispersion_actual()
	comprobar("a11a) apuntar (clic derecho) reduce la dispersion, el FOV y la velocidad",
			gestor.apuntando and d1 < d0 * 0.6 and jugador.camara.fov < fov0 - 5.0 and jugador.mult_velocidad_estado < 0.9,
			"disp %.3f -> %.3f  fov %.1f -> %.1f  vel x%.2f" % [d0, d1, fov0, jugador.camara.fov, jugador.mult_velocidad_estado])
	gestor.gatillo_alt = false
	avanzar_gestor(gestor, 0.5)
	comprobar("a11b) al soltar el clic derecho vuelve todo", not gestor.apuntando and cerca(jugador.camara.fov, fov0, 0.5))
	# fusil de precision: zoom fuerte y mira
	gestor.equipar(&"fusil_precision")
	avanzar_gestor(gestor, 1.5)
	var sin_apuntar: float = gestor.dispersion_actual()
	gestor.gatillo_alt = true
	avanzar_gestor(gestor, 0.8)
	var apuntando: float = gestor.dispersion_actual()
	var pr: ArmaDatos = gestor.actual()
	var suelo_sin: float = Balistica.dispersion(pr, 0.0, true, false, 0.0)
	var suelo_apuntando: float = Balistica.dispersion(pr, 0.0, true, false, 1.0)
	comprobar("a11c) fusil de precision: muy impreciso sin apuntar (3,5 grados) y preciso con zoom fuerte (FOV < 25)",
			suelo_sin > 3.0 and suelo_apuntando < 0.1 and apuntando < sin_apuntar * 0.05 and jugador.camara.fov < 25.0
			and pr.mira_zoom and pr.zoom >= 4.0,
			"suelo %.2f -> %.3f  (en el aire %.2f -> %.3f) fov=%.1f" % [suelo_sin, suelo_apuntando, sin_apuntar, apuntando, jugador.camara.fov])
	gestor.gatillo_alt = false
	avanzar_gestor(gestor, 0.8)
	gestor.reiniciar()
	avanzar_gestor(gestor, 1.5)
	# correr: no se puede disparar y hay una breve demora al dejar de correr
	gestor.cambiar_arma(0)
	avanzar_gestor(gestor, 1.0)
	var antes: int = gestor.disparos_totales
	jugador.corriendo = true
	gestor.gatillo = true
	avanzar_gestor(gestor, 0.5)
	var corriendo_disparos: int = gestor.disparos_totales - antes
	jugador.corriendo = false
	avanzar_gestor(gestor, 0.1)
	var en_demora: int = gestor.disparos_totales - antes
	avanzar_gestor(gestor, 0.4)
	var despues: int = gestor.disparos_totales - antes
	gestor.gatillo = false
	gestor.avanzar(DT)
	comprobar("a11d) correr impide disparar; tras dejar de correr hay una breve demora (0,25 s) y luego dispara",
			corriendo_disparos == 0 and en_demora == 0 and despues > 0, "corriendo=%d demora=%d despues=%d" % [corriendo_disparos, en_demora, despues])
	# velocidades
	jugador.corriendo = false
	jugador.quiere_sigilo = false
	jugador.agachado = false
	jugador.mult_velocidad_estado = 1.0
	var andar: float = jugador.velocidad_objetivo()
	jugador.corriendo = true
	var correr: float = jugador.velocidad_objetivo()
	jugador.corriendo = false
	jugador.quiere_sigilo = true
	var sigilo: float = jugador.velocidad_objetivo()
	jugador.quiere_sigilo = false
	jugador.agachado = true
	var agachado: float = jugador.velocidad_objetivo()
	jugador.agachado = false
	var m: float = jugador.mult_velocidad_arma
	comprobar("a11e) correr (6,5 m/s) es mas rapido que andar (5); sigilo (Alt) 2,6 y agachado (Ctrl) 1,7",
			correr > andar and cerca(correr / m, 6.5, 0.01) and cerca(andar / m, 5.0, 0.01) and cerca(sigilo / m, 2.6, 0.01)
			and cerca(agachado / m, 1.7, 0.01), "andar=%.2f correr=%.2f sigilo=%.2f agachado=%.2f" % [andar, correr, sigilo, agachado])
	# una ametralladora ligera se mueve mas lento que un fusil
	var am: ArmaDatos = Catalogo.arma(&"ametralladora")
	comprobar("a11f) la ametralladora es muy lenta de mover y de recargar", am.velocidad_mov <= 0.75 and am.tiempo_recarga >= 5.0
			and am.cargador >= 100 and fusil.velocidad_mov > am.velocidad_mov)


# ---------------------------------------------------------------- a12 (carga, puño, utilidades en mano)
func _test_carga_y_utilidades() -> void:
	gestor.reiniciar()
	avanzar_gestor(gestor, 1.5)
	jugador.camara.rotation = Vector3.ZERO
	# arco: carga mantenida y suelta; un toque rapido no dispara
	gestor.equipar(&"arco_olivo")
	avanzar_gestor(gestor, 1.5)
	var n0: int = get_nodes_in_group("proyectiles").size()
	var cargador0: int = gestor.municion_cargador()
	gestor.gatillo = true
	avanzar_gestor(gestor, 0.05)
	gestor.gatillo = false
	avanzar_gestor(gestor, 0.1)
	var toque: int = get_nodes_in_group("proyectiles").size() - n0
	gestor.gatillo = true
	avanzar_gestor(gestor, 1.1)
	var carga_llena: float = gestor.carga
	gestor.gatillo = false
	gestor.avanzar(DT)
	var flechas: int = get_nodes_in_group("proyectiles").size() - n0
	comprobar("a12a) arco: un toque no dispara; mantener el clic carga (1 s) y al soltar sale una flecha",
			toque == 0 and carga_llena >= 0.99 and flechas == 1 and gestor.municion_cargador() == cargador0 - 1,
			"toque=%d carga=%.2f flechas=%d" % [toque, carga_llena, flechas])
	for p: Node in get_nodes_in_group("proyectiles"):
		p.queue_free()
	await process_frame
	# puño-bot: carga, dispara, vuelve a los 1,5 s
	gestor.equipar(&"puno_bot")
	avanzar_gestor(gestor, 1.5)
	gestor.gatillo = true
	avanzar_gestor(gestor, 0.9)
	gestor.gatillo = false
	gestor.avanzar(DT)
	var en_vuelo: bool = gestor.puno_en_vuelo
	avanzar_gestor(gestor, 1.0)
	var aun_vuelo: bool = gestor.puno_en_vuelo
	avanzar_gestor(gestor, 0.6)
	comprobar("a12b) Puño-Bot: se carga, sale el puño y vuelve a la mano a los ~1,5 s (sin municion)",
			en_vuelo and aun_vuelo and not gestor.puno_en_vuelo and Catalogo.arma(&"puno_bot").cargador == 0
			and Catalogo.hueco(&"puno_bot") == &"secundaria")
	for p: Node in get_nodes_in_group("proyectiles"):
		p.queue_free()
	await process_frame
	# utilidades en mano: 4 cicla, el lanzamiento gasta una unidad y la mecha de la granada explosiva (2 s) hiere
	gestor.reiniciar()
	avanzar_gestor(gestor, 1.5)
	gestor.equipar(&"granada_explosiva")
	gestor.equipar(&"granada_humo")
	gestor.cambiar_arma(3)
	var primera: StringName = gestor.id_actual()
	gestor.cambiar_arma(3)
	var segunda: StringName = gestor.id_actual()
	avanzar_gestor(gestor, 1.0)
	gestor.cambiar_arma(3)  # vuelve a la explosiva
	avanzar_gestor(gestor, 1.0)
	var lado: Vector3 = fwd.cross(Vector3.UP).normalized()
	var objetivo: Diana = nueva_diana(base + fwd * 9.0 - lado * 10.0)
	await esperar_fisica(3)
	# la lanzamos con el clic izquierdo (fuerte) hacia la diana: comprobamos mecha y que se consume
	jugador.camara.look_at(objetivo.centro("torso") + Vector3(0, 2.0, 0), Vector3.UP)
	gestor.gatillo = true
	gestor.avanzar(DT)
	gestor.gatillo = false
	gestor.avanzar(DT)
	var lanz: Array[Node] = get_nodes_in_group("lanzables")
	comprobar("a12c) la tecla 4 cicla entre utilidades, el lanzamiento consume una y crea la granada",
			primera != segunda and gestor.cargador_en(3) <= 1 and lanz.size() == 1,
			"%s -> %s, lanzables=%d" % [primera, segunda, lanz.size()])
	for l: Node in lanz:
		(l as Lanzable).global_position = objetivo.global_position + Vector3(1.0, 1.0, 0.0)
		(l as Lanzable).vel = Vector3.ZERO
		(l as Lanzable).en_reposo = true
		(l as Lanzable).set_physics_process(false)
		for i in int(2.1 / DT):
			(l as Lanzable).avanzar(DT)
	comprobar("a12d) la granada explosiva detona a los 2 s y hace dano en area", objetivo.salud.vida < 100.0,
			"vida=%.1f" % objetivo.salud.vida)
	# extintor: la nube empuja al jugador
	var ext: ArmaDatos = Catalogo.arma(&"extintor")
	var nube: NubeVision = NubeVision.crear(jugador, base + fwd * 1.0, ext.radio_efecto, ext.duracion_efecto, ext.empuje)
	jugador.velocity = Vector3.ZERO
	nube.avanzar(0.3)
	var empujado: float = jugador.velocity.length()
	var tapa: bool = nube.tapa(base + Vector3(0, 1.6, 0) - fwd * 3.0, base + Vector3(0, 1.6, 0) + fwd * 5.0)
	nube.avanzar(3.0)
	comprobar("a12e) extintor: nube de 3 s que tapa la vision y empuja", empujado > 1.0 and tapa and not nube.vigente()
			and ext.duracion_efecto == 3.0, "empuje=%.2f" % empujado)
	# altavoz: 6 s de pasos y disparos falsos como ruido para los bots
	var alt: ArmaDatos = Catalogo.arma(&"altavoz")
	var ruidos: Array[int] = [0]
	SenalesCombate.obtener(self).ruido.connect(func(_p: Vector3, _r: float, f: Node) -> void:
		if f is Altavoz:
			ruidos[0] += 1)
	var av: Altavoz = Altavoz.crear(jugador, base + fwd * 5.0, alt, jugador)
	av.set_physics_process(false)
	var n: int = 0
	while is_instance_valid(av) and av.t < alt.duracion_efecto and n < 1000:
		av.avanzar(DT)
		n += 1
	await process_frame
	comprobar("a12f) altavoz senuelo: 6 s de ruido (senal ruido del bus) y despues desaparece",
			alt.duracion_efecto == 6.0 and ruidos[0] >= 15 and get_nodes_in_group("altavoces").is_empty(), "ruidos=%d" % ruidos[0])
	jugador.velocity = Vector3.ZERO
	gestor.reiniciar()
	avanzar_gestor(gestor, 1.0)
	limpiar_extra()


# ---------------------------------------------------------------- a12 suelo
func _test_suelo() -> void:
	ArmaSuelo.limpiar_armas_suelo(self)
	gestor.kit_reaparicion = []
	gestor.reiniciar()
	avanzar_gestor(gestor, 1.0)
	gestor.equipar(&"subfusil_9mm")
	gestor.equipar(&"revolver_357")
	gestor.inventario.fijar_municion(&"subfusil_9mm", 17, 55)
	gestor.inventario.fijar_municion(&"revolver_357", 3, 12)
	# morir: se sueltan la principal y la secundaria compradas (la Pistola 9 mm gratuita no)
	jugador.salud.recibir_dano(9999.0, "torso", 1.0, null)
	await esperar_fisica(40)
	var armas: Array[Node] = get_nodes_in_group("armas_suelo")
	var ids: Array[StringName] = []
	var quietas: bool = true
	for a: Node in armas:
		ids.append((a as ArmaSuelo).arma_id)
		quietas = quietas and (a as ArmaSuelo).quieta
	ids.sort()
	comprobar("a12a) al morir se sueltan la principal y la secundaria compradas (no la Pistola 9 mm), caen y quedan quietas",
			ids == [&"revolver_357", &"subfusil_9mm"] and quietas and gestor.inventario.principal == &"" and
			gestor.inventario.secundaria == &"pistola_9mm", "ids=%s quietas=%s" % [str(ids), quietas])
	var sub: ArmaSuelo = null
	var rev: ArmaSuelo = null
	for a: Node in armas:
		if (a as ArmaSuelo).arma_id == &"subfusil_9mm":
			sub = a as ArmaSuelo
		else:
			rev = a as ArmaSuelo
	comprobar("a12b) las armas del suelo conservan su municion", sub != null and sub.cargador == 17 and sub.reserva == 55
			and rev != null and rev.cargador == 3 and rev.reserva == 12)
	await esperar_fisica(110)  # el jugador reaparece
	comprobar("a12c) al reaparecer solo tiene lo gratuito", not jugador.muerto and gestor.inventario.principal == &"" and
			gestor.inventario.secundaria == &"pistola_9mm")
	# otro jugador las recoge con E (conserva la municion)
	var j2: Jugador = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Jugador
	main.add_child(j2)
	extra.append(j2)
	await esperar_fisica(2)
	j2.activo = false
	j2.entrada_manual = true
	j2.gestor.entrada_manual = true
	j2.gestor.kit_reaparicion = []
	j2.gestor.reiniciar()
	j2.global_position = sub.global_position + Vector3(1.2, 0.0, 0.0)
	j2.camara.look_at(sub.global_position, Vector3.UP)
	await esperar_fisica(2)
	var mirada: ArmaSuelo = j2.gestor.arma_mirada()
	var tira_pistola: bool = j2.gestor.tirar_arma()  # indice 0 = principal vacia -> no hay nada que tirar
	j2.gestor.cambiar_arma(1)
	var tira_pistola2: bool = j2.gestor.tirar_arma()
	j2.gestor.equipar(&"fusil_asalto")
	var recogida: bool = j2.gestor.recoger()
	var inv2: Inventario = j2.gestor.inventario
	comprobar("a12d) E recoge el arma mirada: cambia por la del mismo hueco (el fusil cae al suelo) y conserva la municion",
			mirada == sub and recogida and inv2.principal == &"subfusil_9mm" and inv2.cargador(&"subfusil_9mm") == 17
			and inv2.reserva(&"subfusil_9mm") == 55 and not tira_pistola and not tira_pistola2,
			"mirada_ok=%s recogida=%s principal=%s" % [mirada == sub, recogida, inv2.principal])
	await esperar_fisica(40)
	var fusil_suelo: bool = false
	for a: Node in get_nodes_in_group("armas_suelo"):
		if (a as ArmaSuelo).arma_id == &"fusil_asalto" and (a as ArmaSuelo).cargador == 30:
			fusil_suelo = true
	comprobar("a12e) el arma sustituida cae al suelo y se puede recoger (con su municion)", fusil_suelo)
	j2.global_position = rev.global_position + Vector3(0.8, 0.0, 0.0)
	j2.camara.look_at(rev.global_position, Vector3.UP)
	await esperar_fisica(2)
	var recogida2: bool = j2.gestor.recoger()
	comprobar("a12f) la secundaria del suelo se recoge tambien con su municion (revolver 3/12)",
			recogida2 and inv2.secundaria == &"revolver_357" and inv2.cargador(&"revolver_357") == 3 and inv2.reserva(&"revolver_357") == 12)
	# G tira el arma en mano
	j2.gestor.cambiar_arma(0)
	avanzar_gestor(j2.gestor, 1.0)
	var n_antes: int = get_nodes_in_group("armas_suelo").size()
	var tirada: bool = j2.gestor.tirar_arma()
	await esperar_fisica(40)
	var tirada_ok: bool = false
	for a: Node in get_nodes_in_group("armas_suelo"):
		if (a as ArmaSuelo).arma_id == &"subfusil_9mm" and (a as ArmaSuelo).cargador == 17 and (a as ArmaSuelo).quieta:
			tirada_ok = true
	comprobar("a12g) G tira el arma en mano al suelo (con su municion) y pasa a otra arma",
			tirada and tirada_ok and inv2.principal == &"" and j2.gestor.indice != 0
			and get_nodes_in_group("armas_suelo").size() == n_antes + 1)
	# fin de ronda: limpiar_armas_suelo()
	var n_limpiadas: int = j2.gestor.limpiar_armas_suelo()
	await process_frame
	comprobar("a12h) limpiar_armas_suelo() quita todas las armas del suelo (API para P4)", n_limpiadas >= 2
			and get_nodes_in_group("armas_suelo").is_empty(), "limpiadas=%d" % n_limpiadas)
	gestor.kit_reaparicion = [&"fusil_asalto"]
	gestor.reiniciar()
	limpiar_extra()
