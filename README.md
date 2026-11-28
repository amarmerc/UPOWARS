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

### Suelo de pasillos (columna `suelo` de `data/alturas.csv`) y escaleras (`data/escaleras.csv`)

Vacio = el suelo es el terreno. `suelo=plano` (techos con pasillo bajo ellos: el pasillo central `1373541639` y la marquesina
diagonal del 18 `553042591`) convierte el terreno bajo la huella en un pavimento blanco y recto:

- Plano: ajuste robusto LIBRE (residuos > 0,5 m fuera) a las cotas del MDT de 1 m dentro de la huella encogida 0,5 m (sin
  edificios volumen).
- El terreno se aplana a ese plano en `Terreno.altura_raster()` (antes de mallar: colision y `altura()` coinciden) dentro de
  huella + 1,5 m; donde se solapan dos zonas manda el pasillo central. Fuera, transicion suave de 2 m solo donde el exterior esta
  a menos de 0,5 m del plano; donde queda mas de 0,5 m por debajo se levanta un muro de hormigon (0,3 m, con colision, nodo
  `muros_suelo-col`) desde la cota exterior - 0,5 m hasta plano + 1,0 m (pretil), y donde queda mas de 0,5 m por encima, un muro
  de contencion hasta la cota exterior. Resultado: un macizo por el que se anda y bajo el que no se puede pasar (la marquesina del
  18 cruza asi el cauce).
- Malla `suelo_pasillos` (+2 cm, material `pavimento_blanco`, baldosa casi blanca, sin colision) sobre la huella.
- Losa: si la losa `inclinado` del LiDAR deja < 2,4 m sobre el suelo en algun punto, se usa una losa paralela al suelo con
  galibo 3,0 m. Los pilares parten del suelo aplanado.

`data/escaleras.csv` (id, x1, z1, x2, z2, ancho, notas; coordenadas de juego, (x1, z1) arriba y (x2, z2) abajo): cada fila genera una
escalera de peldaños de 0,17 x 0,30 m (nodo `escaleras`, sin colision, material `pavimento_blanco`), una rampa lisa de colision
(`escaleras_rampa-col`, invisible; ademas el terreno bajo ella se aplana a la misma rampa), muros laterales con barandilla
(`escaleras_muros-col`) y recorta los muros de los pasillos en su arranque. Las cotas de arriba y abajo son las del suelo resuelto
en cada extremo. Fila `18-bajada`: del final del pasillo central (~14,5 m s.n.m.) al arranque de la marquesina 553042591 (~12,0 m).

`generar_spawns.py` escribe los datos de `test_suelos`, `test_puente` y `test_recorrido` (puntos del suelo sobre su plano, rayos
contra el pretil y el macizo, recorrido a pie ida y vuelta por la escalera y la marquesina). `scripts/zoom_zona_hundida.py`
dibuja la zona entre el 18 y el 24 (`export/zoom_pasillo_hundido.png`) y mide las zanjas del MDT.

Cómo se apoya cada elemento (`scripts/terreno.py` ofrece `Terreno.altura(x, z)`, que devuelve la altura de la malla
exportada, de modo que spawns, caminos y colisión coinciden):

- Caminos y zonas: mallas drapeadas, cada vértice a `altura + offset` (0,03 caminos; 0,013-0,016 zonas).
- Edificios volumen: base a (cota mínima bajo la huella - 0,5 m), cubierta a (cota media + altura); soportales con el
  gálibo medido desde la cota media.
- Techos (también `building=roof`, con `base_m` relativa al terreno local) y túneles: columna `nivel` de
  `data/alturas.csv`: `plano` (defecto) = losa horizontal con la cara superior a una cota absoluta constante
  (`cota_abs`, m s.n.m.; si está rellena manda; si no, mediana de mdt+ndsm LiDAR en la huella encogida 1 m con
  ndsm >= 2 m, o terreno máximo + altura si hay < 10 píxeles); `inclinado` (defecto del pasillo central) = plano de
  mínimos cuadrados de esos píxeles; `terreno` = losa drapeada sobre el terreno. Grosor 0,4 m, watertight. Los
  valores calculados se escriben en el CSV (nivel, cota_abs y notas) si estaban vacíos. Pilares desde terreno - 0,3 m
  hasta la cara inferior de la losa en su punto; paredes de túnel desde terreno - 0,3 m hasta la losa. El generador
  avisa si el terreno sobresale por encima de la cara inferior de la losa. `forma=excluir` omite el edificio.
- Muros, vallas, pádel y `limite`: prismas con base a terreno - 0,3 m y cara superior a terreno + altura.

Además de `export/preview.png` (con curvas de nivel cada 1 m, cota sobre el nivel del mar), se generan
`export/perfil_pasillo.png` (perfil lateral del pasillo cubierto central: terreno, losa y pilares, medido sobre el .glb),
`export/perfil_marquesinas.png` (marquesinas 321893434 y 555538618, igual) y
`export/perfil_escaleras.png` (las dos escaleras OSM 1373674173 y 1373674174: MDT de 5 m, MDT de 1 m y malla final).
`generar_spawns.py` escribe y = terreno + 0,1 en los spawns y datos de test relativos al terreno (rayos a 1,5 m sobre
él, troceados en tramos si el terreno estorbaría; ver su docstring).

### Vegetación y coches

`generar_blockout.py` añade (módulos `scripts/vegetacion.py`, `scripts/coches.py` y `scripts/entorno.py`, este último con los
obstáculos comunes):

- **Árboles** desde `data/raw/ndsm_veg_lidar_1m.tif`: nDSM suavizado (gauss 1 px), máximos locales en ventana de 5 m con
  altura >= 3 m, separación mínima 3 m (se conserva el más alto), radio de copa = región conectada por encima del 50 % de la
  altura (acotado por una regla altura-radio y a 1,5-7 m). Se descartan los troncos dentro de edificios (+1 m), sobre
  caminos, aparcamientos, agua o pistas, a < 2 m de pilares y muros/vallas, a < 3 m de un spawn y fuera del muro límite.
  Tronco = prisma de 8 lados hasta el 45 % de la altura (radio 0,15-0,3 m); copa = icosfera de 1 nivel escalada entre el
  35 % y el 100 %. Nodos: `arboles_troncos-col` (con colisión) y `arboles_copas`, `arboles_copas_2`, `arboles_copas_3`
  (sin colisión; uno por tono de verde, porque Godot no usa el color de vértice del glTF como albedo).
- **Coches** (props estáticos con colisión): carrocería + habitáculo + cristales + 4 ruedas, 6 colores apagados. Nodos
  `coches_<color>-col`, `coches_ruedas-col` (con colisión) y `coches_cristales`. Aparcamientos (todos los `amenity=parking`):
  filas de plazas de 2,5 x 5 m en doble fila con pasillo de 6 m dentro del polígono con 1 m de margen (se elige la
  orientación y fase con más plazas útiles), ocupación aleatoria; bajo marquesinas solo con >= 2,1 m de galibo; evitan
  pilares (0,5 m), árboles, edificios, muros y spawns (5 m). Carreteras: coches aparcados en el borde de vías
  service/residential (a la derecha del sentido de la vía) y alguno parado en una tertiary, separados >= 40 m y a >= 15 m
  de cruces y rotondas. Cada coche se apoya en el terreno (centro = media de las 4 ruedas, inclinado según su plano) y no se
  coloca donde el terreno se aparta > 25 cm de ese plano o supera 10 grados.
- `export/coches.json`: posición (juego), `yaw_deg` (rotación Y de Godot), `pitch_deg`, `roll_deg`, color y origen
  (`parking P11`, `carretera`...) de cada coche, por si se quieren editar.
- Previews: `export/preview.png` dibuja las copas (círculos verdes) y los coches (rectángulos); `export/zoom_aparcamiento.png`
  amplía el aparcamiento P11.

Opciones (comunes a `generar_blockout.py` y `generar_spawns.py`; usa las mismas en los dos: `generar_spawns.py` reconstruye
árboles y coches y aborta si no coinciden con el blockout):

- `--sin-arboles`: no genera árboles. `--sin-coches`: no genera coches.
- `--ocupacion F`: fracción de plazas ocupadas (0,55 por defecto).
- `--coches-carretera N`: coches en carretera (15 por defecto).
- `--semilla N`: semilla del azar (tonos, ocupación, colores, pequeñas variaciones de posición); misma semilla = mismo mapa (1).
- `--altura-min-arbol M` (3) y `--sep-arboles M` (3): sube cualquiera de los dos para tener menos árboles.
- `--ndsm-veg RUTA`: nDSM de vegetación (por defecto `data/raw/ndsm_veg_lidar_1m.tif`).

