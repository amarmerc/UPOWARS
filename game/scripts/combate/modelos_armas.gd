class_name ModelosArmas
extends RefCounted
## Modelos 3D externos de las armas (Quaternius LowPoly Guns y Medieval Weapons, CC0; sable de DeathKing680). Un solo punto
## convierte el fichero original (FBX en "centimetros": la raiz trae escala 100 y las armas miden ~5 unidades) a un nodo
## normalizado: el CANON apunta a -Z, el origen esta en la empunadura (x = `agarre` del largo contando desde la culata; y = eje del
## canon), la altura va en +Y y el largo real en metros (`largo`). Metadatos del nodo devuelto:
##   "boca": Vector3 punto de la boca del canon (fogonazo / trazadora), "atras": float cuanto sobresale hacia +Z (culata).
## Si el fichero no existe o no carga, `crear` devuelve null y quien lo llama usa el modelo procedural (fallback).
## Orientacion de los FBX (comprobada): canon hacia +X, arriba +Y. Para convertir uno nuevo basta una entrada en CONFIG.

const DIR: String = "res://assets/externos/armas/"
const RUTA_SABLE: String = "res://assets/externos/armas/light-saber.glb"

## id del articulo -> {f: fichero, largo: m (de culata a boca), agarre: fraccion 0..1 desde la culata donde esta la mano trasera,
## extra: [{f, fx (fraccion x del arma donde se pega), y (cota y bruta), ...}]}. Un modelo distinto por arma (sin repetir).
const CONFIG: Dictionary = {
	&"pistola_9mm": {"f": "Pistol_2.fbx", "largo": 0.20, "agarre": 0.28},
	&"pistola_auto": {"f": "Pistol_6.fbx", "largo": 0.25, "agarre": 0.22},
	&"pistola_pesada": {"f": "Pistol_4.fbx", "largo": 0.25, "agarre": 0.3},
	&"revolver_357": {"f": "Revolver_2.fbx", "largo": 0.25, "agarre": 0.2},
	&"escopeta_recortada": {"f": "Shotgun_SawedOff.fbx", "largo": 0.46, "agarre": 0.25},
	&"subfusil_compacto": {"f": "SubmachineGun_1.fbx", "largo": 0.30, "agarre": 0.5},
	&"subfusil_9mm": {"f": "SubmachineGun_2.fbx", "largo": 0.56, "agarre": 0.45},
	&"subfusil_45": {"f": "SubmachineGun_4.fbx", "largo": 0.38, "agarre": 0.5},
	&"escopeta_corredera": {"f": "Shotgun_2.fbx", "largo": 1.0, "agarre": 0.3},
	&"escopeta_auto": {"f": "Bullpup_3.fbx", "largo": 0.72, "agarre": 0.55},
	&"carabina_556": {"f": "AssaultRifle2_4.fbx", "largo": 0.62, "agarre": 0.4},
	&"fusil_asalto": {"f": "AssaultRifle2_1.fbx", "largo": 0.9, "agarre": 0.38},
	&"fusil_combate": {"f": "AssaultRifle_2.fbx", "largo": 0.95, "agarre": 0.38},
	&"fusil_tirador": {"f": "SniperRifle_2.fbx", "largo": 1.1, "agarre": 0.32},
	&"fusil_precision": {"f": "SniperRifle_1.fbx", "largo": 1.15, "agarre": 0.3},
	&"ametralladora": {"f": "Bullpup_1.fbx", "largo": 0.95, "agarre": 0.5,
			"extra": [{"f": "acc/Bipod.fbx", "fx": 0.82, "y": 0.28, "z": 0.0}]},
	&"arco_olivo": {"f": "Bow_Evil.fbx", "largo": 1.0, "agarre": 0.5, "arco": true},
}


static func tiene(id: StringName) -> bool:
	return CONFIG.has(id)


static func _cargar(ruta: String) -> Node3D:
	if not ResourceLoader.exists(ruta):
		return null
	var esc: PackedScene = load(ruta) as PackedScene
	if esc == null:
		return null
	return esc.instantiate() as Node3D


## AABB (en el espacio de `n`, sin contar su propia transformacion) de todas las mallas descendientes.
static func aabb_de(n: Node, xf: Transform3D = Transform3D.IDENTITY) -> AABB:
	var acc: Array = [null]
	_acumular(n, xf, acc)
	return acc[0] if acc[0] != null else AABB()


