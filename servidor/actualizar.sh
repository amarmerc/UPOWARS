#!/bin/sh
# Actualiza el servidor: git pull, reconstruye la imagen y reinicia el contenedor. Ejecutar en la VM:  ./servidor/actualizar.sh
# Las partidas en curso se cortan al reiniciar.
set -eu
cd "$(dirname "$0")"
git pull --ff-only
docker compose up -d --build
docker image prune -f >/dev/null
docker compose ps
echo "Listo. Logs:  docker compose logs -f --tail 50"
