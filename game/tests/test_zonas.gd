extends SceneTree
## Test headless de las zonas competitivas (muro translucido, barreras, spawns, sites, navegacion). Uso:
##   Godot_console.exe --headless --path game --script res://tests/test_zonas.gd
## Imprime PASS/FAIL por comprobacion y sale con codigo 0 (todo bien) o 1.
## Por cada zona de res://data/zonas.json (ZonaActiva):
##   z1 el muro existe, tiene colision (capa mundo) y su shader tiene alpha < 1
##   z2 los 10 spawns tienen la capsula del jugador libre y suelo debajo
##   z3 los sites estan dentro del limite
##   z4 con NavigationServer3D y una malla horneada de la zona, desde cada spawn se llega a A y B (registra los tiempos a 5 m/s)
##   z5 un rayo desde dentro hacia fuera choca con el muro
##   z6 con activar_barreras(true) un cuerpo con la capsula del jugador no sale del spawn (con false si sale)

const VEL_MS: float = 5.0
const RADIO: float = 0.35
const ALTO: float = 1.8
const CAPA_MUNDO: int = 1
const ENVOLTURA_BAKE_M: float = 8.0

var fallos: int = 0
var main: Node
var espacio: PhysicsDirectSpaceState3D
## tiempos de llegada medidos (para el informe): zona -> {sitio: {equipo: [s...]}}
var tiempos: Dictionary = {}


