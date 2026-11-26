"""Procesa las nubes PNOA-LiDAR 2a cobertura (2020, .laz en data/raw/lidar/) del campus de la UPO.

Salidas (todas EPSG:25830, malla de 1 m alineada con la del MDT de 5 m: E 239040-240370, N 4137740-4138990):
  data/raw/mdt_lidar_1m.tif          MDT 1 m (float32, nodata -9999), valido para generar_blockout.py --mdt
  data/raw/ndsm_edif_lidar_1m.tif    altura sobre el MDT de la edificacion (clase 6), maximo por celda
  data/raw/ndsm_veg_lidar_1m.tif     idem vegetacion (clases 3-5)
  export/alturas_lidar2020_propuesta.csv   altura propuesta por edificio (solo modifica data/alturas.csv con --aplicar-alturas)
  export/lidar_resumen.json          estadisticas de la nube, validacion y saltos en escaleras/muros
  export/terreno_lidar_preview.png   hillshade + curvas 0,5 m + huellas + escaleras/muros + recuadro del eje central

Metodo del MDT: solo clase 2 (suelo). Mediana por celda de 1 m (con ~1-2 puntos de suelo por m2 el
minimo se sesga a la baja con el ruido vertical y en pendientes; la mediana es robusta y no sesgada).
Descarte de atipicos: celda observada que difiere > UMBRAL_ATIPICO_M de la mediana 5x5 del MDT
interpolado. Huecos (bajo edificios, copas, agua) por interpolacion lineal sobre TIN (Delaunay) de las
celdas observadas; fuera del casco convexo, vecino mas proximo.

Uso: uv run python scripts/lidar_procesar.py [--releer] [--sin-preview]
Los puntos del bbox se guardan en data/raw/lidar_campus_pts.npz (cache) para no releer 450 MB de .laz.
Los .laz se tratan solo como datos (laspy); no se ejecuta nada de data/raw/lidar/.
"""
import argparse
import csv
import json
import sys
import time
from pathlib import Path

import laspy
import numpy as np
import rasterio
from rasterio.features import geometry_mask
from rasterio.transform import from_origin
from scipy import ndimage
from scipy.interpolate import LinearNDInterpolator
import shapely
from shapely.affinity import translate
from shapely.ops import unary_union

sys.path.insert(0, str(Path(__file__).resolve().parent))
from alturas_lidar import MIN_ALTURA, estadisticas  # noqa: E402
from generar_blockout import CAMPOS_CSV, CAMPUS_ID, GROSOR_TECHO, PLANTA_M, RX_NUM_EDIF, Mapa, num, validos  # noqa: E402

LAZ_DIR = Path("data/raw/lidar")
CACHE = Path("data/raw/lidar_campus_pts.npz")
MDT_5M = Path("data/raw/mdt_upo.tif")
OUT_MDT = Path("data/raw/mdt_lidar_1m.tif")
OUT_NDSM_E = Path("data/raw/ndsm_edif_lidar_1m.tif")
OUT_NDSM_V = Path("data/raw/ndsm_veg_lidar_1m.tif")
OUT_CSV = Path("export/alturas_lidar2020_propuesta.csv")
OUT_JSON = Path("export/lidar_resumen.json")
OUT_PNG = Path("export/terreno_lidar_preview.png")

# Malla = la del MDT de 5 m (campus + ~65 m), a 1 m. El bbox campus+60 m (E 239104-240305, N 4137802-4138929)
# queda dentro; el margen extra evita bordes en la malla de suelo del generador (campus + 50 m).
E_MIN, E_MAX, N_MIN, N_MAX = 239040.0, 240370.0, 4137740.0, 4138990.0
PASO = 1.0
NODATA = -9999.0
UMBRAL_ATIPICO_M = 0.5
MIN_FILA_BUF = 1.0
CLASES = {0: "nunca clasificado", 1: "sin clasificar", 2: "suelo", 3: "vegetacion baja", 4: "vegetacion media",
          5: "vegetacion alta", 6: "edificacion", 7: "ruido bajo", 8: "reservado", 9: "agua", 10: "ferrocarril",
          11: "carretera", 12: "reservado/solape", 13: "cable", 14: "torre", 15: "puente", 16: "estructura", 17: "puente",
          18: "ruido alto"}
SEMI_PERP_M = 3.0
PASO_PERFIL_M = 2.0
UMBRAL_DIF_ALTURA_M = 3.0


