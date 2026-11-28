"""Valida, completa y exporta las zonas competitivas: data/zonas.json (fuente editable) -> game/data/zonas.json.

Coordenadas de data/zonas.json: de juego (x = este, z = -norte, metros; yaw_deg = rotacion Y de Godot, 0 = mirando a -Z = norte).
Cada zona lleva: id, nombre, limite (poligono de 8-20 vertices), sites A y B (circulo {centro, radio} o {poligono}),
spawn_atacantes / spawn_defensores ({posiciones: [[x, z, yaw]] x 5, barrera: poligono que encierra el spawn}) y camara_lobby
({pos: [x, z], altura, mira: [x, z], mira_altura, fov}).

El generador, con el mismo terreno, arboles, coches y props que el blockout (mismas opciones que generar_blockout.py):
  1. Valida cada zona (tamano, vertices, sites 8-12 m, todo fuera de edificios cerrados, dentro del limite, spawns libres de
     troncos / coches / props, limite y barreras sin cortar troncos ni coches) y estima los recorridos a pie (scripts/zonas_nav.py:
     rejilla de 0,5 m con obstaculos engrosados 0,4 m y Dijkstra; tiempo = longitud / 5 m/s) de cada spawn a cada site: media de los
     5 spawns de cada equipo y ventaja de los defensores (objetivo 5-8 s). Cuenta rutas alternativas y el mayor tramo abierto
     (sin cobertura a < 3 m) de las rutas.
  2. Escribe game/data/zonas.json con la y del terreno (limite y barreras ademas densificados cada <= 4 m para el muro de
     runtime) y las estimaciones.
  3. Dibuja export/zonas/<id>.png: limite, sites, spawns, barreras, edificios, coberturas, rutas y curvas de nivel.
Sale con codigo 1 si alguna zona no cumple las comprobaciones duras (no hace falta que cumpla las de ventaja de tiempo).

Uso: uv run python scripts/generar_zonas.py [--solo plaza_america] [--sin-preview] [--sin-exportar] (+ opciones del mapa)
"""
import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np
import shapely
from shapely.geometry import Point, Polygon
from shapely.ops import unary_union

sys.path.insert(0, str(Path(__file__).resolve().parent))
import coches as coc  # noqa: E402
import contexto as cx  # noqa: E402
import datos_zonas as dz  # noqa: E402
import generar_blockout as gb  # noqa: E402
import props as prp  # noqa: E402
import zonas_nav as nav  # noqa: E402

SALIDA_JUEGO = "game/data/zonas.json"
DIR_PREVIEW = "export/zonas"
Y_SPAWN = 0.1
TAM_MIN, TAM_MAX = 110.0, 215.0         # lado del rectangulo minimo orientado (~120-200 m)
VERTICES = (8, 20)
RADIO_SITE = (8.0, 12.0)
VENTAJA_OBJ = (5.0, 8.0)                # llegada de los defensores unos 5-8 s antes
VENTAJA_TOL = (4.0, 9.5)                # tolerancia que se acepta antes de avisar
RUTAS_MIN = 3
PASO_DENSO = 4.0
ALTO_MURO = 8.0
ALTO_BARRERA = 4.0
COL_EQUIPO = {"atacantes": "#e8590c", "defensores": "#1c7ed6"}
EQUIPOS = dz.EQUIPOS


class Contexto:
    def __init__(self, a):
        self.mapa, self.T, self.geo, self.filas = cx.crear_geo(a)
        self.props = gb.construir_props(self.mapa, self.geo, a)
        self.arboles, self.coches = self.props["arboles"], self.props["coches"]
        self.entorno = self.props["entorno"]
        self.huellas_props = self.props["huellas_props"]
        self.opacos = nav.edificios_cerrados(self.geo)
        self.campus = self.geo["campus"]
        self.obst = nav.obstaculos_mundo(self.geo, self.entorno, self.arboles, self.coches, self.huellas_props)
        # cobertura: lo que protege de una bala (altura > 0,8 m), sin engrosar
        cob = [self.opacos]
        cob += [Point(t["x"], t["y"]).buffer(t["r_tronco"]) for t in self.arboles if t["r_tronco"] >= 0.45]
        cob += [coc.rect_coche(c) for c in self.coches]
        cob += [g for g, p in zip(self.huellas_props, self.props["props"]) if prp.alto(p["tipo"], p["escala"], p["notas"]) >= nav.COBERTURA_ALTA_M]
        if self.entorno.barreras is not None:
            cob.append(self.entorno.barreras.buffer(0.1))
        self.cobertura = unary_union(cob)
        self.troncos = shapely.points([(t["x"], t["y"]) for t in self.arboles]) if self.arboles else np.zeros(0, object)
        self.r_troncos = np.array([t["r_tronco"] for t in self.arboles])
        self.rects_coches = [coc.rect_coche(c) for c in self.coches]


