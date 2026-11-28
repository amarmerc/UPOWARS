class_name ModeloPersonaje
extends RefCounted
## PUNTO UNICO donde se construye el cuerpo de un personaje (bots en partida y retratos del lobby). Usa el pack externo
## "Ultimate Modular Men" de Quaternius (CC0): res://assets/externos/personajes/humans_master.fbx trae 12 conjuntos como piezas
## sueltas (Cabeza / Cuerpo / Piernas / Pies) sobre UN esqueleto de 79 huesos con 24 animaciones (Idle, Idle_Gun, Walk, Run,
## Run_Shoot, Gun_Shoot, Death...). Cada personaje de `CatalogoPersonajes` elige las piezas por nombre (se pueden mezclar conjuntos)
## y puede recolorear materiales (`colores`; hoy ninguno: se respeta el aspecto original). El color del equipo es un brazalete en cada
## brazo (material en el metadato "mat_equipo"). Mide 1,8 m (los hitboxes de `Hitboxes` siguen valiendo), origen en los pies, mira hacia -Z.
## Si el fbx no existe se usa el blockout de cajas de antes (fallback).
## Metadatos del nodo devuelto: "mat_equipo" (StandardMaterial3D), "anim" (AnimationPlayer), "mano" (BoneAttachment3D de la mano
## derecha, donde `poner_arma` cuelga el arma).

const RUTA_MASTER: String = "res://assets/externos/personajes/humans_master.fbx"
const PREFIJO_ANIM: String = "CharacterArmature|"
const HUESO_MANO: String = "Wrist.R"
## Escala de anchura (x, z) por silueta (solo el blockout).
const SILUETAS: Dictionary = {&"normal": 1.0, &"delgado": 0.86, &"robusto": 1.2, &"alto": 0.96}
## Animaciones en bucle del pack.
const BUCLE: Array[String] = ["Idle", "Idle_Gun", "Idle_Gun_Pointing", "Idle_Neutral", "Walk", "Run", "Run_Back", "Run_Left",
		"Run_Right", "Run_Shoot"]
const BRAZALETE_RADIO: float = 0.065
const BRAZALETE_POS: Vector3 = Vector3(0.0, 0.12, 0.0)
const VEL_ANDAR: float = 0.25
const VEL_CORRER: float = 3.2
## Orientacion del arma respecto al hueso de la muneca derecha (ajustada a ojo con capturas).
## "rot": giro del arma en la mano; "pos": desplazamiento en ejes del arma (m; -Z = hacia la boca); "esc": 0.01 compensa la escala 100 del esqueleto.
static var AJUSTE_MANO: Dictionary = {"rot": Vector3(0.0, PI * 0.5, 0.0), "pos": Vector3(0.0, 0.0, -0.12), "esc": 0.01}


## Cuerpo del personaje `p` (diccionario de `CatalogoPersonajes`) con brazaletes del color de equipo `color_equipo`. `con_arma` deja
## el hueco de la mano para `poner_arma`; `tintar` = false no pone brazaletes (retratos del lobby).
static func crear(p: Dictionary, color_equipo: Color, con_arma: bool = true, tintar: bool = true) -> Node3D:
	var raiz := Node3D.new()
	raiz.name = "Cuerpo"
	if ResourceLoader.exists(RUTA_MASTER) and p.has("cabeza"):
		var esc: PackedScene = load(RUTA_MASTER) as PackedScene
		if esc != null:
			_montar(raiz, esc.instantiate() as Node3D, p, color_equipo, con_arma, tintar)
			return raiz
	_blockout(raiz, p, color_equipo, con_arma)
	return raiz


static func _montar(raiz: Node3D, inst: Node3D, p: Dictionary, color_equipo: Color, con_arma: bool, tintar: bool) -> void:
	var sk: Skeleton3D = inst.find_child("Skeleton3D", true, false) as Skeleton3D
	var quedan: Array[String] = [String(p["cabeza"]), String(p["cuerpo"]), String(p["piernas"]), String(p["pies"])]
	for extra: String in p.get("extras", []):
		quedan.append(extra)
	var cambios: Dictionary = p.get("colores", {})
	var repl: Dictionary = {}   # material original -> copia propia de este personaje
	for hijo: Node in sk.get_children():
		if not (hijo is MeshInstance3D):
			continue
		var mi: MeshInstance3D = hijo as MeshInstance3D
		if not quedan.has(String(mi.name)):
			sk.remove_child(mi)
			mi.free()
			continue
		for i: int in mi.mesh.get_surface_count():
			var orig: Material = mi.mesh.surface_get_material(i)
			if not (orig is StandardMaterial3D):
				continue
			var nombre: String = orig.resource_name
			if not repl.has(orig):
				var c: StandardMaterial3D = (orig as StandardMaterial3D).duplicate() as StandardMaterial3D
				if cambios.has(nombre):
					c.albedo_color = cambios[nombre]
				repl[orig] = c
			mi.set_surface_override_material(i, repl[orig])
	# el pack mira hacia +Z: se gira para que mire a -Z como el resto del juego
	inst.rotation.y = PI
	raiz.add_child(inst)
	var ap: AnimationPlayer = inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap != null:
		for nombre: String in ap.get_animation_list():
			var corto: String = nombre.trim_prefix(PREFIJO_ANIM)
			ap.get_animation(nombre).loop_mode = Animation.LOOP_LINEAR if BUCLE.has(corto) else Animation.LOOP_NONE
		raiz.set_meta("anim", ap)
		raiz.set_meta("estado_anim", &"idle")
		ap.play(PREFIJO_ANIM + ("Idle_Gun" if con_arma else "Idle"))
	if tintar and sk != null:
		_brazaletes(raiz, sk, color_equipo)
	if con_arma and sk != null and sk.find_bone(HUESO_MANO) >= 0:
		var ba := BoneAttachment3D.new()
		ba.name = "Mano"
		ba.bone_name = HUESO_MANO
		sk.add_child(ba)
		raiz.set_meta("mano", ba)


