"""Genera el blockout 3D del campus de la UPO (glTF/GLB para Godot 4).

Entrada: data/raw/osm_upo.json (Overpass `out body; >; out skel qt;`: los ways
traen ids de nodo; la geometria se reconstruye con un dict de nodos).
Proyeccion: EPSG:25830 (UTM 30N) con origen en el centroide del contorno del
campus. Ejes glTF (Y arriba): x = este, y = altura, z = -norte.

Salidas: export/upo_blockout.glb, export/upo_blockout_meta.json,
export/preview.png y data/alturas.csv (editable; solo se anaden filas nuevas;
columna `fuente`: defecto|osm|lidar|manual).
Los nodos acabados en `-col` generan colision automatica al importar en Godot.

Uso: uv run python scripts/generar_blockout.py [--entrada data/raw/osm_upo.json]
     [--alturas data/alturas.csv] [--salida export/upo_blockout.glb] [--sin-preview]
"""
import argparse
import csv
import json
import re
import sys
import unicodedata
from collections import Counter
from pathlib import Path

import numpy as np
import trimesh
from pyproj import Transformer
from shapely.geometry import LineString, MultiPolygon, Polygon, box
from shapely.ops import linemerge, polygonize, unary_union
from shapely.validation import make_valid

CAMPUS_ID = 39935092
PLANTA_M = 3.5
PLANTAS_DEFECTO = 3
ALTURA_DEFECTO = PLANTAS_DEFECTO * PLANTA_M
MARGEN_SUELO = 50.0
MARGEN_CAMINOS = 30.0
MARGEN_LIMITE = 20.0
CAMPOS_CSV = ["osm_id", "nombre", "building", "plantas", "altura_m", "base_m", "notas", "fuente"]
# fuente: defecto | osm | lidar | manual (ver scripts/alturas_lidar.py; solo se pisan defecto y lidar)

ANCHO_CAMINO = {
    "tertiary": 7, "residential": 6, "trunk_link": 6, "service": 4,
    "pedestrian": 4, "track": 3, "footway": 2.5, "steps": 2.5,
    "cycleway": 2, "path": 1.5,
}
ASFALTO = {"tertiary", "residential", "trunk_link", "service", "track"}

ZONAS = {  # categoria -> (y, {clave OSM: valores})
    "verde": (0.013, {"leisure": {"garden", "sports_centre"},
                      "landuse": {"grass", "allotments", "farmland"},
                      "natural": {"wood", "wetland"}}),
    "agua": (0.014, {"natural": {"water"}, "leisure": {"swimming_pool"}}),
    "pista": (0.015, {"leisure": {"pitch", "track"}}),
    "aparcamiento": (0.016, {"amenity": {"parking"}}),
}

# RGBA 0-255
COLORES = {
    "edificio": (200, 200, 205, 255), "cubierta": (85, 88, 95, 255),
    "torre": (150, 120, 105, 255), "suelo": (190, 170, 135, 255),
    "camino_asfalto": (60, 62, 66, 255), "camino_peatonal": (170, 170, 172, 255),
    "verde": (110, 160, 90, 255), "pista": (176, 90, 70, 255),
    "agua": (70, 130, 190, 255), "aparcamiento": (130, 132, 136, 255),
    "muros": (160, 158, 150, 255), "vallas": (110, 90, 70, 255),
    "limite": (255, 60, 60, int(0.15 * 255)),
}


# ---------------------------------------------------------------- utilidades
def slug(texto):
    t = unicodedata.normalize("NFKD", texto or "").encode("ascii", "ignore").decode()
    t = re.sub(r"[^a-zA-Z0-9]+", "-", t).strip("-").lower()
    return t[:40] or "sin-nombre"


def num(v):
    """Convierte '12', '12,5' o '12 m' a float; None si no se puede."""
    if v is None:
        return None
    m = re.search(r"-?\d+(?:[.,]\d+)?", str(v))
    return float(m.group().replace(",", ".")) if m else None


