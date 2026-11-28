class_name ProtoRed
extends RefCounted
## Formato binario compacto de los datos que van por la red (snapshots y entradas). Un snapshot lleva primero el bloque PROPIO del
## cliente (40 bytes: ultima entrada procesada, posicion y velocidad exactas, estado, vida, municion: para reconciliar la prediccion)
## y despues el bloque COMUN igual para todos (cabecera de la partida + una fila de 12 bytes por participante: id, estado, posicion
## a 1/32 m, yaw, pitch y arma en mano). Con 10 participantes ~ 200 bytes por snapshot; a 20 Hz son ~4 KB/s por cliente.

const PUERTO_DEFECTO: int = 7777
const VERSION: int = 1
const ESC_POS: float = 32.0
const TAM_PROPIO: int = 40
const TAM_CABECERA: int = 36
const TAM_ENTIDAD: int = 12
const SIN_PORTADOR: int = 255

# bits de flags de una entidad
const F_VIVO: int = 1
const F_AGACHADO: int = 2
const F_CORRIENDO: int = 4
## bits 3-4: lado (0 libre, 1 atacantes, 2 defensores)
const F_LADO_SHIFT: int = 3
# bits de flags del bloque propio
const P_AGACHADO: int = 1
const P_EN_SUELO: int = 2
const P_CORRIENDO: int = 4
const P_SALTAR_PREV: int = 8
const P_VIVO: int = 16
const P_APUNTANDO: int = 32


static func id_arma(id: StringName) -> int:
	for i in Catalogo.ITEMS.size():
		if Catalogo.ITEMS[i][0] == id:
			return i
	return 255


static func arma_de_indice(i: int) -> StringName:
	if i >= 0 and i < Catalogo.ITEMS.size():
		return Catalogo.ITEMS[i][0]
	return &""


static func _q(x: float) -> int:
	return clampi(int(roundf(x * ESC_POS)), -32767, 32767)


static func _ang_u16(a: float) -> int:
	return int(roundf(wrapf(a, 0.0, TAU) / TAU * 65536.0)) & 0xFFFF


static func _u16_ang(v: int) -> float:
	return float(v) / 65536.0 * TAU


## Bloque comun: `cab` = {tick, t_ms, fase, t_fase, ronda, puntos: [a, b], lado0, cach_estado, cach_site, cach_restante, cach_progreso,
## cach_pos, portador, caida (Vector3 o null)}; `ents` = Array de {id, vivo, agachado, corriendo, lado, pos, yaw, pitch, arma}.
static func codificar_comun(cab: Dictionary, ents: Array) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(TAM_CABECERA + 1 + ents.size() * TAM_ENTIDAD)
	b.encode_u32(0, int(cab["tick"]))
	b.encode_u32(4, int(cab["t_ms"]))
	b.encode_u8(8, int(cab["fase"]))
	b.encode_s16(9, clampi(int(roundf(float(cab["t_fase"]) * 10.0)), -32000, 32000))
	b.encode_u8(11, int(cab["ronda"]))
	b.encode_u8(12, int(cab["puntos"][0]))
	b.encode_u8(13, int(cab["puntos"][1]))
	b.encode_u8(14, int(cab["lado0"]))
	b.encode_u8(15, int(cab["cach_estado"]))
	b.encode_u8(16, int(cab["cach_site"]))
	b.encode_u16(17, clampi(int(roundf(float(cab["cach_restante"]) * 10.0)), 0, 65535))
	b.encode_u16(19, clampi(int(roundf(float(cab["cach_progreso"]) * 10.0)), 0, 65535))
	var cp: Vector3 = cab["cach_pos"]
	b.encode_s16(21, _q(cp.x))
	b.encode_s16(23, _q(cp.y))
	b.encode_s16(25, _q(cp.z))
	b.encode_u8(27, int(cab["portador"]))
	var caida: Variant = cab["caida"]
	b.encode_u8(28, 1 if caida != null else 0)
	var cv: Vector3 = caida if caida != null else Vector3.ZERO
	b.encode_s16(29, _q(cv.x))
	b.encode_s16(31, _q(cv.y))
	b.encode_s16(33, _q(cv.z))
	b.encode_u8(35, 0)
	b.encode_u8(TAM_CABECERA, ents.size())
	var o: int = TAM_CABECERA + 1
	for e: Dictionary in ents:
		b.encode_u8(o, int(e["id"]))
		var f: int = (F_VIVO if e["vivo"] else 0) | (F_AGACHADO if e["agachado"] else 0) | (F_CORRIENDO if e["corriendo"] else 0)
		f |= (int(e["lado"]) & 3) << F_LADO_SHIFT
		b.encode_u8(o + 1, f)
		var p: Vector3 = e["pos"]
		b.encode_s16(o + 2, _q(p.x))
		b.encode_s16(o + 4, _q(p.y))
		b.encode_s16(o + 6, _q(p.z))
		b.encode_u16(o + 8, _ang_u16(float(e["yaw"])))
		b.encode_s8(o + 10, clampi(int(roundf(float(e["pitch"]) / (PI * 0.5) * 127.0)), -127, 127))
		b.encode_u8(o + 11, int(e["arma"]))
		o += TAM_ENTIDAD
	return b


