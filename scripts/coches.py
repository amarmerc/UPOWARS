"""Coches estaticos (props con colision) en los aparcamientos y en algunas carreteras.

Modelo blockout (sistema del coche: x = derecha, y = arriba, z = atras; el morro apunta a -z, como en Godot):
carroceria 1,8 x 0,75 x 4,4 m a 0,25 m del suelo + habitaculo 1,6 x 0,6 x 2,3 m encima y algo atras + banda de
cristales oscura + 4 ruedas de 8 lados. Nodos: `coches_<color>-col` (6 colores apagados, con colision),
`coches_ruedas-col` (con colision) y `coches_cristales` (sin colision): un nodo por material.

Aparcamientos (todos los amenity=parking): rectangulo minimo orientado, filas de plazas de 2,5 x 5 m en doble fila
espalda con espalda + pasillo de 6 m (periodo de 16 m), dentro del poligono con 1 m de margen; se prueban las dos
orientaciones y varias fases y se queda la que mas plazas utiles da. Cada plaza se ocupa con probabilidad
`ocupacion`. Bajo marquesinas (techos) solo caben los coches con >= 2,1 m de galibo en todo su rectangulo.
Carreteras: `n_carretera` coches aparcados en el borde de vias service / residential (a la derecha segun el sentido
de la via) y algunos parados en una tertiary, separados >= 40 m y a >= 15 m de cruces y rotondas.
Cada coche se apoya en el terreno: y del centro = media de las cotas bajo las 4 ruedas y se inclina segun el plano de
las ruedas (pitch/roll); no se coloca donde el terreno se aparta del plano > 25 cm (bordillos, escalones) o pasa de 10 grados.
Todo es reproducible con la semilla.
"""
import math
from collections import Counter

import numpy as np
import shapely
import trimesh
from shapely.geometry import LineString, MultiPoint, Point
from shapely.ops import unary_union

LARGO, ANCHO = 4.4, 1.8
Y_CARROCERIA = (0.25, 1.0)
CABINA_ANCHO, CABINA_LARGO, CABINA_ALTO, CABINA_DESPL = 1.6, 2.3, 0.6, 0.25     # desplazada hacia atras (+z)
RUEDA_R, RUEDA_ANCHO, RUEDA_X, RUEDA_Z = 0.32, 0.22, 0.82, 1.35
ALTURA_TOTAL = 1.6
GALIBO_MIN = ALTURA_TOTAL + 0.5        # separacion libre bajo marquesinas: 2,1 m
PLAZA_ANCHO, PLAZA_FONDO, PASILLO = 2.5, 5.0, 6.0
PERIODO = 2 * PLAZA_FONDO + PASILLO
MARGEN_PARKING = 1.0
HOLGURA_PILAR = 0.5
DIST_SPAWN = 5.0
DIST_CRUCE = 15.0
SEP_CARRETERA = 40.0
MAX_INCLINACION = math.radians(10.0)
MAX_RESIDUO = 0.25
ENTRE_EJES_X, ENTRE_EJES_Z = 2 * 0.85, 2 * 1.35       # puntos de apoyo de las 4 ruedas
VIAS_APARCABLES = {"service": 4.0, "residential": 6.0}
ANCHO_TERTIARY = 7.0

COLORES = {   # carroceria: nombre -> (rgb, peso)
    "blanco": ((205, 205, 202), 3), "gris": ((122, 124, 128), 3), "negro": ((38, 39, 42), 2),
    "rojo_oscuro": ((124, 36, 36), 1), "azul_oscuro": ((34, 52, 98), 1.5), "plata": ((170, 174, 180), 3),
}
CRISTAL = (28, 34, 42)
GOMA = (24, 24, 26)
COLORES_MATERIAL = {**{f"coche_{k}": (*rgb, 255) for k, (rgb, _) in COLORES.items()},
                    "coche_cristal": (*CRISTAL, 255), "coche_goma": (*GOMA, 255)}