func comprobar(nombre: String, ok: bool, detalle: String = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", nombre, detalle])
	if not ok:
		fallos += 1


func _init() -> void:
	_ejecutar.call_deferred()


func esperar_fisica(n: int) -> void:
	for i in n:
		await physics_frame


func _ejecutar() -> void:
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await esperar_fisica(5)
	espacio = (main as Node3D).get_world_3d().direct_space_state
	main.get_node("Jugador").set_physics_process(false)

	# z0) modo libre: el mapa no instancia ninguna zona; un id desconocido no crea nada
	comprobar("z0a) el modo libre (escena principal) no instancia ZonaActiva", main.find_children("*", "ZonaActiva", true, false).is_empty())
	comprobar("z0b) ZonaActiva.crear con un id desconocido devuelve null", ZonaActiva.crear("no_existe") == null)
	var ids: PackedStringArray = ZonaActiva.ids_disponibles()
	comprobar("z0c) zonas.json trae las 5 zonas del diseno", ids.size() == 5 and ids.has("plaza_america") and ids.has("biblioteca_24")
			and ids.has("detras_22") and ids.has("el_eje") and ids.has("el_puente"), str(ids))

	var solo: PackedStringArray = OS.get_cmdline_user_args()      # -- <id> ...: solo esas zonas (depuracion)
	for zid in ids:
		if solo.is_empty() or solo.has(zid):
			await _probar_zona(zid)

	print("--- tiempos de llegada a 5 m/s (s) por zona: media [min-max] de los 5 spawns ---")
	for zid: String in tiempos:
		for k: String in tiempos[zid]:
			var partes: Array[String] = []
			for eq: String in ZonaActiva.EQUIPOS:
				var l: Array = tiempos[zid][k][eq]
				var suma: float = 0.0
				for t: float in l:
					suma += t
				partes.append("%s %.1f [%.1f-%.1f]" % [eq, suma / maxf(l.size(), 1.0), l.min() if l.size() > 0 else 0.0, l.max() if l.size() > 0 else 0.0])
			var ta: Array = tiempos[zid][k]["atacantes"]
			var td: Array = tiempos[zid][k]["defensores"]
			var ma: float = 0.0
			var md: float = 0.0
			for t: float in ta:
				ma += t
			for t: float in td:
				md += t
			print("%s site %s: %s | ventaja defensores %+.1f s" % [zid, k, " | ".join(partes), ma / maxf(ta.size(), 1.0) - md / maxf(td.size(), 1.0)])

	print("RESULTADO: %s (%d fallos)" % ["PASS" if fallos == 0 else "FAIL", fallos])
	main.queue_free()
	await process_frame
	quit(0 if fallos == 0 else 1)


func _probar_zona(zid: String) -> void:
	print("=== %s ===" % zid)
	var zona: ZonaActiva = ZonaActiva.crear(zid)
	if zona == null:
		comprobar("%s: crear" % zid, false)
		return
	main.add_child(zona)
	await esperar_fisica(3)

	# z1) muro: existe, colision (capa mundo) y alpha < 1
	var cuerpo: StaticBody3D = zona.muro.get_node("Cuerpo") as StaticBody3D
	var n_formas: int = cuerpo.get_child_count()
	var malla: MeshInstance3D = zona.muro.get_node("Malla") as MeshInstance3D
	var mat: ShaderMaterial = malla.material_override as ShaderMaterial
	var alpha_max: float = float(mat.get_shader_parameter("alpha_max")) if mat != null else 2.0
	comprobar("%s z1) muro con colision en la capa mundo y shader translucido (alpha < 1)" % zid,
			cuerpo != null and n_formas >= 20 and (cuerpo.collision_layer & CAPA_MUNDO) != 0
			and mat != null and mat.shader != null and mat.shader.resource_path.ends_with("muro_zona.gdshader")
			and alpha_max < 1.0 and malla.mesh != null and malla.mesh.get_surface_count() == 1,
			"cajas=%d, alpha_max=%.2f, altura=%.0f m" % [n_formas, alpha_max, zona.limites()["alto_muro"]])

	# z2) 10 spawns: capsula libre y suelo
	var libres: int = 0
	var detalle_z2: String = ""
	for eq in ZonaActiva.EQUIPOS:
		for i in zona.n_spawns(eq):
			var sp: Dictionary = zona.punto_spawn(eq, i)
			var pos: Vector3 = sp["pos"]
			var forma := CapsuleShape3D.new()
			forma.radius = RADIO
			forma.height = ALTO
			var q := PhysicsShapeQueryParameters3D.new()
			q.shape = forma
			q.transform = Transform3D(Basis.IDENTITY, pos + Vector3(0, ALTO * 0.5 + 0.02, 0))
			q.collision_mask = CAPA_MUNDO
			var choques: Array[Dictionary] = espacio.intersect_shape(q, 4)
			var r := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 1.0, 0), pos + Vector3(0, -1.0, 0))
			r.collision_mask = CAPA_MUNDO
			var suelo: Dictionary = espacio.intersect_ray(r)
			var ok_suelo: bool = not suelo.is_empty() and absf((suelo["position"] as Vector3).y - (pos.y - 0.1)) < 0.35
			if choques.is_empty() and ok_suelo and zona.dentro(pos):
				libres += 1
			else:
				detalle_z2 += " [%s %d: choques=%d suelo=%s]" % [eq, i, choques.size(), str(ok_suelo)]
	comprobar("%s z2) los 10 spawns tienen la capsula libre, suelo y estan dentro" % zid, libres == 10, "libres=%d/10%s" % [libres, detalle_z2])

	# z3) los sites dentro del limite
	var sites_ok: bool = true
	var det3: String = ""
	for k: String in zona.zona["sites"]:
		var c: Vector3 = zona.centro_site(k)
		var rad: float = float(zona.zona["sites"][k]["radio"])
		var todos: bool = zona.dentro(c) and zona.site_en(c) == k
		for a in 16:
			var ang: float = TAU * a / 16.0
			todos = todos and zona.dentro(c + Vector3(cos(ang), 0, sin(ang)) * rad)
		sites_ok = sites_ok and todos
		det3 += " %s radio=%.0f m" % [k, rad]
	comprobar("%s z3) los sites A y B estan dentro del limite" % zid, sites_ok and zona.site_en(zona.punto_spawn("atacantes", 0)["pos"]) == "", det3)

	# z4) navegacion
	await _probar_navegacion(zona)

	# z5) un rayo de dentro hacia fuera choca con el muro
	_probar_muro_rayos(zona)

	# z6) barreras
	await _probar_barreras(zona)

	zona.queue_free()
	await esperar_fisica(2)


