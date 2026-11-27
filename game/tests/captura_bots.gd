extends SceneTree
## Capturas de bots en combate (necesita GPU: NO usar --headless). Uso:
##   Godot_console.exe --path game --script res://tests/captura_bots.gd [-- salida=<carpeta> zona=el_eje modo=cachimba dificultad=normal]
## Monta la escena de prueba sin jugador, acelera la simulacion y, cuando un bot tiene a un enemigo en el punto de mira, hace una
## captura desde detras del bot (maximo 8). Guarda bots_<n>.png en export/capturas_p3 por defecto.

var salida: String = ""


func _init() -> void:
	_ejecutar.call_deferred()


func _ejecutar() -> void:
	salida = ProjectSettings.globalize_path("res://").path_join("../export/capturas_p3")
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("salida="):
			salida = a.substr(7)
	DirAccess.make_dir_recursive_absolute(salida)
	var prueba: Node = (load("res://scenes/prueba_bots.tscn") as PackedScene).instantiate()
	prueba.opciones["jugador"] = "0"
	root.add_child(prueba)
	for i in 200:
		await physics_frame
		if prueba.director != null and prueba.director.bots.size() > 0 and prueba.director.t_ronda > 0.1:
			break
	prueba._etiqueta.visible = true
	var cam := Camera3D.new()
	cam.far = 1500.0
	cam.fov = 70.0
	prueba.add_child(cam)
	cam.make_current()
	# la camara de captura manda: sin el arma ni el HUD del jugador observador
	prueba.jugador.gestor.mostrar_viewmodel(false)
	prueba.main.hud.visible = false
	Engine.time_scale = 3.0
	var hechas: int = 0
	var ultimo: float = -10.0
	var ts: float = 0.0
	while hechas < 8 and ts < 120.0:
		await physics_frame
		ts += 1.0 / 60.0
		var d: DirectorBots = prueba.director
		if d == null or ts - ultimo < 4.0:
			continue
		var mejor: Bot = null
		for b: Bot in d.bots:
			if not b.muerto and not b.cerebro.objetivo.is_empty() and b.cerebro.estado == CerebroBot.Estado.COMBATE:
				mejor = b
				break
		var c: Cachimba = prueba.partida.cachimba()
		if mejor == null and c != null and c.estado != Cachimba.Estado.SIN_MONTAR and hechas % 2 == 1:
			cam.global_position = c.global_position + Vector3(6, 4, 6)
			cam.look_at(c.global_position + Vector3(0, 0.6, 0))
		elif mejor != null:
			var tgt: Vector3 = mejor.cerebro.objetivo["torso"]
			var atras: Vector3 = (mejor.global_position - tgt)
			atras.y = 0.0
			atras = atras.normalized()
			cam.global_position = mejor.global_position + atras * 4.0 + Vector3(0, 2.4, 0)
			cam.look_at(mejor.global_position.lerp(tgt, 0.3) + Vector3(0, 1.3, 0))
		else:
			continue
		ultimo = ts
		Engine.time_scale = 0.05   # congela un instante para que el fotograma sea limpio
		await process_frame
		await process_frame
		var img: Image = root.get_viewport().get_texture().get_image()
		img.save_png(salida.path_join("bots_%d.png" % hechas))
		print("captura bots_%d.png (t=%.0f s)" % [hechas, ts])
		hechas += 1
		Engine.time_scale = 3.0
	Engine.time_scale = 1.0
	quit(0)
