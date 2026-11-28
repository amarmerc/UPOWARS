class_name Cachimba
extends Node3D
## "La Cachimba" (modo Cachimba): estado y temporizadores. Pieza minima y provisional para probar los bots sin la Partida (P4), que
## puede adoptarla o sustituirla. No decide quien puede montar o apagar (eso lo valida `ApiPartida`): solo avanza con `avanzar(dt)`.
## Estados: SIN_MONTAR -> MONTANDO (4 s, el atacante quieto en un site) -> MONTADA (cuenta atras de 40 s) -> APAGANDO (7 s, un
## defensor quieto a su lado; si se interrumpe vuelve a MONTADA) -> APAGADA, o ALARMA si la cuenta llega a 0 (suena la alarma de
## incendios: no explota). Mientras esta montada emite pitidos como ruido (`SenalesCombate.ruido`, fuente = este nodo).

signal montada(site: String)
signal apagada
signal alarma

enum Estado { SIN_MONTAR, MONTANDO, MONTADA, APAGANDO, APAGADA, ALARMA }

const T_MONTAR: float = 4.0
const T_TEMPORIZADOR: float = 40.0
const T_APAGAR: float = 7.0
const RADIO_APAGAR: float = 2.5
const RADIO_RUIDO: float = 80.0
const INTERVALO_PITIDO: float = 3.0

var estado: Estado = Estado.SIN_MONTAR
var site: String = ""
## Segundos de montaje o de apagado acumulados.
var progreso: float = 0.0
## Segundos que quedan para la alarma (solo MONTADA / APAGANDO).
var restante: float = T_TEMPORIZADOR
var montador: Node = null
var apagador: Node = null

var _pitido: float = 0.0
var _etiqueta: Label3D
var _malla: MeshInstance3D
var _mat: StandardMaterial3D


func _ready() -> void:
	add_to_group("cachimba")
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.9, 0.55, 0.15)
	_mat.emission_enabled = true
	_mat.emission = Color(1.0, 0.5, 0.1)
	_mat.emission_energy_multiplier = 0.8
	_malla = MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.18
	cm.bottom_radius = 0.28
	cm.height = 0.7
	_malla.mesh = cm
	_malla.material_override = _mat
	_malla.position = Vector3(0, 0.35, 0)
	add_child(_malla)
	_etiqueta = Label3D.new()
	_etiqueta.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_etiqueta.no_depth_test = true
	_etiqueta.fixed_size = true
	_etiqueta.pixel_size = 0.0012
	_etiqueta.font_size = 48
	_etiqueta.outline_size = 12
	_etiqueta.position = Vector3(0, 1.3, 0)
	add_child(_etiqueta)
	_actualizar_visual()


func reiniciar() -> void:
	estado = Estado.SIN_MONTAR
	site = ""
	progreso = 0.0
	restante = T_TEMPORIZADOR
	montador = null
	apagador = null
	_pitido = 0.0
	_actualizar_visual()


func esta_montada() -> bool:
	return estado == Estado.MONTADA or estado == Estado.APAGANDO


func empezar_montaje(quien: Node) -> void:
	if estado == Estado.SIN_MONTAR:
		estado = Estado.MONTANDO
		progreso = 0.0
		montador = quien
		SenalesCombate.obtener(get_tree()).ruido.emit(global_position, RADIO_RUIDO, self)
	_actualizar_visual()


func cancelar_montaje() -> void:
	if estado == Estado.MONTANDO:
		estado = Estado.SIN_MONTAR
		progreso = 0.0
		montador = null
		_actualizar_visual()


func empezar_apagado(quien: Node) -> void:
	if estado == Estado.MONTADA:
		estado = Estado.APAGANDO
		progreso = 0.0
		apagador = quien
		_actualizar_visual()


func cancelar_apagado() -> void:
	if estado == Estado.APAGANDO:
		estado = Estado.MONTADA
		progreso = 0.0
		apagador = null
		_actualizar_visual()


## Monta instantaneamente en `pos` (pruebas, o al terminar los 4 s).
func montar_en(pos: Vector3, site_id: String) -> void:
	global_position = pos
	site = site_id
	estado = Estado.MONTADA
	progreso = 0.0
	restante = T_TEMPORIZADOR
	_pitido = 0.0
	SenalesCombate.obtener(get_tree()).ruido.emit(pos, RADIO_RUIDO, self)
	montada.emit(site_id)
	_actualizar_visual()


## Avanza `dt` s. `montando` / `apagando`: la Partida confirma que la condicion (quieto, en el sitio) se cumple este tick.
func avanzar(dt: float, montando: bool = false, apagando: bool = false) -> void:
	match estado:
		Estado.MONTANDO:
			if not montando:
				cancelar_montaje()
				return
			progreso += dt
			if progreso >= T_MONTAR:
				montar_en(global_position, site)
		Estado.MONTADA, Estado.APAGANDO:
			restante -= dt
			_pitido += dt
			if _pitido >= INTERVALO_PITIDO:
				_pitido -= INTERVALO_PITIDO
				SenalesCombate.obtener(get_tree()).ruido.emit(global_position, RADIO_RUIDO, self)
			if estado == Estado.APAGANDO:
				if not apagando:
					cancelar_apagado()
				else:
					progreso += dt
					if progreso >= T_APAGAR:
						estado = Estado.APAGADA
						_actualizar_visual()
						apagada.emit()
						return
			if restante <= 0.0:
				estado = Estado.ALARMA
				restante = 0.0
				_actualizar_visual()
				alarma.emit()
	if esta_montada() or estado == Estado.MONTANDO:
		_actualizar_visual()


func _actualizar_visual() -> void:
	if _etiqueta == null:
		return
	visible = estado != Estado.SIN_MONTAR
	match estado:
		Estado.MONTANDO:
			_etiqueta.text = "Montando %.0f%%" % (progreso / T_MONTAR * 100.0)
			_mat.emission = Color(1.0, 0.85, 0.2)
		Estado.MONTADA:
			_etiqueta.text = "CACHIMBA %s  %.0f s" % [site, restante]
			_mat.emission = Color(1.0, 0.4, 0.1)
		Estado.APAGANDO:
			_etiqueta.text = "Apagando %.0f%%  (%.0f s)" % [progreso / T_APAGAR * 100.0, restante]
			_mat.emission = Color(0.3, 0.7, 1.0)
		Estado.APAGADA:
			_etiqueta.text = "Apagada"
			_mat.emission = Color(0.2, 0.2, 0.25)
		Estado.ALARMA:
			_etiqueta.text = "ALARMA"
			_mat.emission = Color(1.0, 0.1, 0.1)
