class_name Balistica
extends RefCounted
## Resolucion de disparos hitscan, separada de la entrada y del dibujo.
## Todo son funciones estaticas: lo usan el gestor de armas del jugador, los bots y (a futuro) un servidor.
## El azar sale de un RandomNumberGenerator inyectado, asi que con la misma semilla el resultado se repite.

const CAPA_MUNDO: int = 1
const CAPA_HITBOX: int = 2
const MASCARA_DISPARO: int = CAPA_MUNDO | CAPA_HITBOX
## Velocidad horizontal (m/s) a partir de la cual la dispersion de movimiento es la maxima (carrera).
const VEL_DISPERSION_MAX: float = 5.0
## Por debajo de esta velocidad se considera "quieto".
const VEL_QUIETO: float = 0.5


## Semiangulo del cono de dispersion (grados) segun el estado del tirador.
static func dispersion(arma: ArmaDatos, velocidad: float, en_suelo: bool, agachado: bool) -> float:
	if not en_suelo:
		return arma.dispersion_aire
	var base: float = arma.dispersion_agachado if agachado else arma.dispersion_quieto
	var t: float = clampf((velocidad - VEL_QUIETO) / (VEL_DISPERSION_MAX - VEL_QUIETO), 0.0, 1.0)
	return base + (arma.dispersion_movimiento - arma.dispersion_quieto) * t


## Dano de un impacto: base x multiplicador de zona x caida por distancia.
static func calcular_dano(arma: ArmaDatos, zona: String, distancia: float, fuerte: bool = false) -> float:
	var base: float = arma.dano_fuerte if (fuerte and arma.dano_fuerte > 0.0) else arma.dano_base
	return base * arma.mult_zona(zona) * factor_distancia(arma, distancia)


static func factor_distancia(arma: ArmaDatos, distancia: float) -> float:
	if distancia <= arma.caida_inicio or arma.alcance <= arma.caida_inicio:
		return 1.0
	var t: float = clampf((distancia - arma.caida_inicio) / (arma.alcance - arma.caida_inicio), 0.0, 1.0)
	return lerpf(1.0, arma.caida_factor_min, t)


## Direccion `dir` desviada un angulo aleatorio uniforme dentro de un cono de semiangulo `grados`.
static func aplicar_dispersion(dir: Vector3, grados: float, rng: RandomNumberGenerator) -> Vector3:
	var d: Vector3 = dir.normalized()
	if grados <= 0.0:
		return d
	var theta: float = deg_to_rad(grados) * sqrt(rng.randf())
	var phi: float = rng.randf() * TAU
	var ref: Vector3 = Vector3.UP if absf(d.y) < 0.99 else Vector3.RIGHT
	var der: Vector3 = d.cross(ref).normalized()
	var arr: Vector3 = der.cross(d)
	return (d + (der * cos(phi) + arr * sin(phi)) * tan(theta)).normalized()


## Resuelve un disparo. Devuelve {impacto, punto, normal, collider, zona, daño, distancia, direccion, salud, fuerte}.
## `dispersion_deg` es el semiangulo del cono. Si el rayo choca antes con el mundo que con una hitbox no hay dano.
## `tirador` (Node3D en el arbol) aporta el mundo fisico y se excluye junto con sus hitboxes.
static func resolver_disparo(origen: Vector3, direccion: Vector3, arma: ArmaDatos, tirador: Node3D,
		rng: RandomNumberGenerator, dispersion_deg: float = 0.0, fuerte: bool = false) -> Dictionary:
	var dir: Vector3 = aplicar_dispersion(direccion, dispersion_deg, rng)
	var res: Dictionary = {"impacto": false, "punto": origen + dir * arma.alcance, "normal": -dir,
			"collider": null, "zona": "", "daño": 0.0, "distancia": arma.alcance, "direccion": dir,
			"salud": null, "fuerte": fuerte}
	var espacio: PhysicsDirectSpaceState3D = tirador.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origen, origen + dir * arma.alcance, MASCARA_DISPARO)
	q.collide_with_areas = true
	q.collide_with_bodies = true
	q.exclude = _excluidos(tirador)
	var r: Dictionary = espacio.intersect_ray(q)
	if r.is_empty():
		return res
	res["impacto"] = true
	res["punto"] = r["position"]
	res["normal"] = r["normal"]
	res["collider"] = r["collider"]
	var dist: float = origen.distance_to(r["position"] as Vector3)
	res["distancia"] = dist
	var c: Object = r["collider"]
	if c is ZonaImpacto:
		var z := c as ZonaImpacto
		res["zona"] = z.zona
		res["salud"] = z.salud
		res["daño"] = calcular_dano(arma, z.zona, dist, fuerte)
	return res


## Aplica el dano de un resultado a la Salud alcanzada. Devuelve el dano que llego a la vida.
static func aplicar(res: Dictionary, arma: ArmaDatos, atacante: Node) -> float:
	var s: Salud = res.get("salud") as Salud
	if s == null or float(res["daño"]) <= 0.0:
		return 0.0
	return s.recibir_dano(float(res["daño"]), str(res["zona"]), arma.penetracion_armadura, atacante)


static func _excluidos(tirador: Node3D) -> Array[RID]:
	var ex: Array[RID] = []
	if tirador is CollisionObject3D:
		ex.append((tirador as CollisionObject3D).get_rid())
	for h: Node in tirador.find_children("*", "Hitboxes", true, false):
		ex.append_array((h as Hitboxes).rids())
	return ex
