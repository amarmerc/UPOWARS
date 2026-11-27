extends SceneTree
## Capturas del mapa (necesita GPU: NO usar --headless). Uso:
##   Godot_console.exe --path game --script res://tests/captura.gd [-- <carpeta_salida>]
## Guarda PNG en la carpeta (por defecto ../export/capturas) y sale.

const VISTAS := [
	# nombre, spawn (o posición absoluta), yaw_deg, pitch_deg, altura_ojo
	["spawn_entrada", "entrada", 0.0, 0.0, 1.7],
	["eje_central", "eje_central", 0.0, 0.0, 1.7],
	["aparcamiento", "aparcamiento", 0.0, -8.0, 1.7],
	["fachada_biblioteca", "biblioteca", 0.0, 5.0, 1.7],
	# fachadas: [nombre, "edif", osm_id, "larga"|"testero", lado (+1/-1), distancia a la fachada, desplazamiento a lo largo, altura mirada, altura_ojo]
	["fachada_rectorado", "edif", "1373541637", "larga", 1, 35.0, 10.0, 6.0, 1.7],
	["fachada_torre", "edif", "191918054", "larga", -1, 60.0, 0.0, 30.0, 1.7],
	["fachada_eje", "edif", "1373541644", "testero", -1, 45.0, 12.0, 6.0, 1.7],
	["fachada_eje_larga", "edif", "1373541644", "larga", 1, 30.0, 0.0, 6.0, 1.7],
	["fachada_24", "edif", "142262880", "larga", 1, 30.0, 30.0, 6.0, 1.7],
	["fachada_45", "edif", "142258873", "larga", 1, 12.0, 0.0, 3.0, 1.7],
	["fachada_45b", "edif", "142258873", "testero", 1, 20.0, 0.0, 3.0, 1.7],
	["fachada_rectorado_cerca", "edif", "1373541637", "larga", 1, 6.0, 15.0, 3.0, 1.7],
	["fachada_torre_cerca", "edif", "191918054", "larga", -1, 18.0, 0.0, 14.0, 1.7],
	["fachada_biblioteca_cerca", "edif", "142262877", "larga", 1, 6.0, 30.0, 2.5, 1.7],
	# borde: [nombre, "valla", dirección hacia fuera]: la cámara se coloca 6 m por dentro del poste más extremo en esa dirección
	["borde_oeste", "valla", Vector3(-1, 0, 0)],
	["borde_este", "valla", Vector3(1, 0, 0)],
	["borde_sur", "valla", Vector3(0, 0, 1)],
	# desde spawns.json (generar_spawns.py): [nombre, "json", bloque, clave, altura_ojo]; el bloque lleva "capturas"
	# {clave: {desde [x, y, z] (suelo), hacia [x, y, z]}}
	["pasillo_central_18", "json", "test_recorrido", "pasillo_central_18", 1.7],
	["escalera_arriba", "json", "test_recorrido", "escalera_arriba", 1.7],
	["marquesina_baja", "json", "test_recorrido", "marquesina_baja", 1.7],
	["puente_cauce", "json", "test_puente", "puente_cauce", 1.7],
	["zanja_macizo", "json", "test_puente", "zanja_macizo", 1.7],
	["aerea", Vector3(0.0, 0.0, 0.0), 20.0, -22.0, 140.0],
]


## y del terreno bajo (x, z), ignorando edificios y demas cuerpos (el rayo vertical cae por encima de los tejados).
func y_terreno(espacio: PhysicsDirectSpaceState3D, x: float, z: float, excluir: Array[RID]) -> float:
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, 300, z), Vector3(x, -300, z))
	q.exclude = excluir
	var r: Dictionary = espacio.intersect_ray(q)
	return (r["position"] as Vector3).y if not r.is_empty() else 0.0


func _init() -> void:
	_ejecutar.call_deferred()


