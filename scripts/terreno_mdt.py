"""Analisis del relieve del campus con el MDT del IGN (solo medicion; no toca el blockout).

Servicio: WCS 2.0.1 https://servicios.idee.es/wcs-inspire/mdt (MDT PNOA-LiDAR). Se hace
GetCapabilities, se listan las coverages y se elige la de mejor resolucion en EPSG:25830
(Elevacion25830_<paso>, paso en m; hoy 5 m: no hay 2 m ni 1 m en este servicio).
Recorte: contorno del campus (way 39935092) + 60 m -> data/raw/mdt_upo.tif (float32; se pide
en ASCII Grid porque el image/tiff del servicio es INT16 y redondea a metros enteros).

Calcula (en coordenadas del juego: x=este, norte; origen = centroide del campus):
  - cota min/max/p5/p50/p95 dentro del contorno y desnivel total;
  - pendiente (%) dentro del contorno: percentiles y mapa;
  - por edificio: cota media bajo la huella y diferencia max-min (edificio en ladera);
  - salto de cota de lado a lado (perfil perpendicular +-6 m) en highway=steps y barrier=retaining_wall.
Escribe export/terreno_resumen.json y export/terreno_preview.png.

Uso: uv run python scripts/terreno_mdt.py [--entrada data/raw/osm_upo.json]
     [--raster data/raw/mdt_upo.tif] [--redescargar] [--sin-preview]
"""
import argparse
import json
import re
import sys
from pathlib import Path

import numpy as np
import rasterio
import rasterio.transform
import requests
from rasterio.features import geometry_mask
from shapely.affinity import translate
from shapely.geometry import Point
from shapely.ops import unary_union

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generar_blockout import CAMPUS_ID, Mapa, validos  # noqa: E402

WCS_URL = "https://servicios.idee.es/wcs-inspire/mdt"
UA = {"User-Agent": "UPOWARS-blockout/0.1"}
CRS_URI = "http://www.opengis.net/def/crs/EPSG/0/25830"
MARGEN_M = 60.0
SEMI_PERFIL_M = 6.0
PASO_MUESTRA_M = 5.0   # distancia entre perfiles a lo largo de un muro/escalera


# ---------------------------------------------------------------- descarga
def listar_coverages():
    """GetCapabilities -> [(coverageId, paso_m)] de las coverages EPSG:25830, mejor resolucion primero."""
    r = requests.get(WCS_URL, params={"service": "WCS", "version": "2.0.1", "request": "GetCapabilities"},
                     headers=UA, timeout=60)
    r.raise_for_status()
    ids = re.findall(r"<wcs:CoverageId>([^<]+)</wcs:CoverageId>", r.text)
    print(f"Coverages del servicio ({len(ids)}): {', '.join(ids)}")
    cands = []
    for i in ids:
        m = re.fullmatch(r"Elevacion25830_(\d+)", i)
        if m:
            cands.append((i, int(m.group(1))))
    if not cands:
        raise SystemExit("No hay coverages EPSG:25830 en el servicio")
    # el sufijo es el paso de malla en m (1000, 500, 200, 25, 5): el menor es el mejor
    cands.sort(key=lambda c: c[1])
    return cands


