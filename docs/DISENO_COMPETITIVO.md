# UPOWARS: diseño del modo competitivo y modo libre

Documento de referencia para los agentes que implementan el rediseño. Fecha: 2026-11-27.

Convenciones del documento:

- **Fijo**: viene de la especificación del líder; no se cambia sin consultarlo.
- **Propuesta (ajustable)**: valor razonable pero revisable. Debe vivir en datos (`.tres`, CSV o JSON), nunca hardcodeado.
- No se añaden mecánicas fuera de lo indicado aquí. Si algo no está, se pregunta al líder.

---

## 1. Visión

UPOWARS es un FPS táctico **original** ambientado en el campus de la UPO. No se usan nombres, assets ni HUD de juegos existentes: las armas, la tienda, el HUD y los menús tienen identidad propia.

| Modo | Descripción |
|---|---|
| **Libre** | Todo el campus abierto. Entrar y salir en cualquier momento, reaparición, todos contra todos o por equipos, bots opcionales. |
| **Competitivo** (principal) | Una **zona** del campus cerrada con muros translúcidos. Por rondas, hasta 5 contra 5. Dos submodos: Cachimba y Eliminación. |

### 1.1 Modo libre

- Mapa: todo el campus. Reaparición tras morir.
- Todos contra todos o por equipos. Bots opcionales (NavigationMesh del campus completo).
- **Esc** abre la tienda junto con "Reanudar / Salir de la partida".
- Dinero: **infinito** (decisión del líder). La tienda se abre con Esc y no descuenta créditos. Además, el armero de pruebas (F6) permite equiparse cualquier arma sin tienda.

### 1.2 Modo competitivo

- Se elige una zona (sección 8). La zona se cierra con muros translúcidos: se ven a través pero tienen colisión.
- **Esc** abre solo un menú de pausa: Reanudar / Opciones / Salir de la partida. La tienda NO se abre con Esc; solo durante la fase de compra (tecla B).
- Submodos:

| Submodo | Condición de victoria de ronda |
|---|---|
| **Cachimba** (principal) | Los atacantes **montan** "la Cachimba" en una de las 2 zonas de montaje (A/B); los defensores la **apagan** o eliminan a todos los atacantes. Si se agota el tiempo con la Cachimba encendida, **no explota**: suena la alarma de incendios y se desaloja la UPO (ronda para los atacantes). Ver sección 3. |
| **Eliminación** | Gana la ronda el equipo que elimina al otro. Si se acaba el tiempo, gana el que tenga más jugadores vivos; en empate, ganan los defensores. |

---

## 2. Lobby

Pantalla previa al inicio de partida.

| Opción | Valores | Por defecto |
|---|---|---|
| Modo | Libre / Competitivo | Competitivo |
| Submodo (solo competitivo) | Cachimba / Eliminación | Cachimba |
| Zona (solo competitivo) | Las 5 zonas de la sección 8 | Primera de la lista |
| Nombre equipo atacante | Texto editable | "EPS" |
| Nombre equipo defensor | Texto editable | "CEUPO" |
| Jugadores por equipo | 1 a 5 | 5 |
| Rellenar con bots | Sí / No | Sí |
| Dificultad de bots | Fácil / Normal / Difícil | Normal |
| Rondas para ganar | Número | 7 (de 12) |

Notas:

- El jugador **elige su equipo** (atacantes o defensores).
- Con 7 rondas para ganar de 12, hay **cambio de bando tras la ronda 6**.
- Los valores por defecto de la tabla que no están en la especificación (modo, submodo, zona, jugadores por equipo, rellenar con bots, dificultad) son **propuesta (ajustable)**.

---

## 3. Rondas (submodo Cachimba)

Todos los tiempos son **propuesta (ajustable)** y deben estar en un recurso de configuración.

