class_name Materiales
extends RefCounted
## Sustituye los materiales planos del .glb por materiales con textura procedural, sin UVs:
## StandardMaterial3D con triplanar en espacio mundial (uv1_world_triplanar) o el ShaderMaterial de fachada.
## Las texturas las genera scripts/generar_texturas.py en res://assets/texturas/. Se aplica por NOMBRE de material.

const DIR_TEX := "res://assets/texturas/"
const SHADER_FACHADA := "res://shaders/fachada.gdshader"
const SHADER_VALLA := "res://shaders/valla.gdshader"
const SHADER_LOSA := "res://shaders/losa.gdshader"
const JSON_ESTILOS := "res://data/estilos.json"   # osm_id -> estilo (lo exporta generar_blockout.py)
const COLOR_PILAR := "#E2BE78"

## material del glb -> [textura, metros por tesela de 512 px, tinte, roughness, metallic]
const TRIPLANAR := {
	"suelo": ["albero", 4.0, Color.WHITE, 0.95, 0.0],
	"camino_asfalto": ["asfalto", 4.0, Color.WHITE, 0.88, 0.0],
	"camino_peatonal": ["baldosa", 3.2, Color.WHITE, 0.85, 0.0],
	"pavimento_blanco": ["baldosa_clara", 4.0, Color(0.95, 0.945, 0.915), 0.8, 0.0],   # ~#E8E6E0: suelo de los pasillos cubiertos
	"verde": ["cesped", 3.0, Color.WHITE, 0.95, 0.0],
	"pista": ["pista", 4.0, Color.WHITE, 0.8, 0.0],
	"agua": ["agua", 6.0, Color.WHITE, 0.12, 0.0],
	"aparcamiento": ["aparcamiento", 4.0, Color.WHITE, 0.88, 0.0],
	"muros": ["hormigon", 3.0, Color(1.05, 1.0, 0.92), 0.92, 0.0],
	"campo": ["campo", 10.0, Color.WHITE, 1.0, 0.0],
}

## materiales del glb que se conservan (color y transparencia) ajustando solo el brillo: nombre -> [roughness, metallic]
const AJUSTES := {
	"arbol_corteza": [1.0, 0.0], "arbol_copa_1": [0.95, 0.0], "arbol_copa_2": [0.95, 0.0], "arbol_copa_3": [0.95, 0.0],
	"coche_cristal": [0.08, 0.3], "coche_goma": [0.95, 0.0],
	"valla_metal": [0.45, 0.6], "vallas": [0.8, 0.0],
	# coberturas (props de data/props.csv): conservan su color del glb
	"prop_hormigon": [0.92, 0.0], "prop_madera": [0.8, 0.0], "prop_metal": [0.5, 0.55], "prop_basura": [0.7, 0.05],
	"prop_reciclaje_azul": [0.6, 0.05], "prop_reciclaje_amarillo": [0.6, 0.05], "prop_reciclaje_verde": [0.6, 0.05],
	"prop_expendedora": [0.4, 0.2], "prop_cristal_oscuro": [0.12, 0.3], "prop_pizarra": [0.85, 0.0],
	"prop_silla": [0.55, 0.0], "prop_arbusto": [0.95, 0.0],
}
const AJUSTE_COCHE := [0.3, 0.45]   # el resto de coche_* (carrocerias)

## materiales translúcidos: sus mallas no proyectan sombra (si no, la valla/pádel dejan una mancha oscura en el suelo)
const SIN_SOMBRA := ["valla_malla", "cristal_padel", "limite", "coche_cristal"]

const OCRE := "#E2BE78"
const BLANCO := "#EDEBE6"
const LADRILLO := "#B4583F"

## Parametros base de fachada.gdshader compartidos por los estilos "eje pastel".
const _EJE_BASE := {
	"color_testero": OCRE, "modo_vent": 0, "planta": 3.5, "modulo": 2.4, "vent_w": 1.1, "vent_h": 1.1, "alfeizar": 1.1,
	"marco_w": 0.07, "color_marco": "#F4F2EC", "color_cristal": "#0A1220",
	"banda_h": 0.25, "color_banda": "#F4F2EC",
	"remate_h": 0.7, "color_remate": OCRE, "remate_borde_h": 0.1, "color_remate_borde": "#F4F2EC",
}

