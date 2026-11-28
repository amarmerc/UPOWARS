extends "res://tests/captura.gd"
## Capturas de las mejoras (coberturas, arboles gruesos, zoom y mira telescopica, contorno de enemigos, manos). NECESITA GPU (sin --headless):
##   Godot_console.exe --path game --script res://tests/captura_mejoras.gd -- <carpeta_salida> [bloque]
## Salida por defecto: export/capturas_mejoras/. `bloque` (opcional): zonas | arbol | zoom | contorno | manos (solo ese bloque).

var main: Node3D
var jug: Jugador
var gest: GestorArmas


func _ejecutar() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var salida: String = args[0] if args.size() > 0 else ProjectSettings.globalize_path("res://").path_join("../export/capturas_mejoras")
	var bloque: String = args[1] if args.size() > 1 else ""
	DirAccess.make_dir_recursive_absolute(salida)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 10:
		await physics_frame
	main.menu.cerrar()
	jug = main.get_node("Jugador")
	jug.activo = true
	jug.entrada_manual = true
	jug.camara.make_current()
	gest = jug.gestor
	gest.entrada_manual = true
	gest.kit_reaparicion = []
	gest.reiniciar()
	main.campo.visible = false
	for d: Diana in main.campo.dianas:
		d.visible = false
		d.process_mode = Node.PROCESS_MODE_DISABLED
		d.salud.vivo = false
		d.hitboxes.activar(false)
	if bloque == "" or bloque == "zonas":
		await _zonas_a_pie(salida)
	if bloque == "" or bloque == "arbol":
		await _arbol_grueso(salida)
	if bloque == "" or bloque == "zoom":
		await _zooms(salida)
	if bloque == "" or bloque == "contorno":
		await _contornos(salida)
	if bloque == "" or bloque == "manos":
		await _manos(salida)
	quit(0)


func _mirar(desde: Vector3, hacia: Vector3) -> void:
	var d: Vector3 = hacia - desde
	jug.teletransportar(desde, rad_to_deg(atan2(-d.x, -d.z)))
	jug._pitch = 0.0
	jug._aplicar_rotacion_cabeza()


func _esperar(n: int) -> void:
	for i in n:
		await physics_frame
	await process_frame


## Cada zona a pie desde el spawn de atacantes mirando a cada site.
func _zonas_a_pie(salida: String) -> void:
	gest.equipar(&"fusil_asalto")
	main.hud.get_node("Info").visible = false
	for zid in ZonaActiva.ids_disponibles():
		var zona: ZonaActiva = ZonaActiva.crear(zid)
		main.add_child(zona)
		await _esperar(3)
		var sp: Dictionary = zona.punto_spawn("atacantes", 2)
		for k in ["A", "B"]:
			var c: Vector3 = zona.centro_site(k)
			var p: Vector3 = sp["pos"]
			_mirar(p, c)
			await _esperar(30)
			await _guardar(salida, "zona_%s_site%s" % [zid, k])
		zona.queue_free()
		await _esperar(2)


## Un arbol grueso de una zona con un enemigo detras del tronco: el tronco (0,9-1,4 m) lo tapa.
func _arbol_grueso(salida: String) -> void:
	var tronco: Dictionary = _tronco_mas_grueso("detras_22")
	if tronco.is_empty():
		print("sin arbol grueso en detras_22")
		return
	var zona: ZonaActiva = ZonaActiva.crear("detras_22")
	main.add_child(zona)
	var base: Vector3 = tronco["pos"]
	var r: float = tronco["radio"]
	print("arbol grueso en ", base, " radio ", r)
	var bot: Bot = _bot_enemigo("Enemigo", base)
	var espacio: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	var mejor: Vector3 = Vector3.ZERO
	for a in 16:
		var ang: float = TAU * float(a) / 16.0
		var v: Vector3 = Vector3(cos(ang), 0, sin(ang))
		var cam_p: Vector3 = base + v * 8.0 + Vector3(0, 1.65, 0)
		var q := PhysicsRayQueryParameters3D.create(cam_p, base + Vector3(0, 1.4, 0) + v * (r + 0.05), 1)
		var hit: Dictionary = espacio.intersect_ray(q)
		if hit.is_empty() or (hit["position"] as Vector3).distance_to(base + Vector3(0, 1.4, 0)) < r + 0.3:
			mejor = v
			break
	if mejor == Vector3.ZERO:
		mejor = Vector3(1, 0, 0)
	var suelo_p: Vector3 = base - mejor * (r + 0.55)
	suelo_p.y = _suelo_en(suelo_p)
	bot.teletransportar(suelo_p, rad_to_deg(atan2(mejor.x, mejor.z)))
	var cam_pos: Vector3 = base + mejor * 8.0
	cam_pos.y = _suelo_en(cam_pos)
	_mirar(cam_pos, base)
	await _esperar(40)
	await _guardar(salida, "arbol_grueso_jugador_detras")
	bot.teletransportar(base + Vector3(30, 0, 30), 0.0)
	await _esperar(10)
	await _guardar(salida, "arbol_grueso_solo")
	bot.queue_free()
	zona.queue_free()
	await _esperar(2)


