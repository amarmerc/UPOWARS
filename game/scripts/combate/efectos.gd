class_name EfectosCombate
extends Node3D
## Efectos del combate en el mundo (blockout): trazador fino, fogonazo de luz, marcas de impacto (pool de 64),
## chispas/polvo y sonidos de impacto. Escucha `GestorArmas.disparo_realizado`; cualquier otro tirador puede
## llamar a `mostrar_disparo()` igual. Este nodo debe estar en el origen sin transformar.

const MAX_MARCAS: int = 64
const MAX_TRAZADORES: int = 12
const MAX_PARTICULAS: int = 10
const MAX_SONIDOS: int = 8
const VIDA_TRAZADOR: float = 0.07
const VIDA_LUZ: float = 0.05

var _marcas: Array[MeshInstance3D] = []
var _siguiente_marca: int = 0
var _trazadores: Array[MeshInstance3D] = []
var _vida_trazadores: Array[float] = []
var _siguiente_trazador: int = 0
var _particulas: Array[CPUParticles3D] = []
var _siguiente_particula: int = 0
var _sonidos3d: Array[AudioStreamPlayer3D] = []
var _siguiente_sonido: int = 0
var _luz: OmniLight3D
var _vida_luz: float = 0.0
var _mat_marca: StandardMaterial3D
var _mat_trazador: StandardMaterial3D
var _snd_superficie: AudioStream
var _snd_carne: AudioStream
var _cache_sonidos: Dictionary = {}


func _ready() -> void:
	add_to_group("efectos")
	_mat_marca = StandardMaterial3D.new()
	_mat_marca.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_marca.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_marca.albedo_texture = _textura_marca()
	_mat_marca.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_marca.render_priority = 1
	_mat_trazador = StandardMaterial3D.new()
	_mat_trazador.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_trazador.albedo_color = Color(1.0, 0.85, 0.45)
	_mat_trazador.cull_mode = BaseMaterial3D.CULL_DISABLED
	_luz = OmniLight3D.new()
	_luz.light_color = Color(1.0, 0.75, 0.4)
	_luz.light_energy = 3.0
	_luz.omni_range = 9.0
	_luz.shadow_enabled = false
	_luz.visible = false
	add_child(_luz)
	for i in MAX_TRAZADORES:
		var m := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.012, 0.012, 1.0)
		m.mesh = bm
		m.material_override = _mat_trazador
		m.visible = false
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(m)
		_trazadores.append(m)
		_vida_trazadores.append(0.0)
	for i in MAX_PARTICULAS:
		var p := CPUParticles3D.new()
		p.emitting = false
		p.one_shot = true
		p.explosiveness = 1.0
		p.amount = 10
		p.lifetime = 0.45
		p.direction = Vector3.UP
		p.spread = 55.0
		p.initial_velocity_min = 1.5
		p.initial_velocity_max = 4.0
		p.gravity = Vector3(0, -9.8, 0)
		p.scale_amount_min = 0.6
		p.scale_amount_max = 1.2
		var pm := BoxMesh.new()
		pm.size = Vector3(0.03, 0.03, 0.03)
		var pmat := StandardMaterial3D.new()
		pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		pmat.vertex_color_use_as_albedo = true
		pm.material = pmat
		p.mesh = pm
		add_child(p)
		_particulas.append(p)
	for i in MAX_SONIDOS:
		var s := AudioStreamPlayer3D.new()
		s.max_distance = 80.0
		s.unit_size = 8.0
		add_child(s)
		_sonidos3d.append(s)
	if ResourceLoader.exists("res://assets/sonidos/impacto_superficie.wav"):
		_snd_superficie = load("res://assets/sonidos/impacto_superficie.wav")
	if ResourceLoader.exists("res://assets/sonidos/impacto_carne.wav"):
		_snd_carne = load("res://assets/sonidos/impacto_carne.wav")


func vincular(gestor: GestorArmas) -> void:
	gestor.disparo_realizado.connect(mostrar_disparo)


