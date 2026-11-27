extends SceneTree
## Regenera los iconos de la tienda (game/assets/iconos/<id>.png) renderizando los modelos del viewmodel actual (`ViewmodelCapa`).
## Hay que volver a ejecutarlo cada vez que cambien los modelos de las armas. Necesita GPU: NO usar --headless. Uso:
##   Godot_console.exe --path game --script res://tests/generar_iconos.gd
## y despues `--headless --path game --import` para que Godot importe los PNG nuevos. Los articulos sin modelo (escudos) no tienen
## icono: la tienda dibuja el suyo.

const SALIDA: String = "res://assets/iconos"
const TAM: Vector2i = Vector2i(256, 128)


func _init() -> void:
	_ejecutar.call_deferred()


func _ejecutar() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SALIDA))
	var vm := ViewmodelCapa.new()
	root.add_child(vm)
	await process_frame
	var n: int = 0
	for id: StringName in vm.ids_modelo():
		var sv: SubViewport = vm.preparar_icono(id, TAM)
		if sv == null:
			continue
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var img: Image = sv.get_texture().get_image()
		var ruta: String = ProjectSettings.globalize_path(SALIDA).path_join("%s.png" % String(id))
		img.save_png(ruta)
		n += 1
		print("icono ", id)
	print("RESULTADO: %d iconos en %s" % [n, SALIDA])
	quit(0 if n > 0 else 1)
