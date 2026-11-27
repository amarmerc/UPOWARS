"""Genera los sonidos sinteticos del juego (numpy + wave, sin descargas) en game/assets/sonidos/.

Semilla fija: misma salida cada vez. WAV mono de 16 bits a 44,1 kHz.
Uso: uv run python scripts/generar_sonidos.py [--semilla 7] [--salida game/assets/sonidos]
Luego reimportar en Godot (godot --headless --path game --import).
"""
import argparse
import wave
from pathlib import Path

import numpy as np

SR = 44100


def t_(dur):
    return np.arange(int(SR * dur)) / SR


def env(dur, ataque=0.002, decay=0.05):
    """Ataque lineal corto y caida exponencial."""
    t = t_(dur)
    return np.minimum(t / max(ataque, 1e-6), 1.0) * np.exp(-t / decay)


def lowpass(x, k):
    """Media movil simple de k muestras (filtro paso bajo barato)."""
    if k <= 1:
        return x
    return np.convolve(x, np.ones(k) / k, mode="same")


def ruido(rng, dur):
    return rng.uniform(-1, 1, int(SR * dur))


def disparo_fusil(rng):
    dur = 0.35
    t = t_(dur)
    crack = lowpass(ruido(rng, dur), 3) * env(dur, 0.0008, 0.018)
    cuerpo = lowpass(ruido(rng, dur), 28) * env(dur, 0.001, 0.09) * 1.6
    thump = np.sin(2 * np.pi * (70 * np.exp(-t * 12) + 40) * t) * env(dur, 0.001, 0.07)
    return 0.55 * crack + 0.7 * cuerpo + 0.8 * thump


def disparo_pistola(rng):
    dur = 0.28
    t = t_(dur)
    crack = lowpass(ruido(rng, dur), 2) * env(dur, 0.0006, 0.012)
    cuerpo = lowpass(ruido(rng, dur), 14) * env(dur, 0.001, 0.06) * 1.3
    thump = np.sin(2 * np.pi * (110 * np.exp(-t * 18) + 60) * t) * env(dur, 0.001, 0.045)
    return 0.6 * crack + 0.6 * cuerpo + 0.6 * thump


def navaja(rng):
    dur = 0.25
    t = t_(dur)
    barrido = lowpass(ruido(rng, dur), 5) * np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 2
    tono = np.sin(2 * np.pi * (900 + 1500 * t / dur) * t) * np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 2
    return 0.7 * barrido + 0.12 * tono


def clic(rng, dur=0.03, f=2200.0, dec=0.006):
    t = t_(dur)
    return (np.sin(2 * np.pi * f * t) * 0.6 + lowpass(ruido(rng, dur), 2) * 0.4) * env(dur, 0.0003, dec)


def recarga(rng):
    # sacar cargador (golpe seco), pausa, meter cargador (golpe + clic metalico), cerrojo
    out = np.zeros(int(SR * 1.2))

    def pon(s, t0):
        i = int(SR * t0)
        out[i:i + len(s)] += s[:len(out) - i]
    pon(clic(rng, 0.06, 700, 0.015) * 1.1, 0.10)
    pon(lowpass(ruido(rng, 0.12), 12) * env(0.12, 0.002, 0.03) * 0.5, 0.45)
    pon(clic(rng, 0.05, 1500, 0.01) * 1.2, 0.70)
    pon(clic(rng, 0.07, 900, 0.02) * 1.3, 0.95)
    pon(clic(rng, 0.03, 2600, 0.006) * 0.8, 1.05)
    return out


def impacto_superficie(rng):
    dur = 0.22
    t = t_(dur)
    polvo = lowpass(ruido(rng, dur), 8) * env(dur, 0.0005, 0.03)
    golpe = np.sin(2 * np.pi * 180 * t) * env(dur, 0.0005, 0.025)
    chispa = clic(rng, dur, 3800, 0.012)
    return 0.7 * polvo + 0.5 * golpe + 0.25 * chispa