def descargar(mapa, ruta, coverage, paso):
    """GetCoverage en ASCII Grid (application/asc): el image/tiff del servicio es INT16 y redondea
    las cotas a metros enteros; el .asc conserva los decimales. El bbox se alinea a la malla nativa
    (multiplos del paso) para que el servidor no remuestree. Se guarda como GeoTIFF float32."""
    campus = unary_union(validos(mapa.poligono(mapa.ways[CAMPUS_ID])))
    minx, miny, maxx, maxy = campus.bounds
    e0 = np.floor((mapa.E0 + minx - MARGEN_M) / paso) * paso
    e1 = np.ceil((mapa.E0 + maxx + MARGEN_M) / paso) * paso
    n0 = np.floor((mapa.N0 + miny - MARGEN_M) / paso) * paso
    n1 = np.ceil((mapa.N0 + maxy + MARGEN_M) / paso) * paso
    params = {"service": "WCS", "version": "2.0.1", "request": "GetCoverage", "coverageId": coverage,
              "format": "application/asc", "subset": [f"x({e0:.0f},{e1:.0f})", f"y({n0:.0f},{n1:.0f})"],
              "subsettingcrs": CRS_URI, "outputcrs": CRS_URI}
    r = requests.get(WCS_URL, params=params, headers=UA, timeout=180)
    r.raise_for_status()
    txt = r.content.decode("latin-1")
    i = txt.find("ncols")
    if i < 0:
        raise SystemExit(f"Respuesta WCS inesperada ({r.headers.get('content-type')}): {txt[:500]}")
    j = txt.find("--wcs", i)
    lineas = [l for l in txt[i:j if j > 0 else None].splitlines() if l.strip()]
    cab = {}
    k = 0
    while k < len(lineas) and re.match(r"^[A-Za-z_]+\s", lineas[k]):
        c, v = lineas[k].split()[:2]
        cab[c.lower()] = float(v)
        k += 1
    nodata = cab.get("nodata_value")
    z = np.array([[float(v) for v in l.split()] for l in lineas[k:]], dtype="float32")
    if z.shape != (int(cab["nrows"]), int(cab["ncols"])):
        raise SystemExit(f"ASC incoherente: {z.shape} vs cabecera {cab}")
    cell = cab["cellsize"]
    tf = rasterio.transform.from_origin(cab["xllcorner"], cab["yllcorner"] + cab["nrows"] * cell, cell, cell)
    ruta.parent.mkdir(parents=True, exist_ok=True)
    with rasterio.open(ruta, "w", driver="GTiff", height=z.shape[0], width=z.shape[1], count=1, dtype="float32",
                       crs="EPSG:25830", transform=tf, nodata=nodata if nodata is not None else -9999.0,
                       compress="deflate") as dst:
        dst.write(z, 1)
    print(f"Descargado {ruta} ({ruta.stat().st_size / 1e3:.0f} kB, {z.shape[1]}x{z.shape[0]} px de {cell:g} m) "
          f"bbox E[{e0:.0f},{e1:.0f}] N[{n0:.0f},{n1:.0f}]")


# ---------------------------------------------------------------- raster
class Terreno:
    """MDT en coordenadas locales del juego (x=este, y=norte) con muestreo bilineal."""

    def __init__(self, ruta, mapa):
        with rasterio.open(ruta) as src:
            self.z = src.read(1).astype("float64")
            self.tf = src.transform
            self.nodata = src.nodata
            self.crs = str(src.crs)
        if self.nodata is not None:
            self.z[self.z == self.nodata] = np.nan
        self.z[~np.isfinite(self.z) | (self.z < -500) | (self.z > 5000)] = np.nan
        self.E0, self.N0 = mapa.E0, mapa.N0
        self.paso = self.tf.a
        self.h, self.w = self.z.shape

    def muestrea(self, x, y):
        """Cota bilineal en puntos locales (x este, y norte); NaN fuera del raster."""
        x, y = np.atleast_1d(np.asarray(x, float)), np.atleast_1d(np.asarray(y, float))
        col = (x + self.E0 - self.tf.c) / self.tf.a - 0.5   # coordenada continua de centro de pixel
        fil = (y + self.N0 - self.tf.f) / self.tf.e - 0.5
        c0, f0 = np.floor(col).astype(int), np.floor(fil).astype(int)
        dc, df = col - c0, fil - f0
        ok = (c0 >= 0) & (f0 >= 0) & (c0 + 1 < self.w) & (f0 + 1 < self.h)
        c0, f0 = np.clip(c0, 0, self.w - 2), np.clip(f0, 0, self.h - 2)
        z = self.z
        v = (z[f0, c0] * (1 - dc) * (1 - df) + z[f0, c0 + 1] * dc * (1 - df)
             + z[f0 + 1, c0] * (1 - dc) * df + z[f0 + 1, c0 + 1] * dc * df)
        return np.where(ok, v, np.nan)

    def centros_locales(self):
        """Mallas (X, Y) de centros de pixel en coordenadas locales."""
        cols = (np.arange(self.w) + 0.5) * self.tf.a + self.tf.c - self.E0
        filas = (np.arange(self.h) + 0.5) * self.tf.e + self.tf.f - self.N0
        return np.meshgrid(cols, filas)

    def mascara(self, geom_local):
        g = translate(geom_local, self.E0, self.N0)
        return ~geometry_mask([g], out_shape=self.z.shape, transform=self.tf, all_touched=False)

    def pendiente_pct(self):
        gy, gx = np.gradient(self.z, self.paso)
        return np.hypot(gx, gy) * 100.0