Árboles y coches evitan los puntos de `game/data/spawns.json` si existe (lo leen antes de que `generar_spawns.py` lo
reescriba), y `generar_spawns.py` mueve al punto libre más cercano cualquier spawn bloqueado por un tronco o un coche.
`spawns.json` lleva además `n_arboles`, `n_coches`, `test_coche` y `test_arbol` para el test de Godot. Orden recomendado
tras cambiar opciones o datos: `generar_blockout.py`, `generar_spawns.py`, import de Godot y test.

`generar_blockout.py` copia el .glb a `game/assets/mapa/` salvo que se pase `--no-copiar-godot`.
Después de regenerar el mapa conviene volver a ejecutar `generar_spawns.py` y reimportar en Godot
(abrir el editor o `--import`). Los spawns usan las mismas coordenadas que el glb
(x = este, y = arriba, z = -norte, metros; origen = centroide del campus).

### Texturas y bordes del campus

**Texturas procedurales** (sin descargas): `scripts/generar_texturas.py` (numpy + Pillow, semilla fija `--semilla 7`) escribe
PNG tileables de 512x512 en `game/assets/texturas/`: `albero`, `asfalto`, `baldosa` (losetas de 0,4 m), `cesped`, `hormigon`,
`aparcamiento`, `pista`, `agua` y `campo` (exterior). Sin normal maps ni líneas de plaza (las plazas no tienen orientación fija
en un triplanar). Cómo regenerarlas:

```
uv run python scripts/generar_texturas.py
Godot_v4.7.2-stable_win64_console.exe --headless --path game --import
uv run python scripts/generar_texturas.py      # solo la 1.ª vez: parchea los .png.import con mipmaps/generate=true
Godot_v4.7.2-stable_win64_console.exe --headless --path game --import
```

(El import por defecto de un PNG no genera mipmaps y la textura centellea a distancia; el script los activa en los `.import`.
`project.godot` fija el filtrado anisotrópico a 16x.)

**Materiales** (`game/scripts/materiales.gd`, llamado desde `mapa.gd`): el .glb no tiene UVs, así que cada material del .glb
(por nombre) se sustituye en runtime por un `StandardMaterial3D` con `uv1_triplanar` + `uv1_world_triplanar` y escala en metros por
tesela: suelo->albero (4 m), camino_asfalto->asfalto (4), camino_peatonal->baldosa (3,2), verde->cesped (3), pista->pista (4),
agua->agua (6, roughness 0,12), aparcamiento->aparcamiento (4), muros/pilar/cubierta->hormigon (3), campo (10). Edificios y torre usan
`game/shaders/fachada.gdshader`: en caras verticales, plantas de 3,5 m y ventanas de 1,5x1,4 m cada 3 m en coordenadas de mundo
(la coordenada horizontal es la proyección sobre la tangente de la normal, así que alinea en cualquier orientación); cristal azul
oscuro reflectante y pared del color del edificio con ruido; en horizontales, grava gris. El shader calcula la normal plana de
la cara por derivadas (el .glb no trae normales y Godot las suaviza entre cubierta y paredes). `cristal_padel`, `limite`, copas y
corteza conservan su color/transparencia (copas y coches con roughness ajustado; los translúcidos no proyectan sombra). La malla
`valla_malla` usa `game/shaders/valla.gdshader` (rombos de alambre en mundo). Ni la geometría ni la colisión dependen de los materiales.

**Bordes** (en `generar_blockout.py`): `valla_perimetral` (postes de 10 cm cada 3 m, 2 m de alto, apoyados en el terreno) y
`valla_perimetral_malla` (panel fino), ambas sin colisión, 0,8 m por dentro del muro `limite` (que está a 20 m del contorno): así
el jugador ve la valla justo donde topa con la colisión; en el contorno real quedaría 20 m dentro del área jugable. `exterior`: faldón
de terreno SIN colisión (anillo de malla de 2 km alrededor del borde de la malla del terreno; cota del borde del MDT, con caída
suave de 0,004 m/m y ondulación creciente con la distancia; material `campo`). Niebla: `fog_density` 0,0009, color igual al
horizonte del cielo (y el suelo del cielo del mismo color); `far` de la cámara 4500 m.

**Capturas** (necesitan GPU, no `--headless`): `Godot_v4.7.2-stable_win64_console.exe --path game --script res://tests/captura.gd`
guarda PNG en `export/capturas/` (spawns, aparcamiento, fachada, bordes con valla y vista aérea).

## Zonas y coberturas (paquete P1)

Base del modo competitivo (ver `docs/DISENO_COMPETITIVO.md`, secciones 8 y 9): 5 zonas del campus cerradas con un muro translúcido de
runtime y coberturas con colisión dentro del `.glb`. Todo es dato editable. Orden de regeneración: `generar_props.py` (solo la 1.ª vez, o
`--completar`) -> `generar_blockout.py` -> `generar_spawns.py` -> `generar_zonas.py` -> import de Godot.

```
data/zonas.json          fuente editable de las zonas (coordenadas de juego: x = este, z = -norte; yaw = rotación Y de Godot)
data/props.csv           coberturas: tipo, x, z, yaw, escala, notas (se edita a mano; ver más abajo)
scripts/generar_zonas.py valida, completa y exporta a game/data/zonas.json (y dibuja export/zonas/<id>.png)
scripts/generar_props.py propone data/props.csv (no lo pisa sin --forzar; --completar solo añade lo que falte)
scripts/props.py         geometría low-poly de cada tipo de cobertura; scripts/zonas_nav.py rejilla de navegación para estimar tiempos
game/scripts/zonas/zona_activa.gd   ZonaActiva: muro, barreras y marcadores en runtime; game/shaders/muro_zona.gdshader
game/tests/test_zonas.gd            tests z0-z6; test_mapa.gd (bloque p) comprueba los props; tests/captura_zonas.gd las capturas
```

### data/zonas.json

Por zona: `id`, `nombre`, `limite` (8-20 vértices `[x, z]`), `sites` `A` y `B` (`{centro, radio}` con radio 8-12 m, o `{poligono}`),
`spawn_atacantes` / `spawn_defensores` (`posiciones`: 5 x `[x, z, yaw]`, y `barrera`: polígono que encierra el spawn) y `camara_lobby`
(`pos` `[x, z]` + `altura` sobre el terreno, `mira` `[x, z]`, `fov`). `generar_zonas.py` lo lee y:

- **Valida** (un error da código de salida 1): vértices, límite dentro del área jugable, sites de 8-12 m dentro del límite y fuera de
  edificios cerrados (las huellas descuentan los pasos peatonales abiertos), 5 spawns por equipo dentro de su barrera y libres de troncos / coches /
  props / edificios, barreras fuera de edificios, y que el límite y las barreras no corten troncos ni coches (`construir_props` los excluye:
  `entorno.py` aparta árboles y coches de los límites, de las barreras de spawn y de las coberturas). Avisa, sin fallar, del tamaño (~120-200 m),
  de los metros de límite que pasan por dentro de un edificio (el muro queda oculto en él) y de lo que no cumpla los objetivos de abajo.
- **Estima los tiempos** (`scripts/zonas_nav.py`): rejilla de 0,5 m dentro del límite; una celda es transitable si no toca ningún obstáculo
  engrosado 0,4 m (edificios macizos, pilares, muros y vallas, troncos, coches, coberturas) y la pendiente entre celdas vecinas es <= 42 grados;
  Dijkstra con 8 vecinos y tiempo = longitud / 5 m/s (la velocidad de correr). Para cada spawn da el tiempo al centro de cada site; la ventaja de
  los defensores es la media de los 5 atacantes menos la de los 5 defensores (objetivo 5-8 s). Cuenta las **rutas distintas** de los atacantes a cada
  site (tras cada ruta se bloquea una banda de 3 m a cada lado de su tramo central y se busca la siguiente, hasta 2,2 veces la más corta) y el mayor
  **tramo abierto** de las rutas (sin cobertura de > 0,8 m a menos de 3 m; no se exige dentro de la barrera de spawn + 4 m).
- **Exporta** `game/data/zonas.json` con la y del terreno: `limite`, `limite_denso` (puntos cada <= 4 m, para el muro), sites, spawns (y + 0,1),
  `barrera` / `barrera_densa`, cámara del lobby y la estimación. `--depurar` pinta en rojo las celdas no transitables de la preview.

Las 5 zonas (`export/zonas/<id>.png`: límite en rojo, sites, spawns y barreras por equipo, edificios, árboles, coches, coberturas, rutas de
spawn a site, curvas de nivel cada 0,5 m y una x magenta donde quedaría un tramo abierto). Tiempos medidos por el test z4 con `NavigationServer3D`
(a 5 m/s, media de los 5 spawns, atacantes / defensores y ventaja); la estimación de Python coincide a +-1 s:

