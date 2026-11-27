class_name Balistica
extends RefCounted
## Resolucion del dano (hitscan, perdigones, golpes en arco, pasos de proyectil y explosiones), separada de la entrada y
## del dibujo. Todo son funciones estaticas: las usan el gestor de armas del jugador, los bots y (a futuro) un servidor.
## El azar sale de un RandomNumberGenerator inyectado, asi que con la misma semilla el resultado se repite.

const CAPA_MUNDO: int = 1
const CAPA_HITBOX: int = 2
const MASCARA_DISPARO: int = CAPA_MUNDO | CAPA_HITBOX
## Velocidad horizontal (m/s) a partir de la cual la dispersion de movimiento es la maxima (carrera).
const VEL_DISPERSION_MAX: float = 5.0
## Por debajo de esta velocidad se considera "quieto".
const VEL_QUIETO: float = 0.5
## Grados de dispersion extra con ceguera total.
const DISPERSION_CEGUERA: float = 10.0


## Semiangulo del cono de dispersion (grados) segun el estado del tirador. `apuntado` (0..1) reduce el cono hacia
## `dispersion_apuntando`; `ceguera` (0..1) lo agranda (los bots ciegos pierden punteria).
static func dispersion(arma: ArmaDatos, velocidad: float, en_suelo: bool, agachado: bool,
		apuntado: float = 0.0, ceguera: float = 0.0) -> float:
	var d: float
	if not en_suelo:
		d = arma.dispersion_aire
	else:
		var base: float = arma.dispersion_agachado if agachado else arma.dispersion_quieto
		var t: float = clampf((velocidad - VEL_QUIETO) / (VEL_DISPERSION_MAX - VEL_QUIETO), 0.0, 1.0)
		d = base + (arma.dispersion_movimiento - arma.dispersion_quieto) * t
	d *= lerpf(1.0, arma.dispersion_apuntando, clampf(apuntado, 0.0, 1.0))
	return d + ceguera * DISPERSION_CEGUERA


## Dano de un impacto: base x multiplicador de zona x caida por distancia (x `mult`, p. ej. la carga del arco).
static func calcular_dano(arma: ArmaDatos, zona: String, distancia: float, fuerte: bool = false,
		mult: float = 1.0) -> float:
	var base: float = arma.dano_fuerte if (fuerte and arma.dano_fuerte > 0.0) else arma.dano_base
	return base * arma.mult_zona(zona) * factor_distancia(arma, distancia) * mult


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


## Completa un resultado con el impacto de un rayo (`r` = intersect_ray): zona, salud y dano si es una hitbox.
static func resolver_impacto(res: Dictionary, r: Dictionary, origen: Vector3, arma: ArmaDatos, fuerte: bool = false,
		mult: float = 1.0, distancia_extra: float = 0.0) -> Dictionary:
	res["impacto"] = true
	res["punto"] = r["position"]
	res["normal"] = r["normal"]
	res["collider"] = r["collider"]
	var dist: float = origen.distance_to(r["position"] as Vector3) + distancia_extra
	res["distancia"] = dist
	var c: Object = r["collider"]
	if c is ZonaImpacto:
		var z := c as ZonaImpacto
		res["zona"] = z.zona
		res["salud"] = z.salud
		res["daño"] = calcular_dano(arma, z.zona, dist, fuerte, mult)
	return res


static func _res_vacio(origen: Vector3, dir: Vector3, alcance: float, fuerte: bool) -> Dictionary:
	return {"impacto": false, "punto": origen + dir * alcance, "normal": -dir,
			"collider": null, "zona": "", "daño": 0.0, "distancia": alcance, "direccion": dir,
			"salud": null, "fuerte": fuerte}


## Resuelve un disparo hitscan. Devuelve {impacto, punto, normal, collider, zona, daño, distancia, direccion, salud, fuerte}.
## `dispersion_deg` es el semiangulo del cono. Si el rayo choca antes con el mundo que con una hitbox no hay dano.
## `tirador` (Node3D en el arbol) aporta el mundo fisico y se excluye junto con sus hitboxes.
static func resolver_disparo(origen: Vector3, direccion: Vector3, arma: ArmaDatos, tirador: Node3D,
		rng: RandomNumberGenerator, dispersion_deg: float = 0.0, fuerte: bool = false) -> Dictionary:
	var dir: Vector3 = aplicar_dispersion(direccion, dispersion_deg, rng)
	var res: Dictionary = _res_vacio(origen, dir, arma.alcance, fuerte)
	var espacio: PhysicsDirectSpaceState3D = tirador.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origen, origen + dir * arma.alcance, MASCARA_DISPARO)
	q.collide_with_areas = true
	q.collide_with_bodies = true
	q.exclude = excluidos(tirador)
	var r: Dictionary = espacio.intersect_ray(q)
	if r.is_empty():
		return res
	return resolver_impacto(res, r, origen, arma, fuerte)


