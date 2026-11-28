"""Estimacion de recorridos a pie dentro de una zona competitiva (plano local: x = este, y = norte).

Metodo (documentado tambien en el README): se rasteriza la zona en celdas de PASO m; una celda es transitable si esta dentro
del limite (0,5 m de margen), la pendiente entre celdas vecinas no pasa de 45 grados y no toca ningun obstaculo
engrosado con el radio del jugador (0,35 m + 0,05): edificios volumen, pilares, muros y vallas, troncos, coches y props.
Entre celdas vecinas (8 direcciones) el coste es la distancia horizontal (el agua del campus no tiene colision y se pisa igual). El tiempo de un recorrido es longitud / VEL_MS (5 m/s: la velocidad de correr del jugador).
Esto es una estimacion de diseno; el test de Godot (test_zonas.gd, z4) lo comprueba con NavigationServer3D sobre una malla
horneada de la propia zona.
"""
import math

import numpy as np
import shapely
from scipy import ndimage as ndi
from scipy.sparse import csr_matrix, diags
from scipy.sparse.csgraph import dijkstra
from shapely.geometry import LineString, Point
from shapely.ops import unary_union

import coches as coc

VEL_MS = 5.0
PASO = 0.5
RADIO_JUGADOR = 0.40
PENDIENTE_MAX = 0.9           # ~42 grados (el jugador sube hasta 45)
MARGEN_LIMITE = 0.5
COBERTURA_ALTA_M = 0.8        # un obstaculo cuenta como cobertura si supera esta altura
DIST_COBERTURA_M = 3.0
TRAMO_ABIERTO_MAX_M = 25.0


def edificios_cerrados(geo):
    """Union de las huellas de los edificios macizos (forma != techo) menos los pasos peatonales abiertos (sin galibo o con
    galibo >= 2 m): lo que de verdad ocupa el suelo y bloquea."""
    macizos = [e["poly"] for e in geo["edificios"] if e["forma"] != "techo"]
    if not macizos:
        return None
    g = unary_union(macizos)
    pasos = [p["poly"] for p in geo.get("pasos", []) if p["galibo"] is None or p["galibo"] >= 2.0]
    return g.difference(unary_union(pasos)) if pasos else g


def obstaculos_mundo(geo, entorno, arboles, coches, huellas_props):
    """Dict de geometrias bloqueantes (ya engrosadas con el radio del jugador), plano local."""
    r = RADIO_JUGADOR
    d = {}
    cerrados = edificios_cerrados(geo)
    d["edificios"] = cerrados.buffer(r) if cerrados is not None else None
    pil = [Point(p).buffer(0.2 + r, 4) for e in geo["edificios"] for p in e["pilares"]]
    d["pilares"] = unary_union(pil) if pil else None
    lineas = []
    if entorno.barreras is not None:
        lineas.append(entorno.barreras.buffer(0.1 + r))
    for info in geo.get("suelos", {}).values():
        for a, b, _, _ in info["muros"]:
            lineas.append(LineString([a, b]).buffer(0.2 + r))
    d["barreras"] = unary_union(lineas) if lineas else None
    for pi in geo.get("pistas", []):
        lineas.append(pi["poly"].exterior.buffer(0.1 + r))
    d["troncos"] = unary_union([Point(t["x"], t["y"]).buffer(t["r_tronco"] + r, 8) for t in arboles]) if arboles else None
    d["coches"] = unary_union([coc.rect_coche(c).buffer(r) for c in coches]) if coches else None
    d["props"] = unary_union([g.buffer(r) for g in huellas_props]) if huellas_props else None
    return d