func _ejecutar() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var salida: String = args[0] if args.size() > 0 else ProjectSettings.globalize_path("res://").path_join("../export/capturas")
	DirAccess.make_dir_recursive_absolute(salida)
	var main: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 10:
		await physics_frame
	main.menu.cerrar()
	main.hud.visible = false
	var jugador: Node3D = main.get_node("Jugador")
	jugador.set_physics_process(false)
	var cam := Camera3D.new()
	cam.far = 4500.0
	cam.fov = 75.0
	main.add_child(cam)
	cam.make_current()
	var espacio: PhysicsDirectSpaceState3D = (main as Node3D).get_world_3d().direct_space_state
	var no_terreno: Array[RID] = []
	for h: Node in main.find_children("*", "StaticBody3D", true, false):
		if h.get_parent().name != "terreno":
			no_terreno.append((h as StaticBody3D).get_rid())
	var spawns: Dictionary = {}
	for s: Dictionary in main.spawns:
		spawns[s["id"]] = s
	for v: Array in VISTAS:
		var pos: Vector3
		var yaw: float = 0.0
		var pitch: float = 0.0
		var ojo: float = 1.7
		if v[1] is String and v[1] == "valla":
			var dir: Vector3 = v[2]
			var vs: PackedVector3Array = ((main.find_child("valla_perimetral", true, false) as MeshInstance3D).mesh
					.surface_get_arrays(0)[Mesh.ARRAY_VERTEX])
			var mejor: Vector3 = vs[0]
			for p3: Vector3 in vs:
				if p3.dot(dir) > mejor.dot(dir):
					mejor = p3
			pos = mejor - dir * 6.0
			var q2 := PhysicsRayQueryParameters3D.create(Vector3(pos.x, 200, pos.z), Vector3(pos.x, -200, pos.z))
			var r2: Dictionary = espacio.intersect_ray(q2)
			pos.y = (r2["position"] as Vector3).y if not r2.is_empty() else 0.0
			yaw = rad_to_deg(atan2(-dir.x, -dir.z))
			pitch = 2.0
		elif v[1] is String and v[1] == "edif":
			var mi: MeshInstance3D = main.find_children("edif_%s_*" % v[2], "MeshInstance3D", true, false)[0]
			var e: Vector2 = mi.get_instance_shader_parameter("eje_principal")
			var ex: Vector4 = mi.get_instance_shader_parameter("ext_eje")
			var pe := Vector2(-e.y, e.x)
			var c: Vector2 = e * (ex.x + ex.y) * 0.5 + pe * (ex.z + ex.w) * 0.5
			var lado: float = float(v[4])
			var cara: Vector2
			var normal: Vector2
			var tang: Vector2
			if v[3] == "larga":
				normal = pe * lado
				tang = e
				cara = c + normal * (ex.w - ex.z) * 0.5
			else:
				normal = e * lado
				tang = pe
				cara = c + normal * (ex.y - ex.x) * 0.5
			var punto: Vector2 = cara + tang * float(v[6])
			# la huella no es un rectangulo: el punto de la pared real es el primer choque del rayo contra ese edificio
			var solo: Array[RID] = []
			for h: Node in main.find_children("*", "StaticBody3D", true, false):
				if not h.get_parent().name.begins_with("edif_%s_" % v[2]):
					solo.append((h as StaticBody3D).get_rid())
			var y_c: float = y_terreno(espacio, punto.x, punto.y, no_terreno) + 2.0
			var o3 := Vector3(punto.x + normal.x * 150.0, y_c, punto.y + normal.y * 150.0)
			var q6 := PhysicsRayQueryParameters3D.create(o3, Vector3(punto.x - normal.x * 150.0, y_c, punto.y - normal.y * 150.0))
			q6.exclude = solo
			var r6: Dictionary = espacio.intersect_ray(q6)
			if not r6.is_empty():
				punto = Vector2((r6["position"] as Vector3).x, (r6["position"] as Vector3).z)
			var desde: Vector2 = punto + normal * float(v[5])
			ojo = float(v[8])
			pos = Vector3(desde.x, 0.0, desde.y)
			pos.y = y_terreno(espacio, pos.x, pos.z, no_terreno)
			var yh2: float = pos.y + float(v[7])
			yaw = rad_to_deg(atan2(-(punto.x - desde.x), -(punto.y - desde.y)))
			pitch = rad_to_deg(atan2(yh2 - (pos.y + ojo), desde.distance_to(punto)))
			print(v[0], " cam=", pos, " yaw=", yaw)
		elif v[1] is String and v[1] == "json":
			var datos_j: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/spawns.json"))
			var cj: Dictionary = (datos_j[v[2]] as Dictionary)["capturas"][v[3]]
			var dj: Array = cj["desde"]
			var hj: Array = cj["hacia"]
			ojo = float(v[4])
			pos = Vector3(dj[0], dj[1], dj[2])
			var dxz: float = Vector2(float(hj[0]) - float(dj[0]), float(hj[2]) - float(dj[2])).length()
			yaw = rad_to_deg(atan2(-(float(hj[0]) - float(dj[0])), -(float(hj[2]) - float(dj[2]))))
			pitch = rad_to_deg(atan2(float(hj[1]) - (float(dj[1]) + ojo), dxz))
			print(v[0], " cam=", pos, " yaw=", yaw, " pitch=", pitch)
		elif v[1] is String and v[1] == "mira":
			var d: Vector2 = v[2]
			var h: Vector2 = v[3]
			ojo = float(v[5])
			pos = Vector3(d.x, 0.0, d.y)
			var q3 := PhysicsRayQueryParameters3D.create(Vector3(pos.x, 200, pos.z), Vector3(pos.x, -200, pos.z))
			var r3: Dictionary = espacio.intersect_ray(q3)
			pos.y = (r3["position"] as Vector3).y if not r3.is_empty() else 0.0
			var q4 := PhysicsRayQueryParameters3D.create(Vector3(h.x, 200, h.y), Vector3(h.x, -200, h.y))
			var r4: Dictionary = espacio.intersect_ray(q4)
			var yh: float = ((r4["position"] as Vector3).y if not r4.is_empty() else 0.0) + float(v[4])
			yaw = rad_to_deg(atan2(-(h.x - d.x), -(h.y - d.y)))
			pitch = rad_to_deg(atan2(yh - (pos.y + ojo), d.distance_to(h)))
		elif v[1] is String:
			pitch = float(v[3])
			ojo = float(v[4])
			var p: Array = spawns[v[1]]["pos"]
			pos = Vector3(p[0], p[1], p[2])
			yaw = float(spawns[v[1]]["yaw_deg"])
		else:
			yaw = v[2]
			pitch = float(v[3])
			ojo = float(v[4])
			pos = v[1]
			var q := PhysicsRayQueryParameters3D.create(Vector3(pos.x, 200, pos.z), Vector3(pos.x, -200, pos.z))
			var r: Dictionary = espacio.intersect_ray(q)
			pos.y = (r["position"] as Vector3).y if not r.is_empty() else 0.0
		cam.global_position = pos + Vector3(0, ojo, 0)
		cam.rotation = Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0)
		for i in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		var img: Image = root.get_viewport().get_texture().get_image()
		var ruta: String = salida.path_join(String(v[0]) + ".png")
		img.save_png(ruta)
		print("captura ", ruta, " ", img.get_size())
	await _combate(main, cam, salida)
	await _arsenal(main, cam, salida)
	quit(0)


