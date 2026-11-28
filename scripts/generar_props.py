"""Propone las posiciones de las coberturas (props) y escribe data/props.csv. Despues se editan a mano.

Columnas del CSV: tipo, x, z, yaw, escala, notas (ver scripts/props.py). generar_blockout.py lee el CSV y mete los props
en el glb (`props_<material>-col`); este script solo PROPONE: no sobrescribe un CSV existente sin --forzar.

Reglas de la propuesta (todas sobre el terreno y la geometria reales, mismas opciones que generar_blockout.py):
  1. Aula al aire libre: 4 filas de 4 asientos mirando a una pizarra, en el bosque de `detras_22` junto al Edificio 24, en un
     claro (la columna notas lleva `claro=R`: ningun tronco a R m).
  2. Dentro de cada zona: cobertura alrededor de cada site (3-9 m del centro) y, a lo largo de las rutas (spawn -> site y
     alternativas), un prop cada vez que quedaria un tramo de mas de ~22 m sin cobertura (edificio, tronco de >= 0,45 m, coche,
     muro o prop de >= 0,8 m a menos de 3 m). Van a 1,1 m o mas de la ruta, nunca encima. Murete y banco se colocan de
     traves a la ruta. Ademas, grupos junto a las fachadas (maquinas expendedoras, contenedores de reciclaje de 3 colores, aparcabicis).
  3. Marquesina de autobus en cada highway=bus_stop del OSM (de cara a la carretera).
  4. Fuera de las zonas, unos pocos bancos a lo largo de caminos peatonales y contenedores junto a los aparcamientos.
Nunca se coloca un prop sobre un edificio, tronco, coche, pilar, muro, escalera, paso peatonal, agua ni a menos de 2 m de una
barrera de spawn, y solo con un desnivel del terreno bajo la huella <= 0,45 m.

Uso: uv run python scripts/generar_props.py [--forzar] [--salida data/props.csv] (+ opciones del mapa)
"""
import argparse
import math
import sys
from collections import Counter
from pathlib import Path

import numpy as np
import shapely
from shapely.geometry import LineString, Point
from shapely.ops import nearest_points, unary_union

sys.path.insert(0, str(Path(__file__).resolve().parent))
import contexto as cx  # noqa: E402
import datos_zonas as dz  # noqa: E402
import generar_blockout as gb  # noqa: E402
import generar_zonas as gz  # noqa: E402
import props as prp  # noqa: E402
import zonas_nav as nav  # noqa: E402

TRAMO_MAX = 12.0            # se propone un prop cuando el tramo abierto de una ruta supera esto (el limite de generar_zonas es 14 m)
DIST_MAX_COBERTURA = 10.0   # el relleno de espacios abiertos busca que ningun punto de la zona quede a mas de esto de una cobertura
SEP_OBRA = 2.0              # separacion minima entre coberturas grandes (deja pasar a un jugador entre dos)
OBJ_SITE = 11               # coberturas altas (>= 0,8 m) a menos de 10 m del centro de cada site
MARGEN_RUTA = 1.1           # un prop queda como minimo a 1,1 m de cualquier ruta
CICLO_ABIERTO = ["muro_obra", "palets", "cuba", "valla_obra", "bigbag", "muro_obra", "sacos", "bloques", "caseta", "bobina",
                 "muro_obra", "palets", "murete", "bigbag", "jardinera", "valla_obra", "bloques", "cuba", "bobina", "sacos"]
# variantes bajas (1-1,2 m: agacharse) y altas (2 m o mas: cubren de pie) de cada tipo de obra; (notas, ancho_aprox_m)
OBRA = {
    "muro_obra": ["alto=2.2;largo=4.5", "alto=2.4;largo=5.5;ladrillo", "alto=2.0;largo=3.4;l", "alto=2.3;largo=4.2;ladrillo;l", "alto=2.5;largo=6.0",
                  "alto=2.1;largo=3.2;ladrillo"],
    "valla_obra": ["largo=3.2", "largo=4.8", "largo=3.2"],
    "palets": ["n=7", "n=14", "n=8", "n=15"],
    "sacos": ["n=6", "n=5", "n=6"],
    "bigbag": ["alto=1", "alto=2", "alto=1"],
    "cuba": [""],
    "caseta": [""],
    "bobina": ["n=1", "n=2"],
    "bloques": ["n=2", "n=4", "n=3;ladrillo", "n=2;ladrillo"],
}
GRANDES = ("muro_obra", "caseta", "cuba", "valla_obra", "bigbag", "palets", "bloques", "bobina", "sacos")
CICLO_FACHADA = ["contenedor", "expendedora", "reciclaje", "aparcabicis", "expendedora", "contenedor"]
ESCALA_MURETE = (1.0, 1.25)


