extends Node
## Escena de prueba de los bots (sin la Partida de P4). Instancia el mapa principal, una zona competitiva con su navegacion y
## NvM bots con `DirectorBots` + `PartidaPrueba`. Argumentos tras `--` (todos opcionales, forma clave=valor):
##   zona=el_eje|plaza_america|biblioteca_24|detras_22|el_puente   (o "libre" = campus entero, bots que deambulan)
##   modo=cachimba|eliminacion   n=5 (bots por equipo, 1-5)   dificultad=facil|normal|dificil
##   jugador=1|0 (0 = camara libre para observar)   equipo=atacantes|defensores (equipo del jugador)
## Ejemplo: Godot.exe --path game res://scenes/prueba_bots.tscn -- zona=el_eje modo=cachimba n=5 dificultad=normal equipo=defensores
## Teclas: F9 reinicia la ronda de prueba, F10 siguiente zona, F11 cambia la dificultad. El jugador usa el armero (F6) y K (suicidio).

const ZONAS: Array[String] = ["plaza_america", "biblioteca_24", "detras_22", "el_eje", "el_puente"]

var main: Node
var jugador: Jugador
var zona: ZonaActiva
var region: NavigationRegion3D
var partida: PartidaPrueba
var director: DirectorBots
var bots: Array[Bot] = []
var opciones: Dictionary = {"zona": "el_eje", "modo": "cachimba", "n": "5", "dificultad": "normal", "jugador": "1", "equipo": "atacantes"}
var semilla: int = 1
var fin_anunciado: bool = false
var _etiqueta: Label
var _t_fin: float = 0.0


func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=")
		if kv.size() == 2:
			opciones[kv[0]] = kv[1]
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await get_tree().physics_frame
	await get_tree().physics_frame
	main.menu.cerrar()
	jugador = main.get_node("Jugador")
	var capa := CanvasLayer.new()
	capa.layer = 30
	add_child(capa)
	_etiqueta = Label.new()
	_etiqueta.position = Vector2(16, 120)
	_etiqueta.add_theme_color_override("font_color", Color(1, 1, 0.6))
	_etiqueta.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_etiqueta.add_theme_constant_override("outline_size", 6)
	capa.add_child(_etiqueta)
	await montar()


## Monta (o remonta) la partida segun `opciones`.
func montar() -> void:
	desmontar()
	fin_anunciado = false
	semilla += 1
	var libre: bool = str(opciones["zona"]) == "libre"
	var n: int = clampi(int(opciones["n"]), 1, 5)
	var dif: StringName = StringName(str(opciones["dificultad"]))
	var modo: StringName = &"libre" if libre else StringName(str(opciones["modo"]))
	var propio: int = Bot.EQ_DEFENSORES if str(opciones["equipo"]) == "defensores" else Bot.EQ_ATACANTES
	var con_jugador: bool = str(opciones["jugador"]) != "0"
	partida = PartidaPrueba.new()
	add_child(partida)
	director = DirectorBots.new()
	add_child(director)
	if libre:
		zona = null
		region = NavBots.hornear_campus(main)
		var origen := Vector3(-486.58, -1.9, 142.56)
		await NavBots.esperar_listo(main, origen)
		partida.configurar(&"libre", null)
		director.configurar(null, partida, &"libre", NavBots.mapa(main), semilla)
		_poner_jugador(origen, 0.0, 0, con_jugador)
		for i in n * 2:
			var p: Vector3 = NavigationServer3D.map_get_closest_point(NavBots.mapa(main), origen + Vector3(randf_range(-40, 40), 0, randf_range(-40, 40)))
			var b: Bot = Bot.crear("Libre%d" % (i + 1), 0, Bot.ROL_LIBRE, dif, semilla * 100 + i, partida)
			b.reaparicion_auto = true
			add_child(b)
			b.teletransportar(p, randf() * 360.0)
			director.agregar(b)
			bots.append(b)
	else:
		zona = ZonaActiva.crear(str(opciones["zona"]))
		if zona == null:
			push_error("Zona desconocida: %s" % str(opciones["zona"]))
			return
		add_child(zona)
		await get_tree().physics_frame
		region = NavBots.hornear_zona(main, zona)
		await NavBots.esperar_listo(main, zona.punto_spawn("atacantes", 0)["pos"])
		partida.configurar(modo, zona)
		director.configurar(zona, partida, modo, NavBots.mapa(main), semilla)
		for eq in [Bot.EQ_ATACANTES, Bot.EQ_DEFENSORES]:
			var txt: String = "atacantes" if eq == Bot.EQ_ATACANTES else "defensores"
			for i in n:
				if con_jugador and eq == propio and i == 0:
					var sp0: Dictionary = zona.punto_spawn(txt, 0)
					_poner_jugador(sp0["pos"], float(sp0["yaw_deg"]), eq, true)
					continue
				var sp: Dictionary = zona.punto_spawn(txt, i)
				var b: Bot = Bot.crear("%s%d" % ["ATQ" if eq == Bot.EQ_ATACANTES else "DEF", i + 1], eq,
						Bot.ROL_ATACANTE if eq == Bot.EQ_ATACANTES else Bot.ROL_DEFENSOR, dif, semilla * 100 + eq * 10 + i, partida)
				add_child(b)
				b.teletransportar(sp["pos"], float(sp["yaw_deg"]))
				director.agregar(b)
				bots.append(b)
		if not con_jugador:
			var cam: Dictionary = zona.camara_lobby()
			_poner_jugador(cam["pos"], 0.0, 0, false)
			jugador.look_at(cam["mira"], Vector3.UP)
	director.preparar()
	for b: Bot in bots:
		b.comprar_kit()
	if con_jugador:
		for id: StringName in [&"escudo_ligero", &"fusil_asalto"]:
			jugador.gestor.equipar(id)