def percentiles(v, ps=(5, 50, 95)):
    return {f"p{p}": round(float(np.percentile(v, p)), 3) for p in ps}


# ---------------------------------------------------------------- analisis
def stats_campus(ter, campus):
    m = ter.mascara(campus)
    z = ter.z[m]
    z = z[np.isfinite(z)]
    sl = ter.pendiente_pct()[m]
    sl = sl[np.isfinite(sl)]
    zs = {"min": round(float(z.min()), 3), "max": round(float(z.max()), 3), **percentiles(z),
          "media": round(float(z.mean()), 3), "desnivel_total_m": round(float(z.max() - z.min()), 3),
          "desnivel_p5_p95_m": round(float(np.percentile(z, 95) - np.percentile(z, 5)), 3),
          "pixeles": int(z.size)}
    ps = {**percentiles(sl, (5, 50, 75, 90, 95, 99)), "max": round(float(sl.max()), 3),
          "media": round(float(sl.mean()), 3),
          "pct_area_mayor_2": round(float((sl > 2).mean() * 100), 1),
          "pct_area_mayor_5": round(float((sl > 5).mean() * 100), 1),
          "pct_area_mayor_8": round(float((sl > 8).mean() * 100), 1)}
    return zs, ps


def puntos_en(poly, paso=2.0):
    """Rejilla de puntos de muestreo dentro de un poligono (centroide si es muy pequeno)."""
    minx, miny, maxx, maxy = poly.bounds
    xs, ys = np.meshgrid(np.arange(minx, maxx + paso, paso), np.arange(miny, maxy + paso, paso))
    pts = [(x, y) for x, y in zip(xs.ravel(), ys.ravel()) if poly.contains(Point(x, y))]
    if len(pts) < 3:
        c = poly.representative_point()
        pts.append((c.x, c.y))
    return np.array(pts)


def stats_edificios(ter, mapa):
    res = []
    for wid, w in sorted(mapa.ways.items()):
        t = w.get("tags", {})
        if not (("building" in t or t.get("man_made") == "tower") and mapa.cerrado(w)):
            continue
        polys = validos(mapa.poligono(w))
        if not polys:
            continue
        huella = unary_union(polys)
        pts = puntos_en(huella)
        z = ter.muestrea(pts[:, 0], pts[:, 1])
        z = z[np.isfinite(z)]
        if z.size == 0:
            continue
        res.append({"osm_id": wid, "nombre": t.get("name", ""), "building": t.get("building", t.get("man_made", "")),
                    "area_m2": round(huella.area, 1), "cota_media": round(float(z.mean()), 3),
                    "cota_min": round(float(z.min()), 3), "cota_max": round(float(z.max()), 3),
                    "dif_max_min_m": round(float(z.max() - z.min()), 3), "n_muestras": int(z.size)})
    return res