## Dibuja el resultado de un disparo: `origen_visual` es el punto de la boca del arma. Hitscan y perdigones dibujan trazador;
## los proyectiles (flecha, cohete...) se dibujan solos como nodos `Proyectil`.
func mostrar_disparo(arma: ArmaDatos, res: Dictionary, origen_visual: Vector3) -> void:
	var dir: Vector3 = res["direccion"]
	var trazadores: bool = arma.tipo == ArmaDatos.T_HITSCAN or arma.tipo == ArmaDatos.T_PERDIGONES
	if trazadores:
		_luz.global_position = origen_visual + dir * 0.3
		_luz.visible = true
		_vida_luz = VIDA_LUZ
	var lista: Array = res.get("impactos", [res])
	if arma.tipo == ArmaDatos.T_SABLE or arma.tipo == ArmaDatos.T_CUERPO:
		lista = [res]
	if arma.tipo == ArmaDatos.T_PROYECTIL or arma.tipo == ArmaDatos.T_COHETE or arma.tipo == ArmaDatos.T_PUNO:
		return
	for r: Dictionary in lista:
		if trazadores:
			_trazador(origen_visual, r["punto"])
		_impacto(r)


func _impacto(res: Dictionary) -> void:
	if not bool(res["impacto"]):
		return
	var punto: Vector3 = res["punto"]
	var normal: Vector3 = res["normal"]
	var carne: bool = str(res["zona"]) != ""
	if not carne:
		_marca(punto, normal)
	_chispas(punto, normal, carne)
	_sonido(punto, _snd_carne if carne else _snd_superficie)


## Sonido 3D de `res://assets/sonidos/<clave>.wav` en un punto (cacheado).
func sonido_en(punto: Vector3, clave: StringName) -> void:
	if not _cache_sonidos.has(clave):
		var ruta: String = "res://assets/sonidos/%s.wav" % String(clave)
		_cache_sonidos[clave] = load(ruta) if ResourceLoader.exists(ruta) else null
	_sonido(punto, _cache_sonidos[clave])


## Bola de fuego, humo oscuro, chispas y luz de una explosion de radio `radio` (m).
func explosion(punto: Vector3, radio: float) -> void:
	sonido_en(punto, &"explosion")
	var bola := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	bola.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(1.0, 0.62, 0.2, 0.9)
	bola.material_override = mat
	bola.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(bola)
	bola.global_position = punto
	bola.scale = Vector3.ONE * radio * 0.25
	var tw: Tween = create_tween().set_parallel(true)
	tw.tween_property(bola, "scale", Vector3.ONE * radio * 0.75, 0.3).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.45)
	tw.chain().tween_callback(bola.queue_free)
	var luz := OmniLight3D.new()
	luz.light_color = Color(1.0, 0.65, 0.3)
	luz.light_energy = 8.0
	luz.omni_range = radio * 3.0
	add_child(luz)
	luz.global_position = punto + Vector3(0, 0.5, 0)
	var tl: Tween = create_tween()
	tl.tween_property(luz, "light_energy", 0.0, 0.4)
	tl.tween_callback(luz.queue_free)
	_particulas_explosion(punto, radio, Color(0.25, 0.22, 0.2), 28, 1.6, 0.3)
	_particulas_explosion(punto, radio, Color(1.0, 0.7, 0.25), 24, 0.6, 1.0)


func _particulas_explosion(punto: Vector3, radio: float, color: Color, cantidad: int, vida: float, brillo: float) -> void:
	var p := CPUParticles3D.new()
	p.amount = cantidad
	p.lifetime = vida
	p.one_shot = true
	p.explosiveness = 1.0
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = radio * 0.6
	p.initial_velocity_max = radio * 1.6
	p.gravity = Vector3(0, -2.0, 0)
	p.damping_min = 2.0
	p.damping_max = 4.0
	var bm := SphereMesh.new()
	bm.radius = 0.28
	bm.height = 0.56
	var pm := StandardMaterial3D.new()
	pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pm.albedo_color = color * (1.0 + brillo)
	bm.material = pm
	p.mesh = bm
	p.emitting = true
	add_child(p)
	p.global_position = punto
	get_tree().create_timer(vida + 0.5).timeout.connect(p.queue_free)


