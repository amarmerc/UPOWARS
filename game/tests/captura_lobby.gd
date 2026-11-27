extends SceneTree
## Capturas del lobby y la tienda: lobby con el jugador en EPS, tras cambiarse a CEUPO, en Modo libre, tienda y detalle de un arma.
## Necesita GPU: NO usar --headless. Uso:
##   Godot_console.exe --path game --script res://tests/captura_lobby.gd [-- <carpeta_salida>]
## Guarda lobby_eps.png, lobby_ceupo.png, lobby_libre.png, tienda.png, tienda_detalle.png y tienda_detalle_utilidad.png en export/capturas_lobby por defecto.

var salida: String = ""
var juego: Juego


func _init() -> void:
	_ejecutar.call_deferred()


func _foto(nombre: String) -> void:
	for i in 4:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png(salida.path_join(nombre + ".png"))
	print("captura ", nombre)


func _ejecutar() -> void:
	PerfilJugador.ruta = "user://perfil_captura.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PerfilJugador.ruta))
	var args: PackedStringArray = OS.get_cmdline_user_args()
	salida = args[0] if args.size() > 0 else ProjectSettings.globalize_path("res://").path_join("../export/capturas_lobby")
	DirAccess.make_dir_recursive_absolute(salida)
	juego = (load("res://scenes/juego.tscn") as PackedScene).instantiate()
	root.add_child(juego)
	for i in 20:
		await physics_frame
	var lobby: LobbyUI = juego.lobby
	await _foto("lobby_eps")
	lobby.clic_hueco(1, 2)
	lobby.poner_nombre("Alex")
	lobby.cambiar_personaje(2)
	await _foto("lobby_ceupo")
	lobby.poner_modo(ConfigPartida.M_LIBRE)
	await _foto("lobby_libre")
	lobby.poner_modo(ConfigPartida.M_CACHIMBA_WARS)
	lobby._mostrar_creditos()
	await _foto("creditos")
	lobby._creditos.visible = false
	# partida: la tienda se abre sola en la fase de compra
	var c: ConfigPartida = lobby.config()
	c.zona = "plaza_america"
	await juego.iniciar(c)
	for i in 30:
		await physics_frame
	var cam := Camera3D.new()
	cam.far = 1500.0
	juego.add_child(cam)
	cam.make_current()
	juego.camara_fija = cam
	var p: Partida = juego.partida
	p.comprar(juego.jugador, &"escudo_ligero")
	p.comprar(juego.jugador, &"granada_humo")
	p.comprar(juego.jugador, &"subfusil_9mm")
	await _foto("tienda")
	var t: TiendaUI = juego.tienda
	t._hover = &"fusil_combate"
	t.refrescar()
	await process_frame
	t.mostrar_detalle(&"fusil_combate")
	await _foto("tienda_detalle")
	t._hover = &"granada_explosiva"
	t.refrescar()
	t.mostrar_detalle(&"granada_explosiva")
	await _foto("tienda_detalle_utilidad")
	print("RESULTADO: PASS")
	quit(0)
