"""Calcula los puntos de aparicion del jugador y escribe game/data/spawns.json.

Coordenadas del juego (mismo convenio y origen que el glb): x = este, y = arriba,
z = -norte, en metros, origen = centroide del campus (se comprueba contra
export/upo_blockout_meta.json). El yaw es la rotacion Y de Godot en grados
(0 = mirando a -Z = norte; positivo = giro antihorario visto desde arriba).

Cada spawn queda en espacio libre: >= 3 m de cualquier huella de edificio y del muro
limite, >= 1,5 m de muros/vallas y fuera de zonas de agua; los de edificio, a 5-15 m
de la fachada y preferentemente sobre un camino o via.

Los techos (forma=techo) no cuentan como huella: se puede aparecer bajo ellos, pero a
>= 1 m de sus pilares. Los building=roof siguen contando como huella (margen de 3 m).
Ademas calcula "test_pasillo" (puntos para el test de Godot): un rayo horizontal a 1,5 m
que cruza el pasillo cubierto central de lado a lado entre una pareja de edificios y un
rayo vertical hacia la losa.

Relieve: y = altura(x, z) + 0,1 con el mismo Terreno que generar_blockout.py (mismas opciones --mdt,
--terreno, --paso-terreno, --paso-grueso, --buffer-fino, --suavizado-m; defectos en terreno.py). Todos los rayos de test van a 1,5 m SOBRE EL TERRENO en cada
extremo; si el rayo recto tocaria el terreno (loma intermedia) se trocea en tramos ("tramos": lista de
[desde, hasta]) con los puntos de corte tambien a 1,5 m sobre el terreno. Tambien escribe "test_terreno"
(5 puntos libres con cotas distintas: la y esperada del terreno) y "test_subida" (tramo de maxima pendiente
para que el test haga subir al jugador).

Salidas: game/data/spawns.json y export/spawns_preview.png.
Uso: uv run python scripts/generar_spawns.py [--entrada data/raw/osm_upo.json]
"""
import argparse
import json
import math
import re
import sys
from pathlib import Path

import numpy as np
import shapely
from shapely.geometry import LineString, Point
from shapely.ops import nearest_points, polylabel, unary_union

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generar_blockout as gb  # noqa: E402
import terreno as ter  # noqa: E402

Y_SPAWN = 0.1
DIST_EDIF_MIN = 3.0       # a huellas de edificio
DIST_LIMITE_MIN = 3.0     # al muro limite
DIST_VALLA_MIN = 1.5      # a muros-col y vallas-col
FACHADA_MIN, FACHADA_MAX = 5.0, 15.0
DIST_FACHADA_IDEAL = 8.0
DIST_PILAR_MIN = 1.0
ID_PASILLO_CENTRAL = 1373541639   # techo del eje central (edificios 1 a 18)
PAREJA_TEST = (8, 9)
ID_TUNEL_37 = 142276198
ALT_RAYO = 1.5            # altura de los rayos de test sobre el terreno
LIBRE_RAYO = 0.4          # holgura minima entre un rayo y el terreno

EDIFICIOS = [  # id, nombre visible, numero de edificio
    ("biblioteca", "Biblioteca (Edificio 25)", 25),
    ("pabellon", "Pabellón / Gimnasio (Edificio 26)", 26),
    ("rectorado", "Rectorado (Edificio 32)", 32),
    ("eje_central", "Eje central (Edificio 8)", 8),
]


def yaw_hacia(px, py, tx, ty):
    """Yaw (grados, rotacion Y de Godot) en el plano local (este, norte) hacia un objetivo."""
    dx, dz = tx - px, -(ty - py)          # al convenio del juego: z = -norte
    return math.degrees(math.atan2(-dx, -dz))


