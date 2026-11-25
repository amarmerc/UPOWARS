# UPOWARS — mapa 3D de la UPO para un FPS tipo Counter-Strike

Proyecto personal. Mapa 3D de la Universidad Pablo de Olavide (Sevilla) para un FPS al estilo Counter-Strike.

## 1. Objetivo

- Crear un mapa 3D de la Universidad Pablo de Olavide (Sevilla).
- Fase inicial: solo **EXTERIORES** en blockout (volúmenes simples). Sin interiores.

## 2. Alcance

- Todo el campus a escala real: ~1,5 km de largo, frente a los 100-150 m de un mapa típico de CS.
- 4-6 puntos de aparición elegibles mediante un selector (entrada principal, biblioteca, pabellón, aparcamientos).
- Más adelante: zona reducida para 5v5 competitivo (p. ej. eje central de los edificios 5-6-7-8-9) con dos zonas de bomba, spawns de equipos y pasillos.
- Resto del campus: mapa libre / práctica con bots.
- El balance (escala, líneas de visión, rotaciones) se ajusta jugando.

## 3. Datos y método (Fase 1)

La geometría se genera con código (Python + trimesh, o Blender headless) a partir de datos abiertos:

1. **OpenStreetMap** vía Overpass API (overpass-api.de): huellas de edificios, caminos, vallas, zonas verdes, arbolado.
2. **Alturas**: `building:levels` o `height` de OSM; si faltan, 3,5 m por planta. Los valores se guardan en un fichero editable para poder corregirlos.
3. **Relieve**: plano (el campus es casi llano). Opcional: MDT del IGN/CNIG (5 m o LiDAR).
4. **Referencias del usuario** (fotos/planos) para pasarelas, escaleras, muros y soportales.
5. **Exportación** a glTF (preferido), colisiones básicas, materiales planos o textura aérea en el suelo.

Requisitos de red: acceso a overpass-api.de y al centro de descargas del CNIG.

## 4. Motor

- **Godot 4**: gratuito, ligero, importa glTF, colisiones fáciles, plantillas FPS en GDScript.
- Descartados por ahora:
  - Unity (pesado).
  - CS2 Workshop / Hammer (no es juego propio).

## 5. Servidor multijugador 5v5

- Servidor Godot **autoritativo y headless**.
- Requisitos para 10 jugadores: 1-2 vCPU, 1-4 GB RAM, 10-20 GB de disco, 2-10 Mbps.
- Infraestructura: **Oracle Cloud Free Tier**, Ampere A1 (ARM64), 2 OCPU / 12 GB RAM → 1-2 partidas simultáneas.

Puntos a cuidar:

- Export `linux/arm64`.
- Abrir el puerto UDP en la Security List de Oracle y en iptables de Ubuntu.
- Región con baja latencia desde España (no se puede cambiar).
- Compilar en el PC y subir solo el binario.
- Vigilar que Oracle no reclame instancias inactivas.

## 6. Docker (después de tener el servidor funcionando)

- Imagen `linux/arm64` con `docker buildx --platform linux/arm64`, publicada en un registro o como `.tar`.
- Un contenedor por partida, cada uno en su propio puerto UDP, con límites de CPU/RAM.
- Red: `-p PUERTO:PUERTO/udp` o `network_mode: host`.
- `docker-compose.yml` con `restart: unless-stopped`.

## 7. Plan por fases

1. **Blockout del mapa**: edificios extruidos, suelo, caminos, colisiones, glTF.
2. **Proyecto Godot**: jugador FPS, mapa importado, spawns.
3. **Mejoras**: texturas, vegetación, vallas, bordes.
4. **Modo CS opcional**: bombas, rondas, bots, servidor autoritativo.
5. **Despliegue**: Docker en Oracle.

## 8. Organización del trabajo con IA

| Rol | Modelo | Función |
|---|---|---|
| Agente principal (líder y cerebro) | Opus | Dirige el proyecto |
| Agente "lector" | Haiku | Lee ficheros |
| Agente "escritor" | Sonnet | Escribe código y ficheros |

Si el escritor se atasca, el líder avisa al usuario y lo hace él con permiso.

## 9. Registro de decisiones

- **2026-11-26**: Arranque del proyecto en local (D:\Juegos\UPOWARS); definidos agentes lector/escritor.
- **2026-11-26**: Alturas de edificios desde LiDAR IGN (MDSn edificación, WCS wcs-mds.idee.es/mds, coverage mdsn_e025) vía scripts/alturas_lidar.py; correcciones manuales: torre (Edificio 35) 63 m, biblioteca (25) igual que 23/24.
