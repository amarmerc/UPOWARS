extends SceneTree
## Test headless del mapa. Uso:
##   Godot_console.exe --headless --path game --script res://tests/test_mapa.gd
## Imprime PASS/FAIL por comprobación y sale con código 0 (todo bien) o 1.
## El suelo ya no es plano: las alturas esperadas salen de spawns.json (generar_spawns.py), que usa la misma
## función altura(x, z) que generó el terreno. Tolerancia general contra el terreno: +-0,3 m.

const TOL_TERRENO: float = 0.3

var fallos: int = 0


func comprobar(nombre: String, ok: bool, detalle: String = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", nombre, detalle])
	if not ok:
		fallos += 1


## Primer choque de un rayo {"desde", "hasta", "tramos"}: los tramos se recorren en orden (sin "tramos" se usa
## desde-hasta). Diccionario vacío si ningún tramo choca.
func primer_choque(espacio: PhysicsDirectSpaceState3D, jugador: Jugador, rd: Dictionary) -> Dictionary:
	var tramos: Array = rd.get("tramos", [[rd["desde"], rd["hasta"]]])
	for t: Array in tramos:
		var d: Array = t[0]
		var h: Array = t[1]
		var q := PhysicsRayQueryParameters3D.create(Vector3(d[0], d[1], d[2]), Vector3(h[0], h[1], h[2]))
		q.exclude = [jugador.get_rid()]
		var r: Dictionary = espacio.intersect_ray(q)
		if not r.is_empty():
			return r
	return {}


## Nombre del nodo de malla dueño del collider (Godot cuelga el StaticBody3D del MeshInstance3D "-col").
func dueno(r: Dictionary) -> String:
	if r.is_empty():
		return ""
	var c: Node = r["collider"] as Node
	return str(c.get_parent().name) if c.get_parent() != null else str(c.name)


func describir(r: Dictionary) -> String:
	return "nada" if r.is_empty() else "%s en %s" % [dueno(r), str(r["position"])]


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
	var datos: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/spawns.json"))

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

	# t1) terreno-col (Godot: nodo "terreno" con StaticBody3D y CollisionShape3D)
	var terreno: Node = mapa.find_child("terreno", true, false)
	comprobar("t1) existe terreno-col (nodo 'terreno') con colisión",
			terreno is MeshInstance3D and terreno.find_children("*", "StaticBody3D", true, false).size() > 0
			and terreno.find_children("*", "CollisionShape3D", true, false).size() > 0)

	# t2) 5 puntos repartidos con cotas distintas: un rayo vertical choca con el terreno a +-0,3 m de lo esperado
	var tt: Dictionary = datos.get("test_terreno", {})
	comprobar("t2-0) datos test_terreno presentes (5 puntos)", tt.has("puntos") and (tt["puntos"] as Array).size() == 5)
	if tt.has("puntos"):
		var ys: Array[float] = []
		for pt: Dictionary in tt["puntos"]:
			var pp: Array = pt["pos"]
			var ye: float = pp[1]
			ys.append(ye)
			var q := PhysicsRayQueryParameters3D.create(Vector3(pp[0], ye + 40.0, pp[2]), Vector3(pp[0], ye - 40.0, pp[2]))
			q.exclude = [jugador.get_rid()]
			var r: Dictionary = espacio.intersect_ray(q)
			var yh: float = (r["position"] as Vector3).y if not r.is_empty() else NAN
			comprobar("t2) rayo vertical en el punto '%s' choca con el terreno a +-%.1f m" % [pt["nombre"], TOL_TERRENO],
					not r.is_empty() and dueno(r) == "terreno" and absf(yh - ye) <= TOL_TERRENO,
					"y_esperada=%.3f y_choque=%.3f collider=%s" % [ye, yh, dueno(r)])
		ys.sort()
		comprobar("t2-1) los 5 puntos tienen cotas distintas (desnivel >= 5 m)", ys[4] - ys[0] >= 5.0,
				"desnivel=%.2f m" % (ys[4] - ys[0]))

	# b) cada spawn: suelo a la altura del terreno (+-0,3 m) y cápsula libre
	var spawns: Array = main.spawns
	comprobar("b0) spawns cargados", spawns.size() == 6, "n=%d" % spawns.size())
	var caps := CapsuleShape3D.new()
	caps.radius = 0.35
	caps.height = 1.8
	for s: Dictionary in spawns:
		var p: Array = s["pos"]
		var pos := Vector3(p[0], p[1], p[2])
		var yt: float = s["y_terreno"]
		var rq := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 5, 0), pos + Vector3(0, -5, 0))
		rq.exclude = [jugador.get_rid()]
		var r: Dictionary = espacio.intersect_ray(rq)
		var y_suelo: float = (r["position"] as Vector3).y if not r.is_empty() else NAN
		comprobar("b1) suelo bajo spawn '%s' a la altura del terreno" % s["nombre"],
				not r.is_empty() and absf(y_suelo - yt) <= TOL_TERRENO,
				"y_suelo=%.3f y_terreno=%.3f" % [y_suelo, yt])
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = caps
		q.exclude = [jugador.get_rid()]
		q.transform = Transform3D(Basis.IDENTITY, pos + Vector3(0, 0.9 + 0.02, 0))
		var choques: Array[Dictionary] = espacio.intersect_shape(q, 8)
		comprobar("b2/k4) cápsula libre (sin árboles ni coches) en '%s'" % s["nombre"], choques.is_empty(),
				"choques=%d" % choques.size())

	# c) raycast horizontal desde el centro hacia +x (a 1,5 m sobre el terreno del origen, y_terreno del spawn
	#    más cercano no hace falta: el rayo termina en el muro límite o en el terreno)
	var rc := PhysicsRayQueryParameters3D.create(Vector3(0, 1.5, 0), Vector3(2000, 1.5, 0))
	rc.exclude = [jugador.get_rid()]
	var hit: Dictionary = espacio.intersect_ray(rc)
	comprobar("c) rayo +x desde el centro choca antes de 2000 m", not hit.is_empty(),
			"x=%.1f" % ((hit["position"] as Vector3).x if not hit.is_empty() else NAN))

	# d) caída de ~2 s desde 2 m sobre un spawn: queda apoyado sobre el terreno (+-0,3 m)
	for s: Dictionary in spawns:
		var p: Array = s["pos"]
		jugador.teletransportar(Vector3(p[0], p[1] + 2.0, p[2]), float(s["yaw_deg"]))
		jugador.activo = true
		await esperar_fisica(120)
		var y: float = jugador.global_position.y
		var yt: float = s["y_terreno"]
		comprobar("d/k4) jugador apoyado en '%s'" % s["nombre"],
				jugador.is_on_floor() and absf(y - yt) <= TOL_TERRENO,
				"y=%.3f y_terreno=%.3f on_floor=%s" % [y, yt, jugador.is_on_floor()])
		jugador.activo = false

	# e) pasillo cubierto central: se cruza a 1,5 m sobre el terreno sin chocar; hacia arriba choca con la losa
	var tp: Dictionary = datos.get("test_pasillo", {})
	comprobar("e0) datos test_pasillo presentes", not tp.is_empty())
	if not tp.is_empty():
		var rhit: Dictionary = primer_choque(espacio, jugador, tp["rayo_horizontal"])
		comprobar("e1) rayo horizontal a 1,5 m sobre el terreno cruza el pasillo sin chocar", rhit.is_empty(),
				"choca en %s" % describir(rhit))
		var rv: Dictionary = tp["rayo_vertical"]
		var vd: Array = rv["desde"]
		var vh: Array = rv["hasta"]
		var qv := PhysicsRayQueryParameters3D.create(Vector3(vd[0], vd[1], vd[2]), Vector3(vh[0], vh[1], vh[2]))
		qv.exclude = [jugador.get_rid()]
		var vhit: Dictionary = espacio.intersect_ray(qv)
		var yv: float = (vhit["position"] as Vector3).y if not vhit.is_empty() else NAN
		comprobar("e2) rayo vertical choca con la losa inclinada del pasillo",
				not vhit.is_empty() and yv >= float(rv["techo_y_min"]) - 0.15 and yv <= float(rv["techo_y_max"]) + 0.15,
				"y=%.3f esperado [%.3f, %.3f] collider=%s" % [yv, rv["techo_y_min"], rv["techo_y_max"], dueno(vhit)])

	# f) franja abierta entre los edificios 22 y 24: rayo a 1,5 m sobre el terreno por el eje, de oeste
	#    a este y de extremo a extremo, sin chocar
	var tp2: Dictionary = datos.get("test_paso_22_24", {})
	comprobar("f0) datos test_paso_22_24 presentes", not tp2.is_empty())
	if not tp2.is_empty():
		var hf: Dictionary = primer_choque(espacio, jugador, tp2["rayo_horizontal"])
		comprobar("f1) rayo a 1,5 m por el eje de la franja 22-24 llega al extremo este sin chocar", hf.is_empty(),
				"choca en %s" % describir(hf))

	# j) marquesinas 18-24 (building=roof, losa plana): la larga a una cota constante y la corta a su misma cota
	var tm: Dictionary = datos.get("test_marquesinas", {})
	comprobar("j0) datos test_marquesinas presentes", tm.has("larga") and tm.has("corta"))
	if tm.has("larga") and tm.has("corta"):
		var medias: Dictionary = {}
		for clave: String in ["larga", "corta"]:
			var ys_m: Array[float] = []
			var ok_dueno: bool = true
			var det: String = ""
			for pt: Dictionary in tm[clave]["puntos"]:
				var d_: Array = pt["desde"]
				var h_: Array = pt["hasta"]
				var qm := PhysicsRayQueryParameters3D.create(Vector3(d_[0], d_[1], d_[2]), Vector3(h_[0], h_[1], h_[2]))
				qm.exclude = [jugador.get_rid()]
				var rm: Dictionary = espacio.intersect_ray(qm)
				var ym: float = (rm["position"] as Vector3).y if not rm.is_empty() else NAN
				ys_m.append(ym)
				ok_dueno = ok_dueno and dueno(rm).begins_with("edif_%d_" % int(tm[clave]["id"]))
				det += " %.3f" % ym
			var mn: float = ys_m.min()
			var mx: float = ys_m.max()
			var media: float = (mn + mx) / 2.0
			medias[clave] = media
			if clave == "larga":
				comprobar("j1) 5 rayos verticales bajo la marquesina larga chocan con su losa y la cota varía < 0,05 m",
						ys_m.size() == 5 and ok_dueno and not is_nan(mn) and mx - mn < 0.05,
						"y=[%s ] dispersión=%.4f" % [det, mx - mn])
			else:
				var dif: float = absf(media - float(medias["larga"]))
				comprobar("j2) la losa de la marquesina corta está a la cota de la larga (±0,05 m)",
						ok_dueno and not is_nan(mn) and mx - mn < 0.05 and dif <= 0.05,
						"y=[%s ] media_corta=%.3f media_larga=%.3f dif=%.4f" % [det, media, medias["larga"], dif])
	# j3) el bloque 1373674172 (excluido) ya no existe y la franja 22-24 sigue libre
	var hay_bloque: bool = false
	for h: Node in mapa.find_children("*", "MeshInstance3D", true, false):
		if str(h.name).begins_with("edif_1373674172"):
			hay_bloque = true
	var hf3: Dictionary = primer_choque(espacio, jugador, tp2["rayo_horizontal"]) if not tp2.is_empty() else {"x": 1}
	comprobar("j3) franja 22-24 libre y sin el bloque 1373674172", not hay_bloque and hf3.is_empty(),
			"bloque_presente=%s choque=%s" % [hay_bloque, describir(hf3) if hf3.has("collider") else "nada"])

	# g) cerramiento de las pistas de pádel
	# (Godot quita el sufijo -col del nombre del nodo y le añade un StaticBody3D hijo: padel-col -> "padel")
	var padel: Node = mapa.find_child("padel", true, false)
	comprobar("g) existe padel-col (nodo 'padel') con colisión",
			padel is MeshInstance3D and padel.find_children("*", "StaticBody3D", true, false).size() > 0)

	# h) tunel del 37 y pasillo central sin pilares interiores
	#    h2 debe chocar con la pared DEL EDIFICIO (no con el terreno): se comprueba el dueño del collider
	var casos: Array = [
		["h1", "test_tunel_37", "rayo_norte_sur", true, "rayo a 1,5 m N-S por el centro del 37 no choca"],
		["h2", "test_tunel_37", "rayo_oeste_este", false, "rayo a 1,5 m O-E por el centro del 37 choca con la pared"],
		["h3", "test_pasillo_pilares", "rayo_horizontal", true, "rayo a 1,5 m por el eje del pasillo (30 m) no choca"],
	]
	for caso: Array in casos:
		var dd: Dictionary = datos.get(caso[1], {})
		if dd.is_empty():
			comprobar("%s) datos %s presentes" % [caso[0], caso[1]], false)
			continue
		var hr: Dictionary = primer_choque(espacio, jugador, dd[caso[2]])
		var ok: bool = hr.is_empty() == caso[3]
		if not caso[3] and not hr.is_empty():
			ok = ok and dueno(hr).begins_with("edif_")
		comprobar("%s) %s" % [caso[0], caso[4]], ok, "choca en %s" % describir(hr))

	# i) subida: el jugador camina cuesta arriba por el tramo de mayor pendiente del campus (floor_max_angle)
	var ts: Dictionary = datos.get("test_subida", {})
	comprobar("i0) datos test_subida presentes", not ts.is_empty())
	if not ts.is_empty():
		var a: Array = ts["desde"]
		var b: Array = ts["hasta"]
		jugador.teletransportar(Vector3(a[0], a[1], a[2]), float(ts["yaw_deg"]))
		jugador.activo = true
		await esperar_fisica(30)
		Input.action_press("mover_adelante")
		var llegado: bool = false
		for i in 360:  # hasta 6 s
			await physics_frame
			var d_xz: float = Vector2(jugador.global_position.x - a[0], jugador.global_position.z - a[2]).length()
			if d_xz >= float(ts["longitud_m"]):
				llegado = true
				break
		Input.action_release("mover_adelante")
		await esperar_fisica(30)
		var yf: float = jugador.global_position.y
		comprobar("i) el jugador sube %.1f grados (floor_max_angle=%.0f) y recorre %.0f m de rampa" % [
				ts["pendiente_grados"], rad_to_deg(jugador.floor_max_angle), ts["longitud_m"]],
				llegado and yf >= float(b[1]) - 0.5,
				"y_final=%.2f y_cima=%.2f llegado=%s" % [yf, b[1], llegado])
		jugador.activo = false

	# k) vegetación y coches
	#    (Godot quita el sufijo -col: arboles_troncos-col -> "arboles_troncos", coches-col -> "coches")
	var troncos: Node = mapa.find_child("arboles_troncos", true, false)
	var copas: Array[Node] = mapa.find_children("arboles_copas*", "MeshInstance3D", true, false)
	var n_coches_col: int = 0
	var coches_mallas: int = 0
	for h: Node in mapa.find_children("coches_*", "MeshInstance3D", true, false):
		coches_mallas += 1
		if not h.find_children("*", "StaticBody3D", true, false).is_empty():
			n_coches_col += 1
	comprobar("k1) existen arboles_troncos-col y coches-col (coches_<color>-col) con colisión",
			troncos is MeshInstance3D and troncos.find_children("*", "StaticBody3D", true, false).size() > 0
			and n_coches_col >= 3,
			"nodos de coches con colisión=%d de %d" % [n_coches_col, coches_mallas])
	var copas_con_col: int = 0
	for c: Node in copas:
		copas_con_col += c.find_children("*", "StaticBody3D", true, false).size()
	comprobar("k1b) las copas (arboles_copas*) existen y NO tienen colisión", copas.size() >= 1 and copas_con_col == 0,
			"nodos de copas=%d, cuerpos de colisión=%d" % [copas.size(), copas_con_col])
	var n_arb: int = int(datos.get("n_arboles", 0))
	var n_coc: int = int(datos.get("n_coches", 0))
	comprobar("k2) árboles >= 100 y coches >= 50", n_arb >= 100 and n_coc >= 50,
			"arboles=%d coches=%d (parking=%d, carretera=%d)" % [n_arb, n_coc, int(datos.get("n_coches_parking", 0)),
			int(datos.get("n_coches_carretera", 0))])
	var tc: Dictionary = datos.get("test_coche", {})
	comprobar("k3-0) datos test_coche presentes", not tc.is_empty())
	if not tc.is_empty():
		var rc3: Dictionary = primer_choque(espacio, jugador, tc)
		comprobar("k3) rayo horizontal a 0,8 m hacia el coche %d (%s) choca con él" % [int(tc["id"]), tc["origen"]],
				dueno(rc3).begins_with("coches_"), "choca en %s" % describir(rc3))
	var ta: Dictionary = datos.get("test_arbol", {})
	comprobar("k5-0) datos test_arbol presentes", not ta.is_empty())
	if not ta.is_empty():
		var rt: Dictionary = primer_choque(espacio, jugador, ta["rayo_tronco"])
		comprobar("k5) rayo horizontal a 1 m hacia un tronco choca con arboles_troncos", dueno(rt) == "arboles_troncos",
				"choca en %s" % describir(rt))
		var rcp: Dictionary = primer_choque(espacio, jugador, ta["rayo_copa"])
		comprobar("k6) rayo horizontal por el centro de la copa (a 75 % de la altura) no choca con nada", rcp.is_empty(),
				"choca en %s" % describir(rcp))

	print("RESULTADO: %s (%d fallos)" % ["PASS" if fallos == 0 else "FAIL", fallos])
	main.queue_free()
	await process_frame
	quit(0 if fallos == 0 else 1)
