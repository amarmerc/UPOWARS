"""Descarga de OSM (Overpass) del campus de la Universidad Pablo de Olavide.

Formato elegido: `out body; >; out skel qt;` -> elementos con tags + nodos
referenciados (sin geometria embebida). Hay que reconstruir los poligonos
uniendo way.nodes con el diccionario de nodos (id -> lat/lon). Asi las
relations multipolygon y los ways compartidos se resuelven por id.

Uso: uv run python scripts/descargar_osm.py [--salida data/raw/osm_upo.json]
     [--bbox S,W,N,E]
"""
import argparse
import json
import math
import sys
import time
from collections import Counter
from pathlib import Path

import requests

ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]
HEADERS = {"User-Agent": "UPOWARS-blockout/0.1"}
CENTRO = (37.3560, -5.9380)  # lat, lon
ANCHO_KM, ALTO_KM = 1.8, 1.4  # E-O, N-S

# Cuerpo comun: se evalua dentro de {{area}} (area.a) o de una bbox.
CLAUSULAS = [
    'nwr[building]', 'nwr["building:part"]', 'nwr[highway]', 'nwr[barrier]',
    'nwr[landuse]', 'nwr[leisure]', 'nwr[natural]', 'nwr[amenity=parking]',
    'nwr[man_made]', 'nwr[bridge]', 'nwr[footway]', 'nwr[path]',
]


def bbox_defecto():
    dlat = (ALTO_KM / 2) / 111.2
    dlon = (ANCHO_KM / 2) / (111.32 * math.cos(math.radians(CENTRO[0])))
    return (CENTRO[0] - dlat, CENTRO[1] - dlon, CENTRO[0] + dlat, CENTRO[1] + dlon)


def query_area():
    cuerpo = "\n  ".join(f"{c}(area.a);" for c in CLAUSULAS)
    return f"""[out:json][timeout:120];
(
  way["amenity"="university"]["name"~"Pablo de Olavide"];
  relation["amenity"="university"]["name"~"Pablo de Olavide"];
)->.u;
.u map_to_area->.a;
(
  .u;
  {cuerpo}
);
out body;
>;
out skel qt;"""


def query_bbox(b):
    bb = ",".join(f"{v:.6f}" for v in b)
    cuerpo = "\n  ".join(f"{c}({bb});" for c in CLAUSULAS)
    return f"""[out:json][timeout:120];
(
  {cuerpo}
);
out body;
>;
out skel qt;"""


def ejecutar(query, reintentos=2):
    ultimo = None
    for url in ENDPOINTS:
        for i in range(reintentos):
            try:
                print(f"POST {url} (intento {i + 1})", file=sys.stderr)
                r = requests.post(url, data={"data": query}, headers=HEADERS, timeout=180)
                r.raise_for_status()
                return r.json()
            except (requests.RequestException, ValueError) as e:
                ultimo = e
                print(f"  fallo: {e}", file=sys.stderr)
                time.sleep(5 * (i + 1))
    raise SystemExit(f"Overpass no responde: {ultimo}")


def resumen(data, metodo):
    els = data.get("elements", [])
    nodos = {e["id"]: e for e in els if e["type"] == "node"}
    tagged = [e for e in els if e.get("tags")]
    edif = [e for e in tagged if e["type"] in ("way", "relation") and "building" in e["tags"]]
    hw = Counter(e["tags"]["highway"] for e in tagged if e["type"] == "way" and "highway" in e["tags"])
    barr = [e for e in tagged if "barrier" in e["tags"]]
    arboles = [e for e in tagged if e["type"] == "node" and e["tags"].get("natural") == "tree"]
    partes = [e for e in tagged if "building:part" in e["tags"]]
    lats = [n["lat"] for n in nodos.values()]
    lons = [n["lon"] for n in nodos.values()]
    print(f"Metodo de area: {metodo}")
    print(f"Elementos totales: {len(els)} (nodos: {len(nodos)})")
    print(f"Edificios: {len(edif)} | con height: {sum('height' in e['tags'] for e in edif)}"
          f" | con building:levels: {sum('building:levels' in e['tags'] for e in edif)}")
    print(f"building:part: {len(partes)}")
    print("Vias por highway:", dict(hw.most_common()))
    print(f"Barreras: {len(barr)} {dict(Counter(e['tags']['barrier'] for e in barr).most_common(8))}")
    print(f"Arboles (nodos): {len(arboles)}")
    if lats:
        print(f"BBox real (S,W,N,E): {min(lats):.5f}, {min(lons):.5f}, {max(lats):.5f}, {max(lons):.5f}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--salida", default="data/raw/osm_upo.json")
    ap.add_argument("--bbox", help="S,W,N,E (fuerza bbox, omite area del campus)")
    a = ap.parse_args()

    metodo = None
    data = None
    if a.bbox:
        b = tuple(float(x) for x in a.bbox.split(","))
        data, metodo = ejecutar(query_bbox(b)), f"bbox forzada {b}"
    else:
        data = ejecutar(query_area())
        if any(e.get("tags", {}).get("amenity") == "university" for e in data.get("elements", [])):
            metodo = "map_to_area (amenity=university, Pablo de Olavide)"
        else:
            b = bbox_defecto()
            print("Area del campus no encontrada; uso bbox de respaldo", file=sys.stderr)
            data, metodo = ejecutar(query_bbox(b)), f"bbox respaldo {tuple(round(x, 5) for x in b)}"

    out = Path(a.salida)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    print(f"Guardado {out} ({out.stat().st_size / 1e6:.2f} MB)")
    resumen(data, metodo)


if __name__ == "__main__":
    main()