class Contexto:
    def __init__(self, mapa, geo):
        self.mapa = mapa
        self.campus = geo["campus"]
        self.edificios = geo["edificios"]
        # los techos (forma=techo) no son huella, salvo los building=roof (conservador)
        self.opacos = [e for e in self.edificios
                       if e["forma"] != "techo" or e["tags"].get("building") == "roof"]
        self.huellas = unary_union([e["poly"] for e in self.opacos])
        self.pilares = unary_union([Point(x, y) for e in self.edificios for x, y in e["pilares"]])             if any(e["pilares"] for e in self.edificios) else None
        self.zona_valida = self.campus.buffer(gb.MARGEN_LIMITE - DIST_LIMITE_MIN)
        self.caminos = unary_union(list(geo["caminos"].values())) if geo["caminos"] else None
        self.agua = geo["zonas"].get("agua")
        barreras = []
        for w in mapa.ways.values():
            if w.get("tags", {}).get("barrier") in ("retaining_wall", "fence"):
                l = mapa.linea(w)
                if l is not None:
                    barreras.append(l)
        self.barreras = unary_union(barreras) if barreras else None
        self.tertiary = geo["caminos"]["tertiary"].intersection(self.zona_valida)

    def pilares_dist(self, geom):
        return geom.distance(self.pilares) if self.pilares is not None else 99.0

    def libre(self, p):
        if not self.zona_valida.contains(p):
            return False
        if self.huellas.distance(p) < DIST_EDIF_MIN:
            return False
        if self.barreras is not None and self.barreras.distance(p) < DIST_VALLA_MIN:
            return False
        if self.pilares is not None and self.pilares.distance(p) < DIST_PILAR_MIN:
            return False
        if self.agua is not None and self.agua.distance(p) < 1.0:
            return False
        return True

    def en_camino(self, p):
        return self.caminos is not None and self.caminos.contains(p)

    def despejado(self, p, objetivo, ignorar):
        """Sin otros edificios entre el punto y el objetivo."""
        l = LineString([p, objetivo])
        return not any(e["id"] != ignorar and l.intersects(e["poly"]) for e in self.opacos)


def buscar_edificio(ctx, numero):
    rx = re.compile(rf"^Edific\w*\s+{numero}\b")
    c = [e for e in ctx.edificios if rx.match(e["nombre"] or "")]
    if not c:
        raise SystemExit(f"No se encuentra el Edificio {numero} en el OSM/CSV")
    return max(c, key=lambda e: e["poly"].area)


def spawn_edificio(ctx, edif):
    poly = edif["poly"]
    mejor = None
    for d in np.arange(FACHADA_MIN, FACHADA_MAX + 0.01, 1.0):
        anillo = poly.buffer(float(d), join_style="round").exterior
        n = max(int(anillo.length / 1.5), 8)
        for i in range(n):
            p = anillo.interpolate(i / n, normalized=True)
            if not ctx.libre(p):
                continue
            q = nearest_points(poly, p)[0]
            if not ctx.despejado(p, q, edif["id"]):
                continue
            espacio = min(ctx.huellas.distance(p), 10.0)
            puntos = (0 if ctx.en_camino(p) else 1000) + abs(d - DIST_FACHADA_IDEAL) * 10 - espacio
            if mejor is None or puntos < mejor[0]:
                mejor = (puntos, p, q, float(d))
    if mejor is None:
        raise SystemExit(f"No hay posicion libre junto a {edif['nombre']}")
    _, p, q, d = mejor
    return p, yaw_hacia(p.x, p.y, q.x, q.y), {"distancia_fachada_m": round(d, 1),
                                               "sobre_camino": bool(ctx.en_camino(p))}


def spawn_entrada(ctx):
    """Junto a la parada 'Universidad Pablo Olavide', sobre la via tertiary libre mas cercana."""
    mapa = ctx.mapa
    parada = None
    for n in mapa.nodos.values():
        t = n.get("tags", {})
        if t.get("highway") == "bus_stop" and t.get("name", "").strip() == "Universidad Pablo Olavide":
            x, y = mapa.tr.transform(n["lon"], n["lat"])
            parada = Point(x - mapa.E0, y - mapa.N0)
    if parada is None:
        raise SystemExit("No hay parada de bus 'Universidad Pablo Olavide' en el OSM")
    mejor = None
    # la via es un poligono (buffer de las lineas): se muestrea en rejilla de 1 m
    cerca = ctx.tertiary.intersection(parada.buffer(60))
    if cerca.is_empty:
        raise SystemExit("No hay via tertiary libre cerca de la parada")
    cx, cy = parada.x, parada.y
    for dx in np.arange(-60, 60.01, 1.0):
        for dy in np.arange(-60, 60.01, 1.0):
            p = Point(cx + dx, cy + dy)
            if cerca.contains(p) and ctx.libre(p):
                d = p.distance(parada)
                if mejor is None or d < mejor[0]:
                    mejor = (d, p)
    d, p = mejor
    centro = ctx.campus.centroid
    return p, yaw_hacia(p.x, p.y, centro.x, centro.y), {"distancia_parada_m": round(d, 1),
                                                         "sobre_camino": True}


