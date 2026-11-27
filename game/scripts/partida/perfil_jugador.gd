class_name PerfilJugador
extends RefCounted
## Perfil local del jugador (nombre y personaje), guardado en user://perfil.cfg. `ruta` se puede cambiar (los tests usan otra).

const NOMBRE_DEFECTO: String = "Jugador"
static var ruta: String = "user://perfil.cfg"


## {nombre: String, personaje: StringName}. Valores por defecto si no hay fichero.
static func cargar() -> Dictionary:
	var cf := ConfigFile.new()
	var nombre: String = NOMBRE_DEFECTO
	var pers: StringName = CatalogoPersonajes.PERSONAJES[0]["id"]
	if cf.load(ruta) == OK:
		nombre = str(cf.get_value("perfil", "nombre", NOMBRE_DEFECTO))
		var id: StringName = StringName(str(cf.get_value("perfil", "personaje", String(pers))))
		if CatalogoPersonajes.existe(id):
			pers = id
	return {"nombre": nombre, "personaje": pers}


static func guardar(nombre: String, personaje: StringName) -> void:
	var cf := ConfigFile.new()
	cf.set_value("perfil", "nombre", nombre)
	cf.set_value("perfil", "personaje", String(personaje))
	cf.save(ruta)
