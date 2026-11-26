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
