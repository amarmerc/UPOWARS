"""Arboles low-poly a partir del nDSM de vegetacion LiDAR (data/raw/ndsm_veg_lidar_1m.tif, 1 m, EPSG:25830).

Deteccion de copas: nDSM suavizado (gauss sigma 1 px) -> maximos locales en una ventana de 5 m con altura >= ALT_MIN_M ->
separacion minima SEP_MIN_M (se conserva el mas alto) -> radio de copa = region conectada alrededor del maximo por
encima del 50 % de su altura, acotado por una regla altura -> radio y por [1,5; 7] m.
Descartes (ver Entorno.prohibido_arbol): dentro de edificios (+1 m), sobre caminos, aparcamientos, agua y pistas,
a < 2 m de pilares o muros/vallas, a < 3 m de un spawn y fuera del muro limite.
Geometria (plano local x = este, y = norte, z = arriba; generar_blockout la gira a glTF): tronco = prisma de 8 lados
de la base (terreno - 0,3 m) al 45 % de la altura; copa = icosfera de 1 nivel escalada entre el 35 % y el 100 %.
Nodos: `arboles_troncos-col` (con colision, corteza) y `arboles_copas`, `arboles_copas_2`, `arboles_copas_3` (sin
colision, un nodo por tono de verde: Godot no usa el color de vertice del glTF como albedo). Todo es reproducible con
la semilla.
"""
import numpy as np
import shapely
import trimesh
from scipy import ndimage as ndi
from scipy.spatial import cKDTree

ALT_MIN_M = 3.0          # altura minima de un arbol
ALT_MAX_M = 30.0         # alturas mayores se recortan (el LiDAR trae picos de 40-56 m: cables, grullas...)
ALT_RUIDO_M = 35.0       # un maximo por encima de esto se descarta (no es un arbol)
SEP_MIN_M = 3.0          # separacion minima entre troncos
VENTANA_M = 5            # ventana del maximo local
SUAVIZADO_PX = 1.0
RADIO_MIN_M, RADIO_MAX_M = 1.5, 7.0
LADOS_TRONCO = 8
TRONCO_FRAC = 0.45       # el tronco llega al 45 % de la altura
COPA_INI_FRAC = 0.35     # la copa va del 35 % al 100 %
ENTERRADO_M = 0.3
COLORES_MATERIAL = {"arbol_corteza": (98, 72, 50, 255), "arbol_copa_1": (72, 118, 56, 255),
                    "arbol_copa_2": (58, 104, 50, 255), "arbol_copa_3": (92, 132, 62, 255)}
N_TONOS = 3
MAX_ARBOLES = 6000


def radio_tronco(h):
    """Radio del tronco (m): 0,15 con 3 m de altura hasta 0,30 con 15 m o mas."""
    return np.clip(0.15 + 0.15 * (np.asarray(h) - 3.0) / 12.0, 0.15, 0.30)


def _leer_ndsm(ruta, E0, N0):
    import rasterio
    with rasterio.open(ruta) as d:
        a = d.read(1).astype(float)
        t, nd = d.transform, d.nodata
    a[~np.isfinite(a) | (a == nd) | (a < 0)] = 0.0   # sin puntos de vegetacion = 0 m
    return a, t


def _regla_radio(h):
    return 0.3 * h + 0.6


def detectar_copas(ruta, E0, N0, alt_min=ALT_MIN_M, sep_min=SEP_MIN_M):
    """Copas del nDSM: lista ordenada (de mas alto a mas bajo) de (x, norte, altura, radio_copa) en el plano local."""
    a, t = _leer_ndsm(ruta, E0, N0)
    sm = ndi.gaussian_filter(a, SUAVIZADO_PX)
    mx = ndi.maximum_filter(sm, size=VENTANA_M)
    ii, jj = np.nonzero((sm == mx) & (sm >= alt_min))
    raw = ndi.maximum_filter(a, size=3)
    h_raw = raw[ii, jj]
    ok = h_raw < ALT_RUIDO_M
    ii, jj, h_raw = ii[ok], jj[ok], np.minimum(h_raw[ok], ALT_MAX_M)
    orden = np.argsort(-sm[ii, jj], kind="stable")
    ii, jj, h_raw = ii[orden], jj[orden], h_raw[orden]
    x = t.c + (jj + 0.5) * t.a - E0
    y = t.f + (ii + 0.5) * t.e - N0
    # separacion minima: se conserva el mas alto de cada grupo de vecinos < sep_min
    arbol = cKDTree(np.column_stack([x, y]))
    descartado = np.zeros(len(x), bool)
    for k in range(len(x)):
        if descartado[k]:
            continue
        for v in arbol.query_ball_point([x[k], y[k]], sep_min - 1e-9):
            if v > k:
                descartado[v] = True
    ii, jj, x, y, h = ii[~descartado], jj[~descartado], x[~descartado], y[~descartado], h_raw[~descartado]
    # radio: region conectada alrededor del maximo con suavizado >= 50 % de su altura (ventana de +-8 m)
    R = 8
    radios = np.empty(len(x))
    for k in range(len(x)):
        i0, j0 = max(ii[k] - R, 0), max(jj[k] - R, 0)
        sub = sm[i0:ii[k] + R + 1, j0:jj[k] + R + 1]
        lab, _ = ndi.label(sub >= 0.5 * sm[ii[k], jj[k]])
        reg = lab == lab[ii[k] - i0, jj[k] - j0]
        r_reg = np.sqrt(reg.sum() / np.pi)
        radios[k] = np.clip(min(r_reg, 1.25 * _regla_radio(h[k])), RADIO_MIN_M, RADIO_MAX_M)
    return x, y, h, radios