# ------------------------------------------------------------------ 1. lectura de las nubes
def leer_nubes(releer):
    if CACHE.exists() and not releer:
        d = np.load(CACHE)
        print(f"Cache de puntos: {CACHE} ({d['x'].size:,} puntos en el bbox)")
        return d["x"], d["y"], d["z"], d["c"], json.loads(str(d["info"]))
    info = {"hojas": []}
    xs, ys, zs, cs = [], [], [], []
    tot_bbox = np.zeros(256, dtype=np.int64)
    for f in sorted(LAZ_DIR.glob("*.laz")):
        t0 = time.time()
        tot = np.zeros(256, dtype=np.int64)
        dentro = 0
        with laspy.open(f) as r:
            h = r.header
            crs = h.parse_crs()
            hoja = {"fichero": f.name, "puntos": int(h.point_count), "formato_punto": int(h.point_format.id),
                    "version": str(h.version), "crs": crs.to_string() if crs else None,
                    "vlrs": [f"{v.user_id}/{v.record_id}: {v.description}" for v in h.vlrs],
                    "bbox_cabecera": [float(h.mins[0]), float(h.mins[1]), float(h.maxs[0]), float(h.maxs[1])],
                    "z_cabecera": [float(h.mins[2]), float(h.maxs[2])],
                    "sistema_generador": h.system_identifier, "software": h.generating_software}
            for ch in r.chunk_iterator(2_000_000):
                cl = np.asarray(ch.classification)
                tot += np.bincount(cl, minlength=256)
                x, y = np.asarray(ch.x), np.asarray(ch.y)
                m = (x >= E_MIN) & (x < E_MAX) & (y >= N_MIN) & (y < N_MAX)
                # descarta ruido (7, 18) y puntos marcados withheld
                m &= (cl != 7) & (cl != 18)
                if hasattr(ch, "withheld"):
                    m &= ~np.asarray(ch.withheld, dtype=bool)
                if m.any():
                    xs.append(x[m]); ys.append(y[m]); zs.append(np.asarray(ch.z)[m]); cs.append(cl[m])
                    dentro += int(m.sum())
                    tot_bbox += np.bincount(cl[m], minlength=256)
        hoja["clases_hoja"] = {int(k): int(v) for k, v in enumerate(tot) if v}
        hoja["puntos_en_bbox"] = dentro
        info["hojas"].append(hoja)
        print(f"  {f.name}: {hoja['puntos']:,} pts, {dentro:,} en bbox ({time.time() - t0:.0f} s)")
    x, y, z, c = (np.concatenate(a) for a in (xs, ys, zs, cs))
    info["clases_bbox"] = {int(k): int(v) for k, v in enumerate(tot_bbox) if v}
    np.savez_compressed(CACHE, x=x, y=y, z=z.astype("float32"), c=c.astype("uint8"), info=json.dumps(info))
    return x, y, z.astype("float32"), c, info


def informe_nube(x, c, info):
    area = (E_MAX - E_MIN) * (N_MAX - N_MIN)
    print(f"\n== Nube LiDAR ==  bbox malla {area / 1e6:.2f} km2")
    for h in info["hojas"]:
        print(f"  {h['fichero']}: v{h['version']} formato {h['formato_punto']} CRS {h['crs']} | {h['puntos']:,} pts "
              f"({h['puntos'] / 4e6:.2f} pts/m2 de hoja de 2x2 km)")
        print(f"     VLRs: {h['vlrs']}")
    print(f"  Puntos en bbox (sin ruido ni withheld): {x.size:,} -> {x.size / area:.2f} pts/m2")
    cb = {int(k): v for k, v in info["clases_bbox"].items()}
    print("  Clases en el bbox (ASPRS):")
    for k, v in sorted(cb.items()):
        print(f"     {k:>2} {CLASES.get(k, '?'):<20} {v:>10,}  {v / x.size * 100:5.1f} %  {v / area:.2f} pts/m2")
    return {"area_bbox_m2": area, "puntos_bbox": int(x.size), "densidad_pts_m2": round(x.size / area, 3),
            "clases_bbox": {str(k): {"nombre": CLASES.get(k, "?"), "n": int(v), "densidad_pts_m2": round(v / area, 3)}
                            for k, v in sorted(cb.items())}}


# ------------------------------------------------------------------ 2. rasterizado
NX, NY = int(round((E_MAX - E_MIN) / PASO)), int(round((N_MAX - N_MIN) / PASO))
TRANSFORM = from_origin(E_MIN, N_MAX, PASO, PASO)


def celdas(x, y):
    col = np.floor((x - E_MIN) / PASO).astype(np.int64)
    fila = np.floor((N_MAX - y) / PASO).astype(np.int64)
    ok = (col >= 0) & (col < NX) & (fila >= 0) & (fila < NY)
    return fila * NX + col, ok