def validos(geom):
    """Devuelve la lista de Polygon validos de una geometria cualquiera."""
    if geom is None or geom.is_empty:
        return []
    if not geom.is_valid:
        geom = make_valid(geom)
        if not geom.is_valid:
            geom = geom.buffer(0)
    if geom.geom_type == "Polygon":
        return [geom] if geom.area > 0.5 else []
    if hasattr(geom, "geoms"):
        return [p for g in geom.geoms for p in validos(g)]
    return []


def a_gltf(mesh):
    """(x, norte, arriba) -> glTF (x, arriba, -norte). Rotacion, no cambia el bobinado."""
    m = np.array([[1, 0, 0, 0], [0, 0, 1, 0], [0, -1, 0, 0], [0, 0, 0, 1]], float)
    mesh.apply_transform(m)
    return mesh


def material(nombre, clave):
    r, g, b, a = COLORES[clave]
    return trimesh.visual.material.PBRMaterial(
        name=nombre, baseColorFactor=[r, g, b, a], metallicFactor=0.0, roughnessFactor=0.9,
        alphaMode="BLEND" if a < 255 else "OPAQUE", doubleSided=a < 255)


def con_material(mesh, clave):
    mesh.visual = trimesh.visual.TextureVisuals(material=material(clave, clave))
    return mesh


def plano(geom, y):
    """Triangula poligonos (earcut) a altura y; normales hacia +arriba. Mesh local (x, norte, z)."""
    vs, fs = [], []
    off = 0
    for p in validos(geom):
        v, f = trimesh.creation.triangulate_polygon(p, engine="earcut")
        v = np.column_stack([v, np.full(len(v), y)])
        a, b, c = v[f[:, 0]], v[f[:, 1]], v[f[:, 2]]
        neg = np.cross(b - a, c - a)[:, 2] < 0
        f = f.copy()
        f[neg] = f[neg][:, ::-1]
        vs.append(v)
        fs.append(f + off)
        off += len(v)
    if not vs:
        return None
    return trimesh.Trimesh(np.vstack(vs), np.vstack(fs), process=False)


def extruir(geom, h, base=0.0):
    ms = []
    for p in validos(geom):
        m = trimesh.creation.extrude_polygon(p, h, engine="earcut")
        m.apply_translation([0, 0, base])
        ms.append(m)
    return trimesh.util.concatenate(ms) if ms else None


# ---------------------------------------------------------------- datos OSM
class Mapa:
    def __init__(self, ruta):
        data = json.loads(Path(ruta).read_text(encoding="utf-8"))
        els = data["elements"]
        self.nodos = {e["id"]: e for e in els if e["type"] == "node"}
        self.ways = {e["id"]: e for e in els if e["type"] == "way"}
        self.rels = [e for e in els if e["type"] == "relation"]
        lat0, lon0 = self._centro_campus()
        self.tr = Transformer.from_crs("EPSG:4326", "EPSG:25830", always_xy=True)
        self.E0, self.N0 = self.tr.transform(lon0, lat0)
        self.origen = (lat0, lon0)

    def _ll(self, way):
        return [(self.nodos[n]["lon"], self.nodos[n]["lat"]) for n in way["nodes"] if n in self.nodos]

    def _centro_campus(self):
        w = self.ways.get(CAMPUS_ID)
        if w is None:
            raise SystemExit(f"No esta el contorno del campus (way {CAMPUS_ID})")
        tr = Transformer.from_crs("EPSG:4326", "EPSG:25830", always_xy=True)
        pts = [tr.transform(lo, la) for lo, la in self._ll(w)]
        c = Polygon(pts).centroid
        lon, lat = Transformer.from_crs("EPSG:25830", "EPSG:4326", always_xy=True).transform(c.x, c.y)
        return lat, lon

    def coords(self, way):
        """Coordenadas locales en metros (x=este, y=norte) desde el origen."""
        ll = self._ll(way)
        if not ll:
            return []
        xs, ys = self.tr.transform([p[0] for p in ll], [p[1] for p in ll])
        return list(zip(np.asarray(xs) - self.E0, np.asarray(ys) - self.N0))

    @staticmethod
    def cerrado(w):
        return len(w["nodes"]) >= 4 and w["nodes"][0] == w["nodes"][-1]

    def poligono(self, w):
        c = self.coords(w)
        return Polygon(c) if len(c) >= 4 else None

    def linea(self, w):
        c = self.coords(w)
        return LineString(c) if len(c) >= 2 else None

    def relacion(self, rel):
        """Poligono del multipolygon: outers unidos (linemerge+polygonize) menos inners."""
        def lineas(rol):
            ls = []
            for m in rel["members"]:
                w = self.ways.get(m["ref"]) if m["type"] == "way" and m["role"] == rol else None
                if w:
                    l = self.linea(w)
                    if l:
                        ls.append(l)
            return ls
        out = list(polygonize(linemerge(lineas("outer")))) if lineas("outer") else []
        inn = list(polygonize(linemerge(lineas("inner")))) if lineas("inner") else []
        if not out:
            return None
        g = unary_union(out)
        return g.difference(unary_union(inn)) if inn else g