## Malla de navegacion de la zona (horneada del mapa y del muro; barreras desactivadas) y rutas spawn -> sites.
func _probar_navegacion(zona: ZonaActiva) -> void:
	var zid: String = zona.id
	var lim: Dictionary = zona.limites()
	var navmesh := NavigationMesh.new()
	navmesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	navmesh.geometry_collision_mask = CAPA_MUNDO
	navmesh.cell_size = 0.25
	navmesh.cell_height = 0.2
	navmesh.agent_radius = 0.4
	navmesh.agent_height = ALTO
	navmesh.agent_max_climb = 0.5
	navmesh.agent_max_slope = 45.0
	navmesh.region_min_size = 4.0
	var mn: Vector3 = lim["min"]
	var mx: Vector3 = lim["max"]
	navmesh.filter_baking_aabb = AABB(mn - Vector3(ENVOLTURA_BAKE_M, 12.0, ENVOLTURA_BAKE_M), (mx - mn) + Vector3(2 * ENVOLTURA_BAKE_M, 40.0, 2 * ENVOLTURA_BAKE_M))
	var t0: int = Time.get_ticks_msec()
	var fuente := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(navmesh, fuente, main)
	NavigationServer3D.bake_from_source_geometry_data(navmesh, fuente)
	var t_bake: float = (Time.get_ticks_msec() - t0) / 1000.0
	# la malla horneada va en una NavigationRegion3D (mapa de navegacion del mundo de la escena)
	var region := NavigationRegion3D.new()
	region.navigation_mesh = navmesh
	main.add_child(region)
	var mapa_nav: RID = (main as Node3D).get_world_3d().navigation_map
	var p0: Vector3 = zona.punto_spawn("atacantes", 0)["pos"]
	for i in 30:        # el mapa tarda unos fotogramas en sincronizar la region
		await physics_frame
		NavigationServer3D.map_force_update(mapa_nav)
		if NavigationServer3D.map_get_closest_point(mapa_nav, p0).distance_to(p0) < 5.0:
			break
	var n_poly: int = navmesh.get_polygon_count()
	var alcanzados: int = 0
	var intentos: int = 0
	var det: String = ""
	var res: Dictionary = {}
	for k: String in zona.zona["sites"]:
		res[k] = {}
		var destino: Vector3 = NavigationServer3D.map_get_closest_point(mapa_nav, zona.centro_site(k))
		for eq in ZonaActiva.EQUIPOS:
			var l: Array = []
			for i in zona.n_spawns(eq):
				intentos += 1
				var origen: Vector3 = NavigationServer3D.map_get_closest_point(mapa_nav, zona.punto_spawn(eq, i)["pos"])
				var ruta: PackedVector3Array = NavigationServer3D.map_get_path(mapa_nav, origen, destino, true)
				var largo: float = 0.0
				for j in range(1, ruta.size()):
					largo += ruta[j - 1].distance_to(ruta[j])
				var llega: bool = ruta.size() >= 2 and ruta[ruta.size() - 1].distance_to(destino) < 1.0 \
						and origen.distance_to(zona.punto_spawn(eq, i)["pos"]) < 2.5 and destino.distance_to(zona.centro_site(k)) < 6.0
				if llega:
					alcanzados += 1
					l.append(largo / VEL_MS)
				else:
					det += " [%s %d -> %s: sin ruta (puntos=%d, fin a %.1f m del destino, origen a %.1f m del spawn, destino a %.1f m del site)]" % [
							eq, i, k, ruta.size(), ruta[ruta.size() - 1].distance_to(destino) if ruta.size() > 0 else -1.0,
							origen.distance_to(zona.punto_spawn(eq, i)["pos"]), destino.distance_to(zona.centro_site(k))]
			res[k][eq] = l
	tiempos[zid] = res
	region.queue_free()
	var resumen: String = ""
	for k: String in res:
		for eq: String in res[k]:
			var l: Array = res[k][eq]
			if l.size() > 0:
				var s: float = 0.0
				for t: float in l:
					s += t
				resumen += " %s/%s=%.1f s" % [k, eq.substr(0, 3), s / l.size()]
	comprobar("%s z4) desde cada spawn se llega a A y B (malla horneada de la zona)" % zid, alcanzados == intentos and n_poly > 50,
			"%d/%d rutas, %d poligonos, horneado %.1f s;%s%s" % [alcanzados, intentos, n_poly, t_bake, resumen, det])


