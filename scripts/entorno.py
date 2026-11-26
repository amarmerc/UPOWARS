"""Geometria de obstaculos compartida por vegetacion.py y coches.py (plano local: x = este, y = norte).

`Entorno` agrupa, a partir del `geo` que devuelve generar_blockout.construir, todo lo que no debe ocupar un arbol
o un coche: edificios (huella), pilares, muros y vallas, caminos, aparcamientos, agua, pistas y los puntos de
aparicion del jugador. Tambien lee las posiciones de los spawns de game/data/spawns.json (si existe) para que el
blockout evite esos puntos.
"""
import json
from pathlib import Path

import numpy as np
import shapely
from shapely.geometry import MultiPoint, Point
from shapely.ops import unary_union

ZONA_MARGEN_LIMITE = 1.5   # los arboles y coches quedan al menos 1,5 m por dentro del muro limite


def leer_spawns(ruta):
    """Posiciones (x, norte) de los spawns de un spawns.json (juego: x, y, z con z = -norte). [] si no existe."""
    ruta = Path(ruta)
    if not ruta.exists():
        return []
    try:
        datos = json.loads(ruta.read_text(encoding="utf-8"))
        return [(float(s["pos"][0]), -float(s["pos"][2])) for s in datos.get("spawns", [])]
    except (ValueError, KeyError, TypeError):
        return []


class Entorno:
    def __init__(self, mapa, geo, spawns, margen_limite):
        self.mapa, self.geo = mapa, geo
        self.T = geo["terreno"]
        self.campus = geo["campus"]
        self.zona = self.campus.buffer(margen_limite - ZONA_MARGEN_LIMITE)
        self.edificios = geo["edificios"]
        self.spawns = list(spawns)
        # huellas: todos los edificios (arboles) / solo los que ocupan el suelo (coches; los techos se tratan aparte)
        self.huellas = unary_union([e["poly"] for e in self.edificios])
        self.macizos = unary_union([e["poly"] for e in self.edificios if e["forma"] != "techo"])
        self.techos = [e for e in self.edificios if e["forma"] == "techo"]
        self.pilares_xy = np.array([p for e in self.edificios for p in e["pilares"]], float).reshape(-1, 2)
        self.pilares = MultiPoint([tuple(p) for p in self.pilares_xy]) if len(self.pilares_xy) else None
        barreras = []
        for w in mapa.ways.values():
            if w.get("tags", {}).get("barrier") in ("retaining_wall", "fence"):
                l = mapa.linea(w)
                if l is not None:
                    barreras.append(l)
        self.barreras = unary_union(barreras) if barreras else None
        zonas = geo["zonas"]
        self.parkings = zonas.get("aparcamiento")
        self.agua = zonas.get("agua")
        self.pistas = zonas.get("pista")
        self.caminos = unary_union(list(geo["caminos"].values())) if geo["caminos"] else None
        self.spawn_pts = MultiPoint(self.spawns) if self.spawns else None

    @staticmethod
    def _g(geoms, buf):
        g = [x for x in geoms if x is not None and not x.is_empty]
        return unary_union(g).buffer(buf) if g else None

    def prohibido_arbol(self):
        """Geometria donde no puede haber un tronco: huella + 1 m, caminos, aparcamientos, agua, pistas,
        pilares y muros a 2 m, spawns a 3 m."""
        partes = [self.huellas.buffer(1.0),
                  self._g([self.caminos], 0.3),
                  self._g([self.parkings], 0.0),
                  self._g([self.agua], 0.5),
                  self._g([self.pistas], 0.0),
                  self._g([self.pilares], 2.0),
                  self._g([self.barreras], 2.0),
                  self._g([self.spawn_pts], 3.0)]
        return unary_union([p for p in partes if p is not None])

    def fuera_zona(self, x, y):
        return ~shapely.contains_xy(self.zona, x, y)
