class_name MontajePartida
extends RefCounted
## Ayuda de los tests y simulaciones de la Partida (P4): monta zona + navegacion + Partida + Director + combatientes sobre un `main`.
## `auto` = verdadero: todo avanza solo en _physics_process (simulacion con bots); falso: el test avanza a mano con `avanzar(dt)`.
## Devuelve {"zona", "region", "partida", "director", "bots", "jugador"}.

static func montar(main: Node3D, cfg: ConfigPartida, auto: bool) -> Dictionary:
	var arbol: SceneTree = main.get_tree()
	var zona: ZonaActiva = ZonaActiva.crear(cfg.zona)
	main.add_child(zona)
	for i in 3:
		await arbol.physics_frame
	var region: NavigationRegion3D = NavBots.hornear_zona(main, zona)
	await NavBots.esperar_listo(main, zona.punto_spawn("atacantes", 0)["pos"])
	var partida := Partida.new()
	partida.manual = not auto
	main.add_child(partida)
	partida.configurar(cfg, zona)
	var dir := DirectorBots.new()
	dir.set_physics_process(auto)
	main.add_child(dir)
	dir.configurar(zona, partida, cfg.modo_partida(), NavBots.mapa(main), cfg.semilla)
	partida.director = dir
	var jugador: Jugador = main.get_node("Jugador") as Jugador if cfg.con_jugador else null
	var bots: Array[Bot] = []
	var k: int = 0
	for g in 2:
		var lado: int = Partida.EQ_ATACANTES if g == 0 else Partida.EQ_DEFENSORES
		for i in cfg.jugadores_por_equipo:
			if jugador != null and g == cfg.grupo_jugador and i == 0:
				partida.registrar(jugador, g, "Tu")
				continue
			var rol: StringName = Bot.ROL_CAZADOR if cfg.submodo == ConfigPartida.SUB_ELIMINACION else (Bot.ROL_ATACANTE if lado == Partida.EQ_ATACANTES else Bot.ROL_DEFENSOR)
			var b: Bot = Bot.crear("B%d_%d" % [g, i], lado, rol, cfg.dificultad, cfg.semilla * 100 + k, partida)
			k += 1
			b.entrada_manual = not auto
			main.add_child(b)
			partida.registrar(b, g, b.nombre)
			dir.agregar(b)
			bots.append(b)
	return {"zona": zona, "region": region, "partida": partida, "director": dir, "bots": bots, "jugador": jugador}


static func desmontar(m: Dictionary) -> void:
	for b: Bot in m["bots"]:
		if is_instance_valid(b):
			b.free()
	for k: String in ["director", "partida"]:
		(m[k] as Node).free()
	(m["region"] as Node).queue_free()
	(m["zona"] as Node).queue_free()
	var j: Jugador = m["jugador"]
	if j != null:
		j.tiempo_reaparicion = 2.0
		j.gestor.kit_reaparicion = [&"fusil_asalto"]
		j.muerto = false
		j.salud.reiniciar()
		j.hitboxes.activar(true)
		j.gestor.reiniciar()
	var arbol: SceneTree = j.get_tree() if j != null else null
	if arbol != null:
		for g: String in ["lanzables", "nubes", "proyectiles", "altavoces", "armas_suelo", "cachimba_suelo"]:
			for n: Node in arbol.get_nodes_in_group(g):
				n.queue_free()