def impacto_carne(rng):
    dur = 0.2
    t = t_(dur)
    sordo = lowpass(ruido(rng, dur), 30) * env(dur, 0.001, 0.05)
    golpe = np.sin(2 * np.pi * (140 * np.exp(-t * 15) + 60) * t) * env(dur, 0.001, 0.06)
    tic = np.sin(2 * np.pi * 1300 * t) * env(dur, 0.0005, 0.02)  # marca de acierto
    return 0.6 * sordo + 0.8 * golpe + 0.3 * tic


def cambio_arma(rng):
    out = np.zeros(int(SR * 0.4))
    s1 = clic(rng, 0.05, 1100, 0.012) * 1.0
    s2 = clic(rng, 0.06, 1700, 0.014) * 0.9
    out[int(SR * 0.02):int(SR * 0.02) + len(s1)] += s1
    out[int(SR * 0.17):int(SR * 0.17) + len(s2)] += s2
    out += lowpass(ruido(rng, 0.4), 10) * env(0.4, 0.05, 0.08) * 0.12
    return out


def disparo_gen(rng, dur, crack, cuerpo, thump, ecos=()):
    """Disparo generico: crack (k, decay, ganancia), cuerpo (k, decay, ganancia), thump (f0, f1, decay, ganancia) y ecos
    [(retardo s, ganancia)] que alargan la cola (sonido de campo abierto)."""
    t = t_(dur)
    x = (crack[2] * lowpass(ruido(rng, dur), crack[0]) * env(dur, 0.0006, crack[1])
         + cuerpo[2] * lowpass(ruido(rng, dur), cuerpo[0]) * env(dur, 0.001, cuerpo[1])
         + thump[3] * np.sin(2 * np.pi * (thump[0] * np.exp(-t * 14) + thump[1]) * t) * env(dur, 0.001, thump[2]))
    for retardo, g in ecos:
        i = int(SR * retardo)
        x[i:] += g * lowpass(x[:len(x) - i], 40)
    return x


def disparo_subfusil(rng):
    return disparo_gen(rng, 0.2, (2, 0.008, 0.6), (12, 0.04, 1.1), (130, 70, 0.03, 0.5))


def disparo_pesada(rng):
    return disparo_gen(rng, 0.55, (2, 0.015, 0.7), (22, 0.12, 1.5), (80, 45, 0.11, 1.0), [(0.09, 0.25)])


def disparo_combate(rng):
    return disparo_gen(rng, 0.5, (3, 0.02, 0.6), (26, 0.1, 1.5), (60, 38, 0.1, 1.0), [(0.12, 0.2)])


def disparo_precision(rng):
    return disparo_gen(rng, 1.0, (2, 0.02, 0.8), (30, 0.14, 1.5), (55, 32, 0.14, 1.1), [(0.18, 0.3), (0.4, 0.15)])


def disparo_escopeta(rng):
    return disparo_gen(rng, 0.6, (3, 0.02, 0.5), (36, 0.16, 2.0), (70, 36, 0.12, 1.2), [(0.1, 0.2)])


def disparo_ametralladora(rng):
    return disparo_gen(rng, 0.28, (3, 0.012, 0.6), (30, 0.06, 1.4), (65, 40, 0.06, 1.0))


def disparo_cohete(rng):
    dur = 1.0
    t = t_(dur)
    soplido = lowpass(ruido(rng, dur), 14) * np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 0.7
    thump = np.sin(2 * np.pi * (90 * np.exp(-t * 6) + 35) * t) * env(dur, 0.002, 0.25)
    return 0.9 * soplido + 1.1 * thump


def arco_disparo(rng):
    dur = 0.35
    t = t_(dur)
    cuerda = np.sin(2 * np.pi * (170 + 40 * np.exp(-t * 20)) * t) * env(dur, 0.001, 0.07)
    chasquido = lowpass(ruido(rng, dur), 4) * env(dur, 0.0005, 0.012)
    return 0.8 * cuerda + 0.5 * chasquido


def arco_tensar(rng):
    dur = 0.9
    t = t_(dur)
    crujido = lowpass(ruido(rng, dur), 20) * (0.5 + 0.5 * np.sin(2 * np.pi * 14 * t)) * np.minimum(t / 0.1, 1.0)
    tono = np.sin(2 * np.pi * (90 + 70 * t / dur) * t) * np.minimum(t / 0.2, 1.0)
    return 0.7 * crujido + 0.4 * tono


