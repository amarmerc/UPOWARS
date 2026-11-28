#!/bin/sh
# Sano = el proceso escucha en el puerto UDP configurado (ENet abre el socket al iniciar el servidor).
hex=$(printf '%04X' "${PUERTO:-7777}")
grep -qi ":${hex} " /proc/net/udp /proc/net/udp6 2>/dev/null
