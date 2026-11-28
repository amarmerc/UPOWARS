class_name ArmaSuelo
extends Node3D
## Arma (o utilidad) en el suelo, recogible con E. NO es un RigidBody: cae con una simulacion simple por tick (rayo
## continuo contra el mundo), se posa y se queda quieta. Conserva la municion con la que se solto. Al mirarla muestra una
## etiqueta y un brillo. Esta en el grupo "armas_suelo"; la Partida llama a `limpiar_armas_suelo()` al acabar la ronda.

const RUTA_ESCENA: String = "res://scenes/arma_suelo.tscn"
const GRAVEDAD: float = 18.0

var arma_id: StringName = &""
var cargador: int = 0
var reserva: int = 0
var vel: Vector3 = Vector3.ZERO
var quieta: bool = false

var _etiqueta: Label3D
var _mat: StandardMaterial3D
var _resaltada: bool = false
var _t: float = 0.0


## Crea un arma en el suelo en `pos` con velocidad inicial `v` (m/s). Cae sola hasta posarse.
static func crear(ctx: Node, id: StringName, carg: int, res: int, pos: Vector3, v: Vector3 = Vector3.ZERO) -> ArmaSuelo:
	var a: ArmaSuelo = (load(RUTA_ESCENA) as PackedScene).instantiate() as ArmaSuelo
	a.arma_id = id
	a.cargador = carg
	a.reserva = res
	a.vel = v
	Utilidades.mundo(ctx).add_child(a)
	a.global_position = pos
	return a


## Quita del mundo todas las armas del suelo (fin de ronda).
static func limpiar_armas_suelo(arbol: SceneTree) -> int:
	var n: int = 0
	for a: Node in arbol.get_nodes_in_group("armas_suelo"):
		a.remove_from_group("armas_suelo")
		a.queue_free()
		n += 1
	return n


func _ready() -> void:
	add_to_group("armas_suelo")
	var info: Dictionary = Catalogo.info(arma_id)
	var hueco: StringName = StringName(info.get("hueco", &"principal"))
	var largo: float = 0.85 if hueco == &"principal" else (0.36 if hueco == &"secundaria" else 0.16)
	_mat = StandardMaterial3D.new()
	_mat.emission_enabled = true
	_mat.emission = Color(0.2, 0.7, 1.0)
	_mat.emission_energy_multiplier = 0.0
	var modelo: Node3D = _modelo_externo()
	if modelo != null:
		# resalte: material superpuesto aditivo que solo emite (energia 0 = invisible)
		_mat.albedo_color = Color(0, 0, 0)
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		for m: Node in modelo.find_children("*", "MeshInstance3D", true, false):
			(m as MeshInstance3D).material_overlay = _mat
		add_child(modelo)
	else:
		_mat.albedo_color = Color(0.22, 0.24, 0.26)
		_mat.metallic = 0.5
		_mat.roughness = 0.5
		var cuerpo := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.07, 0.09, largo)
		cuerpo.mesh = bm
		cuerpo.material_override = _mat
		cuerpo.position = Vector3(0, 0.05, 0)
		add_child(cuerpo)
		if hueco != &"utilidades":
			var asa := MeshInstance3D.new()
			var bm2 := BoxMesh.new()
			bm2.size = Vector3(0.05, 0.12, 0.06)
			asa.mesh = bm2
			asa.material_override = _mat
			asa.position = Vector3(0, -0.01, largo * 0.2)
			add_child(asa)
	_etiqueta = Label3D.new()
	_etiqueta.text = "%s\n[E] recoger" % str(info.get("nombre", arma_id))
	_etiqueta.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_etiqueta.no_depth_test = true
	_etiqueta.fixed_size = true
	_etiqueta.pixel_size = 0.0011
	_etiqueta.font_size = 48
	_etiqueta.outline_size = 12
	_etiqueta.modulate = Color(0.75, 0.95, 1.0)
	_etiqueta.position = Vector3(0, 0.45, 0)
	_etiqueta.visible = false
	add_child(_etiqueta)
	rotation.y = float(hash(arma_id) % 628) / 100.0


## Modelo importado del arma, tumbado de lado sobre el suelo (null si no hay: se usa la caja de siempre).
func _modelo_externo() -> Node3D:
	var m: Node3D
	if arma_id == &"sable_plasma":
		m = ModelosArmas.crear_sable()
		if m != null:
			var hoja: Node3D = m.find_child("Blade", true, false) as Node3D
			if hoja != null:
				hoja.scale = Vector3(0.001, 1.0, 1.0)   # apagado en el suelo
	else:
		m = ModelosArmas.crear(arma_id)
	if m == null:
		return null
	var cont := Node3D.new()
	cont.name = "Modelo"
	m.rotation = Vector3(PI * 0.5 if arma_id == &"arco_olivo" else 0.0, 0.0, 0.0 if arma_id == &"arco_olivo" else PI * 0.5)
	m.position = Vector3(0, 0.05, 0)
	cont.add_child(m)
	return cont


func _physics_process(delta: float) -> void:
	avanzar(delta)


## Un tick de la caida: gravedad, rayo continuo contra el mundo y rozamiento al posarse.
func avanzar(dt: float) -> void:
	_t += dt
	if _resaltada and _mat != null:
		_mat.emission_energy_multiplier = 0.9 + 0.5 * sin(_t * 6.0)
	if quieta:
		return
	vel.y -= GRAVEDAD * dt
	var fin: Vector3 = global_position + vel * dt
	var q := PhysicsRayQueryParameters3D.create(global_position + Vector3(0, 0.1, 0), fin - Vector3(0, 0.04, 0),
			Balistica.CAPA_MUNDO)
	var r: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	if r.is_empty():
		global_position = fin
		return
	var n: Vector3 = r["normal"]
	if n.y > 0.5:
		global_position = (r["position"] as Vector3) + Vector3(0, 0.04, 0)
		vel = Vector3.ZERO
		quieta = true
	else:  # pared: rebota sin energia hacia fuera y sigue cayendo
		global_position = (r["position"] as Vector3) + n * 0.1
		vel = Vector3(n.x, 0.0, n.z) * 1.0


func resaltar(valor: bool) -> void:
	if valor == _resaltada:
		return
	_resaltada = valor
	if _etiqueta != null:
		_etiqueta.visible = valor
	if _mat != null and not valor:
		_mat.emission_energy_multiplier = 0.0


func nombre_arma() -> String:
	return str(Catalogo.info(arma_id).get("nombre", arma_id))