## Guarda la ventana actual como PNG.
func _guardar(salida: String, nombre: String) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = root.get_viewport().get_texture().get_image()
	var ruta: String = salida.path_join(nombre + ".png")
	img.save_png(ruta)
	print("captura ", ruta, " ", img.get_size())


## Un disparo del gestor sin teclado (gatillo pulsado un instante).
func _disparar(gestor: GestorArmas, objetivo: Vector3, cam: Camera3D) -> void:
	cam.look_at(objetivo, Vector3.UP)
	gestor.gatillo = true
	gestor.avanzar(1.0 / 60.0)
	gestor.gatillo = false
	gestor.avanzar(1.0 / 60.0)


## Vistas del campo de practica con el fusil en mano, del HUD y de cada arma. Simula disparos antes de capturar.
func _combate(main: Node, cam_libre: Camera3D, salida: String) -> void:
	var jugador: Jugador = main.get_node("Jugador")
	var campo: CampoPractica = main.campo
	var gestor: GestorArmas = jugador.gestor
	var vm: CanvasLayer = gestor.get_node("Viewmodel")
	var n: int = 0
	while not campo.listo and n < 120:
		await physics_frame
		n += 1
	var sp: Dictionary = {}
	for s: Dictionary in main.spawns:
		if s["id"] == "campo_practica":
			sp = s
	if sp.is_empty():
		push_error("no hay spawn campo_practica")
		return
	main._colocar(sp)
	jugador.activo = true  # sin teclado: solo cae al suelo y fija is_on_floor
	jugador.set_physics_process(true)
	jugador.camara.make_current()
	gestor.entrada_manual = true
	gestor.rng.seed = 4242
	for i in 12:
		await physics_frame
	for i in 70:  # fin del cambio de arma inicial
		gestor.avanzar(1.0 / 60.0)
	main.hud.visible = false
	main.hud.get_node("Info").visible = false
	var d: Array[Diana] = campo.dianas
	var ojo: Vector3 = jugador.camara.global_position
	var fwd: Vector3 = campo.adelante

	# 1. campo de practica con el fusil: tres disparos al suelo (marcas, chispas) y uno a una diana (trazador, fogonazo)
	for k in 3:
		var p: Vector3 = campo.punto_tiro + fwd * (14.0 + 3.0 * k) + fwd.cross(Vector3.UP) * (1.0 - k * 1.2)
		await _disparar(gestor, Vector3(p.x, d[2].global_position.y, p.z), jugador.camara)
		for i in 10:
			gestor.avanzar(1.0 / 60.0)
			await process_frame
	jugador.camara.look_at(d[3].centro("torso"), Vector3.UP)
	for i in 30:
		gestor.avanzar(1.0 / 60.0)
	await _disparar(gestor, d[3].centro("torso"), jugador.camara)
	await process_frame
	await _guardar(salida, "combate_campo_fusil")

	# 2. HUD completo: disparo a la cabeza de la diana a 20 m (hit marker rojo, numero de dano), vineta de dano recibido
	for i in 40:
		gestor.avanzar(1.0 / 60.0)
		await process_frame
	main.hud.visible = true
	jugador.salud.recibir_dano(35.0, "torso", 1.0, null)
	jugador.salud.armadura = 60.0
	await _disparar(gestor, d[2].centro("cabeza"), jugador.camara)
	for i in 2:
		await process_frame
	await _guardar(salida, "combate_hud")

	# 3. vista del campo desde atras y arriba (dianas, carteles, armaduras)
	vm.visible = false
	main.hud.visible = false
	cam_libre.make_current()
	cam_libre.fov = 70.0
	var base: Vector3 = campo.punto_tiro - fwd * 6.0 + Vector3(0, 5.0, 0)
	cam_libre.global_position = base
	cam_libre.look_at(campo.punto_tiro + fwd * 30.0 + Vector3(0, 1.0, 0), Vector3.UP)
	for i in 6:
		await process_frame
	await _guardar(salida, "combate_campo_vista")
	vm.visible = true
	jugador.camara.make_current()

	# 4. las tres armas en mano (HUD visible), tras unos disparos / un tajo
	main.hud.visible = true
	jugador.salud.reiniciar()
	for idx in [1, 2]:
		gestor.cambiar_arma(idx)
		for i in 70:
			gestor.avanzar(1.0 / 60.0)
			await process_frame
		if idx == 1:
			await _disparar(gestor, d[1].centro("torso"), jugador.camara)
		else:
			gestor.gatillo_alt = true
			gestor.avanzar(1.0 / 60.0)
			gestor.gatillo_alt = false
			gestor.avanzar(1.0 / 60.0)
			for i in 12:
				await process_frame
		for i in 2:
			await process_frame
		await _guardar(salida, "combate_" + ("pistola" if idx == 1 else "navaja"))


