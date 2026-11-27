class_name CochesExternos
extends RefCounted
## Coches del mapa con los modelos del pack "Generic Passenger Car Pack" (Sketchfab, Comrade1280; licencia CC-BY).
## El blockout (cajas) sigue en el glb del mapa SOLO por su colision (nodos `coches_*-col`); aqui se oculta su malla y se dibujan
## los coches reales en las mismas posiciones / giros / inclinaciones (`res://data/coches.json`, copia de export/coches.json).
##
## Rendimiento (1.359 coches de ~7.000 triangulos): una `MultiMesh` por (celda de 80 m x modelo) con rango de visibilidad;
## mas alla de DIST_DETALLE se dibuja una version de cajas (~50 triangulos, `MultiMesh` por celda). Los 10 modelos del pack se
## fusionan en una malla cada uno (carroceria + cristal + faros + 4 ruedas) con el origen en el centro del coche a ras de suelo y el
## morro hacia -Z (como el blockout). Cada coche elige modelo y pintura de forma determinista (semilla + id): la pintura de la
## carroceria se recolorea en un shader (zonas saturadas de la textura -> color de `coches.json`), y una parte conserva su pintura
## original (colores vivos del pack).

const RUTA_PACK: String = "res://assets/externos/coches/generic_passenger_car_pack.glb"
const RUTA_JSON: String = "res://data/coches.json"
const DIST_DETALLE: float = 120.0
const CELDA: float = 80.0
const FRACCION_ORIGINAL: float = 0.3
const LARGO_BLOCKOUT: float = 4.4
## Nodos del pack que son una carroceria (el resto de partes se agrupa con ella por nombre o cercania).
const CARROCERIAS: Array[String] = ["Compact Body", "Coupe Body", "Hatchback Body", "minivan body", "Offroad Body", "Pickup Body",
		"Sedan Body", "Sport body", "SUV Body", "Wagon Body"]
## Pinturas de coches.json (mismos RGB que scripts/coches.py).
const PINTURAS: Dictionary = {
	"blanco": Color8(205, 205, 202), "gris": Color8(122, 124, 128), "negro": Color8(38, 39, 42),
	"rojo_oscuro": Color8(124, 36, 36), "azul_oscuro": Color8(34, 52, 98), "plata": Color8(170, 174, 180)}
## Si es false se dibuja el blockout de siempre (para comparar rendimiento).
static var activado: bool = true

static var _modelos: Array = []
static var _proxy: ArrayMesh = null
static var _mat_pintura: Shader = null


## Dibuja los coches de `res://data/coches.json` bajo `padre` y oculta las mallas del blockout. Devuelve {coches, modelos, multimallas}.
static func montar(padre: Node3D, semilla: int = 1) -> Dictionary:
	var vacio: Dictionary = {"coches": 0, "modelos": 0, "multimallas": 0}
	if not activado or not ResourceLoader.exists(RUTA_PACK) or not FileAccess.file_exists(RUTA_JSON):
		return vacio
	var datos: Variant = JSON.parse_string(FileAccess.get_file_as_string(RUTA_JSON))
	if not (datos is Dictionary) or not (datos as Dictionary).has("coches"):
		return vacio
	var modelos: Array = _construir_modelos()
	if modelos.is_empty():
		return vacio
	for h: Node in padre.find_children("coches_*", "MeshInstance3D", true, false):
		(h as MeshInstance3D).visible = false   # la colision (StaticBody3D hijo) se mantiene
	var raiz := Node3D.new()
	raiz.name = "CochesExternos"
	padre.add_child(raiz)
	# agrupa por celda y modelo
	var grupos: Dictionary = {}
	for c: Dictionary in (datos as Dictionary)["coches"]:
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(str(semilla) + "_" + str(int(c["id"])))
		var m: int = rng.randi() % modelos.size()
		var original: bool = rng.randf() < FRACCION_ORIGINAL
		var p: Array = c["pos"]
		var clave := Vector3i(floori(float(p[0]) / CELDA), floori(float(p[2]) / CELDA), m)
		if not grupos.has(clave):
			grupos[clave] = []
		(grupos[clave] as Array).append([c, original])
	var n_mm: int = 0
	var celdas: Dictionary = {}   # (cx, cz) -> lista para las cajas lejanas
	for clave: Vector3i in grupos.keys():
		var lista: Array = grupos[clave]
		var modelo: Dictionary = modelos[clave.z]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = modelo["mesh"]
		mm.instance_count = lista.size()
		for i: int in lista.size():
			var c: Dictionary = (lista[i] as Array)[0]
			mm.set_instance_transform(i, _transform_coche(c, modelo))
			mm.set_instance_color(i, _pintura(str(c["color"]), bool((lista[i] as Array)[1])))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Coches_%d_%d_m%d" % [clave.x, clave.y, clave.z]
		mmi.multimesh = mm
		mmi.visibility_range_end = DIST_DETALLE
		raiz.add_child(mmi)
		n_mm += 1
		var cc := Vector2i(clave.x, clave.y)
		if not celdas.has(cc):
			celdas[cc] = []
		(celdas[cc] as Array).append_array(lista)
	for cc: Vector2i in celdas.keys():
		var lista2: Array = celdas[cc]
		var mm2 := MultiMesh.new()
		mm2.transform_format = MultiMesh.TRANSFORM_3D
		mm2.use_colors = true
		mm2.mesh = _malla_cajas()
		mm2.instance_count = lista2.size()
		for i: int in lista2.size():
			var c2: Dictionary = (lista2[i] as Array)[0]
			mm2.set_instance_transform(i, _transform_coche(c2, {"escala": 1.0}))
			mm2.set_instance_color(i, _pintura(str(c2["color"]), false))
		var mmi2 := MultiMeshInstance3D.new()
		mmi2.name = "CochesLejos_%d_%d" % [cc.x, cc.y]
		mmi2.multimesh = mm2
		mmi2.visibility_range_begin = DIST_DETALLE
		mmi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		raiz.add_child(mmi2)
		n_mm += 1
	return {"coches": (datos as Dictionary)["coches"].size(), "modelos": modelos.size(), "multimallas": n_mm}


