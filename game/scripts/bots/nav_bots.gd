class_name NavBots
extends RefCounted
## Navegacion de los bots: hornea una `NavigationMesh` en runtime (colisiones estaticas del mapa en la capa 1, incluidos el muro de
## la zona y los props) y la deja en una `NavigationRegion3D` hija de `raiz`. Dos modos:
##  - `hornear_zona(raiz, zona)`: solo dentro del limite de la `ZonaActiva` (+ margen), celdas de 0,25 m. ~0,3 s por zona.
##  - `hornear_campus(raiz)`: todo el campus para el modo libre, celdas de 0,5 m (el radio del agente se redondea a 0,5 m). ~4 s,
##    ~34 000 poligonos; `hornear_radio` limita a un circulo si se quiere algo mas ligero. No hace falta cachear a disco.
## Tras hornear hay que esperar unos fotogramas a que el mapa de navegacion se sincronice: `await NavBots.esperar_listo(raiz, punto)`.
## Las barreras de spawn de la zona (si estan activas al hornear) quedan fuera de la malla; hornear con `activar_barreras(false)`.

const ALTO_AGENTE: float = 1.8
const RADIO_AGENTE: float = 0.4
const MARGEN_ZONA_M: float = 8.0
const AABB_CAMPUS := AABB(Vector3(-800.0, -40.0, -700.0), Vector3(1600.0, 140.0, 1400.0))


static func _malla(celda: float) -> NavigationMesh:
	var nm := NavigationMesh.new()
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nm.geometry_collision_mask = 1  # capa "mundo"
	nm.cell_size = celda
	nm.cell_height = celda * 0.8
	nm.agent_radius = RADIO_AGENTE
	nm.agent_height = ALTO_AGENTE
	nm.agent_max_climb = 0.5
	nm.agent_max_slope = 45.0
	nm.region_min_size = 4.0
	return nm


## Hornea sobre `aabb` y crea la region. Guarda `tiempo_s` y `poligonos` como metadatos de la region.
static func hornear(raiz: Node3D, aabb: AABB, celda: float, nombre: String) -> NavigationRegion3D:
	var nm: NavigationMesh = _malla(celda)
	nm.filter_baking_aabb = aabb
	var t0: int = Time.get_ticks_msec()
	var fuente := NavigationMeshSourceGeometryData3D.new()
	# los coches decorativos (MultiMesh de `CochesExternos`) no deben contar como geometria navegable: el parser salta lo invisible
	var coches: Node3D = raiz.find_child("CochesExternos", true, false) as Node3D
	var coches_visibles: bool = coches != null and coches.visible
	if coches != null:
		coches.visible = false
	NavigationServer3D.parse_source_geometry_data(nm, fuente, raiz)
	if coches != null:
		coches.visible = coches_visibles
	NavigationServer3D.bake_from_source_geometry_data(nm, fuente)
	var region := NavigationRegion3D.new()
	region.name = nombre
	region.navigation_mesh = nm
	region.set_meta("tiempo_s", (Time.get_ticks_msec() - t0) / 1000.0)
	region.set_meta("poligonos", nm.get_polygon_count())
	raiz.add_child(region)
	return region


static func hornear_zona(raiz: Node3D, zona: ZonaActiva, celda: float = 0.25) -> NavigationRegion3D:
	var lim: Dictionary = zona.limites()
	var mn: Vector3 = lim["min"]
	var mx: Vector3 = lim["max"]
	var m := Vector3(MARGEN_ZONA_M, 0.0, MARGEN_ZONA_M)
	var aabb := AABB(mn - m - Vector3(0.0, 12.0, 0.0), (mx - mn) + m * 2.0 + Vector3(0.0, 40.0, 0.0))
	return hornear(raiz, aabb, celda, "Nav_" + zona.id)


static func hornear_campus(raiz: Node3D, celda: float = 0.5) -> NavigationRegion3D:
	return hornear(raiz, AABB_CAMPUS, celda, "Nav_campus")


## Solo un circulo (cuadrado) de `radio` m alrededor de `centro`.
static func hornear_radio(raiz: Node3D, centro: Vector3, radio: float, celda: float = 0.4) -> NavigationRegion3D:
	var aabb := AABB(centro - Vector3(radio, 40.0, radio), Vector3(radio * 2.0, 140.0, radio * 2.0))
	return hornear(raiz, aabb, celda, "Nav_radio")


## Mapa de navegacion del mundo de `nodo`.
static func mapa(nodo: Node) -> RID:
	return (nodo as Node3D).get_world_3d().navigation_map


## Espera (hasta `max_frames` fotogramas de fisica) a que el mapa conozca la region: devuelve true si `punto` ya tiene malla a menos de 5 m.
static func esperar_listo(raiz: Node3D, punto: Vector3, max_frames: int = 40) -> bool:
	var m: RID = mapa(raiz)
	for i in max_frames:
		await raiz.get_tree().physics_frame
		NavigationServer3D.map_force_update(m)
		if NavigationServer3D.map_get_closest_point(m, punto).distance_to(punto) < 5.0:
			return true
	return false


## Longitud (m) del camino por la malla entre dos puntos; -1 si no hay camino.
static func longitud_ruta(m: RID, a: Vector3, b: Vector3) -> float:
	var ruta: PackedVector3Array = NavigationServer3D.map_get_path(m, a, b, true)
	if ruta.size() < 2:
		return -1.0
	var largo: float = 0.0
	for i in range(1, ruta.size()):
		largo += ruta[i - 1].distance_to(ruta[i])
	return largo