# ---------------------------------------------------------------- modelo
def _caja(x0, x1, y0, y1, z0, z1):
    v = np.array([[x, y, z] for x in (x0, x1) for y in (y0, y1) for z in (z0, z1)], float)
    # 6 caras (indices del producto x, y, z); el bobinado se corrige luego en _orientar
    f = [(0, 1, 3), (0, 3, 2),      # x0
         (4, 6, 7), (4, 7, 5),      # x1
         (2, 3, 7), (2, 7, 6),      # y1 (arriba)
         (0, 4, 5), (0, 5, 1),      # y0 (abajo)
         (0, 2, 6), (0, 6, 4),      # z0
         (1, 5, 7), (1, 7, 3)]      # z1
    return v, np.array(f)


def _rueda(cx, cy, cz, lados=8):
    """Cilindro con eje x, con tapas (la exterior y la interior)."""
    a = np.arange(lados) * 2 * math.pi / lados
    ring = np.column_stack([np.zeros(lados), RUEDA_R * np.sin(a), RUEDA_R * np.cos(a)])
    xi, xo = -RUEDA_ANCHO / 2, RUEDA_ANCHO / 2
    v = np.vstack([ring + [xi, 0, 0], ring + [xo, 0, 0], [[xi, 0, 0]], [[xo, 0, 0]]]) + [cx, cy, cz]
    k = np.arange(lados)
    kn = (k + 1) % lados
    f = np.vstack([np.column_stack([k, lados + kn, kn]), np.column_stack([k, lados + k, lados + kn]),
                   np.column_stack([np.full(lados, 2 * lados), kn, k]),
                   np.column_stack([np.full(lados, 2 * lados + 1), lados + k, lados + kn])])
    return v, f


def _orientar(v, f, centro):
    """Orienta los triangulos de una malla convexa para que la normal apunte fuera de `centro`."""
    a, b, c = v[f[:, 0]], v[f[:, 1]], v[f[:, 2]]
    n = np.cross(b - a, c - a)
    dentro = (((a + b + c) / 3 - np.asarray(centro)) * n).sum(1) < 0
    f = f.copy()
    f[dentro] = f[dentro][:, ::-1]
    return f


def plantilla():
    """(vertices (n, 3), caras (m, 3), tipo (n,)) con tipo 0 = carroceria, 1 = cristal, 2 = rueda."""
    partes = []
    y0, y1 = Y_CARROCERIA
    cab_z0 = -CABINA_LARGO / 2 + CABINA_DESPL
    cab_z1 = CABINA_LARGO / 2 + CABINA_DESPL
    cajas = [(_caja(-ANCHO / 2, ANCHO / 2, y0, y1, -LARGO / 2, LARGO / 2), 0),
             (_caja(-CABINA_ANCHO / 2, CABINA_ANCHO / 2, y1, y1 + CABINA_ALTO, cab_z0, cab_z1), 0),
             (_caja(-CABINA_ANCHO / 2 - 0.02, CABINA_ANCHO / 2 + 0.02, y1 + 0.08, y1 + CABINA_ALTO - 0.17,
                    cab_z0 - 0.03, cab_z1 + 0.03), 1)]
    for (v, f), t in cajas:
        c = v.mean(0)
        partes.append((v, _orientar(v, f, c), t))
    for sx in (-1, 1):
        for sz in (-1, 1):
            v, f = _rueda(sx * RUEDA_X, RUEDA_R, sz * RUEDA_Z)
            partes.append((v, _orientar(v, f, v.mean(0)), 2))
    vs, fs, ts, off = [], [], [], 0
    for v, f, t in partes:
        vs.append(v)
        fs.append(f + off)
        ts.append(np.full(len(v), t))
        off += len(v)
    return np.vstack(vs), np.vstack(fs), np.concatenate(ts)


# ---------------------------------------------------------------- apoyo en el terreno
def _ejes(theta):
    """Ejes locales (x derecha, z atras) del coche en el plano (este, norte) para el giro Godot `theta` (rad)."""
    c, s = np.cos(theta), np.sin(theta)
    return np.stack([c, s], -1), np.stack([s, -c], -1)


