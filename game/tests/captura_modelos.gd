extends SceneTree
## Capturas de los modelos externos (necesita GPU: NO usar --headless). Uso:
##   Godot_console.exe --path game --script res://tests/captura_modelos.gd [-- salida=<carpeta> partes=mosaico,sable,arco,suelo]
## Mosaico de armas en primera persona, sable encendiendose y encendido, arco cargando y armas en el suelo.
## Guarda en export/capturas_modelos por defecto.

const ORDEN: Array[StringName] = [
	&"pistola_9mm", &"pistola_auto", &"pistola_pesada", &"revolver_357", &"escopeta_recortada", &"subfusil_compacto",
	&"subfusil_9mm", &"subfusil_45", &"escopeta_corredera", &"escopeta_auto", &"carabina_556", &"fusil_asalto",
	&"fusil_combate", &"fusil_tirador", &"fusil_precision", &"ametralladora", &"arco_olivo", &"tirachinas",
	&"lanzacohetes", &"sable_plasma", &"puno_bot", &"navaja", &"granada_humo", &"granada_cegadora",
	&"granada_explosiva", &"bote_pintura", &"extintor", &"altavoz"]

var salida: String = ""
var partes: PackedStringArray = ["mosaico", "sable", "arco", "suelo"]


func _init() -> void:
	_ejecutar.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _listo(gestor: GestorArmas, segundos: float) -> void:
	for i in int(segundos * 60.0):
		gestor.avanzar(1.0 / 60.0)
		if i % 6 == 0:
			await process_frame
	await process_frame


