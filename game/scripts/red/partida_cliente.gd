class_name PartidaCliente
extends Partida
## ESPEJO de la `Partida` autoritativa en un cliente: tiene la misma interfaz (el HUD, la tienda y los menus la leen igual), pero no
## decide nada. `ClienteRed` le vuelca el estado que manda el servidor (fase, reloj, marcador, Cachimba, tabla, dinero) y las
## acciones del jugador (comprar, vender, montar, apagar) se convierten en comandos al servidor, que valida y responde. La compra se
## aplica tambien en local (prediccion) para que la tienda responda al instante; el servidor la confirma o la corrige.

## Callable(nombre: StringName, a: Variant, b: Variant) que manda un comando al servidor (lo pone `ClienteRed`).
var enviar_cmd: Callable = Callable()


func _init() -> void:
	manual = true            # no avanza sola con la logica de la partida: solo el reloj visual (`avanzar`)


func _physics_process(delta: float) -> void:
	avanzar(delta)


## Solo relojes visuales; el servidor corrige con cada snapshot.
func avanzar(dt: float) -> void:
	_t += dt
	if fase == Fase.COMPRA or fase == Fase.RONDA or fase == Fase.FIN_RONDA:
		var c: Cachimba = cachimba_nodo
		var corre: bool = true
		if fase == Fase.RONDA and c != null and c.estado != Cachimba.Estado.SIN_MONTAR:
			corre = false
		if corre:
			t_fase = maxf(t_fase - dt, 0.0)
		if c != null:
			if c.estado == Cachimba.Estado.MONTADA or c.estado == Cachimba.Estado.APAGANDO:
				c.restante = maxf(c.restante - dt, 0.0)
			if c.estado == Cachimba.Estado.MONTANDO or c.estado == Cachimba.Estado.APAGANDO:
				c.progreso += dt


func _cmd(nombre: StringName, a: Variant = null, b: Variant = null) -> void:
	if enviar_cmd.is_valid():
		enviar_cmd.call(nombre, a, b)


func comprar(combatiente: Node, id: StringName) -> bool:
	var ev: Dictionary = evaluar_compra(combatiente, id)
	if not bool(ev["ok"]):
		return false
	_cmd(&"comprar", String(id))
	return super.comprar(combatiente, id)


func vender(combatiente: Node, id: StringName) -> bool:
	if not super.vender(combatiente, id):
		return false
	_cmd(&"vender", String(id))
	return true


func montar_cachimba(_combatiente: Node, activo: bool) -> void:
	_cmd(&"montar", activo)


func apagar_cachimba(_combatiente: Node, activo: bool) -> void:
	_cmd(&"apagar", activo)