static func _acumular(n: Node, xf: Transform3D, acc: Array) -> void:
	for c: Node in n.get_children():
		if c is Node3D:
			var t: Transform3D = xf * (c as Node3D).transform
			if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
				var ab: AABB = t * (c as MeshInstance3D).get_aabb()
				acc[0] = ab if acc[0] == null else (acc[0] as AABB).merge(ab)
			_acumular(c, t, acc)


## Vertices (en el espacio de `n`) con x >= x_min: sirve para localizar la boca del canon.
static func _vertices_x(n: Node, xf: Transform3D, x_min: float, salida: PackedVector3Array) -> void:
	for c: Node in n.get_children():
		if c is Node3D:
			var t: Transform3D = xf * (c as Node3D).transform
			if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
				for v: Vector3 in (c as MeshInstance3D).mesh.get_faces():
					var w: Vector3 = t * v
					if w.x >= x_min:
						salida.append(w)
			_vertices_x(c, t, x_min, salida)


## Modelo normalizado del arma `id` (null si no hay modelo o el fichero falta).
static func crear(id: StringName) -> Node3D:
	var c: Dictionary = CONFIG.get(id, {})
	if c.is_empty():
		return null
	var inst: Node3D = _cargar(DIR + String(c["f"]))
	if inst == null:
		return null
	var b: AABB = aabb_de(inst)
	if b.size.x <= 0.0001:
		inst.free()
		return null
	if bool(c.get("arco", false)):
		return _normalizar_arco(inst, b, float(c["largo"]))
	var s: float = float(c["largo"]) / b.size.x
	var raiz := Node3D.new()
	raiz.name = "Modelo_" + String(id)
	# accesorios (bipode...) en coordenadas brutas del arma
	for e: Dictionary in c.get("extra", []):
		var acc: Node3D = _cargar(DIR + String(e["f"]))
		if acc != null:
			acc.position = Vector3(b.position.x + float(e["fx"]) * b.size.x, float(e["y"]), float(e.get("z", 0.0)))
			inst.add_child(acc)
	var vs := PackedVector3Array()
	_vertices_x(inst, Transform3D.IDENTITY, b.end.x - b.size.x * 0.03, vs)
	var boca_y: float = b.get_center().y
	var boca_z: float = b.get_center().z
	if vs.size() > 0:
		var sy: float = 0.0
		var sz: float = 0.0
		for v: Vector3 in vs:
			sy += v.y
			sz += v.z
		boca_y = sy / vs.size()
		boca_z = sz / vs.size()
	var ox: float = b.position.x + float(c["agarre"]) * b.size.x
	# p' = R(y,+90) * S * (p - o): canon +X -> -Z, y arriba, z bruta (ancho) -> x
	var rot := Basis(Vector3.UP, PI * 0.5)
	var bs: Basis = rot * Basis.from_scale(Vector3.ONE * s)
	var origen_bruto := Vector3(ox, boca_y, b.get_center().z)
	inst.transform = Transform3D(bs, -(bs * origen_bruto))
	raiz.add_child(inst)
	var ab: AABB = aabb_de(raiz)
	raiz.set_meta("boca", Vector3(0.0, 0.0, -(b.end.x - ox) * s))
	raiz.set_meta("atras", maxf(ab.end.z, 0.0))
	raiz.set_meta("alto_abajo", -ab.position.y)
	raiz.set_meta("largo", float(c["largo"]))
	return raiz


## Arco: el modelo es vertical (eje Y), con la cuerda en +X; la flecha sale hacia -X. Se gira para que salga hacia -Z.
static func _normalizar_arco(inst: Node3D, b: AABB, largo: float) -> Node3D:
	var s: float = largo / b.size.y
	var raiz := Node3D.new()
	raiz.name = "Modelo_arco"
	var rot := Basis(Vector3.UP, -PI * 0.5)
	var bs: Basis = rot * Basis.from_scale(Vector3.ONE * s)
	var centro := b.get_center()
	inst.transform = Transform3D(bs, -(bs * centro))
	raiz.add_child(inst)
	var ab: AABB = aabb_de(raiz)
	raiz.set_meta("boca", Vector3(0.0, 0.0, ab.position.z))
	raiz.set_meta("atras", maxf(ab.end.z, 0.0))
	raiz.set_meta("alto_abajo", -ab.position.y)
	raiz.set_meta("largo", largo)
	# la mitad del arco que sobresale hacia la cuerda (+X bruto -> +Z) marca donde se cuelga la cuerda
	raiz.set_meta("cuerda_z", ab.end.z)
	raiz.set_meta("cuerda_y", ab.size.y * 0.5)
	return raiz


