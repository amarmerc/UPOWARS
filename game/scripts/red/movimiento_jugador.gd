class_name MovimientoJugador
extends RefCounted
## Paso de movimiento del jugador humano en la red: una unica funcion (`paso`) que usan IGUAL el servidor (sobre el `Bot` que hace de
## avatar de cada humano remoto) y el cliente (prediccion y reconciliacion sobre su `Jugador`). Mismas constantes que `Jugador`
## (andar 5, correr 7,8, sigilo 2,6, agachado 1,7 m/s; aceleracion 40 / friccion 30 / aire 5; gravedad 20; salto 1 m), asi que con las
## mismas entradas ambos lados llegan al mismo sitio. El cliente NO envia su posicion: solo entradas, y el servidor simula.

const VEL_NORMAL: float = 5.0
const VEL_SPRINT: float = 7.8
const VEL_SIGILO: float = 2.6
const VEL_AGACHADO: float = 1.7
const ACEL_SUELO: float = 40.0
const FRICCION_SUELO: float = 30.0
const ACEL_AIRE: float = 5.0
const GRAVEDAD: float = 20.0
const ALTURA_SALTO: float = 1.0
const ALTURA_PIE: float = 1.8
const ALTURA_AGACHADO: float = 1.2
const OJOS_PIE: float = 1.65
const OJOS_AGACHADO: float = 1.15
const VEL_TRANSICION_OJOS: float = 6.0
## Velocidad horizontal maxima fisicamente posible (correr x multiplicador de arma <= 1,2) mas margen: lo que el servidor tolera.
const VEL_MAX: float = VEL_SPRINT * 1.25


## Estado que arrastra el movimiento entre pasos (ademas de `velocity` y la posicion del cuerpo).
class Estado:
	extends RefCounted
	var agachado: bool = false
	var en_suelo: bool = true
	var corriendo: bool = false
	var saltar_prev: bool = false
	var ojos_y: float = OJOS_PIE
	var mult_arma: float = 1.0
	var mult_estado: float = 1.0

	func copiar_de(o: Estado) -> void:
		agachado = o.agachado
		en_suelo = o.en_suelo
		corriendo = o.corriendo
		saltar_prev = o.saltar_prev
		ojos_y = o.ojos_y


## Un paso de `dt` s del cuerpo `c` con la entrada `e` (`EntradaRed`). Deja la posicion, `velocity` y `st` actualizados.
static func paso(c: CharacterBody3D, st: Estado, e: EntradaRed, dt: float) -> void:
	var quiere_sigilo: bool = e.sigilo()
	if e.agachar():
		if not st.agachado:
			poner_postura(c, st, true)
	elif st.agachado and _puede_levantarse(c):
		poner_postura(c, st, false)
	st.ojos_y = move_toward(st.ojos_y, OJOS_AGACHADO if st.agachado else OJOS_PIE, VEL_TRANSICION_OJOS * dt)
	c.rotation.y = e.yaw
	var v: Vector3 = c.velocity
	var salto: bool = e.saltar() and not st.saltar_prev
	st.saltar_prev = e.saltar()
	if not st.en_suelo:
		v.y -= GRAVEDAD * dt
	elif salto:
		v.y = sqrt(2.0 * GRAVEDAD * ALTURA_SALTO)
	var ent: Vector2 = Vector2(e.mx_f(), e.mz_f()).limit_length(1.0)
	st.corriendo = e.correr() and ent.y < -0.1 and st.en_suelo and not st.agachado and not quiere_sigilo
	var dir: Vector3 = Basis(Vector3.UP, e.yaw) * Vector3(ent.x, 0.0, ent.y)
	var vel: float = VEL_NORMAL
	if st.agachado:
		vel = VEL_AGACHADO
	elif quiere_sigilo:
		vel = VEL_SIGILO
	elif st.corriendo:
		vel = VEL_SPRINT
	var objetivo: Vector3 = dir.normalized() * vel * st.mult_arma * st.mult_estado
	var h := Vector3(v.x, 0.0, v.z)
	var ritmo: float
	if st.en_suelo:
		ritmo = ACEL_SUELO if dir.length_squared() > 0.0 else FRICCION_SUELO
	else:
		ritmo = ACEL_AIRE if dir.length_squared() > 0.0 else 0.0
	h = h.move_toward(objetivo, ritmo * dt)
	v.x = h.x
	v.z = h.z
	c.velocity = v
	c.move_and_slide()
	st.en_suelo = c.is_on_floor()


static func poner_postura(c: CharacterBody3D, st: Estado, abajo: bool) -> void:
	st.agachado = abajo
	var h: float = ALTURA_AGACHADO if abajo else ALTURA_PIE
	var col: CollisionShape3D = c.get_node("Colision") as CollisionShape3D
	(col.shape as CapsuleShape3D).height = h
	col.position.y = h * 0.5
	var hb: Hitboxes = c.get_node_or_null("Hitboxes") as Hitboxes
	if hb != null:
		hb.ajustar_altura(h)


static func _puede_levantarse(c: CharacterBody3D) -> bool:
	return not c.test_move(c.global_transform, Vector3.UP * (ALTURA_PIE - ALTURA_AGACHADO))


## Vuelve a la postura de pie sin comprobar techo (reaparicion).
static func de_pie(c: CharacterBody3D, st: Estado) -> void:
	poner_postura(c, st, false)
	st.ojos_y = OJOS_PIE
	st.en_suelo = true
	st.saltar_prev = false