## estilo -> parametros del ShaderMaterial (los colores son sRGB en texto). Los que no aparecen quedan en el defecto del shader.
static func _estilos() -> Dictionary:
	var verde: Dictionary = _EJE_BASE.duplicate()
	verde["color_muro"] = "#8FB7A0"
	var rosa: Dictionary = _EJE_BASE.duplicate()
	rosa["color_muro"] = "#D79A9E"
	var malva: Dictionary = _EJE_BASE.duplicate()
	malva["color_muro"] = "#8E7391"
	return {
		"eje_pastel_verde": verde, "eje_pastel_rosa": rosa, "eje_pastel_malva": malva,
		"ladrillo_rectorado": {
			"color_muro": LADRILLO, "color_testero": LADRILLO, "ladrillo": 0.8,
			"modo_vent": 1, "planta": 3.5, "modulo": 3.0, "vent_h": 1.4, "alfeizar": 1.1, "marco_w": 0.06,
			"color_marco": "#3A3A3C", "color_cristal": "#0B1838",
			"panel_h": 1.0, "color_panel": "#D9A441", "remate_h": 0.6, "color_remate": BLANCO,
		},
		"ladrillo_torre": {
			"color_muro": LADRILLO, "color_testero": LADRILLO, "ladrillo": 0.8,
			"modo_vent": 0, "planta": 7.0, "modulo": 7.0, "vent_w": 0.9, "vent_h": 2.4, "alfeizar": 2.0, "marco_w": 0.08,
			"vent_testero": 1.0, "color_marco": "#3A3A3C", "color_cristal": "#0A1220",
			"mirador_h": 6.0, "color_mirador": BLANCO,
		},
		"biblioteca": {
			"color_muro": "#C98A73", "color_testero": "#C98A73", "ladrillo": 0.35,
			"modo_vent": 1, "planta": 3.5, "modulo": 3.0, "vent_h": 1.8, "alfeizar": 0.7, "marco_w": 0.06,
			"color_marco": "#2E2E30", "color_cristal": "#0A1018",
			"lama_h": 0.6, "color_lama": "#9A9A96",
		},
		"rosa_24": {
			"color_muro": "#C25E6C", "color_testero": "#C25E6C",
			"modo_vent": 0, "planta": 3.5, "modulo": 3.0, "vent_w": 1.3, "vent_h": 1.5, "alfeizar": 0.9, "marco_w": 0.16,
			"color_marco": "#F4F2EC", "color_cristal": "#0A1220",
			"banda_h": 0.25, "color_banda": "#F4F2EC", "remate_h": 0.7, "color_remate": "#F4F2EC",
		},
		"policarbonato": {
			"color_muro": "#DDE2E4", "color_testero": "#DDE2E4", "modo_vent": 2, "rugosidad": 0.3,
			"nervio_sep": 0.6, "nervio_w": 0.06, "nervio_oscuro": 0.8, "brillo": 0.86,
		},
	}

const FACHADAS := {
	"edificio": Color(200.0 / 255.0, 200.0 / 255.0, 205.0 / 255.0),
	"torre": Color(150.0 / 255.0, 120.0 / 255.0, 105.0 / 255.0),
}

static var _cache: Dictionary = {}
static var _estilos_json: Dictionary = {}


## Recorre todas las MeshInstance3D bajo `raiz` y sustituye los materiales. Devuelve cuántas superficies cambió.
## Los edificios (nodos `edif_<osmid>_<slug>`) reciben el ShaderMaterial de su estilo (estilos.json) y los
## instance uniform eje_principal / y_cubierta / ext_eje, calculados de su malla.
static func aplicar(raiz: Node) -> int:
	var n := 0
	_estilos_json = {}
	if FileAccess.file_exists(JSON_ESTILOS):
		var datos: Variant = JSON.parse_string(FileAccess.get_file_as_string(JSON_ESTILOS))
		if datos is Dictionary:
			_estilos_json = datos
	for nodo: Node in raiz.find_children("*", "MeshInstance3D", true, false):
		var mi := nodo as MeshInstance3D
		if mi.mesh == null:
			continue
		var geom_fachada := false
		for i in mi.mesh.get_surface_count():
			var orig: Material = mi.mesh.surface_get_material(i)
			if orig == null:
				continue
			var nombre := String(orig.resource_name)
			if nombre in SIN_SOMBRA:
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var nuevo: Material = null
			if FACHADAS.has(nombre) and String(mi.name).begins_with("edif_"):
				nuevo = material_estilo(estilo_de(String(mi.name)))
				geom_fachada = true
			else:
				nuevo = _material_para(nombre, orig)
			if nuevo != null:
				mi.set_surface_override_material(i, nuevo)
				n += 1
		if geom_fachada:
			_instance_uniforms(mi)
	return n


## Estilo de un nodo `edif_<osmid>_<slug>`: el de estilos.json o, si falta, eje pastel por osm_id mod 3.
static func estilo_de(nombre_nodo: String) -> String:
	var id := nombre_nodo.get_slice("_", 1)
	var e: Variant = _estilos_json.get(id, null)
	if e is String and _estilos().has(e):
		return e
	var ejes := ["eje_pastel_verde", "eje_pastel_rosa", "eje_pastel_malva"]
	return ejes[int(id) % 3] if id.is_valid_int() else ejes[0]