| Zona | Tamaño | Site A | Site B | Qué contiene |
|---|---|---|---|---|
| `plaza_america` Plaza América | 185 x 168 m | Plaza norte: 21,6 / 16,7 s (+4,9) | Plaza sur: 21,2 / 15,7 s (+5,5) | Rectorado 31/32 (cada equipo lo rodea por un lado), torre 35, cubierta en V; 4-6 rutas a cada site |
| `biblioteca_24` Biblioteca-24 | 163 x 120 m | Arcada: 16,9 / 10,7 s (+6,2) | Pasarela: 16,8 / 9,3 s (+7,5) | Patio entre el 25 y el 24, arcada, pasarela 555538618, plaza de la rotonda; 6 rutas |
| `detras_22` Detrás del 22 | 194 x 98 m | Aula al aire libre: 19,9 / 13,7 s (+6,2) | Bosque norte: 21,7 / 15,6 s (+6,1) | Bosque con troncos gruesos, franja 22-24 de 5 m, patio del 23 con el estanque; 3 rutas |
| `el_eje` El Eje | 174 x 140 m | Eje central: 17,1 / 12,3 s (+4,9) | Patio este: 25,0 / 18,6 s (+6,4) | Pasillo cubierto con muros laterales y los patios entre los edificios 5-12; 3 rutas |
| `el_puente` El Puente | 201 x 114 m | Valle del cauce: 22,5 / 15,8 s (+6,6) | Aparcamiento: 21,7 / 16,2 s (+5,5) | Final del pasillo central, escalera, marquesina-puente 553042591 en rampa, valle arbolado; 3-4 rutas |

### Muro, barreras y marcadores (`ZonaActiva`)

`ZonaActiva` (`class_name`, `Node3D`) carga una zona y construye **en runtime** (el `.glb` no cambia; fuera del modo competitivo no se instancia nada):

```gdscript
var zona := ZonaActiva.crear("plaza_america")      # null si el id no existe (ZonaActiva.ids_disponibles() los lista)
add_child(zona)
zona.activar_barreras(true)                         # fase de compra: barreras de los dos equipos con colisión; false las quita
var sp: Dictionary = zona.punto_spawn("atacantes", 0)   # {"pos": Vector3, "yaw_deg": float}; i = 0-4; "defensores" igual
zona.site_en(jugador.global_position)               # "A", "B" o ""
zona.limites()                                      # {poligono: PackedVector2Array (x, z), min, max, centro, alto_muro}
```

- **Muro perimetral**: 8 m sobre el terreno (y 2 m enterrado), malla `Muro/Malla` con `muro_zona.gdshader` y `Muro/Cuerpo` (StaticBody3D en la
  capa 1 `mundo`: una caja por tramo de `limite_denso`, así que bloquea al jugador y a los disparos). **Barreras de compra** (`Barrera_atacantes`,
  `Barrera_defensores`, 4 m): igual pero con el color del equipo (naranja / azul); `activar_barreras(false)` las oculta y pone su capa a 0
  (por defecto, tras `cargar`, están desactivadas).
- **`muro_zona.gdshader`**: hexágonos de 1,5 m en coordenadas de la propia pared (UV = metros a lo largo y sobre el terreno). Relleno casi
  transparente (alfa 0,035) y aristas que pasan de 0,34 de alfa (lejos; se engrosan con la distancia para no desaparecer) a 0,6 junto a la
  cámara (`CAMERA_POSITION_WORLD`); el alfa nunca supera `alpha_max` (0,75). Base y corona algo más marcadas, pulso suave, sin sombra.
- **Marcadores**: `Label3D` con la letra del site flotando a 5,5 m (billboard) y un `Decal` con un aro en el suelo del radio del site.
- `camara_lobby()` devuelve `{pos, mira, fov}` de la vista previa del lobby.

### Coberturas (`data/props.csv` y `props.py`)

Tipos clasicos: `banco`, `murete` (4 m x `escala`, o `largo=6` en `notas`; 1,0 m de alto), `jardinera` (con arbusto), `contenedor` (basura, grande),
`reciclaje_azul` / `reciclaje_amarillo` / `reciclaje_verde`, `aparcabicis`, `marquesina` (autobús; una en cada `highway=bus_stop` de OSM, de cara a
la carretera), `expendedora` (junto a fachadas), `pila_sillas`, `mesa` (`volcada` en `notas` para usarla de cobertura) y `aula` (el aula al aire
libre: 4 filas de 4 asientos con respaldo mirando a una pizarra sobre patas; `claro=9` en `notas` quita los troncos a 9 m).

**Coberturas de obra (grandes, mejoras tras probar el juego)**: `muro_obra` (bloques u hormigon a medio construir, 2-2,5 m de alto y 3-6 m de largo, coronacion escalonada; notas `largo=`, `alto=`, `ladrillo`, `l` = en L), `valla_obra` (tablones de 2 m), `palets` (dos pilas; `n=7` = 1,05 m para agacharse, `n=14` = 2,1 m), `sacos` (pila escalonada de ~1,1 m), `bigbag` (fila de 3 de ~1,15 m; `alto=2` = 2,3 m), `cuba` (cuba de escombros de 3,7 m y ~1,6 m), `caseta` (caseta de obra de 2,6 m), `bobina` (cable tumbada de 1,1 m; `n=2` = 2,2 m) y `bloques` (palet con paquetes de bloques; `n=2` = 1,3 m, `n=4` = 2,4 m; `ladrillo`). Mezclan alturas bajas (1-1,2 m: agacharse) y altas (>= 2 m: cubren de pie). Materiales nuevos `prop_ladrillo`, `prop_saco`, `prop_cuba`, `prop_caseta`. Las parametrizaciones van en `notas` (`clave=valor; flag`), antes del texto libre.
`x`, `z` son de juego; `yaw` es la rotación Y de Godot (el *frente* del prop mira a -Z con yaw 0); una fila con `#` en `tipo` se ignora.

Cada prop son cajas cerradas (watertight) apoyadas en el terreno (las del suelo bajan hasta el punto más alto de la huella y el desnivel bajo ella
debe ser <= 0,45 m), un nodo por material: `props_hormigon-col`, `props_madera-col`, `props_metal-col`, `props_basura-col`,
`props_reciclaje_azul/amarillo/verde-col`, `props_expendedora-col`, `props_cristal_oscuro-col`, `props_pizarra-col`, `props_silla-col` y
`props_arbusto` (sin colisión). Los materiales conservan su color del `.glb` (`materiales.gd` solo ajusta rugosidad y metal). Árboles grandes: dentro
de las zonas, los árboles de >= 6 m tienen tronco de 0,45-0,7 m de radio = 0,9-1,4 m de diámetro, que tapa a un jugador (`--altura-tronco-grande`, antes 12 m y 0,5-0,7); la copa se ensancha (radio >= 1,4 + 2,2 x radio del tronco) y el tronco sube al 55 % de la altura. Son 280 con la semilla 1 (cuentan como cobertura).

`generar_props.py --completar --densificar` (idempotente; no toca tus filas) refuerza cada site hasta 11 coberturas altas a < 10 m del centro y rellena los espacios abiertos de cada zona (ningun punto libre a > 10 m de una cobertura, separacion >= 2 m entre coberturas grandes y rutas principales libres); correrlo dos veces porque las rutas cambian al poner props. `generar_props.py` propone: el aula (en el bosque de `detras_22`, junto al 24), 5 coberturas alrededor de cada site, grupos de mobiliario junto a
las fachadas (reciclaje, expendedoras, aparcabicis), una cobertura cada vez que quedaría un tramo abierto de > 12 m en alguna ruta (`generar_zonas` avisa por encima de 14 m; antes 22 / 25 m), las 6
marquesinas y unos pocos bancos / contenedores fuera de las zonas. Nunca pone nada sobre edificios, troncos, coches, pilares, muros, escaleras,
pasos peatonales, agua ni las barreras de spawn; deja libre el eje de los suelos de pasillo (los tests de recorrido pasan por él) y los puntos de
`test_suelos`. Tras editar el CSV a mano, `generar_zonas.py` lo revalida (solapes, suelos reservados, desnivel) y `generar_props.py --completar` añade
lo que falte sin tocar tus filas. Con las posiciones actuales hay 476 props (antes 246; 160 de obra grande) y unos 51 000 triángulos.

Opciones nuevas, comunes a `generar_blockout.py` y `generar_spawns.py` (usa las mismas en los dos): `--zonas data/zonas.json`,
`--props data/props.csv`, `--altura-tronco-grande 12`. `generar_spawns.py` escribe además `n_props`, `test_props` (un rayo horizontal por tipo hacia
el centro de su caja mayor) y `aula` en `spawns.json`, y no coloca spawns sobre coberturas.

### Tests y capturas

```
Godot_v4.7.2-stable_win64_console.exe --headless --path game --import
Godot_v4.7.2-stable_win64_console.exe --headless --path game --script res://tests/test_mapa.gd     # incluye p1-p4: props existen, colisión, rayos, aula
Godot_v4.7.2-stable_win64_console.exe --headless --path game --script res://tests/test_zonas.gd    # opcional: -- <id> para una sola zona
Godot_v4.7.2-stable_win64_console.exe --path game --script res://tests/captura_zonas.gd            # con GPU: solo las capturas de zonas
```

