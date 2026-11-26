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

## Jugar (Godot 4.7.2)

Abrir el proyecto `game/` con `D:\Juegos\godot\Godot_v4.7.2-stable_win64.exe` (importador de proyectos, o
`Godot_v4.7.2-stable_win64.exe --path game`) y pulsar F5. Al arrancar aparece el selector de punto de aparición.

Controles: WASD mover, ratón mirar, Espacio saltar, Shift caminar lento, Ctrl agacharse, Esc liberar/capturar
el ratón, M reabrir el selector de spawn, F1 modo vuelo/noclip (20 m/s, x3 con Shift; Espacio/Ctrl suben/bajan).
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

Diseño y plan del proyecto: [docs/PROYECTO.md](docs/PROYECTO.md).
