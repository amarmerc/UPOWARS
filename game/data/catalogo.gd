class_name Catalogo
extends RefCounted
## Catalogo de articulos (armas, utilidades y escudo) con id, nombre, categoria, hueco, precio y ruta al .tres.
## Es la unica fuente de precios: la tienda de la partida (P4) y el armero de pruebas la leen de aqui.
## Categorias de la tienda: secundaria, principal, especial, utilidad, escudo. Huecos del inventario: principal, secundaria,
## cuerpo, utilidades y escudo (las armas especiales cuentan como principal, salvo el Puño-Bot que es secundaria).

const CATEGORIAS: Array[String] = ["secundaria", "principal", "especial", "utilidad", "escudo"]
## [id, nombre, categoria, hueco, precio, descripcion / contrapartida]
const ITEMS: Array = [
	[&"pistola_9mm", "Pistola 9 mm", "secundaria", &"secundaria", 0, "Arma inicial, siempre disponible"],
	[&"pistola_auto", "Pistola automática 9 mm", "secundaria", &"secundaria", 500, "Ráfagas de 3; imprecisa"],
	[&"pistola_pesada", "Pistola pesada .50", "secundaria", &"secundaria", 800, "Mucho daño; lenta, 7 balas"],
	[&"revolver_357", "Revólver .357", "secundaria", &"secundaria", 700, "6 balas, cadencia lenta, recarga larga"],
	[&"escopeta_recortada", "Escopeta recortada", "secundaria", &"secundaria", 600, "2 cartuchos; solo letal muy cerca"],
	[&"subfusil_compacto", "Subfusil compacto", "secundaria", &"secundaria", 900, "Cadencia alta, poco daño, imprecisa a distancia"],
	[&"subfusil_9mm", "Subfusil 9 mm", "principal", &"principal", 1500, "Cadencia alta, daño bajo"],
	[&"subfusil_45", "Subfusil pesado .45", "principal", &"principal", 1900, "Más daño, menos cadencia"],
	[&"escopeta_corredera", "Escopeta de corredera", "principal", &"principal", 1800, "Letal de cerca; cadencia lenta"],
	[&"escopeta_auto", "Escopeta automática", "principal", &"principal", 2600, "Poco daño por perdigón; cara"],
	[&"carabina_556", "Carabina 5,56", "principal", &"principal", 2500, "Menos daño que el fusil; precisa en movimiento"],
	[&"fusil_asalto", "Fusil de asalto 5,56", "principal", &"principal", 2900, "Fusil base"],
	[&"fusil_combate", "Fusil de combate 7,62", "principal", &"principal", 3200, "Más daño, menos cadencia; cabeza letal"],
	[&"fusil_tirador", "Fusil tirador semiautomático", "principal", &"principal", 3500, "Zoom medio; semiautomático"],
	[&"fusil_precision", "Fusil de precisión de cerrojo", "principal", &"principal", 4700, "Zoom fuerte, letal al torso; lento"],
	[&"ametralladora", "Ametralladora ligera", "principal", &"principal", 3300, "Cargador grande; muy lenta de recargar y mover"],
	[&"arco_olivo", "Arco \"Olivo\"", "especial", &"principal", 2200, "Carga mantenida, flecha con caída; silencioso; recuperación lenta"],
	[&"tirachinas", "Tirachinas \"Gomero\"", "especial", &"principal", 400, "Proyectil con caída, silencioso y barato; poco daño"],
	[&"lanzacohetes", "Lanzacohetes \"Traca\"", "especial", &"principal", 4500, "3 cohetes en el cargador, 6 de reserva; autodaño y empuje; recarga lenta"],
	[&"sable_plasma", "\"Sable de Plasma\"", "especial", &"principal", 3000, "Bloquea disparos (clic derecho); se sobrecalienta"],
	[&"puno_bot", "\"Puño-Bot\"", "especial", &"secundaria", 600, "Puño proyectil cargable; tarda 1,5 s en volver"],
	[&"navaja", "Navaja", "cuerpo", &"cuerpo", 0, "Siempre; clic derecho = golpe fuerte"],
	[&"granada_humo", "Granada de humo", "utilidad", &"utilidades", 300, "Humo de 5 m durante 15 s"],
	[&"granada_cegadora", "Granada cegadora", "utilidad", &"utilidades", 250, "Mecha 1,5 s; ciega según ángulo y distancia"],
	[&"granada_explosiva", "Granada explosiva", "utilidad", &"utilidades", 400, "Mecha 2 s; daño en área"],
	[&"bote_pintura", "Bote de pintura", "utilidad", &"utilidades", 300, "Marca 5 s a los enemigos en 4 m"],
	[&"extintor", "Extintor", "utilidad", &"utilidades", 350, "Nube de 3 s que tapa la visión y empuja"],
	[&"altavoz", "Altavoz señuelo", "utilidad", &"utilidades", 200, "6 s de pasos y disparos falsos"],
	[&"escudo_ligero", "Escudo ligero", "escudo", &"escudo", 400, "25 puntos de escudo"],
	[&"escudo_pesado", "Escudo pesado", "escudo", &"escudo", 1000, "50 puntos de escudo"],
]
const PUNTOS_ESCUDO: Dictionary = {&"escudo_ligero": 25.0, &"escudo_pesado": 50.0}

static var _indice: Dictionary = {}
static var _armas: Dictionary = {}


static func _construir() -> void:
	if not _indice.is_empty():
		return
	for it: Array in ITEMS:
		var ruta: String = "" if it[3] == &"escudo" else "res://data/armas/%s.tres" % String(it[0])
		_indice[it[0]] = {"id": it[0], "nombre": it[1], "categoria": it[2], "hueco": it[3], "precio": it[4],
				"descripcion": it[5], "ruta": ruta}


static func existe(id: StringName) -> bool:
	_construir()
	return _indice.has(id)


## {id, nombre, categoria, hueco, precio, descripcion, ruta} o {} si no existe.
static func info(id: StringName) -> Dictionary:
	_construir()
	return _indice.get(id, {})


static func hueco(id: StringName) -> StringName:
	return StringName(info(id).get("hueco", &""))


static func precio(id: StringName) -> int:
	return int(info(id).get("precio", 0))


static func todos() -> Array[Dictionary]:
	_construir()
	var out: Array[Dictionary] = []
	for it: Array in ITEMS:
		out.append(_indice[it[0]])
	return out


static func por_categoria(categoria: String) -> Array[Dictionary]:
	return todos().filter(func(d: Dictionary) -> bool: return d["categoria"] == categoria)


## ArmaDatos (arma o utilidad) del id, cacheada. null si no tiene .tres (escudo).
static func arma(id: StringName) -> ArmaDatos:
	if _armas.has(id):
		return _armas[id]
	var ruta: String = str(info(id).get("ruta", ""))
	if ruta == "" or not ResourceLoader.exists(ruta):
		return null
	var a: ArmaDatos = load(ruta) as ArmaDatos
	_armas[id] = a
	return a
