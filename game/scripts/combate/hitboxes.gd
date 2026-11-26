class_name Hitboxes
extends Node3D
## Conjunto reutilizable de hitboxes humanoides (cabeza, torso, piernas) para jugador, dianas y bots.
## El origen del nodo esta en los pies. Crea una `ZonaImpacto` por zona y la enlaza con la `Salud` del dueno.

@export var salud: Salud
@export var altura: float = 1.8
@export var ancho: float = 0.56
@export var fondo: float = 0.30

var zonas: Dictionary = {}  # nombre -> ZonaImpacto
var _formas: Dictionary = {}  # nombre -> CollisionShape3D


func _ready() -> void:
	if salud == null and get_parent() != null:
		var ss: Array[Node] = get_parent().find_children("*", "Salud", false, false)
		if not ss.is_empty():
			salud = ss[0] as Salud
	_crear("cabeza", SphereShape3D.new())
	_crear("torso", BoxShape3D.new())
	_crear("piernas", BoxShape3D.new())
	ajustar_altura(altura)


func _crear(nombre: String, forma: Shape3D) -> void:
	var z := ZonaImpacto.new()
	z.name = nombre.capitalize()
	z.zona = nombre
	z.salud = salud
	z.collision_layer = 1 << (ZonaImpacto.CAPA_HITBOX - 1)
	z.collision_mask = 0
	z.monitoring = false
	var cs := CollisionShape3D.new()
	cs.shape = forma
	z.add_child(cs)
	add_child(z)
	zonas[nombre] = z
	_formas[nombre] = cs


## Reproporciona las zonas a una altura de cuerpo (p. ej. agachado = 1,2 m).
func ajustar_altura(h: float) -> void:
	altura = h
	var k: float = h / 1.8
	((_formas["cabeza"] as CollisionShape3D).shape as SphereShape3D).radius = 0.13
	(_formas["cabeza"] as CollisionShape3D).position = Vector3(0.0, h - 0.18, 0.0)
	var torso := (_formas["torso"] as CollisionShape3D)
	(torso.shape as BoxShape3D).size = Vector3(ancho, 0.62 * k, fondo)
	torso.position = Vector3(0.0, 1.15 * k, 0.0)
	var piernas := (_formas["piernas"] as CollisionShape3D)
	(piernas.shape as BoxShape3D).size = Vector3(ancho - 0.1, 0.84 * k, fondo - 0.04)
	piernas.position = Vector3(0.0, 0.42 * k, 0.0)


## Activa o desactiva todas las zonas (un muerto no debe parar balas).
func activar(valor: bool) -> void:
	for z: ZonaImpacto in zonas.values():
		z.collision_layer = (1 << (ZonaImpacto.CAPA_HITBOX - 1)) if valor else 0


func rids() -> Array[RID]:
	var r: Array[RID] = []
	for z: ZonaImpacto in zonas.values():
		r.append(z.get_rid())
	return r


## Centro de una zona en coordenadas globales (util para apuntar en tests y bots).
func centro_zona(nombre: String) -> Vector3:
	return (_formas[nombre] as CollisionShape3D).global_position