## Tronco grueso aislado de la zona (posicion de scripts: ctx.arboles con r_tronco 0,68; ver README).
func _tronco_mas_grueso(_zid: String) -> Dictionary:
	var p := Vector3(63.5, 0.0, -304.2)
	p.y = _suelo_en(p)
	return {"pos": p, "radio": 0.68}


func _suelo_en(p: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 30, 0), p + Vector3(0, -30, 0), 1)
	var h: Dictionary = main.get_world_3d().direct_space_state.intersect_ray(q)
	return (h["position"] as Vector3).y if not h.is_empty() else p.y


func _bot_enemigo(nombre: String, pos: Vector3, equipo: int = 2) -> Bot:
	var b: Bot = Bot.crear(nombre, equipo, Bot.ROL_ESTATICO, &"normal", 5, null, &"soldado")
	b.entrada_manual = true
	main.add_child(b)
	b.teletransportar(pos, 0.0)
	jug.salud.equipo = 1
	return b


## Fusil de precision con la mira telescopica a 4x y 8x, y otras armas apuntando.
func _zooms(salida: String) -> void:
	var campo: CampoPractica = main.campo
	var fwd: Vector3 = campo.adelante
	jug.teletransportar(campo.punto_tiro, rad_to_deg(atan2(-fwd.x, -fwd.z)))
	main.hud.visible = true
	main.hud.get_node("Info").visible = false
	var bots: Array[Bot] = []
	for i in 3:
		var p: Vector3 = campo.punto_tiro + fwd * (30.0 + 25.0 * i) + fwd.cross(Vector3.UP) * (3.0 - 3.0 * i)
		p.y = _suelo_en(p)
		var b: Bot = _bot_enemigo("Objetivo%d" % i, p)
		b.teletransportar(p, rad_to_deg(atan2(fwd.x, fwd.z)))
		bots.append(b)
	await _esperar(30)
	gest.equipar(&"fusil_precision")
	await _listo(gest, jug, 1.3)
	await _guardar(salida, "zoom_precision_cadera")
	gest.gatillo_alt = true
	await _listo(gest, jug, 1.0)
	await _guardar(salida, "zoom_precision_4x")
	gest.ciclar_zoom(1)
	await _listo(gest, jug, 0.8)
	await _guardar(salida, "zoom_precision_8x")
	gest.gatillo_alt = false
	await _listo(gest, jug, 0.6)
	gest.equipar(&"fusil_tirador")
	await _listo(gest, jug, 1.3)
	gest.gatillo_alt = true
	await _listo(gest, jug, 1.0)
	await _guardar(salida, "zoom_tirador_4x")
	gest.gatillo_alt = false
	await _listo(gest, jug, 0.6)
	for par: Array in [[&"fusil_asalto", "zoom_fusil_asalto"], [&"subfusil_9mm", "zoom_subfusil"], [&"pistola_pesada", "zoom_pistola"]]:
		gest.equipar(par[0])
		await _listo(gest, jug, 1.3)
		await _guardar(salida, str(par[1]) + "_cadera")
		gest.gatillo_alt = true
		await _listo(gest, jug, 0.8)
		await _guardar(salida, str(par[1]) + "_apuntando")
		gest.gatillo_alt = false
		await _listo(gest, jug, 0.5)
	for b: Bot in bots:
		b.queue_free()
	await _esperar(2)


