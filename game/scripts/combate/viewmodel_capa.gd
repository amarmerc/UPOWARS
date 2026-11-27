class_name ViewmodelCapa
extends CanvasLayer
## Arma en primera persona (blockout con cajas y cilindros). Se dibuja en un SubViewport con mundo propio y camara
## propia, encima de la escena: asi nunca atraviesa paredes. Animacion procedural de retroceso, recarga, cambio, ataque,
## apuntar (el arma se centra; con mira de zoom se oculta y el HUD dibuja la mira), cuerda del arco, puño-bot y sable.
## Cada arma tiene un modelo distintivo; los ids son los de `Catalogo` / `ArmaDatos.id`.

## Posicion (espacio de la camara del viewmodel) y escala del arma en pantalla, por id: [pos, escala].
const AJUSTE: Dictionary = {
	&"pistola_9mm": [Vector3(0.11, -0.115, -0.40), 0.8], &"pistola_auto": [Vector3(0.11, -0.115, -0.40), 0.8],
	&"pistola_pesada": [Vector3(0.12, -0.12, -0.40), 1.0], &"revolver_357": [Vector3(0.12, -0.12, -0.40), 0.95],
	&"escopeta_recortada": [Vector3(0.13, -0.14, -0.40), 0.95], &"subfusil_compacto": [Vector3(0.12, -0.13, -0.42), 1.0],
	&"subfusil_9mm": [Vector3(0.13, -0.14, -0.44), 0.85], &"subfusil_45": [Vector3(0.13, -0.14, -0.44), 0.85],
	&"escopeta_corredera": [Vector3(0.14, -0.15, -0.46), 0.72], &"escopeta_auto": [Vector3(0.14, -0.15, -0.46), 0.78],
	&"carabina_556": [Vector3(0.14, -0.15, -0.46), 0.82], &"fusil_asalto": [Vector3(0.14, -0.15, -0.46), 0.8],
	&"fusil_combate": [Vector3(0.14, -0.15, -0.46), 0.75], &"fusil_tirador": [Vector3(0.14, -0.15, -0.46), 0.7],
	&"fusil_precision": [Vector3(0.14, -0.15, -0.46), 0.6], &"ametralladora": [Vector3(0.14, -0.16, -0.46), 0.7],
	&"arco_olivo": [Vector3(-0.02, -0.07, -0.42), 0.9], &"tirachinas": [Vector3(0.1, -0.1, -0.4), 1.0],
	&"lanzacohetes": [Vector3(0.12, -0.14, -0.5), 0.55], &"sable_plasma": [Vector3(0.17, -0.2, -0.4), 0.65],
	&"puno_bot": [Vector3(0.13, -0.12, -0.45), 0.55], &"navaja": [Vector3(0.16, -0.17, -0.46), 0.8],
	&"granada_humo": [Vector3(0.14, -0.13, -0.4), 1.0], &"granada_cegadora": [Vector3(0.14, -0.13, -0.4), 1.0],
	&"granada_explosiva": [Vector3(0.14, -0.13, -0.4), 1.0], &"bote_pintura": [Vector3(0.14, -0.14, -0.42), 0.7],
	&"extintor": [Vector3(0.14, -0.16, -0.45), 0.55], &"altavoz": [Vector3(0.14, -0.14, -0.45), 0.55]}

## Ajuste de los modelos externos (`ModelosArmas`): [pos, escala]. El origen del modelo es la empunadura; `pos` es donde queda
## esa empunadura en el espacio de la camara. Si el arma sobresale hacia atras mas de lo que cabe se empuja hacia delante.
const AJUSTE_EXT: Dictionary = {
	&"pistola_9mm": [Vector3(0.13, -0.12, -0.40), 1.0], &"pistola_auto": [Vector3(0.13, -0.12, -0.40), 1.0],
	&"pistola_pesada": [Vector3(0.13, -0.12, -0.40), 1.0], &"revolver_357": [Vector3(0.13, -0.12, -0.40), 1.0],
	&"escopeta_recortada": [Vector3(0.14, -0.13, -0.40), 1.0], &"subfusil_compacto": [Vector3(0.14, -0.13, -0.42), 1.0],
	&"subfusil_9mm": [Vector3(0.14, -0.14, -0.44), 0.9], &"subfusil_45": [Vector3(0.14, -0.14, -0.44), 1.0],
	&"escopeta_corredera": [Vector3(0.14, -0.14, -0.46), 0.7], &"escopeta_auto": [Vector3(0.14, -0.14, -0.46), 0.85],
	&"carabina_556": [Vector3(0.14, -0.14, -0.46), 0.9], &"fusil_asalto": [Vector3(0.14, -0.14, -0.46), 0.75],
	&"fusil_combate": [Vector3(0.14, -0.14, -0.46), 0.72], &"fusil_tirador": [Vector3(0.14, -0.14, -0.46), 0.62],
	&"fusil_precision": [Vector3(0.14, -0.14, -0.46), 0.6], &"ametralladora": [Vector3(0.14, -0.15, -0.46), 0.72],
	&"arco_olivo": [Vector3(-0.02, -0.07, -0.42), 0.62], &"sable_plasma": [Vector3(0.17, -0.2, -0.4), 0.65]}

