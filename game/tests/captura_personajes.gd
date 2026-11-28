extends SceneTree
## Hoja de contacto de los personajes (necesita GPU). Uso: --script res://tests/captura_personajes.gd -- salida=<png> [arma=fusil_asalto] [anim=Idle_Gun] [yaw=0]
## Una fila por equipo (atacantes naranja, defensores azul); cada personaje de frente y de espalda.

func _init() -> void:
	_ejecutar.call_deferred()


func _ejecutar() -> void:
	var salida: String = ""
	var arma: StringName = &"fusil_asalto"
	var anim: String = "Idle_Gun"
	var yaws: Array[float] = [0.0, 180.0]
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("salida="):
			salida = a.substr(7)
		elif a.begins_with("arma="):
			arma = StringName(a.substr(5))
		elif a.begins_with("anim="):
			anim = a.substr(5)
		elif a.begins_with("yaws="):
			yaws = []
			for y: String in a.substr(5).split(","):
				yaws.append(float(y))
		elif a.begins_with("rot="):
			var v: PackedStringArray = a.substr(4).split(",")
			ModeloPersonaje.AJUSTE_MANO["rot"] = Vector3(deg_to_rad(float(v[0])), deg_to_rad(float(v[1])), deg_to_rad(float(v[2])))
		elif a.begins_with("pos="):
			var v2: PackedStringArray = a.substr(4).split(",")
			ModeloPersonaje.AJUSTE_MANO["pos"] = Vector3(float(v2[0]), float(v2[1]), float(v2[2]))
	var ids: Array[StringName] = CatalogoPersonajes.ids()
	var cw: int = 200
	var ch: int = 330
	var img := Image.create(cw * ids.size(), ch * yaws.size(), false, Image.FORMAT_RGBA8)
	var equipos: Array[Color] = [Bot.COLORES_EQUIPO[1], Bot.COLORES_EQUIPO[2]]
	for fila: int in yaws.size():
		var sv := SubViewport.new()
		sv.size = Vector2i(cw * ids.size(), ch)
		sv.own_world_3d = true
		sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		sv.msaa_3d = Viewport.MSAA_4X
		root.add_child(sv)
		var cam := Camera3D.new()
		cam.fov = 28.0
		cam.position = Vector3(0, 1.0, -9.5)
		sv.add_child(cam)
		cam.look_at(Vector3(0, 0.95, 0))
		cam.position = Vector3(float(ids.size() - 1) * 0.5 * 1.1, 1.0, -9.0)
		cam.look_at(Vector3(float(ids.size() - 1) * 0.5 * 1.1, 0.95, 0))
		var l := DirectionalLight3D.new()
		l.rotation_degrees = Vector3(-40, 160, 0)
		sv.add_child(l)
		var e := Environment.new()
		e.background_mode = Environment.BG_COLOR
		e.background_color = Color(0.55, 0.62, 0.7)
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		e.ambient_light_color = Color(0.9, 0.9, 1.0)
		e.ambient_light_energy = 0.7
		var we := WorldEnvironment.new()
		we.environment = e
		sv.add_child(we)
		for i in ids.size():
			var c: Node3D = ModeloPersonaje.crear(CatalogoPersonajes.por_id(ids[i]), equipos[0], true, true)
			c.position = Vector3(float(i) * 1.1, 0, 0)
			c.rotation_degrees.y = yaws[fila]
			sv.add_child(c)
			ModeloPersonaje.poner_arma(c, arma)
			var ap: AnimationPlayer = c.get_meta("anim")
			ap.play(ModeloPersonaje.PREFIJO_ANIM + anim)
		for k in 8:
			await process_frame
		await RenderingServer.frame_post_draw
		var t: Image = sv.get_texture().get_image()
		t.convert(Image.FORMAT_RGBA8)
		img.blit_rect(t, Rect2i(0, 0, t.get_width(), ch), Vector2i(0, fila * ch))
		sv.queue_free()
	img.save_png(salida)
	print("captura ", salida)
	quit(0)
