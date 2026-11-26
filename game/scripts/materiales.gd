class_name Materiales
extends RefCounted
## Sustituye los materiales planos del .glb por materiales con textura procedural, sin UVs:
## StandardMaterial3D con triplanar en espacio mundial (uv1_world_triplanar) o el ShaderMaterial de fachada.
## Las texturas las genera scripts/generar_texturas.py en res://assets/texturas/. Se aplica por NOMBRE de material.

const DIR_TEX := "res://assets/texturas/"
const SHADER_FACHADA := "res://shaders/fachada.gdshader"
const SHADER_VALLA := "res://shaders/valla.gdshader"

## material del glb -> [textura, metros por tesela de 512 px, tinte, roughness, metallic]
const TRIPLANAR := {
	"suelo": ["albero", 4.0, Color.WHITE, 0.95, 0.0],
	"camino_asfalto": ["asfalto", 4.0, Color.WHITE, 0.88, 0.0],
	"camino_peatonal": ["baldosa", 3.2, Color.WHITE, 0.85, 0.0],
	"verde": ["cesped", 3.0, Color.WHITE, 0.95, 0.0],
	"pista": ["pista", 4.0, Color.WHITE, 0.8, 0.0],
	"agua": ["agua", 6.0, Color.WHITE, 0.12, 0.0],
	"aparcamiento": ["aparcamiento", 4.0, Color.WHITE, 0.88, 0.0],
	"muros": ["hormigon", 3.0, Color(1.05, 1.0, 0.92), 0.92, 0.0],
	"pilar": ["hormigon", 3.0, Color.WHITE, 0.92, 0.0],
	"cubierta": ["hormigon", 3.0, Color(0.62, 0.64, 0.7), 0.9, 0.0],
	"campo": ["campo", 10.0, Color.WHITE, 1.0, 0.0],
}

## materiales del glb que se conservan (color y transparencia) ajustando solo el brillo: nombre -> [roughness, metallic]
const AJUSTES := {
	"arbol_corteza": [1.0, 0.0], "arbol_copa_1": [0.95, 0.0], "arbol_copa_2": [0.95, 0.0], "arbol_copa_3": [0.95, 0.0],
	"coche_cristal": [0.08, 0.3], "coche_goma": [0.95, 0.0],
	"valla_metal": [0.45, 0.6], "vallas": [0.8, 0.0],
}
const AJUSTE_COCHE := [0.3, 0.45]   # el resto de coche_* (carrocerias)

## materiales translúcidos: sus mallas no proyectan sombra (si no, la valla/pádel dejan una mancha oscura en el suelo)
const SIN_SOMBRA := ["valla_malla", "cristal_padel", "limite", "coche_cristal"]

const FACHADAS := {
	"edificio": Color(200.0 / 255.0, 200.0 / 255.0, 205.0 / 255.0),
	"torre": Color(150.0 / 255.0, 120.0 / 255.0, 105.0 / 255.0),
}

static var _cache: Dictionary = {}


## Recorre todas las MeshInstance3D bajo `raiz` y sustituye los materiales. Devuelve cuántas superficies cambió.
static func aplicar(raiz: Node) -> int:
	var n := 0
	for nodo: Node in raiz.find_children("*", "MeshInstance3D", true, false):
		var mi := nodo as MeshInstance3D
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var orig: Material = mi.mesh.surface_get_material(i)
			if orig == null:
				continue
			if String(orig.resource_name) in SIN_SOMBRA:
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var nuevo: Material = _material_para(String(orig.resource_name), orig)
			if nuevo != null:
				mi.set_surface_override_material(i, nuevo)
				n += 1
	return n


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
