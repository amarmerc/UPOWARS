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
    }
    for nombre, f in sonidos.items():
        x = f(rng)
        guardar(salida / f"{nombre}.wav", x)
        print(f"{nombre}.wav  {len(x) / SR:.2f} s")


if __name__ == "__main__":
    main()
