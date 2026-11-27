class_name DificultadBot
extends RefCounted
## Perfiles de dificultad de los bots (facil / normal / dificil). Todo son numeros: se pueden ajustar aqui sin tocar la IA.
##  reaccion          s desde que ve a un enemigo nuevo hasta que empieza a disparar
##  error_inicial     grados de error de punteria al adquirir un objetivo (repartido al azar en yaw y pitch) ...
##  tau_error         ... que decae como exp(-t / tau) mientras lo sigue; error_residual = temblor constante
##  spray_por_disparo grados que se suman al cono de dispersion por cada disparo (spray creciente), hasta spray_max, y
##  spray_recup       grados/s que se recuperan al dejar de disparar
##  vel_giro          grados/s maximos de giro de la mira
##  p_cabeza          probabilidad de apuntar a la cabeza (si no, al torso) en cada objetivo
##  rafaga/pausa      disparos seguidos antes de soltar el gatillo y segundos de pausa (control de rafagas)
##  p_utilidad        probabilidad por evaluacion (0,8 s) de lanzar una granada cuando la situacion lo pide
##  memoria           s que recuerda donde vio por ultima vez a un enemigo
##  vision / fov      alcance (m) y campo de vision (grados) con el que detecta enemigos
##  apunta            0..1 = cuanto "apunta" (clic derecho) cuando esta quieto: reduce la dispersion del arma
##  quieto_al_disparar si es falso, sigue andando mientras dispara (mas dispersion)
##  sigue_ruido       probabilidad de ir a investigar un ruido lejano

const FACIL: StringName = &"facil"
const NORMAL: StringName = &"normal"
const DIFICIL: StringName = &"dificil"
const TODAS: Array[StringName] = [FACIL, NORMAL, DIFICIL]

const PERFILES: Dictionary = {
	&"facil": {
		"reaccion": 0.70, "error_inicial": 7.0, "tau_error": 0.8, "error_residual": 1.6,
		"spray_por_disparo": 0.7, "spray_max": 7.0, "spray_recup": 5.0, "vel_giro": 150.0, "p_cabeza": 0.03,
		"rafaga": 7, "pausa_rafaga": 0.45, "p_utilidad": 0.03, "memoria": 5.0, "vision": 60.0, "fov": 100.0,
		"apunta": 0.0, "quieto_al_disparar": false, "sigue_ruido": 0.5,
	},
	&"normal": {
		"reaccion": 0.38, "error_inicial": 4.0, "tau_error": 0.45, "error_residual": 0.8,
		"spray_por_disparo": 0.45, "spray_max": 4.5, "spray_recup": 8.0, "vel_giro": 260.0, "p_cabeza": 0.15,
		"rafaga": 4, "pausa_rafaga": 0.32, "p_utilidad": 0.08, "memoria": 8.0, "vision": 80.0, "fov": 110.0,
		"apunta": 0.5, "quieto_al_disparar": true, "sigue_ruido": 0.8,
	},
	&"dificil": {
		"reaccion": 0.18, "error_inicial": 2.0, "tau_error": 0.22, "error_residual": 0.3,
		"spray_por_disparo": 0.25, "spray_max": 2.5, "spray_recup": 12.0, "vel_giro": 480.0, "p_cabeza": 0.40,
		"rafaga": 3, "pausa_rafaga": 0.22, "p_utilidad": 0.18, "memoria": 12.0, "vision": 100.0, "fov": 120.0,
		"apunta": 1.0, "quieto_al_disparar": true, "sigue_ruido": 1.0,
	},
}


## Perfil (copia) de una dificultad; un nombre desconocido da el normal.
static func perfil(nombre: StringName) -> Dictionary:
	return (PERFILES.get(nombre, PERFILES[NORMAL]) as Dictionary).duplicate()
