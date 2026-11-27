class_name ZonaActiva
extends Node3D
## Zona competitiva en juego: carga una zona de res://data/zonas.json (lo exporta scripts/generar_zonas.py) y construye en runtime,
## sin tocar el .glb del mapa:
##  - un muro perimetral de `alto_muro` m (8) sobre el terreno, con colision en la capa "mundo" (1) y el shader translucido
##    res://shaders/muro_zona.gdshader (hexagonos tenues, mas visibles cerca de la camara; se ve a traves);
##  - las barreras de la fase de compra de cada equipo (poligono que encierra su spawn), del mismo estilo pero con el color del
##    equipo; se activan y desactivan con activar_barreras();
##  - los marcadores de site: la letra A/B flotante y un aro en el suelo (Decal).
## Fuera del modo competitivo no se instancia nada: el modo libre no crea este nodo. Uso:
##     var zona := ZonaActiva.crear("plaza_america")   # null si el id no existe
##     add_child(zona); zona.activar_barreras(true)
##     var s := zona.punto_spawn("atacantes", 0)       # {"pos": Vector3, "yaw_deg": float}
##     zona.site_en(jugador.global_position)           # "A" / "B" / ""
## Equipos: "atacantes" y "defensores". Todas las posiciones son de juego (x = este, y = arriba, z = -norte).

const RUTA_ZONAS := "res://data/zonas.json"
const SHADER_MURO := "res://shaders/muro_zona.gdshader"
const CAPA_MUNDO: int = 1
const EQUIPOS: Array[String] = ["atacantes", "defensores"]
const COLOR_MURO := Color(0.45, 0.86, 1.0)
const COLORES_EQUIPO := {"atacantes": Color(1.0, 0.48, 0.12), "defensores": Color(0.25, 0.6, 1.0)}
const COLOR_SITE := Color(1.0, 0.85, 0.25)
const ENTERRADO_M: float = 2.0       # el muro y las barreras bajan 2 m bajo el terreno (laderas entre vertices)
const GROSOR_COLISION_M: float = 0.5
const ALTO_LETRA_M: float = 5.5

static var _cache: Dictionary = {}

var zona: Dictionary = {}
var id: String = ""
var muro: Node3D                       # malla + StaticBody3D del limite
var barreras: Dictionary = {}          # equipo -> Node3D (malla + StaticBody3D)
var marcadores: Node3D
var barreras_activas: bool = false


## Contenido de data/zonas.json (se lee una sola vez). {} si falta o no es valido.
static func datos_zonas() -> Dictionary:
	if _cache.is_empty():
		if not FileAccess.file_exists(RUTA_ZONAS):
			push_error("No existe %s (uv run python scripts/generar_zonas.py)" % RUTA_ZONAS)
			return {}
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(RUTA_ZONAS))
		if d is Dictionary and (d as Dictionary).has("zonas"):
			_cache = d
	return _cache


## Ids de las zonas disponibles, en el orden del fichero.
static func ids_disponibles() -> PackedStringArray:
	var out := PackedStringArray()
	for z: Dictionary in datos_zonas().get("zonas", []):
		out.append(str(z["id"]))
	return out


## Datos crudos de una zona (sin instanciar nada). {} si no existe.
static func datos_de(zona_id: String) -> Dictionary:
	for z: Dictionary in datos_zonas().get("zonas", []):
		if str(z["id"]) == zona_id:
			return z
	return {}


## Crea el nodo y carga la zona; null si el id no existe.
static func crear(zona_id: String) -> ZonaActiva:
	var za := ZonaActiva.new()
	if not za.cargar(zona_id):
		za.free()
		return null
	return za


## Construye muro, barreras y marcadores de la zona. Devuelve false si el id no existe.
func cargar(zona_id: String) -> bool:
	var datos: Dictionary = datos_de(zona_id)
	if datos.is_empty():
		push_error("Zona desconocida: %s" % zona_id)
		return false
	_vaciar()
	zona = datos
	id = zona_id
	name = "Zona_" + zona_id
	var alto: float = float(zona.get("alto_muro", 8.0))
	muro = _crear_pared("Muro", zona["limite_denso"], alto, COLOR_MURO, 1.0)
	add_child(muro)
	var alto_b: float = float(zona.get("alto_barrera", 4.0))
	for eq in EQUIPOS:
		var b: Node3D = _crear_pared("Barrera_" + eq, zona["spawn_" + eq]["barrera_densa"], alto_b, COLORES_EQUIPO[eq], 1.6)
		barreras[eq] = b
		add_child(b)
	marcadores = _crear_marcadores()
	add_child(marcadores)
	barreras_activas = true       # activar_barreras() lo deja en el estado pedido y aplica visibilidad y colision
	activar_barreras(false)
	return true


