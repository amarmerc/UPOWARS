"""Rellena data/alturas.csv con alturas reales del LiDAR del IGN (MDSn de edificacion).

Servicio: WCS 2.0.1 https://wcs-mds.idee.es/mds, coverage `mdsn_e025`
(Modelo Digital de Superficies normalizado de Edificacion, 2,5 m, PNOA-LiDAR,
primera cobertura). Se pide el recorte del campus (way 39935092) + 50 m en
EPSG:25830 y se guarda en data/raw/mdsn_upo.tif (el raster ya es altura sobre el
suelo; 0 = sin edificio).

Para cada edificio de OSM: pixeles dentro de la huella encogida 1 m, descartando
valores < 1 m; altura propuesta = percentil 75 redondeado a 0,5 m. Menos de 4
pixeles validos o cobertura valida < 30 % -> "sin dato LiDAR" (edificio posiblemente
posterior a ~2010). building=roof: base_m = mediana - 0,4 (minimo 2,5).

Columna `fuente` del CSV: defecto | osm | lidar | manual. Este script SOLO toca
filas con fuente `defecto` o `lidar`. SI EDITAS UNA FILA A MANO, PON fuente=manual
(o se pisara al re-ejecutar).

Uso: uv run python scripts/alturas_lidar.py [--entrada data/raw/osm_upo.json]
     [--alturas data/alturas.csv] [--raster data/raw/mdsn_upo.tif] [--redescargar]
"""
import argparse
import csv
import sys
from pathlib import Path

import numpy as np
import rasterio
import requests
from rasterio.features import geometry_mask
from shapely.affinity import translate
from shapely.ops import unary_union

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generar_blockout import CAMPOS_CSV, CAMPUS_ID, PLANTA_M, Mapa, num, validos  # noqa: E402

WCS_URL = "https://wcs-mds.idee.es/mds"
COVERAGE = "mdsn_e025"
CRS_URI = "http://www.opengis.net/def/crs/EPSG/0/25830"
MARGEN_M = 50.0
TESELA_M = 3000.0  # lado maximo por peticion (el recorte del campus cabe en una)
MIN_ALTURA = 1.0
MIN_PIXELES = 4
MIN_COBERTURA = 0.30
NOTA_SIN_DATO = "sin dato LiDAR (posible edificio posterior a 2010)"
EDITABLES = {"defecto", "lidar"}


def descargar(mapa, ruta):
    """GetCoverage del campus + margen en EPSG:25830 -> GeoTIFF. Trocea si excede TESELA_M."""
    minx, miny, maxx, maxy = unary_union(validos(mapa.poligono(mapa.ways[CAMPUS_ID]))).bounds
    e0, e1 = np.floor(mapa.E0 + minx - MARGEN_M), np.ceil(mapa.E0 + maxx + MARGEN_M)
    n0, n1 = np.floor(mapa.N0 + miny - MARGEN_M), np.ceil(mapa.N0 + maxy + MARGEN_M)
    if (e1 - e0) > TESELA_M or (n1 - n0) > TESELA_M:
        raise SystemExit("Recorte mayor que TESELA_M: implementar teselado si el campus crece")
    params = {"service": "WCS", "version": "2.0.1", "request": "GetCoverage",
              "coverageId": COVERAGE, "format": "image/tiff",
              "subset": [f"x({e0:.0f},{e1:.0f})", f"y({n0:.0f},{n1:.0f})"],
              "subsettingcrs": CRS_URI, "outputcrs": CRS_URI}
    r = requests.get(WCS_URL, params=params, headers={"User-Agent": "UPOWARS-blockout/0.1"}, timeout=180)
    r.raise_for_status()
    if "tiff" not in r.headers.get("content-type", ""):
        raise SystemExit(f"Respuesta WCS inesperada: {r.headers.get('content-type')}\n{r.text[:500]}")
    ruta.parent.mkdir(parents=True, exist_ok=True)
    ruta.write_bytes(r.content)
    print(f"Descargado {ruta} ({len(r.content) / 1e3:.0f} kB) bbox E[{e0:.0f},{e1:.0f}] N[{n0:.0f},{n1:.0f}]")


