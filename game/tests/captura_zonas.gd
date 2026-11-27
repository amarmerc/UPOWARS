extends "res://tests/captura.gd"
## Solo las capturas de las zonas competitivas y del aula al aire libre (necesita GPU: NO usar --headless). Uso:
##   Godot_console.exe --path game --script res://tests/captura_zonas.gd [-- <carpeta_salida>]
## Guarda zona_<id>.png, zona_<id>_lobby.png y aula_aire_libre.png (ver _zonas en captura.gd) en export/capturas por defecto.


func _ejecutar() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var salida: String = args[0] if args.size() > 0 else ProjectSettings.globalize_path("res://").path_join("../export/capturas")
	DirAccess.make_dir_recursive_absolute(salida)
	var main: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 10:
		await physics_frame
	main.menu.cerrar()
	main.hud.visible = false
	(main.get_node("Jugador") as Node3D).set_physics_process(false)
	var cam := Camera3D.new()
	cam.far = 4500.0
	cam.fov = 75.0
	main.add_child(cam)
	cam.make_current()
	await _zonas(main, cam, salida)
	quit(0)