## Destello blanco de la granada cegadora.
func destello(punto: Vector3) -> void:
	var luz := OmniLight3D.new()
	luz.light_color = Color(1.0, 1.0, 0.95)
	luz.light_energy = 14.0
	luz.omni_range = 18.0
	add_child(luz)
	luz.global_position = punto
	var tl: Tween = create_tween()
	tl.tween_property(luz, "light_energy", 0.0, 0.5)
	tl.tween_callback(luz.queue_free)


## Salpicadura de pintura rosa del bote (esfera que se desvanece).
func salpicadura(punto: Vector3, radio: float) -> void:
	var m := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radio * 0.5
	sm.height = radio
	m.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.95, 0.15, 0.55, 0.45)
	m.material_override = mat
	add_child(m)
	m.global_position = punto
	var tw: Tween = create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, 1.2)
	tw.tween_callback(m.queue_free)


func _process(delta: float) -> void:
	if _vida_luz > 0.0:
		_vida_luz -= delta
		if _vida_luz <= 0.0:
			_luz.visible = false
	for i in _trazadores.size():
		if _vida_trazadores[i] > 0.0:
			_vida_trazadores[i] -= delta
			if _vida_trazadores[i] <= 0.0:
				_trazadores[i].visible = false


func _trazador(desde: Vector3, hasta: Vector3) -> void:
	var largo: float = desde.distance_to(hasta)
	if largo < 0.8:
		return
	var m: MeshInstance3D = _trazadores[_siguiente_trazador]
	_vida_trazadores[_siguiente_trazador] = VIDA_TRAZADOR
	_siguiente_trazador = (_siguiente_trazador + 1) % MAX_TRAZADORES
	var dir: Vector3 = (hasta - desde) / largo
	var up: Vector3 = Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT
	m.global_transform = Transform3D(Basis.looking_at(dir, up) * Basis.from_scale(Vector3(1, 1, largo)), (desde + hasta) * 0.5)
	m.visible = true


func _marca(punto: Vector3, normal: Vector3) -> void:
	var m: MeshInstance3D
	if _marcas.size() < MAX_MARCAS:
		m = MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(0.14, 0.14)
		m.mesh = q
		m.material_override = _mat_marca
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(m)
		_marcas.append(m)
	else:
		m = _marcas[_siguiente_marca]
	_siguiente_marca = (_siguiente_marca + 1) % MAX_MARCAS
	var up: Vector3 = Vector3.UP if absf(normal.y) < 0.99 else Vector3.RIGHT
	# QuadMesh mira a +Z: -Z debe apuntar contra la normal
	m.global_transform = Transform3D(Basis.looking_at(-normal, up), punto + normal * 0.012)
	m.rotate_object_local(Vector3.BACK, randf() * TAU)
	m.visible = true


func _chispas(punto: Vector3, normal: Vector3, carne: bool) -> void:
	var p: CPUParticles3D = _particulas[_siguiente_particula]
	_siguiente_particula = (_siguiente_particula + 1) % MAX_PARTICULAS
	p.global_position = punto + normal * 0.02
	p.direction = normal
	p.color = Color(0.75, 0.12, 0.1) if carne else Color(0.85, 0.78, 0.6)
	p.restart()
	p.emitting = true


func _sonido(punto: Vector3, stream: AudioStream) -> void:
	if stream == null:
		return
	var s: AudioStreamPlayer3D = _sonidos3d[_siguiente_sonido]
	_siguiente_sonido = (_siguiente_sonido + 1) % MAX_SONIDOS
	s.global_position = punto
	s.stream = stream
	s.play()


## Numero de marcas de impacto creadas (nunca supera MAX_MARCAS).
func n_marcas() -> int:
	return _marcas.size()


func _textura_marca() -> ImageTexture:
	var n: int = 32
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var d: float = Vector2(x + 0.5 - n * 0.5, y + 0.5 - n * 0.5).length() / (n * 0.5)
			var a: float = clampf(1.0 - d, 0.0, 1.0)
			a = clampf(a * 2.2, 0.0, 1.0) * 0.85
			img.set_pixel(x, y, Color(0.05, 0.05, 0.05, a))
	return ImageTexture.create_from_image(img)
