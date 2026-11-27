"""Genera el blockout 3D del campus de la UPO (glTF/GLB para Godot 4).

Entrada: data/raw/osm_upo.json (Overpass `out body; >; out skel qt;`: los ways
traen ids de nodo; la geometria se reconstruye con un dict de nodos).
Proyeccion: EPSG:25830 (UTM 30N) con origen en el centroide del contorno del
campus. Ejes glTF (Y arriba): x = este, y = altura, z = -norte.

Salidas: export/upo_blockout.glb, export/upo_blockout_meta.json,
export/preview.png, export/perfil_pasillo.png, export/zoom_22_24.png y data/alturas.csv (editable; solo se anaden
filas nuevas; columna `fuente`: defecto|osm|lidar|manual; columna `forma`: volumen|techo).
forma=tunel_z|tunel_x: losa + paredes de 0,3 m en los lados paralelos al eje; columna `pilares`: perimetro|todos|ninguno.
forma=techo: losa de 0,4 m (cara superior a la altura de cubierta) sobre pilares de 0,4x0,4 m.
Columna `estilo` (opcional; vacia = por defecto segun nombre/osm_id): estilo de fachada; se exporta resuelto a game/data/estilos.json.
forma=excluir: el edificio se omite del todo (sin malla ni colision; tampoco cuenta en generar_spawns.py).
Columna `nivel` (techos y tuneles): plano = losa horizontal a la cota constante `cota_abs` (m s.n.m. de la cara
superior; si esta vacia, mediana de mdt+ndsm LiDAR bajo la huella encogida 1 m); inclinado = plano de minimos
cuadrados de esos pixeles; terreno = la losa sigue el terreno (drapeada). Vacio: plano (inclinado en el pasillo
central). Si `cota_abs` esta rellena manda (losa plana a esa cota). Los calculados se escriben en el CSV.
data/pasos.csv: pasos peatonales (segmento + ancho + galibo) que parten los edificios volumen.
Los nodos acabados en `-col` generan colision automatica al importar en Godot.
Bordes: `valla_perimetral` (+ `valla_perimetral_malla`, sin colision) 0,8 m por dentro del limite y `exterior`
(faldon de terreno sin colision, 2 km desde el borde de la malla, material `campo`).

Relieve (scripts/terreno.py): el suelo es `terreno-col`, una rejilla regular sobre el MDT (campus + 50 m); y_juego =
cota - cota_ref (mediana de las cotas dentro del contorno). Caminos y zonas se drapean sobre el terreno; los
edificios volumen van de la cota minima de su huella - 0,5 m a la cota media + altura; techos, tuneles, muros, vallas,
padel y limite siguen el terreno (ver README). --terreno plano reproduce el suelo plano anterior.

Uso: uv run python scripts/generar_blockout.py [--entrada data/raw/osm_upo.json]
     [--alturas data/alturas.csv] [--pasos data/pasos.csv] [--salida export/upo_blockout.glb] [--sin-preview]
     [--mdt data/raw/mdt_lidar_1m.tif] [--terreno mdt|plano] [--paso-terreno 1] [--paso-grueso 4] [--buffer-fino 8]
     [--suavizado-m 1]   (los valores por defecto viven en scripts/terreno.py)
     [--no-copiar-godot]   (por defecto copia el .glb a game/assets/mapa/)
     [--sin-arboles] [--sin-coches] [--ocupacion 0.55] [--coches-carretera 15] [--semilla 1]
     [--altura-min-arbol 3] [--sep-arboles 3] [--zonas data/zonas.json] [--props data/props.csv]
     [--altura-tronco-grande 12]

Vegetacion y coches (scripts/vegetacion.py, coches.py, entorno.py): arboles low-poly desde el nDSM de vegetacion LiDAR
(`arboles_troncos-col` con colision y `arboles_copas*` sin ella, uno por tono de verde) y coches estaticos
(`coches_<color>-col` con colision, `coches_ruedas-col`, `coches_cristales`) en los aparcamientos y algunas carreteras; ademas export/coches.json. Evitan los spawns de game/data/spawns.json si existe.
Zonas y coberturas (scripts/datos_zonas.py, props.py): data/zonas.json excluye arboles y coches de los limites y barreras de las zonas y
engrosa los troncos altos dentro de ellas; data/props.csv coloca los props (nodos `props_<material>-col`, ver props.py).
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
import shapely
import trimesh
from pyproj import Transformer
from shapely.affinity import rotate
from shapely.geometry import LineString, MultiPolygon, Point, Polygon, box
from shapely.ops import linemerge, polygonize, unary_union
from shapely.validation import make_valid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import coches as coc  # noqa: E402
import datos_zonas as dz  # noqa: E402
import entorno as ent  # noqa: E402
import props as prp  # noqa: E402
import terreno as ter  # noqa: E402
import vegetacion as veg  # noqa: E402

CAMPUS_ID = 39935092
DESTINO_GODOT = "game/assets/mapa/upo_blockout.glb"
SPAWNS_JSON = "game/data/spawns.json"
NDSM_VEG_DEFECTO = "data/raw/ndsm_veg_lidar_1m.tif"   # altura de la vegetacion sobre el suelo (LiDAR 2020, 1 m)
PLANTA_M = 3.5
PLANTAS_DEFECTO = 3
ALTURA_DEFECTO = PLANTAS_DEFECTO * PLANTA_M
MARGEN_SUELO = 50.0
MARGEN_CAMINOS = 30.0
MARGEN_LIMITE = 20.0
VALLA_INTERIOR = 0.8         # la valla perimetral va 0,8 m por dentro del muro limite (visible, el jugador la ve como borde)
VALLA_ALTURA = 2.0
VALLA_POSTE_SEP = 3.0
VALLA_POSTE_LADO = 0.1
FALDON_EXTENSION = 2000.0    # el faldon exterior se extiende 2 km desde el borde de la malla de terreno
FALDON_PASO = 4.0            # paso de los vertices a lo largo del borde (= bloque grueso del terreno)
FALDON_ANILLOS = (0.0, 8.0, 24.0, 60.0, 120.0, 250.0, 500.0, 900.0, 1400.0, 2000.0)
FALDON_CAIDA = 0.004         # m de descenso por m de distancia al borde (8 m a 2 km)
CAMPOS_CSV = ["osm_id", "nombre", "building", "forma", "plantas", "altura_m", "base_m", "notas", "fuente", "pilares",
              "nivel", "cota_abs", "estilo", "suelo"]
SUELOS = ("", "plano", "eje")                  # columna `suelo` de los techos: vacio = terreno, plano = pavimento aplanado a un plano, eje = cota solo funcion de la distancia a lo largo del eje (pasillos curvos)
GALIBO_EJE_MIN, GALIBO_EJE_MAX = 2.5, 3.0      # suelo=eje: galibo de la losa = mediana LiDAR acotada
SUELO_BORDE_M = 1.5          # la zona aplanada excede la huella 1,5 m (> diagonal de una celda de 1 m: el suelo de la huella es exacto)
SUELO_TRANSICION_M = 2.0     # transicion suave hacia fuera (solo donde el exterior esta a < SUELO_UMBRAL_M del plano)
SUELO_UMBRAL_M = 0.5
SUELO_RESIDUO_M = 0.5        # ajuste robusto: se descartan residuos > 0,5 m
SUELO_PAVIMENTO_Y = 0.02     # malla `suelo_pasillos` 2 cm sobre el suelo aplanado
MURO_SUELO_GROSOR = 0.3
MURO_SUELO_PRETIL = 1.0      # el muro llega hasta plano + 1,0 m
MURO_SUELO_ENTERRADO = 0.5   # y baja hasta cota exterior - 0,5 m
GALIBO_MIN_M = 2.4           # si la losa del LiDAR deja < 2,4 m sobre el suelo, losa paralela al suelo
GALIBO_PARALELA_M = 3.0
ESTILOS_JSON = "game/data/estilos.json"
FORMAS = ("volumen", "techo", "tunel_z", "tunel_x", "excluir")   # excluir: el edificio se omite (sin malla ni colision)
NIVELES = ("plano", "inclinado", "terreno")   # columna `nivel` de techos y tuneles; ver calcular_losa
ID_PASILLO_CENTRAL = 1373541639               # techo del eje central: nivel por defecto inclinado
ID_PUENTE_18 = 553042591                      # marquesina diagonal del 18: puente macizo sobre el cauce (suelo=plano, nivel=inclinado)
NDSM_DEFECTO = "data/raw/ndsm_edif_lidar_1m.tif"   # altura de la clase edificacion sobre el MDT (LiDAR 2020, 1 m)
NDSM_MIN_M = 2.0             # pixeles de cubierta: ndsm >= 2 m
LOSA_MIN_PIXELES = 10        # con menos pixeles se usa el terreno + la altura de la fila
MODOS_PILARES = ("perimetro", "todos", "ninguno")   # columna opcional `pilares`; vacio = automatico
GROSOR_TECHO = 0.4
PILAR_LADO = 0.4
PILAR_SEP = 8.0
PILAR_INTERIOR_BUFFER = 7.5  # pilares interiores solo en los puntos de la rejilla dentro de huella.buffer(-7.5)
PILAR_TODOS_BUFFER = 3.0     # pilares=todos: rejilla dentro de huella.buffer(-3)
GROSOR_PARED_TUNEL = 0.3
ZOCALO_EDIFICIO = 0.5        # los volumenes bajan 0,5 m por debajo de la cota minima de su huella
ENTERRADO_LINEAL = 0.3       # muros, vallas, padel, limite, pilares y paredes de tunel: base a terreno - 0,3 m
EMPOTRADO_PILAR = 0.1        # el pilar entra 0,1 m en la losa
FRAG_AREA_MIN = 0.25         # fragmentos de un edificio partido por pasos: < 25 % del mayor -> descartar
FRAG_ANCHO_MIN = 1.5         # ... y los de menos de 1,5 m de ancho (desaparecen con buffer(-0.75))
CAMPOS_PASOS = ["id", "descripcion", "x1", "z1", "x2", "z2", "ancho_m", "galibo_m", "notas"]
# fuente: defecto | osm | lidar | lidar2020 | manual (ver scripts/alturas_lidar.py; solo se pisan defecto y lidar)

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
    "valla_metal": (95, 100, 105, 255), "valla_malla": (140, 145, 150, int(0.30 * 255)),
    "campo": (125, 105, 70, 255),
    "pavimento_blanco": (232, 230, 224, 255),   # #E8E6E0
}
COLORES.update(veg.COLORES_MATERIAL)
COLORES.update(coc.COLORES_MATERIAL)
COLORES.update(prp.COLORES_MATERIAL)


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


# ---------------------------------------------------------------- mallas sobre el terreno
def _poligonos(g):
    """Todos los Polygon (no vacios) de una geometria cualquiera, sin filtrar por area."""
    if g.is_empty:
        return []
    if g.geom_type == "Polygon":
        return [g] if g.area > 1e-9 else []
    return [q for h in g.geoms for q in _poligonos(h)] if hasattr(g, "geoms") else []


def _earcut(p):
    """Triangula un Polygon (con huecos) con earcut. Devuelve (v (N, 2), f (M, 3)) con normal +arriba."""
    import mapbox_earcut as earcut
    anillos = [np.asarray(p.exterior.coords)[:-1]] + [np.asarray(r.coords)[:-1] for r in p.interiors]
    v = np.vstack(anillos).astype(np.float64)
    fin = np.cumsum([len(r) for r in anillos]).astype(np.uint32)
    f = np.asarray(earcut.triangulate_float64(v, fin), np.int64).reshape(-1, 3)
    a, b, c = v[f[:, 0]], v[f[:, 1]], v[f[:, 2]]
    neg = (b[:, 0] - a[:, 0]) * (c[:, 1] - a[:, 1]) - (b[:, 1] - a[:, 1]) * (c[:, 0] - a[:, 0]) < 0
    f[neg] = f[neg][:, ::-1]
    return v, f


def superficie(geom, T):
    """Triangula en planta los poligonos de geom sobre la malla del terreno T. T plano: un earcut por poligono.
    Si no, el plano se corta en los bloques de T.paso_bloque alineados con el origen y cada bloque con las facetas
    EXACTAS del terreno (T.facetas_bloques: 2 triangulos si es grueso, celdas de paso fino si es fino, abanico si es
    de transicion). Los triangulos enteros dentro del poligono se copian tal cual; los de borde se intersecan con el
    poligono y se triangulan con earcut. Asi las piezas quedan sobre facetas planas del terreno, los vertices
    coinciden entre bloques vecinos (sin uniones en T; se sueldan por redondeo a 1 micra) y el dibujado sigue la
    colision. Devuelve (v (N, 2), f (M, 3)) con normal +arriba, o (None, None)."""
    vs, fs = [], []
    G = None if T.es_plano else T.paso_bloque
    for p in validos(geom):
        if G is None:
            v, f = _earcut(p)
            vs.append(v)
            fs.append(f)
            continue
        x0, y0, x1, y1 = p.bounds
        i0, i1, j0, j1 = math.floor(x0 / G), math.ceil(x1 / G), math.floor(y0 / G), math.ceil(y1 / G)
        ii, jj = np.meshgrid(np.arange(i0, i1), np.arange(j0, j1))
        ii, jj = ii.ravel(), jj.ravel()
        cajas = shapely.box(ii * G, jj * G, (ii + 1) * G, (jj + 1) * G)
        shapely.prepare(p)
        toca = shapely.intersects(p, cajas)
        entera = toca & shapely.contains(p, cajas)
        if entera.any():
            tr = T.facetas_bloques(ii[entera], jj[entera])
            vs.append(tr.reshape(-1, 2))
            fs.append(np.arange(len(tr) * 3).reshape(-1, 3))
        for i, j in zip(ii[toca & ~entera], jj[toca & ~entera]):
            g = shapely.clip_by_rect(p, i * G, j * G, (i + 1) * G, (j + 1) * G)
            if g.is_empty:
                continue
            tr = T.facetas_bloques(i, j)
            tp = shapely.polygons(tr)
            shapely.prepare(g)
            dentro = shapely.contains(g, tp)
            if dentro.any():
                vs.append(tr[dentro].reshape(-1, 2))
                fs.append(np.arange(int(dentro.sum()) * 3).reshape(-1, 3))
            for k in np.nonzero(shapely.intersects(g, tp) & ~dentro)[0]:
                for q in _poligonos(g.intersection(tp[k])):
                    v, f = _earcut(q)
                    vs.append(v)
                    fs.append(f)
    if not vs:
        return None, None
    off = np.cumsum([0] + [len(v) for v in vs[:-1]])
    v = np.vstack(vs)
    f = np.vstack([f + o for f, o in zip(fs, off)])
    if G is not None:        # soldar vertices coincidentes
        v, f = _soldar(v, f)
    return v, f


def _soldar(v, f):
    """Une los vertices (N, 2) que coinciden (redondeo a 1 micra) y descarta los triangulos degenerados."""
    claves = np.round(v * 1e6).astype(np.int64)
    _, idx, inv = np.unique(claves, axis=0, return_index=True, return_inverse=True)
    inv = np.asarray(inv).ravel()
    v, f = v[idx], inv[f]
    f = f[(f[:, 0] != f[:, 1]) & (f[:, 1] != f[:, 2]) & (f[:, 0] != f[:, 2])]
    return v, f


def plano_drapeado(geom, T, y_off):
    """Malla (superficie) que sigue el terreno: cada vertice a altura(x, z) + y_off. Mesh local (x, norte, z)."""
    v, f = superficie(geom, T)
    if v is None:
        return None
    z = T.h(v[:, 0], v[:, 1]) + y_off
    return trimesh.Trimesh(np.column_stack([v, z]), f, process=False)


def prisma_drapeado(geom, fbot, ftop, T):
    """Solido watertight sobre la planta geom: en cada vertice la cara inferior esta a fbot(x, y) y la
    superior a ftop(x, y) (funciones del plano local (x, norte) -> cota de juego)."""
    v, f = superficie(geom, T)
    if v is None:
        return None
    n = len(v)
    zt, zb = ftop(v[:, 0], v[:, 1]), fbot(v[:, 0], v[:, 1])
    verts = np.vstack([np.column_stack([v, zt]), np.column_stack([v, zb])])
    # aristas dirigidas que no tienen la inversa: borde de la planta (el exterior queda a la derecha)
    e = np.concatenate([f[:, [0, 1]], f[:, [1, 2]], f[:, [2, 0]]])
    claves = e[:, 0] * n + e[:, 1]
    inversas = e[:, 1] * n + e[:, 0]
    borde = e[~np.isin(inversas, claves)]
    a, b = borde[:, 0], borde[:, 1]
    lados = np.concatenate([np.column_stack([a + n, b + n, b]), np.column_stack([a + n, b, a])])
    faces = np.vstack([f, f[:, ::-1] + n, lados])
    return trimesh.Trimesh(verts, faces, process=False)


def malla_terreno(caja, T):
    """Malla del terreno sobre `caja` (se redondea hacia fuera a bloques de T.paso_bloque alineados con el origen):
    las facetas de Terreno.facetas_bloques (ver terreno.py: grueso / fino / transicion), con cada vertice a
    T.h(x, y). Mesh local (x, norte, z)."""
    x0, y0, x1, y1 = caja.bounds
    if T.es_plano:
        return plano(caja, 0.0)
    G = T.paso_bloque
    ii, jj = np.meshgrid(np.arange(math.floor(x0 / G), math.ceil(x1 / G)), np.arange(math.floor(y0 / G), math.ceil(y1 / G)))
    tr = T.facetas_bloques(ii.ravel(), jj.ravel())
    v, f = _soldar(tr.reshape(-1, 2), np.arange(len(tr) * 3).reshape(-1, 3))
    return trimesh.Trimesh(np.column_stack([v, T.h(v[:, 0], v[:, 1])]), f, process=False)


# zona de malla fina: detalle donde hay escaleras, rampas y muros de contencion
EDIF_PASILLO = 1373541639
HW_ZONA_FINA = ("steps", "footway", "path", "pedestrian")


def zona_fina(mapa, campus, buffer_m, ids_extra=()):
    """Geometria (x, norte local) donde la malla del terreno usa el paso fino: `buffer_m` alrededor de los
    highway=steps/footway/path/pedestrian, los barrier=retaining_wall, el pasillo central y los techos con suelo=plano
    (`ids_extra`, ver ids_suelo). None si buffer_m <= 0."""
    if buffer_m <= 0:
        return None
    gs = []
    for w in mapa.ways.values():
        t = w.get("tags", {})
        if t.get("highway") in HW_ZONA_FINA or t.get("barrier") == "retaining_wall":
            l = mapa.linea(w)
            if l is not None:
                gs.append(l)
    for wid in {EDIF_PASILLO, *ids_extra}:
        w = mapa.ways.get(wid)
        if w is not None and mapa.cerrado(w):
            gs.extend(validos(mapa.poligono(w)))
    if not gs:
        return None
    return unary_union([g.buffer(buffer_m) for g in gs]).intersection(campus.buffer(MARGEN_CAMINOS))


def muestras_huella(poly, T, paso=1.0):
    """Cotas de juego del terreno bajo una huella: rejilla de `paso` m dentro + vertices del contorno."""
    x0, y0, x1, y1 = poly.bounds
    X, Y = np.meshgrid(np.arange(x0, x1 + paso, paso), np.arange(y0, y1 + paso, paso))
    X, Y = X.ravel(), Y.ravel()
    d = shapely.contains_xy(poly, X, Y)
    xs, ys = [X[d]], [Y[d]]
    for p in validos(poly):
        c = np.asarray(p.exterior.coords)
        xs.append(c[:, 0])
        ys.append(c[:, 1])
    return T.h(np.concatenate(xs), np.concatenate(ys))


def _muestras_xy(poly, paso=1.0):
    """Puntos (x, norte) bajo una huella: rejilla de `paso` m dentro + vertices del contorno."""
    x0, y0, x1, y1 = poly.bounds
    X, Y = np.meshgrid(np.arange(x0, x1 + paso, paso), np.arange(y0, y1 + paso, paso))
    X, Y = X.ravel(), Y.ravel()
    d = shapely.contains_xy(poly, X, Y)
    xs, ys = [X[d]], [Y[d]]
    for p in validos(poly):
        c = np.asarray(p.exterior.coords)
        xs.append(c[:, 0])
        ys.append(c[:, 1])
    return np.concatenate(xs), np.concatenate(ys)


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


# ---------------------------------------------------------------- estilos de fachada
# Columna `estilo` de alturas.csv (vacia = defecto). Los estilos los define game/scripts/materiales.gd.
ESTILOS_EJE = ("eje_pastel_verde", "eje_pastel_rosa", "eje_pastel_malva")
ESTILOS_POR_NUM = {"31": "ladrillo_rectorado", "32": "ladrillo_rectorado", "35": "ladrillo_torre",
                   "25": "biblioteca", "22": "rosa_24", "23": "rosa_24", "24": "rosa_24", "45": "policarbonato"}
ESTILOS_VALIDOS = set(ESTILOS_EJE) | set(ESTILOS_POR_NUM.values())


def estilo_defecto(osm_id, nombre):
    """Estilo por defecto: por numero de edificio (nombre `Edificio N`, tolera typos), por nombre
    (Rectorado/Paraninfo) o, en el resto, eje pastel segun osm_id mod 3."""
    m = RX_NUM_EDIF.match(nombre or "")
    n = m.group(1) if m else ""
    if n in ESTILOS_POR_NUM:
        return ESTILOS_POR_NUM[n]
    if re.search(r"rectorado|paraninfo", nombre or "", re.I):
        return "ladrillo_rectorado"
    if n.isdigit() and 1 <= int(n) <= 18:
        return ESTILOS_EJE[int(n) % 3]
    return ESTILOS_EJE[int(osm_id) % 3]


def estilo_de(fila):
    e = (fila.get("estilo") or "").strip().lower()
    return e if e in ESTILOS_VALIDOS else estilo_defecto(fila["osm_id"], fila.get("nombre"))


def exportar_estilos(filas, ruta=ESTILOS_JSON):
    """game/data/estilos.json: osm_id -> estilo resuelto (explicito o por defecto) de todas las filas."""
    est = {str(k): estilo_de(f) for k, f in filas.items()}
    Path(ruta).parent.mkdir(parents=True, exist_ok=True)
    Path(ruta).write_text(json.dumps(est, indent=1, sort_keys=True), encoding="utf-8")
    print(f"{ruta}: {len(est)} estilos {dict(Counter(est.values()))}")
    return est


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
    guardar_alturas(ruta, filas)
    print(f"{ruta}: {len(filas)} filas ({nuevas} nuevas)")
    return filas


def guardar_alturas(ruta, filas):
    ruta = Path(ruta)
    ruta.parent.mkdir(parents=True, exist_ok=True)
    with open(ruta, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=CAMPOS_CSV, extrasaction="ignore")
        w.writeheader()
        w.writerows(filas.values())


def resolver(fila):
    """(altura_m, base_m) finales de una fila del CSV."""
    alt = num(fila.get("altura_m"))
    if alt is None:
        pl = num(fila.get("plantas"))
        alt = pl * PLANTA_M if pl is not None else ALTURA_DEFECTO
    base = num(fila.get("base_m")) or 0.0
    return max(alt, 0.05), base


# ---------------------------------------------------------------- losas de techos y tuneles
class Lidar:
    """MDT + nDSM de edificacion (1 m, EPSG:25830). `pixeles(huella)` -> (x, norte, cota_abs) de los pixeles de
    cubierta (ndsm >= NDSM_MIN_M) cuyo centro cae dentro de la huella encogida 1 m. Cota absoluta = mdt + ndsm."""

    def __init__(self, ruta_mdt, ruta_ndsm, E0, N0):
        self.ok = Path(ruta_mdt).exists() and Path(ruta_ndsm).exists()
        self.E0, self.N0 = E0, N0
        if not self.ok:
            print(f"AVISO: falta {ruta_mdt} o {ruta_ndsm}: las losas usan terreno + altura", file=sys.stderr)
            return
        import rasterio
        with rasterio.open(ruta_mdt) as d:
            self.mdt, self.t, self.nd_mdt = d.read(1).astype(float), d.transform, d.nodata
        with rasterio.open(ruta_ndsm) as d:
            self.ndsm, self.nd_ndsm = d.read(1).astype(float), d.nodata
        if self.mdt.shape != self.ndsm.shape:
            raise SystemExit("mdt y ndsm LiDAR no tienen la misma rejilla")

    def pixeles(self, huella):
        vacio = np.zeros(0)
        if not self.ok or huella is None:
            return vacio, vacio, vacio
        g = huella.buffer(-1.0)
        if g.is_empty:
            return vacio, vacio, vacio
        x0, y0, x1, y1 = g.bounds
        t = self.t
        j0, j1 = int((x0 + self.E0 - t.c) // t.a), int((x1 + self.E0 - t.c) // t.a) + 1
        i0, i1 = int((t.f - (y1 + self.N0)) // -t.e), int((t.f - (y0 + self.N0)) // -t.e) + 1
        j0, i0 = max(j0, 0), max(i0, 0)
        j1, i1 = min(j1, self.mdt.shape[1]), min(i1, self.mdt.shape[0])
        if j1 <= j0 or i1 <= i0:
            return vacio, vacio, vacio
        I, J = np.meshgrid(np.arange(i0, i1), np.arange(j0, j1), indexing="ij")
        X = t.c + (J + 0.5) * t.a - self.E0
        Y = t.f + (I + 0.5) * t.e - self.N0
        nd, m = self.ndsm[I, J], self.mdt[I, J]
        buenos = (np.isfinite(nd) & np.isfinite(m) & (nd >= NDSM_MIN_M) & (m > -1000)
                  & (nd != self.nd_ndsm) & (m != self.nd_mdt))
        buenos &= shapely.contains_xy(g, X, Y)
        return X[buenos], Y[buenos], (m + nd)[buenos]


def ajustar_plano(x, y, z, residuo_max=1.0):
    """Minimos cuadrados z = a x + b y + c con un robusto simple: descarta residuos > residuo_max y reajusta.
    Devuelve (a, b, c, n_usados)."""
    ox, oy = x.mean(), y.mean()
    A = np.column_stack([x - ox, y - oy, np.ones_like(x)])
    usar = np.ones(len(x), bool)
    for _ in range(3):
        coef = np.linalg.lstsq(A[usar], z[usar], rcond=None)[0]
        nuevo = np.abs(A @ coef - z) <= residuo_max
        if nuevo.sum() < LOSA_MIN_PIXELES or (nuevo == usar).all():
            break
        usar = nuevo
    a, b = float(coef[0]), float(coef[1])
    return a, b, float(coef[2] - a * ox - b * oy), int(usar.sum())


def nivel_de(fila, wid):
    n = (fila.get("nivel") or "").strip().lower()
    if n in NIVELES:
        return n
    return "inclinado" if int(wid) == ID_PASILLO_CENTRAL else "plano"


def altura_cubierta(fila, forma, es_roof):
    """(cara superior de la cubierta sobre el terreno local, grosor de la losa) segun la fila del CSV."""
    alt, base = resolver(fila)
    if forma == "techo" and es_roof:
        return base + alt, alt
    if forma == "techo":
        return alt, min(GROSOR_TECHO, alt)
    return alt + base, min(GROSOR_TECHO, alt)


def calcular_losa(wid, fila, huella, top_rel, T, lidar, hx, hy):
    """Cara superior de la losa de un techo o tunel. Devuelve dict con `nivel`, `plano` ((a, b, c) en coordenadas
    de juego: y = a x + b norte + c; None si sigue el terreno), `cota_abs` (plano: m s.n.m.), `n_px` y `origen`.
    (hx, hy): puntos del terreno bajo la huella (para el caso con pocos pixeles LiDAR)."""
    nivel = nivel_de(fila, wid)
    ref = T.cota_ref
    usuario = num(fila.get("cota_abs"))
    if usuario is not None:
        return {"nivel": "plano", "plano": (0.0, 0.0, usuario - ref), "cota_abs": usuario, "n_px": 0,
                "origen": "cota_abs del CSV"}
    if nivel == "terreno" or T.es_plano:
        return {"nivel": "terreno", "plano": None, "cota_abs": None, "n_px": 0, "origen": "terreno"}
    px, py, pz = lidar.pixeles(huella)
    pz_juego = pz - ref
    suficientes = len(px) >= LOSA_MIN_PIXELES
    if nivel == "plano":
        if suficientes:
            c, origen = float(np.median(pz_juego)), f"mediana lidar de {len(px)} px"
        else:
            c, origen = float(np.max(T.h(hx, hy))) + top_rel, f"terreno max + altura ({len(px)} px lidar)"
        return {"nivel": "plano", "plano": (0.0, 0.0, c), "cota_abs": c + ref, "n_px": len(px), "origen": origen}
    if suficientes:
        a, b, c, n = ajustar_plano(px, py, pz_juego)
        origen = f"ajuste lineal lidar de {n}/{len(px)} px"
    else:
        a, b, c, _ = ajustar_plano(hx, hy, T.h(hx, hy))
        c += top_rel
        origen, n = f"plano del terreno + altura ({len(px)} px lidar)", 0
    return {"nivel": "inclinado", "plano": (a, b, c), "cota_abs": None, "n_px": n, "origen": origen}


def anotar_losa(fila, losa, T):
    """Escribe nivel / cota_abs / notas calculados en la fila del CSV solo si el usuario no los relleno."""
    if losa["nivel"] == "eje":
        nota = re.sub(r"(; )?losa (plana|inclinada|sobre el eje)[^;]*$", "", fila.get("notas") or "").strip()
        txt = f"losa sobre el eje: {losa['origen']}"
        fila["notas"] = f"{nota}; {txt}" if nota else txt
        return
    if not (fila.get("nivel") or "").strip():
        fila["nivel"] = losa["nivel"]
    if losa["nivel"] == "plano" and not (fila.get("cota_abs") or "").strip():
        fila["cota_abs"] = f"{losa['cota_abs']:.2f}"
    if losa["origen"] not in ("terreno", "cota_abs del CSV"):
        if losa["plano"] is not None and losa["nivel"] == "plano":
            txt = f"losa plana a {losa['cota_abs']:.2f} m s.n.m. ({losa['origen']})"
        else:
            a, b, c = losa["plano"]
            txt = (f"losa inclinada: pendiente {math.degrees(math.atan(math.hypot(a, b))):.2f} grados, "
                   f"cara superior a {c + T.cota_ref:.2f} m s.n.m. en el origen ({losa['origen']})")
        nota = re.sub(r"(; )?losa (plana|inclinada)[^;]*$", "", fila.get("notas") or "").strip()
        fila["notas"] = f"{nota}; {txt}" if nota else txt


# ---------------------------------------------------------------- suelos de pasillo (columna `suelo`)
def suelo_de(fila):
    v = (fila.get("suelo") or "").strip().lower()
    return v if v in SUELOS else ""


def ids_suelo(filas):
    """osm_id (int) de los techos con suelo=plano o eje: primero el pasillo central (el que manda donde se solapan), despues el resto."""
    ids = [int(k) for k, f in filas.items() if suelo_de(f)]
    return sorted(ids, key=lambda i: (i != ID_PASILLO_CENTRAL, i))


def _ajuste_suelo(px, pn, z):
    """Plano y = a x + b norte + c por minimos cuadrados robusto: se descartan residuos > 1,5, 1,0 y luego > SUELO_RESIDUO_M
    (hasta 5 pasadas; asi un tramo en rampa o escalon no arrastra el plano). Devuelve (a, b, c, usados, rms)."""
    ox, on = px.mean(), pn.mean()
    usar = np.ones(len(px), bool)
    for umbral in (1.5, 1.0, SUELO_RESIDUO_M, SUELO_RESIDUO_M, SUELO_RESIDUO_M):
        A = np.column_stack([px - ox, pn - on, np.ones_like(px)])
        coef = np.linalg.lstsq(A[usar], z[usar], rcond=None)[0]
        a, b, c = float(coef[0]), float(coef[1]), float(coef[2] - coef[0] * ox - coef[1] * on)
        nuevo = np.abs(a * px + b * pn + c - z) <= umbral
        if nuevo.sum() < 10:
            break
        usar = nuevo
    res = a * px + b * pn + c - z
    return a, b, c, int(usar.sum()), float(np.sqrt(np.mean(res[usar] ** 2)))


def _proyectar_eje(P, cum, x, n):
    """Distancia s a lo largo de la polilinea P (con abscisas acumuladas cum) del punto de P mas cercano a cada (x, n)."""
    x = np.asarray(x, float)
    n = np.asarray(n, float)
    forma = np.broadcast(x, n).shape
    q = np.column_stack([np.broadcast_to(x, forma).ravel(), np.broadcast_to(n, forma).ravel()])
    A, B = P[:-1], P[1:]
    d = B - A
    L2 = np.maximum((d ** 2).sum(1), 1e-12)
    largo = np.sqrt(L2)
    out = np.empty(len(q))
    for i0 in range(0, len(q), 20000):
        c = q[i0:i0 + 20000]
        t = np.clip(((c[:, None, :] - A[None]) * d[None]).sum(2) / L2[None], 0.0, 1.0)
        pt = A[None] + t[..., None] * d[None]
        k = np.argmin(((c[:, None, :] - pt) ** 2).sum(2), axis=1)
        idx = np.arange(len(c))
        out[i0:i0 + 20000] = cum[k] + t[idx, k] * largo[k]
    return out.reshape(forma)


def _hat(s, kn):
    """Matriz (N, K) de pesos de la interpolacion lineal entre los nudos kn (creciente)."""
    A = np.zeros((len(s), len(kn)))
    j = np.clip(np.searchsorted(kn, s, side="right") - 1, 0, len(kn) - 2)
    t = np.clip((s - kn[j]) / (kn[j + 1] - kn[j]), 0.0, 1.0)
    A[np.arange(len(s)), j] = 1 - t
    A[np.arange(len(s)), j + 1] = t
    return A


def _ajuste_tramos(s, z, L):
    """Perfil longitudinal z(s), lineal a tramos continuo (sin escalones) con 1, 2 o 3 tramos: ajuste robusto (descarta
    residuos > 1,5, 1,0 y 0,5 m) y busqueda de los nudos cada 5 m; se pasa a mas tramos solo si el rms baja >= 0,08 m y
    >= 25 %. Devuelve (nudos_s, nudos_z, rms, usados)."""
    def ajustar(kn):
        A = _hat(s, kn)
        usar = np.ones(len(s), bool)
        for um in (1.5, 1.0, SUELO_RESIDUO_M, SUELO_RESIDUO_M, SUELO_RESIDUO_M):
            v = np.linalg.lstsq(A[usar], z[usar], rcond=None)[0]
            nuevo = np.abs(A @ v - z) <= um
            if nuevo.sum() < 20:
                break
            usar = nuevo
        r = A @ v - z
        return v, float(np.sqrt(np.mean(r[usar] ** 2))), int(usar.sum()), kn
    cand = np.arange(10.0, L - 9.0, 5.0)
    opciones = {1: [np.array([0.0, L])],
                2: [np.array([0.0, c, L]) for c in cand],
                3: [np.array([0.0, c1, c2, L]) for c1 in cand for c2 in cand if c2 - c1 >= 20.0]}
    elegido = None
    for k in (1, 2, 3):
        if not opciones[k]:
            break
        mejor = min((ajustar(kn) for kn in opciones[k]), key=lambda r: r[1])
        if elegido is None or elegido[1] - mejor[1] >= max(0.08, 0.25 * elegido[1]):
            elegido = mejor
        else:
            break
    v, rms, n, kn = elegido
    return kn, v, rms, n


def _suelo_y(info, x, n):
    """Cota de juego del suelo aplanado de `info` en (x, norte): plano o perfil a lo largo del eje."""
    return info["y"](x, n)


def _anillos_muestreados(zona, paso=1.0):
    """Puntos (N, 2) cada ~`paso` m de cada anillo (exterior e interiores) de la zona."""
    out = []
    for pol in validos(zona):
        for anillo in [pol.exterior, *pol.interiors]:
            n = max(int(round(anillo.length / paso)), 4)
            d = np.linspace(0.0, anillo.length, n, endpoint=False)
            out.append(shapely.get_coordinates(shapely.line_interpolate_point(anillo, d)))
    return out


def preparar_suelos(mapa, filas, T, huecos=None):
    """Aplana el terreno T bajo los techos con suelo=plano (ANTES de mallar: Terreno.anadir_suelo) y devuelve (y guarda
    en T.suelos) {osm_id: info}.

    Plano de cada techo: ajuste robusto LIBRE (descarta residuos > 0,5 m) a las cotas del MDT (T.altura_base: raster de 1 m)
    en una rejilla de 1 m dentro de la huella encogida 0,5 m, sin los edificios volumen. Zona aplanada = huella +
    SUELO_BORDE_M. Donde se solapan dos zonas manda la del pasillo central (se registra la ultima en el terreno). Fuera de la
    zona: transicion suave de SUELO_TRANSICION_M donde el exterior esta a menos de 0,5 m del plano; donde queda mas de 0,5 m
    por debajo -> muro vertical de 0,3 m desde la cota exterior - 0,5 hasta plano + 1,0 (pretil); mas de 0,5 m por encima
    -> muro de contencion desde plano - 0,5 hasta la cota exterior. `huecos` (shapely, plano local): en ellos no hay muro
    (arranque de escaleras). info: plano (a, b, c: y = a x + b norte + c), huella, zona, prioridad (mayor = manda),
    muros [(a_xy, b_xy, y_bajo, y_alto)], long_muros_m y estadisticas del ajuste."""
    T.suelos = {}
    ids = [i for i in ids_suelo(filas) if i in mapa.ways and mapa.cerrado(mapa.ways[i])]
    if T.es_plano or not ids:
        return T.suelos
    vols = []
    for wid, w in mapa.ways.items():
        if "building" in w.get("tags", {}) and mapa.cerrado(w) and str(wid) in filas \
                and forma_de(filas[str(wid)]) == "volumen":
            vols.extend(validos(mapa.poligono(w)))
    bloq = unary_union(vols).buffer(0.5)
    for prio, wid in enumerate(reversed(ids)):          # el primero de ids (pasillo central) tiene la mayor prioridad
        huella = unary_union(validos(mapa.poligono(mapa.ways[wid])))
        px, pn = _muestras_xy(huella.buffer(-0.5), 1.0)
        libre = ~shapely.contains_xy(bloq, px, pn)
        px, pn = px[libre], pn[libre]
        z = T.altura_base(px, -pn)
        modo = suelo_de(filas[str(wid)])
        info = {"id": wid, "modo": modo, "huella": huella, "zona": huella.buffer(SUELO_BORDE_M), "prioridad": prio,
                "n_px": len(px)}
        if modo == "eje":
            # cota = f(s), s = distancia a lo largo del eje geodesico (desde el extremo mas cercano al otro pasillo)
            otros = [h_ for h_ in (mapa.poligono(mapa.ways[i]) for i in ids if i != wid) if h_ is not None]
            ref_pt = unary_union(otros).centroid if otros else None
            vert = list(huella.exterior.coords) if huella.geom_type == "Polygon" else \
                [q for g_ in huella.geoms for q in g_.exterior.coords]
            ini = min(vert, key=lambda q: math.dist(q, (ref_pt.x, ref_pt.y)) if ref_pt is not None else q[0])
            pts, _ = eje_geodesico(huella, ini)
            P = np.array(pts)
            cum = np.concatenate([[0.0], np.cumsum(np.hypot(*np.diff(P, axis=0).T))])
            sm = _proyectar_eje(P, cum, px, pn)
            kn, kz, rms, n_usados = _ajuste_tramos(sm, z, float(cum[-1]))
            info["y"] = lambda x, n, P=P, cum=cum, kn=kn, kz=kz: np.interp(_proyectar_eje(P, cum, x, n), kn, kz)
            res = np.interp(sm, kn, kz) - z
            info.update(eje=P, cum=cum, nudos_s=kn, nudos_y=kz, plano=None,
                        pendiente_grados=math.degrees(math.atan(abs(kz[-1] - kz[0]) / cum[-1])))
        else:
            a, b, c, n_usados, rms = _ajuste_suelo(px, pn, z)
            res = a * px + b * pn + c - z
            info["y"] = lambda x, n, a=a, b=b, c=c: a * np.asarray(x) + b * np.asarray(n) + c
            info.update(plano=(a, b, c), pendiente_grados=math.degrees(math.atan(math.hypot(a, b))))
        info.update(n_usados=n_usados, rms=rms, res_max=float(np.abs(res).max()))
        T.suelos[wid] = info
    # muros y zonas de transicion
    for wid, info in T.suelos.items():
        zona = info["zona"]
        mias = [o for o in T.suelos.values() if o is not info]
        manda = [o["zona"] for o in mias if o["prioridad"] > info["prioridad"]]
        manda = unary_union(manda).buffer(-0.2) if manda else None
        debajo = [o for o in mias if o["prioridad"] < info["prioridad"]]

        def ext_h(x, n, debajo=debajo):
            """cota exterior: la del suelo de menor prioridad si el punto cae en su zona, si no el terreno original."""
            h = T.altura_base(x, -n)
            for o in debajo:
                m = shapely.contains_xy(o["zona"], x, n)
                if m.any():
                    h = np.where(m, o["y"](x, n), h)
            return h
        muros, abierto, largo = [], [], 0.0
        for P in _anillos_muestreados(zona, 1.0):
            n = len(P)
            t = np.roll(P, -1, axis=0) - np.roll(P, 1, axis=0)
            t /= np.maximum(np.linalg.norm(t, axis=1, keepdims=True), 1e-9)
            nor = np.column_stack([t[:, 1], -t[:, 0]])
            dentro = shapely.contains_xy(zona, P[:, 0] + 0.3 * nor[:, 0], P[:, 1] + 0.3 * nor[:, 1])
            nor[dentro] *= -1                                    # normal hacia fuera de la zona
            hp = info["y"](P[:, 0], P[:, 1])
            alt = {d: ext_h(P[:, 0] + d * nor[:, 0], P[:, 1] + d * nor[:, 1]) for d in (0.4, 1.0, 2.0)}
            dif = alt[1.0] - hp
            abajo, arriba = dif < -SUELO_UMBRAL_M, dif > SUELO_UMBRAL_M
            interno = shapely.contains_xy(bloq, P[:, 0], P[:, 1])
            if manda is not None and not manda.is_empty:
                interno |= shapely.contains_xy(manda, P[:, 0], P[:, 1])
            if huecos is not None and not huecos.is_empty:
                interno |= shapely.contains_xy(huecos, P[:, 0], P[:, 1])
            pared = (abajo | arriba) & ~interno
            pared |= np.roll(pared, 1) & np.roll(pared, -1)      # cierra huecos de 1 muestra
            pared &= ~interno
            ybajo = np.where(abajo, np.minimum(np.minimum(alt[0.4], alt[1.0]), alt[2.0]) - MURO_SUELO_ENTERRADO,
                             hp - MURO_SUELO_ENTERRADO)
            yalto = np.where(arriba, np.maximum(alt[0.4], alt[1.0]), hp + MURO_SUELO_PRETIL)
            ybajo = np.minimum(ybajo, hp - MURO_SUELO_ENTERRADO)
            yalto = np.maximum(yalto, hp + 0.3)
            for i in range(n):
                j = (i + 1) % n
                if pared[i] and pared[j]:
                    muros.append((P[i], P[j], float(min(ybajo[i], ybajo[j])), float(max(yalto[i], yalto[j]))))
                    largo += float(np.linalg.norm(P[j] - P[i]))
            ok = ~pared & ~interno
            abierto.extend(shapely.points(P[ok]).tolist() if ok.any() else [])
        info["muros"] = muros
        info["long_muros_m"] = largo
        info["abierto"] = unary_union([q.buffer(SUELO_TRANSICION_M + 0.5) for q in abierto]) if abierto else None
    # el terreno ya ve el plano: se registra DESPUES de calcular los muros (que usan altura_base); el de mayor
    # prioridad el ultimo (gana en el solape)
    for info in sorted(T.suelos.values(), key=lambda i: i["prioridad"]):
        T.anadir_suelo(info["zona"], info["plano"] if info["plano"] is not None else info["y"], info["abierto"], SUELO_TRANSICION_M)
    return T.suelos


def _hexaedros(lista):
    """Mesh de solidos de 8 vertices: lista de (xy (4, 2) antihorario visto desde arriba, z_bajo (4,), z_alto (4,))."""
    N = len(lista)
    v = np.zeros((N, 8, 3))
    for k, (xy, zb, zt) in enumerate(lista):
        v[k, :4, :2], v[k, 4:, :2] = xy, xy
        v[k, :4, 2], v[k, 4:, 2] = zb, zt
    f0 = np.array([[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7]]
                  + [[i, (i + 1) % 4, (i + 1) % 4 + 4] for i in range(4)]
                  + [[i, (i + 1) % 4 + 4, i + 4] for i in range(4)])
    f = (f0[None] + (np.arange(N) * 8)[:, None, None]).reshape(-1, 3)
    return trimesh.Trimesh(v.reshape(-1, 3), f, process=False)


def _caja_segmento(a, b, grosor, y0, y1, ext=0.15):
    """Caja vertical sobre el segmento a-b de `grosor` m (centrada en el, prolongada `ext` m por cada extremo)."""
    t = (b - a) / max(np.linalg.norm(b - a), 1e-9)
    n = np.array([-t[1], t[0]]) * grosor / 2
    a2, b2 = a - t * ext, b + t * ext
    return np.array([a2 - n, b2 - n, b2 + n, a2 + n]), np.full(4, y0), np.full(4, y1)


def malla_muros_suelo(suelos):
    """Muros verticales de hormigon (0,3 m) de todos los suelos: una caja por segmento de 1 m (se prolonga 0,15 m por
    cada extremo para cerrar esquinas). Mesh local (x, norte, z) o None."""
    cajas = [_caja_segmento(a, b, MURO_SUELO_GROSOR, y0, y1)
             for info in suelos.values() for a, b, y0, y1 in info["muros"]]
    return _hexaedros(cajas) if cajas else None


# ---------------------------------------------------------------- escaleras (data/escaleras.csv)
CAMPOS_ESCALERAS = ["id", "x1", "z1", "x2", "z2", "ancho", "notas"]
PELDANO_ALTO = 0.17
PELDANO_HUELLA = 0.30
ESCALERA_ANCHO_DEFECTO = 3.0
ESCALERA_MURO_GROSOR = 0.2
ESCALERA_MURO_ALTO = 1.0      # barandilla (muro) 1 m sobre la rampa
ESCALERA_HUECO_M = 0.6        # el muro lateral de los pasillos se recorta a 0,6 m de la escalera


def cargar_escaleras(ruta):
    """Filas de data/escaleras.csv: id, x1, z1 (arriba), x2, z2 (abajo) en coordenadas de juego (x = este, z = -norte), ancho
    (m, 3 por defecto) y notas. Devuelve [{id, x1, n1, x2, n2, ancho, notas}] (n = -z: norte local)."""
    ruta = Path(ruta)
    out = []
    if not ruta.exists():
        return out
    with open(ruta, newline="", encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            try:
                x1, z1, x2, z2 = (float(str(r[k]).replace(",", ".")) for k in ("x1", "z1", "x2", "z2"))
            except (KeyError, ValueError):
                print(f"AVISO: fila de escaleras invalida: {r}", file=sys.stderr)
                continue
            ancho = num(r.get("ancho")) or ESCALERA_ANCHO_DEFECTO
            out.append({"id": (r.get("id") or "").strip(), "x1": x1, "n1": -z1, "x2": x2, "n2": -z2, "ancho": ancho,
                        "notas": r.get("notas") or ""})
    return out


def _rect_escalera(e, margen=0.0):
    """Rectangulo (x, norte) de la escalera `e` (con `margen` en los cuatro lados)."""
    a, b = np.array([e["x1"], e["n1"]]), np.array([e["x2"], e["n2"]])
    t = (b - a) / np.linalg.norm(b - a)
    n = np.array([-t[1], t[0]])
    w = e["ancho"] / 2 + margen
    a2, b2 = a - t * margen, b + t * margen
    return Polygon([tuple(a2 - n * w), tuple(b2 - n * w), tuple(b2 + n * w), tuple(a2 + n * w)])


def huecos_escaleras(escs):
    """Zona (x, norte) donde se recortan los muros laterales de los pasillos: el rectangulo de cada escalera + 0,6 m."""
    gs = [_rect_escalera(e, ESCALERA_HUECO_M) for e in escs]
    return unary_union(gs) if gs else None


def _cota_suelo(T, p):
    """Cota de juego del suelo resuelto en el punto p (x, norte): el plano del pasillo cuya huella lo contiene (manda el de mayor
    prioridad; en el solape de zonas el terreno ya muestra el de mayor prioridad aunque el punto sea de otro pasillo), si no
    la del terreno."""
    pt = Point(float(p[0]), float(p[1]))
    donde = [i for i in getattr(T, "suelos", {}).values() if i["huella"].contains(pt)]
    if donde:
        return float(max(donde, key=lambda i: i["prioridad"])["y"](p[0], p[1]))
    return float(T.h(p[0], p[1]))


def preparar_escaleras(T, escs):
    """Calcula las escaleras (cota de arriba y de abajo = suelo resuelto en cada extremo, T.altura) y las registra en el
    terreno como RAMPA lisa (suelo inclinado f(s), plano horizontal fuera de los extremos), de modo que la colision del
    terreno es la rampa. Devuelve y guarda en T.escaleras la lista de dicts: id, a/b (x, norte) arriba/abajo, y1, y2, ancho,
    peldanos (N), alto (m), huella (m), longitud_m, angulo (grados), rect, t (vector unitario hacia abajo)."""
    T.escaleras = []
    if T.es_plano:
        return T.escaleras
    for e in escs:
        a, b = np.array([e["x1"], e["n1"]]), np.array([e["x2"], e["n2"]])
        L = float(np.linalg.norm(b - a))
        y1, y2 = _cota_suelo(T, a), _cota_suelo(T, b)
        dy = y1 - y2
        if dy < 0.3 or L < 0.5:
            print(f"AVISO: escalera {e['id']}: desnivel {dy:.2f} m sobre {L:.2f} m: se ignora", file=sys.stderr)
            continue
        N = max(1, round(dy / PELDANO_ALTO))
        t = (b - a) / L
        d = dict(e, a=a, b=b, y1=y1, y2=y2, longitud_m=L, peldanos=N, alto=dy / N, huella=L / N, t=t,
                 angulo=math.degrees(math.atan2(dy, L)), rect=_rect_escalera(e))

        def rampa(x, n, a=a, t=t, L=L, y1=y1, dy=dy):
            s = np.clip((np.asarray(x) - a[0]) * t[0] + (np.asarray(n) - a[1]) * t[1], 0.0, L)
            return y1 - s * dy / L
        d["rampa"] = rampa
        T.escaleras.append(d)
    for d in T.escaleras:    # despues de leer todos los extremos (los registros modifican el terreno)
        T.anadir_suelo(d["rect"].buffer(SUELO_BORDE_M), d["rampa"], None, SUELO_TRANSICION_M)
    return T.escaleras


def mallas_escaleras(escs):
    """(peldanos, rampa, muros) de las escaleras: peldanos = cajas macizas de N peldanos (sin colision; su cara superior
    sigue la rampa +-media contrahuella), rampa = prisma inclinado liso de 0,3 m (la colision; invisible), muros = muros
    laterales de 0,2 m con barandilla (1 m sobre la rampa). Cada uno es un Trimesh en (x, norte, z) o None."""
    pel, ram, mur = [], [], []
    for d in escs:
        a, t, L, w, N, h, y1, dy = d["a"], d["t"], d["longitud_m"], d["ancho"], d["peldanos"], d["alto"], d["y1"], d["y1"] - d["y2"]
        r = L / N
        n = np.array([-t[1], t[0]])
        for k in range(N):
            s0, s1 = k * r, (k + 1) * r
            xy = np.array([a + t * s0 - n * w / 2, a + t * s1 - n * w / 2, a + t * s1 + n * w / 2, a + t * s0 + n * w / 2])
            top = y1 - (k + 0.5) * h
            base = y1 - s1 * dy / L - 0.1
            pel.append((xy, np.full(4, base), np.full(4, top)))
        xy = np.array([a - n * w / 2, a + t * L - n * w / 2, a + t * L + n * w / 2, a + n * w / 2])
        zt = np.array([y1, d["y2"], d["y2"], y1])
        ram.append((xy, zt - 0.3, zt))
        for sg in (-1, 1):                                  # muros laterales a cada lado, por peldano
            for k in range(N):
                s0, s1 = k * r, (k + 1) * r
                c0, c1 = a + t * s0 + n * sg * (w / 2 + ESCALERA_MURO_GROSOR / 2), a + t * s1 + n * sg * (w / 2 + ESCALERA_MURO_GROSOR / 2)
                ya, yb = y1 - s0 * dy / L, y1 - s1 * dy / L
                xyk, _, _ = _caja_segmento(c0, c1, ESCALERA_MURO_GROSOR, 0.0, 0.0, ext=0.02)
                mur.append((xyk, np.full(4, yb - 0.6), np.full(4, ya + ESCALERA_MURO_ALTO)))
    return (_hexaedros(pel) if pel else None, _hexaedros(ram) if ram else None, _hexaedros(mur) if mur else None)


def eje_geodesico(poly, inicio, paso=0.5, tramo=2.0, camino=False, fin=None):
    """Linea central aproximada [(x, norte)] de una banda larga y estrecha (puede ser curva): distancia geodesica por
    una rejilla de `paso` m dentro de `poly` desde el pixel mas cercano a `inicio`; cada `tramo` m de distancia, el
    centroide de los pixeles de esa franja. Devuelve (puntos, distancia_geodesica_total). Con camino=True devuelve en cambio
    el camino mas corto (cada `tramo` m) desde `inicio` hasta el pixel mas lejano (o el mas cercano a `fin`), que siempre
    queda dentro de `poly`."""
    import heapq
    x0, y0, x1, y1 = poly.bounds
    xs, ys = np.arange(x0 + paso / 2, x1, paso), np.arange(y0 + paso / 2, y1, paso)
    X, Y = np.meshgrid(xs, ys)
    dentro = shapely.contains_xy(poly, X.ravel(), Y.ravel()).reshape(X.shape)
    idx = np.argwhere(dentro)
    k0 = idx[np.argmin(np.hypot(X[dentro] - inicio[0], Y[dentro] - inicio[1]))]
    dist = np.full(X.shape, np.inf)
    previo = {}
    dist[tuple(k0)] = 0.0
    cola = [(0.0, int(k0[0]), int(k0[1]))]
    vec = [(di, dj, math.hypot(di, dj) * paso) for di in (-1, 0, 1) for dj in (-1, 0, 1) if (di or dj)]
    while cola:
        d, i, j = heapq.heappop(cola)
        if d > dist[i, j]:
            continue
        for di, dj, w in vec:
            a, b = i + di, j + dj
            if 0 <= a < X.shape[0] and 0 <= b < X.shape[1] and dentro[a, b] and d + w < dist[a, b]:
                dist[a, b] = d + w
                previo[(a, b)] = (i, j)
                heapq.heappush(cola, (d + w, a, b))
    lejos = dist[dentro & np.isfinite(dist)].max()
    if camino:
        if fin is None:
            k = np.unravel_index(np.argmax(np.where(np.isfinite(dist), dist, -1.0)), dist.shape)
        else:
            k = np.unravel_index(np.argmin(np.where(np.isfinite(dist), np.hypot(X - fin[0], Y - fin[1]), np.inf)), dist.shape)
        ruta = [(int(k[0]), int(k[1]))]
        while ruta[-1] in previo:
            ruta.append(previo[ruta[-1]])
        ruta = ruta[::-1]
        paso_px = max(1, int(round(tramo / paso)))
        sel = ruta[::paso_px] + ([ruta[-1]] if (len(ruta) - 1) % paso_px else [])
        return [(float(X[i, j]), float(Y[i, j])) for i, j in sel], float(dist[k])
    pts = []
    for d0 in np.arange(0.0, lejos + tramo, tramo):
        m = dentro & (np.abs(dist - d0) <= tramo / 2)
        if m.any():
            pts.append((float(X[m].mean()), float(Y[m].mean())))
    return pts, float(lejos)


def losa_eje(info, huella, lidar, T, grosor):
    """Losa de un pasillo con suelo=eje: cara inferior = suelo(s) + galibo, sin inclinacion lateral. galibo = mediana LiDAR
    (mdt + ndsm - suelo - grosor) acotada entre GALIBO_EJE_MIN y GALIBO_EJE_MAX."""
    px, py, pz = lidar.pixeles(huella)
    g_med = float(np.median(pz - T.cota_ref - info["y"](px, py) - grosor)) if len(px) >= LOSA_MIN_PIXELES else GALIBO_EJE_MAX
    g = float(np.clip(g_med, GALIBO_EJE_MIN, GALIBO_EJE_MAX))
    ftop = lambda x, y, g=g: info["y"](x, y) + g + grosor
    return {"nivel": "eje", "plano": None, "cota_abs": None, "n_px": len(px), "ftop": ftop, "galibo": (g, g, g),
            "galibo_lidar": (g_med, g_med, g_med),
            "origen": f"siguiendo el suelo(s) del eje + galibo {g:.2f} m (mediana lidar {g_med:.2f} m, {len(px)} px)"}


def losa_sobre_suelo(losa, suelo, huella, grosor):
    """Galibo de la losa inclinada sobre el suelo aplanado: si la losa del LiDAR deja < GALIBO_MIN_M en algun punto de
    la huella, se sustituye por una losa paralela al suelo con galibo max(GALIBO_PARALELA_M, mediana del galibo
    LiDAR si es holgado). Anota losa['galibo'] = (min, mediana, max) y losa['galibo_lidar']."""
    if losa["plano"] is None or losa["nivel"] != "inclinado" or suelo is None or suelo.get("plano") is None:
        return losa
    px, pn = _muestras_xy(huella, 1.0)
    sa, sb, sc = suelo["plano"]
    a, b, c = losa["plano"]
    gal = (a * px + b * pn + c - grosor) - (sa * px + sb * pn + sc)
    losa["galibo_lidar"] = (float(gal.min()), float(np.median(gal)), float(gal.max()))
    if gal.min() < GALIBO_MIN_M:
        med = float(np.median(gal))
        g = max(GALIBO_PARALELA_M, med if med > GALIBO_MIN_M + 1.0 else 0.0)
        losa["plano"] = (sa, sb, sc + g + grosor)
        losa["origen"] = (f"paralela al suelo, galibo {g:.1f} m (el ajuste lidar daba un galibo minimo de "
                          f"{gal.min():.2f} m < {GALIBO_MIN_M} m)")
        losa["galibo"] = (g, g, g)
        losa["n_px"] = 0
    else:
        losa["galibo"] = losa["galibo_lidar"]
    return losa


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


def partir_por_pasos(huella, base, top, pasos, etiqueta="", ref=0.0):
    """Divide la huella de un edificio volumen con los pasos. Devuelve (mesh|None, n_pasos_aplicados).
    (huella - paso) se extruye entera; (huella ∩ paso) solo de galibo a top (soportal); sin
    galibo (o galibo >= top) el paso queda abierto al cielo. Si queda partida en varios
    poligonos se descartan los fragmentos sueltos (ver filtrar_fragmentos) y se informa.
    base, top y `ref` son cotas de juego; el galibo se mide desde `ref` (cota media del terreno bajo la huella)."""
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
        if g is not None and g > 0 and ref + g < top - 0.05:
            z0 = max(ref + g, base)
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
def malla_tunel(huella, forma, base, losa_bot, losa_top, T):
    """Edificio-tunel: losa sobre toda la huella (cara inferior losa_bot(x, y), superior losa_top(x, y), alturas de
    juego absolutas) + paredes de 0,3 m hacia dentro, del terreno (- ENTERRADO_LINEAL) a la cara inferior de la
    losa, solo en los lados paralelos al eje (tunel_z: |dnorte| > |deste|, o sea caras este/oeste; tunel_x: al
    reves). base: altura relativa al terreno donde empiezan las paredes (0 = en el suelo).
    Devuelve (mesh, poligono_paredes)."""
    ent = 0.0 if T.es_plano else ENTERRADO_LINEAL
    ms = [prisma_drapeado(huella, losa_bot, losa_top, T)]
    paredes = []
    for p in validos(huella):
        c = list(p.exterior.coords)
        for a, b in zip(c[:-1], c[1:]):
            dx, dy = abs(b[0] - a[0]), abs(b[1] - a[1])
            if (dy > dx) if forma == "tunel_z" else (dx > dy):
                paredes.append(LineString([a, b]).buffer(GROSOR_PARED_TUNEL, cap_style="flat").intersection(p))
    muros = unary_union(paredes) if paredes else None
    if muros is not None:
        mxy = np.vstack([np.asarray(p.exterior.coords) for p in validos(muros)])
        mx, my = mxy[:, 0], mxy[:, 1]
        if (losa_bot(mx, my) - T.h(mx, my) - base).max() > 0.05:
            off = base - ent if base <= 0.05 else base
            m = prisma_drapeado(muros, lambda x, y: T.h(x, y) + off, losa_bot, T)
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


def malla_pilares(centros, losa_bot, T):
    """Pilares de 0,4 x 0,4 m desde el terreno (- ENTERRADO_LINEAL) hasta la cara inferior de la losa
    (losa_bot(x, y), cota de juego; entran EMPOTRADO_PILAR en la losa). Se omiten los que no tienen hueco
    (terreno a menos de 0,05 m de la losa). Devuelve (mesh, centros construidos)."""
    ent, emp = (0.0, 0.0) if T.es_plano else (ENTERRADO_LINEAL, EMPOTRADO_PILAR)
    ms, usados = [], []
    for x, y in centros:
        h = float(T.h(x, y))
        zb, zt = h - ent, float(losa_bot(x, y)) + emp
        if zt - emp - h < 0.05:
            continue
        m = trimesh.creation.box(extents=[PILAR_LADO, PILAR_LADO, zt - zb])
        m.apply_translation([x, y, (zb + zt) / 2])
        ms.append(m)
        usados.append((x, y))
    return (trimesh.util.concatenate(ms) if ms else None), usados


# ---------------------------------------------------------------- construccion
def campus_local(mapa):
    """Poligono del contorno del campus en el plano local (x = este, y = norte)."""
    return validos(mapa.poligono(mapa.ways[CAMPUS_ID]))[0]


def construir(mapa, filas, pasos=(), pistas=(), T=None, lidar=None):
    """Piezas del blockout sobre el terreno T (Terreno.plano() por defecto). La malla del terreno (y la densificacion
    de todo lo que se apoya en el) la fija T: ver Terreno.definir_zona_fina."""
    if T is None:
        T = ter.Terreno.plano()
    if lidar is None:
        lidar = Lidar(ter.MDT_DEFECTO, NDSM_DEFECTO, mapa.E0, mapa.N0)
    ent_e = 0.0 if T.es_plano else ZOCALO_EDIFICIO
    ent_l = 0.0 if T.es_plano else ENTERRADO_LINEAL
    campus = campus_local(mapa)
    minx, miny, maxx, maxy = campus.bounds
    caja_suelo = box(minx - MARGEN_SUELO, miny - MARGEN_SUELO, maxx + MARGEN_SUELO, maxy + MARGEN_SUELO)
    zona_caminos = campus.buffer(MARGEN_CAMINOS)

    piezas = []  # (nombre_nodo, mesh_local, clave_material)
    stats = Counter()
    edif_info = []  # para preview

    # Terreno (rejilla regular con colision)
    piezas.append(("terreno-col", malla_terreno(caja_suelo, T), "suelo"))

    # Edificios
    techos = []  # (info, es_roof)
    for wid, w in sorted(mapa.ways.items()):
        t = w.get("tags", {})
        if not (("building" in t or t.get("man_made") == "tower") and mapa.cerrado(w)):
            continue
        fila = filas[str(wid)]
        forma = forma_de(fila)
        if forma == "excluir":
            stats["edificios_excluidos"] += 1
            continue
        alt, base = resolver(fila)
        polys = validos(mapa.poligono(w))
        huella = unary_union(polys) if polys else None
        es_roof = t.get("building") == "roof"
        nombre = fila.get("nombre") or t.get("name", "")
        muros_tunel = None
        hs = muestras_huella(huella, T) if huella is not None else np.zeros(1)
        h_min, h_med, h_max = float(hs.min()), float(hs.mean()), float(hs.max())
        y_base = y_top = None
        losa = None
        if forma in ("techo", "tunel_z", "tunel_x"):
            top, grosor = altura_cubierta(fila, forma, es_roof)
            if huella is not None:
                px_, py_ = _muestras_xy(huella)
                losa = calcular_losa(wid, fila, huella, top, T, lidar, px_, py_)
                suelo_i = getattr(T, "suelos", {}).get(wid)
                if suelo_i is not None and suelo_i["modo"] == "eje":
                    losa = losa_eje(suelo_i, huella, lidar, T, grosor)
                elif suelo_i is not None:
                    losa_sobre_suelo(losa, suelo_i, huella, grosor)
                anotar_losa(fila, losa, T)
                plano_ = losa["plano"]
                if losa.get("ftop") is not None:
                    ftop = losa["ftop"]
                elif plano_ is None:      # sigue el terreno
                    ftop = lambda x, y, top=top: T.h(x, y) + top
                else:
                    ftop = lambda x, y, p=plano_: p[0] * np.asarray(x) + p[1] * np.asarray(y) + p[2]
                fbot = lambda x, y, ftop=ftop, g=grosor: ftop(x, y) - g
                losa.update(top=ftop, bot=fbot, grosor=grosor)
                exceso = float((T.h(px_, py_) - fbot(px_, py_)).max())
                losa["terreno_sobre_m"] = max(exceso, 0.0)
                if exceso > 0.05:
                    stats["techos_terreno_sobre_losa"] += 1
                    print(f"AVISO: {wid} {nombre[:30]}: el terreno sobresale {exceso:.2f} m por encima de la cara "
                          f"inferior de la losa ({losa['nivel']})", file=sys.stderr)
                stats["losas_" + losa["nivel"]] += 1
                if forma == "techo":
                    m = prisma_drapeado(huella, fbot, ftop, T)
                else:
                    m, muros_tunel = malla_tunel(huella, forma, base, fbot, ftop, T)
            else:
                m = None
        else:
            # volumen: base = cota minima bajo la huella - zocalo; cubierta = cota media + altura
            top = alt + base
            y_base = h_min - ent_e if base <= 0.05 else h_med + base
            y_top = h_med + top
            if pasos and huella is not None:
                m, n = partir_por_pasos(huella, y_base, y_top, pasos, f"{wid} {nombre}"[:40], ref=h_med)
                if n:
                    stats["edificios_partidos"] += 1
            else:
                m = extruir(huella, y_top - y_base, y_base)
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
                "muros": muros_tunel, "h_min": h_min, "h_med": h_med, "h_max": h_max,
                "y_base": y_base, "y_top": y_top, "losa": losa}
        edif_info.append(info)
        if forma == "techo":
            techos.append((info, es_roof))

    # Pilares de los techos
    escaleras = getattr(T, "escaleras", [])
    hueco_esc = unary_union([_rect_escalera(d, 0.8) for d in escaleras]) if escaleras else None
    volumenes = unary_union([e["poly"] for e in edif_info if e["forma"] == "volumen"])
    for info, es_roof in techos:
        poly = info["poly"]
        if es_roof and poly.area > 0 and poly.intersection(volumenes).area / poly.area > 0.5:
            stats["techos_sin_pilares_sobre_edificio"] += 1
            continue
        modo = modo_pilares(filas[str(info["id"])])
        if modo == "ninguno":
            continue
        centros = pilares_techo(poly, 0.0, volumenes, modo)
        if hueco_esc is not None:      # sin pilares en la escalera
            centros = [c_ for c_ in centros if not hueco_esc.contains(Point(*c_))]
        m, centros = malla_pilares(centros, info["losa"]["bot"], T)
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
    suelos = getattr(T, "suelos", {})
    geom_pav = None
    if suelos:   # pavimento blanco de los pasillos: huellas con suelo=plano menos los edificios volumen
        geom_pav = unary_union([i["huella"] for i in suelos.values()]).difference(volumenes)
    for hw, bufs in por_tipo.items():
        g = unary_union(bufs).intersection(zona_caminos)
        if geom_pav is not None and not geom_pav.is_empty:
            g = g.difference(geom_pav)     # los caminos (+3 cm) taparian el pavimento (+2 cm)
        caminos_geom[hw] = g
        m = plano_drapeado(g, T, 0.03)
        if m is not None:
            clave = "camino_asfalto" if hw in ASFALTO else "camino_peatonal"
            piezas.append((f"caminos_{hw}", m, clave))
            stats["caminos_" + hw] = len(bufs)

    # Suelo de los pasillos: pavimento blanco (sin colision: la da el terreno aplanado) y muros laterales (con colision)
    if geom_pav is not None and not geom_pav.is_empty:
        m = plano_drapeado(geom_pav, T, SUELO_PAVIMENTO_Y)
        if m is not None:
            piezas.append(("suelo_pasillos", m, "pavimento_blanco"))
        mm = malla_muros_suelo(suelos)
        if mm is not None:
            piezas.append(("muros_suelo-col", mm, "muros"))
        stats["suelos_pasillo"] = len(suelos)
        stats["muros_suelo_m"] = round(sum(i["long_muros_m"] for i in suelos.values()))

    # Escaleras: peldanos visibles (sin colision), rampa lisa invisible (colision) y muros laterales
    if escaleras:
        m_pel, m_ram, m_mur = mallas_escaleras(escaleras)
        for nombre, m_, clave in (("escaleras", m_pel, "pavimento_blanco"), ("escaleras_rampa-col", m_ram, "pavimento_blanco"),
                                  ("escaleras_muros-col", m_mur, "muros")):
            if m_ is not None:
                piezas.append((nombre, m_, clave))
        stats["escaleras"] = len(escaleras)
        stats["peldanos"] = sum(d["peldanos"] for d in escaleras)

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
        m = plano_drapeado(g, T, y)
        if m is not None:
            piezas.append((f"zona_{cat}", m, cat))
            stats["zonas_" + cat] = len(cats[cat])

    def sobre_terreno(geom, altura):
        """Prisma cuya base sigue el terreno (- ENTERRADO_LINEAL) y cuya cara superior esta a terreno + altura."""
        return prisma_drapeado(geom, lambda x, y: T.h(x, y) - ent_l, lambda x, y: T.h(x, y) + altura, T)

    # Muros y vallas
    for nombre, valor, grosor, h, clave in (("muros-col", "retaining_wall", 0.15, 1.2, "muros"),
                                            ("vallas-col", "fence", 0.05, 1.8, "vallas")):
        bufs = []
        for w in mapa.ways.values():
            if w.get("tags", {}).get("barrier") == valor:
                l = mapa.linea(w)
                if l is not None:
                    bufs.append(l.buffer(grosor, cap_style="flat", join_style="mitre"))
        m = sobre_terreno(unary_union(bufs), h) if bufs else None
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
        m = sobre_terreno(cerramiento_pista(poly, GROSOR_CERRAMIENTO), pi["altura"])
        if m is not None:
            mallas_padel.append(m)
        pistas_info.append({"id": pi["id"], "nombre": pi["nombre"], "poly": poly})
    if mallas_padel:
        piezas.append(("padel-col", trimesh.util.concatenate(mallas_padel), "cristal_padel"))
        stats["pistas_padel"] = len(mallas_padel)

    # Limite del mapa
    ext = campus.buffer(MARGEN_LIMITE)
    anillo = ext.exterior.buffer(0.25, join_style="mitre")
    piezas.append(("limite-col", sobre_terreno(anillo, 6.0), "limite"))
    piezas.extend(valla_perimetral(campus, T))

    return piezas, stats, {"campus": campus, "edificios": edif_info, "caminos": caminos_geom,
                           "zonas": zonas_geom, "suelo": caja_suelo, "pasos": list(pasos), "pistas": pistas_info,
                           "terreno": T, "suelos": suelos, "escaleras": escaleras}


# ---------------------------------------------------------------- bordes del campus
def valla_perimetral(campus, T):
    """Valla metalica de 2 m: postes de 10 cm cada 3 m (`valla_perimetral`, material valla_metal) y un panel de malla
    semitransparente (`valla_perimetral_malla`). Va VALLA_INTERIOR m por dentro del muro limite (a MARGEN_LIMITE del
    contorno): el limite tiene la colision y la valla es solo visual, asi el jugador ve el borde justo donde topa.
    Devuelve [(nombre, mesh_local, clave)]."""
    zona = campus.buffer(MARGEN_LIMITE - VALLA_INTERIOR, join_style="round")
    if zona.geom_type == "MultiPolygon":
        zona = max(zona.geoms, key=lambda g: g.area)
    linea = LineString(zona.exterior.coords)
    n = int(math.ceil(linea.length / VALLA_POSTE_SEP))
    pts = np.array([linea.interpolate(i * linea.length / n).coords[0] for i in range(n)])
    h0 = T.h(pts[:, 0], pts[:, 1])
    caja = trimesh.creation.box(extents=(VALLA_POSTE_LADO, VALLA_POSTE_LADO, 1.0))
    alto = VALLA_ALTURA + ENTERRADO_LINEAL
    v = np.asarray(caja.vertices)
    verts, caras = [], []
    for i in range(n):
        w = v.copy()
        w[:, 2] = (w[:, 2] + 0.5) * alto + h0[i] - ENTERRADO_LINEAL
        w[:, 0] += pts[i, 0]
        w[:, 1] += pts[i, 1]
        verts.append(w)
        caras.append(np.asarray(caja.faces) + i * len(v))
    postes = trimesh.Trimesh(np.vstack(verts), np.vstack(caras), process=False)
    banda = linea.buffer(0.03, cap_style="flat", join_style="mitre")
    panel = prisma_drapeado(banda, lambda x, y: T.h(x, y) - ENTERRADO_LINEAL, lambda x, y: T.h(x, y) + VALLA_ALTURA - 0.1, T)
    out = [("valla_perimetral", postes, "valla_metal")]
    if panel is not None:
        out.append(("valla_perimetral_malla", panel, "valla_malla"))
    return out


def faldon_exterior(T, caja):
    """Anillo de terreno SIN colision alrededor de `caja` (x0, norte0, x1, norte1; el borde de la malla del terreno).
    Se extiende FALDON_EXTENSION m; cada vertice toma la cota del punto mas cercano del borde (T.h) menos una caida suave
    (FALDON_CAIDA * distancia) y una ondulacion de baja frecuencia que crece con la distancia. Mesh local (x, norte, z)."""
    x0, y0, x1, y1 = caja
    ds = np.array(FALDON_ANILLOS[1:])
    dentro = lambda a, b: np.arange(a, b + 1e-6, FALDON_PASO)
    xs = np.concatenate([x0 - ds[::-1], dentro(x0, x1), x1 + ds])
    ys = np.concatenate([y0 - ds[::-1], dentro(y0, y1), y1 + ds])
    X, Y = np.meshgrid(xs, ys)
    dx = np.maximum(np.maximum(x0 - X, X - x1), 0)
    dy = np.maximum(np.maximum(y0 - Y, Y - y1), 0)
    d = np.hypot(dx, dy)
    base = T.h(np.clip(X, x0, x1), np.clip(Y, y0, y1))
    ondas = 0.5 * (np.sin(X / 170.0 + 0.7) + np.sin(Y / 230.0 + 2.0) + np.sin((X + Y) / 310.0))
    amp = np.clip(d / 300.0, 0.0, 1.0)
    Z = base - FALDON_CAIDA * d + 2.5 * ondas * amp - 0.05 * (d == 0)
    ny, nx = X.shape
    idx = np.arange(nx * ny).reshape(ny, nx)
    a, b, c, e = idx[:-1, :-1], idx[:-1, 1:], idx[1:, 1:], idx[1:, :-1]
    xc = (xs[:-1] + xs[1:]) / 2
    yc = (ys[:-1] + ys[1:]) / 2
    XC, YC = np.meshgrid(xc, yc)
    fuera = ~((XC > x0) & (XC < x1) & (YC > y0) & (YC < y1))     # se descarta el interior (lo cubre el terreno)
    a, b, c, e = a[fuera], b[fuera], c[fuera], e[fuera]
    caras = np.vstack([np.column_stack([a, b, c]), np.column_stack([a, c, e])])
    verts = np.column_stack([X.ravel(), Y.ravel(), Z.ravel()])
    m = trimesh.Trimesh(verts, caras, process=False)
    m.remove_unreferenced_vertices()
    return m


# ---------------------------------------------------------------- vegetacion y coches
def anadir_argumentos_props(ap):
    """Opciones de arboles y coches (las comparten generar_blockout.py y generar_spawns.py: usa las mismas)."""
    ap.add_argument("--ndsm-veg", default=NDSM_VEG_DEFECTO, help="nDSM de vegetacion LiDAR de 1 m")
    ap.add_argument("--sin-arboles", action="store_true", help="no genera arboles")
    ap.add_argument("--sin-coches", action="store_true", help="no genera coches")
    ap.add_argument("--ocupacion", type=float, default=0.55, help="fraccion de plazas de aparcamiento ocupadas (0.55)")
    ap.add_argument("--coches-carretera", type=int, default=15, help="coches aparcados en carreteras (15)")
    ap.add_argument("--semilla", type=int, default=1, help="semilla del azar (tonos, ocupacion, colores, jitter)")
    ap.add_argument("--altura-min-arbol", type=float, default=veg.ALT_MIN_M, help="altura minima de un arbol (m)")
    ap.add_argument("--sep-arboles", type=float, default=veg.SEP_MIN_M, help="separacion minima entre troncos (m)")
    ap.add_argument("--zonas", default=dz.ZONAS_FUENTE, help="zonas competitivas (data/zonas.json): sus limites y barreras "
                    "excluyen arboles y coches; dentro, los arboles altos tienen tronco grueso")
    ap.add_argument("--props", default=dz.PROPS_CSV, help="coberturas (data/props.csv); vacio o inexistente = ninguna")
    ap.add_argument("--altura-tronco-grande", type=float, default=veg.ALT_TRONCO_GRANDE_M,
                    help="en las zonas, altura (m) desde la que un arbol tiene tronco de 0,5-0,7 m de radio (12)")


def construir_props(mapa, geo, a, spawns_json=SPAWNS_JSON, spawns=None):
    """Arboles y coches sobre el terreno de `geo`. `spawns`: lista de (x, norte) a evitar; por defecto los de
    game/data/spawns.json (si no existe, ninguno). Devuelve dict con `entorno`, `arboles`, `coches`, `piezas`,
    `stats` y `huella` (hash de las posiciones: generar_spawns.py comprueba que coincide con el blockout)."""
    import hashlib
    if spawns is None:
        spawns = ent.leer_spawns(spawns_json)
    zonas = dz.zonas_local(dz.leer_zonas(a.zonas))
    filas_props = dz.leer_props(a.props)
    huellas_props = [prp.huella(p) for p in filas_props]
    claros = [Point(p["x"], -p["z"]).buffer(float(prp.parse_notas(p["notas"])["claro"]), 24)
              for p in filas_props if "claro" in prp.parse_notas(p["notas"])]
    entorno = ent.Entorno(mapa, geo, spawns, MARGEN_LIMITE, zonas, huellas_props, claros)
    piezas, stats, arboles, lista = [], {}, [], []
    if filas_props:
        piezas.extend(prp.piezas_props(filas_props, geo["terreno"]))
        stats["props"] = len(filas_props)
        for tipo in prp.TIPOS:
            n_t = sum(1 for p in filas_props if p["tipo"] == tipo)
            if n_t:
                stats["props_" + tipo] = n_t
    if not a.sin_arboles:
        rng = np.random.default_rng([a.semilla, 1])
        arboles, st = veg.generar_arboles(entorno, a.ndsm_veg, mapa.E0, mapa.N0, rng, a.altura_min_arbol, a.sep_arboles,
                                          a.altura_tronco_grande)
        stats.update({"arboles_" + k: v for k, v in st.items()})
        piezas.extend(veg.piezas_arboles(arboles))
    if not a.sin_coches:
        rng = np.random.default_rng([a.semilla, 2])
        lista, st = coc.generar_coches(mapa, entorno, arboles, rng, a.ocupacion, a.coches_carretera)
        prohibido = entorno.prohibido_coche()
        if prohibido is not None:     # ningun coche cruza un limite de zona ni una barrera ni se solapa con un prop
            n0 = len(lista)
            lista = [c for c in lista if not prohibido.intersects(coc.rect_coche(c))]
            n_p = sum(1 for c in lista if c["plaza"])
            st = {**st, "coches_zona_excluidos": n0 - len(lista), "coches": len(lista), "coches_parking": n_p,
                  "coches_carretera": len(lista) - n_p}
        stats.update(st)
        piezas.extend(coc.piezas_coches(lista))
    h = hashlib.sha1()
    for t in arboles:
        h.update(f"{t['x']:.2f},{t['y']:.2f},{t['h']:.1f},{t['r_tronco']:.2f};".encode())
    for p in filas_props:
        h.update(f"{p['tipo']},{p['x']:.2f},{p['z']:.2f},{p['yaw']:.1f},{p['escala']:g},{p['notas']};".encode())
    for c in lista:
        h.update(f"{c['pos']},{c['yaw_deg']};".encode())
    return {"entorno": entorno, "arboles": arboles, "coches": lista, "piezas": piezas, "stats": stats,
            "props": filas_props, "huellas_props": huellas_props, "zonas": zonas, "huella": h.hexdigest()[:16]}


def dibujar_props(ax, props):
    """Arboles (circulos verdes translucidos del radio de copa) y coches (rectangulos) en la vista cenital."""
    from matplotlib.collections import PatchCollection
    from matplotlib.patches import Circle, Polygon as MPoly
    arb = props["arboles"]
    if arb:
        ax.add_collection(PatchCollection([Circle((t["x"], t["y"]), t["r_copa"]) for t in arb],
                                          facecolor=(0.1, 0.5, 0.15, 0.35), edgecolor=(0.05, 0.3, 0.08, 0.6),
                                          linewidth=0.3, zorder=3.5))
    if props["coches"]:
        rs = [coc.rect_coche(c) for c in props["coches"]]
        cols = [tuple(v / 255 for v in coc.COLORES[c["color"]][0]) for c in props["coches"]]
        ax.add_collection(PatchCollection([MPoly(np.asarray(r.exterior.coords)[:-1]) for r in rs], facecolor=cols,
                                          edgecolor="black", linewidth=0.4, zorder=4.5))


def zoom_aparcamiento(ruta, geo, mapa, props, nombre="P11", margen=12.0):
    """Vista cenital ampliada de un aparcamiento (por `ref`) con sus coches y los arboles de alrededor."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import PathPatch
    from matplotlib.path import Path as MPath
    w = next((w for w in mapa.ways.values() if w.get("tags", {}).get("amenity") == "parking"
              and coc._nombre_parking(w) == nombre), None)
    if w is None:
        print(f"AVISO: no hay aparcamiento {nombre}; no se genera {ruta}", file=sys.stderr)
        return
    poly = mapa.poligono(w)
    x0, y0, x1, y1 = poly.buffer(margen).bounds
    ventana = box(x0, y0, x1, y1)
    fig, ax = plt.subplots(figsize=(15, 15 * (y1 - y0) / (x1 - x0)), dpi=100)
    ax.add_patch(plt.Rectangle((x0, y0), x1 - x0, y1 - y0, fc="#e9e1cf", ec="none"))
    col_z = {"verde": "#a8d08d", "agua": "#7fb2e0", "pista": "#d98a73", "aparcamiento": "#bdbdbd"}

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

    for cat, g in geo["zonas"].items():
        for p in parche(g.intersection(ventana), fc=col_z[cat], ec="none", zorder=1):
            ax.add_patch(p)
    for hw, g in geo["caminos"].items():
        for p in parche(g.intersection(ventana), fc="#555555" if hw in ASFALTO else "#b5b5b5", ec="none", zorder=2):
            ax.add_patch(p)
    for e in geo["edificios"]:
        if e["poly"].intersects(ventana):
            kw = dict(fc="#c8c8cd", ec="black", lw=0.8, zorder=3)
            if e["forma"] == "techo":
                kw.update(fc="#555860", alpha=0.5, hatch="//")
            for p in parche(e["poly"], **kw):
                ax.add_patch(p)
            for px, py in e["pilares"]:
                ax.plot(px, py, "s", color="#222222", ms=3, zorder=4)
    for p in parche(poly, fc="none", ec="red", lw=1.5, ls="--", zorder=4):
        ax.add_patch(p)
    dibujar_props(ax, {**props,
                       "arboles": [t for t in props["arboles"] if ventana.contains(Point(t["x"], t["y"]))],
                       "coches": [c for c in props["coches"] if ventana.contains(Point(c["pos"][0], -c["pos"][2]))]})
    ax.set_xlim(x0, x1)
    ax.set_ylim(y0, y1)
    ax.set_aspect("equal")
    ax.grid(alpha=0.25)
    n_c = sum(1 for c in props["coches"] if c["origen"] == f"parking {nombre}")
    ax.set_title(f"Aparcamiento {nombre}: {n_c} coches (norte arriba); verde = copas, rojo discontinuo = contorno OSM")
    fig.tight_layout()
    fig.savefig(ruta)
    plt.close(fig)
    print(f"Zoom: {ruta}")


