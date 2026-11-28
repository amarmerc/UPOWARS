class_name NubeVision
extends Node3D
## Nube que tapa la vision: humo (5 m, 15 s) y extintor (3,5 m, 3 s, empuja a quien esta dentro). Aparece en el grupo
## "nubes"; `Utilidades.linea_de_vision()` la tiene en cuenta. La logica avanza con `avanzar(dt)`.

var radio: float = 5.0
var duracion: float = 15.0
## Aceleracion (m/s por segundo) con la que empuja hacia fuera a quien esta dentro (0 = no empuja).
var empuje: float = 0.0
var color: Color = Color(0.82, 0.84, 0.86)
var t: float = 0.0

var _mat: StandardMaterial3D
var _bolas: Array[MeshInstance3D] = []


static func crear(ctx: Node, pos: Vector3, radio_m: float, dur: float, empuje_m: float = 0.0,
		col: Color = Color(0.82, 0.84, 0.86)) -> NubeVision:
	var n := NubeVision.new()
	n.radio = radio_m
	n.duracion = dur
	n.empuje = empuje_m
	n.color = col
	Utilidades.mundo(ctx).add_child(n)
	n.global_position = pos
	return n


func _ready() -> void:
	add_to_group("nubes")
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.albedo_color = Color(color.r, color.g, color.b, 0.0)
	var r := RandomNumberGenerator.new()
	r.seed = hash(Vector2(global_position.x, global_position.z))
	for i in 12:
		var m := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radial_segments = 14
		sm.rings = 8
		sm.radius = radio * r.randf_range(0.42, 0.6)
		sm.height = sm.radius * 2.0
		m.mesh = sm
		m.material_override = _mat
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var d: Vector3 = Vector3(r.randf_range(-1, 1), r.randf_range(-0.3, 0.8), r.randf_range(-1, 1)).normalized()
		m.position = d * radio * r.randf_range(0.0, 0.5) + Vector3(0, radio * 0.25, 0)
		add_child(m)
		_bolas.append(m)
	_actualizar_visual()


func _physics_process(delta: float) -> void:
	avanzar(delta)


func vigente() -> bool:
	return t < duracion


func avanzar(delta: float) -> void:
	t += delta
	if t >= duracion:
		remove_from_group("nubes")
		queue_free()
		return
	if empuje > 0.0:
		for s: Node in get_tree().get_nodes_in_group("salud"):
			var duenio: Node = s.get_parent()
			if duenio is Node3D and duenio.has_method("aplicar_impulso") and (s as Salud).vivo:
				var p: Vector3 = (duenio as Node3D).global_position + Vector3(0.0, 1.0, 0.0)
				var d: Vector3 = p - global_position
				if d.length() <= radio:
					d.y = 0.0
					var dir: Vector3 = d.normalized() if d.length() > 0.05 else Vector3.RIGHT
					duenio.call("aplicar_impulso", dir * empuje * 6.0 * delta)
	_actualizar_visual()


func _actualizar_visual() -> void:
	if _mat == null:
		return
	var crece: float = clampf(t / 0.7, 0.0, 1.0)
	var fade: float = clampf((duracion - t) / minf(1.5, duracion * 0.4), 0.0, 1.0)
	_mat.albedo_color.a = 0.55 * fade * minf(crece * 2.0, 1.0)
	scale = Vector3.ONE * lerpf(0.3, 1.0, 1.0 - pow(1.0 - crece, 2.0))


## Verdadero si el segmento a-b pasa por dentro de la nube.
func tapa(a: Vector3, b: Vector3) -> bool:
	if not vigente():
		return false
	var centro: Vector3 = global_position + Vector3(0.0, radio * 0.25, 0.0)
	var ab: Vector3 = b - a
	var l2: float = ab.length_squared()
	var k: float = 0.0 if l2 < 0.000001 else clampf((centro - a).dot(ab) / l2, 0.0, 1.0)
	return (a + ab * k).distance_to(centro) <= radio