# ======================================================================== arsenal (P2)

const ARSENAL_ORDEN: Array[StringName] = [
	&"pistola_9mm", &"pistola_auto", &"pistola_pesada", &"revolver_357", &"escopeta_recortada", &"subfusil_compacto",
	&"subfusil_9mm", &"subfusil_45", &"escopeta_corredera", &"escopeta_auto", &"carabina_556", &"fusil_asalto",
	&"fusil_combate", &"fusil_tirador", &"fusil_precision", &"ametralladora", &"arco_olivo", &"tirachinas",
	&"lanzacohetes", &"sable_plasma", &"puno_bot", &"navaja", &"granada_humo", &"granada_cegadora",
	&"granada_explosiva", &"bote_pintura", &"extintor", &"altavoz"]


## Frames de proceso (y de fisica) para que animaciones y efectos avancen.
func _frames(n: int) -> void:
	for i in n:
		await process_frame


## Mira al horizonte (algo hacia arriba) y avanza el gestor hasta terminar el cambio de arma.
func _listo(gestor: GestorArmas, jugador: Jugador, segundos: float = 1.3) -> void:
	for i in int(segundos * 60.0):
		gestor.avanzar(1.0 / 60.0)
		if i % 6 == 0:
			await process_frame
	await process_frame


## Capturas del arsenal: mosaico de todas las armas, fusil de precision apuntando, humo, explosion, sable bloqueando,
## arco cargando, arma en el suelo con el aviso de recoger y HUD con kill feed, marcas, direccion del dano y ceguera.
func _arsenal(main: Node, cam_libre: Camera3D, salida: String) -> void:
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
	var d: Array[Diana] = campo.dianas
	var fwd: Vector3 = campo.adelante
	for i in 20:
		await physics_frame
	# --- 1. mosaico: cada arma en la mano, mirando al cielo para un fondo limpio
	jugador._pitch = deg_to_rad(24.0)
	jugador._aplicar_rotacion_cabeza()
	var celdas: Array[Image] = []
	for id: StringName in ARSENAL_ORDEN:
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
		await _listo(gestor, jugador, 1.2)
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
	mosaico.save_png(salida.path_join("arsenal_mosaico.png"))
	print("captura ", salida.path_join("arsenal_mosaico.png"), " ", mosaico.get_size())
	gestor.inventario.utilidades.clear()
	gestor.reiniciar()

	# --- 2. fusil de precision apuntando (mira de zoom) a una diana a 35 m
	gestor.equipar(&"fusil_precision")
	jugador._pitch = 0.0
	jugador._aplicar_rotacion_cabeza()
	jugador.camara.look_at(d[5].centro("torso"), Vector3.UP)
	jugador.rotation.y += 0.0
	await _listo(gestor, jugador, 1.3)
	gestor.gatillo_alt = true
	await _listo(gestor, jugador, 0.8)
	jugador.camara.look_at(d[5].centro("cabeza"), Vector3.UP)
	await process_frame
	await _guardar(salida, "arsenal_precision_apuntando")
	gestor.gatillo_alt = false
	await _listo(gestor, jugador, 0.6)
	# mismo fusil sin apuntar, para comparar el viewmodel y la mira normal
	await _guardar(salida, "arsenal_precision_cadera")

	# --- 3. humo: una granada de humo explota a 9 m delante, entre el tirador y las dianas
	gestor.reiniciar()
	await _listo(gestor, jugador, 0.8)
	jugador.camara.look_at(jugador.camara.global_position + fwd * 10.0 + Vector3(0, -0.3, 0), Vector3.UP)
	var humo: ArmaDatos = Catalogo.arma(&"granada_humo")
	var punto: Vector3 = campo.punto_tiro + fwd * 9.0
	punto.y = campo._suelo(punto)
	Utilidades.activar(jugador, humo, punto, jugador)
	await _frames(70)
	await _guardar(salida, "arsenal_humo")
	for n: Node in get_nodes_in_group("nubes"):
		(n as NubeVision).avanzar(30.0)
	await _frames(3)

	# --- 4. explosion: granada explosiva junto a las dianas a 20 m (bola de fuego, humo, luz)
	var explosiva: ArmaDatos = Catalogo.arma(&"granada_explosiva")
	var pe: Vector3 = d[3].global_position + Vector3(-1.5, 0.3, 1.0)
	cam_libre.make_current()
	cam_libre.fov = 70.0
	cam_libre.global_position = campo.punto_tiro + fwd * 6.0 + Vector3(2.5, 2.0, 0)
	cam_libre.look_at(pe + Vector3(0, 1.2, 0), Vector3.UP)
	main.hud.visible = false
	jugador.get_node("Armas/Viewmodel").visible = false
	await _frames(4)
	Utilidades.explosion(jugador, pe, explosiva, jugador)
	await _frames(9)
	await _guardar(salida, "arsenal_explosion")
	await _frames(40)
	jugador.get_node("Armas/Viewmodel").visible = true
	jugador.camara.make_current()
	main.hud.visible = true
	for dd: Diana in d:
		dd.salud.reiniciar()
		dd.muerta = false
		dd.caida.rotation.x = 0.0
		dd.hitboxes.activar(true)

	# --- 5. sable de plasma bloqueando un disparo
	gestor.equipar(&"sable_plasma")
	jugador.camara.look_at(jugador.camara.global_position + fwd * 10.0, Vector3.UP)
	await _listo(gestor, jugador, 1.0)
	gestor.gatillo_alt = true
	await _listo(gestor, jugador, 0.4)
	var tirador := Node3D.new()
	root.add_child(tirador)
	tirador.global_position = jugador.camara.global_position + fwd * 9.0
	var pistola: ArmaDatos = Catalogo.arma(&"pistola_pesada")
	for k in 4:
		var r: Dictionary = Balistica.resolver_disparo(tirador.global_position,
				(jugador.hitboxes.centro_zona("torso") - tirador.global_position).normalized(), pistola, tirador, gestor.rng)
		Balistica.aplicar(r, pistola, tirador)
	await process_frame
	await _guardar(salida, "arsenal_sable_bloqueo")
	tirador.queue_free()
	gestor.gatillo_alt = false
	jugador.salud.reiniciar()
	await _listo(gestor, jugador, 0.6)

	# --- 6. arco cargando (la cuerda se tensa y sale la barra de carga)
	gestor.equipar(&"arco_olivo")
	await _listo(gestor, jugador, 1.0)
	gestor.gatillo = true
	await _listo(gestor, jugador, 0.7)
	await _guardar(salida, "arsenal_arco_carga")
	gestor.gatillo = false
	await _listo(gestor, jugador, 0.3)
	for p: Node in get_nodes_in_group("proyectiles"):
		p.queue_free()

	# --- 7. armas en el suelo: el aviso "E para recoger" al mirarlas
	gestor.reiniciar()
	await _listo(gestor, jugador, 0.8)
	var frente: Vector3 = campo.punto_tiro + fwd * 2.0
	var ids: Array[StringName] = [&"escopeta_corredera", &"fusil_precision", &"lanzacohetes", &"revolver_357"]
	for i in ids.size():
		var pos: Vector3 = frente + fwd.cross(Vector3.UP) * (float(i) * 0.9 - 1.4)
		pos.y = campo._suelo(pos) + 0.5
		ArmaSuelo.crear(jugador, ids[i], 5, 10, pos)
	await _frames(40)
	var objetivo: Node3D = get_nodes_in_group("armas_suelo")[1] as Node3D
	jugador._pitch = 0.0
	jugador.camara.look_at(objetivo.global_position + Vector3(0, 0.05, 0), Vector3.UP)
	jugador.rotation.y = jugador.rotation.y
	await _frames(6)
	await _guardar(salida, "arsenal_armas_suelo")
	gestor.limpiar_armas_suelo()

	# --- 8. HUD: utilidades, kill feed, marcas de pintura a traves de pared, direccion del dano y ceguera
	gestor.equipar(&"granada_humo")
	gestor.equipar(&"granada_humo")
	gestor.equipar(&"bote_pintura")
	gestor.equipar(&"granada_explosiva")
	gestor.cambiar_arma(3)
	await _listo(gestor, jugador, 1.0)
	jugador.camara.look_at(d[3].centro("torso"), Vector3.UP)
	jugador.salud.escudo = 40.0
	d[2].salud.marcar(0, 5.0)
	d[4].salud.marcar(0, 5.0)
	d[7].salud.recibir_dano(500.0, "cabeza", 1.0, jugador, Catalogo.arma(&"fusil_combate"))
	d[6].salud.recibir_dano(500.0, "torso", 1.0, jugador, Catalogo.arma(&"revolver_357"))
	jugador.salud.recibir_dano(22.0, "torso", 1.0, d[1])
	jugador.salud.recibir_dano(12.0, "torso", 1.0, d[3])
	await _frames(3)
	await _guardar(salida, "arsenal_hud")
	jugador.ceguera.cegar(1.0, 3.0)
	await _frames(2)
	await _guardar(salida, "arsenal_ceguera")
	jugador.ceguera.restante = 0.0
	gestor.kit_reaparicion = [&"fusil_asalto"]
	gestor.reiniciar()