# ---------------------------------------------------------------- alturas.csv
def default_edificio(tags):
    """(plantas, altura_m, base_m, notas) por defecto segun etiquetas OSM."""
    b = tags.get("building")
    h = num(tags.get("height"))
    lv = num(tags.get("building:levels"))
    if b == "roof":
        return "", 0.4, 3.0, "cubierta elevada (losa)"
    if h is not None:
        return "", h, 0.0, "height de OSM"
    if lv is not None:
        return int(lv), "", 0.0, "building:levels de OSM"
    if tags.get("man_made") == "tower":
        return "", 15.0, 0.0, "torre: valor por defecto"
    if b == "greenhouse":
        return "", 4.0, 0.0, "invernadero: valor por defecto"
    if b == "dormitory":
        return 4, "", 0.0, "residencia: 4 plantas por defecto"
    return PLANTAS_DEFECTO, "", 0.0, "por defecto 3 plantas"


def cargar_alturas(ruta, edificios):
    """Lee el CSV (si existe), anade filas nuevas y lo reescribe. Devuelve dict id->fila."""
    ruta = Path(ruta)
    filas = {}
    if ruta.exists():
        with open(ruta, newline="", encoding="utf-8-sig") as f:
            for r in csv.DictReader(f):
                if not (r.get("fuente") or "").strip():  # CSV antiguo sin columna fuente
                    r["fuente"] = "osm" if "de OSM" in (r.get("notas") or "") else "defecto"
                filas[str(r["osm_id"]).strip()] = r
    nuevas = 0
    for wid, tags in edificios:
        k = str(wid)
        if k in filas:
            continue
        pl, alt, base, nota = default_edificio(tags)
        filas[k] = {"osm_id": k, "nombre": tags.get("name", ""),
                    "building": tags.get("building", tags.get("man_made", "")),
                    "plantas": pl, "altura_m": alt, "base_m": base, "notas": nota,
                    "fuente": "osm" if "de OSM" in nota else "defecto"}
        nuevas += 1
    ruta.parent.mkdir(parents=True, exist_ok=True)
    with open(ruta, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=CAMPOS_CSV, extrasaction="ignore")
        w.writeheader()
        w.writerows(filas.values())
    print(f"{ruta}: {len(filas)} filas ({nuevas} nuevas)")
    return filas


def resolver(fila):
    """(altura_m, base_m) finales de una fila del CSV."""
    alt = num(fila.get("altura_m"))
    if alt is None:
        pl = num(fila.get("plantas"))
        alt = pl * PLANTA_M if pl is not None else ALTURA_DEFECTO
    base = num(fila.get("base_m")) or 0.0
    return max(alt, 0.05), base


