extends Node3D
## Envoltorio del .glb del blockout. Los nodos "-col" ya generan colisión trimesh al importar
## (Godot los convierte en StaticBody3D); aquí se oculta la malla del muro límite y se aplican los materiales
## procedurales (Materiales.aplicar). No tocan la geometría ni la colisión.


func _ready() -> void:
	for nombre: String in ["limite", "escaleras_rampa"]:   # mallas invisibles: la colisión (StaticBody3D hijo) se mantiene
		var oculto: Node = find_child(nombre, true, false)
		if oculto is MeshInstance3D:
			(oculto as MeshInstance3D).visible = false
	Materiales.aplicar(self)
