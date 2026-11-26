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
from shapely.geometry import LineString, Point
from shapely.ops import nearest_points, polylabel, unary_union

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generar_blockout as gb  # noqa: E402

Y_SPAWN = 0.1
DIST_EDIF_MIN = 3.0       # a huellas de edificio
DIST_LIMITE_MIN = 3.0     # al muro limite
DIST_VALLA_MIN = 1.5      # a muros-col y vallas-col
FACHADA_MIN, FACHADA_MAX = 5.0, 15.0
DIST_FACHADA_IDEAL = 8.0
DIST_PILAR_MIN = 1.0
ID_PASILLO_CENTRAL = 1373541639   # techo del eje central (edificios 1 a 18)
PAREJA_TEST = (8, 9)

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
                       if e["forma"] == "volumen" or e["tags"].get("building") == "roof"]
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


def test_pasillo(ctx):
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
    g = lambda p, y: [round(p[0], 2), y, round(-p[1], 2)]   # plano local -> juego
    return {"descripcion": f"pasillo central (techo {ID_PASILLO_CENTRAL}) entre los edificios {PAREJA_TEST[0]} y {PAREJA_TEST[1]}",
            "rayo_horizontal": {"desde": g(a2, 1.5), "hasta": g(b2, 1.5)},
            "rayo_vertical": {"desde": g(m, 1.5), "hasta": g(m, 30.0), "techo_y_min": round(techo["altura"] - gb.GROSOR_TECHO, 2),
                              "techo_y_max": round(techo["altura"], 2)},
            "ancho_pasillo_m": round(ancho, 1)}


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


def test_paso_22_24(geo):
    """Rayo horizontal a 1,5 m por el eje de la franja abierta entre los edificios 22 y 24
    (paso '22-24' de pasos.csv), de oeste a este y de extremo a extremo; no debe chocar con nada."""
    p = next((q for q in geo["pasos"] if q["id"] == "22-24"), None)
    if p is None:
        raise SystemExit("No hay paso 22-24 en pasos.csv para test_paso_22_24")
    (x1, y1), (x2, y2) = p["seg"].coords
    return {"descripcion": "franja abierta entre los edificios 22 y 24: rayo a 1,5 m por el eje, de oeste a este",
            "ancho_m": p["ancho"],
            "rayo_horizontal": {"desde": [round(x1, 2), 1.5, round(-y1, 2)],
                                "hasta": [round(x2, 2), 1.5, round(-y2, 2)]}}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--entrada", default="data/raw/osm_upo.json")
    ap.add_argument("--alturas", default="data/alturas.csv")
    ap.add_argument("--pasos", default="data/pasos.csv")
    ap.add_argument("--pistas", default="data/pistas.csv")
    ap.add_argument("--meta", default="export/upo_blockout_meta.json")
    ap.add_argument("--salida", default="game/data/spawns.json")
    ap.add_argument("--preview", default="export/spawns_preview.png")
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
    _, _, geo = gb.construir(mapa, filas, gb.cargar_pasos(a.pasos), gb.cargar_pistas(a.pistas))
    ctx = Contexto(mapa, geo)

    cand = [("entrada", "Entrada principal", *spawn_entrada(ctx))]
    for sid, nombre, num in EDIFICIOS:
        cand.append((sid, nombre, *spawn_edificio(ctx, buscar_edificio(ctx, num))))
    cand.append(("aparcamiento", "Aparcamiento", *spawn_aparcamiento(ctx)))

    spawns = []
    for sid, nombre, p, yaw, info in cand:
        x, z = float(p.x), float(-p.y)       # plano local (este, norte) -> glTF (x, z = -norte)
        spawns.append({"id": sid, "nombre": nombre, "pos": [round(x, 2), Y_SPAWN, round(z, 2)],
                       "yaw_deg": round(yaw, 1), "info": info})
        print(f"{sid:13s} {nombre:36s} pos=({x:8.2f}, {Y_SPAWN}, {z:8.2f}) yaw={yaw:7.1f}  {info}")

    salida = Path(a.salida)
    salida.parent.mkdir(parents=True, exist_ok=True)
    tp = test_pasillo(ctx)
    print("test_pasillo:", json.dumps(tp, ensure_ascii=False))
    tp2 = test_paso_22_24(geo)
    print("test_paso_22_24:", json.dumps(tp2, ensure_ascii=False))
    salida.write_text(json.dumps({"ejes": meta["ejes_gltf"], "origen": meta["origen"], "spawns": spawns,
                                  "test_pasillo": tp, "test_paso_22_24": tp2},
                                 indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Escrito {salida}")
    gb.preview(Path(a.preview), geo, extra=lambda ax: dibujar(ax, spawns))


if __name__ == "__main__":
    main()