def y_terreno(T, x_juego, z_juego):
    return float(T.altura(float(x_juego), float(z_juego)))


def dims_orientadas(poly):
    mrr = poly.minimum_rotated_rectangle
    c = list(mrr.exterior.coords)
    a, b = math.dist(c[0], c[1]), math.dist(c[1], c[2])
    return max(a, b), min(a, b)


def radio_equivalente(g):
    return math.sqrt(g.area / math.pi)


def libre_de_obstaculos(ctx, p, margen=0.0):
    """Un punto (Point local) a salvo de troncos, coches, props y edificios."""
    d_edif = ctx.opacos.distance(p)
    if d_edif < 0.5 + margen:
        return False, "edificio"
    for i in range(len(ctx.troncos)):
        if ctx.troncos[i].distance(p) < ctx.r_troncos[i] + 0.35 + 0.15 + margen:
            return False, "tronco"
    for r in ctx.rects_coches:
        if r.distance(p) < 0.35 + 0.5 + margen:
            return False, "coche"
    for g in ctx.huellas_props:
        if g.distance(p) < 0.35 + 0.2 + margen:
            return False, "prop"
    return True, ""


def sitio(z, k, ctx):
    s = z["sites"][k]
    if "poligono" in s:
        return dz.poligono_local(s["poligono"])
    return Point(dz.a_local(*s["centro"][:2])).buffer(float(s["radio"]), 32)


def centro_site(z, k):
    s = z["sites"][k]
    if "poligono" in s:
        c = dz.poligono_local(s["poligono"]).centroid
        return (c.x, c.y)
    return dz.a_local(*s["centro"][:2])


