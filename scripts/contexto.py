"""Contexto geometrico compartido por generar_zonas.py y generar_props.py (y utilidades de lectura de datos).

`crear_geo(a)` reconstruye lo mismo que generar_blockout.py / generar_spawns.py: mapa OSM, terreno (con suelos aplanados y
escaleras) y la geometria del blockout (`geo`), SIN arboles ni coches (esos los pide construir_props). Tarda ~20 s.
Las coordenadas de los CSV/JSON de datos son de juego (x = este, z = -norte); la geometria interna es local (x, norte).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generar_blockout as gb  # noqa: E402
import terreno as ter  # noqa: E402

def argumentos(ap):
    """Opciones del mapa (las mismas que generar_blockout.py / generar_spawns.py)."""
    ap.add_argument("--entrada", default="data/raw/osm_upo.json")
    ap.add_argument("--alturas", default="data/alturas.csv")
    ap.add_argument("--pasos", default="data/pasos.csv")
    ap.add_argument("--pistas", default="data/pistas.csv")
    ap.add_argument("--escaleras", default="data/escaleras.csv")
    ter.anadir_argumentos(ap)
    gb.anadir_argumentos_props(ap)


def crear_geo(a):
    """Devuelve (mapa, T, geo, filas). Mismo terreno y geometria que el blockout."""
    mapa = gb.Mapa(a.entrada)
    edificios = [(wid, w["tags"]) for wid, w in sorted(mapa.ways.items())
                 if "tags" in w and mapa.cerrado(w)
                 and ("building" in w["tags"] or w["tags"].get("man_made") == "tower")]
    filas = gb.cargar_alturas(a.alturas, edificios)
    campus = gb.campus_local(mapa)
    T = ter.crear(a, mapa.E0, mapa.N0, campus, gb.zona_fina(mapa, campus, a.buffer_fino, gb.ids_suelo(filas)))
    escs = gb.cargar_escaleras(a.escaleras)
    gb.preparar_suelos(mapa, filas, T, gb.huecos_escaleras(escs))
    gb.preparar_escaleras(T, escs)
    _, _, geo = gb.construir(mapa, filas, gb.cargar_pasos(a.pasos), gb.cargar_pistas(a.pistas), T,
                             gb.Lidar(a.mdt, gb.NDSM_DEFECTO, mapa.E0, mapa.N0))
    return mapa, T, geo, filas
