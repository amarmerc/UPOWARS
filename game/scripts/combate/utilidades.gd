class_name Utilidades
extends RefCounted
## API estatica de las utilidades (granadas y gadgets) y consultas tacticas que usan el jugador, los bots y la Partida:
## `linea_de_vision(ctx, a, b)` (pared y humo/extintor), `marcados_para(ctx, equipo)` (bote de pintura) y
## `activar()` (lo que hace cada utilidad al detonar). El ruido para los bots sale por `SenalesCombate.ruido`.

const T_HUMO: StringName = &"granada_humo"
const T_CEGADORA: StringName = &"granada_cegadora"
const T_EXPLOSIVA: StringName = &"granada_explosiva"
const T_PINTURA: StringName = &"bote_pintura"
const T_EXTINTOR: StringName = &"extintor"
const T_ALTAVOZ: StringName = &"altavoz"


## Nodo (en la raiz) donde viven los proyectiles, granadas, nubes y armas del suelo. Se crea al primer uso.
static func mundo(ctx: Node) -> Node3D:
	var raiz: Node = ctx.get_tree().root
	var m: Node = raiz.get_node_or_null("MundoCombate")
	if m == null:
		m = Node3D.new()
		m.name = "MundoCombate"
		raiz.add_child(m)
	return m as Node3D


static func efectos(ctx: Node) -> EfectosCombate:
	return ctx.get_tree().get_first_node_in_group("efectos") as EfectosCombate


## Verdadero si a y b se ven: sin pared (mundo) ni nube de humo/extintor por medio.
static func linea_de_vision(ctx: Node3D, a: Vector3, b: Vector3) -> bool:
	if Balistica.hay_pared(ctx.get_world_3d().direct_space_state, a, b):
		return false
	for n: Node in ctx.get_tree().get_nodes_in_group("nubes"):
		if (n as NubeVision).tapa(a, b):
			return false
	return true


## Combatientes vivos marcados (bote de pintura) visibles para el equipo `equipo`, aunque haya paredes.
static func marcados_para(ctx: Node, equipo: int) -> Array[Salud]:
	var out: Array[Salud] = []
	for n: Node in ctx.get_tree().get_nodes_in_group("salud"):
		var s: Salud = n as Salud
		if s != null and s.marcado_para(equipo):
			out.append(s)
	return out


## Lanza una utilidad como `Lanzable` desde `pos` con velocidad `vel`.
static func lanzar(ctx: Node, arma: ArmaDatos, pos: Vector3, vel: Vector3, lanzador: Node) -> Lanzable:
	return Lanzable.crear(ctx, arma, pos, vel, lanzador)


## Efecto de cada utilidad al detonar en `pos`.
static func activar(ctx: Node3D, arma: ArmaDatos, pos: Vector3, lanzador: Node) -> void:
	var ef: EfectosCombate = efectos(ctx)
	match arma.tipo:
		T_HUMO:
			NubeVision.crear(ctx, pos, arma.radio_efecto, arma.duracion_efecto)
			if ef != null:
				ef.sonido_en(pos, &"humo")
		T_EXTINTOR:
			NubeVision.crear(ctx, pos, arma.radio_efecto, arma.duracion_efecto, arma.empuje, Color(0.96, 0.97, 1.0))
			if ef != null:
				ef.sonido_en(pos, &"humo")
		T_CEGADORA:
			cegar_en(ctx, pos, arma)
			if ef != null:
				ef.destello(pos)
				ef.sonido_en(pos, &"cegadora")
		T_EXPLOSIVA:
			explosion(ctx, pos, arma, lanzador)
		T_PINTURA:
			marcar_en(ctx, pos, arma, lanzador)
			if ef != null:
				ef.salpicadura(pos, arma.radio_efecto)
		T_ALTAVOZ:
			Altavoz.crear(ctx, pos, arma, lanzador)


## Explosion con dano (cohete o granada explosiva) mas efectos visuales y sonido.
static func explosion(ctx: Node3D, pos: Vector3, arma: ArmaDatos, lanzador: Node) -> Array[Dictionary]:
	var r: Array[Dictionary] = Balistica.aplicar_explosion(pos, arma, lanzador, ctx)
	var ef: EfectosCombate = efectos(ctx)
	if ef != null:
		ef.explosion(pos, arma.radio_explosion)
	SenalesCombate.obtener(ctx.get_tree()).ruido.emit(pos, 120.0, lanzador)
	return r


## Granada cegadora: ciega a todos los `EstadoCeguera` con linea de vision al destello, segun el angulo (mirando hacia ella
## ciega mas que de espaldas) y la distancia. Devuelve cuantos han quedado cegados.
static func cegar_en(ctx: Node3D, pos: Vector3, arma: ArmaDatos) -> int:
	var n: int = 0
	for c: Node in ctx.get_tree().get_nodes_in_group("cegables"):
		var e: EstadoCeguera = c as EstadoCeguera
		var ojos: Vector3 = e.ojos()
		var d: float = ojos.distance_to(pos)
		if d > arma.radio_efecto or not linea_de_vision(ctx, pos, ojos):
			continue
		var ang: float = rad_to_deg(e.mirada().angle_to((pos - ojos).normalized())) if d > 0.05 else 0.0
		var f_ang: float = clampf(remap(ang, 30.0, 150.0, 1.0, 0.12), 0.12, 1.0)
		var f_dist: float = clampf(remap(d, 4.0, arma.radio_efecto, 1.0, 0.2), 0.2, 1.0)
		var nivel: float = f_ang * f_dist
		e.cegar(nivel, arma.duracion_efecto * (0.35 + 0.65 * nivel))
		n += 1
	return n


## Bote de pintura: marca durante `duracion_efecto` s a los enemigos a menos de `radio_efecto` m del bote.
static func marcar_en(ctx: Node, pos: Vector3, arma: ArmaDatos, lanzador: Node) -> int:
	var propio: Salud = Salud.de(lanzador)
	var equipo: int = propio.equipo if propio != null else 0
	var n: int = 0
	for nodo: Node in ctx.get_tree().get_nodes_in_group("salud"):
		var s: Salud = nodo as Salud
		if s == null or not s.vivo or s == propio or (equipo != 0 and s.equipo == equipo):
			continue
		var duenio: Node3D = s.get_parent() as Node3D
		if duenio == null:
			continue
		if (duenio.global_position + Vector3(0.0, 1.0, 0.0)).distance_to(pos) <= arma.radio_efecto:
			s.marcar(equipo, arma.duracion_efecto)
			n += 1
	return n