| Fase / evento | Duración | Notas |
|---|---|---|
| Fase de compra | 25 s | Tienda abierta automáticamente; la tecla **B** la reabre durante la fase. Los jugadores están bloqueados en su spawn tras una barrera. |
| Ronda | 1:40 | Cuenta atrás de ronda. |
| Montar | 4 s | El atacante debe estar quieto dentro de una zona de montaje y "monta" la Cachimba. |
| Temporizador de la Cachimba | 40 s | Cuenta atrás desde que se monta. Al llegar a 0 no hay explosión: suena la alarma de incendios (sirena sintética) y se desaloja la UPO. |
| Apagar | 7 s | El defensor debe estar quieto junto a la Cachimba para "apagarla" (desactivarla). |
| Fin de ronda | 5 s | Pantalla de resultado antes de la siguiente fase de compra. |
| Prórroga | n/a | Con empate 6-6, se juega a ganar por 2 (propuesta). |

Reglas:

- Los jugadores muertos pasan a **espectar** a sus compañeros vivos.
- Cambio de bando tras la ronda 6 (con la configuración por defecto de 12 rondas).
- Condiciones de fin de ronda (Cachimba): se agota el tiempo de la Cachimba montada y suena la alarma de incendios con desalojo de la UPO (atacantes ganan); se apaga (defensores ganan); eliminan a todos los atacantes sin Cachimba montada (defensores ganan); eliminan a todos los defensores (atacantes ganan); se acaba el tiempo sin montarla (defensores ganan). Estas combinaciones derivan de las reglas de la sección 1; el tratamiento exacto de casos límite (por ejemplo, atacantes eliminados con la Cachimba ya montada) es **propuesta (ajustable)**: la Cachimba sigue encendida y los defensores deben apagarla, o ganan los atacantes si suena la alarma.
- Submodo Eliminación: misma estructura de fase de compra y fin de ronda; la ronda dura lo mismo (1:40, propuesta) y no hay Cachimba.

---

## 4. Economía

Moneda: **créditos**. Valores propios, inspirados en el estándar del género pero ajustables (recurso de datos).

| Concepto | Valor |
|---|---|
| Créditos iniciales | 800 |
| Máximo | 9000 |
| Por eliminación | +200 |
| Victoria de ronda | +3000 |
| Derrota de ronda | +1900 |
| Bonus por derrota consecutiva | +500 por cada derrota consecutiva, con un máximo de 2900 de recompensa total por derrota |
| Montar la Cachimba | +300 al jugador que la monta |
| Suena la alarma de la Cachimba (desalojo) | +300 al equipo atacante |
| Pistola 9 mm | Gratis, siempre se tiene |
| Navaja | Gratis, siempre se tiene |

Cálculo de la recompensa por derrota: `min(1900 + 500 * (derrotas_consecutivas - 1), 2900)`, es decir 1900, 2400, 2900, 2900... Se interpreta "derrotas consecutivas" como contadas incluyendo la actual (la primera derrota da 1900). Interpretación **propuesta (ajustable)**. El contador se reinicia al ganar una ronda.

### 4.1 Reglas de inventario

| Regla | Detalle |
|---|---|
| Composición máxima | 1 arma principal ("grande") + 1 secundaria ("pequeña") + cuerpo a cuerpo + utilidades |
| Muerte | Se pierde todo lo comprado: vuelves a Pistola 9 mm y escudo 0. La principal y la secundaria compradas **se sueltan y se pueden recoger** (la Pistola 9 mm gratuita no) |
| Sobrevivir la ronda | Se conservan armas, munición, utilidades no usadas y el escudo restante |
| Comprar arma de la misma ranura | Sustituye a la anterior; la anterior se tira al suelo y cualquiera puede recogerla con **E** (conserva su munición). **G** tira el arma en mano |
| Pedir o regalar un arma a un compañero | Propuesta, fase 2 (no entra en el primer alcance) |
| Utilidades | Máximo 2 de cada tipo, 4 en total (propuesta, ajustable) |

El cuerpo a cuerpo por defecto es la navaja (siempre; clic derecho = golpe fuerte). Las armas **especiales** (arco, tirachinas, lanzacohetes, Sable de Plasma) cuentan como arma principal; el Puño-Bot cuenta como secundaria. Armas en el suelo: al acabar la ronda desaparecen (`limpiar_armas_suelo()`).

