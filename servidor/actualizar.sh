#!/bin/sh
# Actualiza el servidor: git pull, reconstruye la imagen, reinicia los contenedores y reexporta el cliente web. Ejecutar en la VM:  ./servidor/actualizar.sh
# Las partidas en curso se cortan al reiniciar.
set -eu
cd "$(dirname "$0")"
git pull --ff-only
docker compose up -d --build            # servidor (ENet/UDP) y servidor-web (WebSocket)
docker image prune -f >/dev/null
docker compose ps
# Cliente web: reexporta y copia a /var/www/upowars (o DESTINO_WEB). Si no se quiere: WEB=0 ./actualizar.sh
if [ "${WEB:-1}" != "0" ]; then
    ./exportar_web.sh
fi
echo "Listo. Logs:  docker compose logs -f --tail 50"
