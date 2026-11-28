extends Node3D
## Envoltorio del .glb del blockout. Los nodos "-col" ya generan colisión trimesh al importar
## (Godot los convierte en StaticBody3D); aquí se oculta la malla del muro límite y se aplican los materiales
## procedurales (Materiales.aplicar). No tocan la geometría ni la colisión. Los coches del pack externo los dibuja
## `CochesExternos` encima de las colisiones del blockout (cuyas mallas oculta).

## Resultado de `CochesExternos.montar` ({coches, modelos, multimallas}); vacio si no hay pack.
var estadisticas_coches: Dictionary = {}


func _ready() -> void:
	for nombre: String in ["limite", "escaleras_rampa"]:   # mallas invisibles: la colisión (StaticBody3D hijo) se mantiene
		var oculto: Node = find_child(nombre, true, false)
		if oculto is MeshInstance3D:
			(oculto as MeshInstance3D).visible = false
	Materiales.aplicar(self)
	estadisticas_coches = CochesExternos.montar(self)