Huecos y teclas: 1 principal, 2 secundaria, 3 cuerpo a cuerpo, 4 utilidades (4 o rueda para ciclar entre ellas), Q última arma, E recoger, G tirar.

---

## 5. Escudo

| Escudo | Puntos | Precio |
|---|---|---|
| Ligero | 25 | 400 |
| Pesado | 50 | 1000 |

El escudo (antes "armadura") va de 0 a 50. Absorbe parte del daño según la **penetración** del arma (campo `penetracion_armadura` de su `.tres`): a la vida llega `daño x penetración`; el resto lo absorbe el escudo a razón de 2 puntos de daño por punto de escudo, y si se agota el sobrante pasa a la vida. Los explosivos usan su propia penetración (0,6). Implementado en `Salud` (`escudo`, `escudo_max` = 50).

---

## 6. Arsenal

Todos los nombres son **realistas pero genéricos** (tipo y calibre o descripción; nunca marcas ni modelos comerciales). Los valores de daño, cadencia, cargador, recarga, etc. son **propuesta (ajustable)** y viven en recursos `.tres` (`game/data/armas/`); el catálogo con precios y categorías está en `game/data/catalogo.gd`. Las armas fuertes llevan contrapartidas: poca munición, recarga lenta, sobrecalentamiento o lentitud.

### 6.1 Secundarias (pequeñas)

| Arma | Precio | Descripción y contrapartidas |
|---|---|---|
| Pistola 9 mm | Gratis (la antigua P-9) | Arma inicial, siempre disponible |
| Pistola automática 9 mm | 500 | Ráfagas de 3 balas, imprecisa |
| Pistola pesada .50 | 800 | Mucho daño, lenta, 7 balas |
| Revólver .357 | 700 | 6 balas, cadencia lenta, recarga larga |
| Escopeta recortada | 600 | 2 cartuchos, mucho daño muy cerca, cae enseguida |
| Subfusil compacto | 900 | Cadencia alta, poco daño, imprecisa a distancia |

### 6.2 Principales (grandes)

| Arma | Precio | Descripción y contrapartidas |
|---|---|---|
| Subfusil 9 mm | 1500 | Cadencia alta, daño bajo |
| Subfusil pesado .45 | 1900 | Más daño y menos cadencia que el 9 mm |
| Escopeta de corredera | 1800 | Perdigones, letal a corta distancia, cadencia lenta |
| Escopeta automática | 2600 | Menos daño por perdigón, más cadencia, cara |
| Carabina 5,56 | 2500 | Algo menos de daño que el fusil de asalto; más precisa en movimiento |
| Fusil de asalto 5,56 | 2900 | Fusil base (la antigua R-7) |
| Fusil de combate 7,62 | 3200 | Más daño y menos cadencia; un tiro a la cabeza mata incluso con escudo |
| Fusil tirador semiautomático | 3500 | Semiautomático, zoom medio, cadencia limitada |
| Fusil de precisión de cerrojo | 4700 | Zoom fuerte, letal al torso, muy lento e impreciso sin apuntar |
| Ametralladora ligera | 3300 | Cargador grande, muy lenta de recargar y de mover |

### 6.3 Especiales (categoría aparte en la tienda)

Cuentan como PRINCIPAL, salvo el Puño-Bot que cuenta como SECUNDARIA.

| Arma | Precio | Descripción y contrapartidas |
|---|---|---|
| Arco "Olivo" | 2200 | Carga con clic mantenido; flecha con caída; silencioso; cabeza letal; recuperación lenta |
| Tirachinas "Gomero" | 400 | Proyectil con caída, silencioso y barato; poco daño |
| Lanzacohetes "Traca" | 4000 | 2 cohetes en total; daño en área con autodaño reducido y empuje; recarga muy lenta |
| "Sable de Plasma" | 3000 | Golpe en arco. Clic derecho = bloqueo de disparos y proyectiles en un cono frontal de ~70 grados; cada bloqueo sube el calor y al 100 se sobrecalienta 4 s; no bloquea explosiones; más lento al bloquear |
| "Puño-Bot" (secundaria) | 600 | Carga y dispara el puño con daño y empuje; vuelve a la mano a los ~1,5 s; sin munición |

