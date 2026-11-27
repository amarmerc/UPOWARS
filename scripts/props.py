"""Coberturas (props) low-poly con colision, apoyadas en el terreno. Las posiciones viven en data/props.csv.

Columnas de data/props.csv: tipo, x, z, yaw, escala, notas
- x, z: coordenadas de juego (x = este, z = -norte), centro del prop en planta.
- yaw: rotacion Y de Godot en grados (0 = el frente mira a -Z = norte; positivo = giro antihorario visto desde arriba).
  "Frente" = el lado hacia donde mira un asiento o se abre una marquesina; el respaldo / la espalda queda detras.
- escala: factor uniforme de tamano (1 por defecto). En el murete multiplica solo el largo (4 m x escala).
- notas: texto libre; admite parametros `clave=valor` separados por `;` (`largo=6` en el murete, `volcada` en la mesa).

Cada prop se construye con cajas cerradas (cada caja es un solido cerrado: la malla es watertight) en el marco local
(a = a lo largo, f = hacia el frente, y = arriba; y=0 es el suelo). Las cajas que tocan el suelo se prolongan hacia abajo lo
justo para que ninguna quede en el aire sobre una pendiente. Un nodo por material: `props_<material>-col` (el arbusto de la
jardinera no tiene colision).
"""
import math
import re

import numpy as np
import shapely
import trimesh
from shapely.geometry import Polygon

TIPOS = ("banco", "murete", "jardinera", "contenedor", "reciclaje_azul", "reciclaje_amarillo", "reciclaje_verde",
         "aparcabicis", "marquesina", "expendedora", "pila_sillas", "mesa", "aula")

# material -> RGBA (el nodo del glb es `props_<sin prefijo>[-col]`)
COLORES_MATERIAL = {
    "prop_hormigon": (176, 172, 162, 255),
    "prop_madera": (152, 106, 66, 255),
    "prop_metal": (78, 83, 90, 255),
    "prop_basura": (44, 88, 64, 255),
    "prop_reciclaje_azul": (36, 92, 176, 255),
    "prop_reciclaje_amarillo": (228, 190, 40, 255),
    "prop_reciclaje_verde": (52, 150, 84, 255),
    "prop_expendedora": (190, 40, 46, 255),
    "prop_cristal_oscuro": (22, 28, 38, 255),
    "prop_pizarra": (34, 66, 54, 255),
    "prop_silla": (60, 112, 190, 255),
    "prop_arbusto": (62, 118, 58, 255),
}
SIN_COLISION = ("prop_arbusto",)
ENTERRADO_MIN = 0.1        # las cajas del suelo bajan 0,1 m por debajo del terreno mas bajo de la huella
PENDIENTE_MAX_M = 0.45     # desnivel maximo del terreno bajo la huella (generar_props lo respeta)


def nodo(material):
    return "props_" + material[len("prop_"):] + ("" if material in SIN_COLISION else "-col")


def parse_notas(notas):
    """`clave=valor; clave2; ...` -> dict (los parametros sin valor valen True)."""
    d = {}
    for trozo in re.split(r"[;|]", notas or ""):
        trozo = trozo.strip()
        if not trozo:
            continue
        if "=" in trozo:
            k, v = trozo.split("=", 1)
            d[k.strip().lower()] = v.strip()
        elif re.fullmatch(r"[a-z_]+", trozo):
            d[trozo] = True
    return d


class Constructor:
    """Acumula cajas por material en el marco local del prop."""

    def __init__(self):
        self.cajas = {}      # material -> [(a0, a1, f0, f1, y0, y1)]
        self.extra = {}      # material -> [(centro(a,f,y), semiejes(a,f,y))] elipsoides low-poly (arbusto)

    def caja(self, mat, a0, a1, f0, f1, y0, y1):
        self.cajas.setdefault(mat, []).append((min(a0, a1), max(a0, a1), min(f0, f1), max(f0, f1), y0, y1))

    def elipsoide(self, mat, c, r):
        self.extra.setdefault(mat, []).append((c, r))