def spawn_aparcamiento(ctx):
    mapa = ctx.mapa
    mejor = None
    for w in mapa.ways.values():
        t = w.get("tags", {})
        if t.get("amenity") == "parking" and (t.get("name") or "").startswith("P") and mapa.cerrado(w):
            poly = mapa.poligono(w)
            if mejor is None or poly.area > mejor[0].area:
                mejor = (poly, t["name"])
    poly, nombre = mejor
    libre = poly.intersection(ctx.zona_valida).difference(ctx.huellas.buffer(DIST_EDIF_MIN))
    if ctx.barreras is not None:
        libre = libre.difference(ctx.barreras.buffer(DIST_VALLA_MIN))
    cand = max(gb.validos(libre), key=lambda g: g.area)
    p = polylabel(cand, tolerance=0.5)
    if not ctx.libre(p):
        raise SystemExit("El centro del aparcamiento no esta libre")
    centro = ctx.campus.centroid
    return p, yaw_hacia(p.x, p.y, centro.x, centro.y), {"aparcamiento": nombre, "area_m2": round(poly.area)}


def test_pasillo(ctx, T):
    """Cruza el pasillo central (techo) de lado a lado, perpendicular a su eje, en un punto
    libre de edificios, vallas y pilares cercano al punto medio entre los edificios de PAREJA_TEST."""
    techo = next(e for e in ctx.edificios if e["id"] == ID_PASILLO_CENTRAL)
    poly = techo["poly"]
    cs = list(poly.minimum_rotated_rectangle.exterior.coords)
    l0, l1 = (cs[0], cs[1]) if math.dist(cs[0], cs[1]) > math.dist(cs[1], cs[2]) else (cs[1], cs[2])
    ux, uy = (l1[0] - l0[0]) / math.dist(l0, l1), (l1[1] - l0[1]) / math.dist(l0, l1)
    nx, ny = -uy, ux                                  # perpendicular al eje
    ca, cb = (buscar_edificio(ctx, n)["poly"].centroid for n in PAREJA_TEST)
    objetivo = Point((ca.x + cb.x) / 2, (ca.y + cb.y) / 2)
    eje = LineString([(l0[0] - 400 * ux, l0[1] - 400 * uy), (l0[0] + 400 * ux, l0[1] + 400 * uy)])
    s_obj = eje.project(objetivo)
    obstaculos = unary_union([e["poly"] for e in ctx.edificios if e is not techo])
    mejor = None
    for s in np.arange(0.0, eje.length, 0.5):
        c = eje.interpolate(s)
        cruce = LineString([(c.x - 40 * nx, c.y - 40 * ny), (c.x + 40 * nx, c.y + 40 * ny)]).intersection(poly)
        if cruce.is_empty or cruce.geom_type != "LineString":
            continue
        cc = list(cruce.coords)
        a, b = Point(cc[0]), Point(cc[-1])
        mx, my = (a.x + b.x) / 2, (a.y + b.y) / 2
        ancho = a.distance(b)
        if ancho < 6:
            continue
        a2 = (a.x - 1.5 * nx, a.y - 1.5 * ny)    # 1,5 m fuera de cada borde
        b2 = (b.x + 1.5 * nx, b.y + 1.5 * ny)
        linea = LineString([a2, b2])
        if linea.distance(obstaculos) < 1.0:
            continue
        if ctx.pilares is not None and linea.distance(ctx.pilares) < 1.0:
            continue
        if ctx.barreras is not None and linea.distance(ctx.barreras) < 1.0:
            continue
        d = abs(s - s_obj)
        if mejor is None or d < mejor[0]:
            mejor = (d, a2, b2, (mx, my), ancho)
    if mejor is None:
        raise SystemExit("No hay seccion libre del pasillo central para el test de rayos")
    _, a2, b2, m, ancho = mejor
    hm = float(T.altura(m[0], -m[1]))
    g = lambda p, y: [round(p[0], 2), round(y, 3), round(-p[1], 2)]   # plano local -> juego
    return {"descripcion": f"pasillo central (techo {ID_PASILLO_CENTRAL}) entre los edificios {PAREJA_TEST[0]} y {PAREJA_TEST[1]}",
            "rayo_horizontal": rayo_sobre_terreno(T, (a2[0], -a2[1]), (b2[0], -b2[1])),
            "rayo_vertical": {"desde": g(m, hm + ALT_RAYO), "hasta": g(m, hm + 30.0),
                              "techo_y_min": round(hm + techo["altura"] - gb.GROSOR_TECHO, 3),
                              "techo_y_max": round(hm + techo["altura"], 3)},
            "ancho_pasillo_m": round(ancho, 1)}