## z5: rayos de dentro hacia fuera por el punto medio de cada tramo del limite; el primer choque debe ser el muro.
func _probar_muro_rayos(zona: ZonaActiva) -> void:
	var lim: PackedVector2Array = zona.limites()["poligono"]
	var n: int = lim.size()
	var muro_cuerpo: StaticBody3D = zona.muro.get_node("Cuerpo") as StaticBody3D
	var aciertos: int = 0
	var probados: int = 0
	var otros: Dictionary = {}
	for i in n:
		var a: Vector2 = lim[i]
		var b: Vector2 = lim[(i + 1) % n]
		if a.distance_to(b) < 4.0:
			continue
		var medio: Vector2 = (a + b) * 0.5
		var t: Vector2 = (b - a).normalized()
		var normal: Vector2 = Vector2(-t.y, t.x)
		if Geometry2D.is_point_in_polygon(medio + normal * 0.5, lim):
			pass
		else:
			normal = -normal
		var y: float = _y_terreno(medio) + 2.0
		var desde := Vector3(medio.x + normal.x * 2.5, y, medio.y + normal.y * 2.5)
		var hasta := Vector3(medio.x - normal.x * 12.0, y, medio.y - normal.y * 12.0)
		var q := PhysicsRayQueryParameters3D.create(desde, hasta)
		q.collision_mask = CAPA_MUNDO
		var r: Dictionary = espacio.intersect_ray(q)
		probados += 1
		if not r.is_empty() and r["collider"] == muro_cuerpo:
			aciertos += 1
		elif not r.is_empty():
			var nom: String = str((r["collider"] as Node).get_parent().name)
			otros[nom] = int(otros.get(nom, 0)) + 1
	# los tramos ocultos tras un edificio / un tronco / un prop cuentan como "tapados"; el resto debe chocar con el muro
	comprobar("%s z5) un rayo de dentro hacia fuera choca con el muro" % zona.id, aciertos >= 4 and aciertos * 10 >= probados * 6,
			"%d/%d tramos chocan con el muro (tapados por: %s)" % [aciertos, probados, str(otros)])
	comprobar("%s z5b) el muro mide 8 m: un rayo horizontal a 7 m sobre el terreno, por fuera de un tramo libre, lo cruza" % zona.id,
			_muro_alto(zona))


## Rayo horizontal a 7 m sobre el terreno cruzando el muro por el tramo mas largo del limite sin obstaculos hasta el: choca con el muro.
func _muro_alto(zona: ZonaActiva) -> bool:
	var lim: PackedVector2Array = zona.limites()["poligono"]
	var muro_cuerpo: StaticBody3D = zona.muro.get_node("Cuerpo") as StaticBody3D
	for i in lim.size():
		var a: Vector2 = lim[i]
		var b: Vector2 = lim[(i + 1) % lim.size()]
		if a.distance_to(b) < 8.0:
			continue
		var medio: Vector2 = (a + b) * 0.5
		var t: Vector2 = (b - a).normalized()
		var normal: Vector2 = Vector2(-t.y, t.x)
		if not Geometry2D.is_point_in_polygon(medio + normal * 0.5, lim):
			normal = -normal
		var y: float = _y_terreno(medio) + 7.0
		var q := PhysicsRayQueryParameters3D.create(Vector3(medio.x + normal.x * 2.0, y, medio.y + normal.y * 2.0),
				Vector3(medio.x - normal.x * 6.0, y, medio.y - normal.y * 6.0))
		q.collision_mask = CAPA_MUNDO
		var r: Dictionary = espacio.intersect_ray(q)
		if not r.is_empty() and r["collider"] == muro_cuerpo:
			return true
	return false