func _poner_jugador(pos: Vector3, yaw: float, equipo: int, activo: bool) -> void:
	jugador.salud.equipo = equipo
	jugador.salud.vivo = activo
	jugador.hitboxes.activar(activo)
	jugador.teletransportar(pos, yaw)
	jugador.activo = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if not activo:
		jugador._poner_vuelo(true)   # observador: vuelo libre sin hitboxes


func desmontar() -> void:
	for b: Bot in bots:
		if is_instance_valid(b):
			b.queue_free()
	bots.clear()
	for n: Node in [director, partida, region, zona]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	for g: String in ["lanzables", "nubes", "proyectiles", "altavoces", "armas_suelo"]:
		for n: Node in get_tree().get_nodes_in_group(g):
			n.queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match (event as InputEventKey).keycode:
		KEY_F9:
			montar()
		KEY_F10:
			var i: int = ZONAS.find(str(opciones["zona"]))
			opciones["zona"] = ZONAS[(i + 1) % ZONAS.size()]
			montar()
		KEY_F11:
			var l: Array[StringName] = DificultadBot.TODAS
			opciones["dificultad"] = String(l[(l.find(StringName(str(opciones["dificultad"]))) + 1) % l.size()])
			montar()


func _process(delta: float) -> void:
	if _etiqueta == null or director == null:
		return
	var va: int = director.vivos_de(Bot.EQ_ATACANTES).size()
	var vd: int = director.vivos_de(Bot.EQ_DEFENSORES).size()
	if jugador.salud.vivo and jugador.salud.equipo == 1:
		va += 1
	elif jugador.salud.vivo and jugador.salud.equipo == 2:
		vd += 1
	var c: Cachimba = partida.cachimba() if partida != null else null
	_etiqueta.text = "PRUEBA DE BOTS  zona=%s modo=%s dif=%s | atacantes vivos %d  defensores vivos %d | Cachimba: %s | F9 reiniciar  F10 zona  F11 dificultad" % [
			opciones["zona"], opciones["modo"], opciones["dificultad"], va, vd, Cachimba.Estado.keys()[c.estado] if c != null else "-"]
	if zona != null and not fin_anunciado and (va == 0 or vd == 0) and not bots.is_empty():
		_t_fin += delta
		if _t_fin > 4.0:
			_t_fin = 0.0
			fin_anunciado = true
			montar()
