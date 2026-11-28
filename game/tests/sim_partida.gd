extends SceneTree
## Simulacion acelerada de rondas con bots para medir el equilibrio (tasa de victoria por bando, uso de la Cachimba y de granadas).
## Uso (headless):
##   Godot_console.exe --headless --path game --script res://tests/sim_partida.gd -- zonas=el_eje,plaza_america rondas=12 n=5 dificultad=normal modo=cachimba semilla=1 escala=12
## Juega `rondas` rondas por zona (sin cambio de lado ni fin de partida: la economia sigue su curso) y escribe una tabla.

var opciones: Dictionary = {"zonas": "plaza_america,biblioteca_24,detras_22,el_eje,el_puente", "rondas": "10", "n": "5", "dificultad": "normal",
		"modo": "cachimba", "semilla": "1", "escala": "12", "t_compra": "3"}


func _init() -> void:
	_ejecutar.call_deferred()


func _ejecutar() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=")
		if kv.size() == 2:
			opciones[kv[0]] = kv[1]
	var main: Node3D = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 6:
		await physics_frame
	main.menu.cerrar()
	(main.get_node("Jugador") as Node3D).set_physics_process(false)
	for d: Diana in main.campo.dianas:
		d.salud.vivo = false
		d.hitboxes.activar(false)
	Engine.max_physics_steps_per_frame = 64
	var total: Dictionary = {"rondas": 0, "atq": 0, "def": 0, "montadas": 0}
	var lineas: Array[String] = []
	for zid: String in str(opciones["zonas"]).split(","):
		var r: Dictionary = await _zona(main, zid)
		lineas.append(r["texto"])
		for k: String in ["rondas", "atq", "def", "montadas"]:
			total[k] = int(total[k]) + int(r[k])
	print("=== RESUMEN (%s, n=%s, %s, %s rondas por zona) ===" % [opciones["modo"], opciones["n"], opciones["dificultad"], opciones["rondas"]])
	for l: String in lineas:
		print(l)
	var n: int = maxi(int(total["rondas"]), 1)
	print("TOTAL: %d rondas, atacantes %d (%.0f%%), defensores %d (%.0f%%), Cachimba montada en %d (%.0f%%)" % [total["rondas"], total["atq"],
			100.0 * float(total["atq"]) / n, total["def"], 100.0 * float(total["def"]) / n, total["montadas"], 100.0 * float(total["montadas"]) / n])
	Engine.time_scale = 1.0
	quit(0)


