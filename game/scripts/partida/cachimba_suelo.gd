class_name CachimbaSuelo
extends Node3D
## "La Cachimba" caida al morir su portador: hay que recogerla (acercarse) para poder montarla. Solo la malla y la etiqueta.

const RADIO_RECOGER: float = 2.0


func _ready() -> void:
	add_to_group("cachimba_suelo")
	var m := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.12
	cm.bottom_radius = 0.2
	cm.height = 0.5
	m.mesh = cm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.55, 0.15)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.55, 0.1)
	mat.emission_energy_multiplier = 1.4
	m.material_override = mat
	m.position = Vector3(0, 0.25, 0)
	add_child(m)
	var e := Label3D.new()
	e.text = "CACHIMBA (recoger)"
	e.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	e.no_depth_test = true
	e.fixed_size = true
	e.pixel_size = 0.0012
	e.font_size = 40
	e.outline_size = 10
	e.modulate = Color(1.0, 0.8, 0.4)
	e.position = Vector3(0, 1.0, 0)
	add_child(e)