def validar(z, ctx):
    """(errores, avisos, info). Errores = comprobaciones duras."""
    err, av, info = [], [], {}
    zl = dz.zonas_local([z])[0]
    lim = zl["limite"]
    nv = len(z["limite"])
    if not VERTICES[0] <= nv <= VERTICES[1]:
        err.append(f"el limite tiene {nv} vertices (deben ser {VERTICES[0]}-{VERTICES[1]})")
    if not lim.is_valid:
        err.append("el limite no es un poligono simple valido")
    largo, ancho = dims_orientadas(lim)
    info["largo_m"], info["ancho_m"], info["area_m2"] = round(largo, 1), round(ancho, 1), round(lim.area)
    if not (TAM_MIN <= largo <= TAM_MAX):
        av.append(f"tamano {largo:.0f} x {ancho:.0f} m (se pretende ~120-200 m de lado)")
    if ancho < 70:
        av.append(f"zona estrecha: {ancho:.0f} m")
    if not ctx.campus.buffer(gb.MARGEN_LIMITE - 1.0).contains(lim):
        err.append("el limite sale del area jugable (contorno del campus + 20 m - 1 m)")
    # el limite no corta edificios: longitud del perimetro dentro de edificios cerrados
    dentro = lim.exterior.intersection(ctx.opacos.buffer(-0.5)).length   # 0,5 m de tolerancia: el muro junto a la fachada no cuenta
    info["limite_en_edificios_m"] = round(dentro, 1)
    if dentro > 0.5:
        av.append(f"{dentro:.1f} m del limite atraviesan edificios (el muro quedaria dentro del edificio)")
    # troncos y coches
    lineas = [lim.exterior] + [b.exterior for b in zl["barreras"]]
    cortan_arb = [i for i in range(len(ctx.troncos)) if any(l.distance(ctx.troncos[i]) < ctx.r_troncos[i] + 0.05 for l in lineas)]
    cortan_coc = [i for i, r in enumerate(ctx.rects_coches) if any(l.intersects(r) for l in lineas)]
    if cortan_arb:
        err.append(f"el limite/barreras cortan {len(cortan_arb)} troncos")
    if cortan_coc:
        err.append(f"el limite/barreras cortan {len(cortan_coc)} coches")
    # sites
    for k, s in zl["sites"].items():
        r = radio_equivalente(s)
        if not RADIO_SITE[0] - 0.01 <= r <= RADIO_SITE[1] + 0.01:
            err.append(f"site {k}: radio equivalente {r:.1f} m (8-12 m)")
        if not lim.buffer(-1.0).contains(s):
            err.append(f"site {k} no esta dentro del limite")
        solape = s.intersection(ctx.opacos).area
        if solape > 0.01:
            err.append(f"site {k}: {solape:.0f} m2 dentro de edificios cerrados")
    # spawns y barreras
    for eq in EQUIPOS:
        sp = z["spawn_" + eq]
        pos = sp["posiciones"]
        if len(pos) != 5:
            err.append(f"spawn_{eq}: {len(pos)} posiciones (deben ser 5)")
        bar = dz.poligono_local(sp["barrera"])
        if not bar.is_valid:
            err.append(f"barrera de {eq} no valida")
        if len(sp["barrera"]) < 3:
            err.append(f"barrera de {eq} con < 3 vertices")
        if not lim.buffer(0.01).contains(bar):
            err.append(f"barrera de {eq} sale del limite")
        if bar.intersection(ctx.opacos).area > 1.0:
            err.append(f"barrera de {eq}: {bar.intersection(ctx.opacos).area:.0f} m2 dentro de edificios")
        pts = []
        for p in pos:
            pl = Point(dz.a_local(p[0], p[1]))
            pts.append(pl)
            if not bar.buffer(-0.5).contains(pl):
                err.append(f"spawn {eq} ({p[0]:.1f}, {p[1]:.1f}) a < 0,5 m de la barrera o fuera de ella")
            ok, que = libre_de_obstaculos(ctx, pl)
            if not ok:
                err.append(f"spawn {eq} ({p[0]:.1f}, {p[1]:.1f}) bloqueado por {que}")
            if len(p) < 3:
                err.append(f"spawn {eq} sin yaw")
        for i in range(len(pts)):
            for j in range(i + 1, len(pts)):
                if pts[i].distance(pts[j]) < 1.2:
                    err.append(f"spawns {eq} {i} y {j} a < 1,2 m")
        info["area_barrera_" + eq] = round(bar.area)
    if zl["barreras"][0].intersects(zl["barreras"][1]):
        err.append("las barreras de los dos equipos se solapan")
    # cobertura de los sites (n. de coberturas a < 8 m)
    return err, av, info


def validar_props(ctx):
    """Comprobaciones globales de data/props.csv: (errores, avisos). Un prop no puede solaparse con un edificio, un coche ni un
    tronco, ni con otro prop (aviso), ni sobre un terreno con mas de 0,45 m de desnivel bajo su huella (aviso)."""
    err, av = [], []
    import generar_props as gp
    libre_suelos = unary_union(gp.zona_libre_suelos(ctx.geo)) if ctx.geo.get("suelos") else None
    filas, hs = ctx.props["props"], ctx.huellas_props
    for i, (p, g) in enumerate(zip(filas, hs)):
        et = f"prop {i + 2} ({p['tipo']} en {p['x']:.1f}, {p['z']:.1f})"
        if ctx.opacos is not None and ctx.opacos.intersection(g).area > 0.02:
            err.append(f"{et} se solapa con un edificio")
        if any(g.intersects(r) for r in ctx.rects_coches):
            err.append(f"{et} se solapa con un coche")
        if libre_suelos is not None and libre_suelos.intersects(g):
            err.append(f"{et} esta sobre un suelo de pasillo reservado (puente / centro del pasillo central)")
        for k in range(len(ctx.troncos)):
            if ctx.troncos[k].distance(g) < ctx.r_troncos[k]:
                err.append(f"{et} se solapa con un tronco")
                break
        lo, hi = prp.desnivel(p, ctx.T)
        if hi - lo > prp.PENDIENTE_MAX_M + 0.05:
            av.append(f"{et}: desnivel {hi - lo:.2f} m bajo su huella")
    if hs:
        arbol = shapely.STRtree(hs)
        for i, g in enumerate(hs):
            for j in arbol.query(g):
                if j > i and g.intersection(hs[j]).area > 0.02 and not (filas[i]["tipo"].startswith("reciclaje") and filas[j]["tipo"].startswith("reciclaje")):
                    av.append(f"props {i + 2} ({filas[i]['tipo']}) y {j + 2} ({filas[j]['tipo']}) se solapan")
    return err, av