def por_celda(idx, v, modo):
    """Estadistico por celda -> raster (NY, NX) con NaN donde no hay puntos. modo: mediana | max | p95."""
    o = np.lexsort((v, idx))
    idx_s, v_s = idx[o], v[o]
    celdas_u, ini, cnt = np.unique(idx_s, return_index=True, return_counts=True)
    if modo == "max":
        val = v_s[ini + cnt - 1]
    elif modo == "p95":
        val = v_s[ini + np.round(0.95 * (cnt - 1)).astype(np.int64)]
    else:  # mediana
        val = 0.5 * (v_s[ini + (cnt - 1) // 2] + v_s[ini + cnt // 2])
    r = np.full(NY * NX, np.nan, dtype=np.float32)
    r[celdas_u] = val
    return r.reshape(NY, NX), cnt


def interpolar(obs):
    """Rellena los NaN de `obs` (TIN lineal + vecino mas proximo fuera del casco)."""
    fil, col = np.nonzero(np.isfinite(obs))
    pts = np.column_stack([col + 0.5, fil + 0.5])
    f = LinearNDInterpolator(pts, obs[fil, col].astype("float64"))
    hu_f, hu_c = np.nonzero(~np.isfinite(obs))
    out = obs.astype("float64").copy()
    if hu_f.size:
        out[hu_f, hu_c] = f(np.column_stack([hu_c + 0.5, hu_f + 0.5]))
    malo = ~np.isfinite(out)
    if malo.any():  # fuera del casco convexo
        _, (fi, ci) = ndimage.distance_transform_edt(malo, return_indices=True)
        out[malo] = out[fi[malo], ci[malo]]
    return out


def construir_mdt(x, y, z, c):
    t0 = time.time()
    m = c == 2
    idx, ok = celdas(x[m], y[m])
    obs, cnt = por_celda(idx[ok], z[m][ok], "mediana")
    n_obs = int(np.isfinite(obs).sum())
    print(f"\n== MDT ==  puntos de suelo {int(ok.sum()):,}; celdas con suelo {n_obs:,} de {NX * NY:,} "
          f"({n_obs / (NX * NY) * 100:.1f} %); pts/celda mediana {int(np.median(cnt))}")
    mdt0 = interpolar(obs)
    med = ndimage.median_filter(mdt0, size=5, mode="nearest")
    atip = np.isfinite(obs) & (np.abs(obs - med) > UMBRAL_ATIPICO_M)
    print(f"  atipicos descartados (|celda - mediana 5x5| > {UMBRAL_ATIPICO_M} m): {int(atip.sum()):,} celdas")
    obs2 = obs.copy()
    obs2[atip] = np.nan
    mdt = interpolar(obs2).astype("float32")
    print(f"  hecho en {time.time() - t0:.0f} s; cota min {mdt.min():.2f} max {mdt.max():.2f}")
    return mdt, obs, n_obs, int(atip.sum())


def guardar(ruta, a, descripcion):
    a = np.where(np.isfinite(a), a, NODATA).astype("float32")
    perfil = dict(driver="GTiff", dtype="float32", nodata=NODATA, width=NX, height=NY, count=1, crs="EPSG:25830",
                  transform=TRANSFORM, compress="deflate", predictor=3)
    with rasterio.open(ruta, "w", **perfil) as dst:
        dst.write(a, 1)
        dst.update_tags(DESCRIPCION=descripcion)
    print(f"  escrito {ruta} ({ruta.stat().st_size / 1e6:.2f} MB)")


class Muestreador:
    """Muestreo bilineal de un raster georreferenciado (coordenadas del mundo EPSG:25830)."""

    def __init__(self, a, transform, nodata=None):
        a = a.astype("float64")
        if nodata is not None:
            a = np.where(a == nodata, np.nan, a)
        self.a, self.t = a, transform

    def __call__(self, x, y):
        x, y = np.atleast_1d(x).astype(float), np.atleast_1d(y).astype(float)
        col = (x - self.t.c) / self.t.a - 0.5
        fila = (y - self.t.f) / self.t.e - 0.5
        # NaN-aware: interpola con pesos
        a = self.a
        v = np.where(np.isfinite(a), a, 0.0)
        w = np.isfinite(a).astype(float)
        sv = ndimage.map_coordinates(v, [fila, col], order=1, mode="nearest")
        sw = ndimage.map_coordinates(w, [fila, col], order=1, mode="nearest")
        with np.errstate(invalid="ignore", divide="ignore"):
            r = np.where(sw > 0.999, sv / sw, np.nan)
        return r


def construir_ndsm(x, y, z, c, clases, mdt, modo="max"):
    m = np.isin(c, clases)
    idx, ok = celdas(x[m], y[m])
    xm, ym, zm = x[m][ok], y[m][ok], z[m][ok]
    h = zm - Muestreador(mdt, TRANSFORM)(xm, ym)
    h = np.clip(h, 0, None).astype("float32")
    r, _ = por_celda(idx[ok], h, modo)
    return r


# ------------------------------------------------------------------ 4. alturas de edificios
def huella_local(mapa, w):
    polys = validos(mapa.poligono(w))
    return unary_union(polys) if polys else None


def alturas_edificios(mapa, ndsm, ruta_alturas, pts):
    with open(ruta_alturas, newline="", encoding="utf-8-sig") as f:
        filas = list(csv.DictReader(f))
    filas_out = []
    class _Src:  # estadisticas() solo usa .transform
        transform = TRANSFORM
    for r in filas:
        w = mapa.ways.get(int(r["osm_id"]))
        if w is None:
            continue
        g = huella_local(mapa, w)
        n, cob, med, p75, _ = estadisticas(_Src, ndsm, NODATA, g, mapa) if g is not None else (0, 0.0, None, None, None)
        a_csv = num(r["altura_m"])
        pl = num(r["plantas"])
        actual = a_csv if a_csv is not None else (pl * PLANTA_M if pl is not None else None)
        es_techo = r["building"] == "roof" or r.get("forma") == "techo"
        if es_techo and (a_csv is None or a_csv <= 1.0) and num(r["base_m"]) is not None:
            actual = num(r["base_m"]) + GROSOR_TECHO  # techo: altura_m es el grosor; la cota superior es base + grosor
        h20 = round(p75, 1) if p75 is not None else None
        dif = round(h20 - actual, 1) if (h20 is not None and actual is not None) else None
        notas = []
        if "sin dato" in (r.get("notas") or ""):
            notas.append("sin dato LiDAR 2010")
        if a_csv is None:
            notas.append("altura_actual = plantas x 3,5 (sin altura)")
        if dif is not None and abs(dif) > UMBRAL_DIF_ALTURA_M:
            notas.append(f"difiere > {UMBRAL_DIF_ALTURA_M:g} m")
        if h20 is None:
            px, py, pc = pts
            ins = shapely.contains_xy(translate(g, mapa.E0, mapa.N0).buffer(-1.0), px, py) if g is not None else np.zeros(px.size, bool)
            frac = float((pc[ins] == 2).mean()) if ins.any() else 0.0
            notas.append(f"sin clase 6 en 2020 ({frac * 100:.0f} % de los puntos de la huella son suelo: "
                         + ("probable edificio posterior a 2020)" if frac > 0.5 else "revisar)"))
        elif cob < 0.30:
            notas.append(f"cobertura baja ({cob * 100:.0f} %): dato poco fiable")
        if es_techo:
            notas.append("techo: altura_actual = altura_m si > 1 m, si no base_m + 0,4 (cota de la cubierta); altura_2020 = cota de cubierta sobre el suelo")
        filas_out.append({"osm_id": r["osm_id"], "nombre": r["nombre"], "altura_actual": f"{actual:g}" if actual is not None else "",
                          "fuente_actual": r["fuente"], "altura_2020": h20 if h20 is not None else "", "n_px": n,
                          "diferencia": dif if dif is not None else "", "mediana_2020": round(med, 1) if med is not None else "",
                          "cobertura": round(cob, 2), "building": r["building"], "notas": "; ".join(notas)})
    return filas_out


def aplicar_alturas(ruta_propuesta, ruta_alturas):
    """Aplica altura_2020 a data/alturas.csv. Filas editables: defecto, lidar, lidar2020 (las manual NO se tocan).
    Sin altura_2020 la fila se queda como esta. Techos (building=roof): altura_m es el grosor de la losa y
    base_m = max(altura_2020 - GROSOR_TECHO, 2,5), de modo que base_m + altura_m = cota de la cara superior."""
    with open(ruta_propuesta, newline="", encoding="utf-8-sig") as f:
        prop = {r["osm_id"]: r for r in csv.DictReader(f)}
    with open(ruta_alturas, newline="", encoding="utf-8-sig") as f:
        filas = list(csv.DictReader(f))
    cambios, sin_dato, manuales = [], [], []
    for r in filas:
        p = prop.get(r["osm_id"])
        if r["fuente"] == "manual":
            manuales.append(r["osm_id"])
            continue
        if r["fuente"] not in ("defecto", "lidar", "lidar2020") or p is None:
            continue
        if not (p["altura_2020"] or "").strip():
            sin_dato.append(r["osm_id"])
            continue
        h, med = float(p["altura_2020"]), float(p["mediana_2020"])
        if r["building"] == "roof":
            ant = f"base {r['base_m']}"
            r["base_m"] = f"{max(h - GROSOR_TECHO, 2.5):.1f}"
            r["altura_m"] = f"{GROSOR_TECHO:g}"
            nuevo = f"base {r['base_m']}"
        else:
            ant = r["altura_m"] or (f"{num(r['plantas']) * PLANTA_M:g}" if num(r["plantas"]) is not None else "")
            r["altura_m"] = f"{h:g}"
            r["plantas"] = str(int(round(h / PLANTA_M)))
            r["base_m"] = r["base_m"] or "0.0"
            nuevo = r["altura_m"]
        r["notas"] = f"lidar2020 p75={h:.1f}, mediana={med:.1f}, n={p['n_px']}, cobertura={float(p['cobertura']) * 100:.0f}%"
        r["fuente"] = "lidar2020"
        cambios.append((r["osm_id"], r["nombre"] or f"({r['building']})", ant, nuevo))
    with open(ruta_alturas, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=CAMPOS_CSV, extrasaction="ignore")
        w.writeheader()
        w.writerows(filas)
    print(f"\n== Alturas 2020 aplicadas a {ruta_alturas}: {len(cambios)} filas ==")
    for c in cambios:
        print(f"  {c[0]:>11} {c[1][:44]:<44} {c[2]:>10} -> {c[3]}")
    print(f"  Sin dato 2020 (sin cambios): {sin_dato}\n  Manual (sin cambios): {manuales}")


# ------------------------------------------------------------------ 5. validacion
def validar_vs_5m(mdt, mapa, campus_w):
    with rasterio.open(MDT_5M) as s:
        a5, t5, nd5 = s.read(1), s.transform, s.nodata
    m5 = Muestreador(a5, t5, nd5)
    cx = E_MIN + (np.arange(NX) + 0.5) * PASO
    cy = N_MAX - (np.arange(NY) + 0.5) * PASO
    dentro = ~geometry_mask([campus_w], out_shape=(NY, NX), transform=TRANSFORM, all_touched=False)
    gx, gy = np.meshgrid(cx, cy)
    z5 = m5(gx[dentro], gy[dentro])
    d = mdt[dentro].astype("float64") - z5
    d = d[np.isfinite(d)]
    r = {"n_celdas": int(d.size), "media_m": round(float(d.mean()), 3), "desv_m": round(float(d.std()), 3),
         "mediana_m": round(float(np.median(d)), 3), "p5_m": round(float(np.percentile(d, 5)), 3),
         "p95_m": round(float(np.percentile(d, 95)), 3), "rmse_m": round(float(np.sqrt((d ** 2).mean())), 3),
         "pct_dentro_1m": round(float((np.abs(d) <= 1).mean() * 100), 1), "convencion": "1 m - 5 m"}
    print(f"\n== Validacion MDT 1 m - MDT 5 m dentro del campus ==\n  {r}")
    return r, m5


def perfil_perp(f, linea, semi=SEMI_PERP_M, paso=PASO_PERFIL_M):
    """Perfiles perpendiculares: lista de (cota(+semi) - cota(-semi), salto local max a 0,5 m)."""
    L = linea.length
    ds = np.arange(0, L, paso) + min(paso, L) / 2 if L > paso else np.array([L / 2])
    ds = ds[ds <= L]
    off = np.arange(-semi, semi + 1e-9, 0.5)
    out = []
    for d in ds:
        a, b = linea.interpolate(max(d - 1.0, 0)), linea.interpolate(min(d + 1.0, L))
        tx, ty = b.x - a.x, b.y - a.y
        n = np.hypot(tx, ty)
        if n == 0:
            continue
        nx, ny = -ty / n, tx / n
        c = linea.interpolate(d)
        z = f(c.x + nx * off, c.y + ny * off)
        if not np.isfinite(z).all():
            continue
        out.append((float(z[-1] - z[0]), float(np.abs(np.diff(z)).max())))
    return out


def saltos_lineales(mapa, f1, f5, json5):
    d5 = {r["osm_id"]: r for k in ("escaleras", "muros_contencion") for r in json5[k]["detalle"]}
    esc, muros = [], []
    for wid, w in sorted(mapa.ways.items()):
        t = w.get("tags", {})
        es_e, es_m = t.get("highway") == "steps", t.get("barrier") == "retaining_wall"
        if not (es_e or es_m):
            continue
        l0 = mapa.linea(w)
        if l0 is None or l0.length == 0:
            continue
        l = translate(l0, mapa.E0, mapa.N0)
        reg = {"osm_id": wid, "largo_m": round(l.length, 1), "incline": t.get("incline", "")}
        for nom, f in (("1m", f1), ("5m", f5)):
            p = perfil_perp(f, l)
            dz = np.array([a for a, _ in p]) if p else np.array([np.nan])
            loc = np.array([b for _, b in p]) if p else np.array([np.nan])
            reg[f"perp_max_abs_{nom}"] = round(float(np.nanmax(np.abs(dz))), 2)
            reg[f"perp_med_abs_{nom}"] = round(float(np.nanmedian(np.abs(dz))), 2)
            reg[f"salto_local_med_{nom}"] = round(float(np.nanmedian(loc)), 2)
            reg[f"salto_local_max_{nom}"] = round(float(np.nanmax(loc)), 2)
            if es_e:
                s = np.linspace(0, l.length, max(int(l.length / 0.5), 2) + 1)
                pts = [l.interpolate(v) for v in s]
                z = f(np.array([p.x for p in pts]), np.array([p.y for p in pts]))
                reg[f"eje_fin_menos_ini_{nom}"] = round(float(z[-1] - z[0]), 2)
                reg[f"eje_rango_{nom}"] = round(float(np.nanmax(z) - np.nanmin(z)), 2)
        r5 = d5.get(wid)
        if r5:
            reg["json_5m_perp6_max"] = r5["dz_perp_max_abs"]
            if es_e:
                reg["json_5m_eje_fin_menos_ini"] = r5["dz_a_lo_largo_fin_menos_inicio"]
        (esc if es_e else muros).append(reg)
    return esc, muros


# ------------------------------------------------------------------ 6. preview
def preview(ruta, mdt, mapa, campus_w, edif, esc, muros, zoom_box):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import LightSource
    from matplotlib.patches import Rectangle

    xs = E_MIN + (np.arange(NX) + 0.5) * PASO
    ys = N_MAX - (np.arange(NY) + 0.5) * PASO
    ext = (E_MIN, E_MAX, N_MIN, N_MAX)
    hs = LightSource(azdeg=315, altdeg=40).hillshade(mdt.astype("float64"), vert_exag=3.0, dx=PASO, dy=PASO)
    zs = ndimage.gaussian_filter(mdt.astype("float64"), 1.5)  # solo para curvas (evita dientes de 1 m)
    niv = np.arange(np.floor(zs.min() * 2) / 2, np.ceil(zs.max() * 2) / 2 + 0.01, 0.5)
    mayores = [v for v in niv if abs(v - round(v)) < 1e-6 and int(round(v)) % 2 == 0]

    def dibujar(ax, detalle):
        ax.imshow(hs, extent=ext, cmap="gray", vmin=0.2, vmax=1.0, origin="upper", zorder=0)
        ax.contour(xs, ys, zs, levels=niv, colors="#5a3b1e", linewidths=0.35 if not detalle else 0.6, alpha=0.8, zorder=2)
        c2 = ax.contour(xs, ys, zs, levels=mayores, colors="#3b2410", linewidths=0.8 if not detalle else 1.1, zorder=3)
        ax.clabel(c2, fmt="%.0f", fontsize=6 if not detalle else 8, inline=True)
        for g in edif:
            for p in (g.geoms if hasattr(g, "geoms") else [g]):
                ax.plot(*p.exterior.xy, color="#1b3a8a", lw=0.6 if not detalle else 1.2, zorder=4)
        for l in muros:
            ax.plot(*l.xy, color="#e0149c", lw=1.6 if not detalle else 3, zorder=5, solid_capstyle="round")
        for l in esc:
            ax.plot(*l.xy, color="#ff7a00", lw=2.4 if not detalle else 4, zorder=6, solid_capstyle="round")
        for p in (campus_w.geoms if hasattr(campus_w, "geoms") else [campus_w]):
            ax.plot(*p.exterior.xy, color="#d10000", lw=1.2, ls="--", zorder=7)
        ax.set_aspect("equal")

    fig, (a1, a2) = plt.subplots(1, 2, figsize=(26, 12), dpi=100, gridspec_kw={"width_ratios": [1.15, 1]})
    dibujar(a1, False)
    cb = campus_w.bounds
    a1.set_xlim(cb[0] - 30, cb[2] + 30)
    a1.set_ylim(cb[1] - 30, cb[3] + 30)
    x0, y0, x1, y1 = zoom_box
    a1.add_patch(Rectangle((x0, y0), x1 - x0, y1 - y0, fill=False, ec="#00a000", lw=2, zorder=9))
    a1.set_title("MDT LiDAR 2020 1 m: hillshade (x3), curvas cada 0,5 m (etiqueta cada 2 m)")
    a1.plot([], [], color="#1b3a8a", label="huellas de edificios")
    a1.plot([], [], color="#ff7a00", lw=3, label="escaleras (highway=steps)")
    a1.plot([], [], color="#e0149c", lw=2, label="muros de contencion")
    a1.plot([], [], color="#d10000", ls="--", label="contorno del campus")
    a1.legend(loc="lower left", fontsize=9, framealpha=0.9)
    dibujar(a2, True)
    a2.set_xlim(x0, x1)
    a2.set_ylim(y0, y1)
    a2.set_title("Recuadro: eje central (pasillo y edificios 1-18)")
    fig.tight_layout()
    fig.savefig(ruta)
    plt.close(fig)
    print(f"Preview: {ruta}")


# ------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--entrada", default="data/raw/osm_upo.json")
    ap.add_argument("--alturas", default="data/alturas.csv")
    ap.add_argument("--releer", action="store_true", help="ignora la cache de puntos y relee los .laz")
    ap.add_argument("--sin-preview", action="store_true")
    ap.add_argument("--aplicar-alturas", action="store_true",
                    help="vuelca la altura 2020 en data/alturas.csv (filas defecto/lidar/lidar2020; nunca manual). "
                         "Usa la propuesta existente; si no existe, la recalcula")
    a = ap.parse_args()

    if a.aplicar_alturas and OUT_CSV.exists():
        aplicar_alturas(OUT_CSV, a.alturas)
        return

    x, y, z, c, info = leer_nubes(a.releer)
    res = {"nube": informe_nube(x, c, info), "hojas": info["hojas"]}

    mdt, obs, n_obs, n_atip = construir_mdt(x, y, z, c)
    res["mdt"] = {"metodo": "mediana por celda 1 m de clase 2 + TIN lineal + descarte de atipicos",
                  "celdas_con_suelo_pct": round(n_obs / (NX * NY) * 100, 1), "atipicos_descartados": n_atip,
                  "umbral_atipico_m": UMBRAL_ATIPICO_M, "cota_min": round(float(mdt.min()), 2), "cota_max": round(float(mdt.max()), 2)}
    guardar(OUT_MDT, mdt, "MDT PNOA-LiDAR 2a cobertura 2020, 1 m, clase 2, mediana por celda + TIN lineal. Cotas ortometricas (m)")

    nd_e = construir_ndsm(x, y, z, c, [6], mdt)
    nd_v = construir_ndsm(x, y, z, c, [3, 4, 5], mdt)
    print(f"\n== nDSM ==  edificacion: {int(np.isfinite(nd_e).sum()):,} celdas, max {np.nanmax(nd_e):.1f} m; "
          f"vegetacion: {int(np.isfinite(nd_v).sum()):,} celdas, max {np.nanmax(nd_v):.1f} m")
    guardar(OUT_NDSM_E, nd_e, "Altura sobre MDT, clase 6 (edificacion), maximo por celda 1 m; nodata = sin puntos")
    guardar(OUT_NDSM_V, nd_v, "Altura sobre MDT, clases 3-5 (vegetacion), maximo por celda 1 m; nodata = sin puntos")

    mapa = Mapa(a.entrada)
    campus_w = translate(unary_union(validos(mapa.poligono(mapa.ways[CAMPUS_ID]))), mapa.E0, mapa.N0)

    # --- alturas
    nd_e_f = np.where(np.isfinite(nd_e), nd_e, NODATA).astype("float32")
    filas = alturas_edificios(mapa, nd_e_f, a.alturas, (x, y, c))
    OUT_CSV.parent.mkdir(parents=True, exist_ok=True)
    campos = ["osm_id", "nombre", "altura_actual", "fuente_actual", "altura_2020", "n_px", "diferencia",
              "mediana_2020", "cobertura", "building", "notas"]
    with open(OUT_CSV, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=campos)
        w.writeheader()
        w.writerows(filas)
    print(f"\n== Alturas 2020 ==  {OUT_CSV} ({len(filas)} edificios)")
    sin = [r for r in filas if "sin dato LiDAR 2010" in r["notas"]]
    print(f"  Sin dato en 2010 ({len(sin)}):")
    for r in sin:
        print(f"   {r['osm_id']:>11} {r['nombre'][:44]:<44} 2020={r['altura_2020']!s:>5} med={r['mediana_2020']!s:>5} n_px={r['n_px']:>5} cob={r['cobertura']}")
    gr = [r for r in filas if "difiere" in r["notas"] and r not in sin]
    print(f"  Dif > {UMBRAL_DIF_ALTURA_M:g} m (con dato previo) ({len(gr)}):")
    for r in sorted(gr, key=lambda r: -abs(r["diferencia"])):
        print(f"   {r['osm_id']:>11} {r['nombre'][:40]:<40} act={r['altura_actual']:>5} ({r['fuente_actual']}) 2020={r['altura_2020']!s:>5} dif={r['diferencia']:>5} n_px={r['n_px']}")
    res["alturas"] = {"n": len(filas), "sin_dato_2010": [r["osm_id"] for r in sin], "dif_mayor_3m": [r["osm_id"] for r in gr]}

    # --- validacion
    val, m5 = validar_vs_5m(mdt, mapa, campus_w)
    res["validacion_vs_5m"] = val
    f1 = Muestreador(mdt, TRANSFORM)
    json5 = json.loads(Path("export/terreno_resumen.json").read_text(encoding="utf-8"))
    esc, muros = saltos_lineales(mapa, f1, m5, json5)
    res["escaleras"], res["muros"] = esc, muros
    print(f"\n== Escaleras (perfil +-{SEMI_PERP_M:g} m; dz = cota(+) - cota(-); eje = fin - inicio) ==")
    print(f"{'id':>11} {'L':>5} | {'perp max 1m':>11} {'5m':>5} | {'salto local med 1m':>18} {'5m':>5} | {'eje f-i 1m':>10} {'5m':>6} {'json5m':>6} | rango eje 1m")
    for r in esc:
        print(f"{r['osm_id']:>11} {r['largo_m']:>5} | {r['perp_max_abs_1m']:>11} {r['perp_max_abs_5m']:>5} | {r['salto_local_med_1m']:>18} {r['salto_local_med_5m']:>5} | "
              f"{r['eje_fin_menos_ini_1m']:>10} {r['eje_fin_menos_ini_5m']:>6} {r.get('json_5m_eje_fin_menos_ini', ''):>6} | {r['eje_rango_1m']}")
    print(f"\n== Muros de contencion ==")
    print(f"{'id':>11} {'L':>5} | {'perp max 1m':>11} {'5m':>5} | {'perp med 1m':>11} {'5m':>5} | {'salto local med 1m':>18} {'5m':>5} | json5m(+-6)")
    for r in muros:
        print(f"{r['osm_id']:>11} {r['largo_m']:>5} | {r['perp_max_abs_1m']:>11} {r['perp_max_abs_5m']:>5} | {r['perp_med_abs_1m']:>11} {r['perp_med_abs_5m']:>5} | "
              f"{r['salto_local_med_1m']:>18} {r['salto_local_med_5m']:>5} | {r.get('json_5m_perp6_max', '')}")
    for tit, regs in (("escaleras", esc), ("muros", muros)):
        for k in ("perp_max_abs_1m", "perp_max_abs_5m", "salto_local_med_1m", "salto_local_med_5m"):
            v = np.array([r[k] for r in regs])
            print(f"  {tit} {k}: mediana {np.median(v):.2f}  max {v.max():.2f}  n>0,5 m: {(v > 0.5).sum()}  n>1 m: {(v > 1).sum()}")
    OUT_JSON.write_text(json.dumps(res, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Resumen: {OUT_JSON}")

    if a.aplicar_alturas:
        aplicar_alturas(OUT_CSV, a.alturas)

    # --- preview
    if not a.sin_preview:
        edif, nums = [], {}
        for wid, w in mapa.ways.items():
            t = w.get("tags", {})
            if ("building" in t or t.get("man_made") == "tower") and mapa.cerrado(w):
                g = huella_local(mapa, w)
                if g is None:
                    continue
                g = translate(g, mapa.E0, mapa.N0)
                edif.append(g)
                m = RX_NUM_EDIF.match(t.get("name", ""))
                if m and m.group(1).isdigit() and 1 <= int(m.group(1)) <= 18:
                    nums[wid] = g
        bx = unary_union(list(nums.values())).bounds
        mg = 15.0
        zoom_box = (bx[0] - mg, bx[1] - mg, bx[2] + mg, bx[3] + mg)
        esc_l = [translate(mapa.linea(w), mapa.E0, mapa.N0) for w in mapa.ways.values()
                 if w.get("tags", {}).get("highway") == "steps" and mapa.linea(w)]
        mur_l = [translate(mapa.linea(w), mapa.E0, mapa.N0) for w in mapa.ways.values()
                 if w.get("tags", {}).get("barrier") == "retaining_wall" and mapa.linea(w)]
        preview(OUT_PNG, mdt, mapa, campus_w, edif, esc_l, mur_l, zoom_box)


if __name__ == "__main__":
    main()