`test_zonas.gd`, por zona: **z1** el muro existe, su StaticBody3D está en la capa mundo y el shader es `muro_zona` con `alpha_max` < 1; **z2** los 10
spawns tienen la cápsula del jugador libre, suelo debajo y están dentro del límite; **z3** los sites (y 16 puntos de su perímetro) están dentro del
límite; **z4** con una `NavigationMesh` horneada de la zona (`NavigationServer3D`, colisiones del mapa + muro) desde cada spawn se llega a A y B, y
registra los tiempos a 5 m/s (la tabla de arriba); **z5** rayos de dentro hacia fuera por el medio de cada tramo del límite chocan con el muro (>= 60 %;
el resto queda tapado por un edificio) y un rayo a 7 m de altura también; **z6** 8 `CharacterBody3D` con la cápsula del jugador corren 2,5 s desde el
spawn: con `activar_barreras(true)` ninguno sale del polígono de la barrera y con `false` salen. Además **z0**: la escena principal no instancia
ninguna zona, un id desconocido devuelve null y están las 5 zonas. Las capturas (`export/capturas/`) son `zona_<id>.png` (desde el spawn de
defensores con las barreras activas), `zona_<id>_muro.png` (el muro de 8 m visto desde dentro), `zona_<id>_lobby.png` y `aula_aire_libre.png`;
`captura.gd` las incluye al final de su ejecución.

## Jugar (Godot 4.7.2)

Abrir el proyecto `game/` con `D:\Juegos\godot\Godot_v4.7.2-stable_win64.exe` (importador de proyectos, o
`Godot_v4.7.2-stable_win64.exe --path game`) y pulsar F5. Al arrancar aparece el **lobby** (ver "Partida (paquete P4)"); la escena
principal es `scenes/juego.tscn`. `scenes/main.tscn` es el mundo (campus, jugador, HUD de combate) que usan juego y tests.

Controles de movimiento (los de combate están en las secciones de armas): WASD mover, ratón mirar, Espacio saltar, Shift correr, Alt caminar lento, Ctrl agacharse,
F2 liberar/capturar el ratón (Esc ahora es el menú), M reabrir el selector de spawn (modo libre), F1 modo vuelo/noclip (20 m/s, x3 con Shift; Espacio/Ctrl suben/bajan).
Combate: clic izquierdo disparar (mantenido = ráfaga si el arma es automática), clic derecho ataque fuerte con la navaja,
R recargar, 1 fusil, 2 pistola, 3 navaja, rueda del ratón siguiente/anterior arma, Q última arma, F3 mostrar/ocultar los
datos de depuración, K suicidio (pruebas). Las acciones están en el Input Map de `game/project.godot`. Colisión: los nodos
`-col` del .glb se importan como StaticBody3D trimesh (automático en Godot); el muro `limite` se oculta y los materiales se
aplican en `game/scripts/mapa.gd`.

## Armas y combate (fase 4a)

Capas de física (`project.godot`): 1 `mundo` (mapa), 2 `hitbox` (zonas de impacto), 3 `cuerpo` (cápsula de movimiento del
jugador, que ya no la ven los disparos). Los disparos usan la máscara 1+2: el rayo se detiene en lo primero que choque, así
que una pared delante de una hitbox bloquea el daño.

```
game/scripts/combate/
  arma_datos.gd      Resource ArmaDatos: todos los números de un arma
  salud.gd           nodo Salud: vida, armadura, señales herido(cantidad, zona, atacante) y muerto(atacante)
  hitboxes.gd        nodo Hitboxes: cabeza, torso y piernas (Area3D ZonaImpacto, capa hitbox); reutilizable por jugador, dianas y bots
  balistica.gd       Balistica (estática): resolver_disparo(origen, direccion, arma, tirador, rng, dispersion_deg) -> {impacto, punto,
                     normal, collider, zona, daño, distancia, ...}; dispersion(); calcular_dano(); aplicar(). Sin entrada ni dibujo: RNG inyectable
  gestor_armas.gd    GestorArmas (hijo del jugador): ranuras, disparo, cadencia, recarga, cambio, retroceso; avanzar(delta) + gatillo
  viewmodel_capa.gd  arma en primera persona en un SubViewport con mundo propio (no atraviesa paredes) + animaciones
  efectos.gd         trazadores, fogonazo, marcas de impacto (pool de 64), chispas y sonidos de impacto
  diana.gd, campo_practica.gd
game/data/armas/     fusil_r7.tres, pistola_p9.tres, navaja.tres
```

**Equilibrar**: editar los `.tres` de `game/data/armas/` (en el editor de Godot o a mano; no hace falta tocar código).
Campos de `ArmaDatos`: `cadencia` (disparos/s), `automatica`, `tiempo_cambio`; `dano_base`, `mult_cabeza/torso/piernas`,
`alcance`, `caida_inicio` y `caida_factor_min` (el daño cae linealmente desde `caida_inicio` hasta `alcance`, donde vale
`dano_base x caida_factor_min`); `penetracion_armadura` (fracción del daño que llega a la vida si hay armadura; el resto lo
absorbe la armadura a 2 puntos de daño por punto); `cargador`, `reserva`, `tiempo_recarga`; `dispersion_quieto/agachado/
movimiento/aire` (semiángulo del cono en grados; en suelo se interpola con la velocidad entre quieto/agachado y movimiento
hasta 5 m/s); `retroceso_pitch` y `retroceso_yaw` (grados por disparo de la ráfaga, el último valor se repite),
`retroceso_recuperacion` (grados/s) y `retroceso_pausa`; `velocidad_mov` (multiplicador de velocidad del jugador). La navaja
usa `cuerpo_a_cuerpo`, `alcance` 2 m, `dano_base` (ligero, 40) y `dano_fuerte` / `intervalo_fuerte` (clic derecho, 65).

| Arma | Ranura | Disparo | Cadencia | Cargador / reserva | Daño | Recarga |
|---|---|---|---|---|---|---|
| Fusil R-7 | 1 | automático | 10/s | 30 / 90 | 33 (cabeza x4, piernas x0,75), pen. 0,7 | 2,4 s |
| Pistola P-9 | 2 | semiautomática | 6/s máx. | 12 / 48 | 28, pen. 0,5 | 1,7 s |
| Navaja | 3 | cuerpo a cuerpo, 2 m | 2/s (fuerte 1,1 s) | - | 40 / 65, pen. 0,85 | - |

Retroceso: cada disparo suma a la mira (`Jugador.fijar_retroceso`) un offset de pitch/yaw según su posición en la ráfaga;
si se deja de disparar (`retroceso_pausa`) la mira vuelve sola a `retroceso_recuperacion` grados/s (el ratón no se corrige).
Armadura: se aplica a todas las zonas por igual.

**Muerte**: al llegar a 0 de vida el jugador queda fijo (cámara baja y ladeada) `tiempo_reaparicion` = 2 s y reaparece en el
spawn elegido con vida 100, armadura 0 y munición llena. K lo provoca en pruebas.

**Campo de práctica**: spawn `campo_practica` ("Campo de práctica" en el selector de M) en (x 126, z -148), la explanada llana
al sureste de la Biblioteca 25 (~90 m de ella), entre el cauce y el polideportivo; el punto de tiro mira al sur y los 22 x 60 m
de delante no tienen troncos, coches ni edificios. 8 dianas a 10, 20, 35 y 50 m (a +-2,5 / 4 / 6 / 8 m del eje; 3 con armadura 100,
con chaleco amarillo); al morir caen y reaparecen a los 3 s; muestran el daño en números flotantes; una línea amarilla marca el
punto de tiro y carteles con la distancia a la derecha. El spawn se genera en `scripts/generar_spawns.py` (constante
`CAMPO_PRACTICA`), así que sobrevive a regenerar `spawns.json`; las dianas las coloca `campo_practica.gd` en runtime sobre el
terreno a partir de ese spawn (mismo yaw y posición).

**Sonidos**: `uv run python scripts/generar_sonidos.py` (numpy + wave, semilla fija) regenera los WAV sintéticos de
`game/assets/sonidos/`; después, reimportar en Godot.

Tests headless (deben terminar con PASS y código 0):

```
Godot_v4.7.2-stable_win64_console.exe --headless --path game --import
Godot_v4.7.2-stable_win64_console.exe --headless --path game --script res://tests/test_mapa.gd
Godot_v4.7.2-stable_win64_console.exe --headless --path game --script res://tests/test_combate.gd
```

`test_combate.gd` cubre daño por zona y armadura, caída por distancia, cargador/recarga/cadencia, bloqueo por el mundo,
dispersión, muerte y reaparición de dianas y jugador (usa las dianas reales del campo de práctica). Las capturas
(`tests/captura.gd`, con GPU) incluyen `combate_campo_fusil`, `combate_hud`, `combate_campo_vista`, `combate_pistola` y
`combate_navaja`.

