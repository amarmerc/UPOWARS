extends Node3D
## Envoltorio del .glb del blockout. Los nodos "-col" ya generan colisión trimesh al importar
## (Godot los convierte en StaticBody3D); aquí se oculta la malla del muro límite y se aplican los materiales
## procedurales (Materiales.aplicar). No tocan la geometría ni la colisión.


func _ready() -> void:
	var limite: Node = find_child("limite", true, false)
	if limite is MeshInstance3D:
		(limite as MeshInstance3D).visible = false  # la colisión (StaticBody3D hijo) se mantiene
	Materiales.aplicar(self)
