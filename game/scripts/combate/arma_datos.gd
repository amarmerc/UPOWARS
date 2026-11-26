class_name ArmaDatos
extends Resource
## Datos de un arma (equilibrio). Las instancias viven en res://data/armas/*.tres.
## Pensado para que lo lean igual el jugador, los bots y un servidor autoritativo.

@export var id: StringName = &""
@export var nombre: String = ""
## Ranura de inventario (1 = principal, 2 = secundaria, 3 = cuerpo a cuerpo).
@export var ranura: int = 1
@export var cuerpo_a_cuerpo: bool = false

@export_group("Cadencia")
## Disparos por segundo.
@export var cadencia: float = 10.0
@export var automatica: bool = true
## Tiempo (s) hasta poder disparar tras sacar el arma.
@export var tiempo_cambio: float = 0.6

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
## Fraccion del dano que pasa a la vida cuando hay armadura (el resto lo absorbe la armadura).
@export_range(0.0, 1.0) var penetracion_armadura: float = 0.7
## Solo cuerpo a cuerpo: ataque fuerte (clic derecho).
@export var dano_fuerte: float = 0.0
@export var intervalo_fuerte: float = 1.0

@export_group("Municion")
@export var cargador: int = 30
@export var reserva: int = 90
@export var tiempo_recarga: float = 2.3

@export_group("Dispersion (grados, semiangulo del cono)")
@export var dispersion_quieto: float = 0.15
@export var dispersion_agachado: float = 0.08
@export var dispersion_movimiento: float = 2.0
@export var dispersion_aire: float = 4.0

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


func intervalo() -> float:
	return 1.0 / maxf(cadencia, 0.01)


func mult_zona(zona: String) -> float:
	match zona:
		"cabeza":
			return mult_cabeza
		"piernas":
			return mult_piernas
	return mult_torso