def perfiles(ter, linea, semi=SEMI_PERFIL_M, paso=PASO_MUESTRA_M):
    """Perfiles perpendiculares a una linea cada `paso` m: lista de (cota_izq - cota_dcha) con +-semi m."""
    L = linea.length
    ds = np.arange(0, L, paso) + min(paso, L) / 2 if L > paso else np.array([L / 2])
    ds = ds[ds <= L]
    out = []
    for d in ds:
        a, b = linea.interpolate(max(d - 1.0, 0)), linea.interpolate(min(d + 1.0, L))
        tx, ty = b.x - a.x, b.y - a.y
        n = np.hypot(tx, ty)
        if n == 0:
            continue
        nx, ny = -ty / n, tx / n          # normal a la izquierda del sentido de la linea
        c = linea.interpolate(d)
        zi = ter.muestrea(c.x + nx * semi, c.y + ny * semi)[0]
        zd = ter.muestrea(c.x - nx * semi, c.y - ny * semi)[0]
        if np.isfinite(zi) and np.isfinite(zd):
            out.append(float(zi - zd))
    return out


def stats_lineales(ter, mapa):
    escaleras, muros = [], []
    for wid, w in sorted(mapa.ways.items()):
        t = w.get("tags", {})
        es_esc, es_muro = t.get("highway") == "steps", t.get("barrier") == "retaining_wall"
        if not (es_esc or es_muro):
            continue
        l = mapa.linea(w)
        if l is None or l.length == 0:
            continue
        d = perfiles(ter, l)
        if not d:
            continue
        ad = np.abs(d)
        reg = {"osm_id": wid, "nombre": t.get("name", ""), "largo_m": round(l.length, 1),
               "dz_perp_max_abs": round(float(ad.max()), 3), "dz_perp_mediana_abs": round(float(np.median(ad)), 3),
               "n_perfiles": len(d), "tags": {k: v for k, v in t.items() if k in ("height", "step_count", "incline", "layer", "bridge", "tunnel", "material")}}
        if es_esc:
            # las escaleras salvan el desnivel A LO LARGO del eje (OSM: sentido = hacia arriba)
            z0 = ter.muestrea(*l.coords[0])[0]
            z1 = ter.muestrea(*l.coords[-1])[0]
            reg["dz_a_lo_largo_fin_menos_inicio"] = round(float(z1 - z0), 3) if np.isfinite(z0 + z1) else None
            escaleras.append(reg)
        else:
            muros.append(reg)
    return escaleras, muros


def resumen_dz(regs):
    v = np.array([r["dz_perp_max_abs"] for r in regs])
    if v.size == 0:
        return {}
    return {"n": int(v.size), "dz_perp_max_abs_mediana": round(float(np.median(v)), 3),
            "dz_perp_max_abs_max": round(float(v.max()), 3),
            "n_con_salto_mayor_0_5m": int((v > 0.5).sum()), "n_con_salto_mayor_1m": int((v > 1.0).sum())}