def generar_arboles(entorno, ruta_ndsm, E0, N0, rng, alt_min=ALT_MIN_M, sep_min=SEP_MIN_M):
    """Detecta y filtra los arboles. Devuelve (lista de dicts {x, y, h, r_copa, r_tronco, base, tono}, stats)."""
    T = entorno.T
    x, y, h, r = detectar_copas(ruta_ndsm, E0, N0, alt_min, sep_min)
    stats = {"copas_detectadas": int(len(x))}
    prohibido = entorno.prohibido_arbol()
    shapely.prepare(prohibido)
    malo = entorno.fuera_zona(x, y) | shapely.contains_xy(prohibido, x, y)
    stats["descartados"] = int(malo.sum())
    x, y, h, r = x[~malo], y[~malo], h[~malo], r[~malo]
    if len(x) > MAX_ARBOLES:
        raise SystemExit(f"{len(x)} arboles (> {MAX_ARBOLES}): sube --altura-min-arbol o --sep-arboles")
    base = T.h(x, y) - ENTERRADO_M
    tono = rng.integers(0, N_TONOS, len(x))
    giro = rng.uniform(0, 2 * np.pi, len(x))
    achat = rng.uniform(0.9, 1.1, len(x))          # el elipsoide no es de revolucion
    arboles = [{"x": float(x[k]), "y": float(y[k]), "h": float(h[k]), "r_copa": float(r[k]),
                "r_tronco": float(radio_tronco(h[k])), "base": float(base[k]), "tono": int(tono[k]),
                "giro": float(giro[k]), "achat": float(achat[k])} for k in range(len(x))]
    stats["arboles"] = len(arboles)
    return arboles, stats


def malla_troncos(arboles, lados=LADOS_TRONCO):
    """Todos los troncos en un solo mesh: tronco conico (radio superior = 70 % del inferior) con tapa superior."""
    n = len(arboles)
    if n == 0:
        return None
    ang = np.arange(lados) * 2 * np.pi / lados
    cs = np.column_stack([np.cos(ang), np.sin(ang)])
    x = np.array([a["x"] for a in arboles])
    y = np.array([a["y"] for a in arboles])
    rb = np.array([a["r_tronco"] for a in arboles])
    z0 = np.array([a["base"] for a in arboles])
    h = np.array([a["h"] for a in arboles])
    z1 = z0 + ENTERRADO_M + TRONCO_FRAC * h
    inf = np.stack([x[:, None] + rb[:, None] * cs[:, 0], y[:, None] + rb[:, None] * cs[:, 1],
                    np.repeat(z0[:, None], lados, 1)], -1)
    sup = np.stack([x[:, None] + 0.7 * rb[:, None] * cs[:, 0], y[:, None] + 0.7 * rb[:, None] * cs[:, 1],
                    np.repeat(z1[:, None], lados, 1)], -1)
    centro = np.stack([x, y, z1], -1)[:, None, :]
    v = np.concatenate([inf, sup, centro], 1).reshape(-1, 3)          # por arbol: lados + lados + 1
    k = np.arange(lados)
    kn = (k + 1) % lados
    lat = np.concatenate([np.column_stack([k, kn, lados + kn]), np.column_stack([k, lados + kn, lados + k])])
    tapa = np.column_stack([np.full(lados, 2 * lados), lados + k, lados + kn])
    f1 = np.vstack([lat, tapa])
    f = (f1[None, :, :] + (np.arange(n) * (2 * lados + 1))[:, None, None]).reshape(-1, 3)
    return trimesh.Trimesh(v, f, process=False)


def malla_copas(arboles):
    """Todas las copas de `arboles` en un solo mesh: icosfera de 1 nivel (80 triangulos) escalada a (r, r, semialtura)."""
    n = len(arboles)
    if n == 0:
        return None
    ico = trimesh.creation.icosphere(subdivisions=1, radius=1.0)
    uv, uf = np.asarray(ico.vertices), np.asarray(ico.faces)
    x = np.array([a["x"] for a in arboles])
    y = np.array([a["y"] for a in arboles])
    h = np.array([a["h"] for a in arboles])
    rc = np.array([a["r_copa"] for a in arboles])
    z0 = np.array([a["base"] for a in arboles]) + ENTERRADO_M
    giro = np.array([a["giro"] for a in arboles])
    ach = np.array([a["achat"] for a in arboles])
    semi = (1.0 - COPA_INI_FRAC) * h / 2
    zc = z0 + (COPA_INI_FRAC + 1.0) / 2 * h
    c, s = np.cos(giro), np.sin(giro)
    px = uv[None, :, 0] * (rc * ach)[:, None]
    py = uv[None, :, 1] * (rc / ach)[:, None]
    X = x[:, None] + px * c[:, None] - py * s[:, None]
    Y = y[:, None] + px * s[:, None] + py * c[:, None]
    Z = zc[:, None] + uv[None, :, 2] * semi[:, None]
    v = np.stack([X, Y, Z], -1).reshape(-1, 3)
    f = (uf[None, :, :] + (np.arange(n) * len(uv))[:, None, None]).reshape(-1, 3)
    return trimesh.Trimesh(v, f, process=False)


def piezas_arboles(arboles):
    """[(nombre_nodo, mesh, material)]: troncos con colision y una malla de copas por tono de verde (sin colision)."""
    piezas = [("arboles_troncos-col", malla_troncos(arboles), "arbol_corteza")]
    for k in range(N_TONOS):
        sub = [a for a in arboles if a["tono"] == k]
        if sub:
            piezas.append(("arboles_copas" + ("" if k == 0 else f"_{k + 1}"), malla_copas(sub), f"arbol_copa_{k + 1}"))
    return piezas