def apoyo(T, x, y, theta):
    """Para coches en (x, norte) con giro Godot theta: (cota del centro, sx, sz, residuo maximo) con el plano
    y_local = cota + sx * x_local + sz * z_local ajustado a las 4 ruedas; residuo medido en 15 puntos de la huella."""
    x, y, theta = (np.atleast_1d(np.asarray(a, float)) for a in (x, y, theta))
    ex, ez = _ejes(theta)

    def altura(lx, lz):
        p = np.stack([x, y], -1) + lx * ex + lz * ez
        return T.h(p[:, 0], p[:, 1])

    hx, hz = ENTRE_EJES_X / 2, ENTRE_EJES_Z / 2
    h = {(a, b): altura(a * hx, b * hz) for a in (-1, 1) for b in (-1, 1)}
    cota = sum(h.values()) / 4
    sx = ((h[1, -1] + h[1, 1]) - (h[-1, -1] + h[-1, 1])) / 2 / ENTRE_EJES_X
    sz = ((h[-1, 1] + h[1, 1]) - (h[-1, -1] + h[1, -1])) / 2 / ENTRE_EJES_Z
    res = np.zeros(len(x))
    for lx in (-ANCHO / 2, 0.0, ANCHO / 2):
        for lz in np.linspace(-LARGO / 2, LARGO / 2, 5):
            res = np.maximum(res, np.abs(altura(lx, lz) - (cota + sx * lx + sz * lz)))
    return cota, sx, sz, res


def _bases(theta, sx, sz):
    """Matrices (n, 3, 3) columnas = ejes del coche en coordenadas de juego (x, y, z = -norte)."""
    n = len(theta)
    ex = np.stack([np.ones(n), sx, np.zeros(n)], -1)
    ez = np.stack([np.zeros(n), sz, np.ones(n)], -1)
    ey = np.cross(ez, ex)
    ey /= np.linalg.norm(ey, axis=1, keepdims=True)
    ex = np.cross(ey, ez)
    ex /= np.linalg.norm(ex, axis=1, keepdims=True)
    ez /= np.linalg.norm(ez, axis=1, keepdims=True)
    B = np.stack([ex, ey, ez], -1)                  # columnas: ex, ey, ez en el sistema "de giro"
    c, s = np.cos(theta), np.sin(theta)
    Ry = np.zeros((n, 3, 3))
    Ry[:, 0, 0], Ry[:, 0, 2], Ry[:, 1, 1], Ry[:, 2, 0], Ry[:, 2, 2] = c, s, 1.0, -s, c
    return Ry @ B


def piezas_coches(coches):
    """[(nombre_nodo, mesh, material)] en el plano local (x, norte, arriba): carroceria + habitaculo agrupados por color
    (`coches_<color>-col`, con colision), ruedas (`coches_ruedas-col`) y cristales (`coches_cristales`, sin colision)."""
    if not coches:
        return []
    pv, pf, pt = plantilla()
    n = len(coches)
    theta = np.radians([c["yaw_deg"] for c in coches])
    R = _bases(theta, np.tan(np.radians([c["roll_deg"] for c in coches])),
               np.tan(np.radians([c["pitch_deg"] for c in coches])))
    pos = np.array([c["pos"] for c in coches], float)
    V = np.einsum("nij,vj->nvi", R, pv) + pos[:, None, :]            # juego (x, y, z)
    loc = np.stack([V[..., 0], -V[..., 2], V[..., 1]], -1).reshape(-1, 3)   # a plano local (x, norte, arriba)
    F = (pf[None] + (np.arange(n) * len(pv))[:, None, None]).reshape(-1, 3)
    tipo_cara = np.tile(pt[pf[:, 0]], n)
    coche_cara = np.repeat(np.arange(n), len(pf))
    color = np.array([c["color"] for c in coches])

    def sub(mascara):
        m = trimesh.Trimesh(loc, F[mascara], process=False)
        m.remove_unreferenced_vertices()
        return m

    piezas = []
    for nombre in COLORES:
        m = (tipo_cara == 0) & (color[coche_cara] == nombre)
        if m.any():
            piezas.append((f"coches_{nombre}-col", sub(m), f"coche_{nombre}"))
    piezas.append(("coches_ruedas-col", sub(tipo_cara == 2), "coche_goma"))
    piezas.append(("coches_cristales", sub(tipo_cara == 1), "coche_cristal"))
    return piezas