def rayo_sobre_terreno(T, p0, p1):
    """Rayo entre dos puntos (x, z de juego) a ALT_RAYO m sobre el terreno en cada extremo. Si el segmento recto
    queda a menos de LIBRE_RAYO m del terreno en algun punto, se trocea en los tramos rectos mas largos posibles
    cuyos puntos de corte estan tambien a ALT_RAYO m sobre el terreno. Devuelve {"desde", "hasta", "tramos"}."""
    L = math.dist(p0, p1)
    n = max(2, int(math.ceil(L / 0.5)) + 1)
    xs, zs = np.linspace(p0[0], p1[0], n), np.linspace(p0[1], p1[1], n)
    hs = T.altura(xs, zs) + ALT_RAYO

    def ok(i, j):
        if j == i + 1:
            return True
        t = np.arange(i, j + 1)
        yr = hs[i] + (hs[j] - hs[i]) * (t - i) / (j - i)
        return bool((yr - (hs[t] - ALT_RAYO) >= LIBRE_RAYO).all())

    pts, i = [0], 0
    while i < n - 1:
        j = n - 1
        while not ok(i, j):
            j -= 1
        pts.append(j)
        i = j
    P = lambda k: [round(float(xs[k]), 2), round(float(hs[k]), 3), round(float(zs[k]), 2)]
    tramos = [[P(a), P(b)] for a, b in zip(pts[:-1], pts[1:])]
    return {"desde": P(0), "hasta": P(n - 1), "tramos": tramos}


def dibujar(ax, spawns):
    for s in spawns:
        x, _, z = s["pos"]
        ax.plot(x, -z, marker="*", ms=17, mfc="yellow", mec="black", mew=1.2, zorder=10, ls="none")
        r = math.radians(s["yaw_deg"])
        ax.annotate("", xy=(x - 45 * math.sin(r), -z + 45 * math.cos(r)), xytext=(x, -z), zorder=10,
                    arrowprops=dict(arrowstyle="-|>", color="red", lw=2))
        ax.annotate(f"{s['id']}: {s['nombre']}", (x, -z), xytext=(10, 14), textcoords="offset points",
                    fontsize=9, fontweight="bold", zorder=11,
                    bbox=dict(boxstyle="round,pad=0.25", fc="white", ec="black", alpha=0.9))


def test_paso_22_24(geo, T):
    """Rayo horizontal a 1,5 m por el eje de la franja abierta entre los edificios 22 y 24
    (paso '22-24' de pasos.csv), de oeste a este y de extremo a extremo; no debe chocar con nada."""
    p = next((q for q in geo["pasos"] if q["id"] == "22-24"), None)
    if p is None:
        raise SystemExit("No hay paso 22-24 en pasos.csv para test_paso_22_24")
    (x1, y1), (x2, y2) = p["seg"].coords
    return {"descripcion": "franja abierta entre los edificios 22 y 24: rayo a 1,5 m por el eje, de oeste a este",
            "ancho_m": p["ancho"],
            "rayo_horizontal": rayo_sobre_terreno(T, (x1, -y1), (x2, -y2))}