def estimar(z, ctx, rej):
    """Recorridos spawn -> site: {site: {equipo: [t_s]}} y rutas alternativas y tramos abiertos."""
    zl = dz.zonas_local([z])[0]
    out = {"tiempos": {}, "rutas": {}, "abierto_max_m": {}, "caminos": {}, "tramos_abiertos": []}
    spawns = {eq: [dz.a_local(p[0], p[1]) for p in z["spawn_" + eq]["posiciones"]] for eq in EQUIPOS}
    for k in z["sites"]:
        c = centro_site(z, k)
        d, _ = rej.distancias([c])
        cel = [rej.celda_libre_cercana(*c)]
        ic = cel[0][0] * rej.nx + cel[0][1]
        out["tiempos"][k] = {}
        for eq in EQUIPOS:
            ts = []
            for p in spawns[eq]:
                cp = rej.celda_libre_cercana(*p)
                ts.append(float(d[0, cp[0] * rej.nx + cp[1]]) / nav.VEL_MS if cp else math.inf)
            out["tiempos"][k][eq] = ts
        # rutas alternativas desde el centro del spawn de atacantes
        cen = tuple(np.mean(spawns["atacantes"], axis=0))
        rutas = rej.rutas_alternativas(cen, c)
        out["rutas"][k] = [round(L / nav.VEL_MS, 1) for L, _ in rutas]
        out["caminos"][k] = [pts for _, pts in rutas]
        for eq in EQUIPOS:
            cen_e = tuple(np.mean(spawns[eq], axis=0))
            pts, L = rej.camino(cen_e, c)
            out["caminos"][f"{k}_{eq}"] = [pts] if pts else []
        mx = 0.0
        spawn_zona = unary_union([b.buffer(4.0) for b in zl["barreras"]])
        for pts in out["caminos"][k] + out["caminos"][f"{k}_atacantes"] + out["caminos"][f"{k}_defensores"]:
            m, tr = nav.tramos_abiertos(pts, ctx.cobertura, ignorar=spawn_zona)
            mx = max(mx, m)
            out["tramos_abiertos"].extend(tr)
        out["abierto_max_m"][k] = round(mx, 1)
    return out


def resumen_tiempos(z, est):
    lineas = []
    for k in z["sites"]:
        t = est["tiempos"][k]
        ma, md = float(np.mean(t["atacantes"])), float(np.mean(t["defensores"]))
        lineas.append((k, ma, md, ma - md, min(t["atacantes"]), max(t["atacantes"]), min(t["defensores"]), max(t["defensores"])))
    return lineas


# ------------------------------------------------------------------ exportacion
def densificar(pts_local, T, paso=PASO_DENSO):
    """Anillo cerrado local (x, norte) -> [[x, y, z]] de juego, vertices originales + puntos intermedios cada <= paso m."""
    out = []
    n = len(pts_local)
    for i in range(n):
        a, b = np.array(pts_local[i]), np.array(pts_local[(i + 1) % n])
        L = float(np.linalg.norm(b - a))
        m = max(1, int(math.ceil(L / paso)))
        for k in range(m):
            p = a + (b - a) * (k / m)
            out.append([round(float(p[0]), 2), round(y_terreno(T, p[0], -p[1]), 3), round(float(-p[1]), 2)])
    return out


