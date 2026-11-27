extends SceneTree
## Test headless de la Partida (paquete P4). Uso:
##   Godot_console.exe --headless --path game --script res://tests/test_partida.gd [-- rapido]
## Imprime PASS/FAIL por comprobacion y sale con codigo 0 (todo bien) o 1. Secciones:
##   p1 economia (config, derrotas consecutivas, tope, bajas)      p2 tienda: comprar, vender, sustituir, limites, fase
##   p3 inventario: se conserva al sobrevivir y se pierde al morir  p4 transiciones de fase y tiempos
##   p5 victorias: Cachimba montada + alarma, apagada, eliminaciones, tiempo (cachimba y eliminacion), Cachimba caida
##   p6 cambio de lado y fin de partida   p7 partida completa acelerada con bots (hasta que un equipo gana)
## Con `-- rapido` se salta la partida completa acelerada (p7).

const DT: float = 0.05

var fallos: int = 0
var main: Node3D
var rapido: bool = false
var informe: Array[String] = []


func comprobar(nombre: String, ok: bool, detalle: String = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", nombre, detalle])
	if not ok:
		fallos += 1


func esperar_fisica(n: int) -> void:
	for i in n:
		await physics_frame


func _init() -> void:
	_ejecutar.call_deferred()


func _ejecutar() -> void:
	rapido = OS.get_cmdline_user_args().has("rapido")
	_test_config()
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await esperar_fisica(6)
	main.menu.cerrar()
	var j: Jugador = main.get_node("Jugador")
	j.set_physics_process(false)
	j.gestor.set_physics_process(false)
	for d: Diana in main.campo.dianas:
		d.salud.vivo = false
		d.hitboxes.activar(false)
	await _test_tienda_e_inventario()
	await _test_economia_rondas()
	await _test_fases()
	await _test_victorias_cachimba()
	await _test_eliminacion()
	await _test_lados_y_fin()
	if not rapido:
		await _test_partida_completa()
	print("--- informe ---")
	for l: String in informe:
		print(l)
	print("RESULTADO: %s (%d fallos)" % ["PASS" if fallos == 0 else "FAIL", fallos])
	main.queue_free()
	await process_frame
	quit(0 if fallos == 0 else 1)


# ------------------------------------------------------------------ utilidades

func config_base(n: int = 2) -> ConfigPartida:
	var c := ConfigPartida.new()
	c.zona = "el_eje"
	c.jugadores_por_equipo = n
	c.semilla = 3
	return c


func a_fase(p: Partida, fase: int, max_s: float = 400.0) -> bool:
	var t: float = 0.0
	while p.fase != fase and t < max_s:
		p.avanzar(DT)
		t += DT
	return p.fase == fase


func a_ronda(p: Partida) -> bool:
	return a_fase(p, Partida.Fase.RONDA)


func matar(c: Node, por: Node = null) -> void:
	(Salud.de(c) as Salud).recibir_dano(9999.0, "torso", 1.0, por)


func lado_de_bots(m: Dictionary, lado: int) -> Array[Bot]:
	var out: Array[Bot] = []
	for b: Bot in m["bots"]:
		if b.equipo == lado:
			out.append(b)
	return out


# ------------------------------------------------------------------ p1: economia pura

func _test_config() -> void:
	var c := ConfigPartida.new()
	comprobar("p1a) valores por defecto del documento: 800 / 9000 / +200 / +3000", c.dinero_inicial == 800 and c.dinero_max == 9000 and c.por_baja == 200 and c.por_victoria == 3000)
	comprobar("p1b) montar +300 y alarma +300; tiempos 25 / 100 / 5 s", c.por_montar == 300 and c.por_alarma == 300 and c.t_compra == 25.0 and c.t_ronda == 100.0 and c.t_fin_ronda == 5.0)
	var rec: Array[int] = []
	for n in range(1, 7):
		rec.append(c.recompensa_derrota(n))
	comprobar("p1c) derrota: 1900, 2400, 2900 y tope 2900", rec == [1900, 2400, 2900, 2900, 2900, 2900], str(rec))
	comprobar("p1d) 7 de 12: 12 rondas normales y cambio de lado tras la 6", c.rondas_normales() == 12 and c.ronda_cambio_lado() == 6)
	c.rondas_ganar = 3
	comprobar("p1e) con 3 rondas para ganar: 4 rondas normales y cambio tras la 2", c.rondas_normales() == 4 and c.ronda_cambio_lado() == 2)
	comprobar("p1f) modo libre -> &libre; competitivo -> el submodo", ConfigPartida.new().modo_partida() == &"cachimba"
			and _libre().modo_partida() == &"libre")
	var nombres: Array[String] = []
	for m: Array in ConfigPartida.MODOS:
		nombres.append(str(m[1]))
	comprobar("p1g) modos del lobby: Modo libre / Cachimba Wars / Modo pleno", nombres == ["Modo libre", "Cachimba Wars", "Modo pleno"], str(nombres))
	var cm := ConfigPartida.new()
	cm.aplicar_modo(ConfigPartida.M_PLENO)
	var ok_pleno: bool = cm.modo_partida() == &"eliminacion" and cm.id_modo() == ConfigPartida.M_PLENO and cm.nombre_modo() == "Modo pleno"
	cm.aplicar_modo(ConfigPartida.M_CACHIMBA_WARS)
	var ok_cw: bool = cm.modo_partida() == &"cachimba" and cm.nombre_modo() == "Cachimba Wars"
	cm.aplicar_modo(ConfigPartida.M_LIBRE)
	comprobar("p1h) aplicar_modo traduce a modo/submodo internos (pleno = eliminacion, Cachimba Wars = cachimba)", ok_pleno and ok_cw and cm.es_libre() and cm.nombre_modo() == "Modo libre")
	var cd := ConfigPartida.new()
	cd.jugadores_por_equipo = 3
	cd.grupo_jugador = 1
	cd.semilla = 9
	var hs: Array = cd.huecos_efectivos()
	var humanos: int = 0
	var validos: bool = true
	for g in 2:
		for h: Dictionary in hs[g]:
			humanos += 1 if h["tipo"] == ConfigPartida.TIPO_HUMANO else 0
			validos = validos and CatalogoPersonajes.existe(StringName(h["personaje"]))
	var hs2: Array = cd.huecos_efectivos()
	comprobar("p1i) huecos deducidos: 3 por equipo, un humano local en su grupo, personajes validos y repetibles con la semilla",
			(hs[0] as Array).size() == 3 and (hs[1] as Array).size() == 3 and humanos == 1 and bool((hs[1][0] as Dictionary)["local"]) and validos and str(hs) == str(hs2))


func _libre() -> ConfigPartida:
	var c := ConfigPartida.new()
	c.modo = ConfigPartida.MODO_LIBRE
	return c


# ------------------------------------------------------------------ p2 y p3: tienda e inventario

func _test_tienda_e_inventario() -> void:
	var m: Dictionary = await MontajePartida.montar(main, config_base(2), false)
	var p: Partida = m["partida"]
	var j: Jugador = m["jugador"]
	var zona: ZonaActiva = m["zona"]
	p.iniciar_partida()
	await esperar_fisica(2)
	var inv: Inventario = j.gestor.inventario
	comprobar("p2a) arranca en la fase de compra de la ronda 1, 25 s, barreras activas, todos con 800", p.fase == Partida.Fase.COMPRA and p.ronda == 1
			and is_equal_approx(p.t_fase, 25.0) and zona.barreras_activas and p.dinero_de(j) == 800)
	comprobar("p2b) competitivo: solo pistola 9 mm + navaja (kit de reaparicion vacio)", inv.principal == &"" and inv.secundaria == &"pistola_9mm"
			and j.gestor.kit_reaparicion.is_empty())
	var cj := ComandosJugador.new(j, p)
	comprobar("p2c) no se compra lo que no llega (fusil 2900 con 800)", not cj.comprar(&"fusil_asalto") and p.dinero_de(j) == 800)
	comprobar("p2d) compra una pistola automatica (500): descuenta y equipa", cj.comprar(&"pistola_auto") and p.dinero_de(j) == 300 and inv.secundaria == &"pistola_auto")
	comprobar("p2e) devolverla da el reembolso completo y vuelve a la 9 mm", cj.vender(&"pistola_auto") and p.dinero_de(j) == 800 and inv.secundaria == &"pistola_9mm")
	var suelo0: int = get_nodes_in_group("armas_suelo").size()
	cj.comprar(&"pistola_auto")
	var ok_sust: bool = cj.comprar(&"revolver_357")
	comprobar("p2f) sustituir lo comprado en esta fase devuelve lo anterior (no cae al suelo): 800-700 = 100", ok_sust and p.dinero_de(j) == 100
			and inv.secundaria == &"revolver_357" and get_nodes_in_group("armas_suelo").size() == suelo0)
	cj.vender(&"revolver_357")
	comprobar("p2g) escudo ligero 400: 25 puntos en inventario y en la Salud", cj.comprar(&"escudo_ligero") and inv.escudo == 25.0 and j.salud.escudo == 25.0 and p.dinero_de(j) == 400)
	comprobar("p2h) el escudo pesado (1000) no llega con 400 + 400 de reembolso", not cj.comprar(&"escudo_pesado"))
	cj.vender(&"escudo_ligero")
	comprobar("p2i) devolver el escudo: 0 puntos y 800", inv.escudo == 0.0 and j.salud.escudo == 0.0 and p.dinero_de(j) == 800)
	var a: bool = cj.comprar(&"granada_cegadora")
	var b: bool = cj.comprar(&"granada_cegadora")
	var c3: bool = cj.comprar(&"granada_cegadora")
	comprobar("p2j) maximo 2 utilidades de cada tipo", a and b and not c3 and inv.cantidad_utilidad(&"granada_cegadora") == 2 and p.dinero_de(j) == 300)
	comprobar("p2k) no se puede comprar la pistola 9 mm ni la navaja (gratis y siempre)", not cj.comprar(&"pistola_9mm") and not cj.comprar(&"navaja"))
	cj.vender(&"granada_cegadora")
	cj.vender(&"granada_cegadora")
	# el modo libre: dinero infinito y compra siempre
	p.t_fase = 0.01
	a_ronda(p)
	comprobar("p2l) fuera de la fase de compra no se compra ni se devuelve", not cj.comprar(&"pistola_auto") and not cj.vender(&"pistola_auto"))
	MontajePartida.desmontar(m)
	await esperar_fisica(2)
	# libre
	var libre: Partida = Partida.new()
	main.add_child(libre)
	libre.configurar(_libre(), null)
	libre.registrar(j, 0, "Tu")
	libre.iniciar_partida()
	var cl := ComandosJugador.new(j, libre)
	comprobar("p2m) libre: dinero infinito, compra lo mas caro y el dinero no baja", libre.dinero_de(j) > 1000000 and cl.comprar(&"fusil_precision") and cl.comprar(&"fusil_precision") == false
			and libre.dinero_de(j) > 1000000 and j.gestor.inventario.principal == &"fusil_precision" and libre.fase == Partida.Fase.LIBRE)
	libre.free()
	j.gestor.reiniciar()
	j.tiempo_reaparicion = 2.0
	j.gestor.kit_reaparicion = [&"fusil_asalto"]
	j.gestor.reiniciar()


func _test_economia_rondas() -> void:
	var m: Dictionary = await MontajePartida.montar(main, config_base(2), false)
	var p: Partida = m["partida"]
	var j: Jugador = m["jugador"]
	p.iniciar_partida()
	await esperar_fisica(2)
	var d: Partida.DatosJugador = p.datos[j]
	a_ronda(p)
	# victoria de ronda (el jugador es del grupo 0): +3000
	var antes: int = d.dinero
	p.terminar_ronda(0, "tiempo")
	comprobar("p1g) victoria de ronda: +3000 al ganador", d.ingreso_ronda == 3000 and d.dinero == mini(antes + 3000, 9000), "ingreso %d, dinero %d" % [d.ingreso_ronda, d.dinero])
	var dl: Partida.DatosJugador = p.datos[(m["bots"][1] as Bot)]    # un defensor (grupo 1)
	comprobar("p1h) el perdedor cobra 1900 la primera derrota", dl.ingreso_ronda == 1900, str(dl.ingreso_ronda))
	# racha de derrotas del grupo 0: 1900, 2400, 2900, 2900
	var cobros: Array[int] = []
	for i in 4:
		a_ronda(p)
		d.dinero = 0                        # sin tope de 9000 de por medio: se mide la recompensa en bruto
		p.terminar_ronda(1, "tiempo")
		cobros.append(d.ingreso_ronda)
	comprobar("p1i) racha de derrotas consecutivas: 1900, 2400, 2900 y tope 2900", cobros == [1900, 2400, 2900, 2900], str(cobros))
	# el contador se reinicia al ganar
	a_ronda(p)
	var rondas_antes: int = p.ronda
	comprobar("p1j) la racha del grupo 0 es 4 (ronda %d)" % rondas_antes, p.consecutivas[0] == 4)
	p.terminar_ronda(0, "tiempo")
	comprobar("p1k) ganar reinicia la racha de derrotas", p.consecutivas[0] == 0 and p.consecutivas[1] == 1)
	# tope de 9000
	a_fase(p, Partida.Fase.COMPRA)
	d.dinero = 8800
	a_ronda(p)
	p.terminar_ronda(0, "tiempo")
	comprobar("p1l) el dinero no pasa de 9000", d.dinero == 9000, str(d.dinero))
	# baja: +200 y estadisticas
	a_fase(p, Partida.Fase.COMPRA)
	a_ronda(p)
	var din: int = d.dinero
	d.dinero = 1000
	var enemigo: Bot = lado_de_bots(m, p.lado_de(j) % 2 + 1)[0]
	matar(enemigo, j)
	comprobar("p1m) una baja da +200 y suma bajas / muertes", d.dinero == 1200 and d.bajas == 1 and (p.datos[enemigo] as Partida.DatosJugador).muertes == 1)
	d.dinero = din
	MontajePartida.desmontar(m)
	await esperar_fisica(2)


func _test_fases() -> void:
	var m: Dictionary = await MontajePartida.montar(main, config_base(2), false)
	var p: Partida = m["partida"]
	var j: Jugador = m["jugador"]
	var zona: ZonaActiva = m["zona"]
	var señales: Array[String] = []
	p.fase_cambiada.connect(func(f: int) -> void: señales.append(Partida.Fase.keys()[f]))
	p.iniciar_partida()
	await esperar_fisica(2)
	for i in 498:
		p.avanzar(DT)          # 24,9 s
	comprobar("p4a) a los 24,9 s sigue la fase de compra con las barreras", p.fase == Partida.Fase.COMPRA and zona.barreras_activas)
	for b: Bot in m["bots"]:
		if not b.congelado:
			comprobar("p4a2) bots quietos en la compra", false)
	for i in 4:
		p.avanzar(DT)
	comprobar("p4b) a los 25 s empieza la ronda: barreras fuera, bots libres, 100 s", p.fase == Partida.Fase.RONDA and not zona.barreras_activas
			and not (m["bots"][0] as Bot).congelado and absf(p.t_fase - 100.0) < 0.2, "t=%.2f" % p.t_fase)
	var t: float = 0.0
	while p.fase == Partida.Fase.RONDA and t < 120.0:
		p.avanzar(DT)
		t += DT
	comprobar("p4c) sin montar la Cachimba, a los 100 s ganan los defensores (tiempo)", p.fase == Partida.Fase.FIN_RONDA and t >= 99.5 and t <= 100.5
			and p.ultimo_ganador == 1 and p.ultimo_motivo == "tiempo" and p.puntos == [0, 1], "t=%.1f ganador=%d" % [t, p.ultimo_ganador])
	t = 0.0
	while p.fase == Partida.Fase.FIN_RONDA and t < 10.0:
		p.avanzar(DT)
		t += DT
	comprobar("p4d) el fin de ronda dura 5 s y vuelve la compra (ronda 2, barreras activas)", p.fase == Partida.Fase.COMPRA and t >= 4.9 and t <= 5.2 and p.ronda == 2
			and zona.barreras_activas, "t=%.1f ronda=%d" % [t, p.ronda])
	comprobar("p4e) secuencia de fases: COMPRA, RONDA, FIN_RONDA, COMPRA", señales == ["COMPRA", "RONDA", "FIN_RONDA", "COMPRA"], str(señales))
	comprobar("p4f) el jugador esta en su spawn de la ronda 2", j.global_position.distance_to(zona.punto_spawn("atacantes", 0)["pos"]) < 0.6)
	MontajePartida.desmontar(m)
	await esperar_fisica(2)


# ------------------------------------------------------------------ p5: victorias

## Monta una partida de cachimba 2v2 con el jugador atacante y la pone en RONDA.
func _ronda_cachimba(sub: StringName = ConfigPartida.SUB_CACHIMBA) -> Dictionary:
	var c: ConfigPartida = config_base(2)
	c.submodo = sub
	var m: Dictionary = await MontajePartida.montar(main, c, false)
	var p: Partida = m["partida"]
	p.iniciar_partida()
	await esperar_fisica(2)
	a_ronda(p)
	return m


func _plantar(m: Dictionary, quien: Node, segundos: float = 4.3) -> void:
	var p: Partida = m["partida"]
	var zona: ZonaActiva = m["zona"]
	var pos: Vector3 = zona.centro_site("A")
	(quien as Node3D).global_position = pos
	if quien is CharacterBody3D:
		(quien as CharacterBody3D).velocity = Vector3.ZERO
	var t: float = 0.0
	while t < segundos:
		p.montar_cachimba(quien, true)
		p.avanzar(DT)
		t += DT


func _test_victorias_cachimba() -> void:
	var m: Dictionary = await _ronda_cachimba()
	var p: Partida = m["partida"]
	var j: Jugador = m["jugador"]
	var zona: ZonaActiva = m["zona"]
	var c: Cachimba = p.cachimba()
	var d: Partida.DatosJugador = p.datos[j]
	var aliado: Bot = lado_de_bots(m, 1)[0]
	# solo el portador monta
	p.portador = aliado
	j.global_position = zona.centro_site("A")
	for i in 100:
		p.montar_cachimba(j, true)
		p.avanzar(DT)
	comprobar("p5a) un atacante que no lleva la Cachimba no puede montarla", c.estado == Cachimba.Estado.SIN_MONTAR)
	p.portador = j
	j.global_position = zona.punto_spawn("atacantes", 0)["pos"]
	for i in 100:
		p.montar_cachimba(j, true)
		p.avanzar(DT)
	comprobar("p5b) fuera de un site tampoco", c.estado == Cachimba.Estado.SIN_MONTAR)
	var t_antes: float = p.t_fase
	var dinero0: int = d.dinero
	var pl: Array[String] = []
	p.cachimba_montada.connect(func(s: String) -> void: pl.append(s))
	_plantar(m, j, 3.5)
	comprobar("p5c) a los 3,5 s aun se esta montando", c.estado == Cachimba.Estado.MONTANDO)
	_plantar(m, j, 0.8)
	comprobar("p5d) a los 4 s esta montada en el site A, +300 al que la monta y ya no hay portador", c.estado == Cachimba.Estado.MONTADA and pl == ["A"]
			and d.dinero == dinero0 + 300 and p.portador_cachimba() == null, "estado=%d dinero=%d" % [int(c.estado), d.dinero])
	var t_ronda: float = p.t_fase
	for i in 100:
		p.avanzar(DT)
	comprobar("p5e) con la Cachimba montada el reloj de la ronda se detiene", absf(p.t_fase - t_ronda) < 0.01)
	# alarma a los 40 s: ganan los atacantes, sin explosion
	var t: float = 0.0
	while p.fase == Partida.Fase.RONDA and t < 60.0:
		p.avanzar(DT)
		t += DT
	comprobar("p5f) al agotarse el temporizador suena la alarma (no explota) y ganan los atacantes", p.fase == Partida.Fase.FIN_RONDA and p.ultimo_motivo == "alarma"
			and p.ultimo_ganador == 0 and c.estado == Cachimba.Estado.ALARMA and p.mensaje_evacuacion.contains("UPO"), "t=%.1f motivo=%s" % [t, p.ultimo_motivo])
	comprobar("p5g) el temporizador de la Cachimba son 40 s desde que se monto", t >= 34.0 and t <= 36.5, "restaban %.1f s tras los 5 s de las pruebas" % t)
	comprobar("p5h) la alarma da +300 a los atacantes sobre la victoria (3000 + 300 + 300 de montar)", d.ingreso_ronda == 3600, str(d.ingreso_ronda))
	# apagada
	a_ronda(p)
	var def: Bot = lado_de_bots(m, 2)[0]
	c.montar_en(zona.centro_site("B"), "B")
	def.teletransportar(c.global_position + Vector3(1.2, 0, 0), 0.0)
	var t2: float = 0.0
	while t2 < 3.0:
		p.apagar_cachimba(def, true)
		p.avanzar(DT)
		t2 += DT
	for i in 20:
		p.avanzar(DT)          # lo suelta un segundo: el progreso se pierde
	comprobar("p5i) interrumpir el apagado lo cancela (vuelve a MONTADA)", c.estado == Cachimba.Estado.MONTADA)
	t2 = 0.0
	while t2 < 7.3 and p.fase == Partida.Fase.RONDA:
		p.apagar_cachimba(def, true)
		p.avanzar(DT)
		t2 += DT
	comprobar("p5j) tras 7 s quieto a su lado el defensor apaga la Cachimba y ganan los defensores", c.estado == Cachimba.Estado.APAGADA and p.fase == Partida.Fase.FIN_RONDA
			and p.ultimo_motivo == "apagada" and p.ultimo_ganador == 1 and t2 >= 6.9, "t=%.1f" % t2)
	# defensores eliminados -> atacantes
	a_ronda(p)
	for b: Bot in lado_de_bots(m, 2):
		matar(b, j)
	p.avanzar(DT)
	comprobar("p5k) si se elimina a todos los defensores ganan los atacantes", p.fase == Partida.Fase.FIN_RONDA and p.ultimo_motivo == "defensores_eliminados" and p.ultimo_ganador == 0)
	# atacantes eliminados sin montar -> defensores
	a_ronda(p)
	matar(j)
	matar(aliado)
	p.avanzar(DT)
	comprobar("p5l) atacantes eliminados sin Cachimba montada: ganan los defensores", p.fase == Partida.Fase.FIN_RONDA and p.ultimo_motivo == "atacantes_eliminados" and p.ultimo_ganador == 1)
	# atacantes eliminados con la Cachimba montada: la ronda sigue
	a_ronda(p)
	c.montar_en(zona.centro_site("A"), "A")
	matar(j)
	matar(aliado)
	for i in 10:
		p.avanzar(DT)
	comprobar("p5m) atacantes eliminados con la Cachimba montada: sigue la ronda (hay que apagarla)", p.fase == Partida.Fase.RONDA)
	var tt: float = 0.0
	while p.fase == Partida.Fase.RONDA and tt < 60.0:
		p.avanzar(DT)
		tt += DT
	comprobar("p5n) si nadie la apaga, alarma: ganan los atacantes aunque esten muertos", p.ultimo_motivo == "alarma" and p.ultimo_ganador == 0)
	# Cachimba caida
	a_ronda(p)
	var portador: Node = p.portador_cachimba()
	comprobar("p5o) cada ronda un atacante lleva la Cachimba", portador != null and p.lado_de(portador) == 1)
	var otro: Node = aliado if portador == j else j
	(otro as Node3D).global_position = zona.punto_spawn("atacantes", 1)["pos"] + Vector3(30, 0, 0)
	matar(portador)
	comprobar("p5p) al morir el portador la Cachimba cae al suelo y no pasa sola a otro", p.cachimba_caida() != null and p.portador_cachimba() == null)
	var pos_c: Vector3 = p.cachimba_caida().global_position
	for i in 20:
		p.avanzar(DT)
	comprobar("p5q) sigue en el suelo hasta que un atacante vivo la recoja", p.portador_cachimba() == null and p.cachimba_caida() != null)
	(otro as Node3D).global_position = pos_c + Vector3(0.5, 0, 0)
	p.avanzar(DT)
	comprobar("p5r) un atacante vivo que se acerca la recoge y pasa a ser el portador", p.portador_cachimba() == otro and p.cachimba_caida() == null)
	MontajePartida.desmontar(m)
	await esperar_fisica(2)


func _test_eliminacion() -> void:
	var m: Dictionary = await _ronda_cachimba(ConfigPartida.SUB_ELIMINACION)
	var p: Partida = m["partida"]
	var j: Jugador = m["jugador"]
	comprobar("p5s) eliminacion: sin Cachimba", p.cachimba() == null and p.modo() == &"eliminacion" and not p.exige_portador())
	for b: Bot in lado_de_bots(m, 2):
		matar(b, j)
	p.avanzar(DT)
	comprobar("p5t) eliminacion: gana quien elimina al otro equipo", p.fase == Partida.Fase.FIN_RONDA and p.ultimo_ganador == 0 and p.ultimo_motivo == "eliminacion")
	a_ronda(p)
	var t: float = 0.0
	while p.fase == Partida.Fase.RONDA and t < 120.0:
		p.avanzar(DT)
		t += DT
	comprobar("p5u) eliminacion: si se acaba el tiempo ganan los defensores", p.ultimo_ganador == 1 and p.ultimo_motivo == "tiempo" and t >= 99.5 and t <= 100.5, "t=%.1f" % t)
	a_ronda(p)
	matar(j)
	for b: Bot in lado_de_bots(m, 1):
		matar(b)
	p.avanzar(DT)
	comprobar("p5v) eliminacion: eliminar a todos los atacantes da la ronda a los defensores", p.ultimo_ganador == 1 and p.ultimo_motivo == "eliminacion")
	MontajePartida.desmontar(m)
	await esperar_fisica(2)


# ------------------------------------------------------------------ p3 (cont.), p6: inventario entre rondas, lados, fin

func _test_lados_y_fin() -> void:
	var c: ConfigPartida = config_base(2)
	var m: Dictionary = await MontajePartida.montar(main, c, false)
	var p: Partida = m["partida"]
	var j: Jugador = m["jugador"]
	var zona: ZonaActiva = m["zona"]
	p.iniciar_partida()
	await esperar_fisica(2)
	var d: Partida.DatosJugador = p.datos[j]
	var cj := ComandosJugador.new(j, p)
	# --- ronda 1: se gana y se compra (3800 tras ganar)
	a_ronda(p)
	p.terminar_ronda(0, "tiempo")
	a_fase(p, Partida.Fase.COMPRA)
	comprobar("p3a) tras ganar hay 3800 para comprar", d.dinero == 3800, str(d.dinero))
	cj.comprar(&"escudo_ligero")
	cj.comprar(&"fusil_asalto")
	cj.comprar(&"granada_humo")
	var inv: Inventario = j.gestor.inventario
	comprobar("p3b) compra fusil + escudo ligero + humo", inv.principal == &"fusil_asalto" and inv.escudo == 25.0 and inv.cantidad_utilidad(&"granada_humo") == 1, "dinero=%d" % d.dinero)
	a_ronda(p)
	j.salud.recibir_dano(30.0, "torso", 0.0, null)    # algo de dano: el escudo no se gasta con penetracion 0 -> si se gasta, queda < 25
	var escudo_fin: float = j.salud.escudo
	p.terminar_ronda(0, "tiempo")
	a_fase(p, Partida.Fase.COMPRA)
	comprobar("p3c) sobrevivir conserva el arma, las utilidades y el escudo restante (y repone la vida)", j.gestor.inventario.principal == &"fusil_asalto"
			and j.gestor.inventario.cantidad_utilidad(&"granada_humo") == 1 and is_equal_approx(j.salud.escudo, escudo_fin) and j.salud.vida == j.salud.vida_max,
			"escudo=%.1f vida=%.0f" % [j.salud.escudo, j.salud.vida])
	comprobar("p3d) las compras de la ronda anterior ya no se pueden devolver", p.compras_de(j).is_empty() and not cj.vender(&"fusil_asalto"))
	# --- morir: se pierde todo lo comprado y el arma queda en el suelo hasta el final de la ronda
	a_ronda(p)
	matar(j)
	await esperar_fisica(2)
	comprobar("p3e) al morir se suelta la principal (y se puede recoger del suelo)", get_nodes_in_group("armas_suelo").size() >= 1 and j.gestor.inventario.principal == &"")
	p.terminar_ronda(1, "tiempo")
	a_fase(p, Partida.Fase.COMPRA)
	await esperar_fisica(2)
	var inv2: Inventario = j.gestor.inventario
	comprobar("p3f) al reaparecer vuelve con pistola 9 mm, sin principal, sin escudo ni utilidades", inv2.principal == &"" and inv2.secundaria == &"pistola_9mm"
			and inv2.escudo == 0.0 and inv2.utilidades.is_empty() and j.salud.escudo == 0.0 and not j.muerto and j.salud.vivo)
	comprobar("p3g) al empezar la ronda se limpian las armas del suelo", get_nodes_in_group("armas_suelo").is_empty())
	# --- cambio de lado tras la ronda 6
	for k in 3:
		a_ronda(p)
		p.terminar_ronda(k % 2, "tiempo")
		a_fase(p, Partida.Fase.COMPRA)
	# rondas jugadas: 1..6 ya? ronda actual = 7 tras la 6
	comprobar("p6a) tras la ronda 6 se cambia de lado (grupos intercambian atacar y defender)", p.ronda == 7 and p.lado_grupo == [2, 1], "ronda=%d lados=%s" % [p.ronda, str(p.lado_grupo)])
	var bot_g0: Bot = m["bots"][0] as Bot       # grupo 0
	comprobar("p6b) los bots y el jugador cambian de equipo y de spawn", bot_g0.equipo == 2 and j.salud.equipo == 2 and p.lado_de(j) == 2
			and j.global_position.distance_to(zona.punto_spawn("defensores", 0)["pos"]) < 0.6)
	comprobar("p6c) al cambiar de lado la economia se reinicia (800)", d.dinero == 800, str(d.dinero))
	# --- fin de partida: 7 rondas para ganar
	var fin: Array[int] = [-1]
	p.partida_terminada.connect(func(g: int) -> void: fin[0] = g)
	p.puntos = [0, 0]
	for k in 7:
		if not a_ronda(p):
			break
		p.terminar_ronda(1, "tiempo")
		if p.fase == Partida.Fase.FIN_PARTIDA:
			break
		a_fase(p, Partida.Fase.COMPRA)
	comprobar("p6d) a 7 rondas ganadas acaba la partida con victoria del grupo 1", p.fase == Partida.Fase.FIN_PARTIDA and fin[0] == 1 and p.ganador_partida == 1 and p.puntos[1] == 7)
	# reglas de victoria (puro)
	var reglas: Array = [[7, 5, 0, 7, 0], [7, 6, 0, 7, -1], [8, 6, 0, 7, 0], [6, 6, 0, 7, -1], [0, 7, 1, 7, 1], [1, 0, 0, 1, 0], [7, 0, 0, 7, 0]]
	var ok: bool = true
	var det: String = ""
	for r: Array in reglas:
		p.puntos = [int(r[0]), int(r[1])]
		p.cfg.rondas_ganar = int(r[3])
		var g: int = p._ganador_partida()
		if g != int(r[4]):
			ok = false
			det += " %s->%d" % [str(r), g]
	comprobar("p6e) victoria: 7-5 gana, 7-6 sigue (prorroga a ganar por 2), 8-6 gana, 6-6 sigue, 1 de 1", ok, det)
	MontajePartida.desmontar(m)
	await esperar_fisica(2)


# ------------------------------------------------------------------ p7: partida completa con bots

func _test_partida_completa() -> void:
	var c: ConfigPartida = config_base(3)
	c.con_jugador = false
	c.rondas_ganar = 2
	c.semilla = 21
	c.t_compra = 4.0
	c.t_fin_ronda = 1.0
	var m: Dictionary = await MontajePartida.montar(main, c, true)
	var p: Partida = m["partida"]
	var finalizada: Array[bool] = [false]
	p.partida_terminada.connect(func(_g: int) -> void: finalizada[0] = true)
	var resultados: Array[String] = []
	p.ronda_terminada.connect(func(g: int, mot: String) -> void: resultados.append("%s(%s)" % [("ATQ" if p.lado_grupo[g] == 1 else "DEF"), mot]))
	p.iniciar_partida()
	Engine.time_scale = 8.0
	var t0: int = Time.get_ticks_msec()
	var guarda: int = 0
	while not finalizada[0] and guarda < 100000:
		await physics_frame
		guarda += 1
		if p._t > 1500.0:
			break
	Engine.time_scale = 1.0
	var real: float = (Time.get_ticks_msec() - t0) / 1000.0
	comprobar("p7a) la partida completa con bots termina con un ganador", finalizada[0] and p.ganador_partida >= 0, "fase=%d rondas=%d puntos=%s" % [p.fase, p.ronda, str(p.puntos)])
	comprobar("p7b) se jugaron rondas con victorias y economia coherente", p.ronda >= 2 and p.puntos[0] + p.puntos[1] == p.ronda and not resultados.is_empty(), str(resultados))
	var din_ok: bool = true
	for n: Node in p.jugadores:
		var dj: Partida.DatosJugador = p.datos[n]
		din_ok = din_ok and dj.dinero >= 0 and dj.dinero <= 9000
	comprobar("p7c) el dinero siempre esta entre 0 y 9000", din_ok)
	informe.append("Partida completa (3v3, el_eje, 2 para ganar): %s; puntos %s; %.0f s simulados, %.0f s reales; rondas: %s" % [
			"termino" if finalizada[0] else "NO termino", str(p.puntos), p._t, real, ", ".join(resultados)])
	MontajePartida.desmontar(m)
	await esperar_fisica(2)