def tirachinas(rng):
    dur = 0.22
    t = t_(dur)
    goma = np.sin(2 * np.pi * (320 + 120 * np.exp(-t * 35)) * t) * env(dur, 0.001, 0.04)
    zumbido = lowpass(ruido(rng, dur), 6) * env(dur, 0.002, 0.05)
    return 0.8 * goma + 0.4 * zumbido


def puno_disparo(rng):
    dur = 0.45
    t = t_(dur)
    aire = lowpass(ruido(rng, dur), 6) * env(dur, 0.001, 0.05)
    clang = np.sin(2 * np.pi * 420 * t) * env(dur, 0.001, 0.09) + 0.5 * np.sin(2 * np.pi * 1130 * t) * env(dur, 0.001, 0.05)
    motor = np.sin(2 * np.pi * (200 + 500 * t / dur) * t) * np.sin(np.pi * np.clip(t / dur, 0, 1)) * 0.5
    return 0.8 * aire + 0.6 * clang + 0.4 * motor


def sable_golpe(rng):
    dur = 0.5
    t = t_(dur)
    sw = np.sin(np.pi * np.clip(t / dur, 0, 1))
    zumbido = (np.sin(2 * np.pi * 110 * t) + 0.5 * np.sin(2 * np.pi * 220 * t + 3 * np.sin(2 * np.pi * 9 * t))) * sw
    barrido = lowpass(ruido(rng, dur), 5) * sw ** 2
    return 0.6 * zumbido + 0.5 * barrido


def sable_bloqueo(rng):
    dur = 0.3
    t = t_(dur)
    chisporroteo = (ruido(rng, dur) - lowpass(ruido(rng, dur), 30)) * env(dur, 0.0005, 0.05)
    tono = np.sin(2 * np.pi * (1100 - 600 * t / dur) * t) * env(dur, 0.001, 0.08)
    zum = np.sin(2 * np.pi * 120 * t) * env(dur, 0.001, 0.12)
    return 0.6 * chisporroteo + 0.5 * tono + 0.5 * zum


def sable_sobrecalentamiento(rng):
    dur = 1.2
    t = t_(dur)
    queja = np.sin(2 * np.pi * (900 * np.exp(-t * 2.2) + 150) * t) * np.exp(-t * 1.5)
    siseo = (ruido(rng, dur) - lowpass(ruido(rng, dur), 10)) * np.minimum(t / 0.05, 1.0) * np.exp(-t * 2.5)
    return 0.6 * queja + 0.5 * siseo


def lanzar(rng):
    dur = 0.28
    t = t_(dur)
    return (lowpass(ruido(rng, dur), 8) * np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 2 * 0.8
            + 0.15 * np.sin(2 * np.pi * (300 - 150 * t / dur) * t) * env(dur, 0.01, 0.1))


def recoger(rng):
    out = np.zeros(int(SR * 0.3))
    s1 = clic(rng, 0.05, 900, 0.012)
    s2 = clic(rng, 0.06, 1500, 0.015)
    out[int(SR * 0.01):int(SR * 0.01) + len(s1)] += s1
    out[int(SR * 0.09):int(SR * 0.09) + len(s2)] += s2
    t = t_(0.3)
    out += 0.25 * np.sin(2 * np.pi * (500 + 900 * t / 0.3) * t) * env(0.3, 0.005, 0.07)
    return out


def explosion(rng):
    dur = 2.0
    t = t_(dur)
    boom = np.sin(2 * np.pi * (70 * np.exp(-t * 2.5) + 28) * t) * env(dur, 0.003, 0.5)
    rafaga = lowpass(ruido(rng, dur), 40) * env(dur, 0.002, 0.35) * 1.4
    crack = lowpass(ruido(rng, dur), 3) * env(dur, 0.0005, 0.03)
    retumbo = lowpass(ruido(rng, dur), 120) * np.exp(-t * 1.6) * 0.8
    return 0.9 * boom + 0.8 * rafaga + 0.5 * crack + 0.6 * retumbo


