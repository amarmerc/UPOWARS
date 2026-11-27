"""Exporta data/props.csv a game/data/props_cobertura.json para que los bots (P3) conozcan las coberturas.

Los bots calculan sus puntos de defensa en runtime (detras de cada cobertura respecto a la amenaza), asi que solo necesitan
[tipo, x, z, yaw, escala] de cada prop (coordenadas de juego). Se ignoran las filas con '#' en tipo.

Uso: uv run python scripts/exportar_props_bots.py
"""
import csv
import json
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
ENTRADA = RAIZ / "data" / "props.csv"
SALIDA = RAIZ / "game" / "data" / "props_cobertura.json"


def main() -> None:
    props = []
    with open(ENTRADA, encoding="utf-8-sig", newline="") as f:
        for fila in csv.DictReader(f):
            tipo = (fila.get("tipo") or "").strip()
            if not tipo or tipo.startswith("#"):
                continue
            props.append([tipo, float(fila["x"]), float(fila["z"]), float(fila.get("yaw") or 0.0), float(fila.get("escala") or 1.0)])
    SALIDA.write_text(json.dumps({"formato": "[tipo, x, z, yaw, escala] en coordenadas de juego", "props": props}, ensure_ascii=False) + "\n",
                      encoding="utf-8")
    print(f"{len(props)} props -> {SALIDA}")


if __name__ == "__main__":
    main()