def _banco(c, s):
    for sg in (-1, 1):
        c.caja("prop_hormigon", sg * 0.70 * s, sg * 0.84 * s, -0.22 * s, 0.22 * s, 0.0, 0.42 * s)
    c.caja("prop_madera", -0.9 * s, 0.9 * s, -0.22 * s, 0.26 * s, 0.42 * s, 0.47 * s)
    c.caja("prop_madera", -0.9 * s, 0.9 * s, -0.27 * s, -0.21 * s, 0.47 * s, 0.92 * s)
    return (-0.9 * s, 0.9 * s, -0.27 * s, 0.26 * s)


def _murete(c, s, notas):
    largo = float(notas.get("largo", 4.0 * s))
    h = largo / 2
    c.caja("prop_hormigon", -h, h, -0.2, 0.2, 0.0, 0.92)
    c.caja("prop_hormigon", -h - 0.03, h + 0.03, -0.25, 0.25, 0.92, 1.0)
    return (-h - 0.03, h + 0.03, -0.25, 0.25)


def _jardinera(c, s):
    c.caja("prop_hormigon", -0.9 * s, 0.9 * s, -0.45 * s, 0.45 * s, 0.0, 0.8 * s)
    c.elipsoide("prop_arbusto", (0.0, 0.0, 0.8 * s + 0.15 * s), (0.62 * s, 0.34 * s, 0.38 * s))
    return (-0.9 * s, 0.9 * s, -0.45 * s, 0.45 * s)


def _contenedor(c, s):
    c.caja("prop_basura", -1.0 * s, 1.0 * s, -0.55 * s, 0.55 * s, 0.12 * s, 1.28 * s)
    c.caja("prop_metal", -1.03 * s, 1.03 * s, -0.58 * s, 0.58 * s, 1.28 * s, 1.38 * s)
    for sa in (-1, 1):
        for sf in (-1, 1):
            c.caja("prop_metal", sa * 0.78 * s - 0.08 * s, sa * 0.78 * s + 0.08 * s,
                   sf * 0.38 * s - 0.08 * s, sf * 0.38 * s + 0.08 * s, 0.0, 0.2 * s)
    return (-1.03 * s, 1.03 * s, -0.58 * s, 0.58 * s)


def _reciclaje(c, s, mat):
    c.caja(mat, -0.65 * s, 0.65 * s, -0.55 * s, 0.55 * s, 0.0, 1.32 * s)
    c.caja(mat, -0.55 * s, 0.55 * s, -0.45 * s, 0.45 * s, 1.32 * s, 1.5 * s)
    c.caja("prop_metal", -0.3 * s, 0.3 * s, 0.55 * s, 0.6 * s, 0.9 * s, 1.1 * s)   # boca de entrada
    return (-0.65 * s, 0.65 * s, -0.55 * s, 0.6 * s)


def _aparcabicis(c, s):
    for k in range(5):
        a = (k - 2) * 0.6 * s
        for sf in (-1, 1):
            c.caja("prop_metal", a - 0.025, a + 0.025, sf * 0.35 * s - 0.025, sf * 0.35 * s + 0.025, 0.0, 0.78 * s)
        c.caja("prop_metal", a - 0.025, a + 0.025, -0.375 * s, 0.375 * s, 0.75 * s, 0.8 * s)
    return (-1.25 * s, 1.25 * s, -0.375 * s, 0.375 * s)


