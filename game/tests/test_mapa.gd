extends SceneTree
## Test headless del mapa. Uso:
##   Godot_console.exe --headless --path game --script res://tests/test_mapa.gd
## Imprime PASS/FAIL por comprobación y sale con código 0 (todo bien) o 1.

var fallos: int = 0


func comprobar(nombre: String, ok: bool, detalle: String = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", nombre, detalle])
	if not ok:
		fallos += 1


func esperar_fisica(n: int) -> void:
	for i in n:
		await physics_frame


func _init() -> void:
	_ejecutar.call_deferred()


func _ejecutar() -> void:
	var main: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await esperar_fisica(5)

	var jugador: Jugador = main.get_node("Jugador")
	var mapa: Node = main.get_node("Mapa")
	var espacio: PhysicsDirectSpaceState3D = (main as Node3D).get_world_3d().direct_space_state

	# a) cuerpos de colisión de edificios
	var n_edif: int = 0
	var n_cuerpos: int = 0
	for h: Node in mapa.find_children("*", "StaticBody3D", true, false):
		n_cuerpos += 1
		if h.get_parent().name.begins_with("edif_"):
			n_edif += 1
	comprobar("a) cuerpos de colisión de edificios >= 70", n_edif >= 70,
			"edificios=%d, StaticBody3D totales=%d" % [n_edif, n_cuerpos])
	var limite: Node = mapa.find_child("limite", true, false)
	comprobar("a2) limite oculto pero con colisión",
			limite is MeshInstance3D and not (limite as MeshInstance3D).visible
			and limite.get_child_count() > 0 and limite.get_child(0) is StaticBody3D)

	# b) cada spawn: suelo a y~0 y cápsula libre
	var spawns: Array = main.spawns
	comprobar("b0) spawns cargados", spawns.size() == 6, "n=%d" % spawns.size())
	var caps := CapsuleShape3D.new()
	caps.radius = 0.35
	caps.height = 1.8
	for s: Dictionary in spawns:
		var p: Array = s["pos"]
		var pos := Vector3(p[0], p[1], p[2])
		var rq := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 5, 0), pos + Vector3(0, -5, 0))
		rq.exclude = [jugador.get_rid()]
		var r: Dictionary = espacio.intersect_ray(rq)
		var y_suelo: float = (r["position"] as Vector3).y if not r.is_empty() else NAN
		comprobar("b1) suelo bajo spawn '%s'" % s["nombre"],
				not r.is_empty() and absf(y_suelo) < 0.05, "y_suelo=%.3f" % y_suelo)
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = caps
		q.exclude = [jugador.get_rid()]
		q.transform = Transform3D(Basis.IDENTITY, pos + Vector3(0, 0.9 + 0.02, 0))
		var choques: Array[Dictionary] = espacio.intersect_shape(q, 8)
		comprobar("b2) cápsula libre en '%s'" % s["nombre"], choques.is_empty(),
				"choques=%d" % choques.size())

	# c) raycast horizontal desde el centro hacia +x
	var rc := PhysicsRayQueryParameters3D.create(Vector3(0, 1.5, 0), Vector3(2000, 1.5, 0))
	rc.exclude = [jugador.get_rid()]
	var hit: Dictionary = espacio.intersect_ray(rc)
	comprobar("c) rayo +x desde el centro choca antes de 2000 m", not hit.is_empty(),
			"x=%.1f" % ((hit["position"] as Vector3).x if not hit.is_empty() else NAN))

	# d) caída de ~2 s desde 2 m sobre un spawn
	for s: Dictionary in spawns:
		var p: Array = s["pos"]
		jugador.teletransportar(Vector3(p[0], p[1] + 2.0, p[2]), float(s["yaw_deg"]))
		jugador.activo = true
		await esperar_fisica(120)
		var y: float = jugador.global_position.y
		comprobar("d) jugador apoyado en '%s'" % s["nombre"],
				jugador.is_on_floor() and absf(y) < 0.05, "y=%.3f on_floor=%s" % [y, jugador.is_on_floor()])
		jugador.activo = false

	# e) pasillo cubierto central: se cruza a 1,5 m sin chocar; hacia arriba choca con la losa
	var datos: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/spawns.json"))
	var tp: Dictionary = (datos as Dictionary).get("test_pasillo", {})
	comprobar("e0) datos test_pasillo presentes", not tp.is_empty())
	if not tp.is_empty():
		var rh: Dictionary = tp["rayo_horizontal"]
		var d: Array = rh["desde"]
		var h: Array = rh["hasta"]
		var qh := PhysicsRayQueryParameters3D.create(Vector3(d[0], d[1], d[2]), Vector3(h[0], h[1], h[2]))
		qh.exclude = [jugador.get_rid()]
		var rhit: Dictionary = espacio.intersect_ray(qh)
		comprobar("e1) rayo horizontal a 1,5 m cruza el pasillo sin chocar", rhit.is_empty(),
				"choca en %s" % str(rhit.get("position", "nada")))
		var rv: Dictionary = tp["rayo_vertical"]
		var vd: Array = rv["desde"]
		var vh: Array = rv["hasta"]
		var qv := PhysicsRayQueryParameters3D.create(Vector3(vd[0], vd[1], vd[2]), Vector3(vh[0], vh[1], vh[2]))
		qv.exclude = [jugador.get_rid()]
		var vhit: Dictionary = espacio.intersect_ray(qv)
		var yv: float = (vhit["position"] as Vector3).y if not vhit.is_empty() else NAN
		comprobar("e2) rayo vertical choca con la losa del techo",
				not vhit.is_empty() and yv >= float(rv["techo_y_min"]) - 0.05 and yv <= float(rv["techo_y_max"]) + 0.05,
				"y=%.2f esperado [%.2f, %.2f]" % [yv, rv["techo_y_min"], rv["techo_y_max"]])

	# f) franja abierta entre los edificios 22 y 24: rayo horizontal a 1,5 m por el eje, de oeste
	#    a este y de extremo a extremo, sin chocar
	var tp2: Dictionary = (datos as Dictionary).get("test_paso_22_24", {})
	comprobar("f0) datos test_paso_22_24 presentes", not tp2.is_empty())
	if not tp2.is_empty():
		var rf: Dictionary = tp2["rayo_horizontal"]
		var fd: Array = rf["desde"]
		var fh: Array = rf["hasta"]
		var qf := PhysicsRayQueryParameters3D.create(Vector3(fd[0], fd[1], fd[2]), Vector3(fh[0], fh[1], fh[2]))
		qf.exclude = [jugador.get_rid()]
		var hf: Dictionary = espacio.intersect_ray(qf)
		comprobar("f1) rayo a 1,5 m por el eje de la franja 22-24 llega al extremo este sin chocar", hf.is_empty(),
				"choca en %s" % str(hf.get("position", "nada")))

	# g) cerramiento de las pistas de pádel
	# (Godot quita el sufijo -col del nombre del nodo y le añade un StaticBody3D hijo: padel-col -> "padel")
	var padel: Node = mapa.find_child("padel", true, false)
	comprobar("g) existe padel-col (nodo 'padel') con colisión",
			padel is MeshInstance3D and padel.find_children("*", "StaticBody3D", true, false).size() > 0)

	print("RESULTADO: %s (%d fallos)" % ["PASS" if fallos == 0 else "FAIL", fallos])
	main.queue_free()
	await process_frame
	quit(0 if fallos == 0 else 1)