## Cambia entre los coches del pack (true) y el blockout de cajas (false) sin recargar el mapa (comparar rendimiento).
static func alternar(padre: Node3D, externos: bool) -> void:
	var raiz: Node = padre.find_child("CochesExternos", true, false)
	if raiz is Node3D:
		(raiz as Node3D).visible = externos
	for h: Node in padre.find_children("coches_*", "MeshInstance3D", true, false):
		(h as MeshInstance3D).visible = not externos


## Pinturas: color de `coches.json` (en lineal) con alfa 1 = recolorear; alfa 0 = conservar la pintura original del modelo.
static func _pintura(nombre: String, original: bool) -> Color:
	var c: Color = (PINTURAS.get(nombre, Color(0.5, 0.5, 0.5)) as Color).srgb_to_linear()
	c.a = 0.0 if original else 1.0
	return c


## Transformacion del coche: giro Y, luego inclinacion segun el terreno (misma base que scripts/coches.py: _bases).
static func _transform_coche(c: Dictionary, modelo: Dictionary) -> Transform3D:
	var sx: float = tan(deg_to_rad(float(c["roll_deg"])))
	var sz: float = tan(deg_to_rad(float(c["pitch_deg"])))
	var ex := Vector3(1.0, sx, 0.0)
	var ez := Vector3(0.0, sz, 1.0)
	var ey: Vector3 = ez.cross(ex).normalized()
	ex = ey.cross(ez).normalized()
	ez = ez.normalized()
	var b := Basis(ex, ey, ez)
	var p: Array = c["pos"]
	var esc: float = float(modelo.get("escala", 1.0))
	return Transform3D(Basis(Vector3.UP, deg_to_rad(float(c["yaw_deg"]))) * b * Basis.from_scale(Vector3.ONE * esc),
			Vector3(float(p[0]), float(p[1]), float(p[2])))


# ------------------------------------------------------------------ modelos