def test_pasillo_pilares(ctx, T):
    """Tramo recto de ~30 m por el centro del pasillo central (paralelo a uno de sus bordes largos,
    a 4-6 m de el): un rayo a 1,5 m por ahi no debe chocar (sin pilares interiores)."""
    techo = next(e for e in ctx.edificios if e["id"] == ID_PASILLO_CENTRAL)
    poly = techo["poly"]
    sin_orilla = poly.buffer(-3.0)
    obst = unary_union([e["poly"] for e in ctx.edificios if e is not techo and e["forma"] != "techo"])
    mejor = None
    for pg in gb.validos(poly):
        c = list(pg.exterior.coords)
        for a, b in zip(c[:-1], c[1:]):
            L = math.dist(a, b)
            if L < 32:
                continue
            ux, uy = (b[0] - a[0]) / L, (b[1] - a[1]) / L
            for sgn in (1, -1):
                nx, ny = -uy * sgn, ux * sgn
                for off in (4.0, 5.0, 6.0):
                    for t0 in np.arange(0.0, L - 30.0, 1.0):
                        p0 = (a[0] + ux * t0 + nx * off, a[1] + uy * t0 + ny * off)
                        p1 = (p0[0] + 30 * ux, p0[1] + 30 * uy)
                        ln = LineString([p0, p1])
                        if not sin_orilla.contains(ln) or ln.distance(obst) < 1.0:
                            continue
                        d = ln.distance(ctx.pilares) if ctx.pilares is not None else 99.0
                        if d < 1.5:
                            continue
                        if mejor is None or d > mejor[0]:
                            mejor = (d, p0, p1)
    if mejor is None:
        raise SystemExit("No hay tramo recto de 30 m libre en el pasillo central para test_pasillo_pilares")
    return {"descripcion": f"tramo recto de 30 m por el centro del pasillo central ({ID_PASILLO_CENTRAL}), sin pilares interiores",
            "rayo_horizontal": rayo_sobre_terreno(T, (mejor[1][0], -mejor[1][1]), (mejor[2][0], -mejor[2][1])),
            "dist_min_pilar_m": round(mejor[0], 1)}


def test_tunel_37(ctx, T):
    """Edificio 37 (tunel_z): rayo a 1,5 m de norte a sur por su centro (debe pasar) y de oeste a
    este (debe chocar con la pared)."""
    e = next(e for e in ctx.edificios if e["id"] == ID_TUNEL_37)
    poly = e["poly"]
    c = poly.centroid
    x0, y0, x1, y1 = poly.bounds
    g = lambda x, y: (round(x, 2), round(-y, 2))
    return {"descripcion": "Edificio 37 (tunel_z): rayo N-S por el centro (libre) y rayo O-E (choca con pared)",
            "rayo_norte_sur": rayo_sobre_terreno(T, g(c.x, y1 + 2.0), g(c.x, y0 - 2.0)),
            "rayo_oeste_este": rayo_sobre_terreno(T, g(x0 - 2.0, c.y), g(x1 + 2.0, c.y))}