def yaw_hacia(fe, fn):
    """yaw (grados Godot) cuyo frente (-Z local) apunta a (este, norte) = (fe, fn)."""
    return math.degrees(math.atan2(-fe, fn)) % 360


def yaw_largo(te, tn):
    """yaw cuyo eje largo (+X local = (cos, sin) en (este, norte)) es el vector (te, tn)."""
    return math.degrees(math.atan2(tn, te)) % 360


def puntos_test_suelos(ruta="game/data/spawns.json"):
    """Puntos (x, norte) de test_suelos de spawns.json: el test de Godot lanza un rayo vertical sobre cada uno y espera el suelo,
    asi que ningun prop puede estar encima (si el fichero no existe, ninguno)."""
    import json
    if not Path(ruta).exists():
        return []
    try:
        d = json.loads(Path(ruta).read_text(encoding="utf-8"))
        return [(float(p[0]), -float(p[1])) for v in d.get("test_suelos", {}).values() for p in v["puntos"]]
    except (ValueError, KeyError, TypeError):
        return []


def zona_libre_suelos(geo):
    """Suelos de pasillo (los tests de recorrido y de suelo pasan por su eje): la marquesina-puente (modo `eje`, ~6,4 m de ancho)
    deja libre una franja central de 3,2 m y el pasillo central deja libre todo salvo 3,5 m junto a sus muros; en el resto solo
    cabe cobertura baja pegada a los bordes."""
    out = []
    for info in geo.get("suelos", {}).values():
        if info["modo"] == "eje":
            out.append(info["huella"].buffer(-1.6))
        else:
            out.append(info["huella"].buffer(-3.5))
    out.extend(Point(p).buffer(1.8) for p in puntos_test_suelos())
    return out


class Colocador:
    def __init__(self, ctx, zonas_loc, rng):
        self.ctx, self.rng, self.T = ctx, rng, ctx.T
        self.zonas = zonas_loc
        self.motivos = Counter()
        self.puestos = []                 # dicts de data/props.csv
        self.huellas = []
        geo = ctx.geo
        partes = []
        pil = [Point(p).buffer(1.0 + 0.2) for e in geo["edificios"] for p in e["pilares"]]
        partes.append(unary_union(pil) if pil else None)
        partes.append(unary_union([Point(t["x"], t["y"]).buffer(t["r_tronco"] + 0.8, 8) for t in ctx.arboles]))
        partes.append(unary_union([r.buffer(0.8) for r in ctx.rects_coches]))
        if ctx.entorno.barreras is not None:
            partes.append(ctx.entorno.barreras.buffer(0.9))
        for info in geo.get("suelos", {}).values():
            partes.extend(LineString([a, b]).buffer(1.0) for a, b, _, _ in info["muros"])
        partes.extend(d["rect"].buffer(1.5) for d in geo.get("escaleras", []))
        partes.extend(p["poly"].buffer(1.5) for p in geo.get("pasos", []))
        partes.extend(zona_libre_suelos(geo))
        if "agua" in geo["zonas"]:
            partes.append(geo["zonas"]["agua"].buffer(0.6))
        for z in zonas_loc:
            partes.extend(b.buffer(2.0) for b in z["barreras"])
        resto = unary_union([p for p in partes if p is not None])
        self.bloq = unary_union([resto, ctx.opacos.buffer(0.8)])          # a >= 0,8 m de los edificios
        self.bloq_fachada = unary_union([resto, ctx.opacos.buffer(0.05)])  # mobiliario pegado a la fachada
        shapely.prepare(self.bloq)
        shapely.prepare(self.bloq_fachada)
        self.cobertura = ctx.cobertura
        self.rutas = []                   # LineString de las rutas de la zona en curso
        self.rutas_buf = None
        self.rutas_fino = None
        self.zona = None

    def poner_rutas(self, caminos):
        self.rutas = [LineString(p) for p in caminos if p and len(p) > 1]
        self.rutas_buf = unary_union([r.buffer(MARGEN_RUTA) for r in self.rutas]) if self.rutas else None
        self.rutas_fino = unary_union([r.buffer(0.45) for r in self.rutas]) if self.rutas else None

    def valido(self, p, en_zona=None, margen_zona=1.5, respetar_rutas=True, fino=False, sep=1.0, fachada=False):
        g = prp.huella(p)
        t = p["tipo"]
        if (self.bloq_fachada if fachada else self.bloq).intersects(g):
            self.motivos[(t, "obstaculo")] += 1
            return False
        if en_zona is not None and not en_zona.buffer(-margen_zona).contains(g):
            self.motivos[(t, "fuera de zona")] += 1
            return False
        if respetar_rutas:
            rb = self.rutas_fino if fino else self.rutas_buf
            if rb is not None and rb.intersects(g):
                self.motivos[(t, "ruta")] += 1
                return False
        for h in self.huellas:
            if h.distance(g) < sep:
                self.motivos[(t, "otro prop")] += 1
                return False
        lo, hi = prp.desnivel(p, self.T)
        if hi - lo > prp.PENDIENTE_MAX_M:
            self.motivos[(t, "pendiente")] += 1
            return False
        return True

    def poner(self, p, **kw):
        if not self.valido(p, **kw):
            return False
        self.puestos.append(p)
        g = prp.huella(p)
        self.huellas.append(g)
        if prp.alto(p["tipo"], p["escala"], p["notas"]) >= nav.COBERTURA_ALTA_M:
            self.cobertura = unary_union([self.cobertura, g])
        return True

    def fila(self, tipo, x, n, yaw, escala=1.0, notas=""):
        return {"tipo": tipo, "x": round(float(x), 2), "z": round(-float(n), 2), "yaw": round(float(yaw), 1),
                "escala": escala, "notas": notas}


