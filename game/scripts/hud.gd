extends CanvasLayer
## HUD: punto de mira dinamico y hit marker, vida/armadura, arma y municion, vineta roja al recibir dano
## y datos de depuracion (spawn, posicion, velocidad; F3 los muestra u oculta).

const DURACION_VINETA: float = 0.45

@onready var _info: Label = $Info
@onready var _mira: Control = $Mira
@onready var _combate: Control = $Combate
@onready var _vineta: TextureRect = $Vineta

var _jugador: Jugador
var _vineta_t: float = 0.0
var _vineta_fuerza: float = 0.0


func _ready() -> void:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.62, 1.0])
	g.colors = PackedColorArray([Color(0.8, 0.0, 0.0, 0.0), Color(0.8, 0.0, 0.0, 0.0), Color(0.8, 0.0, 0.0, 0.7)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 1.0)
	t.width = 256
	t.height = 256
	_vineta.texture = t
	_vineta.stretch_mode = TextureRect.STRETCH_SCALE
	_vineta.modulate.a = 0.0


## Conecta el HUD con el jugador: vida, municion, dispersion, hit marker y vineta.
func vincular(jugador: Jugador) -> void:
	_jugador = jugador
	jugador.salud.herido.connect(_on_jugador_herido)
	jugador.gestor.impacto_confirmado.connect(_on_impacto_confirmado)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("depuracion"):
		_info.visible = not _info.visible


func _process(delta: float) -> void:
	if _vineta_t > 0.0:
		_vineta_t = maxf(_vineta_t - delta, 0.0)
		_vineta.modulate.a = _vineta_fuerza * (_vineta_t / DURACION_VINETA)
	if _jugador == null:
		return
	var g: GestorArmas = _jugador.gestor
	var a: ArmaDatos = g.actual()
	var s: Salud = _jugador.salud
	_combate.call("poner", s.vida, s.vida_max, s.armadura, a.nombre,
			g.municion_cargador(), g.municion_reserva(), a.cuerpo_a_cuerpo, g.recargando)
	_mira.call("poner_apertura", _apertura_px(g))


## Separacion (px) de los trazos de la mira: el angulo de dispersion proyectado en pantalla.
func _apertura_px(g: GestorArmas) -> float:
	var cam: Camera3D = _jugador.camara
	var alto: float = float(get_viewport().get_visible_rect().size.y)
	var grados: float = g.dispersion_actual()
	var px: float = tan(deg_to_rad(grados)) / tan(deg_to_rad(cam.fov) * 0.5) * alto * 0.5
	return 3.0 + px


func _on_jugador_herido(cantidad: float, _zona: String, _atacante: Node) -> void:
	_vineta_t = DURACION_VINETA
	_vineta_fuerza = clampf(0.3 + cantidad / 100.0, 0.3, 0.8)
	_vineta.modulate.a = _vineta_fuerza


func _on_impacto_confirmado(zona: String, mato: bool) -> void:
	_mira.call("mostrar_hit", zona == "cabeza", mato)


func actualizar(nombre: String, pos: Vector3, velocidad: float, vuelo: bool) -> void:
	_info.text = "%s%s\nx %.1f  y %.1f  z %.1f\nv %.2f m/s" % [
			nombre, "  [VUELO]" if vuelo else "", pos.x, pos.y, pos.z, velocidad]