## Flecha normalizada (punta hacia -Z, origen en el centro) de `largo` m; null si falta el fichero.
static func crear_flecha(largo: float = 0.65) -> Node3D:
	var inst: Node3D = _cargar(DIR + "Arrow.fbx")
	if inst == null:
		return null
	var b: AABB = aabb_de(inst)
	if b.size.z <= 0.0001:
		inst.free()
		return null
	# el eje largo es Z; las plumas rojas marcan la cola
	var cola_z: float = b.position.z
	var z_rojo: float = INF
	for m: Node in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		for i: int in mi.mesh.get_surface_count():
			var mat: Material = mi.mesh.surface_get_material(i)
			if mat != null and mat.resource_name == "Red":
				var ab: AABB = aabb_de(inst)  # (cota gruesa; basta el lado del extremo)
				z_rojo = ab.get_center().z
	var s: float = largo / b.size.z
	var raiz := Node3D.new()
	raiz.name = "Flecha"
	# punta hacia +Z bruto (se comprueba abajo); la giramos para que apunte a -Z
	var rot := Basis(Vector3.UP, PI)
	var bs: Basis = rot * Basis.from_scale(Vector3.ONE * s)
	inst.transform = Transform3D(bs, -(bs * b.get_center()))
	raiz.add_child(inst)
	raiz.set_meta("cola_z", cola_z + 0.0 * z_rojo)
	return raiz


## Sable de plasma: empunadura + hoja del glb (la hoja apunta a -Z, origen en el centro de la empunadura). Devuelve el nodo; en
## sus metadatos: "hoja" (MeshInstance3D de la hoja), "mat_hoja" (StandardMaterial3D propio para recolorear),
## "largo_hoja" (m), "pos_hoja" (Vector3, base de la hoja). null si falta el glb.
static func crear_sable() -> Node3D:
	var inst: Node3D = _cargar(RUTA_SABLE)
	if inst == null:
		return null
	# no usamos la animacion del glb (27 s de apertura de tapas): el encendido es una animacion propia de la hoja
	for ap: Node in inst.find_children("*", "AnimationPlayer", true, false):
		ap.queue_free()
	var hoja: MeshInstance3D = null
	for m: Node in inst.find_children("*", "MeshInstance3D", true, false):
		if (m as MeshInstance3D).skin != null:
			hoja = m as MeshInstance3D
	# empunadura: x bruta -2.03..1.54 (eje largo X, canon hacia -X), centro ~ (-0.25, 0.84, 3.7)
	const EMPU_LARGO: float = 3.47
	const BASE_X: float = -2.03
	var s: float = 0.30 / EMPU_LARGO
	var raiz := Node3D.new()
	raiz.name = "Modelo_sable"
	var rot := Basis(Vector3.UP, -PI * 0.5)
	var bs: Basis = rot * Basis.from_scale(Vector3.ONE * s)
	var centro := Vector3(-0.25, 0.84, 3.69)
	inst.transform = Transform3D(bs, -(bs * centro))
	raiz.add_child(inst)
	if hoja != null:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.2, 0.85, 1.0)
		mat.emission_enabled = true
		mat.emission = Color(0.2, 0.85, 1.0)
		mat.emission_energy_multiplier = 2.4
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		hoja.material_override = mat
		raiz.set_meta("hoja", hoja)
		raiz.set_meta("mat_hoja", mat)
	# la hoja nace en la boca de la empunadura (x bruta = BASE_X) y mide ~8 unidades brutas
	raiz.set_meta("pos_hoja", Vector3(0.0, 0.0, -(BASE_X - centro.x) * s * -1.0))
	raiz.set_meta("largo_hoja", 8.0 * s)
	return raiz
