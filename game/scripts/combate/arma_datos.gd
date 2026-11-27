class_name ArmaDatos
extends Resource
## Datos de un arma o utilidad (equilibrio). Las instancias viven en res://data/armas/*.tres.
## Pensado para que lo lean igual el jugador, los bots y un servidor autoritativo.
## `tipo` decide como dispara: hitscan, perdigones, proyectil (con gravedad, el arco carga), cohete (explosivo),
## cuerpo (navaja), sable (golpe en arco + bloqueo), puno (puño-bot), granada_humo/cegadora/explosiva,
## bote_pintura, extintor y altavoz (utilidades lanzables).

const T_HITSCAN: StringName = &"hitscan"
const T_PERDIGONES: StringName = &"perdigones"
const T_PROYECTIL: StringName = &"proyectil"
const T_COHETE: StringName = &"cohete"
const T_CUERPO: StringName = &"cuerpo"
const T_SABLE: StringName = &"sable"
const T_PUNO: StringName = &"puno"

@export var id: StringName = &""
@export var nombre: String = ""
## Ranura de inventario (1 = principal, 2 = secundaria, 3 = cuerpo a cuerpo, 4 = utilidad).
@export var ranura: int = 1
@export var tipo: StringName = &"hitscan"
## Nombre (sin extension) del sonido de disparo en res://assets/sonidos/.
@export var sonido: StringName = &"disparo_fusil"
## Verdadero si el arma esta pensada para el clic derecho de apuntar (armas de fuego).
@export var apuntable: bool = true
## Radio (m) con el que oyen el disparo los bots (0 = silencioso).
@export var ruido: float = 60.0

## Compatibilidad: `cuerpo_a_cuerpo` es verdadero para navaja y sable (el gestor usa `es_melee()`).
@export var cuerpo_a_cuerpo: bool = false

@export_group("Cadencia")
## Disparos por segundo.
@export var cadencia: float = 10.0
@export var automatica: bool = true
## Tiempo (s) hasta poder disparar tras sacar el arma.
@export var tiempo_cambio: float = 0.6
## Disparos por rafaga (1 = sin rafaga); `pausa_rafaga` es la espera (s) tras la rafaga completa.
@export var rafaga: int = 1
@export var pausa_rafaga: float = 0.3

@export_group("Dano")
@export var dano_base: float = 30.0
@export var mult_cabeza: float = 4.0
@export var mult_torso: float = 1.0
@export var mult_piernas: float = 0.75
## Distancia maxima del disparo (m).
@export var alcance: float = 100.0
## A partir de esta distancia (m) el dano cae linealmente hasta `caida_factor_min` en el alcance.
@export var caida_inicio: float = 30.0
@export var caida_factor_min: float = 0.6
## Fraccion del dano que pasa a la vida cuando hay escudo (el resto lo absorbe el escudo).
@export_range(0.0, 1.0) var penetracion_armadura: float = 0.7
## Solo cuerpo a cuerpo: ataque fuerte (clic derecho).
@export var dano_fuerte: float = 0.0
@export var intervalo_fuerte: float = 1.0

@export_group("Perdigones")
@export var perdigones: int = 1
## Semiangulo (grados) del cono de los perdigones.
@export var dispersion_perdigon: float = 0.0

@export_group("Proyectil")
@export var velocidad_proyectil: float = 60.0
@export var gravedad_proyectil: float = 0.0
## Tiempo (s) de carga del tiro (arco, puño): 0 = dispara al pulsar.
@export var carga_tiempo: float = 0.0
## Fraccion de dano y velocidad con la carga minima.
@export var carga_minima: float = 0.3
## Puño-Bot: segundos hasta que el puño vuelve a la mano.
@export var retorno_tiempo: float = 1.5
@export var empuje: float = 0.0

@export_group("Explosion")
@export var radio_explosion: float = 0.0
@export var dano_explosion: float = 0.0
@export_range(0.0, 1.0) var caida_explosion: float = 0.1
## Multiplicador del dano que se hace el propio lanzador.
@export var autodano: float = 0.5

@export_group("Sable")
@export var angulo_golpe: float = 90.0
@export var angulo_bloqueo: float = 70.0
@export var calor_por_bloqueo: float = 18.0
@export var enfriamiento: float = 16.0
@export var tiempo_sobrecalentado: float = 4.0

@export_group("Utilidad")
@export var mecha: float = 0.0
@export var radio_efecto: float = 0.0
@export var duracion_efecto: float = 0.0
@export var velocidad_lanzamiento: float = 17.0
@export var velocidad_lanzamiento_flojo: float = 7.0

@export_group("Municion")
@export var cargador: int = 30
@export var reserva: int = 90
@export var tiempo_recarga: float = 2.3

@export_group("Dispersion (grados, semiangulo del cono)")
@export var dispersion_quieto: float = 0.15
@export var dispersion_agachado: float = 0.08
@export var dispersion_movimiento: float = 2.0
@export var dispersion_aire: float = 4.0
## Dispersion al correr (solo informativa: correr impide disparar).
@export var dispersion_correr: float = 8.0
## Multiplicador de la dispersion al apuntar (clic derecho).
@export var dispersion_apuntando: float = 0.4

@export_group("Apuntar")
## Aumentos al apuntar (1 = sin zoom): el campo de vision base se divide por este valor.
@export var zoom: float = 1.25
## Si es verdadero se dibuja la mira de zoom (francotirador) y se oculta el arma.
@export var mira_zoom: bool = false
@export var tiempo_apuntar: float = 0.16
@export var velocidad_apuntando: float = 0.65

@export_group("Retroceso")
## Grados que sube la mira con el disparo n-esimo de una rafaga (el ultimo valor se repite).
@export var retroceso_pitch: PackedFloat32Array = PackedFloat32Array([0.5])
## Grados de desvio lateral con el disparo n-esimo (+ = izquierda).
@export var retroceso_yaw: PackedFloat32Array = PackedFloat32Array([0.0])
## Grados por segundo que se recupera la mira cuando se deja de disparar.
@export var retroceso_recuperacion: float = 12.0
## Segundos sin disparar antes de que empiece la recuperacion (y la rafaga se reinicie).
@export var retroceso_pausa: float = 0.15

@export_group("Movimiento")
## Multiplicador de la velocidad del jugador con esta arma en la mano.
@export var velocidad_mov: float = 1.0
## Multiplicador de velocidad mientras se bloquea (sable).
@export var velocidad_bloqueando: float = 0.6


func intervalo() -> float:
	return 1.0 / maxf(cadencia, 0.01)


func mult_zona(zona: String) -> float:
	match zona:
		"cabeza":
			return mult_cabeza
		"piernas":
			return mult_piernas
	return mult_torso


func es_melee() -> bool:
	return tipo == T_CUERPO or tipo == T_SABLE


func es_utilidad() -> bool:
	return ranura == 4
