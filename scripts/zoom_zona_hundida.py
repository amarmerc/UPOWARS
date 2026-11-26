"""Planta de la zona entre el Edificio 18 y el 24 (zanjas del MDT de 1 m, marquesinas, steps) -> export/zoom_pasillo_hundido.png
y medidas de las zanjas (perfiles transversales del MDT de 1 m SIN suavizar). Solo lectura de datos; no toca el mapa.

    uv run python scripts/zoom_zona_hundida.py [--medir]
"""
import argparse
import math
import sys
from pathlib import Path

import numpy as np
import rasterio
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

sys.path.insert(0, str(Path(__file__).parent))
import generar_blockout as g  # noqa: E402

MDT = "data/raw/mdt_lidar_1m.tif"
CAJA = (-170.0, 235.0, 115.0, 340.0)      # x0, x1, norte0, norte1 (coordenadas locales: x=este, norte)
MARQ = {553042591: "marquesina diagonal (18 -> NE)", 321893434: "321893434 (corr. previa 'larga 18-24')",
        555538618: "555538618 (corr. previa 'corta')", 191918053: "191918053 (hipotesis inicial)"}


class Raster:
    def __init__(self, mapa, ruta=MDT):
        ds = rasterio.open(ruta)
        self.a, self.t, self.m = ds.read(1).astype(float), ds.transform, mapa

    def __call__(self, x, n):
        t = self.t
        x, n = np.asarray(x, float), np.asarray(n, float)
        fx = (x + self.m.E0 - t.c) / t.a - 0.5
        fy = (t.f - (n + self.m.N0)) / -t.e - 0.5
        j0, i0 = np.floor(fx).astype(int), np.floor(fy).astype(int)
        tx, ty = fx - j0, fy - i0
        a = self.a
        return (a[i0, j0] * (1 - tx) * (1 - ty) + a[i0, j0 + 1] * tx * (1 - ty)
                + a[i0 + 1, j0] * (1 - tx) * ty + a[i0 + 1, j0 + 1] * tx * ty)


def planta(mapa, R, ruta):
    x0, x1, n0, n1 = CAJA
    xs, ns = np.arange(x0, x1, 1.0) + 0.5, np.arange(n0, n1, 1.0) + 0.5
    X, N = np.meshgrid(xs, ns)
    Z = R(X, N)
    fig, ax = plt.subplots(figsize=(20, 20 * (n1 - n0) / (x1 - x0) + 0.8), dpi=90)
    im = ax.imshow(Z, extent=(x0, x1, n0, n1), origin="lower", cmap="terrain", alpha=0.75)
    plt.colorbar(im, ax=ax, shrink=0.5, label="cota MDT 1 m (m s.n.m.)")
    niv = np.arange(np.floor(Z.min()), Z.max() + 0.5, 0.5)
    ax.contour(X, N, Z, levels=niv, colors="k", linewidths=[0.6 if abs(v % 1) < 1e-9 else 0.25 for v in niv])
    cs = ax.contour(X, N, Z, levels=np.arange(np.ceil(Z.min()), Z.max(), 1.0), colors="none")
    ax.clabel(cs, fmt="%.0f", fontsize=6, colors="k")
    for wid, w in mapa.ways.items():
        tg = w.get("tags", {})
        if "building" in tg and mapa.cerrado(w):
            p = g.validos(mapa.poligono(w))
            if not p or not p[0].intersects(g.box(CAJA[0], CAJA[2], CAJA[1], CAJA[3])):
                continue
            p = p[0]
            xx, yy = p.exterior.xy
            if tg["building"] == "roof":
                ax.fill(xx, yy, color="red", alpha=0.25)
                ax.plot(xx, yy, color="red", lw=1.4)
                c = p.representative_point()
                ax.annotate(str(wid), (c.x, c.y), fontsize=9, color="darkred", weight="bold",
                            xytext=(4, 6), textcoords="offset points",
                            bbox=dict(fc="white", ec="red", alpha=0.8, pad=1))
            else:
                ax.plot(xx, yy, color="navy", lw=1.2)
                nm = tg.get("name", "")
                import re
                mm = re.match(r"^Edi\w*\s+([^\s.]+)", nm, re.I)
                c = p.representative_point()
                ax.text(c.x, c.y, f"Ed. {mm.group(1)}" if mm else "", fontsize=10, color="navy", ha="center", weight="bold")
        elif tg.get("highway") == "steps":
            l = mapa.linea(w)
            xx, yy = l.xy
            ax.plot(xx, yy, color="magenta", lw=3)
            ax.annotate(f"steps {wid}", (xx[0], yy[0]), fontsize=8, color="magenta", xytext=(5, 5), textcoords="offset points")
        elif tg.get("highway") in ("footway", "path", "pedestrian", "service", "cycleway"):
            xx, yy = mapa.linea(w).xy
            ax.plot(xx, yy, color="dimgray", lw=0.8, ls="--")
    # final del pasillo central
    pc = g.validos(mapa.poligono(mapa.ways[g.ID_PASILLO_CENTRAL]))[0]
    xx, yy = pc.exterior.xy
    ax.fill(xx, yy, color="gold", alpha=0.35)
    ax.plot(xx, yy, color="darkorange", lw=1.6)
    ax.annotate("pasillo central 1373541639 (termina aqui, junto al Ed. 18)", (-140, 138), fontsize=9, color="darkorange",
                weight="bold", xytext=(40, -45), textcoords="offset points", arrowprops=dict(arrowstyle="->", color="darkorange"))
    for (x, n, t) in ((7, 261, "(7, 261) del usuario"), (-12, 250, "(-12, 250) del usuario")):
        ax.plot(x, n, "k*", ms=13)
        ax.annotate(t, (x, n), fontsize=8, xytext=(6, -12), textcoords="offset points", bbox=dict(fc="yellow", alpha=0.8, pad=1))
    ax.set_xlim(x0, x1)
    ax.set_ylim(n0, n1)
    ax.set_aspect("equal")
    ax.set_xlabel("x (este, m)")
    ax.set_ylabel("norte (m)  [z juego = -norte]")
    ax.set_title("Zona entre el Edificio 18 y el 24: MDT LiDAR 1 m (curvas cada 0,5 m), marquesinas (rojo, osm_id), steps (magenta), pasillo central (naranja)")
    fig.tight_layout()
    fig.savefig(ruta)
    plt.close(fig)
    print(f"Zoom: {ruta}")