def exportar_zona(z, ctx, est):
    T = ctx.T
    y = lambda x, zz: round(y_terreno(T, x, zz), 3)
    lim = [[round(p[0], 2), y(p[0], p[1]), round(p[1], 2)] for p in z["limite"]]
    lim_l = [dz.a_local(p[0], p[1]) for p in z["limite"]]
    out = {"id": z["id"], "nombre": z["nombre"], "descripcion": z.get("descripcion", ""),
           "limite": lim, "limite_denso": densificar(lim_l, T),
           "alto_muro": ALTO_MURO, "alto_barrera": ALTO_BARRERA, "sites": {}}
    for k, s in z["sites"].items():
        if "poligono" in s:
            c = dz.poligono_local(s["poligono"]).centroid
            cj = [round(c.x, 2), y(c.x, -c.y), round(-c.y, 2)]
            out["sites"][k] = {"nombre": s.get("nombre", k), "centro": cj, "radio": round(radio_equivalente(dz.poligono_local(s["poligono"])), 2),
                               "poligono": [[round(p[0], 2), y(p[0], p[1]), round(p[1], 2)] for p in s["poligono"]]}
        else:
            c = s["centro"]
            out["sites"][k] = {"nombre": s.get("nombre", k), "centro": [round(c[0], 2), y(c[0], c[1]), round(c[1], 2)],
                               "radio": float(s["radio"])}
    for eq in EQUIPOS:
        sp = z["spawn_" + eq]
        bar_l = [dz.a_local(p[0], p[1]) for p in sp["barrera"]]
        out["spawn_" + eq] = {
            "posiciones": [{"pos": [round(p[0], 2), round(y(p[0], p[1]) + Y_SPAWN, 3), round(p[1], 2)], "yaw_deg": round(p[2], 1)}
                           for p in sp["posiciones"]],
            "barrera": [[round(p[0], 2), y(p[0], p[1]), round(p[1], 2)] for p in sp["barrera"]],
            "barrera_densa": densificar(bar_l, T)}
    cam = z["camara_lobby"]
    cx_, cz_ = cam["pos"]
    mx_, mz_ = cam["mira"]
    out["camara_lobby"] = {"pos": [round(cx_, 2), round(y(cx_, cz_) + float(cam["altura"]), 3), round(cz_, 2)],
                           "mira": [round(mx_, 2), round(y(mx_, mz_) + float(cam.get("mira_altura", 0.0)), 3), round(mz_, 2)],
                           "fov": float(cam.get("fov", 60.0))}
    out["tam_m"] = [est["info"]["largo_m"], est["info"]["ancho_m"]]
    out["estimacion"] = {
        "metodo": "rejilla 0,5 m + Dijkstra a 5 m/s desde cada spawn hasta el centro del site (scripts/zonas_nav.py)",
        "sites": {k: {"atacantes_s": [round(t, 1) for t in est["tiempos"][k]["atacantes"]],
                      "defensores_s": [round(t, 1) for t in est["tiempos"][k]["defensores"]],
                      "ventaja_defensores_s": round(float(np.mean(est["tiempos"][k]["atacantes"]) - np.mean(est["tiempos"][k]["defensores"])), 1),
                      "rutas_atacantes_s": est["rutas"][k], "tramo_abierto_max_m": est["abierto_max_m"][k]}
                  for k in z["sites"]}}
    return out


