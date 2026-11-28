extends CanvasLayer
## HUD: punto de mira dinamico, hit marker y mira de zoom, vida/escudo, arma y municion, utilidades, carga y calor, aviso de
## recoger armas, marcas de pintura, kill feed, indicador de direccion del dano, ceguera, vineta roja al recibir dano y
## datos de depuracion (spawn, posicion, velocidad; F3 los muestra u oculta).

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
	SenalesCombate.obtener(get_tree()).baja.connect(_on_baja)


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
	var mirada: ArmaSuelo = g.arma_mirada() if (_jugador.activo and not _jugador.muerto) else null
	var carga: float = -1.0
	var etiqueta: String = "CARGA"
	if a.tipo == ArmaDatos.T_PUNO and g.puno_en_vuelo:
		carga = g.progreso_puno()
		etiqueta = "VUELVE"
	elif g.cargando:
		carga = g.carga
		etiqueta = "TENSANDO" if a.tipo == ArmaDatos.T_PROYECTIL else "CARGANDO"
	_combate.call("poner", {
		"vida": s.vida, "vida_max": s.vida_max, "escudo": s.escudo, "arma": a.nombre,
		"cargador": g.municion_cargador(), "reserva": g.municion_reserva(),
		"infinita": a.cargador <= 0 and not a.es_utilidad(), "utilidad": a.es_utilidad(),
		"recargando": g.recargando, "carga": carga, "etiqueta_carga": etiqueta,
		"calor": g.calor if a.tipo == ArmaDatos.T_SABLE else -1.0, "sobrecalentado": g.sobrecalentado,
		"utilidades": g.utilidades_info(),
		"prompt": ("E para recoger %s" % mirada.nombre_arma()) if mirada != null else ""})
	_combate.call("poner_marcas", _marcas(), _jugador.ceguera.nivel() if _jugador.ceguera != null else 0.0)
	var scope: bool = a.mira_zoom and g.aim_t > 0.8
	_mira.call("poner_zoom", scope, g.zoom_actual() if scope else 0.0)
	_mira.call("poner_apertura", _apertura_px(g))


## Marcas de pintura de los enemigos visibles para el equipo del jugador (a traves de paredes).
func _marcas() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var cam: Camera3D = _jugador.camara
	for sm: Salud in Utilidades.marcados_para(self, _jugador.salud.equipo):
		var duenio: Node3D = sm.get_parent() as Node3D
		if duenio == null or sm == _jugador.salud:
			continue
		var p: Vector3 = duenio.global_position + Vector3(0.0, 2.1, 0.0)
		if cam.is_position_behind(p):
			continue
		out.append({"pos": cam.unproject_position(p), "texto": "%d m" % int(p.distance_to(cam.global_position))})   # sin nombre del enemigo
	return out


## Separacion (px) de los trazos de la mira: el angulo de dispersion proyectado en pantalla.
func _apertura_px(g: GestorArmas) -> float:
	var cam: Camera3D = _jugador.camara
	var alto: float = float(get_viewport().get_visible_rect().size.y)
	var grados: float = g.dispersion_actual()
	var px: float = tan(deg_to_rad(grados)) / tan(deg_to_rad(cam.fov) * 0.5) * alto * 0.5
	return 3.0 + minf(px, alto * 0.3)


func _on_jugador_herido(cantidad: float, _zona: String, atacante: Node) -> void:
	_vineta_t = DURACION_VINETA
	_vineta_fuerza = clampf(0.3 + cantidad / 100.0, 0.3, 0.8)
	_vineta.modulate.a = _vineta_fuerza
	var origen: Node3D = atacante as Node3D
	if origen != null and _jugador != null and origen != _jugador:
		var d: Vector3 = origen.global_position - _jugador.global_position
		var f: Vector3 = -_jugador.camara.global_transform.basis.z
		d.y = 0.0
		f.y = 0.0
		if d.length() > 0.1 and f.length() > 0.01:
			_combate.call("anadir_golpe", f.signed_angle_to(d.normalized(), Vector3.DOWN))


func _on_impacto_confirmado(zona: String, mato: bool) -> void:
	_mira.call("mostrar_hit", zona == "cabeza", mato)


func _on_baja(atacante: Node, victima: Salud, arma: ArmaDatos) -> void:
	var sa: Salud = Salud.de(atacante)
	var quien: String = sa.nombre_visible() if sa != null else "El campus"
	var propia: bool = _jugador != null and (sa == _jugador.salud)
	_combate.call("anadir_baja", quien, arma.nombre if arma != null else "", victima.nombre_visible(), propia)


func actualizar(nombre: String, pos: Vector3, velocidad: float, vuelo: bool) -> void:
	_info.text = "%s%s\nx %.1f  y %.1f  z %.1f\nv %.2f m/s" % [
			nombre, "  [VUELO]" if vuelo else "", pos.x, pos.y, pos.z, velocidad]