## Salva de perdigones: una desviacion de punteria para toda la salva (`dispersion_deg`) y luego cada perdigon dentro de
## `arma.dispersion_perdigon`. Devuelve el resultado del primer perdigon mas {"impactos": Array[Dictionary], "daño_total"}.
static func resolver_perdigones(origen: Vector3, direccion: Vector3, arma: ArmaDatos, tirador: Node3D,
		rng: RandomNumberGenerator, dispersion_deg: float = 0.0) -> Dictionary:
	var dir0: Vector3 = aplicar_dispersion(direccion, dispersion_deg, rng)
	var lista: Array[Dictionary] = []
	var total: float = 0.0
	for i in maxi(arma.perdigones, 1):
		var r: Dictionary = resolver_disparo(origen, dir0, arma, tirador, rng, arma.dispersion_perdigon)
		lista.append(r)
		total += float(r["daño"])
	return _compuesto(lista, total, dir0)


## Golpe en arco (sable): rayos repartidos en `angulo_golpe` grados en horizontal respecto a la base de la camara.
## Cada objetivo (Salud) se golpea una sola vez.
static func resolver_arco(origen: Vector3, base: Basis, arma: ArmaDatos, tirador: Node3D,
		rng: RandomNumberGenerator, rayos: int = 9) -> Dictionary:
	var adelante: Vector3 = -base.z
	var lista: Array[Dictionary] = []
	var vistos: Array[Salud] = []
	var total: float = 0.0
	for i in rayos:
		var k: float = (float(i) / float(rayos - 1) - 0.5) if rayos > 1 else 0.0
		var dir: Vector3 = adelante.rotated(base.y.normalized(), deg_to_rad(arma.angulo_golpe) * k)
		var r: Dictionary = resolver_disparo(origen, dir, arma, tirador, rng, 0.0)
		var s: Salud = r["salud"] as Salud
		if s != null:
			if vistos.has(s):
				r["daño"] = 0.0
			else:
				vistos.append(s)
				total += float(r["daño"])
		lista.append(r)
	return _compuesto(lista, total, adelante)


static func _compuesto(lista: Array[Dictionary], total: float, dir: Vector3) -> Dictionary:
	var res: Dictionary = (lista[0] as Dictionary).duplicate()
	for r: Dictionary in lista:  # el compuesto representa el mejor impacto (el primero que dana)
		if float(r["daño"]) > 0.0:
			res = r.duplicate()
			break
	res["impactos"] = lista
	res["daño_total"] = total
	res["direccion"] = dir
	return res


## Aplica el dano de un resultado a la Salud alcanzada. Devuelve el dano que llego a la vida.
## Si el objetivo bloquea el golpe (sable) no hay dano y el resultado queda marcado como "bloqueado".
static func aplicar(res: Dictionary, arma: ArmaDatos, atacante: Node) -> float:
	var s: Salud = res.get("salud") as Salud
	if s == null or float(res["daño"]) <= 0.0:
		return 0.0
	if s.intenta_bloquear(res["direccion"] as Vector3):
		res["bloqueado"] = true
		return 0.0
	return s.recibir_dano(float(res["daño"]), str(res["zona"]), arma.penetracion_armadura, atacante, arma)


## Aplica todos los perdigones o rayos de un resultado compuesto. Devuelve el dano total que llego a la vida.
static func aplicar_multiple(res: Dictionary, arma: ArmaDatos, atacante: Node) -> float:
	var total: float = 0.0
	for r: Dictionary in res.get("impactos", []):
		total += aplicar(r, arma, atacante)
	return total


## Un paso de `dt` s de un proyectil con gravedad: integra la velocidad (Euler semiimplicito), traza un rayo continuo del
## punto actual al nuevo (no atraviesa paredes) y devuelve {pos, vel, choque, res}. `res` es como el de resolver_disparo
## (con "daño" segun la distancia recorrida `recorrido` y el multiplicador `mult`). Determinista: sin azar.
static func paso_proyectil(pos: Vector3, vel: Vector3, dt: float, gravedad: float, arma: ArmaDatos, ctx: Node3D,
		excluir: Array[RID], recorrido: float = 0.0, mult: float = 1.0) -> Dictionary:
	var v: Vector3 = vel + Vector3(0.0, -gravedad * dt, 0.0)
	var fin: Vector3 = pos + v * dt
	var paso: Dictionary = {"pos": fin, "vel": v, "choque": false, "res": null}
	var espacio: PhysicsDirectSpaceState3D = ctx.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pos, fin, MASCARA_DISPARO)
	q.collide_with_areas = true
	q.collide_with_bodies = true
	q.exclude = excluir
	var r: Dictionary = espacio.intersect_ray(q)
	if r.is_empty():
		return paso
	var res: Dictionary = _res_vacio(pos, v.normalized(), arma.alcance, false)
	resolver_impacto(res, r, pos, arma, false, mult, recorrido)
	paso["choque"] = true
	paso["pos"] = r["position"]
	paso["res"] = res
	return paso


