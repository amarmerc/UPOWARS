class_name Diana
extends Node3D
## Diana humanoide blockout con Salud y Hitboxes. Al morir cae, tras `tiempo_reaparicion` s se levanta con la
## vida completa. Muestra numeros de dano flotantes. Mira hacia -Z (usar `look_at` para encararla al tirador).

signal reaparecida

@export_range(0.0, 100.0) var armadura: float = 0.0
@export var tiempo_reaparicion: float = 3.0
@export var duracion_caida: float = 0.35

var salud: Salud
var hitboxes: Hitboxes
var caida: Node3D  ## pivote en los pies que gira al caer
var muerta: bool = false

var _t_muerta: float = 0.0
var _numeros: Array[Label3D] = []
var _vida_numeros: Array[float] = []


func _ready() -> void:
	salud = Salud.new()
	salud.name = "Salud"
	salud.armadura_inicial = armadura
	add_child(salud)
	caida = Node3D.new()
	caida.name = "Cuerpo"
	add_child(caida)
	hitboxes = Hitboxes.new()
	hitboxes.name = "Hitboxes"
	hitboxes.salud = salud
	caida.add_child(hitboxes)
	_construir_visual()
	salud.herido.connect(_on_herido)
	salud.muerto.connect(_on_muerto)


func centro(zona: String) -> Vector3:
	return hitboxes.centro_zona(zona)


func _physics_process(delta: float) -> void:
	avanzar(delta)


## Avanza `delta` s: caida, reaparicion y numeros flotantes (separado para poder simular el tiempo).
func avanzar(delta: float) -> void:
	if muerta:
		_t_muerta += delta
		var k: float = clampf(_t_muerta / duracion_caida, 0.0, 1.0)
		caida.rotation.x = deg_to_rad(90.0) * (1.0 - pow(1.0 - k, 2.0))
		if _t_muerta >= tiempo_reaparicion:
			_reaparecer()
	for i in range(_numeros.size() - 1, -1, -1):
		_vida_numeros[i] -= delta
		var l: Label3D = _numeros[i]
		l.position.y += delta * 1.0
		l.modulate.a = clampf(_vida_numeros[i] / 0.4, 0.0, 1.0)
		if _vida_numeros[i] <= 0.0:
			l.queue_free()
			_numeros.remove_at(i)
			_vida_numeros.remove_at(i)


func _on_herido(cantidad: float, zona: String, _atacante: Node) -> void:
	var l := Label3D.new()
	l.text = str(roundi(cantidad))
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = false
	l.pixel_size = 0.006 if zona != "cabeza" else 0.008
	l.font_size = 64
	l.outline_size = 16
	l.modulate = Color(1.0, 0.9, 0.3) if zona != "cabeza" else Color(1.0, 0.25, 0.2)
	l.position = Vector3(randf_range(-0.2, 0.2), 2.1, 0.0)
	add_child(l)
	_numeros.append(l)
	_vida_numeros.append(0.9)


func _on_muerto(_atacante: Node) -> void:
	muerta = true
	_t_muerta = 0.0
	hitboxes.activar(false)


func _reaparecer() -> void:
	muerta = false
	caida.rotation.x = 0.0
	salud.reiniciar()
	hitboxes.activar(true)
	reaparecida.emit()


func _construir_visual() -> void:
	var gris := _mat(Color(0.35, 0.38, 0.45))
	var cuerpo := _mat(Color(0.2, 0.42, 0.7) if armadura <= 0.0 else Color(0.22, 0.25, 0.3))
	var cabeza := _mat(Color(0.85, 0.35, 0.25))
	var piernas := MeshInstance3D.new()
	var bp := BoxMesh.new()
	bp.size = Vector3(0.42, 0.84, 0.24)
	piernas.mesh = bp
	piernas.material_override = gris
	piernas.position = Vector3(0, 0.42, 0)
	caida.add_child(piernas)
	var torso := MeshInstance3D.new()
	var bt := BoxMesh.new()
	bt.size = Vector3(0.54, 0.62, 0.28)
	torso.mesh = bt
	torso.material_override = cuerpo
	torso.position = Vector3(0, 1.15, 0)
	caida.add_child(torso)
	if armadura > 0.0:  # chaleco
		var chaleco := MeshInstance3D.new()
		var bc := BoxMesh.new()
		bc.size = Vector3(0.58, 0.4, 0.32)
		chaleco.mesh = bc
		chaleco.material_override = _mat(Color(0.95, 0.75, 0.15))
		chaleco.position = Vector3(0, 1.2, 0)
		caida.add_child(chaleco)
	var cab := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.13
	sm.height = 0.26
	cab.mesh = sm
	cab.material_override = cabeza
	cab.position = Vector3(0, 1.62, 0)
	caida.add_child(cab)


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	return m
