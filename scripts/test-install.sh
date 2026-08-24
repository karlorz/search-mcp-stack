#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file $1 to exist"
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -Fq -- "$pattern" "$file" || fail "expected $file to contain: $pattern"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -Fq -- "$pattern" "$file"; then
    fail "expected $file NOT to contain: $pattern"
  fi
}

assert_equals() {
  local want="$1"
  local got="$2"
  [[ "$want" == "$got" ]] || fail "expected [$want], got [$got]"
}

printf '=== Step 1: Static checks on repo files ===\n'

VERSIONS_FILE="$ROOT/versions.env"
assert_file "$VERSIONS_FILE"

# Assert versions.env SHAs are 40-hex
GROKSEARCH_SHA="$(grep '^GROKSEARCH_SHA=' "$VERSIONS_FILE" | cut -d= -f2)"
GUDA_GATEWAY_SHA="$(grep '^GUDA_GATEWAY_SHA=' "$VERSIONS_FILE" | cut -d= -f2)"

[[ "$GROKSEARCH_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "GROKSEARCH_SHA is not a 40-hex SHA: $GROKSEARCH_SHA"
[[ "$GUDA_GATEWAY_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "GUDA_GATEWAY_SHA is not a 40-hex SHA: $GUDA_GATEWAY_SHA"

assert_equals "aeb0f752c8ef086059db1aec5aa4ba3c3dba6844" "$GROKSEARCH_SHA"
assert_equals "6c95d8e8488f64d284cd48e4eeb8d8ff17590d6f" "$GUDA_GATEWAY_SHA"

# Assert systemd unit template / source
UNIT_SRC="$ROOT/systemd/grok-search-mcp.service"
assert_file "$UNIT_SRC"
assert_contains "$UNIT_SRC" "uv run --frozen"
assert_contains "$UNIT_SRC" "127.0.0.1"
assert_contains "$UNIT_SRC" "EnvironmentFile="
assert_contains "$UNIT_SRC" "NoNewPrivileges=true"
assert_contains "$UNIT_SRC" "ProtectSystem=strict"
assert_contains "$UNIT_SRC" "ProtectHome=true"
assert_contains "$UNIT_SRC" "PrivateTmp=true"
assert_contains "$UNIT_SRC" "PrivateDevices=true"
assert_contains "$UNIT_SRC" "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX"
assert_contains "$UNIT_SRC" "RestrictRealtime=true"
assert_contains "$UNIT_SRC" "LockPersonality=true"
assert_contains "$UNIT_SRC" "MemoryDenyWriteExecute=true"

# Assert env example
ENV_EXAMPLE="$ROOT/systemd/grok-search-mcp.env.example"
assert_file "$ENV_EXAMPLE"
assert_contains "$ENV_EXAMPLE" "GROK_SEARCH_MCP_VERIFY_URL=http://127.0.0.1:8080/internal/keys/verify"
assert_contains "$ENV_EXAMPLE" "GROK_SEARCH_MCP_HOST=127.0.0.1"
assert_contains "$ENV_EXAMPLE" "GROK_SEARCH_MCP_PORT=8800"
assert_contains "$ENV_EXAMPLE" "GROK_SEARCH_MCP_PATH=/mcp"
# Ensure no real tokens assigned
if grep -E '^GROK_SEARCH_MCP_INTERNAL_TOKEN=[^#[:space:]]+' "$ENV_EXAMPLE" >/dev/null; then
  fail "env example should not contain real GROK_SEARCH_MCP_INTERNAL_TOKEN value"
fi
if grep -E '^GUDA_API_KEY=[^#[:space:]]+' "$ENV_EXAMPLE" >/dev/null; then
  fail "env example should not contain real GUDA_API_KEY value"
fi

# Assert Caddy template / snippet
CADDY_SRC="$ROOT/caddy/Caddyfile.code-guda-gateway"
assert_file "$CADDY_SRC"
assert_contains "$CADDY_SRC" "handle /internal*"
assert_contains "$CADDY_SRC" "respond 404"
assert_contains "$CADDY_SRC" "handle /mcp*"
assert_contains "$CADDY_SRC" "reverse_proxy 127.0.0.1:8800"
assert_contains "$CADDY_SRC" "flush_interval -1"
assert_not_contains "$CADDY_SRC" "handle_path"

# Assert Dockerfile
DOCKERFILE="$ROOT/docker/Dockerfile"
assert_file "$DOCKERFILE"
assert_contains "$DOCKERFILE" "uv"
assert_not_contains "$DOCKERFILE" "COPY .env"
assert_not_contains "$DOCKERFILE" "COPY *.env"

# Assert docker-compose.coolify.yml
COMPOSE_COOLIFY="$ROOT/docker/docker-compose.coolify.yml"
assert_file "$COMPOSE_COOLIFY"
# Must not publish host port directly (avoid conflicting with host / Traefik)
if grep -E '^\s*-\s*["'\'']?[0-9]+:8800' "$COMPOSE_COOLIFY" >/dev/null; then
  fail "docker-compose.coolify.yml must not publish host ports directly"
fi

# Assert no leaked secrets in repo tree
if grep -rnE '(gsk_[a-zA-Z0-9_-]{20,}|sk-[a-zA-Z0-9_-]{20,})' "$ROOT" --exclude-dir=.git | grep -v 'test-install.sh' >/dev/null; then
  fail "Found apparent real secret tokens (gsk_... or sk-...) in repository"
fi

printf '=== Step 2: Test install.sh rendering in fake root ===\n'

FAKE_ROOT="$TMP/root"
mkdir -p "$FAKE_ROOT"

assert_file "$ROOT/install.sh"
chmod +x "$ROOT/install.sh"

SEARCH_STACK_TEST_MODE=1 INSTALL_ROOT="$FAKE_ROOT" \
  "$ROOT/install.sh" \
  --render-only \
  --domain search.karldigi.dev \
  --listen-addr 127.0.0.1:8080 >/dev/null

INSTALLED_SERVICE="$FAKE_ROOT/etc/systemd/system/grok-search-mcp.service"
INSTALLED_ENV="$FAKE_ROOT/etc/grok-search-mcp.env"
INSTALLED_CADDY="$FAKE_ROOT/etc/caddy/Caddyfile.code-guda-gateway"

assert_file "$INSTALLED_SERVICE"
assert_file "$INSTALLED_ENV"
assert_file "$INSTALLED_CADDY"

assert_contains "$INSTALLED_SERVICE" "uv run --frozen"
assert_contains "$INSTALLED_SERVICE" "EnvironmentFile=/etc/grok-search-mcp.env"
assert_contains "$INSTALLED_SERVICE" "User=groksearch"

assert_contains "$INSTALLED_CADDY" "search.karldigi.dev {"
assert_contains "$INSTALLED_CADDY" "handle /internal*"
assert_contains "$INSTALLED_CADDY" "respond 404"
assert_contains "$INSTALLED_CADDY" "handle /mcp*"
assert_contains "$INSTALLED_CADDY" "reverse_proxy 127.0.0.1:8800"
assert_contains "$INSTALLED_CADDY" "flush_interval -1"
assert_contains "$INSTALLED_CADDY" "reverse_proxy 127.0.0.1:8080"
assert_not_contains "$INSTALLED_CADDY" "handle_path"
assert_not_contains "$INSTALLED_CADDY" "{{DOMAIN}}"
assert_not_contains "$INSTALLED_CADDY" "{{LISTEN_ADDR}}"

printf '=== Step 3: Test idempotency (do not overwrite existing env) ===\n'

printf 'EXISTING_CUSTOM_CONFIG=keep_me\n' > "$INSTALLED_ENV"

SEARCH_STACK_TEST_MODE=1 INSTALL_ROOT="$FAKE_ROOT" \
  "$ROOT/install.sh" \
  --render-only >/dev/null

assert_contains "$INSTALLED_ENV" "EXISTING_CUSTOM_CONFIG=keep_me"
assert_not_contains "$INSTALLED_ENV" "GROK_SEARCH_MCP_TRANSPORT=http"

printf '=== Step 4: Test update.sh dry-run / test-mode ===\n'

assert_file "$ROOT/update.sh"
chmod +x "$ROOT/update.sh"

SEARCH_STACK_TEST_MODE=1 INSTALL_ROOT="$FAKE_ROOT" \
  "$ROOT/update.sh" \
  --dry-run >/dev/null

printf 'All tests passed successfully.\n'