## Explosion en `centro`: dano en area con caida lineal hasta `caida_explosion` en el borde, bloqueada por las paredes
## (rayo del centro al cuerpo), con autodano reducido (`arma.autodano`) para el propio `atacante`, sin fuego amigo entre
## companeros y con empuje a quien pueda recibirlo (`aplicar_impulso`). No la bloquea el sable. `ctx` aporta el mundo
## fisico. Devuelve [{salud, daño, distancia}] de los combatientes alcanzados.
static func aplicar_explosion(centro: Vector3, arma: ArmaDatos, atacante: Node, ctx: Node3D,
		mult_dano: float = 1.0) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var radio: float = arma.radio_explosion
	if radio <= 0.0:
		return out
	var espacio: PhysicsDirectSpaceState3D = ctx.get_world_3d().direct_space_state
	var forma := SphereShape3D.new()
	forma.radius = radio + 0.4
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = forma
	q.transform = Transform3D(Basis.IDENTITY, centro)
	q.collision_mask = 1 << (CAPA_HITBOX - 1)
	q.collide_with_areas = true
	q.collide_with_bodies = false
	var cercanas: Array[Dictionary] = espacio.intersect_shape(q, 128)
	var por_salud: Dictionary = {}  # Salud -> Array[Vector3] (centros de zona)
	for h: Dictionary in cercanas:
		var z: ZonaImpacto = h["collider"] as ZonaImpacto
		if z == null or z.salud == null or not z.salud.vivo:
			continue
		if not por_salud.has(z.salud):
			por_salud[z.salud] = []
		(por_salud[z.salud] as Array).append(_centro_zona(z))
	var propio: Salud = Salud.de(atacante)
	for s: Salud in por_salud.keys():
		var centros: Array = por_salud[s]
		centros.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.distance_to(centro) < b.distance_to(centro))
		var mejor: Vector3 = Vector3.INF
		for c3: Vector3 in centros:
			if not hay_pared(espacio, centro, c3):
				mejor = c3
				break
		if mejor == Vector3.INF:
			continue
		var d: float = maxf(mejor.distance_to(centro) - 0.3, 0.0)
		if d > radio:
			continue
		var f: float = lerpf(1.0, arma.caida_explosion, d / radio)
		var dano: float = arma.dano_explosion * f * mult_dano
		if s == propio:
			dano *= arma.autodano
		var a_vida: float = s.recibir_dano(dano, "torso", arma.penetracion_armadura, atacante, arma)
		var duenio: Node = s.get_parent()
		if arma.empuje > 0.0 and duenio != null and duenio.has_method("aplicar_impulso"):
			var dir: Vector3 = (mejor - centro)
			dir = (dir + Vector3.UP * 0.6).normalized() if dir.length() > 0.01 else Vector3.UP
			duenio.call("aplicar_impulso", dir * arma.empuje * f)
		out.append({"salud": s, "daño": a_vida, "distancia": d})
	return out


## Empuja (impulso en m/s) al dueno de `s` si sabe recibirlo (`aplicar_impulso`): jugador, bots.
static func empujar(s: Salud, impulso: Vector3) -> void:
	var duenio: Node = s.get_parent() if s != null else null
	if duenio != null and duenio.has_method("aplicar_impulso"):
		duenio.call("aplicar_impulso", impulso)


## Verdadero si el mundo (capa 1) corta el segmento a-b.
static func hay_pared(espacio: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(a, b, CAPA_MUNDO)
	return not espacio.intersect_ray(q).is_empty()


static func _centro_zona(z: ZonaImpacto) -> Vector3:
	for c: Node in z.get_children():
		if c is CollisionShape3D:
			return (c as CollisionShape3D).global_position
	return z.global_position


static func excluidos(tirador: Node3D) -> Array[RID]:
	var ex: Array[RID] = []
	if tirador is CollisionObject3D:
		ex.append((tirador as CollisionObject3D).get_rid())
	for h: Node in tirador.find_children("*", "Hitboxes", true, false):
		ex.append_array((h as Hitboxes).rids())
	return ex