def _marquesina(c, s):
    for sa in (-1, 1):
        c.caja("prop_metal", sa * 1.75 * s - 0.05, sa * 1.75 * s + 0.05, -0.75 * s, -0.65 * s, 0.0, 2.45 * s)
        c.caja("prop_cristal_oscuro", sa * 1.7 * s - 0.03, sa * 1.7 * s + 0.03, -0.72 * s, 0.5 * s, 0.35 * s, 2.4 * s)
    c.caja("prop_metal", -1.95 * s, 1.95 * s, -0.85 * s, 0.95 * s, 2.45 * s, 2.55 * s)
    c.caja("prop_cristal_oscuro", -1.7 * s, 1.7 * s, -0.76 * s, -0.7 * s, 0.35 * s, 2.45 * s)
    c.caja("prop_madera", -1.2 * s, 1.2 * s, -0.6 * s, -0.2 * s, 0.42 * s, 0.47 * s)
    for sa in (-1, 1):
        c.caja("prop_metal", sa * 1.1 * s - 0.04, sa * 1.1 * s + 0.04, -0.5 * s, -0.3 * s, 0.0, 0.42 * s)
    return (-1.95 * s, 1.95 * s, -0.85 * s, 0.95 * s)


def _expendedora(c, s):
    c.caja("prop_expendedora", -0.5 * s, 0.5 * s, -0.4 * s, 0.4 * s, 0.0, 1.85 * s)
    c.caja("prop_cristal_oscuro", -0.4 * s, 0.4 * s, 0.4 * s, 0.44 * s, 0.4 * s, 1.7 * s)
    return (-0.5 * s, 0.5 * s, -0.4 * s, 0.44 * s)


def _silla(c, s, y_base, a_off=0.0, f_off=0.0):
    """Una silla con las patas apoyadas en y_base; devuelve la y del asiento (cara superior)."""
    ys = y_base + 0.44 * s
    for sa in (-1, 1):
        for sf in (-1, 1):
            c.caja("prop_metal", a_off + sa * 0.19 * s - 0.015 * s, a_off + sa * 0.19 * s + 0.015 * s,
                   f_off + sf * 0.19 * s - 0.015 * s, f_off + sf * 0.19 * s + 0.015 * s, y_base, ys)
    c.caja("prop_silla", a_off - 0.22 * s, a_off + 0.22 * s, f_off - 0.22 * s, f_off + 0.22 * s, ys, ys + 0.04 * s)
    c.caja("prop_silla", a_off - 0.22 * s, a_off + 0.22 * s, f_off - 0.24 * s, f_off - 0.20 * s, ys + 0.04 * s, ys + 0.46 * s)
    return ys + 0.04 * s


def _pila_sillas(c, s):
    y = 0.0
    for k in range(5):
        top = _silla(c, s, y, 0.0, -0.05 * s * k)
        y = top - 0.30 * s          # la siguiente apoya sus patas en el asiento de la anterior (encajadas)
    return (-0.25 * s, 0.25 * s, -0.45 * s, 0.25 * s)


def _mesa(c, s, notas):
    if notas.get("volcada"):
        c.caja("prop_madera", -0.8 * s, 0.8 * s, -0.03 * s, 0.03 * s, 0.0, 0.85 * s)
        for sa in (-1, 1):
            for yy in (0.04, 0.76):
                c.caja("prop_metal", sa * 0.7 * s - 0.025, sa * 0.7 * s + 0.025, 0.03 * s, 0.75 * s, yy * s, (yy + 0.05) * s)
        return (-0.8 * s, 0.8 * s, -0.03 * s, 0.75 * s)
    c.caja("prop_madera", -0.8 * s, 0.8 * s, -0.4 * s, 0.4 * s, 0.72 * s, 0.77 * s)
    for sa in (-1, 1):
        for sf in (-1, 1):
            c.caja("prop_metal", sa * 0.72 * s - 0.025, sa * 0.72 * s + 0.025,
                   sf * 0.32 * s - 0.025, sf * 0.32 * s + 0.025, 0.0, 0.72 * s)
    return (-0.8 * s, 0.8 * s, -0.4 * s, 0.4 * s)


