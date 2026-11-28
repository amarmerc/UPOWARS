extends SceneTree
## Prueba de humo del flujo del juego (escena principal `juego.tscn`): lobby, partida competitiva (tienda automatica, B, Esc),
## espectador al morir, partida libre (Esc = tienda con opciones) y vuelta al lobby. Uso:
##   Godot_console.exe --headless --path game --script res://tests/test_juego.gd
## Imprime PASS/FAIL y sale con codigo 0 (todo bien) o 1.

var fallos: int = 0
var juego: Juego


func comprobar(nombre: String, ok: bool, detalle: String = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", nombre, detalle])
	if not ok:
		fallos += 1


func esperar_fisica(n: int) -> void:
	for i in n:
		await physics_frame


func accion(nombre: String) -> void:
	var e := InputEventAction.new()
	e.action = nombre
	e.pressed = true
	Input.parse_input_event(e)
	await physics_frame
	await process_frame
	await physics_frame
	await process_frame


func _init() -> void:
	_ejecutar.call_deferred()


## Lobby: modos, huecos, intercambio con bots, tamano de equipos, perfil persistente y Listo.
func _test_lobby() -> void:
	var lobby: LobbyUI = juego.lobby
	var nombres: Array[String] = []
	for i in lobby._modo.item_count:
		nombres.append(lobby._modo.get_item_text(i))
	comprobar("l1) un solo desplegable de modo: Modo libre / Cachimba Wars / Modo pleno", nombres == ["Modo libre", "Cachimba Wars", "Modo pleno"], str(nombres))
	var humanos: int = 0
	var bots: int = 0
	for g in 2:
		for h: Dictionary in lobby.equipos[g]:
			humanos += 1 if h["tipo"] == ConfigPartida.TIPO_HUMANO else 0
			bots += 1 if h["tipo"] == ConfigPartida.TIPO_BOT else 0
	comprobar("l2) 5 huecos por equipo: el jugador en EPS y el resto bots; contador 0/1",
			(lobby.equipos[0] as Array).size() == 5 and (lobby.equipos[1] as Array).size() == 5 and humanos == 1 and bots == 9
			and lobby.pos_local() == Vector2i(0, 0) and lobby.contador_listos() == Vector2i(0, 1))
	lobby.clic_hueco(1, 2)
	comprobar("l3) clic en un bot de CEUPO: el jugador se intercambia con el (cambia de equipo)", lobby.pos_local() == Vector2i(1, 2) and lobby.grupo_jugador() == 1
			and (lobby.equipos[0][0] as Dictionary)["tipo"] == ConfigPartida.TIPO_BOT)
	lobby.clic_hueco(1, 2)
	comprobar("l4) clic sobre uno mismo no hace nada", lobby.pos_local() == Vector2i(1, 2))
	lobby.clic_hueco(1, 0)
	comprobar("l5) clic en un bot del mismo equipo cambia de hueco", lobby.pos_local() == Vector2i(1, 0))
	lobby.poner_tam(3)
	var ok3: bool = (lobby.equipos[0] as Array).size() == 3 and (lobby.equipos[1] as Array).size() == 3 and lobby.pos_local().x == 1
	lobby.poner_tam(5)
	comprobar("l6) el tamano de equipo quita y crea huecos (siempre bots) sin perder al jugador",
			ok3 and (lobby.equipos[0] as Array).size() == 5 and (lobby.equipos[1] as Array).size() == 5 and lobby.pos_local().x == 1)
	lobby.poner_nombre("Alex")
	var pers0: StringName = lobby.personaje_elegido()
	lobby.cambiar_personaje(1)
	var cargado: Dictionary = PerfilJugador.cargar()
	var otro: LobbyUI = LobbyUI.new()
	juego.add_child(otro)
	comprobar("l7) nombre y personaje se guardan en el perfil y un lobby nuevo los recupera", cargado["nombre"] == "Alex" and cargado["personaje"] == lobby.personaje_elegido()
			and lobby.personaje_elegido() != pers0 and otro._nombre.text == "Alex" and otro.personaje_elegido() == lobby.personaje_elegido())
	otro.queue_free()
	comprobar("l8) el nombre por defecto es Jugador", PerfilJugador.NOMBRE_DEFECTO == "Jugador")
	lobby.poner_modo(ConfigPartida.M_PLENO)
	lobby._nombres_equipo[0].text = "Los A"
	var c: ConfigPartida = lobby.config()
	var pers_ok: bool = true
	for g in 2:
		for h: Dictionary in c.huecos[g]:
			pers_ok = pers_ok and CatalogoPersonajes.existe(StringName(h["personaje"]))
	comprobar("l9) config: Modo pleno = eliminacion, nombres de equipo, grupo del jugador, huecos con personaje y perfil",
			c.submodo == ConfigPartida.SUB_ELIMINACION and not c.es_libre() and c.nombres[0] == "Los A" and c.grupo_jugador == 1 and c.nombre_jugador == "Alex"
			and (c.huecos[1][0] as Dictionary)["local"] and pers_ok and c.personaje_jugador == lobby.personaje_elegido())
	lobby.poner_modo(ConfigPartida.M_LIBRE)
	comprobar("l10) Modo libre: se ocultan los paneles de equipo y la config es libre", not lobby._paneles_equipo[0].visible and lobby._panel_libre.visible and lobby.config().es_libre())
	lobby.poner_modo(ConfigPartida.M_CACHIMBA_WARS)
	lobby._nombres_equipo[0].text = "EPS"
	# Listo: arranca la partida (pasa por Juego.iniciar) con el 2v2 elegido
	lobby.poner_tam(2)
	lobby._dificultad.select(0)
	lobby.clic_hueco(0, 1)
	var antes_listo: Vector2i = lobby.contador_listos()
	lobby.pulsar_listo()
	for i in 240:
		await physics_frame
		if juego.en_partida:
			break
	var pj: Partida = juego.partida
	var grupo_ok: bool = pj != null and pj.grupo_de(juego.jugador) == 0
	var bots_ok: bool = juego.bots.size() == 3
	for b: Bot in juego.bots:
		bots_ok = bots_ok and CatalogoPersonajes.existe(b.personaje) and b._mat_torso != null
	comprobar("l11) Listo con todos los humanos listos arranca la partida 2v2 (jugador + 3 bots con personaje) y el lobby se oculta",
			antes_listo == Vector2i(0, 1) and juego.en_partida and not juego.lobby.visible and pj.jugadores.size() == 4 and grupo_ok and bots_ok and juego.cfg.nombre_jugador == "Alex")
	juego.mostrar_lobby()
	await esperar_fisica(4)


func _ejecutar() -> void:
	PerfilJugador.ruta = "user://perfil_test.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PerfilJugador.ruta))
	juego = (load("res://scenes/juego.tscn") as PackedScene).instantiate()
	root.add_child(juego)
	await esperar_fisica(12)
	comprobar("j1) la escena principal arranca en el lobby", ProjectSettings.get_setting("application/run/main_scene") == "res://scenes/juego.tscn"
			and juego.lobby.visible and not juego.en_partida and not juego.hud_partida.visible)
	await _test_lobby()
	var cfg := ConfigPartida.new()
	cfg.zona = "el_eje"
	cfg.semilla = 4
	cfg.dificultad = &"facil"
	await juego.iniciar(cfg)
	await esperar_fisica(6)
	var p: Partida = juego.partida
	comprobar("j2) competitivo 5v5: 10 combatientes (jugador + 9 bots), fase de compra y tienda abierta sola", juego.en_partida and p.jugadores.size() == 10
			and juego.bots.size() == 9 and p.fase == Partida.Fase.COMPRA and juego.tienda.visible and not juego.lobby.visible and not juego.jugador.activo)
	comprobar("j3) el HUD de partida y el marcador estan visibles; el jugador tiene 800", juego.hud_partida.visible and p.dinero_de(juego.jugador) == 800)
	await accion("tienda")
	comprobar("j4) B cierra la tienda durante la fase de compra", not juego.tienda.visible and juego.jugador.activo)
	await accion("tienda")
	comprobar("j5) B la vuelve a abrir", juego.tienda.visible)
	await accion("ui_cancel")
	comprobar("j6) Esc cierra la tienda, no abre la pausa", not juego.tienda.visible and not juego.pausa.visible)
	await accion("ui_cancel")
	comprobar("j7) Esc en competitivo abre solo la pausa (el arbol se detiene)", juego.pausa.visible and paused and not juego.tienda.visible)
	await accion("ui_cancel")
	comprobar("j8) Esc de nuevo reanuda", not juego.pausa.visible and not paused and juego.jugador.activo)
	await accion("tienda")
	var antes: int = p.dinero_de(juego.jugador)
	juego.tienda.refrescar()
	var tienda: TiendaUI = juego.tienda
	var n_art: int = Catalogo.todos().filter(func(d: Dictionary) -> bool: return d["categoria"] != "cuerpo").size()
	comprobar("j9) la tienda muestra una tarjeta por articulo (armas, escudos y utilidades)", tienda.tarjetas.size() == n_art and tienda.tarjetas.has(&"revolver_357") and tienda.tarjetas.has(&"escudo_pesado"))
	juego.comandos_jugador.comprar(&"pistola_auto")
	comprobar("j10) comprar por ComandosJugador descuenta el dinero", p.dinero_de(juego.jugador) == antes - 500)
	# tarjetas: deshabilitada si no llega, clic derecho devuelve, clic izquierdo compra
	var rev: PanelContainer = tienda.tarjetas[&"lanzacohetes"]
	tienda.clic_tarjeta(&"lanzacohetes", MOUSE_BUTTON_LEFT)
	comprobar("t1) tarjeta no asequible: atenuada, deshabilitada y el clic no compra", bool(rev.get_meta("estado")["deshabilitada"]) and rev.modulate.a < 0.9
			and p.dinero_de(juego.jugador) == antes - 500 and not p.lleva(juego.jugador, &"lanzacohetes"))
	var auto_c: PanelContainer = tienda.tarjetas[&"pistola_auto"]
	comprobar("t2) lo comprado en esta fase se marca como comprado", bool(auto_c.get_meta("estado")["comprado"]))
	tienda.clic_tarjeta(&"pistola_auto", MOUSE_BUTTON_RIGHT)
	comprobar("t3) clic derecho devuelve lo comprado (reembolso completo)", p.dinero_de(juego.jugador) == antes and not p.lleva(juego.jugador, &"pistola_auto")
			and not bool(auto_c.get_meta("estado")["comprado"]))
	tienda.clic_tarjeta(&"pistola_auto", MOUSE_BUTTON_LEFT)
	comprobar("t4) clic izquierdo compra", p.dinero_de(juego.jugador) == antes - 500 and p.lleva(juego.jugador, &"pistola_auto") and bool(auto_c.get_meta("estado")["comprado"]))
	tienda.mostrar_detalle(&"fusil_asalto")
	comprobar("t5) el panel de detalle se muestra con las estadisticas", tienda._detalle.visible and tienda._det_cont.get_child_count() >= 8)
	tienda._detalle.visible = false
	juego.tienda.cerrar_tienda()
	# la ronda: cuando acaba la compra se cierra sola la tienda
	juego.tienda.abrir()
	p.t_fase = 0.0
	await esperar_fisica(3)
	comprobar("j11) al acabar la fase de compra la tienda se cierra sola y empieza la ronda", p.fase == Partida.Fase.RONDA and not juego.tienda.visible and juego.jugador.activo)
	# espectador
	(juego.jugador.salud as Salud).recibir_dano(9999.0, "torso", 1.0, null)
	await esperar_fisica(4)
	await process_frame
	await process_frame
	comprobar("j12) al morir se espectea a un aliado vivo con la camara del lobby/espectador", juego.hud_partida.espectando != null and juego.camara.is_current()
			and p.lado_de(juego.hud_partida.espectando) == p.lado_de(juego.jugador))
	var primero: Node = juego.hud_partida.espectando
	juego._siguiente_aliado()
	await esperar_fisica(2)
	comprobar("j13) el clic cambia de aliado", juego.hud_partida.espectando != primero)
	# volver al lobby
	juego.mostrar_lobby()
	await esperar_fisica(4)
	comprobar("j14) volver al lobby desmonta la partida y los bots", juego.lobby.visible and not juego.en_partida and juego.partida == null and juego.bots.is_empty())
	# libre
	var libre := ConfigPartida.new()
	libre.modo = ConfigPartida.MODO_LIBRE
	libre.bots_libres = 2
	await juego.iniciar(libre)
	await esperar_fisica(6)
	var pl: Partida = juego.partida
	comprobar("j15) libre: fase LIBRE, dinero infinito, 2 bots y sin tienda automatica", pl.fase == Partida.Fase.LIBRE and pl.dinero_de(juego.jugador) > 1000000 and juego.bots.size() == 2 and not juego.tienda.visible)
	juego.mundo.menu.cerrar()
	juego.jugador.activo = true
	await accion("ui_cancel")
	comprobar("j16) libre: Esc abre la tienda con las opciones de salir (sin pausar)", juego.tienda.visible and juego.tienda.modo_libre and not paused, "vis=%s libre=%s paused=%s" % [juego.tienda.visible, juego.tienda.modo_libre, paused])
	await accion("ui_cancel")
	comprobar("j17) libre: Esc de nuevo la cierra", not juego.tienda.visible)
	juego.mostrar_lobby()
	await esperar_fisica(3)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PerfilJugador.ruta))
	print("RESULTADO: %s (%d fallos)" % ["PASS" if fallos == 0 else "FAIL", fallos])
	quit(0 if fallos == 0 else 1)