def guardar_coches(ruta, props, a):
    Path(ruta).write_text(json.dumps(
        {"ejes": "x=este, y=arriba, z=-norte (metros); yaw_deg = rotacion Y de Godot (0 = morro hacia -Z = norte); "
                 "pitch/roll = inclinacion segun el terreno; pos = centro del coche a nivel del suelo",
         "semilla": a.semilla, "ocupacion": a.ocupacion, "coches_carretera": a.coches_carretera,
         "coches": props["coches"]}, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"Coches: {ruta}")


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
    T = geo.get("terreno")
    if T is not None and not T.es_plano:  # curvas de nivel suaves cada 1 m (cota sobre el nivel del mar)
        gx = np.arange(suelo.bounds[0], suelo.bounds[2] + 2, 2.0)
        gy = np.arange(suelo.bounds[1], suelo.bounds[3] + 2, 2.0)
        GX, GY = np.meshgrid(gx, gy)
        cota = T.h(GX, GY) + T.cota_ref
        lv = np.arange(math.floor(cota.min()), math.ceil(cota.max()) + 1)
        ax.contour(GX, GY, cota, levels=lv, colors="#7a5c2e", linewidths=0.4, alpha=0.7, zorder=1.5)
        cs5 = ax.contour(GX, GY, cota, levels=[v for v in lv if v % 5 == 0], colors="#6b4a1a",
                         linewidths=0.8, alpha=0.8, zorder=1.6)
        ax.clabel(cs5, fmt="%d m", fontsize=7)
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
    ax.set_title("UPO blockout - vista cenital (norte arriba); color = altura de cubierta (m)"
                 + ("" if T is None or T.es_plano else "; curvas de nivel cada 1 m (cota s.n.m.)"))
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


def _perfil_techo(ax, sc, geo, edif_id, titulo, linea_y=None):
    """Dibuja en `ax` el perfil lateral del techo `edif_id` medido sobre la escena del .glb: plano vertical por el
    eje largo del techo; distancia a lo largo del eje frente a y (juego) con terreno, losa y pilares.
    linea_y: cota de juego de una recta de referencia (opcional). Devuelve el numero de pilares proyectados."""
    e = next((q for q in geo["edificios"] if q["id"] == edif_id), None)
    if e is None:
        return 0
    cs = list(e["poly"].minimum_rotated_rectangle.exterior.coords)
    l0, l1 = (cs[0], cs[1]) if math.dist(cs[0], cs[1]) > math.dist(cs[1], cs[2]) else (cs[1], cs[2])
    L = math.dist(l0, l1)
    d = np.array([(l1[0] - l0[0]) / L, 0.0, -(l1[1] - l0[1]) / L])      # eje en coordenadas del juego
    c = e["poly"].centroid
    o = np.array([c.x, 0.0, -c.y])
    n = np.array([-d[2], 0.0, d[0]])
    semiancho = min(math.dist(cs[0], cs[1]), math.dist(cs[1], cs[2])) / 2 + 1.0

    def geom(prefijo):
        return [sc.geometry[sc.graph[nm][1]] for nm in sc.graph.nodes_geometry if nm.startswith(prefijo)]

    def secciones(mesh):
        """Segmentos (s, y) de la interseccion de la malla con el plano vertical (sin scipy)."""
        v, f = mesh.vertices, mesh.faces
        dist = (v - o) @ n
        dist[dist == 0] = 1e-9
        a_, b_ = f, np.roll(f, -1, axis=1)
        da, db = dist[a_], dist[b_]
        cruza = (da > 0) != (db > 0)
        k = cruza.sum(1) == 2
        t = da[k] / (da[k] - db[k])
        P = v[a_[k]] + (v[b_[k]] - v[a_[k]]) * t[..., None]
        seg = P[cruza[k]].reshape(-1, 2, 3)
        return (seg - o) @ d, seg[:, :, 1]

    def envolvente(ss, yy, grid):
        """Cota minima y maxima de la seccion en cada s de la rejilla."""
        lo, hi = np.full(len(grid), np.inf), np.full(len(grid), -np.inf)
        for (s0, s1), (y0, y1) in zip(ss, yy):
            if s0 == s1:
                continue
            if s0 > s1:
                s0, s1, y0, y1 = s1, s0, y1, y0
            m = (grid >= s0) & (grid <= s1)
            y = y0 + (y1 - y0) * (grid[m] - s0) / (s1 - s0)
            lo[m], hi[m] = np.minimum(lo[m], y), np.maximum(hi[m], y)
        ok = np.isfinite(lo)
        return ok, lo, hi

    proy = np.array([(np.array([x, 0.0, -y]) - o) @ d for x, y in e["poly"].exterior.coords])
    grid = np.arange(proy.min() - 15, proy.max() + 15, 0.5)
    ok, lo, hi = envolvente(*secciones(geom("terreno")[0]), grid)
    ax.fill_between(grid[ok], hi[ok], hi[ok].min() - 3, color="#d9c9a3", zorder=1)
    ax.plot(grid[ok], hi[ok], color="#7a5c2e", lw=1.5, zorder=2, label="terreno (plano vertical por el eje)")
    for g in geom(f"edif_{edif_id}_"):
        ok, lo, hi = envolvente(*secciones(g), grid)
        ax.fill_between(grid[ok], lo[ok], hi[ok], color="#555860", zorder=3, label="losa (cara inferior a superior)")
    n_pil = 0
    for g in geom(f"pilares_{edif_id}_"):
        v = g.vertices
        for px, py in e["pilares"]:
            q = np.array([px, 0.0, -py])
            if abs((q - o) @ n) > semiancho:
                continue
            m = (np.abs(v[:, 0] - q[0]) < 0.25) & (np.abs(v[:, 2] - q[2]) < 0.25)
            if not m.any():
                continue
            s_ = float((q - o) @ d)
            ax.plot([s_, s_], [v[m, 1].min(), v[m, 1].max()], color="#b03030", lw=2.2, zorder=4,
                    label="pilares (proyectados)" if n_pil == 0 else None)
            n_pil += 1
    h, lab = ax.get_legend_handles_labels()
    ax.legend(dict(zip(lab, h)).values(), dict(zip(lab, h)).keys(), loc="upper right")
    if linea_y is not None:
        ax.axhline(linea_y[0], color="#1f77b4", ls="--", lw=1.2, label=linea_y[1])
    h, lab = ax.get_legend_handles_labels()
    ax.legend(dict(zip(lab, h)).values(), dict(zip(lab, h)).keys(), loc="upper right")
    ax.set_xlabel("distancia a lo largo del eje del techo (m)")
    ax.set_ylabel("y del juego (m)")
    ax.set_title(f"{titulo} (plano vertical por su eje; escala vertical exagerada); {n_pil} pilares proyectados")
    ax.grid(alpha=0.3)
    return n_pil


def perfil_pasillo(ruta, glb, geo, edif_id=1373541639):
    """Perfil lateral del techo `edif_id` (pasillo central, losa inclinada) medido sobre el .glb exportado."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    sc = trimesh.load(glb, force="scene")
    fig, ax = plt.subplots(figsize=(18, 6.5), dpi=100)
    _perfil_techo(ax, sc, geo, edif_id, f"Perfil del pasillo cubierto {edif_id}")
    fig.tight_layout()
    fig.savefig(ruta)
    plt.close(fig)
    print(f"Perfil: {ruta}")


def perfil_pasillo_18(ruta, geo, T, centro=(-12.0, 250.0), id_puente=ID_PUENTE_18):
    """Perfiles del puente macizo (marquesina `id_puente`, suelo=plano): longitudinal por su linea central y transversal en el
    cruce del cauce (la estacion con mas desnivel hacia el lado NO a < 40 m de `centro`). Terreno original (MDT 1 m, sin
    aplanar), suelo nuevo (la malla de terreno aplanada), pavimento, muros y losa; todo en cota s.n.m. Calculado con las
    mismas funciones que la malla (T.h, losa top/bot)."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle
    info = geo["suelos"].get(id_puente)
    e = next((q for q in geo["edificios"] if q["id"] == id_puente), None)
    if info is None or e is None:
        return
    ref = T.cota_ref
    esc = (geo.get("escaleras") or [None])[0]
    if esc is not None:      # ruta: 20 m de pasillo central -> escalera -> linea central de la marquesina
        top, bot, tt = esc["a"], esc["b"], esc["t"]
        zc = geo["suelos"][ID_PASILLO_CENTRAL]["huella"].intersection(Point(*top).buffer(45.0))
        eje_c, _ = eje_geodesico(zc, tuple(top))
        ini = eje_c[min(range(len(eje_c)), key=lambda k: abs(2.0 * k - 20.0))]
        t1, _ = eje_geodesico(zc.buffer(-1.2), ini, camino=True, fin=tuple(top - tt * 3.5))
        t3, _ = eje_geodesico(info["huella"].buffer(-1.2), tuple(bot), camino=True)
        P = np.array(t1 + [tuple(top - tt * 2.0), tuple(top), tuple(bot)] + t3)
        Proof = np.array(t3)
    else:
        eje, _ = eje_geodesico(info["huella"], info["huella"].exterior.coords[0])
        P = Proof = np.array(eje)
    s = np.concatenate([[0.0], np.cumsum(np.hypot(*np.diff(P, axis=0).T))])
    orig = lambda x, n: T.altura_base(x, -np.asarray(n)) + ref
    fig = plt.figure(figsize=(18, 11), dpi=100)
    ax = fig.add_subplot(2, 1, 1)
    ax.fill_between(s, orig(P[:, 0], P[:, 1]), 5, color="#e6dcc3", zorder=0)
    ax.plot(s, orig(P[:, 0], P[:, 1]), color="#7a5c2e", lw=1.6, label="terreno original (MDT 1 m, bajo la linea central)", zorder=2)
    ax.plot(s, T.h(P[:, 0], P[:, 1]) + ref, color="#1b7837", lw=2.2, label="suelo nuevo (terreno aplanado al plano)", zorder=4)
    ax.plot(s, T.h(P[:, 0], P[:, 1]) + ref + SUELO_PAVIMENTO_Y, color="#e8e6e0", lw=1.0, label="pavimento blanco (+2 cm)", zorder=5)
    bot, top = e["losa"]["bot"](P[:, 0], P[:, 1]) + ref, e["losa"]["top"](P[:, 0], P[:, 1]) + ref
    ax.fill_between(s, bot, top, color="#555860", zorder=3, label="losa (cara inferior a superior)")
    for pil in e["pilares"]:
        q = np.array(pil)
        k = int(np.argmin(np.hypot(P[:, 0] - q[0], P[:, 1] - q[1])))
        if math.dist(P[k], q) < 4.0:
            ax.plot([s[k], s[k]], [T.h(q[0], q[1]) + ref, e["losa"]["bot"](q[0], q[1]) + ref], color="#b03030", lw=1.6, zorder=3)
    primero = True
    for a_, b_, y0, y1 in info["muros"]:
        m = (a_ + b_) / 2
        k = int(np.argmin(np.hypot(P[:, 0] - m[0], P[:, 1] - m[1])))
        if math.dist(P[k], m) < 6.5:
            ax.vlines(s[k], y0 + ref, y1 + ref, color="#c07a2a", lw=1.2, alpha=0.55, zorder=6,
                      label="muros laterales (proyectados)" if primero else None)
            primero = False
    if esc is not None:
        k0 = int(np.argmin(np.hypot(P[:, 0] - esc["a"][0], P[:, 1] - esc["a"][1])))
        N_, h_ = esc["peldanos"], esc["alto"]
        sx, sy = [s[k0]], [esc["y1"] + ref]
        for k in range(N_):
            sx += [s[k0] + k * esc["huella"], s[k0] + (k + 1) * esc["huella"]]
            sy += [esc["y1"] + ref - (k + 0.5) * h_] * 2
        sx.append(s[k0] + esc["longitud_m"])
        sy.append(esc["y2"] + ref)
        ax.plot(sx, sy, color="#e08a00", lw=2.0, zorder=7, label=f"escalera {esc['id']}: {N_} peldaños de {h_:.2f} x {esc['huella']:.2f} m")
    ax.set_xlabel("distancia a lo largo de la ruta: pasillo central, escalera y linea central de la marquesina (m)")
    ax.set_ylabel("cota s.n.m. (m)")
    ax.set_ylim(min(orig(P[:, 0], P[:, 1]).min(), T.h(P[:, 0], P[:, 1]).min() + ref) - 1.0, top.max() + 1.5)
    gal = e["losa"].get("galibo")
    ax.set_title(f"Marquesina {id_puente} (puente macizo) y escalera de bajada: perfil longitudinal; plano del suelo {info['pendiente_grados']:.2f} grados, "
                 f"galibo {'%.1f-%.1f m' % (gal[0], gal[2]) if gal else '?'}; muros {info['long_muros_m']:.0f} m")
    ax.grid(alpha=0.3)
    ax.legend(loc="upper left", fontsize=8)
    # transversal en el cruce del cauce
    nw = np.array([-0.78, 0.62]) / math.hypot(0.78, 0.62)
    mejor = None
    for i in range(1, len(Proof) - 1):
        if math.dist(Proof[i], centro) > 40:
            continue
        t = Proof[i + 1] - Proof[i - 1]
        t /= np.linalg.norm(t)
        n = np.array([-t[1], t[0]])
        if n @ nw < 0:
            n = -n
        q7 = Proof[i] + n * 7.0
        h = float(T.h(*Proof[i])) - float(T.altura_base(q7[0], -q7[1]))
        if mejor is None or h > mejor[0]:
            mejor = (h, i, n)
    ax2 = fig.add_subplot(2, 1, 2)
    if mejor is not None:
        _, i, n = mejor
        p0 = Proof[i]
        o = np.arange(-16.0, 16.01, 0.25)
        Q = p0[None, :] + o[:, None] * n[None, :]
        ax2.fill_between(o, orig(Q[:, 0], Q[:, 1]), 5, color="#e6dcc3", zorder=0)
        ax2.plot(o, orig(Q[:, 0], Q[:, 1]), color="#7a5c2e", lw=1.6, label="terreno original (MDT 1 m)", zorder=2)
        ax2.plot(o, T.h(Q[:, 0], Q[:, 1]) + ref, color="#1b7837", lw=2.2, label="suelo nuevo / terreno final", zorder=4)
        dentro = shapely.contains_xy(info["huella"], Q[:, 0], Q[:, 1])
        if dentro.any():
            ax2.fill_between(o[dentro], e["losa"]["bot"](Q[dentro, 0], Q[dentro, 1]) + ref,
                             e["losa"]["top"](Q[dentro, 0], Q[dentro, 1]) + ref, color="#555860", zorder=3, label="losa")
        primero = True
        for a_, b_, y0, y1 in info["muros"]:
            m = (a_ + b_) / 2
            q = m - p0
            if abs(q @ np.array([-n[1], n[0]])) < 1.0:       # a menos de 1 m del plano transversal
                x_ = float(q @ n)
                ax2.add_patch(Rectangle((x_ - MURO_SUELO_GROSOR / 2, y0 + ref), MURO_SUELO_GROSOR, y1 - y0, color="#c07a2a", zorder=6,
                                        label="muros laterales (0,3 m, con pretil)" if primero else None))
                primero = False
        ax2.set_xlabel("distancia al eje del puente (m); + = lado NO (zanja NO) ; - = lado SE")
        ax2.set_ylabel("cota s.n.m. (m)")
        ax2.set_xlim(-16, 16)
        ax2.set_ylim(orig(Q[:, 0], Q[:, 1]).min() - 0.8, e["losa"]["top"](*p0) + ref + 1.5)
        ax2.set_title(f"Seccion transversal en el cruce del cauce, en ({p0[0]:.0f}, {p0[1]:.0f}) (este, norte): desnivel exterior NO a 7 m {mejor[0]:.1f} m")
        ax2.grid(alpha=0.3)
        h2, l2 = ax2.get_legend_handles_labels()
        ax2.legend(dict(zip(l2, h2)).values(), dict(zip(l2, h2)).keys(), loc="upper right", fontsize=8)
    fig.tight_layout()
    fig.savefig(ruta)
    plt.close(fig)
    print(f"Perfil: {ruta}")


def perfil_marquesinas(ruta, glb, geo, larga=321893434, corta=555538618):
    """Perfiles de la marquesina larga (18-24) y de la corta (medidos sobre el .glb): terreno, losa y pilares; la
    corta lleva la cara inferior de la larga como referencia (deben coincidir)."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    sc = trimesh.load(glb, force="scene")
    el = next((q for q in geo["edificios"] if q["id"] == larga), None)
    ec = next((q for q in geo["edificios"] if q["id"] == corta), None)
    if el is None or ec is None:
        return
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(18, 11), dpi=100)
    y_larga = float(el["losa"]["bot"](el["poly"].centroid.x, el["poly"].centroid.y))
    _perfil_techo(a1, sc, geo, larga, f"Marquesina larga {larga} (nivel {el['losa']['nivel']}, cota {el['losa']['cota_abs']:.2f} m s.n.m.)")
    _perfil_techo(a2, sc, geo, corta, f"Marquesina corta {corta} (nivel {ec['losa']['nivel']}, cota {ec['losa']['cota_abs']:.2f} m s.n.m.)",
                  linea_y=(y_larga, "cara inferior de la marquesina larga"))
    fig.tight_layout()
    fig.savefig(ruta)
    plt.close(fig)
    print(f"Perfil: {ruta}")


ESCALERAS_PERFIL = (1373674173, 1373674174)   # dos escaleras/rampas largas (highway=steps) con tramos de varios metros de desnivel


def _y_malla(mesh, x, z):
    """y de la malla `mesh` (trimesh, ejes del glb) bajo cada punto (x, z) por la vertical, sin rtree: se filtran
    los triangulos de la caja de los puntos y se resuelven las coordenadas baricentricas. NaN si no hay triangulo."""
    v, f = mesh.vertices, mesh.faces
    tri = v[f]
    caja = ((tri[:, :, 0].max(1) >= x.min() - 1) & (tri[:, :, 0].min(1) <= x.max() + 1)
            & (tri[:, :, 2].max(1) >= z.min() - 1) & (tri[:, :, 2].min(1) <= z.max() + 1))
    t = tri[caja]
    a, b, c = t[:, 0], t[:, 1], t[:, 2]
    d = (b[:, 2] - c[:, 2]) * (a[:, 0] - c[:, 0]) + (c[:, 0] - b[:, 0]) * (a[:, 2] - c[:, 2])
    out = np.full(len(x), np.nan)
    ok = np.abs(d) > 1e-12
    a, b, c, d = a[ok], b[ok], c[ok], d[ok]
    for i in range(len(x)):
        l1 = ((b[:, 2] - c[:, 2]) * (x[i] - c[:, 0]) + (c[:, 0] - b[:, 0]) * (z[i] - c[:, 2])) / d
        l2 = ((c[:, 2] - a[:, 2]) * (x[i] - c[:, 0]) + (a[:, 0] - c[:, 0]) * (z[i] - c[:, 2])) / d
        m = (l1 >= -1e-9) & (l2 >= -1e-9) & (1 - l1 - l2 >= -1e-9)
        if m.any():
            k = np.nonzero(m)[0][0]
            out[i] = l1[k] * a[k, 1] + l2[k] * b[k, 1] + (1 - l1[k] - l2[k]) * c[k, 1]
    return out


def perfil_escaleras(ruta, glb, mapa, T, E0, N0, campus, ways=ESCALERAS_PERFIL):
    """Perfil a lo largo de las escaleras/rampas `ways` (distancia por la polilinea frente a cota s.n.m.):
    MDT de 5 m (IGN, suavizado de 5 m: el relieve de antes), MDT de 1 m (LiDAR, sin suavizar), el 1 m con el
    suavizado usado y la malla final (corte de terreno-col del .glb por la vertical de cada punto) con su
    triangulacion (puntos = vertices de la malla), mas la pieza `caminos_steps` (+3 cm)."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fuentes = []
    for etiqueta, ruta_mdt, suav, estilo in (
            ("MDT 5 m IGN (suavizado 5 m)", ter.MDT_ALTERNATIVO, 5.0, dict(color="#c0392b", lw=1.6, ls="--")),
            ("MDT 1 m LiDAR (sin suavizar)", ter.MDT_DEFECTO, 0.0, dict(color="#2c7fb8", lw=1.0, alpha=0.8))):
        if Path(ruta_mdt).exists():
            fuentes.append((etiqueta, ter.Terreno.desde_raster(ruta_mdt, E0, N0, campus, suav, 1.0), estilo))
    sc = trimesh.load(glb, force="scene")
    malla = sc.geometry["terreno-col"]
    pasos_ = sc.geometry[sc.graph["caminos_steps"][1]] if "caminos_steps" in sc.graph.nodes_geometry else None
    fig, axs = plt.subplots(len(ways), 1, figsize=(15, 5.2 * len(ways)), dpi=100)
    axs = np.atleast_1d(axs)
    for ax, wid in zip(axs, ways):
        w = mapa.ways.get(wid)
        l = mapa.linea(w) if w is not None else None
        if l is None:
            continue
        d = np.arange(0.0, l.length, 0.1)
        pts = np.array([l.interpolate(q).coords[0] for q in d])
        x, z = pts[:, 0], -pts[:, 1]
        for etiqueta, F, estilo in fuentes:
            ax.plot(d, F.altura_raster(x, z) + F.cota_ref, label=etiqueta, **estilo)
        # corte de la malla final: rayos verticales sobre cada punto
        ymalla = _y_malla(malla, x, z)
        ax.plot(d, ymalla + T.cota_ref, color="#1b7837", lw=2.4, label=f"malla final del .glb (terreno-col; suavizado {T.suavizado_m:g} m)")
        if pasos_ is not None:
            yp = _y_malla(pasos_, x, z)
            ax.plot(d, yp + T.cota_ref, color="#f39c12", lw=1.0, label="pieza caminos_steps (+3 cm)")
        ax.set_xlabel("distancia a lo largo de la polilinea de la escalera (m)")
        ax.set_ylabel("cota s.n.m. (m)")
        ax.set_title(f"OSM way {wid} (highway=steps, {l.length:.0f} m; pendiente media "
                     f"{abs(ymalla[-1] - ymalla[0]) / l.length * 100 if np.isfinite(ymalla[[0, -1]]).all() else float('nan'):.0f} %)")
        ax.grid(alpha=0.3)
        ax.legend(loc="best", fontsize=8)
    fig.suptitle("Perfil de las escaleras: MDT 5 m vs MDT 1 m vs malla final")
    fig.tight_layout()
    fig.savefig(ruta)
    plt.close(fig)
    print(f"Perfil escaleras: {ruta}")


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
    lineales = [n for n in nombres if n.startswith(("muros", "vallas", "padel", "limite"))]
    malos_l = [n for n in lineales if not sc.geometry[sc.graph[n][1]].is_watertight]
    print(f"[verificacion] prismas lineales (muros, vallas, padel, limite): {len(lineales)} | NO watertight: {len(malos_l)}")
    for n in malos_l:
        print("   no watertight:", n)
    tri_terreno = sum(len(sc.geometry[sc.graph[n][1]].faces) for n in nombres if n.startswith("terreno"))
    print(f"[verificacion] triangulos del terreno: {tri_terreno}")
    pr = [n for n in nombres if n.startswith("props_")]
    malos_p = [n for n in pr if not sc.geometry[sc.graph[n][1]].is_watertight]
    print(f"[verificacion] nodos de props: {len(pr)} | triangulos: "
          f"{sum(len(sc.geometry[sc.graph[n][1]].faces) for n in pr)} | NO watertight: {len(malos_p)}")
    for n in malos_p:
        print("   no watertight:", n)
    tri_arboles = sum(len(sc.geometry[sc.graph[n][1]].faces) for n in nombres if n.startswith("arboles"))
    tri_coches = sum(len(sc.geometry[sc.graph[n][1]].faces) for n in nombres if n.startswith("coches"))
    print(f"[verificacion] triangulos de arboles: {tri_arboles} | de coches: {tri_coches}")
    mats = {sc.geometry[sc.graph[n][1]].visual.material.name for n in nombres}
    print(f"[verificacion] materiales distintos: {len(mats)} {sorted(mats)}")
    return {"nodos": len(nombres), "triangulos": tris, "bounds": b.tolist(),
            "edificios": len(edif), "no_watertight": malos + malos_l + malos_p,
            "triangulos_terreno": tri_terreno, "triangulos_arboles": tri_arboles, "triangulos_coches": tri_coches}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--entrada", default="data/raw/osm_upo.json")
    ap.add_argument("--alturas", default="data/alturas.csv")
    ap.add_argument("--pasos", default="data/pasos.csv")
    ap.add_argument("--pistas", default="data/pistas.csv")
    ap.add_argument("--escaleras", default="data/escaleras.csv")
    ap.add_argument("--salida", default="export/upo_blockout.glb")
    ap.add_argument("--sin-preview", action="store_true")
    ap.add_argument("--solo-estilos", action="store_true",
                    help="solo reescribe el CSV y game/data/estilos.json (sin regenerar el .glb)")
    ap.add_argument("--copiar-godot", action=argparse.BooleanOptionalAction, default=True,
                    help="copia el .glb a game/assets/mapa/ (--no-copiar-godot lo desactiva)")
    ter.anadir_argumentos(ap)
    anadir_argumentos_props(ap)
    a = ap.parse_args()

    mapa = Mapa(a.entrada)
    edificios = [(wid, w["tags"]) for wid, w in sorted(mapa.ways.items())
                 if "tags" in w and mapa.cerrado(w)
                 and ("building" in w["tags"] or w["tags"].get("man_made") == "tower")]
    filas = cargar_alturas(a.alturas, edificios)
    exportar_estilos(filas)
    if a.solo_estilos:
        return
    pasos = cargar_pasos(a.pasos)
    campus = campus_local(mapa)
    T = ter.crear(a, mapa.E0, mapa.N0, campus, zona_fina(mapa, campus, a.buffer_fino, ids_suelo(filas)))
    print(f"Terreno: {T.info()}")
    escs = cargar_escaleras(a.escaleras)
    for wid, i in preparar_suelos(mapa, filas, T, huecos_escaleras(escs)).items():
        forma_ = (f"plano a={i['plano'][0]:.5f} b={i['plano'][1]:.5f} c={i['plano'][2]:.3f}" if i["plano"] is not None else
                  "eje: " + " / ".join(f"s={a_:.0f} m: {b_ + T.cota_ref:.2f} m s.n.m." for a_, b_ in zip(i["nudos_s"], i["nudos_y"])))
        print(f"Suelo {wid}: {forma_} (pendiente "
              f"{i['pendiente_grados']:.2f} grados, {i['n_usados']}/{i['n_px']} puntos, rms {i['rms']:.2f} m, "
              f"residuo max {i['res_max']:.2f} m), muros {i['long_muros_m']:.0f} m")
    for d in preparar_escaleras(T, escs):
        print(f"Escalera {d['id']}: arriba y={d['y1']:.2f} abajo y={d['y2']:.2f} (desnivel {d['y1'] - d['y2']:.2f} m) en "
              f"{d['longitud_m']:.2f} m, {d['peldanos']} peldanos de {d['alto']:.3f} x {d['huella']:.3f} m, {d['angulo']:.1f} grados")
    lidar = Lidar(a.mdt, NDSM_DEFECTO, mapa.E0, mapa.N0)
    piezas, stats, geo = construir(mapa, filas, pasos, cargar_pistas(a.pistas), T, lidar)
    guardar_alturas(a.alturas, filas)    # nivel / cota_abs / notas de las losas calculados

    props = construir_props(mapa, geo, a)
    print("Props:", {k: v for k, v in props["stats"].items() if k != "por_parking"})
    stats.update({k: v for k, v in props["stats"].items() if k != "por_parking"})
    piezas = piezas + props["piezas"]

    sx0, sy0, sx1, sy1 = geo["suelo"].bounds
    q = T.paso_bloque or 1.0   # la malla se redondea hacia fuera a multiplos del bloque
    bbox_malla = list(geo["suelo"].bounds) if T.es_plano else [
        math.floor(sx0 / q) * q, math.floor(sy0 / q) * q, math.ceil(sx1 / q) * q, math.ceil(sy1 / q) * q]
    piezas.append(("exterior", faldon_exterior(T, bbox_malla), "campo"))   # sin -col: sin colision

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
        "terreno": {**T.info(), "paso_terreno_m": a.paso_terreno, "buffer_fino_m": a.buffer_fino,
                    "ejes": "y_juego = cota_s.n.m. - cota_ref",
                    "bbox_malla_m": bbox_malla,
                    "bbox_malla_orden": "x_min, norte_min, x_max, norte_max"},
        "recuentos": dict(stats),
        "props": {"semilla": a.semilla, "ocupacion": a.ocupacion, "coches_carretera": a.coches_carretera,
                  "sin_arboles": a.sin_arboles, "sin_coches": a.sin_coches, "huella": props["huella"],
                  "arboles": len(props["arboles"]), "coches": len(props["coches"]),
                  "por_parking": props["stats"].get("por_parking", {})},
    }
    if not a.sin_coches:
        guardar_coches(salida.with_name("coches.json"), props, a)
        guardar_coches(Path(__file__).resolve().parent.parent / "game" / "data" / "coches.json", props, a)   # lo lee game/scripts/coches_externos.gd
    meta_ruta = salida.with_name(salida.stem + "_meta.json")
    meta_ruta.write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Meta: {meta_ruta}")
    print("Recuentos:", dict(stats))

    ver = verificar(salida)
    meta["verificacion"] = ver
    meta_ruta.write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")

    if not a.sin_preview:
        preview(salida.with_name("preview.png"), geo, extra=lambda ax: dibujar_props(ax, props))
        zoom_aparcamiento(salida.with_name("zoom_aparcamiento.png"), geo, mapa, props, "P11")
        zoom_paso(salida.with_name("zoom_22_24.png"), geo, mapa, "22-24")
        zoom_tunel(salida.with_name("zoom_37.png"), geo, 142276198)
        if not T.es_plano:
            perfil_pasillo(salida.with_name("perfil_pasillo.png"), salida, geo)
            perfil_pasillo_18(salida.with_name("perfil_pasillo_18.png"), geo, T)
            perfil_marquesinas(salida.with_name("perfil_marquesinas.png"), salida, geo)
            perfil_escaleras(salida.with_name("perfil_escaleras.png"), salida, mapa, T, mapa.E0, mapa.N0, campus)


if __name__ == "__main__":
    main()