var _gestor: GestorArmas
var _jugador: Jugador
var _sv: SubViewport
var _pivote: Node3D
var _modelos: Dictionary = {}  # id -> Node3D
var _externos: Dictionary = {}  # id -> true si el modelo es el importado (no el procedural)
var _atras: Dictionary = {}  # id -> cuanto sobresale el modelo hacia atras (m, sin escalar)
var _bocas: Dictionary = {}  # id -> punto de la boca en el espacio del modelo
var _arco_cy: float = 0.36
var _arco_cz: float = 0.0
var _sable_t: float = 1.0  # encendido del sable (0 apagado, 1 completo)
var _hoja_nodo: Node3D
var _flashes: Dictionary = {}  # id -> MeshInstance3D
var _patada: float = 0.0
var _golpe: float = 0.0
var _golpe_fuerte: bool = false
var _flash_t: float = 0.0
var _tiempo: float = 0.0
var _id_actual: StringName = &""
var _arma_actual: ArmaDatos
var _bloq: float = 0.0
var _chispa_t: float = 0.0
# piezas animadas
var _cuerda: Array[MeshInstance3D] = []
var _flecha: Node3D
var _puno: Node3D
var _puno_mat: StandardMaterial3D
var _hoja_mat: StandardMaterial3D
var _luz_sable: OmniLight3D
var _cohete: Node3D
var _chispa_sable: MeshInstance3D
# materiales
var _m_metal: StandardMaterial3D
var _m_cuerpo: StandardMaterial3D
var _m_acento: StandardMaterial3D
var _m_hoja: StandardMaterial3D
var _m_piel: StandardMaterial3D
var _m_madera: StandardMaterial3D
var _m_oscuro: StandardMaterial3D


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
	luz.light_energy = 1.5
	_sv.add_child(luz)
	var entorno := Environment.new()
	entorno.background_mode = Environment.BG_CLEAR_COLOR
	entorno.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	entorno.ambient_light_color = Color(0.75, 0.78, 0.85)
	entorno.ambient_light_energy = 1.1
	var we := WorldEnvironment.new()
	we.environment = entorno
	_sv.add_child(we)
	_pivote = Node3D.new()
	_sv.add_child(_pivote)
	_construir_modelos()
	_sustituir_por_externos()


## Ids de los articulos con modelo (los que tienen icono en la tienda).
func ids_modelo() -> Array[StringName]:
	var r: Array[StringName] = []
	for k: StringName in _modelos:
		r.append(k)
	return r


## Para los iconos de la tienda (tests/generar_iconos.gd): deja solo el modelo `id`, de perfil y encuadrado, en un SubViewport de
## `tam` pixeles con fondo transparente; devuelve ese SubViewport (dibujalo 2-3 fotogramas y guarda `get_texture()`), o null si no hay modelo.
func preparar_icono(id: StringName, tam: Vector2i) -> SubViewport:
	if not _modelos.has(id) or _sv == null:
		return null
	(_sv.get_parent() as SubViewportContainer).stretch = false
	_sv.size = tam
	for k: StringName in _modelos:
		(_modelos[k] as Node3D).visible = (k == id)
	_pivote.visible = true
	_pivote.scale = Vector3.ONE
	_pivote.position = Vector3.ZERO
	if _hoja_nodo != null:
		_hoja_nodo.scale = Vector3.ONE
	_pivote.rotation = Vector3(deg_to_rad(-8.0), deg_to_rad(-90.0), 0.0)   # de perfil, boca del arma a la derecha
	_iluminar_icono()
	var caja := AABB()
	var primero: bool = true
	for m: Node in (_modelos[id] as Node3D).find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = m as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		# sin manos ni cuerda procedural (cajas) en el icono: solo el modelo del arma
		if mi.mesh is BoxMesh and (mi.material_override == _m_piel or (mi.mesh as BoxMesh).size.z >= 0.99):
			mi.visible = false
			continue
		var a: AABB = mi.global_transform * mi.mesh.get_aabb()
		caja = a if primero else caja.merge(a)
		primero = false
	if id == &"sable_plasma":   # la hoja (malla con piel) no cuenta en el AABB: se anade a mano
		caja = caja.expand((_modelos[id] as Node3D).global_transform * Vector3(0.0, 0.0, -0.75))
	elif id == &"arco_olivo":   # el arco es vertical: se tumba para aprovechar el icono apaisado
		_pivote.basis = Basis(Vector3.BACK, PI * 0.5) * Basis(Vector3.UP, -PI * 0.5)
		caja = AABB()
		primero = true
		for m2: Node in (_modelos[id] as Node3D).find_children("*", "MeshInstance3D", true, false):
			var mi2: MeshInstance3D = m2 as MeshInstance3D
			if mi2.mesh == null or not mi2.visible:
				continue
			var a2: AABB = mi2.global_transform * mi2.mesh.get_aabb()
			caja = a2 if primero else caja.merge(a2)
			primero = false
	var cam: Camera3D = _sv.get_camera_3d()
	var th: float = tan(deg_to_rad(cam.fov * 0.5))
	var c: Vector3 = caja.get_center()
	var d: float = maxf((caja.size.y * 0.5) / (0.86 * th), (caja.size.x * 0.5) / (0.86 * th * float(tam.x) / float(tam.y)))
	d = maxf(d, caja.size.z * 0.5 + 0.1)
	_pivote.position = Vector3(-c.x, -c.y, -d - c.z)
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	return _sv


## Luz mas fuerte y frontal para los iconos (las armas son oscuras sobre el fondo oscuro de la tienda).
func _iluminar_icono() -> void:
	for h: Node in _sv.get_children():
		if h is DirectionalLight3D:
			(h as DirectionalLight3D).light_energy = 2.6
		elif h is WorldEnvironment:
			var e: Environment = (h as WorldEnvironment).environment
			e.ambient_light_energy = 2.0
			e.ambient_light_color = Color(0.9, 0.92, 1.0)
	if _sv.get_node_or_null("LuzIcono") == null:
		var l2 := DirectionalLight3D.new()
		l2.name = "LuzIcono"
		l2.rotation_degrees = Vector3(-20.0, 150.0, 0.0)
		l2.light_energy = 1.6
		_sv.add_child(l2)


func vincular(gestor: GestorArmas, jugador: Jugador) -> void:
	_gestor = gestor
	_jugador = jugador
	gestor.arma_cambiada.connect(_on_arma_cambiada)
	gestor.disparo_realizado.connect(_on_disparo)
	gestor.ataque_cuerpo.connect(_on_ataque)
	gestor.bloqueo_realizado.connect(_on_bloqueo)
	_on_arma_cambiada(gestor.actual())


func _on_arma_cambiada(a: ArmaDatos) -> void:
	_id_actual = a.id
	_arma_actual = a
	var aj: Array = _ajuste(a.id)
	_pivote.scale = Vector3.ONE * float(aj[1])
	if a.id == &"sable_plasma":
		_sable_t = 0.0   # al sacarlo se enciende la hoja
	for k: StringName in _modelos:
		(_modelos[k] as Node3D).visible = (k == a.id)
	_pivote.visible = true
	_patada = 0.0
	_golpe = 0.0


