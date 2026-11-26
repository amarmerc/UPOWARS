extends Node3D
## Escena principal: carga los spawns, muestra el selector y coordina jugador, HUD y menú.

const RUTA_SPAWNS := "res://data/spawns.json"

var spawns: Array = []
var spawn_actual: Dictionary = {}

@onready var jugador: Jugador = $Jugador
@onready var menu: CanvasLayer = $MenuSpawn
@onready var hud: CanvasLayer = $Hud


func _ready() -> void:
	spawns = _leer_spawns()
	menu.cargar(spawns)
	menu.spawn_elegido.connect(_on_spawn_elegido)
	if not spawns.is_empty():
		_colocar(spawns[0])  # el jugador espera inmóvil en el primer spawn hasta elegir
	jugador.activo = false
	menu.abrir()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("abrir_selector") and not menu.visible:
		jugador.activo = false
		menu.abrir()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	var vel: float = jugador.velocity.length() if jugador.vuelo else jugador.velocidad_horizontal()
	hud.actualizar(str(spawn_actual.get("nombre", "")), jugador.global_position, vel, jugador.vuelo)


func _on_spawn_elegido(datos: Dictionary) -> void:
	_colocar(datos)
	menu.cerrar()
	jugador.activo = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _colocar(datos: Dictionary) -> void:
	spawn_actual = datos
	var p: Array = datos["pos"]
	jugador.nombre_spawn = str(datos["nombre"])
	jugador.teletransportar(Vector3(p[0], p[1], p[2]), float(datos["yaw_deg"]))


func _leer_spawns() -> Array:
	var f := FileAccess.open(RUTA_SPAWNS, FileAccess.READ)
	if f == null:
		push_error("No se puede abrir %s" % RUTA_SPAWNS)
		return []
	var datos: Variant = JSON.parse_string(f.get_as_text())
	if datos is Dictionary and (datos as Dictionary).has("spawns"):
		return (datos as Dictionary)["spawns"]
	push_error("Formato de spawns.json no válido")
	return []