### 6.4 Cuerpo a cuerpo y controles de combate

- Navaja: siempre; clic izquierdo ligero, clic derecho golpe fuerte.
- Clic derecho apunta con todas las armas de fuego (FOV menor, dispersión reducida, movimiento más lento, viewmodel centrado; el fusil de precisión tiene mira con zoom fuerte). Con el sable bloquea, con la navaja golpea fuerte; arco y Puño-Bot se cargan con el izquierdo mantenido.
- Shift = correr (~6,5 m/s; no se puede disparar corriendo y hay una breve demora al dejar de correr); Alt = caminar sigiloso; Ctrl = agacharse; E = recoger o interactuar; G = tirar el arma en mano.

### 6.5 Utilidades (máx. 2 de cada tipo, 4 en total)

Se lanzan con clic izquierdo (lanzamiento fuerte) o derecho (flojo), con rebotes simples.

| Utilidad | Tipo | Precio | Efecto |
|---|---|---|---|
| Granada de humo | Granada | 300 | Humo de ~5 m de radio durante 15 s; bloquea la línea de visión |
| Granada cegadora | Granada | 250 | Mecha de 1,5 s; ceguera según el ángulo y la distancia; los bots ciegos pierden puntería |
| Granada explosiva | Granada | 400 | Mecha de 2 s; daño en área con caída, autodaño y empuje; las paredes bloquean la explosión |
| "Bote de pintura" | Gadget del campus | 300 | Al romperse marca durante 5 s a los enemigos en 4 m, visibles para tu equipo a través de paredes |
| "Extintor" | Gadget del campus | 350 | Nube de 3 s que tapa la visión y empuja a quien está dentro |
| "Altavoz señuelo" | Gadget del campus | 200 | Durante 6 s emite pasos y disparos falsos; los bots lo oyen como ruido |

Los radios y daños de las utilidades (salvo los 5 s y 4 m del bote de pintura, los 6 s del altavoz y los 3 s del extintor) son **propuesta (ajustable)**.

### 6.6 Escudo

Ligero (25 puntos) por 400 y pesado (50 puntos) por 1000 (ver sección 5).

---

## 7. Tienda

- Menú **propio** (no copiar la estética de otros juegos), organizado por categorías: **Secundarias / Principales / Especiales / Escudo / Utilidades**.
- Cada artículo muestra: precio, daño, cadencia y movilidad. Lo equipado se marca visualmente.
- Se puede **vender** lo comprado en la fase de compra actual con **reembolso completo**.
- Se cierra automáticamente al acabar la fase de compra.
- Competitivo: se abre sola al empezar la fase de compra; B la reabre durante la fase. Libre: se abre con Esc y el dinero es infinito.

---

## 8. Zonas competitivas

Cada zona mide ~120-200 m de lado, está cerrada con muro translúcido y contiene: 2 zonas de montaje (A/B), spawn de atacantes, spawn de defensores y varias rutas. El diseño de cada zona se **valida con previews** (imágenes renderizadas) antes de darlo por bueno.

| # | Zona | Contenido de referencia |
|---|---|---|
| 1 | Plaza América | Rectorado 31/32, torre 35 y la plaza al norte del 32 |
| 2 | Biblioteca-24 | Entre la Biblioteca 25 y el Edificio 24; patio hundido al sur del 24, pasarela 555538618, marquesinas y la plaza |
| 3 | Detrás del 22 | Bosque y estanque al oeste o suroeste del 22, franja 22-24 y patio del 23. Aquí va el aula al aire libre |
| 4 | El Eje | Entre los edificios del pasillo central (5-6-7-8-9) y el propio pasillo |
| 5 | El Puente (propuesta del líder) | Final del pasillo central junto al 18, escalera de bajada, pasillo del 18 en rampa y cruce del cauce |

Muro translúcido: se ve que hay un muro pero se ve a través; tiene colisión.

---

## 9. Coberturas nuevas

Se colocan sobre todo dentro de las zonas, con colisión y apoyadas en el terreno.

