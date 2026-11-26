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
	# borde: [nombre, "valla", dirección hacia fuera]: la cámara se coloca 6 m por dentro del poste más extremo en esa dirección
	["borde_oeste", "valla", Vector3(-1, 0, 0)],
	["borde_este", "valla", Vector3(1, 0, 0)],
	["borde_sur", "valla", Vector3(0, 0, 1)],
	["aerea", Vector3(0.0, 0.0, 0.0), 20.0, -22.0, 140.0],
]


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
	quit(0)
