class_name RetratosPersonajes
extends Node
## Retratos de los personajes para las tarjetas del lobby: un SubViewport con mundo propio por personaje, dibujado una vez con
## `ModeloPersonaje.crear` (asi cualquier cambio de modelo se refleja solo). `textura(&"_bot")` es el retrato gris de los bots.
## Hay que tenerlo en el arbol (el lobby lo anade como hijo).

const TAM: Vector2i = Vector2i(192, 240)
var _vistas: Dictionary = {}


func textura(id: StringName) -> Texture2D:
	if not _vistas.has(id):
		_vistas[id] = _crear(id)
	return (_vistas[id] as SubViewport).get_texture()


func _crear(id: StringName) -> SubViewport:
	var p: Dictionary = CatalogoPersonajes.por_id(id)
	var sv := SubViewport.new()
	sv.size = TAM
	sv.own_world_3d = true
	sv.transparent_bg = true
	sv.msaa_3d = Viewport.MSAA_4X
	sv.render_target_update_mode = SubViewport.UPDATE_ONCE
	var cuerpo: Node3D = ModeloPersonaje.crear(p, Color(0.5, 0.5, 0.55) if id == &"_bot" else Color(0.95, 0.7, 0.2), false, false)
	cuerpo.rotation_degrees.y = 20.0
	sv.add_child(cuerpo)
	var cam := Camera3D.new()
	cam.fov = 30.0
	var pos := Vector3(0, 1.4, -2.7)
	cam.transform = Transform3D(Basis.looking_at(Vector3(0, 1.3, 0) - pos, Vector3.UP), pos)
	sv.add_child(cam)
	var luz := DirectionalLight3D.new()
	luz.rotation_degrees = Vector3(-35.0, 160.0, 0.0)
	luz.light_energy = 1.2
	sv.add_child(luz)
	var entorno := Environment.new()
	entorno.background_mode = Environment.BG_CLEAR_COLOR
	entorno.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	entorno.ambient_light_color = Color(0.8, 0.82, 0.9)
	entorno.ambient_light_energy = 0.7
	var we := WorldEnvironment.new()
	we.environment = entorno
	sv.add_child(we)
	add_child(sv)
	ModeloPersonaje.pose(cuerpo)
	return sv
