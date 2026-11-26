extends Node3D
## Envoltorio del .glb del blockout. Los nodos "-col" ya generan colisión trimesh al importar
## (Godot los convierte en StaticBody3D); aquí solo se oculta la malla del muro límite.


func _ready() -> void:
	var limite: Node = find_child("limite", true, false)
	if limite is MeshInstance3D:
		(limite as MeshInstance3D).visible = false  # la colisión (StaticBody3D hijo) se mantiene
