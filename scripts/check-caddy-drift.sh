#!/usr/bin/env bash
# Read-only gate: refuse service updates after another installer replaces ingress.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAIN="${DOMAIN:-search.karldigi.dev}"
LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1:8080}"
TARGET="${1:-${INSTALL_ROOT:-}${CADDY_SNIPPET:-/etc/caddy/Caddyfile.code-guda-gateway}}"
EXPECTED="$(mktemp)"
trap 'rm -f "$EXPECTED"' EXIT
DOMAIN="$DOMAIN" LISTEN_ADDR="$LISTEN_ADDR" bash "$ROOT/scripts/render-caddy.sh" > "$EXPECTED"
if [[ ! -f "$TARGET" ]] || ! cmp -s "$EXPECTED" "$TARGET"; then
  echo 'Caddy configuration drift: reapply the reviewed stack template, validate the full Caddy config, then reload before updating the service.' >&2
  exit 1
fi
printf 'Stack Caddy configuration matches the reviewed template.\n'