# ------------------------------------------------------------------ preview
def preview(z, ctx, est, ruta, margen=22.0, rej=None):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import PatchCollection
    from matplotlib.patches import Circle, FancyArrow, PathPatch, Polygon as MPoly
    from matplotlib.path import Path as MPath

    zl = dz.zonas_local([z])[0]
    lim = zl["limite"]
    x0, y0, x1, y1 = lim.buffer(margen).bounds
    vent = Polygon([(x0, y0), (x1, y0), (x1, y1), (x0, y1)])
    ancho = 15.5
    fig, ax = plt.subplots(figsize=(ancho, ancho * (y1 - y0) / (x1 - x0) + 0.4), dpi=80)
    ax.set_facecolor("#e9e1cf")

    def parche(g, **kw):
        ps = []
        for p in gb.validos(g):
            vs, cs = [], []
            for an in [p.exterior, *p.interiors]:
                c = np.asarray(an.coords)
                vs.extend(c)
                cs.extend([MPath.MOVETO] + [MPath.LINETO] * (len(c) - 2) + [MPath.CLOSEPOLY])
            ps.append(PathPatch(MPath(vs, cs), **kw))
        return ps

    col = {"verde": "#a8d08d", "agua": "#7fb2e0", "pista": "#d98a73", "aparcamiento": "#bdbdbd"}
    for c, g in ctx.geo["zonas"].items():
        for p in parche(g.intersection(vent), fc=col[c], ec="none", zorder=1):
            ax.add_patch(p)
    gx = np.arange(x0, x1 + 1, 1.0)
    gy = np.arange(y0, y1 + 1, 1.0)
    GX, GY = np.meshgrid(gx, gy)
    co = ctx.T.h(GX, GY) + ctx.T.cota_ref
    lv = np.arange(math.floor(co.min()), math.ceil(co.max()) + 0.5, 0.5)
    cs = ax.contour(GX, GY, co, levels=lv, colors="#7a5c2e", linewidths=0.5, zorder=1.5)
    ax.clabel(cs, fmt="%.1f", fontsize=6)
    for hw, g in ctx.geo["caminos"].items():
        for p in parche(g.intersection(vent), fc="#555555" if hw in gb.ASFALTO else "#9a9a9a", ec="none", zorder=2, alpha=0.8):
            ax.add_patch(p)
    for e in ctx.geo["edificios"]:
        if e["poly"].intersects(vent):
            kw = dict(fc="#c8c8cd", ec="black", lw=1, zorder=3)
            if e["forma"] == "techo":
                kw.update(fc="#555860", alpha=0.4, hatch="//")
            for p in parche(e["poly"], **kw):
                ax.add_patch(p)
            for px, py in e["pilares"]:
                ax.plot(px, py, "s", color="k", ms=2, zorder=4)
            m = gb.RX_NUM_EDIF.match(e["nombre"] or "")
            if m and vent.contains(e["poly"].representative_point()):
                c = e["poly"].representative_point()
                ax.text(c.x, c.y, m.group(1), fontsize=9, ha="center", va="center", zorder=6, color="white",
                        fontweight="bold", bbox=dict(boxstyle="round,pad=0.1", fc="k", ec="none", alpha=0.6))
    if rej is not None:     # celdas NO transitables dentro del limite (rojo tenue): sirve para depurar rutas
        masc = np.ma.masked_where(rej.libre, np.ones(rej.libre.shape))
        ax.imshow(masc, extent=(rej.x0, rej.x0 + rej.nx * rej.paso, rej.y0, rej.y0 + rej.ny * rej.paso), origin="lower",
                  cmap="Reds", alpha=0.28, vmin=0, vmax=1.5, zorder=3.2, interpolation="nearest")
    arb = [t for t in ctx.arboles if vent.contains(Point(t["x"], t["y"]))]
    ax.add_collection(PatchCollection([Circle((t["x"], t["y"]), t["r_copa"]) for t in arb], fc=(0.1, 0.5, 0.15, 0.22),
                                      ec=(0.05, 0.3, 0.08, 0.45), lw=0.4, zorder=3.5))
    ax.add_collection(PatchCollection([Circle((t["x"], t["y"]), max(t["r_tronco"], 0.25)) for t in arb], fc="#5a3a1a", ec="none", zorder=4))
    cc = [c for c in ctx.coches if vent.contains(Point(c["pos"][0], -c["pos"][2]))]
    ax.add_collection(PatchCollection([MPoly(np.asarray(coc.rect_coche(c).exterior.coords)[:-1]) for c in cc], fc="#c33", ec="k", lw=0.4, zorder=4.5))
    COL_PROP = {"banco": "#8b5a2b", "murete": "#777777", "jardinera": "#2e8b57", "contenedor": "#2f4f4f", "aparcabicis": "#222222",
                "marquesina": "#6a0dad", "expendedora": "#d2142a", "pila_sillas": "#1e90ff", "mesa": "#cd853f", "aula": "#ff1493"}
    for p, g in zip(ctx.props["props"], ctx.huellas_props):
        if vent.intersects(g):
            c = COL_PROP.get(p["tipo"], "#1b9e77" if p["tipo"].startswith("reciclaje") else "#000")
            ax.add_patch(MPoly(np.asarray(g.exterior.coords)[:-1], fc=c, ec="k", lw=0.5, zorder=5))
    if ctx.entorno.barreras is not None:
        for g in (ctx.entorno.barreras.geoms if hasattr(ctx.entorno.barreras, "geoms") else [ctx.entorno.barreras]):
            xs, ys = g.xy
            ax.plot(xs, ys, color="#900", lw=1.2, zorder=5)
    # rutas
    est_cam = est["caminos"]
    for k in z["sites"]:
        for eq in EQUIPOS:
            for pts in est_cam.get(f"{k}_{eq}", []):
                if pts:
                    a = np.array(pts)
                    ax.plot(a[:, 0], a[:, 1], color=COL_EQUIPO[eq], lw=1.6, ls="--", alpha=0.9, zorder=7)
        for i, pts in enumerate(est_cam.get(k, [])):
            if pts and i:
                a = np.array(pts)
                ax.plot(a[:, 0], a[:, 1], color=COL_EQUIPO["atacantes"], lw=0.9, ls=":", alpha=0.8, zorder=7)
    for (xs_, ys_, (mx_, my_)) in est["tramos_abiertos"]:
        ax.plot(mx_, my_, marker="x", color="m", ms=9, mew=2, zorder=9)
    # limite, barreras, sites, spawns
    xs, ys = lim.exterior.xy
    ax.plot(xs, ys, color="#d00", lw=3, zorder=8)
    for i, v in enumerate(lim.exterior.coords[:-1]):
        ax.text(v[0], v[1], str(i), fontsize=7, color="#d00", zorder=9, ha="center", va="bottom")
    for eq, b in zip(EQUIPOS, zl["barreras"]):
        xs, ys = b.exterior.xy
        ax.add_patch(MPoly(np.column_stack([xs, ys]), fc=COL_EQUIPO[eq], alpha=0.18, ec=COL_EQUIPO[eq], lw=2.2, zorder=6))
    for k, s in zl["sites"].items():
        ax.add_patch(MPoly(np.asarray(s.exterior.coords)[:-1], fc="#ffd43b", alpha=0.28, ec="#b8860b", lw=2, zorder=6))
        cxy = centro_site(z, k)
        ax.text(cxy[0], cxy[1], k, fontsize=20, fontweight="bold", ha="center", va="center", zorder=10,
                color="#7a5900", bbox=dict(boxstyle="circle,pad=0.15", fc="#ffd43b", ec="#7a5900", alpha=0.9))
    for eq in EQUIPOS:
        for i, p in enumerate(z["spawn_" + eq]["posiciones"]):
            lx, ly = dz.a_local(p[0], p[1])
            t = math.radians(p[2])
            fx, fy = -math.sin(t), math.cos(t)
            ax.add_patch(Circle((lx, ly), 0.5, fc=COL_EQUIPO[eq], ec="k", lw=0.8, zorder=10))
            ax.add_patch(FancyArrow(lx, ly, fx * 2.4, fy * 2.4, width=0.35, head_width=1.1, head_length=1.0,
                                    fc=COL_EQUIPO[eq], ec="k", lw=0.5, zorder=10))
    cam = z["camara_lobby"]
    ax.plot(cam["pos"][0], -cam["pos"][1], marker="^", color="k", ms=11, zorder=10)
    ax.plot([cam["pos"][0], cam["mira"][0]], [-cam["pos"][1], -cam["mira"][1]], color="k", lw=0.8, ls="-.", zorder=10)
    ax.set_xlim(x0, x1)
    ax.set_ylim(y0, y1)
    ax.set_aspect("equal")
    xt = np.arange(math.ceil(x0 / 10) * 10, x1, 10)
    yt = np.arange(math.ceil(y0 / 10) * 10, y1, 10)
    ax.set_xticks(xt)
    ax.set_yticks(yt)
    ax.set_yticklabels([f"{-v:.0f}" for v in yt])
    ax.tick_params(labelsize=7, labeltop=True, labelright=True)
    ax.grid(alpha=0.35, lw=0.5)
    ax.set_xlabel("x (este), juego")
    ax.set_ylabel("z (= -norte), juego; el norte esta ARRIBA")
    tt = []
    for k, ma, md, v, a0, a1, d0, d1 in resumen_tiempos(z, est):
        tt.append(f"{k}: atac {ma:.1f}s [{a0:.0f}-{a1:.0f}]  def {md:.1f}s [{d0:.0f}-{d1:.0f}]  ventaja {v:+.1f}s  rutas {len(est['rutas'][k])}")
    inf = est["info"]
    ax.set_title(f"{z['nombre']} ({z['id']}) - {inf['largo_m']:.0f} x {inf['ancho_m']:.0f} m, {inf['area_m2']} m2 | " + " | ".join(tt)
                 + "\nrojo = limite; amarillo = sites; naranja = atacantes, azul = defensores; x magenta = tramo abierto > 25 m",
                 fontsize=8)
    fig.tight_layout()
    Path(ruta).parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(ruta)
    plt.close(fig)
    print(f"Preview: {ruta}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    cx.argumentos(ap)
    ap.add_argument("--salida", default=SALIDA_JUEGO)
    ap.add_argument("--preview-dir", default=DIR_PREVIEW)
    ap.add_argument("--solo", default="", help="solo esta zona (id)")
    ap.add_argument("--sin-preview", action="store_true")
    ap.add_argument("--depurar", action="store_true", help="la preview marca en rojo las celdas no transitables (nav)")
    ap.add_argument("--sin-exportar", action="store_true")
    a = ap.parse_args()

    zonas = dz.leer_zonas(a.zonas)
    if not zonas:
        raise SystemExit(f"No hay zonas en {a.zonas}")
    if a.solo:
        zonas = [z for z in zonas if z["id"] == a.solo]
    ctx = Contexto(a)
    print(f"Props: {len(ctx.arboles)} arboles, {len(ctx.coches)} coches, {len(ctx.props['props'])} coberturas")
    salida, malas = [], 0
    e_p, a_p = validar_props(ctx)
    for e in e_p:
        print("ERROR:", e)
    for w in a_p:
        print("AVISO:", w)
    malas += bool(e_p)
    for z in zonas:
        print(f"\n=== {z['id']}: {z['nombre']} ===")
        err, av, info = validar(z, ctx)
        zl = dz.zonas_local([z])[0]
        rej = nav.Rejilla(ctx.T, zl["limite"], ctx.obst)
        est = {"info": info}
        try:
            est.update(estimar(z, ctx, rej))
        except ValueError as e:
            err.append(f"navegacion: {e}")
            est.update({"tiempos": {k: {eq: [math.inf] * 5 for eq in EQUIPOS} for k in z["sites"]}, "rutas": {k: [] for k in z["sites"]},
                        "abierto_max_m": {k: 0 for k in z["sites"]}, "caminos": {}, "tramos_abiertos": []})
        print(f"tamano {info['largo_m']} x {info['ancho_m']} m, area {info['area_m2']} m2, vertices {len(z['limite'])}, "
              f"limite en edificios {info['limite_en_edificios_m']} m")
        for k, ma, md, v, a0, a1, d0, d1 in resumen_tiempos(z, est):
            print(f"site {k}: atacantes {ma:.1f} s [{a0:.1f}-{a1:.1f}], defensores {md:.1f} s [{d0:.1f}-{d1:.1f}], ventaja {v:+.1f} s, "
                  f"rutas {est['rutas'][k]}, tramo abierto max {est['abierto_max_m'][k]} m")
            if not (VENTAJA_TOL[0] <= v <= VENTAJA_TOL[1]):
                av.append(f"site {k}: ventaja de los defensores {v:+.1f} s (objetivo {VENTAJA_OBJ[0]:g}-{VENTAJA_OBJ[1]:g} s)")
            if len(est["rutas"][k]) < RUTAS_MIN:
                av.append(f"site {k}: solo {len(est['rutas'][k])} rutas distintas (minimo {RUTAS_MIN})")
            if est["abierto_max_m"][k] > nav.TRAMO_ABIERTO_MAX_M:
                av.append(f"site {k}: tramo abierto de {est['abierto_max_m'][k]} m sin cobertura (max ~{nav.TRAMO_ABIERTO_MAX_M:g})")
            if not all(math.isfinite(t) for eq in EQUIPOS for t in est["tiempos"][k][eq]):
                err.append(f"site {k}: algun spawn no llega al site")
        for e in err:
            print("ERROR:", e)
        for w in av:
            print("AVISO:", w)
        malas += bool(err)
        if not a.sin_preview:
            preview(z, ctx, est, Path(a.preview_dir) / f"{z['id']}.png", rej=rej if a.depurar else None)
        salida.append(exportar_zona(z, ctx, est))
    if not a.sin_exportar and not a.solo:
        meta = ctx.mapa
        datos = {"ejes": "x=este, y=arriba, z=-norte (metros), igual que el glb; yaw_deg = rotacion Y de Godot (0 = mirando a -Z)",
                 "origen": {"E_utm25830": meta.E0, "N_utm25830": meta.N0}, "velocidad_ms": nav.VEL_MS,
                 "huella_props": ctx.props["huella"], "zonas": salida}
        ruta = Path(a.salida)
        ruta.parent.mkdir(parents=True, exist_ok=True)
        ruta.write_text(json.dumps(datos, indent=1, ensure_ascii=False), encoding="utf-8")
        print(f"\nEscrito {ruta}")
    sys.exit(1 if malas else 0)


if __name__ == "__main__":
    main()