def fila_abierta(col, tipo, q, te, tn, texto, k=0):
    """Fila de props.csv de una cobertura de espacio abierto en q. (te, tn) = direccion que sigue su eje largo (los muros y vallas se
    ponen de traves a la ruta). Los tipos de obra eligen una variante baja o alta segun k."""
    rng = col.rng
    esc = 1.0
    if tipo in OBRA:
        var = OBRA[tipo]
        notas = var[int(rng.integers(0, len(var))) if k % 2 else k % len(var)]
        if tipo == "muro_obra":     # largo 3-6 m
            partes = notas.split(";")
            largo = round(float(rng.uniform(3.0, 6.0)), 1)
            notas = ";".join(x if not x.startswith("largo=") else f"largo={largo}" for x in partes)
        yaw = yaw_largo(te, tn) + float(rng.uniform(-18, 18)) if tipo in ("muro_obra", "valla_obra", "palets", "sacos", "bigbag", "bloques")             else float(rng.uniform(0, 360))
        return col.fila(tipo, q[0], q[1], yaw % 360, 1.0, f"{notas}; {texto}" if notas else texto)
    if tipo == "murete":
        esc = round(float(rng.uniform(*ESCALA_MURETE)), 2)
    yaw = yaw_largo(te, tn) if tipo in ("murete", "banco", "jardinera", "mesa") else float(rng.uniform(0, 360))
    return col.fila(tipo, q[0], q[1], yaw, esc, texto + ("; volcada" if tipo == "mesa" else ""))


def punto_y_normal(pts, s):
    a = np.array(pts)
    seg = np.hypot(*np.diff(a, axis=0).T)
    acum = np.concatenate([[0.0], np.cumsum(seg)])
    s = float(np.clip(s, 0, acum[-1] - 1e-6))
    i = int(np.searchsorted(acum, s, side="right") - 1)
    i = min(i, len(seg) - 1)
    t = (a[i + 1] - a[i]) / max(seg[i], 1e-9)
    p = a[i] + t * (s - acum[i])
    return p, t


