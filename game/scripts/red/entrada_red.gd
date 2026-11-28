class_name EntradaRed
extends RefCounted
## Una entrada de un tick que el cliente manda al servidor: ejes de movimiento, botones, angulo del cuerpo (yaw), mira de la camara
## (con retroceso) y la marca temporal de lo que el jugador VE (hora de servidor, ms) para la compensacion de latencia al disparar.
## Se empaqueta en 16 bytes (`escribir` / `leer`).

const B_SALTAR: int = 1
const B_CORRER: int = 2
const B_SIGILO: int = 4
const B_AGACHAR: int = 8
const B_DISPARAR: int = 16
const B_APUNTAR: int = 32
const TAM: int = 16

var seq: int = 0
## Ejes -127..127 (mx: derecha +; mz: atras +, como `Input.get_vector`).
var mx: int = 0
var mz: int = 0
var botones: int = 0
## Yaw del cuerpo (rad, [-PI, PI)).
var yaw: float = 0.0
## Mira de la camara (yaw / pitch en rad, con retroceso): la direccion real de los disparos.
var mira_yaw: float = 0.0
var mira_pitch: float = 0.0
## Hora de servidor (ms) que veia el jugador al generar la entrada.
var t_vista: int = 0


func saltar() -> bool:
	return botones & B_SALTAR != 0


func correr() -> bool:
	return botones & B_CORRER != 0


func sigilo() -> bool:
	return botones & B_SIGILO != 0


func agachar() -> bool:
	return botones & B_AGACHAR != 0


func disparar() -> bool:
	return botones & B_DISPARAR != 0


func apuntar() -> bool:
	return botones & B_APUNTAR != 0


func mx_f() -> float:
	return clampf(float(mx) / 127.0, -1.0, 1.0)


func mz_f() -> float:
	return clampf(float(mz) / 127.0, -1.0, 1.0)


func mira_dir() -> Vector3:
	return Vector3(-sin(mira_yaw) * cos(mira_pitch), sin(mira_pitch), -cos(mira_yaw) * cos(mira_pitch))


func copiar() -> EntradaRed:
	var o := EntradaRed.new()
	o.seq = seq
	o.mx = mx
	o.mz = mz
	o.botones = botones
	o.yaw = yaw
	o.mira_yaw = mira_yaw
	o.mira_pitch = mira_pitch
	o.t_vista = t_vista
	return o


static func _ang_u16(a: float) -> int:
	return int(roundf(wrapf(a, -PI, PI) / TAU * 65536.0)) & 0xFFFF


static func _u16_ang(v: int) -> float:
	var x: int = v if v < 32768 else v - 65536
	return float(x) / 65536.0 * TAU


func escribir(b: PackedByteArray, off: int) -> void:
	b.encode_u32(off, seq)
	b.encode_u16(off + 4, botones)
	b.encode_s8(off + 6, clampi(mx, -127, 127))
	b.encode_s8(off + 7, clampi(mz, -127, 127))
	b.encode_u16(off + 8, _ang_u16(yaw))
	b.encode_u16(off + 10, _ang_u16(mira_yaw))
	b.encode_s16(off + 12, clampi(int(roundf(mira_pitch * 10000.0)), -15700, 15700))
	b.encode_u16(off + 14, t_vista & 0xFFFF)


## Lee una entrada. `t_ref` = hora de servidor (ms) de referencia para reconstruir los 32 bits de `t_vista` (se guardan 16: +-32 s).
static func leer(b: PackedByteArray, off: int, t_ref: int) -> EntradaRed:
	var e := EntradaRed.new()
	e.seq = b.decode_u32(off)
	e.botones = b.decode_u16(off + 4)
	e.mx = b.decode_s8(off + 6)
	e.mz = b.decode_s8(off + 7)
	e.yaw = _u16_ang(b.decode_u16(off + 8))
	e.mira_yaw = _u16_ang(b.decode_u16(off + 10))
	e.mira_pitch = float(b.decode_s16(off + 12)) / 10000.0
	var bajo: int = b.decode_u16(off + 14)
	var base: int = t_ref - (t_ref & 0xFFFF)
	var t: int = base + bajo
	if t - t_ref > 32768:
		t -= 65536
	elif t_ref - t > 32768:
		t += 65536
	e.t_vista = t
	return e
