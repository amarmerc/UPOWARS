class_name ViewmodelCapa
extends CanvasLayer
## Arma en primera persona (blockout con cajas y cilindros). Se dibuja en un SubViewport con mundo propio y camara
## propia, encima de la escena: asi nunca atraviesa paredes. Animacion procedural de retroceso, recarga, cambio y ataque.

## Posicion y escala del arma en pantalla (espacio de la camara del viewmodel), por arma.
const POS_ARMA: Dictionary = {
	&"fusil": Vector3(0.14, -0.15, -0.46), &"pistola": Vector3(0.11, -0.115, -0.40),
	&"navaja": Vector3(0.16, -0.17, -0.46)}
const ESCALA_ARMA: Dictionary = {&"fusil": 0.8, &"pistola": 1.0, &"navaja": 0.8}

var _gestor: GestorArmas
var _jugador: Jugador
var _sv: SubViewport
var _pivote: Node3D
var _modelos: Dictionary = {}  # id -> Node3D
var _flashes: Dictionary = {}  # id -> MeshInstance3D
var _patada: float = 0.0
var _golpe: float = 0.0
var _golpe_fuerte: bool = false
var _flash_t: float = 0.0
var _tiempo: float = 0.0
var _id_actual: StringName = &""


func _init() -> void:
	layer = 0
	name = "Viewmodel"


func _ready() -> void:
	var cont := SubViewportContainer.new()
	cont.stretch = true
	cont.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cont.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(cont)
	_sv = SubViewport.new()
	_sv.own_world_3d = true
	_sv.transparent_bg = true
	_sv.handle_input_locally = false
	_sv.size = Vector2i(1280, 720)
	cont.add_child(_sv)
	var cam := Camera3D.new()
	cam.fov = 62.0
	cam.near = 0.02
	cam.far = 10.0
	cam.current = true
	_sv.add_child(cam)
	var luz := DirectionalLight3D.new()
	luz.rotation_degrees = Vector3(-45.0, -30.0, 0.0)
	luz.light_energy = 1.1
	_sv.add_child(luz)
	var entorno := Environment.new()
	entorno.background_mode = Environment.BG_CLEAR_COLOR
	entorno.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	entorno.ambient_light_color = Color(0.75, 0.78, 0.85)
	entorno.ambient_light_energy = 0.7
	var we := WorldEnvironment.new()
	we.environment = entorno
	_sv.add_child(we)
	_pivote = Node3D.new()
	_sv.add_child(_pivote)
	_construir_modelos()


func vincular(gestor: GestorArmas, jugador: Jugador) -> void:
	_gestor = gestor
	_jugador = jugador
	gestor.arma_cambiada.connect(_on_arma_cambiada)
	gestor.disparo_realizado.connect(_on_disparo)
	gestor.ataque_cuerpo.connect(_on_ataque)
	_on_arma_cambiada(gestor.actual())


func _on_arma_cambiada(a: ArmaDatos) -> void:
	_id_actual = a.id
	_pivote.scale = Vector3.ONE * float(ESCALA_ARMA.get(a.id, 1.0))
	for k: StringName in _modelos:
		(_modelos[k] as Node3D).visible = (k == a.id)
	_patada = 0.0
	_golpe = 0.0


func _on_disparo(a: ArmaDatos, _res: Dictionary, _origen: Vector3) -> void:
	if a.cuerpo_a_cuerpo:
		return
	_patada = minf(_patada + 1.0, 1.6)
	_flash_t = 0.06
	if _flashes.has(a.id):
		var f: MeshInstance3D = _flashes[a.id]
		f.visible = true
		f.rotation.z = randf() * TAU
		f.scale = Vector3.ONE * randf_range(0.8, 1.2)


func _on_ataque(fuerte: bool) -> void:
	_golpe = 1.0
	_golpe_fuerte = fuerte


func _process(delta: float) -> void:
	if _gestor == null or _pivote == null:
		return
	_tiempo += delta
	_patada = move_toward(_patada, 0.0, delta * 9.0)
	_golpe = move_toward(_golpe, 0.0, delta * (2.6 if _golpe_fuerte else 4.0))
	if _flash_t > 0.0:
		_flash_t -= delta
		if _flash_t <= 0.0 and _flashes.has(_id_actual):
			(_flashes[_id_actual] as MeshInstance3D).visible = false
	var pos: Vector3 = POS_ARMA.get(_id_actual, Vector3(0.14, -0.15, -0.45))
	var rot: Vector3 = Vector3.ZERO
	# retroceso: el arma retrocede y levanta la boca
	pos.z += _patada * 0.045
	pos.y += _patada * 0.006
	rot.x += _patada * 0.07
	# vaiven al andar
	if _jugador != null and _jugador.is_on_floor() and not _jugador.vuelo:
		var v: float = clampf(_jugador.velocidad_horizontal() / 5.0, 0.0, 1.0)
		pos.y += sin(_tiempo * 9.5) * 0.006 * v
		pos.x += cos(_tiempo * 4.75) * 0.005 * v
	# recarga: el arma baja y se inclina
	if _gestor.recargando:
		var p: float = _gestor.progreso_recarga()
		var k: float = sin(p * PI)
		pos.y -= k * 0.10
		pos.x -= k * 0.05
		rot.x -= k * 0.55
		rot.z += k * 0.45 + sin(p * TAU * 2.0) * 0.04
	# cambio: sube desde abajo
	if _gestor.cambiando:
		var q: float = 1.0 - _gestor.progreso_cambio()
		q = q * q
		pos.y -= q * 0.32
		rot.x -= q * 0.9
	# ataque cuerpo a cuerpo: tajo en diagonal
	if _golpe > 0.0:
		var s: float = sin((1.0 - _golpe) * PI)
		var amp: float = 1.4 if _golpe_fuerte else 1.0
		pos.x -= s * 0.22 * amp
		pos.z -= s * 0.12 * amp
		rot.y += s * 0.9 * amp
		rot.z -= s * 0.6 * amp
		rot.x += s * 0.3 * amp
	_pivote.position = pos
	_pivote.rotation = rot