## Arsenal, utilidades y controles (paquete P2)

Diseño en [docs/DISENO_COMPETITIVO.md](docs/DISENO_COMPETITIVO.md). Catálogo (ids, categorías, precios): `game/data/catalogo.gd`;
números de cada arma: `game/data/armas/*.tres` (campo `tipo`: hitscan, perdigones, proyectil, cohete, cuerpo, sable, puno o utilidad).
Código nuevo en `game/scripts/combate/`: `inventario.gd` (huecos, límites, munición, serializar), `proyectil.gd` (gravedad, rayo por tick,
sin RigidBody), `lanzable.gd`, `nube_vision.gd`, `altavoz.gd`, `utilidades.gd` (`linea_de_vision`, `marcados_para`), `estado_ceguera.gd`,
`arma_suelo.gd` (+ `scenes/arma_suelo.tscn`, `limpiar_armas_suelo()`), `armero.gd` (F6), `senales_combate.gd` (bus `ruido` y `baja`).
Todo el daño pasa por `Balistica` (RNG inyectable). Escudo 0-50 en `Salud` (equipo, `Salud.fuego_amigo` = false por defecto, autodaño explosivo).

**Controles**: WASD, Espacio salta, **Shift correr** (7,8 m/s, no se dispara corriendo y hay 0,25 s de demora), **Alt sigilo**, **Ctrl agacharse**,
**clic derecho apunta** (FOV menor, zoom por arma: pistolas y subfusiles 1,3-1,4x, fusiles 1,8-2x, tirador semiautomático 4x, precisión de cerrojo 4x y 8x: **rueda del ratón** o un **segundo clic derecho rápido** (< 0,45 s) cambia de nivel; sensibilidad del ratón proporcional a tan(FOV/2); `ArmaDatos.zoom` y `zoom_niveles`; menos dispersión, más lento, arma centrada; mira de zoom en el fusil de precisión y el tirador; con el
sable bloquea, con la navaja golpe fuerte), clic izquierdo dispara (arco y Puño-Bot: mantener para cargar), R recargar, 1 principal, 2 secundaria,
3 cuerpo a cuerpo, 4 utilidades (de nuevo 4 cicla), rueda cicla, Q última, **E recoger**, **G tirar el arma**, **F6 armero de pruebas**, F1 vuelo, M selector, F3 depuración, K suicidio.

| Arma | Categoría | Precio | Daño torso | Cadencia | Cargador | Contrapartida |
|---|---|---|---|---|---|---|
| Pistola 9 mm | secundaria | 0 | 28 | 6/s semi | 12/48 | - |
| Pistola automática 9 mm | secundaria | 500 | 19 | ráfagas de 3 | 21/63 | imprecisa |
| Pistola pesada .50 | secundaria | 800 | 54 | 2,4/s | 7/28 | lenta, poca munición |
| Revólver .357 | secundaria | 700 | 76 | 1,7/s | 6/24 | recarga 3,4 s |
| Escopeta recortada | secundaria | 600 | 8 x 11 | 2,5/s | 2/10 | cae enseguida |
| Subfusil compacto | secundaria | 900 | 15 | 15/s | 25/100 | imprecisa lejos |
| Subfusil 9 mm | principal | 1500 | 21 | 12,5/s | 30/120 | poco daño |
| Subfusil pesado .45 | principal | 1900 | 28 | 9/s | 25/75 | menos cadencia |
| Escopeta de corredera | principal | 1800 | 9 x 14 | 1,15/s | 6/24 | solo cerca |
| Escopeta automática | principal | 2600 | 7 x 9,5 | 4,2/s | 8/32 | poco daño por perdigón |
| Carabina 5,56 | principal | 2500 | 29 | 10,5/s | 30/90 | menos daño que el fusil |
| Fusil de asalto 5,56 | principal | 2900 | 33 | 10/s | 30/90 | base |
| Fusil de combate 7,62 | principal | 3200 | 44 (cabeza mata) | 6,5/s | 20/60 | lento, pesado |
| Fusil tirador semiautomático | principal | 3500 | 58 | 3,3/s | 10/40 | impreciso sin apuntar |
| Fusil de precisión de cerrojo | principal | 4700 | 115 | 0,85/s | 5/20 | muy lento, impreciso sin apuntar |
| Ametralladora ligera | principal | 3300 | 26 | 11/s | 100/100 | recarga 5,8 s, vel. 0,7 |
| Arco "Olivo" | especial | 2200 | 78 (cabeza 273) | carga 1 s | 10/20 | recuperación lenta |
| Tirachinas "Gomero" | especial | 400 | 20 | 2/s | 12/48 | poco daño |
| Lanzacohetes "Traca" | especial | 4500 | 125 área, 6 m | 0,8/s | 3/6 | 9 cohetes, autodaño, recarga 4,8 s |
| "Sable de Plasma" | especial | 3000 | 68 arco | 1,5/s | - | bloqueo con calor, 4 s sobrecalentado |
| "Puño-Bot" | especial (secundaria) | 600 | 46 + empuje | carga 0,8 s | - | vuelve a los 1,5 s |
| Navaja | cuerpo a cuerpo | 0 | 40 / 65 | 2/s | - | siempre |

Utilidades (máx. 2 de cada tipo, 4 en total; clic izquierdo fuerte, derecho flojo): humo 300 (5 m, 15 s), cegadora 250 (mecha 1,5 s),
explosiva 400 (mecha 2 s, 110 en 5,5 m), bote de pintura 300 (marca 5 s en 4 m), extintor 350 (nube 3 s que empuja), altavoz señuelo 200 (6 s).
Escudo: ligero 25 por 400, pesado 50 por 1000.

Tests: `test_arsenal.gd` (70 comprobaciones a1-a12) y `test_combate.gd`, ambos con `--headless --script`. Capturas del arsenal
(`captura.gd`, con GPU; pasar una carpeta de salida): `arsenal_mosaico`, `arsenal_precision_apuntando`, `arsenal_humo`, `arsenal_explosion`,
`arsenal_sable_bloqueo`, `arsenal_arco_carga`, `arsenal_armas_suelo`, `arsenal_hud`, `arsenal_ceguera`. Sirena de alarma de la Cachimba:
`game/assets/sonidos/sirena_alarma.wav` (la usará P4).

## Bots (paquete P3)

Bots jugables que usan los mismos componentes de combate que el jugador (`Salud`, `Hitboxes`, `Inventario`, `Balistica`, `Utilidades`, `SenalesCombate`,
`EstadoCeguera`, `ArmaSuelo`). Todo en `game/scripts/bots/`; el `Bot` es `scenes/bot.tscn` (CharacterBody3D, capa 3 `cuerpo`, mascara 1; hitboxes en la capa 2).

```
bot.gd            Bot: cuerpo, vida/escudo, muerte (suelta armas), reaparicion, comprar_kit(); ojos a 1,6 m
cerebro_bot.gd    CerebroBot: percepcion (vision con linea_de_vision: paredes y humo; ceguera; ruido y bajas) + maquina de estados + roles
comandos.gd       Comandos: contrato de acciones (mover_hacia, mirar_punto, disparar, recargar, cambiar_arma, lanzar_utilidad, comprar,
                  montar_cachimba, apagar_cachimba, recoger_arma, tirar_arma). comandos_bot.gd lo implementa para el Bot
armas_bot.gd      ArmasBot: cadencia, cargador, recarga, cambio; TODO el dano sale de Balistica; ruido por SenalesCombate
director_bots.gd  DirectorBots: roles, site de ataque, portador de la Cachimba, apagador, rotaciones, grupo flexible, informacion compartida
compra_bot.gd     CompraBot.comprar(dinero, inventario, rol, catalogo, rng) -> Array[StringName]: funcion PURA
dificultad_bot.gd perfiles facil / normal / dificil (reaccion, error de punteria, spray, giro, cabeza, rafagas, utilidades)
nav_bots.gd       NavBots: hornea la NavigationMesh en runtime (por zona o campus); puntos_tacticos.gd: puntos detras de coberturas
api_partida.gd    ApiPartida: interfaz que P4 debe ofrecer (comprar, montar/apagar Cachimba, cachimba(), modo(), zona(), dinero_de())
partida_prueba.gd + cachimba.gd   Partida MINIMA para probar sin P4 (sin rondas ni economia); la Cachimba (4 s / 40 s / 7 s) es provisional
prueba_bots.gd    escena de prueba (scenes/prueba_bots.tscn)
```

**Comandos comunes (sin tocar `player.gd`)**: refactorizar `Jugador`/`GestorArmas` era arriesgado (el gestor esta atado a la camara y la entrada), asi que `ArmasBot` reutiliza
`Inventario`/`Balistica` y se define el contrato `Comandos` + `ApiPartida`. P4 solo debe implementar `ApiPartida` y, si quiere, un `ComandosJugador` sobre `GestorArmas`.
`kit_reaparicion` y la logica de rondas/economia no se han tocado.

