extends SceneTree
## Capturas de la partida (P4): lobby, tienda, HUD en ronda, tabla Tab y alarma / evacuacion. Necesita GPU: NO usar --headless. Uso:
##   Godot_console.exe --path game --script res://tests/captura_p4.gd [-- <carpeta_salida>]
## Guarda lobby.png, tienda.png, hud_ronda.png, tabla.png, alarma.png y espectador.png en export/capturas_p4 por defecto.
## Usa una camara de captura propia (`Juego.camara_fija`), asi el juego no cambia la camara mientras se fotografia.

var salida: String = ""
var juego: Juego


func _init() -> void:
	_ejecutar.call_deferred()


func _foto(nombre: String) -> void:
	await process_frame
	await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png(salida.path_join(nombre + ".png"))
	print("captura ", nombre)


func _ejecutar() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	salida = args[0] if args.size() > 0 else ProjectSettings.globalize_path("res://").path_join("../export/capturas_p4")
	DirAccess.make_dir_recursive_absolute(salida)
	juego = (load("res://scenes/juego.tscn") as PackedScene).instantiate()
	root.add_child(juego)
	for i in 20:
		await physics_frame
	# --- lobby (con la vista previa de la zona detras)
	await _foto("lobby")
	# --- partida competitiva 5v5 en Plaza America, el jugador ataca
	var c := ConfigPartida.new()
	c.zona = "plaza_america"
	c.semilla = 5
	await juego.iniciar(c)
	for i in 30:
		await physics_frame
	var cam := Camera3D.new()
	cam.name = "CamaraCaptura"
	cam.far = 1500.0
	cam.fov = 80.0
	juego.add_child(cam)
	cam.make_current()
	juego.camara_fija = cam
	var j: Jugador = juego.jugador
	cam.global_transform = j.camara.global_transform
	var p: Partida = juego.partida
	# --- tienda (se abre sola en la fase de compra); se compra algo para ver el estado
	p.comprar(j, &"escudo_ligero")
	p.comprar(j, &"carabina_556")
	await _foto("tienda")
	juego.tienda.mostrar_detalle(&"fusil_precision")
	await _foto("tienda_detalle")
	juego.tienda.cerrar_tienda()
	# --- HUD en ronda: pasar a la ronda y dejar que los bots se muevan
	p.t_fase = 0.0
	for i in 8:
		await physics_frame
	Engine.time_scale = 4.0
	for i in 160:
		await physics_frame
	Engine.time_scale = 1.0
	cam.global_transform = j.camara.global_transform
	await _foto("hud_ronda")
	juego.hud_partida.forzar_tabla = true
	await _foto("tabla")
	juego.hud_partida.forzar_tabla = false
	# --- Cachimba montada y alarma / evacuacion
	var c_n: Cachimba = p.cachimba_nodo
	var pos: Vector3 = p.zona_activa.centro_site("A")
	c_n.montar_en(pos, "A")
	for i in 6:
		await physics_frame
	cam.global_position = pos + Vector3(7, 3.5, 7)
	cam.look_at(pos + Vector3(0, 0.8, 0), Vector3.UP)
	await _foto("cachimba_montada")
	c_n.restante = 0.2
	for i in 20:
		await physics_frame
	await _foto("alarma")
	# --- espectador: el jugador muere y ve a un aliado
	juego.camara_fija = null
	if p.fase == Partida.Fase.RONDA:
		p.terminar_ronda(0, "alarma")
	for i in 3:
		await physics_frame
	await _foto("fin_ronda")
	Engine.time_scale = 6.0
	while p.fase != Partida.Fase.RONDA:
		await physics_frame
	Engine.time_scale = 1.0
	(Salud.de(j) as Salud).recibir_dano(9999.0, "torso", 1.0, null)
	for i in 40:
		await physics_frame
	await _foto("espectador")
	quit(0)
