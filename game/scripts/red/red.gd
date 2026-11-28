class_name Red
extends Node
## Nodo de red: transporte ENet (UDP, puerto 7777 por defecto) o WebSocket (TCP, para los navegadores) y TODOS los RPC del juego en un unico sitio, con el mismo script en el
## servidor y en los clientes (Godot exige que el nodo y sus RPC coincidan en ambos lados). Los RPC solo reenvian a `ServidorRed`
## (autoritativo: lobby, partida, simulacion) o a `ClienteRed` (entradas, prediccion, interpolacion). Prefijos: `c_` cliente -> servidor,
## `s_` servidor -> cliente. Los clientes pueden llamar `c_*` en el servidor, pero ninguno puede llamar a otro cliente.
##
## Simulacion de mala red (`--lag=80 --perdida=2`): `lag_ms` es el RTT simulado (cada extremo retrasa lo que envia la mitad) y `perdida`
## el % de paquetes NO fiables descartados al enviar. Las funciones `enviar*` pasan siempre por aqui.

enum Rol { NINGUNO, SERVIDOR, CLIENTE }

signal peer_conectado(id: int)
signal peer_desconectado(id: int)
signal conectado_al_servidor
signal conexion_fallida
signal servidor_perdido

const FIABLES: Dictionary = {&"c_unirse": true, &"c_lobby": true, &"c_mundo_listo": true, &"c_cmd": true, &"c_chat": true,
		&"s_bienvenida": true, &"s_rechazo": true, &"s_lobby": true, &"s_iniciar": true, &"s_evento": true}
const CANAL_NO_FIABLE: int = 1

var rol: Rol = Rol.NINGUNO
## Transporte activo: `ENetMultiplayerPeer` (UDP) o `WebSocketMultiplayerPeer` (ws/wss; el que usan los navegadores).
var transporte: MultiplayerPeer = null
## Si el transporte activo es WebSocket (el servidor solo ve texto plano `ws`: el TLS lo pone un proxy delante).
var es_websocket: bool = false
var servidor: ServidorRed = null
var cliente: ClienteRed = null
var lag_ms: int = 0
var perdida_pct: float = 0.0
## Estadisticas de envio de esta instancia: {paquetes, bytes} por metodo.
var stats: Dictionary = {}
var _cola: Array = []
var _rng := RandomNumberGenerator.new()
var _api: SceneMultiplayer = null


## Crea un nodo `Red` con su propio `MultiplayerAPI` bajo un nodo propio (para varias instancias en un mismo proceso: tests).
static func nuevo_aislado(arbol: SceneTree, nombre: String) -> Red:
	var raiz := Node.new()
	raiz.name = nombre
	arbol.root.add_child(raiz)
	var api := SceneMultiplayer.new()
	arbol.set_multiplayer(api, raiz.get_path())
	var r := Red.new()
	r.name = "Red"
	raiz.add_child(r)
	return r


func _ready() -> void:
	_rng.randomize()
	_api = multiplayer as SceneMultiplayer
	_api.peer_connected.connect(func(id: int) -> void: peer_conectado.emit(id))
	_api.peer_disconnected.connect(func(id: int) -> void: peer_desconectado.emit(id))
	_api.connected_to_server.connect(func() -> void: conectado_al_servidor.emit())
	_api.connection_failed.connect(func() -> void: conexion_fallida.emit())
	_api.server_disconnected.connect(func() -> void: servidor_perdido.emit())


## Lee `--lag=N` y `--perdida=P` de los argumentos de usuario.
func leer_argumentos(args: PackedStringArray) -> void:
	for a: String in args:
		if a.begins_with("--lag="):
			lag_ms = int(a.get_slice("=", 1))
		elif a.begins_with("--perdida="):
			perdida_pct = float(a.get_slice("=", 1))


func mi_id() -> int:
	return multiplayer.get_unique_id() if transporte != null else 0


