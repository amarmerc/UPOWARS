"""Genera las texturas procedurales (PNG 512x512 tileables) del mapa en game/assets/texturas/.

Semilla fija: la salida es reproducible. Todas son tileables (ruido espectral periodico + patrones con modulo).
Se usan en Godot con triplanar en espacio mundial (game/scripts/materiales.gd); la escala en metros por tesela vive alli.

Uso: uv run python scripts/generar_texturas.py [--salida game/assets/texturas] [--semilla 7]

Tras el primer `godot --import`, este script parchea los .png.import (mipmaps/generate=true: sin mipmaps las
texturas centellean a distancia). Si los .import aun no existen, ejecuta el import y vuelve a lanzar el script.
"""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image

N = 512


def ruido(rng, beta=2.0, n=N):
    """Ruido periodico 1/f^beta normalizado a [0, 1] (via FFT: tileable por construccion)."""
    f = np.fft.fftfreq(n)
    fx, fy = np.meshgrid(f, f)
    r = np.hypot(fx, fy)
    r[0, 0] = 1.0
    esp = (np.fft.fft2(rng.standard_normal((n, n)))) / r ** (beta / 2)
    esp[0, 0] = 0
    a = np.fft.ifft2(esp).real
    a -= a.min()
    return a / a.max()


def grano(rng, n=N):
    return rng.random((n, n))


def mezcla(base, *capas):
    """base (3,) RGB 0-1 con cada capa (mapa 0-1, amplitud) como variacion de brillo."""
    v = np.zeros((N, N))
    for m, amp in capas:
        v += (m - 0.5) * amp
    return np.clip(np.asarray(base)[None, None, :] * (1 + v[..., None]), 0, 1)