class Rejilla:
    def __init__(self, T, poligono, obst, paso=PASO):
        self.T, self.poligono, self.paso = T, poligono, paso
        x0, y0, x1, y1 = poligono.bounds
        self.x0, self.y0 = x0 - 1.0, y0 - 1.0
        self.nx = int(math.ceil((x1 - x0 + 2.0) / paso))
        self.ny = int(math.ceil((y1 - y0 + 2.0) / paso))
        xs = self.x0 + (np.arange(self.nx) + 0.5) * paso
        ys = self.y0 + (np.arange(self.ny) + 0.5) * paso
        self.X, self.Y = np.meshgrid(xs, ys)          # [fila (y), columna (x)]
        px, py = self.X.ravel(), self.Y.ravel()
        dentro = shapely.contains_xy(poligono.buffer(-MARGEN_LIMITE), px, py)
        bloq = np.zeros(px.shape, bool)
        for g in obst.values():
            if g is not None and not g.is_empty:
                shapely.prepare(g)
                bloq |= shapely.contains_xy(g, px, py)
        self.H = np.asarray(T.h(px, py)).reshape(self.ny, self.nx)
        self.libre = (dentro & ~bloq).reshape(self.ny, self.nx)
        self._grafo = None

    # ---- indices
    def celda(self, x, y):
        i = int((y - self.y0) / self.paso)
        j = int((x - self.x0) / self.paso)
        return min(max(i, 0), self.ny - 1), min(max(j, 0), self.nx - 1)

    def celda_libre_cercana(self, x, y, radio=6.0):
        """Celda transitable mas cercana a (x, y) (en la misma si ya lo es)."""
        i, j = self.celda(x, y)
        if self.libre[i, j]:
            return i, j
        r = int(radio / self.paso)
        i0, i1, j0, j1 = max(i - r, 0), min(i + r + 1, self.ny), max(j - r, 0), min(j + r + 1, self.nx)
        sub = np.argwhere(self.libre[i0:i1, j0:j1])
        if len(sub) == 0:
            return None
        d = (sub[:, 0] + i0 - i) ** 2 + (sub[:, 1] + j0 - j) ** 2
        k = int(np.argmin(d))
        return int(sub[k, 0] + i0), int(sub[k, 1] + j0)

    def _construir_grafo(self):
        """Grafo disperso de celdas transitables con 8 vecinos; una arista se corta si la pendiente entre las dos celdas
        supera PENDIENTE_MAX o (en diagonal) si alguna de las dos celdas laterales esta bloqueada."""
        ny, nx = self.ny, self.nx
        idx = np.arange(ny * nx).reshape(ny, nx)
        lib = self.libre.ravel()
        Hf = self.H.ravel()
        filas, cols, pesos = [], [], []
        for di, dj in ((0, 1), (1, 0), (1, 1), (1, -1)):
            jlo, jhi = max(0, -dj), nx - max(0, dj)
            a = idx[0:ny - di, jlo:jhi].ravel()
            b = idx[di:ny, jlo + dj:jhi + dj].ravel()
            w = math.hypot(di, dj) * self.paso
            ok = lib[a] & lib[b] & (np.abs(Hf[a] - Hf[b]) <= PENDIENTE_MAX * w)
            if di and dj:
                ok &= lib[a + dj] & lib[a + di * nx]
            filas.append(a[ok])
            cols.append(b[ok])
            pesos.append(np.full(int(ok.sum()), w))
        f, c, w = np.concatenate(filas), np.concatenate(cols), np.concatenate(pesos)
        self._grafo = csr_matrix((np.concatenate([w, w]), (np.concatenate([f, c]), np.concatenate([c, f]))),
                                 shape=(ny * nx, ny * nx))
        return self._grafo

    @property
    def grafo(self):
        return self._grafo if self._grafo is not None else self._construir_grafo()

    def distancias(self, origenes, grafo=None):
        """Matriz [len(origenes), ny*nx] de distancias (m) por la red; origenes = lista de (x, y) locales."""
        ids = []
        for x, y in origenes:
            c = self.celda_libre_cercana(x, y)
            if c is None:
                raise ValueError(f"({x:.1f}, {y:.1f}) no esta cerca de ninguna celda transitable")
            ids.append(c[0] * self.nx + c[1])
        return dijkstra(grafo if grafo is not None else self.grafo, directed=False, indices=ids), ids

    def camino(self, origen, destino, grafo=None):
        """Lista de (x, y) del camino mas corto origen -> destino y su longitud (m); (None, inf) si no hay."""
        g = grafo if grafo is not None else self.grafo
        co = self.celda_libre_cercana(*origen)
        cd = self.celda_libre_cercana(*destino)
        if co is None or cd is None:
            return None, math.inf
        so, sd = co[0] * self.nx + co[1], cd[0] * self.nx + cd[1]
        dist, pred = dijkstra(g, directed=False, indices=so, return_predecessors=True)
        if not math.isfinite(dist[sd]):
            return None, math.inf
        out = []
        k = sd
        while k >= 0 and k != so:
            out.append(k)
            k = pred[k]
        out.append(so)
        out.reverse()
        pts = [(self.x0 + ((k % self.nx) + 0.5) * self.paso, self.y0 + ((k // self.nx) + 0.5) * self.paso) for k in out]
        return pts, float(dist[sd])

    def rutas_alternativas(self, origen, destino, maxima=6, banda=3.0, factor=2.2, extremos=12.0):
        """Rutas distintas origen -> destino: tras cada camino se bloquea una banda de `banda` m alrededor de su tramo
        central (sin los `extremos` m de cada punta) y se repite. Cuenta las que miden <= factor x la mas corta.
        Devuelve lista de (longitud, camino)."""
        g0 = self.grafo
        bloqueo = np.zeros(self.ny * self.nx, bool)
        out = []
        base = None
        g = g0
        for _ in range(maxima):
            pts, L = self.camino(origen, destino, g)
            if pts is None:
                break
            if base is None:
                base = L
            if L > factor * base:
                break
            out.append((L, pts))
            # acumulado a lo largo del camino para respetar las puntas
            acum = np.concatenate([[0.0], np.cumsum(np.hypot(*np.diff(np.array(pts), axis=0).T))])
            medio = [p for p, s in zip(pts, acum) if extremos < s < L - extremos]
            if not medio:
                break
            ia = np.array([self.celda(*p) for p in medio])
            m = np.zeros((self.ny, self.nx), bool)
            m[ia[:, 0], ia[:, 1]] = True
            m = ndi.binary_dilation(m, iterations=int(banda / self.paso))
            bloqueo |= m.ravel()
            D = diags((~bloqueo).astype(float))
            g = (D @ g0 @ D).tocsr()
        return out

    def altura(self, x, y):
        return float(self.T.h(x, y))


def tramos_abiertos(camino, obst_cobertura, dist=DIST_COBERTURA_M, ignorar=None):
    """Longitud maxima (m) de un tramo del camino sin ninguna cobertura a < `dist` m, y la lista de (inicio_s, fin_s, punto_medio)
    de los tramos que superan TRAMO_ABIERTO_MAX_M. obst_cobertura: geometria shapely (union de obstaculos altos, SIN engrosar).
    ignorar: geometria (las barreras de spawn + 4 m) donde no se exige cobertura (nadie combate dentro de su spawn)."""
    if camino is None or len(camino) < 2:
        return 0.0, []
    pts = np.array(camino)
    seg = np.hypot(*np.diff(pts, axis=0).T)
    s = np.concatenate([[0.0], np.cumsum(seg)])
    # muestreo cada 1 m
    ss = np.arange(0.0, s[-1], 1.0)
    xs = np.interp(ss, s, pts[:, 0])
    ys = np.interp(ss, s, pts[:, 1])
    if obst_cobertura is None or obst_cobertura.is_empty:
        cerca = np.zeros(len(ss), bool)
    else:
        shapely.prepare(obst_cobertura)
        cerca = shapely.dwithin(shapely.points(xs, ys), obst_cobertura, dist)
    if ignorar is not None and not ignorar.is_empty:
        cerca = cerca | shapely.contains_xy(ignorar, xs, ys)
    mx, ini, tramos = 0.0, None, []
    for k, c in enumerate(cerca):
        if not c and ini is None:
            ini = k
        if (c or k == len(cerca) - 1) and ini is not None:
            fin = k if c else k + 1
            largo = fin - ini
            mx = max(mx, largo)
            if largo > TRAMO_ABIERTO_MAX_M:
                m = (ini + fin) // 2
                tramos.append((float(ss[ini]), float(ss[min(fin, len(ss) - 1)]), (float(xs[m]), float(ys[m]))))
            ini = None
    return float(mx), tramos
