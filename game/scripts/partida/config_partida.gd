class_name ConfigPartida
extends RefCounted
## Configuracion de una partida: lo que elige el lobby, mas los tiempos y la economia (todo en datos, nada hardcodeado en la
## logica; los valores por defecto son los del documento de diseno docs/DISENO_COMPETITIVO.md).

const MODO_LIBRE: StringName = &"libre"
const MODO_COMPETITIVO: StringName = &"competitivo"
const SUB_CACHIMBA: StringName = &"cachimba"
const SUB_ELIMINACION: StringName = &"eliminacion"
## Modos que ve el jugador en el lobby: [id, nombre visible]. Internamente: libre = MODO_LIBRE; Cachimba Wars = competitivo +
## SUB_CACHIMBA; Modo pleno = competitivo + SUB_ELIMINACION (los identificadores internos no cambian).
const M_LIBRE: StringName = &"libre"
const M_CACHIMBA_WARS: StringName = &"cachimba_wars"
const M_PLENO: StringName = &"pleno"
const MODOS: Array = [[M_LIBRE, "Modo libre"], [M_CACHIMBA_WARS, "Cachimba Wars"], [M_PLENO, "Modo pleno"]]
const TIPO_HUMANO: StringName = &"humano"
const TIPO_BOT: StringName = &"bot"

# --- lobby
var modo: StringName = MODO_COMPETITIVO
var submodo: StringName = SUB_CACHIMBA
var zona: String = "plaza_america"
## Nombres de los dos equipos (grupo 0 empieza atacando; grupo 1 empieza defendiendo).
var nombres: Array[String] = ["EPS", "CEUPO"]
var jugadores_por_equipo: int = 5
## Si es falso el equipo del jugador no se rellena con bots (el rival siempre es de bots).
var rellenar_bots: bool = true
var dificultad: StringName = &"normal"
var rondas_ganar: int = 7
## Grupo del jugador: 0 = empieza atacando, 1 = empieza defendiendo.
var grupo_jugador: int = 0
var con_jugador: bool = true
## Modo libre: numero de bots que deambulan (0 = ninguno).
var bots_libres: int = 0
var semilla: int = 1
## Huecos de los dos equipos: [Array(grupo 0), Array(grupo 1)], cada hueco = `hueco(...)`. Vacio = se deducen de los campos de arriba
## (`huecos_efectivos`). Los huecos vacios son siempre bots; el humano con `local` = true es el jugador de este cliente.
var huecos: Array = []
var nombre_jugador: String = ""
var personaje_jugador: StringName = &""

# --- tiempos (s)
var t_compra: float = 25.0
var t_ronda: float = 100.0
var t_fin_ronda: float = 5.0

# --- economia (creditos)
var dinero_inicial: int = 800
var dinero_max: int = 9000
var por_baja: int = 200
var por_victoria: int = 3000
var por_derrota: int = 1900
var por_derrota_consecutiva: int = 500
var derrota_max: int = 2900
var por_montar: int = 300
var por_alarma: int = 300
## Al cambiar de lado se reinicia la economia (800 y racha a 0) y el inventario.
var reiniciar_al_cambiar_lado: bool = true

# --- reglas
## Eliminacion: si se acaba el tiempo, gana quien tenga mas vivos (empate: defensores); si es falso, ganan los defensores.
var elim_gana_mas_vivos: bool = false


func es_libre() -> bool:
	return modo == MODO_LIBRE


## Modo para `ApiPartida.modo()`: &"cachimba", &"eliminacion" o &"libre".
func modo_partida() -> StringName:
	return MODO_LIBRE if es_libre() else submodo


## Rondas totales de la fase normal (7 para ganar -> 12). Con 7 ganadas de 12 el cambio de lado es tras la ronda 6.
func rondas_normales() -> int:
	return maxi(2 * (rondas_ganar - 1), 0)


## Ronda tras la cual se cambia de lado (0 = nunca).
func ronda_cambio_lado() -> int:
	return rondas_normales() / 2


## Recompensa por perder una ronda: 1900, 2400, 2900, 2900... (`consecutivas` cuenta la derrota actual).
func recompensa_derrota(consecutivas: int) -> int:
	return mini(por_derrota + por_derrota_consecutiva * maxi(consecutivas - 1, 0), derrota_max)


## Un hueco de equipo: {tipo: humano|bot, nombre, personaje, listo, local}. Preparado para jugadores en red (humanos no locales).
static func hueco(tipo: StringName, nombre: String = "", personaje: StringName = &"", listo: bool = false, local: bool = false) -> Dictionary:
	return {"tipo": tipo, "nombre": nombre, "personaje": personaje, "listo": listo, "local": local}


static func nombre_de_modo(id: StringName) -> String:
	for m: Array in MODOS:
		if m[0] == id:
			return str(m[1])
	return str(id)


## Id de modo del lobby (`M_*`) segun `modo` / `submodo`.
func id_modo() -> StringName:
	if es_libre():
		return M_LIBRE
	return M_PLENO if submodo == SUB_ELIMINACION else M_CACHIMBA_WARS


## Aplica un modo del lobby (`M_*`) a `modo` / `submodo`.
func aplicar_modo(id: StringName) -> void:
	modo = MODO_LIBRE if id == M_LIBRE else MODO_COMPETITIVO
	submodo = SUB_ELIMINACION if id == M_PLENO else SUB_CACHIMBA


## Nombre visible del modo actual.
func nombre_modo() -> String:
	return nombre_de_modo(id_modo())


## Huecos de los dos equipos: `huecos` si el lobby los dio; si no, los deducidos de `jugadores_por_equipo`, `grupo_jugador`,
## `con_jugador` y `rellenar_bots` (el jugador en el hueco 0 de su equipo). Los bots sin personaje lo reciben al azar con la semilla.
func huecos_efectivos() -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = semilla
	var res: Array = [[], []]
	for g in 2:
		var lista: Array = []
		if huecos.size() == 2:
			lista = (huecos[g] as Array).duplicate(true)
		else:
			for i in jugadores_por_equipo:
				if con_jugador and g == grupo_jugador and i == 0:
					lista.append(hueco(TIPO_HUMANO, nombre_jugador, personaje_jugador, true, true))
				elif g == grupo_jugador and not rellenar_bots:
					continue
				else:
					lista.append(hueco(TIPO_BOT))
		for h: Dictionary in lista:
			if StringName(h["personaje"]) == &"" or not CatalogoPersonajes.existe(StringName(h["personaje"])):
				h["personaje"] = CatalogoPersonajes.aleatorio(rng)
		res[g] = lista
	return res