def candidatos_tramo(col, pts, s0, s1, nombre, n_alta, rng):
    """Filas candidatas (en orden de preferencia) para cubrir el tramo [s0, s1] de una ruta."""
    ctx = col.ctx
    largo = s1 - s0
    out = []
    fr = [0.5, 0.42, 0.58, 0.34, 0.66, 0.26, 0.74, 0.18, 0.82, 0.1, 0.9]
    for f in fr:
        sc = s0 + f * largo
        p0, t = punto_y_normal(pts, sc)
        nrm = np.array([-t[1], t[0]])
        for lado in rng.permutation([1, -1]):
            for d in (2.6, 3.4, 4.4, 5.6, 2.0, 7.0, 9.0):
                q = p0 + lado * d * nrm
                dq = ctx.opacos.distance(Point(q))
                if dq < 3.6:
                    qb, _ = nearest_points(ctx.opacos, Point(q))
                    fe, fn = q[0] - qb.x, q[1] - qb.y
                    L = math.hypot(fe, fn) or 1.0
                    fe, fn = fe / L, fn / L
                    tipos = [CICLO_FACHADA[n_alta % len(CICLO_FACHADA)], "contenedor", "banco"]
                    for tipo in tipos:
                        if tipo == "reciclaje":
                            tipo = ["reciclaje_azul", "reciclaje_amarillo", "reciclaje_verde"][n_alta % 3]
                        d_f = {"expendedora": 0.55, "aparcabicis": 1.3}.get(tipo, 1.0)
                        c = np.array([qb.x + fe * d_f, qb.y + fn * d_f])
                        out.append(col.fila(tipo, c[0], c[1], yaw_hacia(fe, fn), 1.0, f"{nombre}: mobiliario junto a la fachada"))
                else:
                    tipos = [CICLO_ABIERTO[n_alta % len(CICLO_ABIERTO)], CICLO_ABIERTO[(n_alta + 3) % len(CICLO_ABIERTO)],
                             "palets", "muro_obra", "bigbag", "banco", "murete"]
                    for ti, tipo in enumerate(tipos):
                        out.append(fila_abierta(col, tipo, q, -t[1], t[0], f"{nombre}: cobertura de ruta", n_alta + ti))
    return out


