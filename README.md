# UPOWARS

Mapa 3D (blockout) del campus de la Universidad Pablo de Olavide (Sevilla) para un FPS tipo CS en Godot 4. Los datos salen de OpenStreetMap y se procesan con scripts Python.

## Uso

Requiere [uv](https://docs.astral.sh/uv/) (Python 3.12 fijado en `.python-version`).

```
uv sync
uv run python scripts/descargar_osm.py      # genera data/raw/osm_upo.json (no versionado)
```

Estructura: `scripts/` (Python), `data/raw/` (descargas, ignoradas por git), `export/` (salida glTF), `game/` (proyecto Godot 4.7), `docs/` (documentación).

## Regenerar el mapa y los puntos de aparición

```
uv run python scripts/generar_blockout.py    # export/upo_blockout.glb (+ meta, preview) y copia a game/assets/mapa/
uv run python scripts/generar_spawns.py      # game/data/spawns.json y export/spawns_preview.png
```

`generar_blockout.py` copia el .glb a `game/assets/mapa/` salvo que se pase `--no-copiar-godot`.
Después de regenerar el mapa conviene volver a ejecutar `generar_spawns.py` y reimportar en Godot
(abrir el editor o `--import`). Los spawns usan las mismas coordenadas que el glb
(x = este, y = arriba, z = -norte, metros; origen = centroide del campus).

## Jugar (Godot 4.7.2)

Abrir el proyecto `game/` con `D:\Juegos\godot\Godot_v4.7.2-stable_win64.exe` (importador de proyectos, o
`Godot_v4.7.2-stable_win64.exe --path game`) y pulsar F5. Al arrancar aparece el selector de punto de aparición.

Controles: WASD mover, ratón mirar, Espacio saltar, Shift caminar lento, Ctrl agacharse, Esc liberar/capturar
el ratón, M reabrir el selector de spawn, F1 modo vuelo/noclip (20 m/s, x3 con Shift; Espacio/Ctrl suben/bajan).
Las acciones están en el Input Map de `game/project.godot`. Colisión: los nodos `-col` del .glb se importan como
StaticBody3D trimesh (automático en Godot); el muro `limite` se oculta en `game/scripts/mapa.gd`.

Test headless (debe terminar con PASS y código 0):

```
Godot_v4.7.2-stable_win64_console.exe --headless --path game --import
Godot_v4.7.2-stable_win64_console.exe --headless --path game --script res://tests/test_mapa.gd
```

Diseño y plan del proyecto: [docs/PROYECTO.md](docs/PROYECTO.md).
