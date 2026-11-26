extends SceneTree
## Test headless del combate (fase 4a). Uso:
##   Godot_console.exe --headless --path game --script res://tests/test_combate.gd
## Imprime PASS/FAIL por comprobacion y sale con codigo 0 (todo bien) o 1.
## Usa el campo de practica real (dianas a 10/20/35/50 m) con RNG fijo y dispersion 0 salvo donde se pide lo contrario.

const FUSIL: ArmaDatos = preload("res://data/armas/fusil_r7.tres")
const PISTOLA: ArmaDatos = preload("res://data/armas/pistola_p9.tres")
const NAVAJA: ArmaDatos = preload("res://data/armas/navaja.tres")
const DT: float = 1.0 / 60.0

var fallos: int = 0
var main: Node
var jugador: Jugador
var gestor: GestorArmas
var campo: CampoPractica
var rng := RandomNumberGenerator.new()


func comprobar(nombre: String, ok: bool, detalle: String = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", nombre, detalle])
	if not ok:
		fallos += 1


func cerca(a: float, b: float, tol: float = 0.05) -> bool:
	return absf(a - b) <= tol


func esperar_fisica(n: int) -> void:
	for i in n:
		await physics_frame


## Tira desde la camara del jugador hacia `objetivo` con dispersion 0 y aplica el dano.
func tirar(arma: ArmaDatos, objetivo: Vector3, aplicar: bool = true, disp: float = 0.0) -> Dictionary:
	var origen: Vector3 = jugador.camara.global_position
	var res: Dictionary = Balistica.resolver_disparo(origen, (objetivo - origen).normalized(), arma, jugador, rng, disp)
	if aplicar:
		Balistica.aplicar(res, arma, jugador)
	return res


func restaurar(d: Diana) -> void:
	d.muerta = false
	d.caida.rotation.x = 0.0
	d.salud.reiniciar()
	d.hitboxes.activar(true)


func avanzar_gestor(segundos: float) -> void:
	var n: int = int(round(segundos / DT))
	for i in n:
		gestor.avanzar(DT)


func angulo_medio(arma: ArmaDatos, grados: float, n: int) -> float:
	var r := RandomNumberGenerator.new()
	r.seed = 99
	var suma: float = 0.0
	for i in n:
		var d: Vector3 = Balistica.aplicar_dispersion(Vector3.FORWARD, grados, r)
		suma += rad_to_deg(Vector3.FORWARD.angle_to(d))
	return suma / n


func _init() -> void:
	_ejecutar.call_deferred()


func _ejecutar() -> void:
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
	comprobar("c0) el campo de practica tiene 8 dianas (3 con armadura 100)",
			campo.dianas.size() == 8 and campo.dianas.filter(func(d: Diana) -> bool: return d.armadura == 100.0).size() == 3,
			"dianas=%d" % campo.dianas.size())
	var sp: Dictionary = {}
	for s: Dictionary in main.spawns:
		if s["id"] == "campo_practica":
			sp = s
	comprobar("c0b) spawns.json tiene el spawn campo_practica", not sp.is_empty())
	main._colocar(sp)
	jugador.activo = false
	gestor.entrada_manual = true
	gestor.auto_recargar = false
	gestor.rng.seed = 12345
	rng.seed = 777
	await esperar_fisica(3)
	avanzar_gestor(1.0)  # termina el cambio de arma inicial

	# ---- datos de las armas
	comprobar("d1) Fusil R-7: automatico, ~10 disp/s, cargador 30, dano 33",
			FUSIL.automatica and cerca(FUSIL.cadencia, 10.0, 0.5) and FUSIL.cargador == 30 and FUSIL.dano_base == 33.0
			and FUSIL.mult_cabeza == 4.0 and FUSIL.mult_torso == 1.0 and FUSIL.mult_piernas == 0.75)
	comprobar("d2) Pistola P-9: semiautomatica, cargador 12, dano 28",
			not PISTOLA.automatica and PISTOLA.cargador == 12 and PISTOLA.dano_base == 28.0)
	comprobar("d3) Navaja: cuerpo a cuerpo, 2 m, dano 40 / fuerte 65",
			NAVAJA.cuerpo_a_cuerpo and NAVAJA.alcance == 2.0 and NAVAJA.dano_base == 40.0 and NAVAJA.dano_fuerte == 65.0)
	comprobar("d4) la capsula de movimiento no esta en la mascara de disparo",
			(jugador.collision_layer & Balistica.MASCARA_DISPARO) == 0)

	# ---- c1: dano por zona y armadura
	var d10: Diana = campo.dianas[0]
	var d10b: Diana = campo.dianas[1]
	var res: Dictionary = tirar(FUSIL, d10.centro("torso"))
	comprobar("c1a) fusil a 10 m al torso hace 33", res["zona"] == "torso" and cerca(res["daño"], 33.0)
			and cerca(d10.salud.vida, 67.0), "zona=%s dano=%.2f vida=%.1f dist=%.2f" % [
			res["zona"], res["daño"], d10.salud.vida, res["distancia"]])
	restaurar(d10)
	res = tirar(FUSIL, d10.centro("cabeza"))
	comprobar("c1b) a la cabeza x4 (132) y mata", res["zona"] == "cabeza" and cerca(res["daño"], 132.0)
			and not d10.salud.vivo, "dano=%.2f vivo=%s" % [res["daño"], d10.salud.vivo])
	restaurar(d10)
	res = tirar(FUSIL, d10.centro("piernas"))
	comprobar("c1c) a las piernas x0,75 (24,75)", res["zona"] == "piernas" and cerca(res["daño"], 24.75),
			"dano=%.2f" % res["daño"])
	restaurar(d10)
	d10b.salud.armadura = 100.0
	res = tirar(FUSIL, d10b.centro("torso"))
	var vida_perdida: float = 100.0 - d10b.salud.vida
	comprobar("c1d) con armadura 100 llega menos dano a la vida (33 x 0,7 = 23,1) y la armadura baja",
			cerca(vida_perdida, 23.1) and vida_perdida < 33.0 and cerca(d10b.salud.armadura, 100.0 - 33.0 * 0.3 * 0.5),
			"vida_perdida=%.2f armadura=%.2f" % [vida_perdida, d10b.salud.armadura])
	restaurar(d10b)
	d10b.salud.armadura = 100.0
	var pen: float = PISTOLA.penetracion_armadura
	d10b.salud.recibir_dano(28.0, "torso", pen, null)
	comprobar("c1e) la penetracion depende del arma (pistola 0,5: 14 a la vida)", cerca(100.0 - d10b.salud.vida, 14.0),
			"vida_perdida=%.2f" % (100.0 - d10b.salud.vida))
	restaurar(d10b)

	# ---- c2: caida de dano a 50 m
	var d50: Diana = campo.dianas[7]
	res = tirar(FUSIL, d50.centro("torso"))
	var esperado: float = 33.0 * (1.0 - 0.45 * ((float(res["distancia"]) - 30.0) / 120.0))
	comprobar("c2a) a 50 m el dano cae (~30,5) y es menor que a 10 m", float(res["daño"]) < 33.0
			and cerca(res["daño"], 30.525, 0.4) and cerca(res["daño"], esperado, 0.01),
			"dist=%.2f dano=%.2f" % [res["distancia"], res["daño"]])
	restaurar(d50)
	comprobar("c2b) calcular_dano: 30 m = 33; alcance = 33 x 0,55; la cabeza a 50 m x4",
			cerca(Balistica.calcular_dano(FUSIL, "torso", 30.0), 33.0)
			and cerca(Balistica.calcular_dano(FUSIL, "torso", 150.0), 33.0 * 0.55)
			and cerca(Balistica.calcular_dano(FUSIL, "cabeza", 50.0), 4.0 * 30.525, 0.2))
	var lejos: Dictionary = Balistica.resolver_disparo(jugador.camara.global_position,
			(d50.centro("torso") - jugador.camara.global_position).normalized(), NAVAJA, jugador, rng)
	comprobar("c2c) la navaja (2 m) no llega a una diana a 50 m", not lejos["impacto"] or lejos["salud"] == null)

	# ---- c3: cargador, sin municion y recarga
	gestor.reiniciar()
	avanzar_gestor(1.0)
	gestor.cambiar_arma(0)
	jugador.camara.look_at(jugador.camara.global_position + Vector3(0, 1, -1), Vector3.UP)  # al cielo
	var antes: int = gestor.disparos_totales
	var cuenta_vacio: Array[int] = [0]
	gestor.sin_municion.connect(func() -> void: cuenta_vacio[0] += 1)
	gestor.gatillo = true
	gestor.avanzar(DT)
	comprobar("c3a) un disparo baja el cargador en 1 (30 -> 29)", gestor.municion_cargador() == 29
			and gestor.disparos_totales == antes + 1, "cargador=%d" % gestor.municion_cargador())
	var guardia: int = 0
	while gestor.municion_cargador() > 0 and guardia < 600:
		gestor.avanzar(DT)
		guardia += 1
	var disparos_hasta_vacio: int = gestor.disparos_totales - antes
	gestor.avanzar(DT)
	gestor.avanzar(DT)
	avanzar_gestor(0.5)
	comprobar("c3b) vacia el cargador con 30 disparos y no dispara a 0", gestor.municion_cargador() == 0
			and disparos_hasta_vacio == 30 and gestor.disparos_totales == antes + 30,
			"disparos=%d cargador=%d" % [disparos_hasta_vacio, gestor.municion_cargador()])
	gestor.gatillo = false
	gestor.avanzar(DT)
	gestor.gatillo = true
	gestor.avanzar(DT)
	comprobar("c3c) con el cargador vacio suena el clic (senal sin_municion) y no sale bala",
			cuenta_vacio[0] >= 1 and gestor.disparos_totales == antes + 30, "clics=%d" % cuenta_vacio[0])
	gestor.gatillo = false
	gestor.avanzar(DT)
	gestor.recargar()
	var t_rec: float = FUSIL.tiempo_recarga
	avanzar_gestor(t_rec - 0.2)
	var a_medias: bool = gestor.recargando and gestor.municion_cargador() == 0
	avanzar_gestor(0.4)
	comprobar("c3d) la recarga repone el cargador (30) y gasta reserva (90 -> 60) en %.1f s" % t_rec,
			a_medias and not gestor.recargando and gestor.municion_cargador() == 30 and gestor.municion_reserva() == 60,
			"cargador=%d reserva=%d" % [gestor.municion_cargador(), gestor.municion_reserva()])
	# recarga interrumpida al cambiar de arma
	gestor.cargadores[0] = 10
	gestor.recargar()
	avanzar_gestor(0.5)
	gestor.cambiar_arma(1)
	avanzar_gestor(t_rec)
	comprobar("c3e) cambiar de arma cancela la recarga", not gestor.recargando and gestor.cargadores[0] == 10
			and gestor.indice == 1, "cargador fusil=%d" % gestor.cargadores[0])
	gestor.cambiar_arma(gestor.indice_previo)
	comprobar("c3f) 'ultima arma' (Q) vuelve al fusil y fija su velocidad de movimiento",
			gestor.indice == 0 and cerca(jugador.mult_velocidad_arma, FUSIL.velocidad_mov))
	avanzar_gestor(1.0)

	# ---- c4: cadencia
	gestor.reiniciar()
	avanzar_gestor(1.0)
	gestor.gatillo = false
	gestor.avanzar(DT)
	antes = gestor.disparos_totales
	gestor.gatillo = true
	avanzar_gestor(1.0)
	var n_seg: int = gestor.disparos_totales - antes
	comprobar("c4a) fuego automatico: en 1 s salen 10 +-1 disparos", absi(n_seg - 10) <= 1, "disparos=%d" % n_seg)
	gestor.gatillo = false
	avanzar_gestor(1.0)
	# pistola semiautomatica: mantener el gatillo = 1 disparo
	gestor.cambiar_arma(1)
	avanzar_gestor(1.0)
	antes = gestor.disparos_totales
	gestor.gatillo = true
	avanzar_gestor(1.0)
	comprobar("c4b) pistola semiautomatica: con el gatillo mantenido solo sale 1 disparo",
			gestor.disparos_totales - antes == 1, "disparos=%d" % (gestor.disparos_totales - antes))
	gestor.gatillo = false
	gestor.avanzar(DT)
	gestor.gatillo = true
	gestor.avanzar(DT)
	gestor.gatillo = false
	gestor.avanzar(DT)
	gestor.gatillo = true
	avanzar_gestor(0.05)
	gestor.gatillo = false
	comprobar("c4c) pistola: pulsar de nuevo dispara solo si ha pasado el intervalo (6 disp/s)",
			gestor.disparos_totales - antes == 2, "disparos=%d" % (gestor.disparos_totales - antes))
	gestor.cambiar_arma(0)
	avanzar_gestor(1.0)

	# ---- c5: el mundo bloquea
	var o: Vector3 = jugador.camara.global_position
	var obj: Vector3 = d10.centro("torso")
	var muro := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var caja := BoxShape3D.new()
	caja.size = Vector3(8.0, 8.0, 0.3)
	cs.shape = caja
	muro.add_child(cs)
	root.add_child(muro)
	muro.global_position = o + (obj - o).normalized() * 5.0
	muro.look_at(obj, Vector3.UP)
	await esperar_fisica(3)
	res = tirar(FUSIL, obj)
	comprobar("c5a) una pared delante de la diana bloquea el disparo: sin dano",
			res["impacto"] and res["collider"] == muro and float(res["daño"]) == 0.0 and d10.salud.vida == 100.0
			and res["zona"] == "", "collider=%s vida=%.1f" % [str(res["collider"]), d10.salud.vida])
	muro.queue_free()
	await esperar_fisica(3)
	res = tirar(FUSIL, obj)
	comprobar("c5b) sin la pared el mismo disparo hace dano", float(res["daño"]) > 0.0 and d10.salud.vida < 100.0)
	restaurar(d10)

	# ---- c6: dispersion
	var quieto: float = Balistica.dispersion(FUSIL, 0.0, true, false)
	var movi: float = Balistica.dispersion(FUSIL, 5.0, true, false)
	var aire: float = Balistica.dispersion(FUSIL, 0.0, false, false)
	var agach: float = Balistica.dispersion(FUSIL, 0.0, true, true)
	comprobar("c6a) dispersion: agachado < quieto < movimiento < aire", agach < quieto and quieto < movi and movi < aire,
			"agachado=%.2f quieto=%.2f mov=%.2f aire=%.2f" % [agach, quieto, movi, aire])
	comprobar("c6b) la dispersion crece con la velocidad", Balistica.dispersion(FUSIL, 2.0, true, false) > quieto
			and Balistica.dispersion(FUSIL, 2.0, true, false) < movi)
	var m_q: float = angulo_medio(FUSIL, quieto, 400)
	var m_m: float = angulo_medio(FUSIL, movi, 400)
	var m_a: float = angulo_medio(FUSIL, aire, 400)
	comprobar("c6c) los disparos reales se abren mas: quieto < movimiento < aire (desvio medio)",
			m_q < m_m and m_m < m_a, "quieto=%.2f mov=%.2f aire=%.2f grados" % [m_q, m_m, m_a])
	var r1 := RandomNumberGenerator.new()
	var r2 := RandomNumberGenerator.new()
	r1.seed = 5
	r2.seed = 5
	var da: Vector3 = Balistica.aplicar_dispersion(Vector3.FORWARD, 3.0, r1)
	var db: Vector3 = Balistica.aplicar_dispersion(Vector3.FORWARD, 3.0, r2)
	comprobar("c6d) con la misma semilla el disparo disperso es identico (determinista)", da == db
			and rad_to_deg(Vector3.FORWARD.angle_to(da)) <= 3.0 + 0.001)
	gestor.cambiar_arma(2)
	comprobar("c6e) el gestor da dispersion 0 con la navaja", cerca(gestor.dispersion_actual(), 0.0))
	gestor.cambiar_arma(0)

	# ---- c7: la diana muere a los disparos esperados y reaparece
	var n_disp: int = 0
	while d10.salud.vivo and n_disp < 20:
		tirar(FUSIL, d10.centro("torso"))
		n_disp += 1
	comprobar("c7a) 100 de vida / 33 por tiro al torso = 4 disparos", n_disp == 4 and d10.muerta,
			"disparos=%d vida=%.1f" % [n_disp, d10.salud.vida])
	await esperar_fisica(2)
	res = tirar(FUSIL, d10.centro("torso"), false)
	comprobar("c7b) una diana muerta no frena las balas (hitboxes desactivadas)", res["salud"] != d10.salud)
	d10.avanzar(0.5)
	comprobar("c7c) la diana cae (90 grados)", cerca(d10.caida.rotation.x, deg_to_rad(90.0), 0.01))
	d10.avanzar(2.3)
	var sigue_muerta: bool = d10.muerta
	d10.avanzar(0.3)
	await esperar_fisica(2)
	comprobar("c7d) reaparece a los 3 s con la vida completa", sigue_muerta and not d10.muerta
			and d10.salud.vida == 100.0 and cerca(d10.caida.rotation.x, 0.0, 0.001))
	res = tirar(FUSIL, d10.centro("torso"), false)
	comprobar("c7e) tras reaparecer vuelve a recibir impactos", res["salud"] == d10.salud)
	# 3 s reales de fisica (la diana avanza sola en _physics_process)
	d10.salud.recibir_dano(500.0, "torso", 1.0, null)
	await esperar_fisica(185)
	comprobar("c7f) la diana reaparece sola tras 3 s de fisica", not d10.muerta and d10.salud.vida == 100.0)
	var cuerpo_c: Array[bool] = [false]
	d10.salud.herido.connect(func(_c: float, _z: String, _a: Node) -> void: cuerpo_c[0] = true)
	tirar(FUSIL, d10.centro("torso"))
	var etiquetas: int = d10.find_children("*", "Label3D", false, false).size()
	comprobar("c7g) muestra un numero de dano flotante", cuerpo_c[0] and etiquetas >= 1, "etiquetas=%d" % etiquetas)
	restaurar(d10)

	# ---- c10: navaja
	var dn := Diana.new()
	main.add_child(dn)
	var fwd: Vector3 = -jugador.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	dn.global_position = Vector3(o.x, jugador.global_position.y, o.z) + fwd * 1.5
	await esperar_fisica(3)
	gestor.cambiar_arma(2)
	avanzar_gestor(1.0)
	jugador.camara.look_at(dn.centro("torso"), Vector3.UP)
	gestor.gatillo = true
	gestor.avanzar(DT)
	gestor.gatillo = false
	gestor.avanzar(DT)
	comprobar("c10a) navaja: ataque ligero a 1,5 m hace 40", cerca(dn.salud.vida, 60.0), "vida=%.1f" % dn.salud.vida)
	restaurar(dn)
	avanzar_gestor(1.5)
	gestor.gatillo_alt = true
	gestor.avanzar(DT)
	gestor.gatillo_alt = false
	gestor.avanzar(DT)
	comprobar("c10b) navaja: ataque fuerte (clic derecho) hace 65", cerca(dn.salud.vida, 35.0), "vida=%.1f" % dn.salud.vida)
	dn.queue_free()
	gestor.cambiar_arma(0)
	avanzar_gestor(1.0)

	# ---- c9: marcas de impacto en pool
	var ef: EfectosCombate = main.efectos
	jugador.camara.look_at(jugador.camara.global_position + Vector3(0.3, -1.0, -0.2), Vector3.UP)
	for i in 100:
		var r9: Dictionary = tirar(FUSIL, jugador.camara.global_position + Vector3(0.1 * (i % 7), -1.6, -2.0 - 0.1 * i), false)
		ef.mostrar_disparo(FUSIL, r9, jugador.camara.global_position)
	comprobar("c9) las marcas de impacto no pasan de 64 (pool)", ef.n_marcas() == 64, "marcas=%d" % ef.n_marcas())

	# ---- c8: el jugador recibe dano, muere y reaparece
	var tirador := Node3D.new()
	root.add_child(tirador)
	tirador.global_position = jugador.global_position + Vector3(7.0, 1.65, 0.0)
	await esperar_fisica(3)
	gestor.cargadores[0] = 5
	jugador.salud.armadura = 50.0
	var obj_j: Vector3 = jugador.hitboxes.centro_zona("torso")
	var r8: Dictionary = Balistica.resolver_disparo(tirador.global_position, (obj_j - tirador.global_position).normalized(),
			FUSIL, tirador, rng, 0.0)
	var herido_n: Array[float] = [0.0]
	jugador.salud.herido.connect(func(c: float, _z: String, _a: Node) -> void: herido_n[0] += c)
	Balistica.aplicar(r8, FUSIL, tirador)
	comprobar("c8a) el jugador recibe un disparo al torso (hitbox propia): pierde vida y armadura",
			r8["zona"] == "torso" and r8["salud"] == jugador.salud and jugador.salud.vida < 100.0
			and jugador.salud.armadura < 50.0 and herido_n[0] > 0.0,
			"vida=%.1f armadura=%.2f" % [jugador.salud.vida, jugador.salud.armadura])
	var pos_muerte: Vector3 = jugador.global_position
	var r8b: Dictionary = Balistica.resolver_disparo(tirador.global_position,
			(jugador.hitboxes.centro_zona("cabeza") - tirador.global_position).normalized(), FUSIL, tirador, rng, 0.0)
	Balistica.aplicar(r8b, FUSIL, tirador)
	comprobar("c8b) un disparo a la cabeza mata al jugador", r8b["zona"] == "cabeza" and jugador.muerto
			and not jugador.salud.vivo, "vida=%.1f" % jugador.salud.vida)
	await esperar_fisica(90)
	comprobar("c8c) sigue muerto a los 1,5 s (camara fija)", jugador.muerto)
	await esperar_fisica(40)
	comprobar("c8d) reaparece a los 2 s con vida 100, armadura 0 y municion llena",
			not jugador.muerto and jugador.salud.vida == 100.0 and jugador.salud.armadura == 0.0
			and gestor.cargadores[0] == 30 and gestor.reservas[0] == 90 and jugador.hitboxes.zonas["torso"].collision_layer == 2,
			"vida=%.1f armadura=%.1f cargador=%d" % [jugador.salud.vida, jugador.salud.armadura, gestor.cargadores[0]])
	var dxz: float = Vector2(jugador.global_position.x - sp["pos"][0], jugador.global_position.z - sp["pos"][2]).length()
	comprobar("c8e) reaparece en el spawn elegido (campo de practica)", dxz < 0.1, "distancia=%.3f m" % dxz)
	comprobar("c8f) la posicion de muerte era la del spawn (no se movio)", pos_muerte.distance_to(jugador.global_position) < 0.5)
	# K = suicidio (tecla de pruebas)
	jugador.activo = true
	var ev := InputEventAction.new()
	ev.action = "suicidio"
	ev.pressed = true
	Input.parse_input_event(ev)
	await process_frame
	await process_frame
	comprobar("c8g) la tecla K (accion suicidio) mata al jugador", jugador.muerto, "muerto=%s" % jugador.muerto)
	jugador.activo = false
	await esperar_fisica(130)
	comprobar("c8h) y reaparece", not jugador.muerto and jugador.salud.vida == 100.0)

	print("RESULTADO: %s (%d fallos)" % ["PASS" if fallos == 0 else "FAIL", fallos])
	main.queue_free()
	await process_frame
	quit(0 if fallos == 0 else 1)