## Color del equipo: un brazalete en cada brazo (no se toca la ropa original). El material se guarda en "mat_equipo".
static func _brazaletes(raiz: Node3D, sk: Skeleton3D, color: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.6
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.35
	raiz.set_meta("mat_equipo", mat)
	for hueso: String in ["UpperArm.L", "UpperArm.R"]:
		if sk.find_bone(hueso) < 0:
			continue
		var ba := BoneAttachment3D.new()
		ba.name = "Brazalete_" + hueso.replace(".", "_")
		ba.bone_name = hueso
		sk.add_child(ba)
		var cont := Node3D.new()
		cont.scale = Vector3.ONE * 0.01   # compensa la escala 100 del esqueleto
		ba.add_child(cont)
		var m := MeshInstance3D.new()
		var cil := CylinderMesh.new()
		cil.top_radius = BRAZALETE_RADIO
		cil.bottom_radius = BRAZALETE_RADIO
		cil.height = 0.075
		cil.radial_segments = 10
		cil.rings = 1
		m.mesh = cil
		m.material_override = mat
		m.position = BRAZALETE_POS
		cont.add_child(m)


## Pone (o quita con null) el material de contorno como overlay de las mallas del cuerpo (sin tocar los materiales propios).
static func fijar_contorno(cuerpo: Node3D, mat: Material) -> void:
	var sk: Skeleton3D = cuerpo.find_child("Skeleton3D", true, false) as Skeleton3D
	var base: Node = sk if sk != null else cuerpo
	for h: Node in base.get_children():
		var mi: MeshInstance3D = h as MeshInstance3D
		if mi != null and not (mi.get_parent() is BoneAttachment3D):
			mi.material_overlay = mat


## Cuelga el arma `id` (modelo de `ModelosArmas`) de la mano del personaje; sin modelo (o sin mano) no pone nada.
static func poner_arma(cuerpo: Node3D, id: StringName) -> void:
	var ba: BoneAttachment3D = cuerpo.get_meta("mano", null) as BoneAttachment3D
	if ba == null or not is_instance_valid(ba):
		return
	if StringName(ba.get_meta("arma_id", &"")) == id:
		return
	ba.set_meta("arma_id", id)
	for h: Node in ba.get_children():
		ba.remove_child(h)
		h.queue_free()
	var m: Node3D = ModelosArmas.crear(id)
	if m == null:
		return
	var aj: Dictionary = AJUSTE_MANO
	var cont := Node3D.new()
	cont.name = "Arma"
	cont.transform = Transform3D(Basis.from_euler(aj["rot"]) * Basis.from_scale(Vector3.ONE * float(aj["esc"])), Vector3.ZERO)
	m.position = aj["pos"]
	cont.add_child(m)
	ba.add_child(cont)


## Elige la animacion segun la velocidad horizontal (m/s).
static func actualizar(cuerpo: Node3D, vel: float) -> void:
	var ap: AnimationPlayer = cuerpo.get_meta("anim", null) as AnimationPlayer
	if ap == null:
		return
	var estado: StringName = &"idle"
	var nombre: String = "Idle_Gun"
	if vel > VEL_CORRER:
		estado = &"correr"
		nombre = "Run"
	elif vel > VEL_ANDAR:
		estado = &"andar"
		nombre = "Walk"
	var actual: StringName = cuerpo.get_meta("estado_anim", &"idle")
	if actual == &"muerto":
		return
	if actual == &"disparo" and estado == &"idle" and ap.is_playing():
		return
	if actual == estado:
		return
	cuerpo.set_meta("estado_anim", estado)
	ap.play(PREFIJO_ANIM + nombre, 0.18)


## Un disparo: anima el gesto solo si esta parado (en movimiento la animacion de correr se mantiene).
static func disparar(cuerpo: Node3D) -> void:
	var ap: AnimationPlayer = cuerpo.get_meta("anim", null) as AnimationPlayer
	if ap == null or cuerpo.get_meta("estado_anim", &"idle") != &"idle":
		return
	ap.play(PREFIJO_ANIM + "Idle_Gun_Shoot", 0.05)
	cuerpo.set_meta("estado_anim", &"disparo")


## Muerte: animacion Death (se queda en el ultimo fotograma). Devuelve false si el modelo no tiene animaciones (blockout): el
## llamador lo tumba girandolo.
static func morir(cuerpo: Node3D) -> bool:
	var ap: AnimationPlayer = cuerpo.get_meta("anim", null) as AnimationPlayer
	if ap == null:
		return false
	cuerpo.set_meta("estado_anim", &"muerto")
	ap.play(PREFIJO_ANIM + "Death", 0.05)
	return true


## Vuelve a la pose de reposo tras morir.
static func revivir(cuerpo: Node3D) -> void:
	var ap: AnimationPlayer = cuerpo.get_meta("anim", null) as AnimationPlayer
	if ap == null:
		return
	cuerpo.set_meta("estado_anim", &"idle")
	ap.play(PREFIJO_ANIM + "Idle_Gun", 0.0)


## Pose estatica para los retratos (render de un solo fotograma): coloca el esqueleto en un fotograma de "Idle".
static func pose(cuerpo: Node3D, t: float = 0.4) -> void:
	var ap: AnimationPlayer = cuerpo.get_meta("anim", null) as AnimationPlayer
	if ap != null:
		ap.play(PREFIJO_ANIM + "Idle")
		ap.seek(t, true)
		ap.pause()


static func _blockout(raiz: Node3D, p: Dictionary, color_equipo: Color, con_arma: bool) -> void:
	var s: float = float(SILUETAS.get(p.get("silueta", &"normal"), 1.0))
	var ropa: Color = p.get("ropa", Color(0.5, 0.5, 0.55))
	var piel: Color = p.get("piel", Color(0.9, 0.75, 0.62))
	var pelo: Color = p.get("pelo", Color(0.2, 0.15, 0.1))
	_caja(raiz, Vector3(0.42 * s, 0.84, 0.24 * s), Vector3(0, 0.42, 0), ropa.darkened(0.5))
	_caja(raiz, Vector3(0.54 * s, 0.62, 0.28 * s), Vector3(0, 1.15, 0), ropa)
	_caja(raiz, Vector3(0.12, 0.5, 0.14), Vector3(0.3 * s, 1.14, 0), ropa)
	_caja(raiz, Vector3(0.12, 0.5, 0.14), Vector3(-0.3 * s, 1.14, 0), ropa)
	var chaleco: MeshInstance3D = _caja(raiz, Vector3(0.58 * s, 0.34, 0.32 * s), Vector3(0, 1.2, 0), color_equipo)
	raiz.set_meta("mat_equipo", chaleco.material_override)
	if con_arma:
		_caja(raiz, Vector3(0.1, 0.12, 0.55), Vector3(0.2, 1.2, -0.3), Color(0.12, 0.12, 0.14))
	var cabeza := MeshInstance3D.new()
	var esf := SphereMesh.new()
	esf.radius = 0.13
	esf.height = 0.26
	cabeza.mesh = esf
	cabeza.material_override = _material(piel)
	cabeza.position = Vector3(0, 1.6, 0)
	raiz.add_child(cabeza)
	_peinado(raiz, StringName(p.get("peinado", &"calvo")), pelo)


static func _peinado(raiz: Node3D, tipo: StringName, pelo: Color) -> void:
	match tipo:
		&"corto", &"largo", &"mono":
			var cas := MeshInstance3D.new()
			var e := SphereMesh.new()
			e.radius = 0.14
			e.height = 0.28
			cas.mesh = e
			cas.material_override = _material(pelo)
			cas.position = Vector3(0, 1.64, 0.015)
			cas.scale = Vector3(1.0, 0.7, 1.0)
			raiz.add_child(cas)
			if tipo == &"largo":
				_caja(raiz, Vector3(0.24, 0.32, 0.06), Vector3(0, 1.5, 0.12), pelo)
			elif tipo == &"mono":
				var m := MeshInstance3D.new()
				var b := SphereMesh.new()
				b.radius = 0.06
				b.height = 0.12
				m.mesh = b
				m.material_override = _material(pelo)
				m.position = Vector3(0, 1.76, 0.1)
				raiz.add_child(m)
		&"gorro":
			var g := MeshInstance3D.new()
			var c := CylinderMesh.new()
			c.top_radius = 0.13
			c.bottom_radius = 0.145
			c.height = 0.12
			g.mesh = c
			g.material_override = _material(pelo)
			g.position = Vector3(0, 1.7, 0)
			raiz.add_child(g)


static func _caja(padre: Node3D, tam: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = tam
	m.mesh = bm
	m.material_override = _material(color)
	m.position = pos
	padre.add_child(m)
	return m


static func _material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	return m
