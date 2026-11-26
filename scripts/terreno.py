"""Relieve del campus: carga un raster de cotas (GeoTIFF en EPSG:25830), lo limpia y ofrece
altura(x, z) en coordenadas del juego (x = este, z = -norte, y = cota - cota_ref).

Independiente de la fuente: sirve el MDT de 5 m del IGN (data/raw/mdt_upo.tif) o un MDT de 1 m
sacado de LiDAR con el mismo formato. Solo usa numpy + rasterio.

Limpieza: nodata rellenado por interpolacion (promedio iterativo de vecinos), mediana 3x3
(artefactos puntuales) y suavizado gaussiano de sigma `suavizado_m` (0 = sin suavizar).
cota_ref = mediana de las cotas limpias dentro del contorno del campus.

Uso como libreria:
    T = Terreno.desde_raster("data/raw/mdt_upo.tif", E0, N0, campus_poly_local, suavizado_m=5)
    y = T.altura(x, z)          # arrays o escalares; altura de la malla de terreno exportada (ver altura())
    T = Terreno.plano()         # altura 0 en todas partes (comportamiento anterior)
"""
import math
from pathlib import Path

import numpy as np
import shapely

# Valores por defecto de las opciones de terreno. Estan AQUI (y solo aqui) para que generar_blockout.py y
# generar_spawns.py no se desincronicen: los dos llaman a anadir_argumentos().
MDT_DEFECTO = "data/raw/mdt_lidar_1m.tif"      # MDT de 1 m desde LiDAR PNOA (scripts/lidar_procesar.py)
MDT_ALTERNATIVO = "data/raw/mdt_upo.tif"       # MDT de 5 m del IGN (scripts/terreno_mdt.py): --mdt data/raw/mdt_upo.tif
SUAVIZADO_DEFECTO_M = 1.0                      # sigma del suavizado gaussiano (el MDT de 1 m ya viene filtrado)
PASO_TERRENO_DEFECTO_M = 1.0                   # paso FINO: en la zona de detalle
PASO_GRUESO_DEFECTO_M = 4.0                    # paso del resto del mapa (bloques de 4 x 4 m)
BUFFER_FINO_DEFECTO_M = 8.0                    # radio de la zona fina alrededor de escaleras, muros, caminos peatonales, pasillo


def anadir_argumentos(ap):
    """Opciones de linea de comandos comunes a generar_blockout.py y generar_spawns.py."""
    ap.add_argument("--mdt", default=MDT_DEFECTO, help="raster de cotas GeoTIFF en EPSG:25830 (defecto %(default)s)")
    ap.add_argument("--terreno", choices=("mdt", "plano"), default="mdt",
                    help="mdt = relieve del raster; plano = suelo plano en y=0 (comportamiento anterior)")
    ap.add_argument("--paso-terreno", type=float, default=PASO_TERRENO_DEFECTO_M,
                    help="paso FINO (m) de la malla del terreno y de la densificacion de lo que se apoya en el "
                         "(defecto %(default)s)")
    ap.add_argument("--paso-grueso", type=float, default=PASO_GRUESO_DEFECTO_M,
                    help="paso (m) fuera de la zona fina = lado de los bloques; multiplo de --paso-terreno. "
                         "Si es <= --paso-terreno la malla es uniforme (defecto %(default)s)")
    ap.add_argument("--buffer-fino", type=float, default=BUFFER_FINO_DEFECTO_M,
                    help="radio (m) de la zona de paso fino alrededor de highway=steps/footway/path/pedestrian, "
                         "barrier=retaining_wall y el pasillo central (defecto %(default)s; 0 = sin zona fina)")
    ap.add_argument("--suavizado-m", type=float, default=SUAVIZADO_DEFECTO_M,
                    help="sigma (m) del suavizado gaussiano del MDT (0 = sin suavizar; defecto %(default)s)")


