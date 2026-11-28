"""Lectura de los datos editables de zonas (data/zonas.json) y coberturas (data/props.csv). Sin dependencias del generador.

Coordenadas de los ficheros: juego (x = este, z = -norte). Las funciones `*_local` devuelven geometria shapely en el plano
local (x = este, y = norte) que usa el generador.
"""
import csv
import json
from pathlib import Path

from shapely.geometry import Point, Polygon

import props as prp

ZONAS_FUENTE = "data/zonas.json"
PROPS_CSV = "data/props.csv"
EQUIPOS = ("atacantes", "defensores")


def leer_zonas(ruta=ZONAS_FUENTE):
    """Zonas de data/zonas.json (fuente editable). [] si el fichero no existe."""
    ruta = Path(ruta)
    if not ruta.exists():
        return []
    return json.loads(ruta.read_text(encoding="utf-8"))["zonas"]


def a_local(x, z):
    """Juego (x, z = -norte) -> local (x, norte)."""
    return (float(x), -float(z))


def poligono_local(pts):
    return Polygon([a_local(p[0], p[1]) for p in pts])


def zonas_local(zonas):
    """Por zona: {id, limite (Polygon), barreras (lista de Polygon), sites {A, B: Polygon}, spawns [(x, norte)]} en local."""
    out = []
    for z in zonas:
        sites = {}
        for k, s in z["sites"].items():
            if "poligono" in s:
                sites[k] = poligono_local(s["poligono"])
            else:
                c = a_local(*s["centro"][:2])
                sites[k] = Point(c).buffer(float(s["radio"]), 32)
        spawns = [a_local(p[0], p[1]) for eq in EQUIPOS for p in z["spawn_" + eq]["posiciones"]]
        out.append({"id": z["id"], "limite": poligono_local(z["limite"]),
                    "barreras": [poligono_local(z["spawn_" + eq]["barrera"]) for eq in EQUIPOS],
                    "sites": sites, "spawns": spawns})
    return out


def leer_props(ruta=PROPS_CSV):
    """Filas de data/props.csv: dicts {tipo, x, z, yaw, escala, notas}. Se ignoran las lineas con `#` en `tipo`."""
    ruta = Path(ruta)
    if not ruta.exists():
        return []
    out = []
    with open(ruta, encoding="utf-8-sig", newline="") as f:
        for fila in csv.DictReader(f):
            tipo = (fila.get("tipo") or "").strip()
            if not tipo or tipo.startswith("#"):
                continue
            if tipo not in prp.TIPOS:
                raise SystemExit(f"{ruta}: tipo de prop desconocido {tipo!r} (validos: {', '.join(prp.TIPOS)})")
            out.append({"tipo": tipo, "x": float(fila["x"]), "z": float(fila["z"]),
                        "yaw": float(fila.get("yaw") or 0.0), "escala": float(fila.get("escala") or 1.0),
                        "notas": (fila.get("notas") or "").strip()})
    return out


def guardar_props(filas, ruta=PROPS_CSV):
    with open(ruta, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["tipo", "x", "z", "yaw", "escala", "notas"])
        for p in filas:
            w.writerow([p["tipo"], f"{p['x']:.2f}", f"{p['z']:.2f}", f"{p['yaw']:.1f}", f"{p['escala']:g}", p["notas"]])