func _vaciar() -> void:
	for h in get_children():
		remove_child(h)
		h.queue_free()
	barreras.clear()
	muro = null
	marcadores = null


## Activa o desactiva las barreras de compra de los dos equipos (malla visible y colision en la capa mundo).
func activar_barreras(activas: bool) -> void:
	barreras_activas = activas
	for eq: String in barreras:
		var b: Node3D = barreras[eq]
		b.visible = activas
		var cuerpo: StaticBody3D = b.get_node("Cuerpo")
		cuerpo.collision_layer = CAPA_MUNDO if activas else 0


## Punto de aparicion i (0-4) del equipo: {"pos": Vector3 (suelo + 0,1 m), "yaw_deg": float}. i se toma modulo 5.
func punto_spawn(equipo: String, i: int) -> Dictionary:
	var lista: Array = zona["spawn_" + equipo]["posiciones"]
	var e: Dictionary = lista[posmod(i, lista.size())]
	var p: Array = e["pos"]
	return {"pos": Vector3(p[0], p[1], p[2]), "yaw_deg": float(e["yaw_deg"])}


func n_spawns(equipo: String) -> int:
	return (zona["spawn_" + equipo]["posiciones"] as Array).size()


## "A", "B" o "" segun el site que contiene la posicion (solo cuentan x y z).
func site_en(posicion: Vector3) -> String:
	var p := Vector2(posicion.x, posicion.z)
	for k: String in zona["sites"]:
		var s: Dictionary = zona["sites"][k]
		if s.has("poligono"):
			var pol := PackedVector2Array()
			for v: Array in s["poligono"]:
				pol.append(Vector2(v[0], v[2]))
			if Geometry2D.is_point_in_polygon(p, pol):
				return k
		else:
			var c: Array = s["centro"]
			if p.distance_to(Vector2(c[0], c[2])) <= float(s["radio"]):
				return k
	return ""


## Centro (Vector3, y del terreno) de un site.
func centro_site(site: String) -> Vector3:
	var c: Array = zona["sites"][site]["centro"]
	return Vector3(c[0], c[1], c[2])


## Limites de la zona: {"poligono": PackedVector2Array (x, z), "min": Vector3, "max": Vector3, "centro": Vector3, "alto_muro": float}.
func limites() -> Dictionary:
	var pol := PackedVector2Array()
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for v: Array in zona["limite"]:
		pol.append(Vector2(v[0], v[2]))
		mn = mn.min(Vector3(v[0], v[1], v[2]))
		mx = mx.max(Vector3(v[0], v[1], v[2]))
	return {"poligono": pol, "min": mn, "max": mx, "centro": (mn + mx) * 0.5, "alto_muro": float(zona.get("alto_muro", 8.0))}


## true si (x, z) esta dentro del limite de la zona.
func dentro(posicion: Vector3) -> bool:
	return Geometry2D.is_point_in_polygon(Vector2(posicion.x, posicion.z), limites()["poligono"])


## Camara de vista previa del lobby: {"pos": Vector3, "mira": Vector3, "fov": float}.
func camara_lobby() -> Dictionary:
	var c: Dictionary = zona["camara_lobby"]
	var p: Array = c["pos"]
	var m: Array = c["mira"]
	return {"pos": Vector3(p[0], p[1], p[2]), "mira": Vector3(m[0], m[1], m[2]), "fov": float(c.get("fov", 60.0))}