def _rellenar_nodata(a, malo):
    """Sustituye las celdas `malo` por el promedio de sus vecinos validos, de fuera hacia dentro."""
    a = a.copy()
    malo = malo.copy()
    if malo.all():
        raise SystemExit("El raster de cotas no tiene ningun valor valido")
    for _ in range(max(a.shape)):
        if not malo.any():
            break
        v = np.where(malo, 0.0, a)
        w = (~malo).astype(float)
        sv = np.zeros_like(v)
        sw = np.zeros_like(v)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            sv += np.roll(v, (dy, dx), (0, 1))
            sw += np.roll(w, (dy, dx), (0, 1))
        nuevo = malo & (sw > 0)
        a[nuevo] = sv[nuevo] / sw[nuevo]
        malo = malo & ~nuevo
    return a


def _mediana3(a):
    p = np.pad(a, 1, mode="edge")
    h, w = a.shape
    pila = np.stack([p[i:i + h, j:j + w] for i in range(3) for j in range(3)])
    return np.median(pila, axis=0)


def _gauss(a, sigma_px):
    if sigma_px <= 0:
        return a
    r = max(1, int(math.ceil(3 * sigma_px)))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma_px) ** 2)
    k /= k.sum()
    for eje in (0, 1):
        p = np.pad(a, [(r, r) if i == eje else (0, 0) for i in range(2)], mode="reflect")
        n = a.shape[eje]
        a = sum(k[i] * np.take(p, np.arange(i, i + n), axis=eje) for i in range(2 * r + 1))
    return a


