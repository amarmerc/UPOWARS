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


## Camina por los puntos de paso `wps` ([x, y, z]) desde el indice `desde`: gira hacia cada uno y avanza (mover_adelante debe estar
## pulsado). Atascado = 3 s sin acercarse al punto. Devuelve {"idx", "atascado", "frames", "y_min", "y_max"}.
func caminar(jugador: Jugador, wps: Array, desde: int) -> Dictionary:
	var idx: int = desde
	var atascado: bool = false
	var mejor: float = INF
	var sin_progreso: int = 0
	var frames: int = 0
	var y_min: float = INF
	var y_max: float = -INF
	while idx < wps.size() and frames < 14000:
		var pos3: Vector3 = jugador.global_position
		var dv := Vector2(float(wps[idx][0]) - pos3.x, float(wps[idx][2]) - pos3.z)
		if dv.length() < 1.2:
			idx += 1
			mejor = INF
			sin_progreso = 0
			continue
		jugador.rotation.y = atan2(-dv.x, -dv.y)
		await physics_frame
		frames += 1
		y_min = minf(y_min, jugador.global_position.y)
		y_max = maxf(y_max, jugador.global_position.y)
		if dv.length() < mejor - 0.02:
			mejor = dv.length()
			sin_progreso = 0
		else:
			sin_progreso += 1
			if sin_progreso > 180:
				atascado = true
				break
	return {"idx": idx, "atascado": atascado, "frames": frames, "y_min": y_min, "y_max": y_max}


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
	comprobar("b0) spawns cargados (6 del campus + campo de práctica)", spawns.size() == 7, "n=%d" % spawns.size())
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

	# p) suelos de pasillo: pasillo central y marquesina 553042591 (puente macizo sobre el cauce)
	var tsu: Dictionary = datos.get("test_suelos", {})
	comprobar("p1-0) datos test_suelos de 2 pasillos", tsu.size() == 2)
	for clave: String in tsu:
		var ds: Dictionary = tsu[clave]
		var ye: Array = ds["y_esperada"]
		var desv_max: float = 0.0
		var todos_terreno: bool = true
		var n_pts: int = 0
		for ip in (ds["puntos"] as Array).size():
			var pt: Array = ds["puntos"][ip]
			var yp: float = float(ye[ip])
			var qs := PhysicsRayQueryParameters3D.create(Vector3(pt[0], yp + 0.8, pt[1]), Vector3(pt[0], yp - 1.5, pt[1]))
			qs.exclude = [jugador.get_rid()]
			var rs: Dictionary = espacio.intersect_ray(qs)
			n_pts += 1
			if rs.is_empty() or dueno(rs) != "terreno":
				todos_terreno = false
				desv_max = INF
			else:
				desv_max = maxf(desv_max, absf((rs["position"] as Vector3).y - yp))
		comprobar("p1) %s (suelo=%s): 10 puntos del suelo a < %.2f m de su %s (pendiente media %.2f grados)" % [clave, ds["modo"], ds["tolerancia_m"], "plano" if ds["modo"] == "plano" else "perfil suelo(s) del eje", ds["pendiente_grados"]],
				n_pts == 10 and todos_terreno and desv_max < float(ds["tolerancia_m"]),
				"puntos=%d desviacion_max=%.4f m" % [n_pts, desv_max])
		if ds.has("secciones"):
			var secs: Array = ds["secciones"]
			var dif_max: float = 0.0
			for sc: Dictionary in secs:
				var ys2: Array[float] = []
				for lado: String in ["izq", "der"]:
					var pl2: Array = sc[lado]
					var qs2 := PhysicsRayQueryParameters3D.create(Vector3(pl2[0], 40.0, pl2[1]), Vector3(pl2[0], -40.0, pl2[1]))
					qs2.exclude = [jugador.get_rid()]
					# el rayo parte por encima de la losa: se ignora lo que no sea terreno (losa, pilares)
					var arriba: float = 40.0
					var rs2: Dictionary = {}
					for intento in 4:
						rs2 = espacio.intersect_ray(qs2)
						if rs2.is_empty() or dueno(rs2) == "terreno":
							break
						qs2.exclude.append(rs2["collider"].get_rid())
					ys2.append((rs2["position"] as Vector3).y if not rs2.is_empty() else NAN)
				dif_max = maxf(dif_max, absf(ys2[0] - ys2[1]))
			comprobar("p1b) %s: en %d secciones transversales la cota del borde izquierdo y la del derecho (a 1,5 m del eje) difiere < 0,05 m" % [clave, secs.size()],
					secs.size() >= 5 and dif_max < 0.05, "diferencia_max=%.4f m" % dif_max)
	var tpu: Dictionary = datos.get("test_puente", {})
	comprobar("p2-0) datos test_puente presentes", not tpu.is_empty())
	if not tpu.is_empty():
		for lado: String in ["no"]:
			var rr: Dictionary = tpu["rayo_pretil_" + lado]
			var dd: Array = rr["desde"]
			var hh: Array = rr["hasta"]
			var qp := PhysicsRayQueryParameters3D.create(Vector3(dd[0], dd[1], dd[2]), Vector3(hh[0], hh[1], hh[2]))
			qp.exclude = [jugador.get_rid()]
			var rp: Dictionary = espacio.intersect_ray(qp)
			var dh: float = Vector2((rp["position"] as Vector3).x - dd[0], (rp["position"] as Vector3).z - dd[2]).length() if not rp.is_empty() else NAN
			comprobar("p2) rayo horizontal a 0,5 m sobre el puente hacia el lado %s choca con el pretil/muro (a %.1f m)" % [lado.to_upper(), rr["dist_esperada_m"]],
					not rp.is_empty() and dueno(rp).begins_with("muros_suelo") and absf(dh - float(rr["dist_esperada_m"])) < 0.6,
					"choca en %s a %.2f m (desnivel exterior %.1f m)" % [describir(rp), dh, rr["desnivel_m"]])
		var rb: Dictionary = tpu["rayo_bajo"]
		var bd: Array = rb["desde"]
		var bh: Array = rb["hasta"]
		var qb := PhysicsRayQueryParameters3D.create(Vector3(bd[0], bd[1], bd[2]), Vector3(bh[0], bh[1], bh[2]))
		qb.exclude = [jugador.get_rid()]
		var rbh: Dictionary = espacio.intersect_ray(qb)
		var db: float = Vector2((rbh["position"] as Vector3).x - bd[0], (rbh["position"] as Vector3).z - bd[2]).length() if not rbh.is_empty() else NAN
		comprobar("p2b) rayo horizontal por debajo del puente (de la zanja NO a la SE, %.1f m bajo la cubierta) choca con el macizo" % (float(rb["cubierta_y"]) - float(bd[1])),
				not rbh.is_empty() and (dueno(rbh) == "terreno" or dueno(rbh).begins_with("muros_suelo"))
				and db >= float(rb["dist_entrada_zona_m"]) - 0.2 and db <= float(rb["dist_salida_zona_m"]) + 0.2,
				"choca en %s a %.2f m (zona aplanada entre %.2f y %.2f m)" % [describir(rbh), db, rb["dist_entrada_zona_m"], rb["dist_salida_zona_m"]])
	var tre: Dictionary = datos.get("test_recorrido", {})
	comprobar("p3-0) datos test_recorrido (ida y vuelta)", tre.has("ida") and (tre["ida"] as Array).size() >= 10 and tre.has("vuelta"))
	if tre.has("ida"):
		var ida: Array = tre["ida"]
		var vuelta: Array = tre["vuelta"]
		var w0: Array = ida[0]
		jugador.teletransportar(Vector3(w0[0], float(w0[1]) + 0.3, w0[2]), 0.0)
		jugador.activo = true
		await esperar_fisica(30)
		Input.action_press("mover_adelante")
		var r1: Dictionary = await caminar(jugador, ida, 1)
		var y_fin_ida: float = jugador.global_position.y
		var r2: Dictionary = await caminar(jugador, vuelta, 0)
		Input.action_release("mover_adelante")
		await esperar_fisica(20)
		var esc: Dictionary = tre["escalera"]
		var wl: Array = vuelta[vuelta.size() - 1]
		var dfin: float = Vector2(jugador.global_position.x - float(wl[0]), jugador.global_position.z - float(wl[2])).length()
		var wi: Array = ida[ida.size() - 1]
		comprobar("p3) ida: pasillo central, escalera de %d peldaños (%.1f m de desnivel) abajo y %.0f m de marquesina 553042591 sin atascarse"
				% [esc["peldanos"], float(esc["y_arriba"]) - float(esc["y_abajo"]), tre["longitud_marquesina_m"]],
				int(r1["idx"]) >= ida.size() and not bool(r1["atascado"]) and absf(y_fin_ida - float(wi[1])) < 0.6,
				"puntos=%d/%d frames=%d y=[%.2f, %.2f] y_final=%.2f (esperada %.2f) %s" % [r1["idx"], ida.size(), r1["frames"], r1["y_min"], r1["y_max"], y_fin_ida, float(wi[1]), str(ida[mini(int(r1["idx"]), ida.size() - 1)])])
		comprobar("p3b) vuelta: marquesina hacia atrás y escalera arriba hasta el pasillo central sin atascarse",
				int(r2["idx"]) >= vuelta.size() and not bool(r2["atascado"]) and dfin < 2.0
				and absf(jugador.global_position.y - float(esc["y_arriba"])) < 0.8 and jugador.is_on_floor(),
				"puntos=%d/%d frames=%d dist_final=%.2f y_final=%.2f (arriba %.2f) pos=%s" % [r2["idx"], vuelta.size(), r2["frames"], dfin, jugador.global_position.y, float(esc["y_arriba"]), str(jugador.global_position)])
		jugador.activo = false

	# m) materiales procedurales y bordes del campus
	var mat_asfalto: Material = null
	var mat_edif: Material = null
	var mat_suelo: Material = null
	for h: Node in mapa.find_children("*", "MeshInstance3D", true, false):
		var mi := h as MeshInstance3D
		if mi.mesh == null or mi.mesh.get_surface_count() == 0:
			continue
		var nm: String = String(mi.mesh.surface_get_material(0).resource_name) if mi.mesh.surface_get_material(0) != null else ""
		if nm == "camino_asfalto" and mat_asfalto == null:
			mat_asfalto = mi.get_surface_override_material(0)
		elif nm == "edificio" and mat_edif == null:
			mat_edif = mi.get_surface_override_material(0)
		elif nm == "suelo" and mat_suelo == null:
			mat_suelo = mi.get_surface_override_material(0)
	var tri_ok: bool = mat_asfalto is StandardMaterial3D and (mat_asfalto as StandardMaterial3D).uv1_triplanar 			and (mat_asfalto as StandardMaterial3D).uv1_world_triplanar 			and (mat_asfalto as StandardMaterial3D).albedo_texture != null
	comprobar("m1) camino_asfalto: StandardMaterial3D triplanar mundial con textura", tri_ok)
	comprobar("m1b) suelo triplanar y edificio con ShaderMaterial de fachada",
			mat_suelo is StandardMaterial3D and (mat_suelo as StandardMaterial3D).uv1_triplanar
			and mat_edif is ShaderMaterial)
	# n) estilos de fachada: 25 biblioteca, 32 ladrillo_rectorado, 45 policarbonato (ShaderMaterial distintos)
	var esperados: Dictionary = {"142262877": "biblioteca", "1373541637": "ladrillo_rectorado", "142258873": "policarbonato"}
	var vistos: Array[String] = []
	var murosv: Array = []
	var n1_ok: bool = true
	for id: String in esperados:
		var nodo_e: MeshInstance3D = null
		for h: Node in mapa.find_children("edif_%s_*" % id, "MeshInstance3D", true, false):
			nodo_e = h as MeshInstance3D
		var me: Material = nodo_e.get_surface_override_material(0) if nodo_e != null else null
		var estilo_e: String = String(me.get_meta("estilo", "")) if me != null else ""
		n1_ok = n1_ok and me is ShaderMaterial and estilo_e == esperados[id] and not vistos.has(estilo_e) 				and nodo_e.get_instance_shader_parameter("y_cubierta") < 500.0 				and (nodo_e.get_instance_shader_parameter("eje_principal") as Vector2).length() > 0.99
		vistos.append(estilo_e)
		if me is ShaderMaterial:
			murosv.append((me as ShaderMaterial).get_shader_parameter("color_muro"))
	comprobar("n1) edificios 25, 32 y 45 tienen ShaderMaterial con estilo distinto (biblioteca, rectorado, policarbonato)",
			n1_ok and murosv.size() == 3 and murosv[0] != murosv[1] and murosv[1] != murosv[2], "estilos=%s" % str(vistos))
	var est_json: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/estilos.json"))
	comprobar("n2) existe game/data/estilos.json con >= 70 entradas", est_json is Dictionary and (est_json as Dictionary).size() >= 70,
			"entradas=%d" % ((est_json as Dictionary).size() if est_json is Dictionary else 0))
	var valla: Node = mapa.find_child("valla_perimetral", true, false)
	comprobar("m2) existe valla_perimetral (sin colision)",
			valla is MeshInstance3D and valla.find_children("*", "StaticBody3D", true, false).is_empty())
	var exterior: Node = mapa.find_child("exterior", true, false)
	comprobar("m3) existe exterior (malla) sin colision",
			exterior is MeshInstance3D and exterior.find_children("*", "StaticBody3D", true, false).is_empty()
			and exterior.find_children("*", "CollisionShape3D", true, false).is_empty())

	print("RESULTADO: %s (%d fallos)" % ["PASS" if fallos == 0 else "FAIL", fallos])
	main.queue_free()
	await process_frame
	quit(0 if fallos == 0 else 1)