static func _construir_modelos() -> Array:
	if not _modelos.is_empty():
		return _modelos
	var esc: PackedScene = load(RUTA_PACK) as PackedScene
	if esc == null:
		return []
	var inst: Node3D = esc.instantiate() as Node3D
	var partes: Array = []   # [{nombre, malla, xf}]
	_recoger(inst, Transform3D.IDENTITY, partes)
	var carrocerias: Dictionary = {}
	for p: Dictionary in partes:
		var nombre: String = p["nombre"]
		for k: String in CARROCERIAS:
			if nombre == k + "_Body_0":
				var ab: AABB = (p["xf"] as Transform3D) * (p["malla"] as Mesh).get_aabb()
				carrocerias[k] = {"aabb": ab, "partes": {"cuerpo": p, "cristal": null, "faros": null}, "ruedas": []}
	for p: Dictionary in partes:
		var nombre2: String = p["nombre"]
		for k: String in carrocerias.keys():
			if nombre2 == k + "_Glass_0":
				carrocerias[k]["partes"]["cristal"] = p
			elif nombre2 == k + "_Optics_0":
				carrocerias[k]["partes"]["faros"] = p
		if nombre2.begins_with("Wheel_") and not nombre2.contains("_Body_"):
			var ab2: AABB = (p["xf"] as Transform3D) * (p["malla"] as Mesh).get_aabb()
			var c2: Vector3 = ab2.get_center()
			var mejor: String = ""
			var d_mejor: float = INF
			for k2: String in carrocerias.keys():
				var cb: AABB = (carrocerias[k2]["aabb"] as AABB).grow(0.8)
				if c2.x >= cb.position.x and c2.x <= cb.end.x and c2.z >= cb.position.z and c2.z <= cb.end.z:
					var d: float = Vector2(c2.x, c2.z).distance_to(Vector2((carrocerias[k2]["aabb"] as AABB).get_center().x,
							(carrocerias[k2]["aabb"] as AABB).get_center().z))
					if d < d_mejor:
						d_mejor = d
						mejor = k2
			if mejor != "":
				(carrocerias[mejor]["ruedas"] as Array).append(p)
	var res: Array = []
	for k3: String in CARROCERIAS:
		if not carrocerias.has(k3):
			continue
		var m: Dictionary = _fusionar(carrocerias[k3])
		if not m.is_empty():
			res.append(m)
	inst.free()
	_modelos = res
	return res


static func _recoger(n: Node, xf: Transform3D, salida: Array) -> void:
	for c: Node in n.get_children():
		if not (c is Node3D):
			continue
		var t: Transform3D = xf * (c as Node3D).transform
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			salida.append({"nombre": String(c.name), "malla": (c as MeshInstance3D).mesh, "xf": t})
		_recoger(c, t, salida)


## Malla fusionada de un coche. En el pack el eje largo es Z; el origen queda en el centro a ras de suelo.
static func _fusionar(d: Dictionary) -> Dictionary:
	var ruedas: Array = d["ruedas"]
	var cuerpo: Dictionary = d["partes"]["cuerpo"]
	var caja: AABB = d["aabb"]
	var suelo: float = caja.position.y
	for r: Dictionary in ruedas:
		suelo = minf(suelo, ((r["xf"] as Transform3D) * (r["malla"] as Mesh).get_aabb()).position.y)
	var centro := Vector3(caja.get_center().x, suelo, caja.get_center().z)
	var largo: float = caja.size.z
	# normaliza la longitud a ~4,4 m (sin deformar demasiado)
	var escala: float = clampf(LARGO_BLOCKOUT / largo, 0.88, 1.12)
	# el pack pone el morro hacia +Z (se gira 180 grados para que mire a -Z)
	var base := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO) * Transform3D(Basis.IDENTITY, -centro)
	var mat_cuerpo: Material = (cuerpo["malla"] as Mesh).surface_get_material(0)
	var st_cuerpo := SurfaceTool.new()
	st_cuerpo.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_cuerpo.append_from(cuerpo["malla"], 0, base * (cuerpo["xf"] as Transform3D))
	var st_cristal := SurfaceTool.new()
	st_cristal.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cr: Variant = d["partes"]["cristal"]
	if cr != null:
		st_cristal.append_from((cr as Dictionary)["malla"], 0, base * ((cr as Dictionary)["xf"] as Transform3D))
	var st_faros := SurfaceTool.new()
	st_faros.begin(Mesh.PRIMITIVE_TRIANGLES)
	var fa: Variant = d["partes"]["faros"]
	var mat_faros: Material = null
	if fa != null:
		st_faros.append_from((fa as Dictionary)["malla"], 0, base * ((fa as Dictionary)["xf"] as Transform3D))
		mat_faros = ((fa as Dictionary)["malla"] as Mesh).surface_get_material(0)
	var st_rueda := SurfaceTool.new()
	st_rueda.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat_rueda: Material = null
	for r2: Dictionary in ruedas:
		st_rueda.append_from(r2["malla"], 0, base * (r2["xf"] as Transform3D))
		mat_rueda = (r2["malla"] as Mesh).surface_get_material(0)
	var malla := ArrayMesh.new()
	st_cuerpo.commit(malla)
	malla.surface_set_material(malla.get_surface_count() - 1, _material_pintura(mat_cuerpo))
	if cr != null:
		st_cristal.commit(malla)
		malla.surface_set_material(malla.get_surface_count() - 1, _material_cristal())
	if fa != null:
		st_faros.commit(malla)
		malla.surface_set_material(malla.get_surface_count() - 1, mat_faros)
	if not ruedas.is_empty():
		st_rueda.commit(malla)
		malla.surface_set_material(malla.get_surface_count() - 1, mat_rueda)
	# la escala se aplica en la transformacion de cada instancia
	return {"mesh": malla, "escala": escala, "largo": largo * escala}