## Bloque propio: {ack, pos, vel, ojos_y, flags, vida, escudo, cargador, reserva, epoch (sube al teletransportar al jugador: el cliente descarta su prediccion)}.
static func codificar_propio(p: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(TAM_PROPIO)
	b.encode_u32(0, int(p["ack"]))
	var pos: Vector3 = p["pos"]
	var vel: Vector3 = p["vel"]
	b.encode_float(4, pos.x)
	b.encode_float(8, pos.y)
	b.encode_float(12, pos.z)
	b.encode_half(16, vel.x)
	b.encode_half(18, vel.y)
	b.encode_half(20, vel.z)
	b.encode_u8(22, clampi(int(roundf((float(p["ojos_y"]) - 0.5) * 100.0)), 0, 255))
	b.encode_u8(23, int(p["flags"]))
	b.encode_u8(24, clampi(int(roundf(float(p["vida"]))), 0, 255))
	b.encode_u8(25, clampi(int(roundf(float(p["escudo"]))), 0, 255))
	b.encode_u16(26, clampi(int(p["cargador"]), 0, 65535))
	b.encode_u16(28, clampi(int(p["reserva"]), 0, 65535))
	b.encode_u8(30, int(p["epoch"]) & 0xFF)
	b.encode_u8(31, int(p["arma"]))
	return b


static func decodificar(b: PackedByteArray) -> Dictionary:
	if b.size() < TAM_PROPIO + TAM_CABECERA + 1:
		return {}
	var r: Dictionary = {}
	r["propio"] = {"ack": b.decode_u32(0), "pos": Vector3(b.decode_float(4), b.decode_float(8), b.decode_float(12)),
			"vel": Vector3(b.decode_half(16), b.decode_half(18), b.decode_half(20)),
			"ojos_y": float(b.decode_u8(22)) / 100.0 + 0.5, "flags": b.decode_u8(23), "vida": b.decode_u8(24),
			"escudo": b.decode_u8(25), "cargador": b.decode_u16(26), "reserva": b.decode_u16(28), "epoch": b.decode_u8(30), "arma": b.decode_u8(31)}
	var c: int = TAM_PROPIO
	r["tick"] = b.decode_u32(c)
	r["t_ms"] = b.decode_u32(c + 4)
	r["fase"] = b.decode_u8(c + 8)
	r["t_fase"] = float(b.decode_s16(c + 9)) / 10.0
	r["ronda"] = b.decode_u8(c + 11)
	r["puntos"] = [b.decode_u8(c + 12), b.decode_u8(c + 13)]
	r["lado0"] = b.decode_u8(c + 14)
	r["cach_estado"] = b.decode_u8(c + 15)
	r["cach_site"] = b.decode_u8(c + 16)
	r["cach_restante"] = float(b.decode_u16(c + 17)) / 10.0
	r["cach_progreso"] = float(b.decode_u16(c + 19)) / 10.0
	r["cach_pos"] = Vector3(float(b.decode_s16(c + 21)), float(b.decode_s16(c + 23)), float(b.decode_s16(c + 25))) / ESC_POS
	r["portador"] = b.decode_u8(c + 27)
	r["caida"] = (Vector3(float(b.decode_s16(c + 29)), float(b.decode_s16(c + 31)), float(b.decode_s16(c + 33))) / ESC_POS) if b.decode_u8(c + 28) != 0 else null
	var n: int = b.decode_u8(c + TAM_CABECERA)
	var ents: Array = []
	var o: int = c + TAM_CABECERA + 1
	for i in n:
		if o + TAM_ENTIDAD > b.size():
			break
		var f: int = b.decode_u8(o + 1)
		ents.append({"id": b.decode_u8(o), "vivo": f & F_VIVO != 0, "agachado": f & F_AGACHADO != 0, "corriendo": f & F_CORRIENDO != 0,
				"lado": (f >> F_LADO_SHIFT) & 3,
				"pos": Vector3(float(b.decode_s16(o + 2)), float(b.decode_s16(o + 4)), float(b.decode_s16(o + 6))) / ESC_POS,
				"yaw": _u16_ang(b.decode_u16(o + 8)), "pitch": float(b.decode_s8(o + 10)) / 127.0 * PI * 0.5, "arma": b.decode_u8(o + 11)})
		o += TAM_ENTIDAD
	r["ents"] = ents
	return r


## Paquete de entradas: u8 n + n entradas de 16 bytes. Lleva las `n` ultimas (redundancia contra la perdida de paquetes).
static func empaquetar_entradas(lista: Array) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(1 + lista.size() * EntradaRed.TAM)
	b.encode_u8(0, lista.size())
	for i in lista.size():
		(lista[i] as EntradaRed).escribir(b, 1 + i * EntradaRed.TAM)
	return b


static func desempaquetar_entradas(b: PackedByteArray, t_ref: int) -> Array:
	var out: Array = []
	if b.size() < 1:
		return out
	var n: int = mini(b.decode_u8(0), 12)
	for i in n:
		var o: int = 1 + i * EntradaRed.TAM
		if o + EntradaRed.TAM > b.size():
			break
		out.append(EntradaRed.leer(b, o, t_ref))
	return out