def _aula(c, s):
    """4 filas de 4 asientos con respaldo mirando (+f) a una pizarra sobre patas. El origen es el centro de la pizarra."""
    for r in range(4):
        f = -(3.2 + 1.6 * r) * s
        for k in range(4):
            a = (k - 1.5) * 0.95 * s
            c.caja("prop_madera", a - 0.22 * s, a + 0.22 * s, f - 0.22 * s, f + 0.22 * s, 0.0, 0.45 * s)
            c.caja("prop_madera", a - 0.22 * s, a + 0.22 * s, f - 0.24 * s, f - 0.18 * s, 0.45 * s, 0.9 * s)
    c.caja("prop_pizarra", -1.7 * s, 1.7 * s, -0.04 * s, 0.04 * s, 0.85 * s, 2.15 * s)
    for sa in (-1, 1):
        c.caja("prop_metal", sa * 1.45 * s - 0.04, sa * 1.45 * s + 0.04, -0.06 * s, 0.06 * s, 0.0, 0.9 * s)
        c.caja("prop_metal", sa * 1.45 * s - 0.04, sa * 1.45 * s + 0.04, -0.4 * s, 0.4 * s, 0.0, 0.06 * s)
    return (-2.0 * s, 2.0 * s, -(3.2 + 4.8) * s - 0.3 * s, 0.4 * s)


def definir(tipo, escala, notas):
    """(Constructor, (a0, a1, f0, f1) huella) de un tipo de prop."""
    c = Constructor()
    s = float(escala)
    n = parse_notas(notas) if isinstance(notas, str) else (notas or {})
    if tipo == "banco":
        r = _banco(c, s)
    elif tipo == "murete":
        r = _murete(c, s, {**n, **({} if "largo" in n else {"largo": 4.0 * s})})
    elif tipo == "jardinera":
        r = _jardinera(c, s)
    elif tipo == "contenedor":
        r = _contenedor(c, s)
    elif tipo.startswith("reciclaje_"):
        r = _reciclaje(c, s, "prop_" + tipo)
    elif tipo == "aparcabicis":
        r = _aparcabicis(c, s)
    elif tipo == "marquesina":
        r = _marquesina(c, s)
    elif tipo == "expendedora":
        r = _expendedora(c, s)
    elif tipo == "pila_sillas":
        r = _pila_sillas(c, s)
    elif tipo == "mesa":
        r = _mesa(c, s, n)
    elif tipo == "aula":
        r = _aula(c, s)
    else:
        raise ValueError(f"tipo de prop desconocido: {tipo!r} (validos: {', '.join(TIPOS)})")
    return c, r


def alto(tipo, escala=1.0, notas=""):
    """Altura aproximada del prop (m): maxima de sus cajas."""
    c, _ = definir(tipo, escala, notas)
    ys = [cj[5] for v in c.cajas.values() for cj in v] + [e[0][2] + e[1][2] for v in c.extra.values() for e in v]
    return max(ys)


def punto_solido(tipo, escala=1.0, notas=""):
    """(a, f, y) del centro de la caja de mayor volumen del prop (un punto seguro para apuntar un rayo de test)."""
    c, _ = definir(tipo, escala, notas)
    mejor = None
    for mat, cajas in c.cajas.items():
        if mat in SIN_COLISION:
            continue
        for a0, a1, f0, f1, y0, y1 in cajas:
            v = (a1 - a0) * (f1 - f0) * (y1 - y0)
            if mejor is None or v > mejor[0]:
                mejor = (v, ((a0 + a1) / 2, (f0 + f1) / 2, (y0 + y1) / 2))
    return mejor[1]


def _rot(a, f, yaw_deg):
    """Marco local (a, f) -> (este, norte) girando yaw (CCW visto desde arriba, igual que la rotacion Y de Godot)."""
    t = math.radians(yaw_deg)
    return a * math.cos(t) - f * math.sin(t), a * math.sin(t) + f * math.cos(t)


