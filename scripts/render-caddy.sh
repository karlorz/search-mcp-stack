#!/usr/bin/env bash
# One renderer shared by installation and the read-only drift check.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAIN="${DOMAIN:-search.karldigi.dev}"
LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1:8080}"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || { echo 'Invalid domain' >&2; exit 1; }
[[ "$LISTEN_ADDR" =~ ^127\.0\.0\.1:[0-9]+$ ]] || { echo 'Gateway listen address must be loopback' >&2; exit 1; }
sed -e "s|{{DOMAIN}}|$DOMAIN|g" -e "s|{{LISTEN_ADDR}}|$LISTEN_ADDR|g" "$ROOT/caddy/Caddyfile.code-guda-gateway"
