#!/bin/sh
# Exporta el cliente WEB de UPOWARS (HTML5/WASM) con Docker y lo copia al directorio que sirve nginx.
#   Uso:  ./servidor/exportar_web.sh [directorio_destino]        (por defecto /var/www/upowars; o variable DESTINO_WEB)
# La primera vez descarga el editor y las plantillas de exportacion de Godot (~1 GB, verificadas con SHA-512); las siguientes veces
# Docker reutiliza la cache y solo repite la exportacion si cambia game/. Hace falta Docker con BuildKit (docker buildx).
set -eu

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DESTINO="${1:-${DESTINO_WEB:-/var/www/upowars}}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/upowars-web.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# sudo solo si hace falta para escribir en el destino
SUDO=""
PADRE="$(dirname "$DESTINO")"
if [ ! -w "$PADRE" ] || { [ -e "$DESTINO" ] && [ ! -w "$DESTINO" ]; }; then
    SUDO="sudo"
fi

echo "[exportar_web] construyendo la exportacion web (la primera vez descarga ~1 GB de plantillas)..."
DOCKER_BUILDKIT=1 docker build -f "$RAIZ/servidor/Dockerfile.web" --target web --output "type=local,dest=$TMP/web" "$RAIZ"
test -f "$TMP/web/index.html" || { echo "ERROR: la exportacion no genero index.html" >&2; exit 1; }

echo "[exportar_web] instalando en $DESTINO"
$SUDO mkdir -p "$PADRE"
$SUDO rm -rf "$DESTINO.nuevo"
$SUDO cp -a "$TMP/web" "$DESTINO.nuevo"
# legible por nginx (www-data en Debian/Ubuntu): directorios 755, ficheros 644
$SUDO find "$DESTINO.nuevo" -type d -exec chmod 755 {} +
$SUDO find "$DESTINO.nuevo" -type f -exec chmod 644 {} +
if id www-data >/dev/null 2>&1; then
    $SUDO chown -R www-data:www-data "$DESTINO.nuevo"
fi
# cambio casi atomico: nginx no sirve nunca una carpeta a medias
if [ -e "$DESTINO" ]; then
    $SUDO rm -rf "$DESTINO.viejo"
    $SUDO mv "$DESTINO" "$DESTINO.viejo"
fi
$SUDO mv "$DESTINO.nuevo" "$DESTINO"
$SUDO rm -rf "$DESTINO.viejo"

echo "[exportar_web] listo:"
ls -l "$DESTINO"