def humo(rng):
    dur = 1.4
    t = t_(dur)
    return (lowpass(ruido(rng, dur), 5) * np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 1.2
            + 0.1 * lowpass(ruido(rng, dur), 40) * env(dur, 0.01, 0.6))


def cegadora(rng):
    dur = 1.2
    t = t_(dur)
    bang = lowpass(ruido(rng, dur), 3) * env(dur, 0.0005, 0.04) + 0.8 * lowpass(ruido(rng, dur), 18) * env(dur, 0.001, 0.15)
    pitido = np.sin(2 * np.pi * 3100 * t) * np.exp(-t * 3.0) * 0.35
    return bang + pitido


def altavoz(rng):
    """Bucle de 2 s: cuatro pasos (0-1,2 s) y dos disparos falsos (1,4 y 1,75 s)."""
    out = np.zeros(int(SR * 2.0))

    def pon(s, t0):
        i = int(SR * t0)
        out[i:i + len(s)] += s[:len(out) - i]
    for t0 in (0.0, 0.4, 0.8, 1.2):
        pon(lowpass(ruido(rng, 0.12), 14) * env(0.12, 0.002, 0.03) * 0.6
            + np.sin(2 * np.pi * 95 * t_(0.12)) * env(0.12, 0.001, 0.03) * 0.5, t0)
    for t0 in (1.4, 1.75):
        pon(0.8 * disparo_pistola(rng)[:int(SR * 0.28)], t0)
    return lowpass(out, 3)


def sirena_alarma(rng):
    """Sirena de alarma de incendios (la Cachimba, P4): barrido 600-1150 Hz de 1,2 s, 4 ciclos (4,8 s), apta para bucle."""
    dur = 4.8
    t = t_(dur)
    ciclo = (t % 1.2) / 1.2
    f = 600 + 550 * (1.0 - np.abs(2.0 * ciclo - 1.0))
    fase = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(fase) + 0.35 * np.sin(2 * fase) + 0.18 * np.sin(3 * fase)


def guardar(ruta: Path, x):
    x = np.asarray(x, dtype=np.float64)
    pico = np.max(np.abs(x)) or 1.0
    x = np.clip(x / pico * 0.85, -1, 1)
    datos = (x * 32767).astype("<i2")
    with wave.open(str(ruta), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(datos.tobytes())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--semilla", type=int, default=7)
    ap.add_argument("--salida", default="game/assets/sonidos")
    a = ap.parse_args()
    salida = Path(a.salida)
    salida.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(a.semilla)
    sonidos = {
        "disparo_fusil": disparo_fusil, "disparo_pistola": disparo_pistola, "navaja": navaja,
        "recarga": recarga, "impacto_superficie": impacto_superficie, "impacto_carne": impacto_carne,
        "cambio_arma": cambio_arma, "clic_vacio": lambda r: clic(r, 0.04, 1800, 0.008),
        # --- arsenal (P2): al final, para que los sonidos anteriores no cambien con la misma semilla
        "disparo_subfusil": disparo_subfusil, "disparo_pesada": disparo_pesada, "disparo_combate": disparo_combate,
        "disparo_precision": disparo_precision, "disparo_escopeta": disparo_escopeta,
        "disparo_ametralladora": disparo_ametralladora, "disparo_cohete": disparo_cohete,
        "arco_disparo": arco_disparo, "arco_tensar": arco_tensar, "tirachinas": tirachinas,
        "puno_disparo": puno_disparo, "sable_golpe": sable_golpe, "sable_bloqueo": sable_bloqueo,
        "sable_sobrecalentamiento": sable_sobrecalentamiento, "lanzar": lanzar, "recoger": recoger,
        "explosion": explosion, "humo": humo, "cegadora": cegadora, "altavoz": altavoz,
        "sirena_alarma": sirena_alarma,
    }
    for nombre, f in sonidos.items():
        x = f(rng)
        guardar(salida / f"{nombre}.wav", x)
        print(f"{nombre}.wav  {len(x) / SR:.2f} s")


if __name__ == "__main__":
    main()