func _zona(main: Node3D, zid: String) -> Dictionary:
	var c := ConfigPartida.new()
	c.zona = zid
	c.submodo = StringName(str(opciones["modo"]))
	c.jugadores_por_equipo = int(opciones["n"])
	c.dificultad = StringName(str(opciones["dificultad"]))
	c.semilla = int(opciones["semilla"])
	c.con_jugador = false
	c.rondas_ganar = 99
	c.t_compra = float(opciones["t_compra"])
	c.t_fin_ronda = 1.0
	var m: Dictionary = await MontajePartida.montar(main, c, true)
	var p: Partida = m["partida"]
	var bots: Array[Bot] = m["bots"]
	var n_rondas: int = int(opciones["rondas"])
	var res: Dictionary = {"atq": 0, "def": 0, "montadas": 0, "rondas": 0}
	var motivos: Dictionary = {}
	var t_ronda_ini: Array[float] = [0.0]
	var duraciones: Array[float] = []
	var gran0: Dictionary = {}
	var gran_atq: Array[int] = [0]
	var gran_def: Array[int] = [0]
	var montada_ronda: Array[bool] = [false]
	p.cachimba_montada.connect(func(_s: String) -> void: montada_ronda[0] = true)
	p.fase_cambiada.connect(func(f: int) -> void:
		if f == Partida.Fase.RONDA:
			t_ronda_ini[0] = p._t
			montada_ronda[0] = false
			for b: Bot in bots:
				gran0[b] = b.cerebro.n_granadas)
	p.ronda_terminada.connect(func(g: int, mot: String) -> void:
		res["rondas"] = int(res["rondas"]) + 1
		var lado: int = p.lado_grupo[g]
		res["atq" if lado == Partida.EQ_ATACANTES else "def"] = int(res["atq" if lado == Partida.EQ_ATACANTES else "def"]) + 1
		if montada_ronda[0]:
			res["montadas"] = int(res["montadas"]) + 1
		motivos[mot] = int(motivos.get(mot, 0)) + 1
		if str(opciones.get("diag", "0")) == "2":
			var dr: DirectorBots = m["director"]
			var por: Bot = dr.portador
			var linea: String = "  [r%d %s %.0f s] site=%s" % [p.ronda, mot, p._t - t_ronda_ini[0], dr.site_ataque]
			if por != null:
				linea += " portador %s %s a %.0f m del site, estado %s" % [por.nombre, "MUERTO" if por.muerto else "vivo", por.global_position.distance_to(p.zona_activa.centro_site(dr.site_ataque)), str(por.cerebro.estado)]
			else:
				linea += " sin portador (p.portador=%s caida=%s)" % [str(p.portador), str(p.cachimba_caida())]
			var vivos_a: int = 0
			for b: Bot in bots:
				if b.equipo == 1 and not b.muerto:
					vivos_a += 1
			print(linea, " atacantes vivos ", vivos_a)
		duraciones.append(p._t - t_ronda_ini[0])
		for b: Bot in bots:
			var dg: int = b.cerebro.n_granadas - int(gran0.get(b, 0))
			if b.equipo == Partida.EQ_ATACANTES:
				gran_atq[0] += dg
			else:
				gran_def[0] += dg)
	if str(opciones.get("diag", "0")) == "1":
		SenalesCombate.obtener(self).baja.connect(func(a: Node, v: Salud, _arma: ArmaDatos) -> void:
			if p.fase != Partida.Fase.RONDA:
				return
			var vn: Node3D = v.get_parent() as Node3D
			var cs: Vector3 = p.zona_activa.limites()["centro"]
			var sa: Vector3 = (p.zona_activa.punto_spawn("atacantes", 0)["pos"] + p.zona_activa.punto_spawn("atacantes", 4)["pos"]) * 0.5
			var sd: Vector3 = (p.zona_activa.punto_spawn("defensores", 0)["pos"] + p.zona_activa.punto_spawn("defensores", 4)["pos"]) * 0.5
			var arma_id: String = ""
			if a is Bot:
				arma_id = str((a as Bot).armas.id_actual())
			print("  [%s r%d t=%.0f] muere %s (eq%d, %s) a %.0f m del spawn ATQ, %.0f m del spawn DEF; siteA %.0f siteB %.0f; lo mata %s con %s a %.0f m (asesino a %.0f m de su spawn DEF, estado %s)" % [zid, p.ronda, p._t - t_ronda_ini[0], v.nombre_visible(), v.equipo,
					str((vn as Bot).cerebro.estado if vn is Bot else -1), vn.global_position.distance_to(sa), vn.global_position.distance_to(sd),
					vn.global_position.distance_to(p.zona_activa.centro_site("A")), vn.global_position.distance_to(p.zona_activa.centro_site("B")), a.name if a != null else "-", arma_id,
					vn.global_position.distance_to((a as Node3D).global_position) if a is Node3D else -1.0, (a as Node3D).global_position.distance_to(sd) if a is Node3D else -1.0,
					str((a as Bot).cerebro.estado) if a is Bot else "-"]))
	p.iniciar_partida()
	Engine.time_scale = float(opciones["escala"])
	var t0: int = Time.get_ticks_msec()
	var guarda: int = 0
	while int(res["rondas"]) < n_rondas and guarda < 400000:
		await physics_frame
		guarda += 1
	Engine.time_scale = 1.0
	var real: float = (Time.get_ticks_msec() - t0) / 1000.0
	var media: float = 0.0
	for d: float in duraciones:
		media += d
	media /= maxf(float(duraciones.size()), 1.0)
	var k: int = maxi(int(res["rondas"]), 1)
	var texto: String = "%s: %d rondas -> ATQ %d (%.0f%%) / DEF %d (%.0f%%); montada en %d; motivos %s; duracion media %.0f s; granadas/ronda ATQ %.1f DEF %.1f; %.0f s reales" % [
			zid, int(res["rondas"]), int(res["atq"]), 100.0 * float(res["atq"]) / k, int(res["def"]), 100.0 * float(res["def"]) / k,
			int(res["montadas"]), str(motivos), media, float(gran_atq[0]) / k, float(gran_def[0]) / k, real]
	print(texto)
	res["texto"] = texto
	MontajePartida.desmontar(m)
	await physics_frame
	await physics_frame
	return res