func _guardar(nombre: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(salida.path_join(nombre + ".png"))
	print("captura ", nombre)


func _ejecutar() -> void:
	salida = ProjectSettings.globalize_path("res://").path_join("../export/capturas_modelos")
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("salida="):
			salida = a.substr(7)
		elif a.begins_with("partes="):
			partes = a.substr(7).split(",")
	DirAccess.make_dir_recursive_absolute(salida)
	var main: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 10:
		await physics_frame
	main.menu.cerrar()
	var jugador: Jugador = main.get_node("Jugador")
	var campo: CampoPractica = main.campo
	var gestor: GestorArmas = jugador.gestor
	jugador.activo = true
	jugador.set_physics_process(true)
	jugador.entrada_manual = true
	jugador.camara.make_current()
	gestor.entrada_manual = true
	gestor.kit_reaparicion = []
	gestor.reiniciar()
	main.hud.visible = true
	main.hud.get_node("Info").visible = false
	var fwd: Vector3 = campo.adelante
	for i in 20:
		await physics_frame
	jugador._pitch = deg_to_rad(24.0)
	jugador._aplicar_rotacion_cabeza()
	if partes.has("mosaico"):
		var celdas: Array[Image] = []
		for id: StringName in ORDEN:
			gestor.inventario.utilidades.clear()
			if Catalogo.hueco(id) == &"utilidades":
				gestor.equipar(id)
				gestor.sel_util = 0
				gestor.cambiar_arma(3)
				gestor.sel_util = 0
				gestor._forzar_arma(3)
			elif id == &"navaja":
				gestor.cambiar_arma(2)
			else:
				gestor.equipar(id)
			await _listo(gestor, 1.2)
			await RenderingServer.frame_post_draw
			var img: Image = root.get_viewport().get_texture().get_image()
			var celda: Image = img.get_region(Rect2i(500, 250, 780, 470))
			celda.convert(Image.FORMAT_RGBA8)
			celdas.append(celda)
		var cw: int = 390
		var ch: int = 235
		var cols: int = 6
		var filas: int = int(ceil(celdas.size() / float(cols)))
		var mosaico: Image = Image.create(cw * cols, ch * filas, false, Image.FORMAT_RGBA8)
		for i in celdas.size():
			var c: Image = celdas[i]
			c.resize(cw, ch, Image.INTERPOLATE_BILINEAR)
			mosaico.blit_rect(c, Rect2i(0, 0, cw, ch), Vector2i((i % cols) * cw, (i / cols) * ch))
		mosaico.save_png(salida.path_join("armas_mosaico.png"))
		print("captura armas_mosaico")
		gestor.inventario.utilidades.clear()
		gestor.reiniciar()
	jugador._pitch = deg_to_rad(8.0)
	jugador._aplicar_rotacion_cabeza()
	if partes.has("sable"):
		gestor.equipar(&"sable_plasma")
		for i in 14:
			gestor.avanzar(1.0 / 60.0)
		await _frames(2)
		await _guardar("sable_encendiendo")
		await _listo(gestor, 1.4)
		await _guardar("sable_encendido")
		gestor.gatillo_alt = true
		await _listo(gestor, 0.5)
		await _guardar("sable_bloqueo")
		gestor.gatillo_alt = false
		gestor.reiniciar()
		await _listo(gestor, 0.5)
	if partes.has("arco"):
		gestor.equipar(&"arco_olivo")
		await _listo(gestor, 1.0)
		await _guardar("arco_reposo")
		gestor.gatillo = true
		await _listo(gestor, 0.8)
		await _guardar("arco_carga")
		gestor.gatillo = false
		await _listo(gestor, 0.4)
		await _guardar("arco_flecha_vuelo")
		for p: Node in get_nodes_in_group("proyectiles"):
			p.queue_free()
		gestor.reiniciar()
		await _listo(gestor, 0.5)
	if partes.has("suelo"):
		var frente: Vector3 = campo.punto_tiro + fwd * 2.0
		var ids: Array[StringName] = [&"escopeta_corredera", &"fusil_precision", &"ametralladora", &"revolver_357", &"sable_plasma"]
		for i in ids.size():
			var pos: Vector3 = frente + fwd.cross(Vector3.UP) * (float(i) * 0.9 - 1.8)
			pos.y = campo._suelo(pos) + 0.5
			ArmaSuelo.crear(jugador, ids[i], 5, 10, pos)
		await _frames(40)
		var objetivo: Node3D = get_nodes_in_group("armas_suelo")[1] as Node3D
		jugador._pitch = deg_to_rad(-25.0)
		jugador.camara.look_at(objetivo.global_position + Vector3(0, 0.05, 0), Vector3.UP)
		await _frames(6)
		await _guardar("armas_suelo")
		ArmaSuelo.limpiar_armas_suelo(self)
	if partes.has("coches"):
		await _coches(main)
	quit(0)


## Aparcamiento con coches del pack y con el blockout: captura y fotogramas/s medidos sin vsync en cada caso.
func _coches(main: Node) -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var mapa: Node3D = main.find_child("Mapa", true, false) as Node3D
	if mapa == null:
		mapa = main as Node3D
	print("coches externos: ", mapa.get("estadisticas_coches"))
	var jug: Node3D = main.get_node("Jugador")
	jug.set_physics_process(false)
	jug.visible = false
	main.hud.visible = false
	var cam := Camera3D.new()
	cam.far = 2000.0
	cam.fov = 75.0
	main.add_child(cam)
	cam.make_current()
	var sp: Dictionary = {}
	for s: Dictionary in main.spawns:
		if s["id"] == "aparcamiento":
			sp = s
	var p: Array = sp["pos"]
	var vistas: Array = [["aparcamiento", Vector3(p[0], p[1] + 1.7, p[2]), float(sp["yaw_deg"]), -8.0],
			["aparcamiento_alto", Vector3(p[0], p[1] + 22.0, p[2]), float(sp["yaw_deg"]), -35.0],
			["aparcamiento_cerca", Vector3(p[0], p[1] + 1.5, p[2]), float(sp["yaw_deg"]) + 40.0, -4.0]]
	for externos: bool in [false, true]:
		CochesExternos.alternar(mapa, externos)
		for v: Array in vistas:
			cam.global_position = v[1]
			cam.rotation = Vector3(deg_to_rad(v[3]), deg_to_rad(v[2]), 0.0)
			await _frames(25)
			var t0: int = Time.get_ticks_usec()
			var n: int = 150
			for i in n:
				await process_frame
			var ms: float = float(Time.get_ticks_usec() - t0) / 1000.0 / float(n)
			print("RENDIMIENTO %s %s: %.2f ms/frame (%.0f fps)" % [v[0], "pack" if externos else "blockout", ms, 1000.0 / ms])
			if v[0] == "aparcamiento" or externos:
				await _guardar("%s_%s" % [v[0], "pack" if externos else "blockout"])
