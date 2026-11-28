class_name ManosViewmodel
extends RefCounted
## Manos y antebrazos low-poly de la primera persona (reemplazan a las manos-caja del viewmodel). Cada mano es un puño que
## agarra el objeto: dorso, 4 dedos (falange que rodea por delante + falange que vuelve por el lateral, con huecos entre dedos),
## pulgar de dos falanges, muñeca, puño de la manga y antebrazo hacia fuera de la pantalla. Se construyen en el espacio del arma;
## `tam` = (ancho, alto, fondo) del trozo de arma que agarran, centrado en la mano. El eje de la empuñadura es el Y local
## (`eje_z` = true gira la mano 90 grados para agarrar un guardamano horizontal, a lo largo de Z).
## Los materiales son compartidos: cambiar `albedo_color` de piel / manga los repinta todos (ver `ViewmodelCapa.poner_personaje`).
## Colores de piel (o guante) y manga de cada personaje de `CatalogoPersonajes`, sacados de los materiales de humans_master.fbx.

const COLORES_PERSONAJE: Dictionary = {
	&"caballo": [Color("ba9c79"), Color("878276")],
	&"ejecutivo": [Color("ba9c79"), Color("1d2329")],
	&"granjero": [Color("ba9c79"), Color("8d8870")],
	&"soldado": [Color("2b2926"), Color("474a51")],        # guantes negros
	&"mochilero": [Color("ba9c79"), Color("3e3921")],
	&"astronauta": [Color("2a3538"), Color("3b4b49")],     # guantes del traje
	&"estudiante": [Color("ba9c79"), Color("3f3152")],
	&"rey": [Color("ba9c79"), Color("383f4f")],
	&"obrero": [Color("ba9c79"), Color("a38610")],
	&"punk": [Color("ba9c79"), Color("202020")],
	&"playero": [Color("ba9c79"), Color("878276")],
	&"becario": [Color("ba9c79"), Color("878276")],
}
const COLORES_DEFECTO: Array = [Color("ba9c79"), Color("878276")]


## [piel, manga] del personaje `id`.
static func colores(id: StringName) -> Array:
	return COLORES_PERSONAJE.get(id, COLORES_DEFECTO)


static func _caja(padre: Node3D, tam: Vector3, pos: Vector3, mat: Material, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = tam
	m.mesh = bm
	m.material_override = mat
	m.position = pos
	m.rotation = rot
	padre.add_child(m)
	return m


## Mano (y antebrazo) que agarra un trozo de arma de tamaño `tam`. `izq` = mano izquierda (apoyo bajo el guardamano).
static func crear(tam: Vector3, izq: bool, piel: Material, manga: Material, eje_z: bool = false) -> Node3D:
	var raiz := Node3D.new()
	raiz.name = "ManoIzq" if izq else "ManoDer"
	var n := Node3D.new()
	raiz.add_child(n)
	var s: float = -1.0 if izq else 1.0           # +1: derecha, las puntas de los dedos asoman por el lado -x
	var w: float = maxf(tam.x, 0.06)
	var h: float = maxf(tam.y, 0.085)
	var d: float = maxf(tam.z, 0.075)
	# dorso de la mano (la cara que ve la camara) con un abultamiento en los nudillos
	_caja(n, Vector3(w * 1.02, h * 0.98, d * 0.46), Vector3(0.0, 0.0, d * 0.27), piel)
	_caja(n, Vector3(w * 0.9, h * 0.9, d * 0.1), Vector3(0.0, 0.0, d * 0.53), piel, Vector3(0.0, 0.0, 0.0))
	# cuatro dedos: falange que rodea el frente + falange que vuelve por el lado (el dedo corazon es el mas largo)
	var fh: float = h * 0.25
	var largos: Array[float] = [0.9, 1.0, 0.95, 0.8]
	for i: int in 4:
		var y: float = h * 0.5 - fh * (float(i) + 0.5)
		var k: float = largos[i]
		_caja(n, Vector3(w * 0.98, fh * 0.84, d * 0.28), Vector3(0.0, y, -d * 0.12), piel)
		_caja(n, Vector3(w * 0.27, fh * 0.8, d * 0.5 * k), Vector3(-s * w * 0.5, y, d * (0.02 - 0.0 * k) - d * 0.06 * (1.0 - k)), piel)
	# pulgar: dos falanges por encima de los dedos, en el mismo lado que las puntas
	_caja(n, Vector3(w * 0.24, h * 0.3, d * 0.5), Vector3(-s * w * 0.56, h * 0.42, -d * 0.0), piel, Vector3(0.0, -s * 0.18, 0.0))
	_caja(n, Vector3(w * 0.2, h * 0.24, d * 0.34), Vector3(-s * w * 0.5, h * 0.42, -d * 0.3), piel, Vector3(0.0, -s * 0.5, 0.0))
	# muneca, puño de la manga y antebrazo que se aleja hacia abajo y hacia el lado, fuera de la pantalla
	_caja(n, Vector3(w * 0.84, h * 0.78, d * 0.5), Vector3(0.0, -h * 0.02, d * 0.78), piel)
	var arranque: Vector3 = Vector3(0.0, -h * 0.03, d * 1.0)
	_caja(n, Vector3(w * 1.08, h * 0.98, 0.06), arranque + Vector3(0, 0, 0.025), manga)
	var largo: float = 0.7
	var dir: Vector3 = Vector3(s * 0.38, -0.28, 0.88).normalized()
	var ant := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(w * 1.0, h * 0.9, largo)
	ant.mesh = bm
	ant.material_override = manga
	ant.position = arranque + Vector3(0, 0, 0.05) + dir * (largo * 0.5)
	ant.basis = Basis.looking_at(dir, Vector3.UP)
	n.add_child(ant)
	if eje_z:
		raiz.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	return raiz