## [pos, escala] del arma `id` en pantalla; los modelos importados se empujan hacia delante si la culata llegaria a la camara.
func _ajuste(id: StringName) -> Array:
	if _externos.has(id):
		var aj: Array = (AJUSTE_EXT.get(id, [Vector3(0.14, -0.14, -0.45), 0.8]) as Array).duplicate()
		var p: Vector3 = aj[0]
		p.z = minf(p.z, -0.12 - float(_atras.get(id, 0.0)) * float(aj[1]))
		aj[0] = p
		return aj
	return AJUSTE.get(id, [Vector3(0.14, -0.15, -0.45), 1.0])


func _on_disparo(a: ArmaDatos, _res: Dictionary, _origen: Vector3) -> void:
	if a.es_melee():
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


func _on_bloqueo() -> void:
	_chispa_t = 0.12
	if _chispa_sable != null:
		_chispa_sable.visible = true
		_chispa_sable.rotation.z = randf() * TAU


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
	if _chispa_t > 0.0:
		_chispa_t -= delta
		if _chispa_t <= 0.0 and _chispa_sable != null:
			_chispa_sable.visible = false
	var aj: Array = _ajuste(_id_actual)
	var pos: Vector3 = aj[0]
	var rot: Vector3 = Vector3.ZERO
	var aim: float = _gestor.aim_t
	# apuntar: el arma se centra y sube un poco; con mira de zoom se oculta (el HUD dibuja la mira)
	if aim > 0.0:
		pos = pos.lerp(Vector3(0.0, pos.y * 0.5, pos.z + 0.02), aim)
	_pivote.visible = not (_arma_actual != null and _arma_actual.mira_zoom and aim > 0.8)
	# retroceso: el arma retrocede y levanta la boca
	var kp: float = 1.0 - 0.6 * aim
	pos.z += _patada * 0.045 * kp
	pos.y += _patada * 0.006 * kp
	rot.x += _patada * 0.07 * kp
	# vaiven al andar (menos al apuntar) y al correr el arma se inclina
	if _jugador != null and _jugador.is_on_floor() and not _jugador.vuelo:
		var v: float = clampf(_jugador.velocidad_horizontal() / 5.0, 0.0, 1.0) * (1.0 - 0.8 * aim)
		pos.y += sin(_tiempo * 9.5) * 0.006 * v
		pos.x += cos(_tiempo * 4.75) * 0.005 * v
		if _jugador.corriendo:
			pos.y -= 0.03
			rot.x -= 0.25
			rot.y += 0.35
			pos.y += sin(_tiempo * 12.0) * 0.008
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
	# ataque cuerpo a cuerpo / lanzamiento: tajo en diagonal
	if _golpe > 0.0:
		var s: float = sin((1.0 - _golpe) * PI)
		var amp: float = 1.4 if _golpe_fuerte else 1.0
		pos.x -= s * 0.22 * amp
		pos.z -= s * 0.12 * amp
		rot.y += s * 0.9 * amp
		rot.z -= s * 0.6 * amp
		rot.x += s * 0.3 * amp
	# sable: el bloqueo lo levanta delante, en vertical
	var objetivo_bloq: float = 1.0 if _gestor.bloqueando else 0.0
	_bloq = move_toward(_bloq, objetivo_bloq, delta * 7.0)
	if _bloq > 0.0:
		pos = pos.lerp(Vector3(0.02, -0.02, -0.36), _bloq)
		rot = rot.lerp(Vector3(-0.35, 0.0, -0.1) + Vector3(0, sin(_tiempo * 30.0) * 0.01, 0), _bloq)
	_animar_piezas()
	_pivote.position = pos
	_pivote.rotation = rot


## Cuerda y flecha del arco, puño-bot, brillo del sable y cohete cargado.
func _animar_piezas() -> void:
	var a: ArmaDatos = _arma_actual
	if a == null:
		return
	match a.id:
		&"arco_olivo":
			var pull: float = _gestor.carga if _gestor.cargando else 0.0
			_poner_cuerda(Vector3(0, 0.36, 0.0), Vector3(0, -0.36, 0.0), Vector3(0, 0.0, 0.03 + pull * 0.30))
			_flecha.visible = _gestor.municion_cargador() > 0
			_flecha.position = Vector3(0, 0.0, -0.22 + 0.03 + pull * 0.30)
		&"puno_bot":
			_puno.visible = not _gestor.puno_en_vuelo
			var c: float = _gestor.carga if _gestor.cargando else 0.0
			_puno.position = Vector3(0, 0, -0.17 + c * 0.07 + (_gestor.progreso_puno() - 1.0) * 0.0) \
					+ Vector3(sin(_tiempo * 60.0), cos(_tiempo * 53.0), 0.0) * 0.004 * c
			_puno_mat.emission_energy_multiplier = 0.3 + c * 3.0
		&"sable_plasma":
			_sable_t = move_toward(_sable_t, 1.0, get_process_delta_time() * 3.0)
			if _hoja_nodo != null:   # encendido: la hoja crece desde la boca de la empunadura
				var k: float = 1.0 - pow(1.0 - _sable_t, 3.0)
				_hoja_nodo.scale = Vector3(maxf(k, 0.001), 1.0, 1.0)
				if _luz_sable != null:
					_luz_sable.visible = k > 0.05
			var cal: float = clampf(_gestor.calor / 100.0, 0.0, 1.0)
			var col: Color = Color(0.2, 0.85, 1.0).lerp(Color(1.0, 0.35, 0.1), cal)
			var energia: float = 2.4 + sin(_tiempo * 25.0) * 0.25
			if _gestor.sobrecalentado:
				col = Color(0.5, 0.1, 0.05)
				energia = 0.3
			_hoja_mat.emission = col
			_hoja_mat.albedo_color = col
			_hoja_mat.emission_energy_multiplier = energia
			_luz_sable.light_color = col
			_luz_sable.light_energy = 0.3 if _gestor.sobrecalentado else 1.2
		&"lanzacohetes":
			_cohete.visible = _gestor.municion_cargador() > 0


