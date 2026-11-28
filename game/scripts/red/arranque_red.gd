class_name ArranqueRed
extends RefCounted
## Arranque por linea de comandos (despues de `--`):
##   --servidor [puerto=7777] [max=10] [modo=cachimba_wars|pleno|libre] [zona=id] [tam=5] [rondas=7] [t_compra=25] [dificultad=normal]
##       Servidor dedicado SIN ventana (usar `--headless`): no carga UI, viewmodels ni audio.
##   --cliente-sim=IP[:puerto] [nombre=Sim1] [--auto]
##       Cliente automatico (pruebas de carga): se une, se marca listo y juega con entradas guionizadas.
##   --lag=80 --perdida=2      simulacion de mala red (RTT en ms, % de paquetes no fiables perdidos), en servidor y clientes.

static func argumentos() -> Dictionary:
	var r: Dictionary = {"servidor": false, "sim": "", "kv": {}, "lag": 0, "perdida": 0.0}
	for a: String in OS.get_cmdline_user_args():
		if a == "--servidor":
			r["servidor"] = true
		elif a.begins_with("--cliente-sim="):
			r["sim"] = a.get_slice("=", 1)
		elif a.begins_with("--lag="):
			r["lag"] = int(a.get_slice("=", 1))
		elif a.begins_with("--perdida="):
			r["perdida"] = float(a.get_slice("=", 1))
		elif a.contains("="):
			(r["kv"] as Dictionary)[a.get_slice("=", 0)] = a.get_slice("=", 1)
	return r


## Servidor dedicado: mundo minimo (solo el mapa con su colision) + `Red` en /root/Red. Imprime "SERVIDOR LISTO" al escuchar.
static func arrancar_servidor(padre: Node, args: Dictionary) -> Red:
	Bot.sin_visual = true
	Engine.max_fps = 60
	var kv: Dictionary = args["kv"]
	var mundo := Node3D.new()
	mundo.name = "MundoServidor"
	padre.add_child(mundo)
	var mapa: Node3D = (load("res://assets/mapa/upo_blockout.glb") as PackedScene).instantiate() as Node3D
	mapa.transform = Transform3D(Basis.IDENTITY, Vector3(0.002093792, -0.007994771, 0.003832817))   # igual que main.tscn
	mundo.add_child(mapa)
	var red := Red.new()
	red.name = "Red"
	padre.get_tree().root.add_child.call_deferred(red)
	await padre.get_tree().process_frame
	await padre.get_tree().process_frame
	red.lag_ms = int(args["lag"])
	red.perdida_pct = float(args["perdida"])
	var puerto: int = int(kv.get("puerto", ProtoRed.PUERTO_DEFECTO))
	var err: Error = red.iniciar_servidor(puerto, int(kv.get("max", 10)))
	if err != OK:
		push_error("No se puede abrir el puerto UDP %d (error %d)" % [puerto, err])
		padre.get_tree().quit(2)
		return null
	var s: ServidorRed = red.servidor
	s.mundo = mundo
	var cfg: Dictionary = {}
	for k: String in ["modo", "zona", "dificultad"]:
		if kv.has(k):
			cfg[k] = kv[k]
	for k: String in ["rondas", "tam", "bots_libres"]:
		if kv.has(k):
			cfg[k] = int(kv[k])
	s._aplicar_config(cfg)
	if kv.has("t_compra"):
		s.t_compra = float(kv["t_compra"])
	if kv.has("t_ronda"):
		s.t_ronda = float(kv["t_ronda"])
	print("SERVIDOR LISTO udp/%d max=%d modo=%s zona=%s lag=%d perdida=%.1f" % [puerto, s.max_clientes, s.modo, s.zona_id, red.lag_ms, red.perdida_pct])
	return red