**Navegacion**: `NavBots.hornear_zona(raiz, zona)` hornea solo dentro del limite de la `ZonaActiva` (celdas 0,25 m: 0,2-0,4 s y 2 200-5 400 poligonos por zona);
`NavBots.hornear_campus(raiz)` hornea todo el campus con celdas de 0,5 m (~5 s, ~37 000 poligonos; no hace falta cachear a disco) y `hornear_radio` limita a un cuadrado.
Tras hornear: `await NavBots.esperar_listo(raiz, punto)`. Los bots piden rutas con `NavigationServer3D.map_get_path` (sin NavigationAgent3D) y detectan atascos
(nueva ruta -> paso lateral -> recolocarse en la malla; `comandos.atascos` / `rescates`). En el test los bots llegan a A y B desde todos los spawns en ~0,9x del tiempo
de la ruta (5 m/s). Las coberturas salen de `game/data/props_cobertura.json` (`uv run python scripts/exportar_props_bots.py` lo regenera desde `data/props.csv`).

**Comportamiento**: atacante (va en grupo flexible al site elegido; el portador monta la Cachimba quieto 4 s y los demas escoltan detras de coberturas, luego defienden),
defensor (reparte 3/2 los sites, defiende detras de una cobertura, el volante rota ante ruido o enemigo visto en el otro site, y al oir o ver la Cachimba el mas cercano la apaga 7 s
y los demas cubren), cazador (eliminacion: patrulla hacia el enemigo, sigue ruidos y avisos; a los 40 s sin bajas va al spawn enemigo), libre (deambula y combate, reaparece solo).
Todos: no ven a traves de humo/paredes, se ciegan con la cegadora (no ven, disparan a ciegas con mas dispersion), recogen armas mejores del suelo, usan granadas de vez en cuando
(explosiva / cegadora al enemigo visto o recien visto, humo al site los atacantes). Los bots no usan el Sable de Plasma ni el Puño-Bot (CompraBot no los compra); el arco dispara a carga completa.
Dificultad (`DificultadBot.PERFILES`, todo numerico): tiempo de reaccion, error de punteria inicial que decae, spray creciente, velocidad de giro, probabilidad de apuntar a la cabeza,
rafagas, uso de utilidades, memoria, vision. Determinista: `Bot.rng` se siembra (`Bot.crear(..., semilla)`) y `CompraBot.comprar` acepta un `rng` inyectable (sin rng no hay azar).

**Compra** (`CompraBot`): escudo (pesado si sobra, ligero si no; solo si despues llega a una principal) > principal segun dinero (pesos por rol) > hasta 3 utilidades > mejora de secundaria. Sin principal y sin llegar
a 1500 ahorra, salvo la ronda de pistolas (>= 800: la mitad de las veces escudo ligero + utilidad). Armas especiales ~7 % (tirachinas, arco, lanzacohetes).

**Probarlo** (con GPU; el jugador entra como un atacante o defensor mas):

```
Godot_console.exe --path game res://scenes/prueba_bots.tscn -- zona=el_eje modo=cachimba n=5 dificultad=normal equipo=defensores
   zona = plaza_america | biblioteca_24 | detras_22 | el_eje | el_puente | libre (campus entero)   modo = cachimba (Cachimba Wars) | eliminacion (Modo pleno)   jugador=0 para observar en vuelo libre
   teclas: F9 reinicia, F10 siguiente zona, F11 cambia la dificultad, F6 armero, K suicidio
Godot_console.exe --headless --path game --script res://tests/test_bots.gd [-- rapido]       # b1-b6: compra, comandos, combate, navegacion, apagar la Cachimba, 5v5 a x8
Godot_console.exe --path game --script res://tests/captura_bots.gd -- zona=plaza_america      # capturas en export/capturas_p3/
```

## Partida (paquete P4)

La escena principal (`game/scenes/juego.tscn`, script `scripts/juego.gd`) arranca en el **lobby** sobre una vista previa de la zona. Capas (arquitectura del documento
de diseño): la entrada y el render (`juego.gd`, `scripts/ui/*`) leen la `Partida` y mandan comandos; la `Partida` es la única que cambia el estado.

```
scripts/partida/partida.gd           Partida (extiende ApiPartida): fases, equipos, economia, tienda (comprar/vender), Cachimba, portador y fin de partida
scripts/partida/config_partida.gd    ConfigPartida: lo del lobby + tiempos (25 / 100 / 5 s) + economia (800, 9000, +200, +3000, 1900 +500 hasta 2900, +300) + reglas
scripts/partida/comandos_jugador.gd  ComandosJugador: la misma API de Comandos que los bots, sobre Jugador/GestorArmas (comprar, vender, montar, apagar, cambiar, recoger...)
scripts/partida/cachimba_suelo.gd    La Cachimba caida al morir el portador (se recoge acercandose)
scripts/ui/lobby_ui.gd tienda_ui.gd menu_pausa_ui.gd hud_partida.gd estilo_ui.gd icono_escudo.gd    lobby, tienda, pausa, HUD de partida y estilo comun
scripts/personajes/ + data/personajes/   personajes (catalogo, modelo, retratos) y scripts/partida/perfil_jugador.gd (perfil local)
scripts/juego.gd                     flujo: lobby -> montar (zona, navegacion, Partida, Director, bots) -> jugar -> volver al lobby; camara, espectador, teclas
tests/test_partida.gd                p1 economia, p2 tienda, p3 inventario, p4 fases, p5 victorias, p6 lados y fin, p7 partida completa con bots
tests/test_juego.gd                  humo del flujo: lobby (huecos, intercambio con bots, perfil, Listo), tienda (tarjetas, compra, venta), compra automatica, B, Esc, espectador, libre, volver al lobby
tests/generar_iconos.gd              genera game/assets/iconos/*.png desde los modelos del viewmodel (con GPU)
tests/montaje_partida.gd             ayuda de los tests: monta zona + navegacion + Partida + Director + bots
tests/sim_partida.gd                 simulacion acelerada de rondas con bots: tasas de victoria por bando (`-- zonas=el_eje rondas=12 dificultad=normal escala=12`)
tests/captura_p4.gd                  capturas del lobby, tienda, HUD, tabla y alarma en export/capturas_p4/ (con GPU, sin --headless)
```

**Lobby** (rehecho): a la izquierda un panel por equipo (nombre editable, por defecto EPS, que empieza atacando, y CEUPO) con los huecos del equipo como tarjetas con retrato; los huecos que no
son humanos son bots (tarjeta "BOT"). El jugador local aparece resaltado; **un clic sobre una tarjeta de bot (de cualquier equipo) intercambia al jugador con ese bot** (así se cambia de equipo o de hueco).
A la derecha: **Modo** (un solo desplegable: **Modo libre**, **Cachimba Wars** = competitivo con Cachimba, **Modo pleno** = competitivo por eliminación), Zona (las 5), Tamaño equipos (1-5 huecos por equipo,
los vacíos son siempre bots), Dificultad bots y Rondas (7: partida a 12 rondas con cambio de lado tras la 6; con 6-6 se juega a ganar por 2); debajo la tarjeta "tú" (nombre, por defecto "Jugador", y
personaje con flechas `<` `>`, guardados en `user://perfil.cfg`) y el botón **Listo** con el contador listos/humanos ("1/1"); con todos listos arranca la partida. En Modo libre los paneles de equipo se sustituyen
por un panel de modo libre con "Bots en el campus" (0-10). Los identificadores internos no cambian (`ConfigPartida.modo` libre/competitivo y `submodo` cachimba/eliminacion; `ConfigPartida.MODOS`,
`aplicar_modo()` y `nombre_modo()` traducen a los nombres visibles).
Modelo de datos (preparado para red): `LobbyUI.equipos[g]` y `ConfigPartida.huecos[g]` son listas de huecos `{tipo: humano|bot, nombre, personaje, listo, local}`; hoy solo el humano local, mañana los jugadores de la red
serán huecos `humano` no locales y la partida arrancará cuando todos los humanos estén listos. `ConfigPartida.huecos_efectivos()` completa los personajes de los bots al azar con la semilla de la partida.

**Personajes**: `game/data/personajes/catalogo_personajes.gd` (`CatalogoPersonajes`) lista los 12 personajes del pack Quaternius "Ultimate Modular Men" (Caballo, Ejecutivo, Granjero, Soldado, Mochilero, Astronauta, Estudiante, Rey, Obrero, Punk, Playero, Becario), cada uno como combinación de piezas (cabeza/cuerpo/piernas/pies) de `humans_master.fbx`, con su aspecto original. El cuerpo (bots en partida) y los retratos del lobby se
construyen con `game/scripts/personajes/modelo_personaje.gd` (`ModeloPersonaje.crear`): **punto único donde cambiar el modelo** (fallback al blockout de cajas si falta el fbx). Color de equipo = brazalete en cada brazo. El fbx trae esqueleto de 79 huesos y 24 animaciones: se usan Idle_Gun, Walk, Run, Idle_Gun_Shoot y Death (`actualizar`, `disparar`, `morir`) con un `AnimationPlayer`; el arma
se cuelga de un `BoneAttachment3D` en la muñeca derecha (`poner_arma`). Retratos: `retratos_personajes.gd`. Perfil local: `scripts/partida/perfil_jugador.gd`.