# ---------------------------------------------------------------- obstaculos y comprobaciones
class Obstaculos:
    """Lo que un coche no puede pisar (geometria con holgura) y comprobaciones por lotes de huellas."""

    def __init__(self, entorno, arboles):
        e = entorno
        self.e, self.T = e, e.T
        partes = [e.macizos.buffer(0.5), e.agua.buffer(0.5) if e.agua is not None else None,
                  e.barreras.buffer(0.4) if e.barreras is not None else None,
                  e.pilares.buffer(HOLGURA_PILAR + 0.2) if e.pilares is not None else None,
                  e.spawn_pts.buffer(DIST_SPAWN) if e.spawn_pts is not None else None,
                  ]
        troncos = [Point(a["x"], a["y"]).buffer(0.5 + a["r_tronco"]) for a in arboles]    # tronco + 0,5 m
        self.bloq = unary_union([p for p in partes if p is not None] + troncos)
        shapely.prepare(self.bloq)
        shapely.prepare(e.zona)
        self.zona = e.zona
        self.techos = e.techos
        self.huellas_techo = unary_union([t["poly"] for t in self.techos]) if self.techos else None

    @staticmethod
    def rects(x, y, theta, largo=LARGO + 0.2, ancho=ANCHO + 0.2):
        ex, ez = _ejes(theta)
        c = np.stack([x, y], -1)
        a, b = ez * (largo / 2), ex * (ancho / 2)
        p = np.stack([c - a - b, c - a + b, c + a + b, c + a - b, c - a - b], 1)
        return shapely.polygons(p)

    def galibo_ok(self, x, y, theta):
        """Todos los puntos de la huella (3 x 5) deben tener >= GALIBO_MIN m bajo cualquier techo que los cubra."""
        ok = np.ones(len(x), bool)
        if not self.techos:
            return ok
        ex, ez = _ejes(theta)
        for lx in (-ANCHO / 2, 0.0, ANCHO / 2):
            for lz in np.linspace(-LARGO / 2, LARGO / 2, 5):
                p = np.stack([x, y], -1) + lx * ex + lz * ez
                for t in self.techos:
                    m = shapely.contains_xy(t["poly"], p[:, 0], p[:, 1])
                    if m.any():
                        libre = t["losa"]["bot"](p[m, 0], p[m, 1]) - self.T.h(p[m, 0], p[m, 1])
                        idx = np.nonzero(m)[0]
                        ok[idx[libre < GALIBO_MIN]] = False
        return ok

    def validos(self, x, y, theta, completo=True):
        """Mascara de coches que caben (zona, obstaculos y, si `completo`, terreno y galibo)."""
        r = self.rects(x, y, theta)
        ok = shapely.contains(self.zona, r) & ~shapely.intersects(self.bloq, r)
        if completo and ok.any():
            i = np.nonzero(ok)[0]
            cota, sx, sz, res = apoyo(self.T, x[i], y[i], theta[i])
            bien = (np.hypot(sx, sz) <= math.tan(MAX_INCLINACION)) & (res <= MAX_RESIDUO) \
                & self.galibo_ok(x[i], y[i], theta[i])
            ok[i[~bien]] = False
        return ok


# ---------------------------------------------------------------- aparcamientos
def _rejilla(coords, ang, fv, fu):
    """Centros (x, norte) y direccion v (ejes de la plaza) de las plazas de una rejilla de filas orientada `ang`.
    coords: vertices de la zona util. Devuelve (x, y, u_hat, v_hat)."""
    u = np.array([math.cos(ang), math.sin(ang)])
    v = np.array([-math.sin(ang), math.cos(ang)])
    us, vs = coords @ u, coords @ v
    u0, u1, v0, v1 = us.min(), us.max(), vs.min(), vs.max()
    vc = []
    k = 0
    while v0 - PERIODO + fv + PERIODO * k < v1:
        base = v0 - PERIODO + fv + PERIODO * k
        vc += [base + PASILLO + PLAZA_FONDO / 2, base + PASILLO + PLAZA_FONDO * 1.5]
        k += 1
    uc = np.arange(u0 + fu + PLAZA_ANCHO / 2, u1, PLAZA_ANCHO)
    UC, VC = np.meshgrid(uc, np.array(vc))
    UC, VC = UC.ravel(), VC.ravel()
    return UC * u[0] + VC * v[0], UC * u[1] + VC * v[1], u, v


