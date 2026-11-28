class_name ClienteSim
extends Node
## Cliente automatico para pruebas de carga y `scripts/probar_red.ps1`: se une a un servidor, se marca listo y, ya en partida, camina
## trazando curvas y dispara a intervalos con entradas guionizadas (sin teclado). Imprime estadisticas cada 10 s.

var red: Red
var jugador: Jugador
var ctl: Dictionary = {"mx": 0, "mz": 0, "btn": 0}
var _t: float = 0.0
var _t_est: float = 0.0
var _listo_enviado: bool = false
var _fase: float = 0.0


static func iniciar(juego: Node, mundo: Node3D, jug: Jugador, destino: String, nombre: String, args: Dictionary) -> ClienteSim:
	var cs := ClienteSim.new()
	cs.name = "ClienteSim"
	juego.add_child(cs)
	cs.jugador = jug
	var red := Red.new()
	red.name = "Red"
	juego.get_tree().root.add_child(red)
	cs.red = red
	red.lag_ms = int(args["lag"])
	red.perdida_pct = float(args["perdida"])
	var ip: String = destino.get_slice(":", 0)
	var puerto: int = int(destino.get_slice(":", 1)) if destino.contains(":") else ProtoRed.PUERTO_DEFECTO
	red.iniciar_cliente(ip, puerto)
	var c: ClienteRed = red.cliente
	c.nombre = nombre
	c.personaje = CatalogoPersonajes.ids()[absi(hash(nombre)) % CatalogoPersonajes.ids().size()]
	c.proveedor_mundo = func() -> Array: return [mundo, jug]
	c.entrada_externa = cs._entrada
	c.lobby_actualizado.connect(cs._al_lobby)
	c.rechazado.connect(func(m: String) -> void:
		print("CLIENTE-SIM rechazado: ", m)
		juego.get_tree().quit(3))
	c.desconectado.connect(func() -> void:
		print("CLIENTE-SIM desconectado del servidor")
		juego.get_tree().quit(0))
	return cs


func _al_lobby(_e: Dictionary) -> void:
	if not _listo_enviado:
		_listo_enviado = true
		red.cliente.lobby_cmd(&"listo", true, null)


func _entrada() -> EntradaRed:
	var e := EntradaRed.new()
	_t += 1.0 / 60.0
	_fase += 0.012
	jugador.rotation.y = sin(_fase) * 2.5
	e.mz = -127
	e.mx = int(sin(_t * 0.7) * 60.0)
	e.botones = (EntradaRed.B_CORRER if int(_t / 6.0) % 2 == 0 else 0) | (EntradaRed.B_DISPARAR if int(_t * 2.0) % 5 == 0 else 0)
	e.mira_yaw = jugador.rotation.y
	e.mira_pitch = 0.0
	return e


func _process(delta: float) -> void:
	_t_est += delta
	if _t_est >= 10.0 and red != null and red.cliente != null:
		_t_est = 0.0
		var c: ClienteRed = red.cliente
		print("CLIENTE-SIM estado=%d rtt=%.0f ms snaps=%d correcciones=%d err_max=%.2f m" % [c.estado, c.rtt_ultimo, c.snapshots_recibidos, c.correcciones, c.max_error])
