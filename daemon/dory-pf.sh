#!/bin/sh
# dory-pf helper v2: persistent pf anchor file + watchdog reapply
# Template path. The GUI installer generates a user-specific copy in /usr/local/libexec.

CONF="/Users/REPLACE_ME/.dory/port-forwards.conf"
ANCHOR="com.dory.rdr"
ANCHOR_FILE="/etc/pf.anchors/$ANCHOR"
PF_CONF="/etc/pf.conf"
TMP="$(mktemp /tmp/dory-pf-anchor.XXXXXX)" || exit 1
changed=0
rule_count=0
trap 'rm -f "$TMP"' EXIT

if [ -f "$CONF" ]; then
  while read -r from to _; do
    case "$from" in ""|\#*) continue ;; esac
    [ -n "$to" ] || continue

    case "$from$to" in *[!0-9]*) echo "$(date '+%Y-%m-%d %H:%M:%S') dory-pf: invalid line ignored: $from $to" >&2; continue ;; esac

    if [ "$from" -ge 1 ] && [ "$from" -le 65535 ] && [ "$to" -ge 1 ] && [ "$to" -le 65535 ]; then
      # Dory's proxy binds IPv4 loopback high ports. Keep the pf rule IPv4-only,
      # matching Dory's own networking helper and avoiding ::1 -> ::1 stalls.
      printf 'rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port %s -> 127.0.0.1 port %s\n' "$from" "$to" >> "$TMP"
      rule_count=$((rule_count + 1))
    fi
  done < "$CONF"
fi

mkdir -p /etc/pf.anchors
if [ ! -f "$ANCHOR_FILE" ] || ! cmp -s "$TMP" "$ANCHOR_FILE"; then
  install -o root -g wheel -m 644 "$TMP" "$ANCHOR_FILE"
  changed=1
fi

if ! grep -q 'rdr-anchor "com.dory.rdr"' "$PF_CONF" 2>/dev/null; then
  PF_TMP="$PF_CONF.dory-pf.$$"
  inserted=0
  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$PF_TMP"
    if [ "$line" = 'rdr-anchor "com.apple/*"' ]; then
      printf '# dory-pf: rules loaded by /usr/local/libexec/dory-pf.sh from ~/.dory/port-forwards.conf\n' >> "$PF_TMP"
      printf 'rdr-anchor "com.dory.rdr"\n' >> "$PF_TMP"
      inserted=1
    fi
  done < "$PF_CONF"
  if [ "$inserted" -eq 0 ]; then
    printf '\n# dory-pf: rules loaded by /usr/local/libexec/dory-pf.sh from ~/.dory/port-forwards.conf\n' >> "$PF_TMP"
    printf 'rdr-anchor "com.dory.rdr"\n' >> "$PF_TMP"
  fi
  cat "$PF_TMP" > "$PF_CONF" && rm -f "$PF_TMP"
  changed=1
fi
if ! grep -q 'load anchor "com.dory.rdr"' "$PF_CONF" 2>/dev/null; then
  printf 'load anchor "com.dory.rdr" from "/etc/pf.anchors/com.dory.rdr"\n' >> "$PF_CONF"
  changed=1
fi

/sbin/pfctl -s info 2>/dev/null | grep -q "Status: Enabled" || /sbin/pfctl -e 2>/dev/null || true
if ! /sbin/pfctl -s nat 2>/dev/null | grep -q 'rdr-anchor "com.dory.rdr"'; then
  changed=1
fi

if [ "$changed" -eq 1 ]; then
  # Only reload the main PF ruleset when the anchor wiring changed or disappeared.
  # Reloading it on every watchdog tick can flush container runtime NAT rules.
  /sbin/pfctl -f "$PF_CONF" >/dev/null 2>&1 || /sbin/pfctl -f "$PF_CONF" 2>&1
else
  /sbin/pfctl -a "$ANCHOR" -f "$ANCHOR_FILE" >/dev/null 2>&1 || /sbin/pfctl -a "$ANCHOR" -f "$ANCHOR_FILE" 2>&1
fi
echo "$(date '+%Y-%m-%d %H:%M:%S') dory-pf: applied $rule_count rule(s); changed=$changed"