def _mrr_angulo(poly):
    cs = list(poly.minimum_rotated_rectangle.exterior.coords)
    if math.dist(cs[0], cs[1]) >= math.dist(cs[1], cs[2]):
        return math.atan2(cs[1][1] - cs[0][1], cs[1][0] - cs[0][0])
    return math.atan2(cs[2][1] - cs[1][1], cs[2][0] - cs[1][0])


def plazas_parking(poly, obs):
    """Mejor rejilla de plazas del aparcamiento `poly`: (x, y, theta_base) de las plazas validas; theta_base = giro
    Godot de un coche con el morro hacia +v. Vacio si no cabe ninguna."""
    interior = poly.buffer(-MARGEN_PARKING).intersection(obs.zona)
    if interior.is_empty:
        return np.zeros((0, 3))
    shapely.prepare(interior)
    coords = shapely.get_coordinates(interior)
    ang0 = _mrr_angulo(poly)
    mejor = None
    for ori in (0.0, math.pi / 2):
        for fv in np.arange(0.0, PERIODO, 2.0):
            for fu in np.arange(0.0, PLAZA_ANCHO, 0.5):
                x, y, u, v = _rejilla(coords, ang0 + ori, fv, fu)
                theta = np.full(len(x), math.atan2(-v[0], v[1]))
                dentro = shapely.contains(interior, Obstaculos.rects(x, y, theta, PLAZA_FONDO, PLAZA_ANCHO)) \
                    & ~shapely.intersects(obs.bloq, Obstaculos.rects(x, y, theta))
                n = int(dentro.sum())
                if mejor is None or n > mejor[0]:
                    mejor = (n, x[dentro], y[dentro], theta[dentro])
    if mejor is None or mejor[0] == 0:
        return np.zeros((0, 3))
    _, x, y, theta = mejor
    ok = obs.validos(x, y, theta)
    return np.column_stack([x[ok], y[ok], theta[ok]])


def _nombre_parking(w):
    t = w.get("tags", {})
    return t.get("ref") or t.get("name") or f"sin_nombre_{w['id']}"


def coches_aparcamientos(mapa, obs, rng, ocupacion):
    """Coches de todos los aparcamientos. Devuelve (lista de coches, {nombre: (plazas, coches)})."""
    coches, resumen = [], {}
    for wid, w in sorted(mapa.ways.items()):
        if w.get("tags", {}).get("amenity") != "parking" or not mapa.cerrado(w):
            continue
        poly = mapa.poligono(w)
        if poly is None or not poly.is_valid:
            poly = poly.buffer(0) if poly is not None else None
        if poly is None or poly.is_empty:
            continue
        nombre = _nombre_parking(w)
        plazas = plazas_parking(poly, obs)
        ocupa = rng.random(len(plazas)) < ocupacion
        jit = rng.uniform(-1, 1, (len(plazas), 3))
        giro = rng.random(len(plazas)) < 0.5
        color = rng.choice(list(COLORES), len(plazas), p=_pesos())
        if len(plazas):
            x, y, th = plazas[:, 0], plazas[:, 1], plazas[:, 2] + np.where(giro, math.pi, 0.0)
            ex, ez = _ejes(th)
            x = x + jit[:, 0] * 0.15 * ex[:, 0] + jit[:, 1] * 0.2 * ez[:, 0]
            y = y + jit[:, 0] * 0.15 * ex[:, 1] + jit[:, 1] * 0.2 * ez[:, 1]
            th = th + np.radians(jit[:, 2] * 2.0)
            bien = ocupa & obs.validos(x, y, th, completo=False)
        n = 0
        for k in (np.nonzero(bien)[0] if len(plazas) else []):
            coches.append({"x": float(x[k]), "y": float(y[k]), "theta": float(th[k]), "color": str(color[k]),
                           "origen": f"parking {nombre}"})
            n += 1
        resumen[nombre] = (len(plazas), n)
    return coches, resumen


def _pesos():
    p = np.array([w for _, w in COLORES.values()], float)
    return p / p.sum()