## Oculta el arma en primera persona (la dibuja un script de combate en su propio SubViewport) para las capturas del mapa.
func _ocultar_viewmodel(main: Node) -> void:
	for n: Node in main.find_children("*", "", true, false):
		var sc: Script = n.get_script() as Script
		if sc != null and sc.resource_path.ends_with("viewmodel_capa.gd") and "visible" in n:
			n.set("visible", false)


## Tres capturas por zona competitiva:
##  zona_<id>.png         desde el spawn de defensores (barreras activas) mirando a un site, con la barrera del equipo a la vista;
##  zona_<id>_muro.png    desde dentro, a ~8 m del tramo del limite mas largo y despejado, mirando al muro translucido de 8 m;
##  zona_<id>_lobby.png   la camara de vista previa del lobby;
## y aula_aire_libre.png (detras de la ultima fila, mirando a la pizarra).
func _zonas(main: Node, cam: Camera3D, salida: String) -> void:
	_ocultar_viewmodel(main)
	var espacio: PhysicsDirectSpaceState3D = (main as Node3D).get_world_3d().direct_space_state
	for zid in ZonaActiva.ids_disponibles():
		var zona: ZonaActiva = ZonaActiva.crear(zid)
		main.add_child(zona)
		zona.activar_barreras(true)
		await physics_frame
		await physics_frame
		# 1) spawn de defensores: el spawn y el site con la vista mas despejada (rayo a 1,7 m hasta el centro del site)
		var mejor_pos: Vector3 = zona.punto_spawn("defensores", 2)["pos"]
		var mejor_obj: Vector3 = zona.centro_site("A") + Vector3(0, 1.2, 0)
		var mejor_libre: float = -1.0
		for i in zona.n_spawns("defensores"):
			var pos: Vector3 = zona.punto_spawn("defensores", i)["pos"]
			for k: String in zona.zona["sites"]:
				var obj: Vector3 = zona.centro_site(k) + Vector3(0, 1.2, 0)
				var ojo: Vector3 = pos + Vector3(0, 1.7, 0)
				var q := PhysicsRayQueryParameters3D.create(ojo, obj)
				q.collision_mask = ZonaActiva.CAPA_MUNDO
				var r: Dictionary = espacio.intersect_ray(q)
				var d: float = ojo.distance_to(obj)
				var libre: float = d if r.is_empty() else ojo.distance_to(r["position"])
				if libre > mejor_libre + (3.0 if i != 2 else 0.0):
					mejor_libre = libre
					mejor_pos = pos
					mejor_obj = obj
		cam.fov = 80.0
		cam.global_position = mejor_pos + Vector3(0, 1.7, 0)
		cam.look_at(mejor_obj, Vector3.UP)
		for i in 8:
			await process_frame
		await _guardar(salida, "zona_" + zid)
		# 2) el muro del limite: tramo largo desde el que un rayo hacia fuera acaba en el muro
		var lim: PackedVector2Array = zona.limites()["poligono"]
		var cuerpo_muro: StaticBody3D = zona.muro.get_node("Cuerpo") as StaticBody3D
		var elegido: Array = []
		var mejor_largo: float = 0.0
		for i in lim.size():
			var a: Vector2 = lim[i]
			var b: Vector2 = lim[(i + 1) % lim.size()]
			var largo: float = a.distance_to(b)
			if largo < 14.0 or largo <= mejor_largo:
				continue
			var medio: Vector2 = (a + b) * 0.5
			var t: Vector2 = (b - a).normalized()
			var normal: Vector2 = Vector2(-t.y, t.x)
			if not Geometry2D.is_point_in_polygon(medio + normal * 0.5, lim):
				normal = -normal
			var y0: float = zona.centro_site("A").y
			var desde := Vector3(medio.x + normal.x * 8.0, y0 + 2.0, medio.y + normal.y * 8.0)
			var q2 := PhysicsRayQueryParameters3D.create(desde, Vector3(medio.x - normal.x * 4.0, y0 + 2.0, medio.y - normal.y * 4.0))
			q2.collision_mask = ZonaActiva.CAPA_MUNDO
			var r2: Dictionary = espacio.intersect_ray(q2)
			if not r2.is_empty() and r2["collider"] == cuerpo_muro:
				mejor_largo = largo
				elegido = [medio, normal]
		if not elegido.is_empty():
			var medio_e: Vector2 = elegido[0]
			var normal_e: Vector2 = elegido[1]
			var qy := PhysicsRayQueryParameters3D.create(Vector3(medio_e.x + normal_e.x * 8.0, 200, medio_e.y + normal_e.y * 8.0),
					Vector3(medio_e.x + normal_e.x * 8.0, -50, medio_e.y + normal_e.y * 8.0))
			var ry: Dictionary = espacio.intersect_ray(qy)
			var suelo_y: float = (ry["position"] as Vector3).y if not ry.is_empty() else zona.centro_site("A").y
			cam.global_position = Vector3(medio_e.x + normal_e.x * 8.0, suelo_y + 1.7, medio_e.y + normal_e.y * 8.0)
			cam.look_at(Vector3(medio_e.x, suelo_y + 3.0, medio_e.y), Vector3.UP)
			for i in 8:
				await process_frame
			await _guardar(salida, "zona_" + zid + "_muro")
		# 3) vista previa del lobby
		var lc: Dictionary = zona.camara_lobby()
		cam.fov = float(lc["fov"])
		cam.global_position = lc["pos"]
		cam.look_at(lc["mira"], Vector3.UP)
		for i in 6:
			await process_frame
		await _guardar(salida, "zona_" + zid + "_lobby")
		zona.queue_free()
		await process_frame
	cam.fov = 75.0
	# aula al aire libre: detras de la ultima fila, mirando a la pizarra
	var datos: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/spawns.json"))
	var aula: Variant = datos.get("aula", null)
	if aula is Dictionary:
		var p: Array = aula["pos"]
		var yaw: float = deg_to_rad(float(aula["yaw_deg"]))
		var atras := Vector3(sin(yaw), 0, cos(yaw))
		var centro := Vector3(p[0], p[1], p[2])
		var desde: Vector3 = centro + atras * 11.0
		var q := PhysicsRayQueryParameters3D.create(Vector3(desde.x, 200, desde.z), Vector3(desde.x, -50, desde.z))
		var no_terreno: Array[RID] = []
		for h: Node in main.find_children("*", "StaticBody3D", true, false):
			if h.get_parent().name != "terreno":
				no_terreno.append((h as StaticBody3D).get_rid())
		q.exclude = no_terreno
		var r: Dictionary = (main as Node3D).get_world_3d().direct_space_state.intersect_ray(q)
		if not r.is_empty():
			desde.y = (r["position"] as Vector3).y
		cam.global_position = desde + Vector3(0, 2.2, 0)
		cam.look_at(centro + Vector3(0, 1.4, 0), Vector3.UP)
		for i in 8:
			await process_frame
		await _guardar(salida, "aula_aire_libre")
