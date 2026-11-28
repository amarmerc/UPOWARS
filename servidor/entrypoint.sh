#!/bin/sh
# Punto de entrada del servidor dedicado de UPOWARS. Traduce variables de entorno a los argumentos de `-- --servidor` (ver
# game/scripts/red/arranque_red.gd) y lanza Godot en headless con `exec` (Godot pasa a ser el proceso que recibe SIGTERM de tini).
#
# Variables (todas opcionales; lo que no se defina usa el valor por defecto del servidor):
#   PUERTO=7777  MAX=10  MODO=cachimba_wars|pleno|libre  ZONA=<id>  TAM=5  RONDAS=7  T_COMPRA=25  DIFICULTAD=normal  LAG=0  PERDIDA=0
#   EXTRA="..."          argumentos adicionales literales para el juego (sin espacios dentro de cada argumento)
#   GODOT_BIN, PROYECTO  rutas (en el contenedor: /opt/godot/godot y /juego); sirven tambien para probar fuera de Docker.
set -eu

GODOT_BIN="${GODOT_BIN:-/opt/godot/godot}"
PROYECTO="${PROYECTO:-/juego}"

# Un valor valido es alfanumerico con _ . - (sin espacios ni comillas) para no inyectar argumentos.
valida() {   # valida NOMBRE VALOR
    case "$2" in
        ''|*[!A-Za-z0-9_.-]*) echo "ERROR: valor no valido para $1: '$2'" >&2; exit 64 ;;
    esac
}

PUERTO="${PUERTO:-7777}"
MAX="${MAX:-10}"
valida PUERTO "$PUERTO"
valida MAX "$MAX"
set -- "--servidor" "puerto=$PUERTO" "max=$MAX"

for par in MODO:modo ZONA:zona TAM:tam RONDAS:rondas T_COMPRA:t_compra DIFICULTAD:dificultad; do
    var="${par%%:*}"; clave="${par#*:}"
    eval "val=\${$var:-}"
    if [ -n "$val" ]; then
        valida "$var" "$val"
        set -- "$@" "$clave=$val"
    fi
done
if [ -n "${LAG:-}" ];     then valida LAG "$LAG";         set -- "$@" "--lag=$LAG"; fi
if [ -n "${PERDIDA:-}" ]; then valida PERDIDA "$PERDIDA"; set -- "$@" "--perdida=$PERDIDA"; fi
if [ -n "${EXTRA:-}" ];   then
    # shellcheck disable=SC2086
    set -- "$@" $EXTRA
fi

echo "[entrypoint] $GODOT_BIN --headless --path $PROYECTO -- $*"
# --headless = display driver headless + audio Dummy + renderer dummy (sin GPU). No usar --fixed-fps: desacopla el tiempo del reloj.
exec "$GODOT_BIN" --headless --audio-driver Dummy --path "$PROYECTO" -- "$@"
