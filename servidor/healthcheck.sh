#!/bin/sh
# Sano = el proceso escucha en su puerto: UDP (ENet) por defecto, o TCP en estado LISTEN si hay WS_PUERTO (modo WebSocket).
if [ -n "${WS_PUERTO:-}" ]; then
    hex=$(printf '%04X' "$WS_PUERTO")
    grep -qi ":${hex} .* 0A " /proc/net/tcp /proc/net/tcp6 2>/dev/null
else
    hex=$(printf '%04X' "${PUERTO:-7777}")
    grep -qi ":${hex} " /proc/net/udp /proc/net/udp6 2>/dev/null
fi
