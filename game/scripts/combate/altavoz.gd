class_name Altavoz
extends Node3D
## "Altavoz senuelo": durante `duracion` s (6) emite pasos y disparos falsos. Cada ruido se anuncia por
## `SenalesCombate.ruido(posicion, radio, fuente)` para que los bots lo oigan como cualquier otro ruido.

var duracion: float = 6.0
var radio: float = 45.0
var lanzador: Node = null
var t: float = 0.0
var ruidos_emitidos: int = 0

var _acum: float = 0.0
var _paso: bool = true
var _audio: AudioStreamPlayer3D


static func crear(ctx: Node, pos: Vector3, arma: ArmaDatos, quien: Node) -> Altavoz:
	var a := Altavoz.new()
	a.duracion = arma.duracion_efecto
	a.radio = arma.radio_efecto
	a.lanzador = quien
	Utilidades.mundo(ctx).add_child(a)
	a.global_position = pos
	return a


func _ready() -> void:
	add_to_group("altavoces")
	var caja := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.22, 0.3, 0.2)
	caja.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.16, 0.18)
	mat.emission_enabled = true
	mat.emission = Color(0.9, 0.55, 0.1)
	mat.emission_energy_multiplier = 0.6
	caja.material_override = mat
	caja.position = Vector3(0, 0.15, 0)
	add_child(caja)
	_audio = AudioStreamPlayer3D.new()
	_audio.max_distance = 70.0
	_audio.unit_size = 6.0
	if ResourceLoader.exists("res://assets/sonidos/altavoz.wav"):
		_audio.stream = load("res://assets/sonidos/altavoz.wav")
	add_child(_audio)
	if _audio.stream != null:
		_audio.play()


func _physics_process(delta: float) -> void:
	avanzar(delta)


func avanzar(delta: float) -> void:
	t += delta
	_acum += delta
	while _acum >= 0.35:
		_acum -= 0.35
		ruidos_emitidos += 1
		# pasos (radio corto) y de vez en cuando un disparo falso (radio largo)
		var disparo: bool = ruidos_emitidos % 4 == 0
		SenalesCombate.obtener(get_tree()).ruido.emit(global_position, radio if disparo else radio * 0.4, self)
		_paso = not _paso
	if _audio != null and _audio.stream != null and not _audio.playing and t < duracion:
		_audio.play()
	if t >= duracion:
		remove_from_group("altavoces")
		queue_free()
