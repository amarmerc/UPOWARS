"""Genera el blockout 3D del campus de la UPO (glTF/GLB para Godot 4).

Entrada: data/raw/osm_upo.json (Overpass `out body; >; out skel qt;`: los ways
traen ids de nodo; la geometria se reconstruye con un dict de nodos).
Proyeccion: EPSG:25830 (UTM 30N) con origen en el centroide del contorno del
campus. Ejes glTF (Y arriba): x = este, y = altura, z = -norte.

Salidas: export/upo_blockout.glb, export/upo_blockout_meta.json,
export/preview.png, export/zoom_22_24.png y data/alturas.csv (editable; solo se anaden
filas nuevas; columna `fuente`: defecto|osm|lidar|manual; columna `forma`: volumen|techo).
forma=tunel_z|tunel_x: losa + paredes de 0,3 m en los lados paralelos al eje; columna `pilares`: perimetro|todos|ninguno.
forma=techo: losa de 0,4 m (cara superior a la altura de cubierta) sobre pilares de 0,4x0,4 m.
data/pasos.csv: pasos peatonales (segmento + ancho + galibo) que parten los edificios volumen.
Los nodos acabados en `-col` generan colision automatica al importar en Godot.

Uso: uv run python scripts/generar_blockout.py [--entrada data/raw/osm_upo.json]
     [--alturas data/alturas.csv] [--pasos data/pasos.csv] [--salida export/upo_blockout.glb] [--sin-preview]
     [--no-copiar-godot]   (por defecto copia el .glb a game/assets/mapa/)
"""
import argparse
import csv
import json
import math
import shutil
import re
import sys
import unicodedata
from collections import Counter
from pathlib import Path

import numpy as np
import trimesh
from pyproj import Transformer
from shapely.affinity import rotate
from shapely.geometry import LineString, MultiPolygon, Point, Polygon, box
from shapely.ops import linemerge, polygonize, unary_union
from shapely.validation import make_valid

CAMPUS_ID = 39935092
DESTINO_GODOT = "game/assets/mapa/upo_blockout.glb"
PLANTA_M = 3.5
PLANTAS_DEFECTO = 3
ALTURA_DEFECTO = PLANTAS_DEFECTO * PLANTA_M
MARGEN_SUELO = 50.0
MARGEN_CAMINOS = 30.0
MARGEN_LIMITE = 20.0
CAMPOS_CSV = ["osm_id", "nombre", "building", "forma", "plantas", "altura_m", "base_m", "notas", "fuente", "pilares"]
FORMAS = ("volumen", "techo", "tunel_z", "tunel_x")
MODOS_PILARES = ("perimetro", "todos", "ninguno")   # columna opcional `pilares`; vacio = automatico
GROSOR_TECHO = 0.4
PILAR_LADO = 0.4
PILAR_SEP = 8.0
PILAR_INTERIOR_BUFFER = 7.5  # pilares interiores solo en los puntos de la rejilla dentro de huella.buffer(-7.5)
PILAR_TODOS_BUFFER = 3.0     # pilares=todos: rejilla dentro de huella.buffer(-3)
GROSOR_PARED_TUNEL = 0.3
FRAG_AREA_MIN = 0.25         # fragmentos de un edificio partido por pasos: < 25 % del mayor -> descartar
FRAG_ANCHO_MIN = 1.5         # ... y los de menos de 1,5 m de ancho (desaparecen con buffer(-0.75))
CAMPOS_PASOS = ["id", "descripcion", "x1", "z1", "x2", "z2", "ancho_m", "galibo_m", "notas"]
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
    "pilar": (120, 122, 128, 255), "muros": (160, 158, 150, 255), "vallas": (110, 90, 70, 255),
    "limite": (255, 60, 60, int(0.15 * 255)),
    "cristal_padel": (150, 205, 255, int(0.35 * 255)),
}


# ---------------------------------------------------------------- utilidades
def slug(texto):
    t = unicodedata.normalize("NFKD", texto or "").encode("ascii", "ignore").decode()
    t = re.sub(r"[^a-zA-Z0-9]+", "-", t).strip("-").lower()
    return t[:40] or "sin-nombre"


RX_NUM_EDIF = re.compile(r"^Edi\w*\s+([^\s.]+)", re.I)  # tolera typos: Edifiicio, Edificico...


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