# ---------------------------------------------------------------- construccion
def construir(mapa, filas):
    campus = mapa.poligono(mapa.ways[CAMPUS_ID])
    campus = validos(campus)[0]
    minx, miny, maxx, maxy = campus.bounds
    caja_suelo = box(minx - MARGEN_SUELO, miny - MARGEN_SUELO, maxx + MARGEN_SUELO, maxy + MARGEN_SUELO)
    zona_caminos = campus.buffer(MARGEN_CAMINOS)

    piezas = []  # (nombre_nodo, mesh_local, clave_material)
    stats = Counter()
    edif_info = []  # para preview

    # Suelo
    piezas.append(("suelo-col", plano(caja_suelo, 0.0), "suelo"))

    # Edificios
    for wid, w in sorted(mapa.ways.items()):
        t = w.get("tags", {})
        if not (("building" in t or t.get("man_made") == "tower") and mapa.cerrado(w)):
            continue
        fila = filas[str(wid)]
        alt, base = resolver(fila)
        polys = validos(mapa.poligono(w))
        m = extruir(unary_union(polys) if polys else None, alt, base)
        if m is None:
            stats["edificios_descartados"] += 1
            print(f"AVISO: edificio {wid} sin geometria valida", file=sys.stderr)
            continue
        nombre = fila.get("nombre") or t.get("name", "")
        if t.get("man_made") == "tower":
            clave = "torre"
        elif t.get("building") == "roof":
            clave = "cubierta"
        else:
            clave = "edificio"
        piezas.append((f"edif_{wid}_{slug(nombre)}-col", m, clave))
        stats["edificios"] += 1
        edif_info.append({"id": wid, "nombre": nombre, "poly": unary_union(polys),
                          "altura": alt + base, "clave": clave, "tags": t})

    # Caminos
    por_tipo = {}
    for w in mapa.ways.values():
        t = w.get("tags", {})
        hw = t.get("highway")
        if hw not in ANCHO_CAMINO or t.get("tunnel") == "yes":
            continue
        l = mapa.linea(w)
        if l is None:
            continue
        por_tipo.setdefault(hw, []).append(l.buffer(ANCHO_CAMINO[hw] / 2, cap_style="flat", join_style="round"))
    caminos_geom = {}
    for hw, bufs in por_tipo.items():
        g = unary_union(bufs).intersection(zona_caminos)
        caminos_geom[hw] = g
        m = plano(g, 0.03)
        if m is not None:
            clave = "camino_asfalto" if hw in ASFALTO else "camino_peatonal"
            piezas.append((f"caminos_{hw}", m, clave))
            stats["caminos_" + hw] = len(bufs)

    # Zonas
    zonas_geom = {}
    cats = {c: [] for c in ZONAS}
    elementos = [(w.get("tags", {}), mapa.poligono(w)) for w in mapa.ways.values()
                 if mapa.cerrado(w) and w.get("tags")]
    for r in mapa.rels:
        t = r.get("tags", {})
        if t.get("type") == "multipolygon":
            elementos.append((t, mapa.relacion(r)))
    for t, g in elementos:
        if g is None:
            continue
        for cat, (_, reglas) in ZONAS.items():
            if any(t.get(k) in v for k, v in reglas.items()):
                cats[cat].extend(validos(g))
                break
    for cat, (y, _) in ZONAS.items():
        if not cats[cat]:
            continue
        g = unary_union(cats[cat]).intersection(caja_suelo)
        zonas_geom[cat] = g
        m = plano(g, y)
        if m is not None:
            piezas.append((f"zona_{cat}", m, cat))
            stats["zonas_" + cat] = len(cats[cat])

    # Muros y vallas
    for nombre, valor, grosor, h, clave in (("muros-col", "retaining_wall", 0.15, 1.2, "muros"),
                                            ("vallas-col", "fence", 0.05, 1.8, "vallas")):
        bufs = []
        for w in mapa.ways.values():
            if w.get("tags", {}).get("barrier") == valor:
                l = mapa.linea(w)
                if l is not None:
                    bufs.append(l.buffer(grosor, cap_style="flat", join_style="mitre"))
        m = extruir(unary_union(bufs), h) if bufs else None
        if m is not None:
            piezas.append((nombre, m, clave))
            stats[nombre] = len(bufs)

    # Limite del mapa
    ext = campus.buffer(MARGEN_LIMITE)
    anillo = ext.exterior.buffer(0.25, join_style="mitre")
    piezas.append(("limite-col", extruir(anillo, 6.0), "limite"))

    return piezas, stats, {"campus": campus, "edificios": edif_info, "caminos": caminos_geom,
                           "zonas": zonas_geom, "suelo": caja_suelo}


