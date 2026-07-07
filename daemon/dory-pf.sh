#!/bin/sh
# Script de redirección de puertos nativo para macOS PF (Packet Filter)
# Administrado por Dory Port Forwarder GUI

CONF="/Users/aleksdj/.dory/port-forwards.conf"
ANCHOR="com.dory.rdr"
rules=""

if [ -f "$CONF" ]; then
  while read -r from to _; do
    case "$from" in ""|\#*) continue ;; esac
    [ -n "$to" ] || continue
    
    # Validar que los puertos sean numéricos
    case "$from$to" in *[!0-9]*) echo "dory-pf: linea invalida ignorada: $from $to" >&2; continue ;; esac
    
    # Validar el rango de puertos TCP (1 - 65535)
    if [ "$from" -ge 1 ] && [ "$from" -le 65535 ] && [ "$to" -ge 1 ] && [ "$to" -le 65535 ]; then
      rules="${rules}rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port = $from -> 127.0.0.1 port $to
rdr pass on lo0 inet6 proto tcp from any to ::1 port = $from -> ::1 port $to
"
    fi
  done < "$CONF"
fi

# Habilitar PF y aplicar las reglas en el ancla com.dory.rdr
/sbin/pfctl -E 2>/dev/null || true
printf '%s' "$rules" | /sbin/pfctl -a "$ANCHOR" -f -