class Terreno:
    def __init__(self):
        self.es_plano = True
        self.cota_ref = 0.0
        self.fuente = "plano"
        self.resolucion_m = None
        self.suavizado_m = 0.0
        self.cota_min = self.cota_max = 0.0
        self.paso_malla = None      # paso fino
        self.paso_bloque = None     # lado de los bloques (= paso grueso; = paso_malla si la malla es uniforme)
        self._tipo = None           # None = malla uniforme; si no, tipo de cada bloque (ver definir_zona_fina)
        self.zona_fina_area_m2 = 0.0

    @classmethod
    def plano(cls):
        return cls()

    @classmethod
    def desde_raster(cls, ruta, E0, N0, campus_local, suavizado_m=SUAVIZADO_DEFECTO_M, paso_malla=PASO_TERRENO_DEFECTO_M):
        """E0, N0: origen del juego en EPSG:25830. campus_local: Polygon del contorno en (x, norte) locales.
        paso_malla: paso (m) de la malla de terreno exportada (ver altura())."""
        import rasterio
        ruta = Path(ruta)
        if not ruta.exists():
            raise SystemExit(f"No existe el raster de cotas {ruta} (ver scripts/terreno_mdt.py; o usa --terreno plano)")
        with rasterio.open(ruta) as ds:
            if ds.crs is None or ds.crs.to_epsg() != 25830:
                raise SystemExit(f"{ruta}: el raster debe estar en EPSG:25830 (CRS={ds.crs})")
            t = ds.transform
            if abs(t.b) > 1e-9 or abs(t.d) > 1e-9 or t.e >= 0 or abs(abs(t.e) - t.a) > 1e-6:
                raise SystemExit(f"{ruta}: se espera un raster norte-arriba con pixel cuadrado")
            a = ds.read(1).astype(np.float64)
            nodata = ds.nodata
        res = float(t.a)
        malo = ~np.isfinite(a) | (a < -1000)
        if nodata is not None:
            malo |= a == nodata
        n_malo = int(malo.sum())
        a = _rellenar_nodata(a, malo)
        a = _mediana3(a)
        a = _gauss(a, suavizado_m / res)

        o = cls()
        o.es_plano = False
        o._a = a
        o._res = res
        # centro de pixel (i, j) en el juego: x = E - E0 ; z = -(N - N0)
        o._x0 = t.c + res / 2 - E0
        o._z0 = -(t.f - res / 2 - N0)          # fila 0 = norte mas alto = z mas pequeno
        o._dz = res                            # z crece con el indice de fila
        ny, nx = a.shape
        xs = o._x0 + np.arange(nx) * res
        zs = o._z0 + np.arange(ny) * res
        X, Z = np.meshgrid(xs, zs)
        dentro = shapely.contains_xy(campus_local, X.ravel(), -Z.ravel()).reshape(X.shape)
        if not dentro.any():
            raise SystemExit("El raster no cubre el contorno del campus")
        o.paso_malla = float(paso_malla)
        o.paso_bloque = o.paso_malla
        o.cota_ref = float(np.median(a[dentro]))
        o.fuente = str(ruta).replace("\\", "/")
        o.resolucion_m = res
        o.suavizado_m = float(suavizado_m)
        o.nodata_rellenado = n_malo
        o.cota_min = float(a[dentro].min())
        o.cota_max = float(a[dentro].max())
        o.extension = (float(xs[0]), float(xs[-1]), float(zs[0]), float(zs[-1]))
        return o

    def altura_raster(self, x, z):
        """y de juego (cota - cota_ref) interpolando bilinealmente el raster limpio; fuera de el se repite el borde."""
        x = np.asarray(x, dtype=float)
        z = np.asarray(z, dtype=float)
        if self.es_plano:
            return np.zeros(np.broadcast(x, z).shape)
        ny, nx = self._a.shape
        fx = np.clip((x - self._x0) / self._res, 0, nx - 1)
        fz = np.clip((z - self._z0) / self._dz, 0, ny - 1)
        j0 = np.minimum(fx.astype(int), nx - 2)
        i0 = np.minimum(fz.astype(int), ny - 2)
        tx, tz = fx - j0, fz - i0
        a = self._a
        c = (a[i0, j0] * (1 - tx) * (1 - tz) + a[i0, j0 + 1] * tx * (1 - tz)
             + a[i0 + 1, j0] * (1 - tx) * tz + a[i0 + 1, j0 + 1] * tx * tz)
        return c - self.cota_ref

    # ------------------------------------------------------------------ malla de resolucion variable
    # La malla exportada se compone de BLOQUES de paso_bloque x paso_bloque m alineados con el origen:
    #   tipo 0 (grueso): 2 triangulos (diagonal suroeste-noreste).
    #   tipo 1 (fino, dentro de la zona fina): (bloque/paso_malla)^2 celdas de paso_malla, 2 triangulos cada una.
    #   tipo 2 (transicion: bloque grueso con algun lado en contacto con un bloque fino): abanico de triangulos
    #     desde el centro del bloque hasta su perimetro, que incluye los vertices de paso_malla de los lados vecinos
    #     de un bloque fino. Asi los dos lados de cada arista comparten exactamente los mismos vertices (sin
    #     uniones en T).
    # Sin zona fina (_tipo None) toda la malla es de tipo 0 con paso_malla (rejilla regular de siempre).
    def definir_zona_fina(self, zona, paso_grueso):
        """zona: geometria shapely (x, norte local) donde la malla usa paso_malla; fuera, bloques de paso_grueso."""
        f, G = self.paso_malla, float(paso_grueso)
        if self.es_plano or zona is None or zona.is_empty or G <= f + 1e-9:
            return
        r = round(G / f)
        if abs(r * f - G) > 1e-6:
            raise SystemExit(f"--paso-grueso ({G:g}) debe ser multiplo de --paso-terreno ({f:g})")
        x0, y0, x1, y1 = zona.bounds
        self._bi0, self._bj0 = math.floor(x0 / G) - 2, math.floor(y0 / G) - 2
        ni, nj = math.ceil(x1 / G) + 2 - self._bi0, math.ceil(y1 / G) + 2 - self._bj0
        ii, jj = np.meshgrid(np.arange(ni) + self._bi0, np.arange(nj) + self._bj0, indexing="ij")
        shapely.prepare(zona)
        fino = shapely.intersects(zona, shapely.box(ii * G, jj * G, (ii + 1) * G, (jj + 1) * G))
        pad = np.pad(fino, 1)
        # bits: 1 = vecino sur fino, 2 = este, 4 = norte, 8 = oeste (indices [i, j]: i = este, j = norte)
        lado = (pad[1:-1, :-2] * 1 + pad[2:, 1:-1] * 2 + pad[1:-1, 2:] * 4 + pad[:-2, 1:-1] * 8)
        lado = np.where(fino, 0, lado)
        self._lado = lado.astype(np.int8)
        self._tipo = np.where(fino, 1, np.where(lado > 0, 2, 0)).astype(np.int8)
        self.paso_bloque = G
        self._r = int(r)
        self.zona_fina_area_m2 = float(fino.sum() * G * G)

    def tipo_bloque(self, i, j):
        """Tipo (0 grueso, 1 fino, 2 transicion) de los bloques de indices (i, j) (arrays enteros)."""
        i, j = np.asarray(i), np.asarray(j)
        if self._tipo is None:
            return np.zeros(np.broadcast(i, j).shape, np.int8)
        a, b = i - self._bi0, j - self._bj0
        ok = (a >= 0) & (b >= 0) & (a < self._tipo.shape[0]) & (b < self._tipo.shape[1])
        return np.where(ok, self._tipo[np.clip(a, 0, self._tipo.shape[0] - 1),
                                       np.clip(b, 0, self._tipo.shape[1] - 1)], 0)

    def _perimetro(self, i, j):
        """Perimetro (antihorario desde el suroeste) del bloque de transicion (i, j), con los vertices de paso_malla
        de los lados en contacto con bloques finos."""
        G, f = self.paso_bloque, self.paso_malla
        lado = int(self._lado[i - self._bi0, j - self._bj0])
        x0, y0 = i * G, j * G
        k = np.arange(1, self._r) * f
        pts = [(x0, y0)]
        if lado & 1:
            pts += [(x0 + q, y0) for q in k]
        pts.append((x0 + G, y0))
        if lado & 2:
            pts += [(x0 + G, y0 + q) for q in k]
        pts.append((x0 + G, y0 + G))
        if lado & 4:
            pts += [(x0 + G - q, y0 + G) for q in k]
        pts.append((x0, y0 + G))
        if lado & 8:
            pts += [(x0, y0 + G - q) for q in k]
        return np.array(pts, float)

    def facetas_bloques(self, i, j):
        """Triangulos (N, 3, 2) en (x, norte), antihorarios (normal +arriba), de los bloques (i, j)."""
        i, j = np.atleast_1d(i).astype(int), np.atleast_1d(j).astype(int)
        G, f = self.paso_bloque, self.paso_malla
        tipo = self.tipo_bloque(i, j)
        out = []
        m = tipo == 0
        if m.any():
            x, y = i[m] * G, j[m] * G
            sw, se, ne, nw = (np.stack([x + dx, y + dy], -1) for dx, dy in ((0, 0), (G, 0), (G, G), (0, G)))
            out.append(np.stack([np.stack([sw, se, ne], 1), np.stack([sw, ne, nw], 1)], 1).reshape(-1, 3, 2))
        m = tipo == 1
        if m.any():
            r = self._r
            a, b = np.meshgrid(np.arange(r), np.arange(r), indexing="ij")
            x = (i[m][:, None] * G + a.ravel()[None, :] * f).ravel()
            y = (j[m][:, None] * G + b.ravel()[None, :] * f).ravel()
            sw, se, ne, nw = (np.stack([x + dx, y + dy], -1) for dx, dy in ((0, 0), (f, 0), (f, f), (0, f)))
            out.append(np.stack([np.stack([sw, se, ne], 1), np.stack([sw, ne, nw], 1)], 1).reshape(-1, 3, 2))
        for q in np.nonzero(tipo == 2)[0]:
            P = self._perimetro(i[q], j[q])
            c = np.array([(i[q] + 0.5) * G, (j[q] + 0.5) * G])
            out.append(np.stack([np.broadcast_to(c, P.shape), P, np.roll(P, -1, axis=0)], 1))
        return np.concatenate(out) if out else np.zeros((0, 3, 2))

    def _celda(self, x, n, p):
        """Altura de la rejilla regular de paso p (nodos = altura_raster; diagonal suroeste-noreste)."""
        i, j = np.floor(x / p), np.floor(n / p)
        tx, ty = x / p - i, n / p - j
        x0, n0 = i * p, j * p
        r = self.altura_raster
        h00, h10, h01, h11 = r(x0, -n0), r(x0 + p, -n0), r(x0, -(n0 + p)), r(x0 + p, -(n0 + p))
        return np.where(tx >= ty, h00 + (h10 - h00) * tx + (h11 - h10) * ty,
                        h00 + (h11 - h01) * tx + (h01 - h00) * ty)

    def _abanico(self, x, n, i, j):
        """Altura en los puntos (x, n) de UN bloque de transicion (i, j)."""
        P = self._perimetro(i, j)
        G = self.paso_bloque
        c = np.array([(i + 0.5) * G, (j + 0.5) * G])
        r = self.altura_raster
        hP, hC = r(P[:, 0], -P[:, 1]), float(r(c[0], -c[1]))
        ang = np.arctan2(P[:, 1] - c[1], P[:, 0] - c[0])
        rel = np.mod(ang - ang[0], 2 * np.pi)
        aq = np.mod(np.arctan2(n - c[1], x - c[0]) - ang[0], 2 * np.pi)
        k = np.clip(np.searchsorted(rel, aq, side="right") - 1, 0, len(P) - 1)
        k1 = (k + 1) % len(P)
        u, v = P[k] - c, P[k1] - c
        qx, qy = x - c[0], n - c[1]
        det = u[:, 0] * v[:, 1] - u[:, 1] * v[:, 0]
        s = (qx * v[:, 1] - qy * v[:, 0]) / det
        t = (u[:, 0] * qy - u[:, 1] * qx) / det
        return hC + s * (hP[k] - hC) + t * (hP[k1] - hC)

    def altura(self, x, z):
        """y de juego en (x, z) de juego: la altura de la SUPERFICIE DEL TERRENO TAL COMO SE EXPORTA (ver arriba:
        bloques gruesos, finos y de transicion; nodos = altura_raster). Asi todo lo que se apoya en el terreno
        (spawns, caminos, tests) coincide exactamente con la colision. Sin malla fijada (o en plano) = altura_raster."""
        if self.es_plano or self.paso_malla is None:
            return self.altura_raster(x, z)
        x = np.asarray(x, dtype=float)
        n = -np.asarray(z, dtype=float)
        if self._tipo is None:
            return self._celda(x, n, self.paso_malla)
        x, n = np.broadcast_arrays(x, n)
        forma = x.shape
        x, n = x.ravel(), n.ravel()
        G = self.paso_bloque
        i, j = np.floor(x / G).astype(int), np.floor(n / G).astype(int)
        tipo = self.tipo_bloque(i, j)
        out = np.empty(x.shape)
        m = tipo == 0
        out[m] = self._celda(x[m], n[m], G)
        m = tipo == 1
        out[m] = self._celda(x[m], n[m], self.paso_malla)
        m2 = np.nonzero(tipo == 2)[0]
        if len(m2):
            clave = i[m2].astype(np.int64) * 1_000_003 + j[m2]
            for c in np.unique(clave):
                sel = m2[clave == c]
                out[sel] = self._abanico(x[sel], n[sel], int(i[sel[0]]), int(j[sel[0]]))
        return out.reshape(forma)

    def h(self, x, norte):
        """Igual que altura() pero con la coordenada norte local (plano de trabajo de generar_blockout)."""
        return self.altura(x, -np.asarray(norte, dtype=float))

    def pendiente_max_grados(self, paso=1.0):
        """Pendiente maxima (grados) del terreno dentro del raster (diferencias finitas)."""
        if self.es_plano:
            return 0.0
        gz, gx = np.gradient(self._a, self._res)
        return float(np.degrees(np.arctan(np.hypot(gx, gz).max())))

    def info(self):
        return {"fuente": self.fuente, "resolucion_m": self.resolucion_m, "suavizado_m": self.suavizado_m,
                "paso_fino_m": self.paso_malla, "paso_grueso_m": self.paso_bloque,
                "zona_fina_m2": round(self.zona_fina_area_m2),
                "cota_ref": round(self.cota_ref, 4),
                "cota_min_campus": round(self.cota_min, 2), "cota_max_campus": round(self.cota_max, 2)}


def crear(a, E0, N0, campus_local, zona_fina=None):
    """Terreno segun los argumentos de anadir_argumentos(). zona_fina: geometria shapely (x, norte local) donde la
    malla usa --paso-terreno; fuera, bloques de --paso-grueso (ver generar_blockout.zona_fina)."""
    if a.terreno == "plano":
        return Terreno.plano()
    T = Terreno.desde_raster(a.mdt, E0, N0, campus_local, a.suavizado_m, a.paso_terreno)
    T.definir_zona_fina(zona_fina, a.paso_grueso)
    return T