# ---------------------------------------------------------------- carreteras
def _cruces(mapa):
    """Geometria de cruces (nodos compartidos entre vias para coches) y de rotondas."""
    vias = {"tertiary", "residential", "service", "trunk_link", "track"}
    uso = Counter()
    rot = []
    for w in mapa.ways.values():
        t = w.get("tags", {})
        if t.get("highway") not in vias:
            continue
        for n in set(w["nodes"]):
            uso[n] += 1
        if t.get("junction") == "roundabout":
            l = mapa.linea(w)
            if l is not None:
                rot.append(l)
    pts = []
    for n, c in uso.items():
        if c >= 2 and n in mapa.nodos:
            x, y = mapa.tr.transform(mapa.nodos[n]["lon"], mapa.nodos[n]["lat"])
            pts.append((x - mapa.E0, y - mapa.N0))
    g = [MultiPoint(pts)] if pts else []
    return unary_union(g + rot) if (g or rot) else None


def candidatos_via(mapa, obs, parkings, cruces):
    """Posibles coches en vias: lista de dicts {x, y, theta, via, tipo} (sin filtrar por separacion)."""
    out = []
    for w in mapa.ways.values():
        t = w.get("tags", {})
        hw = t.get("highway")
        if hw not in VIAS_APARCABLES and hw != "tertiary":
            continue
        if t.get("junction") == "roundabout":
            continue
        l = mapa.linea(w)
        if l is None or l.length < 10:
            continue
        for s in np.arange(6.0, l.length - 6.0, 4.0):
            p0, p1 = l.interpolate(s), l.interpolate(min(s + 1.0, l.length))
            tx, ty = p1.x - p0.x, p1.y - p0.y
            nrm = math.hypot(tx, ty)
            if nrm < 1e-6:
                continue
            tx, ty = tx / nrm, ty / nrm
            rx, ry = ty, -tx                               # a la derecha del sentido de la via
            if hw == "tertiary":
                lados, desp = (1, -1), ANCHO_TERTIARY / 4          # parado en un carril
            else:
                lados, desp = (1, -1), VIAS_APARCABLES[hw] / 2 - 1.1
            for lado in lados:
                fx, fy = (tx, ty) if lado == 1 else (-tx, -ty)
                out.append({"x": p0.x + rx * lado * desp, "y": p0.y + ry * lado * desp,
                            "theta": math.atan2(-fx, fy), "via": w["id"], "tipo": "tertiary" if hw == "tertiary" else "aparcado"})
    if not out:
        return out
    x = np.array([c["x"] for c in out])
    y = np.array([c["y"] for c in out])
    ok = np.ones(len(out), bool)
    pts = shapely.points(x, y)
    if cruces is not None:
        ok &= shapely.distance(pts, cruces) >= DIST_CRUCE
    if parkings is not None:
        ok &= ~shapely.contains_xy(parkings.buffer(2.0), x, y)
    return [c for c, b in zip(out, ok) if b]


