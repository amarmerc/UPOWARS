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

### Relieve (terreno)

El suelo es `terreno-col`, una malla sobre el MDT (campus + 50 m), y todo lo demás se apoya en ella.
`y_juego = cota - cota_ref`, con `cota_ref` = mediana de las cotas del MDT dentro del contorno del campus (se guarda en
`export/upo_blockout_meta.json`, bloque `terreno`, junto con la fuente, la resolución, el suavizado y los pasos de malla).
El código solo exige un GeoTIFF de cotas en EPSG:25830, norte arriba y pixel cuadrado.

**Por defecto** se usa el MDT de 1 m derivado de LiDAR (`data/raw/mdt_lidar_1m.tif`, PNOA 2020, clase suelo): resuelve las
escaleras, rampas y muros de contención (escalones de 1-2,4 m) que el MDT de 5 m del IGN borra. Coincide con el de 5 m
con una desviación de ±0,4 m. La malla es de **resolución variable**: paso 1 m en una zona de detalle (8 m alrededor de
`highway=steps/footway/path/pedestrian`, de `barrier=retaining_wall` y del pasillo central cubierto; ~0,11 km2) y bloques
de 4 m en el resto. Los bloques gruesos que tocan un bloque fino se triangulan en abanico con los vértices de 1 m del lado
vecino, así que no hay grietas ni uniones en T. Caminos, zonas, edificios y muros usan exactamente las mismas facetas
(`Terreno.altura(x, z)` devuelve la altura de la malla exportada), de modo que quedan encima del terreno y spawns, tests y
colisión coinciden. Una malla uniforme de 1 m daba 3,2 M de triángulos de terreno y un .glb de 78 MB; la variable, 0,4 M y
12,8 MB (import de Godot en unos 7 s).

Opciones (comunes a `generar_blockout.py` y `generar_spawns.py`; usa las mismas en los dos. Los valores por defecto viven
solo en `scripts/terreno.py`; `generar_spawns.py` aborta si la fuente, el suavizado, los pasos, la zona fina o `cota_ref` no
coinciden con el `meta` del blockout):

- `--mdt RUTA`: raster de cotas (por defecto `data/raw/mdt_lidar_1m.tif`).
- `--terreno mdt|plano`: `plano` mantiene el suelo plano en y=0 de antes (edificios sin zócalo, sin densificar).
- `--paso-terreno M`: paso FINO (m) de la malla y de la densificación de lo que se apoya en ella (1 por defecto).
- `--paso-grueso M`: paso fuera de la zona fina (4 por defecto; múltiplo de `--paso-terreno`; si es <= que éste, la malla es uniforme).
- `--buffer-fino M`: radio de la zona fina (8 por defecto; 0 = sin zona fina, malla uniforme).
- `--suavizado-m M`: sigma (m) del suavizado gaussiano del MDT (1 por defecto; 0 = sin suavizar). Antes se rellenan los
  nodata por interpolación y se aplica una mediana 3x3 contra artefactos puntuales.

**Alternativa: MDT de 5 m del IGN** (`data/raw/mdt_upo.tif`, se baja con `scripts/terreno_mdt.py`). Reproduce el relieve
anterior (malla uniforme de 4 m, .glb de ~6 MB):

```
uv run python scripts/generar_blockout.py --mdt data/raw/mdt_upo.tif --paso-terreno 4 --suavizado-m 5
uv run python scripts/generar_spawns.py   --mdt data/raw/mdt_upo.tif --paso-terreno 4 --suavizado-m 5
```

**Regenerar el MDT de 1 m desde LiDAR**: colocar las nubes PNOA-LiDAR 2.ª cobertura (2020, `.laz`) del campus en
`data/raw/lidar/` (no versionado; se tratan solo como datos) y ejecutar `uv run python scripts/lidar_procesar.py`
(`--releer` ignora la caché de puntos `data/raw/lidar_campus_pts.npz`). Usa solo la clase suelo (mediana por celda de 1 m,
descarte de atípicos, huecos por TIN) y escribe `data/raw/mdt_lidar_1m.tif`, además de `export/lidar_resumen.json` y
`export/terreno_lidar_preview.png`. Después, regenerar blockout y spawns.

Cómo se apoya cada elemento (`scripts/terreno.py` ofrece `Terreno.altura(x, z)`, que devuelve la altura de la malla
exportada, de modo que spawns, caminos y colisión coinciden):

- Caminos y zonas: mallas drapeadas, cada vértice a `altura + offset` (0,03 caminos; 0,013-0,016 zonas).
- Edificios volumen: base a (cota mínima bajo la huella - 0,5 m), cubierta a (cota media + altura); soportales con el
  gálibo medido desde la cota media.
- Techos (también `building=roof`, con `base_m` relativa al terreno local) y túneles: la losa sigue al terreno
  (cara superior a `altura + altura_m`, grosor constante, watertight); pilares desde terreno - 0,3 m hasta la losa;
  paredes de túnel desde terreno - 0,3 m hasta la losa.
- Muros, vallas, pádel y `limite`: prismas con base a terreno - 0,3 m y cara superior a terreno + altura.

Además de `export/preview.png` (con curvas de nivel cada 1 m, cota sobre el nivel del mar), se generan
`export/perfil_pasillo.png` (perfil lateral del pasillo cubierto central: terreno, losa y pilares, medido sobre el .glb) y
`export/perfil_escaleras.png` (las dos escaleras OSM 1373674173 y 1373674174: MDT de 5 m, MDT de 1 m y malla final).
`generar_spawns.py` escribe y = terreno + 0,1 en los spawns y datos de test relativos al terreno (rayos a 1,5 m sobre
él, troceados en tramos si el terreno estorbaría; ver su docstring).

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