## Pared (malla translucida + StaticBody3D "Cuerpo" con una caja por tramo) siguiendo el anillo cerrado `anillo` ([[x, y, z]]).
## La pared va de ENTERRADO_M bajo el terreno de cada vertice a `alto` m sobre el.
func _crear_pared(nombre: String, anillo: Array, alto: float, color: Color, alfa_rel: float) -> Node3D:
	var raiz := Node3D.new()
	raiz.name = nombre
	var n: int = anillo.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cuerpo := StaticBody3D.new()
	cuerpo.name = "Cuerpo"
	cuerpo.collision_layer = CAPA_MUNDO
	cuerpo.collision_mask = 0
	raiz.add_child(cuerpo)
	var acum: float = 0.0
	for i in n:
		var a: Array = anillo[i]
		var b: Array = anillo[(i + 1) % n]
		var pa := Vector3(a[0], a[1], a[2])
		var pb := Vector3(b[0], b[1], b[2])
		var largo: float = Vector2(pb.x - pa.x, pb.z - pa.z).length()
		if largo < 0.01:
			continue
		var v0 := pa + Vector3.DOWN * ENTERRADO_M
		var v1 := pa + Vector3.UP * alto
		var v2 := pb + Vector3.DOWN * ENTERRADO_M
		var v3 := pb + Vector3.UP * alto
		var u0 := Vector2(acum, -ENTERRADO_M)
		var u1 := Vector2(acum, alto)
		var u2 := Vector2(acum + largo, -ENTERRADO_M)
		var u3 := Vector2(acum + largo, alto)
		for t: Array in [[v0, u0], [v1, u1], [v2, u2], [v1, u1], [v3, u3], [v2, u2]]:
			st.set_uv(t[1])
			st.add_vertex(t[0])
		acum += largo
		# colision: caja alineada con el tramo, un poco mas larga para que no queden huecos en las esquinas
		var y_min: float = minf(pa.y, pb.y) - ENTERRADO_M
		var y_max: float = maxf(pa.y, pb.y) + alto
		var forma := CollisionShape3D.new()
		var caja := BoxShape3D.new()
		caja.size = Vector3(largo + GROSOR_COLISION_M, y_max - y_min, GROSOR_COLISION_M)
		forma.shape = caja
		var centro := Vector3((pa.x + pb.x) * 0.5, (y_min + y_max) * 0.5, (pa.z + pb.z) * 0.5)
		forma.transform = Transform3D(Basis(Vector3.UP, atan2(-(pb.z - pa.z), pb.x - pa.x)), centro)
		cuerpo.add_child(forma)
	var mi := MeshInstance3D.new()
	mi.name = "Malla"
	mi.mesh = st.commit()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = _material_muro(color, alto, alfa_rel)
	raiz.add_child(mi)
	return raiz


func _material_muro(color: Color, alto: float, alfa_rel: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(SHADER_MURO) as Shader
	m.set_shader_parameter("color", color)
	m.set_shader_parameter("altura_total", alto)
	m.set_shader_parameter("alpha_relleno", 0.035 * alfa_rel)
	m.set_shader_parameter("alpha_linea", 0.22 * alfa_rel)
	m.set_shader_parameter("alpha_cerca", minf(0.7 * alfa_rel, 0.9))
	m.set_shader_parameter("alpha_max", minf(0.75 * alfa_rel, 0.9))
	return m


func _crear_marcadores() -> Node3D:
	var raiz := Node3D.new()
	raiz.name = "Marcadores"
	var texs: Array[ImageTexture] = _texturas_aro()
	for k: String in zona["sites"]:
		var s: Dictionary = zona["sites"][k]
		var c: Array = s["centro"]
		var radio: float = float(s["radio"])
		var nodo := Node3D.new()
		nodo.name = "Site_" + k
		nodo.position = Vector3(c[0], c[1], c[2])
		raiz.add_child(nodo)
		var letra := Label3D.new()
		letra.name = "Letra"
		letra.text = k
		letra.font_size = 220
		letra.pixel_size = 0.014
		letra.outline_size = 36
		letra.modulate = COLOR_SITE
		letra.outline_modulate = Color(0.2, 0.14, 0.0)
		letra.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		letra.shaded = false
		letra.double_sided = true
		letra.alpha_cut = Label3D.ALPHA_CUT_DISABLED
		letra.position = Vector3(0, ALTO_LETRA_M, 0)
		letra.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		nodo.add_child(letra)
		var aro := Decal.new()
		aro.name = "Aro"
		aro.size = Vector3(radio * 2.0 + 0.6, 10.0, radio * 2.0 + 0.6)
		aro.position = Vector3(0, 3.0, 0)
		aro.texture_albedo = texs[0]
		aro.texture_emission = texs[1]
		aro.emission_energy = 1.4
		aro.modulate = COLOR_SITE
		aro.upper_fade = 0.1
		aro.lower_fade = 0.1
		nodo.add_child(aro)
	return raiz


## Aro del suelo: anillo fino, anillo interior mas tenue y disco casi transparente, en texturas de 256 px.
## Devuelve [albedo (alfa = forma), emision (gris = forma, alfa 1)].
static func _texturas_aro() -> Array[ImageTexture]:
	var n: int = 256
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var emi := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var r: float = Vector2(x + 0.5 - n * 0.5, y + 0.5 - n * 0.5).length() / (n * 0.5)
			var a: float = 0.0
			if r <= 1.0:
				a = 0.07
				a = maxf(a, 0.95 * clampf(1.0 - absf(r - 0.955) / 0.035, 0.0, 1.0))
				a = maxf(a, 0.5 * clampf(1.0 - absf(r - 0.86) / 0.012, 0.0, 1.0))
			img.set_pixel(x, y, Color(1, 1, 1, a))
			emi.set_pixel(x, y, Color(a, a, a, 1.0))
	return [ImageTexture.create_from_image(img), ImageTexture.create_from_image(emi)]