# ---------------------------------------------------------------- preview
def preview(ruta, geo):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.cm import ScalarMappable
    from matplotlib.colors import Normalize
    from matplotlib.patches import PathPatch
    from matplotlib.path import Path as MPath

    def parche(g, **kw):
        ps = []
        for p in validos(g):
            vs, cs = [], []
            for anillo in [p.exterior, *p.interiors]:
                c = np.asarray(anillo.coords)
                vs.extend(c)
                cs.extend([MPath.MOVETO] + [MPath.LINETO] * (len(c) - 2) + [MPath.CLOSEPOLY])
            ps.append(PathPatch(MPath(vs, cs), **kw))
        return ps

    fig, ax = plt.subplots(figsize=(16, 13), dpi=100)
    suelo = geo["suelo"]
    ax.add_patch(plt.Rectangle((suelo.bounds[0], suelo.bounds[1]), suelo.bounds[2] - suelo.bounds[0],
                               suelo.bounds[3] - suelo.bounds[1], fc="#e9e1cf", ec="none"))
    col_z = {"verde": "#a8d08d", "agua": "#7fb2e0", "pista": "#d98a73", "aparcamiento": "#bdbdbd"}
    for cat, g in geo["zonas"].items():
        for p in parche(g, fc=col_z[cat], ec="none", zorder=1):
            ax.add_patch(p)
    for hw, g in geo["caminos"].items():
        c = "#555555" if hw in ASFALTO else "#9a9a9a"
        for p in parche(g, fc=c, ec="none", zorder=2):
            ax.add_patch(p)
    alts = [e["altura"] for e in geo["edificios"]]
    norm = Normalize(0, max(alts + [1]))
    cmap = plt.get_cmap("viridis")
    for e in geo["edificios"]:
        kw = dict(fc=cmap(norm(e["altura"])), ec="black", lw=0.4, zorder=3)
        if e["clave"] == "cubierta":
            kw.update(alpha=0.6, hatch="//")
        for p in parche(e["poly"], **kw):
            ax.add_patch(p)
        m = re.match(r"^Edificio\s+([^\s.]+)", e["nombre"] or "")
        if m:
            c = e["poly"].representative_point()
            ax.text(c.x, c.y, m.group(1), fontsize=7, ha="center", va="center", zorder=5,
                    color="white", fontweight="bold",
                    bbox=dict(boxstyle="round,pad=0.1", fc="black", ec="none", alpha=0.5))
    cx, cy = geo["campus"].exterior.xy
    ax.plot(cx, cy, color="red", lw=1.5, ls="--", zorder=4, label="contorno campus")
    ax.set_xlim(suelo.bounds[0], suelo.bounds[2])
    ax.set_ylim(suelo.bounds[1], suelo.bounds[3])
    ax.set_aspect("equal")
    ax.set_xlabel("Este (m) respecto al centroide del campus")
    ax.set_ylabel("Norte (m)")
    ax.set_title("UPO blockout - vista cenital (norte arriba); color = altura de cubierta (m)")
    fig.colorbar(ScalarMappable(norm=norm, cmap=cmap), ax=ax, shrink=0.7, label="altura (m)")
    ax.grid(alpha=0.25)
    fig.tight_layout()
    fig.savefig(ruta)
    plt.close(fig)
    print(f"Preview: {ruta}")