## y del terreno bajo (x, z): rayo vertical contra el cuerpo `terreno` (los demas no cuentan).
func _y_terreno(p: Vector2) -> float:
	var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, 200, p.y), Vector3(p.x, -50, p.y))
	q.collision_mask = CAPA_MUNDO
	var excluir: Array[RID] = []
	for intento in 8:
		q.exclude = excluir
		var r: Dictionary = espacio.intersect_ray(q)
		if r.is_empty():
			return 0.0
		var c: Node = r["collider"] as Node
		if c.get_parent() != null and str(c.get_parent().name) == "terreno":
			return (r["position"] as Vector3).y
		excluir.append((c as CollisionObject3D).get_rid())
	return 0.0


## z6: 8 cuerpos con la capsula del jugador (un CharacterBody3D por direccion) corren 2,5 s desde el primer spawn. Con las barreras
## activas ninguno puede salir del poligono de la barrera; con ellas desactivadas, alguno si sale.
func _probar_barreras(zona: ZonaActiva) -> void:
	for activas in [true, false]:
		zona.activar_barreras(activas)
		await esperar_fisica(2)
		var detalle: String = ""
		var salieron: int = 0
		var todo_ok: bool = true
		for eq in ZonaActiva.EQUIPOS:
			var poligono := PackedVector2Array()
			for v: Array in zona.zona["spawn_" + eq]["barrera"]:
				poligono.append(Vector2(v[0], v[2]))
			var inicio: Vector3 = zona.punto_spawn(eq, 0)["pos"]
			var cuerpos: Array[CharacterBody3D] = []
			for d in 8:
				var cuerpo := CharacterBody3D.new()
				cuerpo.collision_layer = 4
				cuerpo.collision_mask = CAPA_MUNDO
				var cf := CollisionShape3D.new()
				var cap := CapsuleShape3D.new()
				cap.radius = RADIO
				cap.height = ALTO
				cf.shape = cap
				cf.position = Vector3(0, ALTO * 0.5, 0)
				cuerpo.add_child(cf)
				main.add_child(cuerpo)
				cuerpo.global_position = inicio
				cuerpos.append(cuerpo)
			for f in 150:
				for d in 8:
					var ang: float = TAU * d / 8.0
					cuerpos[d].velocity = Vector3(cos(ang), 0, sin(ang)) * VEL_MS + Vector3(0, -6.0, 0)
					cuerpos[d].move_and_slide()
				await physics_frame
			for d in 8:
				var fin := Vector2(cuerpos[d].global_position.x, cuerpos[d].global_position.z)
				if not Geometry2D.is_point_in_polygon(fin, poligono):
					salieron += 1
					if activas:
						todo_ok = false
						detalle += " [%s dir %d salio a (%.1f, %.1f)]" % [eq, d, fin.x, fin.y]
				cuerpos[d].queue_free()
		if activas:
			comprobar("%s z6) con activar_barreras(true) nadie sale del spawn (16 carreras de 2,5 s)" % zona.id, todo_ok, detalle)
		else:
			comprobar("%s z6b) con activar_barreras(false) se puede salir del spawn" % zona.id, salieron >= 4, "salieron %d/16 carreras" % salieron)
	zona.activar_barreras(false)
