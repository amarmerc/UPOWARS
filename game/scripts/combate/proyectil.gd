class_name Proyectil
extends Node3D
## Proyectil con gravedad (flecha, piedra del tirachinas, cohete, puno del Puño-Bot). NO es un RigidBody: cada tick
## (`avanzar(dt)`) integra la velocidad y traza un rayo continuo con `Balistica.paso_proyectil`, asi que es determinista y
## no atraviesa paredes por muy rapido que vaya. Todo el dano pasa por `Balistica` (aplicar / aplicar_explosion).
## Estados: VOLANDO, CLAVADO (flecha en una pared), VOLVIENDO (puno de vuelta a la mano) y FIN.

signal impactado(res: Dictionary)
signal terminado

enum Estado { VOLANDO, CLAVADO, VOLVIENDO, FIN }

const VIDA_CLAVADO: float = 6.0

var arma: ArmaDatos
var lanzador: Node = null
var vel: Vector3 = Vector3.ZERO
var estado: Estado = Estado.VOLANDO
var recorrido: float = 0.0
## Fraccion de carga (arco, puno): multiplica dano y empuje.
var mult: float = 1.0
var t: float = 0.0
var ultimo_impacto: Dictionary = {}

var _excluidos: Array[RID] = []
var _t_clavado: float = 0.0


## Crea el proyectil en el mundo. `auto` = avanza solo en _physics_process (los tests lo ponen a false).
static func lanzar(ctx: Node, a: ArmaDatos, pos: Vector3, velocidad: Vector3, quien: Node, multiplicador: float = 1.0,
		auto: bool = true) -> Proyectil:
	var p := Proyectil.new()
	p.arma = a
	p.vel = velocidad
	p.lanzador = quien
	p.mult = multiplicador
	if quien is Node3D and (quien as Node3D).is_inside_tree():
		p._excluidos = Balistica.excluidos(quien as Node3D)
	Utilidades.mundo(ctx).add_child(p)
	p.global_position = pos
	p.set_physics_process(auto)
	p._orientar()
	return p


func _ready() -> void:
	add_to_group("proyectiles")
	_construir_visual()


func _physics_process(delta: float) -> void:
	avanzar(delta)


func _lanzador_valido() -> Node:
	return lanzador if lanzador != null and is_instance_valid(lanzador) else null


func avanzar(dt: float) -> void:
	if estado == Estado.FIN:
		return
	t += dt
	if estado == Estado.CLAVADO:
		_t_clavado += dt
		if _t_clavado >= VIDA_CLAVADO:
			_acabar()
		return
	if estado == Estado.VOLVIENDO:
		_volver(dt)
		return
	var r: Dictionary = Balistica.paso_proyectil(global_position, vel, dt, arma.gravedad_proyectil, arma, self,
			_excluidos, recorrido, mult)
	recorrido += (r["pos"] as Vector3).distance_to(global_position)
	vel = r["vel"]
	global_position = r["pos"]
	_orientar()
	if bool(r["choque"]):
		_impacto(r["res"] as Dictionary)
	elif recorrido >= arma.alcance:
		if arma.tipo == ArmaDatos.T_PUNO:
			estado = Estado.VOLVIENDO
		else:
			_acabar()


func _impacto(res: Dictionary) -> void:
	ultimo_impacto = res
	impactado.emit(res)
	match arma.tipo:
		ArmaDatos.T_COHETE:
			var n: Vector3 = res["normal"]
			Utilidades.explosion(self, (res["punto"] as Vector3) + n * 0.15, arma, _lanzador_valido())
			_acabar()
		ArmaDatos.T_PUNO:
			Balistica.aplicar(res, arma, _lanzador_valido())
			var s: Salud = res["salud"] as Salud
			if s != null and not bool(res.get("bloqueado", false)):
				Balistica.empujar(s, vel.normalized() * arma.empuje * mult + Vector3.UP * 1.5 * mult)
			estado = Estado.VOLVIENDO
		_:
			Balistica.aplicar(res, arma, _lanzador_valido())
			if res["salud"] != null:
				_acabar()
			else:
				estado = Estado.CLAVADO  # flecha o piedra clavada en la pared


func _volver(dt: float) -> void:
	var l: Node3D = _lanzador_valido() as Node3D
	if l == null:
		_acabar()
		return
	var destino: Vector3 = l.global_position + Vector3(0.0, 1.3, 0.0)
	global_position = global_position.move_toward(destino, 38.0 * dt)
	if global_position.distance_to(destino) < 0.4:
		_acabar()


func _acabar() -> void:
	if estado == Estado.FIN:
		return
	estado = Estado.FIN
	terminado.emit()
	queue_free()


func _orientar() -> void:
	if vel.length() > 0.1 and estado == Estado.VOLANDO:
		var arriba: Vector3 = Vector3.UP if absf(vel.normalized().y) < 0.98 else Vector3.RIGHT
		look_at(global_position + vel, arriba)


func _construir_visual() -> void:
	var m := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	match arma.tipo:
		ArmaDatos.T_COHETE:
			var cm := CylinderMesh.new()
			cm.top_radius = 0.06
			cm.bottom_radius = 0.06
			cm.height = 0.55
			m.mesh = cm
			m.rotation = Vector3(PI * 0.5, 0.0, 0.0)
			mat.albedo_color = Color(0.5, 0.52, 0.5)
			var luz := OmniLight3D.new()
			luz.light_color = Color(1.0, 0.6, 0.2)
			luz.omni_range = 5.0
			luz.light_energy = 2.0
			luz.position = Vector3(0, 0, 0.4)
			add_child(luz)
		ArmaDatos.T_PUNO:
			var bm := BoxMesh.new()
			bm.size = Vector3(0.2, 0.18, 0.22)
			m.mesh = bm
			mat.albedo_color = Color(0.7, 0.72, 0.78)
			mat.metallic = 0.8
			mat.roughness = 0.35
		_:
			if arma.velocidad_proyectil > 50.0:  # flecha
				var cm2 := CylinderMesh.new()
				cm2.top_radius = 0.012
				cm2.bottom_radius = 0.012
				cm2.height = 0.7
				m.mesh = cm2
				m.rotation = Vector3(PI * 0.5, 0.0, 0.0)
				mat.albedo_color = Color(0.55, 0.38, 0.2)
			else:  # piedra
				var sm := SphereMesh.new()
				sm.radius = 0.04
				sm.height = 0.08
				m.mesh = sm
				mat.albedo_color = Color(0.4, 0.4, 0.38)
	m.material_override = mat
	add_child(m)