def cubrir_rutas(col, z, zl, caminos, nombre, ignorar=None):
    """Anade props hasta que ninguna ruta tenga un tramo abierto de mas de TRAMO_MAX m. `ignorar`: geometria (barreras
    de spawn + 4 m) donde no se exige cobertura (nadie combate dentro de su spawn)."""
    rng = col.rng
    n_alta = 0
    fallidos = set()
    for it in range(120):
        peor = None
        for ip, pts in enumerate(caminos):
            if not pts or len(pts) < 2:
                continue
            a = np.array(pts)
            seg = np.hypot(*np.diff(a, axis=0).T)
            s = np.concatenate([[0.0], np.cumsum(seg)])
            ss = np.arange(0.0, s[-1], 1.0)
            xs, ys = np.interp(ss, s, a[:, 0]), np.interp(ss, s, a[:, 1])
            cerca = shapely.dwithin(shapely.points(xs, ys), col.cobertura, nav.DIST_COBERTURA_M)
            if ignorar is not None:
                cerca = cerca | shapely.contains_xy(ignorar, xs, ys)
            ini = None
            for k in range(len(cerca) + 1):
                c = cerca[k] if k < len(cerca) else True
                if not c and ini is None:
                    ini = k
                if c and ini is not None:
                    largo = k - ini
                    clave = (ip, int(ini // 8))
                    if largo > TRAMO_MAX and clave not in fallidos and (peor is None or largo > peor[0]):
                        peor = (largo, pts, float(ss[ini]), float(ss[k - 1]), clave)
                    ini = None
        if peor is None:
            return n_alta
        largo, pts, s0, s1, clave = peor
        puesto = False
        for fila in candidatos_tramo(col, pts, s0, s1, nombre, n_alta, rng):
            es_fachada = "fachada" in fila["notas"]
            if col.poner(fila, en_zona=zl["limite"], fachada=es_fachada, fino=es_fachada):
                puesto = True
                break
        if puesto:
            n_alta += 1
        else:
            fallidos.add(clave)
            print(f"  AVISO: no se pudo cubrir un tramo abierto de {largo:.0f} m en {nombre} cerca de ({pts[int(s0)][0]:.0f}, {-pts[int(s0)][1]:.0f})")
    return n_alta


def cubrir_sites(col, z, zl, nombre, objetivo=OBJ_SITE):
    """Coberturas altas (>= 0,8 m) a 3-10 m del centro de cada site hasta tener `objetivo` (cuenta las ya existentes), la mitad de
    obra grande (altas de 2 m o mas y bajas de 1-1,2 m) y orientadas hacia el lado por donde llegan los atacantes."""
    rng, ctx = col.rng, col.ctx
    atac = np.mean([dz.a_local(p[0], p[1]) for p in z["spawn_atacantes"]["posiciones"]], axis=0)
    n_total = 0
    tipos = ["muro_obra", "palets", "murete", "bigbag", "cuba", "jardinera", "valla_obra", "bloques", "banco", "sacos", "caseta",
             "muro_obra", "bobina", "contenedor", "pila_sillas"]
    for k, s in zl["sites"].items():
        c = np.array([s.centroid.x, s.centroid.y])
        dir_att = atac - c
        base = math.atan2(dir_att[1], dir_att[0])
        zona_site = Point(c).buffer(10.0)
        ya = sum(1 for h, p in zip(col.huellas, list(ctx.props["props"]) + col.puestos) if zona_site.intersects(h) and prp.alto(p["tipo"], p["escala"], p["notas"]) >= nav.COBERTURA_ALTA_M)
        puestos = 0
        intentos = 0
        while ya + puestos < objetivo and intentos < 500:
            intentos += 1
            ang = base + math.radians(rng.uniform(-150, 150)) if puestos < 5 else rng.uniform(0, 2 * math.pi)
            r = rng.uniform(3.4, 9.5)
            q = c + r * np.array([math.cos(ang), math.sin(ang)])
            tipo = tipos[(puestos + int(rng.integers(0, 3))) % len(tipos)]
            fila = fila_abierta(col, tipo, q, -math.sin(ang), math.cos(ang), f"{nombre}: cobertura del site {k}", puestos)
            if col.poner(fila, en_zona=zl["limite"], respetar_rutas=True, sep=SEP_OBRA if tipo in GRANDES else 1.0):
                puestos += 1
        n_total += puestos
    return n_total


def rellenar_abiertos(col, z, zl, nombre, max_props=60):
    """Rellena los espacios abiertos de la zona: mientras algun punto libre quede a mas de DIST_MAX_COBERTURA m de toda cobertura
    (edificios, troncos gruesos, coches, props altos), pone una cobertura grande en el punto mas alejado. Fuera de las barreras de spawn."""
    rng = col.rng
    lim = zl["limite"].buffer(-2.5)
    x0, y0, x1, y1 = lim.bounds
    gx, gy = np.meshgrid(np.arange(x0, x1, 2.5), np.arange(y0, y1, 2.5))
    px, py = gx.ravel(), gy.ravel()
    ok = shapely.contains_xy(lim, px, py) & ~shapely.contains_xy(col.bloq, px, py)
    for b in zl["barreras"]:
        ok &= ~shapely.contains_xy(b.buffer(4.0), px, py)
    px, py = px[ok], py[ok]
    if len(px) == 0:
        return 0
    sites = [np.array([s.centroid.x, s.centroid.y]) for s in zl["sites"].values()]
    n = 0
    fallidos = np.zeros(len(px), bool)
    for _ in range(max_props * 3):
        if n >= max_props:
            break
        pts = shapely.points(px, py)
        d = shapely.distance(pts, col.cobertura)
        d[fallidos] = 0
        i = int(np.argmax(d))
        if d[i] <= DIST_MAX_COBERTURA:
            break
        q = np.array([px[i], py[i]])
        cerca = min(sites, key=lambda c: float(np.hypot(*(c - q))))
        dx, dy = cerca - q
        L = math.hypot(dx, dy) or 1.0
        te, tn = -dy / L, dx / L              # de traves a la direccion del site mas cercano
        puesto = False
        orden = [CICLO_ABIERTO[(n * 7 + k) % len(CICLO_ABIERTO)] for k in range(8)]
        for tipo in orden:
            for dq in ((0, 0), (1.5, 0), (-1.5, 0), (0, 1.5), (0, -1.5), (2.5, 2.5), (-2.5, -2.5)):
                f = fila_abierta(col, tipo, q + np.array(dq), te, tn, f"{nombre}: cobertura de espacio abierto", n)
                if col.poner(f, en_zona=zl["limite"], respetar_rutas=True, sep=SEP_OBRA if tipo in GRANDES else 1.0):
                    puesto = True
                    break
            if puesto:
                break
        if puesto:
            n += 1
        else:
            fallidos[i] = True
    return n


def mobiliario_fachada(col, z, zl, caminos, nombre, n=4):
    """Grupos junto a las fachadas cerca de las rutas: reciclaje (3 colores), expendedoras y aparcabicis."""
    rng, ctx = col.rng, col.ctx
    puestos = 0
    cercanos = []
    for pts in caminos:
        if not pts:
            continue
        a = np.array(pts)
        for k in range(0, len(a), 6):
            cercanos.append(a[k])
    cercanos = np.array(cercanos)
    if len(cercanos) == 0:
        return 0
    orden = rng.permutation(len(cercanos))
    cuales = ["reciclaje", "expendedora", "aparcabicis", "expendedora"]
    ya = []
    for idx in orden:
        if puestos >= n:
            break
        p = Point(*cercanos[idx])
        if ctx.opacos.distance(p) > 10.0 or ctx.opacos.distance(p) < 0.8:
            continue
        qb, _ = nearest_points(ctx.opacos, p)
        if any(math.hypot(qb.x - u, qb.y - v) < 22 for u, v in ya):
            continue
        # tangente de la fachada = perpendicular a la direccion al edificio
        fe, fn = p.x - qb.x, p.y - qb.y
        L = math.hypot(fe, fn)
        fe, fn = fe / L, fn / L
        te, tn = -fn, fe
        ok = False
        for tipo in cuales[puestos % len(cuales):] + cuales[:puestos % len(cuales)]:
            if tipo == "reciclaje":
                cols = ["reciclaje_azul", "reciclaje_amarillo", "reciclaje_verde"]
                tmp = []
                for j, t in enumerate(cols):
                    q = np.array([qb.x, qb.y]) + np.array([fe, fn]) * 1.1 + np.array([te, tn]) * (j - 1) * 1.55
                    tmp.append(col.fila(t, q[0], q[1], yaw_hacia(fe, fn), 1.0, f"{nombre}: punto de reciclaje (3 colores)"))
                if all(col.valido(f_, en_zona=zl["limite"], fino=True, fachada=True) for f_ in tmp):
                    ok = all(col.poner(f_, en_zona=zl["limite"], fino=True, sep=0.1, fachada=True) for f_ in tmp)
            elif tipo == "expendedora":
                q = np.array([qb.x, qb.y]) + np.array([fe, fn]) * 0.55
                ok = col.poner(col.fila(tipo, q[0], q[1], yaw_hacia(fe, fn), 1.0, f"{nombre}: maquina expendedora junto a la fachada"),
                               en_zona=zl["limite"], fino=True, fachada=True)
            else:
                q = np.array([qb.x, qb.y]) + np.array([fe, fn]) * 1.3
                ok = col.poner(col.fila(tipo, q[0], q[1], yaw_largo(te, tn), 1.0, f"{nombre}: aparcabicis junto a la fachada"),
                               en_zona=zl["limite"], fino=True, fachada=True)
            if ok:
                break
        if ok:
            puestos += 1
            ya.append((qb.x, qb.y))
    return puestos


def aula(col, z, zl):
    """El aula al aire libre en el bosque de detras_22: busca el punto del bosque mas cercano al muro oeste del Edificio 24
    donde, tras limpiar un claro de 9 m, quepan 4 filas de 4 asientos y la pizarra."""
    ctx = col.ctx
    mejor = None
    for x in np.arange(38.0, 66.0, 1.0):
        for n in np.arange(296.0, 316.0, 1.0):          # norte = -z
            for yaw in (0.0, 180.0, 90.0, 270.0):
                f = col.fila("aula", x, n, yaw, 1.0, "claro=9; aula al aire libre: 4 filas de 4 asientos mirando a la pizarra")
                g = prp.huella(f)
                if not zl["limite"].buffer(-3).contains(g.buffer(1.5)):
                    continue
                if ctx.opacos.distance(g) < 1.5:
                    continue
                lo, hi = prp.desnivel(f, ctx.T)
                if hi - lo > prp.PENDIENTE_MAX_M:
                    continue
                # no puede chocar con edificios, coches, muros, agua ni escaleras: los arboles no cuentan (se limpia un claro)
                if gb_bloq_sin_arboles(col).intersects(g):
                    continue
                d = Point(x, n).distance(Point(77.0, 296.0))
                pun = d + 3.0 * abs(yaw - 0) / 90.0
                if mejor is None or pun < mejor[0]:
                    mejor = (pun, f)
    return mejor[1] if mejor else None


_BLOQ_SIN_ARB = None


def gb_bloq_sin_arboles(col):
    global _BLOQ_SIN_ARB
    if _BLOQ_SIN_ARB is None:
        ctx = col.ctx
        partes = [ctx.opacos.buffer(0.8), unary_union([r.buffer(0.8) for r in ctx.rects_coches])]
        if ctx.entorno.barreras is not None:
            partes.append(ctx.entorno.barreras.buffer(0.9))
        if "agua" in ctx.geo["zonas"]:
            partes.append(ctx.geo["zonas"]["agua"].buffer(0.6))
        for e in ctx.geo["edificios"]:
            partes.extend(Point(p).buffer(1.2) for p in e["pilares"])
        partes.extend(d["rect"].buffer(1.5) for d in ctx.geo.get("escaleras", []))
        partes.extend(p["poly"].buffer(1.5) for p in ctx.geo.get("pasos", []))
        _BLOQ_SIN_ARB = unary_union(partes)
    return _BLOQ_SIN_ARB


def marquesinas(col, mapa):
    """Una marquesina por parada de autobus de OSM (highway=bus_stop), con el frente hacia la carretera mas cercana."""
    ctx = col.ctx
    viales = unary_union([g for hw, g in ctx.geo["caminos"].items() if hw in gb.ASFALTO])
    out = []
    for nid, nd in mapa.nodos.items():
        t = nd.get("tags", {})
        if t.get("highway") != "bus_stop":
            continue
        x, y = mapa.tr.transform(nd["lon"], nd["lat"])
        p = Point(x - mapa.E0, y - mapa.N0)
        q, _ = nearest_points(viales, p)
        fe, fn = q.x - p.x, q.y - p.y            # hacia la carretera
        L = math.hypot(fe, fn) or 1.0
        fe, fn = fe / L, fn / L
        for retroceso in (0.0, 1.0, 2.0, 3.0):    # si cae sobre el asfalto, se retira de la carretera
            c = np.array([p.x - fe * retroceso, p.y - fn * retroceso])
            fila = col.fila("marquesina", c[0], c[1], yaw_hacia(fe, fn), 1.0,
                            f"parada OSM {nid}: {t.get('name', '')}" + ("" if t.get("shelter") == "yes" else " (sin marquesina en OSM)"))
            g = prp.huella(fila)
            if not viales.intersects(g) and not gb_bloq_sin_arboles(col).intersects(g) and col.poner(fila, respetar_rutas=False):
                out.append(fila)
                break
    return out


def fuera_de_zonas(col, mapa, zonas_loc, n_bancos=8, n_conten=3):
    """Pocos props fuera de las zonas: bancos en caminos peatonales y contenedores junto a los aparcamientos."""
    ctx, rng = col.ctx, col.rng
    dentro = unary_union([z["limite"].buffer(3) for z in zonas_loc])
    peat = [g for hw, g in ctx.geo["caminos"].items() if hw in ("footway", "pedestrian", "path")]
    puestos = 0
    if peat:
        # lineas centrales aproximadas: los poligonos de los caminos peatonales; se toma su contorno y se tira hacia dentro
        pg = unary_union(peat).intersection(ctx.campus.buffer(-8))
        intentos = 0
        ya = []
        while puestos < n_bancos and intentos < 3000:
            intentos += 1
            minx, miny, maxx, maxy = pg.bounds
            q = Point(rng.uniform(minx, maxx), rng.uniform(miny, maxy))
            if not pg.contains(q) or dentro.contains(q):
                continue
            if any(math.hypot(q.x - u, q.y - v) < 60 for u, v in ya):
                continue
            # junto al borde del camino, de cara a el
            borde = pg.boundary
            b, _ = nearest_points(borde, q)
            fe, fn = q.x - b.x, q.y - b.y
            L = math.hypot(fe, fn)
            if L < 0.3:
                continue
            fe, fn = fe / L, fn / L
            c = np.array([b.x - fe * 1.0, b.y - fn * 1.0])      # justo fuera del camino mirando hacia el
            fila = col.fila("banco", c[0], c[1], yaw_hacia(fe, fn), 1.0, "fuera de zona: banco junto al camino peatonal")
            if col.poner(fila, respetar_rutas=False):
                puestos += 1
                ya.append((c[0], c[1]))
    # contenedores junto a aparcamientos
    parkings = ctx.geo["zonas"].get("aparcamiento")
    n = 0
    if parkings is not None:
        intentos = 0
        ya = []
        while n < n_conten and intentos < 3000:
            intentos += 1
            minx, miny, maxx, maxy = parkings.bounds
            q = Point(rng.uniform(minx, maxx), rng.uniform(miny, maxy))
            if not parkings.buffer(2.5).contains(q) or parkings.contains(q) or dentro.contains(q):
                continue
            if any(math.hypot(q.x - u, q.y - v) < 90 for u, v in ya):
                continue
            b, _ = nearest_points(parkings.boundary, q)
            fe, fn = q.x - b.x, q.y - b.y
            L = math.hypot(fe, fn)
            if L < 0.3:
                continue
            fe, fn = fe / L, fn / L
            c = np.array([b.x + fe * 1.4, b.y + fn * 1.4])
            tipo = ["contenedor", "reciclaje_azul", "reciclaje_verde"][n % 3]
            fila = col.fila(tipo, c[0], c[1], yaw_hacia(-fe, -fn), 1.0, "fuera de zona: junto al aparcamiento")
            if col.poner(fila, respetar_rutas=False):
                n += 1
                ya.append((c[0], c[1]))
    return puestos, n


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    cx.argumentos(ap)
    ap.add_argument("--salida", default=dz.PROPS_CSV)
    ap.add_argument("--forzar", action="store_true", help="sobrescribe el CSV existente (pierde las ediciones a mano)")
    ap.add_argument("--semilla-props", type=int, default=3)
    ap.add_argument("--completar", action="store_true",
                    help="conserva el CSV actual (con tus ediciones) y solo anade props donde queden tramos abiertos de las rutas")
    ap.add_argument("--densificar", action="store_true",
                    help="(con --completar) ademas refuerza los sites (obra grande) y rellena los espacios abiertos de cada zona; no toca tus filas")
    a = ap.parse_args()
    ruta = Path(a.salida)
    if a.completar:
        if not ruta.exists():
            raise SystemExit(f"{ruta} no existe: ejecuta primero sin --completar")
        a.props = str(ruta)
    else:
        if ruta.exists() and not a.forzar:
            raise SystemExit(f"{ruta} ya existe: se edita a mano; usa --forzar para regenerar la propuesta (o --completar)")
        a.props = str(ruta.with_suffix(".inexistente"))      # la propuesta no depende de los props actuales
    zonas = dz.leer_zonas(a.zonas)
    zonas_loc = dz.zonas_local(zonas)
    ctx = gz.Contexto(a)
    rng = np.random.default_rng(a.semilla_props)
    col = Colocador(ctx, zonas_loc, rng)
    mapa = ctx.mapa
    existentes = list(ctx.props["props"]) if a.completar else []
    col.huellas.extend(ctx.huellas_props if a.completar else [])
    nombre_de = {z["id"]: z["nombre"] for z in zonas}
    # 1. aula
    for z, zl in zip(zonas, zonas_loc):
        if z["id"] == "detras_22" and not a.completar:
            f = aula(col, z, zl)
            if f is None:
                raise SystemExit("No se encuentra sitio para el aula al aire libre")
            col.puestos.append(f)
            col.huellas.append(prp.huella(f))
            col.cobertura = unary_union([col.cobertura, prp.huella(f)])
            print(f"aula en ({f['x']:.1f}, {f['z']:.1f}) yaw {f['yaw']}")
    # 2. zonas
    for z, zl in zip(zonas, zonas_loc):
        rej = nav.Rejilla(ctx.T, zl["limite"], ctx.obst)
        est = gz.estimar(z, ctx, rej)
        caminos = [p for k in z["sites"] for p in (est["caminos"][k] + est["caminos"][f"{k}_atacantes"] + est["caminos"][f"{k}_defensores"])]
        col.poner_rutas([p for k in z["sites"] for eq in ("atacantes", "defensores") for p in est["caminos"][f"{k}_{eq}"]])   # solo las rutas principales quedan libres
        n0 = len(col.puestos)
        ns = cubrir_sites(col, z, zl, z["id"]) if (a.densificar or not a.completar) else 0
        nf = 0 if a.completar else mobiliario_fachada(col, z, zl, caminos, z["id"])
        na = rellenar_abiertos(col, z, zl, z["id"]) if (a.densificar or not a.completar) else 0
        nr = cubrir_rutas(col, z, zl, caminos, z["id"], ignorar=unary_union([b.buffer(4.0) for b in zl["barreras"]]))
        # un segundo repaso de los sites (los props de ruta pueden haberse colocado antes que los del site)
        print(f"{z['id']}: {len(col.puestos) - n0} props (site {ns}, fachada {nf}, abiertos {na}, rutas {nr})")
    # 3. marquesinas y exterior
    if not a.completar:
        mq = marquesinas(col, mapa)
        print(f"marquesinas: {len(mq)}")
        nb, nc = fuera_de_zonas(col, mapa, zonas_loc)
        print(f"fuera de zonas: {nb} bancos, {nc} contenedores")
    ruta.parent.mkdir(parents=True, exist_ok=True)
    col.puestos = existentes + col.puestos
    dz.guardar_props(col.puestos, ruta)
    print("rechazos:", dict(sorted(col.motivos.items(), key=lambda kv: -kv[1])[:14]))
    print(f"Escrito {ruta}: {len(col.puestos)} props", dict(Counter(p["tipo"] for p in col.puestos)))


if __name__ == "__main__":
    main()
