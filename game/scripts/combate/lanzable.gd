class_name Lanzable
extends Node3D
## Utilidad lanzada (granada, bote, extintor, altavoz): vuela con gravedad, rebota con rebotes simples contra el mundo
## (rayo continuo por tick, sin RigidBody) y detona al acabar la mecha o, para bote/extintor/altavoz, al primer impacto.
## `avanzar(dt)` es determinista y lo llama `_physics_process` (los tests lo llaman a mano).

const GRAVEDAD: float = 14.0
const RESTITUCION: float = 0.45
const ROZAMIENTO: float = 0.72
const AL_IMPACTO: Array[StringName] = [&"bote_pintura", &"extintor", &"altavoz"]

var arma: ArmaDatos
var lanzador: Node = null
var vel: Vector3 = Vector3.ZERO
var t: float = 0.0
var rebotes: int = 0
var activada: bool = false
var en_reposo: bool = false
## Red (cliente): copia solo visual de una granada del servidor.
var solo_visual: bool = false


static func crear(ctx: Node, a: ArmaDatos, pos: Vector3, velocidad: Vector3, quien: Node) -> Lanzable:
	var l := Lanzable.new()
	l.arma = a
	l.vel = velocidad
	l.lanzador = quien
	Utilidades.mundo(ctx).add_child(l)
	l.global_position = pos
	return l


func _ready() -> void:
	add_to_group("lanzables")
	var m := MeshInstance3D.new()
	var col: Color = Color(0.25, 0.3, 0.2)
	match arma.tipo:
		&"granada_humo":
			col = Color(0.65, 0.68, 0.7)
		&"granada_cegadora":
			col = Color(0.95, 0.9, 0.5)
		&"granada_explosiva":
			col = Color(0.55, 0.15, 0.1)
		&"bote_pintura":
			col = Color(0.9, 0.2, 0.55)
		&"extintor":
			col = Color(0.85, 0.1, 0.1)
		&"altavoz":
			col = Color(0.15, 0.16, 0.2)
	if arma.tipo == &"extintor" or arma.tipo == &"bote_pintura":
		var cm := CylinderMesh.new()
		cm.top_radius = 0.05
		cm.bottom_radius = 0.05
		cm.height = 0.24
		m.mesh = cm
	else:
		var sm := SphereMesh.new()
		sm.radius = 0.07
		sm.height = 0.14
		m.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.6
	m.material_override = mat
	add_child(m)


func _physics_process(delta: float) -> void:
	avanzar(delta)


func avanzar(dt: float) -> void:
	if activada:
		return
	t += dt
	var choco: bool = false
	if not en_reposo:
		vel.y -= GRAVEDAD * dt
		var fin: Vector3 = global_position + vel * dt
		var q := PhysicsRayQueryParameters3D.create(global_position, fin, Balistica.CAPA_MUNDO)
		var r: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
		if r.is_empty():
			global_position = fin
		else:
			choco = true
			rebotes += 1
			var n: Vector3 = r["normal"]
			global_position = (r["position"] as Vector3) + n * 0.06
			var normal_v: Vector3 = n * vel.dot(n)
			var tang: Vector3 = (vel - normal_v) * ROZAMIENTO
			vel = tang - normal_v * RESTITUCION
			if vel.length() < 1.3 and n.y > 0.55:
				en_reposo = true
				vel = Vector3.ZERO
	if (choco and AL_IMPACTO.has(arma.tipo)) or t >= arma.mecha:
		activar()


func activar() -> void:
	if activada:
		return
	activada = true
	if solo_visual:
		Utilidades.activar_visual(self, arma, global_position)
	else:
		Utilidades.activar(self, arma, global_position, lanzador)
	queue_free()