# ---------------------------------------------------------------- preview
def preview(ruta, ter, mapa, campus, edif_polys, esc_lineas, muro_lineas, zs):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import LightSource

    X, Y = ter.centros_locales()
    x0, x1 = float(X[0, 0]), float(X[0, -1])
    y0, y1 = float(Y[-1, 0]), float(Y[0, 0])
    # remuestreo bilineal a 1 m para curvas y sombreado suaves
    xs = np.arange(x0, x1, 1.0)
    ys = np.arange(y1, y0, -1.0)
    gx, gy = np.meshgrid(xs, ys)
    z = ter.muestrea(gx.ravel(), gy.ravel()).reshape(gx.shape)
    zz = np.where(np.isfinite(z), z, np.nanmean(z))

    fig, ax = plt.subplots(figsize=(15, 13.5), dpi=110)
    ls = LightSource(azdeg=315, altdeg=40)
    # exageracion vertical x4 solo para el sombreado (relieve muy suave)
    hs = ls.hillshade(zz, vert_exag=4.0, dx=1.0, dy=1.0)
    ax.imshow(hs, extent=(xs[0], xs[-1], ys[-1], ys[0]), cmap="gray", vmin=0.2, vmax=1.0, origin="upper", zorder=0)
    ext = (xs[0], xs[-1], ys[-1], ys[0])
    cs_im = ax.imshow(np.where(np.isfinite(z), z, np.nan), extent=ext, cmap="terrain", alpha=0.35, origin="upper", zorder=1)

    lo, hi = np.floor(np.nanmin(z) * 2) / 2, np.ceil(np.nanmax(z) * 2) / 2
    niveles = np.arange(lo, hi + 0.01, 0.5)
    cs = ax.contour(xs, ys, zz, levels=niveles, colors="#5a3b1e", linewidths=0.45, alpha=0.8, zorder=2)
    mayores = [l for l in niveles if abs(l / 2 - round(l / 2)) < 1e-6]
    cs2 = ax.contour(xs, ys, zz, levels=mayores, colors="#3b2410", linewidths=0.9, zorder=3)
    ax.clabel(cs2, levels=mayores, fmt="%.0f m", fontsize=7, inline=True)

    for p in edif_polys:
        for g in (p.geoms if hasattr(p, "geoms") else [p]):
            ax.plot(*g.exterior.xy, color="#1b3a8a", lw=0.6, zorder=4)
    for l in esc_lineas:
        ax.plot(*l.xy, color="#ff7a00", lw=3.2, zorder=6, solid_capstyle="round")
    for l in muro_lineas:
        ax.plot(*l.xy, color="#e0149c", lw=2.2, zorder=5, solid_capstyle="round")
    cg = campus.geoms if hasattr(campus, "geoms") else [campus]
    for g in cg:
        ax.plot(*g.exterior.xy, color="#d10000", lw=1.6, ls="--", zorder=7)

    ax.plot([], [], color="#1b3a8a", lw=1, label="huellas de edificios")
    ax.plot([], [], color="#ff7a00", lw=3, label="escaleras (highway=steps)")
    ax.plot([], [], color="#e0149c", lw=2, label="muros de contencion")
    ax.plot([], [], color="#d10000", lw=1.6, ls="--", label="contorno del campus")
    ax.plot([], [], color="#5a3b1e", lw=0.6, label="curvas cada 0,5 m (etiquetas cada 2 m)")
    ax.legend(loc="lower left", fontsize=9, framealpha=0.9)
    cb = fig.colorbar(cs_im, ax=ax, shrink=0.6, pad=0.01)
    cb.set_label("cota MDT (m)")
    ax.set_xlim(x0 + MARGEN_M / 3, x1 - MARGEN_M / 3)
    ax.set_ylim(y0 + MARGEN_M / 3, y1 - MARGEN_M / 3)
    ax.set_aspect("equal")
    ax.set_xlabel("este (m, ejes del juego, origen = centroide del campus)")
    ax.set_ylabel("norte (m)")
    ax.set_title(f"MDT IGN {ter.paso:g} m: cota {zs['min']:.1f}-{zs['max']:.1f} m dentro del campus "
                 f"(desnivel {zs['desnivel_total_m']:.1f} m; p5-p95 {zs['desnivel_p5_p95_m']:.1f} m). "
                 "Sombreado con exageracion vertical x4")
    fig.tight_layout()
    fig.savefig(ruta)
    plt.close(fig)
    print(f"Preview: {ruta}")


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--entrada", default="data/raw/osm_upo.json")
    ap.add_argument("--raster", default="data/raw/mdt_upo.tif")
    ap.add_argument("--resumen", default="export/terreno_resumen.json")
    ap.add_argument("--preview", default="export/terreno_preview.png")
    ap.add_argument("--redescargar", action="store_true")
    ap.add_argument("--sin-preview", action="store_true")
    a = ap.parse_args()

    mapa = Mapa(a.entrada)
    ruta = Path(a.raster)
    coverage = None
    if a.redescargar or not ruta.exists():
        cands = listar_coverages()
        coverage, paso = cands[0]
        print(f"Coverage elegida: {coverage} ({paso} m)")
        descargar(mapa, ruta, coverage, paso)
    ter = Terreno(ruta, mapa)
    print(f"Raster {ter.w}x{ter.h} px, paso {ter.paso:g} m, CRS {ter.crs}, NaN: {int(np.isnan(ter.z).sum())}")

    campus = unary_union(validos(mapa.poligono(mapa.ways[CAMPUS_ID])))
    zs, ps = stats_campus(ter, campus)
    edif = stats_edificios(ter, mapa)
    escaleras, muros = stats_lineales(ter, mapa)

    en_ladera = sorted(edif, key=lambda e: -e["dif_max_min_m"])
    difs = np.array([e["dif_max_min_m"] for e in edif])
    resumen = {
        "fuente": {"servicio": WCS_URL, "coverage": coverage or "(raster ya descargado)", "resolucion_m": ter.paso,
                   "raster": str(ruta), "crs": ter.crs, "margen_m": MARGEN_M},
        "cota_campus_m": zs,
        "pendiente_campus_pct": ps,
        "edificios": {"n": len(edif), "dif_max_min_mediana_m": round(float(np.median(difs)), 3),
                      "n_dif_mayor_0_5m": int((difs > 0.5).sum()), "n_dif_mayor_1m": int((difs > 1.0).sum()),
                      "top_ladera": en_ladera[:15], "todos": edif},
        "escaleras": {"resumen": resumen_dz(escaleras), "detalle": escaleras},
        "muros_contencion": {"resumen": resumen_dz(muros), "detalle": muros},
        "nota": f"Perfil perpendicular: cota(+{SEMI_PERFIL_M:g} m) - cota(-{SEMI_PERFIL_M:g} m) cada {PASO_MUESTRA_M:g} m; "
                "muestreo bilineal sobre el MDT. Las escaleras salvan el desnivel a lo largo del eje, ver dz_a_lo_largo.",
    }
    Path(a.resumen).parent.mkdir(parents=True, exist_ok=True)
    Path(a.resumen).write_text(json.dumps(resumen, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Resumen: {a.resumen}")

    print(f"\nCota campus: min {zs['min']} max {zs['max']} p5 {zs['p5']} p50 {zs['p50']} p95 {zs['p95']} | desnivel {zs['desnivel_total_m']} m")
    print("Pendiente %:", {k: v for k, v in ps.items()})
    print("\nTop edificios en ladera (dif max-min bajo la huella):")
    for e in en_ladera[:10]:
        print(f"  {e['osm_id']:>11} {e['nombre'][:34]:<34} {e['area_m2']:>8.0f} m2  media {e['cota_media']:.2f}  dif {e['dif_max_min_m']:.2f} m")
    for tit, regs in (("Escaleras", escaleras), ("Muros", muros)):
        print(f"\n{tit}: {resumen_dz(regs)}")
        for r in regs:
            print(f"  {r['osm_id']:>11} largo {r['largo_m']:>6.1f}  dz_perp max {r['dz_perp_max_abs']:.2f} med {r['dz_perp_mediana_abs']:.2f}"
                  + (f"  dz_largo {r['dz_a_lo_largo_fin_menos_inicio']}" if "dz_a_lo_largo_fin_menos_inicio" in r else "")
                  + (f"  tags {r['tags']}" if r["tags"] else ""))

    if not a.sin_preview:
        edif_polys = []
        for wid, w in mapa.ways.items():
            t = w.get("tags", {})
            if ("building" in t or t.get("man_made") == "tower") and mapa.cerrado(w):
                edif_polys.extend(validos(mapa.poligono(w)))
        esc = [mapa.linea(w) for w in mapa.ways.values() if w.get("tags", {}).get("highway") == "steps"]
        mur = [mapa.linea(w) for w in mapa.ways.values() if w.get("tags", {}).get("barrier") == "retaining_wall"]
        preview(Path(a.preview), ter, mapa, campus, edif_polys, [l for l in esc if l], [l for l in mur if l], zs)


if __name__ == "__main__":
    main()