def test_terreno(ctx, T):
    """5 puntos libres (sin edificio, techo ni pilar a mano) con cotas distintas: la mas alta, la mas baja y
    los cuartiles 25/50/75 de las cotas de los puntos libres del campus (rejilla de 5 m). Para cada uno, la
    y esperada del terreno (un rayo vertical debe chocar con terreno-col a +-0,3 m de ella)."""
    techos = unary_union([e["poly"] for e in ctx.edificios if e["forma"] == "techo"])
    x0, y0, x1, y1 = ctx.campus.bounds
    cand = []
    for x in np.arange(x0, x1, 5.0):
        for y in np.arange(y0, y1, 5.0):
            p = Point(x, y)
            if ctx.campus.contains(p) and ctx.libre(p) and techos.distance(p) > 3.0:
                cand.append((float(T.altura(x, -y)), x, y))
    cand.sort()
    idx = {"bajo": 0, "p25": len(cand) // 4, "p50": len(cand) // 2, "p75": 3 * len(cand) // 4, "alto": len(cand) - 1}
    pts = [{"nombre": k, "pos": [round(cand[i][1], 2), round(cand[i][0], 3), round(-cand[i][2], 2)]}
           for k, i in idx.items()]
    return {"descripcion": "5 puntos libres con cotas distintas: y esperada del terreno", "puntos": pts}


PEND_LOCAL_MAX_GRADOS = 35.0   # test_subida: pendiente local maxima admitida a lo largo del tramo (floor_max_angle = 45)


def pend_local_max(T, a, b, paso=0.5, lateral=0.5):
    """Pendiente local maxima (grados) del terreno a lo largo del segmento a-b (plano este-norte), muestreado cada
    `paso` m en el eje y en dos carriles a +-`lateral` m (el jugador es una capsula, no un punto). Con un MDT de 1 m
    hay taludes y muros de contencion: la media del tramo puede ser caminable y un escalon intermedio no."""
    a, b = np.asarray(a, float), np.asarray(b, float)
    d = b - a
    L = float(np.hypot(*d))
    u, nrm = d / L, np.array([-d[1], d[0]]) / L
    t = np.linspace(0.0, L, int(round(L / paso)) + 1)
    peor = 0.0
    for off in (-lateral, 0.0, lateral):
        P = a[None, :] + t[:, None] * u[None, :] + off * nrm[None, :]
        h = T.altura(P[:, 0], -P[:, 1])
        peor = max(peor, float(np.abs(np.diff(h)).max() / (t[1] - t[0])))
    return math.degrees(math.atan(peor))


def test_subida(ctx, T, longitud=12.0):
    """Tramo recto de `longitud` m, libre de obstaculos, con la mayor pendiente media del campus (y pendiente local
    <= PEND_LOCAL_MAX_GRADOS en todo el tramo): el test hace
    caminar al jugador cuesta arriba desde `desde` (yaw hacia `hasta`) y comprueba que llega arriba."""
    obst = unary_union([ctx.huellas] + ([ctx.barreras] if ctx.barreras is not None else []) +
                       ([ctx.agua] if ctx.agua is not None else []))
    x0, y0, x1, y1 = ctx.campus.bounds
    mejor = None
    xs, ys = np.arange(x0, x1, 6.0), np.arange(y0, y1, 6.0)
    GX, GY = np.meshgrid(xs, ys, indexing="ij")
    H0 = T.altura(GX, -GY)                          # alturas de todo el barrido de una vez (vectorizado)
    ok0 = shapely.contains_xy(ctx.zona_valida, GX, GY)
    cand = []                                       # (pendiente, ix, iy, ia)
    for ia, ang in enumerate(range(0, 360, 45)):
        QX, QY = GX + math.cos(math.radians(ang)) * longitud, GY + math.sin(math.radians(ang)) * longitud
        H1 = T.altura(QX, -QY)
        ok = ok0 & shapely.contains_xy(ctx.zona_valida, QX, QY) & (H1 > H0)
        for ix, iy in zip(*np.nonzero(ok)):
            cand.append(((H1[ix, iy] - H0[ix, iy]) / longitud, ix, iy, ia))
    cand.sort(key=lambda c: (-c[0], c[1], c[2], c[3]))     # mayor pendiente; a igualdad, el primero del barrido
    for pend, ix, iy, ia in cand:
        x, y, ang = xs[ix], ys[iy], ia * 45
        q = (x + math.cos(math.radians(ang)) * longitud, y + math.sin(math.radians(ang)) * longitud)
        l = LineString([(x, y), q])
        if l.distance(obst) > 2.0 and ctx.pilares_dist(l) > 1.0 and pend_local_max(T, (x, y), q) <= PEND_LOCAL_MAX_GRADOS:
            mejor = (pend, (x, y), q, float(H0[ix, iy]), float(T.altura(q[0], -q[1])))
            break
    pend, a, b, h0, h1 = mejor
    grados = math.degrees(math.atan(pend))
    return {"descripcion": f"tramo de {longitud:g} m con la mayor pendiente media del campus ({grados:.1f} grados)",
            "desde": [round(a[0], 2), round(h0 + Y_SPAWN, 3), round(-a[1], 2)],
            "hasta": [round(b[0], 2), round(h1, 3), round(-b[1], 2)],
            "yaw_deg": round(yaw_hacia(a[0], a[1], b[0], b[1]), 1), "longitud_m": longitud,
            "pendiente_grados": round(grados, 2)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--entrada", default="data/raw/osm_upo.json")
    ap.add_argument("--alturas", default="data/alturas.csv")
    ap.add_argument("--pasos", default="data/pasos.csv")
    ap.add_argument("--pistas", default="data/pistas.csv")
    ap.add_argument("--meta", default="export/upo_blockout_meta.json")
    ap.add_argument("--salida", default="game/data/spawns.json")
    ap.add_argument("--preview", default="export/spawns_preview.png")
    ter.anadir_argumentos(ap)
    a = ap.parse_args()

    mapa = gb.Mapa(a.entrada)
    meta = json.loads(Path(a.meta).read_text(encoding="utf-8"))
    for k, v in (("E_utm25830", mapa.E0), ("N_utm25830", mapa.N0)):
        if abs(meta["origen"][k] - v) > 1e-3:
            raise SystemExit(f"El origen del OSM no coincide con {a.meta} ({k}); regenera el blockout")

    edificios = [(wid, w["tags"]) for wid, w in sorted(mapa.ways.items())
                 if "tags" in w and mapa.cerrado(w)
                 and ("building" in w["tags"] or w["tags"].get("man_made") == "tower")]
    filas = gb.cargar_alturas(a.alturas, edificios)
    campus = gb.campus_local(mapa)
    T = ter.crear(a, mapa.E0, mapa.N0, campus, gb.zona_fina(mapa, campus, a.buffer_fino))
    mt = meta.get("terreno", {})
    # la fuente y la cota de referencia deben coincidir con el blockout; tambien la malla (pasos y zona fina),
    # porque las alturas de spawns y tests se calculan sobre la misma malla que la colision
    dif = [k for k in ("fuente", "suavizado_m", "paso_fino_m", "paso_grueso_m", "zona_fina_m2") if mt.get(k) != T.info()[k]]
    if abs(mt.get("cota_ref", 0.0) - T.cota_ref) > 1e-3:
        dif.append("cota_ref")
    if dif:
        raise SystemExit(f"El terreno ({T.info()}) no coincide con {a.meta} ({mt}) en {dif}; "
                         "usa las mismas opciones que generar_blockout.py o regenera el blockout")
    _, _, geo = gb.construir(mapa, filas, gb.cargar_pasos(a.pasos), gb.cargar_pistas(a.pistas), T)
    ctx = Contexto(mapa, geo)

    cand = [("entrada", "Entrada principal", *spawn_entrada(ctx))]
    for sid, nombre, num in EDIFICIOS:
        cand.append((sid, nombre, *spawn_edificio(ctx, buscar_edificio(ctx, num))))
    cand.append(("aparcamiento", "Aparcamiento", *spawn_aparcamiento(ctx)))

    spawns = []
    for sid, nombre, p, yaw, info in cand:
        x, z = float(p.x), float(-p.y)       # plano local (este, norte) -> glTF (x, z = -norte)
        yt = float(T.altura(x, z))
        spawns.append({"id": sid, "nombre": nombre, "pos": [round(x, 2), round(yt + Y_SPAWN, 3), round(z, 2)],
                       "y_terreno": round(yt, 3), "yaw_deg": round(yaw, 1), "info": info})
        print(f"{sid:13s} {nombre:36s} pos=({x:8.2f}, {yt + Y_SPAWN:7.3f}, {z:8.2f}) yaw={yaw:7.1f}  {info}")

    salida = Path(a.salida)
    salida.parent.mkdir(parents=True, exist_ok=True)
    tp = test_pasillo(ctx, T)
    print("test_pasillo:", json.dumps(tp, ensure_ascii=False))
    tp3 = test_pasillo_pilares(ctx, T)
    print("test_pasillo_pilares:", json.dumps(tp3, ensure_ascii=False))
    tp4 = test_tunel_37(ctx, T)
    print("test_tunel_37:", json.dumps(tp4, ensure_ascii=False))
    tp2 = test_paso_22_24(geo, T)
    print("test_paso_22_24:", json.dumps(tp2, ensure_ascii=False))
    tt = test_terreno(ctx, T)
    print("test_terreno:", json.dumps(tt, ensure_ascii=False))
    ts = test_subida(ctx, T)
    print("test_subida:", json.dumps(ts, ensure_ascii=False))
    salida.write_text(json.dumps({"ejes": meta["ejes_gltf"], "origen": meta["origen"], "spawns": spawns,
                                  "test_pasillo": tp, "test_paso_22_24": tp2,
                                  "test_pasillo_pilares": tp3, "test_tunel_37": tp4,
                                  "test_terreno": tt, "test_subida": ts, "terreno": mt},
                                 indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Escrito {salida}")
    gb.preview(Path(a.preview), geo, extra=lambda ax: dibujar(ax, spawns))


if __name__ == "__main__":
    main()