func es_servidor() -> bool:
	return rol == Rol.SERVIDOR


# ------------------------------------------------------------------ transporte

## Abre el servidor. `websocket = true` escucha por WebSocket (TCP, ws sin cifrar: detras de un proxy con TLS) en vez de ENet (UDP).
func iniciar_servidor(puerto: int = ProtoRed.PUERTO_DEFECTO, max_clientes: int = 10, websocket: bool = false) -> Error:
	cerrar()
	var err: Error
	if websocket:
		var ws := WebSocketMultiplayerPeer.new()
		err = ws.create_server(puerto)
		transporte = ws
	else:
		var enet := ENetMultiplayerPeer.new()
		err = enet.create_server(puerto, max_clientes)
		transporte = enet
	if err != OK:
		transporte = null
		return err
	es_websocket = websocket
	multiplayer.multiplayer_peer = transporte
	rol = Rol.SERVIDOR
	servidor = ServidorRed.new()
	servidor.name = "Servidor"
	servidor.red = self
	servidor.max_clientes = max_clientes
	add_child(servidor)
	return OK


## Si `destino` es una URL WebSocket (`ws://...` o `wss://...`) y no `IP` / `IP:puerto` (ENet).
static func es_url_ws(destino: String) -> bool:
	var d: String = destino.strip_edges().to_lower()
	return d.begins_with("ws://") or d.begins_with("wss://")


## Conecta con un servidor. `ip` puede ser una IP/host (ENet, usa `puerto`) o una URL `ws://...` / `wss://...` (WebSocket; `puerto` se
## ignora: va en la URL, o es el 80/443 por defecto del esquema).
func iniciar_cliente(ip: String, puerto: int = ProtoRed.PUERTO_DEFECTO) -> Error:
	cerrar()
	var err: Error
	var ws_url: bool = es_url_ws(ip)
	if ws_url:
		var ws := WebSocketMultiplayerPeer.new()
		err = ws.create_client(ip.strip_edges())
		transporte = ws
	else:
		var enet := ENetMultiplayerPeer.new()
		err = enet.create_client(ip, puerto)
		transporte = enet
	if err != OK:
		transporte = null
		return err
	es_websocket = ws_url
	multiplayer.multiplayer_peer = transporte
	rol = Rol.CLIENTE
	cliente = ClienteRed.new()
	cliente.name = "Cliente"
	cliente.red = self
	add_child(cliente)
	return OK


func cerrar() -> void:
	if servidor != null and is_instance_valid(servidor):
		servidor.cerrar()
		servidor.queue_free()
	if cliente != null and is_instance_valid(cliente):
		cliente.cerrar()
		cliente.queue_free()
	servidor = null
	cliente = null
	if transporte != null:
		transporte.close()
		transporte = null
	es_websocket = false
	if _api != null:
		_api.multiplayer_peer = null
	rol = Rol.NINGUNO
	_cola.clear()


func desconectar_peer(id: int) -> void:
	if transporte != null and rol == Rol.SERVIDOR:
		transporte.disconnect_peer(id)


# ------------------------------------------------------------------ envio (con simulacion de lag y perdida)

## Llama al RPC `metodo` en el peer `peer` (1 = servidor) con `args`.
func enviar(peer: int, metodo: StringName, args: Array = []) -> void:
	if transporte == null:
		return
	var fiable: bool = FIABLES.has(metodo)
	if perdida_pct > 0.0 and not fiable and _rng.randf() * 100.0 < perdida_pct:
		return
	var n: int = _tam(args)
	var s: Dictionary = stats.get(metodo, {"paquetes": 0, "bytes": 0})
	s["paquetes"] = int(s["paquetes"]) + 1
	s["bytes"] = int(s["bytes"]) + n
	stats[metodo] = s
	if lag_ms <= 0:
		_enviar_ya(peer, metodo, args)
	else:
		_cola.append([Time.get_ticks_msec() + lag_ms / 2, peer, metodo, args])


