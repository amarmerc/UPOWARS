class_name PuntosTacticos
extends RefCounted
## Puntos tacticos para los bots, calculados en runtime sobre la malla de navegacion: posiciones DETRAS de las coberturas
## (`game/data/props_cobertura.json`, exportado de `data/props.csv` con `scripts/exportar_props_bots.py`) respecto a la amenaza,
## cerca de un centro (un site, la Cachimba). Si no hay coberturas suficientes se completa con puntos navegables de un anillo.

const RUTA: String = "res://data/props_cobertura.json"
## Tolerancia (m) entre el punto deseado y el punto de la malla mas cercano para darlo por valido.
const TOLERANCIA_M: float = 1.8
const DETRAS_M: float = 1.3

static var _props: Array = []


## [[tipo, x, z, yaw, escala]] en coordenadas de juego (se lee una vez).
static func props() -> Array:
	if _props.is_empty():
		if not FileAccess.file_exists(RUTA):
			push_warning("No existe %s (uv run python scripts/exportar_props_bots.py)" % RUTA)
			return []
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(RUTA))
		if d is Dictionary and (d as Dictionary).has("props"):
			_props = (d as Dictionary)["props"]
	return _props


## Punto de la malla a menos de TOLERANCIA_M de `deseado` (en horizontal) y de 6 m en vertical de `y_ref`; Vector3.INF si no hay.
static func navegable(mapa: RID, deseado: Vector3, y_ref: float, tol: float = TOLERANCIA_M) -> Vector3:
	var p: Vector3 = NavigationServer3D.map_get_closest_point(mapa, Vector3(deseado.x, y_ref, deseado.z))
	if Vector2(p.x - deseado.x, p.z - deseado.z).length() > tol or absf(p.y - y_ref) > 6.0:
		return Vector3.INF
	return p


## Hasta `n` posiciones a entre `r_min` y `r_max` m de `centro`, cada una justo detras de una cobertura vista desde `amenaza`
## (se prefieren las que estan a `ideal` m de `centro`), separadas >= `separacion` m. `zona` (opcional) descarta lo que cae fuera.
static func puntos_defensa(mapa: RID, centro: Vector3, amenaza: Vector3, n: int, r_min: float, r_max: float,
		rng: RandomNumberGenerator, zona: ZonaActiva = null, separacion: float = 4.0, ideal: float = 11.0) -> Array[Vector3]:
	var candidatos: Array[Dictionary] = []
	var c2 := Vector2(centro.x, centro.z)
	var a2 := Vector2(amenaza.x, amenaza.z)
	for p: Array in props():
		var pos := Vector2(float(p[1]), float(p[2]))
		var d: float = pos.distance_to(c2)
		if d < r_min or d > r_max:
			continue
		if zona != null and not zona.dentro(Vector3(pos.x, 0.0, pos.y)):
			continue
		var dir: Vector2 = (pos - a2).normalized()
		var hold: Vector2 = pos + dir * DETRAS_M
		var nav: Vector3 = navegable(mapa, Vector3(hold.x, centro.y, hold.y), centro.y)
		if nav == Vector3.INF:
			continue
		candidatos.append({"pos": nav, "score": absf(d - ideal) + rng.randf() * 3.0})
	candidatos.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x["score"]) < float(y["score"]))
	var out: Array[Vector3] = []
	for c: Dictionary in candidatos:
		if out.size() >= n:
			break
		if _separado(out, c["pos"], separacion):
			out.append(c["pos"])
	if out.size() < n:
		out.append_array(puntos_anillo(mapa, centro, n - out.size(), r_min, r_max, rng, zona, separacion, out))
	return out


## `n` puntos navegables al azar en el anillo [r_min, r_max] alrededor de `centro` (separados >= `separacion` entre si y de `previos`).
static func puntos_anillo(mapa: RID, centro: Vector3, n: int, r_min: float, r_max: float, rng: RandomNumberGenerator,
		zona: ZonaActiva = null, separacion: float = 4.0, previos: Array[Vector3] = []) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var todos: Array[Vector3] = previos.duplicate()
	for intento in n * 30:
		if out.size() >= n:
			break
		var ang: float = rng.randf() * TAU
		var r: float = rng.randf_range(r_min, r_max)
		var deseado := Vector3(centro.x + cos(ang) * r, centro.y, centro.z + sin(ang) * r)
		if zona != null and not zona.dentro(deseado):
			continue
		var nav: Vector3 = navegable(mapa, deseado, centro.y, 2.5)
		if nav == Vector3.INF or not _separado(todos, nav, separacion):
			continue
		out.append(nav)
		todos.append(nav)
	return out


static func _separado(lista: Array[Vector3], p: Vector3, separacion: float) -> bool:
	for q: Vector3 in lista:
		if Vector2(q.x - p.x, q.z - p.z).length() < separacion:
			return false
	return true
