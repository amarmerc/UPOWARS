# syntax=docker/dockerfile:1
#
# Servidor dedicado de UPOWARS (Godot 4.7.2 headless) para linux/arm64 (tambien vale amd64: cambia GODOT_ARCH).
# Construir DESDE LA RAIZ del repo (el contexto es la raiz, el Dockerfile esta en servidor/):
#   docker build -f servidor/Dockerfile -t upowars-servidor .
# o simplemente:  cd servidor && docker compose up -d --build
#
# No hace falta plantilla de exportacion: se descarga el binario oficial del EDITOR de Godot (que tambien corre sin ventana) y se
# ejecuta el proyecto desde el codigo (--headless --path /juego). Alternativa con .pck exportado: ver servidor/README.md.

ARG DEBIAN_TAG=bookworm-slim

# ---------------------------------------------------------------------------------------------------------------------------
# Etapa 1: descargar y verificar el binario de Godot (aqui van curl/unzip; no acaban en la imagen final)
# ---------------------------------------------------------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG} AS descarga

ARG GODOT_VERSION=4.7.2-stable
ARG GODOT_ARCH=arm64
ARG GODOT_BASE_URL=https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}
ARG GODOT_ZIP=Godot_v${GODOT_VERSION}_linux.${GODOT_ARCH}.zip
ARG GODOT_SUMS=SHA512-SUMS.txt

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /descarga
RUN set -eux; \
    curl -fsSL --retry 5 --retry-delay 3 -o "${GODOT_ZIP}" "${GODOT_BASE_URL}/${GODOT_ZIP}"; \
    curl -fsSL --retry 5 --retry-delay 3 -o "${GODOT_SUMS}" "${GODOT_BASE_URL}/${GODOT_SUMS}"; \
    # El fichero de sumas tiene una linea "<sha512>  <nombre>" por cada asset: comprobar solo la nuestra (falla si no aparece).
    grep -F " ${GODOT_ZIP}" "${GODOT_SUMS}" > sumas_godot.txt; \
    test -s sumas_godot.txt; \
    sha512sum -c sumas_godot.txt; \
    unzip -q "${GODOT_ZIP}"; \
    mv "Godot_v${GODOT_VERSION}_linux.${GODOT_ARCH}" /godot; \
    chmod 0755 /godot

# ---------------------------------------------------------------------------------------------------------------------------
# Etapa 2: imagen final minima (solo las librerias de ejecucion de Godot + tini)
# ---------------------------------------------------------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG} AS final

# libstdc++6 y libfontconfig1: unicas dependencias reales del binario en modo headless (X11/Wayland/audio se cargan por dlopen y no
# se usan). tini: PID 1 que reenvia SIGTERM (un proceso que es PID 1 ignora las senales sin manejador) y recoge zombis.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libstdc++6 libfontconfig1 tini \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 upowars \
 && useradd --system --uid 10001 --gid upowars --create-home --home-dir /home/upowars --shell /usr/sbin/nologin upowars

COPY --from=descarga /godot /opt/godot/godot

# Proyecto: solo lo que el servidor necesita (ver .dockerignore en la raiz del repo).
COPY --chown=upowars:upowars game/ /juego/
COPY --chown=root:root --chmod=0755 servidor/entrypoint.sh servidor/healthcheck.sh /usr/local/bin/

# Importar los recursos en el build (genera /juego/.godot: mapa .glb, armas .tres, cache de clases...). Con --quit-after el editor
# termina solo; si el import fallase de verdad no existiria la cache de clases y el build se detiene.
USER upowars
WORKDIR /juego
RUN set -eux; \
    /opt/godot/godot --headless --audio-driver Dummy --path /juego --import || true; \
    test -f /juego/.godot/global_script_class_cache.cfg; \
    test -d /juego/.godot/imported

ENV HOME=/home/upowars \
    GODOT_BIN=/opt/godot/godot \
    PROYECTO=/juego \
    PUERTO=7777 \
    MAX=10

# Juego en red: UDP (ENet). Cambiar con PUERTO=... (y publicar el mismo puerto).
EXPOSE 7777/udp
# Modo WebSocket (variable WS_PUERTO, p. ej. 7780): TCP, solo detras de un proxy (nginx del host).
EXPOSE 7780/tcp

# El puerto esta abierto si aparece en /proc/net/udp(6) (ENet) o en LISTEN en /proc/net/tcp(6) (WS_PUERTO) (no hay curl ni nc en la imagen).
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 CMD ["/usr/local/bin/healthcheck.sh"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]