# ---------------------------------------------------------------- verificacion
def verificar(ruta):
    sc = trimesh.load(ruta, force="scene")
    nombres = list(sc.graph.nodes_geometry)
    tris = sum(len(sc.geometry[sc.graph[n][1]].faces) for n in nombres)
    b = sc.bounds
    print(f"[verificacion] nodos con geometria: {len(nombres)} | triangulos: {tris}")
    print(f"[verificacion] bounds (m) min={np.round(b[0], 1).tolist()} max={np.round(b[1], 1).tolist()} "
          f"-> {b[1][0] - b[0][0]:.0f} x {b[1][2] - b[0][2]:.0f} m (E-O x N-S), alto {b[1][1]:.1f} m")
    edif = [n for n in nombres if n.startswith("edif_")]
    malos = []
    for n in edif:
        g = sc.geometry[sc.graph[n][1]]
        if not g.is_watertight:
            malos.append(n)
    print(f"[verificacion] edificios: {len(edif)} | NO watertight: {len(malos)}")
    for n in malos:
        print("   no watertight:", n)
    mats = {sc.geometry[sc.graph[n][1]].visual.material.name for n in nombres}
    print(f"[verificacion] materiales distintos: {len(mats)} {sorted(mats)}")
    return {"nodos": len(nombres), "triangulos": tris, "bounds": b.tolist(),
            "edificios": len(edif), "no_watertight": malos}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--entrada", default="data/raw/osm_upo.json")
    ap.add_argument("--alturas", default="data/alturas.csv")
    ap.add_argument("--salida", default="export/upo_blockout.glb")
    ap.add_argument("--sin-preview", action="store_true")
    a = ap.parse_args()

    mapa = Mapa(a.entrada)
    edificios = [(wid, w["tags"]) for wid, w in sorted(mapa.ways.items())
                 if "tags" in w and mapa.cerrado(w)
                 and ("building" in w["tags"] or w["tags"].get("man_made") == "tower")]
    filas = cargar_alturas(a.alturas, edificios)
    piezas, stats, geo = construir(mapa, filas)

    escena = trimesh.Scene()
    for nombre, mesh, clave in piezas:
        if mesh is None:
            continue
        mesh = con_material(a_gltf(mesh), clave)
        escena.add_geometry(mesh, node_name=nombre, geom_name=nombre)

    salida = Path(a.salida)
    salida.parent.mkdir(parents=True, exist_ok=True)
    escena.export(salida)
    print(f"Exportado {salida} ({salida.stat().st_size / 1e6:.2f} MB)")

    campus = geo["campus"]
    minx, miny, maxx, maxy = campus.bounds
    meta = {
        "origen": {"lat": mapa.origen[0], "lon": mapa.origen[1], "E_utm25830": mapa.E0, "N_utm25830": mapa.N0},
        "ejes_gltf": "x=este, y=altura, z=-norte (metros)",
        "bbox_campus_m": {"x_min": minx, "x_max": maxx, "norte_min": miny, "norte_max": maxy},
        "bbox_suelo_m": dict(zip(["x_min", "norte_min", "x_max", "norte_max"], geo["suelo"].bounds)),
        "recuentos": dict(stats),
    }
    meta_ruta = salida.with_name(salida.stem + "_meta.json")
    meta_ruta.write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Meta: {meta_ruta}")
    print("Recuentos:", dict(stats))

    ver = verificar(salida)
    meta["verificacion"] = ver
    meta_ruta.write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")

    if not a.sin_preview:
        preview(salida.with_name("preview.png"), geo)


if __name__ == "__main__":
    main()
