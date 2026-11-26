class_name CampoPractica
extends Node3D
## Campo de practica: 8 dianas a 10, 20, 35 y 50 m del punto de tiro. El punto de tiro y la direccion salen del spawn
## "campo_practica" de spawns.json (pos y yaw_deg). Las dianas se apoyan en el terreno con un rayo vertical.

const DIANA: PackedScene = preload("res://scenes/diana.tscn")
const ID_SPAWN: String = "campo_practica"
## [distancia (m), desplazamiento lateral (m, + = derecha), armadura]
const DISPOSICION: Array = [
	[10.0, -2.5, 0.0], [10.0, 2.5, 0.0],
	[20.0, -4.0, 100.0], [20.0, 4.0, 0.0],
	[35.0, -6.0, 0.0], [35.0, 6.0, 100.0],
	[50.0, -8.0, 100.0], [50.0, 8.0, 0.0],
]

var punto_tiro: Vector3 = Vector3.ZERO
var adelante: Vector3 = Vector3.FORWARD
var dianas: Array[Diana] = []
var listo: bool = false

signal construido


func _ready() -> void:
	# el espacio fisico del mapa no responde a rayos hasta que pasa un paso de fisica
	await get_tree().physics_frame
	await get_tree().physics_frame
	construir()


func construir() -> void:
	var sp: Dictionary = _leer_spawn()
	if sp.is_empty():
		push_warning("CampoPractica: no hay spawn '%s' en spawns.json" % ID_SPAWN)
		return
	var p: Array = sp["pos"]
	punto_tiro = Vector3(p[0], p[1], p[2])
	var yaw: float = deg_to_rad(float(sp["yaw_deg"]))
	adelante = Vector3(-sin(yaw), 0.0, -cos(yaw))
	var derecha: Vector3 = adelante.cross(Vector3.UP)
	for d: Array in DISPOSICION:
		var xz: Vector3 = punto_tiro + adelante * float(d[0]) + derecha * float(d[1])
		var diana: Diana = DIANA.instantiate() as Diana
		diana.armadura = float(d[2])
		diana.name = "Diana_%dm_%s" % [int(d[0]), "izq" if float(d[1]) < 0.0 else "der"]
		add_child(diana)
		diana.global_position = Vector3(xz.x, _suelo(xz), xz.z)
		diana.look_at(Vector3(punto_tiro.x, diana.global_position.y, punto_tiro.z), Vector3.UP)
		dianas.append(diana)
	_linea_de_tiro()
	listo = true
	construido.emit()


func _suelo(xz: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(Vector3(xz.x, punto_tiro.y + 20.0, xz.z),
			Vector3(xz.x, punto_tiro.y - 20.0, xz.z), Balistica.CAPA_MUNDO)
	var r: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	return (r["position"] as Vector3).y if not r.is_empty() else punto_tiro.y - 0.1


func _linea_de_tiro() -> void:
	var m := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(3.0, 0.02, 0.12)
	m.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.8, 0.1)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.material_override = mat
	add_child(m)
	var pos: Vector3 = punto_tiro + adelante * 0.8
	m.global_position = Vector3(pos.x, _suelo(pos) + 0.03, pos.z)
	m.look_at(m.global_position + adelante, Vector3.UP)
	# carteles de distancia a la derecha de la fila (11 m)
	for dist: int in [10, 20, 35, 50]:
		var l := Label3D.new()
		l.text = "%d m" % dist
		l.fixed_size = true
		l.pixel_size = 0.0007
		l.font_size = 64
		l.outline_size = 16
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.modulate = Color(1.0, 0.9, 0.3)
		add_child(l)
		var q: Vector3 = punto_tiro + adelante * float(dist) + adelante.cross(Vector3.UP) * 11.0
		l.global_position = Vector3(q.x, _suelo(q) + 3.0, q.z)


func _leer_spawn() -> Dictionary:
	var datos: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/spawns.json"))
	if datos is Dictionary and (datos as Dictionary).has("spawns"):
		for s: Dictionary in (datos as Dictionary)["spawns"]:
			if str(s.get("id", "")) == ID_SPAWN:
				return s
	return {}