def modo_pilares(fila):
    m = (fila.get("pilares") or "").strip().lower()
    return m if m in MODOS_PILARES else ""


def forma_defecto(building):
    return "techo" if building == "roof" else "volumen"


def forma_de(fila):
    f = (fila.get("forma") or "").strip().lower()
    return f if f in FORMAS else forma_defecto((fila.get("building") or "").strip())


def cargar_alturas(ruta, edificios):
    """Lee el CSV (si existe), anade filas nuevas y lo reescribe. Devuelve dict id->fila."""
    ruta = Path(ruta)
    filas = {}
    if ruta.exists():
        with open(ruta, newline="", encoding="utf-8-sig") as f:
            for r in csv.DictReader(f):
                if not (r.get("fuente") or "").strip():  # CSV antiguo sin columna fuente
                    r["fuente"] = "osm" if "de OSM" in (r.get("notas") or "") else "defecto"
                r["forma"] = forma_de(r)
                filas[str(r["osm_id"]).strip()] = r
    nuevas = 0
    for wid, tags in edificios:
        k = str(wid)
        if k in filas:
            continue
        pl, alt, base, nota = default_edificio(tags)
        filas[k] = {"osm_id": k, "nombre": tags.get("name", ""),
                    "building": tags.get("building", tags.get("man_made", "")),
                    "forma": forma_defecto(tags.get("building")),
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


# ---------------------------------------------------------------- pistas de padel
GROSOR_CERRAMIENTO = 0.15
ABERTURA_PADEL = 1.2


def cargar_pistas(ruta):
    """Lee data/pistas.csv (osm_id, nombre, altura_cerramiento_m): pistas con cerramiento perimetral."""
    ruta = Path(ruta)
    if not ruta.exists():
        return []
    pistas = []
    with open(ruta, newline="", encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            try:
                wid = int(r["osm_id"])
            except (KeyError, ValueError, TypeError):
                print(f"AVISO: fila de pistas sin osm_id valido: {r}", file=sys.stderr)
                continue
            pistas.append({"id": wid, "nombre": (r.get("nombre") or "").strip(),
                           "altura": num(r.get("altura_cerramiento_m")) or 3.0})
    return pistas


def cerramiento_pista(poly, grosor=GROSOR_CERRAMIENTO, abertura=ABERTURA_PADEL):
    """Contorno de la pista (poligono 2D) con una abertura de `abertura` m en el centro de cada lado largo."""
    cs = list(poly.minimum_rotated_rectangle.exterior.coords)[:4]
    lados = [(np.array(cs[i]), np.array(cs[(i + 1) % 4])) for i in range(4)]
    largo = max(np.linalg.norm(b - a) for a, b in lados)
    muro = poly.exterior.buffer(grosor / 2, join_style="mitre")
    huecos = []
    for a, b in lados:
        if np.linalg.norm(b - a) < largo - 0.5:
            continue
        u = (b - a) / np.linalg.norm(b - a)
        mid = (a + b) / 2
        huecos.append(LineString([tuple(mid - u * abertura / 2), tuple(mid + u * abertura / 2)])
                      .buffer(grosor, cap_style="flat"))
    return muro.difference(unary_union(huecos))


DESCARTADOS = []   # fragmentos descartados al partir edificios (informe)


# ---------------------------------------------------------------- pasos y pilares
def cargar_pasos(ruta):
    """Lee data/pasos.csv. Coordenadas del juego (x = este, z = -norte); el poligono se
    devuelve en el plano local (este, norte) = buffer(ancho/2) del segmento (extremos planos)."""
    ruta = Path(ruta)
    if not ruta.exists():
        return []
    pasos = []
    with open(ruta, newline="", encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            x1, z1, x2, z2, ancho = (num(r.get(k)) for k in ("x1", "z1", "x2", "z2", "ancho_m"))
            if None in (x1, z1, x2, z2, ancho):
                print(f"AVISO: paso {r.get('id')} con coordenadas incompletas", file=sys.stderr)
                continue
            seg = LineString([(x1, -z1), (x2, -z2)])
            pasos.append({"id": r["id"], "descripcion": r.get("descripcion", ""), "seg": seg,
                          "ancho": ancho, "galibo": num(r.get("galibo_m")),
                          "poly": seg.buffer(ancho / 2, cap_style="flat")})
    return pasos


def filtrar_fragmentos(geom):
    """Separa los poligonos de geom en (conservados, descartados): se descarta lo que tenga area
    < 25 % de la del fragmento mayor o menos de 1,5 m de ancho (buffer(-0.75) vacio)."""
    polys = validos(geom)
    if len(polys) <= 1:
        return polys, []
    mayor = max(p.area for p in polys)
    ok, malos = [], []
    for p in polys:
        (malos if p.area < FRAG_AREA_MIN * mayor or p.buffer(-FRAG_ANCHO_MIN / 2).is_empty else ok).append(p)
    return ok, malos


def partir_por_pasos(huella, base, top, pasos, etiqueta=""):
    """Divide la huella de un edificio volumen con los pasos. Devuelve (mesh|None, n_pasos_aplicados).
    (huella - paso) se extruye entera; (huella ∩ paso) solo de galibo a top (soportal); sin
    galibo (o galibo >= top) el paso queda abierto al cielo. Si queda partida en varios
    poligonos se descartan los fragmentos sueltos (ver filtrar_fragmentos) y se informa."""
    resto, ms, n = huella, [], 0

    def limpiar(g, que):
        ok, malos = filtrar_fragmentos(g)
        for q in malos:
            c = q.representative_point()
            print(f"AVISO: edificio {etiqueta}: fragmento descartado ({que}) area={q.area:.1f} m2 "
                  f"en ({c.x:.1f}, {c.y:.1f})", file=sys.stderr)
            DESCARTADOS.append({"edificio": etiqueta, "parte": que, "area_m2": round(q.area, 1),
                                "centro": [round(c.x, 1), round(c.y, 1)]})
        return unary_union(ok) if ok else None

    for p in pasos:
        inter = resto.intersection(p["poly"])
        if not validos(inter):
            continue
        n += 1
        resto = resto.difference(p["poly"])
        g = p["galibo"]
        if g is not None and g > 0 and g < top - 0.05:
            z0 = max(g, base)
            inter = limpiar(inter, f"soportal {p['id']}")
            m = extruir(inter, top - z0, z0) if inter is not None else None
            if m is not None:
                ms.append(m)
    if n:
        resto = limpiar(resto, "resto")
    m = extruir(resto, top - base, base) if resto is not None else None
    if m is not None:
        ms.append(m)
    return (trimesh.util.concatenate(ms) if ms else None), n


# ---------------------------------------------------------------- tuneles
def malla_tunel(huella, forma, base, z_losa, top):
    """Edificio-tunel: losa (z_losa..top) sobre toda la huella + paredes de 0,3 m hacia dentro, del
    suelo a la losa, solo en los lados paralelos al eje (tunel_z: |dnorte| > |deste|, o sea caras
    este/oeste; tunel_x: al reves). Devuelve (mesh, poligono_paredes)."""
    ms = [extruir(huella, top - z_losa, z_losa)]
    paredes = []
    for p in validos(huella):
        c = list(p.exterior.coords)
        for a, b in zip(c[:-1], c[1:]):
            dx, dy = abs(b[0] - a[0]), abs(b[1] - a[1])
            if (dy > dx) if forma == "tunel_z" else (dx > dy):
                paredes.append(LineString([a, b]).buffer(GROSOR_PARED_TUNEL, cap_style="flat").intersection(p))
    muros = unary_union(paredes) if paredes else None
    if muros is not None and z_losa - base > 0.05:
        m = extruir(muros, z_losa - base, base)
        if m is not None:
            ms.append(m)
    return trimesh.util.concatenate([m for m in ms if m is not None]), muros


def _perimetro(poly, sep):
    pts = []
    for q in validos(poly.buffer(-PILAR_LADO / 2 - 0.05)) or [poly]:
        c = list(q.simplify(0.5).exterior.coords)[:-1]
        for i in range(len(c)):
            a, b = np.array(c[i]), np.array(c[(i + 1) % len(c)])
            n = max(1, math.ceil(np.linalg.norm(b - a) / sep))
            pts.extend(tuple(a + (b - a) * k / n) for k in range(n))
    return pts


def _rejilla_interior(poly, sep, margen=PILAR_INTERIOR_BUFFER):
    """Rejilla (alineada con el rectangulo minimo) restringida a los puntos que caen dentro de
    poly.buffer(-margen): solo hay pilares interiores donde el poligono es realmente ancho."""
    interior = poly.buffer(-margen)
    if interior.is_empty:
        return []
    mrr = poly.minimum_rotated_rectangle
    cs = list(mrr.exterior.coords)
    ang = math.degrees(math.atan2(cs[1][1] - cs[0][1], cs[1][0] - cs[0][0]))
    c = mrr.centroid
    x0, y0, x1, y1 = rotate(poly, -ang, origin=c).bounds
    nx, ny = int((x1 - x0) // sep) + 1, int((y1 - y0) // sep) + 1
    pts = []
    for i in range(nx):
        for j in range(ny):
            p = Point((x0 + x1) / 2 + (i - (nx - 1) / 2) * sep, (y0 + y1) / 2 + (j - (ny - 1) / 2) * sep)
            q = rotate(p, ang, origin=c)
            if interior.contains(q):
                pts.append((q.x, q.y))
    return pts


def pilares_techo(huella, h, volumenes, modo=""):
    """Centros (x, y) de pilares: perimetro cada ~8 m + esquinas (+ rejilla interior si la
    huella es grande). Se omiten los que caen dentro de un edificio volumen."""
    pts = []
    for p in validos(huella):
        pts.extend(_perimetro(p, PILAR_SEP))
        if modo == "todos":
            pts.extend(_rejilla_interior(p, PILAR_SEP, PILAR_TODOS_BUFFER))
        elif modo != "perimetro":
            pts.extend(_rejilla_interior(p, PILAR_SEP))
    out = []
    for x, y in pts:
        if volumenes is not None and volumenes.contains(Point(x, y)):
            continue
        if any(math.hypot(x - a, y - b) < 1.0 for a, b in out):
            continue
        out.append((x, y))
    return out


def malla_pilares(centros, h):
    ms = []
    for x, y in centros:
        m = trimesh.creation.box(extents=[PILAR_LADO, PILAR_LADO, h])
        m.apply_translation([x, y, h / 2])
        ms.append(m)
    return trimesh.util.concatenate(ms) if ms else None


# ---------------------------------------------------------------- construccion
def construir(mapa, filas, pasos=(), pistas=()):
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
    techos = []  # (wid, nombre, huella, z_losa_inferior, grosor, es_roof)
    for wid, w in sorted(mapa.ways.items()):
        t = w.get("tags", {})
        if not (("building" in t or t.get("man_made") == "tower") and mapa.cerrado(w)):
            continue
        fila = filas[str(wid)]
        forma = forma_de(fila)
        alt, base = resolver(fila)
        polys = validos(mapa.poligono(w))
        huella = unary_union(polys) if polys else None
        es_roof = t.get("building") == "roof"
        nombre = fila.get("nombre") or t.get("name", "")
        if forma == "techo":
            if es_roof:      # base_m + grosor altura_m
                z0, grosor = base, alt
            else:            # altura_m = cota de la cara superior de la cubierta
                grosor = min(GROSOR_TECHO, alt)
                z0 = alt - grosor
            top = z0 + grosor
            m = extruir(huella, grosor, z0)
        elif forma in ("tunel_z", "tunel_x"):
            top = alt + base
            m, muros_tunel = malla_tunel(huella, forma, base, top - min(GROSOR_TECHO, alt), top)
        else:
            top = alt + base
            if pasos and huella is not None:
                m, n = partir_por_pasos(huella, base, top, pasos, f"{wid} {nombre}"[:40])
                if n:
                    stats["edificios_partidos"] += 1
            else:
                m = extruir(huella, alt, base)
        if m is None:
            stats["edificios_descartados"] += 1
            print(f"AVISO: edificio {wid} sin geometria valida", file=sys.stderr)
            continue
        if t.get("man_made") == "tower":
            clave = "torre"
        elif forma == "techo":
            clave = "cubierta"
        else:
            clave = "edificio"
        piezas.append((f"edif_{wid}_{slug(nombre)}-col", m, clave))
        stats["edificios"] += 1
        info = {"id": wid, "nombre": nombre, "poly": unary_union(polys), "altura": top,
                "clave": clave, "forma": forma, "tags": t, "pilares": [],
                "muros": muros_tunel if forma in ("tunel_z", "tunel_x") else None}
        edif_info.append(info)
        if forma == "techo":
            techos.append((info, z0, es_roof))

    # Pilares de los techos
    volumenes = unary_union([e["poly"] for e in edif_info if e["forma"] == "volumen"])
    for info, z0, es_roof in techos:
        poly = info["poly"]
        if z0 < 0.05:
            continue
        if es_roof and poly.area > 0 and poly.intersection(volumenes).area / poly.area > 0.5:
            stats["techos_sin_pilares_sobre_edificio"] += 1
            continue
        modo = modo_pilares(filas[str(info["id"])])
        if modo == "ninguno":
            continue
        centros = pilares_techo(poly, z0, volumenes, modo)
        m = malla_pilares(centros, z0)
        if m is not None:
            piezas.append((f"pilares_{info['id']}_{slug(info['nombre'])}-col", m, "pilar"))
            info["pilares"] = centros
            stats["pilares"] += len(centros)
        stats["techos"] += 1

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

    # Cerramientos de pistas de padel
    pistas_info, mallas_padel = [], []
    for pi in pistas:
        w = mapa.ways.get(pi["id"])
        polys = validos(mapa.poligono(w)) if w is not None and mapa.cerrado(w) else []
        if not polys:
            print(f"AVISO: pista {pi['id']} no encontrada o no cerrada en el OSM", file=sys.stderr)
            continue
        poly = polys[0]
        m = extruir(cerramiento_pista(poly, GROSOR_CERRAMIENTO), pi["altura"])
        if m is not None:
            mallas_padel.append(m)
        pistas_info.append({"id": pi["id"], "nombre": pi["nombre"], "poly": poly})
    if mallas_padel:
        piezas.append(("padel-col", trimesh.util.concatenate(mallas_padel), "cristal_padel"))
        stats["pistas_padel"] = len(mallas_padel)

    # Limite del mapa
    ext = campus.buffer(MARGEN_LIMITE)
    anillo = ext.exterior.buffer(0.25, join_style="mitre")
    piezas.append(("limite-col", extruir(anillo, 6.0), "limite"))

    return piezas, stats, {"campus": campus, "edificios": edif_info, "caminos": caminos_geom,
                           "zonas": zonas_geom, "suelo": caja_suelo, "pasos": list(pasos), "pistas": pistas_info}


# ---------------------------------------------------------------- preview
def preview(ruta, geo, extra=None):
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
        m = RX_NUM_EDIF.match(e["nombre"] or "")
        if m:
            c = e["poly"].representative_point()
            ax.text(c.x, c.y, m.group(1), fontsize=7, ha="center", va="center", zorder=5,
                    color="white", fontweight="bold",
                    bbox=dict(boxstyle="round,pad=0.1", fc="black", ec="none", alpha=0.5))
    grupos = {}
    for pi in geo.get("pistas", []):  # una etiqueta por nombre (varias pistas pueden compartirlo)
        grupos.setdefault(pi["nombre"], []).append(pi["poly"])
    for nombre, polys in grupos.items():
        c = unary_union(polys).centroid
        ax.text(c.x, c.y, nombre, fontsize=7, ha="center", va="center", zorder=5,
                color="white", fontweight="bold",
                bbox=dict(boxstyle="round,pad=0.1", fc="#1f6fb2", ec="none", alpha=0.7))
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
    if extra is not None:  # extra(ax): dibuja encima antes de guardar
        extra(ax)
    fig.tight_layout()
    fig.savefig(ruta)
    plt.close(fig)
    print(f"Preview: {ruta}")


def zoom_paso(ruta, geo, mapa, paso_id, radio=45.0):
    """Vista cenital ampliada (2*radio m) de un paso (o grupo de pasos con ese prefijo de id): antes (sin partir) y despues."""
    grupo = [p for p in geo["pasos"] if p["id"] == paso_id or p["id"].startswith(paso_id)]
    if not grupo:
        print(f"AVISO: no hay paso '{paso_id}' en pasos.csv; no se genera {ruta}", file=sys.stderr)
        return
    paso = {"id": paso_id, "descripcion": grupo[0]["descripcion"], "galibo": grupo[0]["galibo"],
            "seg": unary_union([p["seg"] for p in grupo]), "poly": unary_union([p["poly"] for p in grupo])}
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
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

    c = paso["seg"].centroid
    ventana = box(c.x - radio, c.y - radio, c.x + radio, c.y + radio)
    todos = unary_union([q["poly"] for q in geo["pasos"]])
    col_z = {"verde": "#a8d08d", "agua": "#7fb2e0", "pista": "#d98a73", "aparcamiento": "#bdbdbd"}
    fig, axs = plt.subplots(1, 2, figsize=(20, 10.4), dpi=100)
    for ax, despues in zip(axs, (False, True)):
        ax.add_patch(plt.Rectangle((c.x - radio, c.y - radio), 2 * radio, 2 * radio, fc="#e9e1cf", ec="none"))
        for cat, g in geo["zonas"].items():
            for p in parche(g.intersection(ventana), fc=col_z[cat], ec="none", zorder=1):
                ax.add_patch(p)
        for hw, g in geo["caminos"].items():
            for p in parche(g.intersection(ventana), fc="#555555" if hw in ASFALTO else "#b5b5b5", ec="none", zorder=2):
                ax.add_patch(p)
        for w in mapa.ways.values():  # ejes de footway/path/steps con sus nodos finales
            hw = w.get("tags", {}).get("highway")
            if hw in ("footway", "path", "steps", "pedestrian", "cycleway"):
                l = mapa.linea(w)
                if l is not None and l.intersects(ventana):
                    xs, ys = l.xy
                    ax.plot(xs, ys, color="#1a5fb4", lw=1.2, ls=":", zorder=6)
                    ax.plot([xs[0], xs[-1]], [ys[0], ys[-1]], "o", color="#1a5fb4", ms=5, zorder=6)
        for e in geo["edificios"]:
            if not e["poly"].intersects(ventana):
                continue
            kw = dict(fc="#c8c8cd", ec="black", lw=0.8, zorder=3)
            if e["forma"] == "techo":
                kw.update(fc="#555860", alpha=0.6, hatch="//")
            g = e["poly"]
            if despues and e["forma"] == "volumen":
                for p in parche(g.intersection(todos), fc="#f4d35e", ec="black", lw=0.8, hatch="xx", zorder=4):
                    ax.add_patch(p)
                g = g.difference(todos)
            for p in parche(g, **kw):
                ax.add_patch(p)
            m = RX_NUM_EDIF.match(e["nombre"] or "")
            if m:
                rp = e["poly"].intersection(ventana.buffer(-12)).representative_point()
                if not rp.is_empty:
                    ax.text(rp.x, rp.y, m.group(1), fontsize=18, ha="center", va="center", zorder=8,
                            color="white", fontweight="bold",
                            bbox=dict(boxstyle="round,pad=0.15", fc="black", ec="none", alpha=0.6))
        for p in parche(paso["poly"], fc="none", ec="red", lw=2, ls="--", zorder=7):
            ax.add_patch(p)
        for q in grupo:
            xs, ys = q["seg"].xy
            ax.plot(xs, ys, color="red", lw=1.5, zorder=7)
        ax.set_xlim(c.x - radio, c.x + radio)
        ax.set_ylim(c.y - radio, c.y + radio)
        ax.set_aspect("equal")
        ax.grid(alpha=0.25)
        ax.set_xlabel("Este (m)")
        ax.set_ylabel("Norte (m)")
        ax.set_title("DESPUES: huella - paso (gris) y %s" % (
            "soportal (amarillo, desde galibo %g m)" % paso["galibo"] if paso["galibo"] is not None
            else "hueco abierto al cielo (amarillo = zona recortada)") if despues
            else "ANTES: huellas enteras; rojo = paso %s; azul = footway/path" % paso_id)
    fig.suptitle(f"Paso {paso_id}: {paso['descripcion']} (norte arriba)")
    fig.tight_layout()
    fig.savefig(ruta)
    plt.close(fig)
    print(f"Zoom: {ruta}")


def zoom_tunel(ruta, geo, edif_id, radio=40.0):
    """Vista cenital ampliada de un edificio-tunel: antes (huella entera) y despues (losa + paredes + pilares)."""
    e = next((q for q in geo["edificios"] if q["id"] == edif_id), None)
    if e is None:
        return
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
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

    c = e["poly"].centroid
    fig, axs = plt.subplots(1, 2, figsize=(20, 10.4), dpi=100)
    for ax, despues in zip(axs, (False, True)):
        ax.add_patch(plt.Rectangle((c.x - radio, c.y - radio), 2 * radio, 2 * radio, fc="#e9e1cf", ec="none"))
        for q in geo["edificios"]:
            if q is e or not q["poly"].buffer(radio).contains(c) and not q["poly"].intersects(e["poly"].buffer(radio)):
                continue
            for p in parche(q["poly"], fc="#c8c8cd", ec="black", lw=0.8, zorder=2):
                ax.add_patch(p)
        kw = dict(fc="#555860", alpha=0.5, ec="black", lw=1.0, hatch="//", zorder=3) if despues             else dict(fc="#c8c8cd", ec="black", lw=1.0, zorder=3)
        for p in parche(e["poly"], **kw):
            ax.add_patch(p)
        if despues:
            if e["muros"] is not None:
                for p in parche(e["muros"], fc="#222222", ec="red", lw=1.0, zorder=4):
                    ax.add_patch(p)
            for x, y in e["pilares"]:
                ax.plot(x, y, "s", color="#333333", ms=4, zorder=5)
        ax.set_xlim(c.x - radio, c.x + radio)
        ax.set_ylim(c.y - radio, c.y + radio)
        ax.set_aspect("equal")
        ax.grid(alpha=0.25)
        ax.set_xlabel("Este (m)")
        ax.set_ylabel("Norte (m)")
        ax.set_title("DESPUES: losa (trama) + paredes de 0,3 m (negro); lados N y S abiertos" if despues
                     else "ANTES: huella entera")
    fig.suptitle(f"Edificio {edif_id} ({e['forma']}): {e['nombre']} (norte arriba)")
    fig.tight_layout()
    fig.savefig(ruta)
    plt.close(fig)
    print(f"Zoom: {ruta}")


# ---------------------------------------------------------------- verificacion
def verificar(ruta):
    sc = trimesh.load(ruta, force="scene")
    nombres = list(sc.graph.nodes_geometry)
    tris = sum(len(sc.geometry[sc.graph[n][1]].faces) for n in nombres)
    b = sc.bounds
    print(f"[verificacion] nodos con geometria: {len(nombres)} | triangulos: {tris}")
    print(f"[verificacion] bounds (m) min={np.round(b[0], 1).tolist()} max={np.round(b[1], 1).tolist()} "
          f"-> {b[1][0] - b[0][0]:.0f} x {b[1][2] - b[0][2]:.0f} m (E-O x N-S), alto {b[1][1]:.1f} m")
    edif = [n for n in nombres if n.startswith(("edif_", "pilares_"))]
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
    ap.add_argument("--pasos", default="data/pasos.csv")
    ap.add_argument("--pistas", default="data/pistas.csv")
    ap.add_argument("--salida", default="export/upo_blockout.glb")
    ap.add_argument("--sin-preview", action="store_true")
    ap.add_argument("--copiar-godot", action=argparse.BooleanOptionalAction, default=True,
                    help="copia el .glb a game/assets/mapa/ (--no-copiar-godot lo desactiva)")
    a = ap.parse_args()

    mapa = Mapa(a.entrada)
    edificios = [(wid, w["tags"]) for wid, w in sorted(mapa.ways.items())
                 if "tags" in w and mapa.cerrado(w)
                 and ("building" in w["tags"] or w["tags"].get("man_made") == "tower")]
    filas = cargar_alturas(a.alturas, edificios)
    pasos = cargar_pasos(a.pasos)
    piezas, stats, geo = construir(mapa, filas, pasos, cargar_pistas(a.pistas))

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
    if a.copiar_godot:
        destino = Path(DESTINO_GODOT)
        destino.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(salida, destino)
        print(f"Copiado a {destino}")

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
        zoom_paso(salida.with_name("zoom_22_24.png"), geo, mapa, "22-24")
        zoom_tunel(salida.with_name("zoom_37.png"), geo, 142276198)


if __name__ == "__main__":
    main()