def guardar(ruta, rgb):
    Image.fromarray((np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB").save(ruta, optimize=True)


def asfalto(rng, base=(0.27, 0.28, 0.30), claro=0.0):
    b = np.array(base) + claro
    img = mezcla(b, (ruido(rng, 2.5), 0.15), (ruido(rng, 1.0), 0.14), (grano(rng), 0.30))
    # gravilla: motas claras y oscuras sueltas
    g = grano(rng)
    img = np.where((g > 0.995)[..., None], img * 1.3, img)
    img = np.where((g < 0.005)[..., None], img * 0.8, img)
    return img


def aparcamiento(rng):
    return asfalto(rng, base=(0.46, 0.47, 0.49))


def baldosa(rng):
    """8x8 losetas de 64 px (0,4 m si la tesela mide 3,2 m), con juntas de 2 px."""
    n = 8
    t = N // n
    tono = rng.uniform(-0.07, 0.07, (n, n))
    idx = np.arange(N) // t
    base = 0.68 + tono[idx[:, None], idx[None, :]]
    img = mezcla(np.array([1.0, 1.0, 1.02]), (ruido(rng, 2.0), 0.10), (grano(rng), 0.10))
    img *= base[..., None]
    loc = np.arange(N) % t
    junta = (loc[:, None] < 2) | (loc[None, :] < 2)
    img = np.where(junta[..., None], np.array([0.30, 0.30, 0.31]) * (0.9 + 0.2 * grano(rng))[..., None], img)
    return img


def baldosa_clara(rng):
    """Baldosa casi blanca (pavimento de los pasillos cubiertos): losetas de 0,5 m (tesela de 4 m), juntas finas grises."""
    n = 8
    t = N // n
    tono = rng.uniform(-0.025, 0.025, (n, n))
    idx = np.arange(N) // t
    base = 0.97 + tono[idx[:, None], idx[None, :]]
    img = mezcla(np.array([1.0, 1.0, 0.99]), (ruido(rng, 2.0), 0.05), (grano(rng), 0.05))
    img *= base[..., None]
    loc = np.arange(N) % t
    junta = (loc[:, None] < 1) | (loc[None, :] < 1)
    return np.where(junta[..., None], np.array([0.72, 0.72, 0.71]) * (0.95 + 0.1 * grano(rng))[..., None], img)


def cesped(rng):
    img = mezcla((0.27, 0.42, 0.15), (ruido(rng, 3.0), 0.55), (ruido(rng, 1.2), 0.35), (grano(rng), 0.25))
    # briznas: pequenos trazos mas claros y mas oscuros
    g = grano(rng)
    img = np.where((g > 0.97)[..., None], img * np.array([1.25, 1.3, 1.0]), img)
    # manchas secas amarillentas
    seco = 0.6 * np.clip((ruido(rng, 3.5) - 0.55) * 2.5, 0, 1)
    return img * (1 - seco[..., None]) + np.array([0.50, 0.46, 0.22]) * seco[..., None] * (0.8 + 0.4 * ruido(rng, 1.5))[..., None]


def albero(rng):
    """Tierra albero sevillana: beige cálido con grano y algunas piedrecitas."""
    img = mezcla((0.74, 0.62, 0.42), (ruido(rng, 2.8), 0.16), (ruido(rng, 1.2), 0.12), (grano(rng), 0.24))
    g = grano(rng)
    img = np.where((g > 0.995)[..., None], img * 0.65, img)
    img = np.where((g < 0.004)[..., None], img * 1.2, img)
    return img


def hormigon(rng):
    img = mezcla((0.60, 0.60, 0.58), (ruido(rng, 2.2), 0.22), (ruido(rng, 0.8), 0.14), (grano(rng), 0.18))
    # poros
    g = grano(rng)
    img = np.where((g < 0.01)[..., None], img * 0.7, img)
    # juntas de encofrado cada 128 px (tileable: 512/128 = 4)
    loc = np.arange(N) % 128
    junta = (loc[:, None] < 2) | (loc[None, :] < 2)
    img = np.where(junta[..., None], img * 0.78, img)
    return img


def pista(rng):
    """Pista deportiva de teja/resina rojiza con grano."""
    img = mezcla((0.62, 0.30, 0.22), (ruido(rng, 2.5), 0.22), (ruido(rng, 1.0), 0.15), (grano(rng), 0.28))
    g = grano(rng)
    img = np.where((g > 0.99)[..., None], img * 1.3, img)
    return img


def agua(rng):
    """Azul con ondas suaves (suma de senos periodicos deformados por ruido)."""
    y, x = np.mgrid[0:N, 0:N] / N * 2 * np.pi
    w = ruido(rng, 3.0)
    o = (np.sin(3 * x + 2 * y + 6 * w) + np.sin(-2 * x + 4 * y + 5 * w) + np.sin(5 * x - y + 4 * w)) / 3
    o = o * 0.5 + 0.5
    img = mezcla((0.16, 0.38, 0.56), (o, 0.35), (ruido(rng, 2.5), 0.15))
    img += (np.clip(o - 0.85, 0, 1) * 1.5)[..., None] * 0.35   # crestas claras
    return img


def campo(rng):
    """Campo exterior: tierra de labranza (surcos suaves) con verde seco."""
    y, x = np.mgrid[0:N, 0:N] / N * 2 * np.pi
    w = ruido(rng, 3.0)
    surcos = np.sin(24 * (x + 0.5 * np.sin(y + 3 * w))) * 0.5 + 0.5
    tierra = mezcla((0.52, 0.42, 0.28), (ruido(rng, 2.6), 0.35), (grano(rng), 0.18), (surcos, 0.14))
    seco = mezcla((0.50, 0.50, 0.27), (ruido(rng, 2.2), 0.40), (grano(rng), 0.22))
    m = np.clip((ruido(rng, 3.2) - 0.35) * 2.5, 0, 1)[..., None]
    return tierra * (1 - m) + seco * m


TEXTURAS = {
    "asfalto": asfalto, "baldosa": baldosa, "cesped": cesped, "albero": albero, "hormigon": hormigon,
    "aparcamiento": aparcamiento, "pista": pista, "agua": agua, "campo": campo, "baldosa_clara": baldosa_clara,
}


def parchear_import(ruta_png):
    """Activa mipmaps en el .import de Godot si existe (el import por defecto de un PNG no los genera)."""
    imp = Path(str(ruta_png) + ".import")
    if not imp.exists():
        return False
    t = imp.read_text(encoding="utf-8")
    nuevo = t.replace("mipmaps/generate=false", "mipmaps/generate=true")
    if nuevo != t:
        imp.write_text(nuevo, encoding="utf-8")
        return True
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--salida", default="game/assets/texturas")
    ap.add_argument("--semilla", type=int, default=7)
    a = ap.parse_args()
    out = Path(a.salida)
    out.mkdir(parents=True, exist_ok=True)
    cambiados = 0
    for i, (nombre, fn) in enumerate(TEXTURAS.items()):
        rng = np.random.default_rng([a.semilla, i])   # semilla independiente por textura
        ruta = out / f"{nombre}.png"
        guardar(ruta, fn(rng))
        cambiados += parchear_import(ruta)
        print(f"{ruta}")
    print(f"{len(TEXTURAS)} texturas de {N}x{N}; .import parcheados (mipmaps): {cambiados}")


if __name__ == "__main__":
    main()