**Modelos externos** (créditos y licencias en `CREDITOS.md`, visibles en el lobby con el botón *Créditos*; copias de trabajo en `game/assets/externos/{armas,personajes,coches}`, el original sin tocar en `data/raw/modelos/`):
- *Armas*: `game/scripts/combate/modelos_armas.gd` (`ModelosArmas`) normaliza cada modelo (canon hacia -Z, origen en la empunadura, largo real, punto de boca para fogonazo/trazadora); la tabla `CONFIG` asigna un fbx distinto a cada arma; si falta el fichero se usa el modelo procedural. Se importan los FBX directamente (Godot 4.7 los lee con ufbx; no hace falta convertirlos). Posición en primera persona: `AJUSTE_EXT` en `viewmodel_capa.gd`; en mano de los bots: `ModeloPersonaje.AJUSTE_MANO`. El sable usa `light-saber.glb` con hoja emisiva y encendido animado por código (la animación del glb dura 27 s y no se usa); el arco usa `Bow_Evil` con la cuerda dibujada por código y `Arrow` como flecha. Sin modelo (siguen procedurales): tirachinas, lanzacohetes, puño-bot, navaja y utilidades. Iconos de la tienda: `tests/generar_iconos.gd` (sin `--headless`; luz reforzada, sin manos), luego `--import`.
- *Coches*: `game/scripts/coches_externos.gd` sustituye el blockout (cuya colisión se mantiene) por los 10 modelos del pack, con modelo y pintura deterministas por coche (`MultiMesh` por celda de 80 m y modelo, versión de cajas a más de 120 m). Aparcamiento, mismo equipo: blockout 262 fps vs pack 165 fps (vista a pie), 240 vs 143 (vista aérea).
- Capturas: `game/tests/captura_modelos.gd`, `captura_personajes.gd`, `captura_lobby.gd` y `captura_bots.gd` (salida en `export/capturas_modelos/`).

**Cachimba Wars y Modo pleno** (competitivos): cada ronda empieza con la **fase de compra** (25 s, barreras de spawn activas, bots quietos, tienda abierta sola; **B** la reabre), luego la **ronda** (1:40).
- Cachimba Wars: el atacante que la **lleva** (uno al azar por ronda, se indica en el HUD y en el minimapa) la monta manteniendo **E** quieto dentro de un site (4 s, +300 créditos); montada hay 40 s
  (el reloj de la ronda se detiene). Un defensor la apaga manteniendo **E** quieto a su lado 7 s. Si se agota el temporizador **no explota**: suena la alarma de incendios y el HUD avisa de que se
  desaloja la UPO (ganan los atacantes, +300 a cada atacante). Si muere el portador, la Cachimba cae al suelo y hay que **recogerla** acercándose (un bot atacante va a por ella).
  Ganan los defensores si apagan la Cachimba, eliminan a todos los atacantes sin que esté montada o se acaba el tiempo sin montarla; los atacantes si suena la alarma o eliminan a todos los defensores
  (con la Cachimba montada y los atacantes muertos la ronda sigue: hay que apagarla).
- Modo pleno (eliminación): gana quien elimina al otro equipo; si se acaba el tiempo, los defensores.
- Economía: 800 al empezar, máximo 9000, +200 por baja, +3000 por ganar la ronda, 1900 por perderla (+500 por cada derrota consecutiva, tope 2900), +300 montar y +300 a cada atacante con la alarma. Todo en
  `ConfigPartida`. Si mueres pierdes lo comprado (vuelves con pistola 9 mm y navaja; la principal queda en el suelo hasta que acabe la ronda); si sobrevives conservas armas, munición, utilidades y el escudo
  restante. En el competitivo `kit_reaparicion` está vacío. Al cambiar de lado la economía y los inventarios se reinician (800).
- **Esc** abre solo la pausa (Reanudar / Volver al lobby / Salir del juego); la tienda solo con B en la fase de compra.
- Tienda (B), estilo Valorant, a pantalla completa: columnas Pequeñas | Grandes (subfusiles y escopetas / fusiles, precisión y ametralladora) | Especiales | Escudos y utilidades; cada artículo es una tarjeta con icono,
  nombre y precio. Al pasar el ratón sale un panel con barras de daño cabeza / cuerpo / piernas, cadencia, cargador, recarga, movilidad y precio. **Clic izquierdo compra, clic derecho devuelve** lo comprado en esta
  fase (reembolso completo; comprar otra del mismo hueco devuelve la anterior sola). Lo no asequible se atenúa, lo equipado y lo comprado se marcan. Arriba: dinero y fase / tiempo; en Modo libre (Esc) además
  Reanudar / Volver al lobby / Salir. Iconos: `game/assets/iconos/<id>.png`, generados desde los modelos del viewmodel con
  `Godot_console.exe --path game --script res://tests/generar_iconos.gd` (con GPU; **volver a ejecutarlo cuando cambien los modelos de las armas**) y luego `--headless --path game --import`. Los escudos dibujan su icono (`scripts/ui/icono_escudo.gd`).
- HUD: marcador de rondas y equipos, temporizador, dinero, **Tab** tabla de puntuación (bajas / muertes / dinero propio), killfeed (HUD de combate), minimapa de la zona (límite, sites A/B, aliados, Cachimba),
  aviso de Cachimba montada / caída / alarma, resultado de la ronda y de la partida. Al morir espectas a un aliado vivo (**clic** cambia de aliado) hasta la siguiente ronda.

**Modo libre**: todo el campus, eliges el punto de aparición (M para cambiar), reapareces al morir, bots opcionales que deambulan, dinero infinito. **Esc** abre la tienda con Reanudar / Volver al lobby / Salir.

**Teclas de partida**: B tienda (fase de compra), Tab marcador, E mantenido montar / apagar la Cachimba (con un arma del suelo en el punto de mira, E la recoge), Esc pausa, F2 liberar el ratón.

**Equilibrio de los bots (P4)**: medido con `tests/sim_partida.gd` (5v5 normal, Cachimba, 3 semillas x 24 rondas por zona, sin cambio de lado): atacantes 54 % / defensores 46 % en total
(plaza América 53/47, biblioteca-24 50/50, detrás del 22 54/46, el Eje 58/42, el Puente 57/43; eliminación 38/62). Antes de ajustar ganaban casi siempre los defensores (30 % ataque) y casi no
se usaban granadas (0-0,4 por ronda). Ajustes en `scripts/bots/`: los atacantes usan más humo y cegadoras (humo de cobertura al ver enemigos a >= 18 m, humo y cegadora al entrar al site; máx. un humo por
equipo cada 14 s), los defensores no inician duelos a más de `DirectorBots.VISION_DEFENSOR_M` (70 m; ajustes por zona en `VISION_DEFENSOR_ZONA` / `VISION_ATACANTE_ZONA`) y el portador sigue montando
mientras dispara si ya está en el site. Granadas por ronda: atacantes 1,6-3,4; defensores ~0. **Límite conocido**: la Cachimba solo se monta en ~6 % de las rondas (22 % en plaza América, ~0 % en las zonas
abiertas): los atacantes suelen ganar eliminando a los defensores antes de llegar al site; empujar más (avanzar disparando a > 40 m) los hace morir en campo abierto y desequilibra (13 % de victorias).

**Pruebas**: `Godot_console.exe --headless --path game --script res://tests/test_partida.gd [-- rapido]` (con `rapido` se salta la partida completa acelerada);
`Godot_console.exe --headless --path game --script res://tests/sim_partida.gd -- zonas=el_eje rondas=12 escala=12` mide la tasa de victoria por bando. `tests/test_bots.gd` sigue usando `PartidaPrueba`.

## Mejoras tras probar el juego

- **Contorno de enemigos y sin nombres** (`scripts/combate/contorno_enemigos.gd`, `shaders/contorno_enemigo.gdshader`): los enemigos ya no llevan etiqueta de nombre (tampoco en las marcas de pintura: solo la distancia). Un nodo
  `ContornoEnemigos` (lo crea `main.gd`) revisa cada enemigo vivo cada 3 fotogramas (desfasados) con `Utilidades.linea_de_vision` desde la camara a cabeza y torso (pared, prop, tronco y humo tapan) y, si lo ve, pone como
  `material_overlay` de sus mallas un contorno magenta-rojo (inverted hull en espacio de vista, ancho creciente con la distancia, prueba de profundidad normal: nunca se pinta a traves de nada). Aliados: nombre pequeno solo
  a menos de 14 m o al apuntarles con vista despejada, y siempre (con vista despejada) al espectar. Equipo 0 (modo libre) = todos enemigos. Coste: ~3 comprobaciones (2 rayos) por fotograma con 10 personajes.