def coches_carretera(mapa, obs, rng, n, parkings, ocupados):
    """Elige n coches de carretera (>= 1 en una tertiary si n >= 2) con separacion >= 40 m entre si."""
    cand = candidatos_via(mapa, obs, parkings, _cruces(mapa))
    if not cand:
        return []
    th = np.array([c["theta"] for c in cand])
    x = np.array([c["x"] for c in cand])
    y = np.array([c["y"] for c in cand])
    ok = obs.validos(x, y, th)
    if ocupados:
        ok &= ~shapely.intersects(unary_union(ocupados).buffer(1.0), obs.rects(x, y, th))
    cand = [c for c, b in zip(cand, ok) if b]
    orden = rng.permutation(len(cand))
    cand = [cand[i] for i in orden]
    n_tert = min(max(1, n // 7), n) if n > 0 else 0
    elegidos = []

    def libre(c):
        return all(math.hypot(c["x"] - e["x"], c["y"] - e["y"]) >= SEP_CARRETERA for e in elegidos)

    for tipo, cupo in (("tertiary", n_tert), ("aparcado", n - n_tert)):
        k = 0
        for c in cand:
            if k >= cupo:
                break
            if c["tipo"] == tipo and libre(c):
                elegidos.append(c)
                k += 1
    for c in cand:                      # si faltan, se completa con lo que haya (sea del tipo que sea)
        if len(elegidos) >= n:
            break
        if c not in elegidos and libre(c):
            elegidos.append(c)
    colores = rng.choice(list(COLORES), len(elegidos), p=_pesos())
    for c, col in zip(elegidos, colores):
        c["color"] = str(col)
        c["origen"] = "carretera" + (" (parado en tertiary)" if c["tipo"] == "tertiary" else "")
    return elegidos


# ---------------------------------------------------------------- conjunto
def generar_coches(mapa, entorno, arboles, rng, ocupacion=0.55, n_carretera=15):
    """Coches del mapa: aparcamientos + carretera. Devuelve (lista de dicts con pos / yaw / pitch / roll, stats)."""
    obs = Obstaculos(entorno, arboles)
    lista, resumen = coches_aparcamientos(mapa, obs, rng, ocupacion)
    rects = [Obstaculos.rects(np.array([c["x"]]), np.array([c["y"]]), np.array([c["theta"]]))[0] for c in lista]
    carr = coches_carretera(mapa, obs, rng, n_carretera, entorno.parkings, rects)
    lista = lista + carr
    T = entorno.T
    x = np.array([c["x"] for c in lista])
    y = np.array([c["y"] for c in lista])
    th = np.array([c["theta"] for c in lista])
    cota, sx, sz, res = apoyo(T, x, y, th) if lista else (np.zeros(0),) * 4
    out = []
    for i, c in enumerate(lista):
        out.append({"id": i, "pos": [round(float(x[i]), 3), round(float(cota[i]) - 0.02, 3), round(float(-y[i]), 3)],
                    "yaw_deg": round(math.degrees(th[i]) % 360, 2),
                    "pitch_deg": round(math.degrees(math.atan(sz[i])), 2),
                    "roll_deg": round(math.degrees(math.atan(sx[i])), 2),
                    "color": c["color"], "origen": c["origen"], "plaza": c["origen"].startswith("parking")})
    stats = {"coches": len(out), "coches_parking": len(lista) - len(carr), "coches_carretera": len(carr),
             "por_parking": {k: {"plazas": v[0], "coches": v[1]} for k, v in resumen.items()}}
    return out, stats


def rect_coche(c):
    """Poligono (plano local) de la huella de un coche generado."""
    return Obstaculos.rects(np.array([c["pos"][0]]), np.array([-c["pos"][2]]),
                            np.array([math.radians(c["yaw_deg"])]), LARGO, ANCHO)[0]


def candidato_test(coches, T, entorno):
    """Coche de aparcamiento para el test de rayo horizontal: el mas llano del mayor numero posible de aparcamientos
    de gran tamano, con el rayo (a 0,8 m sobre el terreno) por su eje largo desde el pasillo, sin nada intermedio.
    Devuelve dict o None."""
    rects = [rect_coche(c) for c in coches]
    arbol = shapely.STRtree(rects)
    mejor = None
    for i, c in enumerate(coches):
        if not c["plaza"] or abs(c["pitch_deg"]) > 1.5 or abs(c["roll_deg"]) > 1.5:
            continue
        th = math.radians(c["yaw_deg"])
        fx, fy = -math.sin(th), math.cos(th)            # morro en el plano (este, norte)
        cx, cy = c["pos"][0], -c["pos"][2]
        for lado in (1, -1):
            a = (cx + lado * fx * (LARGO / 2 + 2.8), cy + lado * fy * (LARGO / 2 + 2.8))
            seg = LineString([a, (cx, cy)])
            vecinos = [j for j in arbol.query(seg) if j != i and rects[j].intersects(seg)]
            if vecinos or not entorno.zona.contains(Point(a)) or entorno.macizos.distance(Point(a)) < 1.0:
                continue
            if entorno.barreras is not None and entorno.barreras.distance(seg) < 0.5:
                continue
            if entorno.pilares is not None and entorno.pilares.distance(seg) < 0.7:
                continue
            ya = float(T.h(a[0], a[1]))
            yc = c["pos"][1]
            pend = abs(ya - yc)
            if mejor is None or pend < mejor[0]:
                mejor = (pend, i, a, (cx, cy), yc)
    if mejor is None:
        return None
    _, i, a, b, yc = mejor
    c = coches[i]
    return {"id": c["id"], "origen": c["origen"], "color": c["color"],
            "desde": [round(a[0], 2), round(yc + 0.8, 3), round(-a[1], 2)],
            "hasta": [round(b[0], 2), round(yc + 0.8, 3), round(-b[1], 2)]}