## ShaderMaterial de fachada de un estilo (uno compartido por todos los edificios de ese estilo).
static func material_estilo(estilo: String) -> ShaderMaterial:
	var clave := "estilo:" + estilo
	if _cache.has(clave):
		return _cache[clave]
	var m := ShaderMaterial.new()
	m.shader = load(SHADER_FACHADA) as Shader
	m.resource_name = estilo
	m.set_meta("estilo", estilo)
	var params: Dictionary = _estilos().get(estilo, {})
	for k: String in params:
		var v: Variant = params[k]
		m.set_shader_parameter(k, Color(v) if v is String else v)
	_cache[clave] = m
	return m


## Rellena los instance uniform del shader de fachada de un edificio. Las instance uniform son por instancia
## (GeometryInstance3D.set_instance_shader_parameter) y funcionan con el material de superficie compartido.
## eje_principal: lado largo del rectangulo minimo de los vertices en XZ; y_cubierta: y maxima del AABB global;
## ext_eje: extension de la huella a lo largo de ese eje y del perpendicular.
static func _instance_uniforms(mi: MeshInstance3D) -> void:
	var pts := PackedVector2Array()
	var gt: Transform3D = mi.global_transform
	for i in mi.mesh.get_surface_count():
		for v: Vector3 in mi.mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]:
			var w := gt * v
			pts.append(Vector2(w.x, w.z))
	if pts.size() < 3:
		return
	var casco := Geometry2D.convex_hull(pts)
	var mejor_area := INF
	var mejor := Vector4(1, 0, 0, 0)   # (ex, ez, largo_a, largo_b)
	var mejor_ext := Vector4.ZERO
	for i in casco.size() - 1:
		var d := casco[i + 1] - casco[i]
		if d.length() < 0.01:
			continue
		d = d.normalized()
		var p := Vector2(-d.y, d.x)
		var a0 := INF
		var a1 := -INF
		var b0 := INF
		var b1 := -INF
		for q: Vector2 in casco:
			var a := q.dot(d)
			var b := q.dot(p)
			a0 = minf(a0, a)
			a1 = maxf(a1, a)
			b0 = minf(b0, b)
			b1 = maxf(b1, b)
		var area := (a1 - a0) * (b1 - b0)
		if area < mejor_area:
			mejor_area = area
			mejor = Vector4(d.x, d.y, a1 - a0, b1 - b0)
			mejor_ext = Vector4(a0, a1, b0, b1)
	var eje := Vector2(mejor.x, mejor.y)
	if mejor.w > mejor.z:   # el eje largo es el otro lado del rectangulo
		eje = Vector2(-eje.y, eje.x)
		mejor_ext = Vector4(mejor_ext.z, mejor_ext.w, -mejor_ext.y, -mejor_ext.x)
	# con eje' = perp(eje): a' = dot(q, perp) = b ; b' = dot(q, perp(eje')) = dot(q, -eje) = -a
	mi.set_instance_shader_parameter("eje_principal", eje)
	mi.set_instance_shader_parameter("y_cubierta", (gt * mi.get_aabb()).end.y)
	mi.set_instance_shader_parameter("ext_eje", mejor_ext)


static func _material_para(nombre: String, orig: Material) -> Material:
	if _cache.has(nombre):
		return _cache[nombre]
	var m: Material = null
	if TRIPLANAR.has(nombre):
		var c: Array = TRIPLANAR[nombre]
		m = _triplanar(c[0], c[1], c[2], c[3], c[4])
	elif nombre == "valla_malla":
		m = ShaderMaterial.new()
		(m as ShaderMaterial).shader = load(SHADER_VALLA) as Shader
	elif nombre == "pilar":
		var sm := StandardMaterial3D.new()
		sm.albedo_color = Color(COLOR_PILAR)
		sm.roughness = 0.92
		m = sm
	elif nombre == "cubierta":
		m = ShaderMaterial.new()
		(m as ShaderMaterial).shader = load(SHADER_LOSA) as Shader
	elif FACHADAS.has(nombre):
		m = _fachada(FACHADAS[nombre])
	elif AJUSTES.has(nombre) or (nombre.begins_with("coche_") and orig is StandardMaterial3D):
		var aj: Array = AJUSTES.get(nombre, AJUSTE_COCHE)
		if orig is StandardMaterial3D:
			var d := (orig as StandardMaterial3D).duplicate() as StandardMaterial3D
			d.roughness = aj[0]
			d.metallic = aj[1]
			m = d
	_cache[nombre] = m   # null = se deja el material importado (cristal_padel, limite, valla_malla...)
	return m


static func _triplanar(tex: String, metros: float, tinte: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load(DIR_TEX + tex + ".png") as Texture2D
	m.albedo_color = tinte
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE / metros
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.roughness = rough
	m.metallic = metal
	return m


static func _fachada(color_pared: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(SHADER_FACHADA) as Shader
	m.set_shader_parameter("color_pared", color_pared)
	return m
