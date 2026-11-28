extends SceneTree
## Carga los scripts indicados (o todos los de red) para ver errores de parseo. Uso: --script res://tests/comprobar_scripts.gd
func _init() -> void:
	var lista: Array[String] = []
	for f in DirAccess.get_files_at("res://scripts/red"):
		if f.ends_with(".gd"):
			lista.append("res://scripts/red/" + f)
	lista.append_array(["res://scripts/player.gd", "res://scripts/combate/gestor_armas.gd", "res://scripts/bots/bot.gd", "res://scripts/partida/partida.gd",
			"res://scripts/combate/proyectil.gd", "res://scripts/combate/lanzable.gd", "res://scripts/combate/utilidades.gd", "res://scripts/combate/contorno_enemigos.gd", "res://scripts/ui/lobby_ui.gd", "res://scripts/ui/chat_red.gd", "res://scripts/juego.gd"])
	var mal: int = 0
	for r in lista:
		var s: Script = load(r) as Script
		if s == null or not s.can_instantiate():
			print("ERROR cargando ", r)
			mal += 1
		else:
			print("ok ", r)
	quit(1 if mal > 0 else 0)