## Contorno de enemigo: visible, el mismo enemigo tapado por un muro (sin contorno) y por humo, y un aliado con nombre.
func _contornos(salida: String) -> void:
	var campo: CampoPractica = main.campo
	var fwd: Vector3 = campo.adelante
	var lado: Vector3 = fwd.cross(Vector3.UP)
	jug.teletransportar(campo.punto_tiro, rad_to_deg(atan2(-fwd.x, -fwd.z)))
	gest.equipar(&"fusil_asalto")
	main.hud.visible = true
	main.hud.get_node("Info").visible = false
	var p1: Vector3 = campo.punto_tiro + fwd * 13.0
	p1.y = _suelo_en(p1)
	var p2: Vector3 = campo.punto_tiro + fwd * 22.0 + lado * 3.5
	p2.y = _suelo_en(p2)
	var enemigo: Bot = _bot_enemigo("Enemigo", p1)
	enemigo.teletransportar(p1, rad_to_deg(atan2(fwd.x, fwd.z)))
	var enemigo2: Bot = _bot_enemigo("Enemigo2", p2)
	enemigo2.teletransportar(p2, rad_to_deg(atan2(fwd.x, fwd.z)))
	var pa: Vector3 = campo.punto_tiro + fwd * 6.0 + lado * 2.5
	pa.y = _suelo_en(pa)
	var aliado: Bot = _bot_enemigo("Aliado", pa, 1)
	aliado.teletransportar(pa, rad_to_deg(atan2(fwd.x, fwd.z)))
	await _listo(gest, jug, 1.3)
	await _esperar(30)
	await _guardar(salida, "contorno_enemigo_visible")
	var muro := StaticBody3D.new()
	muro.collision_layer = 1
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = Vector3(5.0, 3.0, 0.4)
	cs.shape = bx
	muro.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = bx.size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.62, 0.6, 0.55)
	mi.material_override = mat
	muro.add_child(mi)
	main.add_child(muro)
	var pm: Vector3 = campo.punto_tiro + fwd * 7.0
	muro.global_position = Vector3(pm.x, _suelo_en(pm) + 1.5, pm.z)
	muro.look_at(muro.global_position - fwd, Vector3.UP)
	await _esperar(40)
	await _guardar(salida, "contorno_enemigo_tapado_por_muro")
	muro.queue_free()
	await _esperar(40)
	var humo: ArmaDatos = Catalogo.arma(&"granada_humo")
	Utilidades.activar(jug, humo, p1 - fwd * 5.0 + Vector3(0, 0.1, 0), jug)
	await _esperar(90)
	await _guardar(salida, "contorno_enemigo_tapado_por_humo")
	for n: Node in get_nodes_in_group("nubes"):
		(n as NubeVision).avanzar(40.0)
	enemigo.queue_free()
	enemigo2.queue_free()
	aliado.queue_free()
	await _esperar(5)


## Mosaico de las armas con las manos nuevas (con dos personajes) y varias armas en detalle.
func _manos(salida: String) -> void:
	main.hud.visible = true
	main.hud.get_node("Info").visible = false
	jug.salud.equipo = 1
	jug._pitch = deg_to_rad(24.0)
	jug._aplicar_rotacion_cabeza()
	gest.reiniciar()
	for pj: StringName in [&"soldado", &"estudiante"]:
		gest.poner_personaje(pj)
		var celdas: Array[Image] = []
		for id: StringName in ARSENAL_ORDEN:
			gest.inventario.utilidades.clear()
			if Catalogo.hueco(id) == &"utilidades":
				gest.equipar(id)
				gest.sel_util = 0
				gest.cambiar_arma(3)
				gest.sel_util = 0
				gest._forzar_arma(3)
			elif id == &"navaja":
				gest.cambiar_arma(2)
			else:
				gest.equipar(id)
			await _listo(gest, jug, 1.2)
			await RenderingServer.frame_post_draw
			var img: Image = root.get_viewport().get_texture().get_image()
			var sz: Vector2i = img.get_size()
			var celda: Image = img.get_region(Rect2i(int(sz.x * 0.36), int(sz.y * 0.28), int(sz.x * 0.64), int(sz.y * 0.72)))
			celda.convert(Image.FORMAT_RGBA8)
			celdas.append(celda)
		var cw: int = 360
		var ch: int = 220
		var cols: int = 6
		var filas: int = int(ceil(celdas.size() / float(cols)))
		var mosaico: Image = Image.create(cw * cols, ch * filas, false, Image.FORMAT_RGBA8)
		for i in celdas.size():
			var c: Image = celdas[i]
			c.resize(cw, ch, Image.INTERPOLATE_BILINEAR)
			mosaico.blit_rect(c, Rect2i(0, 0, cw, ch), Vector2i((i % cols) * cw, (i / cols) * ch))
		mosaico.save_png(salida.path_join("manos_mosaico_%s.png" % pj))
		print("captura manos_mosaico_", pj)
	gest.poner_personaje(&"estudiante")
	jug._pitch = 0.0
	jug._aplicar_rotacion_cabeza()
	for par: Array in [[&"fusil_asalto", "manos_fusil"], [&"pistola_9mm", "manos_pistola"], [&"arco_olivo", "manos_arco"],
			[&"sable_plasma", "manos_sable"], [&"granada_explosiva", "manos_granada"]]:
		gest.equipar(par[0])
		if Catalogo.hueco(par[0]) == &"utilidades":
			gest.cambiar_arma(3)
		await _listo(gest, jug, 1.3)
		await _guardar(salida, str(par[1]))