func _poner_cuerda(punta_a: Vector3, punta_b: Vector3, nock: Vector3) -> void:
	_segmento(_cuerda[0], punta_a, nock)
	_segmento(_cuerda[1], nock, punta_b)


func _segmento(m: MeshInstance3D, a: Vector3, b: Vector3) -> void:
	var l: float = maxf(a.distance_to(b), 0.001)
	m.position = (a + b) * 0.5
	var dir: Vector3 = (b - a) / l
	var up: Vector3 = Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT
	m.basis = Basis.looking_at(dir, up) * Basis.from_scale(Vector3(1, 1, l))


# ---------------------------------------------------------------- modelos

func _caja(padre: Node3D, tam: Vector3, pos: Vector3, mat: Material, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = tam
	m.mesh = bm
	m.material_override = mat
	m.position = pos
	m.rotation = rot
	padre.add_child(m)
	return m


func _cilindro(padre: Node3D, radio: float, largo: float, pos: Vector3, mat: Material, eje_z: bool = true,
		radio_sup: float = -1.0) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radio if radio_sup < 0.0 else radio_sup
	cm.bottom_radius = radio
	cm.height = largo
	cm.radial_segments = 12
	m.mesh = cm
	m.material_override = mat
	m.position = pos
	if eje_z:
		m.rotation = Vector3(PI * 0.5, 0.0, 0.0)  # eje del cilindro a lo largo de Z
	padre.add_child(m)
	return m


func _esfera(padre: Node3D, radio: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radio
	sm.height = radio * 2.0
	sm.radial_segments = 16
	sm.rings = 8
	m.mesh = sm
	m.material_override = mat
	m.position = pos
	padre.add_child(m)
	return m


func _material(color: Color, metal: float = 0.4, rugos: float = 0.55) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metal
	m.roughness = rugos
	return m


func _emisivo(color: Color, energia: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energia
	m.roughness = 0.3
	return m


func _fogonazo(padre: Node3D, pos: Vector3, tam: float, c1: Color = Color(1.0, 0.95, 0.7, 1.0),
		c2: Color = Color(1.0, 0.6, 0.15, 0.0)) -> MeshInstance3D:
	var g := Gradient.new()
	g.colors = PackedColorArray([c1, c2])
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


func _registrar(id: StringName, nodo: Node3D) -> void:
	nodo.visible = false
	_pivote.add_child(nodo)
	_modelos[id] = nodo


func _mano(padre: Node3D, pos: Vector3, tam: Vector3 = Vector3(0.05, 0.05, 0.08)) -> void:
	_caja(padre, tam, pos, _m_piel)


## Arma larga parametrica: cuerpo, canon, cargador, culata, mira y extras segun `o`.
func _arma_larga(id: StringName, o: Dictionary) -> void:
	var n := Node3D.new()
	var largo: float = o.get("largo", 0.5)
	var alto: float = o.get("alto", 0.09)
	var ancho: float = o.get("ancho", 0.06)
	var canon: float = o.get("canon", 0.34)
	var mat: Material = o.get("mat", _m_cuerpo)
	var z_fin: float = -0.10 - largo * 0.5
	_caja(n, Vector3(ancho, alto, largo), Vector3(0, 0, -0.10), mat)
	_cilindro(n, o.get("rc", 0.014), canon, Vector3(0, 0.015, z_fin - canon * 0.5 + 0.02), _m_metal)
	_caja(n, Vector3(0.04, 0.11, 0.05), Vector3(0, -0.095, 0.10), _m_metal, Vector3(-0.25, 0, 0))
	if o.get("guardamano", true):
		_caja(n, Vector3(ancho + 0.01, 0.05, 0.18), Vector3(0, -0.02, z_fin - 0.03), _m_metal)
	match o.get("cargador", "curvo"):
		"curvo":
			_caja(n, Vector3(0.05, 0.13, 0.065), Vector3(0, -0.10, -0.02), _m_metal, Vector3(0.18, 0, 0))
		"recto":
			_caja(n, Vector3(0.045, o.get("alto_mag", 0.15), 0.055), Vector3(0, -0.11, -0.04), _m_metal)
		"grande":
			_caja(n, Vector3(0.06, 0.16, 0.09), Vector3(0, -0.12, -0.03), _m_metal, Vector3(0.12, 0, 0))
		"lateral":
			_caja(n, Vector3(0.12, 0.12, 0.15), Vector3(-0.085, -0.04, -0.04), _m_oscuro)
		"tubo":
			_cilindro(n, 0.018, canon * 0.8, Vector3(0, -0.04, z_fin - canon * 0.4 + 0.02), _m_metal)
	if o.get("culata", true):
		_caja(n, Vector3(0.05, 0.10, 0.20), Vector3(0, -0.01, -0.10 + largo * 0.5 + 0.11), o.get("mat_culata", mat))
	match o.get("mira", "punto"):
		"punto":
			_caja(n, Vector3(0.02, 0.03, 0.10), Vector3(0, alto * 0.5 + 0.015, -0.12), _m_acento)
		"zoom":
			var r: float = o.get("radio_mira", 0.028)
			_cilindro(n, r, o.get("largo_mira", 0.22), Vector3(0, alto * 0.5 + 0.045, -0.12), _m_oscuro)
			_cilindro(n, r * 1.3, 0.03, Vector3(0, alto * 0.5 + 0.045, -0.22), _m_metal)
			_cilindro(n, r * 1.3, 0.03, Vector3(0, alto * 0.5 + 0.045, -0.02), _m_metal)
			_caja(n, Vector3(0.02, 0.03, 0.06), Vector3(0, alto * 0.5 + 0.015, -0.12), _m_metal)
	if o.get("corredera", false):  # escopeta de corredera: pomo movil bajo el canon
		_caja(n, Vector3(0.06, 0.055, 0.16), Vector3(0, -0.045, z_fin - 0.10), _m_madera)
	if o.get("bipode", false):
		_caja(n, Vector3(0.012, 0.012, 0.16), Vector3(-0.03, -0.09, z_fin - canon * 0.6), _m_metal, Vector3(0, 0, 0.7))
		_caja(n, Vector3(0.012, 0.012, 0.16), Vector3(0.03, -0.09, z_fin - canon * 0.6), _m_metal, Vector3(0, 0, -0.7))
	if o.get("cerrojo", false):
		_caja(n, Vector3(0.05, 0.015, 0.015), Vector3(0.05, 0.03, 0.02), _m_metal)
		_esfera(n, 0.014, Vector3(0.078, 0.03, 0.02), _m_metal)
	if o.get("cinta", false):  # ametralladora: cinta de balas
		_caja(n, Vector3(0.015, 0.05, 0.12), Vector3(-0.06, -0.01, -0.12), _m_acento, Vector3(0, 0, -0.5))
	_mano(n, Vector3(0.0, -0.065, z_fin - 0.02), Vector3(0.06, 0.05, 0.09))
	_flashes[id] = _fogonazo(n, Vector3(0, 0.015, z_fin - canon - 0.03), o.get("flash", 0.22))
	_registrar(id, n)


## Pistola parametrica: corredera, empuñadura y extras.
func _pistola(id: StringName, o: Dictionary) -> void:
	var n := Node3D.new()
	var largo: float = o.get("largo", 0.21)
	var alto: float = o.get("alto", 0.055)
	var ancho: float = o.get("ancho", 0.045)
	_caja(n, Vector3(ancho, alto, largo), Vector3(0, 0, -0.08 - (largo - 0.21) * 0.5), _m_metal)
	_caja(n, Vector3(0.038, 0.12, 0.055), Vector3(0, -0.08, 0.0), _m_cuerpo, Vector3(-0.18, 0, 0))
	_caja(n, Vector3(0.02, 0.012, 0.03), Vector3(0, alto * 0.5 + 0.007, 0.0), _m_acento)
	if o.get("cargador_largo", false):
		_caja(n, Vector3(0.034, 0.10, 0.045), Vector3(0, -0.17, 0.02), _m_oscuro, Vector3(-0.18, 0, 0))
	if o.get("tambor", false):
		_cilindro(n, 0.04, 0.07, Vector3(0, 0.0, -0.06), _m_acento)
		_cilindro(n, 0.012, 0.18, Vector3(0, 0.02, -0.2), _m_metal)
	if o.get("canon_grueso", false):
		_cilindro(n, 0.022, 0.1, Vector3(0, 0.0, -0.22), _m_metal)
	_mano(n, Vector3(0.0, -0.1, 0.03), Vector3(0.06, 0.06, 0.07))
	_flashes[id] = _fogonazo(n, Vector3(0, 0.0, -0.22 - (largo - 0.21) * 0.5 - (0.09 if o.get("tambor", false) else 0.0)),
			o.get("flash", 0.16))
	_registrar(id, n)


func _construir_modelos() -> void:
	_m_metal = _material(Color(0.16, 0.17, 0.19), 0.6, 0.45)
	_m_cuerpo = _material(Color(0.24, 0.27, 0.22), 0.3, 0.6)
	_m_acento = _material(Color(0.78, 0.45, 0.12), 0.2, 0.6)
	_m_hoja = _material(Color(0.78, 0.8, 0.84), 0.9, 0.25)
	_m_piel = _material(Color(0.72, 0.55, 0.45), 0.0, 0.8)
	_m_madera = _material(Color(0.42, 0.27, 0.15), 0.0, 0.7)
	_m_oscuro = _material(Color(0.08, 0.09, 0.1), 0.4, 0.5)

	# --- pistolas y secundarias
	_pistola(&"pistola_9mm", {})
	_pistola(&"pistola_auto", {"largo": 0.24, "cargador_largo": true})
	_pistola(&"pistola_pesada", {"largo": 0.27, "alto": 0.07, "ancho": 0.055, "canon_grueso": true, "flash": 0.22})
	_pistola(&"revolver_357", {"tambor": true, "flash": 0.2})
	_construir_recortada()
	_arma_larga(&"subfusil_compacto", {"largo": 0.26, "canon": 0.1, "alto": 0.08, "ancho": 0.05, "cargador": "recto",
			"culata": false, "guardamano": false, "mira": "punto", "flash": 0.17})
	# --- subfusiles
	_arma_larga(&"subfusil_9mm", {"largo": 0.34, "canon": 0.16, "cargador": "recto", "alto_mag": 0.17, "culata": true,
			"guardamano": false, "flash": 0.19})
	_arma_larga(&"subfusil_45", {"largo": 0.38, "canon": 0.2, "ancho": 0.07, "alto": 0.1, "cargador": "grande",
			"culata": true, "mat": _m_oscuro, "mat_culata": _m_cuerpo, "flash": 0.22})
	# --- escopetas
	_arma_larga(&"escopeta_corredera", {"largo": 0.34, "canon": 0.5, "rc": 0.022, "cargador": "tubo", "culata": true,
			"mat_culata": _m_madera, "corredera": true, "guardamano": false, "mira": "punto", "flash": 0.3})
	_arma_larga(&"escopeta_auto", {"largo": 0.4, "canon": 0.36, "rc": 0.022, "ancho": 0.07, "alto": 0.1,
			"cargador": "grande", "culata": true, "mat": _m_oscuro, "mat_culata": _m_oscuro, "flash": 0.3})
	# --- fusiles
	_arma_larga(&"carabina_556", {"largo": 0.4, "canon": 0.22, "cargador": "curvo", "culata": true, "mira": "punto"})
	_arma_larga(&"fusil_asalto", {})
	_arma_larga(&"fusil_combate", {"largo": 0.55, "canon": 0.4, "ancho": 0.07, "alto": 0.1, "cargador": "grande",
			"culata": true, "mat_culata": _m_madera, "mat": _m_oscuro, "flash": 0.28})
	_arma_larga(&"fusil_tirador", {"largo": 0.5, "canon": 0.42, "cargador": "recto", "culata": true, "mira": "zoom",
			"radio_mira": 0.026, "largo_mira": 0.2, "flash": 0.24, "mat": _m_oscuro})
	_arma_larga(&"fusil_precision", {"largo": 0.5, "canon": 0.6, "rc": 0.016, "cargador": "ninguno", "culata": true,
			"mat_culata": _m_madera, "mira": "zoom", "radio_mira": 0.034, "largo_mira": 0.3, "bipode": true,
			"cerrojo": true, "flash": 0.3, "mat": _m_cuerpo, "guardamano": false})
	_arma_larga(&"ametralladora", {"largo": 0.52, "canon": 0.4, "rc": 0.02, "ancho": 0.08, "alto": 0.11,
			"cargador": "lateral", "culata": true, "mat": _m_oscuro, "bipode": true, "cinta": true, "flash": 0.28})
	# --- especiales
	_construir_arco()
	_construir_tirachinas()
	_construir_lanzacohetes()
	_construir_sable()
	_construir_puno()
	_construir_navaja()
	# --- utilidades
	_construir_utilidades()


func _construir_recortada() -> void:
	var n := Node3D.new()
	_cilindro(n, 0.02, 0.3, Vector3(-0.022, 0.0, -0.17), _m_metal)
	_cilindro(n, 0.02, 0.3, Vector3(0.022, 0.0, -0.17), _m_metal)
	_caja(n, Vector3(0.1, 0.06, 0.12), Vector3(0, -0.005, 0.0), _m_metal)
	_caja(n, Vector3(0.05, 0.12, 0.07), Vector3(0, -0.075, 0.07), _m_madera, Vector3(-0.35, 0, 0))
	_caja(n, Vector3(0.07, 0.04, 0.08), Vector3(0, -0.035, -0.12), _m_madera)
	_mano(n, Vector3(0, -0.07, -0.12), Vector3(0.07, 0.05, 0.09))
	_flashes[&"escopeta_recortada"] = _fogonazo(n, Vector3(0, 0.0, -0.36), 0.3)
	_registrar(&"escopeta_recortada", n)


func _construir_arco() -> void:
	var n := Node3D.new()
	var madera := _material(Color(0.5, 0.33, 0.17), 0.0, 0.6)
	var pasos: int = 12
	var largo: float = 0.4
	var ant: Vector3 = Vector3.ZERO
	for i in range(pasos + 1):
		var y: float = lerpf(-largo, largo, float(i) / pasos)
		var u: float = y / largo
		var p: Vector3 = Vector3(0, y, -0.14 * (1.0 - u * u))
		if i > 0:
			var w: float = 0.026 - 0.012 * absf(u)
			_segmento(_caja(n, Vector3(w, w, 1.0), Vector3.ZERO, madera), ant, p)
		ant = p
	_caja(n, Vector3(0.03, 0.12, 0.05), Vector3(0, 0, -0.14), _m_oscuro)  # empuñadura
	_mano(n, Vector3(0.0, -0.01, -0.12), Vector3(0.06, 0.07, 0.07))
	var cuerda_m := _material(Color(0.9, 0.88, 0.8), 0.0, 0.9)
	for i in 2:
		var c := _caja(n, Vector3(0.004, 0.004, 1.0), Vector3.ZERO, cuerda_m)
		_cuerda.append(c)
	_flecha = _caja(n, Vector3(0.008, 0.008, 0.56), Vector3(0, 0, -0.2), _material(Color(0.6, 0.45, 0.25), 0.0, 0.7))
	_caja(_flecha, Vector3(0.03, 0.03, 0.06), Vector3(0, 0, -0.29), _m_metal)  # punta
	_registrar(&"arco_olivo", n)


func _construir_tirachinas() -> void:
	var n := Node3D.new()
	var madera := _material(Color(0.45, 0.3, 0.16), 0.0, 0.7)
	_caja(n, Vector3(0.03, 0.12, 0.03), Vector3(0, -0.06, 0.02), madera)
	_caja(n, Vector3(0.025, 0.1, 0.025), Vector3(-0.045, 0.05, 0.0), madera, Vector3(0, 0, 0.5))
	_caja(n, Vector3(0.025, 0.1, 0.025), Vector3(0.045, 0.05, 0.0), madera, Vector3(0, 0, -0.5))
	var goma := _material(Color(0.1, 0.1, 0.1), 0.0, 0.9)
	_segmento(_caja(n, Vector3(0.006, 0.006, 1.0), Vector3.ZERO, goma), Vector3(-0.07, 0.1, 0.0), Vector3(0, 0.05, 0.12))
	_segmento(_caja(n, Vector3(0.006, 0.006, 1.0), Vector3.ZERO, goma), Vector3(0.07, 0.1, 0.0), Vector3(0, 0.05, 0.12))
	_esfera(n, 0.018, Vector3(0, 0.05, 0.12), _material(Color(0.4, 0.4, 0.38), 0.1, 0.8))
	_mano(n, Vector3(0, -0.1, 0.03), Vector3(0.06, 0.06, 0.07))
	n.rotation = Vector3(0.0, 0.0, 0.0)
	_registrar(&"tirachinas", n)


func _construir_lanzacohetes() -> void:
	var n := Node3D.new()
	var tubo := _material(Color(0.28, 0.32, 0.24), 0.3, 0.6)
	_cilindro(n, 0.065, 0.95, Vector3(0, 0.02, -0.15), tubo)
	_cilindro(n, 0.065, 0.14, Vector3(0, 0.02, 0.36), _m_metal, true, 0.09)  # boca trasera acampanada
	_cilindro(n, 0.08, 0.1, Vector3(0, 0.02, -0.64), _m_metal)
	_caja(n, Vector3(0.04, 0.12, 0.05), Vector3(0, -0.09, 0.0), _m_oscuro, Vector3(-0.2, 0, 0))
	_caja(n, Vector3(0.04, 0.1, 0.05), Vector3(0, -0.08, -0.22), _m_oscuro)
	_caja(n, Vector3(0.02, 0.06, 0.08), Vector3(0, 0.1, -0.1), _m_acento)
	_caja(n, Vector3(0.01, 0.05, 0.01), Vector3(0, 0.1, -0.5), _m_acento)
	_mano(n, Vector3(0, -0.075, -0.22), Vector3(0.07, 0.05, 0.09))
	_cohete = Node3D.new()
	_cilindro(_cohete, 0.05, 0.3, Vector3(0, 0.02, -0.72), _material(Color(0.7, 0.7, 0.65), 0.4, 0.5))
	_cilindro(_cohete, 0.0, 0.12, Vector3(0, 0.02, -0.9), _m_acento, true, 0.05)  # ojiva
	n.add_child(_cohete)
	_flashes[&"lanzacohetes"] = _fogonazo(n, Vector3(0, 0.02, -1.0), 0.4)
	_registrar(&"lanzacohetes", n)


func _construir_sable() -> void:
	var n := Node3D.new()
	_hoja_mat = _emisivo(Color(0.2, 0.85, 1.0), 2.4)
	var empunadura := _material(Color(0.2, 0.2, 0.23), 0.8, 0.3)
	_cilindro(n, 0.018, 0.2, Vector3(0, 0, 0.0), empunadura)
	_cilindro(n, 0.024, 0.02, Vector3(0, 0, -0.11), _m_acento)
	_cilindro(n, 0.022, 0.015, Vector3(0, 0, 0.1), _m_metal)
	var hoja := _cilindro(n, 0.01, 0.8, Vector3(0, 0, -0.52), _hoja_mat, true, 0.014)
	var halo_m := StandardMaterial3D.new()
	halo_m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	halo_m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	halo_m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	halo_m.albedo_color = Color(0.3, 0.8, 1.0, 0.18)
	_cilindro(n, 0.024, 0.8, Vector3(0, 0, -0.52), halo_m, true, 0.034)
	_luz_sable = OmniLight3D.new()
	_luz_sable.light_color = Color(0.2, 0.85, 1.0)
	_luz_sable.omni_range = 1.5
	_luz_sable.position = Vector3(0, 0.05, -0.4)
	n.add_child(_luz_sable)
	_mano(n, Vector3(0, -0.02, 0.0), Vector3(0.06, 0.06, 0.07))
	_chispa_sable = _fogonazo(n, Vector3(0, 0.0, -0.45), 0.35, Color(0.8, 0.95, 1.0, 1.0), Color(0.2, 0.7, 1.0, 0.0))
	n.rotation = Vector3(0.3, 0.0, 0.0)  # la hoja apunta arriba y hacia delante
	hoja.name = "Hoja"
	_registrar(&"sable_plasma", n)


func _construir_puno() -> void:
	var n := Node3D.new()
	_puno_mat = _emisivo(Color(0.2, 0.7, 1.0), 0.3)
	var metal_claro := _material(Color(0.62, 0.65, 0.72), 0.85, 0.3)
	_caja(n, Vector3(0.09, 0.09, 0.3), Vector3(0, 0, 0.06), metal_claro)  # antebrazo
	_cilindro(n, 0.012, 0.24, Vector3(0.05, 0.03, -0.02), _m_metal)  # piston
	_caja(n, Vector3(0.1, 0.1, 0.02), Vector3(0, 0, -0.1), _puno_mat)  # anillo
	_puno = Node3D.new()
	_caja(_puno, Vector3(0.14, 0.12, 0.14), Vector3(0, 0, 0), metal_claro)
	for i in 4:  # nudillos
		_caja(_puno, Vector3(0.028, 0.03, 0.03), Vector3(-0.05 + i * 0.033, 0.03, -0.075), _m_oscuro)
	_caja(_puno, Vector3(0.06, 0.02, 0.1), Vector3(0, 0.07, 0.0), _puno_mat)
	_puno.position = Vector3(0, 0, -0.17)
	n.add_child(_puno)
	_registrar(&"puno_bot", n)


func _construir_navaja() -> void:
	var navaja := Node3D.new()
	_caja(navaja, Vector3(0.03, 0.035, 0.13), Vector3(0, -0.02, 0.04), _m_cuerpo)
	_caja(navaja, Vector3(0.012, 0.05, 0.24), Vector3(0, 0.0, -0.16), _m_hoja)
	_caja(navaja, Vector3(0.02, 0.012, 0.04), Vector3(0, -0.004, -0.02), _m_acento)
	navaja.rotation = Vector3(0.15, 0.0, 0.35)
	_mano(navaja, Vector3(0, -0.02, 0.09))
	_registrar(&"navaja", navaja)


func _construir_utilidades() -> void:
	var gris := _material(Color(0.55, 0.58, 0.6), 0.5, 0.5)
	var rojo := _material(Color(0.6, 0.12, 0.08), 0.3, 0.5)
	var amarillo := _material(Color(0.9, 0.82, 0.35), 0.2, 0.5)
	var rosa := _material(Color(0.9, 0.2, 0.55), 0.2, 0.5)
	# granada: cuerpo esferico + palanca; cambia el color y el anillo segun el tipo
	for par: Array in [[&"granada_humo", gris], [&"granada_cegadora", amarillo], [&"granada_explosiva", rojo]]:
		var n := Node3D.new()
		_esfera(n, 0.05, Vector3.ZERO, par[1])
		_cilindro(n, 0.018, 0.04, Vector3(0, 0.055, 0), _m_metal, false)
		_caja(n, Vector3(0.012, 0.012, 0.07), Vector3(0.0, 0.07, 0.03), _m_metal, Vector3(0.5, 0, 0))
		_cilindro(n, 0.02, 0.012, Vector3(0.03, 0.06, 0.0), _m_acento, false)
		_mano(n, Vector3(0.0, -0.06, 0.03), Vector3(0.07, 0.05, 0.08))
		_registrar(par[0], n)
	var bote := Node3D.new()
	_cilindro(bote, 0.045, 0.16, Vector3.ZERO, rosa, false)
	_cilindro(bote, 0.03, 0.04, Vector3(0, 0.1, 0), _m_metal, false)
	_caja(bote, Vector3(0.02, 0.01, 0.04), Vector3(0, 0.125, 0.0), _m_oscuro)
	_mano(bote, Vector3(0.0, -0.09, 0.03), Vector3(0.07, 0.05, 0.08))
	_registrar(&"bote_pintura", bote)
	var ext := Node3D.new()
	_cilindro(ext, 0.06, 0.28, Vector3.ZERO, _material(Color(0.8, 0.08, 0.06), 0.4, 0.4), false)
	_cilindro(ext, 0.03, 0.05, Vector3(0, 0.165, 0), _m_metal, false)
	_caja(ext, Vector3(0.02, 0.012, 0.12), Vector3(0, 0.2, 0.0), _m_oscuro)
	_caja(ext, Vector3(0.012, 0.012, 0.14), Vector3(0.0, 0.17, -0.07), _m_oscuro, Vector3(0.7, 0, 0))
	_mano(ext, Vector3(0.0, -0.16, 0.03), Vector3(0.07, 0.05, 0.08))
	_registrar(&"extintor", ext)
	var alt := Node3D.new()
	_caja(alt, Vector3(0.12, 0.18, 0.1), Vector3.ZERO, _m_oscuro)
	_cilindro(alt, 0.04, 0.02, Vector3(0, 0.04, -0.055), gris, true)
	_cilindro(alt, 0.025, 0.02, Vector3(0, -0.04, -0.055), gris, true)
	_cilindro(alt, 0.004, 0.14, Vector3(0.04, 0.15, 0.0), _m_metal, false)
	_caja(alt, Vector3(0.03, 0.01, 0.01), Vector3(-0.03, 0.0, -0.055), _emisivo(Color(1.0, 0.6, 0.1), 1.0))
	_mano(alt, Vector3(0.0, -0.12, 0.03), Vector3(0.07, 0.05, 0.08))
	_registrar(&"altavoz", alt)


# ------------------------------------------------------- modelos externos (ModelosArmas)

## Cambia los modelos procedurales por los importados cuando el fichero existe (si falta, se queda el procedural: fallback).
func _sustituir_por_externos() -> void:
	for id: StringName in ModelosArmas.CONFIG.keys():
		var m: Node3D = ModelosArmas.crear(id)
		if m == null:
			continue
		var tam_flash: float = 0.2
		if _flashes.has(id):
			var q: QuadMesh = (_flashes[id] as MeshInstance3D).mesh as QuadMesh
			tam_flash = q.size.x if q != null else 0.2
		_retirar(id)
		if id == &"arco_olivo":
			_montar_arco(m)
			continue
		var boca: Vector3 = m.get_meta("boca")
		_flashes[id] = _fogonazo(m, boca + Vector3(0, 0, -0.03), tam_flash)
		var largo: float = float(m.get_meta("largo"))
		_mano(m, Vector3(0.0, -0.06, 0.02), Vector3(0.05, 0.07, 0.06))
		if largo > 0.4:
			_mano(m, Vector3(0.0, -0.045, boca.z * 0.5), Vector3(0.05, 0.045, 0.08))
		_atras[id] = float(m.get_meta("atras"))
		_bocas[id] = boca
		_externos[id] = true
		_registrar(id, m)
	var sable: Node3D = ModelosArmas.crear_sable()
	if sable != null:
		_retirar(&"sable_plasma")
		_montar_sable(sable)


## Quita el modelo procedural `id` (y sus piezas animadas registradas) para poner otro.
func _retirar(id: StringName) -> void:
	if _modelos.has(id):
		(_modelos[id] as Node3D).queue_free()
		_modelos.erase(id)
	_flashes.erase(id)
	if id == &"arco_olivo":
		_cuerda.clear()
		_flecha = null
	elif id == &"sable_plasma":
		_hoja_mat = null
		_hoja_nodo = null
		_luz_sable = null
		_chispa_sable = null


func _montar_arco(m: Node3D) -> void:
	# la cuerda del modelo (material "White") se oculta: la dibuja el codigo para poder tensarla
	for mi: Node in m.find_children("*", "MeshInstance3D", true, false):
		var mesh: MeshInstance3D = mi as MeshInstance3D
		for i: int in mesh.mesh.get_surface_count():
			var mat: Material = mesh.mesh.surface_get_material(i)
			if mat != null and mat.resource_name == "White":
				var inv := StandardMaterial3D.new()
				inv.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				inv.albedo_color = Color(1, 1, 1, 0.0)
				inv.cull_mode = BaseMaterial3D.CULL_DISABLED
				mesh.set_surface_override_material(i, inv)
	_arco_cy = float(m.get_meta("cuerda_y")) * 0.97
	_arco_cz = float(m.get_meta("cuerda_z"))
	_mano(m, Vector3(0.0, -0.01, -0.01), Vector3(0.06, 0.07, 0.07))
	var cuerda_m := _material(Color(0.9, 0.88, 0.8), 0.0, 0.9)
	for i in 2:
		_cuerda.append(_caja(m, Vector3(0.004, 0.004, 1.0), Vector3.ZERO, cuerda_m))
	var fl: Node3D = ModelosArmas.crear_flecha(0.62)
	if fl != null:
		m.add_child(fl)
		_flecha = fl
	else:
		_flecha = _caja(m, Vector3(0.008, 0.008, 0.56), Vector3(0, 0, -0.2), _material(Color(0.6, 0.45, 0.25), 0.0, 0.7))
	_atras[&"arco_olivo"] = float(m.get_meta("atras")) + 0.3
	_externos[&"arco_olivo"] = true
	_registrar(&"arco_olivo", m)


func _montar_sable(m: Node3D) -> void:
	_hoja_mat = m.get_meta("mat_hoja", null) as StandardMaterial3D
	_hoja_nodo = m.find_child("Blade", true, false) as Node3D
	_luz_sable = OmniLight3D.new()
	_luz_sable.light_color = Color(0.2, 0.85, 1.0)
	_luz_sable.omni_range = 1.5
	_luz_sable.position = Vector3(0, 0.05, -0.4)
	m.add_child(_luz_sable)
	_mano(m, Vector3(0, -0.04, 0.0), Vector3(0.06, 0.06, 0.07))
	_chispa_sable = _fogonazo(m, Vector3(0, 0.0, -0.45), 0.35, Color(0.8, 0.95, 1.0, 1.0), Color(0.2, 0.7, 1.0, 0.0))
	m.rotation = Vector3(0.3, 0.0, 0.0)
	_externos[&"sable_plasma"] = true
	_registrar(&"sable_plasma", m)