| Cobertura | Medidas / notas |
|---|---|
| Árboles más grandes | Troncos de 0,5-0,7 m de radio |
| Muretes bajos | 0,9-1,1 m de alto |
| Bancos | |
| Jardineras | |
| Contenedores de basura y de reciclaje | |
| Aparcabicis | |
| Marquesina de autobús | En las paradas |
| Máquinas expendedoras | Junto a edificios |
| Pilas de sillas o mesas | |
| Aula al aire libre | En el bosque junto al 24: filas de bancos o asientos mirando a una pizarra |

Todo es configurable en datos (CSV o JSON) con posiciones editables, para ajustar sin tocar código ni regenerar a mano.

---

## 10. Bots

| Aspecto | Requisito |
|---|---|
| Navegación | NavigationMesh horneada en runtime por zona (competitivo) o para todo el campus (libre) |
| Compra | Según la economía del equipo |
| Roles | Atacante y defensor: ir al site, montar, defender, rotar, apagar |
| Combate | Tiempo de reacción y error de puntería según la dificultad (fácil/normal/difícil) |
| Granadas | Uso básico |
| Relleno | Se pueden rellenar hasta 5 por equipo, o no (opción del lobby) |

---

## 11. HUD y extras

| Elemento | Descripción |
|---|---|
| Marcador (Tab) | Eliminaciones, muertes y dinero |
| Killfeed | Registro de eliminaciones |
| Minimapa | De la zona, con compañeros y sites |
| Temporizador y marcador de rondas | Arriba |
| Espectador | Tras morir, ver a compañeros vivos |
| Indicador de dirección del daño | Al recibir daño |
| Sonidos de pasos | Información táctica |

El HUD debe tener estética propia, sin copiar la de otros juegos.

---

## 12. Arquitectura

- El **estado de partida autoritativo** vive en un nodo `Partida`: lógica de rondas, economía e inventarios. Está **separado de la entrada y del render**.
- Las acciones del jugador y de los bots pasan por la **misma API de comandos** (por ejemplo, comprar, vender, montar, apagar, disparar, usar utilidad). La API valida y aplica sobre el estado de `Partida`.
- Motivo: poder añadir después la red (servidor headless autoritativo Godot en Docker sobre Oracle ARM64) sin rehacer la lógica.
- La red se hace **después**, cuando todo funcione en local con bots.

Esquema de capas:

| Capa | Responsabilidad |
|---|---|
| Entrada / IA | Genera comandos (jugador por input, bots por IA) |
| API de comandos | Punto único de entrada de acciones; valida |
| `Partida` (autoritativa) | Estado de rondas, economía, inventarios, resultados |
| Render / HUD / audio | Lee el estado y lo muestra; no lo modifica directamente |

---

## 13. Orden de implementación

| Paquete | Contenido |
|---|---|
| P1 | Zonas, muros translúcidos y coberturas (generador Python + datos) |
| P2 | Arsenal ampliado, proyectiles, granadas, gadgets y escudo |
| P3 | Bots |
| P4 | Partida: modos, rondas, economía, tienda, lobby, menús Esc, HUD de partida |
| P5 | Integración y pruebas |
| Después | Red y despliegue |

---

## 14. Preguntas abiertas (resueltas)

| # | Pregunta | Decisión |
|---|---|---|
| 1 | Nombre del artefacto y sus tiempos | **Resuelta**: el artefacto es "la Cachimba". Se **monta** (se planta) y se **apaga** (se desactiva). Tiempos: montar 4 s, temporizador 40 s, apagar 7 s. Al agotarse el tiempo no explota: suena la alarma de incendios (sirena) y se desaloja la UPO, ronda para los atacantes |
| 2 | Las armas tiradas al morir, ¿se pueden recoger? | **Resuelta**: sí. Al morir se sueltan la principal y la secundaria compradas (la Pistola 9 mm gratuita no), y también la sustituida al comprar del mismo hueco. Se recogen con E conservando la munición; G tira el arma en mano; desaparecen al final de ronda |
| 3 | ¿El modo libre tiene dinero infinito? | **Resuelta**: sí, dinero infinito |