def medir(R):
    """Perfiles transversales del MDT 1 m: zanja SE (N-S) y zanja NO (ESE-ONO)."""
    print("== zanja SE (secciones E-O a norte constante): borde O / fondo / borde E, anchura a +1 m sobre el fondo")
    for n in range(160, 250, 10):
        x = np.arange(-20, 60, 0.5)
        z = R(x, np.full_like(x, n))
        k = int(np.argmin(z))
        if z[k] > 12.9:
            continue
        izq = z[:k][-24:]
        der = z[k:][:24]
        bo, be = izq.max(), der.max()
        sel = x[z < z[k] + 1.0]
        print(f"  norte {n}: fondo {z[k]:.2f} en x={x[k]:.1f} | borde O {bo:.2f} borde E {be:.2f} | prof {min(bo, be) - z[k]:.2f} | ancho(+1m) {sel.max() - sel.min():.1f}")
    print("== zanja NO (secciones N-S a x constante)")
    for xx in range(-125, -15, 10):
        n = np.arange(235, 290, 0.5)
        z = R(np.full_like(n, xx), n)
        k = int(np.argmin(z))
        izq, der = z[:k][-24:], z[k:][:24]
        bo, be = izq.max(), der.max()
        sel = n[z < z[k] + 1.0]
        print(f"  x {xx}: fondo {z[k]:.2f} en norte={n[k]:.1f} | borde S {bo:.2f} borde N {be:.2f} | prof {min(bo, be) - z[k]:.2f} | ancho(+1m) {sel.max() - sel.min():.1f}")


def medir_24(R):
    print("== zanja junto al Ed. 24 (secciones N-S): fondo / bordes / ancho a +1 m")
    for xx in range(76, 224, 12):
        n = np.arange(270, 310, 0.5)
        z = R(np.full_like(n, xx), n)
        k = int(np.argmin(z))
        izq, der = z[:k][-20:], z[k:][:20]
        sel = n[z < z[k] + 1.0]
        print(f"  x {xx}: fondo {z[k]:.2f} en norte={n[k]:.1f} | borde S {izq.max():.2f} borde N {der.max():.2f} | ancho(+1m) {sel.max() - sel.min():.1f}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--medir", action="store_true")
    ap.add_argument("--salida", default="export/zoom_pasillo_hundido.png")
    a = ap.parse_args()
    mapa = g.Mapa("data/raw/osm_upo.json")
    R = Raster(mapa)
    planta(mapa, R, a.salida)
    if a.medir:
        medir(R)
        medir_24(R)