# ---------------------------------------------------------------- modelos

func _caja(padre: Node3D, tam: Vector3, pos: Vector3, mat: Material, rot: Vector3 = Vector3.ZERO) -> void:
	var m := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = tam
	m.mesh = bm
	m.material_override = mat
	m.position = pos
	m.rotation = rot
	padre.add_child(m)


func _cilindro(padre: Node3D, radio: float, largo: float, pos: Vector3, mat: Material) -> void:
	var m := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radio
	cm.bottom_radius = radio
	cm.height = largo
	cm.radial_segments = 12
	m.mesh = cm
	m.material_override = mat
	m.position = pos
	m.rotation = Vector3(PI * 0.5, 0.0, 0.0)  # eje del cilindro a lo largo de Z
	padre.add_child(m)


func _material(color: Color, metal: float = 0.4, rugos: float = 0.55) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metal
	m.roughness = rugos
	return m


func _fogonazo(padre: Node3D, pos: Vector3, tam: float) -> MeshInstance3D:
	var g := Gradient.new()
	g.colors = PackedColorArray([Color(1.0, 0.95, 0.7, 1.0), Color(1.0, 0.6, 0.15, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_texture = tex
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var q := QuadMesh.new()
	q.size = Vector2(tam, tam)
	var m := MeshInstance3D.new()
	m.mesh = q
	m.material_override = mat
	m.position = pos
	m.visible = false
	padre.add_child(m)
	return m


func _construir_modelos() -> void:
	var metal := _material(Color(0.16, 0.17, 0.19), 0.6, 0.45)
	var cuerpo := _material(Color(0.24, 0.27, 0.22), 0.3, 0.6)
	var acento := _material(Color(0.78, 0.45, 0.12), 0.2, 0.6)
	var hoja := _material(Color(0.78, 0.8, 0.84), 0.9, 0.25)
	var piel := _material(Color(0.72, 0.55, 0.45), 0.0, 0.8)

	# Fusil R-7: cuerpo largo, cargador curvo, culata, mira
	var fusil := Node3D.new()
	_caja(fusil, Vector3(0.06, 0.09, 0.50), Vector3(0, 0, -0.10), cuerpo)
	_cilindro(fusil, 0.014, 0.34, Vector3(0, 0.015, -0.52), metal)
	_caja(fusil, Vector3(0.05, 0.13, 0.065), Vector3(0, -0.10, -0.02), metal, Vector3(0.18, 0, 0))
	_caja(fusil, Vector3(0.05, 0.10, 0.20), Vector3(0, -0.01, 0.26), cuerpo)
	_caja(fusil, Vector3(0.04, 0.11, 0.05), Vector3(0, -0.095, 0.10), metal, Vector3(-0.25, 0, 0))
	_caja(fusil, Vector3(0.02, 0.03, 0.10), Vector3(0, 0.06, -0.12), acento)
	_caja(fusil, Vector3(0.07, 0.05, 0.18), Vector3(0, -0.02, -0.38), metal)
	_flashes[&"fusil"] = _fogonazo(fusil, Vector3(0, 0.015, -0.72), 0.22)
	_registrar(&"fusil", fusil)

	# Pistola P-9
	var pistola := Node3D.new()
	_caja(pistola, Vector3(0.045, 0.055, 0.21), Vector3(0, 0, -0.08), metal)
	_caja(pistola, Vector3(0.038, 0.12, 0.055), Vector3(0, -0.08, 0.0), cuerpo, Vector3(-0.18, 0, 0))
	_caja(pistola, Vector3(0.02, 0.012, 0.03), Vector3(0, 0.034, 0.0), acento)
	_flashes[&"pistola"] = _fogonazo(pistola, Vector3(0, 0.0, -0.22), 0.16)
	_registrar(&"pistola", pistola)

	# Navaja: mango y hoja
	var navaja := Node3D.new()
	_caja(navaja, Vector3(0.03, 0.035, 0.13), Vector3(0, -0.02, 0.04), cuerpo)
	_caja(navaja, Vector3(0.012, 0.05, 0.24), Vector3(0, 0.0, -0.16), hoja)
	_caja(navaja, Vector3(0.02, 0.012, 0.04), Vector3(0, -0.004, -0.02), acento)
	navaja.rotation = Vector3(0.15, 0.0, 0.35)
	var mano := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.05, 0.05, 0.08)
	mano.mesh = bm
	mano.material_override = piel
	mano.position = Vector3(0, -0.02, 0.09)
	navaja.add_child(mano)
	_registrar(&"navaja", navaja)


func _registrar(id: StringName, nodo: Node3D) -> void:
	nodo.visible = false
	_pivote.add_child(nodo)
	_modelos[id] = nodo