- **Manos** (`scripts/combate/manos_viewmodel.gd`): las manos-caja del viewmodel son ahora manos low-poly con dorso, 4 dedos de 2 falanges, pulgar, muneca, puno de manga y antebrazo (derecha en la empunadura, izquierda bajo el
  guardamano). Piel (o guantes) y manga salen del personaje elegido (`ManosViewmodel.COLORES_PERSONAJE`, colores de humans_master.fbx; `GestorArmas.poner_personaje`, lo llama `juego.gd`). No se reutiliza el esqueleto de
  Humans_Master en primera persona (habria que animar su pose con cada arma).
- **Zoom** (ver Controles): overlay de mira telescopica (vineta circular negra + reticula + aumentos "4x"/"8x") en el fusil tirador y el de precision.
- **Equilibrio de los bots tras las coberturas**: ver `docs/PROYECTO.md` (antes / despues con `tests/sim_partida.gd`).
- Capturas: `tests/captura_mejoras.gd` (sin `--headless`; `-- <carpeta> [zonas|arbol|zoom|contorno|manos]`) escribe en `export/capturas_mejoras/`.

Diseño y plan del proyecto: [docs/PROYECTO.md](docs/PROYECTO.md).

## Red: multijugador con servidor autoritativo (N1)

Varias instancias (mismo PC o LAN) juegan juntas Cachimba Wars, Modo pleno o Modo libre, con bots rellenando huecos. El servidor ejecuta
`Partida`, bots, proyectiles, dano (`Balistica`), economia y rondas; los clientes solo mandan ENTRADAS y comandos. El modo un jugador no cambia.

```
game/scripts/red/
  red.gd             Red: ENet (UDP, 7777 por defecto) + todos los RPC (c_* cliente->servidor, s_* servidor->cliente) + simulacion de lag/perdida
  servidor_red.gd    ServidorRed: lobby, montaje de la partida, avatares de los humanos, entradas, disparo con compensacion de latencia, snapshots
  cliente_red.gd     ClienteRed: lobby, prediccion + reconciliacion del movimiento, interpolacion de los demas, eventos del servidor
  movimiento_jugador.gd  paso de movimiento COMPARTIDO por servidor y cliente (mismas constantes que Jugador)
  protocolo_red.gd / entrada_red.gd   formato binario compacto de snapshots (12 bytes por participante) y entradas (16 bytes)
  proxy_red.gd       modelo de otro participante en el cliente;  partida_cliente.gd  espejo de la Partida para HUD y tienda
  arranque_red.gd    argumentos de linea de comandos y servidor dedicado;  cliente_sim.gd  cliente automatico para pruebas de carga
game/scripts/ui/chat_red.gd    chat (T)
```

### Hospedar y unirse (con ventana)

- **Crear partida local**: en el lobby, boton "Crear partida local". Este proceso hace de servidor y el jugador local es un participante sin
  latencia. Muestra las IP de la LAN. Abre el puerto **UDP 7777** (en Windows, permitir Godot en el cortafuegos).
- **Unirse**: escribir `IP:puerto` (por defecto `127.0.0.1:7777`) y "Unirse". Los humanos ocupan huecos de equipo (se cambia de equipo o hueco
  pinchando una tarjeta BOT), eligen nombre y personaje y pulsan LISTO (contador X/Y). La partida arranca cuando todos estan listos o cuando
  el anfitrion (el primero en entrar) pulsa "Forzar inicio". Solo el anfitrion cambia modo, zona, tamano, dificultad y rondas.
- Se entra solo desde el lobby: no hay union a partida en curso. Si un humano se desconecta en partida, su hueco pasa a un bot.
- `T` abre el chat; el killfeed, el marcador (Tab) y la tienda funcionan igual que en local (la tienda solo en la fase de compra).

### Servidor dedicado (headless)

```
Godot --headless --path game -- --servidor [puerto=7777] [max=10] [modo=cachimba_wars|pleno|libre] [zona=el_eje] [tam=5] [rondas=7] [t_compra=25] [dificultad=normal] [--lag=80 --perdida=2]
```

No carga UI, viewmodels ni audio (solo el mapa con su colision). Imprime `SERVIDOR LISTO udp/7777 ...`. Puerto: **UDP** (el mismo en el cliente).
Cliente automatico de pruebas: `-- --cliente-sim=127.0.0.1:7777 nombre=Sim1`.

**Docker / Oracle Cloud (linux/arm64)**: `cd servidor && docker compose up -d --build`; guia completa paso a paso (VM, firewall, actualizacion, mediciones) en [servidor/README.md](servidor/README.md).

### Como funciona (resumen)

- **Tick**: fisica a 60 Hz; snapshots a 20 Hz (`TICK_SNAPSHOT = 3`); entradas del cliente a 60 Hz (cada paquete lleva las 4 ultimas).
- **Movimiento**: el cliente predice con `MovimientoJugador` y guarda las entradas no reconocidas; cada snapshot trae `ack` y la posicion/velocidad
  exactas, el cliente las aplica y re-simula lo pendiente. Error < 2 m: desplazamiento visual que se desvanece; mayor, o teletransporte
  (reaparicion), correccion inmediata. El cliente nunca envia su posicion; el servidor limita las entradas procesadas al tiempo real (no hay
  speed-hack ni teletransporte posibles).
- **Otros jugadores y bots**: interpolacion a 100 ms.
- **Disparo**: el cliente muestra efectos al instante y manda la entrada con la hora de servidor que VE; el servidor rebobina los hitboxes de los
  demas a esa hora (limite 300 ms = 100 de interpolacion + 200 de latencia), resuelve con `Balistica` y devuelve hitmarker, dano y killfeed.
  Cadencia, municion, recarga y dispersion las impone el servidor (`ArmasBot`).
- **Anti-trampas basico**: el servidor valida precios/dinero/fase de compra (`Partida`), distancia de recogida, cadencia, municion y velocidad;
  comandos desconocidos o mal formados se rechazan y se cuentan (`stats.rechazos`). Al cliente solo se le manda SU dinero e inventario (el
  marcador oculta el dinero rival). No hay (todavia) ocultacion de posiciones tras paredes ni deteccion de aimbot/sin retroceso.
- **Chat**: 120 caracteres, 1 mensaje cada 0,5 s.

### Pruebas y mediciones

```
Godot --headless --path game --script res://tests/test_red.gd          # ~3,5 min; servidor + 2 clientes en un proceso con ENet real
powershell -File scripts/probar_red.ps1 [-Segundos 40 -Lag 80 -Perdida 2 -Clientes 2 -Tam 5]   # servidor + clientes automaticos en procesos distintos
```

`test_red.gd`: conexion y rechazo de version, lobby (unirse, hueco, nombre, personaje, listo, config del anfitrion), arranque, sincronizacion
de posiciones, disparo que mata, compensacion de latencia (con 100 ms de RTT: 8/8 impactos con rebobinado, 2/8 sin el), compra y venta,
comandos invalidos (sin dinero, sin municion, teletransporte, cadencia, inundacion de entradas), chat, desconexion a bot, vuelta al lobby y
ancho de banda con 10 participantes. Mediciones de referencia (PC de desarrollo, loopback):

| Medida | Valor |
|---|---|
| Snapshot con 10 participantes | 197 bytes, 20/s -> ~3,9 KB/s de bajada por cliente (~4,6 KB/s en el cable) |
| Entradas del cliente | 60 paquetes/s, ~3,5 KB/s (~5,7 KB/s en el cable) |
| Servidor dedicado, 2 humanos simulados + 8 bots | ~12 % de un nucleo (con los 2 clientes y el sistema en el mismo PC), 350 MB de memoria |
| Prediccion vs servidor corriendo | diferencia maxima 0,08 m |

Referencia Ampere A1 (2 OCPU): un nucleo ARM es varias veces mas lento que el del PC de desarrollo; aun asi 12 % de un nucleo x3-4 deja margen para
2-3 partidas por servidor (a medir en el despliegue, N2).

### Limitaciones y pendiente

- Humanos remotos: no soportan Sable de Plasma, Puno-Bot ni el golpe fuerte de la navaja (el servidor usa `ArmasBot`; la tienda los rechaza para ellos).
  El arco dispara al completar la carga. En el modo libre en red el humano remoto aparece junto al primer spawn (sin selector M).
- Sin union a partida en curso ni reconexion; sin interest management (todos ven todas las posiciones); marcas de pintura y altavoz senuelo no se
  replican al cliente; el cliente no valida su propio modelo de colision con otros jugadores.
- N2 hecho: servidor dedicado en Docker linux/arm64 (Oracle Cloud): ver [servidor/README.md](servidor/README.md).