def huella(p):
    """Poligono (plano local: este, norte) de la huella de un prop de data/props.csv (dict con tipo, x, z, yaw, escala, notas)."""
    _, (a0, a1, f0, f1) = definir(p["tipo"], p["escala"], p["notas"])
    x, n = float(p["x"]), -float(p["z"])
    pts = [_rot(a, f, p["yaw"]) for a, f in ((a0, f0), (a1, f0), (a1, f1), (a0, f1))]
    return Polygon([(x + u, n + v) for u, v in pts])


def desnivel(p, T, paso=0.4):
    """(min, max) del terreno bajo la huella del prop."""
    g = huella(p)
    x0, y0, x1, y1 = g.bounds
    xs, ys = np.meshgrid(np.arange(x0, x1 + paso, paso), np.arange(y0, y1 + paso, paso))
    dentro = shapely.contains_xy(g.buffer(0.05), xs.ravel(), ys.ravel())
    if not dentro.any():
        h = float(T.h(p["x"], -p["z"]))
        return h, h
    h = np.asarray(T.h(xs.ravel()[dentro], ys.ravel()[dentro]))
    return float(h.min()), float(h.max())


def _caja_malla(v0, v1, ejes, centro, yaw, z_base):
    """Vertices (8) de una caja del marco local en el plano local (este, norte, z)."""
    a0, a1, f0, f1 = v0
    y0, y1 = v1
    pts = []
    for a, f, y in ((a0, f0, y0), (a1, f0, y0), (a1, f1, y0), (a0, f1, y0),
                    (a0, f0, y1), (a1, f0, y1), (a1, f1, y1), (a0, f1, y1)):
        u, v = _rot(a, f, yaw)
        pts.append((centro[0] + u, centro[1] + v, z_base + y))
    return pts


_CARAS_CAJA = np.array([[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4],
                        [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]])


def piezas_props(filas, T):
    """[(nombre_nodo, mesh local (x, norte, z), clave_material)] con todos los props de `filas`, un nodo por material."""
    verts, caras = {}, {}
    ico = trimesh.creation.icosphere(subdivisions=1, radius=1.0)
    for p in filas:
        c, _ = definir(p["tipo"], p["escala"], p["notas"])
        lo, hi = desnivel(p, T)
        z_base = lo
        ent = ENTERRADO_MIN + (hi - lo)       # lo que se prolonga hacia abajo una caja del suelo (hasta el terreno mas alto)
        centro = (float(p["x"]), -float(p["z"]))
        for mat, cajas in c.cajas.items():
            vs = verts.setdefault(mat, [])
            fs = caras.setdefault(mat, [])
            for a0, a1, f0, f1, y0, y1 in cajas:
                yb = (-ent if y0 <= 1e-6 else y0)
                pts = _caja_malla((a0, a1, f0, f1), (yb, y1), None, centro, p["yaw"], z_base)
                n0 = sum(len(v) for v in vs)
                vs.append(np.array(pts))
                fs.append(_CARAS_CAJA + n0)
        for mat, elips in c.extra.items():
            vs = verts.setdefault(mat, [])
            fs = caras.setdefault(mat, [])
            for (ca, cf, cy), (ra, rf, ry) in elips:
                loc = np.asarray(ico.vertices) * np.array([ra, rf, ry])
                pts = []
                for a, f, y in loc:
                    u, v = _rot(a + ca, f + cf, p["yaw"])
                    pts.append((centro[0] + u, centro[1] + v, z_base + cy + y))
                n0 = sum(len(v) for v in vs)
                vs.append(np.array(pts))
                fs.append(np.asarray(ico.faces) + n0)
    piezas = []
    for mat in COLORES_MATERIAL:
        if mat in verts:
            m = trimesh.Trimesh(np.vstack(verts[mat]), np.vstack(caras[mat]), process=False)
            piezas.append((nodo(mat), m, mat))
    return piezas