def estadisticas(src, datos, nodata, poly_local, mapa):
    """(n_validos, cobertura, mediana, p75, p90) de una huella en coordenadas locales."""
    g = translate(poly_local.buffer(-1.0), mapa.E0, mapa.N0)
    if g.is_empty:  # huella muy estrecha: usar la huella completa
        g = translate(poly_local, mapa.E0, mapa.N0)
    dentro = ~geometry_mask([g], out_shape=datos.shape, transform=src.transform, all_touched=False)
    v = datos[dentro].astype("float64")
    total = v.size
    v = v[np.isfinite(v)]
    if nodata is not None:
        v = v[v != nodata]
    v = v[v >= MIN_ALTURA]
    if total == 0 or v.size == 0:
        return 0, 0.0, None, None, None
    return v.size, v.size / total, float(np.median(v)), float(np.percentile(v, 75)), float(np.percentile(v, 90))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--entrada", default="data/raw/osm_upo.json")
    ap.add_argument("--alturas", default="data/alturas.csv")
    ap.add_argument("--raster", default="data/raw/mdsn_upo.tif")
    ap.add_argument("--redescargar", action="store_true")
    a = ap.parse_args()

    mapa = Mapa(a.entrada)
    ruta_r = Path(a.raster)
    if a.redescargar or not ruta_r.exists():
        descargar(mapa, ruta_r)

    with open(a.alturas, newline="", encoding="utf-8-sig") as f:
        filas = list(csv.DictReader(f))
    for r in filas:
        if not (r.get("fuente") or "").strip():
            r["fuente"] = "osm" if "de OSM" in (r.get("notas") or "") else "defecto"

    resumen, alturas_nuevas, sin_dato, saltadas = [], [], [], []
    with rasterio.open(ruta_r) as src:
        datos = src.read(1)
        nodata = src.nodata
        for r in filas:
            wid = int(r["osm_id"])
            w = mapa.ways.get(wid)
            if w is None:
                continue
            if r["fuente"] not in EDITABLES:
                saltadas.append((wid, r["fuente"]))
                continue
            polys = validos(mapa.poligono(w))
            n, cob, med, p75, p90 = estadisticas(src, datos, nodata, unary_union(polys), mapa) if polys else (0, 0.0, None, None, None)
            etiqueta = r["nombre"][:38] or f"({r['building']})"
            if n < MIN_PIXELES or cob < MIN_COBERTURA:
                r["notas"] = NOTA_SIN_DATO
                sin_dato.append(wid)
                resumen.append((wid, etiqueta, r["altura_m"] or f"{num(r['plantas'])}pl", "sin dato", n))
                continue
            if r["building"] == "roof":
                ant = r["base_m"]
                r["base_m"] = f"{max(med - 0.4, 2.5):.1f}"
                nuevo = f"base {r['base_m']}"
                ant = f"base {ant}"
            else:
                h = round(p75 * 2) / 2
                ant = f"{num(r['altura_m']):g}" if num(r["altura_m"]) is not None else f"{(num(r['plantas']) or 0) * PLANTA_M:g}"
                r["altura_m"] = f"{h:g}"
                r["plantas"] = str(int(round(h / PLANTA_M)))
                r["base_m"] = r["base_m"] or "0.0"
                nuevo = f"{h:g}"
                alturas_nuevas.append(h)
            r["notas"] = f"lidar p75={p75:.1f}, mediana={med:.1f}, n={n}"
            r["fuente"] = "lidar"
            resumen.append((wid, etiqueta, ant, nuevo, n))

    with open(a.alturas, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=CAMPOS_CSV, extrasaction="ignore")
        w.writeheader()
        w.writerows(filas)

    print(f"\n{'osm_id':>11}  {'edificio':<38} {'antes':>10} -> {'nueva':<10} {'n px':>5}")
    for wid, nom, ant, nuevo, n in resumen:
        print(f"{wid:>11}  {nom:<38} {str(ant):>10} -> {nuevo:<10} {n:>5}")
    print(f"\nFilas no tocadas (fuente osm/manual): {saltadas}")
    print(f"Sin dato LiDAR ({len(sin_dato)}): {sin_dato}")
    if alturas_nuevas:
        print(f"Alturas LiDAR (no roof): n={len(alturas_nuevas)} min={min(alturas_nuevas):g} "
              f"mediana={float(np.median(alturas_nuevas)):g} max={max(alturas_nuevas):g}")
    print(f"CSV actualizado: {a.alturas}")


if __name__ == "__main__":
    main()
