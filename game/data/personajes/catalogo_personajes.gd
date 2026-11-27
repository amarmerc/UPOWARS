class_name CatalogoPersonajes
extends RefCounted
## Registro de personajes jugables (los 12 del pack Quaternius "Ultimate Modular Men", ver `ModeloPersonaje`). El cuerpo en partida y
## los retratos del lobby se construyen SIEMPRE con `ModeloPersonaje.crear`. Los ids son estables (se guardan en el perfil del jugador).

## Los 12 personajes predefinidos del pack Quaternius "Ultimate Modular Men" (humans_master.fbx), con su aspecto original. Cada uno
## nombra las mallas del fbx que lo forman (cabeza / cuerpo / piernas / pies, mas `extras`); el Caballo es la cabeza de caballo sobre
## el cuerpo de Casual2 (el pack no trae cuerpo propio para ella). El color del equipo se anade aparte (brazaletes, `ModeloPersonaje`).
const PERSONAJES: Array = [
	{"id": &"caballo", "nombre": "Caballo", "cabeza": "Horse_Head", "cuerpo": "Casual2_Body", "piernas": "Casual2_Legs", "pies": "Casual2_Feet"},
	{"id": &"ejecutivo", "nombre": "Ejecutivo", "cabeza": "Suit_Head", "cuerpo": "Suit_Body", "piernas": "Suit_Legs", "pies": "Suit_Feet"},
	{"id": &"granjero", "nombre": "Granjero", "cabeza": "Farmer_Head", "cuerpo": "Farmer_Body", "piernas": "Farmer_Pants", "pies": "Farmer_Feet"},
	{"id": &"soldado", "nombre": "Soldado", "cabeza": "Swat_Head", "cuerpo": "Swat_Body", "piernas": "Swat_Legs", "pies": "Swat_Feet"},
	{"id": &"mochilero", "nombre": "Mochilero", "cabeza": "Adventurer_Head", "cuerpo": "Adventurer_Body", "piernas": "Adventurer_Legs", "pies": "Adventurer_Feet", "extras": ["Backpack"]},
	{"id": &"astronauta", "nombre": "Astronauta", "cabeza": "SpaceSuit_Head", "cuerpo": "SpaceSuit_Body", "piernas": "SpaceSuit_Legs", "pies": "SpaceSuit_Feet"},
	{"id": &"estudiante", "nombre": "Estudiante", "cabeza": "Casual_Head", "cuerpo": "Casual_Body", "piernas": "Casual_Legs", "pies": "Casual_Feet"},
	{"id": &"rey", "nombre": "Rey", "cabeza": "King_Head", "cuerpo": "King_Body", "piernas": "King_Legs", "pies": "King_Feet"},
	{"id": &"obrero", "nombre": "Obrero", "cabeza": "Worker_Head", "cuerpo": "Worker_Body", "piernas": "Worker_Legs", "pies": "Worker_Feet"},
	{"id": &"punk", "nombre": "Punk", "cabeza": "Punk_Head", "cuerpo": "Punk_Body", "piernas": "Punk_Legs", "pies": "Punk_Feet"},
	{"id": &"playero", "nombre": "Playero", "cabeza": "Beach_Head", "cuerpo": "Beach_Body", "piernas": "Beach_Legs", "pies": "Beach_Feet"},
	{"id": &"becario", "nombre": "Becario", "cabeza": "Casual2_Head", "cuerpo": "Casual2_Body", "piernas": "Casual2_Legs", "pies": "Casual2_Feet"},
]
## Personaje gris de los huecos de bot en el lobby (no se puede elegir).
const GENERICO: Dictionary = {"id": &"_bot", "nombre": "Bot", "cabeza": "SpaceSuit_Head", "cuerpo": "SpaceSuit_Body",
		"piernas": "SpaceSuit_Legs", "pies": "SpaceSuit_Feet", "ropa": Color(0.55, 0.58, 0.64), "piel": Color(0.78, 0.8, 0.84),
		"pelo": Color(0.4, 0.42, 0.48), "silueta": &"normal", "peinado": &"calvo"}


static func todos() -> Array:
	return PERSONAJES


static func ids() -> Array[StringName]:
	var r: Array[StringName] = []
	for p: Dictionary in PERSONAJES:
		r.append(p["id"])
	return r


## Datos del personaje `id` (el generico para `_bot`; el primero si el id no existe).
static func por_id(id: StringName) -> Dictionary:
	if id == GENERICO["id"]:
		return GENERICO
	for p: Dictionary in PERSONAJES:
		if p["id"] == id:
			return p
	return PERSONAJES[0]


static func existe(id: StringName) -> bool:
	return ids().has(id)


## Id al azar con el RNG dado (el de la partida: misma semilla, mismos personajes).
static func aleatorio(rng: RandomNumberGenerator) -> StringName:
	return PERSONAJES[rng.randi() % PERSONAJES.size()]["id"]


## Id del personaje anterior / siguiente (dir = -1 / +1), circular.
static func vecino(id: StringName, dir: int) -> StringName:
	var i: int = ids().find(id)
	i = 0 if i < 0 else i
	return PERSONAJES[posmod(i + dir, PERSONAJES.size())]["id"]