static func _material_cristal() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.05, 0.07, 0.1)
	m.metallic = 0.6
	m.roughness = 0.12
	return m


## Material de la carroceria: textura del pack + recoloreado de las zonas saturadas con el color de instancia (alfa 1).
static func _material_pintura(orig: Material) -> Material:
	if not (orig is StandardMaterial3D) or (orig as StandardMaterial3D).albedo_texture == null:
		return orig
	if _mat_pintura == null:
		_mat_pintura = Shader.new()
		_mat_pintura.code = """
shader_type spatial;
uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float lum_ref = 0.2;
uniform float metalico = 0.4;
uniform float rugosidad = 0.38;
varying vec4 pint;
void vertex() { pint = COLOR; }
void fragment() {
	vec3 c = texture(tex, UV).rgb;
	float mx = max(c.r, max(c.g, c.b));
	float mn = min(c.r, min(c.g, c.b));
	float sat = (mx - mn) / max(mx, 0.0001);
	float masc = smoothstep(0.35, 0.7, sat) * pint.a;
	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	vec3 nuevo = pint.rgb * clamp(lum / lum_ref, 0.0, 2.0) * 1.6;
	ALBEDO = mix(c, nuevo, masc);
	METALLIC = metalico;
	ROUGHNESS = rugosidad;
}
"""
	var m := ShaderMaterial.new()
	m.shader = _mat_pintura
	var tex: Texture2D = (orig as StandardMaterial3D).albedo_texture
	m.set_shader_parameter("tex", tex)
	m.set_shader_parameter("lum_ref", _lum_pintura(tex))
	return m


## Luminancia media (lineal) de los pixeles saturados de la textura: referencia para repintar sin cambiar el brillo.
static func _lum_pintura(tex: Texture2D) -> float:
	var img: Image = tex.get_image()
	if img == null:
		return 0.2
	if img.is_compressed():
		img.decompress()
	img.resize(64, 64, Image.INTERPOLATE_BILINEAR)
	var suma: float = 0.0
	var n: int = 0
	for y: int in 64:
		for x: int in 64:
			var c: Color = img.get_pixel(x, y).srgb_to_linear()
			var mx: float = maxf(c.r, maxf(c.g, c.b))
			var mn: float = minf(c.r, minf(c.g, c.b))
			if mx > 0.0001 and (mx - mn) / mx > 0.5:
				suma += c.r * 0.299 + c.g * 0.587 + c.b * 0.114
				n += 1
	return maxf(suma / float(n), 0.02) if n > 0 else 0.2


## Version lejana: dos cajas (carroceria + cabina) con la pintura por color de instancia; sin sombra.
static func _malla_cajas() -> ArrayMesh:
	if _proxy != null:
		return _proxy
	var cuerpo := BoxMesh.new()
	cuerpo.size = Vector3(1.8, 0.75, 4.3)
	var cabina := BoxMesh.new()
	cabina.size = Vector3(1.6, 0.55, 2.2)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(cuerpo, 0, Transform3D(Basis.IDENTITY, Vector3(0, 0.62, 0)))
	var st2 := SurfaceTool.new()
	st2.begin(Mesh.PRIMITIVE_TRIANGLES)
	st2.append_from(cabina, 0, Transform3D(Basis.IDENTITY, Vector3(0, 1.28, 0.25)))
	_proxy = ArrayMesh.new()
	st.commit(_proxy)
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.metallic = 0.3
	m.roughness = 0.45
	_proxy.surface_set_material(0, m)
	st2.commit(_proxy)
	var mc := StandardMaterial3D.new()
	mc.albedo_color = Color(0.05, 0.07, 0.1)
	_proxy.surface_set_material(1, mc)
	return _proxy