func _tam(args: Array) -> int:
	var n: int = 0
	for a: Variant in args:
		n += a.size() if a is PackedByteArray else var_to_bytes(a).size()
	return n


func _enviar_ya(peer: int, metodo: StringName, args: Array) -> void:
	var todo: Array = [peer, metodo]
	todo.append_array(args)
	callv("rpc_id", todo)


func _process(_delta: float) -> void:
	if _cola.is_empty():
		return
	var ahora: int = Time.get_ticks_msec()
	while not _cola.is_empty() and int(_cola[0][0]) <= ahora:
		var m: Array = _cola.pop_front()
		if transporte != null:
			_enviar_ya(int(m[1]), m[2], m[3])


# ------------------------------------------------------------------ RPC cliente -> servidor

@rpc("any_peer", "call_remote", "reliable")
func c_unirse(nombre: String, personaje: String, version: int) -> void:
	if servidor != null:
		servidor.on_unirse(multiplayer.get_remote_sender_id(), nombre, personaje, version)


@rpc("any_peer", "call_remote", "reliable")
func c_lobby(accion: String, a: Variant, b: Variant) -> void:
	if servidor != null:
		servidor.lobby_cmd(multiplayer.get_remote_sender_id(), StringName(accion), a, b)


@rpc("any_peer", "call_remote", "reliable")
func c_mundo_listo() -> void:
	if servidor != null:
		servidor.on_mundo_listo(multiplayer.get_remote_sender_id())


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func c_entradas(paq: PackedByteArray) -> void:
	if servidor != null:
		servidor.on_entradas(multiplayer.get_remote_sender_id(), paq)


@rpc("any_peer", "call_remote", "reliable")
func c_cmd(nombre: String, a: Variant, b: Variant) -> void:
	if servidor != null:
		servidor.on_cmd(multiplayer.get_remote_sender_id(), StringName(nombre), a, b)


@rpc("any_peer", "call_remote", "reliable")
func c_chat(texto: String) -> void:
	if servidor != null:
		servidor.on_chat(multiplayer.get_remote_sender_id(), texto)


@rpc("any_peer", "call_remote", "unreliable")
func c_ping(t: int) -> void:
	if servidor != null:
		enviar(multiplayer.get_remote_sender_id(), &"s_pong", [t])


# ------------------------------------------------------------------ RPC servidor -> cliente (se ignoran si no vienen del servidor)

func _del_servidor() -> bool:
	return cliente != null and multiplayer.get_remote_sender_id() == 1


@rpc("any_peer", "call_remote", "reliable")
func s_bienvenida(info: Dictionary) -> void:
	if _del_servidor():
		cliente.on_bienvenida(info)


@rpc("any_peer", "call_remote", "reliable")
func s_rechazo(motivo: String) -> void:
	if _del_servidor():
		cliente.on_rechazo(motivo)


@rpc("any_peer", "call_remote", "reliable")
func s_lobby(estado: Dictionary) -> void:
	if _del_servidor():
		cliente.on_lobby(estado)


@rpc("any_peer", "call_remote", "reliable")
func s_iniciar(datos: Dictionary) -> void:
	if _del_servidor():
		cliente.on_iniciar(datos)


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func s_snapshot(paq: PackedByteArray) -> void:
	if _del_servidor():
		cliente.on_snapshot(paq)


@rpc("any_peer", "call_remote", "reliable")
func s_evento(tipo: String, datos: Variant) -> void:
	if _del_servidor():
		cliente.on_evento(StringName(tipo), datos)


@rpc("any_peer", "call_remote", "unreliable")
func s_disparo(paq: PackedByteArray) -> void:
	if _del_servidor():
		cliente.on_disparo(paq)


@rpc("any_peer", "call_remote", "unreliable")
func s_pong(t: int) -> void:
	if _del_servidor():
		cliente.on_pong(t)
